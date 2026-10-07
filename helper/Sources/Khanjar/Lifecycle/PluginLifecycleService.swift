import Foundation

/// Auto-gestion du plugin UXP : le .ccx est embarqué dans les ressources de
/// l'app ; ce service l'installe (ou le met à niveau) via UPIA.
/// Enseignements empiriques intégrés :
///  - première installation → chargement à chaud (~5-15 s) sans redémarrage ;
///  - mise à jour par-dessus une instance en cours → PAS de rechargement :
///    remove+install, et si le hello reste sur l'ancienne version, proposer
///    un redémarrage de Premiere (hot-swap parfois inopérant après une longue
///    inactivité — constat du 2026-07-07) ;
///  - ⚠️ UPIA peut rester BLOQUÉ plusieurs minutes (3 min mesurées le
///    2026-09-19 pendant le démarrage de Premiere, sortie « status = -642 »).
///    Exécuté sur le fil principal, il gelait TOUTE l'app (pont WebSocket
///    compris : le plugin bouclait « WS fermé — reconnexion dans 2 s » jusqu'au
///    retour d'UPIA) → ⌘J muet 3 minutes après chaque lancement de Premiere.
///    Désormais : file dédiée + délai maximal, et aucune réinstallation
///    aveugle quand le dossier versionné du plugin est déjà présent.
final class PluginLifecycleService {
    private let log = Logger.shared

    static let pluginDisplayName = "Khanjar"
    static let pluginId = "io.khanjar.executor"

    private static let upiaPath =
        "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
    /// Au-delà, UPIA est considéré bloqué et le processus est arrêté.
    private static let upiaTimeout: TimeInterval = 90

    private let queue = DispatchQueue(label: "khanjar.upia", qos: .utility)
    /// Une seule opération UPIA à la fois (des cycles rapides le bloquent, §6).
    private(set) var busy = false

    /// Version du ccx embarqué (gravée au packaging par build-app.sh).
    /// nil si on tourne hors bundle (dev CLI) → service inactif.
    var embeddedCcx: (url: URL, version: String)? {
        guard let url = Bundle.main.url(forResource: "khanjar-executor", withExtension: "ccx"),
              let version = Bundle.main.object(forInfoDictionaryKey: "KhanjarPluginVersion") as? String
        else { return nil }
        return (url, version)
    }

    var upiaAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.upiaPath) }

    /// Dossier où UPIA dépose le plugin : `…/External/io.khanjar.executor_<version>/`.
    static func installedPluginDir(version: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Adobe/UXP/Plugins/External/\(pluginId)_\(version)", isDirectory: true)
    }

    /// Le ccx embarqué est-il déjà déposé par UPIA (dossier versionné + manifeste) ?
    func isEmbeddedVersionInstalled() -> Bool {
        guard let embedded = embeddedCcx else { return false }
        let manifest = Self.installedPluginDir(version: embedded.version).appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Appelé au démarrage (aucun hello encore) et à chaque hello.
    /// `installedVersion` = version annoncée par le hello, nil si inconnue.
    /// `force` = réinstaller même si le dossier versionné est déjà présent.
    /// Retourne immédiatement un message utilisateur si une action est LANCÉE ;
    /// l'action s'exécute en arrière-plan (jamais sur le fil principal).
    /// `completion` (fil principal) reçoit le succès d'UPIA.
    @discardableResult
    func reconcile(installedVersion: String?, force: Bool = false,
                   completion: ((Bool) -> Void)? = nil) -> String? {
        guard let embedded = embeddedCcx else { return nil } // mode dev
        guard upiaAvailable else {
            log.error("UPIA introuvable — Creative Cloud est requis pour installer le plugin")
            return L("Creative Cloud is required to install the Khanjar plugin")
        }
        guard !busy else {
            log.info("UPIA déjà en cours — demande ignorée")
            return nil
        }
        switch installedVersion {
        case nil:
            // Pas (encore) de hello. Si le dossier versionné existe, Premiere
            // charge le plugin tout seul : on attend sa connexion au lieu de
            // relancer UPIA (qui bloquait 3 min pendant le démarrage de Premiere).
            if !force, isEmbeddedVersionInstalled() {
                log.info("Plugin v\(embedded.version) déjà déposé par UPIA — en attente de sa connexion (pas de réinstallation)")
                return nil
            }
            log.info("Plugin non connecté — installation du ccx embarqué v\(embedded.version)\(force ? " (forcée)" : "")")
            run([["--install", embedded.url.path]], completion: completion)
            return L("Installing the Khanjar plugin in Premiere…")
        case embedded.version:
            return nil // à jour
        case .some(let old):
            log.info("Plugin v\(old) ≠ embarqué v\(embedded.version) — mise à niveau (remove+install)")
            run([["--remove", Self.pluginDisplayName], ["--install", embedded.url.path]], completion: completion)
            return L("Updating the Khanjar plugin — restart Premiere if it doesn't take effect")
        }
    }

    /// Enchaîne les commandes UPIA sur la file dédiée ; le succès rapporté est
    /// celui de la DERNIÈRE commande (un --remove sans plugin installé échoue
    /// sans conséquence).
    private func run(_ commands: [[String]], completion: ((Bool) -> Void)?) {
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            var ok = false
            for args in commands { ok = self.runUpia(args).ok }
            DispatchQueue.main.async {
                self.busy = false
                completion?(ok)
            }
        }
    }

    /// Exécution synchrone SUR LA FILE UPIA (jamais sur le fil principal),
    /// bornée dans le temps.
    private func runUpia(_ args: [String]) -> (ok: Bool, output: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.upiaPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            log.error("UPIA injoignable : \(error)")
            return (false, "", false)
        }
        // Lecture en tâche de fond : un tampon plein bloquerait UPIA lui-même.
        var outputData = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let deadline = Date().addingTimeInterval(Self.upiaTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        reader.wait()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let last = output.split(separator: "\n").last.map(String.init) ?? "(vide)"
        if timedOut {
            log.error("UPIA \(args.first ?? "") → délai dépassé (\(Int(Self.upiaTimeout)) s), processus arrêté — \(last)")
            return (false, output, true)
        }
        log.info("UPIA \(args.first ?? "") → \(last)")
        return (process.terminationStatus == 0 && !output.contains("Failed"), output, false)
    }

    // MARK: - Ancien plugin « Dagger Executor »

    /// Nom d'affichage de l'ancien plugin (avant le renommage en Khanjar,
    /// 2026-10-06). S'il reste inscrit chez Adobe, il se reconnecte toutes les
    /// 2 s au port de Khanjar, se fait refuser (identifiant inattendu) et
    /// recommence indéfiniment : bruit dans le journal, CPU gaspillé.
    static let legacyPluginDisplayName = "Dagger Executor"

    private static var legacyRemovedMarker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar/.legacy-plugin-removed")
    }

    /// Retire l'ancien plugin, une seule fois. Le marqueur est posé si UPIA a
    /// répondu, y compris « -406 » (plugin déjà absent) ; il ne l'est PAS sur
    /// délai dépassé, pour retenter au prochain lancement.
    func removeLegacyPluginOnce() {
        let marker = Self.legacyRemovedMarker
        guard !FileManager.default.fileExists(atPath: marker.path), upiaAvailable, !busy else { return }
        busy = true
        log.info("Retrait de l'ancien plugin « \(Self.legacyPluginDisplayName) »")
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.runUpia(["--remove", Self.legacyPluginDisplayName])
            DispatchQueue.main.async {
                self.busy = false
                guard !result.timedOut else { return }
                // Marqueur posé seulement si le retrait est acquis (réussi, ou -406 = déjà
                // absent). Sur une autre erreur d'UPIA (Poco::SystemException…), on
                // retentera au prochain lancement au lieu d'abandonner pour toujours.
                guard result.ok || result.output.contains("-406") else {
                    self.log.error("Retrait de l'ancien plugin non abouti — nouvel essai au prochain lancement")
                    return
                }
                try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? Data().write(to: marker)
                if !result.ok, result.output.contains("-406") {
                    self.log.info("Ancien plugin déjà absent (-406) — rien à retirer")
                }
            }
        }
    }
}
