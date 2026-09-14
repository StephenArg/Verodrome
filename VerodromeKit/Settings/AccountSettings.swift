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
    /// Raw product version from the ping's `serverVersion` attribute
    /// (`"0.63.2 (aa84e645)"`). Read by the Navidrome canonical-ID gate to decide whether
    /// local IDs might already be stale. Nil until the first successful ping.
    public var serverVersion: String?
    /// The Navidrome version at which local IDs were last finished checking. Nil
    /// means never checked. Written only after a completed probe/remap (or a
    /// pre-0.64 marker seed). Comparing its epoch to the live `serverVersion`
    /// decides whether to run the 0.64 ID check again.
    public var canonicalIdsVerifiedAtVersion: String?

    public init(
        credentials: AccountCredentials = AccountCredentials(),
        themeColorHex: String? = nil,
        artworkDownloadSetting: ArtworkDownloadSetting = .always,
        autoCacheNewest: Bool = false,
        homeSections: [HomeSection] = HomeSection.allCases,
        apiType: ApiType = .notDetected,
        serverTypeName: String? = nil,
        serverVersion: String? = nil,
        canonicalIdsVerifiedAtVersion: String? = nil
    ) {
        self.credentials = credentials
        self.themeColorHex = themeColorHex
        self.artworkDownloadSetting = artworkDownloadSetting
        self.autoCacheNewest = autoCacheNewest
        self.homeSections = homeSections
        self.apiType = apiType
        self.serverTypeName = serverTypeName
        self.serverVersion = serverVersion
        self.canonicalIdsVerifiedAtVersion = canonicalIdsVerifiedAtVersion
    }

    public static let `default` = AccountSettings()

    enum CodingKeys: String, CodingKey {
        case credentials
        case themeColorHex
        case artworkDownloadSetting
        case autoCacheNewest
        case homeSections
        case apiType
        case serverTypeName
        case serverVersion
        case canonicalIdsVerifiedAtVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        credentials = try c.decodeIfPresent(AccountCredentials.self, forKey: .credentials) ?? AccountCredentials()
        themeColorHex = try c.decodeIfPresent(String.self, forKey: .themeColorHex)
        artworkDownloadSetting = try c.decodeIfPresent(ArtworkDownloadSetting.self, forKey: .artworkDownloadSetting) ?? .always
        autoCacheNewest = try c.decodeIfPresent(Bool.self, forKey: .autoCacheNewest) ?? false
        homeSections = try c.decodeIfPresent([HomeSection].self, forKey: .homeSections) ?? HomeSection.allCases
        apiType = try c.decodeIfPresent(ApiType.self, forKey: .apiType) ?? .notDetected
        serverTypeName = try c.decodeIfPresent(String.self, forKey: .serverTypeName)
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion)
        canonicalIdsVerifiedAtVersion = try c.decodeIfPresent(String.self, forKey: .canonicalIdsVerifiedAtVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(credentials, forKey: .credentials)
        try c.encodeIfPresent(themeColorHex, forKey: .themeColorHex)
        try c.encode(artworkDownloadSetting, forKey: .artworkDownloadSetting)
        try c.encode(autoCacheNewest, forKey: .autoCacheNewest)
        try c.encode(homeSections, forKey: .homeSections)
        try c.encode(apiType, forKey: .apiType)
        try c.encodeIfPresent(serverTypeName, forKey: .serverTypeName)
        try c.encodeIfPresent(serverVersion, forKey: .serverVersion)
        try c.encodeIfPresent(canonicalIdsVerifiedAtVersion, forKey: .canonicalIdsVerifiedAtVersion)
    }
}
