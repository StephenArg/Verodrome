import SwiftUI

struct SettingsHostView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { GeneralSettingsView() } label: {
                    Label("General", systemImage: "gearshape")
                }
                NavigationLink { DisplaySettingsView() } label: {
                    Label("Display", systemImage: "paintbrush")
                }
                NavigationLink { AccountSettingsView() } label: {
                    Label("Account", systemImage: "person.crop.circle")
                }
                NavigationLink { LibrarySettingsView() } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                NavigationLink { PlayerSettingsView() } label: {
                    Label("Player", systemImage: "play.circle")
                }
                NavigationLink { EqualizerSettingsView() } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
                NavigationLink { SwipeSettingsView() } label: {
                    Label("Swipe Actions", systemImage: "hand.draw")
                }
                NavigationLink { ArtworkSettingsView() } label: {
                    Label("Artwork", systemImage: "photo")
                }
                NavigationLink { SupportSettingsView() } label: {
                    Label("Support", systemImage: "questionmark.circle")
                }
                NavigationLink { EventLogView() } label: {
                    Label("Event Log", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink { DeveloperSettingsView() } label: {
                    Label("Developer", systemImage: "hammer")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
