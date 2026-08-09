import Foundation

/// What a screen is offering to share, resolved into the resource type and ids the
/// backend needs.
public struct ShareSubject: Sendable, Equatable, Identifiable {
    public let resourceType: ShareResourceType
    public let resourceIds: [String]
    /// Seeds the description field and titles the composer.
    public let title: String
    public let subtitle: String?
    public let artwork: ArtworkRef?

    public var id: String { "\(resourceType.rawValue):\(resourceIds.joined(separator: ","))" }

    public init(
        resourceType: ShareResourceType,
        resourceIds: [String],
        title: String,
        subtitle: String? = nil,
        artwork: ArtworkRef? = nil
    ) {
        self.resourceType = resourceType
        self.resourceIds = resourceIds
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
    }
}

/// High-level sharing for the UI: capability lookup, and create / list / edit / delete
/// against whichever backend is signed in.
///
/// Shares live entirely on the server and there are only ever a handful, so nothing here
/// is cached in SwiftData the way the library is — every screen fetches on appear.
@MainActor
public final class ShareActions {
    public static let shared = ShareActions()

    private var kit: VerodromeKit { .shared }
    private var manager: ShareManaging? { kit.backendProxy.sharing }

    /// Mirrors the backend's own cache so a menu can ask "can I share this?" during a
    /// view update without waiting on the network.
    private var lastKnownCapabilities: ShareCapabilities?

    private init() {}

    /// The capabilities already established this session, or nil if nothing has probed
    /// yet. Synchronous so menu construction never blocks.
    public var knownCapabilities: ShareCapabilities? { lastKnownCapabilities }

    @discardableResult
    public func capabilities() async -> ShareCapabilities {
        // Deliberately not remembered before sign-in: every share call would fail
        // authentication, and caching that answer would leave the whole session
        // believing the server can't share.
        guard let manager, kit.backendProxy.isAuthenticated else { return .unsupported }

        let capabilities = await manager.shareCapabilities()
        lastKnownCapabilities = capabilities
        return capabilities
    }

    /// Whether an entry point should offer to share this kind of thing at all. Answers
    /// from the cache when there is one and probes otherwise, so the first menu opened in
    /// a session pays for the lookup and the rest don't.
    public func canShare(_ type: ShareResourceType) async -> Bool {
        if let lastKnownCapabilities { return lastKnownCapabilities.canShare(type) }
        return await capabilities().canShare(type)
    }

    public func shares() async throws -> [ShareRef] {
        guard let manager else { throw BackendApiError.unsupportedOperation("This server does not support sharing") }
        return try await manager.shares()
    }

    public func createShare(
        subject: ShareSubject,
        description: String?,
        expires: Date?,
        isDownloadable: Bool?
    ) async throws -> ShareRef {
        guard let manager else { throw BackendApiError.unsupportedOperation("This server does not support sharing") }

        let draft = ShareDraft(
            resourceType: subject.resourceType,
            resourceIds: subject.resourceIds,
            description: description?.nilIfBlank,
            expires: expires,
            isDownloadable: isDownloadable
        )
        return try await manager.createShare(draft)
    }

    public func updateShare(
        id: String,
        description: String? = nil,
        expires: Date?? = nil,
        isDownloadable: Bool? = nil
    ) async throws {
        guard let manager else { throw BackendApiError.unsupportedOperation("This server does not support sharing") }
        try await manager.updateShare(
            id: id,
            ShareUpdate(description: description, expires: expires, isDownloadable: isDownloadable)
        )
    }

    public func deleteShare(id: String) async throws {
        guard let manager else { throw BackendApiError.unsupportedOperation("This server does not support sharing") }
        try await manager.deleteShare(id: id)
    }

    /// Dropped when the account changes, since capabilities belong to a server and a
    /// user's permissions on it.
    public func reset() {
        lastKnownCapabilities = nil
    }
}
