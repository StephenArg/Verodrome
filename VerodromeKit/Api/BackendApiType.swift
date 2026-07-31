import Foundation

/// Identifies which server-side API dialect is in use.
public enum BackendApiType: String, Sendable, Codable, CaseIterable {
    case ampache
    case subsonic
    case subsonicLegacy
    case notDetected
}
