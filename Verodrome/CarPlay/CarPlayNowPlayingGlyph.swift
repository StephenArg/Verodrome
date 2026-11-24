import CoreGraphics
import SwiftUI

/// The custom glyphs on CarPlay's Now Playing button row.
///
/// Each is drawn on a 16-unit grid (y down) with 1.5-unit strokes, the proportions of
/// the phone player's shuffle glyph, so the row reads as one set. `CarPlayArtwork`
/// places that grid in the button image; nothing here knows about points or pixels.
enum CarPlayNowPlayingGlyph {
    case addToPlaylist
    case inPlaylist
    case shuffle
    case repeatAll
    case repeatOne

    static let gridSize: CGFloat = 16
    private static let stroke: CGFloat = 1.5

    /// Draws the glyph in opaque black, for use as a template image.
    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(Self.stroke)
        switch self {
        case .addToPlaylist: drawAddToPlaylist(in: ctx)
        case .inPlaylist: drawInPlaylist(in: ctx)
        case .shuffle: drawShuffle(in: ctx)
        case .repeatAll: drawRepeat(in: ctx, showsOne: false)
        case .repeatOne: drawRepeat(in: ctx, showsOne: true)
        }
        ctx.restoreGState()
    }

    // MARK: - Add to playlist

    /// A ring with a plus inside it.
    private func drawAddToPlaylist(in ctx: CGContext) {
        let half = Self.stroke / 2
        ctx.strokeEllipse(in: CGRect(x: half, y: half, width: 16 - Self.stroke, height: 16 - Self.stroke))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 5, y: 8))
        ctx.addLine(to: CGPoint(x: 11, y: 8))
        ctx.move(to: CGPoint(x: 8, y: 5))
        ctx.addLine(to: CGPoint(x: 8, y: 11))
        ctx.strokePath()
    }

    /// A solid disc with the check cut out of it, so the CarPlay chrome shows through.
    /// A template SF Symbol can't do that: its check is tinted along with the disc.
    private func drawInPlaylist(in ctx: CGContext) {
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        ctx.setBlendMode(.destinationOut)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.miter)
        ctx.move(to: CGPoint(x: 4.28, y: 8.56))
        ctx.addLine(to: CGPoint(x: 6.22, y: 10.5))
        ctx.addLine(to: CGPoint(x: 11.22, y: 5.5))
        ctx.strokePath()
    }

    // MARK: - Shuffle

    /// The crossing arrows the phone player draws, from the same path data.
    private func drawShuffle(in ctx: CGContext) {
        for data in ShuffleControlIcon.pathData {
            ctx.addPath(SVGPathParser.parse(data).cgPath)
        }
        ctx.fillPath()
    }

    // MARK: - Repeat

    /// A rounded loop whose bottom edge ends in an arrowhead pointing back along it.
    /// Repeat One opens the top edge for a "1".
    private func drawRepeat(in ctx: CGContext, showsOne: Bool) {
        let half = Self.stroke / 2
        let left = half, right = 16 - half
        let top = 1 + half, bottom = 13.5 - half
        let radius: CGFloat = 3

        // Clockwise from the stub left of the arrowhead, round to the arrowhead's base.
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 5, y: bottom))
        ctx.addLine(to: CGPoint(x: left + radius, y: bottom))
        ctx.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - radius), radius: radius)
        ctx.addLine(to: CGPoint(x: left, y: top + radius))
        ctx.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + radius, y: top), radius: radius)
        if showsOne {
            ctx.addLine(to: CGPoint(x: 4.5, y: top))
            ctx.move(to: CGPoint(x: 11.5, y: top))
        }
        ctx.addLine(to: CGPoint(x: right - radius, y: top))
        ctx.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + radius), radius: radius)
        ctx.addLine(to: CGPoint(x: right, y: bottom - radius))
        ctx.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - radius, y: bottom), radius: radius)
        ctx.addLine(to: CGPoint(x: 8, y: bottom))
        ctx.strokePath()

        // Arrowhead: two arms meeting in a point on the bottom edge.
        ctx.setLineCap(.round)
        ctx.setLineJoin(.miter)
        ctx.move(to: CGPoint(x: 10.3, y: bottom - 2.3))
        ctx.addLine(to: CGPoint(x: 8, y: bottom))
        ctx.addLine(to: CGPoint(x: 10.3, y: bottom + 2.3))
        ctx.strokePath()

        if showsOne {
            drawOne(in: ctx)
        }
    }

    /// The "1" standing in the gap: a stem with a flag swept back from its top, starting
    /// a little above the loop and ending just past its middle.
    private func drawOne(in ctx: CGContext) {
        let stemLeft: CGFloat = 8, stemRight: CGFloat = 9.46
        let top: CGFloat = 0.25, bottom: CGFloat = 8.05
        let flagLeft: CGFloat = 6.15, flagBottom: CGFloat = 2.65
        ctx.move(to: CGPoint(x: stemRight, y: bottom))
        ctx.addLine(to: CGPoint(x: stemRight, y: top))
        ctx.addLine(to: CGPoint(x: stemLeft + 0.05, y: top))
        ctx.addCurve(
            to: CGPoint(x: flagLeft, y: 1.5),
            control1: CGPoint(x: 7.95, y: 0.95),
            control2: CGPoint(x: 7.3, y: 1.45)
        )
        ctx.addLine(to: CGPoint(x: flagLeft, y: flagBottom))
        ctx.addLine(to: CGPoint(x: stemLeft, y: flagBottom))
        ctx.addLine(to: CGPoint(x: stemLeft, y: bottom))
        ctx.closePath()
        ctx.fillPath()
    }
}
