import Foundation

/// Classement « fréquence + récence » des items réellement appliqués.
///
/// POURQUOI (2026-09-21, mesuré sur 982 applications réelles) : l'utilisateur
/// n'emploie que 41 entrées sur 436, et 3 presets font 76 % des applications.
/// Ouvrir la palette sur un champ vide lui fait donc retaper, à chaque fois,
/// le nom de ce qu'il applique de toute façon. On affiche le classement quand
/// le champ est vide ; dès la première lettre, la recherche reprend la main.
///
/// POURQUOI PAS LA FRÉQUENCE SEULE : la queue du classement est mince (40, 30,
/// 27, 22… applications). Un preset très utilisé en juillet et abandonné depuis
/// occuperait une ligne devant celui du projet en cours. On décote donc le passé.
///
/// MODÈLE : décroissance exponentielle, demi-vie 30 jours. Un usage d'aujourd'hui
/// vaut 1, le même il y a 30 jours vaut 0,5, il y a 60 jours 0,25. Équivalent à
/// la somme de toutes les utilisations pondérées par leur âge, mais en O(1) de
/// stockage : on décote le score accumulé jusqu'à l'instant présent, puis on
/// ajoute 1. `count` n'entre pas dans le tri : il ne sert qu'à l'affichage.
struct UsageEntry: Codable {
    var count: Int          // nombre brut d'applications (affichage « 418 × »)
    var score: Double       // score décoté à la date `lastUsed`
    var lastUsed: Date
    var title: String       // secours d'affichage si l'item disparaît de l'index
}

final class UsageStore {

    /// Demi-vie du score. 30 jours : un projet client dure quelques semaines,
    /// le classement doit suivre le montage en cours sans oublier les habitudes.
    static let halfLifeDays = 30.0

    /// Deux applications séparées de moins de ça = un enchaînement voulu, pas
    /// deux gestes indépendants. Mesuré sur l'usage réel (2026-10-02) : le duo
    /// « Edge + 2 drop shadow » / « Gaussian Blur » revient 43 fois en 11 jours,
    /// avec une médiane de 6 à 8 secondes entre les deux. 120 s laisse de la
    /// marge pour un repositionnement de la tête de lecture entre les deux.
    static let pairWindowSeconds = 120.0

    /// En deçà, un enchaînement est une coïncidence, pas une habitude.
    static let minPairObservations = 4

    private var entries: [String: UsageEntry] = [:]
    /// Enchaînements observés : id appliqué → id appliqué juste après → nombre.
    private var transitions: [String: [String: Int]] = [:]
    /// Dernière application vue (vraie ou rejouée), pour détecter les duos.
    private var lastApplied: (id: String, date: Date)?
    private var seeded = false
    private var seededPairs = false
    /// Suspend les écritures disque pendant un rejeu (≈1000 appels à record).
    private var bulkLoading = false
    private let log = Logger.shared
    /// Mode test : aucune écriture disque (le selftest ne doit jamais toucher
    /// au classement réel de l'utilisateur).
    private let inMemory: Bool

    init(inMemory: Bool = false) { self.inMemory = inMemory }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }

    private struct Payload: Codable {
        var version: Int
        var seeded: Bool
        var entries: [String: UsageEntry]
        /// v2 : enchaînements. Optionnels — un usage.json v1 reste lisible.
        var seededPairs: Bool?
        var transitions: [String: [String: Int]]?
    }

    // MARK: - Persistance

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            log.error("usage.json illisible — classement des fréquents reparti de zéro")
            return
        }
        entries = payload.entries
        seeded = payload.seeded
        transitions = payload.transitions ?? [:]
        seededPairs = payload.seededPairs ?? false
    }

    private func save() {
        guard !inMemory, !bulkLoading else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(version: 2, seeded: seeded, entries: entries,
                              seededPairs: seededPairs, transitions: transitions)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Score

    /// Décote un score de `from` vers `to`. Jamais de remontée dans le temps
    /// (horloge reculée, journal rejoué) : on rend le score tel quel.
    private static func decayed(_ score: Double, from: Date, to: Date) -> Double {
        let days = to.timeIntervalSince(from) / 86_400
        guard days > 0, score > 0 else { return score }
        return score * pow(0.5, days / halfLifeDays)
    }

    /// Enregistre une application réussie. `date` doit croître (le rejeu du
    /// journal est chronologique) — sinon le score reste correct, seul le
    /// classement relatif de cette entrée est légèrement conservateur.
    /// Note l'enchaînement avec l'application précédente, puis retient celle-ci.
    /// Appelé aussi bien en direct qu'au rejeu du journal : même règle, mêmes
    /// chiffres. Un même item répété ne compte pas (ce n'est pas un duo).
    private func noteTransition(to id: String, at date: Date) {
        if let last = lastApplied, last.id != id {
            let gap = date.timeIntervalSince(last.date)
            if gap > 0, gap <= Self.pairWindowSeconds {
                transitions[last.id, default: [:]][id, default: 0] += 1
            }
        }
        lastApplied = (id, date)
    }

    func record(id: String, title: String, at date: Date = Date()) {
        noteTransition(to: id, at: date)
        var entry = entries[id] ?? UsageEntry(count: 0, score: 0, lastUsed: date, title: title)
        let now = max(date, entry.lastUsed)
        entry.score = Self.decayed(entry.score, from: entry.lastUsed, to: now) + 1
        entry.count += 1
        entry.lastUsed = now
        entry.title = title
        entries[id] = entry
        save()
    }

    /// Ids les mieux classés à l'instant `now`, du plus fort au plus faible.
    /// Égalité de score départagée par le nombre brut, puis par le titre : le
    /// classement ne doit jamais sautiller d'une ouverture à l'autre.
    func top(_ limit: Int, now: Date = Date()) -> [(id: String, count: Int, score: Double)] {
        entries
            .map { (id: $0.key,
                    count: $0.value.count,
                    score: Self.decayed($0.value.score, from: $0.value.lastUsed, to: now),
                    title: $0.value.title) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
            .map { (id: $0.id, count: $0.count, score: $0.score) }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Application d'un duo : on crédite les DEUX membres et l'enchaînement
    /// lui-même, exactement comme si l'utilisateur les avait appliqués l'un
    /// après l'autre. Sans ça, se servir du duo ferait lentement disparaître
    /// le duo du classement — l'outil s'auto-saboterait à l'usage.
    func recordCombo(from: String, to: String) {
        let now = Date()
        lastApplied = nil
        record(id: from, title: entries[from]?.title ?? from, at: now)
        record(id: to, title: entries[to]?.title ?? to, at: now.addingTimeInterval(1))
    }

    /// Enchaînements assez répétés pour valoir un duo, du plus fréquent au moins.
    /// L'ORDRE COMPTE : (a → b) veut dire « a appliqué, puis b » — donc b se
    /// retrouve AU-DESSUS de a dans la pile d'effets. Vérifié dans les projets
    /// de l'utilisateur (2026-10-02) : sur 63 clips portant le duo flou/contour,
    /// 86 % ont le flou au-dessus, c'est-à-dire appliqué en dernier.
    /// Les deux sens d'une même paire sont fusionnés : on garde le majoritaire.
    func topPairs(_ limit: Int) -> [(from: String, to: String, count: Int)] {
        var merged: [String: (from: String, to: String, count: Int)] = [:]
        for (from, tos) in transitions {
            for (to, n) in tos {
                let key = [from, to].sorted().joined(separator: "\u{0}")
                let total = n + (transitions[to]?[from] ?? 0)
                guard total >= Self.minPairObservations else { continue }
                // Sens majoritaire ; égalité tranchée par l'ordre des ids pour
                // que le classement ne change pas d'un lancement à l'autre.
                let reverse = transitions[to]?[from] ?? 0
                let keep = n > reverse || (n == reverse && from < to)
                if keep, merged[key] == nil || merged[key]!.count < total {
                    merged[key] = (from: from, to: to, count: total)
                }
            }
        }
        return merged.values
            .sorted { $0.count != $1.count ? $0.count > $1.count
                                           : ($0.from + $0.to) < ($1.from + $1.to) }
            .prefix(limit).map { $0 }
    }

    // MARK: - Amorçage depuis le journal existant

    /// Au tout premier lancement, le classement serait vide et la palette
    /// s'ouvrirait sur rien pendant des semaines. On rejoue donc l'historique
    /// déjà écrit dans `helper.log` (« apply OK : <titre>, N clips appliqués »),
    /// avec la date de chaque ligne : le classement est juste dès la 1ʳᵉ ouverture.
    /// Les titres qui ne correspondent plus à aucun item sont ignorés.
    func seedIfNeeded(items: [SearchItem]) {
        // `seeded` = compteurs, `seededPairs` = enchaînements (ajoutés en v2 :
        // un usage.json déjà amorcé doit pouvoir rejouer les paires SANS
        // redoubler les compteurs).
        guard !seeded || !seededPairs else { return }
        let needCounts = !seeded
        // Un index sans preset (permission Documents refusée) résoudrait mal les
        // titres : on attend un index complet plutôt que d'amorcer de travers.
        guard items.contains(where: { $0.kind == "preset" }) else { return }

        var byTitle: [String: SearchItem] = [:]
        for item in items {
            let key = item.title.trimmingCharacters(in: .whitespaces).lowercased()
            if byTitle[key] == nil { byTitle[key] = item }
        }

        let logURL = Logger.shared.fileURL
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            seeded = true
            seededPairs = true
            save()
            return
        }
        bulkLoading = true
        defer { bulkLoading = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var replayed = 0, unknown = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let marker = line.range(of: " apply OK : ") else { continue }
            let rest = line[marker.upperBound...]
            // « <titre>, <N> clips appliqués » — le titre peut contenir des
            // virgules, on part donc de la fin.
            guard let clips = rest.range(of: " clips appliqués") else { continue }
            let head = rest[..<clips.lowerBound]
            guard let comma = head.range(of: ", ", options: .backwards) else { continue }
            let title = String(head[..<comma.lowerBound])

            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            guard let date = formatter.date(from: stamp) else { continue }

            guard let item = byTitle[title.trimmingCharacters(in: .whitespaces).lowercased()] else {
                unknown += 1
                continue
            }
            if needCounts { record(id: item.id, title: item.title, at: date) }
            else { noteTransition(to: item.id, at: date) }
            replayed += 1
        }

        seeded = true
        seededPairs = true
        lastApplied = nil   // le rejeu ne doit pas créer un duo avec la 1ʳᵉ vraie application
        bulkLoading = false
        save()
        let pairs = topPairs(10).count
        log.info("Fréquents amorcés depuis le journal : \(replayed) applications rejouées\(needCounts ? "" : " (enchaînements seuls)"), \(unknown) titres inconnus, \(entries.count) items classés, \(pairs) duo(s) détecté(s)")
    }
}
