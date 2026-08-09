import SwiftUI
import VerodromeKit

/// Creates a public link for an album, playlist, artist or song, or edits one that
/// already exists.
///
/// What the form offers is driven entirely by `ShareCapabilities`: servers disagree about
/// whether downloads are a thing, whether expiry is an instant or a number of days, and
/// which kinds of thing can be shared at all.
struct ShareComposerView: View {
    enum Mode: Equatable {
        case create(ShareSubject)
        case edit(ShareRef)
    }

    let mode: Mode
    /// Called after a successful create or edit so a list behind the sheet can refresh.
    var onChange: (() -> Void)?
    let onClose: () -> Void

    @State private var capabilities: ShareCapabilities?
    @State private var description = ""
    @State private var isDownloadable = false
    @State private var hasExpiry = false
    @State private var expiryDate = Date().addingTimeInterval(7 * 86_400)
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    /// Set once the server has answered with a link, which turns the sheet into a
    /// hand-off screen.
    @State private var createdShare: ShareRef?
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            Group {
                if let createdShare {
                    resultForm(for: createdShare)
                } else if let capabilities, capabilities.isSupported {
                    composerForm(capabilities)
                } else if capabilities == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    unsupportedState
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task { await loadCapabilities() }
    }

    // MARK: - Compose

    @ViewBuilder
    private func composerForm(_ capabilities: ShareCapabilities) -> some View {
        Form {
            Section {
                headerRow
            }

            Section {
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Description")
            } footer: {
                Text("Shown to anyone who opens the link. Leave it blank to let the server name it.")
            }

            downloadSection(capabilities)
            expirySection(capabilities)

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if case .edit = mode {
                Section {
                    Button("Delete Share", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .disabled(isWorking)
                }
            }

            Section {
                Button {
                    Task { await confirm() }
                } label: {
                    if isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(confirmTitle)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isWorking)
            }
        }
        .confirmationDialog(
            "Stop sharing this link?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Share", role: .destructive) {
                Task { await deleteShare() }
            }
        } message: {
            Text("Anyone holding the link will no longer be able to open it.")
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 12) {
            ArtworkView(token: artworkToken, kind: artworkKind, size: ArtworkPixelSize.thumbnail)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func downloadSection(_ capabilities: ShareCapabilities) -> some View {
        switch capabilities.download {
        case .unsupported:
            EmptyView()
        case .configurable:
            Section {
                Toggle("Allow Downloading", isOn: $isDownloadable)
            } footer: {
                Text("Lets people save the files instead of only streaming them.")
            }
        case .fixed(let value):
            Section {
                Toggle("Allow Downloading", isOn: .constant(value))
                    .disabled(true)
            } footer: {
                Text(
                    value
                        ? "This server allows downloads on every share."
                        : "This server does not allow downloads on shares."
                )
            }
        }
    }

    @ViewBuilder
    private func expirySection(_ capabilities: ShareCapabilities) -> some View {
        if capabilities.expiration != .unsupported {
            Section {
                Toggle("Expires", isOn: $hasExpiry)
                if hasExpiry {
                    DatePicker(
                        "Expiry Date",
                        selection: $expiryDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            } footer: {
                if capabilities.expiration == .wholeDays {
                    Text("This server counts expiry in whole days, so the link is kept until the end of the day you pick.")
                } else if !hasExpiry {
                    Text("The link keeps working until you delete it.")
                }
            }
        }
    }

    @ViewBuilder
    private var unsupportedState: some View {
        ContentUnavailableView(
            "Sharing Unavailable",
            systemImage: "square.and.arrow.up.slash",
            description: Text("This server has sharing turned off, or your account isn’t allowed to create links.")
        )
    }

    // MARK: - Result

    @ViewBuilder
    private func resultForm(for share: ShareRef) -> some View {
        Form {
            Section {
                headerRow
            }

            if let url = share.url {
                Section {
                    Text(url.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Link", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }

                    ShareLink(item: url) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Link")
                } footer: {
                    expiryFooter(for: share)
                }
            } else {
                Section {
                    Text("The share was created, but the server didn’t return a link for it. You can find it in the Shared section of your library.")
                }
            }
        }
    }

    @ViewBuilder
    private func expiryFooter(for share: ShareRef) -> some View {
        if let expires = share.expires {
            Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            Text("This link does not expire.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(createdShare == nil ? "Cancel" : "Done") { onClose() }
        }
    }

    // MARK: - Actions

    private func loadCapabilities() async {
        let resolved = await ShareActions.shared.capabilities()
        capabilities = resolved
        seedFields(with: resolved)
    }

    private func seedFields(with capabilities: ShareCapabilities) {
        switch mode {
        case .create(let subject):
            // Prefilled rather than left empty: a server-generated label is fine, but the
            // title is what the person sharing would have typed anyway.
            if description.isEmpty { description = subject.title }
            isDownloadable = capabilities.download.forcedValue ?? false
        case .edit(let share):
            if description.isEmpty { description = share.description ?? "" }
            isDownloadable = share.isDownloadable ?? capabilities.download.forcedValue ?? false
            if let expires = share.expires {
                hasExpiry = true
                // A share that already lapsed can't seed a picker limited to the future.
                expiryDate = max(expires, Date().addingTimeInterval(60))
            }
        }
    }

    private func confirm() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let downloadChoice = capabilities?.download.isConfigurable == true ? isDownloadable : nil
        let expires = hasExpiry ? expiryDate : nil

        do {
            switch mode {
            case .create(let subject):
                let share = try await ShareActions.shared.createShare(
                    subject: subject,
                    description: description,
                    expires: expires,
                    isDownloadable: downloadChoice
                )
                onChange?()
                createdShare = share
            case .edit(let share):
                try await ShareActions.shared.updateShare(
                    id: share.id,
                    description: description,
                    expires: .some(expires),
                    isDownloadable: downloadChoice
                )
                onChange?()
                onClose()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteShare() async {
        guard case .edit(let share) = mode else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await ShareActions.shared.deleteShare(id: share.id)
            onChange?()
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Presentation

    private var navigationTitle: String {
        if createdShare != nil { return "Link Ready" }
        switch mode {
        case .create: return "Share"
        case .edit: return "Edit Share"
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .create: return "Start Sharing"
        case .edit: return "Save"
        }
    }

    private var headerTitle: String {
        switch mode {
        case .create(let subject): return subject.title
        case .edit(let share): return share.displayTitle
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .create(let subject):
            return subject.subtitle ?? subject.resourceType.displayName
        case .edit(let share):
            return share.resourceType?.displayName ?? "Share"
        }
    }

    private var artworkToken: String? {
        if case .create(let subject) = mode { return subject.artwork?.id }
        return nil
    }

    private var artworkKind: ArtworkKind {
        if case .create(let subject) = mode { return subject.artwork?.kind ?? .album }
        return .album
    }
}

extension ShareResourceType {
    var displayName: String {
        switch self {
        case .song: return "Song"
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .artist: return "Artist"
        }
    }

    var symbolName: String {
        switch self {
        case .song: return "music.note"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .artist: return "music.microphone"
        }
    }
}
