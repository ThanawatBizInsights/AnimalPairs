import Foundation

/// Values read from Info.plist, which in turn come from build settings
/// (`AP_FULL_UNLOCK_PRODUCT_ID`, `AP_PRIVACY_POLICY_URL`, `AP_SUPPORT_URL`).
/// Change them in the target's Build Settings, not in code.
struct AppConfiguration: Sendable {
    static let placeholderProductID = "com.example.animalpairs.fullgame"

    let fullUnlockProductID: String
    let privacyPolicyURL: URL?
    let supportURL: URL?
    let appVersion: String

    static let current = AppConfiguration(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let productID = (info["APFullUnlockProductID"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        fullUnlockProductID = productID.isEmpty ? Self.placeholderProductID : productID
        privacyPolicyURL = Self.url(info["APPrivacyPolicyURL"])
        supportURL = Self.url(info["APSupportURL"])
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        appVersion = "\(short) (\(build))"
    }

    init(fullUnlockProductID: String, privacyPolicyURL: URL?, supportURL: URL?, appVersion: String = "test") {
        self.fullUnlockProductID = fullUnlockProductID
        self.privacyPolicyURL = privacyPolicyURL
        self.supportURL = supportURL
        self.appVersion = appVersion
    }

    /// True while the bundle still uses the example product identifier.
    var usesPlaceholderProductID: Bool { fullUnlockProductID == Self.placeholderProductID }

    private static func url(_ value: Any?) -> URL? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }
}
