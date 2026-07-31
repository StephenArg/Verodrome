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

/// Trailing A–Z scrubber used to jump to list sections.
struct AlphabetIndexBar: View {
    let letters: [String]
    var onSelect: (String) -> Void

    @State private var activeLetter: String?
    private let feedback = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: letterFontSize(for: letters.count), weight: .semibold))
                        .foregroundStyle(activeLetter == letter ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !letters.isEmpty else { return }
                        let height = max(geo.size.height, 1)
                        let y = min(max(0, value.location.y), height - 0.001)
                        let index = min(letters.count - 1, Int(y / height * CGFloat(letters.count)))
                        let letter = letters[index]
                        if letter != activeLetter {
                            activeLetter = letter
                            feedback.selectionChanged()
                            onSelect(letter)
                        }
                    }
                    .onEnded { _ in
                        activeLetter = nil
                    }
            )
        }
        .frame(width: 20)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Alphabet index")
        .accessibilityAddTraits(.isButton)
    }

    private func letterFontSize(for count: Int) -> CGFloat {
        switch count {
        case ...20: return 11
        case ...26: return 10
        default: return 9
        }
    }
}

private struct AlphabetSection<Item: Identifiable>: Identifiable {
    let letter: String
    let items: [Item]
    var id: String { letter }
}

/// Groups rows into alphabetic `List` sections with a trailing letter scrubber.
/// Sections are cached and only rebuilt when the item identity fingerprint changes,
/// so unrelated `@EnvironmentObject` publishes (e.g. player) do not regroup thousands of rows.
struct AlphabetIndexedList<Item, Row: View>: View where Item: Identifiable, Item.ID: CustomStringConvertible {
    let items: [Item]
    let sectionTitle: KeyPath<Item, String>
    /// Optional label for PerfTrace (e.g. "Songs", "Artists").
    var perfLabel: String? = nil
    @ViewBuilder var row: (Item) -> Row

    @State private var sections: [AlphabetSection<Item>] = []
    @State private var letters: [String] = []

    init(
        items: [Item],
        sectionTitle: KeyPath<Item, String>,
        perfLabel: String? = nil,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self.sectionTitle = sectionTitle
        self.perfLabel = perfLabel
        self.row = row
    }

    private var itemsFingerprint: String {
        guard let first = items.first, let last = items.last else { return "0" }
        return "\(items.count)|\(first.id)|\(last.id)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            // Uniform trailing inset so row text/icons clear the A–Z scrubber
                            // without shifting rows relative to each other.
                            row(item)
                                .padding(.trailing, letters.count > 1 ? 18 : 0)
                        }
                    } header: {
                        Text(section.letter)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .id(sectionAnchor(section.letter))
                    }
                }
            }
            .listStyle(.plain)
            .overlay(alignment: .trailing) {
                if letters.count > 1 {
                    AlphabetIndexBar(letters: letters) { letter in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(sectionAnchor(letter), anchor: .top)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .task(id: itemsFingerprint) {
            rebuildSections()
        }
    }

    private func rebuildSections() {
        let label = perfLabel.map { "\($0).alphabetSections" } ?? "AlphabetIndexedList.sections"
        PerfTrace.measure(label, details: "items=\(items.count)") {
            let grouped = AlphabetSectioning.group(items) { item in
                item[keyPath: sectionTitle].sectionInitial
            }
            sections = grouped.map { AlphabetSection(letter: $0.letter, items: $0.items) }
            letters = grouped.map(\.letter)
        }
        PerfTrace.event(
            "\(label).ready",
            details: "sections=\(sections.count) letters=\(letters.joined())"
        )
    }

    private func sectionAnchor(_ letter: String) -> String {
        "alphabet-section-\(letter)"
    }
}
