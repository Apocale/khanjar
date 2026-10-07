import AppKit

/// Retour discret post-action : petit panneau flottant bas-centre, disparaît
/// tout seul. Jamais de focus, jamais bloquant.
enum HUD {
    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    static func show(_ text: String, duration: TimeInterval = 1.6) {
        hideTimer?.invalidate()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        let padding: CGFloat = 14
        let size = NSSize(width: label.frame.width + padding * 2,
                          height: label.frame.height + padding)

        let hud = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: padding, y: padding / 2)
        background.addSubview(label)
        hud.contentView = background

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                       y: frame.minY + frame.height * 0.12))
        }
        hud.orderFrontRegardless()
        panel = hud

        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            panel?.orderOut(nil)
            panel = nil
        }
    }
}
