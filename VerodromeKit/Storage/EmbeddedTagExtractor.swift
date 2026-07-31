import Foundation
import ID3TagEditor
import UIKit

/// Extracts embedded artwork and lyrics from downloaded audio files (MP3 ID3 tags).
public enum EmbeddedTagExtractor {
    public struct Result: Sendable {
        public let lyrics: String?
        public let artworkData: Data?
    }

    public static func extract(from fileURL: URL) -> Result {
        do {
            let editor = ID3TagEditor()
            guard let tag = try editor.read(from: fileURL.path) else {
                return Result(lyrics: nil, artworkData: nil)
            }

            var lyrics: String?
            var artwork: Data?

            for (name, frame) in tag.frames {
                if case .unsynchronizedLyrics = name,
                   let localized = frame as? ID3FrameWithLocalizedContent,
                   lyrics == nil {
                    let text = localized.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { lyrics = text }
                }
                if case .attachedPicture = name,
                   let picture = frame as? ID3FrameAttachedPicture,
                   artwork == nil {
                    artwork = picture.picture
                }
            }

            // Prefer front cover if available.
            if let front = tag.frames[.attachedPicture(.frontCover)] as? ID3FrameAttachedPicture {
                artwork = front.picture
            }

            return Result(lyrics: lyrics, artworkData: artwork)
        } catch {
            return Result(lyrics: nil, artworkData: nil)
        }
    }

    public static func lyrics(from fileURL: URL) -> String? {
        extract(from: fileURL).lyrics
    }

    public static func artworkImage(from fileURL: URL) -> UIImage? {
        guard let data = extract(from: fileURL).artworkData else { return nil }
        return UIImage(data: data)
    }
}
