import AppKit
import Carbon.HIToolbox

/// Assignation d'un raccourci clavier à un preset (ou effet), appliqué au(x)
/// clip(s) sélectionné(s) quand Premiere est au premier plan.
/// - `itemId`  : id STABLE du SearchItem — "preset:<uid>" | "effect:<matchName>".
/// - `title`   : conservé en secours d'affichage ET de re-résolution par NOM si
///               l'uid change (presets sans `MZ.EffectPresets.PresetUID`).
/// - `shortcut`: même syntaxe que les autres ("ctrl+shift+a").
struct PresetShortcut: Codable, Equatable {
    var itemId: String
    var title: String
    var shortcut: String
}

/// Réglages utilisateur — fichier JSON simple, surveillé et appliqué à chaud.
/// ~/Library/Application Support/Khanjar/settings.json :
/// {
///   "shortcut": "cmd+j",        // modificateurs : cmd, alt/option, ctrl, shift
///   "maxResults": 8,            // 1…20
///   "theme": "system",          // system | dark | light
///   "presetShortcuts": [        // raccourcis → presets (facultatif)
///     { "itemId": "preset:...", "title": "TR - Appear Up", "shortcut": "ctrl+shift+a" }
///   ]
/// }
struct Settings: Codable, Equatable {
    var shortcut: String = "cmd+j"
    var maxResults: Int = 8
    var theme: String = "system"
    /// Optionnels pour ne pas invalider les settings.json existants (clé absente
    /// = décodage OK grâce à l'optionnalité ; cf. `shortcutAdjustmentLayer`).
    var shortcutAdjustmentLayer: String?
    var presetShortcuts: [PresetShortcut]?
    /// Transposer les presets sur le cadrage ACTUEL du clip (échelle
    /// proportionnelle, position/rotation additives) au lieu d'écraser les
    /// valeurs. Optionnel = compatible avec les settings.json existants.
    var relativeToClip: Bool?
    /// Rapports de plantage anonymes : consentement EXPLICITE (opt-in). Absent = non.
    var crashReports: Bool?

    var adjustmentShortcut: String { shortcutAdjustmentLayer ?? "cmd+shift+j" }
    var shortcuts: [PresetShortcut] { presetShortcuts ?? [] }
    var adaptToClip: Bool { relativeToClip ?? true }
    var sendsCrashReports: Bool { crashReports ?? false }

    static let `default` = Settings()
}

final class SettingsStore {
    private let log = Logger.shared
    private var watcher: DispatchSourceFileSystemObject?
    private(set) var current = Settings.default

    var onChange: ((Settings) -> Void)?

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    /// Écrit les réglages (le watcher déclenchera onChange → application à chaud).
    func save(_ settings: Settings) {
        current = sanitized(settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(current) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func load() {
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            // Fichier modèle au premier lancement (documentation vivante)
            if let data = try? JSONEncoder().encode(Settings.default) {
                try? data.write(to: url)
            }
        }
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(Settings.self, from: data) {
            current = sanitized(parsed)
        } else {
            log.error("settings.json illisible — réglages par défaut conservés")
            current = .default
        }
        watch()
    }

    private func sanitized(_ s: Settings) -> Settings {
        var out = s
        out.maxResults = min(max(s.maxResults, 1), 20)
        if !["system", "dark", "light"].contains(s.theme) { out.theme = "system" }
        return out
    }

    private func watch() {
        watcher?.cancel()
        let fd = open(Self.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let before = self.current
                self.load() // recharge + ré-arme le watcher
                if self.current != before {
                    self.log.info("Réglages rechargés : \(self.current)")
                    self.onChange?(self.current)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: - Parsing du raccourci ("cmd+alt+j" → keyCode + modificateurs Carbon)

    static func parseShortcut(_ text: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: String?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "alt", "option", "opt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            case let k: key = k
            }
        }
        guard modifiers != 0, let k = key, let keyCode = keyCodes[k] else { return nil }
        return (keyCode, modifiers)
    }

    /// "cmd+shift+p" → "⌘⇧P" (affichage). Ordre canonique des symboles macOS.
    static func pretty(_ shortcut: String) -> String {
        var mods = "", key = ""
        for part in shortcut.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control", "⌃": mods += "⌃"
            case "alt", "option", "opt", "⌥": mods += "⌥"
            case "shift", "⇧": mods += "⇧"
            case "cmd", "command", "⌘": mods += "⌘"
            default: key = part == "<" ? "<" : (part == ">" ? ">" : part.uppercased())
            }
        }
        return mods + key
    }

    /// Touches ANSI usuelles (lettres, chiffres, quelques spéciales).
    private static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
        "k": 0x28, "n": 0x2D, "m": 0x2E,
        "space": 0x31, "espace": 0x31, "return": 0x24, "entrée": 0x24,
        // Claviers ISO/AZERTY : touche « < » à gauche du Shift = keycode 50
        // (échange ISO connu avec 10 = « § » au-dessus de Tab ; si « < » ne
        // répond pas sur un clavier donné, utiliser "iso-alt")
        "<": 0x32, ">": 0x32, "iso-alt": 0x0A, "§": 0x0A,
    ]
}
