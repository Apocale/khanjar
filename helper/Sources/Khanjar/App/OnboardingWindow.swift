import AppKit
import ServiceManagement

/// Écran d'accueil : le point de premier contact qui manquait. Affiché au tout
/// premier lancement (et via le menu « Guide de démarrage »). Explique où est
/// Khanjar, comment l'utiliser (⌘J), l'état du plugin, et propose le démarrage
/// automatique. Sans lui, un ami ne voit qu'une icône muette dans la barre de menus.
final class OnboardingWindowController: NSObject {

    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "")
    private let startupCheckbox = NSButton(checkboxWithTitle: L("Launch Khanjar at login"), target: nil, action: nil)
    private let crashCheckbox = NSButton(checkboxWithTitle: L("Send anonymous crash reports"), target: nil, action: nil)

    /// État du plugin (réutilise le fournisseur de statut de l'app).
    var statusProvider: (() -> String)?
    /// Raccourci palette courant (affichage), ex. "⌘J".
    var paletteShortcutProvider: (() -> String)?
    /// Consentement aux rapports de plantage (lu/écrit dans settings.json par l'app).
    var crashReportsEnabled: (() -> Bool)?
    var setCrashReports: ((Bool) -> Void)?

    /// Marqueur de premier lancement (fichier dédié — n'encombre pas settings.json).
    /// Getter PUR (pas d'effet de bord) : le dossier est créé au moment d'écrire.
    private static var onboardedMarker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar/.onboarded")
    }

    static var isFirstLaunch: Bool { !FileManager.default.fileExists(atPath: onboardedMarker.path) }

    /// Affiche au premier lancement uniquement. Marque APRÈS affichage : si open()
    /// échouait, l'accueil serait revu au prochain lancement plutôt que perdu.
    func showIfFirstLaunch() {
        guard Self.isFirstLaunch else { return }
        open()
        let marker = Self.onboardedMarker
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: marker)
    }

    func open() {
        if window == nil { window = buildWindow() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        statusLabel.stringValue = statusProvider?() ?? ""
        startupCheckbox.state = Self.isLoginItemEnabled ? .on : .off
        crashCheckbox.state = (crashReportsEnabled?() ?? false) ? .on : .off
    }

    private func buildWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L("Welcome to Khanjar")
        win.isReleasedWhenClosed = false
        let content = NSView()
        win.contentView = content

        let icon = NSImageView(image: NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Khanjar") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        let title = NSTextField(labelWithString: L("Khanjar is ready"))
        title.font = .systemFont(ofSize: 20, weight: .bold)

        let key = paletteShortcutProvider?() ?? "⌘J"
        func step(_ symbol: String, _ text: String) -> NSStackView {
            let img = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            img.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            img.contentTintColor = .controlAccentColor
            img.setContentHuggingPriority(.required, for: .horizontal)
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 13)
            l.preferredMaxLayoutWidth = 360
            let row = NSStackView(views: [img, l])
            row.alignment = .top
            row.spacing = 10
            return row
        }
        let steps = NSStackView(views: [
            step("menubar.arrow.up.rectangle", L("Khanjar lives in your menu bar — the wand icon ✦ at the top right. It runs in the background.")),
            step("magnifyingglass", LF("In Premiere Pro, press %@ to open the palette. Search for an effect or a preset, then press ↵ to apply it to the selected clips.", key)),
            step("square.stack.3d.up", L("You can also assign your favorite presets to keyboard shortcuts in Settings.")),
            step("lock.shield", L("On first launch, macOS may ask for access to your Documents folder (to read your presets) — click “Allow”.")),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 14

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        startupCheckbox.target = self
        startupCheckbox.action = #selector(toggleStartup)

        let done = NSButton(title: L("Get started"), target: self, action: #selector(close))
        done.keyEquivalent = "\r"

        // Rapports de plantage : décochée par défaut (opt-in), proposée seulement si
        // ce build sait où envoyer. L'explication reste visible, pas cachée en infobulle.
        crashCheckbox.target = self
        crashCheckbox.action = #selector(toggleCrashReports)
        let crashHint = NSTextField(wrappingLabelWithString: L("Only if Khanjar crashes: the versions and where in the code. Never your clips, presets or files."))
        crashHint.font = .systemFont(ofSize: 10)
        crashHint.textColor = .secondaryLabelColor
        crashHint.alignment = .center
        crashHint.preferredMaxLayoutWidth = 360
        let checkboxes: [NSView] = CrashReporter.isAvailable ? [startupCheckbox, crashCheckbox, crashHint] : [startupCheckbox]

        let stack = NSStackView(views: [icon, title, steps, statusLabel] + checkboxes + [done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(8, after: icon)
        if CrashReporter.isAvailable {  // seulement si les vues sont dans la pile
            stack.setCustomSpacing(8, after: startupCheckbox)
            stack.setCustomSpacing(4, after: crashCheckbox)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        return win
    }

    @objc private func close() { window?.close() }

    @objc private func toggleCrashReports() { setCrashReports?(crashCheckbox.state == .on) }

    // MARK: - Login item (démarrage auto)

    private static var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleStartup() {
        guard #available(macOS 13.0, *) else {
            HUD.show(L("Launch at login requires macOS 13 or later"))
            return
        }
        do {
            if startupCheckbox.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            startupCheckbox.state = Self.isLoginItemEnabled ? .on : .off
            HUD.show(L("Couldn't change launch at login"))
        }
    }
}
