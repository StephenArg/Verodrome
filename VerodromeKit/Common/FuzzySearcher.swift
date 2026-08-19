import Foundation

public struct FuzzySearchResult<Item>: Sendable {
    public let item: Item
    public let score: Double
    public let matchedRanges: [Range<String.Index>]

    public init(item: Item, score: Double, matchedRanges: [Range<String.Index>] = []) {
        self.item = item
        self.score = score
        self.matchedRanges = matchedRanges
    }
}

public enum FuzzySearcher {
    /// Returns a score in 0...1 where 1 is a perfect match. Empty query returns 1.
    public static func score(query: String, against candidate: String) -> Double {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !normalizedQuery.isEmpty else { return 1 }
        guard !normalizedCandidate.isEmpty else { return 0 }

        if normalizedCandidate == normalizedQuery { return 1 }
        if normalizedCandidate.hasPrefix(normalizedQuery) { return 0.95 }
        if normalizedCandidate.contains(normalizedQuery) { return 0.85 }

        let subsequenceScore = subsequenceMatchScore(query: normalizedQuery, candidate: normalizedCandidate)
        let tokenScore = tokenOverlapScore(query: normalizedQuery, candidate: normalizedCandidate)
        return max(subsequenceScore, tokenScore)
    }

    public static func ranked<Item>(
        query: String,
        items: [Item],
        keyPath: KeyPath<Item, String>,
        minimumScore: Double = 0.25
    ) -> [FuzzySearchResult<Item>] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return items.map { FuzzySearchResult(item: $0, score: 1) }
        }

        return items
            .map { item in
                let text = item[keyPath: keyPath]
                let value = score(query: query, against: text)
                return FuzzySearchResult(item: item, score: value)
            }
            .filter { $0.score >= minimumScore }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.item[keyPath: keyPath].localizedCaseInsensitiveCompare(rhs.item[keyPath: keyPath]) == .orderedAscending
                }
                return lhs.score > rhs.score
            }
    }

    private static func subsequenceMatchScore(query: String, candidate: String) -> Double {
        var queryIndex = query.startIndex
        var candidateIndex = candidate.startIndex
        var matched = 0
        var consecutiveBonus = 0
        var lastWasMatch = false

        while queryIndex < query.endIndex, candidateIndex < candidate.endIndex {
            if query[queryIndex] == candidate[candidateIndex] {
                matched += 1
                if lastWasMatch { consecutiveBonus += 1 }
                lastWasMatch = true
                queryIndex = query.index(after: queryIndex)
            } else {
                lastWasMatch = false
            }
            candidateIndex = candidate.index(after: candidateIndex)
        }

        guard matched == query.count else { return 0 }

        let base = Double(matched) / Double(max(query.count, candidate.count))
        let bonus = Double(consecutiveBonus) / Double(max(1, query.count * 2))
        return min(0.8, base + bonus * 0.1)
    }

    private static func tokenOverlapScore(query: String, candidate: String) -> Double {
        let queryTokens = Set(query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }))
        let candidateTokens = Set(candidate.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }))
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let overlap = queryTokens.intersection(candidateTokens).count
        return Double(overlap) / Double(queryTokens.count) * 0.75
    }
}
