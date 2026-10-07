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

        let logItem = NSMenuItem(title: L("Open log"), action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("Quit Khanjar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = statusProvider?() ?? ""
        let key = paletteShortcutProvider?() ?? ""
        paletteItem.title = key.isEmpty ? L("Open palette") : LF("Open palette (%@)", key)
        updatesItem.isHidden = (onCheckForUpdates == nil)
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }

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
