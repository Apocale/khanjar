import Foundation

/// Scorer fuzzy pour palette de commande — port de l'algorithme
/// « command-score » (cmdk/⌘K, hérité de Superhuman) : récursif, multiplicatif
/// dans [0, 1], bonus début-de-mot et initiales (« TDS » → « True Drop
/// Shadow »), pénalité par caractère sauté.
///
/// Adaptations :
///  - pliage des diacritiques (« gauss » ↔ « gaussien »), UI française oblige ;
///  - recherche sur titre + mots-clés + champ combiné (requêtes multi-champs
///    type « lumetri cine ») ;
///  - PERFORMANCE : le pliage Unicode est coûteux → les items sont PRÉPARÉS
///    une fois au chargement de l'index (`prepare`), jamais par frappe.
///    Budget §10 : < 5 ms par frappe sur l'index complet.
enum Scorer {

    // Constantes de l'algorithme original
    private static let scoreContinueMatch = 1.0
    private static let scoreSpaceWordJump = 0.9
    private static let scoreNonSpaceWordJump = 0.8
    private static let scoreCharacterJump = 0.17
    private static let penaltySkipped = 0.999
    private static let penaltyCaseMismatch = 0.9999
    private static let penaltyNotComplete = 0.99

    private static let gapSeparators = Set(" /-_()[]·.".map { $0 })

    // MARK: - Préparation (une fois par chargement d'index)

    struct Candidate {
        let original: [Character]
        let folded: [Character]

        init(_ text: String) {
            let orig = Array(text)
            let folded = Array(Scorer.fold(text))
            // Le pliage doit préserver la longueur pour aligner les bonus de
            // casse/camelCase ; sinon on travaille sur le plié des deux côtés.
            if folded.count == orig.count {
                self.original = orig
                self.folded = folded
            } else {
                self.original = folded
                self.folded = folded
            }
        }
    }

    struct PreparedItem {
        let item: SearchItem
        let title: Candidate
        let keywords: [Candidate]
        let combined: Candidate?
    }

    static func prepare(_ items: [SearchItem]) -> [PreparedItem] {
        items.map { item in
            PreparedItem(
                item: item,
                title: Candidate(item.title),
                keywords: item.keywords.map(Candidate.init),
                combined: item.keywords.isEmpty
                    ? nil
                    : Candidate(item.keywords.joined(separator: " ") + " " + item.title)
            )
        }
    }

    // MARK: - Scoring

    /// Titre à plein poids, mots-clés décotés à 70 %, champ combiné à 60 %.
    static func score(queryFolded: [Character], prepared: PreparedItem) -> Double {
        var best = score(queryFolded: queryFolded, candidate: prepared.title)
        for keyword in prepared.keywords {
            best = max(best, score(queryFolded: queryFolded, candidate: keyword) * 0.7)
        }
        if let combined = prepared.combined {
            best = max(best, score(queryFolded: queryFolded, candidate: combined) * 0.6)
        }
        return best
    }

    static func score(queryFolded: [Character], candidate: Candidate) -> Double {
        guard !queryFolded.isEmpty, !candidate.folded.isEmpty,
              isSubsequence(queryFolded, of: candidate.folded) else { return 0 }
        // Mémo en tableau plat : (sIdx, qIdx) → score, -1 = non calculé
        var memo = [Double](repeating: -1,
                            count: (candidate.folded.count + 1) * (queryFolded.count + 1))
        return inner(cand: candidate.original, candFolded: candidate.folded,
                     query: queryFolded, sIdx: 0, qIdx: 0, memo: &memo)
    }

    /// Tri : score décroissant puis titre alphabétique. Seuil anti-bruit.
    static func rank(query: String, prepared: [PreparedItem], limit: Int) -> [(item: SearchItem, score: Double)] {
        let queryFolded = Array(fold(query))
        guard !queryFolded.isEmpty else { return [] }
        let scored = prepared.compactMap { p -> (SearchItem, Double)? in
            let s = score(queryFolded: queryFolded, prepared: p)
            return s > 0.05 ? (p.item, s) : nil
        }
        return Array(scored.sorted {
            $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.prefix(limit))
    }

    // MARK: - API de commodité (tests, appels ponctuels)

    static func score(query: String, candidate: String) -> Double {
        score(queryFolded: Array(fold(query)), candidate: Candidate(candidate))
    }

    static func score(query: String, item: SearchItem) -> Double {
        score(queryFolded: Array(fold(query)), prepared: prepare([item])[0])
    }

    static func rank(query: String, items: [SearchItem], limit: Int) -> [(item: SearchItem, score: Double)] {
        rank(query: query, prepared: prepare(items), limit: limit)
    }

    // MARK: - Cœur récursif mémoïsé

    private static func inner(cand: [Character], candFolded: [Character],
                              query: [Character], sIdx: Int, qIdx: Int,
                              memo: inout [Double]) -> Double {
        if qIdx == query.count {
            return sIdx == cand.count ? scoreContinueMatch : penaltyNotComplete
        }
        let memoKey = sIdx &* (query.count + 1) &+ qIdx
        if memo[memoKey] >= 0 { return memo[memoKey] }

        let target = query[qIdx]
        var high = 0.0
        var index = indexOf(target, in: candFolded, from: sIdx)

        while let i = index {
            var branch = inner(cand: cand, candFolded: candFolded, query: query,
                               sIdx: i + 1, qIdx: qIdx + 1, memo: &memo)
            if branch > high {
                if i == sIdx {
                    branch *= scoreContinueMatch
                } else if gapSeparators.contains(cand[i - 1]) {
                    branch *= scoreSpaceWordJump
                } else if isWordStart(cand, at: i) {
                    branch *= scoreNonSpaceWordJump
                } else {
                    branch *= scoreCharacterJump
                }
                branch *= pow(penaltySkipped, Double(i - sIdx))
                // Requête et candidat sont comparés pliés ; si l'original
                // diffère du caractère requêté, c'est un écart de casse ou
                // d'accent → pénalité (sans allocation de String).
                if cand[i] != target { branch *= penaltyCaseMismatch }
                if branch > high { high = branch }
            }
            index = indexOf(target, in: candFolded, from: i + 1)
        }

        memo[memoKey] = high
        return high
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        var n = 0
        for char in haystack {
            if char == needle[n] {
                n += 1
                if n == needle.count { return true }
            }
        }
        return false
    }

    private static func indexOf(_ char: Character, in array: [Character], from: Int) -> Int? {
        var i = from
        while i < array.count {
            if array[i] == char { return i }
            i += 1
        }
        return nil
    }

    private static func isWordStart(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = chars[index - 1]
        let curr = chars[index]
        if gapSeparators.contains(prev) { return true }
        return (prev.isLowercase && curr.isUppercase) || (!prev.isNumber && curr.isNumber)
    }

    /// Minuscules + suppression des diacritiques.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
    }
}
