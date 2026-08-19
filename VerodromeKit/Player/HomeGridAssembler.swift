import Foundation

/// Builds the even-count Home shortcut grid: recents first, then unique fillers,
/// capped at 6 and snapped down to 4, 2, or 0 when a 2-column layout would be uneven.
public enum HomeGridAssembler {
    public static let targetCount = 6

    public static func assemble<Item>(
        recents: [Item],
        fillers: [Item],
        id: (Item) -> String
    ) -> [Item] {
        var seen = Set<String>()
        var result: [Item] = []
        result.reserveCapacity(targetCount)
        for item in recents + fillers {
            guard seen.insert(id(item)).inserted else { continue }
            result.append(item)
            if result.count == targetCount { break }
        }
        let evenCount = result.count & ~1
        return Array(result.prefix(evenCount))
    }
}
