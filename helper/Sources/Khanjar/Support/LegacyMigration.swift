import Foundation

/// Reprise des données de l'ancienne app « Dagger ».
///
/// POURQUOI (2026-10-06) : l'app a été renommée Khanjar — « Dagger » est déjà
/// le nom d'une extension Premiere commerciale (Knights of the Editing Table).
/// Un utilisateur qui passe de Dagger à Khanjar ne doit RIEN perdre : réglages
/// et raccourcis, classement des fréquents et des duos (des centaines
/// d'applications rejouées depuis le journal), index des presets.
///
/// RÈGLES :
///  - ne joue qu'à la toute première ouverture de Khanjar (aucun settings.json) ;
///  - COPIE, ne déplace jamais : l'ancien dossier reste intact, retour arrière
///    possible en relançant l'ancienne app ;
///  - jamais le verrou d'instance (.instance.lock) ;
///  - les ids d'items ("preset:<uid>", "effect:<matchName>") ne dépendent pas du
///    nom de l'app : usage.json et les raccourcis restent valables tels quels.
enum LegacyMigration {
    static let legacyFolderName = "Dagger"
    static let carriedFiles = ["settings.json", "usage.json", "index.json", ".onboarded"]

    /// Copie les données de Dagger vers Khanjar si besoin ; retourne les fichiers repris.
    @discardableResult
    /// `supportDir` : injectable pour les tests (dossier temporaire) — par
    /// défaut le vrai ~/Library/Application Support.
    static func run(supportDir: URL? = nil, log: Logger = .shared) -> [String] {
        let fm = FileManager.default
        let support = supportDir ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent(legacyFolderName, isDirectory: true)
        let current = support.appendingPathComponent("Khanjar", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: current.appendingPathComponent("settings.json").path) else { return [] }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        var copied: [String] = []
        for name in carriedFiles {
            let source = legacy.appendingPathComponent(name)
            let target = current.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.copyItem(at: source, to: target)
                copied.append(name)
            } catch {
                log.error("Reprise Dagger : \(name) non copié — \(error)")
            }
        }
        if !copied.isEmpty {
            log.info("Reprise des données de Dagger : \(copied.joined(separator: ", ")) (l'ancien dossier reste intact)")
        }
        return copied
    }
}
