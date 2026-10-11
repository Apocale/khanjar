import Foundation
import Network

/// Serveur WebSocket loopback : une session plugin active à la fois,
/// corrélation requête/réponse, heartbeats, callbacks sur la main queue.
final class BridgeServer {
    private let port: UInt16
    private let log = Logger.shared
    private var listener: NWListener?
    /// Écouteur secondaire sur ::1 (C-18) : son échec n'arrête rien.
    private var listener6: NWListener?

    // Session active
    private var connection: NWConnection?
    private(set) var hello: HelloInfo?
    private var lastHeartbeat = Date.distantPast

    // Requêtes en attente : id → (timer, completion)
    private var pending: [String: (timer: DispatchSourceTimer, completion: (Result<[String: Any], BridgeError>) -> Void)] = [:]

    var onHello: ((HelloInfo) -> Void)?
    /// L'ancien plugin « Dagger Executor » s'est présenté (refusé). Signalé une
    /// fois par session d'app pour ne pas inonder le journal toutes les 2 s.
    var onLegacyPlugin: (() -> Void)?
    private var legacyPluginSeen = false
    var onDisconnect: (() -> Void)?
    /// Échec définitif du listener (ex. port déjà pris par une autre instance).
    var onListenerFailed: ((Error) -> Void)?
    var onListenerReady: (() -> Void)?

    var isReady: Bool { connection != nil && hello != nil }

    init(port: UInt16 = Bridge.defaultPort) {
        self.port = port
    }

    // MARK: - Démarrage

    func start() throws {
        // Nouvel essai après un échec (port pris) : libérer d'abord les écouteurs
        // précédents au lieu de les abandonner.
        listener?.cancel()
        listener = nil
        listener6?.cancel()
        listener6 = nil

        let listener = try NWListener(using: makeParameters(host: "127.0.0.1", reuseAddress: false))
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.info("Bridge en écoute sur ws://127.0.0.1:\(self?.port ?? 0)")
                self?.onListenerReady?()
            case .failed(let error):
                self?.log.error("Listener en échec : \(error)")
                self?.onListenerFailed?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        self.listener = listener
        // L'écouteur principal (IPv4) démarre une fois l'écoute ::1 tranchée.
        startLoopbackIPv6 { [weak listener] in listener?.start(queue: .main) }
    }

    /// C-18 (2026-10-09) — le plugin appelle « ws://localhost:48123 » et, sur ce
    /// Mac, localhost se résout d'abord en ::1 (getaddrinfo, 6 essais sur 6) ; le
    /// pont n'écoutait qu'en IPv4. UXP se rabat aujourd'hui sur 127.0.0.1, mais un
    /// UXP qui ne le ferait pas ne joindrait jamais Khanjar, sans trace côté app.
    /// Second écouteur sur ::1, même port ; son échec n'arrête rien (journal seul).
    ///
    /// ⚠️ MESURÉ (macOS 26, Network.framework, ports de test) : deux NWListener
    /// 127.0.0.1:P et [::1]:P se gênent — le second échoue en EADDRINUSE, dans les
    /// deux ordres, version IP forcée ou non (des sockets BSD, eux, coexistent).
    /// Ils coexistent seulement si le PREMIER lié a `allowLocalEndpointReuse`.
    /// D'où l'ordre : ::1 d'abord, avec réutilisation ; puis 127.0.0.1 avec ses
    /// réglages d'avant (sans réutilisation). Vérifié aussi : avec la réutilisation,
    /// un autre processus ne peut toujours PAS écouter sur la même adresse
    /// (SO_REUSEADDR, SO_REUSEPORT ou NWListener réutilisant : EADDRINUSE).
    /// Filet : l'IPv4 démarre au plus tard 1 s après, quoi que fasse ::1.
    private func startLoopbackIPv6(then startIPv4: @escaping () -> Void) {
        var settled = false
        let settle = {
            guard !settled else { return }
            settled = true
            startIPv4()
        }
        let v6: NWListener
        do {
            v6 = try NWListener(using: makeParameters(host: "::1", reuseAddress: true))
        } catch {
            log.error("Écoute IPv6 [::1] impossible (\(error)) — le pont reste en IPv4")
            settle()
            return
        }
        v6.stateUpdateHandler = { [weak self, weak v6] state in
            switch state {
            case .ready:
                self?.log.info("Bridge en écoute aussi sur ws://[::1]:\(self?.port ?? 0)")
                settle()
            case .failed(let error):
                self?.log.error("Écoute IPv6 [::1] indisponible (\(error)) — le pont reste en IPv4")
                v6?.cancel()
                settle()
            case .cancelled:
                settle()
            default: break
            }
        }
        v6.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        v6.start(queue: .main)
        listener6 = v6
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: settle)
    }

    /// Paramètres d'un écouteur WebSocket lié à une adresse de boucle locale.
    private func makeParameters(host: String, reuseAddress: Bool) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        params.allowLocalEndpointReuse = reuseAddress
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // GARDE-FOU WEB (2026-10-06). Le port n'écoute que la boucle locale,
        // mais une PAGE WEB ouverte dans le navigateur de l'utilisateur peut
        // quand même ouvrir un WebSocket vers ws://127.0.0.1:48123 : pour les
        // WebSockets, le navigateur ne demande rien, c'est au serveur de filtrer
        // selon l'en-tête Origin. Sans ce filtre, une page pouvait se présenter
        // comme le plugin, remplacer la vraie session (⌘J muet) et lire ce que
        // l'utilisateur applique. Un navigateur envoie TOUJOURS Origin lors de
        // la poignée de main ; on refuse les origines web (voir isRefused(origin:)).
        // Le plugin UXP, lui, n'est pas une page.
        wsOptions.setClientRequestHandler(.main) { [weak self] subprotocols, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            if let origin, Self.isRefused(origin: origin) {
                self?.noteRefusedOrigin(origin)
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            self?.noteClientOrigin(origin)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
        }
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return params
    }

    /// Origines refusées = ce qu'un NAVIGATEUR peut envoyer (page web ou extension).
    ///
    /// C-07 (2026-10-09, décision Q9 d'Isma). Règle, sur le schéma seulement :
    ///  - REFUSÉS : `http`, `https`, `data`, `blob`, tout schéma d'extension de
    ///    navigateur (`chrome-extension`, `moz-extension`, `safari-web-extension`… :
    ///    suffixe « -extension ») et la valeur `null` (page enfermée dans une iframe
    ///    « sandbox », URL `data:` : passait l'ancienne liste noire, audit du 2026-10-07) ;
    ///  - ACCEPTÉS : pas d'en-tête Origin (client qui n'est pas un navigateur),
    ///    `file://` (ce qu'annonce le plugin UXP sur Premiere 26.5.2, relevé le
    ///    2026-10-06) et tout autre schéma non web (`uxp://`…).
    /// Avant (12b5fdb, liste BLANCHE `file://`) : relevée sur UN seul Premiere ; un
    /// ami dont l'UXP annoncerait autre chose (26.0-26.4, 2027) aurait eu un ⌘J mort,
    /// une ligne d'erreur toutes les 2 s et un socket perdu à chaque essai.
    /// ⚠️ Ce filtre n'arrête que les PAGES WEB : un programme local qui n'envoie pas
    /// d'en-tête est accepté (audit sécurité A6, MAJEUR 1 — modèle de menace d'AGENTS §12).
    /// (L'ancien commentaire disait à la fois « null accepté » et « null refusé ».)
    static func isRefused(origin: String?) -> Bool {
        guard let origin else { return false }   // pas d'en-tête : pas un navigateur
        let value = origin.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "null" { return true }
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = String(value[..<colon])
        return Self.browserSchemes.contains(scheme) || scheme.hasSuffix("-extension")
    }

    private static let browserSchemes: Set<String> = ["http", "https", "data", "blob"]

    /// Variante historique (en-tête présent), gardée pour ses appelants.
    static func isRefusedOrigin(_ origin: String) -> Bool { isRefused(origin: origin) }

    /// C-07 (2026-10-09) — un refus était journalisé en `[error]` à CHAQUE essai :
    /// le plugin d'un Premiere refusé réessaie toutes les 2 s (~7 Mo de journal par
    /// jour). Désormais une ligne par minute et par origine, avec le compte des refus tus.
    private var refusalLog = LogThrottle()
    private func noteRefusedOrigin(_ origin: String) {
        guard let silenced = refusalLog.admit(origin) else { return }
        let more = silenced > 0 ? " (\(silenced) autre(s) refus depuis la dernière ligne)" : ""
        log.error("Connexion refusée : origine web « \(origin) » — une page internet ne peut pas piloter Khanjar\(more)")
    }

    /// Journalise UNE fois l'origine annoncée par un client accepté : c'est la
    /// preuve empirique de ce qu'envoie le plugin UXP (à confirmer en vrai).
    private var loggedOrigins = Set<String>()
    private func noteClientOrigin(_ origin: String?) {
        let key = origin ?? "(aucune)"
        guard loggedOrigins.insert(key).inserted else { return }
        log.info("Client WebSocket accepté — origine annoncée : \(key)")
    }

    /// Connexions ouvertes qui n'ont pas (encore) dit hello. Tenues ici pour être
    /// fermées à coup sûr (C-06) : refusées, muettes ou en échec.
    private var unidentified: [ObjectIdentifier: NWConnection] = [:]
    /// Une connexion sans hello valide au bout de ce délai est fermée. Le plugin
    /// envoie son hello dans le même rappel que l'ouverture (wsClient.js, onopen).
    static let helloDeadline: TimeInterval = 10
    /// Une session qui a donné signe de vie depuis moins que ça n'est pas
    /// remplacée par un nouveau hello (C-19). Le plugin bat toutes les 5 s.
    static let liveSessionWindow: TimeInterval = 10
    private var secondPluginLog = LogThrottle()

    private func noteRefusedSecondPlugin(_ info: HelloInfo) {
        guard let silenced = secondPluginLog.admit("second-plugin") else { return }
        let more = silenced > 0 ? " (\(silenced) autre(s) refus depuis la dernière ligne)" : ""
        log.info("Second plugin refusé (Premiere \(info.hostVersion), plugin \(info.pluginVersion)) : la session en cours bat encore — deux Premiere ouverts ?\(more)")
    }

    private func accept(_ conn: NWConnection) {
        log.debug("Connexion entrante")
        unidentified[ObjectIdentifier(conn)] = conn
        // C-06 (2026-10-09) — aucune NWConnection n'était jamais annulée : seule la
        // session était oubliée (`connection = nil`), sans `cancel()`. Chaque
        // fermeture de Premiere laissait un socket CLOSED (2 chez Isma pour 2
        // fermetures, lsof du 08/10) et CHAQUE poignée de main refusée (origine web)
        // un socket CLOSE_WAIT : 251 sockets après 300 refus (audit A6), soit le
        // plafond de 256 descripteurs d'une app → plus de reconnexion du plugin ni
        // de journal. Une page web pouvait ainsi rendre ⌘J muet en quelques
        // secondes. Désormais : toute connexion en échec est annulée, la session
        // aussi quand elle tombe, et une connexion muette est fermée au bout de 10 s.
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed(let error):
                if self.connection === conn {
                    self.dropSession(reason: "connexion en échec : \(error)")
                } else {
                    conn.cancel()   // poignée de main refusée, ou connexion hors session
                }
            case .cancelled:
                self.unidentified.removeValue(forKey: ObjectIdentifier(conn))
                if self.connection === conn { self.dropSession(reason: "connexion fermée") }
            default: break
            }
        }
        receiveLoop(conn)
        conn.start(queue: .main)
        // La session ne devient active qu'au hello valide.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloDeadline) { [weak self, weak conn] in
            guard let self, let conn, self.unidentified[ObjectIdentifier(conn)] != nil else { return }
            self.log.info("Connexion sans hello depuis \(Int(Self.helloDeadline)) s — fermée")
            conn.cancel()
        }
    }

    private func dropSession(reason: String) {
        guard let conn = connection else { return }
        log.info("Session plugin terminée (\(reason))")
        connection = nil
        hello = nil
        conn.cancel()   // C-06 : sans ça, le socket de la session restait ouvert
        failPendingRequests()
        onDisconnect?()
    }

    /// Les requêtes en attente sur une session qui s'en va n'auront jamais de
    /// réponse (une réponse n'est acceptée que de la session en cours).
    private func failPendingRequests() {
        let waiting = pending
        pending.removeAll()
        for (_, entry) in waiting {
            entry.timer.cancel()
            entry.completion(.failure(.pluginDisconnected))
        }
    }

    // MARK: - Réception

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn else { return }
            if let data, let text = String(data: data, encoding: .utf8),
               let json = JSONText.decode(text) {
                self.route(json, from: conn)
            }
            if error == nil {
                self.receiveLoop(conn)
            } else if self.connection === conn {
                self.dropSession(reason: "erreur de réception")
            } else {
                conn.cancel()   // C-06 : connexion hors session (refusée, remplacée…)
            }
        }
    }

    private func route(_ json: [String: Any], from conn: NWConnection) {
        // Tout message de la session prouve qu'elle vit (C-19) : battement, réponse…
        if conn === connection { lastHeartbeat = Date() }
        switch json["kind"] as? String {
        case "event":
            routeEvent(json, from: conn)
        case "res":
            routeResponse(json, from: conn)
        default:
            log.debug("Message ignoré (kind inconnu)")
        }
    }

    private func routeEvent(_ json: [String: Any], from conn: NWConnection) {
        switch json["type"] as? String {
        case "hello":
            if let info = HelloInfo(json: json), info.pluginId == Bridge.legacyPluginId {
                if !legacyPluginSeen {
                    legacyPluginSeen = true
                    log.info("Ancien plugin Dagger détecté (\(info.pluginVersion)) — refusé, retrait demandé")
                    onLegacyPlugin?()
                }
                conn.cancel()
                return
            }
            guard let info = HelloInfo(json: json), info.pluginId == Bridge.expectedPluginId else {
                log.error("hello invalide ou plugin inattendu — connexion refusée")
                conn.cancel()
                return
            }
            if let previous = connection, previous !== conn {
                // C-19 (2026-10-09) — tout nouveau hello remplaçait la session, sans
                // condition. Deux Premiere ouverts (2025 et 2026 : le manifeste accepte
                // les deux) se volaient la session toutes les 2 s, et un ⌘J pouvait
                // appliquer l'effet dans l'AUTRE Premiere avec un HUD de succès. Une
                // session qui a donné signe de vie depuis moins de 10 s est gardée ; le
                // nouveau venu est refusé. Un rechargement normal du plugin ferme
                // l'ancienne connexion (session tombée → hello accepté aussitôt) ; si
                // elle reste à demi ouverte, le nouveau hello passe au plus tard ~10 s
                // + 2 s de reconnexion après le dernier battement.
                let silence = Date().timeIntervalSince(lastHeartbeat)
                if silence < Self.liveSessionWindow {
                    noteRefusedSecondPlugin(info)
                    conn.cancel()
                    return
                }
                log.info("Nouvelle session : remplacement de la précédente (muette depuis \(Int(silence)) s)")
                previous.cancel()
                failPendingRequests()
            }
            unidentified.removeValue(forKey: ObjectIdentifier(conn))   // devient la session
            connection = conn
            hello = info
            lastHeartbeat = Date()
            log.info("hello : \(info.pluginId) \(info.pluginVersion) — \(info.hostApp) \(info.hostVersion) (\(info.uiLocale))")
            onHello?(info)
        case "hb":
            if conn === connection { lastHeartbeat = Date() }
        case "log":
            if let line = json["line"] as? String { log.debug("[plugin] \(line)") }
        default:
            break
        }
    }

    private func routeResponse(_ json: [String: Any], from conn: NWConnection) {
        guard conn === connection, let id = json["id"] as? String else { return }
        guard let entry = pending.removeValue(forKey: id) else {
            // C-02 (2026-10-09) — une réponse arrivée après le délai était jetée sans
            // trace. Or un `apply` tardif a bel et bien posé ses effets.
            if let cmd = expiredRequests.removeValue(forKey: id) {
                let ok = json["ok"] as? Bool == true
                log.error("Réponse tardive de \(cmd) (\(ok ? "succès" : "échec")) arrivée après le délai — ignorée ; Premiere a pu appliquer quand même")
            }
            return
        }
        entry.timer.cancel()
        if json["ok"] as? Bool == true {
            entry.completion(.success(json["result"] as? [String: Any] ?? [:]))
        } else if let error = json["error"] as? [String: Any],
                  let code = error["code"] as? String {
            entry.completion(.failure(.remote(code: code, message: error["message"] as? String ?? "")))
        } else {
            entry.completion(.failure(.malformed))
        }
    }

    // MARK: - Émission

    /// Requêtes abandonnées au délai (id → commande), pour tracer une réponse
    /// tardive au lieu de la jeter en silence. Bornée.
    private var expiredRequests: [String: String] = [:]

    /// Envoie une requête au plugin. `completion` est appelée UNE fois, sur le fil
    /// principal : réponse, délai, échec d'envoi ou déconnexion.
    ///
    /// C-02 (2026-10-09, contrat §4.1 du plan) — au délai, l'app libérait son
    /// verrou et disait « réessaie » pendant que Premiere appliquait encore : la
    /// réponse tardive était jetée, et le nouvel essai posait les effets EN DOUBLE
    /// (vécu les 07/07 et 11/07). Désormais :
    ///  - sans `onSlow` : comportement historique, échec `.timeout` à `timeout` ;
    ///  - avec `onSlow` ET `hardTimeout` > `timeout` : à `timeout`, `onSlow` est
    ///    appelé une fois et la requête RESTE en attente ; la réponse tardive est
    ///    livrée normalement ; échec `.timeout` seulement à `hardTimeout` (compté
    ///    depuis l'envoi). Une déconnexion libère toujours aussitôt.
    func request(cmd: String,
                 payload: [String: Any] = [:],
                 timeout: TimeInterval,
                 onSlow: (() -> Void)? = nil,
                 hardTimeout: TimeInterval? = nil,
                 completion: @escaping (Result<[String: Any], BridgeError>) -> Void) {
        guard let conn = connection, hello != nil else {
            completion(.failure(.pluginDisconnected))
            return
        }
        let id = UUID().uuidString
        var message: [String: Any] = ["v": Bridge.protocolVersion, "kind": "req", "id": id, "cmd": cmd]
        for (key, value) in payload { message[key] = value }
        guard let text = JSONText.encode(message) else {
            completion(.failure(.malformed))
            return
        }

        let sentAt = DispatchTime.now()
        let hard = hardTimeout.flatMap { onSlow != nil && $0 > timeout ? $0 : nil }
        var slowAnnounced = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: sentAt + timeout)
        timer.setEventHandler { [weak self] in
            guard let self, let entry = self.pending[id] else { return }
            if let hard, !slowAnnounced {
                slowAnnounced = true
                self.log.info("\(cmd) lent : pas de réponse après \(Int(timeout * 1000)) ms — attente jusqu'à \(Int(hard)) s")
                entry.timer.schedule(deadline: sentAt + hard)
                onSlow?()
                return
            }
            self.pending.removeValue(forKey: id)
            entry.timer.cancel()
            self.log.error("Timeout \(cmd) (\(Int((hard ?? timeout) * 1000)) ms)")
            if self.expiredRequests.count >= 20 { self.expiredRequests.removeAll() }
            self.expiredRequests[id] = cmd
            entry.completion(.failure(.timeout))
        }
        pending[id] = (timer, completion)
        timer.resume()

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        conn.send(content: text.data(using: .utf8),
                  contentContext: context,
                  isComplete: true,
                  completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.error("Envoi \(cmd) en échec : \(error)")
                if let entry = self?.pending.removeValue(forKey: id) {
                    entry.timer.cancel()
                    entry.completion(.failure(.pluginDisconnected))
                }
            }
        })
    }
}

/// Événement répété (refus d'origine, second plugin…) : au plus une ligne par
/// intervalle et par clé, avec le nombre d'occurrences tues entre-temps (C-07).
struct LogThrottle {
    let interval: TimeInterval
    private var entries: [String: (at: Date, silenced: Int)] = [:]

    init(interval: TimeInterval = 60) { self.interval = interval }

    /// nil = se taire ; sinon, le nombre d'occurrences tues depuis la dernière ligne.
    mutating func admit(_ key: String, now: Date = Date()) -> Int? {
        if let entry = entries[key], now.timeIntervalSince(entry.at) < interval {
            entries[key] = (entry.at, entry.silenced + 1)
            return nil
        }
        let silenced = entries[key]?.silenced ?? 0
        // Borne : une page peut varier ses sous-domaines, la table ne doit pas grossir sans fin.
        if entries.count > 200 { entries = entries.filter { now.timeIntervalSince($0.value.at) < interval } }
        entries[key] = (now, 0)
        return silenced
    }
}
