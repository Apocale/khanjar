import AppKit

/// Bouton « enregistreur de raccourci » : au clic, capture la PROCHAINE frappe
/// (via un moniteur local `.keyDown`) et la convertit en chaîne "cmd+shift+p".
/// Consomme l'événement pour qu'il ne fuite pas dans la fenêtre.
///
/// 2026-10-09 (audit A4#4, A4#6, B2#3, décision Q8 d'Isma) :
///  - la touche est retenue par sa POSITION (keyCode → `SettingsStore.token`), plus par
///    le caractère : en AZERTY, ⌃⌥A s'inscrivait sur la touche Q (A↔Q, Z↔W, M), en
///    QWERTZ Y↔Z, et tout clavier non latin était refusé ;
///  - ⌘ ou ⌃ obligatoire : ⇧T ou ⌥N seuls avalaient ensuite la frappe dans Premiere
///    (plus moyen de taper un T majuscule) ;
///  - les raccourcis de Premiere (⌘A ⌘C ⌘V ⌘X ⌘Z ⌘⇧Z ⌘S ⌘Q ⌘W) sont refusés ;
///  - le refus s'explique SOUS le bouton (`messageLabel`, 2 lignes) : dans le bouton de
///    180 pt, « Combinaison invalide — pr… » était coupé, et faux pour un clavier non latin ;
///  - un enregistrement abandonné (fenêtre fermée ou quittée, réglages rechargés, autre
///    enregistreur cliqué) s'arrête : il avalait la 1ʳᵉ frappe de la palette.
final class ShortcutRecorder: NSButton {
    private(set) var shortcut: String?      // "cmd+shift+p" si valide, sinon nil
    private var monitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    /// Un seul enregistreur armé à la fois : cliquer le second arrête le premier.
    private static weak var armed: ShortcutRecorder?
    var onChange: (() -> Void)?
    var isRecording: Bool { monitor != nil }

    /// Raison d'un refus, à placer SOUS le bouton par la vue qui l'accueille (caché sinon).
    let messageLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 2
        label.isHidden = true
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = L("Click, then press a key")
        target = self
        action = #selector(startRecording)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Verdict sur une frappe, sans état : testable sans clavier.
    enum Verdict: Equatable { case cancel, accepted(String), refused(String) }

    static func verdict(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Verdict {
        if keyCode == 53 { return .cancel }   // Échap : on garde la valeur précédente
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else {
            return .refused(L("Use ⌘ or ⌃ with a key"))
        }
        guard let key = SettingsStore.token(forKeyCode: keyCode) else {
            return .refused(L("Key not supported — try another"))
        }
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.option)  { parts.append("alt") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.shift)   { parts.append("shift") }
        parts.append(key)
        let combo = parts.joined(separator: "+")
        guard SettingsStore.parseShortcut(combo) != nil else {
            return .refused(L("Key not supported — try another"))
        }
        if SettingsStore.isReservedShortcut(combo) {
            return .refused(L("Premiere already uses this shortcut — choose another"))
        }
        return .accepted(combo)
    }

    @objc private func startRecording() {
        if let other = Self.armed, other !== self { other.cancelRecording() }
        stopRecording()
        Self.armed = self
        title = L("Press your combination…")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        if let window {
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: nil) { [weak self] _ in self?.cancelRecording() })
            }
        }
    }

    /// Frappe vue par le moniteur. Rend nil si elle est consommée ; une frappe destinée
    /// à une AUTRE fenêtre (la palette…) est rendue intacte.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording, event.window === window else { return event }
        stopRecording()
        let verdict = Self.verdict(keyCode: event.keyCode, modifiers: event.modifierFlags)
        switch verdict {
        case .cancel: showMessage(nil)
        case .refused(let reason): showMessage(reason)   // la valeur précédente reste en place
        case .accepted(let combo): shortcut = combo; showMessage(nil)
        }
        title = displayTitle()
        if case .accepted = verdict { onChange?() }
        return nil
    }

    /// Abandon sans rien changer (fenêtre fermée ou quittée, réglages rechargés).
    func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
        title = displayTitle()
    }

    private func displayTitle() -> String {
        if let s = shortcut { return SettingsStore.pretty(s) }
        return L("Click, then press a key")
    }

    private func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }

    func set(_ combo: String?) {
        stopRecording()
        shortcut = combo
        showMessage(nil)
        title = displayTitle()
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        if Self.armed === self { Self.armed = nil }
    }
    deinit { stopRecording() }
}

/// Feuille modale « Nouveau raccourci » : recherche floue d'un preset/effet
/// (via le provider de l'app) + enregistreur de touche. Rappelle `completion`
/// avec le `PresetShortcut` choisi, ou nil si annulé. La validation des
/// conflits est faite par l'appelant (qui connaît les autres raccourcis).
final class PresetShortcutSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let searchProvider: (String) -> [SearchItem]
    private let completion: (PresetShortcut?) -> Void
    private var results: [SearchItem] = []
    private let table = NSTableView()
    private let recorder = ShortcutRecorder(frame: .zero)
    private let addButton = NSButton(title: L("Add"), target: nil, action: nil)
    private var sheet: NSWindow?
    private weak var parent: NSWindow?

    init(searchProvider: @escaping (String) -> [SearchItem], completion: @escaping (PresetShortcut?) -> Void) {
        self.searchProvider = searchProvider
        self.completion = completion
        super.init()
    }

    func present(over parentWindow: NSWindow) {
        parent = parentWindow
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView()
        win.contentView = content

        let heading = NSTextField(labelWithString: L("Assign a shortcut to a preset"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let search = NSSearchField()
        search.placeholderString = L("Search for a preset or effect…")
        search.delegate = self

        table.headerView = nil
        table.rowHeight = 34
        let col = NSTableColumn(identifier: .init("preset"))
        col.width = 340
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let recLabel = NSTextField(labelWithString: L("Shortcut:"))
        recLabel.font = .systemFont(ofSize: 12)
        recorder.onChange = { [weak self] in self?.refreshAddState() }
        let recRow = NSStackView(views: [recLabel, recorder])
        recRow.spacing = 8
        recorder.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(confirm)
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancel, addButton])
        buttons.spacing = 8

        // Raison d'un refus de l'enregistreur, sous la ligne du raccourci (2 lignes max).
        recorder.messageLabel.preferredMaxLayoutWidth = 348
        let stack = NSStackView(views: [heading, search, scroll, recRow, recorder.messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        sheet = win
        parentWindow.beginSheet(win, completionHandler: nil)
    }

    // MARK: Recherche
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        results = q.isEmpty ? [] : searchProvider(q)
        table.reloadData()
        refreshAddState()
    }

    // MARK: Table
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13)
        let sub = NSTextField(labelWithString: item.kind == "effect" ? L("Effect") : item.subtitle)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let v = NSStackView(views: [title, sub])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 1
        return v
    }

    @objc private func rowClicked() { refreshAddState() }

    private var selectedItem: SearchItem? {
        let r = table.selectedRow
        return (r >= 0 && r < results.count) ? results[r] : nil
    }

    private func refreshAddState() {
        addButton.isEnabled = selectedItem != nil && recorder.shortcut != nil
    }

    // MARK: Actions
    @objc private func confirm() {
        guard let item = selectedItem, let combo = recorder.shortcut else { return }
        finish(PresetShortcut(itemId: item.id, title: item.title, shortcut: combo))
    }
    @objc private func cancel() { finish(nil) }

    private func finish(_ result: PresetShortcut?) {
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet = nil
        completion(result)
    }
}
