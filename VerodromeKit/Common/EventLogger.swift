import Foundation

public actor EventLogger {
    public static let shared = EventLogger()

    private var entries: [LogEntrySnapshot] = []
    private let maxEntries = 500

    public struct LogEntrySnapshot: Sendable, Identifiable {
        public let id: UUID
        public let timestamp: Date
        public let level: LogLevel
        public let category: String
        public let message: String

        public init(id: UUID = UUID(), timestamp: Date = .now, level: LogLevel, category: String, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.level = level
            self.category = category
            self.message = message
        }
    }

    public enum LogLevel: String, Sendable, Codable {
        case debug, info, warning, error
    }

    private init() {}

    public func log(_ level: LogLevel, category: String, _ message: String) {
        let snapshot = LogEntrySnapshot(level: level, category: category, message: message)
        entries.append(snapshot)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        #if DEBUG
        print("[\(level.rawValue.uppercased())][\(category)] \(message)")
        #endif
    }

    public func debug(_ category: String, _ message: String) {
        log(.debug, category: category, message)
    }

    public func info(_ category: String, _ message: String) {
        log(.info, category: category, message)
    }

    public func warning(_ category: String, _ message: String) {
        log(.warning, category: category, message)
    }

    public func error(_ category: String, _ message: String) {
        log(.error, category: category, message)
    }

    public func recentEntries(limit: Int = 100) -> [LogEntrySnapshot] {
        Array(entries.suffix(limit))
    }

    public func append(from logEntry: LogEntry) {
        let snapshot = LogEntrySnapshot(
            id: logEntry.id,
            timestamp: logEntry.timestamp,
            level: LogLevel(rawValue: logEntry.levelRaw) ?? .info,
            category: logEntry.category,
            message: logEntry.message
        )
        entries.append(snapshot)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func clear() {
        entries.removeAll()
    }
}
