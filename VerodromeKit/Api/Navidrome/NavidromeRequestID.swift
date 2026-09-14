import Foundation

/// Rewrites a Navidrome media-file ID at request time so stream/download URLs still
/// resolve after a 0.64.0 server upgrade, even if the local library has not been
/// remapped yet (or the in-memory play queue still holds pre-migration IDs).
///
/// `canonical()` is idempotent, so already-migrated IDs pass through unchanged.
/// Pre-0.64 servers, unknown versions, and non-Navidrome backends are left alone —
/// applying the transform there would invent IDs the server has never heard of.
public enum NavidromeRequestID {
    public static func resolve(_ id: String, serverTypeName: String?, version: String?) -> String {
        guard let serverTypeName,
              serverTypeName.caseInsensitiveCompare("navidrome") == .orderedSame else {
            return id
        }
        guard NavidromeVersion.isAtLeast0_64(version) == true else { return id }
        return NavidromeCanonicalID.canonical(id)
    }
}
