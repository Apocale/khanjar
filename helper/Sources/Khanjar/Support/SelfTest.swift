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

        // Dans la fenêtre → duo ; hors fenêtre → deux gestes indépendants.
        let near = UsageStore(inMemory: true)
        for i in 0..<5 {
            let base = t0.addingTimeInterval(Double(i) * 3600)
            near.record(id: "a", title: "A", at: base)
            near.record(id: "b", title: "B", at: base.addingTimeInterval(8))
        }
        check(near.topPairs(5).first.map { $0.from == "a" && $0.to == "b" && $0.count == 5 } == true,
              "5 enchaînements A→B à 8 s détectés comme duo")

        let far = UsageStore(inMemory: true)
        for i in 0..<5 {
            let base = t0.addingTimeInterval(Double(i) * 7200)
            far.record(id: "a", title: "A", at: base)
            far.record(id: "b", title: "B", at: base.addingTimeInterval(UsageStore.pairWindowSeconds + 30))
        }
        check(far.topPairs(5).isEmpty, "au-delà de \(Int(UsageStore.pairWindowSeconds)) s, aucun duo")

        // Sous le seuil de répétition, rien n'est proposé.
        let rare = UsageStore(inMemory: true)
        for i in 0..<(UsageStore.minPairObservations - 1) {
            let base = t0.addingTimeInterval(Double(i) * 3600)
            rare.record(id: "a", title: "A", at: base)
            rare.record(id: "b", title: "B", at: base.addingTimeInterval(5))
        }
        check(rare.topPairs(5).isEmpty, "sous \(UsageStore.minPairObservations) observations, aucun duo proposé")

        // Les deux sens comptent ensemble ; le sens majoritaire l'emporte.
        let mixed = UsageStore(inMemory: true)
        for i in 0..<3 {
            let base = t0.addingTimeInterval(Double(i) * 3600)
            mixed.record(id: "x", title: "X", at: base)
            mixed.record(id: "y", title: "Y", at: base.addingTimeInterval(6))
        }
        for i in 0..<5 {
            let base = t0.addingTimeInterval(Double(i + 10) * 3600)
            mixed.record(id: "y", title: "Y", at: base)
            mixed.record(id: "x", title: "X", at: base.addingTimeInterval(6))
        }
        let top = mixed.topPairs(5)
        check(top.count == 1 && top[0].from == "y" && top[0].to == "x" && top[0].count == 8,
              "les deux sens fusionnent en un duo (8 fois), sens majoritaire Y→X conservé")

        // Répéter le même item n'est pas un duo.
        let same = UsageStore(inMemory: true)
        for i in 0..<6 { same.record(id: "a", title: "A", at: t0.addingTimeInterval(Double(i) * 10)) }
        check(same.topPairs(5).isEmpty, "le même item répété ne fabrique pas un duo")

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

        print(failures.isEmpty
              ? "SELFTEST OK (\(0) échec)"
              : "SELFTEST ÉCHEC : \(failures.count) cas — \(failures.joined(separator: " | "))")
        return failures.isEmpty ? 0 : 1
    }

    private static func f(_ value: Double) -> String { String(format: "%.3f", value) }
}
