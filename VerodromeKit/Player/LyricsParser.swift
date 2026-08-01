import Foundation

/// One displayable lyric line. `start` is nil for unsynced lyrics.
public struct LyricLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public let start: TimeInterval?
    public let text: String

    public init(id: Int, start: TimeInterval?, text: String) {
        self.id = id
        self.start = start
        self.text = text
    }
}

/// Parses LRC-formatted lyrics (`[mm:ss.xx]text`) into displayable lines.
/// Servers that expose timestamps have theirs rendered as LRC upstream, so the
/// whole lyrics pipeline can stay a plain `String`.
public enum LyricsParser {
    /// Tags carrying file metadata rather than a lyric, e.g. `[ar:Artist]`.
    private static let metadataKeys: Set<String> = [
        "ar", "ti", "al", "au", "by", "re", "ve", "length", "offset", "tool", "#"
    ]

    public static func parse(_ raw: String) -> [LyricLine] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var offset: TimeInterval = 0
        var timed: [(start: TimeInterval, text: String)] = []
        var untimed: [String] = []
        var sawTimestamp = false

        for rawLine in trimmed.components(separatedBy: .newlines) {
            var scanner = rawLine[...]
            var stamps: [TimeInterval] = []

            // A line may carry several stamps ("[00:12.00][01:04.00]chorus").
            while let tag = nextTag(in: scanner) {
                if let seconds = parseTimestamp(tag.body) {
                    stamps.append(seconds)
                } else if let value = parseOffsetTag(tag.body) {
                    offset = value
                } else if !isMetadataTag(tag.body) {
                    break
                }
                scanner = tag.remainder
            }

            let text = scanner.trimmingCharacters(in: .whitespaces)
            if stamps.isEmpty {
                // Blank separator lines are meaningful spacing in unsynced lyrics,
                // but only noise between timed lines.
                untimed.append(text)
            } else {
                sawTimestamp = true
                guard !text.isEmpty else { continue }
                for stamp in stamps { timed.append((stamp, text)) }
            }
        }

        if sawTimestamp {
            return timed
                .sorted { $0.start < $1.start }
                .enumerated()
                .map { LyricLine(id: $0.offset, start: max(0, $0.element.start + offset), text: $0.element.text) }
        }

        return trimEmptyEdges(untimed)
            .enumerated()
            .map { LyricLine(id: $0.offset, start: nil, text: $0.element) }
    }

    /// Index of the last line that has already started at `time`.
    public static func activeIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        var match: Int?
        for (index, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= time { match = index } else { break }
        }
        return match
    }

    public static func isSynced(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.start != nil }
    }

    /// Renders seconds as an LRC stamp, for producing LRC text from structured
    /// server responses.
    public static func timestamp(forMilliseconds milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let minutes = clamped / 60_000
        let seconds = (clamped % 60_000) / 1000
        let hundredths = (clamped % 1000) / 10
        return String(format: "[%02d:%02d.%02d]", minutes, seconds, hundredths)
    }

    // MARK: - Tag scanning

    private static func nextTag(in line: Substring) -> (body: Substring, remainder: Substring)? {
        let start = line.drop { $0 == " " || $0 == "\t" }
        guard start.first == "[", let close = start.firstIndex(of: "]") else { return nil }
        let body = start[start.index(after: start.startIndex)..<close]
        return (body, start[start.index(after: close)...])
    }

    private static func isMetadataTag(_ body: Substring) -> Bool {
        guard let colon = body.firstIndex(of: ":") else { return false }
        let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        return metadataKeys.contains(key)
    }

    private static func parseOffsetTag(_ body: Substring) -> TimeInterval? {
        guard let colon = body.firstIndex(of: ":"),
              body[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "offset",
              let milliseconds = Double(body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        else { return nil }
        // LRC offsets shift the lyrics *earlier* when positive.
        return -milliseconds / 1000
    }

    /// Accepts `mm:ss`, `mm:ss.xx`, `mm:ss.xxx` and `hh:mm:ss(.xxx)`.
    private static func parseTimestamp(_ body: Substring) -> TimeInterval? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var seconds: TimeInterval = 0
        for part in parts.dropLast() {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        guard let last = parts.last,
              let tail = Double(last.replacingOccurrences(of: ",", with: ".")),
              tail >= 0
        else { return nil }
        return seconds * 60 + tail
    }

    private static func trimEmptyEdges(_ lines: [String]) -> [String] {
        var result = lines
        while result.first?.isEmpty == true { result.removeFirst() }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }
}
