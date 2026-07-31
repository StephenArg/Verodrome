import Foundation
import SwiftData

/// Merges duplicate library entities that share the same compoundRemoteId.
@MainActor
public enum DuplicateMaintenance {
    @discardableResult
    public static func resolveAll(account: Account, context: ModelContext) throws -> Int {
        let resolver = DuplicateResolver(context: context)
        var merged = 0

        for group in try resolver.findDuplicateArtists(account: account) {
            try resolver.mergeDuplicateArtists(group)
            merged += group.duplicates.count - 1
        }
        for group in try resolver.findDuplicateAlbums(account: account) {
            try resolver.mergeDuplicateAlbums(group)
            merged += group.duplicates.count - 1
        }
        for group in try resolver.findDuplicateSongs(account: account) {
            try resolver.mergeDuplicateSongs(group)
            merged += group.duplicates.count - 1
        }
        return merged
    }
}
