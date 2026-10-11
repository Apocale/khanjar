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

    /// Rappel discret d'une mise à jour trouvée par la vérification programmée :
    /// vrai = l'afficher (point sur l'icône + entrée de menu), faux = le retirer.
    var onGentleReminder: ((Bool) -> Void)?

    // C-12 (2026-10-09) — le drapeau ci-dessus était posé SANS les méthodes de
    // rappel : pour une app d'arrière-plan, Sparkle ouvre alors l'alerte de mise à
    // jour DERRIÈRE les autres apps — derrière Premiere, donc invisible (doc
    // « gentle reminders » de Sparkle). Désormais : au lancement (focus immédiat),
    // Sparkle montre l'alerte lui-même ; sinon, point sur l'icône et entrée « Mise à
    // jour disponible… », qui ramène l'alerte au premier plan via checkForUpdates.
    // Sélecteurs écrits en toutes lettres : une méthode facultative mal nommée
    // ne serait jamais appelée, sans erreur.
    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }   // Sparkle l'affiche lui-même
        log.info("Mises à jour : \(update.displayVersionString) disponible — rappel discret (point sur l'icône)")
        onGentleReminder?(true)
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onGentleReminder?(false)
    }

    @objc(standardUserDriverWillFinishUpdateSession)
    func standardUserDriverWillFinishUpdateSession() {
        onGentleReminder?(false)
    }

    /// C-12 (2026-10-09) — « aucune mise à jour » (SUNoUpdateError, 1001) arrive aussi
    /// par `didAbortWithError` : le journal recevait chaque jour un faux `[error]
    /// … You're up to date!`, qui brouille le diagnostic chez un ami.
    static func isNoUpdateError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)
    }

    /// Domaine des erreurs Sparkle (pour le selftest, qui n'importe pas Sparkle).
    static let sparkleErrorDomain = SUSparkleErrorDomain

    /// Rappels discrets que le protocole de Sparkle déclare mais que ce service ne
    /// sait pas recevoir (vide attendu ; vérifié par le selftest).
    static func missingGentleReminderMethods() -> [String] {
        let names = ["standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                     "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
                     "standardUserDriverDidReceiveUserAttentionForUpdate:",
                     "standardUserDriverWillFinishUpdateSession"]
        return names.filter { name in
            let selector = NSSelectorFromString(name)
            let declared = protocol_getMethodDescription(SPUStandardUserDriverDelegate.self, selector, false, true).name != nil
            return !(declared && UpdateService.instancesRespond(to: selector))
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if Self.isNoUpdateError(error) {
            log.info("Mises à jour : déjà à jour")
            return
        }
        log.error("Mises à jour : vérification interrompue — \(error.localizedDescription)")
    }
}
