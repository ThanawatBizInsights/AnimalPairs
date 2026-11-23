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
        XCTAssertEqual(model.catalog.manifest.artworks.count, 80)
        XCTAssertFalse(model.catalog.manifest.artworks.contains { $0.poseID == "stretch" }, "Stretch is retired")
        XCTAssertTrue(model.catalog.missingArtworks.isEmpty, "every manifest resource is in the asset catalog")
        XCTAssertTrue(model.catalog.manifest.placeholderArtworks.isEmpty, "no development placeholders")
    }

    func testEveryPoseImageLoadsAsATransparentSquare() throws {
        let model = AppTestSupport.makeModel()
        for art in model.catalog.manifest.artworks {
            let image = try XCTUnwrap(UIImage(named: art.resourceName), "\(art.resourceName) is not in the asset catalog")
            XCTAssertEqual(image.size.width, image.size.height, "\(art.resourceName) must be square (never stretched)")
            let alpha = image.cgImage?.alphaInfo
            XCTAssertTrue(alpha != CGImageAlphaInfo.none && alpha != .noneSkipLast && alpha != .noneSkipFirst,
                          "\(art.resourceName) keeps its transparency")
        }
    }

    func testSpeakerButtonMutesEverythingAndRestoresParentsChoices() {
        let defaults = AppTestSupport.isolatedDefaults()
        let model = AppTestSupport.makeModel(defaults: defaults)
        // Parents: music off, effects and voice on.
        model.setMusicEnabled(false)
        XCTAssertTrue(model.isAnySoundOn)

        model.toggleAllSound()                          // mute
        XCTAssertFalse(model.isAnySoundOn)
        XCTAssertTrue(model.settings.allSoundMuted)
        XCTAssertTrue(model.audio.isMuted)
        XCTAssertFalse(model.audio.music.enabled, "no music while muted")
        XCTAssertFalse(model.audio.narrate(.roundStarted, after: 0), "no narration while muted")
        XCTAssertNil(model.audio.playMatchClip(for: model.catalog.manifest.characters.first?.id),
                     "no animal clip while muted")
        XCTAssertFalse(model.openingVideoAudible)
        // The Parents switches are untouched underneath.
        XCTAssertTrue(model.settings.soundEnabled)
        XCTAssertTrue(model.settings.voiceEnabled)
        XCTAssertFalse(model.settings.musicEnabled)

        // Mute survives a relaunch.
        XCTAssertFalse(AppTestSupport.makeModel(defaults: defaults).isAnySoundOn)

        model.toggleAllSound()                          // unmute restores exactly
        XCTAssertTrue(model.isAnySoundOn)
        XCTAssertFalse(model.audio.isMuted)
        XCTAssertTrue(model.settings.soundEnabled && model.settings.voiceEnabled)
        XCTAssertFalse(model.settings.musicEnabled, "music stays off as chosen in Parents")
        XCTAssertFalse(model.audio.music.enabled)
    }

    func testSpeakerButtonShowsOnWhenOnlyNarrationIsEnabled() {
        let model = AppTestSupport.makeModel()
        model.setMusicEnabled(false)
        model.setSoundEnabled(false)
        XCTAssertTrue(model.settings.voiceEnabled)
        XCTAssertTrue(model.isAnySoundOn, "narration alone is audible, so the icon shows sound on")
        model.toggleAllSound()
        XCTAssertFalse(model.isAnySoundOn)
        XCTAssertTrue(model.audio.isMuted)
    }

    func testSpeakerButtonWithEverySwitchOffTurnsThemOn() {
        let model = AppTestSupport.makeModel()
        model.setMusicEnabled(false)
        model.setSoundEnabled(false)
        model.setVoiceEnabled(false)
        XCTAssertFalse(model.isAnySoundOn)
        model.toggleAllSound()
        XCTAssertTrue(model.isAnySoundOn)
        XCTAssertTrue(model.settings.musicEnabled && model.settings.soundEnabled && model.settings.voiceEnabled)
    }

    func testTurningASwitchOnInParentsLiftsTheMute() {
        let model = AppTestSupport.makeModel()
        model.toggleAllSound()
        XCTAssertTrue(model.audio.isMuted)
        model.setMusicEnabled(true)
        XCTAssertFalse(model.audio.isMuted)
        XCTAssertTrue(model.isAnySoundOn)
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


    func testOpeningVideoIsBundledAndPlaysOncePerLaunch() throws {
        let url = try XCTUnwrap(OpeningVideo.url(), "opening_video.mp4 must be in the app target")
        XCTAssertGreaterThan(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1_000_000)

        let defaults = AppTestSupport.isolatedDefaults()
        let model = AppTestSupport.makeModel(defaults: defaults, playsOpeningVideo: true)
        XCTAssertEqual(model.route, .opening)
        model.finishOpening()
        XCTAssertEqual(model.route, .home, "first launch goes straight to Home after the video")
        model.finishOpening()
        XCTAssertEqual(model.route, .home, "finishing twice is harmless")

        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        model.goHome()
        XCTAssertEqual(model.route, .home, "returning from a board never replays the video")

        let nextLaunch = AppTestSupport.makeModel(defaults: defaults, playsOpeningVideo: true)
        XCTAssertEqual(nextLaunch.route, .opening)
        nextLaunch.finishOpening()
        XCTAssertEqual(nextLaunch.route, .home, "later launches go to Home after the video")
    }

    func testBackgroundingDuringTheVideoContinuesToHome() {
        let model = AppTestSupport.makeModel(playsOpeningVideo: true)
        model.scenePhaseChanged(.background)
        XCTAssertEqual(model.route, .home)
        model.scenePhaseChanged(.active)
        XCTAssertEqual(model.route, .home, "returning from the background stays on Home")
    }

    func testOpeningVideoAudioFollowsSoundAndMusicSettings() {
        let model = AppTestSupport.makeModel()
        XCTAssertTrue(model.settings.musicEnabled, "Music is on for a fresh install")
        XCTAssertTrue(model.hasMusic)
        XCTAssertTrue(model.openingVideoAudible)
        model.setSoundEnabled(false)
        XCTAssertTrue(model.openingVideoAudible, "Music is still on")
        model.setMusicEnabled(false)
        XCTAssertFalse(model.openingVideoAudible, "muted when both switches are off")
        model.setMusicEnabled(true)
        model.toggleAllSound()
        XCTAssertFalse(model.openingVideoAudible, "the speaker button's mute silences the video too")
    }

    func testMusicAndSoundEffectsAreSavedIndependently() {
        let defaults = AppTestSupport.isolatedDefaults()
        let model = AppTestSupport.makeModel(defaults: defaults)
        model.setMusicEnabled(false)
        XCTAssertFalse(model.audio.musicEnabled)
        XCTAssertTrue(model.audio.isEnabled, "Sound Effects unchanged")
        var relaunched = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertFalse(relaunched.settings.musicEnabled)
        XCTAssertFalse(relaunched.audio.musicEnabled)
        XCTAssertTrue(relaunched.settings.soundEnabled)
        relaunched.setSoundEnabled(false)
        relaunched.setMusicEnabled(true)
        relaunched = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertTrue(relaunched.settings.musicEnabled)
        XCTAssertFalse(relaunched.settings.soundEnabled)
        XCTAssertTrue(relaunched.settings.voiceEnabled)
    }

    func testAnExistingExplicitMusicChoiceIsKept() {
        let defaults = AppTestSupport.isolatedDefaults()
        defaults.set(false, forKey: "settings.musicEnabled")      // chosen before this version
        XCTAssertFalse(AppTestSupport.makeModel(defaults: defaults).settings.musicEnabled)
        XCTAssertTrue(AppTestSupport.makeModel().settings.musicEnabled, "fresh install: on")
    }

    func testApprovedInterfaceAndRewardSoundsAreBundled() {
        let audio = AudioManager(isEnabled: false, voiceEnabled: false)
        for effect: SoundEffect in [.modeSelect, .back, .pause, .resume, .starEarn, .badgeReveal,
                                    .perfectRound, .confetti, .hint, .tryAgain, .newBest] {
            XCTAssertEqual(audio.resolvedFiles[effect], "\(effect.rawValue).wav", "\(effect) should play its own file")
        }
        XCTAssertTrue(audio.loadedVoiceLines.isEmpty, "no voice recordings are bundled")
    }

    func testEveryLaunchOpensHomeWithoutAnIntroductionPage() {
        // Fresh install (empty settings), ordinary relaunch, and an install
        // that still carries the old "seen the introduction" flag.
        let defaults = AppTestSupport.isolatedDefaults()
        let fresh = AppTestSupport.makeModel(defaults: defaults)
        XCTAssertEqual(fresh.route, .home)
        XCTAssertEqual(AppTestSupport.makeModel(defaults: defaults).route, .home)
        let upgraded = AppTestSupport.isolatedDefaults()
        upgraded.set(false, forKey: "settings.hasSeenWelcome")
        XCTAssertEqual(AppTestSupport.makeModel(defaults: upgraded).route, .home)
        XCTAssertNil(upgraded.object(forKey: "settings.hasSeenWelcome"), "the retired flag is cleaned up")
        let afterVideo = AppTestSupport.makeModel(defaults: AppTestSupport.isolatedDefaults(), playsOpeningVideo: true)
        afterVideo.finishOpening()
        XCTAssertEqual(afterVideo.route, .home)
    }

    func testFreePlayersCanPlayClassicSixAndTwelveButNothingElse() throws {
        let model = AppTestSupport.makeModel()
        guard !model.purchases.isUnlocked else { throw XCTSkip("simulator already holds Full Game Unlock") }
        // Free and unlimited: Classic with 6 or 12 cards, as many times as
        // a child likes, with no purchase step in between.
        for _ in 0..<3 {
            for size in [BoardSize.six, .twelve] {
                XCTAssertNoThrow(try model.startNewGame(GameConfiguration(mode: .classic, boardSize: size)))
                XCTAssertEqual(model.route, .game)
                XCTAssertEqual(model.session?.state.tiles.count, size.rawValue)
            }
        }
        XCTAssertEqual(model.purchases.flowState, .idle, "playing never starts a purchase")
        // Locked options never start a game (and never open a purchase sheet:
        // Setup shows the "ask a grown-up" message instead).
        var locked = [GameConfiguration(mode: .classic, boardSize: .sixteen),
                      GameConfiguration(mode: .classic, boardSize: .twenty)]
        locked += BoardSize.allCases.map { GameConfiguration(mode: .exactPose, boardSize: $0) }
        for config in locked {
            XCTAssertThrowsError(try model.startNewGame(config), "\(config)") { error in
                XCTAssertEqual(error as? AppModel.StartError, .locked)
            }
        }
        XCTAssertEqual(model.purchases.flowState, .idle)
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
