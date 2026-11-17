import AnimalPairsCore
import AVFoundation
import XCTest
@testable import AnimalPairs

/// Background music in the app: bundled loops, exact loop lengths with the
/// real decoder, one track per screen and the switches.
@MainActor
final class MusicAppTests: XCTestCase {
    func testAllFourLoopsAreBundledLoadAndHaveTheirExactLength() throws {
        let indexURL = try XCTUnwrap(Bundle.main.url(forResource: "music_tracks", withExtension: "json"))
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        let tracks = try XCTUnwrap(index?["tracks"] as? [String: [String: Any]])
        for track in AnimalPairsMusicTrack.allCases {
            let url = try XCTUnwrap(BackgroundMusicPlayer.url(for: track, in: .main), "\(track.rawValue).caf is not bundled")
            let expected = try XCTUnwrap(tracks[track.rawValue]?["frames"] as? Int)
            // The exact sample count, read with Apple's decoder: no padding, so
            // numberOfLoops = -1 repeats without a gap.
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Int(file.length), expected, "\(track): the loop would gap or click")
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertTrue(player.prepareToPlay(), "\(track) loads in AVAudioPlayer")
            XCTAssertEqual(player.duration, Double(expected) / 48_000, accuracy: 0.001)
        }
    }

    /// The reported bug: music plays, the app goes to the background (iOS may
    /// report the suspension as an interruption that never ends), and on
    /// return the music must resume from where it was on the same player.
    func testMusicResumesAfterSwitchingAppsFiveTimes() async throws {
        let model = AppTestSupport.makeModel()
        model.start()
        let music = model.audio.music
        XCTAssertEqual(music.currentTrack, .playground)
        let player = try XCTUnwrap(music.player(of: .playground))
        XCTAssertTrue(player.isPlaying)
        for round in 1...5 {
            model.scenePhaseChanged(.inactive)
            model.scenePhaseChanged(.background)
            music.interruptionBegan(suspended: round.isMultiple(of: 2))   // with and without the suspension flag
            XCTAssertFalse(player.isPlaying, "paused in the background")
            let position = player.currentTime
            model.scenePhaseChanged(.active)
            for _ in 0..<50 where !player.isPlaying { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(player.isPlaying, "round \(round): music resumed")
            XCTAssertEqual(player.currentTime, position, accuracy: 0.5, "resumed from the same position")
            XCTAssertTrue(music.player(of: .playground) === player, "the same player, never a second one")
            XCTAssertEqual(music.playingTracks, [.playground], "no overlap")
        }
    }

    func testMusicOffStaysOffAfterReturning() async throws {
        let model = AppTestSupport.makeModel()
        model.start()
        model.setMusicEnabled(false)
        model.scenePhaseChanged(.background)
        model.scenePhaseChanged(.active)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(model.audio.music.wantedTrack)
        XCTAssertTrue(model.audio.music.playingTracks.allSatisfy { model.audio.music.player(of: $0)?.volume ?? 0 == 0 },
                      "returning never switches music back on")
    }

    func testOneSceneAndTrackPerScreen() {
        XCTAssertEqual(AppModel.musicScene(for: .home), .menus)
        XCTAssertEqual(AppModel.musicScene(for: .setup), .menus)
        XCTAssertEqual(AppModel.musicScene(for: .game), .game)
        XCTAssertEqual(AppModel.musicScene(for: .parents), .parents)
        XCTAssertEqual(AppModel.musicScene(for: .parentGate), .parents)
        XCTAssertEqual(AppModel.musicScene(for: .opening), .silent)
    }

    func testHomeMusicContinuesIntoTheGame() throws {
        let model = AppTestSupport.makeModel()
        model.start()
        XCTAssertEqual(model.audio.music.scene, .menus)
        XCTAssertEqual(model.audio.music.wantedTrack, .playground)
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        XCTAssertEqual(model.audio.music.scene, .game)
        XCTAssertEqual(model.audio.music.wantedTrack, .playground, "the same loop continues into the game")
        model.restartCurrentGame()
        XCTAssertEqual(model.audio.music.wantedTrack, .playground, "a restart keeps the same track")
        XCTAssertEqual(model.audio.music.playingTracks, [.playground], "one track, never restarted")
        model.goHome()
        XCTAssertEqual(model.audio.music.wantedTrack, .playground)
    }

    func testMusicSwitchControlsOnlyTheMusic() {
        let model = AppTestSupport.makeModel()
        model.start()
        model.setMusicEnabled(false)
        XCTAssertNil(model.audio.music.wantedTrack)
        XCTAssertTrue(model.audio.isEnabled)
        model.setMusicEnabled(true)
        model.setSoundEnabled(false)
        XCTAssertEqual(model.audio.music.wantedTrack, .playground, "Sound Effects off keeps the music")
    }

    func testBackgroundSilencesAndActiveResumes() {
        let model = AppTestSupport.makeModel()
        model.start()
        model.scenePhaseChanged(.background)
        XCTAssertNil(model.audio.music.wantedTrack)
        model.scenePhaseChanged(.active)
        XCTAssertEqual(model.audio.music.wantedTrack, .playground)
    }

    func testInterruptionsHeadphonesAndOtherAppsKeepMusicQuiet() {
        let music = AppTestSupport.makeModel().audio.music
        music.enabled = true
        music.setScene(.game)
        music.interruptionBegan()
        XCTAssertNil(music.wantedTrack)
        music.interruptionEnded(shouldResume: true)
        XCTAssertEqual(music.wantedTrack, .playground)
        music.outputDeviceRemoved()
        XCTAssertNil(music.wantedTrack, "held after headphones are unplugged")
        music.setScene(.menus)
        XCTAssertEqual(music.wantedTrack, .playground, "back on the next screen")
        music.otherAudioChanged(playing: true)
        XCTAssertNil(music.wantedTrack, "no music over another app's audio")
        music.otherAudioChanged(playing: false)
        XCTAssertEqual(music.wantedTrack, .playground)
    }

    func testAnInterruptionThatNeverEndsDoesNotKeepMusicOffAfterReturning() {
        let model = AppTestSupport.makeModel()
        model.start()
        let music = model.audio.music
        music.interruptionBegan()                       // e.g. reported just before suspension
        model.scenePhaseChanged(.background)
        model.scenePhaseChanged(.active)                // no "ended" ever arrives
        XCTAssertEqual(music.wantedTrack, .playground, "the old bug: music stayed off for good")
        XCTAssertEqual(music.playingTracks, [.playground])
    }

    func testInterruptionWithoutResumeWaitsForTheNextScreen() {
        let model = AppTestSupport.makeModel()
        model.start()
        let music = model.audio.music
        music.interruptionBegan()
        music.interruptionEnded(shouldResume: false)
        XCTAssertNil(music.wantedTrack, "the system said not to resume")
        music.setScene(.game)                           // same track: still a user action
        model.goHome()
        XCTAssertEqual(music.wantedTrack, .playground)
    }
}
