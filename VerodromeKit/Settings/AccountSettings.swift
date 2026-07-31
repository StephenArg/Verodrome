import Foundation

public struct AccountCredentials: Codable, Equatable, Sendable {
    public var serverURL: String
    public var username: String
    public var passwordToken: String

    public init(serverURL: String = "", username: String = "", passwordToken: String = "") {
        self.serverURL = serverURL
        self.username = username
        self.passwordToken = passwordToken
    }
}

public struct AccountSettings: Codable, Equatable, Sendable {
    public var credentials: AccountCredentials
    public var themeColorHex: String?
    public var artworkDownloadSetting: ArtworkDownloadSetting
    public var autoCacheNewest: Bool
    public var scrobbleEnabled: Bool
    public var artistSortField: ArtistSortField
    public var artistSortDirection: SortDirection
    public var albumSortField: AlbumSortField
    public var albumSortDirection: SortDirection
    public var songSortField: SongSortField
    public var songSortDirection: SortDirection
    public var playlistSortField: PlaylistSortField
    public var playlistSortDirection: SortDirection
    public var homeSections: [HomeSection]
    public var libraryDisplayTypesInUse: [LibraryDisplayType]
    public var apiType: ApiType

    public init(
        credentials: AccountCredentials = AccountCredentials(),
        themeColorHex: String? = nil,
        artworkDownloadSetting: ArtworkDownloadSetting = .wifiOnly,
        autoCacheNewest: Bool = false,
        scrobbleEnabled: Bool = true,
        artistSortField: ArtistSortField = .name,
        artistSortDirection: SortDirection = .ascending,
        albumSortField: AlbumSortField = .title,
        albumSortDirection: SortDirection = .ascending,
        songSortField: SongSortField = .title,
        songSortDirection: SortDirection = .ascending,
        playlistSortField: PlaylistSortField = .name,
        playlistSortDirection: SortDirection = .ascending,
        homeSections: [HomeSection] = HomeSection.allCases,
        libraryDisplayTypesInUse: [LibraryDisplayType] = [.grid, .list],
        apiType: ApiType = .notDetected
    ) {
        self.credentials = credentials
        self.themeColorHex = themeColorHex
        self.artworkDownloadSetting = artworkDownloadSetting
        self.autoCacheNewest = autoCacheNewest
        self.scrobbleEnabled = scrobbleEnabled
        self.artistSortField = artistSortField
        self.artistSortDirection = artistSortDirection
        self.albumSortField = albumSortField
        self.albumSortDirection = albumSortDirection
        self.songSortField = songSortField
        self.songSortDirection = songSortDirection
        self.playlistSortField = playlistSortField
        self.playlistSortDirection = playlistSortDirection
        self.homeSections = homeSections
        self.libraryDisplayTypesInUse = libraryDisplayTypesInUse
        self.apiType = apiType
    }

    public static let `default` = AccountSettings()
}
