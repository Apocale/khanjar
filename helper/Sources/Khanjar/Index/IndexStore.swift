import Foundation

/// Construction et persistance de l'index de recherche.
/// Sources : effets (via plugin) + presets (parser prfpset).
/// v1 : items vidéo uniquement (l'application audio n'est pas exposée par UXP).
enum IndexStore {

    struct EffectEntry {
        let matchName: String
        let displayName: String
    }

    // MARK: - Construction

    static func build(effects: [EffectEntry], userPresets: [ParsedPreset], factoryPresets: [ParsedPreset]) -> [SearchItem] {
        var items: [SearchItem] = []
        items.reserveCapacity(effects.count + userPresets.count + factoryPresets.count)

        for effect in effects {
            items.append(SearchItem(
                id: "effect:\(effect.matchName)",
                kind: "effect",
                title: effect.displayName,
                subtitle: L("Video effect"),
                keywords: [effect.matchName],
                plan: ApplyPlan(label: effect.displayName,
                                operations: [.init(matchName: effect.matchName)]),
                fidelityHint: "full"
            ))
        }

        // Les opérations d'un preset sont filtrées contre l'inventaire RÉEL
        // d'effets : les composants intrinsèques (AE.ADBE Motion/Opacity/
        // Geometry, Internal Volume…) et les effets absents de cette
        // installation ne sont pas ajoutables via createComponent — constat
        // empirique 2026-07-07 (EFFECT_NOT_FOUND sur « Gaussian + Scale »).
        // M4 réglera les paramètres des intrinsèques EXISTANTS sur le clip.
        let addable = Set(effects.map(\.matchName))
        items.append(contentsOf: presetItems(userPresets, adobe: false, addable: addable))
        items.append(contentsOf: presetItems(factoryPresets, adobe: true, addable: addable))
        return items
    }

    /// Effets intrinsèques de Premiere : déjà présents sur chaque clip, non
    /// ajoutables par createComponent → leurs params se posent sur le composant
    /// existant du clip (ciblé par matchName côté plugin).
    static let intrinsicMatchNames: Set<String> = [
        "AE.ADBE Opacity", "AE.ADBE Motion", "AE.ADBE Time Remapping", "AE.ADBE MotionBlur",
        // « Vector Motion » d'un graphique/MOGRT : intrinsèque (existe déjà sur le
        // clip graphique), non ajoutable → sans lui les presets qui l'animent
        // étaient jetés en silence (dropped). Le plugin le gère déjà (TOP_INTRINSICS).
        "AE.ADBE Graphic Group",
    ]

    /// Effets RENOMMÉS ou REMPLACÉS par Adobe. Constaté au passage
    /// Premiere 26.3.2 → 26.5.1 (2026-09-19) : 54 effets retirés de l'inventaire
    /// (162 → 108) — 20 presets de l'utilisateur devenaient « partiels ».
    /// Un preset qui référence l'ancien matchName est rejoué sur le successeur
    /// quand celui-ci existe dans l'installation ; le garde-fou paramCount/nom
    /// du plugin (PARAM_STRUCTURE_MISMATCH / NAME_MISMATCH) protège contre une
    /// définition différente. Vérifié dans le prfpset : « AE.ADBE Geometry » =
    /// Transform, 12 paramètres strictement identiques à « AE.ADBE Geometry2 ».
    static let effectAliases: [String: String] = [
        "AE.ADBE Geometry": "AE.ADBE Geometry2",   // Transform (ancienne variante)
        "PR.ADBE Replicate": "AE.ADBE Replicate",  // Replicate (réimplémenté côté AE)
    ]

    /// Résout les alias contre l'inventaire réel ; retourne aussi le nombre
    /// d'effets réécrits (pour le fidelityHint « aliased:N »).
    static func resolveAliases(_ effects: [PresetEffect], addable: Set<String>) -> (effects: [PresetEffect], aliased: Int) {
        var aliased = 0
        let resolved = effects.map { effect -> PresetEffect in
            guard !addable.contains(effect.matchName),
                  let successor = effectAliases[effect.matchName],
                  addable.contains(successor) else { return effect }
            aliased += 1
            return effect.renamed(to: successor)
        }
        return (resolved, aliased)
    }

    /// Lumetri : paramètres non-Arb qu'on NE rejoue PAS, même s'ils sont lisibles.
    /// 130 = Color Space (dépend du clip : l'écraser changerait l'espace colorimétrique),
    /// 121 = progression interne de l'Auto Tone, 5/25/127/128 = menus Input LUT / Look
    /// (la LUT elle-même vit dans un Arb : l'index seul ne veut rien dire).
    static let lumetriSkippedParameterIDs: Set<String> = ["130", "121", "5", "25", "127", "128"]

    /// Un Lumetri est rejouable si TOUS ses Arb sont neutres (le preset ne fait que
    /// bouger des curseurs) et qu'aucun menu LUT/Look n'est choisi. Analyse du
    /// 2026-10-07 : 8 des 18 presets couleur d'Isma, et 88 % des Lumetri de ses projets
    /// récents, sont dans ce cas. Les presets Adobe (ancien schéma, ParameterID -1)
    /// donnent des Arb « inconnus » → exclus, ce qui est voulu (index de Look ambigus).
    static func isReplayableLumetri(_ effect: PresetEffect) -> Bool {
        guard effect.params.filter(\.isArb).allSatisfy({ $0.arbNeutral == true }) else { return false }
        return effect.params.allSatisfy { param in
            guard ["5", "25", "127", "128"].contains(param.parameterID), !param.isArb else { return true }
            return (Double(param.authoredValueRaw) ?? 0) == 0
        }
    }

    /// Compile les params rejouables d'un effet (statiques + keyframés).
    private static func compileParams(_ effect: PresetEffect,
                                      total: inout Int, compiled: inout Int) -> [ApplyPlan.PlanParam] {
        var planParams: [ApplyPlan.PlanParam] = []
        let isLumetri = effect.matchName.contains("Lumetri")
        for param in effect.params {
            // Un Arb Lumetri neutre ne porte rien : il ne compte pas comme réglage perdu
            // (sinon le badge « partiel » s'afficherait sur un preset rejoué en entier).
            if isLumetri, param.isArb, param.arbNeutral == true { continue }
            total += 1
            guard !param.isArb else { continue }
            // Lumetri : seulement les curseurs (ct 8) et les cases d'activation (ct 4),
            // jamais Color Space ni les menus LUT/Look, ni les paramètres sans nom (cachés).
            if isLumetri {
                guard [4, 8].contains(param.controlType),
                      !lumetriSkippedParameterIDs.contains(param.parameterID),
                      !param.name.trimmingCharacters(in: .whitespaces).isEmpty else { total -= 1; continue }
            }
            if param.isTimeVarying {
                guard !param.keyframes.isEmpty else { continue }
                planParams.append(.init(
                    index: param.index, name: param.name, number: nil, bool: nil,
                    keyframes: param.keyframes.map {
                        .init(t: String($0.offsetTicks), v: $0.value,
                              px: $0.pointX, py: $0.pointY, i: $0.interpolationMode,
                              iv: $0.inVelocity, ii: $0.inInfluence,
                              ov: $0.outVelocity, oi: $0.outInfluence)
                    }))
                compiled += 1
                continue
            }
            if param.controlType == 6 {
                let parts = param.authoredValueRaw.split(separator: ":")
                if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                    planParams.append(.init(index: param.index, name: param.name,
                                            number: nil, bool: nil, point: .init(x: x, y: y)))
                    compiled += 1
                }
                continue
            }
            if param.controlType == 5 {
                if let color = Self.decodePackedColor(param.authoredValueRaw) {
                    planParams.append(.init(index: param.index, name: param.name,
                                            number: nil, bool: nil, color: color))
                    compiled += 1
                }
                continue
            }
            if param.authoredValueRaw == "true" || param.authoredValueRaw == "false" {
                planParams.append(.init(index: param.index, name: param.name,
                                        number: nil, bool: param.authoredValueRaw == "true"))
                compiled += 1
            } else if let number = Double(param.authoredValueRaw) {
                planParams.append(.init(index: param.index, name: param.name,
                                        number: number, bool: nil))
                compiled += 1
            }
        }
        return planParams
    }

    /// Un preset qu'on ne peut PAS reproduire fidèlement est EXCLU de la palette
    /// plutôt qu'appliqué de travers (décision produit, 2026-08-01).
    /// Deux cas, tous deux non contournables par l'API UXP :
    ///  - MASQUE : la forme n'est pas recréable → un flou de vignette devient un
    ///    flou plein cadre. Le résultat n'est pas partiel, il est FAUX.
    ///  - COULEUR (Lumetri) qui utilise courbes, roues ou LUT : ces réglages vivent
    ///    dans des paramètres `Arb` que l'API UXP ne sait pas écrire → l'effet
    ///    s'appliquerait sans eux. Depuis le 2026-10-07, un Lumetri qui ne bouge QUE
    ///    des curseurs (tous ses Arb neutres, cf. isReplayableLumetri) n'est plus
    ///    exclu : la règle précédente (« Lumetri avec des Arb ») écartait TOUT Lumetri,
    ///    car même neutre il en porte 24.
    /// Retourne la raison si le preset doit être écarté.
    static func unreplayableReason(_ effects: [PresetEffect]) -> String? {
        if effects.contains(where: { $0.maskCount > 0 }) { return "masque" }
        if effects.contains(where: { $0.matchName.contains("Lumetri") && !isReplayableLumetri($0) }) { return "couleur" }
        return nil
    }

    /// Pourquoi un preset n'entre PAS dans la palette (nil = il y entre).
    /// Même logique que `presetItems`, exposée pour le diagnostic `index-excluded`.
    static func exclusionReason(_ preset: ParsedPreset, addable: Set<String>) -> String? {
        let videoEffects = preset.effects.filter { $0.kind == "video" }
        if videoEffects.isEmpty { return preset.effects.isEmpty ? "vide" : "audio seul" }
        if let reason = unreplayableReason(videoEffects) { return reason }
        let (resolved, _) = resolveAliases(videoEffects, addable: addable)
        let usable = resolved.contains { addable.contains($0.matchName) || intrinsicMatchNames.contains($0.matchName) }
        return usable ? nil : "effets absents"
    }

    private static func presetItems(_ presets: [ParsedPreset], adobe: Bool, addable: Set<String>) -> [SearchItem] {
        presets.compactMap { preset in
            let videoEffects = preset.effects.filter { $0.kind == "video" }
            // Écarté si non reproductible fidèlement (masque / couleur Lumetri).
            if let reason = unreplayableReason(videoEffects) {
                Logger.shared.debug("Preset écarté (\(reason)) : \(preset.name)")
                return nil
            }
            // Effets renommés par Adobe → successeur (voir effectAliases).
            let (resolvedEffects, aliasedCount) = resolveAliases(videoEffects, addable: addable)
            // Trois catégories : ajoutables (nouveau composant), intrinsèques
            // (Opacity/Motion → composant existant du clip), ou vraiment absents.
            let appendable = resolvedEffects.filter { addable.contains($0.matchName) }
            let intrinsic = resolvedEffects.filter {
                !addable.contains($0.matchName) && intrinsicMatchNames.contains($0.matchName)
            }
            let trulyMissing = resolvedEffects.count - appendable.count - intrinsic.count
            guard !appendable.isEmpty || !intrinsic.isEmpty else { return nil }

            let folder = preset.binPath.joined(separator: "/")
            let source = adobe ? L("Adobe preset") : L("Preset")
            var keywords = preset.binPath
            keywords.append(contentsOf: videoEffects.map(\.displayName))
            keywords.append(contentsOf: appendable.map(\.matchName))

            var paramsTotal = 0
            var paramsCompiled = 0
            // Effets ajoutés : inversés (le prfpset stocke la pile à l'envers).
            let operations = appendable.reversed().map { effect in
                ApplyPlan.Operation(matchName: effect.matchName,
                                    params: compileParams(effect, total: &paramsTotal, compiled: &paramsCompiled),
                                    anchorType: effect.anchorType,
                                    srcDur: String(effect.srcDurationTicks),
                                    paramCount: effect.paramCount)
            }
            // Effets intrinsèques : ordre naturel, posés sur les composants existants.
            let existing = intrinsic.map { effect in
                ApplyPlan.Operation(matchName: effect.matchName,
                                    params: compileParams(effect, total: &paramsTotal, compiled: &paramsCompiled),
                                    anchorType: effect.anchorType,
                                    srcDur: String(effect.srcDurationTicks),
                                    paramCount: effect.paramCount)
            }

            var hints: [String] = ["params:\(paramsCompiled)/\(paramsTotal)"]
            if !existing.isEmpty { hints.append("intrinsic:\(existing.count)") }
            if trulyMissing > 0 { hints.append("dropped:\(trulyMissing)") }
            if aliasedCount > 0 { hints.append("aliased:\(aliasedCount)") }

            return SearchItem(
                id: "preset:\(preset.uid)",
                kind: "preset",
                title: preset.name,
                subtitle: folder.isEmpty ? source : "\(source) · \(folder)",
                keywords: keywords,
                plan: ApplyPlan(label: preset.name, operations: operations, existingOperations: existing),
                fidelityHint: hints.joined(separator: ",")
            )
        }
    }

    /// Couleur prfpset : uint64 packé, canaux 16 bits [A|R|G|B] (hypothèse
    /// calibrée empiriquement : noir opaque = 0xFF00000000000000 → A=0xFF00).
    /// Normalisation sur le canal haut 8 bits (0xFF00/0xFFFF ≈ 0.996 ≈ 1).
    static func decodePackedColor(_ raw: String) -> ApplyPlan.PlanParam.ColorValue? {
        guard let packed = UInt64(raw) else { return nil }
        func channel(_ shift: UInt64) -> Double {
            Double((packed >> shift) & 0xFFFF) / Double(0xFF00)
        }
        return .init(r: min(channel(32), 1.0),
                     g: min(channel(16), 1.0),
                     b: min(channel(0), 1.0),
                     a: min(channel(48), 1.0))
    }

    // MARK: - Découverte des fichiers de presets

    /// Fichier de presets utilisateur.
    /// Chez un autre monteur, plusieurs dossiers de version (25.0, 26.0) et
    /// plusieurs profils (« Profile-<nom> », profil Creative Cloud…) peuvent
    /// coexister. Avant : le PREMIER profil listé, dans un ordre que macOS ne
    /// garantit pas — on pouvait indexer un vieux profil. Désormais : le dossier
    /// de la version de Premiere qui tourne (`hostVersion` du hello : 26.5.2 →
    /// « 26.0 ») en priorité, sinon le plus récent ; et dans ce dossier, le
    /// fichier modifié en dernier, celui que Premiere tient à jour.
    static func userPresetFile(hostVersion: String = "") -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Adobe/Premiere Pro")
        guard let versions = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        // Tri numérique décroissant ("26.0" > "25.0")
        var ordered = versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        if let major = hostVersion.split(separator: ".").first.flatMap({ Int($0) }),
           let running = ordered.firstIndex(where: { $0.lastPathComponent == "\(major).0" }) {
            ordered.insert(ordered.remove(at: running), at: 0)
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        for version in ordered {
            guard let profiles = try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil) else { continue }
            let files = profiles
                .filter { $0.lastPathComponent.hasPrefix("Profile-") }
                .map { $0.appendingPathComponent("Effect Presets and Custom Items.prfpset") }
                .filter { fm.fileExists(atPath: $0.path) }
            if let newest = files.max(by: { modified($0) < modified($1) }) { return newest }
        }
        return nil
    }

    /// Presets Adobe du bundle. Version ET langue résolues dynamiquement
    /// (avant : « 2026/en_US » en dur → 0 preset chez un ami en français ou en
    /// Premiere 2025). `hostVersion`/`locale` viennent du hello du plugin.
    static func factoryPresetFiles(hostVersion: String = "", locale: String = "en_US") -> [URL] {
        let fm = FileManager.default
        guard let appDir = premiereAppDir(hostVersion: hostVersion, fm: fm) else {
            Logger.shared.info("Presets Adobe : bundle Premiere introuvable (version « \(hostVersion) »)")
            return []
        }
        let localized = appDir.appendingPathComponent("Contents/Resources/LocalizedPresets")
        // Résolution de la langue depuis le hello (NON authentifié → on interdit
        // tout séparateur de chemin). Le format d'UXP peut varier (fr_FR / fr-FR
        // / fr) : on tente exact, puis par PRÉFIXE de langue contre les dossiers
        // réellement présents, puis anglais.
        let norm = locale.replacingOccurrences(of: "-", with: "_")
        let clean = (norm.contains("/") || norm.contains("..")) ? "" : norm
        let available = ((try? fm.contentsOfDirectory(at: localized, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.lastPathComponent }
        let lang = clean.split(separator: "_").first.map(String.init)?.lowercased() ?? ""
        let byPrefix = lang.isEmpty ? [] : available.filter { $0.lowercased().hasPrefix(lang) }
        for loc in ([clean] + byPrefix + ["en_US"]) where !loc.isEmpty {
            let dir = localized.appendingPathComponent("\(loc)/Effect Presets")
            let presets = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "prfpset" }
            if !presets.isEmpty { return presets }
        }
        Logger.shared.info("Presets Adobe : aucun (langue « \(locale) » ; dossiers dispo : \(available))")
        return []
    }

    /// Localise le bundle Premiere : dérivé de la version hôte (major 26 → 2026),
    /// sinon la plus haute version « Adobe Premiere Pro <année> » dans /Applications
    /// (hors Beta). Le .app est DANS un dossier de même nom.
    private static func premiereAppDir(hostVersion: String, fm: FileManager) -> URL? {
        let apps = URL(fileURLWithPath: "/Applications")
        func appInside(_ folder: String) -> URL? {
            let app = apps.appendingPathComponent("\(folder)/\(folder).app")
            return fm.fileExists(atPath: app.path) ? app : nil
        }
        if let majorStr = hostVersion.split(separator: ".").first, let major = Int(majorStr),
           let hit = appInside("Adobe Premiere Pro \(2000 + major)") { return hit }
        let folders = (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
        let named = folders.map(\.lastPathComponent)
            .filter { $0.hasPrefix("Adobe Premiere Pro ") && !$0.contains("Beta") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for name in named { if let hit = appInside(name) { return hit } }
        return nil
    }

    // MARK: - Snapshot disque

    static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    static func saveSnapshot(_ snapshot: IndexSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    static func loadSnapshot() -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(IndexSnapshot.self, from: data),
              snapshot.version == IndexSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
