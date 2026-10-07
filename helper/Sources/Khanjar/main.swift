import AppKit
import Foundation
import ServiceManagement

/// khanjar — point d'entrée.
/// Modes :
///   app              PRODUIT : app d'arrière-plan, palette sur ⌘J (défaut)
///   run              serveur bridge seul (debug)
///   smoke [--apply]  attend le hello puis déroule ping/listEffects/getSelection
///                    (+ apply Gaussian Blur sur la sélection si --apply) et sort.
///   index-build      construit l'index + snapshot (requiert Premiere)
///   search <q>       recherche dans le snapshot (hors ligne)
///   index-presets    test du parser prfpset (hors ligne)
///   frequents [N]    classement fréquence+récence affiché par la palette (hors ligne)
///   index-preview    aperçu de l'index (effets du snapshot + presets reparsés,
///                    alias/partiels), hors ligne, sans écrire le snapshot
///   selftest         tests du scorer (hors ligne)
/// Codes de sortie smoke : 0 = OK, 2 = pas de hello, 3 = échec d'une étape.

let log = Logger.shared
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "app"

/// Serveur bridge pour les modes CLI qui en ont besoin (le mode `app` a le
/// sien via AppCoordinator — ne jamais en créer deux : un seul port).
func startBridgeOrExit() -> BridgeServer {
    let server = BridgeServer()
    do {
        try server.start()
    } catch {
        log.error("Impossible de démarrer le bridge : \(error)")
        exit(1)
    }
    return server
}

switch mode {
case "run":
    // `run [--port N]` : un autre port permet de tester le pont (ex. le
    // garde-fou web) sans arrêter l'app en service sur 48123.
    var runPort = Bridge.defaultPort
    if let i = arguments.firstIndex(of: "--port"), i + 1 < arguments.count, let p = UInt16(arguments[i + 1]) {
        runPort = p
    }
    let server = BridgeServer(port: runPort)
    do { try server.start() } catch { log.error("Impossible de démarrer le bridge : \(error)"); exit(1) }
    log.info("Mode run — en attente du plugin (Ctrl+C pour quitter)")
    server.onHello = { info in
        log.info("Plugin prêt : \(info.pluginVersion) sur Premiere \(info.hostVersion)")
    }
    server.onDisconnect = { log.info("Plugin déconnecté — reconnexion attendue") }
    RunLoop.main.run()

case "smoke":
    let server = startBridgeOrExit()
    let wantApply = arguments.contains("--apply")
    log.info("Mode smoke\(wantApply ? " (+apply)" : "") — en attente du hello (120 s max)")

    let overallTimeout = DispatchSource.makeTimerSource(queue: .main)
    overallTimeout.schedule(deadline: .now() + 120)
    overallTimeout.setEventHandler {
        log.error("SMOKE ÉCHEC : aucun hello en 120 s (plugin installé ? Premiere lancé ?)")
        exit(2)
    }
    overallTimeout.resume()

    func fail(_ step: String, _ error: BridgeError) -> Never {
        log.error("SMOKE ÉCHEC à l'étape \(step) : \(error)")
        exit(3)
    }

    server.onHello = { info in
        overallTimeout.cancel()
        log.info("── SMOKE : session \(info.pluginId) \(info.pluginVersion) / Premiere \(info.hostVersion) ──")

        server.request(cmd: "ping", timeout: 2) { result in
            switch result {
            case .failure(let error): fail("ping", error)
            case .success(let pong):
                log.info("ping OK (uptime plugin \(pong["uptimeMs"] ?? "?") ms)")

                server.request(cmd: "listEffects", timeout: 5) { result in
                    switch result {
                    case .failure(let error): fail("listEffects", error)
                    case .success(let effects):
                        let counts = effects["counts"] as? [String: Any] ?? [:]
                        let video = effects["video"] as? [[String: Any]] ?? []
                        let sample = video.prefix(3).compactMap { $0["displayName"] as? String }
                        log.info("listEffects OK : \(counts["video"] ?? 0) vidéo / \(counts["audio"] ?? 0) audio (ex. \(sample.joined(separator: ", ")))")

                        server.request(cmd: "getSelection", timeout: 2) { result in
                            switch result {
                            case .failure(.remote(let code, _)) where code == "NO_PROJECT" || code == "NO_SEQUENCE":
                                // Attendu sans projet/séquence : la taxonomie fonctionne.
                                log.info("getSelection OK (erreur attendue : \(code))")
                                guard !wantApply else {
                                    log.error("SMOKE : --apply impossible sans projet/séquence")
                                    exit(3)
                                }
                                log.info("SMOKE OK (apply non demandé)")
                                exit(0)
                            case .failure(let error): fail("getSelection", error)
                            case .success(let selection):
                                log.info("getSelection OK : \(selection["count"] ?? 0) item(s), projet \(selection["project"] ?? "?")")

                                guard wantApply else {
                                    log.info("SMOKE OK (apply non demandé — utiliser --apply avec un clip sélectionné)")
                                    exit(0)
                                }
                                let plan: [String: Any] = [
                                    "label": "Khanjar smoke — Gaussian Blur",
                                    "target": "selection",
                                    "operations": [["effect": ["matchName": "AE.ADBE Gaussian Blur 2"], "params": []]],
                                ]
                                server.request(cmd: "apply", payload: ["plan": plan], timeout: 0.8) { result in
                                    switch result {
                                    case .failure(let error): fail("apply", error)
                                    case .success(let applied):
                                        let clips = (applied["applied"] as? [String: Any])?["clips"] ?? 0
                                        log.info("apply OK : \(clips) clip(s), transaction \(applied["transaction"] ?? "?"), \(applied["latencyMs"] ?? "?") ms")
                                        log.info("SMOKE OK")
                                        exit(0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "index-presets":
    // Vérification M2 : parse les prfpset (chemins passés en argument, sinon
    // auto-découverte profil utilisateur + presets Adobe du bundle) et imprime
    // un résumé chronométré. Lecture seule, ne requiert pas Premiere.
    var files = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    if files.isEmpty {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Adobe/Premiere Pro")
        if let versions = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for version in versions.sorted(by: { $0.path > $1.path }) {
                if let profiles = try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil) {
                    for profile in profiles where profile.lastPathComponent.hasPrefix("Profile-") {
                        let f = profile.appendingPathComponent("Effect Presets and Custom Items.prfpset")
                        if fm.fileExists(atPath: f.path) { files.append(f) }
                    }
                }
            }
        }
        let factory = URL(fileURLWithPath:
            "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app/Contents/Resources/LocalizedPresets/en_US/Effect Presets")
        if let bundleFiles = try? fm.contentsOfDirectory(at: factory, includingPropertiesForKeys: nil) {
            files.append(contentsOf: bundleFiles.filter { $0.pathExtension == "prfpset" })
        }
    }
    guard !files.isEmpty else {
        log.error("Aucun fichier .prfpset trouvé")
        exit(1)
    }

    var totalPresets = 0
    for file in files {
        let started = Date()
        do {
            let presets = try PrfpsetParser.parse(fileURL: file)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let videoOnly = presets.filter(\.isVideoOnly).count
            let partial = presets.filter { $0.arbParamCount > 0 }.count
            let multi = presets.filter { $0.effects.count > 1 }.count
            totalPresets += presets.count
            log.info("\(file.lastPathComponent) : \(presets.count) presets en \(elapsed) ms — \(videoOnly) 100% vidéo, \(multi) multi-effets, \(partial) avec params opaques")
            for preset in presets.prefix(3) {
                let effects = preset.effects.map { "\($0.displayName)[\($0.kind), \($0.paramCount)p/\($0.arbParamCount)arb]" }
                log.info("   • \(preset.binPath.joined(separator: "/"))/\(preset.name) → \(effects.joined(separator: " + ")) (uid \(preset.uid.prefix(8)))")
            }
        } catch {
            log.error("\(file.lastPathComponent) : \(error)")
        }
    }
    log.info("TOTAL : \(totalPresets) presets indexables")
    exit(0)

case "index-build":
    // M2 : construit l'index complet (effets via plugin + presets via parser)
    // et écrit le snapshot disque. Requiert Premiere + plugin.
    let server = startBridgeOrExit()
    log.info("index-build — en attente du plugin (120 s max)")
    let buildTimeout = DispatchSource.makeTimerSource(queue: .main)
    buildTimeout.schedule(deadline: .now() + 120)
    buildTimeout.setEventHandler { log.error("index-build ÉCHEC : plugin injoignable"); exit(2) }
    buildTimeout.resume()

    server.onHello = { info in
        buildTimeout.cancel()
        server.request(cmd: "listEffects", timeout: 5) { result in
            guard case .success(let payload) = result else {
                log.error("index-build ÉCHEC : listEffects — \(result)")
                exit(3)
            }
            let effects = (payload["video"] as? [[String: Any]] ?? []).compactMap { entry -> IndexStore.EffectEntry? in
                guard let matchName = entry["matchName"] as? String else { return nil }
                return IndexStore.EffectEntry(matchName: matchName,
                                              displayName: entry["displayName"] as? String ?? matchName)
            }

            var userPresets: [ParsedPreset] = []
            if let file = IndexStore.userPresetFile(hostVersion: info.hostVersion) {
                userPresets = (try? PrfpsetParser.parse(fileURL: file)) ?? []
                log.info("Presets utilisateur : \(userPresets.count) (\(file.path))")
            } else {
                log.info("Aucun fichier de presets utilisateur trouvé")
            }
            var factoryPresets: [ParsedPreset] = []
            for file in IndexStore.factoryPresetFiles(hostVersion: info.hostVersion, locale: info.uiLocale) {
                factoryPresets.append(contentsOf: (try? PrfpsetParser.parse(fileURL: file)) ?? [])
            }
            log.info("Presets Adobe : \(factoryPresets.count)")

            let items = IndexStore.build(effects: effects, userPresets: userPresets, factoryPresets: factoryPresets)
            let snapshot = IndexSnapshot(version: IndexSnapshot.currentVersion,
                                         generatedAt: Date(),
                                         premiereVersion: info.hostVersion,
                                         items: items)
            do {
                try IndexStore.saveSnapshot(snapshot)
                log.info("INDEX OK : \(items.count) items (\(effects.count) effets) → \(IndexStore.snapshotURL.path)")
                exit(0)
            } catch {
                log.error("index-build ÉCHEC : écriture snapshot — \(error)")
                exit(3)
            }
        }
    }
    RunLoop.main.run()

case "search":
    // M2 : recherche dans le snapshot (hors ligne, sans Premiere).
    let query = arguments.dropFirst().joined(separator: " ")
    guard !query.isEmpty else { log.error("Usage : search <requête>"); exit(1) }
    guard let snapshot = IndexStore.loadSnapshot() else {
        log.error("Pas de snapshot — lancer d'abord : khanjar index-build")
        exit(1)
    }
    let prepStarted = Date()
    let prepared = Scorer.prepare(snapshot.items) // fait UNE fois au chargement dans l'app
    let prepMs = Date().timeIntervalSince(prepStarted) * 1000
    let started = Date()
    let ranked = Scorer.rank(query: query, prepared: prepared, limit: 8)
    let elapsedMs = Date().timeIntervalSince(started) * 1000
    log.info("« \(query) » — \(ranked.count) résultat(s) sur \(snapshot.items.count) items : frappe \(String(format: "%.2f", elapsedMs)) ms (préparation unique \(String(format: "%.0f", prepMs)) ms)")
    for (i, entry) in ranked.enumerated() {
        log.info("  \(i + 1). [\(String(format: "%.3f", entry.score))] \(entry.item.title) — \(entry.item.subtitle)")
    }
    exit(0)

case "app":
    // Verrou d'instance unique (flock) : empêche deux Khanjar de tourner en
    // même temps — sinon ils se disputent le port et les raccourcis (bug
    // constaté 2026-07-14 : un vieux build dans /Applications + le build dev).
    let lockDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Khanjar", isDirectory: true)
    try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
    let lockFd = open(lockDir.appendingPathComponent(".instance.lock").path, O_CREAT | O_RDWR, 0o644)
    if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
        log.error("Une autre instance de Khanjar tourne déjà — arrêt de celle-ci.")
        exit(0)
    }
    // lockFd reste ouvert pour toute la vie du process (verrou tenu par le noyau).

    // Défense : cette instance détient le verrou → elle est autoritaire.
    // On expulse toute AUTRE instance de Khanjar (ex. un ancien build dans
    // /Applications sans verrou, qui recréerait le conflit de port/raccourcis).
    let myPid = ProcessInfo.processInfo.processIdentifier
    // Inclut l'ancienne identité « Dagger » (com.dagger.helper) : lors de la
    // bascule, l'ancien build tourne encore, tient le port 48123 et les mêmes
    // raccourcis. Son verrou est dans un autre dossier, il ne nous voit donc pas.
    for bundleId in ["io.khanjar.app", "com.dagger.helper"] {
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        where other.processIdentifier != myPid {
            log.info("Expulsion d'une autre instance (\(bundleId), pid \(other.processIdentifier))")
            other.forceTerminate()
        }
    }

    // Reprise des réglages et de l'historique de Dagger, AVANT tout chargement
    // (réglages, classement, index) — et après l'expulsion, pour que l'ancienne
    // app n'écrive plus pendant la copie.
    LegacyMigration.run()

    // Mode produit : app d'arrière-plan (pas de Dock), palette sur ⌘J.
    // Double-cliquer Khanjar.app alors qu'elle tourne déjà → fenêtre de réglages
    // (pattern macOS standard : reopen).
    final class AppDelegate: NSObject, NSApplicationDelegate {
        var onReopen: (() -> Void)?
        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            onReopen?()
            return true
        }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let coordinator = AppCoordinator()
    let delegate = AppDelegate()
    delegate.onReopen = { coordinator.openSettings() }
    app.delegate = delegate
    do {
        try coordinator.start()
    } catch {
        log.error("Démarrage impossible : \(error)")
        exit(1)
    }
    app.run()

case "fidelity-test":
    // M4 : mesure empirique de fidélité sur un projet scratch.
    // Usage : fidelity-test <mediaPath> [requête, défaut "glow dorian"]
    let server = startBridgeOrExit()
    let mediaPath = arguments.dropFirst().first ?? "/tmp/khanjar-test.png"
    let query = arguments.dropFirst(2).joined(separator: " ").isEmpty
        ? "glow dorian" : arguments.dropFirst(2).joined(separator: " ")
    guard let snapshot = IndexStore.loadSnapshot() else {
        log.error("Pas de snapshot — lancer d'abord index-build")
        exit(1)
    }
    let prepared = Scorer.prepare(snapshot.items)
    guard let target = Scorer.rank(query: query, prepared: prepared, limit: 5)
        .first(where: { $0.item.kind == "preset" && !$0.item.plan.operations.flatMap(\.params).isEmpty }) else {
        log.error("Aucun preset avec paramètres pour « \(query) »")
        exit(1)
    }
    let plannedParams = target.item.plan.operations.flatMap(\.params)
    log.info("Cible : \(target.item.title) — \(plannedParams.count) paramètre(s) compilé(s)")

    let projectPath = "/tmp/khanjar-fidelity-\(Int(Date().timeIntervalSince1970)).prproj"

    func fail(_ step: String, _ error: BridgeError) -> Never {
        log.error("FIDELITY ÉCHEC \(step) : \(error)")
        exit(3)
    }

    server.onHello = { _ in
        server.request(cmd: "testSetup",
                       payload: ["projectPath": projectPath, "mediaPath": mediaPath],
                       timeout: 30) { result in
            switch result {
            case .failure(let error): fail("testSetup", error)
            case .success(let setup):
                log.info("testSetup OK : \(setup)")
                server.request(cmd: "apply",
                               payload: ["plan": target.item.plan.protocolPayload],
                               timeout: 5) { result in
                    switch result {
                    case .failure(let error): fail("apply", error)
                    case .success(let applied):
                        log.info("apply OK : \(applied["fidelity"] ?? [:])")
                        // Échantillonner aux temps de tous les keyframes du plan
                        // + points de diagnostic (epsilon après 0, milieu du 1er segment)
                        var sampleSet = Set(plannedParams.flatMap { $0.keyframes.map(\.t) })
                        sampleSet.insert("1000")
                        sampleSet.insert("5297292000")
                        let sampleTicks = sampleSet.sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }
                        server.request(cmd: "readParams",
                                       payload: sampleTicks.isEmpty ? [:] : ["sampleTicks": sampleTicks],
                                       timeout: 15) { result in
                            switch result {
                            case .failure(let error): fail("readParams", error)
                            case .success(let live):
                                log.info("Composant relu : \(live["displayName"] ?? "?") (\(live["matchName"] ?? "?"))")
                                let liveParams = live["params"] as? [[String: Any]] ?? []
                                func asDouble(_ any: Any?) -> Double? {
                                    (any as? Double) ?? (any as? Int).map(Double.init)
                                }
                                var okCount = 0
                                for planned in plannedParams {
                                    let match = liveParams.first { ($0["index"] as? Int) == planned.index }
                                    if !planned.keyframes.isEmpty {
                                        // Vérification keyframe par keyframe
                                        let samples = match?["samples"] as? [[String: Any]] ?? []
                                        var kfOk = 0
                                        for kf in planned.keyframes {
                                            let sample = samples.first { ($0["t"] as? String) == kf.t }
                                            let liveV = asDouble(sample?["v"])
                                            let expected = kf.v ?? Double.nan
                                            let same = liveV.map { abs($0 - expected) < 0.01 } ?? false
                                            if same { kfOk += 1 }
                                            log.info("    kf t=\(kf.t) : attendu \(kf.v.map { String($0) } ?? "(point)"), lu \(sample?["v"] ?? "(absent)") \(same ? "✓" : "✗")")
                                        }
                                        let same = kfOk == planned.keyframes.count
                                        if same { okCount += 1 }
                                        let raw = samples.map { "\($0["t"] ?? "?")→\($0["v"] ?? "?")" }.joined(separator: "  ")
                                        log.info("    échantillons bruts : \(raw)")
                                        log.info("  [\(same ? "✓" : "✗")] #\(planned.index) \(planned.name) : \(kfOk)/\(planned.keyframes.count) keyframes conformes")
                                        continue
                                    }
                                    let liveValue = match?["value"]
                                    let expected: String
                                    if let b = planned.bool { expected = String(b) }
                                    else { expected = planned.number.map { String($0) } ?? "?" }
                                    let liveStr = liveValue.map { "\($0)" } ?? "(absent)"
                                    let same: Bool
                                    if let n = planned.number, let ln = asDouble(liveValue) { same = abs(n - ln) < 0.0001 }
                                    else if let b = planned.bool { same = (liveValue as? Bool) == b || (liveValue as? Int).map { ($0 != 0) == b } ?? false }
                                    else { same = false }
                                    if same { okCount += 1 }
                                    log.info("  [\(same ? "✓" : "✗")] #\(planned.index) \(planned.name) : attendu \(expected), lu \(liveStr)")
                                }
                                log.info("FIDÉLITÉ : \(okCount)/\(plannedParams.count) paramètres vérifiés conformes")
                                exit(okCount == plannedParams.count ? 0 : 4)
                            }
                        }
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "apply-dump":
    // Diagnostic multi-effets : projet scratch → apply du preset → dump de la
    // chaîne complète (ordre + valeurs). Usage : apply-dump <media> <requête>
    // [--library <f.prfpset>] : cherche le preset dans CE fichier (bibliothèque
    // d'un autre monteur, preset d'une autre langue) au lieu de l'index.
    let server = startBridgeOrExit()
    let mediaPath = arguments.dropFirst().first ?? "/tmp/khanjar-test.png"
    var dumpArgs = Array(arguments.dropFirst(2))
    var libraryFile: URL?
    if let i = dumpArgs.firstIndex(of: "--library"), i + 1 < dumpArgs.count {
        libraryFile = URL(fileURLWithPath: dumpArgs[i + 1])
        dumpArgs.removeSubrange(i...(i + 1))
    }
    let query = dumpArgs.joined(separator: " ")
    guard !query.isEmpty, let snapshot = IndexStore.loadSnapshot() else {
        log.error("Usage : apply-dump <media> <requête> [--library <f.prfpset>] (et snapshot présent)")
        exit(1)
    }
    var dumpItems = snapshot.items
    if let libraryFile {
        let effects = snapshot.items.filter { $0.kind == "effect" }.compactMap { item -> IndexStore.EffectEntry? in
            guard let mn = item.plan.operations.first?.matchName else { return nil }
            return IndexStore.EffectEntry(matchName: mn, displayName: item.title)
        }
        let library = (try? PrfpsetParser.parse(fileURL: libraryFile)) ?? []
        dumpItems = IndexStore.build(effects: effects, userPresets: library, factoryPresets: []).filter { $0.kind == "preset" }
        log.info("Bibliothèque \(libraryFile.lastPathComponent) : \(library.count) presets, \(dumpItems.count) applicables")
    }
    let prepared = Scorer.prepare(dumpItems)
    guard let target = Scorer.rank(query: query, prepared: prepared, limit: 5).first(where: { $0.item.kind == "preset" }) else {
        log.error("Aucun preset pour « \(query) »")
        exit(1)
    }
    log.info("Cible : \(target.item.title) — \(target.item.plan.operations.count) effet(s), ordre du plan : \(target.item.plan.operations.map(\.matchName).joined(separator: " → "))")
    let projectPath = "/tmp/khanjar-dump-\(Int(Date().timeIntervalSince1970)).prproj"
    func fail(_ s: String, _ e: BridgeError) -> Never { log.error("DUMP ÉCHEC \(s): \(e)"); exit(3) }
    server.onHello = { _ in
        server.request(cmd: "testSetup", payload: ["projectPath": projectPath, "mediaPath": mediaPath], timeout: 30) { r in
            guard case .success = r else { fail("testSetup", (try? r.get()) != nil ? .malformed : .timeout) }
            server.request(cmd: "apply", payload: ["plan": target.item.plan.protocolPayload], timeout: 5) { r in
                switch r {
                case .failure(let e): fail("apply", e)
                case .success(let applied):
                    log.info("apply : fidélité \(applied["fidelity"] ?? [:])")
                    server.request(cmd: "dumpChain", timeout: 10) { r in
                        switch r {
                        case .failure(let e): fail("dumpChain", e)
                        case .success(let dump):
                            let comps = dump["components"] as? [[String: Any]] ?? []
                            log.info("── CHAÎNE (\(comps.count) composants, ordre haut→bas) ──")
                            for comp in comps {
                                let name = comp["displayName"] as? String ?? "?"
                                let mn = comp["matchName"] as? String ?? "?"
                                log.info("  [\(comp["chainIndex"] ?? "?")] \(name) (\(mn))")
                                let params = comp["params"] as? [[String: Any]] ?? []
                                let interesting = params.filter { p in
                                    let n = (p["name"] as? String ?? "").lowercased()
                                    return ["opacity","direction","edge type","scale","complexity","border","distance","softness"].contains { n.contains($0) }
                                }
                                for p in interesting {
                                    log.info("        \(p["name"] ?? "?") = \(p["value"] ?? "?")")
                                }
                                // Modes d'interpolation RELUS depuis Premiere : seule
                                // preuve que le bézier s'est posé (« linéaire (losange) »
                                // = régression silencieuse, cf. captures du 2026-07-21).
                                for p in params {
                                    guard let modes = p["keyframeModes"] as? [[String: Any]], !modes.isEmpty else { continue }
                                    let resume = modes.map { "\($0["label"] ?? $0["mode"] ?? "?")" }.joined(separator: ", ")
                                    log.info("        [kf] \(p["name"] ?? "?") : \(modes.count) → \(resume)")
                                }
                            }
                            exit(0)
                        }
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "adj-test":
    // Test du flux calque d'effets (sans clavier) : attend le hello puis
    // envoie addAdjustmentLayer sur la séquence active.
    let server = startBridgeOrExit()
    server.onHello = { _ in
        server.request(cmd: "addAdjustmentLayer", timeout: 5) { result in
            switch result {
            case .success(let payload): log.info("ADJ OK : \(payload)"); exit(0)
            case .failure(let error): log.info("ADJ résultat : \(error)"); exit(4)
            }
        }
    }
    RunLoop.main.run()

case "multi-test":
    // Reproduction du bug multi-clips : projet avec N clips tous sélectionnés,
    // apply, puis vérif PAR CLIP. Usage : multi-test <requête>
    let server = startBridgeOrExit()
    let query = arguments.dropFirst().joined(separator: " ")
    guard !query.isEmpty, let snapshot = IndexStore.loadSnapshot() else {
        log.error("Usage : multi-test <requête> (snapshot requis)"); exit(1)
    }
    let prepared = Scorer.prepare(snapshot.items)
    guard let target = Scorer.rank(query: query, prepared: prepared, limit: 5).first(where: { $0.item.kind == "preset" }) else {
        log.error("Aucun preset pour « \(query) »"); exit(1)
    }
    // N PNG distincts (Premiere dédoublonne à l'import sinon) — 20 pour
    // stresser la staleness à l'échelle.
    let media = (0..<3).map { "/tmp/khanjar-multi-\($0).png" }
    for p in media { try? FileManager.default.copyItem(atPath: "/tmp/khanjar-test.png", toPath: p) }
    let projectPath = "/tmp/khanjar-multi-\(Int(Date().timeIntervalSince1970)).prproj"
    log.info("Cible : \(target.item.title)")
    func fail(_ s: String, _ e: BridgeError) -> Never { log.error("MULTI ÉCHEC \(s): \(e)"); exit(3) }
    server.onHello = { _ in
        server.request(cmd: "testSetupMulti", payload: ["projectPath": projectPath, "mediaPaths": media], timeout: 30) { r in
            switch r {
            case .failure(let e): fail("testSetupMulti", e)
            case .success(let setup):
                log.info("Setup : \(setup["clipsOnTrack"] ?? "?") clips sur V1, getSelection renvoie \(setup["selectionReturns"] ?? "?")")
                server.request(cmd: "apply", payload: ["plan": target.item.plan.protocolPayload], timeout: 8) { r in
                    switch r {
                    case .failure(let e): fail("apply", e)
                    case .success(let applied):
                        let fid = applied["fidelity"] as? [String: Any] ?? [:]
                        log.info("apply : \(applied["applied"] ?? [:]), transaction=\(applied["transaction"] ?? "?"), params posés=\(fid["paramsSet"] ?? "?") sautés=\(fid["paramsSkipped"] ?? "?")")
                        // Répartition des raisons d'échec
                        let detail = fid["detail"] as? [[String: Any]] ?? []
                        var reasons: [String: Int] = [:]
                        for d in detail { let r = d["reason"] as? String ?? "?"; reasons[r, default: 0] += 1 }
                        if !reasons.isEmpty { log.info("RAISONS échec params : \(reasons)") ; log.info("exemples : \(detail.prefix(4))") }
                        server.request(cmd: "dumpAllSelected", timeout: 10) { r in
                            switch r {
                            case .failure(let e): fail("dumpAllSelected", e)
                            case .success(let dump):
                                let clips = dump["clips"] as? [[String: Any]] ?? []
                                log.info("── \(clips.count) clip(s) sélectionné(s) après apply ──")
                                var withEffect = 0
                                for c in clips {
                                    let last = c["lastComponent"] as? String ?? "?"
                                    let hasFx = last.contains("Drop Shadow") || last.contains("Roughen") || last.contains("Geometry") || last.contains("Gaussian")
                                    if hasFx { withEffect += 1 }
                                    log.info("  [\(hasFx ? "✓" : "✗")] \(c["name"] ?? "?") : \(c["componentCount"] ?? "?") composants, dernier=\(last)")
                                }
                                log.info("RÉSULTAT : \(withEffect)/\(clips.count) clips ont bien reçu l'effet")
                                exit(withEffect == clips.count ? 0 : 4)
                            }
                        }
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "anchor-test":
    // Vérifie l'ancrage temporel des keyframes (Échelle/Entrée/Sortie) :
    // projet scratch → apply du preset → échantillonne le DERNIER composant
    // à 2 %, 50 % et 98 % de la durée du clip. Usage : anchor-test "<requête>"
    let server = startBridgeOrExit()
    // Dernier argument "0.05,0.1,0.15" = fractions d'échantillonnage sur mesure
    // (utile pour viser l'INTÉRIEUR d'un segment keyframé court et lire la
    // forme de la courbe, seule preuve possible sur un paramètre de point).
    var anchorArgs = Array(arguments.dropFirst())
    // --component <texte> : échantillonner ce composant (matchName) plutôt que le dernier.
    var componentMatch: String?
    if let i = anchorArgs.firstIndex(of: "--component"), i + 1 < anchorArgs.count {
        componentMatch = anchorArgs[i + 1]
        anchorArgs.removeSubrange(i...(i + 1))
    }
    var fractions: [Double] = [0.02, 0.5, 0.98]
    if let last = anchorArgs.last, last.contains(","),
       case let parsed = last.split(separator: ",").compactMap({ Double($0) }),
       parsed.count == last.split(separator: ",").count, !parsed.isEmpty {
        fractions = parsed
        anchorArgs.removeLast()
    }
    let query = anchorArgs.joined(separator: " ")
    guard !query.isEmpty, let snapshot = IndexStore.loadSnapshot() else {
        log.error("Usage : anchor-test <requête> [f1,f2,f3] (snapshot requis)"); exit(1)
    }
    let prepared = Scorer.prepare(snapshot.items)
    guard let target = Scorer.rank(query: query, prepared: prepared, limit: 5)
        .first(where: { $0.item.kind == "preset" }) else {
        log.error("Aucun preset pour « \(query) »"); exit(1)
    }
    let anchors = target.item.plan.operations.map { "\($0.matchName.replacingOccurrences(of: "AE.ADBE ", with: "")):T\($0.anchorType)/src\($0.srcDur)" }
    log.info("Cible : \(target.item.title) — ancrages \(anchors.joined(separator: ", "))")
    let projectPath = "/tmp/khanjar-anchor-\(Int(Date().timeIntervalSince1970)).prproj"
    func fail(_ s: String, _ e: BridgeError) -> Never { log.error("ANCHOR ÉCHEC \(s): \(e)"); exit(3) }
    server.onHello = { _ in
        server.request(cmd: "testSetup", payload: ["projectPath": projectPath, "mediaPath": "/tmp/khanjar-test.png"], timeout: 30) { r in
            guard case .success = r else { fail("testSetup", .timeout) }
            server.request(cmd: "apply", payload: ["plan": target.item.plan.protocolPayload], timeout: 8) { r in
                switch r {
                case .failure(let e): fail("apply", e)
                case .success(let applied):
                    let fid = applied["fidelity"] as? [String: Any] ?? [:]
                    log.info("apply OK — params posés=\(fid["paramsSet"] ?? "?") sautés=\(fid["paramsSkipped"] ?? "?")")
                    var readPayload: [String: Any] = ["sampleFractions": fractions]
                    if let componentMatch { readPayload["componentMatch"] = componentMatch }
                    server.request(cmd: "readParams", payload: readPayload, timeout: 15) { r in
                        switch r {
                        case .failure(let e): fail("readParams", e)
                        case .success(let live):
                            log.info("Composant lu : \(live["displayName"] ?? "?")")
                            func fmt(_ v: Any?) -> String {
                                if let d = v as? [String: Any], let x = d["x"], let y = d["y"] {
                                    return "(\(x);\(y))"
                                }
                                if let n = v as? Double { return String(format: "%.4g", n) }
                                return "\(v ?? "?")".replacingOccurrences(of: "\n", with: "")
                            }
                            for p in live["params"] as? [[String: Any]] ?? [] {
                                guard let samples = p["samples"] as? [[String: Any]], !samples.isEmpty else { continue }
                                let vals = samples.map { fmt($0["v"]) }.joined(separator: " → ")
                                let pcts = fractions.map { String(format: "%.3g%%", $0 * 100) }.joined(separator: ",")
                                log.info("  \(p["name"] ?? "?") @[\(pcts)] : \(vals)")
                            }
                            exit(0)
                        }
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "ease-probe":
    // SPIKE : la technique des « keyframes façonneurs » peut-elle courber une
    // trajectoire alors qu'UXP n'expose aucune API de poignées ?
    // Projet scratch → Gaussian Blur (param 0 = Blurriness, sans keyframe) →
    // easeProbe : A(0) S(25 %, 15.6) B(100) en bézier, façonneur retiré.
    // Lecture : ~25/50/75 = poignées NON persistantes (piste morte) ;
    // premier point nettement < 25 = ease obtenue sans API de poignées.
    // Usage : ease-probe [--keep-shaper]
    let server = startBridgeOrExit()
    let keepShaper = arguments.contains("--keep-shaper")
    let projectPath = "/tmp/khanjar-ease-\(Int(Date().timeIntervalSince1970)).prproj"
    func fail(_ s: String, _ e: BridgeError) -> Never { log.error("EASE ÉCHEC \(s): \(e)"); exit(3) }
    log.info("Spike ease — façonneur \(keepShaper ? "CONSERVÉ (contrôle)" : "retiré (test réel)")")
    server.onHello = { _ in
        server.request(cmd: "testSetup", payload: ["projectPath": projectPath, "mediaPath": "/tmp/khanjar-test.png"], timeout: 30) { r in
            guard case .success = r else { fail("testSetup", .timeout) }
            let plan: [String: Any] = [
                "label": "Khanjar spike ease",
                "target": "selection",
                "operations": [["effect": ["matchName": "AE.ADBE Gaussian Blur 2"], "params": []]],
            ]
            server.request(cmd: "apply", payload: ["plan": plan], timeout: 8) { r in
                guard case .success = r else { fail("apply", .timeout) }
                server.request(cmd: "easeProbe", payload: ["paramIndex": 0, "shaperValue": 15.6, "keepShaper": keepShaper], timeout: 20) { r in
                    switch r {
                    case .failure(let e): fail("easeProbe", e)
                    case .success(let out):
                        log.info("Param « \(out["paramName"] ?? "?") » — keyframes restants : \(out["keyframesRestants"] ?? "?")")
                        for s in out["samples"] as? [[String: Any]] ?? [] {
                            let v = (s["v"] as? Double).map { String(format: "%.2f", $0) } ?? "\(s["v"] ?? "?")"
                            log.info("  @\(s["at"] ?? "?") : mesuré \(v)   (linéaire = \(s["linear"] ?? "?"))")
                        }
                        exit(0)
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "inspect-component":
    // SONDE empirique : applique un effet dans un projet scratch puis énumère
    // TOUTES les propriétés runtime du composant → cherche un setter de nom.
    let server = startBridgeOrExit()
    let projectPath = "/tmp/khanjar-inspect-\(Int(Date().timeIntervalSince1970)).prproj"
    func fail(_ s: String, _ e: BridgeError) -> Never { log.error("INSPECT ÉCHEC \(s): \(e)"); exit(3) }
    server.onHello = { _ in
        server.request(cmd: "testSetup", payload: ["projectPath": projectPath, "mediaPath": "/tmp/khanjar-test.png"], timeout: 30) { r in
            guard case .success = r else { fail("testSetup", .timeout) }
            let plan: [String: Any] = [
                "label": "Khanjar inspect",
                "target": "selection",
                "operations": [["effect": ["matchName": "AE.ADBE Gaussian Blur 2"], "params": []]],
            ]
            server.request(cmd: "apply", payload: ["plan": plan], timeout: 8) { r in
                guard case .success = r else { fail("apply", .timeout) }
                server.request(cmd: "inspectComponent", timeout: 8) { r in
                    switch r {
                    case .failure(let e): fail("inspectComponent", e)
                    case .success(let out):
                        log.info("Composant « \(out["displayName"] ?? "?") » — \(out["propsCount"] ?? "?") propriétés runtime")
                        let nameRel = out["nameRelated"] as? [String] ?? []
                        log.info("  Propriétés liées au NOM : \(nameRel.isEmpty ? "AUCUNE" : nameRel.joined(separator: ", "))")
                        log.info("  Surface complète : \((out["all"] as? [String] ?? []).joined(separator: ", "))")
                        exit(0)
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "dump-selected":
    // Lit la SÉLECTION LIVE (aucun projet scratch) : dumpe la chaîne complète
    // de chaque clip sélectionné → diagnostic de l'ordre d'insertion réel sur
    // un graphique/texte (Vector Motion, Text, Transform…).
    let server = startBridgeOrExit()
    server.onHello = { _ in
        server.request(cmd: "dumpAllSelected", timeout: 8) { r in
            switch r {
            case .failure(let e): log.error("dump-selected échec: \(e)"); exit(3)
            case .success(let out):
                let clips = out["clips"] as? [[String: Any]] ?? []
                if clips.isEmpty { log.error("Aucun clip sélectionné dans Premiere."); exit(2) }
                for c in clips {
                    log.info("── CLIP « \(c["name"] ?? "?") » — \(c["componentCount"] ?? 0) composants — média : \(c["kind"] ?? "?") via \(c["via"] ?? "?") (brut : \(c["mediaType"] ?? "nil")) ──")
                    for comp in (c["chain"] as? [[String: Any]] ?? []) {
                        log.info("  [\(comp["i"] ?? "?")] \(comp["dn"] ?? "?")   (\(comp["mn"] ?? "?"))")
                    }
                }
                exit(0)
            }
        }
    }
    RunLoop.main.run()

case "stack-test":
    // Vérifie l'ORDRE d'insertion (v0.6.1 : haut de la pile utilisateur) :
    // projet scratch → apply du preset A → apply du preset B → dumpChain.
    // Attendu : les effets de B apparaissent AU-DESSUS de ceux de A (index
    // plus petits), et tous au-dessous des intrinsèques (Opacity/Motion).
    // Usage : stack-test "<requête A>" "<requête B>"
    let server = startBridgeOrExit()
    let queryA = arguments.dropFirst().first ?? ""
    let queryB = arguments.dropFirst(2).first ?? ""
    guard !queryA.isEmpty, !queryB.isEmpty, let snapshot = IndexStore.loadSnapshot() else {
        log.error("Usage : stack-test \"<requête A>\" \"<requête B>\" (snapshot requis)"); exit(1)
    }
    let prepared = Scorer.prepare(snapshot.items)
    func findPreset(_ q: String) -> SearchItem? {
        Scorer.rank(query: q, prepared: prepared, limit: 5)
            .first(where: { $0.item.kind == "preset" && !$0.item.plan.operations.isEmpty })?.item
    }
    guard let presetA = findPreset(queryA), let presetB = findPreset(queryB) else {
        log.error("Preset introuvable pour « \(queryA) » ou « \(queryB) »"); exit(1)
    }
    log.info("A = \(presetA.title) (\(presetA.plan.operations.count) effet(s)) ; B = \(presetB.title) (\(presetB.plan.operations.count) effet(s))")
    let projectPath = "/tmp/khanjar-stack-\(Int(Date().timeIntervalSince1970)).prproj"
    func fail(_ s: String, _ e: BridgeError) -> Never { log.error("STACK ÉCHEC \(s): \(e)"); exit(3) }
    server.onHello = { _ in
        server.request(cmd: "testSetup", payload: ["projectPath": projectPath, "mediaPath": "/tmp/khanjar-test.png"], timeout: 30) { r in
            guard case .success = r else { fail("testSetup", .timeout) }
            server.request(cmd: "apply", payload: ["plan": presetA.plan.protocolPayload], timeout: 8) { r in
                guard case .success = r else { fail("apply A", .timeout) }
                server.request(cmd: "apply", payload: ["plan": presetB.plan.protocolPayload], timeout: 8) { r in
                    guard case .success = r else { fail("apply B", .timeout) }
                    server.request(cmd: "dumpChain", timeout: 10) { r in
                        switch r {
                        case .failure(let e): fail("dumpChain", e)
                        case .success(let dump):
                            let comps = dump["components"] as? [[String: Any]] ?? []
                            log.info("── CHAÎNE (\(comps.count) composants, ordre haut→bas) ──")
                            var order: [String] = []
                            for comp in comps {
                                let mn = comp["matchName"] as? String ?? "?"
                                order.append(mn)
                                log.info("  [\(comp["chainIndex"] ?? "?")] \(comp["displayName"] as? String ?? "?") (\(mn))")
                            }
                            let wantB = presetB.plan.operations.map(\.matchName)
                            let wantA = presetA.plan.operations.map(\.matchName)
                            func blockStart(_ want: [String], from: Int) -> Int? {
                                guard !want.isEmpty else { return nil }
                                for s in from...(max(from, order.count - want.count)) where s + want.count <= order.count {
                                    if Array(order[s..<(s + want.count)]) == want { return s }
                                }
                                return nil
                            }
                            guard let startB = blockStart(wantB, from: 0),
                                  let startA = blockStart(wantA, from: startB + wantB.count) else {
                                log.error("VERDICT : ÉCHEC — blocs A/B introuvables dans l'ordre attendu (B au-dessus de A)")
                                exit(3)
                            }
                            log.info("VERDICT : OK — B (\(presetB.title)) en [\(startB)…], A (\(presetA.title)) en [\(startA)…] : le dernier appliqué est bien AU-DESSUS")
                            exit(0)
                        }
                    }
                }
            }
        }
    }
    RunLoop.main.run()

case "index-preview":
    // Aperçu HORS LIGNE de l'index : effets du snapshot existant + presets
    // reparsés (fichier utilisateur + Adobe) → statistiques (alias d'effets
    // renommés, presets partiels) SANS écrire le snapshot ni requérir Premiere.
    // `index-preview <fichiers.prfpset…>` : ces fichiers REMPLACENT ceux de
    // l'utilisateur — « que verrait un monteur qui a CETTE bibliothèque ? »
    // (pack acheté, presets d'un ami). Les effets restent ceux de ce Premiere.
    guard let snapshot = IndexStore.loadSnapshot() else {
        log.error("Pas de snapshot — lancer d'abord : khanjar index-build (ou l'app)"); exit(1)
    }
    let effects = snapshot.items.filter { $0.kind == "effect" }.compactMap { item -> IndexStore.EffectEntry? in
        guard let mn = item.plan.operations.first?.matchName else { return nil }
        return IndexStore.EffectEntry(matchName: mn, displayName: item.title)
    }
    let libraryFiles = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    var userPresets: [ParsedPreset] = []
    var factoryPresets: [ParsedPreset] = []
    if libraryFiles.isEmpty {
        if let file = IndexStore.userPresetFile(hostVersion: snapshot.premiereVersion) {
            userPresets = (try? PrfpsetParser.parse(fileURL: file)) ?? []
        }
        for file in IndexStore.factoryPresetFiles(hostVersion: snapshot.premiereVersion, locale: "en_US") {
            factoryPresets.append(contentsOf: (try? PrfpsetParser.parse(fileURL: file)) ?? [])
        }
    } else {
        for file in libraryFiles {
            do { userPresets.append(contentsOf: try PrfpsetParser.parse(fileURL: file)) }
            catch { log.error("\(file.lastPathComponent) illisible : \(error)") }
        }
        // Bilan : ce qui entre dans la palette, et pourquoi le reste n'y entre pas
        // (même règle que la palette : IndexStore.exclusionReason).
        let addable = Set(effects.map(\.matchName))
        var excluded: [String: Int] = [:]
        var missing: [String: Int] = [:]
        for preset in userPresets {
            if let reason = IndexStore.exclusionReason(preset, addable: addable) {
                excluded[reason, default: 0] += 1
                if reason != "effets absents" { continue }
            }
            let video = preset.effects.filter { $0.kind == "video" }
            for effect in IndexStore.resolveAliases(video, addable: addable).effects
            where !addable.contains(effect.matchName) && !IndexStore.intrinsicMatchNames.contains(effect.matchName) {
                missing[effect.matchName, default: 0] += 1
            }
        }
        log.info("Bibliothèque : \(userPresets.count) presets lus dans \(libraryFiles.count) fichier(s)")
        let excludedList = excluded.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        log.info("  écartés : \(excludedList.isEmpty ? "aucun" : excludedList.joined(separator: ", "))")
        let absentList = missing.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }
        log.info("  effets absents de ce Premiere : \(absentList.isEmpty ? "aucun" : absentList.joined(separator: ", "))")
    }
    let items = IndexStore.build(effects: effects, userPresets: userPresets, factoryPresets: factoryPresets)
    let presets = items.filter { $0.kind == "preset" }
    let aliased = presets.filter { $0.fidelityHint.contains("aliased:") }
    let partial = presets.filter { PaletteWindowController.partialNote($0.fidelityHint) != nil }
    log.info("Aperçu index (effets du snapshot \(snapshot.premiereVersion)) : \(items.count) items = \(effects.count) effets + \(presets.count) presets (parsés : \(userPresets.count) user, \(factoryPresets.count) Adobe)")
    log.info("Presets rejoués via un alias d'effet renommé : \(aliased.count)")
    for p in aliased { log.info("  ↻ \(p.title) [\(p.fidelityHint)] → \(p.plan.operations.map(\.matchName).joined(separator: ", "))") }
    log.info("Presets partiels (badge « partiel ») : \(partial.count)")
    for p in partial.prefix(60) { log.info("  ◐ \(p.title) [\(p.fidelityHint)]") }
    exit(0)

case "plan-dump":
    // Diagnostic HORS LIGNE : le plan EXACT qu'appliquerait la palette pour un preset
    // (effets, paramètres et valeurs, keyframes), tel que compilé depuis le .prfpset.
    // Usage : plan-dump "<nom du preset>"
    guard let wanted = arguments.dropFirst().first else { log.error("Usage : plan-dump \"<nom du preset>\""); exit(2) }
    guard let snapshot = IndexStore.loadSnapshot() else { log.error("Pas de snapshot — lancer d'abord l'app"); exit(1) }
    let effectEntries = snapshot.items.filter { $0.kind == "effect" }.compactMap { item -> IndexStore.EffectEntry? in
        item.plan.operations.first.map { IndexStore.EffectEntry(matchName: $0.matchName, displayName: item.title) }
    }
    var presetsToPlan: [ParsedPreset] = []
    if let file = IndexStore.userPresetFile(hostVersion: snapshot.premiereVersion) {
        presetsToPlan = (try? PrfpsetParser.parse(fileURL: file)) ?? []
    }
    let norm = { (t: String) in t.trimmingCharacters(in: .whitespaces).lowercased() }
    let matches = IndexStore.build(effects: effectEntries, userPresets: presetsToPlan, factoryPresets: [])
        .filter { $0.kind == "preset" && norm($0.title) == norm(wanted) }
    guard let item = matches.first else { log.error("Aucun preset « \(wanted) » dans la palette (absent, ou écarté : voir index-excluded)"); exit(1) }
    log.info("\(item.title) [\(item.fidelityHint)]")
    for (label, ops) in [("ajoutés", item.plan.operations), ("intrinsèques", item.plan.existingOperations)] {
        for op in ops {
            let anchor = ["0": "étiré sur toute la durée du clip", "1": "collé au début du clip", "2": "collé à la fin du clip"][String(op.anchorType)] ?? "ancrage \(op.anchorType)"
            log.info("  \(label) : \(op.matchName) — \(op.params.count) réglages (paramCount \(op.paramCount)) — keyframes : \(anchor)")
            for prm in op.params {
                let value = !prm.keyframes.isEmpty ? "\(prm.keyframes.count) keyframes"
                    : prm.number.map { String($0) } ?? prm.bool.map { String($0) }
                    ?? (prm.point != nil ? "point" : prm.color != nil ? "couleur" : "?")
                log.info("    [\(prm.index)] \(prm.name) = \(value)")
            }
        }
    }
    exit(0)

case "login-item":
    // Démarrage de Khanjar avec la session : même mécanisme que la case de l'écran
    // d'accueil (SMAppService). À lancer depuis le binaire DANS Khanjar.app, sinon
    // macOS ne sait pas quelle app inscrire. Usage : login-item on|off|status
    guard #available(macOS 13.0, *) else { log.error("Démarrage auto : macOS 13 ou plus récent requis"); exit(1) }
    guard Bundle.main.bundleURL.pathExtension == "app" else {
        log.error("À lancer depuis Khanjar.app/Contents/MacOS/Khanjar"); exit(2)
    }
    let loginService = SMAppService.mainApp
    do {
        switch arguments.dropFirst().first {
        case "on": try loginService.register()
        case "off": try loginService.unregister()
        default: break
        }
    } catch { log.error("Démarrage auto : \(error.localizedDescription)"); exit(1) }
    let loginState: String
    switch loginService.status {
    case .enabled: loginState = "activé"
    case .requiresApproval: loginState = "en attente de ton accord dans Réglages Système > Général > Ouverture"
    case .notRegistered: loginState = "désactivé"
    default: loginState = "introuvable"
    }
    log.info("Démarrage de Khanjar avec la session : \(loginState) (\(Bundle.main.bundlePath))")
    exit(0)

case "render-media":
    // Images du README, dessinées par les VRAIES vues de Khanjar avec des exemples
    // neutres (aucun preset personnel). Usage : render-media <dossier>
    // Produit : palette (fréquents, recherche) en sombre et clair, frames d'une
    // frappe « gauss » pour l'animation, réglages, accueil.
    guard let outDir = arguments.dropFirst().first.map({ URL(fileURLWithPath: $0) }) else {
        log.error("Usage : render-media <dossier>"); exit(2)
    }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    func demo(_ title: String, _ subtitle: String, kind: String = "preset", hint: String = "full") -> SearchItem {
        SearchItem(id: "\(kind):demo-\(title)", kind: kind, title: title, subtitle: subtitle, keywords: [],
                   plan: ApplyPlan(label: title, operations: [.init(matchName: "AE.ADBE Gaussian Blur 2")]),
                   fidelityHint: hint)
    }
    let mine = "Preset · My Presets"
    let slideUp = demo("Slide Up Text", mine), glow = demo("Glow + Shadow", mine)
    let demoFrequent: [(item: SearchItem, count: Int)] = [
        (glow, 214),
        (SearchItem.combining(slideUp, glow, pairCount: 38) ?? slideUp, 38),
        (slideUp, 96), (demo("Film Grain", mine), 61), (demo("Zoom In 120%", "Preset · Transitions"), 44),
        (demo("Gaussian Blur", L("Video effect"), kind: "effect"), 40), (demo("Cinematic Vignette", "Preset · Color"), 27),
        (demo("Drop Shadow", L("Video effect"), kind: "effect"), 19),
    ]
    let demoCatalog: [SearchItem] = demoFrequent.map(\.item) + [
        demo("Gaussian Blur Fade In", "Preset · Transitions"), demo("Gaussian Blur Fade Out", "Preset · Transitions"),
        demo("Camera Blur", L("Video effect"), kind: "effect"), demo("Directional Blur", L("Video effect"), kind: "effect"),
        demo("Glow Pulse", mine), demo("True Drop Shadow", mine), demo("Tint", L("Video effect"), kind: "effect"),
        demo("Fast Blur In", L("Adobe preset") + " · Blurs"), demo("Lens Distortion", L("Video effect"), kind: "effect"),
        demo("Mosaic", L("Video effect"), kind: "effect"), demo("Wave Warp", L("Video effect"), kind: "effect"),
        demo("Glitch Reveal", "Preset · Transitions", hint: "params:12/14"),
    ]
    let preparedDemo = Scorer.prepare(demoCatalog)
    let palette = PaletteWindowController()
    palette.maxResults = 8
    palette.onFrequent = { limit in Array(demoFrequent.prefix(limit)) }
    palette.onQuery = { query in Scorer.rank(query: query, prepared: preparedDemo, limit: 8) }
    func write(_ data: Data?, _ name: String) {
        guard let data else { log.error("Rendu raté : \(name)"); return }
        try? data.write(to: outDir.appendingPathComponent(name))
        log.info("  \(name) (\(data.count / 1024) Ko)")
    }
    for dark in [true, false] {
        let mode = dark ? "dark" : "light"
        write(palette.snapshotPNG(query: "", dark: dark), "palette-frequent-\(mode).png")
        write(palette.snapshotPNG(query: "blur", dark: dark), "palette-search-\(mode).png")
        write(palette.snapshotPNG(query: "tds", dark: dark), "palette-initials-\(mode).png")
    }
    // Frappe lettre par lettre (frames de l'animation du README)
    for (i, q) in ["", "g", "ga", "gau", "gaus", "gauss"].enumerated() {
        write(palette.snapshotPNG(query: q, dark: true), String(format: "typing-%02d.png", i))
    }
    let settingsStore = SettingsStore()
    var demoSettings = Settings.default
    demoSettings.presetShortcuts = [
        PresetShortcut(itemId: glow.id, title: glow.title, shortcut: "ctrl+alt+g"),
        PresetShortcut(itemId: slideUp.id, title: slideUp.title, shortcut: "ctrl+alt+s"),
        PresetShortcut(itemId: "effect:demo-Gaussian Blur", title: "Gaussian Blur", shortcut: "ctrl+alt+b"),
    ]
    settingsStore.preview(demoSettings)   // en mémoire seulement
    let settingsWindow = SettingsWindowController(store: settingsStore)
    write(settingsWindow.snapshotPNG(dark: true), "settings-dark.png")
    let welcome = OnboardingWindowController()
    welcome.statusProvider = { LF("Connected — Premiere %@ · plugin %@", "26.5.2", "0.7.2") }
    welcome.paletteShortcutProvider = { "⌘J" }
    write(welcome.snapshotPNG(dark: true), "welcome-dark.png")
    exit(0)

case "index-excluded":
    // Diagnostic HORS LIGNE : chaque preset ÉCARTÉ de la palette, avec sa raison
    // (masque, couleur Lumetri, audio seul, effets absents de cette installation)
    // et le détail de ses effets (paramètres opaques « Arb » compris, avec une
    // empreinte de leur contenu pour comparer d'un preset à l'autre).
    // Usage : index-excluded <sortie.json>
    guard let out = arguments.dropFirst().first else { log.error("Usage : index-excluded <sortie.json>"); exit(2) }
    guard let snapshot = IndexStore.loadSnapshot() else { log.error("Pas de snapshot — lancer d'abord l'app"); exit(1) }
    let addable = Set(snapshot.items.filter { $0.kind == "effect" }.compactMap { $0.plan.operations.first?.matchName })
    var sources: [(String, [ParsedPreset])] = []
    if let file = IndexStore.userPresetFile(hostVersion: snapshot.premiereVersion) { sources.append(("user", (try? PrfpsetParser.parse(fileURL: file)) ?? [])) }
    var adobe: [ParsedPreset] = []
    for file in IndexStore.factoryPresetFiles(hostVersion: snapshot.premiereVersion, locale: "en_US") {
        adobe.append(contentsOf: (try? PrfpsetParser.parse(fileURL: file)) ?? [])
    }
    sources.append(("adobe", adobe))
    var report: [[String: Any]] = []
    for (source, presets) in sources {
        for preset in presets {
            guard let reason = IndexStore.exclusionReason(preset, addable: addable) else { continue }
            report.append([
                "source": source, "name": preset.name, "folder": preset.binPath.joined(separator: "/"),
                "reason": reason,
                "effects": preset.effects.map { e -> [String: Any] in [
                    "matchName": e.matchName, "displayName": e.displayName, "kind": e.kind,
                    "addable": addable.contains(e.matchName), "paramCount": e.paramCount,
                    "arbParamCount": e.arbParamCount, "maskCount": e.maskCount,
                    "params": e.params.map { prm -> [String: Any] in [
                        "index": prm.index, "name": prm.name, "controlType": prm.controlType,
                        "arb": prm.isArb, "timeVarying": prm.isTimeVarying,
                        "value": prm.isArb ? "" : String(prm.authoredValueRaw.prefix(80)),
                        "arbLength": prm.isArb ? prm.authoredValueRaw.count : 0,
                        "arbHash": prm.isArb ? String(prm.authoredValueRaw.hashValue & 0xFFFFFFFF, radix: 16) : "",
                    ] },
                ] },
            ])
        }
    }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: out))
    var byReason: [String: Int] = [:]
    for r in report { byReason["\(r["source"]!)/\(r["reason"]!)", default: 0] += 1 }
    log.info("Presets écartés : \(report.count) → \(byReason.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) — détail : \(out)")
    exit(0)

case "frequents":
    // Vérifie HORS LIGNE le classement « fréquence + récence » de la palette :
    // amorce l'historique depuis helper.log si besoin, puis imprime le top N
    // tel que la palette l'affichera. Usage : frequents [N]
    guard let snapshot = IndexStore.loadSnapshot() else {
        log.error("Pas de snapshot — lancer d'abord l'app (ou index-build)"); exit(1)
    }
    let limit = Int(arguments.dropFirst().first ?? "") ?? 10
    let usage = UsageStore()
    usage.load()
    usage.seedIfNeeded(items: snapshot.items)
    let lookup = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let ranked = usage.top(limit)
    guard !ranked.isEmpty else {
        log.info("Classement vide : aucune application enregistrée pour l'instant.")
        exit(0)
    }
    // Duos détectés : exactement ce que la palette met en tête de liste.
    let duos = usage.topPairs(AppCoordinator.maxCombosShown)
    log.info("── Duos détectés (≥ \(UsageStore.minPairObservations) enchaînements à moins de \(Int(UsageStore.pairWindowSeconds)) s) ──")
    if duos.isEmpty { log.info("  aucun") }
    for pair in duos {
        guard let a = lookup[pair.from], let b = lookup[pair.to] else {
            log.info("  ⚠️ duo ignoré : membre absent de l'index (\(pair.from) → \(pair.to))"); continue
        }
        guard let combo = SearchItem.combining(a, b, pairCount: pair.count) else {
            log.info("  ⚠️ fusion refusée : \(a.title) + \(b.title) (intrinsèques en conflit ou plan trop lourd)"); continue
        }
        let stack = combo.plan.operations.map { $0.matchName.replacingOccurrences(of: "AE.ADBE ", with: "") }
        log.info("  ★ \(combo.title)  — \(pair.count) fois")
        log.info("      pile obtenue (haut→bas) : \(stack.joined(separator: " › "))")
        log.info("      un seul Cmd+Z au lieu de deux")
    }
    log.info("── Fréquents (demi-vie \(Int(UsageStore.halfLifeDays)) j) — ce que ⌘J affichera ──")
    for (i, entry) in ranked.enumerated() {
        // Seules les 10 premières lignes portent un raccourci (⌘1…⌘9, ⌘0).
        let key = i < 9 ? "⌘\(i + 1)" : (i == 9 ? "⌘0" : "  ")
        let item = lookup[entry.id]
        let title = item?.title ?? "(disparu de l\'index)"
        let padded = title.count >= 32 ? String(title.prefix(31)) + "…"
                                       : title + String(repeating: " ", count: 32 - title.count)
        let uses = String(format: "%5d", entry.count)
        let score = String(format: "%7.2f", entry.score)
        log.info("  \(key)  \(padded) \(uses) ×   score \(score)   \(item?.subtitle ?? entry.id)")
    }
    exit(0)

case "crash-test":
    // Plantage VOLONTAIRE, pour vérifier la chaîne des rapports : macOS écrit
    // ~/Library/Logs/DiagnosticReports/khanjar-<date>.ips, que `crash-report` relit.
    // Le message porte un faux chemin et un faux nom de preset : ils doivent être
    // masqués dans l'événement produit.
    log.info("Plantage volontaire (crash-test)…")
    let fake = ["/Users/quelquun/Projets/Client secret/montage.prproj", "Preset « Mon client »"]
    fatalError("crash-test \"\(fake[1])\" in \(fake[0])")

case "crash-report":
    // Relit le dernier rapport de plantage de Khanjar (ou un .ips donné) et imprime
    // EXACTEMENT l'événement qui serait envoyé. `--send` l'envoie vraiment, avec
    // KHANJAR_SENTRY_DSN dans l'environnement. Usage : crash-report [fichier.ips] [--send]
    let send = arguments.contains("--send")
    let names: Set<String> = ["Khanjar", "khanjar"]  // app + binaire CLI (crash-test)
    let target: (url: URL, report: CrashReporter.Report)?
    if let path = arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
        let url = URL(fileURLWithPath: path)
        target = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { CrashReporter.parse($0, acceptedNames: names) }.map { (url, $0) }
    } else {
        target = CrashReporter.pendingReports(alreadySent: [], acceptedNames: names).first
    }
    guard let (url, report) = target else {
        log.error("Aucun rapport de plantage de Khanjar lisible (14 derniers jours)"); exit(1)
    }
    log.info("Rapport : \(url.lastPathComponent)")
    let event = CrashReporter.event(for: report, pluginVersion: nil)
    if let data = try? JSONSerialization.data(withJSONObject: event, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    guard send else { exit(0) }
    guard let dsn = CrashReporter.configuredDSN, let endpoint = CrashReporter.endpoint(dsn: dsn),
          let body = CrashReporter.envelope(event: event) else {
        log.error("--send : KHANJAR_SENTRY_DSN absent ou invalide"); exit(1)
    }
    var request = URLRequest(url: endpoint.url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
    request.setValue("Sentry sentry_version=7, sentry_key=\(endpoint.publicKey), sentry_client=khanjar/\(report.appVersion)",
                     forHTTPHeaderField: "X-Sentry-Auth")
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        log.info("Envoi : HTTP \(status) \(data.map { String(decoding: $0, as: UTF8.self) } ?? "") \(error.map { "\($0)" } ?? "")")
        done.signal()
    }.resume()
    done.wait()
    exit(0)

case "selftest":
    exit(SelfTest.run())

default:
    log.error("Mode inconnu : \(mode) (attendu : app | run | smoke | index-presets | index-preview | index-build | search | selftest | frequents | dump-selected | multi-test | apply-dump | anchor-test | stack-test | adj-test | fidelity-test | ease-probe | inspect-component | crash-test | crash-report | index-excluded | plan-dump | login-item | render-media)")
    exit(1)
}
