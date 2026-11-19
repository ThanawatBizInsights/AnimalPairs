import Foundation

/// Release configuration, in ONE place: the AnimalPairs target's Build
/// Settings (User-Defined `AP_*` settings) → Info.plist → this type.
///
/// | Build setting               | Info.plist key          | Meaning |
/// | --- | --- | --- |
/// | `AP_FULL_UNLOCK_PRODUCT_ID` | `APFullUnlockProductID` | Product ID of the one-time, non-consumable "Full Game Unlock". Must match App Store Connect and `Config/Products.storekit`. |
/// | `AP_TERMS_OF_USE_URL`  | `APTermsOfUseURL`   | Terms of Use (EULA) page, `https://` only (optional). |
/// | `AP_PRIVACY_POLICY_URL`| `APPrivacyPolicyURL`| Privacy policy page, `https://` only. |
/// | `AP_SUPPORT_URL`       | `APSupportURL`      | Website / support page, `https://` only. |
///
/// Empty or non-https values are treated as "not set": Parents says so
/// instead of offering a dead link. Change them in Build Settings, not in code.
struct AppConfiguration: Sendable {
    /// The Full Game Unlock product ID. A product ID need not match the
    /// bundle ID; this one must be created in App Store Connect as a
    /// Non-Consumable. Used when the build setting is empty.
    static let defaultFullUnlockProductID = "com.littlepenguinstudio.animalpairs.fullgame"

    let fullUnlockProductID: String
    let termsOfUseURL: URL?
    let privacyPolicyURL: URL?
    let supportURL: URL?
    let appVersion: String

    static let current = AppConfiguration(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let productID = (info["APFullUnlockProductID"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        fullUnlockProductID = productID.isEmpty ? Self.defaultFullUnlockProductID : productID
        termsOfUseURL = Self.url(info["APTermsOfUseURL"])
        privacyPolicyURL = Self.url(info["APPrivacyPolicyURL"])
        supportURL = Self.url(info["APSupportURL"])
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        appVersion = "\(short) (\(build))"
    }

    init(fullUnlockProductID: String, termsOfUseURL: URL? = nil, privacyPolicyURL: URL?, supportURL: URL?,
         appVersion: String = "test") {
        self.fullUnlockProductID = fullUnlockProductID
        self.termsOfUseURL = termsOfUseURL
        self.privacyPolicyURL = privacyPolicyURL
        self.supportURL = supportURL
        self.appVersion = appVersion
    }

    /// Links still missing that a release should have (the privacy policy
    /// is required for the App Store; Terms of Use is optional for a
    /// one-time purchase — Apple's standard EULA applies without it).
    var missingRequiredLinks: [String] {
        [("AP_PRIVACY_POLICY_URL", privacyPolicyURL), ("AP_SUPPORT_URL", supportURL)]
            .filter { $0.1 == nil }.map(\.0)
    }

    private static func url(_ value: Any?) -> URL? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty,
              let url = URL(string: string), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
