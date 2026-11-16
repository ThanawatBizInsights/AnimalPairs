import AnimalPairsCore
import SwiftUI
import UIKit
import XCTest
@testable import AnimalPairs

@MainActor
final class AppFlowTests: XCTestCase {
    func testBundledContentIsCompleteAndLoaded() {
        let model = AppTestSupport.makeModel()
        XCTAssertNil(model.contentError)
        XCTAssertEqual(model.catalog.manifest.artworks.count, 30)
        XCTAssertTrue(model.catalog.missingArtworks.isEmpty, "every manifest resource is in the asset catalog")
    }

    func testInterfaceGraphicsAndIconAreBundled() {
        for name in BrandGraphic.all {
            XCTAssertNotNil(UIImage(named: name), "missing UI graphic \(name)")
        }
    }

    func testSoundEffectsSettingIsSavedAndApplied() {
        let defaults = AppTestSupport.isolatedDefaults()
        let model = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertTrue(model.settings.soundEnabled, "on by default")
        XCTAssertTrue(model.audio.isEnabled)
        model.setSoundEnabled(false)
        XCTAssertFalse(model.audio.isEnabled)
        let relaunched = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertFalse(relaunched.settings.soundEnabled, "the choice survives a relaunch")
        XCTAssertFalse(relaunched.audio.isEnabled)
    }

    func testEffectsPlayTheirFileAFallbackOrStaySilentUntilApproved() {
        let audio = AudioManager(isEnabled: false, voiceEnabled: false)
        for effect in SoundEffect.allCases where !effect.fallbackFiles.isEmpty {
            XCTAssertTrue(audio.loadedEffects.contains(effect), "\(effect) should have its file or a fallback")
        }
        // Batch 1 is approved: these play their own generated files.
        for effect: SoundEffect in [.cardFlip, .cardClose, .pairMatch, .pairMiss, .boardComplete,
                                    .buttonTap, .gameStart, .completionJingle] {
            XCTAssertEqual(audio.resolvedFiles[effect], "\(effect.rawValue).wav")
        }
    }

    func testAnimalCueIsSharedByAllPosesOfACharacter() {
        let model = AppTestSupport.makeModel()
        for character in model.catalog.manifest.characters {
            let cue = SoundEffect.animal(character.id)
            XCTAssertNotNil(cue, "\(character.id) needs an animal cue")
            let poses = model.catalog.manifest.artworks.filter { $0.characterID == character.id }
            XCTAssertEqual(Set(poses.compactMap { SoundEffect.animal($0.characterID) }), [cue!])
        }
        XCTAssertEqual(SoundEffect.animal("iris"), .animalIris)
    }

    func testVoiceSwitchIsSavedSeparatelyFromSoundEffects() {
        let defaults = AppTestSupport.isolatedDefaults()
        let model = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertTrue(model.settings.voiceEnabled)
        model.setVoiceEnabled(false)
        XCTAssertFalse(model.audio.voiceEnabled)
        XCTAssertTrue(model.audio.isEnabled, "sound effects are unaffected")
        let relaunched = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertFalse(relaunched.settings.voiceEnabled)
        XCTAssertTrue(relaunched.settings.soundEnabled)
    }


    func testWelcomeShowsOnFirstLaunchOnly() {
        let defaults = AppTestSupport.isolatedDefaults()
        let first = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertEqual(first.route, .welcome)
        first.finishWelcome()
        XCTAssertEqual(first.route, .home)
        let second = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertEqual(second.route, .home)
    }

    func testStarterCanStartFreeBoardsButNotPremium() throws {
        let model = AppTestSupport.makeModel()
        guard !model.purchases.isUnlocked else { throw XCTSkip("simulator already holds the unlock") }
        XCTAssertNoThrow(try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .twelve)))
        XCTAssertEqual(model.route, .game)
        XCTAssertEqual(model.session?.state.tiles.count, 12)
        XCTAssertThrowsError(try model.startNewGame(GameConfiguration(mode: .exactPose, boardSize: .six)))
        XCTAssertThrowsError(try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .twenty)))
    }

    func testBackgroundPausesSavesAndResumesWithoutReshuffle() throws {
        let directory = AppTestSupport.temporaryDirectory()
        let model = AppTestSupport.makeModel(snapshotDirectory: directory)
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        let session = try XCTUnwrap(model.session)
        let firstTile = session.state.tiles[0].id
        session.tap(firstTile)

        model.scenePhaseChanged(.background)
        XCTAssertTrue(session.state.isPaused)
        XCTAssertTrue(session.isPauseMenuVisible)

        // A fresh launch restores the same round, same order, same open card.
        let relaunched = AppTestSupport.makeModel(snapshotDirectory: directory)
        relaunched.refreshResumableRound()
        let restored = try XCTUnwrap(relaunched.resumableRound)
        XCTAssertEqual(restored.roundID, session.state.roundID)
        XCTAssertEqual(restored.tiles.map(\.id), session.state.tiles.map(\.id))
        XCTAssertEqual(restored.phase, .oneRevealed(firstTile))
        relaunched.resumeSavedGame()
        XCTAssertEqual(relaunched.route, .game)
        XCTAssertEqual(relaunched.session?.state.tiles.map(\.pairKey), session.state.tiles.map(\.pairKey))
    }

    func testCorruptSnapshotDoesNotTouchHistory() throws {
        let directory = AppTestSupport.temporaryDirectory()
        let history = SwiftDataCompletionStore.inMemory()
        try history.record(AppTestSupport.summary(1))
        try Data("garbage".utf8).write(to: directory.appendingPathComponent(RoundSnapshotStore.fileName))
        let model = AppTestSupport.makeModel(snapshotDirectory: directory, history: history)
        model.refreshResumableRound()
        XCTAssertNil(model.resumableRound)
        XCTAssertNotNil(model.snapshotNotice)
        XCTAssertEqual(try history.recentRecords().count, 1, "completed history is never deleted")
    }

    func testResetProgressKeepsPurchases() throws {
        let model = AppTestSupport.makeModel()
        try model.history.record(AppTestSupport.summary(1))
        let before = model.purchases.accessLevel
        model.resetProgress()
        XCTAssertTrue(try model.history.recentRecords().isEmpty)
        XCTAssertEqual(model.purchases.accessLevel, before)
    }

    func testParentAccessExpiresWhenLeavingOrBackgrounding() {
        let model = AppTestSupport.makeModel()
        model.openParentGate()
        XCTAssertEqual(model.route, .parentGate)
        model.parentGatePassed()
        XCTAssertEqual(model.route, .parents)
        model.scenePhaseChanged(.background)
        XCTAssertEqual(model.route, .home)
        model.parentGatePassed()
        model.leaveParents()
        model.validateParentAccess()
        XCTAssertEqual(model.route, .home)
    }

    func testCoveredCardLabelsNeverRevealTheAnimal() throws {
        let model = AppTestSupport.makeModel()
        let names = model.catalog.manifest.characters.map { model.localizer["character.\($0.id.rawValue).name"] }
        let poseWords = ["playing", "napping", "waving"]
        for art in model.catalog.manifest.artworks {
            let covered = CardAccessibility.label(face: .covered, artwork: art, position: CardPosition(index: 0, row: 0, column: 0),
                                                  highlighted: true, localizer: model.localizer)
            XCTAssertFalse(names.contains { covered.contains($0) }, covered)
            XCTAssertFalse(poseWords.contains { covered.contains($0) }, covered)

            let revealed = CardAccessibility.label(face: .revealed, artwork: art, position: CardPosition(index: 0, row: 0, column: 0),
                                                   highlighted: false, localizer: model.localizer)
            XCTAssertTrue(revealed.contains(model.localizer[art.accessibilityKey]), "revealed names animal and pose")
        }
    }

    func testTextIsEnglish() {
        let localizer = Localizer()
        XCTAssertEqual(localizer["home.play"], "Play")
        XCTAssertEqual(localizer("board.progress", 2, 6), "2 of 6 pairs")
        XCTAssertEqual(localizer["character.iris.name"], "Iris")
        XCTAssertEqual(localizer.locale.language.languageCode, .english)
    }

    func testBundleShipsEnglishOnly() {
        XCTAssertEqual(Bundle.main.localizations.filter { $0 != "Base" }, ["en"])
    }
}
