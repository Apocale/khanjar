import AppKit
import Carbon.HIToolbox

/// Assignation d'un raccourci clavier à un preset (ou effet), appliqué au(x)
/// clip(s) sélectionné(s) quand Premiere est au premier plan.
/// - `itemId`  : id STABLE du SearchItem — "preset:<uid>" | "preset:h:<empreinte>" |
///               "preset:adobe:<…>" | "effect:<matchName>" (formats du 2026-10-09).
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

/// Clés de settings.json illisibles relevées pendant un décodage (I-08) : passé au
/// décodeur par `userInfo`, rempli par `Settings.init(from:)`.
final class SettingsDecodingReport {
    var invalidKeys: [String] = []
}

extension CodingUserInfoKey {
    static let settingsReport = CodingUserInfoKey(rawValue: "khanjar.settingsReport")!
}

extension Settings {
    /// 2026-10-09 (audit A3#9, A4#15, B4#12) : le décodage synthétisé rejetait TOUT le
    /// fichier dès qu'une clé manquait (`{"shortcut":"cmd+k"}` → keyNotFound maxResults) :
    /// l'app restait aux défauts, puis le prochain enregistrement écrasait le fichier sans
    /// les raccourcis presets ajoutés à la main. Désormais chaque clé est lue à part :
    /// absente ou illisible → valeur par défaut, les autres sont gardées ; un raccourci
    /// preset abîmé est écarté seul. Les clés illisibles sont notées dans le rapport.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let report = decoder.userInfo[.settingsReport] as? SettingsDecodingReport
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            do { return try container.decodeIfPresent(T.self, forKey: key) }
            catch { report?.invalidKeys.append(key.stringValue); return nil }
        }
        if let value = read(String.self, .shortcut) { shortcut = value }
        if let value = read(Int.self, .maxResults) { maxResults = value }
        if let value = read(String.self, .theme) { theme = value }
        shortcutAdjustmentLayer = read(String.self, .shortcutAdjustmentLayer)
        if let list = read([LenientShortcut].self, .presetShortcuts) {
            presetShortcuts = list.compactMap(\.value)
            if list.contains(where: { $0.value == nil }) { report?.invalidKeys.append("presetShortcuts[…]") }
        }
        relativeToClip = read(Bool.self, .relativeToClip)
        crashReports = read(Bool.self, .crashReports)
    }

    /// Un élément de `presetShortcuts` : nil s'il est abîmé (les autres restent).
    private struct LenientShortcut: Decodable {
        let value: PresetShortcut?
        init(from decoder: Decoder) throws { value = try? PresetShortcut(from: decoder) }
    }
}

extension Settings {
    /// 2026-10-09 (audit A3#2, migration des ids « preset:obj:<n> ») : un raccourci preset
    /// dont l'id n'est plus dans l'index est rattaché au nouvel id quand son titre désigne
    /// un seul id distinct (`idForTitle`, même règle que `UsageStore.remapUnknownIds`), jamais d'un
    /// genre à l'autre. Les autres raccourcis restent tels quels (rien n'est supprimé).
    /// Fonction pure : l'appelant enregistre une seule fois si `remapped > 0` (C-04).
    func remappingUnknownShortcutIds(validIds: Set<String>,
                                     idForTitle: (String) -> String?) -> (settings: Settings, remapped: Int) {
        guard let list = presetShortcuts, !list.isEmpty else { return (self, 0) }
        func kind(_ id: String) -> Substring { id.split(separator: ":", maxSplits: 1).first ?? "" }
        var out = self
        var remapped = 0
        out.presetShortcuts = list.map { shortcut in
            guard !validIds.contains(shortcut.itemId), let newId = idForTitle(shortcut.title),
                  newId != shortcut.itemId, validIds.contains(newId),
                  kind(newId) == kind(shortcut.itemId) else { return shortcut }
            remapped += 1
            var moved = shortcut
            moved.itemId = newId
            return moved
        }
        return (out, remapped)
    }

    /// m3 (relecture finale, 2026-10-11) — raccourci dont l'id existe toujours sous un
    /// AUTRE titre (preset renommé dans Premiere) : le titre mémorisé suit, si plus aucun
    /// item ne porte l'ancien. Sinon un futur preset reprenant l'ancien nom capterait le
    /// raccourci (C-04 cherche par le titre mémorisé).
    func retitlingRenamedShortcuts(currentTitle: (String) -> String?,
                                   titleTaken: (_ title: String, _ id: String) -> Bool) -> (settings: Settings, renamed: Int) {
        guard let list = presetShortcuts, !list.isEmpty else { return (self, 0) }
        var out = self
        var renamed = 0
        out.presetShortcuts = list.map { shortcut in
            guard let title = currentTitle(shortcut.itemId),
                  SearchItem.normalizedTitle(title) != SearchItem.normalizedTitle(shortcut.title),
                  !titleTaken(shortcut.title, shortcut.itemId) else { return shortcut }
            renamed += 1
            var moved = shortcut
            moved.title = title
            return moved
        }
        return (out, renamed)
    }
}

/// Problème de settings.json à montrer au monteur (contrat C-10 : S26 / S27).
typealias SettingsIssue = SettingsStore.SettingsIssue

final class SettingsStore {
    /// 2026-10-09 (I-08, contrat 4.7) : `unreadable` = JSON illisible, réglages par défaut
    /// (ou derniers valides) en mémoire, copie gardée à côté (`backup`, nil si la copie a
    /// échoué) ; `saveFailed` = écriture impossible (disque plein…).
    enum SettingsIssue {
        case unreadable(backup: URL?)
        /// m9 (relecture finale, 2026-10-11) : JSON lisible, mais une ou plusieurs valeurs
        /// abîmées remises par défaut — le reste (raccourcis, thème…) est gardé. Avant,
        /// S26 annonçait « réglages par défaut » pour un seul « maxResults » illisible.
        case valuesReset(keys: [String], backup: URL?)
        case saveFailed
    }

    /// Instance de TEST (fichier dédié) : journal muet (C-11), jamais le vrai Khanjar.log.
    private var log: Logger { customURL != nil ? .muted : .shared }
    private var watcher: DispatchSourceFileSystemObject?
    private(set) var current = Settings.default

    /// Documentation (render-media) : affiche des réglages d'exemple SANS rien écrire
    /// sur le disque — les vrais réglages de l'utilisateur ne sont jamais touchés.
    func preview(_ settings: Settings) { current = sanitized(settings) }

    var onChange: ((Settings) -> Void)?
    /// Branché par AppCoordinator AVANT `load()` (contrat 4.7).
    var onIssue: ((SettingsIssue) -> Void)?

    /// Tests : fichier dédié (jamais le vrai settings.json), sans surveillance du fichier.
    private let customURL: URL?
    private let watchesFile: Bool
    /// Contenu déjà mis de côté : un même fichier abîmé n'est copié qu'une fois.
    private var lastBackedUp: (data: Data, url: URL)?

    init() {
        customURL = nil
        watchesFile = true
    }

    init(fileURL: URL) {
        customURL = fileURL
        watchesFile = false
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private var fileURL: URL { customURL ?? Self.fileURL }

    /// Écrit les réglages (le watcher déclenchera onChange → application à chaud).
    func save(_ settings: Settings) {
        let before = current
        current = sanitized(settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 2026-10-09 (I-08) : une écriture ratée était silencieuse (`try?`) — le monteur
        // croyait son raccourci enregistré, il disparaissait au relancement.
        do {
            try encoder.encode(current).write(to: fileURL, options: .atomic)
        } catch {
            log.error("settings.json non enregistré : \(error.localizedDescription)")
            onIssue?(.saveFailed)
        }
        // Appliquer TOUT DE SUITE. Avant (audit du 2026-10-07), on comptait sur le
        // watcher du fichier : mais `current` étant déjà à jour, il ne voyait aucune
        // différence et n'appelait jamais onChange → un nouveau raccourci preset ou
        // un changement de ⌘J ne marchait qu'après un redémarrage de Khanjar.
        if current != before { onChange?(current) }
    }

    func load() {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            // Fichier modèle au premier lancement (documentation vivante)
            if let data = try? JSONEncoder().encode(Settings.default) {
                try? data.write(to: url)
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            log.error("settings.json illisible (lecture impossible) — derniers réglages valides conservés")
            if watchesFile { watch() }
            return
        }
        let report = SettingsDecodingReport()
        let decoder = JSONDecoder()
        decoder.userInfo[.settingsReport] = report
        if let parsed = try? decoder.decode(Settings.self, from: data) {
            current = sanitized(parsed)
            if !report.invalidKeys.isEmpty {
                // Valeurs illisibles remplacées par les défauts : le prochain enregistrement
                // les effacerait du fichier — on en garde une copie.
                let backup = keepCopy(of: data)
                log.error("settings.json : valeur(s) illisible(s) pour \(report.invalidKeys) — défaut utilisé, le reste est gardé\(backup.map { " (copie : \($0.lastPathComponent))" } ?? "")")
                // C-10 (2026-10-09) : signalé aussi au monteur (S26). Avant, seul un JSON
                // entièrement illisible l'était : un raccourci preset abîmé disparaissait
                // en silence, un mauvais maxResults revenait à 8 sans explication.
                onIssue?(.valuesReset(keys: report.invalidKeys, backup: backup))
            }
        } else {
            // 2026-10-09 (I-08) : JSON abîmé (tronqué, édité à la main…). On GARDE le dernier
            // état valide (au démarrage : les défauts) et on met le fichier de côté AVANT toute
            // écriture : avant, le prochain enregistrement l'écrasait sans copie.
            let backup = keepCopy(of: data)
            log.error("settings.json illisible — derniers réglages valides conservés\(backup.map { ", copie : \($0.lastPathComponent)" } ?? "")")
            onIssue?(.unreadable(backup: backup))
        }
        if watchesFile { watch() }
    }

    /// Copie « settings.json.illisible-aaaammjj-hhmmss » à côté du fichier ; nil si échec.
    /// Un contenu déjà copié (rechargement par la surveillance du fichier) ne l'est pas deux fois.
    private func keepCopy(of data: Data) -> URL? {
        if let last = lastBackedUp, last.data == data { return last.url }
        var backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.illisible-\(UsageStore.backupStamp(Date()))")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = backup.deletingLastPathComponent()
                .appendingPathComponent("settings.json.illisible-\(UsageStore.backupStamp(Date()))-\(n)")
            n += 1
        }
        do {
            try data.write(to: backup, options: .atomic)
            lastBackedUp = (data, backup)
            return backup
        } catch {
            log.error("Copie de settings.json impossible : \(error.localizedDescription)")
            return nil
        }
    }

    private func sanitized(_ s: Settings) -> Settings {
        var out = s
        out.maxResults = min(max(s.maxResults, 1), 20)
        if !["system", "dark", "light"].contains(s.theme) { out.theme = "system" }
        return out
    }

    private func watch() {
        watcher?.cancel()
        let fd = open(fileURL.path, O_EVTONLY)
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
    //
    // 2026-10-09 (audit A3#4, A4#4, B1 Maj.2, B2#3 ; contrat U-02) : un jeton de
    // raccourci désigne désormais la POSITION PHYSIQUE de la touche (nommée comme sur un
    // clavier US-ANSI), plus le caractère tapé. Avant, l'enregistreur stockait le
    // caractère produit (« a » sur la touche A d'un AZERTY) et la table US l'inscrivait
    // sur une autre touche (0x00 = Q en AZERTY ; Z↔W, M → « , » ; Y↔Z en QWERTZ) ; un
    // ⌘⇧A affiché pouvait détourner ⌘⇧Q dans Premiere. Le format de settings.json ne
    // change pas : un raccourci enregistré avant reste sur la même touche physique et
    // s'affiche maintenant honnêtement (« ⌃⌥Q » en AZERTY) — à réenregistrer.

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

    /// "cmd+shift+p" → "⌘⇧P" (affichage), modificateurs dans l'ordre canonique de macOS
    /// (⌃⌥⇧⌘, quel que soit l'ordre dans la chaîne — avant, « alt+ctrl+a » donnait « ⌥⌃A »).
    /// 2026-10-09 (I-04) : la touche est affichée selon la disposition du clavier (la
    /// disposition ASCII courante : AZERTY, QWERTZ… ; pour un clavier non latin, celle que
    /// macOS utilise pour les raccourcis) ; rangée des chiffres toujours en chiffres, F1…F12.
    static func pretty(_ shortcut: String) -> String {
        pretty(shortcut, layout: currentKeyboardLayout())
    }

    /// Même affichage pour une disposition donnée (nil = noms de jetons, sans traduction).
    static func pretty(_ shortcut: String, layout: TISInputSource?) -> String {
        var mods = Set<String>(), key = ""
        for part in shortcut.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control", "⌃": mods.insert("⌃")
            case "alt", "option", "opt", "⌥": mods.insert("⌥")
            case "shift", "⇧": mods.insert("⇧")
            case "cmd", "command", "⌘": mods.insert("⌘")
            default: key = displayKey(part, layout: layout)
            }
        }
        return ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains).joined() + key
    }

    /// Nom de POSITION physique (US-ANSI) d'un keyCode ; nil = touche non prise en charge.
    /// Pour l'enregistreur (U-02) : `token(forKeyCode: event.keyCode)` au lieu du caractère.
    static func token(forKeyCode keyCode: UInt16) -> String? {
        canonicalTokens[UInt32(keyCode)]
    }

    /// Décision Q8 d'Isma (2026-10-09) : raccourcis presets refusés — ils avaleraient
    /// « Tout sélectionner », « Copier », « Annuler »… dans Premiere. Réservé si la
    /// position (jeton US) OU le caractère de la disposition active est a/c/v/x/z/s/q/w
    /// avec ⌘ seul, ou z avec ⌘⇧ : sur un AZERTY ou un QWERTZ, c'est le caractère qui
    /// déclenche le menu de Premiere ; la position est gardée aussi, par prudence.
    static func isReservedShortcut(_ shortcut: String) -> Bool {
        isReservedShortcut(shortcut, layout: currentKeyboardLayout())
    }

    static func isReservedShortcut(_ shortcut: String, layout: TISInputSource?) -> Bool {
        guard let parsed = parseShortcut(shortcut) else { return false }
        let names = [token(forKeyCode: UInt16(parsed.keyCode)),
                     keyLabel(keyCode: UInt16(parsed.keyCode), layout: layout)?.lowercased()].compactMap { $0 }
        switch parsed.modifiers {
        case UInt32(cmdKey): return names.contains { ["a", "c", "v", "x", "z", "s", "q", "w"].contains($0) }
        case UInt32(cmdKey | shiftKey): return names.contains("z")
        default: return false
        }
    }

    /// Disposition installée par son identifiant (« com.apple.keylayout.ABC-AZERTY »),
    /// SANS changer la disposition active — pour les tests de `pretty(_:layout:)`.
    static func installedKeyboardLayout(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    /// Disposition utilisée pour afficher les raccourcis : la disposition ASCII courante
    /// (celle des raccourcis ⌘ de macOS). Fil principal seulement (Text Input Sources).
    private static func currentKeyboardLayout() -> TISInputSource? {
        guard Thread.isMainThread else { return nil }
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    private static func displayKey(_ token: String, layout: TISInputSource?) -> String {
        // Rangée des chiffres : toujours en chiffres (« & » en AZERTY sans Maj).
        if token.count == 1, token.first?.isNumber == true { return token }
        if let n = Int(token.dropFirst()), token.hasPrefix("f"), (1...12).contains(n) { return "F\(n)" }
        if ["space", "espace", "return", "entrée", "iso-alt"].contains(token) { return token.uppercased() }
        if let code = keyCodes[token], let label = keyLabel(keyCode: UInt16(code), layout: layout) {
            return label.uppercased()
        }
        return token == "<" || token == ">" ? token : token.uppercased()
    }

    /// Caractère produit par une touche physique sur une disposition, sans modificateur.
    private static func keyLabel(keyCode: UInt16, layout: TISInputSource?) -> String? {
        guard let layout, let ptr = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let label = String(utf16CodeUnits: chars, count: length)
            let printable = label.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            return printable ? label : nil
        }
    }

    /// Touches prises en charge, nommées par leur POSITION sur un clavier US-ANSI.
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
        // 2026-10-09 (I-04) : ponctuation ANSI/ISO et touches de fonction — sans elles,
        // une touche comme « ; » ou F5 était refusée par l'enregistreur.
        "=": 0x18, "-": 0x1B, "[": 0x21, "]": 0x1E, "'": 0x27, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, ".": 0x2F, "/": 0x2C,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// Table inverse (keyCode → jeton). Doublons tranchés pour rester compatible :
    /// 0x32 → « < », 0x0A → « § », 0x31 → « space », 0x24 → « return ».
    private static let canonicalTokens: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        let preferred: Set<String> = ["<", "§", "space", "return"]
        for (name, code) in keyCodes where table[code] == nil || preferred.contains(name) {
            table[code] = name
        }
        return table
    }()
}
