import SwiftUI
import UIKit

struct AppIconOption: Identifiable, Hashable {
    let id: String
    let title: String
    /// `nil` restores the primary app icon.
    let alternateIconName: String?
    let previewAssetName: String

    static let all: [AppIconOption] = [
        .init(id: "default", title: "Default", alternateIconName: nil, previewAssetName: "AppIconPreview-Default"),
        .init(id: "WaveCyan", title: "Wave Cyan", alternateIconName: "AppIcon-WaveCyan", previewAssetName: "AppIconPreview-WaveCyan"),
        .init(id: "WaveWhite", title: "White Notes", alternateIconName: "AppIcon-WaveWhite", previewAssetName: "AppIconPreview-WaveWhite"),
        .init(id: "WaveMono", title: "Vinyl Blue", alternateIconName: "AppIcon-WaveMono", previewAssetName: "AppIconPreview-WaveMono"),
        .init(id: "WavePeak", title: "Wave Peak", alternateIconName: "AppIcon-WavePeak", previewAssetName: "AppIconPreview-WavePeak"),
        .init(id: "WaveBright", title: "Wave Bright", alternateIconName: "AppIcon-WaveBright", previewAssetName: "AppIconPreview-WaveBright"),
        .init(id: "WaveDeep", title: "Wave Deep", alternateIconName: "AppIcon-WaveDeep", previewAssetName: "AppIconPreview-WaveDeep"),
        .init(id: "PrismV", title: "Headphones", alternateIconName: "AppIcon-PrismV", previewAssetName: "AppIconPreview-PrismV"),
        .init(id: "AuroraV", title: "Speaker", alternateIconName: "AppIcon-AuroraV", previewAssetName: "AppIconPreview-AuroraV"),
        .init(id: "SpectrumV", title: "Spectrum", alternateIconName: "AppIcon-SpectrumV", previewAssetName: "AppIconPreview-SpectrumV"),
        .init(id: "NeonPulse", title: "Neon Pulse", alternateIconName: "AppIcon-NeonPulse", previewAssetName: "AppIconPreview-NeonPulse"),
        .init(id: "SynthSun", title: "Vinyl Sleeve", alternateIconName: "AppIcon-SynthSun", previewAssetName: "AppIconPreview-SynthSun"),
        .init(id: "Signal", title: "Signal", alternateIconName: "AppIcon-Signal", previewAssetName: "AppIconPreview-Signal"),
        .init(id: "Radar", title: "Radar", alternateIconName: "AppIcon-Radar", previewAssetName: "AppIconPreview-Radar"),
        .init(id: "RetroGrid", title: "Retro Grid", alternateIconName: "AppIcon-RetroGrid", previewAssetName: "AppIconPreview-RetroGrid"),
        .init(id: "GlassPlay", title: "Glass Play", alternateIconName: "AppIcon-GlassPlay", previewAssetName: "AppIconPreview-GlassPlay"),
        .init(id: "CrystalPlay", title: "Crystal Play", alternateIconName: "AppIcon-CrystalPlay", previewAssetName: "AppIconPreview-CrystalPlay"),
        .init(id: "HoloDisc", title: "Holo Disc", alternateIconName: "AppIcon-HoloDisc", previewAssetName: "AppIconPreview-HoloDisc"),
        .init(id: "Headphones", title: "Neon V", alternateIconName: "AppIcon-Headphones", previewAssetName: "AppIconPreview-Headphones"),
        .init(id: "Cassette", title: "Cassette", alternateIconName: "AppIcon-Cassette", previewAssetName: "AppIconPreview-Cassette"),
        .init(id: "VinylMark", title: "Glass V", alternateIconName: "AppIcon-VinylMark", previewAssetName: "AppIconPreview-VinylMark"),
        .init(id: "Groove", title: "Groove", alternateIconName: "AppIcon-Groove", previewAssetName: "AppIconPreview-Groove"),
        .init(id: "GoldRibbon", title: "Gold Ribbon", alternateIconName: "AppIcon-GoldRibbon", previewAssetName: "AppIconPreview-GoldRibbon"),
        .init(id: "Speaker", title: "Ember Speaker", alternateIconName: "AppIcon-Speaker", previewAssetName: "AppIconPreview-Speaker"),
        .init(id: "Layers", title: "Layers", alternateIconName: "AppIcon-Layers", previewAssetName: "AppIconPreview-Layers"),
        .init(id: "Sleeve", title: "Sleeve", alternateIconName: "AppIcon-Sleeve", previewAssetName: "AppIconPreview-Sleeve"),
        .init(id: "NightWave", title: "Night Wave", alternateIconName: "AppIcon-NightWave", previewAssetName: "AppIconPreview-NightWave"),
        .init(id: "Ember", title: "Ember", alternateIconName: "AppIcon-Ember", previewAssetName: "AppIconPreview-Ember"),
        .init(id: "PaperCut", title: "Paper Cut", alternateIconName: "AppIcon-PaperCut", previewAssetName: "AppIconPreview-PaperCut"),
        .init(id: "Vintage", title: "Vintage", alternateIconName: "AppIcon-Vintage", previewAssetName: "AppIconPreview-Vintage"),
    ]
}

struct AppIconSettingsView: View {
    @State private var selectedID: String = AppIconOption.all[0].id
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AppIconOption.all) { option in
                    Button {
                        select(option)
                    } label: {
                        VStack(spacing: 8) {
                            Image(option.previewAssetName)
                                .resizable()
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            selectedID == option.id ? Color.accentColor : Color.clear,
                                            lineWidth: 3
                                        )
                                }
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

                            Text(option.title)
                                .font(.caption2)
                                .foregroundStyle(selectedID == option.id ? Color.primary : Color.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selectedID == option.id ? .isSelected : [])
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: syncSelectionFromSystem)
        .alert("Couldn’t Change Icon", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    private func syncSelectionFromSystem() {
        let current = UIApplication.shared.alternateIconName
        selectedID = AppIconOption.all.first(where: { $0.alternateIconName == current })?.id
            ?? AppIconOption.all[0].id
    }

    private func select(_ option: AppIconOption) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "Alternate icons aren’t supported on this device."
            return
        }
        guard option.id != selectedID else { return }

        let previous = selectedID
        selectedID = option.id

        UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
            DispatchQueue.main.async {
                if let error {
                    selectedID = previous
                    errorMessage = error.localizedDescription
                } else {
                    syncSelectionFromSystem()
                }
            }
        }
    }
}
