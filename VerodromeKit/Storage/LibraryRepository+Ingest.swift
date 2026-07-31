import Foundation
import SwiftData

public extension LibraryRepository {
    @discardableResult
    func getOrCreateGenre(remoteId: String, name: String, account: Account, songCount: Int = 0) throws -> Genre {
        let compoundRemoteId = Genre.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.genres[compoundRemoteId] ?? fetchGenre(compoundRemoteId: compoundRemoteId) {
            existing.name = name
            existing.songCount = songCount
            batch?.genres[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let genre = Genre(remoteId: remoteId, name: name, account: account)
        genre.songCount = songCount
        context.insert(genre)
        batch?.genres[compoundRemoteId] = genre
        try saveIfNotBatching()
        return genre
    }

    @discardableResult
    func getOrCreatePodcast(remoteId: String, title: String, account: Account) throws -> Podcast {
        let compoundRemoteId = Podcast.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.podcasts[compoundRemoteId] ?? fetchPodcast(compoundRemoteId: compoundRemoteId) {
            existing.title = title
            existing.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            batch?.podcasts[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let podcast = Podcast(remoteId: remoteId, title: title, account: account)
        context.insert(podcast)
        batch?.podcasts[compoundRemoteId] = podcast
        try saveIfNotBatching()
        return podcast
    }

    @discardableResult
    func getOrCreatePodcastEpisode(remoteId: String, title: String, account: Account, podcast: Podcast?) throws -> PodcastEpisode {
        let compoundRemoteId = PodcastEpisode.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.episodes[compoundRemoteId] ?? fetchPodcastEpisode(compoundRemoteId: compoundRemoteId) {
            existing.title = title
            existing.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            batch?.episodes[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let episode = PodcastEpisode(remoteId: remoteId, title: title, account: account)
        episode.podcast = podcast
        context.insert(episode)
        batch?.episodes[compoundRemoteId] = episode
        try saveIfNotBatching()
        return episode
    }

    @discardableResult
    func getOrCreateRadio(remoteId: String, name: String, account: Account, streamURL: String?) throws -> Radio {
        let compoundRemoteId = Radio.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.radios[compoundRemoteId] ?? fetchRadio(compoundRemoteId: compoundRemoteId) {
            existing.title = name
            existing.sortTitle = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            existing.streamURL = streamURL
            batch?.radios[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let radio = Radio(remoteId: remoteId, title: name, account: account)
        radio.streamURL = streamURL
        context.insert(radio)
        batch?.radios[compoundRemoteId] = radio
        try saveIfNotBatching()
        return radio
    }

    @discardableResult
    func getOrCreateMusicFolder(remoteId: String, name: String, account: Account) throws -> MusicFolder {
        let compoundRemoteId = MusicFolder.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try fetchMusicFolder(compoundRemoteId: compoundRemoteId) {
            existing.name = name
            try saveIfNotBatching()
            return existing
        }
        let folder = MusicFolder(remoteId: remoteId, name: name, account: account)
        context.insert(folder)
        try saveIfNotBatching()
        return folder
    }

    @discardableResult
    func getOrCreateDirectory(remoteId: String, name: String, account: Account, parentRemoteId: String?) throws -> Directory {
        let compoundRemoteId = Directory.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try fetchDirectory(compoundRemoteId: compoundRemoteId) {
            existing.name = name
            try saveIfNotBatching()
            return existing
        }
        let directory = Directory(remoteId: remoteId, name: name, account: account)
        if let parentRemoteId {
            directory.parentRemoteId = parentRemoteId
        }
        context.insert(directory)
        try saveIfNotBatching()
        return directory
    }

    // MARK: - Single-entity fetches (compound-key predicates, no whole-table scans)

    func fetchGenre(compoundRemoteId: String) throws -> Genre? {
        var descriptor = FetchDescriptor<Genre>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchPodcast(compoundRemoteId: String) throws -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchPodcastEpisode(compoundRemoteId: String) throws -> PodcastEpisode? {
        var descriptor = FetchDescriptor<PodcastEpisode>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchRadio(compoundRemoteId: String) throws -> Radio? {
        var descriptor = FetchDescriptor<Radio>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchMusicFolder(compoundRemoteId: String) throws -> MusicFolder? {
        var descriptor = FetchDescriptor<MusicFolder>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchDirectory(compoundRemoteId: String) throws -> Directory? {
        var descriptor = FetchDescriptor<Directory>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
