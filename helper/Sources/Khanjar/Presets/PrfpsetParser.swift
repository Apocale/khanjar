import Foundation

/// Parser des fichiers `.prfpset` (XML `PremiereData`, schéma relevé sur
/// Premiere 26.0 — voir docs/ARCHITECTURE.md §5.2 et l'inspection du
/// 2026-07-07) :
///
///   BinTreeItem (dossier)  TreeItemBase{Name}, Items[ObjectRef]
///   TreeItem (feuille)     TreeItemBase{Name = nom du preset, Data→FilterPresetItem}
///                          Properties{MZ.EffectPresets.PresetUID = GUID stable}
///   FilterPresetItem       FilterPresets[FilterPreset ObjectRef, ordonnés par Index]
///   FilterPreset (déf)     FilterMatchName, Component→(Video|Audio)FilterComponent
///   *FilterComponent       Component{DisplayName, Params[ObjectRef], InstanceName}
///
/// Tolérant : un objet illisible est ignoré (jamais d'exception au-delà du
/// chargement du document) — un fichier corrompu ne doit jamais faire tomber
/// l'index entier.

/// Keyframe extrait : temps RELATIF au point d'ancrage du preset (le premier
/// champ des entrées <Keyframes> est en ticks absolus de capture ; constaté :
/// premier keyframe == AnchorInPoint → offset = t - AnchorInPoint).
/// Format d'une entrée : "ticks,valeur,modeInterp,?,?,easeIn…" (séparées par ;)
struct PresetKeyframe {
    let offsetTicks: Int64
    let value: Double?          // keyframe numérique
    let pointX: Double?         // keyframe de point (Transform Position, etc.)
    let pointY: Double?
    let interpolationMode: Int
    /// Ease temporelle (modèle After Effects, décodée le 2026-07-21 — voir
    /// docs/RECHERCHE-FIDELITE-NATIVE.md §2). Vitesse en unités/s, influence en
    /// fraction 0–1, par côté. Permet de reconstruire la COURBE (le mode bézier
    /// seul ne courbe rien — UXP n'a pas d'API de poignées ; on la « cuit » en
    /// keyframes linéaires denses côté plugin).
    let inVelocity: Double
    let inInfluence: Double
    let outVelocity: Double
    let outInfluence: Double
    /// Tangentes spatiales d'un keyframe de POINT (offsets relatifs à la
    /// position, coords normalisées). Réservé au chemin courbe (non encore
    /// cuit ; les presets « slide/appear » ont un chemin axial → négligeable).
    let inTanX: Double?
    let inTanY: Double?
    let outTanX: Double?
    let outTanY: Double?
}

/// Paramètre extrait, dans l'ORDRE de la liste Params du composant —
/// cet ordre correspond à l'index zéro-based de `Component.getParam(i)` côté
/// UXP (même définition d'effet des deux côtés ; vérifié par nom à l'application).
struct PresetParam {
    let index: Int
    let name: String
    let parameterID: String
    let controlType: Int
    let isTimeVarying: Bool
    /// Valeur authorée = 2ᵉ champ de StartKeyframe (l'échelle interne attendue
    /// par createKeyframe/setValue), et NON CurrentValue qui est souvent
    /// obsolète (=0) — constaté empiriquement le 2026-07-07 sur Drop Shadow /
    /// Roughen Edges (Scale/Complexity/Edge Type/Direction). Fallback CurrentValue.
    let authoredValueRaw: String
    let isArb: Bool // ArbVideoComponentParam etc. : non rejouable par l'API (voir ArbDecoding)
    let keyframes: [PresetKeyframe]
    /// Pour un Arb de Lumetri : true = à son état neutre (le preset ne s'en sert pas),
    /// false = utilisé (courbe, roue, LUT…), nil = inconnu ou sans objet.
    var arbNeutral: Bool? = nil
}

struct PresetEffect {
    let matchName: String
    let displayName: String
    /// "video" | "audio" | "unknown" (déduit du nom d'élément du composant)
    let kind: String
    let paramCount: Int
    /// Paramètres opaques (ArbVideoComponentParam…) : non rejouables → fidélité partielle
    let arbParamCount: Int
    /// Masques/formes attachés à l'effet (SubComponent) dont le tracé n'est PAS vide.
    /// L'API ne permet pas de les recréer : appliquer l'effet sans son masque produit
    /// un résultat FAUX (un flou de vignette devient un flou plein cadre). Un masque à
    /// 0 sommet ne change pas l'image et n'est pas compté (ArbDecoding.maskVertexCount).
    let maskCount: Int
    let params: [PresetParam]
    /// Mode d'ancrage du preset (<Type>) — mapping VÉRIFIÉ empiriquement le
    /// 2026-07-20 sur les noms de presets (« Slide UP (OUT) » = 2, etc.) :
    ///   0 = Échelle (keyframes étirés à la durée du clip cible — défaut Adobe)
    ///   1 = Ancré au point d'entrée (offsets absolus depuis l'entrée)
    ///   2 = Ancré au point de sortie (offsets collés à la FIN du clip)
    let anchorType: Int
    /// Durée du clip source au moment de l'enregistrement (AnchorOut − AnchorIn),
    /// nécessaire pour Échelle (facteur) et Sortie (distance à la fin).
    let srcDurationTicks: Int64
}

extension PresetEffect {
    /// Copie sous un autre matchName (alias d'effet renommé par Adobe) ;
    /// paramètres, ancrage et compteurs conservés tels quels.
    func renamed(to matchName: String) -> PresetEffect {
        PresetEffect(matchName: matchName, displayName: displayName, kind: kind,
                     paramCount: paramCount, arbParamCount: arbParamCount, maskCount: maskCount,
                     params: params, anchorType: anchorType, srcDurationTicks: srcDurationTicks)
    }
}

struct ParsedPreset {
    /// GUID stable (MZ.EffectPresets.PresetUID), sinon "obj:<ObjectID>"
    let uid: String
    let name: String
    /// Chemin de dossiers dans le panneau Effets (racine "Root" exclue)
    let binPath: [String]
    let effects: [PresetEffect]

    var isVideoOnly: Bool { effects.allSatisfy { $0.kind == "video" } }
    var arbParamCount: Int { effects.reduce(0) { $0 + $1.arbParamCount } }
}

enum PrfpsetParseError: Error {
    case unreadable(String)
}

enum PrfpsetParser {

    static func parse(fileURL: URL) throws -> [ParsedPreset] {
        let doc: XMLDocument
        do {
            // Ne JAMAIS charger d'entités externes (défense XXE : un .prfpset est
            // du contenu potentiellement non fiable partagé entre utilisateurs).
            doc = try XMLDocument(contentsOf: fileURL, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw PrfpsetParseError.unreadable("\(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        guard let root = doc.rootElement() else { return [] }

        // Index global ObjectID → élément (le fichier est un graphe par références)
        var byId: [String: XMLElement] = [:]
        indexObjects(root, into: &byId)

        // Racines de l'arborescence : BinTreeItem jamais référencés comme enfants
        var childRefs = Set<String>()
        for element in byId.values where element.name == "BinTreeItem" {
            for ref in itemRefs(of: element) { childRefs.insert(ref) }
        }
        let roots = byId.values.filter { $0.name == "BinTreeItem" && !childRefs.contains(objectId(of: $0) ?? "") }

        var presets: [ParsedPreset] = []
        var visited = Set<String>()
        for rootBin in roots {
            walkBin(rootBin, path: [], byId: byId, visited: &visited, into: &presets)
        }
        return presets
    }

    // MARK: - Parcours de l'arbre

    private static func walkBin(_ bin: XMLElement, path: [String], byId: [String: XMLElement],
                                visited: inout Set<String>, into presets: inout [ParsedPreset]) {
        // Un fichier abîmé ou fabriqué (dossier qui se contient lui-même) ferait boucler
        // la récursion jusqu'au plantage, à chaque reconstruction de l'index.
        if let oid = objectId(of: bin) {
            guard visited.insert(oid).inserted else { return }
        }
        let name = treeItemName(of: bin)
        // La racine s'appelle "Root" : exclue du chemin utilisateur
        let childPath = (path.isEmpty && name == "Root") ? [] : path + [name].compactMap { $0 }

        for ref in itemRefs(of: bin) {
            guard let child = byId[ref] else { continue }
            switch child.name {
            case "BinTreeItem":
                walkBin(child, path: childPath, byId: byId, visited: &visited, into: &presets)
            case "TreeItem":
                if let preset = parseLeaf(child, path: childPath, byId: byId) {
                    presets.append(preset)
                }
            default:
                break
            }
        }
    }

    private static func parseLeaf(_ leaf: XMLElement, path: [String], byId: [String: XMLElement]) -> ParsedPreset? {
        guard let base = firstDescendant(leaf, named: "TreeItemBase"),
              let name = childText(base, "Name"),
              let dataRef = firstDescendant(base, named: "Data")?.attribute(forName: "ObjectRef")?.stringValue,
              let presetItem = byId[dataRef], presetItem.name == "FilterPresetItem" else { return nil }

        let uid = firstDescendant(leaf, named: "MZ.EffectPresets.PresetUID")?.stringValue
            ?? "obj:\(objectId(of: presetItem) ?? "?")"

        // Deux schémas observés :
        //  - FilterPresetItem Version=2 (profil utilisateur) : conteneur
        //    <FilterPresets> avec refs ordonnées par Index (multi-effets) ;
        //  - FilterPresetItem Version=1 (presets Adobe du bundle) : une ref
        //    directe <FilterPreset ObjectRef="…"/> sans conteneur.
        var effectDefs: [(index: Int, element: XMLElement)] = []
        if let container = firstDescendant(presetItem, named: "FilterPresets") {
            for case let ref as XMLElement in container.children ?? [] where ref.name == "FilterPreset" {
                guard let objectRef = ref.attribute(forName: "ObjectRef")?.stringValue,
                      let def = byId[objectRef] else { continue }
                let index = Int(ref.attribute(forName: "Index")?.stringValue ?? "") ?? effectDefs.count
                effectDefs.append((index, def))
            }
        } else {
            for case let ref as XMLElement in presetItem.children ?? [] where ref.name == "FilterPreset" {
                guard let objectRef = ref.attribute(forName: "ObjectRef")?.stringValue,
                      let def = byId[objectRef] else { continue }
                effectDefs.append((effectDefs.count, def))
            }
        }
        effectDefs.sort { $0.index < $1.index }

        let effects = effectDefs.compactMap { parseEffectDef($0.element, byId: byId) }
        guard !effects.isEmpty else { return nil }

        return ParsedPreset(uid: uid, name: name, binPath: path, effects: effects)
    }

    /// "t,v,mode,flags,inVel,inInf,outVel,outInf[,sMode,sFlags,inTanX,inTanY,outTanX,outTanY];…"
    /// → keyframes relatifs à l'ancre. La valeur (champ 1) est soit numérique
    /// (8 champs), soit un point "x:y" (14 champs, avec tangentes spatiales).
    /// Layout décodé le 2026-07-21 (docs/RECHERCHE-FIDELITE-NATIVE.md §2).
    private static func parseKeyframes(_ raw: String, anchorTicks: Int64) -> [PresetKeyframe] {
        raw.split(separator: ";").compactMap { entry in
            let f = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard f.count >= 2, let ticks = Int64(f[0]) else { return nil }
            // Offset SIGNÉ : un keyframe peut précéder l'ancre (il façonne la
            // rampe d'entrée) — le clamper à 0 écrasait plusieurs keyframes
            // sur le même tick (P4, revue 2026-07-20).
            let offset = ticks - anchorTicks
            let mode = f.count >= 3 ? (Int(f[2]) ?? 0) : 0
            let num = { (i: Int) -> Double in i < f.count ? (Double(f[i]) ?? 0) : 0 }
            // Champs d'ease communs aux deux formats (4=inVel,5=inInf,6=outVel,7=outInf).
            let inVel = num(4), inInf = num(5), outVel = num(6), outInf = num(7)
            let rawVal = f[1]
            if let v = Double(rawVal) {
                return PresetKeyframe(offsetTicks: offset, value: v, pointX: nil, pointY: nil,
                                      interpolationMode: mode,
                                      inVelocity: inVel, inInfluence: inInf,
                                      outVelocity: outVel, outInfluence: outInf,
                                      inTanX: nil, inTanY: nil, outTanX: nil, outTanY: nil)
            }
            let parts = rawVal.split(separator: ":")
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                // Format point : tangentes spatiales en champs 10–13.
                let hasTan = f.count >= 14
                return PresetKeyframe(offsetTicks: offset, value: nil, pointX: x, pointY: y,
                                      interpolationMode: mode,
                                      inVelocity: inVel, inInfluence: inInf,
                                      outVelocity: outVel, outInfluence: outInf,
                                      inTanX: hasTan ? num(10) : nil, inTanY: hasTan ? num(11) : nil,
                                      outTanX: hasTan ? num(12) : nil, outTanY: hasTan ? num(13) : nil)
            }
            return nil // couleur/valeur non gérée en keyframe pour l'instant
        }
    }

    private static func parseEffectDef(_ def: XMLElement, byId: [String: XMLElement]) -> PresetEffect? {
        guard let matchName = childText(def, "FilterMatchName"), !matchName.isEmpty else { return nil }
        let anchorTicks = Int64(childText(def, "AnchorInPoint") ?? "") ?? 0
        let anchorOutTicks = Int64(childText(def, "AnchorOutPoint") ?? "") ?? anchorTicks
        let anchorType = Int(childText(def, "Type") ?? "") ?? 1
        let srcDurationTicks = max(0, anchorOutTicks - anchorTicks)

        var displayName = matchName
        var kind = "unknown"
        var params: [PresetParam] = []
        var maskCount = 0

        if let componentRef = firstDescendant(def, named: "Component")?.attribute(forName: "ObjectRef")?.stringValue,
           let component = byId[componentRef] {
            switch component.name {
            case "VideoFilterComponent": kind = "video"
            case "AudioFilterComponent": kind = "audio"
            default: break
            }
            // Masques attachés (formes de vignette, caches…) : non recréables par API.
            // Seuls comptent ceux qui ont une forme (2026-10-07 : les deux « Drop Shadow
            // Preset » d'Isma portaient un masque VIDE et étaient exclus à tort).
            let subComponents = ((try? component.nodes(forXPath: ".//SubComponent")) ?? []).compactMap { $0 as? XMLElement }
            maskCount = subComponents.filter { sub in
                guard let ref = sub.attribute(forName: "ObjectRef")?.stringValue, let mask = byId[ref] else { return true }
                return !isEmptyMask(mask, byId: byId)
            }.count
            if let dn = firstDescendant(component, named: "DisplayName")?.stringValue, !dn.isEmpty {
                displayName = dn
            }
            if let paramsContainer = firstDescendant(component, named: "Params") {
                var ordered: [(Int, XMLElement)] = []
                for case let param as XMLElement in paramsContainer.children ?? [] where param.name == "Param" {
                    guard let ref = param.attribute(forName: "ObjectRef")?.stringValue,
                          let element = byId[ref] else { continue }
                    let index = Int(param.attribute(forName: "Index")?.stringValue ?? "") ?? ordered.count
                    ordered.append((index, element))
                }
                ordered.sort { $0.0 < $1.0 }
                params = ordered.map { index, element in
                    let isTimeVarying = firstDescendant(element, named: "IsTimeVarying")?.stringValue == "true"
                    let keyframesRaw = firstDescendant(element, named: "Keyframes")?.stringValue ?? ""
                    // Valeur authorée : 2ᵉ champ de StartKeyframe (échelle interne),
                    // fallback CurrentValue si StartKeyframe absent/vide.
                    let startKf = firstDescendant(element, named: "StartKeyframe")?.stringValue ?? ""
                    let startValue = startKf.split(separator: ",").dropFirst().first.map(String.init) ?? ""
                    let currentValue = firstDescendant(element, named: "CurrentValue")?.stringValue ?? ""
                    let authored = startValue.isEmpty ? currentValue : startValue
                    let isArb = element.name?.hasPrefix("Arb") == true
                    var arbNeutral: Bool? = nil
                    if isArb, matchName.contains("Lumetri"),
                       let pid = Int(firstDescendant(element, named: "ParameterID")?.stringValue ?? ""),
                       let bytes = ArbDecoding.bytes(fromBase64: firstDescendant(element, named: "StartKeyframeValue")?.stringValue) {
                        // Un Arb animé n'est jamais considéré neutre.
                        arbNeutral = isTimeVarying ? false : ArbDecoding.isNeutralLumetriArb(parameterID: pid, bytes: bytes)
                    }
                    return PresetParam(
                        index: index,
                        name: firstDescendant(element, named: "Name")?.stringValue ?? "",
                        parameterID: firstDescendant(element, named: "ParameterID")?.stringValue ?? "",
                        controlType: Int(firstDescendant(element, named: "ParameterControlType")?.stringValue ?? "") ?? -1,
                        isTimeVarying: isTimeVarying,
                        authoredValueRaw: authored,
                        isArb: isArb,
                        keyframes: isTimeVarying ? parseKeyframes(keyframesRaw, anchorTicks: anchorTicks) : [],
                        arbNeutral: arbNeutral
                    )
                }
            }
        }
        return PresetEffect(matchName: matchName, displayName: displayName,
                            kind: kind, paramCount: params.count,
                            arbParamCount: params.filter(\.isArb).count,
                            maskCount: maskCount,
                            params: params,
                            anchorType: anchorType,
                            srcDurationTicks: srcDurationTicks)
    }

    /// Masque sans forme : son tracé (Arb « 2cin » pour AE.ADBE AEMask, pid 7 pour
    /// AEMask2) a 0 sommet et n'est pas animé. Format inconnu → considéré NON vide.
    private static func isEmptyMask(_ mask: XMLElement, byId: [String: XMLElement]) -> Bool {
        guard let matchName = childText(mask, "MatchName"), matchName.contains("Mask"),
              let params = firstDescendant(mask, named: "Params") else { return false }
        for case let param as XMLElement in params.children ?? [] where param.name == "Param" {
            guard let ref = param.attribute(forName: "ObjectRef")?.stringValue, let element = byId[ref],
                  element.name?.hasPrefix("Arb") == true,
                  let bytes = ArbDecoding.bytes(fromBase64: firstDescendant(element, named: "StartKeyframeValue")?.stringValue) else { continue }
            let pid = firstDescendant(element, named: "ParameterID")?.stringValue
            let isPath = bytes.starts(with: Array("2cin".utf8)) || (matchName == "AE.ADBE AEMask2" && pid == "7")
            guard isPath else { continue }
            if firstDescendant(element, named: "IsTimeVarying")?.stringValue == "true" { return false }
            return ArbDecoding.maskVertexCount(bytes) == 0
        }
        return false
    }

    // MARK: - Aides XML

    private static func indexObjects(_ element: XMLElement, into byId: inout [String: XMLElement]) {
        if let oid = element.attribute(forName: "ObjectID")?.stringValue {
            byId[oid] = element
        }
        for case let child as XMLElement in element.children ?? [] {
            indexObjects(child, into: &byId)
        }
    }

    private static func objectId(of element: XMLElement) -> String? {
        element.attribute(forName: "ObjectID")?.stringValue
    }

    private static func itemRefs(of bin: XMLElement) -> [String] {
        guard let items = firstDescendant(bin, named: "Items") else { return [] }
        var refs: [(Int, String)] = []
        for case let item as XMLElement in items.children ?? [] where item.name == "Item" {
            guard let ref = item.attribute(forName: "ObjectRef")?.stringValue else { continue }
            let index = Int(item.attribute(forName: "Index")?.stringValue ?? "") ?? refs.count
            refs.append((index, ref))
        }
        return refs.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    private static func treeItemName(of element: XMLElement) -> String? {
        guard let base = firstDescendant(element, named: "TreeItemBase") else { return nil }
        return childText(base, "Name")
    }

    private static func childText(_ element: XMLElement, _ name: String) -> String? {
        firstDescendant(element, named: name)?.stringValue
    }

    /// Premier descendant portant ce nom — sans traverser d'autres objets
    /// référencés (le graphe est plat : les objets sont frères sous la racine,
    /// donc une recherche bornée en profondeur reste locale à l'objet).
    private static func firstDescendant(_ element: XMLElement, named name: String, depth: Int = 0) -> XMLElement? {
        if depth > 6 { return nil }
        for case let child as XMLElement in element.children ?? [] {
            if child.name == name { return child }
            if let found = firstDescendant(child, named: name, depth: depth + 1) { return found }
        }
        return nil
    }
}
