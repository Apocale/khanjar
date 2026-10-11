import Foundation

/// Politique d'installation du plugin — décisions PURES, testées par le selftest.
///
/// C-01 (2026-10-09, cas « 3 minutes sans hello » chez un ami testeur). Avant : une seule
/// tentative UPIA à T+20 s, résultat lu par personne, aucun nouvel essai, aucun
/// message d'échec ni « redémarre Premiere » ; UPIA occupé = chaîne arrêtée ; le
/// filet de reprise ne s'armait que sur une DÉCONNEXION (jamais pour un plugin
/// jamais connecté) et pouvait lancer UPIA pendant le démarrage de Premiere (le
/// blocage de 3 min d'AGENTS §6). Le coordinateur fournit l'état ; ces fonctions
/// disent quoi faire.
enum PluginInstallPolicy {
    /// Version minimale de Premiere du manifeste du plugin (host.minVersion 25.6.0).
    static let minimumPremiereVersion = "25.6"
    /// Jamais d'UPIA dans la minute qui suit le lancement de Premiere : sollicité
    /// pendant son démarrage, UPIA reste bloqué jusqu'à 3 min (status -642, AGENTS §6).
    static let launchGrace: TimeInterval = 60
    /// Premiere encore « en cours de lancement » pour AppKit : nouveau regard dans 15 s.
    static let launchingRecheck: TimeInterval = 15
    static let retryWhenBusy: TimeInterval = 30
    static let retryAfterFailure: TimeInterval = 120
    static let maxAttempts = 3
    static let checkAfterInstall: TimeInterval = 45
    static let checkAfterUpgrade: TimeInterval = 30
    static let upgradeCooldown: TimeInterval = 600
    /// Dossier du plugin déjà déposé mais aucun hello : réinstallation forcée après ça.
    static let forceAfterSilence: TimeInterval = 60

    /// Ce que l'app sait du Premiere qui tourne.
    struct Premiere: Equatable {
        var finishedLaunching: Bool
        var launchDate: Date?
        /// CFBundleShortVersionString de l'app Premiere (ex. « 26.5.2 »), nil si illisible.
        var version: String?
    }

    enum Gate: Equatable {
        case noPremiere
        /// Premiere plus ancien que le minimum du manifeste : pas d'UPIA (S5).
        case tooOld(String)
        /// Trop tôt : revenir dans N s.
        case wait(TimeInterval)
        case go
    }

    /// (a) + (f) du plan : peut-on solliciter UPIA maintenant ?
    static func gate(_ premiere: Premiere?, now: Date) -> Gate {
        guard let premiere else { return .noPremiere }
        if let version = premiere.version,
           compareVersions(version, minimumPremiereVersion) == .orderedAscending {
            return .tooOld(version)
        }
        guard premiere.finishedLaunching else { return .wait(launchingRecheck) }
        if let launched = premiere.launchDate {
            let age = now.timeIntervalSince(launched)
            if age < launchGrace { return .wait((launchGrace - age).rounded(.up) + 1) }
        }
        return .go
    }

    /// Délai avant de revenir, selon ce que `reconcile` a répondu (nil = rien à reprogrammer :
    /// une installation lancée rendra son résultat, ou il n'y a rien à faire).
    static func recheckDelay(after outcome: PluginLifecycleService.ReconcileOutcome) -> TimeInterval? {
        switch outcome {
        case .busy: return retryWhenBusy
        case .alreadyDeposited: return forceAfterSilence
        case .started, .upToDate, .unavailable, .devMode: return nil
        }
    }

    enum AfterUpia: Equatable {
        /// Succès : vérifier dans N s qu'un hello est bien arrivé.
        case verify(after: TimeInterval)
        /// Échec : nouvel essai dans N s.
        case retry(after: TimeInterval)
        /// Échec du dernier essai permis : arrêt (S2) ; le menu permet de relancer.
        case giveUp
    }

    /// (c) + (d) : suite à donner au résultat d'UPIA. `failures` = échecs AVANT celui-ci.
    static func afterUpia(ok: Bool, upgrade: Bool, failures: Int) -> (next: AfterUpia, failures: Int) {
        if ok { return (.verify(after: upgrade ? checkAfterUpgrade : checkAfterInstall), 0) }
        let count = failures + 1
        return (count < maxAttempts ? .retry(after: retryAfterFailure) : .giveUp, count)
    }

    /// (d) Installé avec succès mais toujours pas de hello : le plugin a-t-il démarré ?
    /// Son journal disque est réécrit à chaque démarrage (index.js) : écrit depuis le
    /// DÉBUT de l'installation = chargé mais incapable de joindre Khanjar (S4) ; sinon
    /// Premiere ne l'a pas chargé → redémarrer Premiere (S3).
    static func issueAfterSilentInstall(pluginLogDates: [Date], installStartedAt: Date) -> PluginInstallIssue {
        pluginLogDates.contains { $0 >= installStartedAt } ? .loadedButMute : .restartNeeded(afterUpgrade: false)
    }

    /// Comparaison numérique composante par composante (« 0.7.10 » > « 0.7.9 »,
    /// « 25.6 » == « 25.6.0 »). Une composante non numérique compte pour 0.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (pa, pb) = (parts(a), parts(b))
        for i in 0..<max(pa.count, pb.count) {
            let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// (4) Mise à niveau seulement vers une version PLUS RÉCENTE (jamais de rétrogradation).
    static func isNewer(_ candidate: String, than reference: String) -> Bool {
        compareVersions(candidate, reference) == .orderedDescending
    }

    // MARK: - Mise à niveau, Premiere FERMÉ (M1, relecture finale du 2026-10-09)

    /// Après la fermeture de Premiere, attente avant de solliciter UPIA (F1) : une
    /// relance rapide (« Rouvrir » après un plantage, redémarrage voulu) tombe le plus
    /// souvent dans ces 30 s, et la mise à niveau attend alors la fermeture suivante.
    static let afterPremiereQuit: TimeInterval = 30
    /// Au lancement de Khanjar (souvent à l'ouverture de session, en même temps que
    /// Creative Cloud et juste avant Premiere) : une minute d'attente (F1).
    static let afterKhanjarLaunch: TimeInterval = 60
    /// Service de fond de Creative Cloud (« Creative Cloud Core Service ») : UPIA en a
    /// besoin. Absent → pas de mise à niveau, l'ancien plugin reste en service (F1).
    static let creativeCloudServiceId = "com.adobe.acc.AdobeDesktopService"

    /// M1 (2026-10-11) — la mise à niveau partait AU HELLO, c'est-à-dire ~13 s après le
    /// lancement de Premiere : en plein dans la fenêtre du blocage de 3 min d'UPIA
    /// (AGENTS §6) ; si l'installation bloquait après le retrait, plus de plugin du tout.
    /// Et une mise à niveau faite Premiere OUVERT n'est presque jamais rechargée à chaud
    /// (vécu le 2026-10-09) : ⌘J muet en plein montage jusqu'à la relance de Premiere.
    /// Désormais le plugin ancien reste en service (même protocole) et la mise à niveau
    /// se fait Premiere FERMÉ : à sa fermeture, ou au lancement de Khanjar s'il est fermé.
    ///
    /// Version installée à mettre à niveau (nil = rien à faire). L'inscription d'Adobe
    /// (`premierepro.json`) fait foi : un hello falsifié ne déclenche rien si elle est à
    /// jour. Illisible : la version du dernier hello. Absente mais vue au hello : dossier
    /// résiduel chargé par Premiere (AGENTS §6bis) — on réinscrit.
    static func versionToUpgradeWhileClosed(registered: PluginInstallDiagnostics.Registration?,
                                            lastHello: String?, embedded: String) -> String? {
        let installed: String?
        if let registered, registered.found {
            installed = registered.version ?? lastHello
        } else {
            installed = lastHello
        }
        guard let installed, isNewer(embedded, than: installed) else { return nil }
        return installed
    }

    /// Retrait de l'ancien plugin Dagger : même porte que l'installation (il se présente,
    /// lui aussi, pendant le démarrage de Premiere). Délai d'attente, nil = maintenant
    /// (Premiere fermé : UPIA ne risque rien ; trop ancien : rien à attendre).
    static func legacyRemovalDelay(_ premiere: Premiere?, now: Date) -> TimeInterval? {
        if case .wait(let delay) = gate(premiere, now: now) { return delay }
        return nil
    }
}

/// Ce qui empêche le plugin d'être en service, quand on le sait (C-01, affiché par C-05).
enum PluginInstallIssue: Equatable {
    case creativeCloudMissing
    case premiereTooOld(String)
    /// `final` = les 3 essais ont échoué (S2), sinon un nouvel essai est prévu (S1).
    case installFailed(code: Int?, final: Bool)
    /// Installé (ou mis à niveau) mais Premiere ne l'a pas chargé : le relancer (S3 / S6).
    case restartNeeded(afterUpgrade: Bool)
    /// Le plugin tourne (son journal est récent) mais ne joint pas Khanjar (S4).
    case loadedButMute
}

/// Lecture SEULE des traces d'Adobe, pour expliquer un plugin installé mais muet (C-01 d).
enum PluginInstallDiagnostics {
    struct Registration: Equatable, CustomStringConvertible {
        var found: Bool
        var status: String?
        var version: String?
        var description: String {
            found ? "inscrit chez Adobe (statut \(status ?? "?"), v\(version ?? "?"))" : "absent de l'inscription d'Adobe"
        }
    }

    private static var uxpDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Adobe/UXP", isDirectory: true)
    }

    /// Format relevé le 2026-10-09 (Premiere 26.5.2) :
    /// {"plugins":[{"pluginId":"io.khanjar.executor","status":"enabled","versionString":"0.7.2",…}]}
    /// nil = contenu illisible.
    static func registration(in data: Data, pluginId: String) -> Registration? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = json["plugins"] as? [[String: Any]] else { return nil }
        guard let entry = plugins.first(where: { $0["pluginId"] as? String == pluginId }) else {
            return Registration(found: false)
        }
        return Registration(found: true, status: entry["status"] as? String, version: entry["versionString"] as? String)
    }

    /// Inscription du plugin dans `UXP/PluginsInfo/v1/premierepro.json` (nil : fichier absent ou illisible).
    static func readRegistration(pluginId: String) -> Registration? {
        let url = uxpDirectory.appendingPathComponent("PluginsInfo/v1/premierepro.json")
        return (try? Data(contentsOf: url)).flatMap { registration(in: $0, pluginId: pluginId) }
    }

    /// Dates de dernière écriture du journal du plugin, une par version de Premiere :
    /// `UXP/PluginsStorage/PPRO/<n>/External/<id>/PluginData/khanjar-executor.log`.
    static func pluginLogDates(pluginId: String) -> [Date] {
        let fm = FileManager.default
        let root = uxpDirectory.appendingPathComponent("PluginsStorage/PPRO", isDirectory: true)
        let versions = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return versions.compactMap { version in
            let log = root.appendingPathComponent("\(version)/External/\(pluginId)/PluginData/khanjar-executor.log")
            return (try? fm.attributesOfItem(atPath: log.path))?[.modificationDate] as? Date
        }
    }
}
