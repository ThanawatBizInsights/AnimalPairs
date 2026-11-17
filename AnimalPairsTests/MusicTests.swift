import AnimalPairsCore
import AVFoundation
import XCTest
@testable import AnimalPairs

/// Background music in the app: bundled loops, exact loop lengths with the
/// real decoder, one track per screen and the switches.
@MainActor
final class MusicAppTests: XCTestCase {
    func testAllFourLoopsAreBundledAndDecodeToTheirExactLength() throws {
        let indexURL = try XCTUnwrap(Bundle.main.url(forResource: "music_tracks", withExtension: "json"))
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        let tracks = try XCTUnwrap(index?["tracks"] as? [String: [String: Any]])
        for track in AnimalPairsMusicTrack.allCases {
            let url = try XCTUnwrap(BackgroundMusicPlayer.url(for: track, in: .main), "\(track.rawValue).m4a is not bundled")
            let expected = try XCTUnwrap(tracks[track.rawValue]?["frames"] as? Int)
            let decoded = try MusicBuffer(url: url, expectedFrames: expected)
            XCTAssertEqual(Int(decoded.buffer.frameLength), expected, "\(track): a gap or click at the loop join")
            XCTAssertGreaterThan(decoded.buffer.format.sampleRate, 0)
        }
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
        model.audio.music.decode = BackgroundMusicPlayer.decodeImmediately
        model.start()
        XCTAssertEqual(model.audio.music.scene, .menus)
        XCTAssertEqual(model.audio.music.wantedTrack, .playground)
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        XCTAssertEqual(model.audio.music.scene, .game)
        XCTAssertEqual(model.audio.music.wantedTrack, .playground, "the same loop continues into the game")
        model.restartCurrentGame()
        XCTAssertEqual(model.audio.music.wantedTrack, .playground, "a restart keeps the same track")
        XCTAssertLessThanOrEqual(model.audio.music.playingTracks.count, 2, "only two decks exist")
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
        music.interruptionEnded()
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
}
