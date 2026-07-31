import Foundation

public enum ApiType: Int, Codable, CaseIterable, Sendable {
    case notDetected = 0
    case ampache = 1
    case subsonic = 2
    case subsonicLegacy = 3

    public var displayName: String {
        switch self {
        case .notDetected: "Unknown"
        case .ampache: "Ampache"
        case .subsonic: "Subsonic"
        case .subsonicLegacy: "Subsonic (Legacy)"
        }
    }
}


extension ApiType {
    public init(_ backend: BackendApiType) {
        switch backend {
        case .ampache: self = .ampache
        case .subsonic: self = .subsonic
        case .subsonicLegacy: self = .subsonicLegacy
        case .notDetected: self = .notDetected
        }
    }

    public var backendApiType: BackendApiType {
        switch self {
        case .ampache: .ampache
        case .subsonic: .subsonic
        case .subsonicLegacy: .subsonicLegacy
        case .notDetected: .notDetected
        }
    }
}

extension BackendApiType {
    public var displayName: String { ApiType(self).displayName }
}
