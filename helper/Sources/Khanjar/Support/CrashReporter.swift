import Foundation

/// Rapports de plantage anonymes — envoyés SEULEMENT si l'utilisateur a coché la case
/// (opt-in, `Settings.crashReports`) ET si le build porte une adresse d'envoi (DSN Sentry,
/// injectée par build-app.sh depuis l'environnement, jamais commitée dans le dépôt).
///
/// Source : le rapport `.ips` que macOS écrit LUI-MÊME à chaque plantage
/// (~/Library/Logs/DiagnosticReports/Khanjar-<date>.ips). Rien n'est capturé dans le
/// processus (pas de gestionnaire de signaux, pas de SDK tiers) : un plantage reste un
/// plantage ordinaire, son rapport n'est lu qu'au lancement suivant.
///
/// Ce qui part, et rien d'autre : versions de Khanjar et du plugin, version de macOS,
/// type d'exception, message d'erreur Swift nettoyé, et la pile du fil fautif réduite à
/// « bibliothèque + fonction ».
/// Ce qui ne part JAMAIS : chemins, identifiants de la machine ou de l'utilisateur
/// (userID, crashReporterKey, bootSessionUUID…), modèle du Mac, autres fils, noms de
/// clips/presets/projets (les textes entre guillemets du message sont masqués), nom de
/// la machine. Plateforme « other » : Sentry n'en déduit pas d'adresse IP.
enum CrashReporter {

    struct Frame: Equatable {
        let image: String
        let function: String
        let inApp: Bool
        /// Décalage dans la bibliothèque : avec le binaire de la même version,
        /// `atos -o Khanjar -l 0x100000000 <0x100000000 + décalage>` redonne la ligne
        /// exacte du code (vérifié le 2026-10-06 : main.swift:865 retrouvé).
        var offset: Int = 0
    }

    struct Report {
        let incidentId: String
        let timestamp: Date
        let appVersion: String
        /// UUID du binaire de Khanjar qui a planté (relie le rapport à un build précis).
        let buildUUID: String?
        let osVersion: String
        let exceptionType: String
        let signal: String
        let message: String?
        /// Fil fautif, du plus INTERNE au plus externe (ordre du rapport macOS).
        let frames: [Frame]
    }

    static let maxFrames = 40
    static let maxReportsPerLaunch = 3
    static let maxAgeDays = 14.0

    // MARK: - Lecture d'un rapport macOS (.ips)

    /// `.ips` = une ligne d'en-tête JSON, puis le corps JSON. `nil` si ce n'est pas un
    /// rapport de plantage de Khanjar (autre app, format inconnu).
    static func parse(_ text: String, acceptedNames: Set<String> = ["Khanjar"]) -> Report? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = json(String(text[..<newline])),
              let body = json(String(text[text.index(after: newline)...])) else { return nil }
        let name = header["name"] as? String ?? body["procName"] as? String ?? ""
        guard acceptedNames.contains(name) else { return nil }

        let exception = body["exception"] as? [String: Any] ?? [:]
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        var frames: [Frame] = []
        if let faulting = body["faultingThread"] as? Int,
           let threads = body["threads"] as? [[String: Any]], threads.indices.contains(faulting) {
            for raw in (threads[faulting]["frames"] as? [[String: Any]] ?? []).prefix(maxFrames) {
                let index = raw["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index] : "?"
                let offset = raw["imageOffset"] as? Int ?? 0
                let function = (raw["symbol"] as? String).map(scrub) ?? "\(image) + \(offset)"
                frames.append(Frame(image: image, function: function, inApp: acceptedNames.contains(image), offset: offset))
            }
        }
        // Message d'erreur Swift (« Fatal error: … ») : dans « asi » (Application Specific
        // Information), indexé par bibliothèque.
        let asi = (body["asi"] as? [String: [String]] ?? [:]).values.flatMap { $0 }
        let message = asi.first { $0.contains("Fatal error") || $0.contains("error") }.map(scrub)

        return Report(
            incidentId: header["incident_id"] as? String ?? UUID().uuidString,
            timestamp: date(header["timestamp"] as? String) ?? Date(),
            appVersion: (header["app_version"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?",
            buildUUID: header["slice_uuid"] as? String,
            osVersion: header["os_version"] as? String ?? "?",
            exceptionType: exception["type"] as? String ?? "?",
            signal: exception["signal"] as? String ?? "?",
            message: message,
            frames: frames)
    }

    /// Masque ce qui pourrait identifier l'utilisateur dans un texte libre : dossiers
    /// d'un chemin (on garde le nom du fichier source), textes entre guillemets (un nom
    /// de preset ou de clip interpolé dans un message), et longueur bornée.
    static func scrub(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"(?:/[^/\s:"']+)+/([^/\s:"']+)"#, "$1"),          // /Users/x/projet/Fichier.swift → Fichier.swift
            (#""[^"]*""#, "\"…\""), (#"“[^”]*”"#, "“…”"), (#"«[^»]*»"#, "«…»"), (#"'[^']*'"#, "'…'"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }

    // MARK: - Événement Sentry

    static func event(for report: Report, pluginVersion: String?) -> [String: Any] {
        var os: [String: Any] = ["name": "macOS", "version": report.osVersion]
        // « macOS 26.6.2 (25G83) » → version 26.6.2, build 25G83
        let parts = report.osVersion.replacingOccurrences(of: "macOS ", with: "")
            .split(separator: " ").map(String.init)
        if let version = parts.first { os["version"] = version }
        if parts.count > 1 { os["build"] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        return [
            "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "timestamp": report.timestamp.timeIntervalSince1970,
            "platform": "other",
            "level": "fatal",
            "logger": "macos-crash-report",
            "release": "khanjar@\(report.appVersion)",
            // Tout ce qui précède la 1.0 (ou de version inconnue) est une bêta.
            "environment": (Int(report.appVersion.split(separator: ".").first ?? "") ?? 0) >= 1 ? "production" : "beta",
            "tags": ["plugin_version": pluginVersion ?? "?", "signal": report.signal,
                     "build_uuid": report.buildUUID ?? "?"],
            "contexts": ["os": os],
            "exception": ["values": [[
                "type": report.exceptionType,
                "value": report.message ?? report.signal,
                "mechanism": ["type": "mach", "handled": false],
                // Sentry attend l'appelant le plus externe EN PREMIER : inverse de macOS.
                "stacktrace": ["frames": report.frames.reversed().map {
                    ["function": $0.function, "package": $0.image, "in_app": $0.inApp,
                     "instruction_addr": String(format: "0x%llx", $0.offset)]
                }],
            ]]],
        ]
    }

    struct Endpoint: Equatable {
        let url: URL
        let publicKey: String
    }

    /// DSN `https://<clé>@<hôte>/<projet>` → point d'envoi des enveloppes.
    static func endpoint(dsn: String) -> Endpoint? {
        guard let comps = URLComponents(string: dsn.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = comps.user, !key.isEmpty, let host = comps.host,
              comps.scheme == "https" || comps.scheme == "http" else { return nil }
        let path = comps.path.split(separator: "/").map(String.init)
        guard let project = path.last, !project.isEmpty else { return nil }
        var out = URLComponents()
        out.scheme = comps.scheme
        out.host = host
        out.port = comps.port
        out.path = "/" + (path.dropLast() + ["api", project, "envelope"]).joined(separator: "/") + "/"
        return out.url.map { Endpoint(url: $0, publicKey: key) }
    }

    static func envelope(event: [String: Any]) -> Data? {
        guard let payload = try? JSONSerialization.data(withJSONObject: event),
              let id = event["event_id"] as? String else { return nil }
        let header = #"{"event_id":"\#(id)","sent_at":"\#(ISO8601DateFormatter().string(from: Date()))"}"#
        let item = #"{"type":"event","length":\#(payload.count)}"#
        var data = Data((header + "\n" + item + "\n").utf8)
        data.append(payload)
        data.append(Data("\n".utf8))
        return data
    }

    // MARK: - Envoi au lancement

    /// Adresse d'envoi : variable d'environnement (tests), sinon Info.plist (build publié).
    static var configuredDSN: String? {
        let candidates = [ProcessInfo.processInfo.environment["KHANJAR_SENTRY_DSN"],
                          Bundle.main.object(forInfoDictionaryKey: "KhanjarCrashReportDSN") as? String]
        return candidates.compactMap { $0 }.first { endpoint(dsn: $0) != nil }
    }

    /// La case n'est proposée que si ce build sait où envoyer (sinon promesse vide).
    static var isAvailable: Bool { configuredDSN != nil }

    static var reportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar/crash-reports.json")
    }

    /// Rapports de Khanjar pas encore envoyés, des 14 derniers jours, plus récents d'abord.
    static func pendingReports(in directory: URL = reportsDirectory, alreadySent: Set<String>,
                               acceptedNames: Set<String> = ["Khanjar"]) -> [(url: URL, report: Report)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86_400)
        return files
            .filter { url in url.pathExtension == "ips"
                && acceptedNames.contains { url.lastPathComponent.hasPrefix("\($0)-") } }
            .compactMap { url -> (url: URL, report: Report)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let report = parse(text, acceptedNames: acceptedNames),
                      report.timestamp > cutoff, !alreadySent.contains(report.incidentId) else { return nil }
                return (url, report)
            }
            .sorted { $0.report.timestamp > $1.report.timestamp }
    }

    /// Au lancement (hors fil principal) : envoie les plantages en attente si l'utilisateur
    /// a consenti. Un rapport est marqué envoyé sur 2xx, ou sur 4xx (refus définitif :
    /// inutile de réessayer à chaque lancement) ; sur erreur réseau ou 5xx, il attend le
    /// lancement suivant.
    static func sendPendingIfConsented(_ consented: Bool, pluginVersion: String?, log: Logger = .shared) {
        guard consented, let dsn = configuredDSN, let endpoint = endpoint(dsn: dsn) else { return }
        DispatchQueue.global(qos: .utility).async {
            var sent = loadSent()
            let pending = pendingReports(alreadySent: sent).prefix(maxReportsPerLaunch)
            guard !pending.isEmpty else { return }
            let group = DispatchGroup()
            let lock = NSLock()
            for (_, report) in pending {
                guard let body = envelope(event: event(for: report, pluginVersion: pluginVersion)) else { continue }
                var request = URLRequest(url: endpoint.url, timeoutInterval: 15)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
                request.setValue("Sentry sentry_version=7, sentry_key=\(endpoint.publicKey), sentry_client=khanjar/\(report.appVersion)",
                                 forHTTPHeaderField: "X-Sentry-Auth")
                group.enter()
                URLSession.shared.dataTask(with: request) { _, response, error in
                    defer { group.leave() }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(status) || ((400..<500).contains(status) && status != 429) {
                        lock.lock(); sent.insert(report.incidentId); lock.unlock()
                    }
                    log.info("Rapport de plantage \(report.incidentId.prefix(8)) (\(report.exceptionType)) : HTTP \(status)\(error.map { " — \($0.localizedDescription)" } ?? "")")
                }.resume()
            }
            group.wait()
            saveSent(sent)
        }
    }

    private static func loadSent() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    private static func saveSent(_ ids: Set<String>) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids.sorted()).write(to: stateURL, options: .atomic)
    }

    // MARK: - Outils

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// « 2026-10-04 17:41:13.00 +0200 »
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
