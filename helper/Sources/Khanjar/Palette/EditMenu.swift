import AppKit

/// Menu principal minimal avec un menu Édition — jamais affiché.
///
/// 2026-10-09 (audit A4#5, B1 Min.5) : dans la palette et les Réglages, ⌘A, ⌘C,
/// ⌘V, ⌘X et ⌘Z faisaient bip et ne faisaient rien (impossible, par exemple, de
/// vider d'un ⌘A une recherche pré-remplie). Cause : Khanjar est une app
/// « accessory » et main.swift ne crée aucun menu principal ; or AppKit ne fait
/// parvenir ces raccourcis à un champ de texte QUE par les équivalents clavier du
/// menu principal (Annuler, Couper, Copier… envoyés au premier répondeur).
/// Correction : un menu principal avec Édition, installé à la création de la
/// palette. Une app accessory n'a pas de barre de menus : rien ne s'affiche.
enum EditMenu {
    /// N'installe le menu que si l'app n'en a pas déjà un (ne remplace jamais
    /// un menu existant ; un second appel ne fait rien).
    static func installIfNeeded() {
        let app = NSApplication.shared
        if let existing = app.mainMenu, !existing.items.isEmpty { return }
        let main = NSMenu()
        // Le 1er élément d'un menu principal est toujours celui de l'application.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        app.mainMenu = main
    }
}
