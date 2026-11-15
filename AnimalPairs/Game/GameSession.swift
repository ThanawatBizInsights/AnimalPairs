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
    private let sounds: SoundPlayer
    private let localizer: Localizer
    private let catalog: ContentCatalog
    @ObservationIgnored var onCompleted: ((RoundSummary) -> Void)?
    /// Called when the round reaches a state worth saving.
    @ObservationIgnored var onSettled: ((RoundState) -> Void)?

    init(state: RoundState, catalog: ContentCatalog, sounds: SoundPlayer, localizer: Localizer,
         scheduler: RoundScheduler = TaskRoundScheduler()) {
        self.state = state
        self.catalog = catalog
        self.sounds = sounds
        self.localizer = localizer
        controller = RoundController(state: state, scheduler: scheduler)
        controller.onChange = { [weak self] in self?.sync() }
        controller.onEvent = { [weak self] in self?.handle($0) }
    }

    var configuration: GameConfiguration { state.configuration }

    func artwork(for tile: Tile) -> ArtworkDefinition? { catalog.artwork(tile.pairKey) }

    func tap(_ id: TileID) { controller.tap(id) }
    func hint() { controller.requestHint() }

    func showPauseMenu() {
        controller.pause()
        isPauseMenuVisible = true
        sounds.play(.tap)
    }

    func resumeFromPauseMenu() {
        isPauseMenuVisible = false
        controller.resume()
    }

    /// Backgrounding: pause + normalize; the pause menu greets the child on return.
    func pauseForBackground() {
        guard !state.isCompleted else { return }
        controller.pause()
        isPauseMenuVisible = true
    }

    func restart(with newState: RoundState) {
        isPauseMenuVisible = false
        controller.replaceRound(with: newState)
    }

    func end() {
        controller.tearDown()
    }

    private func sync() {
        state = controller.state
        highlightedTiles = controller.highlightedTiles
        if state.pendingResolution == nil && !state.isCompleted {
            onSettled?(state)
        }
    }

    private func handle(_ event: RoundEvent) {
        switch event {
        case .revealed:
            sounds.play(.flip)
        case .matched(let key):
            sounds.play(.match)
            if let art = catalog.artwork(key) {
                announce(localizer("a11y.announce.match", ArtworkText.description(art, localizer)))
            }
        case .mismatchCovered:
            sounds.play(.mismatch)
            announce(localizer["a11y.announce.mismatch"])
        case .hintShown:
            sounds.play(.hint)
            announce(localizer["a11y.announce.hint"])
        case .tapIgnored:
            break
        case .completed(let summary):
            sounds.play(.complete)
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
