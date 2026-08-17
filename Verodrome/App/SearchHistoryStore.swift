import Foundation

@MainActor
final class SearchHistoryStore: ObservableObject {
    private static let defaultsKey = "search.recentTerms"
    private static let limit = 25

    @Published private(set) var terms: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = Self.load(from: defaults)
    }

    private let defaults: UserDefaults

    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // While typing, debounce can land "b" then later "beatles". Treat those as one
        // evolving query: replace the newest entry when one string is a prefix of the other.
        if let newest = terms.first {
            let previous = newest.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let next = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if previous != next, next.hasPrefix(previous) || previous.hasPrefix(next) {
                terms.removeFirst()
            }
        }

        terms.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        terms.insert(trimmed, at: 0)
        // Newest is at the front — drop from the end so the oldest leave first.
        while terms.count > Self.limit {
            terms.removeLast()
        }
        persist()
    }

    func remove(_ term: String) {
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        persist()
    }

    func clear() {
        terms.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(terms, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String] {
        guard let saved = defaults.array(forKey: defaultsKey) as? [String] else { return [] }
        return Array(saved.prefix(limit))
    }
}
