import Foundation

/// Textes d'interface, en anglais par défaut et en français.
///
/// RÈGLE : la CLÉ est le texte anglais lui-même. Une traduction manquante
/// affiche donc l'anglais, jamais un identifiant technique. Les traductions
/// françaises vivent dans `helper/Resources/fr.lproj/Localizable.strings`,
/// copiées dans Khanjar.app par `scripts/build-app.sh`. macOS choisit la langue
/// selon les préférences du Mac (`CFBundleLocalizations` = en, fr ; toute autre
/// langue retombe sur l'anglais).
///
/// Hors du bundle (modes CLI lancés depuis .build/), aucune traduction n'est
/// trouvée : l'interface parle anglais. Les journaux et la CLI, destinés au
/// développement, restent en français.
@inline(__always)
func L(_ english: String) -> String {
    NSLocalizedString(english, comment: "")
}

/// Variante avec arguments (`String(format:)`, %@ pour du texte, %d pour un entier).
func LF(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(english, comment: ""), arguments: arguments)
}
