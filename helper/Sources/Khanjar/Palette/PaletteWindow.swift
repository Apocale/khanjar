import AppKit
import QuartzCore

/// Panneau non-activant : prend le focus clavier SANS activer l'app
/// (Premiere reste l'app active — comportement Spotlight).
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    /// ⌘1…⌘9, ⌘0 → applique la n-ième ligne. Retourne true si consommé.
    /// Le modificateur ⌘ est OBLIGATOIRE : un chiffre nu doit rester saisissable
    /// (des presets s'appellent « 01 Big », « 10 Small », « TR - Fast Zoom In 180-100 »).
    var onDigit: ((Int) -> Bool)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        onCancel?() // clic ailleurs = fermeture, comme Spotlight
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let digit = Int(chars), onDigit?(digit) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Fenêtre palette : champ de recherche + liste de résultats.
/// Aucune logique métier : délègue la recherche (onQuery) et la validation
/// (onCommit) au coordinateur.
final class PaletteWindowController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var onQuery: ((String) -> [(item: SearchItem, score: Double)])?
    var onCommit: ((SearchItem) -> Void)?
    /// Classement « fréquence + récence » affiché quand le champ est vide
    /// (UsageStore). Le nombre d'applications accompagne chaque ligne.
    var onFrequent: ((Int) -> [(item: SearchItem, count: Int)])?

    var maxResults = 8
    /// Plafond de la liste des fréquents : au-delà, on ne lit plus, on cherche.
    private let maxFrequent = 10

    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L("No results"))
    private let frequentLabel = NSTextField(labelWithString: L("Frequently used"))
    /// Une ligne affichée. `count` n'est renseigné que pour les fréquents :
    /// il déclenche l'affichage du rang ⌘n et du nombre d'applications.
    private struct Row { let item: SearchItem; let count: Int? }
    private var results: [Row] = []
    /// Vrai quand la liste affichée est le classement (champ vide).
    private var showingFrequent = false

    private let width: CGFloat = 580
    private let fieldHeight: CGFloat = 48
    private let rowHeight: CGFloat = 40

    var isVisible: Bool { panel.isVisible }

    /// "system" | "dark" | "light"
    func setTheme(_ theme: String) {
        switch theme {
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        case "light": panel.appearance = NSAppearance(named: .aqua)
        default: panel.appearance = nil // suit le système
        }
    }

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.hide() }

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        // Champ de recherche
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = L("Effect or preset…")
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        background.addSubview(field)

        // Liste de résultats
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        let column = NSTableColumn(identifier: .init("main"))
        column.width = width - 24
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        background.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        background.addSubview(emptyLabel)

        frequentLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        frequentLabel.textColor = .tertiaryLabelColor
        frequentLabel.isHidden = true
        background.addSubview(frequentLabel)

        panel.onDigit = { [weak self] digit in self?.commit(digit: digit) ?? false }

        layout(rows: 0, noResult: false)
    }

    /// ⌘1…⌘9 → lignes 1 à 9, ⌘0 → 10ᵉ ligne (rang affiché à gauche).
    private func commit(digit: Int) -> Bool {
        let index = digit == 0 ? 9 : digit - 1
        guard index >= 0, index < results.count else { return false }
        table.selectRowIndexes([index], byExtendingSelection: false)
        commitSelection()
        return true
    }

    // MARK: - Affichage (pop subtil façon Apple : spring discret + fondu)

    private var isClosing = false

    private func centerAnchor(_ layer: CALayer) {
        let bounds = layer.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func show() {
        isClosing = false
        field.stringValue = ""
        // Champ vide = classement fréquence + récence, prêt à l'emploi : la
        // palette ne s'ouvre plus sur une liste vide qui attend une frappe.
        refresh()

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - width / 2,
                                               y: frame.minY + frame.height * 0.72))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)

        if let layer = panel.contentView?.layer {
            centerAnchor(layer)
            layer.removeAllAnimations()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.97
            spring.toValue = 1.0
            spring.damping = 24
            spring.stiffness = 420
            spring.mass = 1
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "pop-in")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        Logger.shared.debug("Palette affichée (key=\(panel.isKeyWindow), focusChamp=\(panel.firstResponder === field.currentEditor()))")
    }

    /// Fermeture immédiate (Échap, clic ailleurs) — instantanée pour rester vive.
    func hide() {
        guard !isClosing else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.contentView?.layer?.removeAllAnimations()
    }

    /// Fermeture avec micro-pop (validation Entrée) : léger zoom + fondu.
    private func dismissWithPop() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        if let layer = panel.contentView?.layer {
            centerAnchor(layer)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.025
            scale.duration = 0.13
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "pop-out")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.contentView?.layer?.removeAllAnimations()
            self.isClosing = false
        })
    }

    /// Documentation : la palette telle qu'elle s'afficherait pour `query`
    /// (champ vide = fréquents), rendue hors écran. Voir Snapshot / render-media.
    func snapshotPNG(query: String, dark: Bool) -> Data? {
        field.stringValue = query
        refresh()
        // Hors écran la fenêtre n'est pas « active » : la sélection se dessinerait
        // éteinte. On la montre comme dans l'app, où la palette a le focus.
        if !results.isEmpty { table.rowView(atRow: 0, makeIfNecessary: true)?.isEmphasized = true }
        guard let view = panel.contentView else { return nil }
        let tint = dark ? NSColor(calibratedWhite: 0.16, alpha: 0.97) : NSColor(calibratedWhite: 0.985, alpha: 0.97)
        return Snapshot.png(of: view, dark: dark, backdrop: tint)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func layout(rows: Int, noResult: Bool) {
        let listHeight = noResult ? 32 : CGFloat(rows) * rowHeight
        let headerVisible = showingFrequent && rows > 0
        let headerHeight: CGFloat = headerVisible ? 18 : 0
        let total = fieldHeight + (listHeight > 0 ? listHeight + headerHeight + 8 : 0)
        let top = panel.frame.origin.y + panel.frame.height
        panel.setContentSize(NSSize(width: width, height: total))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.origin.x, y: top))

        field.frame = NSRect(x: 16, y: total - fieldHeight + 12, width: width - 32, height: 26)
        scroll.frame = NSRect(x: 8, y: 4, width: width - 16, height: max(0, listHeight))
        scroll.isHidden = noResult || rows == 0
        frequentLabel.frame = NSRect(x: 20, y: listHeight + 5, width: width - 40, height: 13)
        frequentLabel.isHidden = !headerVisible
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: 20, y: 8)
        emptyLabel.isHidden = !noResult
    }

    // MARK: - Recherche

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        showingFrequent = query.isEmpty
        if showingFrequent {
            let limit = min(maxResults, maxFrequent)
            results = (onFrequent?(limit) ?? []).map { Row(item: $0.item, count: $0.count) }
        } else {
            results = (onQuery?(query) ?? []).prefix(maxResults).map { Row(item: $0.item, count: nil) }
        }
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false) // meilleur résultat pré-sélectionné
        }
        // « Aucun résultat » ne concerne qu'une recherche : un classement vide
        // (premier lancement, aucune application encore faite) se montre nu.
        layout(rows: results.count, noResult: !query.isEmpty && results.isEmpty)
    }

    // MARK: - Clavier (flèches, Entrée, Échap depuis le champ)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowDoubleClicked() {
        commitSelection()
    }

    private func commitSelection() {
        guard table.selectedRow >= 0, table.selectedRow < results.count else { return }
        let item = results[table.selectedRow].item
        onCommit?(item)  // application déclenchée AVANT l'animation : zéro latence ajoutée
        dismissWithPop()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]
        let cell = NSTableCellView()

        // Fréquents : rang ⌘n à gauche (découvrabilité du raccourci) et nombre
        // d'applications à droite. Le texte se décale pour leur laisser la place.
        // Réserve à droite : le badge « partiel » occupe déjà width-92…width-12
        // sur la ligne du titre ; le compteur se place sous lui, jamais dessus.
        let left: CGFloat = entry.count != nil ? 42 : 12
        let textWidth = entry.count != nil ? width - left - 104 : width - 48

        if entry.count != nil, row < 10 {
            let rank = NSTextField(labelWithString: "⌘\(row == 9 ? 0 : row + 1)")
            rank.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            rank.textColor = .tertiaryLabelColor
            rank.frame = NSRect(x: 12, y: 13, width: 26, height: 14)
            cell.addSubview(rank)
        }

        let title = NSTextField(labelWithString: entry.item.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: left, y: 20, width: textWidth, height: 18)

        let subtitle = NSTextField(labelWithString: entry.item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: left, y: 4, width: textWidth, height: 14)

        cell.addSubview(title)
        cell.addSubview(subtitle)

        if let count = entry.count {
            let uses = NSTextField(labelWithString: "\(count) ×")
            uses.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            uses.textColor = .tertiaryLabelColor
            uses.alignment = .right
            uses.frame = NSRect(x: width - 92, y: 4, width: 80, height: 14)
            cell.addSubview(uses)
        }

        // Badge « partiel » : sans lui, un preset dont une partie n'a pas pu être
        // rejouée (paramètres non supportés, effet absent de cette installation)
        // s'applique en silence — l'utilisateur croit à un bug de son montage.
        if let note = Self.partialNote(entry.item.fidelityHint) {
            let badge = NSTextField(labelWithString: note)
            badge.font = .systemFont(ofSize: 9, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.alignment = .right
            badge.toolTip = L("This preset can't be fully replayed: some settings aren't accessible to Premiere extensions.")
            badge.frame = NSRect(x: width - 92, y: 20, width: 80, height: 16)
            cell.addSubview(badge)
        }
        return cell
    }

    /// "params:12/20,dropped:2" → "partiel" ; nil si tout est rejouable.
    static func partialNote(_ hint: String) -> String? {
        guard !hint.isEmpty, hint != "full" else { return nil }
        var incomplete = hint.contains("dropped:")
        if let r = hint.range(of: "params:") {
            let frag = hint[r.upperBound...].prefix { $0 != "," }
            let parts = frag.split(separator: "/")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a < b { incomplete = true }
        }
        return incomplete ? L("partial") : nil
    }
}
