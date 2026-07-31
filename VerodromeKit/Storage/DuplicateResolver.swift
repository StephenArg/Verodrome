import Foundation
import SwiftData

public struct DuplicateGroup<T: PersistentModel>: Sendable {
    public let compoundRemoteId: String
    public let duplicates: [T]
}

public final class DuplicateResolver {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func findDuplicateArtists(account: Account) throws -> [DuplicateGroup<Artist>] {
        try findDuplicates(account: account, items: try fetchAll(Artist.self, account: account), key: \.compoundRemoteId)
    }

    public func findDuplicateAlbums(account: Account) throws -> [DuplicateGroup<Album>] {
        try findDuplicates(account: account, items: try fetchAll(Album.self, account: account), key: \.compoundRemoteId)
    }

    public func findDuplicateSongs(account: Account) throws -> [DuplicateGroup<Song>] {
        try findDuplicates(account: account, items: try fetchAll(Song.self, account: account), key: \.compoundRemoteId)
    }

    public func mergeDuplicateArtists(_ group: DuplicateGroup<Artist>) throws {
        guard group.duplicates.count > 1 else { return }
        let keeper = group.duplicates[0]
        for duplicate in group.duplicates.dropFirst() {
            for album in duplicate.albums where !keeper.albums.contains(where: { $0.persistentModelID == album.persistentModelID }) {
                album.artist = keeper
                keeper.albums.append(album)
            }
            for song in duplicate.songs where !keeper.songs.contains(where: { $0.persistentModelID == song.persistentModelID }) {
                song.artist = keeper
                keeper.songs.append(song)
            }
            context.delete(duplicate)
        }
        try context.save()
    }

    public func mergeDuplicateAlbums(_ group: DuplicateGroup<Album>) throws {
        guard group.duplicates.count > 1 else { return }
        let keeper = group.duplicates[0]
        for duplicate in group.duplicates.dropFirst() {
            for song in duplicate.songs where !keeper.songs.contains(where: { $0.persistentModelID == song.persistentModelID }) {
                song.album = keeper
                keeper.songs.append(song)
            }
            if duplicate.newestIndex > 0 && (keeper.newestIndex == 0 || duplicate.newestIndex < keeper.newestIndex) {
                keeper.newestIndex = duplicate.newestIndex
            }
            if duplicate.recentIndex > 0 && (keeper.recentIndex == 0 || duplicate.recentIndex < keeper.recentIndex) {
                keeper.recentIndex = duplicate.recentIndex
            }
            keeper.isFavorite = keeper.isFavorite || duplicate.isFavorite
            context.delete(duplicate)
        }
        try context.save()
    }

    public func mergeDuplicateSongs(_ group: DuplicateGroup<Song>) throws {
        guard group.duplicates.count > 1 else { return }
        let keeper = choosePreferredSong(group.duplicates)
        for duplicate in group.duplicates where duplicate.persistentModelID != keeper.persistentModelID {
            mergeSongMetadata(into: keeper, from: duplicate)
            context.delete(duplicate)
        }
        try context.save()
    }

    private func choosePreferredSong(_ songs: [Song]) -> Song {
        songs.max { lhs, rhs in
            let lhsScore = songRetentionScore(lhs)
            let rhsScore = songRetentionScore(rhs)
            return lhsScore < rhsScore
        } ?? songs[0]
    }

    private func songRetentionScore(_ song: Song) -> Int {
        var score = 0
        if song.relFilePath != nil { score += 4 }
        if song.cacheTouchedDate != nil { score += 2 }
        score += song.playCount
        if song.isUserPinned { score += 8 }
        return score
    }

    private func mergeSongMetadata(into keeper: Song, from duplicate: Song) {
        keeper.playCount = max(keeper.playCount, duplicate.playCount)
        keeper.playProgress = max(keeper.playProgress, duplicate.playProgress)
        keeper.rating = max(keeper.rating, duplicate.rating)
        keeper.isFavorite = keeper.isFavorite || duplicate.isFavorite
        keeper.isUserPinned = keeper.isUserPinned || duplicate.isUserPinned
        if keeper.relFilePath == nil { keeper.relFilePath = duplicate.relFilePath }
        if keeper.cacheTouchedDate == nil { keeper.cacheTouchedDate = duplicate.cacheTouchedDate }
        if let duplicateLast = duplicate.lastPlayedDate {
            if let keeperLast = keeper.lastPlayedDate {
                keeper.lastPlayedDate = max(keeperLast, duplicateLast)
            } else {
                keeper.lastPlayedDate = duplicateLast
            }
        }
    }

    private func findDuplicates<T>(
        account: Account,
        items: [T],
        key: KeyPath<T, String>
    ) throws -> [DuplicateGroup<T>] {
        var grouped: [String: [T]] = [:]
        for item in items {
            grouped[item[keyPath: key], default: []].append(item)
        }
        return grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(compoundRemoteId: $0.key, duplicates: $0.value) }
            .sorted { $0.compoundRemoteId < $1.compoundRemoteId }
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, account: Account) throws -> [T] {
        let accountPersistentID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<T>())
        return all.filter { model in
            if let artist = model as? Artist { return artist.account?.persistentModelID == accountPersistentID }
            if let album = model as? Album { return album.account?.persistentModelID == accountPersistentID }
            if let song = model as? Song { return song.account?.persistentModelID == accountPersistentID }
            return false
        }
    }
}
