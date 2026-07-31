import Foundation
import SwiftData

public final class DownloadRequestManager {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createOrReuseDownload(
        remoteId: String,
        title: String,
        account: Account,
        song: Song? = nil,
        podcastEpisode: PodcastEpisode? = nil
    ) throws -> DownloadRecord {
        if let existing = try fetchActiveDownload(remoteId: remoteId, account: account) {
            existing.title = title
            existing.song = song
            existing.podcastEpisode = podcastEpisode
            existing.isActive = true
            try context.save()
            return existing
        }

        let record = DownloadRecord(remoteId: remoteId, title: title, account: account)
        record.song = song
        record.podcastEpisode = podcastEpisode
        context.insert(record)
        try context.save()
        return record
    }

    public func markCompleted(_ record: DownloadRecord, relFilePath: String, byteSize: Int64) throws {
        record.progress = 1
        record.byteReceived = byteSize
        record.byteTotal = max(record.byteTotal, byteSize)
        record.relFilePath = relFilePath
        record.finishedAt = .now
        record.isActive = false
        record.lastError = nil
        try context.save()
    }

    public func markFailed(_ record: DownloadRecord, errorMessage: String) throws {
        record.isActive = false
        record.lastError = errorMessage
        record.finishedAt = .now
        try context.save()
    }

    public func updateProgress(_ record: DownloadRecord, received: Int64, total: Int64) throws {
        record.byteReceived = received
        record.byteTotal = total
        record.progress = total > 0 ? Double(received) / Double(total) : 0
        try context.save()
    }

    public func activeDownloads(for account: Account) throws -> [DownloadRecord] {
        let accountPersistentID = account.persistentModelID
        var descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate { record in
                record.isActive == true
            },
            sortBy: [SortDescriptor(\DownloadRecord.startedAt, order: .reverse)]
        )
        let allActive = try context.fetch(descriptor)
        return allActive.filter { $0.account?.persistentModelID == accountPersistentID }
    }

    private func fetchActiveDownload(remoteId: String, account: Account) throws -> DownloadRecord? {
        let accountPersistentID = account.persistentModelID
        var descriptor = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate { record in
                record.remoteId == remoteId && record.isActive == true
            }
        )
        let matches = try context.fetch(descriptor)
        return matches.first { $0.account?.persistentModelID == accountPersistentID }
    }
}
