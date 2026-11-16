// Working stand-in for the AVAudioPlayer API used by AudioManager, for the
// Linux simulation only: reads real durations (WAV header, or animal_clips.json
// for .m4a clips), tracks play/stop and logs every start. Time does not advance, so a
// started player stays "playing" until something stops it.
import Foundation

public var startedLog: [String] = []
public var allPlayers: [AVAudioPlayer] = []

open class AVAudioPlayer {
    public let url: URL
    private let length: TimeInterval
    private var playing = false
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(contentsOf url: URL) throws {
        self.url = url
        if url.pathExtension == "wav" {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else { throw CocoaError(.fileReadCorruptFile) }
            let byteRate = data[28..<32].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            length = Double(data.count - 44) / Double(max(byteRate, 1))
        } else {
            // .m4a: the clip index next to it records each clip's duration.
            let index = url.deletingLastPathComponent().appendingPathComponent("animal_clips.json")
            guard let data = try? Data(contentsOf: index),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clips = json["clips"] as? [String: [String: Any]],
                  let seconds = clips[url.deletingPathExtension().lastPathComponent]?["duration"] as? Double
            else { throw CocoaError(.fileReadCorruptFile) }
            length = seconds
        }
        allPlayers.append(self)
    }
    open var volume: Float = 1
    open var currentTime: TimeInterval = 0
    open var duration: TimeInterval { length }
    @discardableResult open func prepareToPlay() -> Bool { true }
    @discardableResult open func play() -> Bool { playing = true; startedLog.append(name); return true }
    open func stop() { playing = false }
    open func setVolume(_ volume: Float, fadeDuration: TimeInterval) { self.volume = volume }
    open var isPlaying: Bool { playing }
}

public final class AVAudioSession {
    public struct Category: Hashable { public static let ambient = Category() }
    public struct Mode: Hashable { public static let `default` = Mode() }
    public struct CategoryOptions: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mixWithOthers = CategoryOptions(rawValue: 1)
    }
    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    public func setCategory(_ c: Category, mode: Mode, options: CategoryOptions) throws {}
}
