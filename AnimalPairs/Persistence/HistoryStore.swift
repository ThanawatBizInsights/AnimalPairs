import AnimalPairsCore
import Foundation
import SwiftData

/// Version 1 of the on-device history schema. Future changes add
/// `HistorySchemaV2` plus a migration stage; existing history is migrated,
/// never dropped.
enum HistorySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [CompletedRoundEntity.self, HistoryMetadataEntity.self] }

    @Model
    final class CompletedRoundEntity {
        @Attribute(.unique) var roundID: UUID
        var modeRaw: String
        var boardSizeRaw: Int
        var attempts: Int
        var hintsUsed: Int
        var pairCount: Int
        var startedAt: Date
        var completedAt: Date

        init(record: CompletionRecord) {
            roundID = record.roundID
            modeRaw = record.mode.rawValue
            boardSizeRaw = record.boardSize.rawValue
            attempts = record.attempts
            hintsUsed = record.hintsUsed
            pairCount = record.pairCount
            startedAt = record.startedAt
            completedAt = record.completedAt
        }

        var record: CompletionRecord? {
            guard let mode = GameMode(rawValue: modeRaw), let board = BoardSize(rawValue: boardSizeRaw) else { return nil }
            return CompletionRecord(summary: RoundSummary(
                roundID: roundID, configuration: GameConfiguration(mode: mode, boardSize: board), attempts: attempts,
                hintsUsed: hintsUsed, pairCount: pairCount, startedAt: startedAt, completedAt: completedAt))
        }
    }

    /// Aggregates and de-duplication memory, stored as one JSON payload.
    @Model
    final class HistoryMetadataEntity {
        @Attribute(.unique) var key: String
        var payload: Data

        init(key: String, payload: Data) {
            self.key = key
            self.payload = payload
        }
    }
}

enum HistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HistorySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias CompletedRoundEntity = HistorySchemaV1.CompletedRoundEntity
typealias HistoryMetadataEntity = HistorySchemaV1.HistoryMetadataEntity

/// SwiftData implementation of `CompletionHistoryStore`.
/// Mirrors `CompletionLedger` semantics (verified by the core test suite):
/// unique by round ID, newest 100 kept, aggregates survive trimming.
/// Used from the main thread only (AppModel and tests).
final class SwiftDataCompletionStore: CompletionHistoryStore {
    private static let metadataKey = "history"
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// Opens the on-disk store. If it cannot be opened (e.g. an unexpected
    /// schema), the file is left untouched for recovery and an in-memory store
    /// is used for this session, with a warning for the Parents screen.
    static func makeDefault() -> (SwiftDataCompletionStore, warning: String?) {
        let schema = Schema(versionedSchema: HistorySchemaV1.self)
        do {
            let directory = URL.applicationSupportDirectory.appending(path: "History", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "History.store"))
            let container = try ModelContainer(for: schema, migrationPlan: HistoryMigrationPlan.self, configurations: configuration)
            return (SwiftDataCompletionStore(container: container), nil)
        } catch {
            return (inMemory(), String(describing: error))
        }
    }

    static func inMemory() -> SwiftDataCompletionStore {
        let schema = Schema(versionedSchema: HistorySchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // In-memory creation only fails on programmer error.
        let container = try! ModelContainer(for: schema, migrationPlan: HistoryMigrationPlan.self, configurations: configuration)
        return SwiftDataCompletionStore(container: container)
    }

    @discardableResult
    func record(_ summary: RoundSummary) throws -> Bool {
        var metadata = try loadMetadata()
        let id = summary.roundID
        let existing = try context.fetchCount(FetchDescriptor<CompletedRoundEntity>(predicate: #Predicate { $0.roundID == id }))
        guard existing == 0, !metadata.knows(id) else { return false }

        let record = CompletionRecord(summary: summary)
        context.insert(CompletedRoundEntity(record: record))
        metadata.register(record)
        try saveMetadata(metadata)

        var descriptor = FetchDescriptor<CompletedRoundEntity>(sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        descriptor.fetchOffset = HistoryPolicy.maxRecentRecords
        for old in try context.fetch(descriptor) { context.delete(old) }
        try context.save()
        return true
    }

    func recentRecords() throws -> [CompletionRecord] {
        var descriptor = FetchDescriptor<CompletedRoundEntity>(sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        descriptor.fetchLimit = HistoryPolicy.maxRecentRecords
        return try context.fetch(descriptor).compactMap(\.record)
    }

    func totals() throws -> ProgressTotals { try loadMetadata().totals }

    func resetProgress() throws {
        try context.delete(model: CompletedRoundEntity.self)
        try context.delete(model: HistoryMetadataEntity.self)
        try context.save()
    }

    private func loadMetadata() throws -> HistoryMetadata {
        let key = Self.metadataKey
        let entity = try context.fetch(FetchDescriptor<HistoryMetadataEntity>(predicate: #Predicate { $0.key == key })).first
        guard let entity else { return HistoryMetadata() }
        // A damaged aggregate blob must not block play or delete records;
        // start fresh aggregates and keep the individual results.
        return (try? JSONDecoder().decode(HistoryMetadata.self, from: entity.payload)) ?? HistoryMetadata()
    }

    private func saveMetadata(_ metadata: HistoryMetadata) throws {
        let key = Self.metadataKey
        let payload = try JSONEncoder().encode(metadata)
        if let entity = try context.fetch(FetchDescriptor<HistoryMetadataEntity>(predicate: #Predicate { $0.key == key })).first {
            entity.payload = payload
        } else {
            context.insert(HistoryMetadataEntity(key: key, payload: payload))
        }
    }
}
