import Foundation

/// Release configuration, in ONE place: the AnimalPairs target's Build
/// Settings (User-Defined `AP_*` settings) → Info.plist → this type.
///
/// | Build setting          | Info.plist key      | Meaning |
/// | ---------------------- | ------------------- | ------- |
/// | `AP_PLUS_PRODUCT_ID`   | `APPlusProductID`   | Product ID of the "Animal Pairs Plus" monthly auto-renewable subscription. Must match App Store Connect and `Config/Products.storekit`. |
/// | `AP_TERMS_OF_USE_URL`  | `APTermsOfUseURL`   | Terms of Use (EULA) page, `https://` only. |
/// | `AP_PRIVACY_POLICY_URL`| `APPrivacyPolicyURL`| Privacy policy page, `https://` only. |
/// | `AP_SUPPORT_URL`       | `APSupportURL`      | Website / support page, `https://` only. |
///
/// Empty or non-https values are treated as "not set": Parents says so
/// instead of offering a dead link. Change them in Build Settings, not in code.
struct AppConfiguration: Sendable {
    /// Development placeholder. Replace with `<your bundle ID>.plus.monthly`
    /// (e.g. `com.littlepenguinstudio.animalpairs.plus.monthly`) once the
    /// final bundle ID is known.
    static let placeholderProductID = "com.example.animalpairs.plus.monthly"

    let plusProductID: String
    let termsOfUseURL: URL?
    let privacyPolicyURL: URL?
    let supportURL: URL?
    let appVersion: String

    static let current = AppConfiguration(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let productID = (info["APPlusProductID"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        plusProductID = productID.isEmpty ? Self.placeholderProductID : productID
        termsOfUseURL = Self.url(info["APTermsOfUseURL"])
        privacyPolicyURL = Self.url(info["APPrivacyPolicyURL"])
        supportURL = Self.url(info["APSupportURL"])
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        appVersion = "\(short) (\(build))"
    }

    init(plusProductID: String, termsOfUseURL: URL? = nil, privacyPolicyURL: URL?, supportURL: URL?,
         appVersion: String = "test") {
        self.plusProductID = plusProductID
        self.termsOfUseURL = termsOfUseURL
        self.privacyPolicyURL = privacyPolicyURL
        self.supportURL = supportURL
        self.appVersion = appVersion
    }

    /// True while the bundle still uses the example product identifier.
    var usesPlaceholderProductID: Bool { plusProductID == Self.placeholderProductID }

    /// Links App Review requires for a subscription that are still missing.
    var missingRequiredLinks: [String] {
        [("AP_TERMS_OF_USE_URL", termsOfUseURL), ("AP_PRIVACY_POLICY_URL", privacyPolicyURL)]
            .filter { $0.1 == nil }.map(\.0)
    }

    private static func url(_ value: Any?) -> URL? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty,
              let url = URL(string: string), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
