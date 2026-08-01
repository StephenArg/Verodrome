import SwiftUI
import UIKit
import VerodromeKit

extension String {
    /// Amperfy-compatible alphabetic section key for library indexes.
    var sectionInitial: String {
        guard !isEmpty else { return "?" }
        let initial = String(
            prefix(1)
                .folding(options: .diacriticInsensitive, locale: nil)
                .uppercased()
        )
        if initial.rangeOfCharacter(from: .decimalDigits) != nil {
            return "#"
        }
        if initial.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
            return initial
        }
        if initial.rangeOfCharacter(from: .letters) != nil {
            return "&"
        }
        return "?"
    }
}

enum AlphabetSectioning {
    static let letterSections: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    /// Digits, non-Latin letters, and everything else `sectionInitial` can't place.
    static let symbolSections = ["#", "&", "?"]

    /// The order section headers appear in for a sort option.
    ///
    /// The fetch returns rows in this same order, which is what lets a limited head
    /// page be a true prefix of what ends up on screen.
    static func sectionOrder(for sort: LibrarySortOption) -> [String] {
        let letters = sort.sortsTitleDescending ? letterSections.reversed() : Array(letterSections)
        return sort.showsSymbolsFirst ? symbolSections + letters : letters + symbolSections
    }

    static func sortKey(for section: String, in order: [String]) -> (Int, String) {
        if let idx = order.firstIndex(of: section) {
            return (idx, section)
        }
        return (order.count, section)
    }

    /// Groups items by section key, ordering the sections by `order`. Items keep the
    /// order they arrived in, so a descending fetch stays descending inside each
    /// section.
    static func group<Item>(
        _ items: [Item],
        order: [String],
        sectionKey: (Item) -> String
    ) -> [(letter: String, items: [Item])] {
        let grouped = Dictionary(grouping: items, by: sectionKey)
        return grouped
            .map { (letter: $0.key, items: $0.value) }
            .sorted { sortKey(for: $0.letter, in: order) < sortKey(for: $1.letter, in: order) }
    }
}
