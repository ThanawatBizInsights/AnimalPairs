import Foundation

/// The four bundled background loops (`<rawValue>.m4a`).
public enum AnimalPairsMusicTrack: String, CaseIterable, Codable, Sendable {
    case playground = "music_playground"
    case meadow = "music_meadow"
    case focus = "music_focus"
    case celebration = "music_celebration"
}

/// Where the child is, as far as music is concerned.
public enum MusicScene: Equatable, Sendable {
    /// Home, Welcome and choosing a board.
    case menus
    /// Matching cards (including the pause menu).
    case game
    /// The results screen after a round.
    case results
    /// The grown-ups' area and its gate.
    case parents
    /// No music (the opening video plays its own sound).
    case silent
}

/// Which loop belongs where, and when music may be heard. Pure, so it is
/// tested on its own; `BackgroundMusicPlayer` (app) does the playing.
public enum MusicPolicy {
    /// Track for each scene. Home, choosing a board and playing share one
    /// loop, so moving between them never restarts the music.
    public static func track(for scene: MusicScene) -> AnimalPairsMusicTrack? {
        switch scene {
        case .menus: .playground
        case .game: .playground
        case .results: .celebration
        case .parents: .meadow
        case .silent: nil
        }
    }

    /// Seconds to wait before a scene's track fades in (the results jingle
    /// plays first; elsewhere music starts at once).
    public static func startDelay(for scene: MusicScene) -> TimeInterval {
        scene == .results ? 3.0 : 0
    }

    /// Music is heard only when every condition allows it.
    /// * `otherAudioPlaying`: another app (a parent's podcast or music) is
    ///   playing; background music stays silent rather than layering on it.
    /// * `heldAfterRouteLoss`: headphones were just unplugged; music waits
    ///   for the next screen or for the app to become active again.
    public static func isAudible(enabled: Bool, appActive: Bool, interrupted: Bool,
                                 otherAudioPlaying: Bool, heldAfterRouteLoss: Bool) -> Bool {
        enabled && appActive && !interrupted && !otherAudioPlaying && !heldAfterRouteLoss
    }
}

/// A smooth volume change from `from` to `to` over `duration` seconds,
/// starting at `start` (smoothstep curve, so fades have no audible corner).
public struct VolumeRamp: Equatable, Sendable {
    public var from: Float
    public var to: Float
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(from: Float, to: Float, start: TimeInterval, duration: TimeInterval) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = max(0, duration)
    }

    /// A ramp that is already at `value`.
    public static func steady(_ value: Float) -> VolumeRamp {
        VolumeRamp(from: value, to: value, start: 0, duration: 0)
    }

    public func value(at now: TimeInterval) -> Float {
        guard duration > 0, now < start + duration else { return now < start ? from : to }
        guard now > start else { return from }
        let x = Float((now - start) / duration)
        return from + (to - from) * x * x * (3 - 2 * x)
    }

    public func isFinished(at now: TimeInterval) -> Bool { now >= start + duration }

    /// A new ramp to `target` that starts from wherever this one is at `now`,
    /// so interrupting a fade never jumps.
    public func retargeted(to target: Float, at now: TimeInterval, duration: TimeInterval) -> VolumeRamp {
        VolumeRamp(from: value(at: now), to: target, start: now, duration: duration)
    }
}

/// Lowers the music while an animal clip plays, then brings it back.
/// Overlapping requests extend the dip instead of stacking it.
public struct MusicDuck: Equatable, Sendable {
    /// Music level (share of normal) during an animal clip.
    public var depth: Float
    public var attack: TimeInterval
    public var release: TimeInterval
    private var holdUntil: TimeInterval = -.infinity
    private var dipStart: TimeInterval = -.infinity
    private var dipFrom: Float = 1

    public init(depth: Float = 0.35, attack: TimeInterval = 0.15, release: TimeInterval = 0.8) {
        self.depth = depth
        self.attack = attack
        self.release = release
    }

    /// Dip the music from `now` until `end` (then release). A new clip during
    /// the release dips again from the current level, without a jump.
    public mutating func duck(at now: TimeInterval, until end: TimeInterval) {
        if now > holdUntil {
            dipFrom = level(at: now)
            dipStart = now
        }
        holdUntil = max(holdUntil, end)
    }

    public mutating func reset() {
        holdUntil = -.infinity
        dipStart = -.infinity
        dipFrom = 1
    }

    /// 1 = normal level, `depth` = fully ducked.
    public func level(at now: TimeInterval) -> Float {
        guard now >= dipStart else { return 1 }
        let down = VolumeRamp(from: dipFrom, to: depth, start: dipStart, duration: attack)
        if now <= holdUntil { return down.value(at: now) }
        let reached = down.value(at: holdUntil)
        return VolumeRamp(from: reached, to: 1, start: holdUntil, duration: release).value(at: now)
    }

    public func isActive(at now: TimeInterval) -> Bool { now >= dipStart && now < holdUntil + release }
}

/// Trims a decoded loop to its exact length when a decoder keeps the AAC
/// encoder delay (leading priming samples) and end padding.
public enum LoopTrim {
    /// The frame range to keep, or nil when the decoded length is already exact
    /// or shorter than expected (then the whole buffer is used).
    public static func range(decodedFrames: Int, expectedFrames: Int, encoderDelay: Int = 1024) -> Range<Int>? {
        guard expectedFrames > 0, decodedFrames > expectedFrames else { return nil }
        let lead = min(decodedFrames - expectedFrames, encoderDelay)
        return lead..<(lead + expectedFrames)
    }
}
