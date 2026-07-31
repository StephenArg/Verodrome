import SwiftUI

struct OptionsMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel("More options")
    }
}

struct EntityPreviewSheet: View {
    let title: String
    let subtitle: String
    var artworkURL: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ArtworkView.hero(artworkURL)
                    .frame(width: 220, height: 220)
                    .shadow(radius: 16, y: 8)

                VStack(spacing: 6) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
