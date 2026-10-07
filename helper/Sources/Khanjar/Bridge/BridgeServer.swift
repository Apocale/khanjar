import Foundation
import Network

/// Serveur WebSocket loopback : une session plugin active à la fois,
/// corrélation requête/réponse, heartbeats, callbacks sur la main queue.
final class BridgeServer {
    private let port: UInt16
    private let log = Logger.shared
    private var listener: NWListener?

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

    var isReady: Bool { connection != nil && hello != nil }

    init(port: UInt16 = Bridge.defaultPort) {
        self.port = port
    }

    // MARK: - Démarrage

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // GARDE-FOU WEB (2026-10-06). Le port n'écoute que la boucle locale,
        // mais une PAGE WEB ouverte dans le navigateur de l'utilisateur peut
        // quand même ouvrir un WebSocket vers ws://127.0.0.1:48123 : pour les
        // WebSockets, le navigateur ne demande rien, c'est au serveur de filtrer
        // selon l'en-tête Origin. Sans ce filtre, une page pouvait se présenter
        // comme le plugin, remplacer la vraie session (⌘J muet) et lire ce que
        // l'utilisateur applique. Un navigateur envoie TOUJOURS Origin lors de
        // la poignée de main ; on refuse les origines web (http, https, et les
        // extensions de navigateur). Le plugin UXP, lui, n'est pas une page.
        wsOptions.setClientRequestHandler(.main) { [weak self] subprotocols, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            if let origin, Self.isWebOrigin(origin) {
                self?.log.error("Connexion refusée : origine web « \(origin) » — une page internet ne peut pas piloter Khanjar")
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            self?.noteClientOrigin(origin)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
        }
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log.info("Bridge en écoute sur ws://127.0.0.1:\(self?.port ?? 0)")
            case .failed(let error):
                self?.log.error("Listener en échec : \(error)")
                self?.onListenerFailed?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Origines émises par un navigateur (page web ou extension). Comparaison
    /// sur le schéma seulement : « null » (fichier local) et l'absence d'en-tête
    /// restent acceptés tant qu'on n'a pas relevé ce qu'envoie le plugin UXP.
    static func isWebOrigin(_ origin: String) -> Bool {
        let value = origin.trimmingCharacters(in: .whitespaces).lowercased()
        let webSchemes = ["http://", "https://", "chrome-extension://", "moz-extension://",
                          "safari-web-extension://", "edge-extension://"]
        return webSchemes.contains { value.hasPrefix($0) }
    }

    /// Journalise UNE fois l'origine annoncée par un client accepté : c'est la
    /// preuve empirique de ce qu'envoie le plugin UXP (à confirmer en vrai).
    private var loggedOrigins = Set<String>()
    private func noteClientOrigin(_ origin: String?) {
        let key = origin ?? "(aucune)"
        guard loggedOrigins.insert(key).inserted else { return }
        log.info("Client WebSocket accepté — origine annoncée : \(key)")
    }

    private func accept(_ conn: NWConnection) {
        log.debug("Connexion entrante")
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                if self.connection === conn { self.dropSession(reason: "connexion fermée") }
            default: break
            }
        }
        receiveLoop(conn)
        conn.start(queue: .main)
        // La session ne devient active qu'au hello valide.
    }

    private func dropSession(reason: String) {
        guard connection != nil else { return }
        log.info("Session plugin terminée (\(reason))")
        connection = nil
        hello = nil
        let waiting = pending
        pending.removeAll()
        for (_, entry) in waiting {
            entry.timer.cancel()
            entry.completion(.failure(.pluginDisconnected))
        }
        onDisconnect?()
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
            }
        }
    }

    private func route(_ json: [String: Any], from conn: NWConnection) {
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
                log.info("Nouvelle session : remplacement de la précédente")
                previous.cancel()
            }
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
        guard conn === connection,
              let id = json["id"] as? String,
              let entry = pending.removeValue(forKey: id) else { return }
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

    func request(cmd: String,
                 payload: [String: Any] = [:],
                 timeout: TimeInterval,
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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self, let entry = self.pending.removeValue(forKey: id) else { return }
            entry.timer.cancel()
            self.log.error("Timeout \(cmd) (\(Int(timeout * 1000)) ms)")
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
