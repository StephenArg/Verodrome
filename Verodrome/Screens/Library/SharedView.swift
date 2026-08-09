import SwiftUI
import VerodromeKit

/// Live share links for the signed-in account.
///
/// Shares belong entirely to the server and there are only ever a handful, so this
/// fetches on appear and persists nothing — unlike the rest of the library, there is no
/// local copy that could go stale.
struct SharedView: View {
    @State private var shares: [ShareRef] = []
    @State private var capabilities: ShareCapabilities?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var pendingDeletion: ShareRef?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .listRowBackground(Color(.systemBackground))
            }

            ForEach(shares) { share in
                Button {
                    ShareComposer.presentEditor(for: share) {
                        Task { await reload() }
                    }
                } label: {
                    ShareRow(share: share)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(.systemBackground))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // No `.destructive` role here: that tells List to animate the row
                    // away immediately, which flashes invisible while the confirm sheet
                    // is up. Tint keeps the red affordance without the delete animation.
                    Button {
                        pendingDeletion = share
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)

                    if let url = share.url {
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                            ActionToast.show("Link copied")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Shared")
        .overlay { emptyState }
        .refreshable { await reload() }
        .task { await reload() }
        .alert(
            "Stop sharing this link?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { share in
            Button("Delete Share", role: .destructive) {
                Task { await delete(share) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { share in
            Text("“\(share.displayTitle)” will no longer be reachable for anyone holding the link.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading && shares.isEmpty {
            ProgressView()
        } else if capabilities?.isSupported == false {
            // Distinct from "you haven't shared anything": nothing the user does here
            // will produce a link until an admin turns sharing back on.
            ContentUnavailableView(
                "Sharing Turned Off",
                systemImage: "square.and.arrow.up.slash",
                description: Text("This server has sharing disabled, or your account isn’t allowed to create links.")
            )
        } else if shares.isEmpty {
            ContentUnavailableView(
                "No Shared Links",
                systemImage: "square.and.arrow.up",
                description: Text("Share an album, playlist or song and its link will appear here.")
            )
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        let resolved = await ShareActions.shared.capabilities()
        capabilities = resolved
        guard resolved.isSupported else {
            shares = []
            errorMessage = nil
            return
        }

        do {
            shares = try await ShareActions.shared.shares()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ share: ShareRef) async {
        pendingDeletion = nil
        do {
            try await ShareActions.shared.deleteShare(id: share.id)
            shares.removeAll { $0.id == share.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ShareRow: View {
    let share: ShareRef

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: share.resourceType?.symbolName ?? "link")
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(share.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(expiryLabel)
                    Text("·")
                    Text(share.visitCount == 1 ? "1 visit" : "\(share.visitCount) visits")
                    if share.isDownloadable == true {
                        Text("·")
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(share.isExpired ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var expiryLabel: String {
        guard let expires = share.expires else { return "Never expires" }
        if share.isExpired { return "Expired" }
        return "Expires \(expires.formatted(.relative(presentation: .named)))"
    }
}
