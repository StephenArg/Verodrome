import SwiftUI
import VerodromeKit

struct LargeArtworkView: View {
    var urlString: String?
    var symbol: String = "music.note"
    /// Playing track identity. Drives the slide, so covers shared across an album still
    /// move on every skip.
    var trackID: String? = nil
    var slideDirection: ArtworkSlideDirection = .forward

    /// Floor for the cover, so an extremely short layout still shows recognizable
    /// art rather than a sliver.
    private let minimumSide: CGFloat = 140

    /// The cover currently parked in the hero slot.
    @State private var shownTrackID: String?
    @State private var shownURL: String?
    @State private var shownSymbol: String = "music.note"
    @State private var shownOffset: CGFloat = 0

    /// The cover that just left (or is leaving). Kept only for the duration of a slide.
    @State private var leavingTrackID: String?
    @State private var leavingURL: String?
    @State private var leavingSymbol: String = "music.note"
    @State private var leavingOffset: CGFloat = 0

    var body: some View {
        // Explicit offsets rather than `.transition(.move)`: SwiftUI latches the removal
        // edge onto the outgoing view when it was inserted, so a forward skip left the
        // cover exiting left even on the next backward skip. Driving both layers here
        // means the direction of *this* skip controls both edges.
        //
        // `ArtworkView` is already an aspect-fit square, so offering it a flexible box
        // yields the largest square that fits *both* the content width and the height the
        // player has left over. Pinning the side to the width instead would push the
        // transport controls off the bottom on shorter screens.
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .top) {
                if leavingTrackID != nil {
                    cover(url: leavingURL, symbol: leavingSymbol)
                        .offset(x: leavingOffset)
                }

                cover(url: shownURL, symbol: shownSymbol)
                    .offset(x: shownOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .onAppear {
                guard shownTrackID == nil else { return }
                shownTrackID = trackID
                shownURL = urlString
                shownSymbol = symbol
            }
            .onChange(of: trackID) { _, newID in
                guard newID != shownTrackID else {
                    shownURL = urlString
                    shownSymbol = symbol
                    return
                }
                // First paint after appear with a nil → value change: no slide.
                guard shownTrackID != nil else {
                    shownTrackID = newID
                    shownURL = urlString
                    shownSymbol = symbol
                    return
                }

                let outgoingEnd: CGFloat = slideDirection == .forward ? -width : width
                let incomingStart: CGFloat = slideDirection == .forward ? width : -width

                leavingTrackID = shownTrackID
                leavingURL = shownURL
                leavingSymbol = shownSymbol
                leavingOffset = 0

                shownTrackID = newID
                shownURL = urlString
                shownSymbol = symbol
                shownOffset = incomingStart

                withAnimation(.easeInOut(duration: 0.32)) {
                    shownOffset = 0
                    leavingOffset = outgoingEnd
                } completion: {
                    leavingTrackID = nil
                    leavingURL = nil
                    leavingOffset = 0
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minHeight: minimumSide)
    }

    private func cover(url: String?, symbol: String) -> some View {
        ArtworkView.hero(url, symbol: symbol)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
    }
}
