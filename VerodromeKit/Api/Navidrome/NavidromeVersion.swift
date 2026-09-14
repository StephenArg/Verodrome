import Foundation

/// Semantic-version comparison for Navidrome's `serverVersion` string, including the "epoch"
/// classification that decides whether the canonical-ID migration needs to consider running.
///
/// Navidrome reports versions like `"0.63.2"` or `"0.63.2 (aa84e645)"` (a trailing commit
/// hash on nightly builds). Some installations report entirely unparseable values such as
/// `"dev"` or `""`; those are treated as unknown and force the probe rather than allowing
/// a version-only decision to skip it.
public enum NavidromeVersion {
    /// Machine-readable epoch: 0 for pre-0.64 servers (which still use the old ID zoo),
    /// 1 for 0.64.0 and above (canonical 22-char base62 IDs). `nil` means the version
    /// could not be parsed and the caller should probe instead of assuming.
    ///
    /// The epoch is intentionally coarser than a full version compare: what we care about
    /// is whether the ID scheme changed, and that only moves once, at 0.64.0.
    public static func epoch(of version: String?) -> Int? {
        guard let components = parse(version) else { return nil }
        // (0, 64, 0) is the boundary. Anything at or after is epoch 1.
        if components.major > 0 { return 1 }
        if components.minor > 64 { return 1 }
        if components.minor == 64 { return 1 }
        return 0
    }

    /// Structural comparison — returns nil when either value is unparseable, so callers
    /// can distinguish "definitely lower" from "cannot tell".
    public static func compare(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
        guard let l = parse(lhs), let r = parse(rhs) else { return nil }
        if l.major != r.major { return l.major < r.major ? .orderedAscending : .orderedDescending }
        if l.minor != r.minor { return l.minor < r.minor ? .orderedAscending : .orderedDescending }
        if l.patch != r.patch { return l.patch < r.patch ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// True when `version` parses as ≥ `"0.64.0"`. Unparseable inputs return nil so the
    /// caller can fall through to the probe path rather than picking a wrong default.
    public static func isAtLeast0_64(_ version: String?) -> Bool? {
        guard let e = epoch(of: version) else { return nil }
        return e >= 1
    }

    struct Components: Equatable {
        var major: Int
        var minor: Int
        var patch: Int
    }

    /// Parse the version prefix into (major, minor, patch), tolerating everything that
    /// might trail: whitespace, a `(hash)` build tag, or a `-SNAPSHOT` / `-rc.1` suffix.
    /// Anything without three leading integer components joined by dots returns nil.
    static func parse(_ raw: String?) -> Components? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Split off the first whitespace-delimited token — `"0.63.2 (hash)"` becomes
        // `"0.63.2"`. Then strip any pre-release suffix ("-SNAPSHOT", "-rc.1") so
        // `"0.64.1-SNAPSHOT"` still parses as 0.64.1.
        let firstToken = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        let core = firstToken.split(separator: "-").first.map(String.init) ?? firstToken
        // Strip a leading "v" if present (`"v0.64.0"` in the wild).
        let stripped: String
        if core.first == "v" || core.first == "V" {
            stripped = String(core.dropFirst())
        } else {
            stripped = core
        }
        let parts = stripped.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        return Components(major: major, minor: minor, patch: patch)
    }
}

/// The outcome of comparing the currently-reported server version against the marker
/// stored the last time IDs were verified. Drives whether the migration hook probes,
/// migrates forward, migrates backward, or skips entirely.
///
/// Keyed off the *currently reported* version rather than the stored one — gating on
/// the stored version would make every user on an older Navidrome re-probe forever.
public enum CanonicalIdEpochDecision: Equatable {
    /// Not Navidrome, or the reported version's epoch matches the marker. No work.
    case skip
    /// No marker set and the reported version is definitively below 0.64.0 — safe to
    /// seed the marker without probing, since pre-0.64 IDs and pre-existing local IDs
    /// are trivially consistent.
    case seedMarker
    /// The reported epoch is >= 1 (or unknown) and the marker is either unset or in a
    /// lower epoch. Probe to confirm before running the forward migration.
    case probeForward
    /// The reported epoch is 0 but the marker was set at a >=0.64 version. Almost always
    /// means the server was restored from a pre-0.64 backup. Probe and, if confirmed,
    /// apply the inverse map.
    case probeBackward

    /// Compute the decision from the raw ping values.
    ///
    /// - Parameters:
    ///   - serverTypeName: Ping `type=` (case-insensitive). Only `navidrome` matters.
    ///   - reportedVersion: Ping `serverVersion=`.
    ///   - markerVersion: The version stored on the last successful verification.
    public static func decide(
        serverTypeName: String?,
        reportedVersion: String?,
        markerVersion: String?
    ) -> CanonicalIdEpochDecision {
        // Non-Navidrome backends do not participate; only Navidrome servers ever rewrite
        // their IDs. Ampache and generic Subsonic implementations are safe to skip.
        guard let typeName = serverTypeName,
              typeName.caseInsensitiveCompare("navidrome") == .orderedSame else {
            return .skip
        }

        let reportedEpoch = NavidromeVersion.epoch(of: reportedVersion)
        let markerEpoch = NavidromeVersion.epoch(of: markerVersion)

        // No marker yet: seed for old servers so old-server users never pay a request;
        // probe for new (or unknown) servers, since local IDs could be from either side.
        if markerVersion == nil {
            if reportedEpoch == 0 { return .seedMarker }
            return .probeForward
        }

        // Marker present but its version is unparseable (perhaps written by a future
        // version we do not know about): probe to be safe, treat as forward.
        guard let markerEpoch else { return .probeForward }

        // Reported version unparseable → probe forward and let the sample decide.
        guard let reportedEpoch else { return .probeForward }

        if reportedEpoch == markerEpoch { return .skip }
        return reportedEpoch > markerEpoch ? .probeForward : .probeBackward
    }
}
