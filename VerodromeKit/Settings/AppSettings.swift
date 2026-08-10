import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var isLibrarySynced: Bool
    public var librarySyncVersion: Int
    /// Bumped to 1 once the low-priority full-track backfill completes for the active library.
    public var tracksBackfillVersion: Int

    public init(
        isLibrarySynced: Bool = false,
        librarySyncVersion: Int = 0,
        tracksBackfillVersion: Int = 0
    ) {
        self.isLibrarySynced = isLibrarySynced
        self.librarySyncVersion = librarySyncVersion
        self.tracksBackfillVersion = tracksBackfillVersion
    }

    public static let `default` = AppSettings()

    /// The backfill the current build expects a library to have completed.
    ///
    /// Bump this whenever the track crawl starts reading a field it didn't before:
    /// the crawl is the only bulk path that writes song ratings and play counts, so
    /// libraries stuck on an older version would otherwise never see them.
    ///
    /// - 1: the original full-track backfill.
    /// - 2: adds server-side play counts and ratings.
    public static let currentTracksBackfillVersion = 2

    enum CodingKeys: String, CodingKey {
        case isLibrarySynced, librarySyncVersion, tracksBackfillVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isLibrarySynced = try container.decodeIfPresent(Bool.self, forKey: .isLibrarySynced) ?? false
        librarySyncVersion = try container.decodeIfPresent(Int.self, forKey: .librarySyncVersion) ?? 0
        tracksBackfillVersion = try container.decodeIfPresent(Int.self, forKey: .tracksBackfillVersion) ?? 0
    }
}
