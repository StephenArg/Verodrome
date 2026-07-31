import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var isLibrarySynced: Bool
    public var librarySyncVersion: Int
    public var hasReadSyncInfo: Bool
    /// Bumped to 1 once the low-priority full-track backfill completes for the active library.
    public var tracksBackfillVersion: Int

    public init(
        isLibrarySynced: Bool = false,
        librarySyncVersion: Int = 0,
        hasReadSyncInfo: Bool = false,
        tracksBackfillVersion: Int = 0
    ) {
        self.isLibrarySynced = isLibrarySynced
        self.librarySyncVersion = librarySyncVersion
        self.hasReadSyncInfo = hasReadSyncInfo
        self.tracksBackfillVersion = tracksBackfillVersion
    }

    public static let `default` = AppSettings()

    enum CodingKeys: String, CodingKey {
        case isLibrarySynced, librarySyncVersion, hasReadSyncInfo, tracksBackfillVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isLibrarySynced = try container.decodeIfPresent(Bool.self, forKey: .isLibrarySynced) ?? false
        librarySyncVersion = try container.decodeIfPresent(Int.self, forKey: .librarySyncVersion) ?? 0
        hasReadSyncInfo = try container.decodeIfPresent(Bool.self, forKey: .hasReadSyncInfo) ?? false
        tracksBackfillVersion = try container.decodeIfPresent(Int.self, forKey: .tracksBackfillVersion) ?? 0
    }
}
