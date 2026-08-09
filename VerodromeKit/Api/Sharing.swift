import Foundation

/// What a share points at. Backends disagree about which of these they accept, so the
/// set a server actually supports lives in `ShareCapabilities.shareableTypes`.
public enum ShareResourceType: String, Sendable, Codable, CaseIterable {
    case song
    case album
    case playlist
    case artist

    /// Ampache's `object_type` spelling, which matches every case here.
    var ampacheObjectType: String { rawValue }
}

/// How precisely a server can be told when a share should stop working.
public enum ShareExpirationSupport: Sendable, Equatable {
    /// Subsonic takes an absolute instant as epoch milliseconds.
    case absolute
    /// Ampache stores a whole number of days from creation, so any instant we send is
    /// rounded up to the next day boundary.
    case wholeDays
    case unsupported
}

/// Whether the people a link is sent to may download the files, and whether this client
/// gets a say in it.
public enum ShareDownloadSupport: Sendable, Equatable {
    /// The user can pick, and the choice survives editing.
    case configurable
    /// The server decides; show the state but don't let it be changed.
    case fixed(Bool)
    /// No such concept on this server; don't mention downloads at all.
    case unsupported

    public var isConfigurable: Bool {
        if case .configurable = self { return true }
        return false
    }

    /// The value to seed a new share with when the user has no choice.
    public var forcedValue: Bool? {
        if case .fixed(let value) = self { return value }
        return nil
    }
}

/// What the current server and account allow. Probed once per session — an admin can
/// switch sharing off entirely, and several of these differences are invisible until a
/// call is actually attempted.
public struct ShareCapabilities: Sendable, Equatable {
    public var isSupported: Bool
    public var shareableTypes: Set<ShareResourceType>
    public var expiration: ShareExpirationSupport
    public var download: ShareDownloadSupport
    public var canEditExpiration: Bool
    public var canEditDescription: Bool

    public init(
        isSupported: Bool,
        shareableTypes: Set<ShareResourceType> = [],
        expiration: ShareExpirationSupport = .unsupported,
        download: ShareDownloadSupport = .unsupported,
        canEditExpiration: Bool = false,
        canEditDescription: Bool = false
    ) {
        self.isSupported = isSupported
        self.shareableTypes = shareableTypes
        self.expiration = expiration
        self.download = download
        self.canEditExpiration = canEditExpiration
        self.canEditDescription = canEditDescription
    }

    /// The answer for a server that can't share at all, which is also what a failed
    /// probe settles on.
    public static let unsupported = ShareCapabilities(isSupported: false)

    public func canShare(_ type: ShareResourceType) -> Bool {
        isSupported && shareableTypes.contains(type)
    }
}

/// A live share as the server reports it.
public struct ShareRef: Sendable, Identifiable, Equatable {
    public let id: String
    /// The public link. Servers build this themselves — Navidrome from `ShareURL` or the
    /// request host, Ampache from its own site config — so it is never assembled here.
    public let url: URL?
    public let description: String?
    /// Human label for what is inside, which the server fills in when the description is
    /// blank (Navidrome's `contents`, Ampache's object name).
    public let contentsLabel: String?
    public let resourceType: ShareResourceType?
    public let owner: String?
    public let created: Date?
    public let expires: Date?
    public let lastVisited: Date?
    public let visitCount: Int
    /// Nil when the server has no such concept, which is different from "not allowed".
    public let isDownloadable: Bool?
    public let entryCount: Int

    public init(
        id: String,
        url: URL? = nil,
        description: String? = nil,
        contentsLabel: String? = nil,
        resourceType: ShareResourceType? = nil,
        owner: String? = nil,
        created: Date? = nil,
        expires: Date? = nil,
        lastVisited: Date? = nil,
        visitCount: Int = 0,
        isDownloadable: Bool? = nil,
        entryCount: Int = 0
    ) {
        self.id = id
        self.url = url
        self.description = description
        self.contentsLabel = contentsLabel
        self.resourceType = resourceType
        self.owner = owner
        self.created = created
        self.expires = expires
        self.lastVisited = lastVisited
        self.visitCount = visitCount
        self.isDownloadable = isDownloadable
        self.entryCount = entryCount
    }

    /// What to show as the share's title.
    public var displayTitle: String {
        description?.nilIfBlank ?? contentsLabel?.nilIfBlank ?? id
    }

    public var isExpired: Bool {
        guard let expires else { return false }
        return expires < Date()
    }
}

/// A share the user has asked for but the server hasn't created yet.
public struct ShareDraft: Sendable, Equatable {
    public var resourceType: ShareResourceType
    /// One or more ids of the same type. Only Subsonic accepts several at once; Ampache
    /// shares a single object, so extras are ignored there.
    public var resourceIds: [String]
    public var description: String?
    public var expires: Date?
    public var isDownloadable: Bool?

    public init(
        resourceType: ShareResourceType,
        resourceIds: [String],
        description: String? = nil,
        expires: Date? = nil,
        isDownloadable: Bool? = nil
    ) {
        self.resourceType = resourceType
        self.resourceIds = resourceIds
        self.description = description
        self.expires = expires
        self.isDownloadable = isDownloadable
    }
}

/// A change to an existing share. `nil` means "leave alone"; clearing an expiry is
/// `expires: .some(nil)`, which the double optional is there to express.
public struct ShareUpdate: Sendable, Equatable {
    public var description: String?
    public var expires: Date??
    public var isDownloadable: Bool?

    public init(
        description: String? = nil,
        expires: Date?? = nil,
        isDownloadable: Bool? = nil
    ) {
        self.description = description
        self.expires = expires
        self.isDownloadable = isDownloadable
    }
}

/// Share management, where a backend supports it.
public protocol ShareManaging: AnyObject, Sendable {
    /// Probes the server once and caches the answer for the rest of the session.
    func shareCapabilities() async -> ShareCapabilities
    func shares() async throws -> [ShareRef]
    func createShare(_ draft: ShareDraft) async throws -> ShareRef
    func updateShare(id: String, _ update: ShareUpdate) async throws
    func deleteShare(id: String) async throws
}

// MARK: - Expiry conversion

public enum ShareExpiry {
    /// Ampache counts whole days from creation and treats `0` as "never". Rounding up
    /// means a link outlives the moment the user picked rather than dying before it.
    public static func days(until date: Date, from reference: Date = Date()) -> Int {
        let seconds = date.timeIntervalSince(reference)
        guard seconds > 0 else { return 1 }
        return max(1, Int(ceil(seconds / 86_400)))
    }

    /// Rebuilds the absolute instant Ampache implies from a creation date and day count.
    public static func date(created: Date?, expireDays: Int?) -> Date? {
        guard let created, let expireDays, expireDays > 0 else { return nil }
        return created.addingTimeInterval(TimeInterval(expireDays) * 86_400)
    }

    /// Subsonic's wire format for `expires`.
    public static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
