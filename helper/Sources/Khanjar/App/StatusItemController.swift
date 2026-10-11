import AppKit

/// Icône de barre de menus : identité, état de connexion, accès aux réglages.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let paletteItem = NSMenuItem(title: L("Open palette"), action: nil, keyEquivalent: "")

    var statusProvider: (() -> String)?
    /// Raccourcis courants (affichés dans le menu → découvrabilité).
    var paletteShortcutProvider: (() -> String)?
    var onOpenSettings: (() -> Void)?
    var onAddAdjustmentLayer: (() -> Void)?
    var onOpenPalette: (() -> Void)?
    var onShowGuide: (() -> Void)?
    /// nil = mises à jour indisponibles dans ce build → entrée de menu masquée.
    var onCheckForUpdates: (() -> Void)?
    private let updatesItem = NSMenuItem(title: L("Check for Updates…"), action: nil, keyEquivalent: "")
    /// C-05 (2026-10-09) — rien ne permettait de relancer l'installation du plugin
    /// à la main (le guide renvoyait vers un « bouton Réparer » inexistant).
    /// nil = pas de plugin embarqué (build de développement) → entrée masquée.
    var onReinstallPlugin: (() -> Void)?
    /// Faux pendant qu'UPIA travaille : l'entrée est grisée.
    var canReinstallPlugin: (() -> Bool)?
    private let reinstallItem = NSMenuItem(title: L("Reinstall the plugin in Premiere"), action: nil, keyEquivalent: "")
    /// C-12 (2026-10-09) — rappel discret d'une mise à jour (Sparkle) : entrée
    /// visible seulement quand une mise à jour attend, avec un point sur l'icône.
    private let updateAvailableItem = NSMenuItem(title: L("Update available…"), action: nil, keyEquivalent: "")
    private var updateAvailable = false

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "wand.and.stars",
                                           accessibilityDescription: "Khanjar")

        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: LF("Khanjar %@ — by %@", SettingsWindowController.appVersion, SettingsWindowController.creator),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        updateAvailableItem.action = #selector(checkForUpdates)
        updateAvailableItem.target = self
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)
        menu.addItem(.separator())

        paletteItem.action = #selector(openPalette)
        paletteItem.target = self
        menu.addItem(paletteItem)

        let adjItem = NSMenuItem(title: L("Add an adjustment layer"), action: #selector(addAdjustment), keyEquivalent: "")
        adjItem.target = self
        menu.addItem(adjItem)
        menu.addItem(.separator())

        let guideItem = NSMenuItem(title: L("Getting started…"), action: #selector(showGuide), keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        updatesItem.action = #selector(checkForUpdates)
        updatesItem.target = self
        menu.addItem(updatesItem)

        reinstallItem.action = #selector(reinstallPlugin)
        reinstallItem.target = self
        menu.addItem(reinstallItem)

        let logItem = NSMenuItem(title: L("Open log"), action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("Quit Khanjar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Plugin connecté ou non : l'icône s'éteint quand ⌘J ne peut rien faire.
    /// Le 2026-10-06, ⌘J est resté muet 40 min sans aucun signe visible.
    func setConnected(_ connected: Bool) {
        statusItem.button?.appearsDisabled = !connected
        statusItem.button?.toolTip = connected ? "Khanjar" : L("Khanjar: Premiere not connected")
    }

    /// C-12 — une mise à jour attend (rappel discret) : point sur l'icône et entrée
    /// « Mise à jour disponible… » en tête du menu ; retirés quand le monteur l'a vue.
    func setUpdateAvailable(_ available: Bool) {
        guard available != updateAvailable else { return }
        updateAvailable = available
        updateAvailableItem.isHidden = !available
        statusItem.button?.image = Self.icon(withDot: available)
    }

    /// Icône de la barre de menus, avec un point en haut à droite si demandé
    /// (image « modèle » : suit la couleur de la barre, claire ou sombre).
    static func icon(withDot dot: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Khanjar") else { return nil }
        guard dot else { return base }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let diameter = max(4, size.height * 0.3)
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            // Liseré transparent autour du point : il se détache de l'étoile qu'il recouvre.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -diameter * 0.3, dy: -diameter * 0.3)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Khanjar"
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = statusProvider?() ?? ""
        let key = paletteShortcutProvider?() ?? ""
        paletteItem.title = key.isEmpty ? L("Open palette") : LF("Open palette (%@)", key)
        updatesItem.isHidden = (onCheckForUpdates == nil)
        reinstallItem.isHidden = (onReinstallPlugin == nil)
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func reinstallPlugin() { onReinstallPlugin?() }

    @objc private func openPalette() { onOpenPalette?() }
    @objc private func showGuide() { onShowGuide?() }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func addAdjustment() {
        onAddAdjustmentLayer?()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Logger.shared.fileURL)
    }
}

extension StatusItemController: NSMenuItemValidation {
    /// « Réinstaller le plugin » grisé pendant qu'UPIA travaille (une opération à la fois).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === reinstallItem { return canReinstallPlugin?() ?? true }
        return true
    }
}
