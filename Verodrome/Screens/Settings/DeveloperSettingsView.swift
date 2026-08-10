import SwiftUI
import VerodromeKit

struct DeveloperSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Diagnostics") {
                Toggle("Show Window Sizes", isOn: $settings.developerWindowSizes)
                    .onChange(of: settings.developerWindowSizes) { _, _ in settings.save() }
            }

            if settings.developerWindowSizes {
                Section("Window") {
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Size: \(Int(proxy.size.width)) × \(Int(proxy.size.height))")
                            Text("Safe Area Top: \(Int(proxy.safeAreaInsets.top))")
                            Text("Safe Area Bottom: \(Int(proxy.safeAreaInsets.bottom))")
                        }
                        .font(.caption.monospaced())
                    }
                    .frame(height: 80)
                }
            }
        }
        .verodromePlainList()
        .navigationTitle("Developer")
    }
}
