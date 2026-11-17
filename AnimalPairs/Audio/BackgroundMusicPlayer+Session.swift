import AVFoundation
import Foundation

/// Connects `BackgroundMusicPlayer` to the system (observers only; this file
/// never configures or activates the session — see AudioSessionController): audio interruptions (calls, alarms,
/// Siri), headphones being unplugged, other apps starting or stopping audio,
/// and engine configuration changes. Observers run on the main queue.
extension BackgroundMusicPlayer {
    func observeAudioSession() -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        otherAudioChanged(playing: session.secondaryAudioShouldBeSilencedHint)
        return [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                               queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    switch type {
                    case .began: self?.interruptionBegan()
                    case .ended: self?.interruptionEnded()   // ambient music may always resume
                    default: break
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                               queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                if reason == .oldDeviceUnavailable {
                    MainActor.assumeIsolated { self?.outputDeviceRemoved() }
                }
            },
            center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session,
                               queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:))
                MainActor.assumeIsolated { self?.otherAudioChanged(playing: type == .begin) }
            },
            // Only OUR engine: with `object: nil` a change in any audio engine
            // in the process restarted the music (and its session activation).
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engineForNotifications,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engineConfigurationChanged() }
            },
        ]
    }
}
