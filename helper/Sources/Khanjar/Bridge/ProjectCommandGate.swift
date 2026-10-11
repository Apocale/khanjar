import Foundation

/// Une seule commande qui MODIFIE le projet à la fois (apply, calque d'effets).
///
/// C-02 (2026-10-09) — le verrou de l'app (`applyInFlight`) était relâché au délai
/// d'attente, et le HUD disait « Premiere ne répond pas — réessaie » alors que
/// Premiere travaillait encore : le nouvel essai posait les effets EN DOUBLE (vécu
/// les 07/07 et 11/07 ; même mécanisme pour ⌘⇧J : deux calques empilés). Le verrou
/// est désormais gardé jusqu'à la vraie réponse (même tardive), une déconnexion ou
/// le délai maximal, et la requête porte une échéance (`expiresAt`) au-delà de
/// laquelle le plugin refuse de commencer (EXPIRED, rien n'est fait).
final class ProjectCommandGate {
    /// `working` : rien n'est revenu après `workingAfter` ; `slow` : délai normal
    /// dépassé, on attend toujours (verrou gardé).
    enum Phase { case working, slow }

    private let server: BridgeServer
    private(set) var inFlight = false

    init(server: BridgeServer) {
        self.server = server
    }

    /// Envoie la commande si aucune autre ne tourne. `false` = refusée : une
    /// commande est déjà en cours, rien n'est envoyé (ni `onPhase` ni `completion`).
    @discardableResult
    func send(cmd: String,
              payload: [String: Any] = [:],
              timeout: TimeInterval,
              hardTimeout: TimeInterval,
              workingAfter: TimeInterval = 1,
              onPhase: @escaping (Phase) -> Void,
              completion: @escaping (Result<[String: Any], BridgeError>) -> Void) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        var message = payload
        message["expiresAt"] = Self.expiresAt(now: Date(), hardTimeout: hardTimeout)
        let working = DispatchWorkItem { onPhase(.working) }
        DispatchQueue.main.asyncAfter(deadline: .now() + workingAfter, execute: working)
        server.request(cmd: cmd, payload: message, timeout: timeout,
                       onSlow: {
                           working.cancel()
                           onPhase(.slow)
                       },
                       hardTimeout: hardTimeout) { [weak self] result in
            working.cancel()
            self?.inFlight = false   // AVANT la suite : elle peut relancer une commande
            completion(result)
        }
        return true
    }

    /// Échéance transmise au plugin, en millisecondes depuis 1970 (contrat §4.1) :
    /// le délai maximal de l'app moins 5 s, pour qu'une commande refusée par
    /// échéance le soit avant que l'app n'abandonne l'attente.
    static func expiresAt(now: Date, hardTimeout: TimeInterval) -> Int64 {
        Int64(((now.timeIntervalSince1970 + hardTimeout - 5) * 1000).rounded())
    }
}
