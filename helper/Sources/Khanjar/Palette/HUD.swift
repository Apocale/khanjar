import AppKit

/// Retour discret après une action : petit panneau flottant, jamais de focus,
/// jamais bloquant. Depuis l'audit UX du 2026-10-07 :
///  - il s'affiche à la hauteur de la palette (là où l'œil est déjà), plus en bas
///    de l'écran sur la timeline ;
///  - succès et avertissement se distinguent (icône verte / jaune) et l'erreur
///    reste plus longtemps, le temps de la lire ;
///  - apparition et disparition en fondu.
enum HUD {
    enum Style { case info, success, warning }

    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    /// Hauteur du haut de la palette, en fraction de l'écran utile (cf. PaletteWindowController.show).
    static let anchorFraction: CGFloat = 0.72

    /// Cadre de la palette quand elle est ouverte (nil sinon), posé par
    /// PaletteWindowController : le HUD ne la recouvre jamais (m10).
    static var paletteFrame: (() -> NSRect?)?

    /// Thème forcé de la palette (Réglages > Thème), posé par
    /// PaletteWindowController.setTheme ; nil = apparence du Mac.
    static var appearance: NSAppearance?

    static func show(_ text: String, duration: TimeInterval? = nil, style: Style = .info) {
        hideTimer?.invalidate()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        var icon: NSImageView?
        switch style {
        case .success: icon = symbol("checkmark.circle.fill", .systemGreen)
        case .warning: icon = symbol("exclamationmark.triangle.fill", .systemYellow)
        case .info: icon = nil
        }

        let padding: CGFloat = 14, gap: CGFloat = 8, iconSize: CGFloat = 16
        let iconWidth = icon == nil ? 0 : iconSize + gap
        let size = NSSize(width: label.frame.width + iconWidth + padding * 2,
                          height: max(label.frame.height, iconSize) + padding)

        let hud = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.ignoresMouseEvents = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.appearance = appearance   // même thème que la palette (audit A4#16)

        let background = PaletteBackgroundView(frame: NSRect(origin: .zero, size: size))
        if let icon {
            icon.frame = NSRect(x: padding, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize)
            background.addSubview(icon)
        }
        label.frame.origin = NSPoint(x: padding + iconWidth, y: (size.height - label.frame.height) / 2)
        background.addSubview(label)
        hud.contentView = background

        if let palette = paletteFrame?() {
            // Sous la palette ; au-dessus si elle touche le bas de l'écran.
            let screenFrame = (NSScreen.screens.first { $0.frame.intersects(palette) } ?? NSScreen.main)?.visibleFrame
            var y = palette.minY - 8 - size.height
            if let screenFrame, y < screenFrame.minY { y = palette.maxY + 8 }
            hud.setFrameOrigin(NSPoint(x: palette.midX - size.width / 2, y: y))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let top = frame.minY + frame.height * anchorFraction
            hud.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: top - size.height))
        }
        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; hud.animator().alphaValue = 1 }
        panel = hud
        // VoiceOver (2026-10-09, audit A4#13) : le résultat d'une application
        // (« → 3 clips », « Sélectionne d'abord un clip ») n'était jamais lu.
        announce(text)

        let shown = duration ?? (style == .warning ? 4 : style == .success ? 1.4 : 1.8)
        hideTimer = Timer.scheduledTimer(withTimeInterval: shown, repeats: false) { _ in
            guard let current = panel, current === hud else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; current.animator().alphaValue = 0 },
                                                 completionHandler: {
                current.orderOut(nil)
                if panel === current { panel = nil }
            })
        }
    }

    /// Demande à VoiceOver de lire `text` tout de suite (priorité haute : une
    /// annonce plus récente interrompt la précédente). Sans VoiceOver, sans effet.
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private static func symbol(_ name: String, _ color: NSColor) -> NSImageView? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let view = NSImageView(image: image)
        view.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        view.contentTintColor = color
        return view
    }
}
