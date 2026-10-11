import AppKit

/// Câblage de l'app : bridge ⇄ index ⇄ palette ⇄ hotkey.
/// Machine à états (docs/ARCHITECTURE.md §2.2) : Idle → WaitingPlugin → Ready.
final class AppCoordinator {

    private let log = Logger.shared
    private let server = BridgeServer()
    private let palette = PaletteWindowController()

    /// Index prêt pour la recherche (préparé une seule fois par (re)construction)
    private var prepared: [Scorer.PreparedItem] = []
    private var effectsCache: [IndexStore.EffectEntry] = []
    /// Lookup id → SearchItem, reconstruit à chaque (re)construction d'index :
    /// permet de résoudre un raccourci preset AU MOMENT du fire (l'index peut
    /// avoir été reconstruit depuis l'enregistrement du raccourci).
    private var itemLookup: [String: SearchItem] = [:]
    /// Titre normalisé → ids DISTINCTS qui le portent (C-04) : rattachement par le titre.
    private var idsByTitle: [String: Set<String>] = [:]
    /// Ids Carbon actuellement enregistrés pour les raccourcis presets (à
    /// désenregistrer avant de réappliquer des réglages qui en retirent).
    private var presetHotkeyIds: [UInt32] = []

    private var presetWatcher: DispatchSourceFileSystemObject?
    private var reindexDebounce: DispatchWorkItem?
    private var listenRetries = 0
    private let settings = SettingsStore()
    /// Classement « fréquence + récence » des items appliqués (palette à vide).
    private let usage = UsageStore()
    /// Nombre de duos montrés en tête des fréquents. Deux : au-delà, ils
    /// chassent de la liste les items simples qu'on vient y chercher.
    static let maxCombosShown = 2
    /// Délai avant de conclure qu'un plugin déconnecté ne reviendra pas seul.
    /// 45 s : large devant les 2 s de la boucle de reconnexion et devant un
    /// changement de projet, court devant une session de montage.
    static let pluginRevivalDelay: TimeInterval = 45
    /// Deux réinstallations ne peuvent pas s'enchaîner plus vite que ça : UPIA
    /// se bloque sur des cycles rapprochés (AGENTS.md §6).
    static let pluginRevivalCooldown: TimeInterval = 600
    private var lastRevivalAttempt: Date?
    private let pluginLifecycle = PluginLifecycleService()
    private lazy var settingsWindow = SettingsWindowController(store: settings)
    private let statusItem = StatusItemController()
    private let onboarding = OnboardingWindowController()
    private let updates = UpdateService()
    /// Dernier état connu du consentement aux rapports de plantage.
    private var crashConsent = false
    private static var embeddedPluginVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "KhanjarPluginVersion") as? String
    }

    // MARK: - Démarrage

    func start() throws {
        // 0. Historique d'usage AVANT tout installItems : celui-ci amorce le
        //    classement depuis helper.log si le fichier n'est pas encore chargé.
        //    Charger après aurait réécrit usage.json à chaque démarrage — et le
        //    journal étant tronqué au-delà de 5 Mo (Logger), l'historique aurait
        //    fini par se perdre au lieu d'être conservé.
        usage.load()

        // 1. Index immédiatement utilisable depuis le snapshot (si présent)
        if let snapshot = IndexStore.loadSnapshot() {
            installItems(snapshot.items, origin: "snapshot (\(snapshot.premiereVersion))")
            realIndexInstalled = true
        } else {
            // Snapshot absent, ou d'une version antérieure (v6 avant le passage aux
            // nouveaux ids, 2026-10-09) : index provisoire reconstruit hors ligne.
            rebuildIndexOffline()
        }

        // 2. Bridge
        server.onHello = { [weak self] info in
            guard let self else { return }
            self.log.info("Plugin prêt : \(info.pluginVersion) / Premiere \(info.hostVersion)")
            self.pluginWaitSince = nil
            self.pluginSilentSince = nil
            // C-01 : un hello clôt la chaîne d'installation en cours.
            self.installCheck?.cancel()
            self.installCheck = nil
            self.installFailures = 0
            self.installIssue = nil
            self.premiereHadSession = true
            self.reconcileConnectedPlugin(info)
            self.sessionSerial += 1   // C-16 : les reprises de listEffects d'une session précédente s'éteignent
            self.rebuildIndexFromPlugin()
            // La version de Premiere n'est connue qu'ici : ré-armer la
            // surveillance sur le profil de CETTE version (cf. userPresetFile).
            self.watchUserPresets()
            self.pluginStateChanged()
        }
        // Si Premiere tourne mais qu'aucun plugin ne se connecte, tenter
        // l'installation du ccx embarqué (premier lancement sur machine vierge).
        scheduleInstallCheck(after: 20)
        // M1 : Khanjar mis à jour (Sparkle) pendant que Premiere est fermé → le plugin
        // inscrit chez Adobe est mis à niveau tout de suite, sans attendre Premiere.
        scheduleClosedUpgrade("lancement de Khanjar", after: PluginInstallPolicy.afterKhanjarLaunch)
        // ⚠️ CAS NOMINAL D'UN NOUVEL UTILISATEUR : il lance Khanjar (ou Khanjar
        // démarre avec la session) PUIS ouvre Premiere. La tentative unique à
        // T+20 s ne voyait alors aucun Premiere → le plugin n'était JAMAIS
        // installé et ⌘J restait muet pour toujours. On observe donc aussi le
        // lancement de Premiere.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, app?.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true else { return }
            // C-01 (2026-10-09) — 15 s ne suffisaient pas : AppKit dit « lancé » bien
            // avant que Premiere ait chargé ses plug-ins, et UPIA partait en plein
            // démarrage (blocage de 3 min, AGENTS §6). Le plugin déjà déposé se
            // connecte seul en ~13 s : attendre 60 s ne coûte rien.
            let delay = PluginInstallPolicy.launchGrace + 1
            self.log.info("Premiere lancé — vérification du plugin dans \(Int(delay)) s")
            self.pluginWaitSince = nil
            // Le silence se compte depuis CE lancement : avant, ⌘J pendant le
            // démarrage voyait « 12 h sans plugin » (depuis la veille) et forçait
            // une réinstallation pendant le démarrage (B4 n°7).
            self.pluginSilentSince = Date()
            self.premiereLaunchSeenAt = Date()
            self.premiereHadSession = false
            // S2 dit « quitte et rouvre Premiere » : une relance remet les essais à zéro.
            self.installFailures = 0
            self.installIssue = nil
            self.tooOldNotifiedPid = nil
            self.revivalArmedAfterSilentInstall = false
            self.scheduleInstallCheck(after: delay)
            self.pluginStateChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true else { return }
            self?.pluginStateChanged()
            // M1 : plugin plus ancien que l'embarqué → mis à niveau maintenant que Premiere est fermé.
            self?.scheduleClosedUpgrade("fermeture de Premiere", after: PluginInstallPolicy.afterPremiereQuit)
        }
        // C-08 : Premiere redevenu l'app active (le monteur revient des Réglages Système,
        // où il vient peut-être d'autoriser Documents) → relire les presets perso.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true else { return }
            self?.recheckUserPresetsIfNeeded("Premiere au premier plan")
        }
        // L'ancien plugin Dagger se présente encore : on le retire chez Adobe.
        server.onLegacyPlugin = { [weak self] in
            self?.removeLegacyPlugin()
        }
        server.onDisconnect = { [weak self] in
            guard let self else { return }
            self.pluginSilentSince = Date()
            self.pluginStateChanged()
            self.log.info("Plugin déconnecté — reconnexion attendue")
            // Un plugin VIVANT se reconnecte seul en 2 s (WsClient). S'il ne
            // revient pas, c'est qu'Adobe ne le charge plus — constaté le
            // 2026-10-06 : la mise à jour Premiere 26.5.1 → 26.5.2 avait effacé
            // son inscription UPIA (--remove répondait -406, la liste ne montrait
            // que Logi Options+ et Spell Book). Premiere chargeait le dossier
            // résiduel une fois au démarrage puis le lâchait au bout de 27 s.
            // Sans ce filet, ⌘J restait muet jusqu'au prochain lancement de
            // l'app : 40 minutes perdues ce jour-là, en plein montage.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pluginRevivalDelay) { [weak self] in
                self?.revivePluginIfStillSilent()
            }
        }
        // Port pris = le plus souvent l'ancienne instance en cours de sortie
        // pendant une mise à jour (constaté 2026-07-11) : on réessaie avant de
        // conclure à un vrai conflit. Sans bridge, l'app est inutile → arrêt,
        // en laissant le journal se vider (écriture asynchrone).
        server.onListenerFailed = { [weak self] error in
            guard let self else { return }
            self.listenRetries += 1   // remis à zéro dès que le pont écoute (onListenerReady)
            if self.listenRetries <= 5 {
                self.log.info("Port occupé (\(error)) — nouvel essai \(self.listenRetries)/5 dans 1 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { try? self.server.start() }
                return
            }
            self.log.error("Bridge indisponible (\(error)) — une autre instance de Khanjar tourne ? Arrêt.")
            // C-13 (2026-10-09) — l'app quittait sans rien montrer : avec le démarrage
            // automatique, l'icône apparaissait puis disparaissait 6 s plus tard, à
            // chaque ouverture de session, sans dire pourquoi. On nomme l'app qui
            // tient le port (lsof, borné à 2 s, hors du fil principal), puis on quitte.
            DispatchQueue.global(qos: .userInitiated).async {
                let holder = Self.portHolderName(port: Bridge.defaultPort)
                DispatchQueue.main.async { self.quitBecausePortIsTaken(holder: holder) }
            }
        }
        // Sans remise à zéro, 6 échecs cumulés sur toute la vie de l'app suffisaient à l'arrêter.
        server.onListenerReady = { [weak self] in self?.listenRetries = 0 }
        try server.start()

        // 3. Réglages (chargés avant hotkey/palette, appliqués à chaud ensuite)
        // C-10 (2026-10-09) : problèmes de settings.json branchés AVANT load() (contrat
        // §4.7) — un fichier illisible au démarrage passait aux défauts sans un mot.
        settings.onIssue = { issue in
            let text = Self.settingsIssueMessage(issue)
            // Au démarrage, la boucle d'événements ne tourne pas encore : au premier tour.
            DispatchQueue.main.async { HUD.show(text, duration: 6, style: .warning) }
        }
        settings.load()
        settings.onChange = { [weak self] s in
            self?.applySettings(s)
            // Case « rapports de plantage » cochée à l'instant : envoyer sans attendre
            // le prochain lancement.
            if s.sendsCrashReports && !(self?.crashConsent ?? true) {
                CrashReporter.sendPendingIfConsented(true, pluginVersion: Self.embeddedPluginVersion)
            }
            self?.crashConsent = s.sendsCrashReports
        }
        crashConsent = settings.current.sendsCrashReports
        CrashReporter.sendPendingIfConsented(crashConsent, pluginVersion: Self.embeddedPluginVersion)

        // 4. Hotkeys (palette + calque d'effets)
        applySettings(settings.current)

        // 4. Palette
        palette.onQuery = { [weak self] query in
            guard let self else { return [] }
            return Scorer.rank(query: query, prepared: self.prepared, limit: self.palette.maxResults)
        }
        // C-02 point 5 (contrat §4.6, 2026-10-09) : une validation refusée parce qu'une
        // application tourne encore laisse la palette OUVERTE (HUD S15) ; avant, elle se
        // fermait et le choix du monteur était perdu.
        palette.onCommitChecked = { [weak self] item in self?.apply(item, origin: .palette) ?? false }
        // Champ vide → classement fréquence + récence (voir frequentRows).
        palette.onFrequent = { [weak self] limit in
            guard let self else { return [] }
            return Self.frequentRows(limit: limit,
                                     ranked: self.usage.top(limit * 2),
                                     pairs: self.usage.topPairs(5),
                                     lookup: self.itemLookup,
                                     titleOf: { self.usage.title(for: $0) },
                                     idsForTitle: { [idsByTitle = self.idsByTitle] in
                                         idsByTitle[SearchItem.normalizedTitle($0)] ?? [] })
        }

        // 5. Presets : surveillance du fichier utilisateur
        watchUserPresets()

        // 6. Barre de menus + fenêtre de réglages
        // C-05 : la ligne d'état dit l'état réel (connexion, installation, échec,
        // redémarrage nécessaire…), pas « En attente de Premiere… » Premiere ouvert.
        let statusText: () -> String = { [weak self] in
            self?.currentPluginStatus().statusLine ?? ""
        }
        let paletteShortcut: () -> String = { [weak self] in
            SettingsStore.pretty(self?.settings.current.shortcut ?? "cmd+j")
        }
        statusItem.statusProvider = statusText
        statusItem.paletteShortcutProvider = paletteShortcut
        settingsWindow.statusProvider = statusText
        statusItem.onOpenSettings = { [weak self] in self?.settingsWindow.open() }
        statusItem.onAddAdjustmentLayer = { [weak self] in self?.addAdjustmentLayer() }
        statusItem.onOpenPalette = { [weak self] in self?.summon() }
        statusItem.onShowGuide = { [weak self] in self?.onboarding.open() }
        if pluginLifecycle.embeddedCcx != nil {
            statusItem.onReinstallPlugin = { [weak self] in self?.reinstallPluginFromMenu() }
            statusItem.canReinstallPlugin = { [weak self] in !(self?.pluginLifecycle.busy ?? true) }
        }
        statusItem.setConnected(server.isReady)   // éteinte jusqu'au premier hello
        updates.onGentleReminder = { [weak self] available in
            self?.statusItem.setUpdateAvailable(available)
        }
        updates.start()
        if updates.isRunning {
            statusItem.onCheckForUpdates = { [weak self] in self?.updates.checkForUpdates() }
        }
        // Recherche pour la fenêtre Réglages (assignation raccourci → preset)
        settingsWindow.searchProvider = { [weak self] query in
            guard let self else { return [] }
            return Scorer.rank(query: query, prepared: self.prepared, limit: 12).map { $0.item }
        }
        onboarding.statusProvider = statusText
        onboarding.paletteShortcutProvider = paletteShortcut
        onboarding.crashReportsEnabled = { [weak self] in self?.settings.current.sendsCrashReports ?? false }
        onboarding.setCrashReports = { [weak self] enabled in
            guard let self else { return }
            var s = self.settings.current
            s.crashReports = enabled
            self.settings.save(s)
        }

        // C-13 (2026-10-09) — une 2ᵉ copie lancée d'un autre dossier quittait sans
        // rien montrer : elle prévient maintenant celle-ci, qui ouvre ses Réglages.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showSettingsNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.log.info("Une autre copie de Khanjar a été ouverte — ouverture des Réglages de celle-ci")
            self?.openSettings()
        }

        // 7. Hooks de test sans clavier (documentés dans le README)
        // C-14 (2026-10-09) — ils étaient actifs dans l'app publiée : SIGWINCH, que
        // tout terminal redimensionné envoie à l'app qu'il a lancée, posait un calque
        // d'effets dans la séquence ; et n'importe quel processus du compte pouvait
        // appliquer « gauss » (SIGUSR2) sans le filtre « Premiere au premier plan »
        // (audits A2 n°14, A6). Seulement avec KHANJAR_TEST_HOOKS=1 désormais ;
        // sinon les quatre signaux restent ignorés (un SIGUSR1 égaré ne tue pas l'app).
        if Self.testHooksEnabled(ProcessInfo.processInfo.environment) {
            installSignalHooks()
            log.info("Crochets de test actifs (KHANJAR_TEST_HOOKS=1) : SIGUSR1, SIGUSR2, SIGWINCH, SIGINFO")
        } else {
            for sig in [SIGUSR1, SIGUSR2, SIGWINCH, SIGINFO] { signal(sig, SIG_IGN) }
        }

        // 8. Écran d'accueil au tout premier lancement (point de contact clé
        //    pour un nouvel utilisateur — sinon il ne voit qu'une icône muette).
        onboarding.showIfFirstLaunch()

        log.info("Khanjar prêt — ⌘J dans Premiere pour ouvrir la palette")
    }

    /// Installe le plugin si Premiere tourne et qu'aucun plugin n'est connecté.
    /// Idempotent : ne fait rien si le pont est déjà prêt. UPIA tourne en
    /// arrière-plan (PluginLifecycleService sérialise ses appels).
    ///
    /// POLITIQUE (2026-09-19, après 3 min de gel mesurées) :
    ///  1. Premiere doit avoir FINI de démarrer (UPIA sollicité pendant le
    ///     lancement reste bloqué) — sinon on revérifie dans 15 s ;
    ///  2. si le dossier versionné du plugin existe déjà, on laisse Premiere le
    ///     charger et se connecter (aucun UPIA) ;
    ///  3. si, 60 s après le premier contrôle, toujours aucun hello → une
    ///     réinstallation FORCÉE (dossier présent mais non chargé : enregistrement
    ///     UPIA incohérent), en arrière-plan.
    private var pluginWaitSince: Date?
    /// Recherche ET ligne à reproposer au prochain ⌘J après un échec rattrapable venu
    /// de la palette (60 s) — C-09.
    private var retryQuery: (query: String, itemId: String, at: Date)?
    /// Depuis quand aucun plugin n'est connecté (lancement de l'app, lancement de
    /// Premiere ou déconnexion).
    private var pluginSilentSince: Date? = Date()

    // C-01 (2026-10-09) — état de la chaîne d'installation (voir PluginInstallPolicy).
    /// Prochain contrôle programmé (un seul à la fois : le plus récent remplace).
    private var installCheck: DispatchWorkItem?
    /// Échecs consécutifs d'UPIA (3 au plus, puis arrêt jusqu'à la relance de
    /// Premiere ou l'entrée de menu « Réinstaller »).
    private var installFailures = 0
    /// Ce qui empêche le plugin d'être en service, quand on le sait.
    private var installIssue: PluginInstallIssue?
    /// Repli si NSRunningApplication.launchDate manque.
    private var premiereLaunchSeenAt: Date?
    /// Un hello a eu lieu depuis le lancement de CE Premiere (sinon : jamais connecté).
    private var premiereHadSession = false
    /// « Premiere trop ancien » déjà affiché pour ce processus.
    private var tooOldNotifiedPid: pid_t?
    /// Filet de reprise déjà armé après une installation restée sans hello.
    private var revivalArmedAfterSilentInstall = false
    /// Début de la dernière installation lancée (référence du contrôle à +45 s).
    private var installStartedAt: Date?
    /// Premiere pour lequel cette installation a été lancée (m5 : un contrôle à +45 s
    /// qui tombe après une relance de Premiere ne concerne plus le Premiere qui tourne).
    private var installPremierePid: pid_t?

    /// Programme le prochain contrôle d'installation (remplace le précédent).
    private func scheduleInstallCheck(after delay: TimeInterval) {
        installCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.installPluginIfPremiereRunning() }
        installCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Ce que la politique d'installation doit savoir du Premiere qui tourne.
    private func premiereSnapshot(_ app: NSRunningApplication?) -> PluginInstallPolicy.Premiere? {
        guard let app else { return nil }
        // (f) Version lue dans l'Info.plist de l'app (« 26.5.2 ») : le hello, lui,
        // n'arrive jamais si Premiere est trop ancien pour charger le plugin.
        let version = app.bundleURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return .init(finishedLaunching: app.isFinishedLaunching,
                     launchDate: app.launchDate ?? premiereLaunchSeenAt, version: version)
    }

    private func installPluginIfPremiereRunning() {
        installCheck = nil
        guard !server.isReady else { return }
        let premiere = Self.runningPremiere()
        switch PluginInstallPolicy.gate(premiereSnapshot(premiere), now: Date()) {
        case .noPremiere:
            return   // le lancement de Premiere relancera le contrôle
        case .tooOld(let version):
            notePremiereTooOld(version, pid: premiere?.processIdentifier)
            return
        case .wait(let delay):
            log.info("Premiere en cours de lancement — nouvelle vérification du plugin dans \(Int(delay)) s")
            scheduleInstallCheck(after: delay)
            return
        case .go:
            break
        }
        guard installFailures < PluginInstallPolicy.maxAttempts else { return }
        let since = pluginWaitSince ?? Date()
        pluginWaitSince = since
        let force = Date().timeIntervalSince(since) >= PluginInstallPolicy.forceAfterSilence
        let outcome = pluginLifecycle.reconcile(installedVersion: nil, force: force) { [weak self] result in
            self?.installFinished(result)
        }
        handleInstallOutcome(outcome) { [weak self] delay in self?.scheduleInstallCheck(after: delay) }
    }

    /// Suite immédiate d'un `reconcile` (installation, reprise ou menu).
    private func handleInstallOutcome(_ outcome: PluginLifecycleService.ReconcileOutcome,
                                      recheck: (TimeInterval) -> Void) {
        switch outcome {
        case .started(let message):
            installStartedAt = Date()
            installPremierePid = Self.runningPremiere()?.processIdentifier
            HUD.show(message, duration: 4)
        case .unavailable(let message):
            installIssue = .creativeCloudMissing
            HUD.show(message, duration: 4)
        case .busy:
            log.info("UPIA occupé — nouvel essai dans \(Int(PluginInstallPolicy.retryWhenBusy)) s")
        case .alreadyDeposited, .upToDate, .devMode:
            break
        }
        if let delay = PluginInstallPolicy.recheckDelay(after: outcome) { recheck(delay) }
        pluginStateChanged()
    }

    /// Résultat d'UPIA d'une installation : (c) et (d) du plan.
    /// Les mises à niveau (Premiere fermé, M1) ont leur propre suite : voir
    /// `upgradePluginIfPremiereClosed`.
    private func installFinished(_ result: PluginLifecycleService.UpiaResult) {
        defer { pluginStateChanged() }
        // Le plugin s'est connecté pendant l'installation : rien à signaler.
        if !result.ok, server.isReady { return }
        let decision = PluginInstallPolicy.afterUpia(ok: result.ok, upgrade: false, failures: installFailures)
        installFailures = decision.failures
        switch decision.next {
        case .verify(let delay):
            // Référence = DÉBUT de l'installation, pas l'arrivée du résultat : le plugin
            // peut se charger (et écrire son journal) quelques ms après « Installation
            // Successful », avant que la sortie d'UPIA soit relue (hello 47 ms après,
            // le 06/10) — il serait sinon jugé « non chargé ».
            let startedAt = installStartedAt ?? Date()
            let premierePid = installPremierePid
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // m5 (relecture finale) : Premiere relancé entre-temps (le monteur a suivi
                // « quitte et rouvre Premiere ») → ce contrôle ne le concerne plus ; le
                // nouveau lancement a sa propre chaîne (didLaunch).
                guard let self, Self.runningPremiere()?.processIdentifier == premierePid else {
                    self?.log.info("Contrôle de l'installation ignoré : Premiere relancé ou fermé entre-temps")
                    return
                }
                self.verifyInstall(startedAt: startedAt)
            }
        case .retry(let delay):
            installIssue = .installFailed(code: result.code, final: false)
            HUD.show(L("Couldn't install the Khanjar plugin in Premiere — Khanjar will try again in 2 minutes"),
                     duration: 6, style: .warning)
            log.error("Installation du plugin en échec (essai \(installFailures)/\(PluginInstallPolicy.maxAttempts)) — nouvel essai dans \(Int(delay)) s")
            scheduleInstallCheck(after: delay)
        case .giveUp:
            installIssue = .installFailed(code: result.code, final: true)
            HUD.show(L("The Khanjar plugin still isn't installed: open the Creative Cloud app, check you're signed in, then quit and reopen Premiere"),
                     duration: 6, style: .warning)
            log.error("Installation du plugin en échec \(PluginInstallPolicy.maxAttempts) fois — arrêt ; relance : quitter et rouvrir Premiere, ou menu « Réinstaller le plugin »")
        }
    }

    /// (d) Installé avec succès il y a 45 s : le hello est-il arrivé ?
    private func verifyInstall(startedAt: Date) {
        guard !server.isReady, Self.runningPremiere() != nil else { return }
        let id = PluginLifecycleService.pluginId
        let registration = PluginInstallDiagnostics.readRegistration(pluginId: id)
        let logDates = PluginInstallDiagnostics.pluginLogDates(pluginId: id)
        let issue = PluginInstallPolicy.issueAfterSilentInstall(pluginLogDates: logDates, installStartedAt: startedAt)
        installIssue = issue
        let logState = logDates.isEmpty ? "absent"
            : issue == .loadedButMute ? "écrit depuis l'installation (plugin chargé)" : "pas écrit depuis l'installation"
        log.error("Plugin installé il y a \(Int(PluginInstallPolicy.checkAfterInstall)) s mais aucun hello — \(registration?.description ?? "inscription d'Adobe illisible") ; journal du plugin : \(logState)")
        if issue == .loadedButMute {
            HUD.show(L("The plugin is running but can't reach Khanjar — open the log"), duration: 6, style: .warning)
        } else {
            HUD.show(L("Plugin installed — quit and reopen Premiere to finish"), duration: 6, style: .warning)
        }
        pluginStateChanged()
        // (e) Le filet de reprise s'arme aussi après une 1ʳᵉ installation sans hello
        // (avant : seulement sur une déconnexion, jamais pour un plugin jamais connecté).
        // Une seule fois par lancement de Premiere : sinon, Premiere ne chargeant pas
        // le plugin, réinstallation + HUD toutes les 10 min jusqu'à sa relance.
        guard !revivalArmedAfterSilentInstall else { return }
        revivalArmedAfterSilentInstall = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pluginRevivalDelay) { [weak self] in
            self?.revivePluginIfStillSilent()
        }
    }

    /// Version du plugin connecté, plus ancienne que l'embarquée (vue au dernier hello) :
    /// à mettre à niveau quand Premiere sera fermé (M1).
    private var outdatedPluginVersion: String?

    /// (4) À chaque hello : plugin plus ancien que l'embarqué → mise à niveau à la
    /// FERMETURE de Premiere (M1, 2026-10-11). Avant : remove+install tout de suite,
    /// pendant le démarrage de Premiere (blocage d'UPIA, AGENTS §6), et presque jamais
    /// rechargé à chaud (⌘J muet jusqu'à la relance de Premiere). L'ancien plugin parle
    /// le même protocole : il reste en service d'ici là.
    private func reconcileConnectedPlugin(_ info: HelloInfo) {
        guard let embedded = Self.embeddedPluginVersion,
              PluginInstallPolicy.isNewer(embedded, than: info.pluginVersion) else {
            outdatedPluginVersion = nil
            return
        }
        if outdatedPluginVersion != info.pluginVersion {
            log.info("Plugin v\(info.pluginVersion) < embarqué v\(embedded) — mise à niveau à la fermeture de Premiere (l'ancien plugin reste en service d'ici là)")
        }
        outdatedPluginVersion = info.pluginVersion
    }

    /// M1 (2026-10-11) — Premiere fermé (à sa fermeture, ou au lancement de Khanjar) :
    /// remove+install si le plugin inscrit est plus ancien que l'embarqué. Sans HUD : le
    /// monteur n'a rien à faire, le nouveau plugin se charge au prochain lancement.
    private func upgradePluginIfPremiereClosed(_ trigger: String) {
        guard Self.runningPremiere() == nil, let embedded = Self.embeddedPluginVersion else { return }
        guard !pluginLifecycle.busy else {
            scheduleClosedUpgrade(trigger, after: PluginInstallPolicy.retryWhenBusy)
            return
        }
        let registered = PluginInstallDiagnostics.readRegistration(pluginId: PluginLifecycleService.pluginId)
        guard let installed = PluginInstallPolicy.versionToUpgradeWhileClosed(registered: registered,
                                                                             lastHello: outdatedPluginVersion,
                                                                             embedded: embedded) else { return }
        // F1 (relecture du 2026-10-11) : sans le service de fond de Creative Cloud, UPIA
        // peut retirer l'ancien plugin puis échouer à installer le nouveau.
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == PluginInstallPolicy.creativeCloudServiceId
        }) else {
            log.info("Plugin v\(installed) < embarqué v\(embedded) : Creative Cloud ne tourne pas — mise à niveau à la prochaine fermeture de Premiere")
            return
        }
        // F1 : `--install` seulement si Premiere est TOUJOURS fermé après le `--remove`.
        let outcome = pluginLifecycle.reconcile(installedVersion: installed,
                                                between: { Self.runningPremiere() == nil }) { [weak self] result in
            guard let self else { return }
            if result.ok {
                self.outdatedPluginVersion = nil
                self.log.info("Plugin mis à niveau v\(installed) → v\(embedded), Premiere fermé — chargé au prochain lancement de Premiere")
            } else if result.aborted {
                self.log.info("Premiere rouvert pendant la mise à niveau : ancien plugin retiré, le nouveau sera installé 60 s après le lancement de Premiere")
            } else if PluginInstallDiagnostics.readRegistration(pluginId: PluginLifecycleService.pluginId)?.found == false {
                self.log.error("Mise à niveau du plugin v\(installed) → v\(embedded) (Premiere fermé) en échec après le retrait — installation au prochain lancement de Premiere (60 s après)")
            } else {
                self.log.error("Mise à niveau du plugin v\(installed) → v\(embedded) (Premiere fermé) en échec — l'ancien plugin reste en service, nouvel essai à la prochaine fermeture de Premiere")
            }
            self.pluginStateChanged()
        }
        if case .started = outcome {
            log.info("Mise à niveau du plugin v\(installed) → v\(embedded), Premiere fermé (\(trigger))")
        }
        pluginStateChanged()
    }

    private func scheduleClosedUpgrade(_ trigger: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.upgradePluginIfPremiereClosed(trigger)
        }
    }

    /// (f) Premiere plus ancien que le minimum du manifeste : pas d'UPIA, dit une fois.
    private func notePremiereTooOld(_ version: String, pid: pid_t?) {
        installIssue = .premiereTooOld(version)
        if tooOldNotifiedPid != pid {
            tooOldNotifiedPid = pid
            HUD.show(LF("Premiere %@ is too old for Khanjar (25.6 or later needed)", version), duration: 6, style: .warning)
            log.error("Premiere \(version) trop ancien (minimum \(PluginInstallPolicy.minimumPremiereVersion)) — pas d'installation du plugin")
        }
        pluginStateChanged()
    }

    /// L'état du plugin a changé (hello, déconnexion, UPIA, Premiere lancé/quitté).
    private func pluginStateChanged() {
        statusItem.setConnected(server.isReady)
        // C-05 : l'accueil ouvert suit l'état (le menu et les Réglages le relisent
        // à leur ouverture).
        if onboarding.isVisible { onboarding.refresh() }
    }

    /// C-05 — état affiché du plugin, recalculé à partir des faits.
    private func currentPluginStatus() -> PluginStatus {
        let hello = server.isReady ? server.hello : nil
        return PluginStatus.current(.init(connected: hello.map { ($0.hostVersion, $0.pluginVersion) },
                                          premiereRunning: Self.runningPremiere() != nil,
                                          installing: pluginLifecycle.isInstalling,
                                          issue: installIssue,
                                          hadSession: premiereHadSession))
    }

    /// C-20 (2026-10-09) — retrait de l'ancien plugin Dagger, une fois par session
    /// de l'app ; UPIA occupé (installation de Khanjar en cours…) → nouvel essai à
    /// +2 min au lieu d'abandonner jusqu'au prochain lancement.
    private func removeLegacyPlugin() {
        // M1 (2026-10-11) : l'ancien plugin se présente pendant le démarrage de Premiere ;
        // UPIA sollicité à ce moment-là reste bloqué jusqu'à 3 min (AGENTS §6).
        if let delay = PluginInstallPolicy.legacyRemovalDelay(premiereSnapshot(Self.runningPremiere()), now: Date()) {
            log.info("Retrait de l'ancien plugin Dagger : Premiere démarre encore — dans \(Int(delay)) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.removeLegacyPlugin()
            }
            return
        }
        if pluginLifecycle.removeLegacyPluginOnce() == .busy {
            log.info("Retrait de l'ancien plugin Dagger : UPIA occupé — nouvel essai dans 2 min")
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.removeLegacyPlugin()
            }
        }
    }

    /// C-05 — entrée de menu « Réinstaller le plugin dans Premiere » : relance la
    /// chaîne d'installation (3 essais) même après un abandon.
    private func reinstallPluginFromMenu() {
        guard !pluginLifecycle.busy else {
            HUD.show(L("Installing the Khanjar plugin in Premiere…"), duration: 3)
            return
        }
        log.info("Réinstallation du plugin demandée depuis le menu")
        installFailures = 0
        installIssue = nil
        pluginWaitSince = nil
        let outcome = pluginLifecycle.reconcile(installedVersion: nil, force: true) { [weak self] result in
            self?.installFinished(result)
        }
        handleInstallOutcome(outcome) { [weak self] delay in self?.scheduleInstallCheck(after: delay) }
    }

    /// Le plugin n'est pas revenu de lui-même : on le réinstalle. Ne fait rien
    /// si le pont s'est rétabli entre-temps, si Premiere a été fermé, si UPIA
    /// travaille déjà, ou si une tentative est trop récente.
    /// C-01 (2026-10-09) — mêmes conditions que l'installation : Premiere fini de
    /// démarrer ET lancé depuis 60 s (sinon reprogrammé) ; avant, le filet pouvait
    /// lancer UPIA pendant un redémarrage de Premiere (blocage de 3 min, AGENTS §6).
    private func revivePluginIfStillSilent() {
        guard !server.isReady, !pluginLifecycle.busy else { return }
        let premiere = Self.runningPremiere()
        switch PluginInstallPolicy.gate(premiereSnapshot(premiere), now: Date()) {
        case .noPremiere, .tooOld:
            return
        case .wait(let delay):
            log.info("Plugin absent mais Premiere démarre encore — filet de reprise reporté de \(Int(delay)) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.revivePluginIfStillSilent()
            }
            return
        case .go:
            break
        }
        guard installFailures < PluginInstallPolicy.maxAttempts else {
            log.info("Plugin absent, installation déjà tentée \(PluginInstallPolicy.maxAttempts) fois — on attend la relance de Premiere ou le menu")
            return
        }
        if let last = lastRevivalAttempt, Date().timeIntervalSince(last) < Self.pluginRevivalCooldown {
            log.info("Plugin absent mais réinstallation trop récente — on attend")
            return
        }
        // Le journal distingue « jamais connecté » de « déconnecté » (lu au support).
        let silence = Int(pluginSilentSince.map { Date().timeIntervalSince($0) } ?? 0)
        let what = premiereHadSession ? "déconnecté depuis \(silence) s" : "jamais connecté à ce Premiere (\(silence) s)"
        log.error("Plugin toujours absent (\(what)), Premiere ouvert — réinstallation du ccx embarqué")
        let outcome = pluginLifecycle.reconcile(installedVersion: nil, force: true) { [weak self] result in
            self?.installFinished(result)
        }
        // Le refroidissement ne compte qu'une réinstallation réellement lancée.
        if case .started = outcome { lastRevivalAttempt = Date() }
        handleInstallOutcome(outcome) { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.revivePluginIfStillSilent()
            }
        }
    }

    /// Ouvre la fenêtre de réglages (menu barre de menus, ou reopen de l'app).
    func openSettings() {
        settingsWindow.open()
    }

    // MARK: - Départs (C-13)

    /// Envoyée par une 2ᵉ copie de Khanjar qui renonce (verrou d'instance pris) :
    /// l'instance en service ouvre ses Réglages, le monteur voit qu'elle tourne.
    static let showSettingsNotification = Notification.Name("io.khanjar.app.showSettings")

    /// Nom de l'app qui écoute sur `port` (sortie de lsof, bornée à 2 s), nil si inconnu.
    static func portHolderName(port: UInt16) -> String? {
        let tool = PluginLifecycleService.runTool(executable: "/usr/sbin/lsof",
                                                  args: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"],
                                                  timeout: 2, readerTimeout: 1)
        return parseLsofListener(tool.output, excludingPid: ProcessInfo.processInfo.processIdentifier)
    }

    /// Sortie de `lsof -Fc` (« p38058\ncpython3.13\nf3\n… ») → nom de la première
    /// commande qui n'est pas Khanjar lui-même (son écoute ::1 peut y figurer).
    static func parseLsofListener(_ output: String, excludingPid: Int32) -> String? {
        var pid: Int32?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), pid != excludingPid, line.count > 1 {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    private func quitBecausePortIsTaken(holder: String?) {
        log.error("Port \(Bridge.defaultPort) tenu par : \(holder ?? "inconnu (lsof n'a rien trouvé)") — fenêtre d'explication, puis arrêt")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = LF("Khanjar can't start: port 48123 is used by %@", holder ?? "?")
        alert.informativeText = L("Quit that app, then open Khanjar again.")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        log.waitForPendingWrites()
        exit(1)
    }

    /// S26 / S27 (C-10). `unreadable` : JSON illisible ; `valuesReset` (m9) : valeurs
    /// abîmées remises à zéro, le reste gardé. « Copie gardée » seulement si elle existe.
    static func settingsIssueMessage(_ issue: SettingsIssue) -> String {
        switch issue {
        case .unreadable(let backup):
            return L("Settings file unreadable — default settings in use") + (backup == nil ? "" : L(" (a copy was kept)"))
        case .valuesReset(_, let backup):
            return L("Some settings couldn't be read and were reset — your other settings are kept")
                + (backup == nil ? "" : L(" (a copy was kept)"))
        case .saveFailed: return L("Couldn't save the settings (disk full?)")
        }
    }

    private func applySettings(_ s: Settings) {
        registerHotkey(id: HotkeyService.HotkeyID.palette,
                       spec: s.shortcut, fallback: "cmd+j") { [weak self] in self?.summon() }
        registerHotkey(id: HotkeyService.HotkeyID.adjustmentLayer,
                       spec: s.adjustmentShortcut, fallback: "cmd+shift+j") { [weak self] in self?.addAdjustmentLayer() }
        registerPresetHotkeys(s.shortcuts)
        palette.maxResults = s.maxResults
        palette.setTheme(s.theme)
    }

    /// (Ré)enregistre les raccourcis presets. On désenregistre d'abord les
    /// précédents (les réglages peuvent en retirer), puis on réenregistre depuis
    /// la liste. L'action ne capture QUE l'id/titre — la résolution en SearchItem
    /// se fait au fire (l'index peut avoir changé entre-temps).
    private func registerPresetHotkeys(_ shortcuts: [PresetShortcut]) {
        for id in presetHotkeyIds { HotkeyService.shared.unregister(id: id) }
        presetHotkeyIds.removeAll()
        for (i, ps) in shortcuts.enumerated() {
            let id = HotkeyService.HotkeyID.presetBase + UInt32(i)
            guard let parsed = SettingsStore.parseShortcut(ps.shortcut) else {
                log.error("Raccourci preset invalide « \(ps.shortcut) » (\(ps.title)) — ignoré")
                continue
            }
            let itemId = ps.itemId, title = ps.title
            let ok = HotkeyService.shared.register(id: id, keyCode: parsed.keyCode, modifiers: parsed.modifiers) {
                [weak self] in self?.applyShortcut(itemId: itemId, title: title)
            }
            if ok { presetHotkeyIds.append(id) }
            // C-10 : la touche affichée comme dans les Réglages (« ⌃⌥E »), plus « ctrl+alt+e ».
            else { HUD.show(LF("Khanjar: shortcut “%@” unavailable (%@)", SettingsStore.pretty(ps.shortcut), title)) }
        }
    }

    /// Fire d'un raccourci preset : résout l'item AU MOMENT du clic (voir
    /// resolveShortcut), puis applique. HUD explicite si le preset a disparu ou si
    /// son titre est ambigu — jamais un autre preset.
    private func applyShortcut(itemId: String, title: String) {
        guard server.isReady else { HUD.show(L("Khanjar: Premiere not connected")); return }
        // Index vide (construction en cours ou ratée) : « introuvable — réassigne-le »
        // enverrait le monteur défaire un raccourci qui marchera dans quelques secondes.
        guard !prepared.isEmpty else {
            HUD.show(Self.emptyIndexMessage(buildInFlight: indexBuildInFlight), duration: 3)
            return
        }
        switch Self.resolveShortcut(itemId: itemId, title: title, lookup: itemLookup,
                                    idsForTitle: { [idsByTitle] in idsByTitle[SearchItem.normalizedTitle($0)] ?? [] }) {
        case .item(let id):
            guard let item = itemLookup[id] else { return }
            if id != itemId { retargetShortcut(from: itemId, title: title, to: id) }
            apply(item, origin: .shortcut)
        case .missing where documentsAccessDenied:
            // C-08 point 6 : le preset manque parce que Khanjar ne peut pas lire les
            // presets — « réassigne-le » ferait défaire un raccourci qui est juste.
            HUD.show(LF("“%@” unavailable: Khanjar can't read your presets (Documents access)", title), style: .warning)
            log.error("Raccourci preset : item \(itemId) / « \(title) » absent de l'index — accès Documents refusé")
        case .missing:
            HUD.show(LF("Khanjar: “%@” not found — reassign it in Settings", title), duration: 3)
            log.error("Raccourci preset : item \(itemId) / « \(title) » absent de l'index")
        case .ambiguous:
            HUD.show(LF("Khanjar: several presets are named “%@” — reassign the shortcut in Settings", title), style: .warning)
            log.error("Raccourci preset : id \(itemId) absent ou porté par un autre preset, et plusieurs items s'appellent « \(title) » — rien appliqué")
        }
    }

    /// Cible d'un raccourci preset au moment du clic (C-04).
    enum ShortcutTarget: Equatable {
        case item(id: String)   // id de l'index à appliquer (≠ itemId mémorisé : rattaché par le titre)
        case missing
        case ambiguous
    }

    /// Titre normalisé → ids DISTINCTS qui le portent (C-04). Deux items au même
    /// PresetUID (preset dupliqué dans Premiere) sont UN id, pas un homonyme.
    static func titleIndex(_ items: [SearchItem]) -> [String: Set<String>] {
        items.reduce(into: [:]) { $0[SearchItem.normalizedTitle($1.title), default: []].insert($1.id) }
    }

    /// L'item que désigne encore un id mémorisé avec son titre (raccourci, fréquents),
    /// ou nil. Même titre (casse et espaces ignorés) → lui. Titre différent :
    /// m3 (relecture finale, 2026-10-11) — RENOMMÉ si plus aucun item ne porte l'ancien
    /// titre : depuis I-02 les ids sont stables (PresetUID, contenu, matchName), c'est
    /// donc le même preset (ou le même effet, dans un Premiere d'une autre langue).
    /// Avant, un preset renommé dans Premiere perdait son raccourci et sa ligne ⌘n pour
    /// de bon. L'ancien titre encore porté (copie au même PresetUID) → nil : l'id
    /// désigne peut-être une autre copie (C-04).
    static func currentItem(id: String, storedTitle: String?, lookup: [String: SearchItem],
                            idsForTitle: (String) -> Set<String>) -> SearchItem? {
        guard let item = lookup[id], let storedTitle else { return nil }
        if SearchItem.normalizedTitle(item.title) == SearchItem.normalizedTitle(storedTitle) { return item }
        // Ancien titre porté seulement par un item d'un AUTRE genre (l'effet « Drop Shadow »
        // pour un preset « Drop Shadow » renommé) : c'est bien un renommage (F3).
        return idsForTitle(storedTitle).contains { idKind($0) == idKind(id) } ? nil : item
    }

    /// Genre d'un id : « preset » (« preset:adobe:… » compris) ou « effect ».
    static func idKind(_ id: String) -> Substring { id.split(separator: ":", maxSplits: 1).first ?? "" }

    /// C-04 (2026-10-09) — `itemLookup[itemId] ?? premier item de même titre` : un id
    /// « preset:obj:<n> » que Premiere avait renuméroté désignait un AUTRE preset, et le
    /// raccourci l'appliquait sans alerte ; le secours par titre prenait le premier de
    /// 22 titres portés par plusieurs items (ordre d'un dictionnaire). Désormais : l'id
    /// mémorisé seulement s'il porte encore le titre mémorisé (normalisé) ; sinon
    /// recherche par titre, du MÊME genre (preset/effet) : un seul id → celui-là (le
    /// raccourci y est rattaché) ; aucun → introuvable ; plusieurs → refus.
    static func resolveShortcut(itemId: String, title: String, lookup: [String: SearchItem],
                                idsForTitle: (String) -> Set<String>) -> ShortcutTarget {
        if currentItem(id: itemId, storedTitle: title, lookup: lookup, idsForTitle: idsForTitle) != nil {
            return .item(id: itemId)
        }
        func kind(_ id: String) -> Substring { id.split(separator: ":", maxSplits: 1).first ?? "" }
        let candidates = idsForTitle(title).filter { kind($0) == kind(itemId) && lookup[$0] != nil }
        switch candidates.count {
        case 0: return .missing
        case 1: return .item(id: candidates.first!)
        default: return .ambiguous
        }
    }

    /// Le raccourci (itemId, titre) désigne désormais `newId` : enregistré une fois
    /// (settings.json), hors du gestionnaire Carbon en cours — l'enregistrement
    /// réinscrit tous les raccourcis.
    private func retargetShortcut(from oldId: String, title: String, to newId: String) {
        log.info("Raccourci preset « \(title) » rattaché à \(newId) (\(oldId) absent ou porté par un autre preset)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.settings.current
            guard var list = s.presetShortcuts, list.contains(where: { $0.itemId == oldId && $0.title == title }) else { return }
            for i in list.indices where list[i].itemId == oldId && list[i].title == title { list[i].itemId = newId }
            s.presetShortcuts = list
            self.settings.save(s)
        }
    }

    private func registerHotkey(id: UInt32, spec: String, fallback: String, action: @escaping () -> Void) {
        let parsed = SettingsStore.parseShortcut(spec) ?? SettingsStore.parseShortcut(fallback)
        if SettingsStore.parseShortcut(spec) == nil {
            log.error("Raccourci invalide « \(spec) » — repli \(fallback)")
        }
        guard let parsed else { return }
        if !HotkeyService.shared.register(id: id, keyCode: parsed.keyCode, modifiers: parsed.modifiers, action: action) {
            HUD.show(LF("Khanjar: shortcut “%@” unavailable", SettingsStore.pretty(spec)))
        }
    }

    // MARK: - Calque d'effets

    /// C-02 (2026-10-09) — délai porté de 3 s à 10 s (puis 60 s au plus, verrou
    /// gardé) : sur un gros projet, chercher le calque dépassait 3 s, l'app disait
    /// « réessaie » et le second essai empilait un deuxième calque. Même verrou que
    /// l'application d'un effet : une seule commande qui modifie le projet à la fois.
    static let adjustmentTimeout: TimeInterval = 10
    static let adjustmentHardTimeout: TimeInterval = 60

    func addAdjustmentLayer() {
        guard server.isReady else {
            HUD.show(L("Khanjar: Premiere not connected"))
            log.info("addAdjustmentLayer ignoré : bridge non prêt")
            return
        }
        let accepted = commands.send(cmd: "addAdjustmentLayer",
                                     timeout: Self.adjustmentTimeout,
                                     hardTimeout: Self.adjustmentHardTimeout,
                                     onPhase: { [weak self] phase in
            self?.showProgress(phase, command: "addAdjustmentLayer", timeout: Self.adjustmentTimeout)
        }) { [weak self] result in
            switch result {
            case .success(let payload):
                let track = (payload["trackIndex"] as? Int).map { "V\($0 + 1)" } ?? "?"
                HUD.show(LF("Adjustment layer → track %@", track))
                self?.log.info("addAdjustmentLayer OK : \(payload)")
            case .failure(.remote(let code, let message)) where code == "ADJUSTMENT_NOT_FOUND":
                // Texte de l'app (traduit), pas celui du plugin (en français, en dur).
                // Texte deux fois plus long qu'avant (S18) : 6 s pour le lire.
                HUD.show(Self.userMessage(for: .remote(code: code, message: message),
                                          command: "addAdjustmentLayer", premiereRunning: true), duration: 6)
                self?.log.info("addAdjustmentLayer : \(message)")
            case .failure(let error):
                HUD.show(Self.userMessage(for: error, command: "addAdjustmentLayer",
                                          premiereRunning: Self.runningPremiere() != nil),
                         style: .warning)
                self?.log.error("addAdjustmentLayer ÉCHEC : \(error)")
            }
        }
        if !accepted {
            HUD.show(L("Premiere is still applying the previous one — wait a moment"), duration: 2.5)
            log.info("addAdjustmentLayer ignoré : une commande est déjà en cours")
        }
    }

    /// HUD d'attente d'une commande qui modifie le projet (C-02) : « en cours »
    /// après 1 s sans réponse, puis « occupé, Khanjar terminera » au délai normal.
    private func showProgress(_ phase: ProjectCommandGate.Phase, command: String, timeout: TimeInterval) {
        switch phase {
        case .working:
            HUD.show(L("Applying in Premiere…"), duration: max(1, timeout))
        case .slow:
            HUD.show(L("Premiere is busy — Khanjar will finish as soon as it responds"), duration: 6, style: .warning)
            log.info("\(command) : Premiere occupé après \(Int(timeout)) s — verrou gardé, on attend sa réponse")
        }
    }

    // MARK: - Invocation

    private func summon() {
        if palette.isVisible {
            palette.hide()
            return
        }
        guard server.isReady else {
            // Distinguer les cas : sans ça le HUD disait « Ouvre Premiere
            // Pro » alors que Premiere était à l'écran (capture du 2026-10-06),
            // ce qui envoie chercher le problème au mauvais endroit.
            // C-05 (2026-10-09) — et « se reconnecte » seulement après une VRAIE
            // déconnexion : jamais connecté → « Connexion à Premiere… » ; échec
            // d'installation ou redémarrage nécessaire → le geste à faire.
            let status = currentPluginStatus()
            if let premiere = Self.runningPremiere() {
                HUD.show(status.summonMessage, duration: status.needsAction ? 6 : 3)
                // Réinstaller SEULEMENT si le plugin est muet depuis plus de 45 s et que
                // Premiere a fini de démarrer. Avant (audit du 2026-10-07), ⌘J pendant
                // le lancement de Premiere ou une reconnexion de 2 s lançait UPIA tout
                // de suite : le blocage de 3 min du §6, puis 10 min sans nouvel essai.
                // (Le filet vérifie aussi les 60 s depuis le lancement de Premiere, C-01.)
                let silentFor = pluginSilentSince.map { Date().timeIntervalSince($0) } ?? 0
                if premiere.isFinishedLaunching, silentFor >= Self.pluginRevivalDelay {
                    log.info("Invocation sans plugin depuis \(Int(silentFor)) s, Premiere ouvert — relance du filet")
                    revivePluginIfStillSilent()
                } else {
                    log.info("Invocation sans plugin depuis \(Int(silentFor)) s — trop tôt pour réinstaller, on attend")
                }
            } else {
                HUD.show(status.summonMessage, duration: 3)   // « Ouvre Premiere Pro… »
                log.info("Invocation sans plugin connecté (Premiere fermé)")
            }
            return
        }
        // C-08 : presets perso illisibles ou absents à la dernière lecture → nouvel essai.
        recheckUserPresetsIfNeeded("⌘J")
        if prepared.isEmpty {
            // C-16 : « en construction » seulement si une construction tourne vraiment.
            let message = Self.emptyIndexMessage(buildInFlight: indexBuildInFlight)
            HUD.show(message, duration: indexBuildInFlight ? nil : 6, style: indexBuildInFlight ? .info : .warning)
            if !indexBuildInFlight { log.error("Invocation sans index : lecture des effets de Premiere abandonnée") }
            return
        }
        // Après un échec rattrapable (« Sélectionne d'abord un clip »…), la palette
        // revient avec la même recherche : on ne fait pas retaper le monteur.
        // C-09 : et sur la ligne qu'il avait choisie (un Entrée réflexe appliquait la 1ʳᵉ).
        if let retry = retryQuery, Date().timeIntervalSince(retry.at) < 60 {
            retryQuery = nil
            palette.show(prefill: retry.query, selecting: retry.itemId)
        } else {
            palette.show()
        }
    }

    // MARK: - Application d'un item

    /// Un apply à la fois : deux applications concurrentes s'entrelacent et
    /// posent les effets EN DOUBLE (constaté possible quand un timeout invite à
    /// réessayer alors que Premiere travaille encore).
    /// C-02 (2026-10-09) — ce verrou était relâché AU DÉLAI (4 s pour 321 presets
    /// sur 338), avec « réessaie » à l'écran, alors que Premiere appliquait encore.
    /// Il vit maintenant dans `commands` (ProjectCommandGate), partagé avec ⌘⇧J, et
    /// n'est relâché qu'à la vraie réponse, à la déconnexion ou après 120 s.
    private lazy var commands = ProjectCommandGate(server: server)
    /// Au-delà, on cesse d'attendre une application (verrou libéré, S14).
    static let applyHardTimeout: TimeInterval = 120

    /// D'où vient une application (contrat §4.6) : la recherche n'est reproposée
    /// qu'après un échec venu de la palette (C-09).
    enum ApplyOrigin { case palette, shortcut, test }

    /// Applique `item` à la sélection. `false` = refusé sans rien envoyer : une
    /// application est déjà en cours (contrat §4.6, C-02 point 5).
    @discardableResult
    private func apply(_ item: SearchItem, origin: ApplyOrigin) -> Bool {
        let label = item.title
        guard !commands.inFlight else {
            // S15 : le précédent tourne encore dans Premiere (verrou gardé, C-02).
            HUD.show(L("Premiere is still applying the previous one — wait a moment"), duration: 2.5)
            log.info("apply ignoré : une application est déjà en cours (\(label))")
            return false
        }
        // C-09 (2026-10-09) — recherche ET ligne validées, relevées MAINTENANT : la
        // réponse arrive plus tard, et `retryQuery` était posé aussi après un raccourci
        // preset raté (la palette rouvrait alors sur une vieille recherche).
        let committed = origin == .palette ? palette.lastCommitted : nil
        // Délai proportionné à la CHARGE : un preset très keyframé (cuisson
        // d'ease) demande bien plus que 4 s. Un délai trop court affichait un
        // échec alors que Premiere travaillait encore — et invitait à réappliquer
        // (effets en double). 4 s de base + 1 s par tranche de 200 keyframes.
        // Depuis C-02, ce délai ne déclenche plus qu'un message d'attente.
        let kfCount = item.plan.operations.reduce(0) { $0 + $1.params.reduce(0) { $0 + $1.keyframes.count } }
            + item.plan.existingOperations.reduce(0) { $0 + $1.params.reduce(0) { $0 + $1.keyframes.count } }
        let timeout = min(30.0, 4.0 + Double(kfCount) / 200.0)
        commands.send(cmd: "apply",
                      payload: ["plan": item.plan.protocolPayload,
                                "options": ["relativeToClip": settings.current.adaptToClip]],
                      timeout: timeout,
                      hardTimeout: Self.applyHardTimeout,
                      onPhase: { [weak self] phase in
            self?.showProgress(phase, command: "apply « \(label) »", timeout: timeout)
        }) { [weak self] result in
            switch result {
            case .success(let payload):
                let clips = (payload["applied"] as? [String: Any])?["clips"] as? Int ?? 0
                // Compté seulement si au moins un clip a reçu l'effet : le
                // classement doit refléter le travail réel, pas les tentatives.
                if clips > 0 {
                    // Un duo crédite ses deux membres (et l'enchaînement), pas
                    // un id synthétique que l'index ne connaîtrait pas.
                    // C-03 : avec les clips touchés (enchaînement = même clip).
                    let clipNames = Self.appliedClipNames(payload)
                    if let members = item.comboMembers {
                        self?.usage.recordCombo(from: members.from, to: members.to, clips: clipNames)
                    } else {
                        self?.usage.record(id: item.id, title: item.title, clips: clipNames)
                    }
                }
                let summary = Self.applySummary(label: label, payload: payload)
                HUD.show(summary.message, style: summary.style)
                self?.retryQuery = nil
                self?.log.info(summary.logLine)
                if let detailLine = summary.detailLine { self?.log.info(detailLine) }
            case .failure(let error):
                HUD.show(Self.userMessage(for: error, command: "apply",
                                          premiereRunning: Self.runningPremiere() != nil), style: .warning)
                self?.log.error("apply ÉCHEC : \(label) — \(error)")
                // Erreur que le monteur corrige d'un geste (sélectionner un clip, ouvrir
                // une séquence) : le prochain ⌘J rouvre la palette sur la même recherche,
                // sur la même ligne — seulement si l'échec vient de la palette (C-09).
                if let retry = Self.retryAfterFailure(code: error.code, committed: committed, itemId: item.id) {
                    self?.retryQuery = (retry.query, retry.itemId, Date())
                }
            }
        }
        return true
    }

    /// Ce qu'une application réussie affiche et journalise (C-10).
    struct ApplySummary {
        let message: String
        let style: HUD.Style
        /// Commence TOUJOURS par « apply OK : <titre>, <N> clips appliqués » : relu
        /// par UsageStore.seedIfNeeded (règle 6 du plan) — ne pas changer ce début.
        let logLine: String
        let detailLine: String?
    }

    /// C-10 (2026-10-09) — HUD et journal d'une application, depuis la réponse du plugin.
    /// Avant : HUD VERT malgré des réglages sautés ou restés aux valeurs par défaut
    /// (paramsFailedClips, P-06), nombres additionnés sur tous les clips (« 13 000/13 500
    /// paramètres » pour 27 réglages × 500 clips), journal « transaction=single » alors
    /// qu'il y en avait 1 + N, détail journalisé seulement dans certains cas.
    /// Désormais : avertissement dès qu'un clip, un réglage ou les réglages d'un clip
    /// manquent ; S22/S23 pour les clips restés aux valeurs par défaut ; réglages
    /// affichés PAR CLIP quand ils se répartissent exactement (même nombre posé et
    /// prévu sur chaque clip en moyenne entière, aucun clip sans réglages) ;
    /// `transactions=<n>` (+ « repli par clip ») ; ligne de détail dès qu'une raison
    /// autre que NAME_DIFFERS_SAME_STRUCTURE apparaît.
    /// Raisons de réglages sautés identiques sur tous les clips d'une application : elles
    /// tiennent à la définition de l'effet dans ce Premiere, pas au clip (m14).
    static let clipIndependentSkipReasons: Set<String> = [
        "NAME_MISMATCH", "PARAM_STRUCTURE_MISMATCH", "UNVERIFIABLE_PARAM", "INDEX_OUT_OF_RANGE",
        "NAME_DIFFERS_SAME_STRUCTURE", "EFFECT_MISSING",
    ]

    static func applySummary(label: String, payload: [String: Any]) -> ApplySummary {
        let clips = (payload["applied"] as? [String: Any])?["clips"] as? Int ?? 0
        let latency = payload["latencyMs"] as? Int ?? -1
        let skippedInfo = payload["skipped"] as? [String: Any]
        let skipped = skippedInfo?["items"] as? Int ?? 0
        let reason = skippedInfo?["reason"] as? String
        let failedClips = skippedInfo?["failedClips"] as? [String] ?? []
        let fidelity = payload["fidelity"] as? [String: Any]
        let set = fidelity?["paramsSet"] as? Int ?? 0
        let skippedParams = fidelity?["paramsSkipped"] as? Int ?? 0
        let paramsFailedClips = fidelity?["paramsFailedClips"] as? [String] ?? []
        let detail = fidelity?["detail"] as? [[String: Any]] ?? []

        var message = clips > 1 ? LF("%@ → %ld clips", label, clips) : LF("%@ → %ld clip", label, clips)
        // Les pistes AUDIO liées d'une sélection sont ignorées par
        // construction : ne pas les annoncer (bruit à chaque clip sonore).
        // Seuls les clips VIDÉO qui n'ont pas reçu l'effet sont signalés.
        if !failedClips.isEmpty {
            message += failedClips.count > 1 ? LF(" (%ld clips not applied)", failedClips.count) : L(" (1 clip not applied)")
        }
        // Effets posés mais réglages restés aux valeurs par défaut (contrat §4.1).
        if !paramsFailedClips.isEmpty {
            message += paramsFailedClips.count > 1 ? LF(" — settings not applied on %ld clips", paramsFailedClips.count)
                                                   : L(" — settings not applied on 1 clip")
        }
        if skippedParams > 0 {
            let total = set + skippedParams
            // m14 (relecture finale, 2026-10-11) : la forme « par clip » seulement si les
            // réglages sont sautés pour une raison qui ne dépend pas du clip (définition de
            // l'effet dans ce Premiere). TOO_MANY_KEYFRAMES (longueur du clip),
            // IN_POINT_UNREADABLE… varient d'un clip à l'autre : 3 clips dont un perd ses 3
            // réglages affichaient « 2/3 » comme si chacun en avait eu 2.
            let reasons = Set(detail.compactMap { $0["reason"] as? String })
            let sameOnEveryClip = reasons.isSubset(of: Self.clipIndependentSkipReasons)
            if paramsFailedClips.isEmpty, sameOnEveryClip, clips > 1, total % clips == 0, set % clips == 0 {
                message += LF(" — %ld/%ld parameters", set / clips, total / clips)
            } else {
                message += LF(" — %ld/%ld parameters", set, total)
            }
        }
        let complete = clips > 0 && failedClips.isEmpty && paramsFailedClips.isEmpty && skippedParams == 0

        // Paramètres écrits alors que leur nom diffère (preset créé dans
        // un Premiere d'une autre langue) : tracé pour le diagnostic.
        let namesDiffer = fidelity?["namesDiffer"] as? Int ?? 0
        let langNote = namesDiffer > 0 ? " nomsAutreLangue=\(namesDiffer)" : ""
        let transactions = (fidelity?["transactions"] as? Int).map(String.init) ?? "?"
        let fallback = (payload["transaction"] as? String) == "per-clip" ? " (repli par clip)" : ""
        let noSettings = paramsFailedClips.isEmpty ? "" : " sansRéglages=\(paramsFailedClips)"
        let logLine = "apply OK : \(label), \(clips) clips appliqués, skipped=\(skipped) reason=\(reason ?? "-") failed=\(failedClips)\(noSettings) transactions=\(transactions)\(fallback) \(latency) ms\(langNote)"

        // Raisons détaillées (échec de clip, réglage sauté, média indécis…) :
        // journalisées pour diagnostiquer sans mode debug.
        var detailLine: String?
        if detail.contains(where: { ($0["reason"] as? String) != "NAME_DIFFERS_SAME_STRUCTURE" }) {
            let shown = detail.prefix(6).map { entry in
                entry.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            }
            detailLine = "apply détail (\(detail.count)) : \(shown.joined(separator: " | "))"
        }
        return ApplySummary(message: message, style: complete ? .success : .warning,
                            logLine: logLine, detailLine: detailLine)
    }

    /// C-09 — que reproposer au prochain ⌘J après un échec : la recherche et la ligne
    /// validées dans la palette (`committed` = nil hors palette), seulement pour une
    /// erreur que le monteur corrige d'un geste. Champ vide (validé dans les fréquents,
    /// ⌘n compris) : la palette rouvre les fréquents sur la même ligne.
    static func retryAfterFailure(code: String, committed: (query: String, itemId: String)?,
                                  itemId: String) -> (query: String, itemId: String)? {
        guard ["NO_SELECTION", "NO_APPLICABLE_CLIP", "NO_PROJECT", "NO_SEQUENCE"].contains(code),
              let committed, committed.itemId == itemId else { return nil }
        return committed
    }

    /// Messages orientés ACTION, compréhensibles par un non-technicien (le code
    /// technique reste dans le journal, jamais à l'écran).
    ///
    /// C-02 (2026-10-09) — plus jamais « réessaie » quand Premiere a pu appliquer :
    /// TIMEOUT n'arrive qu'au délai maximal (120 s) → « vérifie la timeline » ; une
    /// coupure avec Premiere ouvert n'est plus « Ouvre Premiere Pro » (S11) ; codes
    /// du plugin BUSY (une commande tourne déjà, rien n'a été fait) et EXPIRED
    /// (échéance dépassée avant de commencer, rien n'a été fait) ; messages propres
    /// au calque d'effets. `command` = commande envoyée (« apply »,
    /// « addAdjustmentLayer »).
    static func userMessage(for error: BridgeError, command: String, premiereRunning: Bool) -> String {
        switch error.code {
        case "NO_SELECTION": return L("Select a clip in the timeline first")
        case "NO_APPLICABLE_CLIP": return L("Select a video clip (not just audio)")
        case "NO_PROJECT", "NO_SEQUENCE": return L("Open a sequence in Premiere")
        case "EFFECT_NOT_FOUND": return L("This effect isn't available in your version of Premiere")
        case "PLUGIN_DISCONNECTED":
            return premiereRunning ? L("Connection to Premiere lost — check the timeline before trying again")
                                   : L("Open Premiere Pro to use Khanjar")
        case "TIMEOUT": return L("Premiere still isn't responding — check the timeline before trying again")
        case "BUSY": return L("Premiere is still applying the previous one — wait a moment")
        case "EXPIRED": return L("Not applied: Premiere was busy for too long")
        case "ADJUSTMENT_NOT_FOUND":
            return L("No adjustment layer found — create one (File > New > Adjustment Layer) and drag it into the timeline once")
        case "TRANSACTION_FAILED" where command == "addAdjustmentLayer":
            return L("Couldn't place the adjustment layer — add an empty video track above your clips")
        // m2 (relecture finale, 2026-10-11) : TRANSACTION_FAILED arrive aussi quand une
        // partie des effets a été posée (PARTIAL_INSERT, READBACK_FAILED) — « réessaie »
        // faisait poser les effets en double.
        case "TRANSACTION_FAILED":
            return L("Couldn't apply the effect — check the timeline before trying again")
        default: return L("Couldn't apply the effect — try again")
        }
    }

    /// Premiere en cours d'exécution (le premier trouvé), s'il y en a un.
    static func runningPremiere() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true }
    }

    // MARK: - Fréquents (C-03, C-04)

    /// Noms des clips qui ont reçu l'effet (`applied.clipNames` de la réponse du plugin).
    /// C-03 (2026-10-09) — l'app notait un enchaînement sans savoir si les deux
    /// applications visaient le même clip : c'est ce qui a inversé le duo d'Isma
    /// (I-01). Ces noms vont à `usage.record` / `recordCombo`, qui ne comptent un
    /// enchaînement que sur un clip commun. Absent (plugin ancien) = liste vide =
    /// aucun enchaînement compté.
    static func appliedClipNames(_ payload: [String: Any]) -> [String] {
        (payload["applied"] as? [String: Any])?["clipNames"] as? [String] ?? []
    }

    /// Lignes de la palette à champ vide, dans l'ordre affiché (⌘1 = la première).
    ///
    /// C-03 / C-04 (2026-10-09) — avant, on prenait `limit` entrées et 2 duos PUIS on
    /// sautait celles absentes de l'index : la liste se vidait d'autant (une entrée
    /// orpheline = une ligne de moins). Et un id resté dans l'index mais désignant un
    /// AUTRE preset (ancien « preset:obj:<n> » renuméroté par Premiere, preset
    /// dupliqué au même PresetUID) était proposé en ⌘n sous son nouveau nom : un
    /// ⌘2 réflexe appliquait autre chose. Désormais : on demande plus d'entrées
    /// (`ranked` = top(limit × 2), `pairs` = topPairs(5)), on saute celles absentes de
    /// l'index OU dont le titre normalisé diffère du titre mémorisé (membres des duos
    /// compris, `titleOf`), puis on coupe à `limit` lignes et `maxCombos` duos.
    static func frequentRows(limit: Int,
                             ranked: [(id: String, count: Int, score: Double, title: String)],
                             pairs: [(from: String, to: String, count: Int)],
                             lookup: [String: SearchItem],
                             titleOf: (String) -> String?,
                             idsForTitle: (String) -> Set<String>,
                             maxCombos: Int = maxCombosShown) -> [(item: SearchItem, count: Int)] {
        // Preset renommé : toujours proposé (m3, voir currentItem).
        func current(_ id: String, _ title: String?) -> SearchItem? {
            currentItem(id: id, storedTitle: title, lookup: lookup, idsForTitle: idsForTitle)
        }
        var singles: [(item: SearchItem, count: Int)] = []
        for entry in ranked where singles.count < limit {
            guard let item = current(entry.id, entry.title) else { continue }
            singles.append((item: item, count: entry.count))
        }
        var combos: [(item: SearchItem, count: Int)] = []
        for pair in pairs where combos.count < maxCombos {
            guard let a = current(pair.from, titleOf(pair.from)), let b = current(pair.to, titleOf(pair.to)),
                  let combo = SearchItem.combining(a, b, pairCount: pair.count) else { continue }
            combos.append((item: combo, count: pair.count))
        }
        // Les duos valent deux ⌘J pour un, donc très haut dans la liste —
        // mais PAS en ⌘1. Cette place appartient à l'item le plus appliqué
        // (469 fois pour le premier, loin devant) : la déplacer ferait
        // déclencher un duo à la place d'un geste devenu réflexe, et
        // appliquerait deux effets au lieu d'un.
        var rows = Array(singles.prefix(1)) + combos + singles.dropFirst()
        if rows.isEmpty { rows = combos }
        return Array(rows.prefix(limit))
    }

    // MARK: - Index

    /// `seedUsage` faux (C-08) : index sans les presets perso — l'amorçage des fréquents
    /// y résoudrait mal les titres et ne serait jamais refait.
    private func installItems(_ items: [SearchItem], origin: String, seedUsage: Bool = true) {
        let started = Date()
        prepared = Scorer.prepare(items)
        itemLookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        idsByTitle = Self.titleIndex(items)
        effectsCache = items.filter { $0.kind == "effect" }.compactMap { item in
            guard let matchName = item.plan.operations.first?.matchName else { return nil }
            return IndexStore.EffectEntry(matchName: matchName, displayName: item.title)
        }
        // Premier lancement : rejoue l'historique du journal pour que la liste
        // des fréquents soit juste dès la première ouverture de la palette.
        if seedUsage { usage.seedIfNeeded(items: items) }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("Index actif : \(items.count) items (préparation \(ms) ms) — source : \(origin)")
    }

    /// C-04 (2026-10-09) — après une RECONSTRUCTION : les entrées d'usage.json et les
    /// raccourcis de settings.json dont l'id n'existe plus (anciens « preset:obj:<n> »,
    /// preset sans UID modifié…) sont rattachés au nouvel id quand leur titre désigne
    /// un seul id distinct ; jamais d'un genre à l'autre, rien n'est supprimé. Un seul
    /// enregistrement de settings.json. Pas au chargement du snapshot : les réglages ne
    /// sont lus qu'ensuite (start, étape 3) — on enregistrerait les défauts.
    private func remapStaleIds(_ items: [SearchItem]) {
        let validIds = Set(items.map(\.id))
        let idForTitle: (String) -> String? = { [idsByTitle] title in
            let ids = idsByTitle[SearchItem.normalizedTitle(title)] ?? []
            return ids.count == 1 ? ids.first : nil
        }
        usage.remapUnknownIds(validIds: validIds, idForTitle: idForTitle)
        let (remapped, moved) = settings.current.remappingUnknownShortcutIds(validIds: validIds, idForTitle: idForTitle)
        // m3 (2026-10-11) — preset renommé dans Premiere (même id) : le titre mémorisé
        // suit, sinon un futur preset reprenant l'ancien nom capterait le raccourci.
        let titleOf: (String) -> String? = { [itemLookup] in itemLookup[$0]?.title }
        let titleTaken: (String, String) -> Bool = { [idsByTitle] title, id in
            (idsByTitle[SearchItem.normalizedTitle(title)] ?? []).contains { Self.idKind($0) == Self.idKind(id) }
        }
        usage.retitleRenamed(currentTitle: titleOf, titleTaken: titleTaken)
        let (retitled, renamed) = remapped.retitlingRenamedShortcuts(currentTitle: titleOf, titleTaken: titleTaken)
        guard moved + renamed > 0 else { return }
        if moved > 0 { log.info("Raccourcis presets : \(moved) rattaché(s) à leur nouvel id par le titre") }
        if renamed > 0 { log.info("Raccourcis presets : \(renamed) preset(s) renommé(s) dans Premiere — titre mis à jour") }
        settings.save(retitled)
    }

    /// C-16 (2026-10-09) — un `listEffects` raté au premier hello (Premiere encore
    /// occupé à ouvrir un gros projet : > 5 s) n'était jamais retenté : sans snapshot
    /// (Mac neuf), ⌘J répétait « index en construction » alors que rien ne se
    /// construisait, jusqu'à la reconnexion suivante. Nouveaux essais à +5, +15,
    /// +30 s tant que la MÊME session vit ; ⌘J sans index ni construction → S43.
    static func listEffectsRetryDelay(afterFailedAttempt attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [5, 15, 30]
        return attempt < delays.count ? delays[attempt] : nil
    }

    /// Message de ⌘J quand l'index est vide (C-16).
    static func emptyIndexMessage(buildInFlight: Bool) -> String {
        buildInFlight ? L("Khanjar: building the index…")
                      : L("Khanjar couldn't read Premiere's effects — quit and reopen Premiere")
    }

    /// Une lecture des effets (ou sa reprise programmée) est en cours.
    private var indexBuildInFlight = false
    /// Numéro de session du plugin (un hello = une session) : une reprise ne sert
    /// que la session qui l'a programmée.
    private var sessionSerial = 0

    private func rebuildIndexFromPlugin(attempt: Int = 0) {
        let serial = sessionSerial
        indexBuildInFlight = true
        server.request(cmd: "listEffects", timeout: 5) { [weak self] result in
            guard let self else { return }
            guard case .success(let payload) = result else {
                let reason: String
                if case .failure(let error) = result { reason = error.code } else { reason = "?" }
                guard let delay = Self.listEffectsRetryDelay(afterFailedAttempt: attempt), self.server.isReady,
                      self.sessionSerial == serial else {
                    if self.sessionSerial == serial { self.indexBuildInFlight = false }
                    self.log.error("listEffects en échec (\(reason)) — index snapshot conservé")
                    return
                }
                self.log.error("listEffects en échec (\(reason)) — index snapshot conservé, nouvel essai \(attempt + 1)/3 dans \(Int(delay)) s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.sessionSerial == serial else { return }   // nouvelle session : elle a lancé sa lecture
                    guard self.server.isReady else { self.indexBuildInFlight = false; return }
                    self.rebuildIndexFromPlugin(attempt: attempt + 1)
                }
                return
            }
            let effects = (payload["video"] as? [[String: Any]] ?? []).compactMap { entry -> IndexStore.EffectEntry? in
                guard let matchName = entry["matchName"] as? String else { return nil }
                return IndexStore.EffectEntry(matchName: matchName,
                                              displayName: entry["displayName"] as? String ?? matchName)
            }
            self.rebuildIndex(effects: effects,
                              premiereVersion: self.server.hello?.hostVersion ?? "?",
                              locale: self.server.hello?.uiLocale ?? "en_US")
        }
    }

    /// Reconstruction complète (parsing presets sur file d'arrière-plan,
    /// installation + snapshot sur main). `locale`/version viennent du hello →
    /// presets Adobe résolus dans la BONNE langue et la BONNE version.
    ///
    /// C-08 (2026-10-09) — un accès Documents refusé (redemandé par macOS à chaque
    /// mise à jour, AGENTS §5) donnait 0 preset perso : `try?` sans trace, et le
    /// garde-fou « plus aucun preset » ne se déclenchait pas, les 38 PiP Adobe comptant
    /// comme des presets. L'index ET index.json perdaient ~300 presets, fréquents et
    /// raccourcis cassés, sans un message. Désormais la lecture est qualifiée
    /// (`userPresetLookup`, parse en do/catch) et `indexUpdate` décide : garder
    /// l'index entier ou installer (voir sa table).
    ///
    /// `provisional` (intégration du 2026-10-09) : index reconstruit HORS LIGNE au
    /// démarrage (voir rebuildIndexOffline) — jamais d'écriture du snapshot, ni de
    /// rattachement d'ids, ni d'amorçage des fréquents (presets Adobe dans une langue
    /// devinée), et abandonné si le vrai index est arrivé entre-temps.
    private func rebuildIndex(effects: [IndexStore.EffectEntry], premiereVersion: String, locale: String,
                              provisional: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lookup = IndexStore.userPresetLookup(hostVersion: premiereVersion)
            var userPresets: [ParsedPreset] = []
            var read = UserPresetRead.noFile
            var userSource = "aucun fichier de presets perso"
            switch lookup {
            case .found(let file):
                userSource = Self.maskedPresetLocation(file)
                do {
                    userPresets = try PrfpsetParser.parse(fileURL: file)
                    read = .read
                } catch {
                    read = .unreadable
                    userSource += " — profil illisible : \(Self.parseErrorText(error))"
                }
            case .noFile:
                read = .noFile
            case .accessDenied(let why):
                read = .accessDenied
                userSource = "accès refusé (\(why))"
            }
            let factoryFiles = IndexStore.factoryPresetFiles(hostVersion: premiereVersion, locale: locale)
            var factoryPresets: [ParsedPreset] = []
            for file in factoryFiles {
                factoryPresets.append(contentsOf: (try? PrfpsetParser.parse(fileURL: file)) ?? [])
            }
            // Langue retenue : …/LocalizedPresets/<langue>/Effect Presets/<fichier>.
            let factoryLocale = factoryFiles.first?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let items = IndexStore.build(effects: effects, userPresets: userPresets, factoryPresets: factoryPresets)

            DispatchQueue.main.async {
                guard let self else { return }
                if provisional {
                    // Le vrai index (snapshot à jour ou hello) est déjà là : on ne l'écrase pas.
                    guard !self.realIndexInstalled else {
                        self.log.info("Index provisoire abandonné : le vrai index est déjà en place")
                        return
                    }
                } else {
                    self.indexBuildInFlight = false   // C-16 : la construction est finie
                }
                self.notePresetLookup(lookup)
                // Point 4 : dossier de version et profil MASQUÉ (il contient souvent le
                // prénom ; le journal se partage), jamais le chemin complet.
                self.log.info("\(provisional ? "Reconstruction hors ligne" : "Reconstruction") : presets perso \(userSource), \(userPresets.count) lu(s) ; presets Adobe \(factoryLocale ?? "aucun") (\(factoryPresets.count)) ; \(effects.count) effets")
                let decision = Self.indexUpdate(presets: read, effectCount: effects.count,
                                                hadUserPresets: self.prepared.contains { $0.item.isUserPreset },
                                                hasUserPresets: items.contains { $0.isUserPreset },
                                                currentIndexEmpty: self.prepared.isEmpty,
                                                currentIsProvisional: !provisional && !self.realIndexInstalled)
                if decision.warnDocuments { self.warnDocumentsAccess() }
                guard case .install(let complete) = decision.update else {
                    self.log.error("Reconstruction écartée — index conservé (\(self.prepared.count) items) : \(Self.keepReason(read, effectCount: effects.count))")
                    return
                }
                let origin = provisional ? "hors ligne, provisoire (\(userPresets.count) presets user)"
                                         : "reconstruction (\(userPresets.count) presets user)"
                self.installItems(items, origin: origin, seedUsage: complete && !provisional)
                if !provisional { self.realIndexInstalled = true }
                guard complete, !provisional else {
                    // Index provisoire, ou sans les presets perso faute de mieux (il était
                    // vide) : ni rattachement des ids, ni snapshot — le vrai index les fera.
                    if provisional {
                        self.log.info("Index provisoire en place — le vrai index sera construit à la connexion du plugin (snapshot non écrit)")
                    } else {
                        self.log.error("Index installé SANS les presets perso (\(Self.keepReason(read, effectCount: effects.count))) — snapshot non écrit")
                    }
                    return
                }
                self.remapStaleIds(items)
                let snapshot = IndexSnapshot(version: IndexSnapshot.currentVersion,
                                             generatedAt: Date(),
                                             premiereVersion: premiereVersion,
                                             items: items)
                // C-17 (2026-10-09) — l'encodage JSON du snapshot (≈ 100 ms, audit A4)
                // tournait sur le fil principal, juste après l'installation de l'index :
                // un ⌘J tapé à cet instant attendait. Encodé et écrit sur une file SÉRIE
                // d'arrière-plan (les items sont des valeurs ; deux reconstructions
                // rapprochées s'écrivent dans l'ordre). L'installation reste ici.
                let log = self.log
                self.snapshotQueue.async {
                    do { try IndexStore.saveSnapshot(snapshot) }
                    catch { log.error("Écriture snapshot en échec : \(error)") }
                }
            }
        }
    }

    // MARK: - Presets perso illisibles (C-08)

    /// Ce que la reconstruction a pu lire des presets perso.
    enum UserPresetRead: Equatable {
        case read            // fichier trouvé et lu (éventuellement vide)
        case noFile          // pas de dossier Premiere ni de profil
        case accessDenied    // macOS refuse l'accès à Documents (TCC) ou droits Unix
        case unreadable      // fichier trouvé mais illisible (parse en échec)
    }

    enum IndexUpdate: Equatable {
        /// `complete` = presets perso compris : snapshot écrit, ids rattachés, amorçage.
        case install(complete: Bool)
        case keep
    }

    /// C-08 (2026-10-09) — après une reconstruction, garder l'index ou l'installer.
    ///  - listEffects a rendu 0 effet → garder (rien d'applicable dans le nouveau) ;
    ///  - accès refusé → garder l'index ENTIER, ni installation ni snapshot, S19 ;
    ///    sauf index vide (Mac neuf, ancien snapshot ignoré) : installer effets et
    ///    presets Adobe faute de mieux, SANS snapshot (« écart sûr » au plan) ;
    ///  - profil illisible → garder les presets perso précédents (l'index entier) ;
    ///    même exception pour un index vide ;
    ///  - il y avait des presets PERSO (`isUserPreset` : les 38 PiP Adobe ne comptent
    ///    plus) et il n'y en a plus → garder l'index + S19 ;
    ///  - sinon installer, complet.
    ///
    /// m1 (relecture finale, 2026-10-11) — `currentIsProvisional` : l'index en place est
    /// l'index provisoire du 1er lancement de la 0.8.4 (effets de l'ancien snapshot,
    /// presets Adobe dans la langue du Mac). Accès refusé à ce moment-là (macOS le
    /// redemande à chaque mise à jour) : le provisoire, sans presets perso, n'était jamais
    /// remplacé par les effets de Premiere. Désormais un provisoire SANS presets perso
    /// est remplacé comme un index vide ; un provisoire qui en a est gardé.
    static func indexUpdate(presets: UserPresetRead, effectCount: Int, hadUserPresets: Bool,
                            hasUserPresets: Bool, currentIndexEmpty: Bool,
                            currentIsProvisional: Bool = false) -> (update: IndexUpdate, warnDocuments: Bool) {
        guard effectCount > 0 else { return (.keep, false) }
        let replaceable = currentIndexEmpty || (currentIsProvisional && !hadUserPresets)
        switch presets {
        case .accessDenied:
            return (replaceable ? .install(complete: false) : .keep, true)
        case .unreadable:
            return (replaceable ? .install(complete: false) : .keep, false)
        case .read, .noFile:
            if hadUserPresets && !hasUserPresets { return (.keep, true) }
            return (.install(complete: true), false)
        }
    }

    /// Raison d'une reconstruction écartée ou incomplète, pour le journal.
    static func keepReason(_ read: UserPresetRead, effectCount: Int) -> String {
        if effectCount == 0 { return "Premiere a rendu 0 effet" }
        switch read {
        case .accessDenied: return "accès Documents refusé"
        case .unreadable: return "fichier de presets perso illisible"
        case .read, .noFile: return "plus aucun preset perso alors que l'index en avait (accès Documents refusé ? profil absent ?)"
        }
    }

    /// « 26.0/Profile-… » : dossier de version gardé, nom du profil masqué (prénom).
    static func maskedPresetLocation(_ file: URL) -> String {
        "\(file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)/Profile-…"
    }

    /// Texte d'une erreur du parseur (il ne cite que le NOM du fichier, jamais son chemin).
    private static func parseErrorText(_ error: Error) -> String {
        if case PrfpsetParseError.unreadable(let text) = error { return text }
        return error.localizedDescription
    }

    /// Dernier résultat connu de la recherche du fichier de presets perso.
    private var lastPresetLookup: UserPresetLookup?
    private var lastPresetRecheck: Date?
    private var presetRecheckInFlight = false
    /// S19 déjà montré pendant cette session de l'app.
    private var documentsWarningShown = false

    private var documentsAccessDenied: Bool {
        if case .accessDenied? = lastPresetLookup { return true }
        return false
    }

    private func notePresetLookup(_ lookup: UserPresetLookup) {
        if case .accessDenied(let why) = lookup, !documentsAccessDenied {
            log.error("Presets perso : accès refusé (\(why)) — index conservé ; nouvel essai à ⌘J (1 fois/min au plus) et quand Premiere revient au premier plan")
        }
        lastPresetLookup = lookup
    }

    /// S19, une fois par session de l'app.
    private func warnDocumentsAccess() {
        guard !documentsWarningShown else { return }
        documentsWarningShown = true
        HUD.show(L("Khanjar can't read your presets: allow Documents in System Settings › Privacy & Security › Files and Folders › Khanjar"),
                 duration: 6, style: .warning)
    }

    /// C-08 points 1 et 5 — accès refusé : nouvel essai au plus une fois par minute ;
    /// pas de fichier de presets : revérifié à chaque fois (un pack importé apparaissait
    /// seulement au relancement : sans fichier au démarrage, aucune surveillance). En
    /// arrière-plan (l'accès à Documents peut bloquer sur le dialogue de macOS) ; si le
    /// fichier est lisible : surveillance et reconstruction.
    private func recheckUserPresetsIfNeeded(_ trigger: String) {
        guard server.isReady, !presetRecheckInFlight, let state = lastPresetLookup else { return }
        switch state {
        case .found:
            return
        case .accessDenied:
            if let last = lastPresetRecheck, Date().timeIntervalSince(last) < 60 { return }
        case .noFile:
            break
        }
        lastPresetRecheck = Date()
        presetRecheckInFlight = true
        let hostVersion = server.hello?.hostVersion ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lookup = IndexStore.userPresetLookup(hostVersion: hostVersion)
            DispatchQueue.main.async {
                guard let self else { return }
                self.presetRecheckInFlight = false
                guard case .found = lookup else { self.notePresetLookup(lookup); return }
                self.log.info("Presets perso lisibles de nouveau (\(trigger)) — surveillance et reconstruction")
                self.watchUserPresets()
                self.rebuildIndex(effects: self.effectsCache,
                                  premiereVersion: self.server.hello?.hostVersion ?? "?",
                                  locale: self.server.hello?.uiLocale ?? "en_US")
            }
        }
    }

    /// File d'écriture du snapshot de l'index (C-17).
    private let snapshotQueue = DispatchQueue(label: "khanjar.snapshot", qos: .utility)

    /// Un index « vrai » est en place (snapshot à jour, ou reconstruction avec les
    /// effets de Premiere) : un index provisoire arrivé après ne l'écrase pas.
    private var realIndexInstalled = false

    /// Intégration du 2026-10-09 — le snapshot passe en v7 (nouveaux ids de presets,
    /// I-02) et un snapshot v6 est ignoré : au PREMIER lancement de la nouvelle version,
    /// la palette (et la recherche des Réglages, qui marche sans Premiere) restait vide
    /// jusqu'au hello, puis 2 à 7 s de reconstruction. On reconstruit donc un index
    /// PROVISOIRE hors ligne : effets de l'ancien snapshot (lus quelle que soit sa
    /// version), presets perso et Adobe reparsés (langue des presets Adobe : celle du
    /// Mac, la vraie n'est connue qu'au hello). Le vrai index le remplace au hello.
    private func rebuildIndexOffline() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let old = IndexStore.loadSnapshotEffects()
            DispatchQueue.main.async {
                guard let self else { return }
                guard let old else {
                    self.log.info("Pas de snapshot — l'index sera construit à la connexion du plugin")
                    return
                }
                guard !self.realIndexInstalled else { return }
                self.log.info("Snapshot v\(old.version) (attendu v\(IndexSnapshot.currentVersion)) — index provisoire reconstruit hors ligne avec ses \(old.effects.count) effets")
                self.rebuildIndex(effects: old.effects, premiereVersion: old.premiereVersion,
                                  locale: Self.guessedPresetLocale(), provisional: true)
            }
        }
    }

    /// Langue des presets Adobe pour l'index provisoire : la 1ʳᵉ langue du Mac
    /// (« fr-FR » : factoryPresetFiles accepte les tirets et se rabat sur l'anglais).
    static func guessedPresetLocale(_ preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.first ?? "en_US"
    }

    // MARK: - Surveillance du fichier de presets (FSEvents/DispatchSource)

    private func watchUserPresets() {
        // L'accès à ~/Documents peut BLOQUER sur le dialogue de permission
        // macOS (TCC) — constaté 2026-07-11 : gel du démarrage quand l'app est
        // lancée via LaunchServices. Découverte + open() en arrière-plan ;
        // seule l'installation de la source revient sur le main thread.
        let hostVersion = server.hello?.hostVersion ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // C-08 (2026-10-09) : résultat qualifié (trouvé / pas de fichier / accès
            // refusé), retenu pour les nouveaux essais de ⌘J (recheckUserPresetsIfNeeded).
            let lookup = IndexStore.userPresetLookup(hostVersion: hostVersion)
            var fd: Int32 = -1
            if case .found(let file) = lookup { fd = open(file.path, O_EVTONLY) }
            DispatchQueue.main.async {
                guard let self else { if fd >= 0 { close(fd) }; return }
                self.notePresetLookup(lookup)
                guard case .found(let file) = lookup else { return }
                self.installPresetWatcher(fd: fd, file: file)
            }
        }
    }

    private func installPresetWatcher(fd: Int32, file: URL) {
        presetWatcher?.cancel()
        guard fd >= 0 else {
            log.error("Surveillance presets impossible (open \(file.lastPathComponent)) — permission Documents accordée ?")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.log.debug("Fichier de presets modifié — réindexation dans 2 s")
            self.reindexDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.rebuildIndex(effects: self.effectsCache,
                                  premiereVersion: self.server.hello?.hostVersion ?? "?",
                                  locale: self.server.hello?.uiLocale ?? "en_US")
                self.watchUserPresets() // ré-armer (Premiere réécrit/renomme le fichier)
            }
            self.reindexDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        presetWatcher = source
        log.debug("Surveillance presets active : \(file.lastPathComponent)")
    }

    // MARK: - Hooks de test (sans clavier ni souris)

    /// C-14 — crochets de signaux seulement sur demande explicite.
    static func testHooksEnabled(_ environment: [String: String]) -> Bool {
        environment["KHANJAR_TEST_HOOKS"] == "1"
    }

    /// SIGUSR1 : toggle palette (sans vérif. du premier plan) — état journalisé.
    /// SIGUSR2 : recherche "gauss" + application du 1er résultat (test bout-en-bout).
    private var sigusr1Source: DispatchSourceSignal?
    private var sigusr2Source: DispatchSourceSignal?
    private var sigwinchSource: DispatchSourceSignal?
    private var siginfoSource: DispatchSourceSignal?

    private func installSignalHooks() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        signal(SIGWINCH, SIG_IGN)
        signal(SIGINFO, SIG_IGN)

        // SIGINFO : ouvre la fenêtre Réglages (test headless de l'UI).
        let si = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        si.setEventHandler { [weak self] in
            self?.log.info("SIGINFO → ouvre Réglages (test)")
            self?.openSettings()
        }
        si.resume()
        siginfoSource = si

        // SIGWINCH : test du calque d'effets (comme le clic menu / ⌘<)
        let sw = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sw.setEventHandler { [weak self] in
            self?.log.info("SIGWINCH → addAdjustmentLayer (test)")
            self?.addAdjustmentLayer()
        }
        sw.resume()
        sigwinchSource = sw

        let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s1.setEventHandler { [weak self] in
            guard let self else { return }
            self.log.info("SIGUSR1 → toggle palette (test)")
            self.palette.isVisible ? self.palette.hide() : self.palette.show()
            self.log.info("Palette visible=\(self.palette.isVisible), index=\(self.prepared.count) items, bridge prêt=\(self.server.isReady)")
        }
        s1.resume()
        sigusr1Source = s1

        let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        s2.setEventHandler { [weak self] in
            guard let self else { return }
            let ranked = Scorer.rank(query: "gauss", prepared: self.prepared, limit: 1)
            guard let first = ranked.first else {
                self.log.error("SIGUSR2 : aucun résultat pour « gauss »")
                return
            }
            self.log.info("SIGUSR2 → apply « \(first.item.title) » (test bout-en-bout)")
            self.apply(first.item, origin: .test)
        }
        s2.resume()
        sigusr2Source = s2
    }
}
