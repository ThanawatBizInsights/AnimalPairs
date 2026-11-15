import AnimalPairsCore
import Foundation
import Observation
import SwiftUI

enum Route: Equatable {
    /// First launch only.
    case welcome
    case home
    case setup
    case game
    case results(RoundSummary)
    case parentGate
    case parents
}

/// Root state and navigation. Owns long-lived services and the current game.
@MainActor
@Observable
final class AppModel {
    private(set) var route: Route = .home
    let settings: SettingsStore
    let localizer: Localizer
    let purchases: PurchaseManager
    let configuration: AppConfiguration
    private(set) var catalog: ContentCatalog
    private(set) var contentError: String?

    let history: CompletionHistoryStore
    private(set) var historyWarning: String?
    let snapshots: RoundSnapshotStore
    let sounds: SoundPlayer

    private(set) var session: GameSession?
    /// A validated unfinished round that can be resumed from Home.
    private(set) var resumableRound: RoundState?
    private(set) var snapshotNotice: String?
    /// Incremented when history changes so the Parents screen refreshes.
    private(set) var historyRevision = 0
    private var parentAccess = ParentAccessSession()
    @ObservationIgnored private var resultsTask: Task<Void, Never>?

    init(settings: SettingsStore = SettingsStore(),
         configuration: AppConfiguration = .current,
         history: CompletionHistoryStore? = nil,
         historyWarning: String? = nil,
         snapshots: RoundSnapshotStore? = nil,
         contentBundle: Bundle = .main) {
        self.settings = settings
        self.configuration = configuration
        route = settings.hasSeenWelcome ? .home : .welcome
        localizer = Localizer()
        purchases = PurchaseManager(productID: configuration.fullUnlockProductID)
        sounds = SoundPlayer(isEnabled: settings.soundEnabled)

        if let history {
            self.history = history
            self.historyWarning = historyWarning
        } else {
            let (store, warning) = SwiftDataCompletionStore.makeDefault()
            self.history = store
            self.historyWarning = warning
        }
        self.snapshots = snapshots ?? RoundSnapshotStore(
            directory: URL.applicationSupportDirectory.appending(path: "Rounds", directoryHint: .isDirectory))

        let repository = BundledContentRepository(bundle: contentBundle)
        do {
            let manifest = try repository.loadManifestSync()
            catalog = ContentCatalog(manifest: manifest, installedAssets: repository.installedAssetsSync(for: manifest))
        } catch {
            catalog = ContentCatalog(manifest: ArtworkManifest(manifestVersion: "missing", characters: [], artworks: []),
                                     installedAssets: [])
            contentError = String(describing: error)
        }
    }

    var policy: ContentAccessPolicy { ContentAccessPolicy(level: purchases.accessLevel) }

    func start() {
        purchases.start()
        refreshResumableRound()
    }

    // MARK: Settings

    func setSoundEnabled(_ enabled: Bool) {
        settings.soundEnabled = enabled
        sounds.isEnabled = enabled
        if enabled { sounds.play(.tap) }
    }

    // MARK: Navigation

    func goHome() {
        leaveGameIfNeeded()
        parentAccess.revoke()
        route = .home
        refreshResumableRound()
    }

    func finishWelcome() {
        settings.hasSeenWelcome = true
        route = .home
        refreshResumableRound()
    }

    func goToSetup() {
        leaveGameIfNeeded()
        route = .setup
    }

    // MARK: Game lifecycle

    enum StartError: Error { case locked, notEnoughContent }

    func startNewGame(_ configuration: GameConfiguration) throws {
        guard policy.isAvailable(configuration) else { throw StartError.locked }
        var generator = SystemRandomNumberGenerator()
        let tiles: [Tile]
        do {
            tiles = try DeckBuilder.makeBoard(configuration: configuration, catalog: catalog, policy: policy, using: &generator)
        } catch {
            throw StartError.notEnoughContent
        }
        settings.lastConfiguration = configuration
        let state = RoundState(configuration: configuration, tiles: tiles)
        if let session {
            session.restart(with: state)
        } else {
            attachSession(GameSession(state: state, catalog: catalog, sounds: sounds, localizer: localizer))
        }
        persist(state)
        route = .game
    }

    func resumeSavedGame() {
        guard let round = resumableRound else { return }
        attachSession(GameSession(state: round, catalog: catalog, sounds: sounds, localizer: localizer))
        resumableRound = nil
        route = .game
    }

    func restartCurrentGame() {
        guard let configuration = session?.configuration else { return }
        try? startNewGame(configuration)
    }

    private func attachSession(_ newSession: GameSession) {
        session?.end()
        resultsTask?.cancel()
        newSession.onSettled = { [weak self] state in self?.persist(state) }
        newSession.onCompleted = { [weak self, weak newSession] summary in
            guard let self, let newSession else { return }
            self.complete(summary, from: newSession)
        }
        session = newSession
    }

    private func leaveGameIfNeeded() {
        resultsTask?.cancel()
        guard let session else { return }
        if !session.state.isCompleted { persist(session.controller.normalizedState()) }
        session.end()
        self.session = nil
    }

    private func complete(_ summary: RoundSummary, from finished: GameSession) {
        do {
            try history.record(summary)
        } catch {
            historyWarning = String(describing: error)
        }
        historyRevision += 1
        try? snapshots.clear()
        resultsTask?.cancel()
        resultsTask = Task { [weak self] in
            // Let the last pair's celebration play before the results screen.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let self, !Task.isCancelled, self.session === finished else { return }
            finished.end()
            self.session = nil
            self.route = .results(summary)
        }
    }

    private func persist(_ state: RoundState) {
        do {
            try snapshots.save(state: state, manifestVersion: catalog.manifest.manifestVersion)
        } catch {
            snapshotNotice = String(describing: error)
        }
    }

    func refreshResumableRound() {
        guard session == nil else { return }
        switch snapshots.load(catalog: catalog, policy: policy) {
        case .none:
            resumableRound = nil
        case .restored(let round):
            resumableRound = round
        case .rejected(let error):
            resumableRound = nil
            snapshotNotice = String(describing: error)
        }
    }

    // MARK: Scene phase

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if let session, !session.state.isCompleted {
                session.pauseForBackground()
                persist(session.controller.normalizedState())
            }
            parentAccess.revoke()
            if route == .parents || route == .parentGate { route = .home }
        case .inactive:
            if let session, !session.state.isCompleted { persist(session.controller.normalizedState()) }
        case .active:
            if route == .home { refreshResumableRound() }
        @unknown default:
            break
        }
    }

    // MARK: Parents area

    func openParentGate() {
        leaveGameIfNeeded()
        parentAccess.revoke()
        route = .parentGate
    }

    func parentGatePassed() {
        parentAccess.grant()
        route = .parents
    }

    /// Re-checks the timeout; sends the adult back to the gate when expired.
    func validateParentAccess() {
        if route == .parents && !parentAccess.isActive() { route = .parentGate }
    }

    func leaveParents() {
        parentAccess.revoke()
        route = .home
        refreshResumableRound()
    }

    func resetProgress() {
        try? history.resetProgress()
        try? snapshots.clear()
        resumableRound = nil
        historyRevision += 1
        // Purchases are deliberately untouched.
    }
}
