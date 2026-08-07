import UIKit

/// Picks the color that best represents a piece of artwork, for tinting UI behind it.
///
/// This replaces `DominantColors.dominantColors(uiImage:maxCount:)` on both artwork tint
/// paths. That routine narrows a palette by re-merging it in a `while` loop that widens the
/// match threshold until the result fits `maxCount`, and each pass mutates `ColorFrequency`
/// objects (`frequency += 1`) while they are held in a `Set` keyed on that same field. A
/// member mutated in place lands in the wrong hash bucket, so the set's count stops being
/// meaningful and the loop is not guaranteed to reach `maxCount: 1` — the value both callers
/// asked for. Run inline on the main actor, as the player tint was, one non-terminating pass
/// freezes the entire app.
///
/// Everything here is a single linear pass over a fixed-size sample, so the cost is the same
/// for every image and cannot depend on how the artwork is colored.
enum DominantColorExtractor {
    /// Side of the square the artwork is sampled at. 4096 pixels is far more than is needed
    /// to rank a cover's palette, and small enough that the whole pass is well under a
    /// millisecond even for a full-size hero image.
    private static let sampleSide = 64

    /// Quantization steps per channel. 16 keeps visibly distinct colors in separate buckets
    /// while collapsing gradients and JPEG ringing into one.
    private static let levels = 16

    /// A color crossing back from the sampler. Deliberately not a `UIColor`/`Color`, so the
    /// result is `Sendable` and callers can build whichever they need on the main actor.
    struct Components: Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var hue: CGFloat
        var saturation: CGFloat
        var brightness: CGFloat
    }

    /// Samples `image` off the main actor. Detached so the work never lands on the caller's
    /// actor — the artwork resolver and the main actor both call this.
    static func dominantComponents(of image: UIImage) async -> Components? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .utility) { sample(cgImage) }.value
    }

    /// Buckets every sampled pixel by coarse RGB, then returns the mean color of the
    /// highest-scoring bucket.
    private static func sample(_ cgImage: CGImage) -> Components? {
        guard let pixels = downsampledPixels(cgImage) else { return nil }

        var sums = [Bucket](repeating: Bucket(), count: levels * levels * levels)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            // Artwork is drawn onto an opaque backing, so anything still transparent came
            // from a padded edge rather than the cover itself.
            guard pixels[offset + 3] > 127 else { continue }
            let red = CGFloat(pixels[offset]) / 255
            let green = CGFloat(pixels[offset + 1]) / 255
            let blue = CGFloat(pixels[offset + 2]) / 255
            let index = bucketIndex(red: red, green: green, blue: blue)
            sums[index].add(red: red, green: green, blue: blue)
        }

        var best: (score: CGFloat, components: Components)?
        var mostCommon: (count: Int, components: Components)?
        for bucket in sums where bucket.count > 0 {
            let components = bucket.mean()
            if mostCommon == nil || bucket.count > mostCommon!.count {
                mostCommon = (bucket.count, components)
            }
            guard !isNeutral(components) else { continue }
            let score = CGFloat(bucket.count) * vividness(components)
            if best == nil || score > best!.score {
                best = (score, components)
            }
        }

        // A cover can legitimately be all black, white or gray. Rather than report nothing,
        // fall back to whatever it is actually made of and let the caller's own neutral
        // handling take over.
        return best?.components ?? mostCommon?.components
    }

    /// Draws the artwork into a fixed-size opaque RGBA buffer.
    private static func downsampledPixels(_ cgImage: CGImage) -> [UInt8]? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func bucketIndex(red: CGFloat, green: CGFloat, blue: CGFloat) -> Int {
        let top = levels - 1
        let r = min(Int(red * CGFloat(levels)), top)
        let g = min(Int(green * CGFloat(levels)), top)
        let b = min(Int(blue * CGFloat(levels)), top)
        return (r * levels + g) * levels + b
    }

    /// Near-black, near-white and near-gray carry no hue worth tinting with, and they
    /// dominate the pixel count of most covers.
    private static func isNeutral(_ components: Components) -> Bool {
        components.brightness < 0.10
            || components.brightness > 0.95
            || components.saturation < 0.12
    }

    /// How much of the tint the color can actually carry, peaking at a mid-lightness,
    /// well-saturated reading. Weighting frequency by this stops a huge expanse of near-black
    /// from beating the small band of color that gives a cover its character.
    private static func vividness(_ components: Components) -> CGFloat {
        let lightness = 1 - abs(components.brightness - 0.5) * 2
        return components.saturation * max(lightness, 0.05)
    }

    private struct Bucket {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count = 0

        mutating func add(red: CGFloat, green: CGFloat, blue: CGFloat) {
            self.red += red
            self.green += green
            self.blue += blue
            count += 1
        }

        func mean() -> Components {
            let divisor = CGFloat(max(count, 1))
            return Components(
                red: red / divisor,
                green: green / divisor,
                blue: blue / divisor
            )
        }
    }
}

extension DominantColorExtractor.Components {
    /// Derives HSB alongside RGB so scoring never has to build a `UIColor` per bucket.
    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = max(red, green, blue)
        let low = min(red, green, blue)
        let chroma = brightness - low
        self.saturation = brightness <= 0 ? 0 : chroma / brightness

        guard chroma > 0 else {
            self.hue = 0
            return
        }
        // Which of the six 60° sectors of the wheel the color falls in, as a -1…5 offset.
        let sector: CGFloat
        if brightness == red {
            sector = (green - blue) / chroma
        } else if brightness == green {
            sector = 2 + (blue - red) / chroma
        } else {
            sector = 4 + (red - green) / chroma
        }
        // `UIColor` and `Color` take hue as a 0…1 fraction of the wheel, not degrees.
        self.hue = sector < 0 ? sector / 6 + 1 : sector / 6
    }
}
