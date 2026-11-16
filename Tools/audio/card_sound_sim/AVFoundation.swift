// Working stand-in for AVAudioPlayer used by the card-sound simulation:
// reads the real WAV header for the duration and tracks play/stop state.
import Foundation
public var audibleLog: [String] = []
open class AVAudioPlayer {
    public let url: URL
    private let length: TimeInterval
    public private(set) var playing = false
    public init(contentsOf url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw CocoaError(.fileReadCorruptFile) }
        let byteRate = data[28..<32].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        length = Double(data.count - 44) / Double(max(byteRate, 1))
    }
    open var volume: Float = 1
    open var currentTime: TimeInterval = 0
    open var duration: TimeInterval { length }
    @discardableResult open func prepareToPlay() -> Bool { true }
    @discardableResult open func play() -> Bool { playing = true; audibleLog.append(url.deletingPathExtension().lastPathComponent); return true }
    open func stop() { playing = false }
    open func setVolume(_ volume: Float, fadeDuration: TimeInterval) { self.volume = volume }
    open var isPlaying: Bool { playing }
}
public final class AVAudioSession {
    public struct Category: Hashable { public static let ambient = Category() }
    public struct Mode: Hashable { public static let `default` = Mode() }
    public struct CategoryOptions: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mixWithOthers = CategoryOptions(rawValue: 1) }
    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    public func setCategory(_ c: Category, mode: Mode, options: CategoryOptions) throws {}
}
