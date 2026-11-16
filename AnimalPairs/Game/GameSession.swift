import AnimalPairsCore
import Foundation
import Observation
import SwiftUI

/// Observable wrapper around the pure `RoundController` for one board.
@MainActor
@Observable
final class GameSession {
    private(set) var state: RoundState
    private(set) var highlightedTiles: Set<TileID> = []
    /// Pause overlay visibility. The controller is paused whenever this is true.
    private(set) var isPauseMenuVisible = false

    let controller: RoundController
    private let audio: AudioManager
    private let localizer: Localizer
    private let catalog: ContentCatalog
    @ObservationIgnored var onCompleted: ((RoundSummary) -> Void)?
    /// Called when the round reaches a state worth saving.
    @ObservationIgnored var onSettled: ((RoundState) -> Void)?

    /// `scheduler` defaults to `nil` and is resolved inside this @MainActor
    /// body: in Swift 5 mode default arguments are evaluated nonisolated, so a
    /// `= TaskRoundScheduler()` default cannot call its main-actor initializer.
    init(state: RoundState, catalog: ContentCatalog, audio: AudioManager, localizer: Localizer,
         scheduler: RoundScheduler? = nil) {
        self.state = state
        self.catalog = catalog
        self.audio = audio
        self.localizer = localizer
        controller = RoundController(state: state, scheduler: scheduler ?? TaskRoundScheduler())
        controller.onChange = { [weak self] in self?.sync() }
        controller.onEvent = { [weak self] in self?.handle($0) }
    }

    var configuration: GameConfiguration { state.configuration }

    func artwork(for tile: Tile) -> ArtworkDefinition? { catalog.artwork(tile.pairKey) }

    func tap(_ id: TileID) { controller.tap(id) }
    func hint() { controller.requestHint() }

    func showPauseMenu() {
        audio.cancelPending()
        audio.stopAnimalClip()
        controller.pause()
        isPauseMenuVisible = true
        audio.play(.pause)
    }

    func resumeFromPauseMenu() {
        isPauseMenuVisible = false
        controller.resume()
        audio.play(.resume)
    }

    /// Backgrounding: pause + normalize; the pause menu greets the child on return.
    func pauseForBackground() {
        audio.cancelPending()
        audio.stopAnimalClip()
        guard !state.isCompleted else { return }
        controller.pause()
        isPauseMenuVisible = true
    }

    func restart(with newState: RoundState) {
        audio.cancelPending()
        audio.stopAnimalClip()
        isPauseMenuVisible = false
        controller.replaceRound(with: newState)
    }

    func end() {
        audio.cancelPending()
        // Leaving for the results screen: let the last animal clip fade out.
        audio.stopAnimalClip(fadeDuration: 0.3)
        controller.tearDown()
    }

    private func sync() {
        state = controller.state
        highlightedTiles = controller.highlightedTiles
        if state.pendingResolution == nil && !state.isCompleted {
            onSettled?(state)
        }
    }

    /// Delay before the gentle "not a pair" cue, so the second card's flip is
    /// heard first. Cancelled if the round is paused, restarted or left.
    static let missCueDelay: TimeInterval = 0.35
    /// An occasional spoken line starts as the pair-match chime fades, so the
    /// two never sound at full level together.
    static let followUpDelay: TimeInterval = 0.75

    /// The animal shown on a tile (the same for every one of its poses).
    func character(of tileID: TileID) -> CharacterID? {
        controller.state.tile(tileID).flatMap { catalog.artwork($0.pairKey)?.characterID }
    }

    /// Event → sound mapping (see README "Sound effects").
    private func handle(_ event: RoundEvent) {
        // Events produced while pausing (normalizing a pending pair) stay quiet.
        let quiet = controller.state.isPaused
        switch event {
        case .revealed:
            // First and second card alike: only the short generic flip.
            audio.play(.cardFlip)
            if let pending = controller.state.pendingResolution, !pending.isMatch,
               !audio.narrate(.missed, after: Self.missCueDelay) {
                audio.play(.pairMiss, after: Self.missCueDelay)
            }
        case .matched(let key):
            let character = catalog.artwork(key)?.characterID
            if !quiet {
                // Once per completed pair (the last one too): one of the matched
                // animal's own clips, played short. The chime plays softer under it.
                let clip = audio.playMatchClip(for: character)
                // The final pair gets board_complete instead, never both at once.
                if !controller.state.isCompleted {
                    audio.play(.pairMatch, level: clip == nil ? 1 : AudioManager.levelUnderAnimalClip)
                    if clip == nil { audio.narrate(.matched, after: Self.followUpDelay) }
                }
            }
            if let art = catalog.artwork(key) {
                announce(localizer("a11y.announce.match", ArtworkText.description(art, localizer)))
            }
        case .mismatchCovered:
            if !quiet { audio.play(.cardClose) }
            announce(localizer["a11y.announce.mismatch"])
        case .hintShown:
            audio.play(.hint)
            announce(localizer["a11y.announce.hint"])
        case .tapIgnored:
            break
        case .completed(let summary):
            // A round with no misses gets the slightly bigger celebration.
            audio.play(summary.attempts == summary.pairCount ? .perfectRound : .boardComplete,
                       level: audio.isAnimalClipPlaying ? AudioManager.levelUnderAnimalClip : 1)
            onCompleted?(summary)
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Localized descriptions of characters and artworks.
enum ArtworkText {
    @MainActor
    static func description(_ art: ArtworkDefinition, _ l10n: Localizer) -> String {
        l10n[art.accessibilityKey]
    }

    @MainActor
    static func characterName(_ id: CharacterID, _ l10n: Localizer) -> String {
        l10n["character.\(id.rawValue).name"]
    }
}
