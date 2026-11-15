import Foundation

public enum SnapshotLoadResult: Equatable, Sendable {
    case none
    case restored(RoundState)
    /// The file was unusable and moved aside (never silently deleted).
    case rejected(SnapshotError)
}

/// Stores the single unfinished round as an atomically written JSON file.
/// Unusable files are quarantined next to it for diagnosis; completed history
/// lives elsewhere and is never touched by this store.
public final class RoundSnapshotStore: @unchecked Sendable {
    public static let fileName = "UnfinishedRound.json"
    public static let maxQuarantinedFiles = 3

    public let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public var hasSnapshot: Bool { fileManager.fileExists(atPath: fileURL.path) }

    public func save(_ snapshot: RoundSnapshot) throws {
        let data = try SnapshotCodec.encode(snapshot)
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Saves the round, or clears the file when the round is completed.
    public func save(state: RoundState, manifestVersion: String, now: Date = Date()) throws {
        if let snapshot = RoundSnapshot(state: state, manifestVersion: manifestVersion, savedAt: now) {
            try save(snapshot)
        } else {
            try clear()
        }
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    public func loadSnapshot() throws -> RoundSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SnapshotError.unreadable("could not read file")
        }
        return try SnapshotCodec.decode(data)
    }

    /// Loads, validates and restores. Invalid data is quarantined.
    public func load(catalog: ContentCatalog, policy: ContentAccessPolicy) -> SnapshotLoadResult {
        do {
            guard let snapshot = try loadSnapshot() else { return .none }
            return .restored(try snapshot.restore(catalog: catalog, policy: policy))
        } catch let error as SnapshotError {
            quarantine()
            return .rejected(error)
        } catch {
            quarantine()
            return .rejected(.unreadable(String(describing: error)))
        }
    }

    public var quarantinedFiles: [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("UnfinishedRound.rejected-") }.sorted().map { directory.appendingPathComponent($0) }
    }

    private func quarantine() {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let target = directory.appendingPathComponent("UnfinishedRound.rejected-\(stamp).json")
        do {
            try fileManager.moveItem(at: fileURL, to: target)
        } catch {
            try? fileManager.removeItem(at: fileURL)
        }
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("UnfinishedRound.rejected-") }.sorted()
        for name in names.dropLast(Self.maxQuarantinedFiles) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
