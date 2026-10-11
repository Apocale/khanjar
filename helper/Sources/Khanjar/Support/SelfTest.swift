import AppKit
import Foundation

/// Harnais de tests sans framework (les Command Line Tools n'embarquent pas
/// XCTest). Exécution : `khanjar selftest` — sortie 0 si tout passe.
/// Table de vérité de pertinence du scorer : on teste des ORDRES relatifs,
/// pas des valeurs absolues (docs/ARCHITECTURE.md §5.3 et §9).
enum SelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures.append(label)
            print("  ✗ \(label)")
        }
    }

    private static func item(_ title: String, keywords: [String] = []) -> SearchItem {
        SearchItem(id: "t:\(title)", kind: "effect", title: title, subtitle: "",
                   keywords: keywords,
                   plan: ApplyPlan(label: title, operations: []),
                   fidelityHint: "full")
    }

    static func run() -> Int32 {
        print("── SelfTest : Scorer ──")

        // Initiales : « TDS » = initiales de True Drop Shadow > lettres éparses
        check(Scorer.score(query: "tds", candidate: "True Drop Shadow")
                > Scorer.score(query: "tds", candidate: "Turbulent Displace"),
              "initiales « tds » > sous-séquence quelconque")

        // Préfixe de mot > infixe
        check(Scorer.score(query: "drop", candidate: "Drop Shadow")
                > Scorer.score(query: "drop", candidate: "Backdrop Blur"),
              "préfixe « drop » > infixe")

        // Exigence produit : « True Dr »
        check(Scorer.score(query: "true dr", candidate: "True Drop Shadow") > 0.3,
              "« true dr » trouve True Drop Shadow avec un bon score")

        // Insensibilité aux accents (UI française)
        check(Scorer.score(query: "gauss", candidate: "Flou gaussien") > 0.1,
              "« gauss » trouve Flou gaussien")
        check(Scorer.score(query: "video", candidate: "Effets vidéo") > 0.1,
              "« video » trouve Effets vidéo (accents pliés)")

        // Absence de correspondance
        check(Scorer.score(query: "xyzq", candidate: "Drop Shadow") == 0,
              "aucune correspondance → score 0")
        check(Scorer.score(query: "", candidate: "Drop Shadow") == 0,
              "requête vide → score 0")

        // Mots-clés cherchables mais décotés vs titre
        let viaKeyword = Scorer.score(query: "lumetri", item: item("Mon look", keywords: ["Lumetri Color"]))
        let viaTitle = Scorer.score(query: "lumetri", item: item("Lumetri Color"))
        check(viaKeyword > 0.1 && viaTitle > viaKeyword,
              "mots-clés cherchables mais décotés (\(f(viaKeyword)) < \(f(viaTitle)))")

        // rank : ordre, seuil, limite
        let items = [item("Gaussian Blur"), item("Camera Blur"), item("Drop Shadow"), item("Channel Blur")]
        let ranked = Scorer.rank(query: "blur", items: items, limit: 2)
        check(ranked.count == 2 && ranked.allSatisfy { $0.item.title.localizedCaseInsensitiveContains("blur") },
              "rank limite et filtre correctement")

        // Budget perf §10 : < 5 ms/frappe sur 1 200 items (marge : seuil 50 ms en debug)
        let bigIndex = (0..<1200).map { item("Preset numéro \($0) Drop Shadow Édition") }
        let started = Date()
        _ = Scorer.rank(query: "drsh", items: bigIndex, limit: 8)
        let elapsed = Date().timeIntervalSince(started)
        check(elapsed < 0.05, "budget perf : rank 1200 items en \(Int(elapsed * 1000)) ms (< 50 ms)")

        // ── Classement fréquence + récence (UsageStore) ──
        print("── SelfTest : Fréquents (fréquence + récence) ──")
        let day = 86_400.0
        let now = Date()
        let store = UsageStore(inMemory: true)

        // Un usage vieux d'une demi-vie vaut la moitié d'un usage d'aujourd'hui.
        store.record(id: "vieux", title: "Vieux", at: now.addingTimeInterval(-UsageStore.halfLifeDays * day))
        store.record(id: "frais", title: "Frais", at: now)
        let scores = Dictionary(uniqueKeysWithValues: store.top(10, now: now).map { ($0.id, $0.score) })
        check(abs((scores["vieux"] ?? 0) - 0.5) < 0.01,
              "décote : un usage d'il y a \(Int(UsageStore.halfLifeDays)) j vaut 0,5 (mesuré \(f(scores["vieux"] ?? 0)))")
        check(abs((scores["frais"] ?? 0) - 1.0) < 0.01, "un usage d'aujourd'hui vaut 1")

        // LE point du mélange : peu mais récent doit battre beaucoup mais ancien.
        let mix = UsageStore(inMemory: true)
        for _ in 0..<20 { mix.record(id: "ancien", title: "Ancien", at: now.addingTimeInterval(-120 * day)) }
        for _ in 0..<3  { mix.record(id: "recent", title: "Récent", at: now) }
        let order = mix.top(10, now: now).map(\.id)
        check(order.first == "recent",
              "3 usages d'aujourd'hui passent devant 20 usages d'il y a 4 mois (ordre : \(order))")

        // La fréquence reste décisive à récence égale.
        let tie = UsageStore(inMemory: true)
        for _ in 0..<5 { tie.record(id: "souvent", title: "Souvent", at: now) }
        tie.record(id: "rare", title: "Rare", at: now)
        check(tie.top(10, now: now).map(\.id) == ["souvent", "rare"],
              "à récence égale, le plus fréquent passe devant")

        // Le compteur affiché reste le nombre brut, jamais le score décoté.
        check(tie.top(10, now: now).first?.count == 5, "le compteur affiché est le nombre brut d'applications")

        // ── Duos : détection des enchaînements et fusion des plans ──
        print("── SelfTest : Duos (enchaînements) ──")
        let t0 = Date()
        func planned(_ id: String, _ title: String, ops: [String], intrinsics: [String] = []) -> SearchItem {
            SearchItem(id: id, kind: "preset", title: title, subtitle: "", keywords: [],
                       plan: ApplyPlan(label: title,
                                       operations: ops.map { ApplyPlan.Operation(matchName: $0) },
                                       existingOperations: intrinsics.map { ApplyPlan.Operation(matchName: $0) }),
                       fidelityHint: "full")
        }

        // 2026-10-09 (audit A3#1, décision Q4) : un enchaînement ne compte que sur
        // un MÊME clip, et un sens n'est retenu qu'à 3 contre 1. Ces cas remplacent
        // ceux de la règle précédente (tout enchaînement < 120 s, majorité simple).
        // `chain` : n fois « from sur un clip, puis to », à 8 s d'écart, une heure
        // entre deux séries ; `clipsTo` décide le clip de la 2ᵉ application.
        func chain(_ store: UsageStore, _ from: String, _ to: String, times: Int, start: Date,
                   gap: Double = 8, clipsTo: (Int) -> [String] = { ["clip \($0)"] }) {
            for i in 0..<times {
                let base = start.addingTimeInterval(Double(i) * 3600)
                store.record(id: from, title: from.uppercased(), clips: ["clip \(i)"], at: base)
                store.record(id: to, title: to.uppercased(), clips: clipsTo(i), at: base.addingTimeInterval(gap))
            }
        }

        // Même clip, dans la fenêtre → duo.
        let near = UsageStore(inMemory: true)
        chain(near, "a", "b", times: 5, start: t0)
        check(near.topPairs(5, now: t0).first.map { $0.from == "a" && $0.to == "b" && $0.count == 5 } == true,
              "5 enchaînements A→B sur le même clip détectés comme duo")

        // Clips disjoints : A sur un clip, B sur le suivant → deux gestes indépendants.
        let disjoint = UsageStore(inMemory: true)
        chain(disjoint, "a", "b", times: 8, start: t0, clipsTo: { ["clip \($0 + 100)"] })
        check(disjoint.topPairs(5, now: t0).isEmpty, "clips disjoints : aucun duo, même 8 fois de suite")

        // Clips inconnus (rejeu du journal, appelant sans clips) → rien.
        let blind = UsageStore(inMemory: true)
        for i in 0..<6 {
            let base = t0.addingTimeInterval(Double(i) * 3600)
            blind.record(id: "a", title: "A", at: base)
            blind.record(id: "b", title: "B", at: base.addingTimeInterval(8))
        }
        check(blind.topPairs(5, now: t0).isEmpty, "sans liste de clips, aucun enchaînement compté")

        let far = UsageStore(inMemory: true)
        chain(far, "a", "b", times: 5, start: t0, gap: UsageStore.pairWindowSeconds + 30)
        check(far.topPairs(5, now: t0).isEmpty, "au-delà de \(Int(UsageStore.pairWindowSeconds)) s, aucun duo")

        // Sous le seuil de répétition, rien n'est proposé.
        let rare = UsageStore(inMemory: true)
        chain(rare, "a", "b", times: UsageStore.minPairObservations - 1, start: t0)
        check(rare.topPairs(5, now: t0).isEmpty, "sous \(UsageStore.minPairObservations) observations, aucun duo proposé")

        // 5 contre 3 : habitude ambiguë → pas de duo (avant : duo de 8, sens à la majorité).
        let ambiguous = UsageStore(inMemory: true)
        chain(ambiguous, "x", "y", times: 5, start: t0)
        chain(ambiguous, "y", "x", times: 3, start: t0.addingTimeInterval(20 * 3600))
        check(ambiguous.topPairs(5, now: t0).isEmpty, "5 contre 3 : aucun duo (il faut 3 contre 1)")

        // 9 contre 3 : sens majoritaire retenu, compte = ce sens seul.
        let clear = UsageStore(inMemory: true)
        chain(clear, "x", "y", times: 9, start: t0)
        chain(clear, "y", "x", times: 3, start: t0.addingTimeInterval(20 * 3600))
        let kept = clear.topPairs(5, now: t0)
        check(kept.count == 1 && kept[0].from == "x" && kept[0].to == "y" && kept[0].count == 9,
              "9 contre 3 : duo X→Y, compté 9 fois (sens retenu seul)")

        // Un enchaînement plus vu depuis 60 jours ne compte plus.
        let old = UsageStore(inMemory: true)
        chain(old, "a", "b", times: 5, start: t0)
        let lastChain = t0.addingTimeInterval(4 * 3600 + 8)
        check(old.topPairs(5, now: lastChain.addingTimeInterval(59 * day)).count == 1
                && old.topPairs(5, now: lastChain.addingTimeInterval(61 * day)).isEmpty,
              "duo gardé à 59 jours, ignoré à 61 jours")

        // Répéter le même item n'est pas un duo.
        let same = UsageStore(inMemory: true)
        for i in 0..<6 { same.record(id: "a", title: "A", clips: ["clip"], at: t0.addingTimeInterval(Double(i) * 10)) }
        check(same.topPairs(5, now: t0).isEmpty, "le même item répété ne fabrique pas un duo")

        // Se servir du duo le crédite (membres + enchaînement) quand les clips sont connus.
        let used = UsageStore(inMemory: true)
        for _ in 0..<UsageStore.minPairObservations { used.recordCombo(from: "a", to: "b", clips: ["clip"]) }
        check(used.topPairs(5).first.map { $0.from == "a" && $0.to == "b" } == true
                && used.top(5).map(\.count) == [4, 4],
              "appliquer le duo crédite ses deux membres et l'enchaînement")

        // usage.json v2 (enchaînements comptés sans clip) : enchaînements jetés, compteurs gardés.
        let usageDir = FileManager.default.temporaryDirectory.appendingPathComponent("khanjar-usage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        let v2File = usageDir.appendingPathComponent("usage.json")
        let v2 = #"{"version":2,"seeded":true,"seededPairs":true,"entries":{"a":{"count":40,"score":3.5,"lastUsed":"2026-10-01T10:00:00Z","title":"A"},"b":{"count":30,"score":2.5,"lastUsed":"2026-10-01T10:00:00Z","title":"B"}},"transitions":{"a":{"b":45},"b":{"a":51}}}"#
        try? Data(v2.utf8).write(to: v2File)
        let migrated = UsageStore(fileURL: v2File)
        migrated.load()
        check(migrated.topPairs(5).isEmpty && migrated.top(5).map(\.count) == [40, 30],
              "usage.json v2 : enchaînements remis à zéro, compteurs gardés")
        let rewritten = (try? JSONSerialization.jsonObject(with: Data(contentsOf: v2File))) as? [String: Any]
        check(rewritten?["version"] as? Int == UsageStore.payloadVersion && rewritten?["transitions"] == nil,
              "usage.json réécrit en v\(UsageStore.payloadVersion), sans les anciens enchaînements")
        try? FileManager.default.removeItem(at: usageDir)

        // Fusion : B d'abord dans le plan = B au-dessus dans la pile.
        let first = planned("p1", "Edge", ops: ["Roughen", "Shadow"])
        let second = planned("p2", "Flou", ops: ["Blur"])
        let combo = SearchItem.combining(first, second, pairCount: 43)
        check(combo?.plan.operations.map(\.matchName) == ["Blur", "Roughen", "Shadow"],
              "plan fusionné : le second appliqué est listé en premier (donc au-dessus)")
        check(combo?.comboMembers.map { $0.from == "p1" && $0.to == "p2" } == true,
              "le duo retient ses deux membres dans l'ordre d'application")
        check(combo?.isCombo == true && combo?.kind == "combo", "le duo est marqué comme tel")

        // Refus : même intrinsèque des deux côtés (keyframes qui se mélangent).
        let o1 = planned("p3", "Fade", ops: ["Blur"], intrinsics: ["AE.ADBE Opacity"])
        let o2 = planned("p4", "Slide", ops: ["Geom"], intrinsics: ["AE.ADBE Opacity"])
        check(SearchItem.combining(o1, o2, pairCount: 10) == nil,
              "fusion refusée quand les deux plans animent le même intrinsèque")
        let o3 = planned("p5", "Move", ops: ["Geom"], intrinsics: ["AE.ADBE Motion"])
        check(SearchItem.combining(o1, o3, pairCount: 10) != nil,
              "fusion acceptée quand les intrinsèques diffèrent")
        check(SearchItem.combining(combo!, first, pairCount: 10) == nil, "pas de duo de duo")
        check(SearchItem.combining(first, second, pairCount: 43, maxOperations: 2) == nil,
              "fusion refusée au-delà du plafond d'opérations")

        // ── Reprise des données de Dagger (renommage en Khanjar) ──
        print("── SelfTest : Reprise Dagger → Khanjar ──")
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("khanjar-selftest-\(UUID().uuidString)")
        let oldDir = sandbox.appendingPathComponent("Dagger")
        let newDir = sandbox.appendingPathComponent("Khanjar")
        try? fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        for name in ["settings.json", "usage.json", "index.json", ".onboarded", ".instance.lock"] {
            try? Data("contenu \(name)".utf8).write(to: oldDir.appendingPathComponent(name))
        }
        let copied = LegacyMigration.run(supportDir: sandbox)
        check(Set(copied) == ["settings.json", "usage.json", "index.json", ".onboarded"],
              "réglages, historique, index et marqueur d'accueil repris (\(copied.sorted()))")
        check(!fm.fileExists(atPath: newDir.appendingPathComponent(".instance.lock").path),
              "le verrou d'instance n'est jamais copié")
        check(fm.fileExists(atPath: oldDir.appendingPathComponent("usage.json").path),
              "l'ancien dossier reste intact (copie, pas déplacement)")
        check((try? String(contentsOf: newDir.appendingPathComponent("usage.json"), encoding: .utf8)) == "contenu usage.json",
              "le contenu repris est identique")
        check(LegacyMigration.run(supportDir: sandbox).isEmpty,
              "deuxième lancement : rien n'est recopié par-dessus")
        try? Data("nouveau".utf8).write(to: oldDir.appendingPathComponent("usage.json"))
        _ = LegacyMigration.run(supportDir: sandbox)
        check((try? String(contentsOf: newDir.appendingPathComponent("usage.json"), encoding: .utf8)) == "contenu usage.json",
              "une fois Khanjar en place, l'ancien dossier ne l'écrase jamais")
        let fresh = fm.temporaryDirectory.appendingPathComponent("khanjar-selftest-\(UUID().uuidString)")
        check(LegacyMigration.run(supportDir: fresh).isEmpty, "nouvel utilisateur sans Dagger : rien à reprendre")
        try? fm.removeItem(at: sandbox)

        // ── Rapports de plantage : rien de personnel ne doit partir ──
        print("── SelfTest : Rapports de plantage (anonymat) ──")
        // Rapport macOS réduit, truffé de données personnelles volontaires.
        let ipsHeader = #"{"app_name":"Khanjar","app_version":"0.8.0","name":"Khanjar","os_version":"macOS 26.6.2 (25G83)","timestamp":"2026-10-06 20:53:28.00 +0200","incident_id":"ABCD-1234","slice_uuid":"8681f71f-529e-37d3-ad84-b091673468e4"}"#
        let ipsBody = #"{"procPath":"/Applications/Khanjar.app/Contents/MacOS/Khanjar","userID":501,"crashReporterKey":"SECRET-KEY-42","bootSessionUUID":"BOOT-UUID","modelCode":"Mac14,2","parentProc":"launchd","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"asi":{"libswiftCore.dylib":["Khanjar/AppCoordinator.swift:42: Fatal error: preset \"Mon client secret\" introuvable dans /Users/quelquun/Projets/Client/montage.prproj"]},"faultingThread":0,"threads":[{"frames":[{"imageIndex":1,"imageOffset":1000,"symbol":"_assertionFailure(_:_:file:line:flags:)"},{"imageIndex":0,"imageOffset":2000,"symbol":"AppCoordinator.apply(_:)"},{"imageIndex":2,"imageOffset":3000}]},{"frames":[{"imageIndex":0,"imageOffset":9,"symbol":"AutreFil.secret()"}]}],"usedImages":[{"name":"Khanjar","path":"/Applications/Khanjar.app/Contents/MacOS/Khanjar"},{"name":"libswiftCore.dylib","path":"/usr/lib/swift/libswiftCore.dylib"},{"name":"dyld","path":"/usr/lib/dyld"}]}"#
        let crash = CrashReporter.parse(ipsHeader + "\n" + ipsBody)
        check(crash != nil, "rapport macOS lu")
        if let crash {
            let event = CrashReporter.event(for: crash, pluginVersion: "0.7.0")
            let wire = String(decoding: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), as: UTF8.self)
            let forbidden = ["/Users/", "quelquun", "Mon client secret", "SECRET-KEY-42", "BOOT-UUID", "Mac14,2",
                             "launchd", "/Applications/", "AutreFil", "ABCD-1234", "501"]
            let leaked = forbidden.filter { wire.contains($0) }
            check(leaked.isEmpty, "aucune donnée personnelle dans l'événement envoyé (fuites : \(leaked))")
            check(wire.contains("montage.prproj") == false || !wire.contains("Projets"),
                  "un chemin ne garde au plus que le nom du fichier")
            check(crash.message?.contains("Fatal error") == true && crash.message?.contains("\"…\"") == true,
                  "message d'erreur Swift gardé, texte entre guillemets masqué")
            check(crash.frames.map(\.function) == ["_assertionFailure(_:_:file:line:flags:)", "AppCoordinator.apply(_:)", "dyld + 3000"],
                  "pile du fil fautif seulement, symbole absent remplacé par bibliothèque + décalage")
            let frames = ((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first
                .flatMap { ($0["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] } ?? []
            check(frames.first?["package"] as? String == "dyld" && frames.last?["package"] as? String == "libswiftCore.dylib",
                  "ordre Sentry : appelant le plus externe en premier")
            check(frames.filter { $0["in_app"] as? Bool == true }.map { $0["function"] as? String } == ["AppCoordinator.apply(_:)"],
                  "seules les fonctions de Khanjar sont marquées « in_app »")
            check(event["environment"] as? String == "beta" && event["release"] as? String == "khanjar@0.8.0",
                  "version 0.x = bêta")
        }
        check(CrashReporter.parse(ipsHeader.replacingOccurrences(of: "Khanjar", with: "Premiere") + "\n" + ipsBody) == nil,
              "rapport d'une autre app ignoré")
        check(CrashReporter.endpoint(dsn: "https://abc123@o42.ingest.de.sentry.io/4507")
                == .init(url: URL(string: "https://o42.ingest.de.sentry.io/api/4507/envelope/")!, publicKey: "abc123"),
              "DSN → point d'envoi des enveloppes")
        check(CrashReporter.endpoint(dsn: "https://o42.ingest.sentry.io/4507") == nil
                && CrashReporter.endpoint(dsn: "pas une adresse") == nil,
              "DSN sans clé ou invalide refusé (case jamais proposée)")
        if let crash, let env = CrashReporter.envelope(event: CrashReporter.event(for: crash, pluginVersion: nil)) {
            let lines = String(decoding: env, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let declared = lines.count > 1 ? (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])?["length"] as? Int : nil
            check(lines.count == 4 && declared == lines[2].utf8.count,
                  "enveloppe : en-tête, type, événement de la longueur annoncée")
        } else { check(false, "enveloppe construite") }

        // ── Décodage des paramètres opaques (Lumetri, masques) ──
        print("── SelfTest : Lumetri et masques décodés ──")
        // Masque vide réel des « Drop Shadow Preset » d'Isma : 2cin, v2, fermé, 0 sommet.
        check(ArbDecoding.maskVertexCount(ArbDecoding.bytes(fromBase64: "MmNpbgIAAAACAAAAAAAAAA==")!) == 0,
              "masque « 2cin » à 0 sommet reconnu vide")
        var ellipse = Data("2cin".utf8)
        for v: UInt32 in [2, 1, 4] { withUnsafeBytes(of: v.littleEndian) { ellipse.append(contentsOf: $0) } }
        ellipse.append(Data(count: 4 * 32))
        check(ArbDecoding.maskVertexCount(ellipse) == 4, "masque « 2cin » à 4 sommets reconnu non vide")
        check(ArbDecoding.maskVertexCount(Data([2, 0, 0, 0, 1, 0, 0, 0])) == 0, "masque AEMask2 de 8 octets = vide")
        func curve(_ points: [(Double, Double)]) -> Data {
            var block = Data()
            for v: UInt32 in [0, UInt32(points.count)] { withUnsafeBytes(of: v.littleEndian) { block.append(contentsOf: $0) } }
            for (x, y) in points {
                for d in [x, y] { withUnsafeBytes(of: d.bitPattern.littleEndian) { block.append(contentsOf: $0) } }
            }
            block.append(Data(count: 520 - block.count))
            return block
        }
        check(ArbDecoding.isNeutralLumetriArb(parameterID: 39, bytes: curve([(0, 0), (1, 1)])) == true,
              "courbe RGB identité = neutre")
        check(ArbDecoding.isNeutralLumetriArb(parameterID: 39, bytes: curve([(0, 0), (0.28, 0.25), (0.78, 0.81), (1, 1)])) == false,
              "courbe RGB en S (« Lumetri logan ») = utilisée")
        check(ArbDecoding.isNeutralLumetriArb(parameterID: 95, bytes: Data([0xFE, 0xFE])) == true
                && ArbDecoding.isNeutralLumetriArb(parameterID: 95, bytes: Data("A\0L\0E\0X\0A\0".utf8)) == false,
              "Input LUT vide = neutre, LUT nommée = utilisée")
        var wheels = Data()
        for d in [0.0, 0.5, 0.0, 0.0, 0.5, 0.0] { withUnsafeBytes(of: d.bitPattern.littleEndian) { wheels.append(contentsOf: $0) } }
        check(ArbDecoding.isNeutralLumetriArb(parameterID: 47, bytes: wheels) == true, "roues au centre = neutres")
        check(ArbDecoding.isNeutralLumetriArb(parameterID: 9999, bytes: Data([0xFE, 0xFE])) == nil,
              "paramètre Arb inconnu → indéterminé (le preset reste exclu)")
        let neutralParam = PresetParam(index: 0, name: "Blob", parameterID: "1", controlType: 0, isTimeVarying: false,
                                       authoredValueRaw: "", isArb: true, keyframes: [], arbNeutral: true)
        let usedParam = PresetParam(index: 1, name: "RGB Curves", parameterID: "39", controlType: 0, isTimeVarying: false,
                                    authoredValueRaw: "", isArb: true, keyframes: [], arbNeutral: false)
        let slider = PresetParam(index: 2, name: "Exposure", parameterID: "11", controlType: 8, isTimeVarying: false,
                                 authoredValueRaw: "-2.93", isArb: false, keyframes: [])
        func lumetri(_ params: [PresetParam]) -> PresetEffect {
            PresetEffect(matchName: "AE.ADBE Lumetri", displayName: "Lumetri Color", kind: "video",
                         paramCount: params.count, arbParamCount: params.filter(\.isArb).count, maskCount: 0,
                         params: params, anchorType: 0, srcDurationTicks: 0)
        }
        check(IndexStore.unreplayableReason([lumetri([neutralParam, slider])]) == nil,
              "Lumetri à curseurs seuls (Arb neutres) : n'est plus exclu")
        check(IndexStore.unreplayableReason([lumetri([neutralParam, usedParam, slider])]) == "couleur",
              "Lumetri avec une courbe : reste exclu")

        // ── I-02 (2026-10-09) : ids stables des presets, favoris fusionnés ──
        print("── SelfTest : Ids des presets (I-02) ──")
        // Petit .prfpset synthétique au schéma de Premiere : Root → Presets → dossiers → presets
        // (TreeItem → FilterPresetItem → FilterPreset → VideoFilterComponent → 1 paramètre).
        // `base` = premier numéro d'objet du preset ; `defOf` = preset dont on partage le
        // FilterPreset (un favori) ; `shortcut` = EffectIsShorcut.
        struct FakePreset {
            let name: String
            let base: Int
            var folder = "Pack"
            var value = "100."
            var shortcut = false
            var defOf: Int? = nil
        }
        func fakePrfpset(_ presets: [FakePreset]) -> String {
            func bin(_ oid: Int, _ name: String, _ items: [Int]) -> String {
                let refs = items.enumerated().map { "<Item Index=\"\($0.offset)\" ObjectRef=\"\($0.element)\"/>" }.joined()
                return "<BinTreeItem ObjectID=\"\(oid)\"><Items>\(refs)</Items><TreeItemBase><Name>\(name)</Name></TreeItemBase></BinTreeItem>\n"
            }
            var folders: [String] = []
            for p in presets where !folders.contains(p.folder) { folders.append(p.folder) }
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<PremiereData Version=\"3\">\n"
            xml += bin(1, "Root", [2]) + bin(2, "Presets", folders.indices.map { 3 + $0 })
            for (i, folder) in folders.enumerated() {
                xml += bin(3 + i, folder, presets.filter { $0.folder == folder }.map(\.base))
            }
            for p in presets {
                let def = (p.defOf ?? p.base) + 2
                xml += "<TreeItem ObjectID=\"\(p.base)\"><TreeItemBase><Name>\(p.name)</Name><Data ObjectRef=\"\(p.base + 1)\"/></TreeItemBase></TreeItem>\n"
                xml += "<FilterPresetItem ObjectID=\"\(p.base + 1)\" Version=\"2\"><EffectItem><EffectIsShorcut>\(p.shortcut)</EffectIsShorcut></EffectItem><FilterPresets><FilterPreset Index=\"0\" ObjectRef=\"\(def)\"/></FilterPresets></FilterPresetItem>\n"
                guard p.defOf == nil else { continue }
                xml += "<FilterPreset ObjectID=\"\(p.base + 2)\"><FilterMatchName>AE.ADBE Geometry2</FilterMatchName><Component ObjectRef=\"\(p.base + 3)\"/><AnchorInPoint>0</AnchorInPoint><AnchorOutPoint>254016000000</AnchorOutPoint><Type>0</Type></FilterPreset>\n"
                xml += "<VideoFilterComponent ObjectID=\"\(p.base + 3)\"><Component><DisplayName>Transform</DisplayName><Params><Param Index=\"0\" ObjectRef=\"\(p.base + 4)\"/></Params></Component></VideoFilterComponent>\n"
                xml += "<VideoComponentParam ObjectID=\"\(p.base + 4)\"><Keyframes></Keyframes><IsTimeVarying>false</IsTimeVarying><ParameterControlType>2</ParameterControlType><StartKeyframe>-91445760000000000,\(p.value),0,0,0,0,0,0</StartKeyframe><Name>Scale Height</Name></VideoComponentParam>\n"
            }
            return xml + "</PremiereData>\n"
        }
        let presetDir = fm.temporaryDirectory.appendingPathComponent("khanjar-presets-\(UUID().uuidString)")
        try? fm.createDirectory(at: presetDir, withIntermediateDirectories: true)
        func parsed(_ name: String, _ xml: String) -> [ParsedPreset] {
            let url = presetDir.appendingPathComponent("\(name).prfpset")
            try? Data(xml.utf8).write(to: url)
            return (try? PrfpsetParser.parse(fileURL: url)) ?? []
        }
        func uid(_ presets: [ParsedPreset], _ name: String) -> String? { presets.first { $0.name == name }?.uid }
        let transform = [IndexStore.EffectEntry(matchName: "AE.ADBE Geometry2", displayName: "Transform")]

        // Un preset ajouté en tête : Premiere renumérote les suivants.
        let before = parsed("avant", fakePrfpset([FakePreset(name: "Glide", base: 100),
                                                   FakePreset(name: "Swoop", base: 200, value: "150.")]))
        let after = parsed("apres", fakePrfpset([FakePreset(name: "Newcomer", base: 100, value: "80."),
                                                  FakePreset(name: "Glide", base: 200),
                                                  FakePreset(name: "Swoop", base: 300, value: "150.")]))
        check(uid(before, "Glide")?.hasPrefix("h:") == true && uid(before, "Glide") == uid(after, "Glide")
                && uid(before, "Swoop") == uid(after, "Swoop") && uid(before, "Glide") != uid(before, "Swoop"),
              "preset sans UID renuméroté par Premiere : même id (« \(uid(before, "Glide") ?? "?") »)")
        // Deux presets qui échangent leurs numéros d'objet.
        let swapped = parsed("echange", fakePrfpset([FakePreset(name: "Glide", base: 200),
                                                      FakePreset(name: "Swoop", base: 100, value: "150.")]))
        check(uid(swapped, "Glide") == uid(before, "Glide") && uid(swapped, "Swoop") == uid(before, "Swoop"),
              "deux presets qui échangent leurs numéros gardent chacun leur id")

        // Favori Premiere (dossier « Fav », mêmes FilterPreset que l'original) → une seule ligne.
        let withFav = parsed("favori", fakePrfpset([FakePreset(name: "Glide", base: 100),
                                                     FakePreset(name: "Glide", base: 400, folder: "Fav",
                                                                shortcut: true, defOf: 100)]))
        let favItems = IndexStore.build(effects: transform, userPresets: withFav, factoryPresets: [])
            .filter { $0.kind == "preset" }
        check(withFav.count == 1 && favItems.count == 1 && favItems.first?.keywords.contains("Fav") == true,
              "favori fusionné dans l'original : une seule ligne, dossier « Fav » cherchable")
        let lonelyFav = parsed("favori-seul", fakePrfpset([FakePreset(name: "Solo", base: 100, folder: "Fav", shortcut: true)]))
        check(lonelyFav.count == 1, "favori sans original : indexé normalement")

        // Une 2ᵉ référence au même preset dans un dossier (fichier abîmé) est ignorée.
        let doubled = parsed("double", fakePrfpset([FakePreset(name: "Glide", base: 100)])
            .replacingOccurrences(of: "<Item Index=\"0\" ObjectRef=\"100\"/>",
                                  with: "<Item Index=\"0\" ObjectRef=\"100\"/><Item Index=\"1\" ObjectRef=\"100\"/>"))
        check(doubled.count == 1, "preset référencé deux fois : une seule ligne")

        // Perso et Adobe au même numéro : deux espaces d'ids distincts.
        let both = IndexStore.build(effects: transform, userPresets: before, factoryPresets: before)
            .filter { $0.kind == "preset" && $0.title == "Glide" }
        check(both.count == 2 && Set(both.map(\.id)).count == 2
                && both.filter(\.isUserPreset).count == 1
                && both.contains { $0.id.hasPrefix(SearchItem.adobePresetPrefix) },
              "preset perso et preset Adobe au même numéro : ids distincts (\(both.map(\.id)))")
        check(SearchItem.normalizedTitle("  Slide \u{A0} UP\ttext ") == "slide up text",
              "titre normalisé : minuscules, bords rognés, espaces (insécables comprises) repliés")

        // Migration : les entrées « preset:obj:<n> » d'usage.json sont rattachées par le titre.
        let catalog = [("preset:h:glide", "Glide"), ("preset:h:swoop", "Swoop"),
                       ("preset:h:twin1", "Twin"), ("preset:h:twin2", "Twin"), ("effect:AE.ADBE Mosaic", "Mosaic")]
        let validIds = Set(catalog.map(\.0))
        var idsByTitle: [String: Set<String>] = [:]   // ids DISTINCTS par titre normalisé
        for (id, title) in catalog { idsByTitle[SearchItem.normalizedTitle(title), default: []].insert(id) }
        let idForTitle: (String) -> String? = { title in
            let ids = idsByTitle[SearchItem.normalizedTitle(title)] ?? []
            return ids.count == 1 ? ids.first : nil
        }
        let remap = UsageStore(inMemory: true)
        for i in 0..<4 {
            let at = t0.addingTimeInterval(Double(i) * 3600)
            remap.record(id: "preset:obj:12", title: "Glide", clips: ["c\(i)"], at: at)
            remap.record(id: "preset:h:swoop", title: "Swoop", clips: ["c\(i)"], at: at.addingTimeInterval(8))
        }
        remap.record(id: "preset:obj:13", title: "swoop ", at: t0.addingTimeInterval(5 * 3600))
        remap.record(id: "preset:obj:14", title: "Twin", at: t0.addingTimeInterval(6 * 3600))
        remap.record(id: "effect:AE.ADBE Gone", title: "Glide", at: t0.addingTimeInterval(7 * 3600))
        let moved = remap.remapUnknownIds(validIds: validIds, idForTitle: idForTitle)
        let counts = Dictionary(uniqueKeysWithValues: remap.top(10, now: t0).map { ($0.id, $0.count) })
        check(moved == 2 && counts["preset:h:glide"] == 4 && counts["preset:h:swoop"] == 5 && counts["preset:obj:12"] == nil,
              "usage.json : ids obj: rattachés par le titre, compteurs fusionnés (\(moved) rattachés)")
        check(counts["preset:obj:14"] == 1 && counts["effect:AE.ADBE Gone"] == 1,
              "titre ambigu ou autre genre : entrée gardée telle quelle, rien n'est perdu")
        check(remap.topPairs(5, now: t0).first.map { $0.from == "preset:h:glide" && $0.to == "preset:h:swoop" } == true,
              "les enchaînements suivent le rattachement")
        var oldSettings = Settings()
        oldSettings.presetShortcuts = [PresetShortcut(itemId: "preset:obj:12", title: "Glide", shortcut: "ctrl+alt+g"),
                                       PresetShortcut(itemId: "preset:obj:14", title: "Twin", shortcut: "ctrl+alt+t"),
                                       PresetShortcut(itemId: "effect:AE.ADBE Mosaic", title: "Mosaic", shortcut: "ctrl+alt+m")]
        let (newSettings, shortcutsMoved) = oldSettings.remappingUnknownShortcutIds(validIds: validIds, idForTitle: idForTitle)
        check(shortcutsMoved == 1 && newSettings.shortcuts.map(\.itemId) == ["preset:h:glide", "preset:obj:14", "effect:AE.ADBE Mosaic"],
              "settings.json : raccourci obj: rattaché par le titre, les autres gardés")
        try? fm.removeItem(at: presetDir)

        // ── I-03 (2026-10-09) : accès refusé ≠ pas de presets ──
        print("── SelfTest : Accès aux presets perso (I-03) ──")
        func lookupKind(_ lookup: UserPresetLookup) -> String {
            switch lookup {
            case .found: return "found"
            case .noFile: return "noFile"
            case .accessDenied: return "accessDenied"
            }
        }
        let docs = fm.temporaryDirectory.appendingPathComponent("khanjar-docs-\(UUID().uuidString)")
        let ppro = docs.appendingPathComponent("Adobe/Premiere Pro")
        let profileDir = ppro.appendingPathComponent("26.0/Profile-Prenom")
        check(lookupKind(IndexStore.userPresetLookup(hostVersion: "26.5.2", in: ppro)) == "noFile",
              "dossier Premiere absent → noFile")
        try? fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        check(lookupKind(IndexStore.userPresetLookup(hostVersion: "26.5.2", in: ppro)) == "noFile",
              "profil sans fichier de presets → noFile")
        let presetsFile = profileDir.appendingPathComponent("Effect Presets and Custom Items.prfpset")
        try? Data("<PremiereData/>".utf8).write(to: presetsFile)
        if case .found(let url) = IndexStore.userPresetLookup(hostVersion: "26.5.2", in: ppro) {
            check(url.resolvingSymlinksInPath() == presetsFile.resolvingSymlinksInPath(), "profil avec fichier → found")
        } else { check(false, "profil avec fichier → found") }
        func deniedLookup(chmod target: URL) -> UserPresetLookup {
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
            return IndexStore.userPresetLookup(hostVersion: "26.5.2", in: ppro)
        }
        for (target, label) in [(ppro, "dossier Premiere Pro"), (ppro.appendingPathComponent("26.0"), "dossier de version"),
                                (profileDir, "dossier du profil")] {
            let lookup = deniedLookup(chmod: target)
            var why = ""
            if case .accessDenied(let text) = lookup { why = text }
            check(lookupKind(lookup) == "accessDenied" && !why.contains(docs.path) && !why.contains("Prenom"),
                  "\(label) en chmod 000 → accessDenied, sans chemin ni nom de profil (« \(why) »)")
        }
        try? fm.removeItem(at: docs)

        // ── I-04 (2026-10-09) : raccourcis par position physique, affichés selon la disposition ──
        print("── SelfTest : Raccourcis presets (I-04) ──")
        check(SettingsStore.token(forKeyCode: 12) == "q" && SettingsStore.parseShortcut("cmd+q")?.keyCode == 12,
              "keyCode 12 → jeton « q » (position US) ; parseShortcut(« cmd+q ») → keyCode 12")
        check(SettingsStore.token(forKeyCode: 0x32) == "<" && SettingsStore.token(forKeyCode: 0x0A) == "§"
                && SettingsStore.token(forKeyCode: 0x31) == "space" && SettingsStore.token(forKeyCode: 0x60) == "f5"
                && SettingsStore.token(forKeyCode: 0x29) == ";" && SettingsStore.token(forKeyCode: 0x35) == nil,
              "table inverse : « < », « § », space, F5, « ; » ; Échap non prise en charge")
        check((0..<128).allSatisfy { code in
                  SettingsStore.token(forKeyCode: UInt16(code)).map { SettingsStore.parseShortcut("ctrl+\($0)")?.keyCode == UInt32(code) } ?? true
              }, "aller-retour jeton ↔ keyCode sur toutes les touches prises en charge")
        if let azerty = SettingsStore.installedKeyboardLayout("com.apple.keylayout.ABC-AZERTY") {
            check(SettingsStore.pretty("cmd+q", layout: azerty) == "⌘A"
                    && SettingsStore.pretty("ctrl+alt+a", layout: azerty) == "⌃⌥Q"
                    && SettingsStore.pretty("cmd+1", layout: azerty) == "⌘1",
                  "AZERTY : touche 12 affichée « ⌘A », ancien « ctrl+alt+a » affiché honnêtement « ⌃⌥Q », chiffres en chiffres")
            check(SettingsStore.isReservedShortcut("cmd+q", layout: azerty) && SettingsStore.isReservedShortcut("cmd+w", layout: azerty),
                  "AZERTY : ⌘A (touche 12) et ⌘Z (touche 13) réservés")
            // Consigne de l'intégrateur (2026-10-09) : la position seule laisserait passer ⇧⌘Z
            // en AZERTY (touche Z = position US « w ») — c'est le caractère qui décide.
            check(SettingsStore.isReservedShortcut("cmd+shift+w", layout: azerty)
                    && SettingsStore.pretty("cmd+shift+w", layout: azerty) == "⇧⌘Z",
                  "AZERTY : ⇧⌘Z (touche Z = position US « w ») affiché « ⇧⌘Z » et réservé (Rétablir)")
        } else { print("  · disposition ABC-AZERTY absente : cas AZERTY ignoré") }
        if let us = SettingsStore.installedKeyboardLayout("com.apple.keylayout.US") {
            check(SettingsStore.pretty("alt+ctrl+shift+cmd+f5", layout: us) == "⌃⌥⇧⌘F5"
                    && SettingsStore.pretty("alt+ctrl+a", layout: us) == "⌃⌥A",
                  "modificateurs dans l'ordre de macOS (⌃⌥⇧⌘), F5")
            let reserved = ["cmd+a", "cmd+c", "cmd+v", "cmd+x", "cmd+z", "cmd+shift+z", "cmd+s", "cmd+q", "cmd+w"]
            let free = ["cmd+e", "cmd+p", "ctrl+alt+a", "cmd+y", "cmd+shift+a", "ctrl+z", "cmd+alt+z"]
            check(reserved.allSatisfy { SettingsStore.isReservedShortcut($0, layout: us) }
                    && !free.contains { SettingsStore.isReservedShortcut($0, layout: us) },
                  "réservés (Q8) : ⌘A ⌘C ⌘V ⌘X ⌘Z ⌘⇧Z ⌘S ⌘Q ⌘W ; ⌘E, ⌘P, ⌃⌥A, ⌘Y, ⌘⇧A, ⌃Z, ⌘⌥Z libres")
        } else { print("  · disposition US absente : cas US ignoré") }
        if let qwertz = SettingsStore.installedKeyboardLayout("com.apple.keylayout.German") {
            check(SettingsStore.isReservedShortcut("cmd+y", layout: qwertz) && SettingsStore.pretty("cmd+y", layout: qwertz) == "⌘Z",
                  "QWERTZ : ⌘ + touche Z (position US « y ») affiché « ⌘Z » et réservé (Annuler)")
            check(SettingsStore.isReservedShortcut("cmd+shift+y", layout: qwertz),
                  "QWERTZ : ⇧⌘Z (position US « y ») réservé (Rétablir)")
        } else { print("  · disposition German absente : cas QWERTZ ignoré") }
        if let us = SettingsStore.installedKeyboardLayout("com.apple.keylayout.US") {
            check(!SettingsStore.isReservedShortcut("cmd+shift+w", layout: us) && !SettingsStore.isReservedShortcut("cmd+shift+y", layout: us),
                  "US : ⇧⌘W et ⇧⌘Y libres (la réservation suit bien le caractère de la disposition)")
        }

        // ── I-05 (2026-10-09) : chrono activé sans image-clé ──
        print("── SelfTest : Chrono sans image-clé (I-05) ──")
        func transformPreset(_ name: String, _ params: [PresetParam]) -> ParsedPreset {
            ParsedPreset(uid: "test-\(name)", name: name, binPath: ["Pack"], effects: [
                PresetEffect(matchName: "AE.ADBE Geometry2", displayName: "Transform", kind: "video",
                             paramCount: params.count, arbParamCount: 0, maskCount: 0,
                             params: params, anchorType: 0, srcDurationTicks: 254_016_000_000)])
        }
        func builtPreset(_ preset: ParsedPreset) -> SearchItem? {
            IndexStore.build(effects: transform, userPresets: [preset], factoryPresets: []).first { $0.kind == "preset" }
        }
        let chronoNoKey = PresetParam(index: 3, name: "Scale Height", parameterID: "3", controlType: 2, isTimeVarying: true,
                                      authoredValueRaw: "150.", isArb: false, keyframes: [])
        let chronoItem = builtPreset(transformPreset("Chrono", [chronoNoKey]))
        check(chronoItem?.fidelityHint == "params:1/1" && chronoItem?.plan.operations.first?.params.first?.number == 150,
              "chrono activé sans image-clé : valeur fixe 150 posée, pas de badge « partiel » (\(chronoItem?.fidelityHint ?? "?"))")
        let unreadableKeys = PresetParam(index: 4, name: "Scale Width", parameterID: "4", controlType: 2, isTimeVarying: true,
                                         authoredValueRaw: "100.", isArb: false, keyframes: [], rawKeyframeCount: 2)
        check(builtPreset(transformPreset("Illisible", [chronoNoKey, unreadableKeys]))?.fidelityHint == "params:1/2",
              "images-clés présentes mais illisibles : réglage non posé, badge « partiel » gardé")

        // ── I-06 (2026-10-09) : recherche — espaces, séparateurs, insécables, voyelles arabes, noms anglais ──
        print("── SelfTest : Recherche (I-06) ──")
        func firstTitle(_ query: String, _ candidates: [SearchItem]) -> String? {
            Scorer.rank(query: query, items: candidates, limit: 8).first?.item.title
        }
        let shadows = [item("Drop Shadow", keywords: ["AE.ADBE Drop Shadow"]), item("AP - DROP SHADOW"),
                       item("Drop Shadow Preset"), item("Captions Chris", keywords: ["Drop Shadow", "Gaussian Blur"]),
                       item("Gaussian Blur", keywords: ["AE.ADBE Gaussian Blur 2"]), item("AP - BLUR FADE IN")]
        check(firstTitle("drop  shadow", shadows) == "Drop Shadow" && firstTitle("gaussian  blur", shadows) == "Gaussian Blur",
              "deux espaces tapés : « drop  shadow » → Drop Shadow, « gaussian  blur » → Gaussian Blur")
        let slides = [item("Slide up text"), item("Slide Down"), item("Up SlowMo text")]
        check(firstTitle("slide-up", slides) == "Slide up text" && firstTitle("slide_up", slides) == "Slide up text"
                && firstTitle("slide/up", slides) == "Slide up text",
              "« slide-up », « slide_up », « slide/up » → Slide up text")
        let arabic = [item("انْزِلاقٌ يَسار"), item("تكبير سريع")]
        check(firstTitle("انزلاق", arabic) == "انْزِلاقٌ يَسار" && firstTitle("يسار", arabic) == "انْزِلاقٌ يَسار",
              "voyelles arabes ignorées : « انزلاق » et « يسار » trouvent « انْزِلاقٌ يَسار »")
        let frenchNames = [item("Noir\u{A0}&\u{A0}blanc"), item("Rotation\u{A0}3D"), item("Effets d\u{2019}éclairage"), item("Netteté")]
        check(firstTitle("noir & blanc", frenchNames) == "Noir\u{A0}&\u{A0}blanc"
                && firstTitle("rotation 3d", frenchNames) == "Rotation\u{A0}3D"
                && firstTitle("effets d'eclairage", frenchNames) == "Effets d\u{2019}éclairage",
              "Premiere français : espaces insécables et apostrophe typographique pliés")
        let frenchBlur = IndexStore.build(effects: [IndexStore.EffectEntry(matchName: "AE.ADBE Gaussian Blur 2", displayName: "Flou gaussien (hérité)"),
                                                    IndexStore.EffectEntry(matchName: "AE.Impact_Blur_FX", displayName: "Flou gaussien")],
                                          userPresets: [], factoryPresets: [])
        check(firstTitle("gaussian blur", frenchBlur) == "Flou gaussien",
              "« gaussian blur » trouve d'abord le nouveau « Flou gaussien » (AE.Impact_Blur_FX) d'un Premiere français")
        let foldStarted = Date()
        _ = Scorer.rank(query: "drsh", items: (0..<1200).map { item("Preset numéro \($0) Drop Shadow Édition") }, limit: 8)
        let foldElapsed = Date().timeIntervalSince(foldStarted)
        check(foldElapsed < 0.05, "budget perf avec le nouveau pliage : préparation + rank de 1200 items en \(Int(foldElapsed * 1000)) ms (< 50 ms)")

        // ── I-07 (2026-10-09) : usage.json illisible mis de côté ; amorçage sans double compte ──
        print("── SelfTest : usage.json (I-07) ──")
        let usageSandbox = fm.temporaryDirectory.appendingPathComponent("khanjar-usage-\(UUID().uuidString)")
        try? fm.createDirectory(at: usageSandbox, withIntermediateDirectories: true)
        let brokenUsage = usageSandbox.appendingPathComponent("usage.json")
        let truncated = #"{"version":3,"seeded":true,"entries":{"a":{"count":476,"sco"#
        try? Data(truncated.utf8).write(to: brokenUsage)
        let restarted = UsageStore(fileURL: brokenUsage)
        restarted.load()
        restarted.record(id: "b", title: "B")
        let usageBackups = ((try? fm.contentsOfDirectory(atPath: usageSandbox.path)) ?? [])
            .filter { $0.hasPrefix("usage.json.illisible-") }
        let backupContent = usageBackups.first.flatMap {
            try? String(contentsOf: usageSandbox.appendingPathComponent($0), encoding: .utf8)
        }
        check(usageBackups.count == 1 && backupContent == truncated && restarted.top(5).map { $0.id } == ["b"]
                && (try? JSONSerialization.jsonObject(with: Data(contentsOf: brokenUsage))) != nil,
              "usage.json illisible : mis de côté intact (\(usageBackups.first ?? "?")) avant la 1ʳᵉ écriture")

        // Amorçage différé : les applications déjà comptées en direct ne sont pas rejouées.
        let seedFile = usageSandbox.appendingPathComponent("seed.json")
        let seeding = UsageStore(fileURL: seedFile)
        seeding.load()                                    // Mac neuf : date de coupure = maintenant
        let cutoff = seeding.seedCutoff ?? .distantPast
        let logFormatter = DateFormatter()
        logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        logFormatter.locale = Locale(identifier: "en_US_POSIX")
        func logLine(_ date: Date) -> String {
            "[\(logFormatter.string(from: date))] [info] apply OK : Glide, 1 clips appliqués, skipped=0 reason=- failed=[]"
        }
        let fakeLog = usageSandbox.appendingPathComponent("Khanjar.log")
        try? Data([logLine(cutoff.addingTimeInterval(-7200)), logLine(cutoff.addingTimeInterval(-3600)),
                   logLine(cutoff.addingTimeInterval(3600))].joined(separator: "\n").utf8).write(to: fakeLog)
        seeding.record(id: "preset:glide", title: "Glide", at: cutoff.addingTimeInterval(3600))   // compté en direct
        let glide = SearchItem(id: "preset:glide", kind: "preset", title: "Glide", subtitle: "", keywords: [],
                               plan: ApplyPlan(label: "Glide", operations: []), fidelityHint: "full")
        seeding.seedIfNeeded(items: [glide], logURL: fakeLog)
        check(seeding.top(5).first?.count == 3,
              "amorçage différé : 2 lignes antérieures rejouées + 1 application en direct = 3 (avant : 4)")
        let pending = usageSandbox.appendingPathComponent("pending.json")
        let dayAgo = Date().addingTimeInterval(-day)
        try? Data(#"{"version":3,"seeded":false,"entries":{},"seedCutoff":"\#(ISO8601DateFormatter().string(from: dayAgo))"}"#.utf8).write(to: pending)
        let reloaded = UsageStore(fileURL: pending)
        reloaded.load()
        check(abs((reloaded.seedCutoff ?? .distantFuture).timeIntervalSince(dayAgo)) < 1,
              "date de coupure gardée dans usage.json d'un lancement à l'autre jusqu'à l'amorçage")
        try? fm.removeItem(at: usageSandbox)

        // ── I-08 (2026-10-09) : settings.json partiel ou abîmé ──
        print("── SelfTest : settings.json (I-08) ──")
        let settingsSandbox = fm.temporaryDirectory.appendingPathComponent("khanjar-settings-\(UUID().uuidString)")
        final class IssueLog { var issues: [SettingsIssue] = [] }
        func loadSettings(_ json: String) -> (store: SettingsStore, issues: IssueLog, dir: URL) {
            let dir = settingsSandbox.appendingPathComponent(UUID().uuidString)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(json.utf8).write(to: dir.appendingPathComponent("settings.json"))
            let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
            let log = IssueLog()
            store.onIssue = { log.issues.append($0) }
            store.load()
            return (store, log, dir)
        }
        func backups(in dir: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("settings.json.illisible-") }
        }
        let partial = loadSettings(#"{"shortcut":"cmd+k","presetShortcuts":[{"itemId":"preset:x","title":"X","shortcut":"ctrl+alt+x"}]}"#)
        check(partial.store.current.shortcut == "cmd+k" && partial.store.current.maxResults == 8
                && partial.store.current.shortcuts.count == 1 && partial.issues.issues.isEmpty && backups(in: partial.dir).isEmpty,
              "settings.json sans maxResults : cmd+k gardé, 8 résultats, raccourci preset conservé")
        let wrongType = #"{"maxResults":"huit","theme":"dark","presetShortcuts":[{"itemId":"preset:x","title":"X","shortcut":"ctrl+alt+x"},{"itemId":"preset:y"}]}"#
        let lenient = loadSettings(wrongType)
        check(lenient.store.current.maxResults == 8 && lenient.store.current.theme == "dark"
                && lenient.store.current.shortcuts.map(\.itemId) == ["preset:x"] && backups(in: lenient.dir).count == 1,
              "valeur de mauvais type ou raccourci abîmé : défaut pour eux seuls, le reste gardé, copie du fichier")
        let truncatedSettings = #"{"shortcut":"cmd+k","presetShortc"#
        let broken = loadSettings(truncatedSettings)
        var unreadableBackup: URL?
        if case .unreadable(let backup)? = broken.issues.issues.first { unreadableBackup = backup }
        check(broken.store.current == Settings.default && broken.issues.issues.count == 1
                && unreadableBackup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == truncatedSettings,
              "settings.json tronqué : défauts en mémoire, copie identique gardée, onIssue(.unreadable)")
        let readOnly = loadSettings(#"{"shortcut":"cmd+k"}"#)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.dir.path)
        var changed = readOnly.store.current
        changed.maxResults = 12
        readOnly.store.save(changed)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.dir.path)
        var saveFailed = false
        if case .saveFailed? = readOnly.issues.issues.last { saveFailed = true }
        check(saveFailed, "écriture impossible (dossier en lecture seule) : onIssue(.saveFailed)")
        try? fm.removeItem(at: settingsSandbox)

        // ── I-09 (2026-10-09) : parseur face à un fichier abîmé ou fabriqué ──
        print("── SelfTest : Fichiers abîmés ou fabriqués (I-09) ──")
        let trapDir = fm.temporaryDirectory.appendingPathComponent("khanjar-pieges-\(UUID().uuidString)")
        try? fm.createDirectory(at: trapDir, withIntermediateDirectories: true)
        func parseTrap(_ name: String, _ xml: String) -> (presets: [ParsedPreset], error: String?) {
            let url = trapDir.appendingPathComponent("\(name).prfpset")
            try? Data(xml.utf8).write(to: url)
            do { return (try PrfpsetParser.parse(fileURL: url), nil) } catch { return ([], "\(error)") }
        }
        let model = fakePrfpset([FakePreset(name: "Glide", base: 100)])
        let staticParam = "<Keyframes></Keyframes><IsTimeVarying>false</IsTimeVarying>"
        // Entités imbriquées (petite bombe : jamais développée, refusée avant l'analyse XML).
        let entities = "<!DOCTYPE PremiereData [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\">]>\n"
        let bomb = model.replacingOccurrences(of: "<PremiereData Version=\"3\">", with: entities + "<PremiereData Version=\"3\">")
            .replacingOccurrences(of: "<Name>Glide</Name>", with: "<Name>&b;</Name>")
        let bombStarted = Date()
        let bombResult = parseTrap("entites", bomb)
        check(bombResult.presets.isEmpty && bombResult.error?.contains("DTD") == true && Date().timeIntervalSince(bombStarted) < 1,
              "DTD / entités internes : fichier refusé avant l'analyse XML (« illisible »)")
        check(parseTrap("utf16", model.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")).error != nil
                && parseTrap("normal", model).presets.count == 1,
              "encodage déclaré autre qu'UTF-8 refusé ; fichier normal toujours lu")
        let nonFinite = parseTrap("nan", fakePrfpset([FakePreset(name: "Nan", base: 100, value: "nan"),
                                                       FakePreset(name: "Huge", base: 200, value: "1e400")])).presets
        let nonFiniteItems = IndexStore.build(effects: transform, userPresets: nonFinite, factoryPresets: []).filter { $0.kind == "preset" }
        check(nonFiniteItems.count == 2 && nonFiniteItems.allSatisfy { $0.fidelityHint == "params:0/1" }
                && (try? JSONEncoder().encode(nonFiniteItems)) != nil,
              "valeur « nan » ou « 1e400 » : réglage non posé (badge « partiel »), index toujours encodable")
        check(parseTrap("sans-type", model.replacingOccurrences(of: "<Type>0</Type>", with: "")).presets.first?.effects.first?.anchorType == 0,
              "<Type> absent → ancrage 0 (Échelle, défaut Adobe) au lieu de 1")
        let nanKey = model.replacingOccurrences(of: staticParam, with:
            "<Keyframes>0,100.,0,0,0,0,0,0;127008000000,nan,0,0,0,0,0,0;254016000000,120.,0,0,0,0,0,0;</Keyframes><IsTimeVarying>true</IsTimeVarying>")
        check(IndexStore.build(effects: transform, userPresets: parseTrap("kf-nan", nanKey).presets, factoryPresets: [])
                .first { $0.kind == "preset" }?.fidelityHint == "params:0/1",
              "image-clé non finie : animation non posée (plutôt que tronquée en silence), badge « partiel »")
        let overflow = model
            .replacingOccurrences(of: "<AnchorInPoint>0</AnchorInPoint>", with: "<AnchorInPoint>-9223372036854775808</AnchorInPoint>")
            .replacingOccurrences(of: staticParam, with: "<Keyframes>9223372036854775807,100.,0,0,0,0,0,0;</Keyframes><IsTimeVarying>true</IsTimeVarying>")
        let overflowPresets = parseTrap("debordement", overflow).presets
        check(overflowPresets.count == 1 && overflowPresets.first?.effects.first?.params.first?.keyframes.isEmpty == true
                && overflowPresets.first?.effects.first?.srcDurationTicks == 0,
              "temps qui débordent Int64 : plus de plantage (SIGTRAP), image-clé écartée")
        let colorKey = PresetKeyframe(offsetTicks: 0, value: 1.8374686479671624e19, pointX: nil, pointY: nil, interpolationMode: 0,
                                      inVelocity: 0, inInfluence: 0, outVelocity: 0, outInfluence: 0,
                                      inTanX: nil, inTanY: nil, outTanX: nil, outTanY: nil)
        let animatedColor = PresetParam(index: 0, name: "Color", parameterID: "1", controlType: 5, isTimeVarying: true,
                                        authoredValueRaw: "18374686479671623680", isArb: false, keyframes: [colorKey], rawKeyframeCount: 1)
        check(builtPreset(transformPreset("Couleur", [animatedColor]))?.fidelityHint == "params:0/1",
              "couleur animée : non posée (l'entier 64 bits n'est plus envoyé comme un nombre)")
        let noComponent = parseTrap("sans-component", model.replacingOccurrences(of: "<Component ObjectRef=\"103\"/>", with: "")).presets
        check(noComponent.first.map { IndexStore.exclusionReason($0, addable: ["AE.ADBE Geometry2"]) } == "composant inconnu",
              "effet sans composant lisible : « composant inconnu » (plus « audio seul »)")
        try? fm.removeItem(at: trapDir)

        // ── I-10 (2026-10-09) : Lumetri, case de section décochée (correction prudente, T-16) ──
        print("── SelfTest : Lumetri, section décochée (I-10) ──")
        func lumetriItem(_ params: [PresetParam]) -> SearchItem? {
            IndexStore.build(effects: [IndexStore.EffectEntry(matchName: "AE.ADBE Lumetri", displayName: "Lumetri Color")],
                             userPresets: [ParsedPreset(uid: "test-lumetri", name: "Look", binPath: ["Pack"], effects: [lumetri(params)])],
                             factoryPresets: []).first { $0.kind == "preset" }
        }
        func sectionToggle(_ value: String, pid: String = "50") -> PresetParam {
            PresetParam(index: 3, name: " ", parameterID: pid, controlType: 4, isTimeVarying: false,
                        authoredValueRaw: value, isArb: false, keyframes: [])
        }
        check(lumetriItem([slider, sectionToggle("false")])?.fidelityHint == "params:1/2",
              "section Lumetri décochée (Vignette, pid 50) : comptée sans être posée → badge « partiel »")
        check(lumetriItem([slider, sectionToggle("true")])?.fidelityHint == "params:1/1",
              "section Lumetri cochée (défaut) : rien ne change, pas de badge")
        // Écart au plan : les cases sans nom 62/74/76/97 valent false dans les 379 Lumetri relevés
        // (ce ne sont pas des sections) — la règle « toute case sans nom à false » marquait
        // « partiel » tous les Lumetri, dont les 8 d'Isma.
        check(lumetriItem([slider, sectionToggle("false", pid: "62")])?.fidelityHint == "params:1/1",
              "case sans nom qui vaut toujours false (pid 62) : pas de faux badge « partiel »")

        // ── Garde-fous de l'audit du 2026-10-07 ──
        print("── SelfTest : Garde-fous (audit) ──")
        check(!BridgeServer.isRefusedOrigin("file://"), "le plugin UXP (Origin file://) est accepté")
        check(BridgeServer.isRefusedOrigin("null") && BridgeServer.isRefusedOrigin("https://site.example")
                && BridgeServer.isRefusedOrigin("chrome-extension://abc"),
              "Origin null (iframe sandbox, data:), pages et extensions refusées")
        let scrubbed = CrashReporter.scrub("NSFilePath=/Users/Jean Dupont/Movies/Client Nike final.prproj")
        check(!scrubbed.contains("Jean") && !scrubbed.contains("Nike"),
              "chemin avec espaces masqué en entier (« \(scrubbed) »)")
        check(CrashReporter.scrub("Khanjar/AppCoordinator.swift:42: Fatal error").contains("AppCoordinator.swift:42"),
              "chemin relatif du code Swift conservé")

        // Bloc du lot C dans sa propre portée : ses noms (kept, before…) existent aussi
        // dans les tests du lot I (intégration du 2026-10-09).
        do {
        // ── Lot C (audit du 2026-10-08) : journal (C-11) ──
        print("── SelfTest : Journal (C-11) ──")
        var stamp = DateComponents()
        (stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second, stamp.nanosecond)
            = (2026, 10, 9, 12, 34, 56, 789_000_000)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        if let fixed = gregorian.date(from: stamp) {
            let line = Logger.makeTimestampFormatter().string(from: fixed)
            let oldStyle = DateFormatter()          // l'ancien réglage, sur un Mac en arabe
            oldStyle.locale = Locale(identifier: "ar_SA")
            oldStyle.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let arabic = oldStyle.string(from: fixed)
            check(line == "2026-10-09 12:34:56.789" && arabic != line,
                  "horodatage grégorien en chiffres latins quel que soit le Mac (« \(line) » ; ancien réglage ar_SA : « \(arabic) »)")
        } else { check(false, "date de référence construite") }
        let logBox = fm.temporaryDirectory.appendingPathComponent("khanjar-selftest-log-\(UUID().uuidString)")
        try? fm.createDirectory(at: logBox, withIntermediateDirectories: true)
        let bigLog = logBox.appendingPathComponent("Khanjar.log")
        try? Data(repeating: 65, count: 300).write(to: bigLog)
        try? Data("ancien".utf8).write(to: bigLog.appendingPathExtension("1"))
        let rotated = Logger.rotateIfNeeded(fileURL: bigLog, maxBytes: 100)
        let kept = (try? Data(contentsOf: bigLog.appendingPathExtension("1")))?.count
        check(rotated && kept == 300 && !fm.fileExists(atPath: bigLog.path),
              "au-delà du seuil, le journal devient Khanjar.log.1 (l'ancien .1 remplacé), rien n'est effacé")
        try? Data(repeating: 66, count: 50).write(to: bigLog)
        check(!Logger.rotateIfNeeded(fileURL: bigLog, maxBytes: 100), "sous le seuil, aucune rotation")
        let periodic = Logger(fileURL: logBox.appendingPathComponent("long.log"), echo: false,
                              maxBytes: 400, checkEveryLines: 5)
        for i in 0..<40 { periodic.info("ligne de remplissage numéro \(i) pour dépasser le seuil") }
        periodic.waitForPendingWrites()
        check(fm.fileExists(atPath: logBox.appendingPathComponent("long.log.1").path),
              "pendant une longue session, la taille est recontrôlée toutes les N lignes (rotation sans relancer)")
        let quietBox = fm.temporaryDirectory.appendingPathComponent("khanjar-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: quietBox.appendingPathComponent("Dagger"), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: quietBox.appendingPathComponent("Dagger/usage.json"))
        Logger.shared.waitForPendingWrites()
        let sizeOf = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0 }
        let before = sizeOf(Logger.shared.fileURL)
        let quietCopy = LegacyMigration.run(supportDir: quietBox)
        Logger.shared.waitForPendingWrites()
        check(quietCopy == ["usage.json"] && sizeOf(Logger.shared.fileURL) == before,
              "la reprise Dagger en bac à sable n'écrit plus dans le journal (\(before) → \(sizeOf(Logger.shared.fileURL)) octets)")
        try? fm.removeItem(at: logBox)
        try? fm.removeItem(at: quietBox)

        // ── Lot C : filtre d'origine du pont (C-07, décision Q9) ──
        print("── SelfTest : Filtre d'origine (C-07) ──")
        let browserOrigins = ["https://site.example", "http://localhost:3000", "null", " NULL ",
                              "chrome-extension://abc", "moz-extension://x", "safari-web-extension://x",
                              "data:text/html,<script>", "blob:https://site.example/1234"]
        let refusedAll = browserOrigins.filter { !BridgeServer.isRefused(origin: $0) }
        check(refusedAll.isEmpty, "pages, data:, blob:, null et extensions de navigateur refusées (passées : \(refusedAll))")
        check(!BridgeServer.isRefused(origin: nil) && !BridgeServer.isRefused(origin: "file://")
                && !BridgeServer.isRefused(origin: "uxp://x") && !BridgeServer.isRefused(origin: "FILE://"),
              "pas d'en-tête, file:// et schémas non web (uxp://) acceptés")
        var throttle = LogThrottle(interval: 60)
        let t = Date()
        let throttled = [throttle.admit("o", now: t), throttle.admit("o", now: t.addingTimeInterval(2)),
                         throttle.admit("o", now: t.addingTimeInterval(30)), throttle.admit("autre", now: t.addingTimeInterval(31)),
                         throttle.admit("o", now: t.addingTimeInterval(61))]
        check(throttled == [0, nil, nil, 0, 2],
              "refus journalisé au plus une fois par minute et par origine, avec le compte des refus tus (\(throttled))")

        // ── Lot C : délai dépassé, messages et échéance (C-02, contrat §4.1) ──
        print("── SelfTest : Délai dépassé et codes du plugin (C-02) ──")
        func says(_ code: String, _ command: String = "apply", premiere: Bool = true) -> String {
            let error: BridgeError = code == "TIMEOUT" ? .timeout
                : code == "PLUGIN_DISCONNECTED" ? .pluginDisconnected : .remote(code: code, message: "")
            return AppCoordinator.userMessage(for: error, command: command, premiereRunning: premiere)
        }
        check(says("TIMEOUT") == L("Premiere still isn't responding — check the timeline before trying again"),
              "délai maximal : « vérifie la timeline », plus jamais « réessaie dans un instant »")
        check(says("BUSY") == L("Premiere is still applying the previous one — wait a moment")
                && says("EXPIRED") == L("Not applied: Premiere was busy for too long"),
              "BUSY → « applique encore le précédent » ; EXPIRED → « non appliqué : occupé trop longtemps »")
        check(says("PLUGIN_DISCONNECTED") == L("Connection to Premiere lost — check the timeline before trying again")
                && says("PLUGIN_DISCONNECTED", premiere: false) == L("Open Premiere Pro to use Khanjar"),
              "coupure Premiere ouvert → « connexion perdue, vérifie la timeline » ; Premiere fermé → « ouvre Premiere »")
        check(says("TRANSACTION_FAILED", "addAdjustmentLayer") == L("Couldn't place the adjustment layer — add an empty video track above your clips")
                && says("TRANSACTION_FAILED") == L("Couldn't apply the effect — check the timeline before trying again")
                && says("CODE_INCONNU") == L("Couldn't apply the effect — try again"),
              "échec de pose du calque d'effets : message propre au calque ; échec d'application : « vérifie la timeline » (une partie a pu être posée, m2)")
        check(says("ADJUSTMENT_NOT_FOUND", "addAdjustmentLayer")
                == L("No adjustment layer found — create one (File > New > Adjustment Layer) and drag it into the timeline once"),
              "aucun calque d'effets : dire comment en créer un et le glisser une fois")
        let sent = Date(timeIntervalSince1970: 1_791_000_000)
        check(ProjectCommandGate.expiresAt(now: sent, hardTimeout: AppCoordinator.applyHardTimeout) == 1_791_000_115_000,
              "échéance transmise au plugin = envoi + 120 s − 5 s, en millisecondes")

        // ── Lot C : installation du plugin (C-01) ──
        print("── SelfTest : Installation du plugin (C-01) ──")
        typealias Policy = PluginInstallPolicy
        let t1 = Date()
        func premiereRunning(_ age: TimeInterval?, finished: Bool = true, version: String? = "26.5.2") -> Policy.Premiere {
            Policy.Premiere(finishedLaunching: finished, launchDate: age.map { t1.addingTimeInterval(-$0) }, version: version)
        }
        check(Policy.gate(premiereRunning(20), now: t1) == .wait(41),
              "Premiere lancé depuis 20 s : pas d'UPIA, nouveau contrôle dans 41 s")
        check(Policy.gate(premiereRunning(300, finished: false), now: t1) == .wait(15)
                && Policy.gate(premiereRunning(120), now: t1) == .go && Policy.gate(nil, now: t1) == .noPremiere,
              "pas fini de démarrer → 15 s ; lancé depuis 2 min → installation ; fermé → rien")
        check(Policy.gate(premiereRunning(600, version: "25.5.1"), now: t1) == .tooOld("25.5.1")
                && Policy.gate(premiereRunning(600, version: "25.6.0"), now: t1) == .go,
              "Premiere 25.5 : pas d'UPIA (message S5) ; 25.6.0 accepté")
        check(Policy.recheckDelay(after: .busy) == 30 && Policy.recheckDelay(after: .alreadyDeposited) == 60
                && Policy.recheckDelay(after: .started("…")) == nil,
              "UPIA occupé → nouveau contrôle à +30 s (la chaîne ne s'arrête plus)")
        let fail1 = Policy.afterUpia(ok: false, upgrade: false, failures: 0)
        let fail2 = Policy.afterUpia(ok: false, upgrade: false, failures: 1)
        let fail3 = Policy.afterUpia(ok: false, upgrade: false, failures: 2)
        check(fail1.next == .retry(after: 120) && fail1.failures == 1 && fail2.next == .retry(after: 120)
                && fail3.next == .giveUp && fail3.failures == 3,
              "échecs 1 et 2 → nouvel essai à +2 min ; échec 3 → arrêt (message S2)")
        check(Policy.afterUpia(ok: true, upgrade: false, failures: 2) == (.verify(after: 45), 0)
                && Policy.afterUpia(ok: true, upgrade: true, failures: 0).next == .verify(after: 30),
              "succès → contrôle du hello à +45 s (mise à niveau : +30 s), compteur d'échecs remis à zéro")
        check(Policy.isNewer("0.7.3", than: "0.7.2") && Policy.isNewer("0.7.10", than: "0.7.9")
                && !Policy.isNewer("0.7.2", than: "0.7.3") && !Policy.isNewer("0.7.2", than: "0.7.2")
                && Policy.compareVersions("25.6", "25.6.0") == .orderedSame,
              "versions comparées en nombres (0.7.10 > 0.7.9), jamais de rétrogradation")
        let pluginsInfo = Data(#"{"plugins":[{"hostMinVersion":"25.6.0","name":"Khanjar","pluginId":"io.khanjar.executor","status":"enabled","type":"uxp","versionString":"0.7.2"}]}"#.utf8)
        check(PluginInstallDiagnostics.registration(in: pluginsInfo, pluginId: "io.khanjar.executor")
                == .init(found: true, status: "enabled", version: "0.7.2")
                && PluginInstallDiagnostics.registration(in: pluginsInfo, pluginId: "autre.plugin")?.found == false
                && PluginInstallDiagnostics.registration(in: Data("pas du json".utf8), pluginId: "x") == nil,
              "inscription d'Adobe (premierepro.json) relue : inscrit / absent / illisible")
        check(Policy.issueAfterSilentInstall(pluginLogDates: [t1.addingTimeInterval(5)], installStartedAt: t1) == .loadedButMute
                && Policy.issueAfterSilentInstall(pluginLogDates: [t1.addingTimeInterval(-3600)], installStartedAt: t1) == .restartNeeded(afterUpgrade: false)
                && Policy.issueAfterSilentInstall(pluginLogDates: [], installStartedAt: t1) == .restartNeeded(afterUpgrade: false),
              "installé sans hello : journal du plugin récent → « tourne mais ne joint pas » (S4), sinon → relancer Premiere (S3)")
        let toolStart = Date()
        let tool = PluginLifecycleService.runTool(executable: "/bin/sh",
                                                  args: ["-c", "sleep 30 & echo \"Installation Successful\""],
                                                  timeout: 10, readerTimeout: 1)
        let toolTook = Date().timeIntervalSince(toolStart)
        check(toolTook < 3 && tool.status == 0 && tool.output.contains("Installation Successful") && tool.readerTimedOut,
              "un enfant qui garde la sortie ouverte ne bloque plus : rendu en \(f(toolTook)) s, sortie gardée")
        check(PluginLifecycleService.upiaStatusCode(in: "Failed to install, status = -642!") == -642
                && PluginLifecycleService.upiaStatusCode(in: "Installation Successful") == nil,
              "code d'UPIA extrait de « status = -642 »")
        // Faux UPIA (script), faux ccx : jamais le vrai UPIA d'Adobe.
        let fakeUpiaDir = fm.temporaryDirectory.appendingPathComponent("khanjar-selftest-upia-\(UUID().uuidString)")
        try? fm.createDirectory(at: fakeUpiaDir, withIntermediateDirectories: true)
        let fakeUpia = fakeUpiaDir.appendingPathComponent("FakeUPIA")
        try? Data("#!/bin/sh\necho \"Starting $1\"\necho \"Failed to install, status = -642!\"\nexit 1\n".utf8).write(to: fakeUpia)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeUpia.path)
        let service = PluginLifecycleService(upiaPath: fakeUpia.path,
                                             embedded: (url: fakeUpiaDir.appendingPathComponent("khanjar-executor.ccx"), version: "9.9.9"))
        func waitFor(_ seconds: TimeInterval, _ done: () -> Bool) {
            let limit = Date().addingTimeInterval(seconds)
            while !done() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        var installResult: PluginLifecycleService.UpiaResult?
        let installOutcome = service.reconcile(installedVersion: nil) { installResult = $0 }
        let duringInstall = service.reconcile(installedVersion: nil) { _ in }
        waitFor(10) { installResult != nil }
        check(installOutcome == .started(L("Installing the Khanjar plugin in Premiere…")) && duringInstall == .busy,
              "faux UPIA : installation lancée ; second appel pendant qu'il tourne → « occupé »")
        check(installResult?.ok == false && installResult?.code == -642 && installResult?.output.contains("Starting --install") == true,
              "échec d'UPIA REMONTÉ à l'app : code -642 et sortie entière (\(installResult?.output ?? "aucun résultat"))")
        var upgradeResult: PluginLifecycleService.UpiaResult?
        let upgradeOutcome = service.reconcile(installedVersion: "9.9.8") { upgradeResult = $0 }
        waitFor(10) { upgradeResult != nil }
        check(upgradeOutcome == .started(L("Updating the Khanjar plugin — restart Premiere if it doesn't take effect"))
                && service.reconcile(installedVersion: "9.9.8") { _ in } == .upToDate,
              "mise à niveau vers plus récent lancée, puis pas d'autre avant 10 min")
        check(service.reconcile(installedVersion: "9.9.10") { _ in } == .upToDate
                && service.reconcile(installedVersion: "9.9.9") { _ in } == .upToDate,
              "plugin plus récent ou identique à l'embarqué : rien (pas de rétrogradation)")
        // F1 (2026-10-11) : Premiere rouvert entre le --remove et le --install → arrêt.
        let recordingUpia = fakeUpiaDir.appendingPathComponent("RecordingUPIA")
        let upiaCalls = fakeUpiaDir.appendingPathComponent("calls.txt")
        try? Data("#!/bin/sh\necho \"$1\" >> '\(upiaCalls.path)'\necho \"Installation Successful\"\nexit 0\n".utf8).write(to: recordingUpia)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordingUpia.path)
        let stepService = PluginLifecycleService(upiaPath: recordingUpia.path,
                                                 embedded: (url: fakeUpiaDir.appendingPathComponent("khanjar-executor.ccx"), version: "9.9.9"))
        var stopped: PluginLifecycleService.UpiaResult?
        _ = stepService.reconcile(installedVersion: "9.9.8", between: { false }) { stopped = $0 }
        waitFor(10) { stopped != nil }
        let calls = (try? String(contentsOf: upiaCalls, encoding: .utf8)) ?? ""
        check(stopped?.aborted == true && stopped?.ok == false && calls == "--remove\n" && !stepService.busy,
              "mise à niveau Premiere fermé : Premiere rouvert après le --remove → --install pas lancé, UPIA libéré (appels : \(calls.replacingOccurrences(of: "\n", with: " ")))")
        try? fm.removeItem(at: upiaCalls)
        let goService = PluginLifecycleService(upiaPath: recordingUpia.path,
                                               embedded: (url: fakeUpiaDir.appendingPathComponent("khanjar-executor.ccx"), version: "9.9.9"))
        var finished: PluginLifecycleService.UpiaResult?
        _ = goService.reconcile(installedVersion: "9.9.8", between: { true }) { finished = $0 }
        waitFor(10) { finished != nil }
        let bothCalls = (try? String(contentsOf: upiaCalls, encoding: .utf8)) ?? ""
        check(finished?.ok == true && finished?.aborted == false && bothCalls.hasPrefix("--remove\n--install"),
              "Premiere toujours fermé : --remove puis --install, succès")
        // M1 (2026-10-11) : mise à niveau Premiere FERMÉ, jamais pendant son démarrage.
        typealias Registration = PluginInstallDiagnostics.Registration
        func toUpgrade(_ registered: Registration?, hello: String?) -> String? {
            Policy.versionToUpgradeWhileClosed(registered: registered, lastHello: hello, embedded: "0.7.3")
        }
        check(toUpgrade(.init(found: true, status: "enabled", version: "0.7.2"), hello: nil) == "0.7.2"
                && toUpgrade(.init(found: true, status: "enabled", version: "0.7.3"), hello: "0.7.2") == nil
                && toUpgrade(.init(found: true, status: "enabled", version: "0.7.4"), hello: nil) == nil,
              "Premiere fermé : l'inscription d'Adobe fait foi (0.7.2 → mise à niveau ; à jour → rien, même si un hello disait 0.7.2 ; plus récent → rien)")
        check(toUpgrade(nil, hello: "0.7.2") == "0.7.2" && toUpgrade(.init(found: false), hello: "0.7.2") == "0.7.2"
                && toUpgrade(.init(found: false), hello: nil) == nil && toUpgrade(nil, hello: nil) == nil,
              "inscription illisible, ou absente mais plugin vu au hello (dossier résiduel) → dernier hello ; jamais installé → rien (l'installation passe par Premiere)")
        check(Policy.legacyRemovalDelay(premiereRunning(20), now: t1) == 41
                && Policy.legacyRemovalDelay(premiereRunning(120), now: t1) == nil
                && Policy.legacyRemovalDelay(nil, now: t1) == nil,
              "retrait de l'ancien plugin Dagger : jamais pendant le démarrage de Premiere (41 s d'attente), tout de suite sinon")

        // ── Lot C : ancien plugin Dagger retiré une fois par SESSION (C-20) ──
        print("── SelfTest : Retrait de l'ancien plugin Dagger (C-20) ──")
        let slowUpia = fakeUpiaDir.appendingPathComponent("SlowUPIA")
        try? Data("#!/bin/sh\nsleep 1\necho \"Failed to remove, status = -406!\"\nexit 1\n".utf8).write(to: slowUpia)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowUpia.path)
        let legacyService = PluginLifecycleService(upiaPath: slowUpia.path,
                                                   embedded: (url: fakeUpiaDir.appendingPathComponent("k.ccx"), version: "9.9.9"))
        var installDone = false
        _ = legacyService.reconcile(installedVersion: nil) { _ in installDone = true }
        let whileInstalling = legacyService.removeLegacyPluginOnce()
        waitFor(10) { installDone }
        var removal: PluginLifecycleService.UpiaResult?
        let firstRemoval = legacyService.removeLegacyPluginOnce { removal = $0 }
        waitFor(10) { removal != nil }
        let marker = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar/.legacy-plugin-removed")
        check(whileInstalling == .busy, "UPIA occupé par l'installation : retrait reporté (l'app réessaie à +2 min)")
        check(firstRemoval == .started && removal?.code == -406 && legacyService.removeLegacyPluginOnce() == .alreadyAttempted,
              "retrait lancé une fois dans la session (-406 = déjà absent), pas deux")
        check(!fm.fileExists(atPath: marker.path),
              "aucun marqueur définitif : un ancien plugin revenu sera retiré au prochain lancement")
        try? fm.removeItem(at: fakeUpiaDir)

        // ── Lot C : état du plugin affiché (C-05) ──
        print("── SelfTest : État du plugin (C-05) ──")
        func status(connected: Bool = false, premiere: Bool = true, installing: Bool = false,
                    issue: PluginInstallIssue? = nil, hadSession: Bool = false) -> PluginStatus {
            PluginStatus.current(.init(connected: connected ? ("26.5.2", "0.7.2") : nil, premiereRunning: premiere,
                                       installing: installing, issue: issue, hadSession: hadSession))
        }
        check(status(connected: true).statusLine == LF("Connected — Premiere %@ · plugin %@", "26.5.2", "0.7.2"),
              "connecté : « Connected — Premiere 26.5.2 · plugin 0.7.2 » (texte cité par les guides, inchangé)")
        check(status(premiere: false).statusLine == L("Waiting for Premiere…")
                && status(premiere: false).summonMessage == L("Open Premiere Pro to use Khanjar"),
              "Premiere fermé : « En attente de Premiere… », ⌘J → « Ouvre Premiere Pro »")
        check(status().statusLine == L("Connecting to Premiere…") && status().summonMessage == L("Connecting to Premiere…"),
              "Premiere ouvert, jamais connecté : « Connexion à Premiere… » (plus « se reconnecte »)")
        check(status(hadSession: true).summonMessage == L("Khanjar is reconnecting to Premiere…"),
              "« se reconnecte » seulement après une vraie déconnexion")
        check(status(installing: true, issue: .installFailed(code: -642, final: false)).statusLine
                == L("Installing the Khanjar plugin in Premiere…"),
              "UPIA en cours : « Installation du plugin… » (même pendant un nouvel essai)")
        check(status(issue: .installFailed(code: -642, final: true)).statusLine == L("Plugin not installed — see the log")
                && status(issue: .installFailed(code: -642, final: true)).summonMessage
                    == L("The Khanjar plugin still isn't installed: open the Creative Cloud app, check you're signed in, then quit and reopen Premiere"),
              "échec d'installation : menu « Plugin non installé — voir le journal », ⌘J → quoi faire (S2)")
        check(status(issue: .restartNeeded(afterUpgrade: false)).statusLine == L("Restart Premiere to finish installing the plugin")
                && status(issue: .restartNeeded(afterUpgrade: false)).summonMessage == L("Plugin installed — quit and reopen Premiere to finish")
                && status(issue: .restartNeeded(afterUpgrade: true)).summonMessage == L("Plugin updated — quit and reopen Premiere to use the new version"),
              "redémarrage nécessaire : menu S9, ⌘J S3 (installation) ou S6 (mise à jour)")
        check(status(issue: .loadedButMute).summonMessage == L("The plugin is running but can't reach Khanjar — open the log")
                && status(issue: .premiereTooOld("25.5.1")).statusLine == LF("Premiere %@ is too old for Khanjar (25.6 or later needed)", "25.5.1")
                && status(issue: .creativeCloudMissing).statusLine == L("Creative Cloud is required to install the Khanjar plugin"),
              "plugin muet, Premiere trop ancien, Creative Cloud absent : chacun son texte")
        check(status(premiere: false, issue: .installFailed(code: nil, final: true)) == .premiereClosed
                && status(connected: true, issue: .loadedButMute) == .connected(premiere: "26.5.2", plugin: "0.7.2"),
              "connecté prime sur tout ; Premiere fermé prime sur un échec ancien")

        // ── Lot C : lecture des effets ratée au premier hello (C-16) ──
        print("── SelfTest : Lecture des effets (C-16) ──")
        let retries = (0...3).map { AppCoordinator.listEffectsRetryDelay(afterFailedAttempt: $0) }
        check(retries == [5, 15, 30, nil], "listEffects raté : nouveaux essais à +5, +15, +30 s, puis arrêt (\(retries))")
        check(AppCoordinator.emptyIndexMessage(buildInFlight: true) == L("Khanjar: building the index…")
                && AppCoordinator.emptyIndexMessage(buildInFlight: false)
                    == L("Khanjar couldn't read Premiere's effects — quit and reopen Premiere"),
              "⌘J sans index : « en construction » seulement si elle tourne, sinon « quitte et rouvre Premiere »")

        // ── Lot C : mises à jour Sparkle (C-12) ──
        print("── SelfTest : Mises à jour (C-12) ──")
        let sparkleDomain = UpdateService.sparkleErrorDomain
        check(UpdateService.isNoUpdateError(NSError(domain: sparkleDomain, code: 1001))
                && !UpdateService.isNoUpdateError(NSError(domain: sparkleDomain, code: 1000))
                && !UpdateService.isNoUpdateError(NSError(domain: NSURLErrorDomain, code: 1001)),
              "« aucune mise à jour » (Sparkle 1001) n'est plus journalisé comme une erreur")
        let unbound = UpdateService.missingGentleReminderMethods()
        check(unbound.isEmpty, "rappels discrets : les 4 méthodes répondent aux sélecteurs du protocole de Sparkle (manquants : \(unbound))")
        func cornerAlpha(_ image: NSImage?) -> CGFloat {
            guard let image, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return -1 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 100, height: 100))
            NSGraphicsContext.restoreGraphicsState()
            return rep.colorAt(x: 85, y: 15)?.alphaComponent ?? -1   // centre du point (origine en haut à gauche)
        }
        let withDot = cornerAlpha(StatusItemController.icon(withDot: true))
        let withoutDot = cornerAlpha(StatusItemController.icon(withDot: false))
        check(withDot > 0.9 && withoutDot < 0.1 && StatusItemController.icon(withDot: true)?.isTemplate == true,
              "mise à jour en attente : point opaque en haut à droite de l'icône (\(f(Double(withDot))) contre \(f(Double(withoutDot))) sans), image « modèle »")

        // ── Lot C : départs silencieux (C-13) ──
        print("── SelfTest : Port pris, 2ᵉ copie (C-13) ──")
        // Sortie réelle relevée le 2026-10-09 (`lsof -nP -iTCP:48199 -sTCP:LISTEN -Fc`, écouteur Python).
        let lsofOutput = "p38058\ncpython3.13\nf3\nf4\n"
        check(AppCoordinator.parseLsofListener(lsofOutput, excludingPid: 1) == "python3.13",
              "le nom de l'app qui tient le port est lu dans la sortie de lsof")
        check(AppCoordinator.parseLsofListener("p100\ncKhanjar\nf5\n" + lsofOutput, excludingPid: 100) == "python3.13"
                && AppCoordinator.parseLsofListener("", excludingPid: 1) == nil,
              "Khanjar lui-même (son écoute ::1) n'est jamais désigné ; sortie vide → inconnu")
        let lsofStart = Date()
        let nobody = AppCoordinator.portHolderName(port: 1)
        check(nobody == nil && Date().timeIntervalSince(lsofStart) < 3,
              "vrai lsof sur un port libre : rien, en moins de 3 s (\(f(Date().timeIntervalSince(lsofStart))) s)")

        // ── Lot C : crochets de test (C-14) ──
        print("── SelfTest : Crochets de signaux (C-14) ──")
        check(!AppCoordinator.testHooksEnabled([:]) && !AppCoordinator.testHooksEnabled(["KHANJAR_TEST_HOOKS": "0"])
                && !AppCoordinator.testHooksEnabled(["KHANJAR_TEST_HOOKS": "yes"])
                && AppCoordinator.testHooksEnabled(["KHANJAR_TEST_HOOKS": "1"]),
              "crochets SIGUSR1/USR2/WINCH/INFO seulement avec KHANJAR_TEST_HOOKS=1 (app publiée : inactifs)")

        // ── Lot C : mode de lancement (C-15) — la fonction seule, jamais le mode app ──
        print("── SelfTest : Mode de lancement (C-15) ──")
        func launchMode(_ args: [String], packaged: Bool = true) -> String {
            LaunchMode.resolveMode(args, packaged: packaged).mode
        }
        check(launchMode(["-psn_0_1234567"]) == "app" && launchMode(["-NSDocumentRevisionsDebugMode", "YES"]) == "app"
                && launchMode([]) == "app",
              "argument système au lancement (-psn_…, -NS…) ou aucun argument : mode app, plus « Mode inconnu »")
        check(launchMode(["inconnu"]) == "app" && launchMode(["inconnu"], packaged: false) == "inconnu",
              "mode inconnu : mode app dans Khanjar.app ; le binaire de développement garde son erreur")
        check(launchMode(["render-media", "/tmp/x"]) == "render-media" && launchMode(["login-item", "status"]) == "login-item"
                && launchMode(["run", "--port", "48199"], packaged: false) == "run"
                && launchMode(["selftest"], packaged: false) == "selftest",
              "les modes connus restent lancés tels quels (dont render-media et login-item depuis l'app)")

        // ── Lot C : rapports de plantage, noms de bibliothèques (audit sécurité A6) ──
        print("── SelfTest : Rapports de plantage, bibliothèques tierces (A6) ──")
        let ipsBody2 = #"{"procPath":"/Applications/Khanjar.app/Contents/MacOS/Khanjar","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"faultingThread":0,"threads":[{"frames":[{"imageIndex":0,"imageOffset":10,"symbol":"AppCoordinator.start()"},{"imageIndex":2,"imageOffset":999},{"imageIndex":3,"imageOffset":20,"symbol":"SPUUpdater.start"},{"imageIndex":4,"imageOffset":5},{"imageIndex":1,"imageOffset":30,"symbol":"swift_retain"},{"imageIndex":5,"imageOffset":7}]}],"usedImages":[{"name":"Khanjar","path":"/Applications/Khanjar.app/Contents/MacOS/Khanjar"},{"name":"libswiftCore.dylib","path":"/usr/lib/swift/libswiftCore.dylib"},{"name":"libInjecteur-JeanDupont.dylib","path":"/Users/jean/Library/Audio/Plug-Ins/libInjecteur-JeanDupont.dylib"},{"name":"Sparkle","path":"/Applications/Khanjar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"},{"name":"libfoo-MarieCurie.dylib","path":"/usr/local/lib/libfoo-MarieCurie.dylib"},{"name":"libSansChemin-Prenom.dylib"}]}"#
        if let report = CrashReporter.parse(ipsHeader + "\n" + ipsBody2) {
            let wire2 = String(decoding: (try? JSONSerialization.data(withJSONObject: CrashReporter.event(for: report, pluginVersion: nil))) ?? Data(),
                               as: UTF8.self)
            let leaks = ["JeanDupont", "Injecteur", "MarieCurie", "SansChemin", "Prenom"].filter { wire2.contains($0) }
            check(leaks.isEmpty, "bibliothèque tierce au nom personnel : nom masqué dans le paquet ET le nom de fonction (fuites : \(leaks))")
            check(report.frames.map(\.image) == ["Khanjar", CrashReporter.maskedImageName, "Sparkle", CrashReporter.maskedImageName,
                                                 "libswiftCore.dylib", CrashReporter.maskedImageName]
                    && report.frames[1].function == "\(CrashReporter.maskedImageName) + 999",
                  "gardés : Khanjar, Sparkle embarqué, bibliothèques du système ; le reste devient « \(CrashReporter.maskedImageName) »")
        } else { check(false, "rapport piégé lu") }

        }

        // ── Lot C, vague 2 (intégration du 2026-10-09) : C-03, C-04, C-08, C-09, C-10 ──
        // Bloc à part, comme la vague 1 : ses noms locaux ne heurtent pas ceux des autres lots.
        do {
            print("── SelfTest : Fréquents complétés, clips transmis (C-03) ──")
            func preset(_ id: String, _ title: String) -> SearchItem {
                SearchItem(id: id, kind: "preset", title: title, subtitle: "Preset · Test", keywords: [],
                           plan: ApplyPlan(label: title, operations: [.init(matchName: "AE.Test \(id)")]),
                           fidelityHint: "full")
            }
            let catalog = [preset("preset:a", "Alpha"), preset("preset:b", "Bravo"), preset("preset:c", "Charlie"),
                           preset("preset:d", "Delta"), preset("preset:e", "Echo")]
            let byId = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
            // Classement tel que le rend usage.top : une entrée orpheline en tête, un id
            // désormais porté par un AUTRE preset (« Ancien nom » ≠ « Bravo »).
            let ranked: [(id: String, count: Int, score: Double, title: String)] = [
                ("preset:obj:9", 50, 9, "Disparu"), ("preset:a", 40, 8, "Alpha"), ("preset:b", 30, 7, "Ancien nom"),
                ("preset:c", 20, 6, "  charlie "), ("preset:d", 10, 5, "Delta"), ("preset:e", 5, 4, "Echo")]
            let titles = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0.title) })
            // « Ancien nom » encore porté par un item (copie au même PresetUID dans
            // Premiere) : l'id désigne peut-être une autre copie → sauté (C-04). Porté par
            // plus personne : preset renommé → gardé (m3).
            let catalogTitles = AppCoordinator.titleIndex(catalog)
            var titlesWithCopy = catalogTitles
            titlesWithCopy[SearchItem.normalizedTitle("Ancien nom"), default: []].insert("preset:b")
            func rows(_ limit: Int, _ pairs: [(from: String, to: String, count: Int)], renamed: Bool = false) -> [String] {
                let index = renamed ? catalogTitles : titlesWithCopy
                return AppCoordinator.frequentRows(limit: limit, ranked: ranked, pairs: pairs, lookup: byId,
                                                   titleOf: { titles[$0] },
                                                   idsForTitle: { index[SearchItem.normalizedTitle($0)] ?? [] }).map(\.item.id)
            }
            check(rows(3, []) == ["preset:a", "preset:c", "preset:d"],
                  "3 lignes demandées : liste pleine malgré une entrée orpheline et un id passé à un autre preset (\(rows(3, [])))")
            check(!rows(10, []).contains("preset:b"),
                  "un id dont l'ancien titre est encore porté (copie au même PresetUID) n'est jamais proposé en ⌘n (casse et espaces ignorés : « charlie » gardé)")
            check(rows(3, [], renamed: true) == ["preset:a", "preset:b", "preset:c"],
                  "preset renommé dans Premiere (même id, ancien titre porté par plus aucun item) : toujours en ⌘n (m3) (\(rows(3, [], renamed: true)))")
            check(rows(4, [("preset:a", "preset:c", 6)]) == ["preset:a", "combo:preset:a|preset:c", "preset:c", "preset:d"],
                  "duo en ⌘2, jamais en ⌘1 (\(rows(4, [("preset:a", "preset:c", 6)])))")
            check(!rows(10, [("preset:b", "preset:a", 9)]).contains { $0.hasPrefix(SearchItem.comboPrefix) },
                  "duo dont un membre porte un autre titre : pas proposé")
            let threeDuos = rows(10, [("preset:a", "preset:c", 9), ("preset:d", "preset:e", 8), ("preset:c", "preset:d", 7)])
            check(threeDuos.filter { $0.hasPrefix(SearchItem.comboPrefix) }.count == AppCoordinator.maxCombosShown,
                  "au plus \(AppCoordinator.maxCombosShown) duos, pris dans topPairs(5)")
            let payload: [String: Any] = ["applied": ["clips": 2, "clipNames": ["plan 1.mov", "titre"]]]
            check(AppCoordinator.appliedClipNames(payload) == ["plan 1.mov", "titre"]
                    && AppCoordinator.appliedClipNames(["applied": ["clips": 1]]).isEmpty,
                  "applied.clipNames lus dans la réponse du plugin (absents : liste vide)")
            // Bout en bout hors Premiere : Alpha puis Charlie sur le MÊME clip, 4 fois, en
            // passant au clip suivant entre deux (T-13) → duo Alpha → Charlie.
            func chained(_ answer: (Int) -> [String: Any]) -> [String] {
                let flow = UsageStore(inMemory: true)
                let start = Date().addingTimeInterval(-3600)
                for i in 0..<4 {
                    let at = start.addingTimeInterval(Double(i) * 60)
                    flow.record(id: "preset:a", title: "Alpha", clips: AppCoordinator.appliedClipNames(answer(i)), at: at)
                    flow.record(id: "preset:c", title: "Charlie", clips: AppCoordinator.appliedClipNames(answer(i)),
                                at: at.addingTimeInterval(8))
                }
                return AppCoordinator.frequentRows(limit: 5, ranked: flow.top(10), pairs: flow.topPairs(5),
                                                   lookup: byId, titleOf: { flow.title(for: $0) },
                                                   idsForTitle: { catalogTitles[SearchItem.normalizedTitle($0)] ?? [] }).map(\.item.id)
            }
            let sameClip = chained { i in ["applied": ["clips": 1, "clipNames": ["plan \(i).mov"]]] }
            let noNames = chained { _ in ["applied": ["clips": 1]] }
            check(sameClip.contains("combo:preset:a|preset:c") && !noNames.contains { $0.hasPrefix(SearchItem.comboPrefix) },
                  "clips transmis : duo Alpha → Charlie après 4 enchaînements sur le même clip ; sans noms de clips : aucun duo")

            print("── SelfTest : Raccourcis presets, jamais un autre preset (C-04) ──")
            // Faux index : « Twin » porté par deux presets distincts, « Gaussian Blur » par un
            // effet ET un preset, « Glide » par un seul preset sous un nouvel id.
            let index = [preset("preset:h:glide", "Glide"), preset("preset:uid-renum", "Autre preset"),
                         preset("preset:twin1", "Twin"), preset("preset:twin2", "Twin"),
                         preset("preset:uid-blur", "Gaussian Blur"),
                         SearchItem(id: "effect:AE.ADBE Gaussian Blur 2", kind: "effect", title: "Gaussian Blur",
                                    subtitle: "", keywords: [], plan: ApplyPlan(label: "Gaussian Blur", operations: []),
                                    fidelityHint: "full"),
                         // Preset « Drop Shadow » renommé « Ombre titres » ; l'effet garde l'ancien nom.
                         preset("preset:uid-ombre", "Ombre titres"),
                         SearchItem(id: "effect:AE.ADBE Drop Shadow", kind: "effect", title: "Drop Shadow",
                                    subtitle: "", keywords: [], plan: ApplyPlan(label: "Drop Shadow", operations: []),
                                    fidelityHint: "full")]
            let indexById = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0) })
            let indexTitles = index.reduce(into: [String: Set<String>]()) {
                $0[SearchItem.normalizedTitle($1.title), default: []].insert($1.id)
            }
            func target(_ id: String, _ title: String) -> AppCoordinator.ShortcutTarget {
                AppCoordinator.resolveShortcut(itemId: id, title: title, lookup: indexById,
                                               idsForTitle: { indexTitles[SearchItem.normalizedTitle($0)] ?? [] })
            }
            check(target("preset:uid-renum", "Glide") == .item(id: "preset:h:glide"),
                  "id présent mais porté par un AUTRE preset : celui-ci n'est pas appliqué, « Glide » est retrouvé par son titre")
            check(target("preset:obj:12", "glide ") == .item(id: "preset:h:glide"),
                  "ancien id disparu, titre unique (casse, espaces) : rattaché au nouvel id")
            check(target("preset:obj:14", "Twin") == .ambiguous,
                  "deux presets « Twin » : refus (S21), rien appliqué")
            check(target("preset:obj:15", "Gaussian Blur") == .item(id: "preset:uid-blur")
                    && target("effect:AE.ADBE Gaussian Blur", "Gaussian Blur") == .item(id: "effect:AE.ADBE Gaussian Blur 2"),
                  "un preset ne se rattache qu'à un preset, un effet qu'à un effet (titres partagés)")
            check(target("preset:obj:16", "Introuvable") == .missing && target("preset:uid-renum", "Autre preset") == .item(id: "preset:uid-renum"),
                  "titre inconnu : introuvable ; id et titre concordants : appliqué tel quel")
            check(target("preset:uid-blur", "Mon flou") == .item(id: "preset:uid-blur")
                    && target("effect:AE.ADBE Gaussian Blur 2", "Flou gaussien") == .item(id: "effect:AE.ADBE Gaussian Blur 2"),
                  "preset renommé dans Premiere, effet d'un Premiere d'une autre langue (même id, ancien titre porté par personne) : raccourci gardé (m3)")
            check(target("preset:uid-ombre", "Drop Shadow") == .item(id: "preset:uid-ombre"),
                  "preset « Drop Shadow » renommé alors que l'EFFET porte toujours ce nom : raccourci gardé (seuls les items du même genre comptent, F3)")
            let renamedUsage = UsageStore(inMemory: true)
            renamedUsage.record(id: "preset:uid-blur", title: "Mon flou")
            renamedUsage.record(id: "preset:twin1", title: "Glide")
            let sameKindTaken: (String, String) -> Bool = { title, id in
                (indexTitles[SearchItem.normalizedTitle(title)] ?? []).contains { AppCoordinator.idKind($0) == AppCoordinator.idKind(id) }
            }
            renamedUsage.record(id: "preset:uid-ombre", title: "Drop Shadow")
            let retitled = renamedUsage.retitleRenamed(currentTitle: { indexById[$0]?.title }, titleTaken: sameKindTaken)
            check(retitled == 2 && renamedUsage.title(for: "preset:uid-blur") == "Gaussian Blur"
                    && renamedUsage.title(for: "preset:uid-ombre") == "Ombre titres"
                    && renamedUsage.title(for: "preset:twin1") == "Glide",
                  "reconstruction : titre mémorisé des fréquents mis à jour pour un renommage, pas quand l'ancien titre est encore porté")
            var renamedSettings = Settings()
            renamedSettings.presetShortcuts = [PresetShortcut(itemId: "preset:uid-blur", title: "Mon flou", shortcut: "cmd+e"),
                                               PresetShortcut(itemId: "preset:twin1", title: "Glide", shortcut: "cmd+p")]
            let shortcutsRetitled = renamedSettings.retitlingRenamedShortcuts(
                currentTitle: { indexById[$0]?.title }, titleTaken: sameKindTaken)
            check(shortcutsRetitled.renamed == 1 && shortcutsRetitled.settings.presetShortcuts?.map(\.title) == ["Gaussian Blur", "Glide"],
                  "reconstruction : titre du raccourci mis à jour pour un renommage, pas quand l'ancien titre est encore porté")

            print("── SelfTest : Accès Documents refusé, index gardé (C-08) ──")
            func decide(_ read: AppCoordinator.UserPresetRead, effects: Int = 108, had: Bool = true, has: Bool = false,
                        empty: Bool = false, provisional: Bool = false) -> (AppCoordinator.IndexUpdate, Bool) {
                let d = AppCoordinator.indexUpdate(presets: read, effectCount: effects, hadUserPresets: had,
                                                   hasUserPresets: has, currentIndexEmpty: empty,
                                                   currentIsProvisional: provisional)
                return (d.update, d.warnDocuments)
            }
            check(decide(.accessDenied, had: false, provisional: true) == (.install(complete: false), true)
                    && decide(.accessDenied, had: true, provisional: true) == (.keep, true)
                    && decide(.unreadable, had: false, provisional: true) == (.install(complete: false), false),
                  "1er lancement de la 0.8.4, accès refusé : l'index provisoire SANS presets perso est remplacé par les effets de Premiere ; avec des presets perso, gardé (m1)")
            check(decide(.accessDenied) == (.keep, true) && decide(.accessDenied, had: false) == (.keep, true),
                  "accès refusé : index ENTIER gardé (ni installation ni snapshot), S19")
            check(decide(.accessDenied, had: false, empty: true) == (.install(complete: false), true),
                  "accès refusé sur un index vide : effets et presets Adobe installés, sans snapshot, S19")
            // Ancien garde-fou : les PiP Adobe comptaient comme des presets — perso perdus, index écrasé.
            let before = [preset("preset:uid-perso", "Mon preset"), preset("preset:adobe:h:pip", "PiP 25% LL")]
            let after = [preset("preset:adobe:h:pip", "PiP 25% LL")]
            check(decide(.read, had: before.contains { $0.isUserPreset }, has: after.contains { $0.isUserPreset }) == (.keep, true)
                    && before.contains { $0.kind == "preset" } && after.contains { $0.kind == "preset" },
                  "presets PERSO disparus (les PiP Adobe restent) : index gardé + S19, plus d'écrasement silencieux")
            check(decide(.read, effects: 0, has: true) == (.keep, false), "Premiere rend 0 effet : index gardé")
            check(decide(.unreadable) == (.keep, false) && decide(.unreadable, empty: true) == (.install(complete: false), false),
                  "profil illisible : presets perso précédents gardés (index vide : installé sans eux, sans snapshot)")
            check(decide(.read, has: true) == (.install(complete: true), false)
                    && decide(.noFile, had: false) == (.install(complete: true), false),
                  "lecture normale, ou aucun preset perso ni avant ni après : installé, snapshot écrit")
            let profileFile = URL(fileURLWithPath: "/Users/prenom/Documents/Adobe/Premiere Pro/26.0/Profile-Prenom/Effect Presets and Custom Items.prfpset")
            check(AppCoordinator.maskedPresetLocation(profileFile) == "26.0/Profile-…",
                  "journal : dossier de version gardé, profil masqué (« \(AppCoordinator.maskedPresetLocation(profileFile)) »)")

            print("── SelfTest : Recherche reproposée après un échec venu de la palette (C-09) ──")
            func retry(_ code: String, _ committed: (query: String, itemId: String)?, item: String = "u:Camera Blur") -> String {
                AppCoordinator.retryAfterFailure(code: code, committed: committed, itemId: item)
                    .map { "\($0.query)|\($0.itemId)" } ?? "rien"
            }
            check(retry("NO_SELECTION", ("blur", "u:Camera Blur")) == "blur|u:Camera Blur"
                    && retry("NO_SEQUENCE", ("blur", "u:Camera Blur")) == "blur|u:Camera Blur",
                  "échec rattrapable venu de la palette : même recherche ET même ligne au prochain ⌘J")
            check(retry("NO_SELECTION", nil) == "rien",
                  "échec d'un raccourci preset (rien de validé dans la palette) : aucune recherche reproposée")
            check(retry("TIMEOUT", ("blur", "u:Camera Blur")) == "rien" && retry("BUSY", ("blur", "u:Camera Blur")) == "rien",
                  "délai dépassé, occupé : rien à reproposer (ce n'est pas un geste du monteur qui corrige)")
            check(retry("NO_SELECTION", ("", "u:Camera Blur")) == "|u:Camera Blur",
                  "validé dans les fréquents (champ vide, ⌘n) : les fréquents rouvrent sur la même ligne")
            check(retry("NO_SELECTION", ("blur", "u:Fast Blur In")) == "rien",
                  "validation qui n'est pas celle de cet échec : rien")

            print("── SelfTest : HUD et journal d'une application (C-10) ──")
            func answer(clips: Int, set: Int, skipped: Int = 0, failed: [String] = [], noSettings: [String] = [],
                        transactions: Int? = 2, mode: String = "single", detail: [[String: Any]] = []) -> [String: Any] {
                var fidelity: [String: Any] = ["paramsSet": set, "paramsSkipped": skipped, "namesDiffer": 0,
                                               "detail": detail, "paramsFailedClips": noSettings]
                if let transactions { fidelity["transactions"] = transactions }
                return ["applied": ["clips": clips, "clipNames": (0..<clips).map { "plan \($0).mov" }],
                        "skipped": ["items": failed.count, "failedClips": failed] as [String: Any],
                        "fidelity": fidelity, "transaction": mode, "latencyMs": 14]
            }
            let clean = AppCoordinator.applySummary(label: "Edge", payload: answer(clips: 3, set: 36))
            check(clean.message == LF("%@ → %ld clips", "Edge", 3) && clean.style == .success && clean.detailLine == nil,
                  "tout posé : « Edge → 3 clips », vert, pas de ligne de détail")
            check(clean.logLine.hasPrefix("apply OK : Edge, 3 clips appliqués,") && clean.logLine.contains("transactions=2")
                    && !clean.logLine.contains("transaction=single"),
                  "journal : début inchangé (relu par l'amorçage), « transactions=2 » au lieu de « transaction=single »")
            let big = AppCoordinator.applySummary(label: "Glow", payload: answer(clips: 500, set: 13_000, skipped: 500))
            check(big.message == LF("%@ → %ld clips", "Glow", 500) + LF(" — %ld/%ld parameters", 26, 27) && big.style == .warning,
                  "500 clips, un réglage sauté partout : « — 26/27 paramètres » PAR CLIP (plus « 13 000/13 500 »), en avertissement")
            let uneven = AppCoordinator.applySummary(label: "Glow", payload: answer(clips: 3, set: 34, skipped: 2))
            check(uneven.message.hasSuffix(LF(" — %ld/%ld parameters", 34, 36)) && uneven.style == .warning,
                  "réglages qui ne se répartissent pas exactement : totaux, comme avant")
            let longClip = AppCoordinator.applySummary(label: "Shake", payload: answer(clips: 3, set: 6, skipped: 3,
                detail: [["param": "Position", "reason": "TOO_MANY_KEYFRAMES"], ["param": "Scale", "reason": "TOO_MANY_KEYFRAMES"],
                         ["param": "Rotation", "reason": "TOO_MANY_KEYFRAMES"]]))
            let otherLanguage = AppCoordinator.applySummary(label: "Zoom", payload: answer(clips: 3, set: 6, skipped: 3,
                detail: [["param": "Echelle", "reason": "NAME_MISMATCH"]]))
            check(longClip.message.hasSuffix(LF(" — %ld/%ld parameters", 6, 9))
                    && otherLanguage.message.hasSuffix(LF(" — %ld/%ld parameters", 2, 3)),
                  "un clip long perd ses 3 réglages (TOO_MANY_KEYFRAMES) : totaux « 6/9 », pas « 2/3 » ; raison commune à tous les clips : par clip (m14)")
            let lost = AppCoordinator.applySummary(label: "Edge", payload: answer(clips: 3, set: 24, skipped: 12, noSettings: ["plan 2.mov"],
                                                                                  detail: [["clip": "plan 2.mov", "reason": "PARAMS_NOT_SET"]]))
            check(lost.message == LF("%@ → %ld clips", "Edge", 3) + L(" — settings not applied on 1 clip") + LF(" — %ld/%ld parameters", 24, 36)
                    && lost.style == .warning && lost.logLine.contains("sansRéglages=[\"plan 2.mov\"]")
                    && lost.detailLine?.contains("PARAMS_NOT_SET") == true,
                  "réglages non posés sur un clip : S23, totaux (pas de moyenne trompeuse), avertissement, détail journalisé")
            let two = AppCoordinator.applySummary(label: "Edge", payload: answer(clips: 4, set: 24, skipped: 24, noSettings: ["a", "b"]))
            check(two.message.contains(LF(" — settings not applied on %ld clips", 2)), "deux clips sans réglages : S22")
            let failedOne = AppCoordinator.applySummary(label: "Edge", payload: answer(clips: 2, set: 24, failed: ["c"], transactions: nil, mode: "per-clip"))
            check(failedOne.message.hasSuffix(L(" (1 clip not applied)")) && failedOne.style == .warning
                    && failedOne.logLine.contains("transactions=? (repli par clip)"),
                  "clip non appliqué : avertissement ; plugin sans `transactions` : « ? », repli par clip noté")
            let namesOnly = AppCoordinator.applySummary(label: "Zoom", payload: answer(clips: 1, set: 12,
                                                                                       detail: [["param": "Echelle", "reason": "NAME_DIFFERS_SAME_STRUCTURE"]]))
            let missingFx = AppCoordinator.applySummary(label: "Zoom", payload: answer(clips: 1, set: 12,
                                                                                       detail: [["matchName": "AE.X", "reason": "EFFECT_MISSING"]]))
            check(namesOnly.detailLine == nil && missingFx.detailLine?.contains("EFFECT_MISSING") == true,
                  "ligne de détail dès qu'une raison autre que NAME_DIFFERS_SAME_STRUCTURE apparaît")
            // La nouvelle ligne de journal reste lisible par l'amorçage des fréquents.
            let seedBox = fm.temporaryDirectory.appendingPathComponent("khanjar-selftest-c10-\(UUID().uuidString)")
            try? fm.createDirectory(at: seedBox, withIntermediateDirectories: true)
            let seedLog = seedBox.appendingPathComponent("Khanjar.log")
            try? Data("[2026-01-05 10:00:00.000] [info] \(lost.logLine)\n".utf8).write(to: seedLog)
            let seeded = UsageStore(fileURL: seedBox.appendingPathComponent("usage.json"))
            seeded.load()
            seeded.seedIfNeeded(items: [preset("preset:edge", "Edge")], logURL: seedLog)
            check(seeded.top(5).first.map { $0.id == "preset:edge" && $0.count == 1 } == true,
                  "l'amorçage des fréquents relit la nouvelle ligne « apply OK : … »")
            // settings.json : clés abîmées → S26 aussi (le lot I ne le signalait que pour un JSON illisible).
            let settingsBox = seedBox.appendingPathComponent("settings.json")
            try? Data(#"{"maxResults":"huit","shortcut":"cmd+k"}"#.utf8).write(to: settingsBox)
            let damaged = SettingsStore(fileURL: settingsBox)
            var issues: [SettingsIssue] = []
            damaged.onIssue = { issues.append($0) }
            damaged.load()
            var copied: URL?
            var resetKeys: [String] = []
            if case .valuesReset(let keys, let backup)? = issues.first { copied = backup; resetKeys = keys }
            check(issues.count == 1 && copied != nil && resetKeys == ["maxResults"]
                    && damaged.current.shortcut == "cmd+k" && damaged.current.maxResults == 8,
                  "settings.json avec une valeur abîmée : onIssue(.valuesReset([maxResults])) avec copie, le reste gardé (m9)")
            let someCopy = URL(fileURLWithPath: "/tmp/settings.json.illisible-test")
            check(AppCoordinator.settingsIssueMessage(.unreadable(backup: someCopy))
                    == L("Settings file unreadable — default settings in use") + L(" (a copy was kept)")
                    && AppCoordinator.settingsIssueMessage(.unreadable(backup: nil)) == L("Settings file unreadable — default settings in use")
                    && AppCoordinator.settingsIssueMessage(.valuesReset(keys: ["maxResults"], backup: someCopy))
                    == L("Some settings couldn't be read and were reset — your other settings are kept") + L(" (a copy was kept)")
                    && AppCoordinator.settingsIssueMessage(.saveFailed) == L("Couldn't save the settings (disk full?)"),
                  "réglages illisibles → S26 ; valeurs abîmées → « remis à zéro, le reste gardé » (m9) ; « copie gardée » seulement si elle existe ; enregistrement impossible → S27")
            try? fm.removeItem(at: seedBox)

            print("── SelfTest : Index provisoire depuis un snapshot d'une version antérieure (snapshot v7) ──")
            // Snapshot v6 synthétique (anciens ids « preset:obj:<n> ») : ses effets restent utilisables.
            let v6 = #"""
            {"version":6,"generatedAt":"2026-10-01T10:00:00Z","premiereVersion":"26.5.2","items":[
             {"id":"effect:AE.ADBE Gaussian Blur 2","kind":"effect","title":"Gaussian Blur","subtitle":"Video effect","keywords":[],"fidelityHint":"full",
              "plan":{"label":"Gaussian Blur","existingOperations":[],"operations":[{"matchName":"AE.ADBE Gaussian Blur 2","params":[],"anchorType":1,"srcDur":"0","paramCount":0}]}},
             {"id":"preset:obj:12","kind":"preset","title":"Glide","subtitle":"Preset","keywords":[],"fidelityHint":"full",
              "plan":{"label":"Glide","existingOperations":[],"operations":[{"matchName":"AE.ADBE Geometry2","params":[],"anchorType":1,"srcDur":"0","paramCount":12}]}},
             {"id":"effect:AE.ADBE Mosaic","kind":"effect","title":"Mosaïque","subtitle":"Video effect","keywords":[],"fidelityHint":"full",
              "plan":{"label":"Mosaïque","existingOperations":[],"operations":[{"matchName":"AE.ADBE Mosaic","params":[],"anchorType":1,"srcDur":"0","paramCount":0}]}}]}
            """#
            let fromV6 = IndexStore.snapshotEffects(from: Data(v6.utf8))
            check(fromV6?.version == 6 && fromV6?.premiereVersion == "26.5.2"
                    && fromV6?.effects.map(\.matchName) == ["AE.ADBE Gaussian Blur 2", "AE.ADBE Mosaic"]
                    && fromV6?.effects.map(\.displayName) == ["Gaussian Blur", "Mosaïque"],
                  "snapshot v6 : ses 2 effets relus (le preset aux anciens ids est ignoré, il sera reparsé)")
            let rebuilt = IndexStore.build(effects: fromV6?.effects ?? [], userPresets: [], factoryPresets: [])
            check(rebuilt.map(\.id) == ["effect:AE.ADBE Gaussian Blur 2", "effect:AE.ADBE Mosaic"]
                    && AppCoordinator.indexUpdate(presets: .noFile, effectCount: rebuilt.count, hadUserPresets: false,
                                                  hasUserPresets: false, currentIndexEmpty: true).update == .install(complete: true),
                  "index provisoire : effets de l'ancien snapshot installables sur un index vide")
            check(IndexStore.snapshotEffects(from: Data("{\"version\":6".utf8)) == nil
                    && IndexStore.snapshotEffects(from: Data(#"{"version":6,"premiereVersion":"26","items":[]}"#.utf8)) == nil,
                  "snapshot tronqué ou sans effet : rien (la palette attend le hello, comme avant)")
            check(AppCoordinator.guessedPresetLocale(["fr-FR", "en-US"]) == "fr-FR" && AppCoordinator.guessedPresetLocale([]) == "en_US",
                  "langue des presets Adobe de l'index provisoire : 1ʳᵉ langue du Mac, sinon anglais")
        }

        // ── Palette : Entrée hors du champ (« bip » chez un ami, 2026-10-08) ──
        print("── SelfTest : Palette (clavier) ──")
        _ = NSApplication.shared
        let palettePanel = PalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
        var returns = 0
        palettePanel.onReturn = { returns += 1 }
        func keyEvent(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        }
        if let e = keyEvent(36, "\r") { palettePanel.keyDown(with: e) }
        check(returns == 1, "Retour remonté jusqu'à la fenêtre (focus hors du champ) : appliqué, plus de bip")
        if let e = keyEvent(76, "\u{3}", [.numericPad, .function]) { palettePanel.keyDown(with: e) }
        check(returns == 2, "Entrée du pavé numérique / fn+Retour : appliqué aussi")

        // ── Lot U (interface) de l'audit du 2026-10-08 — tout hors écran, sans son ──
        // Bloc à part : ses noms locaux ne heurtent pas ceux des sections des autres lots.
        do {
            _ = NSApplication.shared
            print("── SelfTest : Palette ⌘1…⌘0 par touche physique (U-01) ──")
            func uKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [],
                      ignoring: String? = nil, window: Int = 0) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window, context: nil, characters: chars,
                                 charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code)
            }
            let digitPanel = PalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: true)
            var digits: [Int] = []
            var digitReturns = 0
            digitPanel.onDigit = { digits.append($0); return $0 == 1 }   // une seule ligne
            digitPanel.onReturn = { digitReturns += 1 }
            func digitKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> Bool {
                guard let e = uKey(code, chars, flags) else { return false }
                return digitPanel.performKeyEquivalent(with: e)
            }
            check(digitKey(18, "&", [.command]) && digits == [1],
                  "AZERTY : ⌘ + touche « & » (keyCode 18) → ligne 1")
            check(digitKey(18, "&", [.command, .capsLock]) && digits.last == 1, "même chose avec Verr. Maj")
            check(digitKey(18, "1", [.command, .shift]) && digits.last == 1, "⌘⇧ + touche 1 (le « 1 » d'AZERTY) → ligne 1")
            check(digitKey(83, "1", [.command, .numericPad]) && digits.last == 1, "⌘1 du pavé numérique (keyCode 83) → ligne 1")
            check(digitKey(82, "0", [.command, .numericPad]) && digits.last == 0
                    && digitKey(29, "à", [.command]) && digits.last == 0, "⌘0 (pavé 82, rangée 29 « à ») → 10ᵉ ligne")
            check(digitKey(23, "(", [.command]) && digits.last == 5, "⌘5 sans 5ᵉ ligne : consommé (plus de bip)")
            let digitCount = digits.count
            check(!digitKey(18, "&", []) && !digitKey(18, "&", [.option, .command]) && digits.count == digitCount,
                  "chiffre sans ⌘ (ou ⌥⌘) : laissé au champ, rien d'appliqué")
            check(digitKey(36, "\r", [.command]) && digitReturns == 1, "⌘↩ valide comme Entrée (plus de bip)")

            print("── SelfTest : filet Entrée avec Verr. Maj (U-08) ──")
            if let e = uKey(36, "\r", [.capsLock]) { digitPanel.keyDown(with: e) }
            check(digitReturns == 2, "Retour avec Verr. Maj remonté à la fenêtre : rattrapé (plus de bip)")
            if let e = uKey(76, "\u{3}", [.numericPad, .function, .capsLock]) { digitPanel.keyDown(with: e) }
            check(digitReturns == 3, "Entrée du pavé avec Verr. Maj : rattrapée aussi")

            print("── SelfTest : menu Édition invisible (U-04) ──")
            _ = PaletteWindowController()   // l'installe, comme au démarrage de l'app (hors écran)
            let editItems = NSApplication.shared.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            func editMenuHas(_ action: String, _ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
                editItems.contains { $0.action == NSSelectorFromString(action) && $0.keyEquivalent == key
                                     && $0.keyEquivalentModifierMask == mods }
            }
            check(editMenuHas("selectAll:", "a", .command), "⌘A → Tout sélectionner (selectAll:) présent")
            check(editMenuHas("cut:", "x", .command) && editMenuHas("copy:", "c", .command)
                    && editMenuHas("paste:", "v", .command), "⌘X ⌘C ⌘V → Couper, Copier, Coller")
            check(editMenuHas("undo:", "z", .command) && editMenuHas("redo:", "z", [.command, .shift]),
                  "⌘Z → Annuler, ⇧⌘Z → Rétablir")
            let menuCount = NSApplication.shared.mainMenu?.items.count
            EditMenu.installIfNeeded()
            check(menuCount == 2 && NSApplication.shared.mainMenu?.items.count == menuCount,
                  "menu principal installé une seule fois (app + Édition)")

            print("── SelfTest : réouverture après échec — bonne ligne, texte sélectionné (U-03) ──")
            func mirrored<T>(_ object: Any, _ name: String) -> T? {
                Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
            }
            let blurs = ["Gaussian Blur", "Fast Blur In", "Camera Blur", "Directional Blur"].map { title in
                SearchItem(id: "u:\(title)", kind: "preset", title: title, subtitle: "Preset · Test", keywords: [],
                           plan: ApplyPlan(label: title, operations: []), fidelityHint: "full")
            }
            let reopen = PaletteWindowController()
            reopen.onQuery = { q in blurs.filter { $0.title.lowercased().contains(q.lowercased()) }.map { ($0, 1.0) } }
            reopen.onFrequent = { _ in [] }
            var reopenCommits: [String] = []
            reopen.onCommit = { reopenCommits.append($0.id) }
            if let rPanel: PalettePanel = mirrored(reopen, "panel"), let rField: NSTextField = mirrored(reopen, "field"),
               let rTable: NSTableView = mirrored(reopen, "table") {
                _ = rPanel.makeFirstResponder(rField)   // hors écran : le champ passe en édition, rien ne s'affiche
                reopen.prefill("blur", selecting: "u:Camera Blur")
                let editor = rField.currentEditor() as? NSTextView
                check(rTable.selectedRow == 2, "« blur » + id de la 3ᵉ ligne → la 3ᵉ ligne revient en surbrillance (ligne \(rTable.selectedRow + 1))")
                check(editor?.selectedRange == NSRange(location: 0, length: 4),
                      "texte pré-rempli entièrement sélectionné (\(editor.map { NSStringFromRange($0.selectedRange()) } ?? "pas d'éditeur"))")
                if let e = uKey(5, "g") { editor?.keyDown(with: e) }
                check(rField.stringValue == "g", "une frappe REMPLACE la recherche reprise (« \(rField.stringValue) », avant : « blurg »)")
                reopen.prefill("blur", selecting: "u:Camera Blur")
                if let e = uKey(36, "\r") { rPanel.keyDown(with: e) }
                check(reopenCommits == ["u:Camera Blur"] && reopen.lastCommitted?.query == "blur"
                        && reopen.lastCommitted?.itemId == "u:Camera Blur" && reopen.lastCommittedQuery == "blur",
                      "Entrée relance la ligne choisie ; la palette retient requête + id")
                reopen.prefill("blur", selecting: "u:absent")
                check(rTable.selectedRow == 0, "id absent des résultats → 1ʳᵉ ligne, comme d'habitude")
                reopen.clearLastCommitted()
                check(reopen.lastCommitted == nil && reopen.lastCommittedQuery.isEmpty, "clearLastCommitted() oublie requête et id")
            } else {
                check(false, "accès aux vues de la palette (Mirror)")
            }

            print("── SelfTest : validation refusée = palette gardée (U-07) ──")
            if let rPanel: PalettePanel = mirrored(reopen, "panel") {
                var checked: [String] = []
                var accept = false
                reopen.onCommitChecked = { checked.append($0.id); return accept }
                reopenCommits.removeAll()
                reopen.prefill("blur", selecting: "u:Fast Blur In")
                if let e = uKey(36, "\r") { rPanel.keyDown(with: e) }
                check(checked == ["u:Fast Blur In"] && reopenCommits.isEmpty,
                      "onCommitChecked prioritaire sur onCommit (choix transmis : \(checked))")
                check(reopen.lastCommitted?.itemId == "u:Fast Blur In", "choix refusé quand même retenu (requête + id)")
                accept = true
                if let e = uKey(36, "\r") { rPanel.keyDown(with: e) }
                check(checked.count == 2 && reopenCommits.isEmpty, "Entrée suivante : nouvelle tentative avec la même ligne")
                reopen.onCommitChecked = nil
            } else {
                check(false, "accès au panneau de la palette (Mirror)")
            }

            print("── SelfTest : clavier pris avant de remplir la liste (U-06) ──")
            // show() réel, affichage INTERCEPTÉ : orderFront et makeKey sont remplacés
            // (sur PalettePanel seulement, le temps de l'appel) par un simple relevé.
            let opening = PaletteWindowController()
            if let oPanel: PalettePanel = mirrored(opening, "panel"), let oField: NSTextField = mirrored(opening, "field") {
                var trace: [String] = []
                var focusedWhenFilled = false
                opening.onFrequent = { _ in
                    trace.append("liste")
                    focusedWhenFilled = oField.currentEditor() != nil && oPanel.firstResponder === oField.currentEditor()
                    return []
                }
                opening.onQuery = { _ in [] }
                let orderFrontBlock: @convention(block) (NSWindow) -> Void = { _ in trace.append("orderFront") }
                let makeKeyBlock: @convention(block) (NSWindow) -> Void = { _ in trace.append("makeKey") }
                let isKeyBlock: @convention(block) (NSWindow) -> Bool = { _ in true }
                let swaps: [(Selector, Any)] = [(#selector(NSWindow.orderFrontRegardless), orderFrontBlock),
                                                (#selector(NSWindow.makeKey), makeKeyBlock),
                                                (#selector(getter: NSWindow.isKeyWindow), isKeyBlock)]
                var originals: [(Selector, IMP, UnsafePointer<CChar>?)] = []
                for (selector, block) in swaps {
                    guard let method = class_getInstanceMethod(PalettePanel.self, selector) else { continue }
                    originals.append((selector, method_getImplementation(method), method_getTypeEncoding(method)))
                    class_replaceMethod(PalettePanel.self, selector, imp_implementationWithBlock(block),
                                        method_getTypeEncoding(method))
                }
                if originals.count == swaps.count { opening.show() }
                for (selector, imp, types) in originals { class_replaceMethod(PalettePanel.self, selector, imp, types) }
                check(trace == ["orderFront", "makeKey", "liste"],
                      "ordre d'ouverture : fenêtre devant, clavier, PUIS remplissage de la liste (\(trace))")
                check(focusedWhenFilled, "le champ a déjà le clavier quand la liste se remplit")
            } else {
                check(false, "accès aux vues de la palette (Mirror)")
            }

            print("── SelfTest : VoiceOver (U-09) ──")
            if let vField: NSTextField = mirrored(reopen, "field"), let vEditor = vField.currentEditor() as? NSTextView {
                check(vField.accessibilityLabel() == L("Search effects and presets"),
                      "le champ de recherche a un nom pour VoiceOver (« \(vField.accessibilityLabel() ?? "aucun") »)")
                reopen.prefill("blur", selecting: "u:Camera Blur")
                check(reopen.spokenSelection == "Camera Blur", "annonce = la ligne en surbrillance (« \(reopen.spokenSelection ?? "-") »)")
                _ = reopen.control(vField, textView: vEditor, doCommandBy: #selector(NSResponder.moveDown(_:)))
                check(reopen.spokenSelection == "Directional Blur", "↓ : l'annonce suit la nouvelle ligne (« \(reopen.spokenSelection ?? "-") »)")
                reopen.prefill("zzz", selecting: nil)
                check(reopen.spokenSelection == LF("Nothing found for “%@”", "zzz"),
                      "aucun résultat : « Rien trouvé » est annoncé (« \(reopen.spokenSelection ?? "-") »)")
            } else {
                check(false, "accès au champ de la palette (Mirror)")
            }

            print("── SelfTest : palette dans l'écran utile (U-10) ──")
            // Recherche : 78 pt hors lignes ; fréquents : 100 pt (en-tête) ; 28 pt par ligne.
            let laptop = NSRect(x: 0, y: 0, width: 1280, height: 775)   // 13 pouces, ~775 pt utiles (audit A4)
            let twenty = PaletteWindowController.fit(top: laptop.height * HUD.anchorFraction, chrome: 78,
                                                     listHeight: 20 * 28, rowHeight: 28, visible: laptop)
            check(twenty.listHeight == 560 && twenty.top - 78 - 560 >= laptop.minY && twenty.top <= laptop.maxY,
                  "20 résultats sur 1280×800 : palette remontée, entière (haut à \(Int(twenty.top)) pt au lieu de \(Int(laptop.height * HUD.anchorFraction)))")
            let tiny = NSRect(x: 0, y: 40, width: 1024, height: 500)
            let squeezed = PaletteWindowController.fit(top: tiny.minY + tiny.height * HUD.anchorFraction, chrome: 78,
                                                       listHeight: 20 * 28, rowHeight: 28, visible: tiny)
            check(squeezed.listHeight == 14 * 28 && squeezed.top - 78 - squeezed.listHeight >= tiny.minY
                    && squeezed.top <= tiny.maxY, "écran trop petit : 14 lignes visibles sur 20, la liste défile")
            let roomy = NSRect(x: 0, y: 0, width: 1440, height: 875)
            let eight = PaletteWindowController.fit(top: roomy.height * HUD.anchorFraction, chrome: 100,
                                                    listHeight: 8 * 28, rowHeight: 28, visible: roomy)
            check(eight.top == roomy.height * HUD.anchorFraction && eight.listHeight == 224,
                  "8 fréquents sur 1440×900 : position et taille inchangées")
            if let visible = NSScreen.main?.visibleFrame {
                let tall = PaletteWindowController()
                let many = (1...20).map { n in
                    SearchItem(id: "u:n\(n)", kind: "preset", title: "Preset \(n)", subtitle: "Preset · Test", keywords: [],
                               plan: ApplyPlan(label: "Preset \(n)", operations: []), fidelityHint: "full")
                }
                tall.maxResults = 20
                tall.onQuery = { _ in many.map { ($0, 1.0) } }
                tall.onFrequent = { _ in [] }
                if let tPanel: PalettePanel = mirrored(tall, "panel"), let tField: NSTextField = mirrored(tall, "field") {
                    tField.stringValue = "preset"
                    tall.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tField))
                    check(tPanel.frame.minY >= visible.minY && tPanel.frame.maxY <= visible.maxY,
                          "palette réelle, 20 lignes, écran de ce Mac : entièrement dans la zone utile (\(NSStringFromRect(tPanel.frame)) dans \(NSStringFromRect(visible)))")
                }
            }

            print("── SelfTest : HUD au thème de la palette, pied ⌘1–⌘0 (U-11) ──")
            let themed = PaletteWindowController()
            let hudBefore = HUD.appearance
            themed.setTheme("dark")
            check(HUD.appearance?.name == .darkAqua, "thème sombre forcé : le HUD le prend aussi")
            themed.setTheme("light")
            check(HUD.appearance?.name == .aqua, "thème clair forcé : idem")
            themed.setTheme("system")
            check(HUD.appearance == nil, "thème système : le HUD suit le Mac")
            HUD.appearance = hudBefore
            let footer: NSTextField? = mirrored(themed, "footerLabel")
            check(footer?.stringValue == L("↵ apply  ·  ⌘1–⌘0 direct  ·  esc close"),
                  "pied : « \(footer?.stringValue ?? "-") » (⌘0 existe aussi)")

            print("── SelfTest : enregistreur de raccourci (U-02) ──")
            let needsModifier = ShortcutRecorder.Verdict.refused(L("Use ⌘ or ⌃ with a key"))
            let unsupported = ShortcutRecorder.Verdict.refused(L("Key not supported — try another"))
            let reserved = ShortcutRecorder.Verdict.refused(L("Premiere already uses this shortcut — choose another"))
            check(ShortcutRecorder.verdict(keyCode: 12, modifiers: [.control, .option]) == .accepted("alt+ctrl+q")
                    && SettingsStore.parseShortcut("alt+ctrl+q")?.keyCode == 12,
                  "AZERTY ⌃⌥A (touche physique 12) → « alt+ctrl+q », inscrit sur CETTE touche (avant : la touche Q)")
            check(ShortcutRecorder.verdict(keyCode: 38, modifiers: [.command, .shift]) == .accepted("cmd+shift+j"),
                  "clavier non latin : ⌘⇧ + touche J (« о » en russe) accepté par sa position")
            check(ShortcutRecorder.verdict(keyCode: 17, modifiers: [.shift]) == needsModifier
                    && ShortcutRecorder.verdict(keyCode: 45, modifiers: [.option]) == needsModifier
                    && ShortcutRecorder.verdict(keyCode: 17, modifiers: [.shift, .option]) == needsModifier,
                  "⇧T, ⌥N ou ⇧⌥T seuls refusés : « Use ⌘ or ⌃ with a key »")
            check(ShortcutRecorder.verdict(keyCode: 0, modifiers: [.command]) == reserved
                    && ShortcutRecorder.verdict(keyCode: 6, modifiers: [.command, .shift]) == reserved
                    && ShortcutRecorder.verdict(keyCode: 12, modifiers: [.command]) == reserved,
                  "⌘A, ⇧⌘Z, ⌘Q (touche 12 = A en AZERTY) refusés : Premiere s'en sert")
            check(ShortcutRecorder.verdict(keyCode: 123, modifiers: [.command, .numericPad, .function]) == unsupported,
                  "⌘← refusé : « Key not supported — try another »")
            check(ShortcutRecorder.verdict(keyCode: 53, modifiers: [.command]) == .cancel, "Échap annule")
            check(SettingsStore.isReservedShortcut("cmd+a") && SettingsStore.isReservedShortcut("cmd+shift+z")
                    && !SettingsStore.isReservedShortcut("ctrl+alt+a") && !SettingsStore.isReservedShortcut("cmd+shift+k"),
                  "réservés : ⌘A, ⇧⌘Z ; libres : ⌃⌥A, ⇧⌘K")
            let roundTrip = (0..<128).compactMap { code -> UInt16? in
                guard let token = SettingsStore.token(forKeyCode: UInt16(code)) else { return nil }
                return SettingsStore.parseShortcut("ctrl+" + token)?.keyCode == UInt32(code) ? nil : UInt16(code)
            }
            check(roundTrip.isEmpty && SettingsStore.token(forKeyCode: 12) == "q",
                  "jeton de position ↔ touche physique : aller-retour exact (écarts : \(roundTrip))")

            let recWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled],
                                     backing: .buffered, defer: false)   // jamais affichée
            recWindow.isReleasedWhenClosed = false
            let otherWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            let recorder = ShortcutRecorder(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
            let secondRecorder = ShortcutRecorder(frame: NSRect(x: 0, y: 30, width: 180, height: 24))
            recWindow.contentView?.addSubview(recorder)
            recWindow.contentView?.addSubview(secondRecorder)
            var recorderChanges = 0
            recorder.onChange = { recorderChanges += 1 }
            recorder.set("cmd+j")
            func press(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent? {
                uKey(code, chars, flags, window: window.windowNumber).flatMap { recorder.handle($0) }
            }
            recorder.performClick(nil)
            let foreign = press(5, "g", [], in: otherWindow)
            check(recorder.isRecording && foreign != nil && recorder.shortcut == "cmd+j",
                  "frappe d'une autre fenêtre (la palette) : rendue intacte, pas capturée")
            check(press(17, "T", [.shift], in: recWindow) == nil && !recorder.isRecording && recorder.shortcut == "cmd+j"
                    && !recorder.messageLabel.isHidden && recorder.messageLabel.stringValue == L("Use ⌘ or ⌃ with a key"),
                  "⇧T refusé : ⌘J reste en place, la raison s'affiche sous le bouton")
            recorder.performClick(nil)
            check(press(12, "a", [.control, .option], in: recWindow) == nil && recorder.shortcut == "alt+ctrl+q"
                    && recorder.messageLabel.isHidden && recorderChanges == 1,
                  "⌃⌥ + touche 12 enregistré (« \(recorder.shortcut ?? "-") »), message effacé")
            recorder.performClick(nil)
            secondRecorder.performClick(nil)
            check(!recorder.isRecording && secondRecorder.isRecording, "cliquer un 2ᵉ enregistreur arrête le 1ᵉʳ")
            secondRecorder.cancelRecording()
            recorder.performClick(nil)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: recWindow)
            check(!recorder.isRecording, "fenêtre quittée (perte du focus) : enregistrement arrêté")
            recorder.performClick(nil)
            recWindow.close()
            check(!recorder.isRecording && recorder.shortcut == "alt+ctrl+q", "fenêtre fermée : plus de moniteur, valeur gardée")
            recorder.performClick(nil)
            recorder.set("cmd+j")
            check(!recorder.isRecording, "set() (rechargement des Réglages) arrête l'enregistrement")

            print("── SelfTest : conflits de raccourcis (U-05) ──")
            let blurShortcut = PresetShortcut(itemId: "u:blur", title: "Blur", shortcut: "ctrl+alt+b")
            check(SettingsWindowController.conflict(for: "cmd+k", palette: ["cmd+j", "cmd+k"], adjustment: ["cmd+shift+j"],
                                                    presets: []) == LF("the palette (%@)", SettingsStore.pretty("cmd+k")),
                  "palette passée à ⌘K dans l'enregistreur (pas encore enregistrée) : conflit vu, vrai raccourci affiché")
            check(SettingsWindowController.conflict(for: "cmd+shift+j", palette: ["cmd+j"], adjustment: ["cmd+shift+j"],
                                                    presets: []) == L("the adjustment layer"), "conflit avec le calque d'effets")
            check(SettingsWindowController.conflict(for: "alt+ctrl+b", palette: [], adjustment: [], presets: [blurShortcut])
                    == LF("“%@”", "Blur"), "même combinaison écrite dans un autre ordre : conflit avec le preset")
            check(SettingsWindowController.conflict(for: "cmd+k", palette: ["cmd+j"], adjustment: ["cmd+shift+j"],
                                                    presets: [blurShortcut]) == nil, "combinaison libre : aucun conflit")
            var reportedHotkeys: Set<String> = []
            check(HotkeyService.isFirstFailure(id: 100, keyCode: 40, modifiers: 256, reported: &reportedHotkeys)
                    && !HotkeyService.isFirstFailure(id: 100, keyCode: 40, modifiers: 256, reported: &reportedHotkeys)
                    && HotkeyService.isFirstFailure(id: 100, keyCode: 41, modifiers: 256, reported: &reportedHotkeys),
                  "inscription refusée : HUD au 1ᵉʳ échec seulement, de nouveau pour une autre combinaison")
        }

        print(failures.isEmpty
              ? "SELFTEST OK (\(0) échec)"
              : "SELFTEST ÉCHEC : \(failures.count) cas — \(failures.joined(separator: " | "))")
        return failures.isEmpty ? 0 : 1
    }

    private static func f(_ value: Double) -> String { String(format: "%.3f", value) }
}
