import Foundation

/// Journal horodaté : stdout + fichier rotatif simple.
/// (~/Library/Logs/Khanjar/Khanjar.log ; au-delà de 5 Mo, renommé en Khanjar.log.1)
final class Logger {
    static let shared = Logger()
    /// Journal muet : n'écrit ni à l'écran ni sur le disque. Sert aux tests
    /// (LegacyMigration en bac à sable) — voir C-11 ci-dessous.
    static let muted = Logger(muted: true)

    /// Chemin du journal — partagé (menu « Ouvrir le journal », amorçage du
    /// classement des fréquents) pour qu'il n'existe qu'à un seul endroit.
    let fileURL: URL
    private let formatter: DateFormatter
    private let queue = DispatchQueue(label: "khanjar.logger")
    private let isMuted: Bool
    private let echo: Bool
    private let maxBytes: Int
    private let checkEveryLines: Int
    /// Lignes écrites depuis le dernier contrôle de taille (lu et écrit sur `queue`).
    private var linesSinceCheck = 0

    /// `fileURL` nil = ~/Library/Logs/Khanjar/Khanjar.log. Les autres paramètres
    /// ne servent qu'aux tests (fichier temporaire, seuil réduit).
    init(fileURL: URL? = nil, muted: Bool = false, echo: Bool = true,
         maxBytes: Int = 5_000_000, checkEveryLines: Int = 1_000) {
        formatter = Self.makeTimestampFormatter()
        isMuted = muted
        self.echo = echo
        self.maxBytes = maxBytes
        self.checkEveryLines = checkEveryLines
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Khanjar", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("Khanjar.log")
        }
        // Un journal muet ne touche jamais au disque (ni dossier, ni rotation).
        guard !muted else { return }
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // C-11 (2026-10-09) — au-delà de 5 Mo, le journal était EFFACÉ d'un coup au
        // lancement : tout l'historique perdu (dont celui que relit l'amorçage des
        // fréquents). On le renomme désormais en Khanjar.log.1 (qui remplace l'ancien).
        Self.rotateIfNeeded(fileURL: self.fileURL, maxBytes: maxBytes)
    }

    /// C-11 (2026-10-09) — horodatage dans le calendrier et les chiffres du Mac :
    /// sous arabe, thaï ou persan le journal devenait illisible (« ١٤٤٨-٠٤-٢٧ »,
    /// « 2569-10-08 »), et l'amorçage des fréquents, qui relit en en_US_POSIX, ne
    /// reconnaissait plus aucune date. Format FIXE : grégorien, chiffres latins.
    /// Le fuseau reste celui du Mac (comme avant).
    static func makeTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }

    /// Renomme le journal en `<nom>.1` s'il dépasse `maxBytes` (l'ancien `.1` est
    /// remplacé). Retourne vrai si une rotation a eu lieu.
    @discardableResult
    static func rotateIfNeeded(fileURL: URL, maxBytes: Int) -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size > maxBytes else { return false }
        let rotated = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        do {
            try fm.moveItem(at: fileURL, to: rotated)
            return true
        } catch {
            // Renommage impossible (droits…) : on retombe sur l'ancien comportement
            // plutôt que de laisser le fichier grossir sans fin.
            try? fm.removeItem(at: fileURL)
            return false
        }
    }

    var debugEnabled = false

    func info(_ message: String) { write("info", message) }
    func error(_ message: String) { write("error", message) }
    func debug(_ message: String) {
        guard debugEnabled else { return }
        write("debug", message)
    }

    /// Attend que les lignes déjà demandées soient sur le disque (tests).
    func waitForPendingWrites() {
        queue.sync {}
    }

    private func write(_ level: String, _ message: String) {
        guard !isMuted else { return }
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        if echo {
            print(line, terminator: "")
            fflush(stdout)
        }
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }
            // C-11 (2026-10-09) — la taille n'était contrôlée qu'au lancement : une
            // longue session (refus répétés toutes les 2 s : ~7 Mo/jour) faisait
            // grossir le fichier sans borne. Contrôle toutes les 1 000 lignes.
            linesSinceCheck += 1
            if linesSinceCheck >= checkEveryLines {
                linesSinceCheck = 0
                Self.rotateIfNeeded(fileURL: fileURL, maxBytes: maxBytes)
            }
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                // write(contentsOf:) lève une erreur Swift ; write(_:) levait une exception
                // Objective-C (disque plein…) qui faisait planter l'app.
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
