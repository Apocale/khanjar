import Foundation

/// Auto-gestion du plugin UXP : le .ccx est embarqué dans les ressources de
/// l'app ; ce service l'installe (ou le met à niveau) via UPIA.
/// Enseignements empiriques intégrés :
///  - première installation → chargement à chaud (~5-15 s) sans redémarrage ;
///  - mise à jour par-dessus une instance en cours → PAS de rechargement fiable,
///    même en remove+install (constats du 2026-07-07 et du 2026-10-09). Depuis
///    l'app 0.8.4 (M1), la mise à niveau se fait Premiere FERMÉ (AppCoordinator) ;
///  - ⚠️ UPIA peut rester BLOQUÉ plusieurs minutes (3 min mesurées le
///    2026-09-19 pendant le démarrage de Premiere, sortie « status = -642 »).
///    Exécuté sur le fil principal, il gelait TOUTE l'app (pont WebSocket
///    compris : le plugin bouclait « WS fermé — reconnexion dans 2 s » jusqu'au
///    retour d'UPIA) → ⌘J muet 3 minutes après chaque lancement de Premiere.
///    Désormais : file dédiée + délai maximal, et aucune réinstallation
///    aveugle quand le dossier versionné du plugin est déjà présent.
final class PluginLifecycleService {
    private let log: Logger

    static let pluginDisplayName = "Khanjar"
    static let pluginId = "io.khanjar.executor"

    static let defaultUpiaPath =
        "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
    /// Après la fin d'UPIA, attente maximale de la fin de sa sortie (C-01).
    static let readerTimeout: TimeInterval = 5

    private let upiaPath: String
    /// Au-delà, UPIA est considéré bloqué et le processus est arrêté.
    private let upiaTimeout: TimeInterval
    private let embeddedOverride: (url: URL, version: String)?

    private let queue = DispatchQueue(label: "khanjar.upia", qos: .utility)

    enum Operation: Equatable { case install, upgrade, legacyRemoval }
    /// Opération UPIA en cours (lu et écrit sur le fil principal). Une seule à la
    /// fois : des cycles rapides bloquent UPIA (AGENTS §6).
    private(set) var currentOperation: Operation?
    var busy: Bool { currentOperation != nil }
    /// Une installation ou une mise à niveau de Khanjar tourne (pas le retrait de Dagger).
    var isInstalling: Bool { currentOperation == .install || currentOperation == .upgrade }
    /// Dernière mise à niveau lancée : une au plus par 10 min (C-01, point 4).
    private var lastUpgradeAt: Date?

    /// `upiaPath`/`embedded` : injectables pour les tests (faux UPIA, faux ccx).
    init(upiaPath: String = PluginLifecycleService.defaultUpiaPath,
         embedded: (url: URL, version: String)? = nil,
         upiaTimeout: TimeInterval = 90) {
        self.upiaPath = upiaPath
        self.embeddedOverride = embedded
        self.upiaTimeout = upiaTimeout
        // Instance de TEST (faux UPIA ou faux ccx injectés) : journal muet (C-11,
        // intégration du 2026-10-09). Sans ça, un selftest lancé hors HOME jetable
        // écrivait « UPIA --install → -642 » dans le vrai Khanjar.log — la ligne même
        // que lisent le support et le prompt d'installation.
        log = upiaPath == Self.defaultUpiaPath && embedded == nil ? .shared : .muted
    }

    /// Version du ccx embarqué (gravée au packaging par build-app.sh).
    /// nil si on tourne hors bundle (dev CLI) → service inactif.
    var embeddedCcx: (url: URL, version: String)? {
        if let embeddedOverride { return embeddedOverride }
        guard let url = Bundle.main.url(forResource: "khanjar-executor", withExtension: "ccx"),
              let version = Bundle.main.object(forInfoDictionaryKey: "KhanjarPluginVersion") as? String
        else { return nil }
        return (url, version)
    }

    var upiaAvailable: Bool { FileManager.default.isExecutableFile(atPath: upiaPath) }

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

    // MARK: - Installation / mise à niveau

    /// Résultat d'un passage d'UPIA (C-01).
    struct UpiaResult: Equatable {
        var ok: Bool
        /// Code extrait de « status = -NNN » (ex. -642), nil s'il n'y en a pas.
        var code: Int?
        /// Sortie d'UPIA sur une ligne, bornée à 2 Ko.
        var output: String
        var timedOut: Bool
        /// Arrêtée entre deux commandes parce que `between` a répondu non (F1) :
        /// `--remove` fait, `--install` pas lancé.
        var aborted = false
    }

    /// Ce que `reconcile` a fait (C-01, point 1).
    enum ReconcileOutcome: Equatable {
        /// UPIA lancé (message à afficher) ; la completion rendra son résultat.
        case started(String)
        /// Dossier versionné déjà là : on laisse Premiere le charger.
        case alreadyDeposited
        /// Rien à faire (à jour, plus récent que l'embarqué, ou mise à niveau trop récente).
        case upToDate
        /// UPIA travaille déjà : revenir plus tard.
        case busy
        /// UPIA absent (Creative Cloud requis) — message à afficher.
        case unavailable(String)
        /// Hors bundle (CLI de développement) : service inactif.
        case devMode
    }

    /// Installation (aucun plugin connecté) ou mise à niveau (Premiere fermé, M1).
    /// `installedVersion` = version installée connue (inscription d'Adobe, hello),
    /// nil si inconnue. `force` = réinstaller même si le dossier versionné est déjà
    /// présent. `between` (fil principal), demandé entre deux commandes UPIA : non →
    /// arrêt (F1, Premiere relancé pendant une mise à niveau).
    /// L'action s'exécute en arrière-plan (jamais sur le fil principal) ;
    /// `completion` (fil principal) est appelée UNE fois, si et seulement si
    /// le résultat est `.started`. Avant (C-01) : completion facultative, passée
    /// par aucun appelant — le résultat d'UPIA n'était lu par personne.
    @discardableResult
    func reconcile(installedVersion: String?, force: Bool = false, now: Date = Date(),
                   between: (() -> Bool)? = nil,
                   completion: @escaping (UpiaResult) -> Void) -> ReconcileOutcome {
        guard let embedded = embeddedCcx else { return .devMode }
        // 1. Faut-il agir ? (avant de regarder UPIA : un plugin à jour ne doit pas
        //    afficher « Creative Cloud requis » à chaque hello quand UPIA manque.)
        let operation: Operation
        let commands: [[String]]
        let note: String
        switch installedVersion {
        case nil:
            // Pas (encore) de hello. Si le dossier versionné existe, Premiere
            // charge le plugin tout seul : on attend sa connexion au lieu de
            // relancer UPIA (qui bloquait 3 min pendant le démarrage de Premiere).
            if !force, isEmbeddedVersionInstalled() {
                log.info("Plugin v\(embedded.version) déjà déposé par UPIA — en attente de sa connexion (pas de réinstallation)")
                return .alreadyDeposited
            }
            operation = .install
            commands = [["--install", embedded.url.path]]
            note = "Plugin non connecté — installation du ccx embarqué v\(embedded.version)\(force ? " (forcée)" : "")"
        case embedded.version?:
            return .upToDate
        case let old?:
            // C-01 (2026-10-09) — toute version DIFFÉRENTE déclenchait remove+install :
            // une vieille copie de Khanjar rétrogradait le plugin (vécu le 14/07,
            // « v0.4.1 ≠ embarqué v0.4.0 »), sans aucune pause entre deux cycles
            // (et un hello falsifié suffisait à enchaîner des cycles UPIA, audit A6).
            guard PluginInstallPolicy.isNewer(embedded.version, than: old) else {
                log.info("Plugin v\(old) plus récent que l'embarqué v\(embedded.version) — pas de rétrogradation")
                return .upToDate
            }
            if let last = lastUpgradeAt, now.timeIntervalSince(last) < PluginInstallPolicy.upgradeCooldown {
                log.info("Plugin v\(old) < embarqué v\(embedded.version) — mise à niveau déjà tentée il y a \(Int(now.timeIntervalSince(last))) s, on attend")
                return .upToDate
            }
            operation = .upgrade
            commands = [["--remove", Self.pluginDisplayName], ["--install", embedded.url.path]]
            note = "Plugin v\(old) ≠ embarqué v\(embedded.version) — mise à niveau (remove+install)"
        }
        // 2. UPIA présent et libre ?
        guard upiaAvailable else {
            log.error("UPIA introuvable — Creative Cloud est requis pour installer le plugin")
            return .unavailable(L("Creative Cloud is required to install the Khanjar plugin"))
        }
        guard !busy else {
            log.info("UPIA déjà en cours — demande ignorée")
            return .busy
        }
        log.info(note)
        if operation == .upgrade { lastUpgradeAt = now }
        run(commands, operation: operation, between: between, completion: completion)
        return .started(operation == .install
                        ? L("Installing the Khanjar plugin in Premiere…")
                        : L("Updating the Khanjar plugin — restart Premiere if it doesn't take effect"))
    }

    /// Enchaîne les commandes UPIA sur la file dédiée, une par une ; le succès
    /// rapporté est celui de la DERNIÈRE commande (un --remove sans plugin installé
    /// échoue sans conséquence). F1 (relecture du 2026-10-11) : entre deux
    /// commandes, `between` est demandé sur le fil principal ; non → arrêt, résultat
    /// `aborted` (avant : remove puis install sans regarder Premiere entre les deux).
    private func run(_ commands: [[String]], operation: Operation, between: (() -> Bool)? = nil,
                     completion: @escaping (UpiaResult) -> Void) {
        currentOperation = operation
        func step(_ index: Int, _ last: UpiaResult) {
            if index > 0, index < commands.count, let between, !between() {
                currentOperation = nil
                var stopped = last
                stopped.ok = false
                stopped.aborted = true
                completion(stopped)
                return
            }
            guard index < commands.count else {
                currentOperation = nil
                completion(last)
                return
            }
            queue.async { [weak self] in
                guard let self else { return }
                let result = self.runUpia(commands[index])
                DispatchQueue.main.async { step(index + 1, result) }
            }
        }
        step(0, UpiaResult(ok: false, code: nil, output: "", timedOut: false))
    }

    /// Exécution synchrone SUR LA FILE UPIA (jamais sur le fil principal),
    /// bornée dans le temps.
    private func runUpia(_ args: [String]) -> UpiaResult {
        let verb = args.first ?? ""
        let tool = Self.runTool(executable: upiaPath, args: args,
                                timeout: upiaTimeout, readerTimeout: Self.readerTimeout)
        if let launchError = tool.launchError {
            log.error("UPIA injoignable : \(launchError)")
            return UpiaResult(ok: false, code: nil, output: "", timedOut: false)
        }
        let output = Self.oneLine(tool.output, limit: 2_048)
        let code = Self.upiaStatusCode(in: tool.output)
        if tool.readerTimedOut {
            log.info("UPIA \(verb) : sortie encore ouverte \(Int(Self.readerTimeout)) s après la fin du processus — lecture arrêtée")
        }
        if tool.timedOut {
            log.error("UPIA \(verb) → délai dépassé (\(Int(upiaTimeout)) s), processus arrêté — \(output)")
            return UpiaResult(ok: false, code: code, output: output, timedOut: true)
        }
        let ok = tool.status == 0 && !tool.output.contains("Failed")
        // C-01 (2026-10-09) — le résultat partait en [info], réduit à sa dernière
        // ligne : un échec ne ressortait pas en cherchant « [error] ». Début de ligne
        // « UPIA --install → » inchangé (lu par le diagnostic d'installation).
        // Un --remove d'un plugin absent (-406) est sans conséquence : pas une erreur.
        if ok || (verb == "--remove" && code == -406) {
            log.info("UPIA \(verb) → \(output)")
        } else {
            log.error("UPIA \(verb) → \(code.map(String.init) ?? "sortie \(tool.status)") — \(output)")
        }
        return UpiaResult(ok: ok, code: code, output: output, timedOut: false)
    }

    // MARK: - Exécution bornée d'un outil

    struct ToolResult {
        var status: Int32
        var output: String
        var timedOut: Bool
        /// La sortie est restée ouverte après la fin du processus (un processus
        /// enfant la garde) : lecture arrêtée au bout de `readerTimeout`.
        var readerTimedOut: Bool
        var launchError: String?
    }

    /// Lance `executable` et attend sa fin, au plus `timeout` (puis arrêt), puis
    /// la fin de sa sortie, au plus `readerTimeout`.
    ///
    /// C-01 (2026-10-09) — l'ancien `reader.wait()` attendait SANS LIMITE la fin du
    /// tuyau : si UPIA (ou un processus qu'il lance) gardait la sortie ouverte, l'appel
    /// ne rendait jamais la main et `busy` restait vrai toute la session (aucune
    /// installation, mise à niveau ni reprise possible). Mesuré par l'audit A2 : faux
    /// UPIA qui lance `sleep 25 &` → 25 s de blocage malgré le délai de 90 s.
    /// La lecture se fait maintenant par petits morceaux (poll), arrêtée au délai,
    /// la sortie partielle est gardée.
    static func runTool(executable: String, args: [String],
                        timeout: TimeInterval, readerTimeout: TimeInterval) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, output: "", timedOut: false, readerTimedOut: false,
                              launchError: "\(error)")
        }
        // Lecture en tâche de fond : un tampon plein bloquerait l'outil lui-même.
        let reader = PipeReader(handle: pipe.fileHandleForReading)
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let read = reader.collect(eofTimeout: readerTimeout)
        return ToolResult(status: process.terminationStatus,
                          output: String(decoding: read.data, as: UTF8.self),
                          timedOut: timedOut, readerTimedOut: !read.reachedEOF, launchError: nil)
    }

    /// « Failed to install, status = -642! » → -642.
    static func upiaStatusCode(in output: String) -> Int? {
        guard let range = output.range(of: #"status\s*=\s*-?\d+"#, options: .regularExpression) else { return nil }
        let digits = output[range].drop { $0 != "-" && !$0.isNumber }
        return Int(digits)
    }

    /// Sortie sur une seule ligne de journal, bornée.
    static func oneLine(_ output: String, limit: Int) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.isEmpty ? "(vide)" : lines.joined(separator: " | ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    // MARK: - Ancien plugin « Dagger Executor »

    /// Nom d'affichage de l'ancien plugin (avant le renommage en Khanjar,
    /// 2026-10-06). S'il reste inscrit chez Adobe, il se reconnecte toutes les
    /// 2 s au port de Khanjar, se fait refuser (identifiant inattendu) et
    /// recommence indéfiniment : bruit dans le journal, CPU gaspillé.
    static let legacyPluginDisplayName = "Dagger Executor"

    enum LegacyRemovalOutcome: Equatable {
        case started
        /// Déjà tenté pendant cette session de l'app.
        case alreadyAttempted
        /// UPIA travaille : revenir plus tard.
        case busy
        case unavailable
    }

    /// Retrait déjà lancé pendant cette session de l'app.
    private var legacyRemovalAttempted = false

    /// Retire l'ancien plugin, une fois par session de l'app.
    ///
    /// C-20 (2026-10-09) — un marqueur sur disque (`Khanjar/.legacy-plugin-removed`)
    /// rendait le retrait DÉFINITIF : un ancien plugin Dagger réinstallé plus tard
    /// (ancien testeur, sauvegarde restaurée) n'était plus jamais retiré et se
    /// faisait refuser toutes les 2 s, pour toujours. Le pont ne signale l'ancien
    /// plugin qu'une fois par session : une tentative par session suffit, et la
    /// suivante a lieu au prochain lancement de Khanjar. Le vieux marqueur n'est
    /// plus lu. UPIA occupé → `.busy`, l'app réessaie (+2 min).
    @discardableResult
    func removeLegacyPluginOnce(completion: ((UpiaResult) -> Void)? = nil) -> LegacyRemovalOutcome {
        guard !legacyRemovalAttempted else { return .alreadyAttempted }
        guard upiaAvailable else { return .unavailable }
        guard !busy else { return .busy }
        legacyRemovalAttempted = true
        currentOperation = .legacyRemoval
        log.info("Retrait de l'ancien plugin « \(Self.legacyPluginDisplayName) »")
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.runUpia(["--remove", Self.legacyPluginDisplayName])
            DispatchQueue.main.async {
                self.currentOperation = nil
                if !result.ok {
                    if result.code == -406 || result.output.contains("-406") {
                        self.log.info("Ancien plugin déjà absent (-406) — rien à retirer")
                    } else {
                        self.log.error("Retrait de l'ancien plugin non abouti — nouvel essai au prochain lancement de Khanjar")
                    }
                }
                completion?(result)
            }
        }
        return .started
    }
}

/// Lit un tuyau jusqu'à sa fin SANS jamais bloquer au-delà d'un délai choisi
/// (C-01) : lecture par petits morceaux, contrôle d'arrêt toutes les 100 ms.
private final class PipeReader {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var stopRequested = false
    private let finished = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        let fd = handle.fileDescriptor
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                lock.lock(); let stop = stopRequested; lock.unlock()
                if stop { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if ready < 0 { if errno == EINTR { continue } else { break } }
                if ready == 0 { continue }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    lock.lock(); data.append(contentsOf: buffer[0..<count]); lock.unlock()
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break   // 0 = fin du tuyau ; < 0 = erreur
                }
            }
            finished.signal()
        }
    }

    /// Attend la fin du tuyau au plus `eofTimeout`, puis arrête la lecture, ferme
    /// le tuyau et rend ce qui a été lu (partiel si le délai a été dépassé).
    func collect(eofTimeout: TimeInterval) -> (data: Data, reachedEOF: Bool) {
        let reached = finished.wait(timeout: .now() + eofTimeout) == .success
        if !reached {
            lock.lock(); stopRequested = true; lock.unlock()
            _ = finished.wait(timeout: .now() + 1)   // le fil sort au prochain poll (≤ 100 ms)
        }
        try? handle.close()
        lock.lock(); defer { lock.unlock() }
        return (data, reached)
    }
}
