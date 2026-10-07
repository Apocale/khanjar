import Foundation

/// Item de l'index de recherche (docs/ARCHITECTURE.md §5.1).
/// Codable : sérialisé tel quel dans le snapshot disque.
struct SearchItem: Codable {
    let id: String            // stable : "effect:<matchName>" | "preset:<uid>"
    let kind: String          // "effect" | "preset"
    let title: String         // nom affiché (localisé)
    let subtitle: String      // "Effet vidéo" | "Preset · <dossier>" | "Preset Adobe · <dossier>"
    let keywords: [String]    // matchNames, chemin de bin, noms d'effets du preset
    let plan: ApplyPlan
    /// "full" | "effects-only" (params rejoués en M4) — précurseur du badge UI
    let fidelityHint: String
}

extension SearchItem {
    /// Préfixe des items synthétiques « duo » (jamais dans l'index sur disque).
    static let comboPrefix = "combo:"
    var isCombo: Bool { id.hasPrefix(Self.comboPrefix) }
    /// Les deux ids membres d'un duo, dans l'ordre d'application.
    var comboMembers: (from: String, to: String)? {
        guard isCombo else { return nil }
        let parts = id.dropFirst(Self.comboPrefix.count).components(separatedBy: "|")
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Fusionne deux items en UN item applicable en une seule transaction
    /// (donc un seul Cmd+Z au lieu de deux). `first` est celui que
    /// l'utilisateur applique en PREMIER à la main.
    ///
    /// ⚠️ ORDRE — appliquer A puis B à la main laisse les effets de B
    /// AU-DESSUS de ceux de A (chaque apply insère en haut de la pile
    /// utilisateur, AGENTS.md §3.1 item 13). Les opérations d'un plan sont
    /// insérées consécutivement depuis ce même point, donc l'ordre du plan EST
    /// l'ordre d'affichage haut→bas : le plan fusionné liste **B avant A**.
    /// Vérifié contre les projets réels (2026-10-02) : sur 63 clips portant le
    /// duo flou/contour, 86 % ont le flou au-dessus — il est appliqué en dernier.
    ///
    /// Retourne nil si la fusion n'est pas sûre :
    ///  - un membre est déjà un duo (pas d'imbrication) ;
    ///  - les deux plans touchent le MÊME effet intrinsèque (Opacity, Motion…) :
    ///    leurs keyframes se mélangeraient sur le composant existant du clip au
    ///    lieu de se succéder — le résultat ne serait pas celui des deux applies ;
    ///  - le plan fusionné dépasse `maxOperations` (transaction trop lourde).
    static func combining(_ first: SearchItem, _ second: SearchItem,
                          pairCount: Int, maxOperations: Int = 12) -> SearchItem? {
        guard !first.isCombo, !second.isCombo, first.id != second.id else { return nil }
        let intrinsicsA = Set(first.plan.existingOperations.map(\.matchName))
        let intrinsicsB = Set(second.plan.existingOperations.map(\.matchName))
        guard intrinsicsA.isDisjoint(with: intrinsicsB) else { return nil }
        let operations = second.plan.operations + first.plan.operations
        guard !operations.isEmpty, operations.count <= maxOperations else { return nil }

        let a = first.title.trimmingCharacters(in: .whitespaces)
        let b = second.title.trimmingCharacters(in: .whitespaces)
        let title = LF("%@ then %@", a, b)
        var keywords = first.keywords + second.keywords + [a, b]
        keywords.append("duo")
        let partial = PaletteWindowController.partialNote(first.fidelityHint) != nil
                   || PaletteWindowController.partialNote(second.fidelityHint) != nil
        return SearchItem(
            id: "\(comboPrefix)\(first.id)|\(second.id)",
            kind: "combo",
            title: title,
            subtitle: LF("Duo · chained %ld times", pairCount),
            keywords: keywords,
            plan: ApplyPlan(label: title, operations: operations,
                            existingOperations: first.plan.existingOperations + second.plan.existingOperations),
            fidelityHint: partial ? "dropped:1" : "full"
        )
    }
}

/// Plan d'application pré-compilé (forme Codable ; convertie au format
/// protocole au moment de l'envoi — voir `protocolPayload`).
struct ApplyPlan: Codable {
    /// Valeur de paramètre rejouable (M4.1 : nombres/booléens statiques ;
    /// M4.2 : keyframes numériques — temps en ticks RELATIFS au début du clip,
    /// transmis en String pour éviter toute perte de précision).
    struct PlanKeyframe: Codable {
        let t: String   // offset en ticks (Int64 sérialisé)
        var v: Double? = nil   // valeur numérique
        var px: Double? = nil  // ou point x/y (Transform Position…)
        var py: Double? = nil
        let i: Int      // mode d'interpolation Premiere (transmis tel quel)
        // Ease temporelle (vel unités/s, inf 0–1) — permet au plugin de CUIRE
        // la courbe en keyframes linéaires denses (le bézier seul ne courbe pas).
        var iv: Double? = nil  // inVelocity
        var ii: Double? = nil  // inInfluence
        var ov: Double? = nil  // outVelocity
        var oi: Double? = nil  // outInfluence
    }
    struct PlanParam: Codable {
        struct Point: Codable { let x: Double; let y: Double }
        struct ColorValue: Codable { let r: Double; let g: Double; let b: Double; let a: Double }
        let index: Int
        let name: String
        let number: Double?
        let bool: Bool?
        var point: Point? = nil
        var color: ColorValue? = nil
        var keyframes: [PlanKeyframe] = []

        var jsonValue: Any {
            if let bool { return bool }
            if let number { return number }
            if let point { return ["x": point.x, "y": point.y] }
            if let color { return ["r": color.r, "g": color.g, "b": color.b, "a": color.a] }
            return NSNull()
        }
        var jsonKeyframes: [[String: Any]] {
            keyframes.map { kf in
                var value: Any = NSNull()
                if let v = kf.v { value = v }
                else if let px = kf.px, let py = kf.py { value = ["x": px, "y": py] }
                var out: [String: Any] = ["t": kf.t, "value": value, "i": kf.i]
                // Ease : émise seulement si présente (nil = pas d'ease → linéaire).
                if let iv = kf.iv { out["iv"] = iv }
                if let ii = kf.ii { out["ii"] = ii }
                if let ov = kf.ov { out["ov"] = ov }
                if let oi = kf.oi { out["oi"] = oi }
                return out
            }
        }
    }
    struct Operation: Codable {
        let matchName: String
        var params: [PlanParam] = []
        /// Ancrage temporel des keyframes (sémantique native des presets) :
        /// 0=Échelle, 1=Entrée (défaut), 2=Sortie. srcDur = durée du clip
        /// source à l'enregistrement, en ticks (String pour la précision).
        var anchorType: Int = 1
        var srcDur: String = "0"
        /// Nombre de paramètres que l'effet avait AU MOMENT de l'enregistrement
        /// du preset. Si l'effet installé chez l'utilisateur n'en a pas autant,
        /// sa définition diffère (autre version) → les index ne sont plus
        /// fiables et le plugin refuse d'écrire à l'aveugle.
        var paramCount: Int = 0
    }
    let label: String
    /// Effets AJOUTÉS (nouveaux composants, ordre d'affichage = prfpset inversé).
    let operations: [Operation]
    /// Effets INTRINSÈQUES du preset (Opacity/Motion…) : non ajoutables, leurs
    /// params/keyframes se posent sur le composant EXISTANT du clip (ciblé par
    /// matchName). Sinon le fondu/mouvement du preset serait perdu.
    var existingOperations: [Operation] = []

    private static func jsonOps(_ ops: [Operation]) -> [[String: Any]] {
        ops.map { op in
            [
                "effect": ["matchName": op.matchName],
                "anchor": ["type": op.anchorType, "srcDur": op.srcDur],
                "paramCount": op.paramCount,
                "params": op.params.map {
                    ["index": $0.index, "name": $0.name, "value": $0.jsonValue,
                     "keyframes": $0.jsonKeyframes] as [String: Any]
                },
            ]
        }
    }

    /// Représentation protocole (PROTOCOL.md §apply).
    var protocolPayload: [String: Any] {
        [
            "label": label,
            "target": "selection",
            "operations": Self.jsonOps(operations),
            "existingOperations": Self.jsonOps(existingOperations),
        ]
    }
}

/// Snapshot disque de l'index : relu au démarrage pour une palette
/// immédiatement utilisable (le reparse se fait en arrière-plan).
struct IndexSnapshot: Codable {
    let version: Int
    let generatedAt: Date
    let premiereVersion: String
    let items: [SearchItem]

    static let currentVersion = 6 // v6 : ease temporelle des keyframes (vel/inf par côté)
}
