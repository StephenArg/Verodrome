import UIKit
import VerodromeKit

/// Renders timestamped lyrics into a square image for the CarPlay album-art slot.
enum CarPlayLyricsArtwork {
    static let side: CGFloat = 800
    private static let contextLines = 1
    private static let pageSize = 3

    /// Changes only when the visible line window or empty-state copy would change.
    static func token(
        lyrics: String,
        loaded: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> String {
        let lines = LyricsParser.parse(lyrics)
        if lines.isEmpty {
            return loaded ? "empty" : "searching"
        }
        if LyricsParser.isSynced(lines) {
            let index = LyricsParser.activeIndex(in: lines, at: elapsed) ?? -1
            return "s:\(index):\(lyrics.count):\(lyrics.hashValue)"
        }
        return "u:\(unsyncedPage(lineCount: lines.count, elapsed: elapsed, duration: duration)):\(lyrics.count):\(lyrics.hashValue)"
    }

    static func image(
        lyrics: String,
        loaded: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> UIImage {
        let canvas = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor(white: 0.07, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            drawContent(
                lyrics: lyrics,
                loaded: loaded,
                elapsed: elapsed,
                duration: duration,
                in: canvas
            )
        }
    }

    private static func drawContent(
        lyrics: String,
        loaded: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        in canvas: CGSize
    ) {
        let inset: CGFloat = 36
        let bounds = CGRect(origin: .zero, size: canvas).insetBy(dx: inset, dy: inset)
        let lines = LyricsParser.parse(lyrics)
        if lines.isEmpty {
            let copy = loaded ? "No lyrics available." : "Searching for lyrics…"
            drawCentered(copy, in: bounds, fontSize: 72, color: UIColor(white: 0.72, alpha: 1), weight: .medium)
            return
        }

        let window: [(text: String, isCurrent: Bool)]
        if LyricsParser.isSynced(lines) {
            let current = LyricsParser.activeIndex(in: lines, at: elapsed) ?? 0
            window = lineWindow(lines, around: current)
        } else {
            let page = unsyncedPage(lineCount: lines.count, elapsed: elapsed, duration: duration)
            let start = page * pageSize
            let slice = lines[start..<min(lines.count, start + pageSize)]
            window = slice.map { (text: $0.text, isCurrent: false) }
        }

        let rowHeight = bounds.height / CGFloat(max(window.count, 1))
        for (index, row) in window.enumerated() {
            let rowRect = CGRect(
                x: bounds.minX,
                y: bounds.minY + CGFloat(index) * rowHeight,
                width: bounds.width,
                height: rowHeight
            )
            if row.isCurrent {
                let size = fittedFontSize(
                    row.text,
                    in: rowRect,
                    preferred: 96,
                    minimum: 28,
                    weight: .semibold
                )
                drawCentered(row.text, in: rowRect, fontSize: size, color: .white, weight: .semibold)
            } else {
                drawCentered(row.text, in: rowRect, fontSize: 70, color: UIColor(white: 0.55, alpha: 1), weight: .regular)
            }
        }
    }

    private static func lineWindow(
        _ lines: [LyricLine],
        around current: Int
    ) -> [(text: String, isCurrent: Bool)] {
        let span = contextLines * 2 + 1
        var start = max(0, current - contextLines)
        if start + span > lines.count {
            start = max(0, lines.count - span)
        }
        let end = min(lines.count, start + span)
        return (start..<end).map { index in
            (text: lines[index].text, isCurrent: index == current)
        }
    }

    private static func unsyncedPage(
        lineCount: Int,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Int {
        let pages = max(1, Int(ceil(Double(lineCount) / Double(pageSize))))
        guard duration > 0, pages > 1 else { return 0 }
        let progress = min(1, max(0, elapsed / duration))
        return min(pages - 1, Int(progress * Double(pages)))
    }

    /// Largest size at or below `preferred` whose wrapped text still fits in `rect`.
    private static func fittedFontSize(
        _ text: String,
        in rect: CGRect,
        preferred: CGFloat,
        minimum: CGFloat,
        weight: UIFont.Weight
    ) -> CGFloat {
        var size = preferred
        while size > minimum {
            if textFits(text, in: rect, fontSize: size, weight: weight) { return size }
            size -= 2
        }
        return minimum
    }

    private static func textFits(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        weight: UIFont.Weight
    ) -> Bool {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
            .paragraphStyle: paragraph
        ]
        let drawn = (text as NSString).boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return drawn.height <= rect.height + 0.5
    }

    private static func drawCentered(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: UIColor,
        weight: UIFont.Weight
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let drawn = (text as NSString).boundingRect(
            with: CGSize(width: rect.width, height: rect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let origin = CGPoint(
            x: rect.minX,
            y: rect.minY + max(0, (rect.height - drawn.height) / 2)
        )
        (text as NSString).draw(
            with: CGRect(origin: origin, size: CGSize(width: rect.width, height: min(drawn.height, rect.height))),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
    }
}
