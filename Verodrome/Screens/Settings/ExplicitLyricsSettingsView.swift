import SwiftUI
import VerodromeKit

struct ExplicitLyricsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var blacklistDraft = ""
    @State private var whitelistDraft = ""
    @State private var showForbiddenWords = false
    @State private var presentedWordList: CustomWordList?
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
                Button("View Forbidden Words") {
                    showForbiddenWords = true
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
                Text("Hides songs already marked explicit from Songs, Search, Favorites, album track lists, and artist and genre album rows. Playlist tracks stay visible.")
            }

            Section {
                Toggle("Highlight Explicit Words", isOn: $settings.highlightExplicitLyrics)
                    .onChange(of: settings.highlightExplicitLyrics) { _, _ in settings.save() }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Marks matching words in the player and inspector lyrics, using the same list as detection.")
            }

            wordListSection(
                title: "Always Mark Explicit",
                viewTitle: "View Blacklist",
                footer: "Added on top of the built-in list.",
                draft: $blacklistDraft,
                words: $settings.explicitBlacklistWords,
                other: $settings.explicitWhitelistWords,
                list: .blacklist
            )

            wordListSection(
                title: "Never Mark Explicit",
                viewTitle: "View Whitelist",
                footer: "Never flagged, even on the built-in list. Adding a word here removes it from Always Mark Explicit.",
                draft: $whitelistDraft,
                words: $settings.explicitWhitelistWords,
                other: $settings.explicitBlacklistWords,
                list: .whitelist
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
        .onAppear(perform: dropBlacklistWordsAlsoWhitelisted)
        .sheet(isPresented: $showForbiddenWords) {
            ForbiddenWordsSheet(initial: settings.explicitSensitivity)
        }
        .sheet(item: $presentedWordList) { list in
            CustomWordListSheet(list: list)
        }
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
        viewTitle: String,
        footer: String,
        draft: Binding<String>,
        words: Binding<[String]>,
        other: Binding<[String]>,
        list: CustomWordList
    ) -> some View {
        Section {
            HStack {
                TextField("Add a word", text: draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { addWord(from: draft, to: words, removingFrom: other) }
                Button("Add") { addWord(from: draft, to: words, removingFrom: other) }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(viewTitle) {
                presentedWordList = list
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

    private func addWord(
        from draft: Binding<String>,
        to words: Binding<[String]>,
        removingFrom other: Binding<[String]>
    ) {
        let normalized = UserSettings.normalizedWords([draft.wrappedValue])
        guard let word = normalized.first else { return }
        var changed = false
        if other.wrappedValue.contains(word) {
            other.wrappedValue.removeAll { $0 == word }
            changed = true
        }
        if !words.wrappedValue.contains(word) {
            words.wrappedValue.append(word)
            changed = true
        }
        if changed {
            settings.markExplicitWordListChanged()
        }
        draft.wrappedValue = ""
    }

    /// A word on both lists is already ignored. Drop the Always copy so the two sections stay distinct.
    private func dropBlacklistWordsAlsoWhitelisted() {
        let allowed = Set(settings.explicitWhitelistWords)
        let filtered = settings.explicitBlacklistWords.filter { !allowed.contains($0) }
        guard filtered.count != settings.explicitBlacklistWords.count else { return }
        settings.explicitBlacklistWords = filtered
        settings.save()
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

private enum CustomWordList: String, Identifiable {
    case blacklist
    case whitelist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blacklist: "Blacklist"
        case .whitelist: "Whitelist"
        }
    }

    @MainActor
    func words(in settings: SettingsStore) -> [String] {
        switch self {
        case .blacklist: settings.explicitBlacklistWords
        case .whitelist: settings.explicitWhitelistWords
        }
    }

    @MainActor
    func remove(_ word: String, from settings: SettingsStore) {
        switch self {
        case .blacklist:
            settings.explicitBlacklistWords.removeAll { $0 == word }
        case .whitelist:
            settings.explicitWhitelistWords.removeAll { $0 == word }
        }
        settings.markExplicitWordListChanged()
    }
}

/// Custom blacklist or whitelist. Tapping a pill removes that word.
private struct CustomWordListSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    let list: CustomWordList

    private var words: [String] {
        list.words(in: settings).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if words.isEmpty {
                        Text("No words yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(words, id: \.self) { word in
                                wordPill(word)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(list.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var caption: String {
        if words.isEmpty {
            switch list {
            case .blacklist: "Words added here sit on top of the built-in list."
            case .whitelist: "Words added here are never flagged."
            }
        } else {
            switch list {
            case .blacklist:
                "\(words.count) words added on top of the built-in list. Tap a word to remove it."
            case .whitelist:
                "\(words.count) words never flagged. Tap a word to remove it."
            }
        }
    }

    private func wordPill(_ word: String) -> some View {
        Button {
            list.remove(word, from: settings)
        } label: {
            HStack(spacing: 4) {
                Text(word)
                    .font(.subheadline)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(.primary)
            .background(Color.secondary.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word)
        .accessibilityHint("Removes this word")
    }
}

/// Built-in lists for each sensitivity. Tapping a pill adds that word to Never Mark Explicit.
private struct ForbiddenWordsSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var sensitivity: LyricsExplicitSensitivity

    init(initial: LyricsExplicitSensitivity) {
        _sensitivity = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Sensitivity", selection: $sensitivity) {
                        ForEach(LyricsExplicitSensitivity.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 8) {
                        ForEach(words, id: \.self) { word in
                            wordPill(word)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Forbidden Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var words: [String] {
        LyricsExplicitWordLists.words(for: sensitivity).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var caption: String {
        let scope: String
        switch sensitivity {
        case .loose:
            scope = "Strongest terms only."
        case .average:
            scope = "Every Loose word, plus common strong language."
        case .conservative:
            scope = "Every Average word, plus milder language."
        }
        return "\(words.count) words. \(scope) Tap a word to add it to Never Mark Explicit. Filled words are already ignored; tap again to include them."
    }

    private func wordPill(_ word: String) -> some View {
        let ignored = settings.explicitWhitelistWords.contains(word)
        return Button {
            toggleWhitelist(word)
        } label: {
            HStack(spacing: 4) {
                if ignored {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(word)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(ignored ? Color.white : Color.primary)
            .background(ignored ? Color.accentColor : Color.secondary.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word)
        .accessibilityHint(ignored ? "Removes from Never Mark Explicit" : "Adds to Never Mark Explicit")
        .accessibilityAddTraits(ignored ? .isSelected : [])
    }

    private func toggleWhitelist(_ word: String) {
        if let index = settings.explicitWhitelistWords.firstIndex(of: word) {
            settings.explicitWhitelistWords.remove(at: index)
        } else {
            settings.explicitBlacklistWords.removeAll { $0 == word }
            settings.explicitWhitelistWords.append(word)
        }
        settings.markExplicitWordListChanged()
    }
}

/// Wraps pills onto as many rows as the width allows.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .greatestFiniteMagnitude)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Item {
        var view: LayoutSubview
        var size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let fits = current.items.isEmpty || current.width + spacing + size.width <= maxWidth
            if !fits {
                rows.append(current)
                current = Row()
            }
            current.items.append(Item(view: view, size: size))
            current.width = current.items.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
