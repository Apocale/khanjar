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
        } else {
            log.info("Pas de snapshot — l'index sera construit à la connexion du plugin")
        }

        // 2. Bridge
        server.onHello = { [weak self] info in
            self?.log.info("Plugin prêt : \(info.pluginVersion) / Premiere \(info.hostVersion)")
            self?.pluginWaitSince = nil
            self?.pluginSilentSince = nil
            if let message = self?.pluginLifecycle.reconcile(installedVersion: info.pluginVersion) {
                HUD.show(message)
            }
            self?.rebuildIndexFromPlugin()
            // La version de Premiere n'est connue qu'ici : ré-armer la
            // surveillance sur le profil de CETTE version (cf. userPresetFile).
            self?.watchUserPresets()
        }
        // Si Premiere tourne mais qu'aucun plugin ne se connecte, tenter
        // l'installation du ccx embarqué (premier lancement sur machine vierge).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.installPluginIfPremiereRunning()
        }
        // ⚠️ CAS NOMINAL D'UN NOUVEL UTILISATEUR : il lance Khanjar (ou Khanjar
        // démarre avec la session) PUIS ouvre Premiere. La tentative unique à
        // T+20 s ne voyait alors aucun Premiere → le plugin n'était JAMAIS
        // installé et ⌘J restait muet pour toujours. On observe donc aussi le
        // lancement de Premiere.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true else { return }
            self?.log.info("Premiere lancé — vérification du plugin dans 15 s")
            self?.pluginWaitSince = nil
            // Laisser à Premiere le temps de charger ses plug-ins avant de conclure.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.installPluginIfPremiereRunning()
            }
        }
        // L'ancien plugin Dagger se présente encore : on le retire chez Adobe.
        server.onLegacyPlugin = { [weak self] in
            self?.pluginLifecycle.removeLegacyPluginOnce()
        }
        server.onDisconnect = { [weak self] in
            guard let self else { return }
            self.pluginSilentSince = Date()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(1) }
        }
        // Sans remise à zéro, 6 échecs cumulés sur toute la vie de l'app suffisaient à l'arrêter.
        server.onListenerReady = { [weak self] in self?.listenRetries = 0 }
        try server.start()

        // 3. Réglages (chargés avant hotkey/palette, appliqués à chaud ensuite)
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
        palette.onCommit = { [weak self] item in self?.apply(item) }
        // Champ vide → classement fréquence + récence. Les entrées dont l'item
        // a disparu de l'index (preset supprimé dans Premiere) sont sautées.
        palette.onFrequent = { [weak self] limit in
            guard let self else { return [] }
            var singles: [(item: SearchItem, count: Int)] = []
            for entry in self.usage.top(limit) {
                guard let item = self.itemLookup[entry.id] else { continue }
                singles.append((item: item, count: entry.count))
            }
            var combos: [(item: SearchItem, count: Int)] = []
            for pair in self.usage.topPairs(Self.maxCombosShown) {
                guard let a = self.itemLookup[pair.from], let b = self.itemLookup[pair.to],
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

        // 5. Presets : surveillance du fichier utilisateur
        watchUserPresets()

        // 6. Barre de menus + fenêtre de réglages
        let statusText: () -> String = { [weak self] in
            guard let self else { return "" }
            if let hello = self.server.hello {
                return LF("Connected — Premiere %@ · plugin %@", hello.hostVersion, hello.pluginVersion)
            }
            return L("Waiting for Premiere…")
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

        // 7. Hooks de test sans clavier (documentés dans le README)
        installSignalHooks()

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
    /// Depuis quand aucun plugin n'est connecté (lancement de l'app ou déconnexion).
    private var pluginSilentSince: Date? = Date()
    private func installPluginIfPremiereRunning() {
        guard !server.isReady else { return }
        guard let premiere = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true }) else { return }
        guard premiere.isFinishedLaunching else {
            log.info("Premiere en cours de lancement — nouvelle vérification du plugin dans 15 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.installPluginIfPremiereRunning()
            }
            return
        }
        let since = pluginWaitSince ?? Date()
        pluginWaitSince = since
        let force = Date().timeIntervalSince(since) >= 60
        if let message = pluginLifecycle.reconcile(installedVersion: nil, force: force) {
            HUD.show(message, duration: 4)
        } else if !force, !pluginLifecycle.busy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.installPluginIfPremiereRunning()
            }
        }
    }

    /// Le plugin n'est pas revenu de lui-même : on le réinstalle. Ne fait rien
    /// si le pont s'est rétabli entre-temps, si Premiere a été fermé, si UPIA
    /// travaille déjà, ou si une tentative est trop récente.
    private func revivePluginIfStillSilent() {
        guard !server.isReady, !pluginLifecycle.busy else { return }
        let premiereRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true }
        guard premiereRunning else { return }
        if let last = lastRevivalAttempt, Date().timeIntervalSince(last) < Self.pluginRevivalCooldown {
            log.info("Plugin absent mais réinstallation trop récente — on attend")
            return
        }
        lastRevivalAttempt = Date()
        log.error("Plugin toujours absent \(Int(Self.pluginRevivalDelay)) s après la déconnexion, Premiere ouvert — réinstallation du ccx embarqué")
        if let message = pluginLifecycle.reconcile(installedVersion: nil, force: true) {
            HUD.show(message, duration: 4)
        }
    }

    /// Ouvre la fenêtre de réglages (menu barre de menus, ou reopen de l'app).
    func openSettings() {
        settingsWindow.open()
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
            else { HUD.show(LF("Khanjar: shortcut “%@” unavailable (%@)", ps.shortcut, title)) }
        }
    }

    /// Fire d'un raccourci preset : résout l'item par id (secours : par titre si
    /// l'uid a changé), puis applique. HUD explicite si le preset a disparu.
    private func applyShortcut(itemId: String, title: String) {
        guard server.isReady else { HUD.show(L("Khanjar: Premiere not connected")); return }
        if let item = itemLookup[itemId] ?? itemLookup.values.first(where: { $0.title == title }) {
            apply(item)
        } else {
            HUD.show(LF("Khanjar: “%@” not found — reassign it in Settings", title), duration: 3)
            log.error("Raccourci preset : item \(itemId) / « \(title) » absent de l'index")
        }
    }

    private func registerHotkey(id: UInt32, spec: String, fallback: String, action: @escaping () -> Void) {
        let parsed = SettingsStore.parseShortcut(spec) ?? SettingsStore.parseShortcut(fallback)
        if SettingsStore.parseShortcut(spec) == nil {
            log.error("Raccourci invalide « \(spec) » — repli \(fallback)")
        }
        guard let parsed else { return }
        if !HotkeyService.shared.register(id: id, keyCode: parsed.keyCode, modifiers: parsed.modifiers, action: action) {
            HUD.show(LF("Khanjar: shortcut “%@” unavailable", spec))
        }
    }

    // MARK: - Calque d'effets

    func addAdjustmentLayer() {
        guard server.isReady else {
            HUD.show(L("Khanjar: Premiere not connected"))
            log.info("addAdjustmentLayer ignoré : bridge non prêt")
            return
        }
        server.request(cmd: "addAdjustmentLayer", timeout: 3) { [weak self] result in
            switch result {
            case .success(let payload):
                let track = (payload["trackIndex"] as? Int).map { "V\($0 + 1)" } ?? "?"
                HUD.show(LF("Adjustment layer → track %@", track))
                self?.log.info("addAdjustmentLayer OK : \(payload)")
            case .failure(.remote(let code, let message)) where code == "ADJUSTMENT_NOT_FOUND":
                // Texte de l'app (traduit), pas celui du plugin (en français, en dur).
                HUD.show(L("No adjustment layer in this project — create one once (File > New > Adjustment Layer)"), duration: 3.5)
                self?.log.info("addAdjustmentLayer : \(message)")
            case .failure(let error):
                HUD.show(Self.userMessage(for: error))
                self?.log.error("addAdjustmentLayer ÉCHEC : \(error)")
            }
        }
    }

    // MARK: - Invocation

    private func summon() {
        if palette.isVisible {
            palette.hide()
            return
        }
        guard server.isReady else {
            // Distinguer les deux cas : sans ça le HUD disait « Ouvre Premiere
            // Pro » alors que Premiere était à l'écran (capture du 2026-10-06),
            // ce qui envoie chercher le problème au mauvais endroit.
            let premiereRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true }
            if let premiere = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true }), premiereRunning {
                HUD.show(L("Khanjar is reconnecting to Premiere…"), duration: 3)
                // Réinstaller SEULEMENT si le plugin est muet depuis plus de 45 s et que
                // Premiere a fini de démarrer. Avant (audit du 2026-10-07), ⌘J pendant
                // le lancement de Premiere ou une reconnexion de 2 s lançait UPIA tout
                // de suite : le blocage de 3 min du §6, puis 10 min sans nouvel essai.
                let silentFor = pluginSilentSince.map { Date().timeIntervalSince($0) } ?? 0
                if premiere.isFinishedLaunching, silentFor >= Self.pluginRevivalDelay {
                    log.info("Invocation sans plugin depuis \(Int(silentFor)) s, Premiere ouvert — relance du filet")
                    revivePluginIfStillSilent()
                } else {
                    log.info("Invocation sans plugin depuis \(Int(silentFor)) s — trop tôt pour réinstaller, on attend")
                }
            } else {
                HUD.show(L("Open Premiere Pro to use Khanjar"), duration: 3)
                log.info("Invocation sans plugin connecté (Premiere fermé)")
            }
            return
        }
        if prepared.isEmpty {
            HUD.show(L("Khanjar: building the index…"))
            return
        }
        palette.show()
    }

    // MARK: - Application d'un item

    /// Un apply à la fois : deux applications concurrentes s'entrelacent et
    /// posent les effets EN DOUBLE (constaté possible quand un timeout invite à
    /// réessayer alors que Premiere travaille encore).
    private var applyInFlight = false

    private func apply(_ item: SearchItem) {
        let label = item.title
        guard !applyInFlight else {
            HUD.show(L("Applying — one moment"), duration: 2.5)
            log.info("apply ignoré : une application est déjà en cours (\(label))")
            return
        }
        applyInFlight = true
        // Délai proportionné à la CHARGE : un preset très keyframé (cuisson
        // d'ease) demande bien plus que 4 s. Un délai trop court affichait un
        // échec alors que Premiere travaillait encore — et invitait à réappliquer
        // (effets en double). 4 s de base + 1 s par tranche de 200 keyframes.
        let kfCount = item.plan.operations.reduce(0) { $0 + $1.params.reduce(0) { $0 + $1.keyframes.count } }
            + item.plan.existingOperations.reduce(0) { $0 + $1.params.reduce(0) { $0 + $1.keyframes.count } }
        let timeout = min(30.0, 4.0 + Double(kfCount) / 200.0)
        server.request(cmd: "apply",
                       payload: ["plan": item.plan.protocolPayload,
                                 "options": ["relativeToClip": settings.current.adaptToClip]],
                       timeout: timeout) { [weak self] result in
            self?.applyInFlight = false
            switch result {
            case .success(let payload):
                let clips = (payload["applied"] as? [String: Any])?["clips"] as? Int ?? 0
                let latency = payload["latencyMs"] as? Int ?? -1
                let skippedInfo = payload["skipped"] as? [String: Any]
                let skipped = skippedInfo?["items"] as? Int ?? 0
                let reason = skippedInfo?["reason"] as? String
                let failedClips = skippedInfo?["failedClips"] as? [String] ?? []
                var message = clips > 1 ? LF("%@ → %ld clips", label, clips) : LF("%@ → %ld clip", label, clips)
                // Les pistes AUDIO liées d'une sélection sont ignorées par
                // construction : ne pas les annoncer (bruit à chaque clip sonore).
                // Seuls les clips VIDÉO qui n'ont pas reçu l'effet sont signalés.
                if !failedClips.isEmpty {
                    message += failedClips.count > 1 ? LF(" (%ld clips not applied)", failedClips.count) : L(" (1 clip not applied)")
                }
                let fidelity = payload["fidelity"] as? [String: Any]
                let set = fidelity?["paramsSet"] as? Int ?? 0
                let skippedParams = fidelity?["paramsSkipped"] as? Int ?? 0
                if skippedParams > 0 { message += LF(" — %ld/%ld parameters", set, set + skippedParams) }
                // Compté seulement si au moins un clip a reçu l'effet : le
                // classement doit refléter le travail réel, pas les tentatives.
                if clips > 0 {
                    // Un duo crédite ses deux membres (et l'enchaînement), pas
                    // un id synthétique que l'index ne connaîtrait pas.
                    if let members = item.comboMembers {
                        self?.usage.recordCombo(from: members.from, to: members.to)
                    } else {
                        self?.usage.record(id: item.id, title: item.title)
                    }
                }
                HUD.show(message)
                // Paramètres écrits alors que leur nom diffère (preset créé dans
                // un Premiere d'une autre langue) : tracé pour le diagnostic.
                let namesDiffer = fidelity?["namesDiffer"] as? Int ?? 0
                let langNote = namesDiffer > 0 ? " nomsAutreLangue=\(namesDiffer)" : ""
                self?.log.info("apply OK : \(label), \(clips) clips appliqués, skipped=\(skipped) reason=\(reason ?? "-") failed=\(failedClips) transaction=\(payload["transaction"] ?? "?") \(latency) ms\(langNote)")
                // Raisons détaillées (échec de clip, param sauté, média indécis) :
                // journalisées pour diagnostiquer sans mode debug.
                if let detail = fidelity?["detail"] as? [[String: Any]], !detail.isEmpty,
                   !failedClips.isEmpty || skippedParams > 0 || detail.contains(where: { ($0["reason"] as? String) == "MEDIA_TYPE_UNKNOWN" }) {
                    let shown = detail.prefix(6).map { entry in
                        entry.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                    }
                    self?.log.info("apply détail (\(detail.count)) : \(shown.joined(separator: " | "))")
                }
            case .failure(let error):
                HUD.show(Self.userMessage(for: error))
                self?.log.error("apply ÉCHEC : \(label) — \(error)")
            }
        }
    }

    /// Messages orientés ACTION, compréhensibles par un non-technicien (le code
    /// technique reste dans le journal, jamais à l'écran).
    private static func userMessage(for error: BridgeError) -> String {
        switch error.code {
        case "NO_SELECTION": return L("Select a clip in the timeline first")
        case "NO_APPLICABLE_CLIP": return L("Select a video clip (not just audio)")
        case "NO_PROJECT", "NO_SEQUENCE": return L("Open a sequence in Premiere")
        case "EFFECT_NOT_FOUND": return L("This effect isn't available in your version of Premiere")
        case "PLUGIN_DISCONNECTED": return L("Open Premiere Pro to use Khanjar")
        case "TIMEOUT": return L("Premiere isn't responding — try again in a moment")
        default: return L("Couldn't apply the effect — try again")
        }
    }

    // MARK: - Index

    private func installItems(_ items: [SearchItem], origin: String) {
        let started = Date()
        prepared = Scorer.prepare(items)
        itemLookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        effectsCache = items.filter { $0.kind == "effect" }.compactMap { item in
            guard let matchName = item.plan.operations.first?.matchName else { return nil }
            return IndexStore.EffectEntry(matchName: matchName, displayName: item.title)
        }
        // Premier lancement : rejoue l'historique du journal pour que la liste
        // des fréquents soit juste dès la première ouverture de la palette.
        usage.seedIfNeeded(items: items)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("Index actif : \(items.count) items (préparation \(ms) ms) — source : \(origin)")
    }

    private func rebuildIndexFromPlugin() {
        server.request(cmd: "listEffects", timeout: 5) { [weak self] result in
            guard let self else { return }
            guard case .success(let payload) = result else {
                self.log.error("listEffects en échec — index snapshot conservé")
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
    private func rebuildIndex(effects: [IndexStore.EffectEntry], premiereVersion: String, locale: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var userPresets: [ParsedPreset] = []
            if let file = IndexStore.userPresetFile(hostVersion: premiereVersion) {
                userPresets = (try? PrfpsetParser.parse(fileURL: file)) ?? []
            }
            var factoryPresets: [ParsedPreset] = []
            for file in IndexStore.factoryPresetFiles(hostVersion: premiereVersion, locale: locale) {
                factoryPresets.append(contentsOf: (try? PrfpsetParser.parse(fileURL: file)) ?? [])
            }
            let items = IndexStore.build(effects: effects, userPresets: userPresets, factoryPresets: factoryPresets)

            DispatchQueue.main.async {
                guard let self else { return }
                // ⚠️ NE JAMAIS écraser un index qui contenait des presets par un
                // index qui n'en a plus : une permission Documents refusée (ou un
                // profil Premiere temporairement absent) ferait disparaître TOUS
                // les presets de l'utilisateur, en silence et de façon persistante
                // (le snapshot vide étant relu au démarrage suivant).
                let hadPresets = self.prepared.contains { $0.item.kind == "preset" }
                let hasPresets = items.contains { $0.kind == "preset" }
                if hadPresets && !hasPresets {
                    self.log.error("Reconstruction SANS aucun preset alors que l'index en avait — index conservé (permission Documents refusée ?)")
                    HUD.show(L("Presets not found — check access to your Documents folder"), duration: 5)
                    return
                }
                self.installItems(items, origin: "reconstruction (\(userPresets.count) presets user)")
                let snapshot = IndexSnapshot(version: IndexSnapshot.currentVersion,
                                             generatedAt: Date(),
                                             premiereVersion: premiereVersion,
                                             items: items)
                do { try IndexStore.saveSnapshot(snapshot) }
                catch { self.log.error("Écriture snapshot en échec : \(error)") }
            }
        }
    }

    // MARK: - Surveillance du fichier de presets (FSEvents/DispatchSource)

    private func watchUserPresets() {
        // L'accès à ~/Documents peut BLOQUER sur le dialogue de permission
        // macOS (TCC) — constaté 2026-07-11 : gel du démarrage quand l'app est
        // lancée via LaunchServices. Découverte + open() en arrière-plan ;
        // seule l'installation de la source revient sur le main thread.
        let hostVersion = server.hello?.hostVersion ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let file = IndexStore.userPresetFile(hostVersion: hostVersion) else { return }
            let fd = open(file.path, O_EVTONLY)
            DispatchQueue.main.async {
                self?.installPresetWatcher(fd: fd, file: file)
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
            self.apply(first.item)
        }
        s2.resume()
        sigusr2Source = s2
    }
}
