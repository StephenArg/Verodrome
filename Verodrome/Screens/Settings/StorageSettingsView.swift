import SwiftUI
import VerodromeKit

struct StorageSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var player: PlayerViewModel

    @State private var temporaryBytes: Int64 = 0
    @State private var temporaryCount = 0
    @State private var libraryBytes: Int64 = 0
    @State private var artworkBytes: Int64 = 0
    @State private var artworkFileCount = 0
    @State private var isRefreshing = false
    @State private var isClearing = false
    @State private var showClearArtworkConfirm = false
    @State private var showClearQueueConfirm = false
    @State private var statusMessage: String?

    private let staleOptions = [12, 18, 24]

    private var musicCacheBytes: Int64 { temporaryBytes + libraryBytes }

    var body: some View {
        Form {
            Section {
                LabeledContent("Storage Used") {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text(byteFormatter.string(fromByteCount: musicCacheBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Temporary Audio") {
                    Text(byteFormatter.string(fromByteCount: temporaryBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Library Info") {
                    Text(byteFormatter.string(fromByteCount: libraryBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Cached Tracks") {
                    Text("\(temporaryCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Picker("Cache Limit", selection: $settings.cacheLimitBytes) {
                    ForEach(PlayableCacheLimit.allCases) { limit in
                        Text(limit.label).tag(limit.rawValue)
                    }
                }
                .onChange(of: settings.cacheLimitBytes) { _, _ in
                    settings.save()
                    // A lower cap should free space immediately, not wait for the next skip.
                    NotificationCenter.default.post(name: .queueCacheReevaluate, object: nil)
                }
            } header: {
                Text("Music Cache")
            } footer: {
                Text("Storage Used is temporary queue audio plus the local library database (titles, artists, albums, playlists, and the rest). The cache limit only trims temporary audio — offline downloads stay under Downloads, and library info is rebuilt the next time you sync.")
            }

            Section {
                Toggle("Smart Queue Prefetch", isOn: $settings.smartQueuePrefetchEnabled)
                    .onChange(of: settings.smartQueuePrefetchEnabled) { _, _ in
                        settings.save()
                        // Switching off drains the cache it built; switching on fills the
                        // window for the queue that is already playing.
                        NotificationCenter.default.post(name: .queueCacheReevaluate, object: nil)
                    }

                Picker("Stale Threshold", selection: $settings.smartQueueStaleHours) {
                    ForEach(staleOptions, id: \.self) { hours in
                        Text("\(hours) hours").tag(hours)
                    }
                }
                .disabled(!settings.smartQueuePrefetchEnabled)
                .onChange(of: settings.smartQueueStaleHours) { _, _ in settings.save() }
            } header: {
                Text("Prefetch")
            } footer: {
                Text("Caches the tracks just ahead of the one playing so skips start instantly.")
            }

            Section {
                LabeledContent("Storage Used") {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text(byteFormatter.string(fromByteCount: artworkBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Cached Files") {
                    Text("\(artworkFileCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Clear Artwork Cache", role: .destructive) {
                    showClearArtworkConfirm = true
                }
                .disabled(isClearing || (artworkBytes == 0 && artworkFileCount == 0))
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Artwork Cache")
            } footer: {
                Text("Cached cover art on this device. Clearing frees space; artwork will download again when needed.")
            }

            Section {
                Button("Clear Queue", role: .destructive) {
                    showClearQueueConfirm = true
                }
                .disabled(player.queue.isEmpty)
            } header: {
                Text("Queue")
            } footer: {
                Text("Verodrome reopens on the queue you left playing. Clearing it stops playback and starts the next launch empty.")
            }
        }
        .verodromePlainList()
        .navigationTitle("Storage")
        .task {
            await refreshCacheStats()
        }
        .refreshable {
            await refreshCacheStats()
        }
        .confirmationDialog(
            "Clear Artwork Cache?",
            isPresented: $showClearArtworkConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearArtworkCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(byteFormatter.string(fromByteCount: artworkBytes)) of downloaded cover art from this device.")
        }
        .confirmationDialog(
            "Clear Queue?",
            isPresented: $showClearQueueConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Queue", role: .destructive) {
                player.clearQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops playback and removes all \(player.queue.count) tracks from the queue.")
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }

    private func refreshCacheStats() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let cache = VerodromeKit.shared.playableCache
        async let artwork = ArtworkResolver.shared.diskCacheStats()
        async let playable = Task.detached(priority: .utility) {
            cache?.playableCacheStats() ?? .empty
        }.value
        async let library = Task.detached(priority: .utility) {
            PersistentStorage.shared.libraryStoreByteSize()
        }.value
        let (artworkStats, playableStats, librarySize) = await (artwork, playable, library)
        artworkBytes = artworkStats.totalBytes
        artworkFileCount = artworkStats.fileCount
        temporaryBytes = playableStats.temporaryBytes
        temporaryCount = playableStats.temporaryCount
        libraryBytes = librarySize
    }

    private func clearArtworkCache() async {
        isClearing = true
        statusMessage = nil
        defer { isClearing = false }
        do {
            // Stop the queue look-ahead first: a decode already in flight would otherwise
            // land in the cache just after it was emptied.
            PlayerArtworkWarmer.shared.stop()
            ArtworkImageCache.shared.removeAll()
            try await ArtworkResolver.shared.clearCaches()
            await refreshCacheStats()
            statusMessage = "Artwork cache cleared."
        } catch {
            statusMessage = "Couldn’t clear cache: \(error.localizedDescription)"
        }
    }
}
