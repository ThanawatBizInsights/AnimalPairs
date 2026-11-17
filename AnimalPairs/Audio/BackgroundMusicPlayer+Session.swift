import AVFoundation
import Foundation

/// Connects `BackgroundMusicPlayer` to the system. Observers only — this file
/// never configures, activates or deactivates the session (see
/// AudioSessionController). Registered once by `AppModel.start()`; all run on
/// the main queue.
extension BackgroundMusicPlayer {
    /// `AVAudioSession.InterruptionReason.appWasSuspended` (deprecated, so its
    /// raw value is used) and the older "was suspended" flag: iOS reporting the
    /// app's own suspension as an interruption that will never "end".
    nonisolated static let suspendedReasonRawValue: UInt = 1
    nonisolated static let wasSuspendedKey = "AVAudioSessionInterruptionWasSuspendedKey"

    func observeAudioSession() -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        otherAudioChanged(playing: session.secondaryAudioShouldBeSilencedHint)
        return [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                               queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let suspended = (info[AVAudioSessionInterruptionReasonKey] as? UInt) == Self.suspendedReasonRawValue
                    || (info[Self.wasSuspendedKey] as? Bool) == true
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                MainActor.assumeIsolated {
                    switch type {
                    case .began: self?.interruptionBegan(suspended: suspended)
                    case .ended: self?.interruptionEnded(shouldResume: options.contains(.shouldResume))
                    default: break
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                               queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                // Headphones or a Bluetooth device went away: pause (Apple's
                // guideline), never blare on the speaker.
                if reason == .oldDeviceUnavailable {
                    MainActor.assumeIsolated { self?.outputDeviceRemoved() }
                }
            },
            center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session,
                               queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt)
                    .flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:))
                MainActor.assumeIsolated { self?.otherAudioChanged(playing: type == .begin) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaServicesWereReset() }
            },
        ]
    }
}
