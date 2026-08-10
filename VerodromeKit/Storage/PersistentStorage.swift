import Foundation
import SwiftData
import os

public enum PersistentStorageError: Error, Sendable {
    case containerCreationFailed(Error)
    case missingMainContext
}

public actor BackgroundModelActor {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func perform<T: Sendable>(_ work: @Sendable @escaping (ModelContext) throws -> T) async throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let value = try work(context)
        if context.hasChanges {
            try context.save()
        }
        return value
    }
}

public final class PersistentStorage: @unchecked Sendable {
    public static let shared = PersistentStorage()

    public let container: ModelContainer
    public let backgroundActor: BackgroundModelActor
    /// On-disk store URL when the library is persisted; `nil` for in-memory test containers.
    private let storeURL: URL?

    public init(inMemory: Bool = false) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        storeURL = inMemory ? nil : configuration.url
        do {
            container = try Self.makeContainer(configuration: configuration)
        } catch {
            // Lightweight migration can fail when new non-optional attributes were
            // added without defaults. Wipe the local library store and recreate —
            // library content is re-synced from the server.
            if !inMemory {
                Logger(subsystem: "com.verodrome", category: "storage")
                    .error("ModelContainer load failed (\(error.localizedDescription, privacy: .public)); recreating store")
                Self.destroyStoreFiles(at: configuration.url)
                do {
                    container = try Self.makeContainer(configuration: configuration)
                } catch {
                    fatalError("Failed to create ModelContainer after store reset: \(error)")
                }
            } else {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
        backgroundActor = BackgroundModelActor(container: container)
    }

    private static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: Schema(VerodromeSchema.models), configurations: configuration)
    }

    /// Removes the SQLite store and related sidecar files so a fresh container can load.
    private static func destroyStoreFiles(at url: URL) {
        let fm = FileManager.default
        for file in storeFileURLs(for: url) {
            try? fm.removeItem(at: file)
        }
    }

    private static func storeFileURLs(for url: URL) -> [URL] {
        [
            url,
            url.appendingPathExtension("wal"),
            url.appendingPathExtension("shm"),
            // SwiftData may use "default.store-wal" style names already covered above,
            // plus older Core Data naming.
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ]
    }

    /// Bytes used by the local library database (songs, albums, artists, playlists, …).
    ///
    /// Includes SQLite sidecars. Returns 0 for in-memory containers.
    public func libraryStoreByteSize() -> Int64 {
        guard let storeURL else { return 0 }
        let fm = FileManager.default
        var total: Int64 = 0
        var seen = Set<String>()
        for file in Self.storeFileURLs(for: storeURL) {
            let path = file.path
            guard seen.insert(path).inserted else { continue }
            guard fm.fileExists(atPath: path) else { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    @MainActor
    public var mainContext: ModelContext {
        container.mainContext
    }

    /// Call once at app launch. Disables surprise autosaves that can WAL-checkpoint mid-scroll.
    @MainActor
    public func configureMainContext() {
        mainContext.autosaveEnabled = false
    }

    @MainActor
    public func saveMainContextIfNeeded() throws {
        if mainContext.hasChanges {
            try mainContext.save()
        }
    }

    public static func makeInMemory() -> PersistentStorage {
        PersistentStorage(inMemory: true)
    }
}

@MainActor
public final class MainContextProvider {
    public let storage: PersistentStorage

    public init(storage: PersistentStorage = .shared) {
        self.storage = storage
    }

    public var context: ModelContext {
        storage.mainContext
    }
}
