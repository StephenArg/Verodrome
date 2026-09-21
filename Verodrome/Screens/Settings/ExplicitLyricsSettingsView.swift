import SwiftUI
import VerodromeKit

struct ExplicitLyricsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var blacklistDraft = ""
    @State private var whitelistDraft = ""
    @State private var showRecheckConfirm = false
    @State private var isRechecking = false
    @State private var recheckProgress = LyricsExplicitScanProgress()
    @State private var recheckMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Detect Explicit from Lyrics", isOn: $settings.explicitDetectionEnabled)
                    .onChange(of: settings.explicitDetectionEnabled) { _, _ in settings.save() }
                Picker("Sensitivity", selection: $settings.explicitSensitivity) {
                    ForEach(LyricsExplicitSensitivity.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: settings.explicitSensitivity) { _, _ in
                    settings.markExplicitWordListChanged()
                }
            } header: {
                Text("Detection")
            } footer: {
                Text("Songs are checked when their lyrics load, usually while they sit in the play queue. Conservative flags milder language; Loose only the strongest terms.")
            }

            Section {
                Toggle("Hide Explicit Songs", isOn: $settings.hideExplicitSongs)
                    .onChange(of: settings.hideExplicitSongs) { _, _ in settings.save() }
            } header: {
                Text("Library")
            } footer: {
                Text("Hides songs already marked explicit from Songs, Search, Favorites, and similar lists. Album and playlist tracks stay visible.")
            }

            wordListSection(
                title: "Always Mark Explicit",
                footer: "Added to the built-in list for the selected sensitivity.",
                draft: $blacklistDraft,
                words: $settings.explicitBlacklistWords
            )

            wordListSection(
                title: "Never Mark Explicit",
                footer: "Ignored even when they appear in the built-in list.",
                draft: $whitelistDraft,
                words: $settings.explicitWhitelistWords
            )

            Section {
                Button(isRechecking ? "Rechecking…" : "Recheck Songs Marked Explicit") {
                    showRecheckConfirm = true
                }
                .disabled(isRechecking || !settings.explicitDetectionEnabled)
                if isRechecking {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recheckStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LibrarySyncProgressBar(fraction: recheckFraction)
                    }
                }
                if let recheckMessage {
                    Text(recheckMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Looks up lyrics again for every song currently marked explicit. This can take a while when many tracks need a network fetch.")
            }
        }
        .verodromePlainList()
        .navigationTitle("Explicit Lyrics")
        .alert("Recheck Explicit Songs?", isPresented: $showRecheckConfirm) {
            Button("Recheck") {
                Task { await recheckExplicitSongs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This looks up lyrics for every song marked explicit and can take a while, especially when a lot of tracks need a network fetch.")
        }
    }

    @ViewBuilder
    private func wordListSection(
        title: String,
        footer: String,
        draft: Binding<String>,
        words: Binding<[String]>
    ) -> some View {
        Section {
            HStack {
                TextField("Add a word", text: draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { addWord(from: draft, to: words) }
                Button("Add") { addWord(from: draft, to: words) }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(words.wrappedValue, id: \.self) { word in
                Text(word)
            }
            .onDelete { offsets in
                words.wrappedValue.remove(atOffsets: offsets)
                settings.markExplicitWordListChanged()
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private var recheckFraction: Double {
        guard recheckProgress.total > 0 else { return 0 }
        return Double(recheckProgress.completed) / Double(recheckProgress.total)
    }

    private var recheckStatusText: String {
        "Checking \(recheckProgress.completed) of \(recheckProgress.total)…"
    }

    private func addWord(from draft: Binding<String>, to words: Binding<[String]>) {
        let normalized = UserSettings.normalizedWords([draft.wrappedValue])
        guard let word = normalized.first else { return }
        if !words.wrappedValue.contains(word) {
            words.wrappedValue.append(word)
            settings.markExplicitWordListChanged()
        }
        draft.wrappedValue = ""
    }

    private func recheckExplicitSongs() async {
        isRechecking = true
        recheckMessage = nil
        recheckProgress = LyricsExplicitScanProgress()
        let result = await LyricsExplicitScanner.recheckExplicit { progress in
            recheckProgress = progress
        }
        isRechecking = false
        if result.total == 0 {
            recheckMessage = "No songs are marked explicit."
        } else if result.flippedToClean == 0 {
            recheckMessage = "Checked \(result.completed) songs. None changed."
        } else {
            recheckMessage = "Checked \(result.completed) songs. \(result.flippedToClean) no longer marked explicit."
        }
        ActionToast.show(recheckMessage ?? "Recheck finished.")
    }
}
