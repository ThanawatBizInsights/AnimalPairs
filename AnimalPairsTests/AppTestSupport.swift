import AnimalPairsCore
import Foundation
@testable import AnimalPairs

@MainActor
enum AppTestSupport {
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnimalPairsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isolatedDefaults() -> UserDefaults {
        let name = "AnimalPairsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// An AppModel wired to temporary, isolated storage.
    static func makeModel(snapshotDirectory: URL? = nil,
                          history: CompletionHistoryStore? = nil,
                          defaults: UserDefaults? = nil,
                          playsOpeningVideo: Bool = false) -> AppModel {
        AppModel(settings: SettingsStore(defaults: defaults ?? isolatedDefaults()),
                 configuration: AppConfiguration(fullUnlockProductID: AppConfiguration.placeholderProductID,
                                                 privacyPolicyURL: nil, supportURL: nil),
                 history: history ?? SwiftDataCompletionStore.inMemory(),
                 snapshots: RoundSnapshotStore(directory: snapshotDirectory ?? temporaryDirectory()),
                 playsOpeningVideo: playsOpeningVideo)
    }

    static func summary(_ i: Int, id: UUID = UUID()) -> RoundSummary {
        RoundSummary(roundID: id, configuration: GameConfiguration(mode: .classic, boardSize: .six),
                     attempts: 4, hintsUsed: 1, pairCount: 3,
                     startedAt: Date(timeIntervalSince1970: Double(i) * 100),
                     completedAt: Date(timeIntervalSince1970: Double(i) * 100 + 50))
    }
}
