import Foundation

/// Journal horodaté : stdout + fichier rotatif simple.
/// (~/Library/Logs/Khanjar/Khanjar.log, tronqué au-delà de 5 Mo au démarrage)
final class Logger {
    static let shared = Logger()

    /// Chemin du journal — partagé (menu « Ouvrir le journal », amorçage du
    /// classement des fréquents) pour qu'il n'existe qu'à un seul endroit.
    let fileURL: URL
    private let formatter: DateFormatter
    private let queue = DispatchQueue(label: "khanjar.logger")

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Khanjar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("Khanjar.log")

        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size > 5_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    var debugEnabled = false

    func info(_ message: String) { write("info", message) }
    func error(_ message: String) { write("error", message) }
    func debug(_ message: String) {
        guard debugEnabled else { return }
        write("debug", message)
    }

    private func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        print(line, terminator: "")
        fflush(stdout)
        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
