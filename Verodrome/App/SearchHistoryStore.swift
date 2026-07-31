import Foundation

@MainActor
final class SearchHistoryStore: ObservableObject {
    @Published var terms: [String] = []

    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terms.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        terms.insert(trimmed, at: 0)
        if terms.count > 12 { terms = Array(terms.prefix(12)) }
    }
}
