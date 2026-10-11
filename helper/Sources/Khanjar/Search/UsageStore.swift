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

    /// 2026-10-09 (audit A3#1, décision Q4 d'Isma) : un sens n'est retenu que
    /// s'il pèse au moins 3 fois le sens inverse. Avant, la majorité simple
    /// suffisait : « Edge + 2 drop shadow » et « Gaussian Blur » alternés clip
    /// après clip s'équilibraient (45/51), le sens retenu a basculé 8 fois depuis
    /// juillet et ⌘2 posait le flou SOUS le contour, l'inverse de 128 clips sur
    /// 129 de ses projets. Une habitude ambiguë ne donne plus de duo du tout.
    static let pairDominance = 3

    /// 2026-10-09 (audit A3#7) : les enchaînements ne vieillissaient jamais — un
    /// duo de juillet gardait ⌘2 après un changement de projet. Un sens qui n'a
    /// plus été vu depuis 60 jours ne compte plus.
    static let pairMaxAgeDays = 60.0

    /// Un enchaînement dans UN sens : nombre d'observations et dernière date.
    struct PairStat: Codable {
        var count: Int
        var last: Date
    }

    private var entries: [String: UsageEntry] = [:]
    /// Enchaînements observés : id appliqué → id appliqué juste après, SUR UN
    /// MÊME CLIP (v3, 2026-10-09) → compte et dernière date.
    private var transitions: [String: [String: PairStat]] = [:]
    /// Dernière application vue, avec ses clips, pour détecter les duos.
    private var lastApplied: (id: String, date: Date, clips: Set<String>)?
    private var seeded = false
    /// 2026-10-09 (audit A3#8, cas 2) : tant que l'index n'a pas de preset, l'amorçage
    /// attend, mais les applications sont déjà comptées en direct ; rejouer ensuite TOUT
    /// le journal les comptait deux fois (et un enchaînement vu 2 fois atteignait le seuil).
    /// Seules les lignes du journal ANTÉRIEURES à cette date sont rejouées. Fixée au
    /// premier chargement sans amorçage, gardée dans usage.json jusqu'à l'amorçage.
    private(set) var seedCutoff: Date?
    /// Gardé dans le fichier pour un retour à une version antérieure : vrai =
    /// l'ancienne app ne rejoue pas les paires du journal (qui n'ont pas de clip).
    private var seededPairs = true
    /// Suspend les écritures disque pendant un rejeu (≈1000 appels à record).
    private var bulkLoading = false
    /// usage.json illisible ET impossible à mettre de côté : on ne l'écrase jamais.
    private var saveDisabled = false
    /// Instances de TEST (en mémoire, ou sur un fichier dédié) : journal muet (C-11) — un
    /// selftest lancé hors HOME jetable écrivait sinon de fausses lignes (« usage.json
    /// illisible »…) dans le vrai Khanjar.log, trompeuses pour un diagnostic.
    private var log: Logger { inMemory || customURL != nil ? .muted : .shared }
    /// Mode test : aucune écriture disque (le selftest ne doit jamais toucher
    /// au classement réel de l'utilisateur).
    private let inMemory: Bool
    /// Tests : fichier dédié dans un dossier temporaire, jamais le vrai usage.json.
    private let customURL: URL?

    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        self.customURL = nil
    }

    /// Tests hors Premiere (2026-10-09) : lit et écrit CE fichier.
    init(fileURL: URL) {
        self.inMemory = false
        self.customURL = fileURL
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Khanjar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }

    private var storeURL: URL { customURL ?? Self.fileURL }

    /// Version écrite. v3 (2026-10-09) : enchaînements par clip, datés, sous la
    /// clé `pairs`. La clé v2 `transitions` n'est plus lue : un fichier v1/v2 est
    /// relu avec ses compteurs, ses enchaînements sont jetés (voir `load`).
    static let payloadVersion = 3

    private struct Payload: Codable {
        var version: Int
        var seeded: Bool
        var entries: [String: UsageEntry]
        /// Optionnels — un usage.json v1 reste lisible.
        var seededPairs: Bool?
        /// v3 : enchaînements sur un même clip (from → to → compte, dernière date).
        var pairs: [String: [String: PairStat]]?
        /// Voir `seedCutoff` (présent seulement avant l'amorçage).
        var seedCutoff: Date?
    }

    // MARK: - Persistance

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else {
            seedCutoff = seedCutoff ?? Date()   // Mac neuf : l'amorçage rejouera le journal d'avant
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storeURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            // 2026-10-09 (audit A3#8, cas 1) : un usage.json tronqué était réécrit au
            // prochain enregistrement — 42 entrées remplacées par les 7 que le journal
            // (2 jours) permettait de rejouer, « Slide up text » (476 applications)
            // perdu, sans copie. Il est désormais mis de côté AVANT toute écriture.
            var backup = storeURL.deletingLastPathComponent()
                .appendingPathComponent("usage.json.illisible-\(Self.backupStamp(Date()))")
            var n = 2
            while fm.fileExists(atPath: backup.path) {
                backup = backup.deletingLastPathComponent()
                    .appendingPathComponent("usage.json.illisible-\(Self.backupStamp(Date()))-\(n)")
                n += 1
            }
            do {
                try fm.moveItem(at: storeURL, to: backup)
                log.error("usage.json illisible — mis de côté (\(backup.lastPathComponent)), classement des fréquents reparti de zéro")
            } catch {
                log.error("usage.json illisible et impossible à mettre de côté (\(error.localizedDescription)) — classement en mémoire seulement")
                saveDisabled = true
            }
            seedCutoff = Date()
            return
        }
        entries = payload.entries
        seeded = payload.seeded
        seedCutoff = seeded ? nil : (payload.seedCutoff ?? Date())
        seededPairs = true
        if payload.version >= 3 {
            transitions = payload.pairs ?? [:]
        } else {
            // 2026-10-09 (audit A3#1, décision Q4) : les enchaînements v1/v2 ont été
            // comptés sans savoir si les deux applications visaient le même clip
            // (« contour sur un clip, flou sur le suivant » comptait comme un duo) et
            // on ne peut plus les trier : remis à zéro. Les compteurs restent. Les
            // duos reviennent seuls après quelques enchaînements nets.
            transitions = [:]
            // Relecture finale (2026-10-11) : copie de l'ancien fichier AVANT la
            // conversion — sans elle, un retour à la 0.8.3 ne retrouvait plus ses duos.
            let copy = storeURL.deletingLastPathComponent().appendingPathComponent("usage.json.v\(payload.version)")
            if !inMemory, !fm.fileExists(atPath: copy.path) { try? fm.copyItem(at: storeURL, to: copy) }
            log.info("usage.json v\(payload.version) : enchaînements remis à zéro (comptés sans le clip), \(entries.count) compteurs gardés — ancien fichier copié (\(copy.lastPathComponent))")
            save()
        }
    }

    private func save() {
        guard !inMemory, !bulkLoading, !saveDisabled else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(version: Self.payloadVersion, seeded: seeded, entries: entries,
                              seededPairs: seededPairs, pairs: transitions,
                              seedCutoff: seeded ? nil : seedCutoff)
        // 2026-10-09 (audit A3#8) : une écriture ratée (disque plein…) n'était pas journalisée.
        do {
            try encoder.encode(payload).write(to: storeURL, options: .atomic)
        } catch {
            log.error("usage.json non enregistré : \(error.localizedDescription)")
        }
    }

    /// « aaaammjj-hhmmss » (calendrier grégorien, quel que soit le réglage du Mac).
    static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
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
    /// Un même item répété ne compte pas (ce n'est pas un duo).
    ///
    /// 2026-10-09 (audit A3#1, décision Q4) : un enchaînement n'est compté que si
    /// la 2ᵉ application touche AU MOINS UN CLIP de la 1ʳᵉ (`clips` = noms des clips
    /// appliqués, renvoyés par le plugin dans `applied.clipNames`). Avant, deux
    /// applications à moins de 120 s comptaient quel que soit le clip : « contour
    /// sur le clip 1, flou sur le clip 1, contour sur le clip 2… » notait autant
    /// flou → contour (en passant au clip suivant) que contour → flou, et chez un
    /// ami « A sur un clip, B sur le suivant » fabriquait un duo qui pose A et B
    /// sur le MÊME clip. Liste de clips vide (rejeu du journal, appelant qui ne
    /// les connaît pas) = aucun enchaînement. Limite connue : deux clips
    /// différents portant le même nom comptent comme un seul.
    private func noteTransition(to id: String, clips: Set<String>, at date: Date) {
        if let last = lastApplied, last.id != id, !clips.isEmpty, !last.clips.isDisjoint(with: clips) {
            let gap = date.timeIntervalSince(last.date)
            if gap > 0, gap <= Self.pairWindowSeconds {
                var stat = transitions[last.id]?[id] ?? PairStat(count: 0, last: date)
                stat.count += 1
                stat.last = max(stat.last, date)
                transitions[last.id, default: [:]][id] = stat
            }
        }
        lastApplied = (id, date, clips)
    }

    func record(id: String, title: String, clips: [String] = [], at date: Date = Date()) {
        noteTransition(to: id, clips: Set(clips), at: date)
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
    /// `title` (2026-10-09, contrat C-03) : titre mémorisé, pour vérifier qu'un id
    /// désigne toujours le même preset.
    func top(_ limit: Int, now: Date = Date()) -> [(id: String, count: Int, score: Double, title: String)] {
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
            .map { $0 }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Titre mémorisé pour un id (C-03, 2026-10-09) : les membres d'un duo n'ont que
    /// leur id dans `topPairs` ; la palette vérifie qu'il désigne toujours ce preset.
    func title(for id: String) -> String? { entries[id]?.title }

    /// Application d'un duo : on crédite les DEUX membres et l'enchaînement
    /// lui-même, exactement comme si l'utilisateur les avait appliqués l'un
    /// après l'autre. Sans ça, se servir du duo ferait lentement disparaître
    /// le duo du classement — l'outil s'auto-saboterait à l'usage.
    /// `clips` (2026-10-09) : les clips du duo, qui portent les deux membres —
    /// l'enchaînement n'est crédité que s'ils sont connus (même règle que `record`).
    func recordCombo(from: String, to: String, clips: [String]) {
        let now = Date()
        lastApplied = nil
        record(id: from, title: entries[from]?.title ?? from, clips: clips, at: now)
        record(id: to, title: entries[to]?.title ?? to, clips: clips, at: now.addingTimeInterval(1))
    }

    /// Enchaînements assez répétés pour valoir un duo, du plus fréquent au moins.
    /// L'ORDRE COMPTE : (a → b) veut dire « a appliqué, puis b » — donc b se
    /// retrouve AU-DESSUS de a dans la pile d'effets.
    ///
    /// 2026-10-09 (audit A3#1 et A3#7, décision Q4) — règle actuelle :
    ///  - un sens vu pour la dernière fois il y a plus de `pairMaxAgeDays` ne compte plus ;
    ///  - un sens est retenu s'il a au moins `minPairObservations` observations ET
    ///    au moins `pairDominance` fois celles du sens inverse. Avant : les deux sens
    ///    étaient additionnés et la majorité simple gagnait, égalité tranchée par
    ///    l'ordre alphabétique des ids — le sens se jouait à pile ou face ;
    ///  - `count` = observations du SENS RETENU seul (avant : somme des deux sens).
    func topPairs(_ limit: Int, now: Date = Date()) -> [(from: String, to: String, count: Int)] {
        let maxAge = Self.pairMaxAgeDays * 86_400
        func live(_ from: String, _ to: String) -> Int {
            guard let stat = transitions[from]?[to], now.timeIntervalSince(stat.last) <= maxAge else { return 0 }
            return stat.count
        }
        var kept: [(from: String, to: String, count: Int)] = []
        for (from, tos) in transitions {
            for to in tos.keys where to != from {
                let n = live(from, to)
                guard n >= Self.minPairObservations, n >= Self.pairDominance * live(to, from) else { continue }
                kept.append((from: from, to: to, count: n))
            }
        }
        // Ordre stable d'un lancement à l'autre : compte, puis ids.
        return kept
            .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.from, $0.to) < ($1.from, $1.to) }
            .prefix(limit).map { $0 }
    }

    // MARK: - Ids périmés (contrat I-02 ↔ C-04)

    /// 2026-10-09 (audit A3#2) : les ids « preset:obj:<n> » ont été remplacés (empreinte
    /// « h: », espace « adobe: », favoris fusionnés) et un preset sans UID modifié change
    /// d'id. Une entrée dont l'id n'est plus dans l'index est rattachée au NOUVEL id quand
    /// son titre désigne un seul item (`idForTitle` : l'appelant compare les titres par
    /// `SearchItem.normalizedTitle` et renvoie nil si aucun ou plusieurs ids DISTINCTS —
    /// deux items au même PresetUID, cas réel d'un preset dupliqué, sont un seul id :
    /// sur une copie des données d'Isma, compter les items laissait « 2 drop shadow
    /// preset » orphelin, compter les ids distincts le rattache). Si l'id cible a déjà une entrée, les
    /// deux fusionnent (compteurs additionnés, scores décotés à la même date). Jamais d'un
    /// genre à l'autre (un effet disparu n'est pas rattaché à un preset du même nom). Rien
    /// n'est perdu : une entrée sans correspondance unique reste telle quelle.
    /// Retourne le nombre d'entrées rattachées.
    @discardableResult
    func remapUnknownIds(validIds: Set<String>, idForTitle: (String) -> String?) -> Int {
        func kind(_ id: String) -> Substring { id.split(separator: ":", maxSplits: 1).first ?? "" }
        var mapping: [String: String] = [:]
        for (oldId, entry) in entries where !validIds.contains(oldId) {
            guard let newId = idForTitle(entry.title), newId != oldId, validIds.contains(newId),
                  kind(newId) == kind(oldId) else { continue }
            mapping[oldId] = newId
        }
        guard !mapping.isEmpty else { return 0 }

        for (oldId, newId) in mapping {
            guard let moved = entries.removeValue(forKey: oldId) else { continue }
            guard let target = entries[newId] else { entries[newId] = moved; continue }
            let last = max(target.lastUsed, moved.lastUsed)
            entries[newId] = UsageEntry(
                count: target.count + moved.count,
                score: Self.decayed(target.score, from: target.lastUsed, to: last)
                     + Self.decayed(moved.score, from: moved.lastUsed, to: last),
                lastUsed: last,
                title: target.title)
        }
        // Enchaînements : mêmes rattachements (comptes additionnés, date la plus récente).
        var remapped: [String: [String: PairStat]] = [:]
        for (from, tos) in transitions {
            for (to, stat) in tos {
                let a = mapping[from] ?? from, b = mapping[to] ?? to
                guard a != b else { continue }
                if var existing = remapped[a]?[b] {
                    existing.count += stat.count
                    existing.last = max(existing.last, stat.last)
                    remapped[a, default: [:]][b] = existing
                } else {
                    remapped[a, default: [:]][b] = stat
                }
            }
        }
        transitions = remapped
        if let last = lastApplied, let newId = mapping[last.id] {
            lastApplied = (newId, last.date, last.clips)
        }
        save()
        log.info("Fréquents : \(mapping.count) entrée(s) rattachée(s) à leur nouvel id par le titre")
        return mapping.count
    }

    /// m3 (relecture finale, 2026-10-11) — entrées dont l'id existe toujours mais sous
    /// un AUTRE titre (preset renommé dans Premiere, effet d'un Premiere d'une autre
    /// langue) : le titre mémorisé suit, si plus aucun item DU MÊME GENRE ne porte
    /// l'ancien (`titleTaken(titre, id)`). Sinon la palette vérifierait l'ancien nom.
    @discardableResult
    func retitleRenamed(currentTitle: (String) -> String?, titleTaken: (_ title: String, _ id: String) -> Bool) -> Int {
        var changed = 0
        for (id, entry) in entries {
            guard let title = currentTitle(id),
                  SearchItem.normalizedTitle(title) != SearchItem.normalizedTitle(entry.title),
                  !titleTaken(entry.title, id) else { continue }
            var renamed = entry
            renamed.title = title
            entries[id] = renamed
            changed += 1
        }
        guard changed > 0 else { return 0 }
        save()
        log.info("Fréquents : \(changed) titre(s) mis à jour (presets renommés dans Premiere)")
        return changed
    }

    // MARK: - Amorçage depuis le journal existant

    /// Au tout premier lancement, le classement serait vide et la palette
    /// s'ouvrirait sur rien pendant des semaines. On rejoue donc l'historique
    /// déjà écrit dans `helper.log` (« apply OK : <titre>, N clips appliqués »),
    /// avec la date de chaque ligne : le classement est juste dès la 1ʳᵉ ouverture.
    /// Les titres qui ne correspondent plus à aucun item sont ignorés.
    /// `logURL` : le journal de l'app (paramètre pour les tests, 2026-10-09).
    func seedIfNeeded(items: [SearchItem], logURL: URL = Logger.shared.fileURL) {
        // `seeded` = compteurs. 2026-10-09 (audit A3#1) : les enchaînements ne sont
        // plus jamais rejoués depuis le journal — il ne contient pas les clips, or
        // un enchaînement ne compte désormais que sur un même clip.
        guard !seeded else { return }
        // Un index sans preset (permission Documents refusée) résoudrait mal les
        // titres : on attend un index complet plutôt que d'amorcer de travers.
        guard items.contains(where: { $0.kind == "preset" }) else { return }

        var byTitle: [String: SearchItem] = [:]
        for item in items {
            let key = item.title.trimmingCharacters(in: .whitespaces).lowercased()
            if byTitle[key] == nil { byTitle[key] = item }
        }

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

        var replayed = 0, unknown = 0, live = 0
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
            // Déjà comptée en direct (après le 1ᵉʳ chargement) : ne pas la compter deux fois.
            if let cutoff = seedCutoff, date >= cutoff { live += 1; continue }

            guard let item = byTitle[title.trimmingCharacters(in: .whitespaces).lowercased()] else {
                unknown += 1
                continue
            }
            // Sans clips : compteurs seulement, aucun enchaînement (voir noteTransition).
            record(id: item.id, title: item.title, at: date)
            replayed += 1
        }

        seeded = true
        seededPairs = true
        seedCutoff = nil
        lastApplied = nil   // le rejeu ne doit pas créer un duo avec la 1ʳᵉ vraie application
        bulkLoading = false
        save()
        log.info("Fréquents amorcés depuis le journal : \(replayed) applications rejouées, \(unknown) titres inconnus, \(live) déjà comptées en direct, \(entries.count) items classés")
    }
}
