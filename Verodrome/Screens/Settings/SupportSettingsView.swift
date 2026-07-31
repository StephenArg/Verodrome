import SwiftUI

struct SupportSettingsView: View {
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

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "1")
            }
        }
        .navigationTitle("Support")
    }
}
