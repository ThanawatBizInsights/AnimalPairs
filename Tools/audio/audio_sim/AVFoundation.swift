// Working stand-in for the AVAudioPlayer / AVAudioEngine API used by
// AudioManager and MusicPlayer, for the Linux simulation only: reads real durations (WAV header, or animal_clips.json
// for .m4a clips), tracks play/stop and logs every start. Time does not advance, so a
// started player stays "playing" until something stops it.
import Foundation

public var startedLog: [String] = []
/// Failure injection for the simulation.
public var failToLoad: Set<String> = []
public var failToPlay: Set<String> = []
public var failedPlays: [String] = []
public var allPlayers: [AVAudioPlayer] = []

open class AVAudioPlayer {
    public let url: URL
    private let length: TimeInterval
    private var playing = false
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(contentsOf url: URL) throws {
        self.url = url
        let name = url.deletingPathExtension().lastPathComponent
        if failToLoad.contains(name) { throw CocoaError(.fileReadCorruptFile) }
        if url.pathExtension == "wav" {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else { throw CocoaError(.fileReadCorruptFile) }
            let byteRate = data[28..<32].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            length = Double(data.count - 44) / Double(max(byteRate, 1))
        } else {
            // .m4a clips and .caf music: the index next to the file records the length.
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            let folder = url.deletingLastPathComponent()
            var seconds: Double?
            if let data = try? Data(contentsOf: folder.appendingPathComponent("animal_clips.json")),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let clips = json["clips"] as? [String: [String: Any]] {
                seconds = clips[name]?["duration"] as? Double
            }
            if seconds == nil, let data = try? Data(contentsOf: folder.appendingPathComponent("music_tracks.json")),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tracks = json["tracks"] as? [String: [String: Any]],
               let frames = tracks[name]?["frames"] as? Int {
                seconds = Double(frames) / 48_000
            }
            guard let seconds else { throw CocoaError(.fileReadCorruptFile) }
            length = seconds
        }
        allPlayers.append(self)
    }
    open var volume: Float = 1
    open var currentTime: TimeInterval = 0
    open var duration: TimeInterval { length }
    @discardableResult open func prepareToPlay() -> Bool { true }
    open var numberOfLoops = 0
    @discardableResult open func play() -> Bool {
        if failToPlay.contains(name) { failedPlays.append(name); return false }
        playing = true; startedLog.append(name); return true
    }
    open func pause() { playing = false }            // keeps currentTime
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
    public func setCategory(_ c: Category, mode: Mode, options: CategoryOptions) throws { sessionCategoryCalls += 1 }
    /// Counts activations and how many came from the main thread (iOS logs
    /// "This method can lead to UI unresponsiveness…" for those).
    public func setActive(_ active: Bool) throws {
        sessionActivations += 1
        if Thread.isMainThread { sessionMainThreadActivations += 1 }
    }
}

// MARK: Engine (MusicPlayer)

public typealias AVAudioFrameCount = UInt32
public typealias AVAudioFramePosition = Int64
public typealias AVAudioChannelCount = UInt32

public final class AVAudioFormat {
    public let channelCount: AVAudioChannelCount
    public init(channels: AVAudioChannelCount) { channelCount = channels }
}

public final class AVAudioPCMBuffer {
    public let format: AVAudioFormat
    public let frameCapacity: AVAudioFrameCount
    public var frameLength: AVAudioFrameCount = 0
    private let storage: [UnsafeMutablePointer<Float>]
    private let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        format = pcmFormat
        self.frameCapacity = frameCapacity
        storage = (0..<Int(pcmFormat.channelCount)).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCapacity))
            p.initialize(repeating: 0, count: Int(frameCapacity))
            return p
        }
        pointers = .allocate(capacity: storage.count)
        pointers.initialize(from: storage, count: storage.count)
    }
    deinit { storage.forEach { $0.deallocate() }; pointers.deallocate() }
    public var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { UnsafePointer(pointers) }
}

/// Decoding is simulated: the "decoder" keeps a 1024-frame encoder delay
/// and 300 frames of end padding, so MusicBuffer's trim is exercised.
public var simulatedDecoderExtraFrames = (lead: 1024, tail: 300)

public final class AVAudioFile {
    public let processingFormat = AVAudioFormat(channels: 2)
    public let length: AVAudioFramePosition
    private let lead: Int
    public init(forReading url: URL) throws {
        let index = url.deletingLastPathComponent().appendingPathComponent("music_tracks.json")
        guard let data = try? Data(contentsOf: index),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: [String: Any]],
              let frames = tracks[url.deletingPathExtension().lastPathComponent]?["frames"] as? Int
        else { throw CocoaError(.fileReadCorruptFile) }
        lead = simulatedDecoderExtraFrames.lead
        length = AVAudioFramePosition(frames + lead + simulatedDecoderExtraFrames.tail)
        decodedFiles.append(url.lastPathComponent)
    }
    public func read(into buffer: AVAudioPCMBuffer) throws {
        buffer.frameLength = AVAudioFrameCount(length)
        // Mark the first real sample so the trim can be checked.
        buffer.floatChannelData![0][lead] = 1
    }
}
public var decodedFiles: [String] = []

public class AVAudioNode {}
public final class AVAudioMixerNode: AVAudioNode {}
public final class AVAudioTime {}
public struct AVAudioPlayerNodeBufferOptions: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let loops = AVAudioPlayerNodeBufferOptions(rawValue: 1)
}

public var allPlayerNodes: [AVAudioPlayerNode] = []
public final class AVAudioPlayerNode: AVAudioNode {
    public var volume: Float = 1
    public private(set) var isPlaying = false
    public private(set) var scheduled: AVAudioPCMBuffer?
    public private(set) var loops = false
    public private(set) var playCount = 0
    public override init() { super.init(); allPlayerNodes.append(self) }
    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?, options: AVAudioPlayerNodeBufferOptions) {
        scheduled = buffer
        loops = options.contains(.loops)
    }
    public func play() { isPlaying = true; playCount += 1 }
    public func stop() { isPlaying = false; scheduled = nil }
}

public final class AVAudioEngine {
    public let mainMixerNode = AVAudioMixerNode()
    public private(set) var isRunning = false
    public private(set) var attached: [AVAudioNode] = []
    public var failStart = false
    public init() {}
    public func attach(_ node: AVAudioNode) { attached.append(node) }
    public func connect(_ node: AVAudioNode, to: AVAudioNode, format: AVAudioFormat?) {}
    public func start() throws { if failStart { throw CocoaError(.featureUnsupported) }; isRunning = true }
    public func pause() { isRunning = false }
    public func stop() { isRunning = false }
}

// MARK: AudioToolbox names re-exported by AVFoundation
// Apple's AVFoundation re-exports AudioToolbox, whose MIDI sequencer API
// (MusicPlayer.h) declares these opaque types. They are mirrored here so the
// simulation catches name clashes the real SDK would report.
public typealias MusicPlayer = OpaquePointer
public typealias MusicTrack = OpaquePointer
public typealias MusicSequence = OpaquePointer

public var sessionActivations = 0
public var sessionMainThreadActivations = 0
public var sessionCategoryCalls = 0
