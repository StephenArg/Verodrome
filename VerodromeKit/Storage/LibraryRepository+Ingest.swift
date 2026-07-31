import Foundation
import SwiftData

@MainActor
public extension LibraryRepository {
    @discardableResult
    func getOrCreateGenre(remoteId: String, name: String, account: Account, songCount: Int = 0) throws -> Genre {
        let compound = account.compoundKey + "_" + remoteId
        let all = try context.fetch(FetchDescriptor<Genre>())
        if let existing = all.first(where: { $0.account?.persistentModelID == account.persistentModelID && ($0.remoteId == remoteId || $0.name == name) }) {
            existing.name = name
            existing.songCount = songCount
            try save()
            return existing
        }
        let genre = Genre(remoteId: remoteId, name: name, account: account)
        genre.songCount = songCount
        context.insert(genre)
        try save()
        return genre
    }

    @discardableResult
    func getOrCreatePodcast(remoteId: String, title: String, account: Account) throws -> Podcast {
        let all = try fetchPodcasts(account: account)
        if let existing = all.first(where: { $0.remoteId == remoteId }) {
            existing.title = title
            existing.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            try save()
            return existing
        }
        let podcast = Podcast(remoteId: remoteId, title: title, account: account)
        context.insert(podcast)
        try save()
        return podcast
    }

    @discardableResult
    func getOrCreatePodcastEpisode(remoteId: String, title: String, account: Account, podcast: Podcast?) throws -> PodcastEpisode {
        let all = try fetchPodcastEpisodes(account: account, podcast: podcast)
        if let existing = all.first(where: { $0.remoteId == remoteId }) {
            existing.title = title
            try save()
            return existing
        }
        let episode = PodcastEpisode(remoteId: remoteId, title: title, account: account)
        episode.podcast = podcast
        context.insert(episode)
        try save()
        return episode
    }

    @discardableResult
    func getOrCreateRadio(remoteId: String, name: String, account: Account, streamURL: String?) throws -> Radio {
        let all = try fetchRadios(account: account)
        if let existing = all.first(where: { $0.remoteId == remoteId }) {
            existing.title = name
            existing.streamURL = streamURL
            try save()
            return existing
        }
        let radio = Radio(remoteId: remoteId, title: name, account: account)
        radio.streamURL = streamURL
        context.insert(radio)
        try save()
        return radio
    }

    @discardableResult
    func getOrCreateMusicFolder(remoteId: String, name: String, account: Account) throws -> MusicFolder {
        let all = try context.fetch(FetchDescriptor<MusicFolder>())
        if let existing = all.first(where: { $0.account?.persistentModelID == account.persistentModelID && $0.remoteId == remoteId }) {
            existing.name = name
            try save()
            return existing
        }
        let folder = MusicFolder(remoteId: remoteId, name: name, account: account)
        context.insert(folder)
        try save()
        return folder
    }

    @discardableResult
    func getOrCreateDirectory(remoteId: String, name: String, account: Account, parentRemoteId: String?) throws -> Directory {
        let all = try context.fetch(FetchDescriptor<Directory>())
        if let existing = all.first(where: { $0.account?.persistentModelID == account.persistentModelID && $0.remoteId == remoteId }) {
            existing.name = name
            try save()
            return existing
        }
        let directory = Directory(remoteId: remoteId, name: name, account: account)
        context.insert(directory)
        try save()
        return directory
    }
}
