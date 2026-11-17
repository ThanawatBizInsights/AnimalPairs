import Foundation
#if DEBUG && canImport(os)
import os
#endif

/// Debug-only audio log (lifecycle transitions, activation failures, playback
/// recovery). Compiled out of Release builds. Consecutive identical messages
/// are logged once, so a repeating event cannot flood the console.
@MainActor
enum AudioDebugLog {
    #if DEBUG
    private static var last: String?
    #if canImport(os)
    private static let logger = Logger(subsystem: "AnimalPairs", category: "Audio")
    #endif
    /// Every message logged, for tests and the simulation.
    private(set) static var history: [String] = []
    #endif

    static func note(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        guard text != last else { return }
        last = text
        history.append(text)
        #if canImport(os)
        logger.debug("\(text, privacy: .public)")
        #else
        print("[Audio] \(text)")
        #endif
        #endif
    }
}
