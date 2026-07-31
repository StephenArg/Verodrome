import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var draftBands: [Float] = []
    @State private var draggingIndex: Int?

    private static let bandLabels = [
        "32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"
    ]

    private var bands: [Float] {
        draftBands.isEmpty ? player.equalizerBands : draftBands
    }

    var body: some View {
        VStack(spacing: 16) {
            Toggle("Equalizer", isOn: Binding(
                get: { player.equalizerEnabled },
                set: { player.setEqualizerEnabled($0) }
            ))
            .padding(.horizontal)

            GeometryReader { geo in
                let bandCount = max(bands.count, 1)
                let columnWidth = geo.size.width / CGFloat(bandCount)
                // Visual vertical track length; keep inside the available height.
                let sliderLength = min(max(geo.size.height - 40, 80), 150)

                HStack(alignment: .center, spacing: 0) {
                    ForEach(bands.indices, id: \.self) { index in
                        VStack(spacing: 6) {
                            Text(String(format: "%+.0f", bands[index]))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(height: 14)

                            // Rotation does not change layout bounds — apply a square
                            // post-rotation frame so 10 bands fit the screen width.
                            Slider(
                                value: Binding(
                                    get: { Double(bands[index]) },
                                    set: { updateBand(index, Float($0)) }
                                ),
                                in: -12...12,
                                onEditingChanged: { editing in
                                    if editing {
                                        draggingIndex = index
                                        if draftBands.isEmpty {
                                            draftBands = player.equalizerBands
                                        }
                                    } else if draggingIndex == index {
                                        draggingIndex = nil
                                        commitBands()
                                    }
                                }
                            )
                            .disabled(!player.equalizerEnabled)
                            .frame(width: sliderLength, height: 28)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 28, height: sliderLength)

                            Text(Self.bandLabels[min(index, Self.bandLabels.count - 1)])
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: columnWidth, height: geo.size.height)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipped()
            .opacity(player.equalizerEnabled ? 1 : 0.45)

            Button("Reset") {
                draftBands = Array(repeating: 0, count: max(player.equalizerBands.count, 10))
                commitBands()
            }
            .buttonStyle(.bordered)
            .disabled(!player.equalizerEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onAppear {
            draftBands = player.equalizerBands
        }
        .onChange(of: player.equalizerBands) { _, newValue in
            if draggingIndex == nil {
                draftBands = newValue
            }
        }
    }

    private func updateBand(_ index: Int, _ value: Float) {
        if draftBands.isEmpty {
            draftBands = player.equalizerBands
        }
        guard draftBands.indices.contains(index) else { return }
        draftBands[index] = value
        player.applyEqualizerBandsLive(draftBands)
    }

    private func commitBands() {
        let next = draftBands.isEmpty ? player.equalizerBands : draftBands
        player.equalizerBands = next
        player.applyEqualizerBands()
        draftBands = next
    }
}
