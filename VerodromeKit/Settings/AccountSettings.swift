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
    public var homeSections: [HomeSection]
    public var apiType: ApiType
    /// Raw product name from the server handshake/ping (`navidrome`, `Ampache`, …).
    public var serverTypeName: String?

    public init(
        credentials: AccountCredentials = AccountCredentials(),
        themeColorHex: String? = nil,
        artworkDownloadSetting: ArtworkDownloadSetting = .always,
        autoCacheNewest: Bool = false,
        homeSections: [HomeSection] = HomeSection.allCases,
        apiType: ApiType = .notDetected,
        serverTypeName: String? = nil
    ) {
        self.credentials = credentials
        self.themeColorHex = themeColorHex
        self.artworkDownloadSetting = artworkDownloadSetting
        self.autoCacheNewest = autoCacheNewest
        self.homeSections = homeSections
        self.apiType = apiType
        self.serverTypeName = serverTypeName
    }

    public static let `default` = AccountSettings()
}
