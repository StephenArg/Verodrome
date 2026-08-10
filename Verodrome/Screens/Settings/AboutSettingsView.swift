import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("Help") {
                Link(destination: URL(string: "https://github.com/verodrome/verodrome")!) {
                    Label("Documentation", systemImage: "book")
                }
                Link(destination: URL(string: "mailto:support@verodrome.app")!) {
                    Label("Contact Support", systemImage: "envelope")
                }
            }

            Section("Version") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Build", value: Self.build)
            }
        }
        .verodromePlainList()
        .navigationTitle("About")
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
