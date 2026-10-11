import AppKit
import QuartzCore

/// Panneau non-activant : prend le focus clavier SANS activer l'app
/// (Premiere reste l'app active — comportement Spotlight).
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    /// ⌘1…⌘9, ⌘0 → applique la n-ième ligne. Retourne true si une ligne a été appliquée.
    /// Le modificateur ⌘ est OBLIGATOIRE : un chiffre nu doit rester saisissable
    /// (des presets s'appellent « 01 Big », « 10 Small », « TR - Fast Zoom In 180-100 »).
    var onDigit: ((Int) -> Bool)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        onCancel?() // clic ailleurs = fermeture, comme Spotlight
    }
    /// Touche PHYSIQUE → chiffre : rangée du haut (1…9, 0) puis pavé numérique.
    static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 0,
    ]

    /// 2026-10-09 (audit A4#2, B2#2) : ⌘1…⌘0 faisaient bip en AZERTY — donc chez
    /// Isma (disposition ABC-AZERTY). Cause : on lisait le CARACTÈRE
    /// (`charactersIgnoringModifiers`), qui vaut « & » pour la touche 1 en AZERTY même
    /// avec ⌘, et on exigeait des modificateurs exactement égaux à ⌘ : Verr. Maj,
    /// ⌘⇧ (le « 1 » d'AZERTY) et le pavé (drapeau numericPad) échouaient aussi.
    /// Correction : décider par la touche physique (keyCode, même place en AZERTY,
    /// QWERTZ, QWERTY…), en ignorant Verr. Maj, pavé, fn et Maj ; ⌘ reste
    /// OBLIGATOIRE (un chiffre nu doit rester saisissable). Un ⌘n sans n-ième ligne
    /// est consommé en silence (avant : bip). ⌘↩ (réflexe d'Alfred ou de Raycast,
    /// bip garanti avant) valide comme Entrée.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 36 || event.keyCode == 76, mods == .command, let onReturn {
            onReturn()
            return true
        }
        if let digit = Self.digitKeyCodes[event.keyCode], mods.subtracting(.shift) == .command, let onDigit {
            _ = onDigit(digit)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    /// Entrée qui n'est PAS passée par le champ de recherche (2026-10-08, chez un
    /// ami d'Isma : « Entrée fait bip et n'applique rien »). Un clic sur une ligne
    /// ou Tab donnait le focus à la liste ; la liste ne sait rien faire d'Entrée,
    /// la touche remontait jusqu'à la fenêtre et macOS jouait son bip d'action
    /// impossible. La fenêtre la rattrape : Retour (36) et Entrée du pavé (76,
    /// aussi fn+Retour sur un portable).
    /// 2026-10-09 (audit A4#12) : Verr. Maj allumé ajoute le drapeau capsLock, la
    /// touche n'était plus reconnue et retombait sur le bip ; il est ignoré aussi.
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if event.keyCode == 36 || event.keyCode == 76, mods.isEmpty, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
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
    private let emptyLabel = NSTextField(labelWithString: "")
    private let frequentLabel = NSTextField(labelWithString: L("Frequently used"))
    /// Une ligne affichée. `count` n'est renseigné que pour les fréquents :
    /// il déclenche l'affichage du rang ⌘n et du nombre d'applications.
    private struct Row { let item: SearchItem; let count: Int? }
    private var results: [Row] = []
    /// Vrai quand la liste affichée est le classement (champ vide).
    private var showingFrequent = false

    // Style « Premiere » (direction B choisie par Isma le 2026-10-07) : dense, une
    // ligne par item, couleurs du thème sombre d'Adobe (voir PaletteStyle).
    private let width: CGFloat = 560
    private let fieldHeight: CGFloat = 44
    private let rowHeight: CGFloat = 28
    private let footerHeight: CGFloat = 24
    private let searchIcon = NSImageView()
    private let fieldSeparator = FillView(color: PaletteStyle.separator)
    private let footerSeparator = FillView(color: PaletteStyle.separator)
    // 2026-10-09 (audit A4#16) : le pied disait « ⌘1–9 » alors que ⌘0 applique la 10ᵉ ligne.
    private let footerLabel = NSTextField(labelWithString: L("↵ apply  ·  ⌘1–⌘0 direct  ·  esc close"))

    var isVisible: Bool { panel.isVisible }

    /// "system" | "dark" | "light"
    func setTheme(_ theme: String) {
        switch theme {
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        case "light": panel.appearance = NSAppearance(named: .aqua)
        default: panel.appearance = nil // suit le système
        }
        // 2026-10-09 (audit A4#16) : le HUD suivait l'apparence du Mac, pas le thème
        // forcé : palette sombre puis HUD clair. Il prend désormais le même thème.
        HUD.appearance = panel.appearance
    }

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        // ⌘A ⌘C ⌘V ⌘X ⌘Z dans le champ (2026-10-09, audit A4#5) : voir EditMenu.
        EditMenu.installIfNeeded()
        // m10 (relecture finale, 2026-10-11) : palette restée ouverte (validation refusée
        // pendant une application, C-02 point 5) → le HUD se place sous elle au lieu de
        // recouvrir le champ de recherche.
        HUD.paletteFrame = { [weak self] in
            guard let self, self.panel.isVisible else { return nil }
            return self.panel.frame
        }

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.hide() }

        // Fond UNI, comme sur les images du site (2026-10-07, demande d'Isma) : le
        // verre translucide (.menu) laissait voir Premiere en flou derrière, plus
        // difficile à lire et différent de ce que montre la page GitHub.
        let background = PaletteBackgroundView()
        panel.contentView = background

        // Champ de recherche, précédé d'une loupe ; son texte s'aligne sur les titres.
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        searchIcon.contentTintColor = PaletteStyle.secondaryText
        background.addSubview(searchIcon)
        background.addSubview(fieldSeparator)
        background.addSubview(footerSeparator)
        footerLabel.font = .systemFont(ofSize: 10.5)
        footerLabel.textColor = PaletteStyle.tertiaryText
        background.addSubview(footerLabel)
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.textColor = PaletteStyle.primaryText
        field.placeholderString = L("Effect or preset…")
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        // VoiceOver (2026-10-09, audit A4#13) : le champ n'avait pas de nom.
        field.setAccessibilityLabel(L("Search effects and presets"))
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
        table.intercellSpacing = .zero
        // Le focus reste TOUJOURS dans le champ : un clic sur une ligne la
        // sélectionne sans voler le clavier (sinon Entrée faisait bip, voir
        // PalettePanel.keyDown) et la frappe continue de chercher.
        table.refusesFirstResponder = true
        let column = NSTableColumn(identifier: .init("main"))
        column.width = width - 16
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        background.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 12.5)
        emptyLabel.textColor = PaletteStyle.secondaryText
        emptyLabel.isHidden = true
        background.addSubview(emptyLabel)

        frequentLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        frequentLabel.textColor = PaletteStyle.secondaryText
        frequentLabel.isHidden = true
        background.addSubview(frequentLabel)

        panel.onDigit = { [weak self] digit in self?.commit(digit: digit) ?? false }
        panel.onReturn = { [weak self] in self?.commitSelection() }

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

    /// Recherche tapée au moment de la dernière validation (Entrée).
    /// (Gardée jusqu'à ce que le coordinateur passe à `lastCommitted`, contrat §4.6.)
    private(set) var lastCommittedQuery = ""

    /// Recherche ET ligne validées en dernier (2026-10-09, audit A4#3, B4#10). La
    /// requête seule ne suffisait pas : à la réouverture après un échec, c'était la
    /// 1ʳᵉ ligne qui revenait en surbrillance, pas celle que le monteur avait
    /// choisie (↓↓ puis Entrée) — un Entrée réflexe appliquait un AUTRE preset.
    private(set) var lastCommitted: (query: String, itemId: String)?

    func clearLastCommitted() {
        lastCommitted = nil
        lastCommittedQuery = ""
    }

    /// Validation avec refus possible (2026-10-09, audit A4#10), prioritaire sur
    /// `onCommit`. L'app rend false quand elle refuse (une application est déjà en
    /// cours) : la palette RESTE ouverte. Avant, elle se fermait quand même et le
    /// choix du monteur était perdu (HUD « Application en cours »).
    var onCommitChecked: ((SearchItem) -> Bool)?

    /// Rouvre la palette avec une recherche déjà tapée (après un échec rattrapable,
    /// ex. « Sélectionne d'abord un clip » : on ne fait pas retaper le monteur), en
    /// remettant en surbrillance la ligne `itemId` si elle figure dans les résultats
    /// (sinon la 1ʳᵉ, comme d'habitude).
    func show(prefill query: String, selecting itemId: String?) {
        show()
        prefill(query, selecting: itemId)
    }

    /// Remplit la recherche et choisit la ligne — séparé de show() pour être
    /// vérifié hors écran (selftest).
    /// 2026-10-09 (audit A4#3) : le curseur n'est plus remis au bout du texte. Une
    /// frappe s'ajoutait à l'ancienne recherche (« blur » + « glow » = « blurglow »,
    /// « Rien trouvé ») ; le texte est désormais entièrement sélectionné : une
    /// frappe le remplace, Entrée relance.
    func prefill(_ query: String, selecting itemId: String?) {
        var changed = false
        if !query.isEmpty {
            field.stringValue = query
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: query.utf16.count)
            refresh(announce: false)
            changed = true
        }
        if let itemId, let row = results.firstIndex(where: { $0.item.id == itemId }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            changed = true
        }
        if changed { announceSelection() }   // une seule annonce, pour la ligne retenue
    }

    /// Ce que VoiceOver annonce : le titre de la ligne en surbrillance, sinon le
    /// message « Rien trouvé » (nil : rien à dire).
    var spokenSelection: String? {
        let row = table.selectedRow
        if row >= 0, row < results.count { return results[row].item.title }
        return emptyLabel.isHidden ? nil : emptyLabel.stringValue
    }

    /// 2026-10-09 (audit A4#13) : sous VoiceOver, rien n'était annoncé. Le focus
    /// reste dans le champ (correctif 3fede64) : ↓, Tab et chaque frappe changeaient
    /// la ligne choisie en silence, le monteur appliquait à l'aveugle. On annonce
    /// la ligne en surbrillance à chaque changement — seulement palette affichée.
    private func announceSelection() {
        guard panel.isVisible, let text = spokenSelection else { return }
        HUD.announce(text)
    }

    func show() {
        isClosing = false
        // Calque activé à l'affichage (et pas à la création) : les animations pop en
        // ont besoin à l'écran, mais hors écran il empêchait de dessiner la ligne
        // sélectionnée dans les images du README (constaté le 2026-10-07).
        panel.contentView?.wantsLayer = true
        field.stringValue = ""

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - width / 2,
                                               y: frame.minY + frame.height * HUD.anchorFraction))
        }

        // Apparition instantanée, comme un panneau de Premiere (direction B).
        // 2026-10-09 (audit A4#8) : le clavier est pris AVANT de remplir la liste.
        // Tant que la palette n'est pas la fenêtre clé, la frappe part dans
        // Premiere, où une lettre seule est un outil (D sélectionne le clip sous la
        // tête de lecture, C le cutter, M un marqueur…) ; remplir la liste d'abord
        // allongeait cette fenêtre de temps. Le haut de la palette reste fixe quand
        // refresh() la redimensionne : la position posée ici ne bouge pas.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        // Champ vide = classement fréquence + récence, prêt à l'emploi : la
        // palette ne s'ouvre plus sur une liste vide qui attend une frappe.
        refresh()
        Logger.shared.debug("Palette affichée (key=\(panel.isKeyWindow), focusChamp=\(panel.firstResponder === field.currentEditor()))")
        // Sans le focus clavier, la frappe et Entrée partent dans Premiere (qui
        // bipe) : tracé en clair, c'est la première chose à lire chez un ami.
        if !panel.isKeyWindow {
            Logger.shared.error("Palette affichée SANS le focus clavier — la frappe va à l'app au premier plan")
        }
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
        // Direction B : fermeture instantanée, sans zoom ni fondu.
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Documentation : la palette telle qu'elle s'afficherait pour `query`
    /// (champ vide = fréquents), rendue hors écran. Voir Snapshot / render-media.
    func snapshotPNG(query: String, dark: Bool) -> Data? {
        // Apparence posée AVANT de remplir la liste : en changer après recrée les
        // lignes et efface la sélection forcée ci-dessous.
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        field.stringValue = query
        refresh()
        panel.contentView?.layoutSubtreeIfNeeded()
        // Hors écran la fenêtre n'est pas « active » : la sélection se dessinerait
        // éteinte. On la montre comme dans l'app, où la palette a le focus.
        if !results.isEmpty, let row = table.rowView(atRow: 0, makeIfNecessary: true) {
            row.isEmphasized = true
            row.needsDisplay = true
        }
        guard let view = panel.contentView else { return nil }
        // Le fond est désormais peint par la vue elle-même : le rendu = l'app.
        return Snapshot.png(of: view, dark: dark)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// Place la palette dans la partie utile de l'écran (au-dessus du Dock).
    /// 2026-10-09 (audit A4#14, B4#11) : avec 17 à 20 résultats (réglage 1…20), la
    /// palette, dont le haut est à 72 % de l'écran, passait sous le Dock ou hors de
    /// l'écran sur un 13 pouces (100 + 28 pt par ligne) : dernières lignes et pied
    /// invisibles. On remonte d'abord le haut (sans dépasser le haut utile) ; si
    /// elle reste trop grande, on montre moins de lignes (la liste défile, ↓ et Tab
    /// suivent la ligne choisie).
    /// `chrome` = tout sauf les lignes ; renvoie le haut et la hauteur de liste retenus.
    static func fit(top: CGFloat, chrome: CGFloat, listHeight: CGFloat, rowHeight: CGFloat,
                    visible: NSRect, margin: CGFloat = 8) -> (top: CGFloat, listHeight: CGFloat) {
        var list = listHeight
        let room = visible.height - 2 * margin
        if chrome + list > room, list > rowHeight {
            let rowsThatFit = max(1, Int((room - chrome) / rowHeight))
            list = min(list, CGFloat(rowsThatFit) * rowHeight)
        }
        let total = chrome + list
        var fitted = top
        if fitted - total < visible.minY + margin { fitted = visible.minY + margin + total }
        fitted = min(fitted, visible.maxY - margin)
        return (fitted, list)
    }

    private func layout(rows: Int, noResult: Bool) {
        var listHeight: CGFloat = noResult ? 36 : CGFloat(rows) * rowHeight
        let headerVisible = showingFrequent && rows > 0
        let headerHeight: CGFloat = headerVisible ? 22 : 0
        var top = panel.frame.origin.y + panel.frame.height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let chrome = fieldHeight + 1 + 1 + footerHeight + (listHeight > 0 ? headerHeight + 8 : 0)
            (top, listHeight) = Self.fit(top: top, chrome: chrome, listHeight: listHeight,
                                         rowHeight: rowHeight, visible: visible)
        }
        let listBlock = listHeight > 0 ? listHeight + headerHeight + 8 : 0
        let total = fieldHeight + 1 + listBlock + 1 + footerHeight
        panel.setContentSize(NSSize(width: width, height: total))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.origin.x, y: top))

        // Du bas vers le haut : pied, filet, liste (+ en-tête), filet, champ.
        footerLabel.sizeToFit()
        footerLabel.frame.origin = NSPoint(x: 16, y: (footerHeight - footerLabel.frame.height) / 2)
        footerSeparator.frame = NSRect(x: 0, y: footerHeight, width: width, height: 1)
        let listBottom = footerHeight + 1 + 4
        scroll.frame = NSRect(x: 8, y: listBottom, width: width - 16, height: max(0, listHeight))
        scroll.isHidden = noResult || rows == 0
        frequentLabel.frame = NSRect(x: 48, y: listBottom + listHeight + 5, width: width - 64, height: 14)
        frequentLabel.isHidden = !headerVisible
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: 48, y: listBottom + (listHeight - emptyLabel.frame.height) / 2)
        emptyLabel.isHidden = !noResult
        fieldSeparator.frame = NSRect(x: 0, y: total - fieldHeight - 1, width: width, height: 1)
        searchIcon.frame = NSRect(x: 18, y: total - fieldHeight + (fieldHeight - 16) / 2, width: 16, height: 16)
        field.frame = NSRect(x: 46, y: total - fieldHeight + (fieldHeight - 20) / 2, width: width - 62, height: 20)
    }

    // MARK: - Recherche

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    private func refresh(announce: Bool = true) {
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
            table.scrollRowToVisible(0)   // liste raccourcie à l'écran (fit) : revenir en haut
        }
        // « Aucun résultat » ne concerne qu'une recherche : un classement vide
        // (premier lancement, aucune application encore faite) se montre nu.
        if !query.isEmpty && results.isEmpty { emptyLabel.stringValue = LF("Nothing found for “%@”", query) }
        layout(rows: results.count, noResult: !query.isEmpty && results.isEmpty)
        if announce { announceSelection() }
    }

    // MARK: - Clavier (flèches, Entrée, Échap depuis le champ)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        // ⌥Entrée / ⌃Entrée : appliquent aussi, au lieu d'insérer un retour à la
        // ligne invisible dans la recherche.
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            commitSelection(); return true
        // Tab ne sort plus du champ (il donnait le focus à la liste → Entrée
        // faisait bip) : il parcourt les résultats, comme les flèches.
        case #selector(NSResponder.insertTab(_:)):
            move(1); return true
        case #selector(NSResponder.insertBacktab(_:)):
            move(-1); return true
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
        announceSelection()
    }

    @objc private func rowDoubleClicked() {
        commitSelection()
    }

    private func commitSelection() {
        guard table.selectedRow >= 0, table.selectedRow < results.count else { return }
        let item = results[table.selectedRow].item
        lastCommittedQuery = field.stringValue
        lastCommitted = (field.stringValue, item.id)
        // Application déclenchée AVANT la fermeture : zéro latence ajoutée.
        if let onCommitChecked {
            guard onCommitChecked(item) else { return }   // refusé : la palette reste ouverte
        } else {
            onCommit?(item)
        }
        dismissWithPop()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]
        // Colonne de gauche FIXE dans les deux modes (audit UX : les titres sautaient
        // de 30 pt dès la première lettre) : ⌘n pour les fréquents, « fx » ou une
        // icône de type pour la recherche. Le compteur d'applications disparaît : il
        // était coupé à droite et ne parlait pas la même unité sur la ligne d'un duo.
        let glyph: PaletteCellView.Glyph
        if entry.count != nil, row < 10 {
            glyph = .shortcut("⌘\(row == 9 ? 0 : row + 1)")
        } else if entry.item.isCombo {
            glyph = .symbol("link")
        } else if entry.item.kind == "effect" {
            glyph = .fx
        } else {
            glyph = .symbol("square.stack.3d.down.right")
        }
        return PaletteCellView(width: width - 16, height: rowHeight, glyph: glyph,
                               title: entry.item.title, parts: entry.item.parts,
                               detail: Self.shortDetail(entry.item.subtitle),
                               partial: Self.partialNote(entry.item.fidelityHint))
    }

    /// « Preset · grant subtitles presets/Presets » → « Preset · Presets » : seul le
    /// dernier dossier, sinon le détail se coupait au début (« …set · grant… »).
    static func shortDetail(_ subtitle: String) -> String {
        guard let dot = subtitle.range(of: " · ") else { return subtitle }
        let folder = subtitle[dot.upperBound...]
        guard let last = folder.split(separator: "/").last, folder.contains("/") else { return subtitle }
        return subtitle[..<dot.upperBound] + last.trimmingCharacters(in: .whitespaces)
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

/// Couleurs de la palette, direction B « façon Premiere » (thème sombre d'Adobe,
/// Spectrum) ; une variante claire suit l'apparence du Mac.
enum PaletteStyle {
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
    static let background = dynamic(hex(0x1D1D1D), hex(0xF4F4F4))
    static let border = dynamic(hex(0xFFFFFF, 0.09), hex(0x000000, 0.12))
    static let separator = dynamic(hex(0x2C2C2C), hex(0xDDDDDD))
    static let primaryText = dynamic(hex(0xE3E3E3), hex(0x222222))
    static let secondaryText = dynamic(hex(0x8F8F8F), hex(0x6E6E6E))
    static let tertiaryText = dynamic(hex(0x6E6E6E), hex(0x9A9A9A))
    static let selection = hex(0x2680EB)
    static let selectedText = hex(0xFFFFFF)
    static let selectedSecondary = hex(0xFFFFFF, 0.85)
    static let chip = dynamic(hex(0x343434), hex(0xE2E2E2))
    static let partial = hex(0xE8A33D)
}

/// Fond plein d'une couleur (filets de séparation).
final class FillView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

/// Une ligne de résultat : glyphe à gauche, titre, badge « partiel », détail à droite.
/// Les couleurs suivent la sélection (backgroundStyle).
final class PaletteCellView: NSTableCellView {
    enum Glyph { case shortcut(String), fx, symbol(String) }

    private let glyphLabel = NSTextField(labelWithString: "")
    private let glyphImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var partialLabel: NSTextField?

    private var chips: [NSTextField] = []
    private var arrows: [NSTextField] = []

    init(width: CGFloat, height: CGFloat, glyph: Glyph, title: String, parts: [String]? = nil,
         detail: String, partial: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let glyphRect = NSRect(x: 6, y: (height - 16) / 2, width: 30, height: 16)
        switch glyph {
        case .shortcut(let text):
            glyphLabel.stringValue = text
            glyphLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            glyphLabel.frame = NSRect(x: 6, y: (height - 13) / 2 - 1, width: 30, height: 13)
        case .fx:
            glyphLabel.stringValue = "fx"
            glyphLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 11.5, weight: .semibold), toHaveTrait: .italicFontMask)
        case .symbol(let name):
            glyphImage.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            glyphImage.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            glyphImage.frame = glyphRect
            addSubview(glyphImage)
        }
        glyphLabel.alignment = .center
        if glyphLabel.frame == .zero { glyphLabel.frame = glyphRect }
        addSubview(glyphLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.sizeToFit()
        let detailWidth = min(detailLabel.frame.width, 200)
        detailLabel.frame = NSRect(x: width - 12 - detailWidth, y: (height - 14) / 2, width: detailWidth, height: 14)
        addSubview(detailLabel)

        var titleRight = detailLabel.frame.minX - 10
        if let partial {
            // Badge visible (pastille ambre), plus une note grise de 9 pt.
            let badge = NSTextField(labelWithString: partial)
            badge.font = .systemFont(ofSize: 9.5, weight: .semibold)
            badge.textColor = PaletteStyle.partial
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = PaletteStyle.partial.withAlphaComponent(0.15).cgColor
            badge.layer?.cornerRadius = 4
            badge.toolTip = L("This preset can't be fully replayed: some settings aren't accessible to Premiere extensions.")
            badge.sizeToFit()
            let badgeWidth = badge.frame.width + 10
            badge.frame = NSRect(x: titleRight - badgeWidth, y: (height - 15) / 2, width: badgeWidth, height: 15)
            addSubview(badge)
            partialLabel = badge
            titleRight = badge.frame.minX - 8
        }

        if let parts, parts.count == 2 {
            // Duo : deux étiquettes reliées par une flèche — on voit d'un coup d'œil que
            // ce sont deux presets, et dans quel ordre ils seront posés.
            var x: CGFloat = 40
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    let arrow = NSTextField(labelWithString: "→")
                    arrow.font = .systemFont(ofSize: 12, weight: .medium)
                    arrow.sizeToFit()
                    arrow.frame.origin = NSPoint(x: x, y: (height - arrow.frame.height) / 2)
                    addSubview(arrow); arrows.append(arrow)
                    x = arrow.frame.maxX + 6
                }
                let chip = NSTextField(labelWithString: part)
                chip.font = .systemFont(ofSize: 12)
                chip.lineBreakMode = .byTruncatingTail
                chip.alignment = .center
                chip.wantsLayer = true
                chip.layer?.cornerRadius = 4
                chip.sizeToFit()
                let room = titleRight - x - (i == 0 ? 120 : 0)
                let chipWidth = min(chip.frame.width + 14, max(50, room))
                chip.frame = NSRect(x: x, y: (height - 18) / 2, width: chipWidth, height: 18)
                addSubview(chip); chips.append(chip)
                x = chip.frame.maxX + 6
            }
        } else {
            titleLabel.stringValue = title
            titleLabel.font = .systemFont(ofSize: 12.5)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.frame = NSRect(x: 40, y: (height - 16) / 2, width: max(60, titleRight - 40), height: 16)
            addSubview(titleLabel)
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        titleLabel.textColor = selected ? PaletteStyle.selectedText : PaletteStyle.primaryText
        detailLabel.textColor = selected ? PaletteStyle.selectedSecondary : PaletteStyle.secondaryText
        glyphLabel.textColor = selected ? PaletteStyle.selectedSecondary : PaletteStyle.secondaryText
        glyphImage.contentTintColor = selected ? PaletteStyle.selectedSecondary : PaletteStyle.secondaryText
        for chip in chips {
            chip.textColor = selected ? PaletteStyle.selectedText : PaletteStyle.primaryText
            chip.layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(0.22) : PaletteStyle.chip).cgColor
        }
        for arrow in arrows { arrow.textColor = selected ? PaletteStyle.selectedText : PaletteStyle.secondaryText }
    }
}

/// Fond de la palette : couleur unie façon Premiere, filet fin, coins arrondis.
/// Dessiné en draw(_:) (et non en propriété de calque) pour que le rendu hors écran
/// des images du README (Snapshot) soit identique, pixel pour pixel, à l'écran.
final class PaletteBackgroundView: NSView {
    static let cornerRadius: CGFloat = 8

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        PaletteStyle.background.setFill()
        path.fill()
        PaletteStyle.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Ligne de la palette : la sélection est peinte ici, bleu Adobe plein.
/// AppKit ne la dessinait pas dans le rendu hors écran des images (le texte passait
/// en blanc mais le fond bleu manquait) ; la peindre soi-même rend l'écran et les
/// images identiques.
final class PaletteRowView: NSTableRowView {
    // La sélection reste en couleur « active » même quand c'est le CHAMP qui a le
    // focus (toujours le cas dans la palette) : sinon le texte de la ligne
    // sélectionnée restait gris sur le bleu (capture d'Isma, ligne « Crop »).
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        PaletteStyle.selection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Hors écran, drawSelection n'est pas toujours appelé par AppKit.
        if isSelected, NSGraphicsContext.current?.isDrawingToScreen == false {
            drawSelection(in: dirtyRect)
        }
    }
}
