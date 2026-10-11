import Foundation

/// État du plugin tel que le monteur le voit : 2ᵉ ligne du menu, fenêtre d'accueil,
/// Réglages, et message de ⌘J quand le plugin n'est pas en service.
///
/// C-05 (2026-10-09) — l'accueil restait sur « En attente de Premiere… » même
/// Premiere ouvert et après le hello ; ⌘J disait « se reconnecte » à un plugin
/// JAMAIS connecté ; un échec d'installation n'apparaissait nulle part. Un seul
/// état, calculé à partir des faits (pas une variable qu'on oublie de mettre à
/// jour), alimenté par la chaîne d'installation de C-01.
enum PluginStatus: Equatable {
    case premiereClosed
    /// Premiere ouvert, pas encore de hello depuis son lancement (S7).
    case connecting
    /// Premiere ouvert, le plugin s'était connecté puis la session est tombée.
    case reconnecting
    /// UPIA installe ou met à niveau le plugin.
    case installing
    case issue(PluginInstallIssue)
    case connected(premiere: String, plugin: String)

    struct Facts {
        /// Versions annoncées par le hello d'une session EN COURS, sinon nil.
        var connected: (premiere: String, plugin: String)?
        var premiereRunning: Bool
        var installing: Bool
        var issue: PluginInstallIssue?
        /// Un hello a eu lieu depuis le lancement de ce Premiere.
        var hadSession: Bool
    }

    static func current(_ facts: Facts) -> PluginStatus {
        if let connected = facts.connected { return .connected(premiere: connected.premiere, plugin: connected.plugin) }
        guard facts.premiereRunning else { return .premiereClosed }
        if facts.installing { return .installing }
        if let issue = facts.issue { return .issue(issue) }
        return facts.hadSession ? .reconnecting : .connecting
    }

    /// 2ᵉ ligne du menu, accueil, Réglages. « Connected — Premiere … · plugin … »
    /// est gardé tel quel : les guides le citent.
    var statusLine: String {
        switch self {
        case .premiereClosed: return L("Waiting for Premiere…")
        case .connecting: return L("Connecting to Premiere…")
        case .reconnecting: return L("Khanjar is reconnecting to Premiere…")
        case .installing: return L("Installing the Khanjar plugin in Premiere…")
        case .issue(let issue):
            switch issue {
            case .creativeCloudMissing: return L("Creative Cloud is required to install the Khanjar plugin")
            case .premiereTooOld(let version): return LF("Premiere %@ is too old for Khanjar (25.6 or later needed)", version)
            case .installFailed: return L("Plugin not installed — see the log")
            case .restartNeeded: return L("Restart Premiere to finish installing the plugin")
            case .loadedButMute: return L("The plugin is running but can't reach Khanjar — open the log")
            }
        case .connected(let premiere, let plugin): return LF("Connected — Premiere %@ · plugin %@", premiere, plugin)
        }
    }

    /// Message de ⌘J quand le plugin n'est pas en service : ce qu'il faut faire.
    var summonMessage: String {
        switch self {
        case .premiereClosed: return L("Open Premiere Pro to use Khanjar")
        case .issue(.installFailed):
            return L("The Khanjar plugin still isn't installed: open the Creative Cloud app, check you're signed in, then quit and reopen Premiere")
        case .issue(.restartNeeded(let afterUpgrade)):
            return afterUpgrade ? L("Plugin updated — quit and reopen Premiere to use the new version")
                                : L("Plugin installed — quit and reopen Premiere to finish")
        default: return statusLine
        }
    }

    /// Un message qui demande un geste au monteur : affiché plus longtemps.
    var needsAction: Bool {
        if case .issue = self { return true }
        return false
    }
}
