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

    public init(inMemory: Bool = false) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
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
        let candidates = [
            url,
            url.appendingPathExtension("wal"),
            url.appendingPathExtension("shm"),
            // SwiftData may use "default.store-wal" style names already covered above,
            // plus older Core Data naming.
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ]
        for file in candidates {
            try? fm.removeItem(at: file)
        }
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
