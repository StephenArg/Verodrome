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
    static let preferredOrder: [String] =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init) + ["#", "&", "?"]

    static func sortKey(for section: String) -> (Int, String) {
        if let idx = preferredOrder.firstIndex(of: section) {
            return (idx, section)
        }
        return (preferredOrder.count, section)
    }

    static func group<Item>(
        _ items: [Item],
        sectionKey: (Item) -> String
    ) -> [(letter: String, items: [Item])] {
        let grouped = Dictionary(grouping: items, by: sectionKey)
        return grouped
            .map { (letter: $0.key, items: $0.value) }
            .sorted { sortKey(for: $0.letter) < sortKey(for: $1.letter) }
    }
}
