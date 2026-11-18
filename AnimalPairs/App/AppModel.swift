import AnimalPairsCore
import Foundation
import Observation
import SwiftUI

enum Route: Equatable {
    /// The opening video, once per app launch.
    case opening
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
    private(set) var route: Route = .home {
        didSet {
            // One background track per screen; the same screen again (e.g. a
            // restarted round) keeps the music playing without a new player.
            let scene = Self.musicScene(for: route)
            if scene != Self.musicScene(for: oldValue) { audio.music.setScene(scene) }
        }
    }
    @ObservationIgnored private var musicObservers: [NSObjectProtocol] = []
    let settings: SettingsStore
    let localizer: Localizer
    let purchases: PurchaseManager
    let configuration: AppConfiguration
    private(set) var catalog: ContentCatalog
    private(set) var contentError: String?

    let history: CompletionHistoryStore
    private(set) var historyWarning: String?
    let snapshots: RoundSnapshotStore
    let audio: AudioManager

    private(set) var session: GameSession?
    /// A validated unfinished round that can be resumed from Home.
    private(set) var resumableRound: RoundState?
    private(set) var snapshotNotice: String?
    /// Incremented when history changes so the Parents screen refreshes.
    private(set) var historyRevision = 0
    private var parentAccess = ParentAccessSession()
    @ObservationIgnored private var resultsTask: Task<Void, Never>?

    /// `settings` defaults to `nil` and is created inside this @MainActor body
    /// (SettingsStore is main-actor isolated; see GameSession.init).
    init(settings: SettingsStore? = nil,
         configuration: AppConfiguration = .current,
         history: CompletionHistoryStore? = nil,
         historyWarning: String? = nil,
         snapshots: RoundSnapshotStore? = nil,
         contentBundle: Bundle = .main,
         playsOpeningVideo: Bool = true,
         audioSession: AudioSessionController? = nil) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        self.configuration = configuration
        // The opening video plays once per launch (never when returning from a
        // board); without the file, the app goes straight on.
        // Every launch (first launch included) then goes straight to Home.
        if playsOpeningVideo && OpeningVideo.url(in: contentBundle) != nil {
            route = .opening
        } else {
            route = .home
        }
        localizer = Localizer()
        purchases = PurchaseManager(productID: configuration.plusProductID)
        audio = AudioManager(isEnabled: settings.soundEnabled, voiceEnabled: settings.voiceEnabled,
                             musicEnabled: settings.musicEnabled, sessionController: audioSession)

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
        audio.loadAnimalClips(for: catalog.manifest.characters.map(\.id))
    }

    var policy: ContentAccessPolicy { ContentAccessPolicy(level: purchases.accessLevel) }

    func start() {
        purchases.start()
        refreshResumableRound()
        if musicObservers.isEmpty { musicObservers = audio.music.observeAudioSession() }
        audio.music.setScene(Self.musicScene(for: route))
        audio.start()            // the one launch-time session activation (off the main thread)
    }

    /// Background music for each screen (`MusicPolicy` picks the track).
    static func musicScene(for route: Route) -> MusicScene {
        switch route {
        case .opening: .silent                       // the video has its own soundtrack
        case .home, .setup: .menus
        case .game: .game
        case .results: .results
        case .parentGate, .parents: .parents
        }
    }

    // MARK: Settings

    /// The saved "Sound effects" setting (persisted by SettingsStore).
    func setSoundEnabled(_ enabled: Bool) {
        settings.soundEnabled = enabled
        audio.isEnabled = enabled
        if enabled { audio.play(.buttonTap) }
    }

    /// The speaker button on Home and the board: shows "on" while music or
    /// sound effects are on.
    var isAnySoundOn: Bool { settings.soundEnabled || settings.musicEnabled }

    /// The speaker button: everything off when anything is on, otherwise
    /// both back on. Each switch is still saved separately (Settings).
    func toggleAllSound() {
        let on = !isAnySoundOn
        setMusicEnabled(on)
        setSoundEnabled(on)
    }

    /// The saved "Music" setting: background tracks only (persisted by SettingsStore).
    func setMusicEnabled(_ enabled: Bool) {
        settings.musicEnabled = enabled
        audio.musicEnabled = enabled
    }

    /// True when the background tracks are bundled.
    var hasMusic: Bool { !audio.music.availableTracks.isEmpty }

    /// The opening video's audio plays only if Sound Effects or Music is on.
    var openingVideoAudible: Bool { settings.soundEnabled || settings.musicEnabled }

    /// Leaves the opening video for Home.
    func finishOpening() {
        guard route == .opening else { return }
        route = .home
        refreshResumableRound()
    }

    /// The saved "Voice" setting, independent of sound effects.
    func setVoiceEnabled(_ enabled: Bool) {
        settings.voiceEnabled = enabled
        audio.voiceEnabled = enabled
    }

    // MARK: Navigation

    func goHome() {
        audio.cancelPending()
        audio.play(.back)
        leaveGameIfNeeded()
        parentAccess.revoke()
        route = .home
        refreshResumableRound()
    }

    func goToSetup() {
        audio.cancelPending()
        audio.play(.buttonTap)
        leaveGameIfNeeded()
        route = .setup
    }

    // MARK: Game lifecycle

    enum StartError: Error { case locked, notEnoughContent }

    func startNewGame(_ configuration: GameConfiguration, startCueDelay: TimeInterval = 0) throws {
        guard policy.isAvailable(configuration) else { throw StartError.locked }
        audio.cancelPending()   // e.g. the Results jingle when tapping Play again
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
            attachSession(GameSession(state: state, catalog: catalog, audio: audio, localizer: localizer))
        }
        persist(state)
        route = .game
        if startCueDelay > 0 { audio.play(.gameStart, after: startCueDelay) } else { audio.play(.gameStart) }
        audio.narrate(.roundStarted, after: 1.3)
    }

    func resumeSavedGame() {
        guard let round = resumableRound else { return }
        attachSession(GameSession(state: round, catalog: catalog, audio: audio, localizer: localizer))
        resumableRound = nil
        route = .game
        audio.play(.gameStart)
        audio.narrate(.roundStarted, after: 1.3)
    }

    /// "Play again" after a completed round: the kind try_again cue, then the
    /// new round's game_start once it has finished (never overlapping).
    func playAgain(_ configuration: GameConfiguration) {
        do {
            try startNewGame(configuration, startCueDelay: 0.8)
            audio.play(.tryAgain)
        } catch {
            goToSetup()
        }
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
            if route == .opening { finishOpening() }   // never replay it on return
            audio.appDidEnterBackground()
        case .inactive:
            if let session, !session.state.isCompleted { persist(session.controller.normalizedState()) }
        case .active:
            if route == .home { refreshResumableRound() }
            // Codes redeemed or purchases approved outside the app.
            purchases.appBecameActive()
            audio.appDidBecomeActive()
        @unknown default:
            break
        }
    }

    // MARK: Parents area

    func openParentGate() {
        audio.play(.buttonTap)
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
        // Never pull the Parents area away while Apple's sheet is open or a
        // store action is finishing.
        guard !purchases.flowState.isBusy else { return }
        if route == .parents && !parentAccess.isActive() { route = .parentGate }
    }

    func leaveParents() {
        audio.play(.back)
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
