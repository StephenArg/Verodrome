import Combine
import Foundation
import SwiftData

@MainActor
public final class QueryController<T: PersistentModel>: ObservableObject {
    @Published public private(set) var items: [T] = []
    @Published public private(set) var errorMessage: String?

    private let context: ModelContext
    private var descriptor: FetchDescriptor<T>

    public init(context: ModelContext, descriptor: FetchDescriptor<T>) {
        self.context = context
        self.descriptor = descriptor
        reload()
    }

    public func updateDescriptor(_ transform: (inout FetchDescriptor<T>) -> Void) {
        transform(&descriptor)
        reload()
    }

    public func reload() {
        do {
            items = try context.fetch(descriptor)
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }
}

public enum QueryDescriptors {
    public static func artists(account: Account, search: String? = nil) -> FetchDescriptor<Artist> {
        FetchDescriptor<Artist>(
            sortBy: [SortDescriptor(\Artist.sortName, order: .forward)]
        )
    }

    public static func albums(account: Account) -> FetchDescriptor<Album> {
        FetchDescriptor<Album>(
            sortBy: [
                SortDescriptor(\Album.sortTitle, order: .forward),
                SortDescriptor(\Album.year, order: .reverse)
            ]
        )
    }

    public static func songs(account: Account) -> FetchDescriptor<Song> {
        FetchDescriptor<Song>(
            sortBy: [SortDescriptor(\Song.sortTitle, order: .forward)]
        )
    }

    public static func playlists(account: Account) -> FetchDescriptor<Playlist> {
        FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\Playlist.sortName, order: .forward)]
        )
    }

    public static func podcasts(account: Account) -> FetchDescriptor<Podcast> {
        FetchDescriptor<Podcast>(
            sortBy: [SortDescriptor(\Podcast.sortTitle, order: .forward)]
        )
    }

    public static func downloads(account: Account) -> FetchDescriptor<DownloadRecord> {
        FetchDescriptor<DownloadRecord>(
            sortBy: [SortDescriptor(\DownloadRecord.startedAt, order: .reverse)]
        )
    }
}
