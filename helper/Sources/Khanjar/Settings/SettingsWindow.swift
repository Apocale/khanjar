import AppKit

/// Fenêtre de réglages : identité du produit + paramètres modifiables.
/// Écrit settings.json via SettingsStore (application à chaud par le watcher).
final class SettingsWindowController: NSObject {

    static let creator = "Isma"

    /// Thèmes proposés : l'id va dans settings.json, le titre est traduit.
    /// Sélection par POSITION, jamais par titre (un titre traduit ne se compare pas).
    static let themes: [(id: String, title: String)] = [
        ("system", L("System")), ("dark", L("Dark")), ("light", L("Light")),
    ]

    private let store: SettingsStore
    private var window: NSWindow?
    // Enregistreurs de touche (clic → presse la combinaison) — cohérents avec
    // les raccourcis presets ; plus de saisie texte « cmd+j » à connaître.
    private let shortcutRecorder = ShortcutRecorder(frame: .zero)
    private let adjustmentRecorder = ShortcutRecorder(frame: .zero)
    private let adaptCheckbox = NSButton(checkboxWithTitle:
        L("Adapt presets to the clip's framing"), target: nil, action: nil)
    private let crashCheckbox = NSButton(checkboxWithTitle:
        L("Send anonymous crash reports"), target: nil, action: nil)
    private let resultsPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    // Raccourcis presets
    private let shortcutsStack = NSStackView()
    private var draftShortcuts: [PresetShortcut] = []
    private var sheetController: PresetShortcutSheet?

    var statusProvider: (() -> String)?
    /// Recherche floue d'items (presets + effets), fournie par l'app (index).
    var searchProvider: ((String) -> [SearchItem])?

    init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func open() {
        if window == nil { window = buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        let s = store.current
        shortcutRecorder.set(s.shortcut)
        adjustmentRecorder.set(s.adjustmentShortcut)
        adaptCheckbox.state = s.adaptToClip ? .on : .off
        crashCheckbox.state = s.sendsCrashReports ? .on : .off
        resultsPopup.selectItem(withTitle: String(s.maxResults))
        themePopup.selectItem(at: Self.themes.firstIndex { $0.id == s.theme } ?? 0)
        statusLabel.stringValue = statusProvider?() ?? ""
        draftShortcuts = s.shortcuts
        renderShortcuts()
    }

    /// Redessine la liste des raccourcis presets depuis `draftShortcuts`.
    private func renderShortcuts() {
        shortcutsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if draftShortcuts.isEmpty {
            let empty = NSTextField(labelWithString: L("No shortcuts yet. Use “Add a shortcut…” below."))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            shortcutsStack.addArrangedSubview(empty)
            return
        }
        for (i, ps) in draftShortcuts.enumerated() {
            let combo = NSTextField(labelWithString: SettingsStore.pretty(ps.shortcut))
            combo.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            combo.setContentHuggingPriority(.required, for: .horizontal)
            combo.widthAnchor.constraint(equalToConstant: 62).isActive = true
            let name = NSTextField(labelWithString: ps.title)
            name.font = .systemFont(ofSize: 12)
            name.lineBreakMode = .byTruncatingTail
            let remove = NSButton(title: "", target: self, action: #selector(removeShortcut(_:)))
            remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove"))
            remove.isBordered = false
            remove.tag = i
            let row = NSStackView(views: [combo, name, remove])
            row.spacing = 8
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 372).isActive = true
            shortcutsStack.addArrangedSubview(row)
        }
    }

    private func buildWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = L("Khanjar Settings")
        win.isReleasedWhenClosed = false

        let content = NSView()
        win.contentView = content

        // — En-tête identité —
        let icon = NSImageView(image: NSImage(systemSymbolName: "wand.and.stars",
                                              accessibilityDescription: "Khanjar") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        let title = NSTextField(labelWithString: "Khanjar")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString:
            LF("Version %@ — made by %@\nEffects and presets palette for Premiere Pro", Self.appVersion, Self.creator))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        // — Formulaire —
        for n in 1...20 { resultsPopup.addItem(withTitle: String(n)) }
        for theme in Self.themes { themePopup.addItem(withTitle: theme.title) }

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label(L("Palette shortcut:")), shortcutRecorder],
            [label(L("Adjustment layer shortcut:")), adjustmentRecorder],
            [label(L("Number of results:")), resultsPopup],
            [label(L("Theme:")), themePopup],
            [NSGridCell.emptyContentView, adaptCheckbox],
        ])
        // Proposée seulement si ce build sait où envoyer (sinon promesse vide).
        if CrashReporter.isAvailable { grid.addRow(with: [NSGridCell.emptyContentView, crashCheckbox]) }
        crashCheckbox.toolTip = L("Only if Khanjar crashes: the versions and where in the code. Never your clips, presets or files.")
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 180

        let saveButton = NSButton(title: L("Save"), target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        adaptCheckbox.toolTip = L("A zoom preset “100 → 120” applied to a clip already framed at 50% scales it from 50 to 60 instead of jumping to 100. Same for position and rotation.")
        let hint = NSTextField(labelWithString: L("Click a shortcut, then press the key combination you want."))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        // — Section « Raccourcis presets » —
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let scHeader = NSTextField(labelWithString: L("Preset shortcuts"))
        scHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        let scHint = NSTextField(labelWithString: L("One key → applies a preset to the selected clip (only in Premiere)."))
        scHint.font = .systemFont(ofSize: 10)
        scHint.textColor = .tertiaryLabelColor
        shortcutsStack.orientation = .vertical
        shortcutsStack.alignment = .leading
        shortcutsStack.spacing = 6
        let scScroll = NSScrollView()
        scScroll.documentView = shortcutsStack
        scScroll.hasVerticalScroller = true
        scScroll.borderType = .bezelBorder
        scScroll.drawsBackground = false
        scScroll.translatesAutoresizingMaskIntoConstraints = false
        scScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        scScroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        shortcutsStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutsStack.widthAnchor.constraint(equalTo: scScroll.widthAnchor, constant: -4).isActive = true
        // Ancrer la liste en HAUT de la zone défilante (sinon la NSClipView non
        // inversée colle le contenu en bas quand il ne remplit pas la hauteur).
        shortcutsStack.topAnchor.constraint(equalTo: scScroll.contentView.topAnchor, constant: 4).isActive = true
        let addButton = NSButton(title: L("Add a shortcut…"), target: self, action: #selector(addShortcut))
        addButton.bezelStyle = .rounded

        // — Layout vertical —
        let header = NSStackView(views: [icon, title])
        header.spacing = 10
        let stack = NSStackView(views: [header, subtitle, statusLabel, grid, hint,
                                        sep, scHeader, scHint, scScroll, addButton, saveButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        return win
    }

    // MARK: - Raccourcis presets

    @objc private func addShortcut() {
        guard let window, let provider = searchProvider else { return }
        let sheet = PresetShortcutSheet(searchProvider: provider) { [weak self] result in
            guard let self else { return }
            self.sheetController = nil
            guard let ps = result else { return }
            if let conflict = self.conflict(for: ps.shortcut) {
                let alert = NSAlert()
                alert.messageText = L("Shortcut already in use")
                alert.informativeText = LF("%@ is already assigned to %@. Choose another combination.", SettingsStore.pretty(ps.shortcut), conflict)
                alert.beginSheetModal(for: window)
                return
            }
            self.draftShortcuts.append(ps)
            self.renderShortcuts()
            self.persistShortcuts() // application à chaud immédiate (le hotkey s'arme tout de suite)
            HUD.show("\(SettingsStore.pretty(ps.shortcut)) → \(ps.title)")
        }
        self.sheetController = sheet
        sheet.present(over: window)
    }

    @objc private func removeShortcut(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < draftShortcuts.count else { return }
        draftShortcuts.remove(at: sender.tag)
        renderShortcuts()
        persistShortcuts()
    }

    /// Retourne le nom de l'action déjà liée à cette combinaison, ou nil si libre.
    /// (Garde-fou : palette, calque d'effets, autres raccourcis presets.)
    private func conflict(for shortcut: String) -> String? {
        guard let target = SettingsStore.parseShortcut(shortcut) else { return nil }
        let s = store.current
        func same(_ other: String?) -> Bool {
            guard let other, let p = SettingsStore.parseShortcut(other) else { return false }
            return p == target
        }
        if same(s.shortcut) { return L("the palette (⌘J)") }
        if same(s.adjustmentShortcut) { return L("the adjustment layer") }
        if let dup = draftShortcuts.first(where: { same($0.shortcut) }) { return LF("“%@”", dup.title) }
        return nil
    }

    /// Persiste UNIQUEMENT la liste des raccourcis (préserve les autres réglages
    /// déjà enregistrés), déclenchant le ré-enregistrement à chaud.
    private func persistShortcuts() {
        var s = store.current
        s.presetShortcuts = draftShortcuts.isEmpty ? nil : draftShortcuts
        s.relativeToClip = (adaptCheckbox.state == .on)
        store.save(s)
    }

    @objc private func save() {
        // Les enregistreurs ne produisent que des combinaisons valides ; repli
        // sur la valeur courante si l'utilisateur n'a rien changé.
        let shortcut = shortcutRecorder.shortcut ?? store.current.shortcut
        let adjustment = adjustmentRecorder.shortcut ?? store.current.adjustmentShortcut
        // Garde-fou : palette et calque ne peuvent pas partager la même touche.
        if let p = SettingsStore.parseShortcut(shortcut),
           let a = SettingsStore.parseShortcut(adjustment), p == a {
            let alert = NSAlert()
            alert.messageText = L("Two identical shortcuts")
            alert.informativeText = LF("The palette and the adjustment layer both use %@. Choose two different combinations.", SettingsStore.pretty(shortcut))
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        var s = store.current
        s.shortcut = shortcut
        s.shortcutAdjustmentLayer = adjustment
        s.maxResults = Int(resultsPopup.titleOfSelectedItem ?? "8") ?? 8
        s.theme = Self.themes.indices.contains(themePopup.indexOfSelectedItem) ? Self.themes[themePopup.indexOfSelectedItem].id : "system"
        s.presetShortcuts = draftShortcuts.isEmpty ? nil : draftShortcuts
        if CrashReporter.isAvailable { s.crashReports = (crashCheckbox.state == .on) }
        store.save(s)
        window?.close()
        HUD.show(L("Settings saved"))
    }
}
