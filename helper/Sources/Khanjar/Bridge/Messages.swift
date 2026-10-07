import Foundation

/// Types du protocole Bridge v1 (docs/PROTOCOL.md).
/// Les payloads hétérogènes circulent en `[String: Any]` (JSONSerialization) ;
/// seuls les invariants du protocole sont typés fortement.

enum Bridge {
    static let protocolVersion = 1
    static let expectedPluginId = "io.khanjar.executor"
    /// Identifiant de l'ancien plugin, avant le renommage Dagger → Khanjar.
    static let legacyPluginId = "com.dagger.executor"
    static let defaultPort: UInt16 = 48123
}

struct HelloInfo {
    let pluginId: String
    let pluginVersion: String
    let hostApp: String
    let hostVersion: String
    let uiLocale: String
    let capabilities: [String: Bool]

    init?(json: [String: Any]) {
        guard let plugin = json["plugin"] as? [String: Any],
              let id = plugin["id"] as? String else { return nil }
        pluginId = id
        pluginVersion = plugin["version"] as? String ?? "?"
        let host = json["host"] as? [String: Any] ?? [:]
        hostApp = host["app"] as? String ?? "?"
        hostVersion = host["version"] as? String ?? "?"
        uiLocale = host["uiLocale"] as? String ?? "?"
        capabilities = json["capabilities"] as? [String: Bool] ?? [:]
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case pluginDisconnected
    case timeout
    case remote(code: String, message: String)
    case malformed

    var description: String {
        switch self {
        case .pluginDisconnected: return "PLUGIN_DISCONNECTED"
        case .timeout: return "TIMEOUT"
        case .remote(let code, let message): return "\(code): \(message)"
        case .malformed: return "MALFORMED_RESPONSE"
        }
    }

    /// Code machine, aligné sur la taxonomie du protocole.
    var code: String {
        switch self {
        case .pluginDisconnected: return "PLUGIN_DISCONNECTED"
        case .timeout: return "TIMEOUT"
        case .remote(let code, _): return code
        case .malformed: return "MALFORMED_RESPONSE"
        }
    }
}

enum JSONText {
    static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func decode(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
