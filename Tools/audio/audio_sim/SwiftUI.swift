// The one SwiftUI API GameSession uses, for the Linux simulation only.
public enum AccessibilityNotification {
    public struct Announcement {
        public init(_ text: String) {}
        public func post() {}
    }
}
