import AppKit
import Sparkle

/// Mises à jour automatiques (Sparkle 2), depuis les versions publiées sur GitHub.
///
/// Actif SEULEMENT si le build porte l'adresse du flux (SUFeedURL) et la clé publique
/// de signature (SUPublicEDKey) — injectées par build-app.sh. Un build local ou un
/// mode CLI n'a ni l'un ni l'autre : le service reste éteint, le menu n'affiche rien.
///
/// Sécurité : chaque mise à jour est signée (EdDSA) avec une clé privée qui ne quitte
/// jamais la machine de publication ; Sparkle refuse toute archive dont la signature
/// ne correspond pas à la clé publique embarquée. C'est ce qui permet de se passer
/// de la signature Apple pendant la bêta.
///
/// Consentement : au 2ᵉ lancement, Sparkle demande lui-même s'il peut vérifier les
/// mises à jour automatiquement (comportement par défaut, rien d'imposé).
final class UpdateService: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {

    private var controller: SPUStandardUpdaterController?
    private let log = Logger.shared

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = info["SUPublicEDKey"] as? String ?? ""
        return feed?.scheme == "https" && !key.isEmpty
    }

    var isRunning: Bool { controller != nil }

    func start() {
        guard Self.isConfigured else {
            log.info("Mises à jour : désactivées (build sans flux ni clé de signature)")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
        log.info("Mises à jour : actives (\(Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? "?"))")
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // Khanjar vit dans la barre de menus (pas d'icône dans le Dock) : Sparkle
    // recommande alors des rappels discrets, qui ne volent pas le focus pendant
    // un montage. Sans ce drapeau, Sparkle journalise un avertissement.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("Mises à jour : vérification interrompue — \(error.localizedDescription)")
    }
}
