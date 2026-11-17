import AVFoundation
import Foundation

/// Owns the app's one `AVAudioSession` configuration and activation.
///
/// * The category (`.ambient` + `.mixWithOthers`: respects the Ring/Silent
///   switch, never stops other apps' audio) is set once.
/// * Activation runs on a private serial queue, never on the main thread
///   (`setActive` can block; iOS logs "This method can lead to UI
///   unresponsiveness…" for main-thread calls). Requests made while one is in
///   flight are coalesced into it.
/// * It is requested only at launch, on returning to the foreground and after
///   an interruption ends — never for a card flip, an animal sound, a redraw
///   or navigation. Sound players do not start until the session is active, so
///   they never activate it implicitly on the main thread either.
/// * The app never deactivates the session itself; the system does that when
///   the app is suspended or interrupted, and `markInactive()` records it.
@MainActor
final class AudioSessionController {
    enum State: Equatable { case inactive, activating, active, failed }

    /// Runs `work` off the main thread and reports its result on the main
    /// actor. Injectable so tests can check threading and count calls.
    typealias Runner = (_ work: @escaping @Sendable () -> Bool,
                        _ done: @escaping @MainActor (Bool) -> Void) -> Void

    private(set) var state: State = .inactive
    /// How many times `setActive(true)` was actually requested (tests).
    private(set) var activationCount = 0
    private var waiting: [@MainActor () -> Void] = []
    /// Set when the session is lost (background, interruption) while an
    /// activation is in flight: its late success must not count.
    private var invalidated = false
    /// A request arrived after the in-flight activation was invalidated: run
    /// a fresh activation when that one returns.
    private var requestedAgain = false
    private let runner: Runner
    private var configured = false

    static let backgroundRunner: Runner = { work, done in
        AudioSessionController.queue.async {
            let ok = work()
            Task { @MainActor in done(ok) }
        }
    }

    private static let queue = DispatchQueue(label: "AnimalPairs.audio-session", qos: .userInitiated)

    /// Tests only: runs the work at once on the calling thread.
    static let immediateRunner: Runner = { work, done in
        let ok = work()
        MainActor.assumeIsolated { done(ok) }
    }

    /// `runner` defaults to nil and is resolved inside this @MainActor body
    /// (default arguments are evaluated outside the main actor in Swift 5 mode).
    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.backgroundRunner
    }

    /// Sound may start: the session is active, or activation failed (then
    /// playback is attempted anyway rather than leaving the game silent).
    var allowsPlayback: Bool { state == .active || state == .failed }

    /// Activates the session if it is not active yet; `then` runs on the main
    /// actor once it is (immediately when it already is).
    func activate(then: (@MainActor () -> Void)? = nil) {
        if let then { waiting.append(then) }
        switch state {
        case .active:
            flush()
            return
        case .activating:
            if invalidated { requestedAgain = true }
            return                              // coalesced into the request in flight
        case .inactive, .failed:
            break
        }
        state = .activating
        invalidated = false
        activationCount += 1
        let configure = !configured
        configured = true
        runner({
            let session = AVAudioSession.sharedInstance()
            if configure {
                try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            do {
                try session.setActive(true)
                return true
            } catch {
                return false
            }
        }, { [weak self] ok in
            guard let self else { return }
            if self.invalidated {
                // Backgrounded or interrupted meanwhile: this result is stale.
                self.invalidated = false
                self.state = .inactive
                AudioDebugLog.note("audio session activation superseded (app left or was interrupted)")
                if self.requestedAgain {
                    self.requestedAgain = false
                    self.activate()             // the waiting callbacks run after this one
                } else {
                    self.waiting = []           // the next foreground / interruption end asks again
                }
                return
            }
            self.state = ok ? .active : .failed
            AudioDebugLog.note(ok ? "audio session active" : "audio session activation failed; sounds will still try to play, retry at next foreground")
            self.flush()
        })
    }

    /// The system deactivated the session (app suspended, interruption began).
    func markInactive() {
        if state == .activating { invalidated = true } else { state = .inactive }
    }

    /// The media server restarted: configure the category again on the next
    /// activation.
    func reset() {
        configured = false
        invalidated = state == .activating
        if state != .activating { state = .inactive }
    }

    private func flush() {
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0() }
    }
}
