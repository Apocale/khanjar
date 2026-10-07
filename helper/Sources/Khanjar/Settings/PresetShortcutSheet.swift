import AppKit

/// Bouton « enregistreur de raccourci » : au clic, capture la PROCHAINE frappe
/// (via un moniteur local `.keyDown`) et la convertit en chaîne "cmd+shift+p".
/// Consomme l'événement pour qu'il ne fuite pas dans la fenêtre.
final class ShortcutRecorder: NSButton {
    private(set) var shortcut: String?      // "cmd+shift+p" si valide, sinon nil
    private var monitor: Any?
    var onChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = L("Click, then press a key")
        target = self
        action = #selector(startRecording)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func startRecording() {
        title = L("Press your combination…")
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil // événement consommé
        }
    }

    private func capture(_ event: NSEvent) {
        stopMonitor()
        // Échap annule l'enregistrement, restaure l'état précédent.
        if event.keyCode == 53 { title = displayTitle(); return }
        var parts: [String] = []
        let f = event.modifierFlags
        if f.contains(.command) { parts.append("cmd") }
        if f.contains(.option)  { parts.append("alt") }
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.shift)   { parts.append("shift") }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        parts.append(key)
        let combo = parts.joined(separator: "+")
        if !key.isEmpty, SettingsStore.parseShortcut(combo) != nil {
            shortcut = combo
        } else {
            shortcut = nil // pas de modificateur, ou touche non supportée
        }
        title = displayTitle()
        onChange?()
    }

    private func displayTitle() -> String {
        if let s = shortcut { return SettingsStore.pretty(s) }
        return L("Invalid combination — press at least one modifier")
    }

    func set(_ combo: String?) { shortcut = combo; title = combo == nil ? L("Click, then press a key") : SettingsStore.pretty(combo!) }
    private func stopMonitor() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
    deinit { stopMonitor() }
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

        let stack = NSStackView(views: [heading, search, scroll, recRow, buttons])
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
