import AnimalPairsCore
import XCTest
@testable import AnimalPairs

/// The website links Parents opens come from one place: the AnimalPairs
/// target's AP_* build settings → Info.plist → `AppConfiguration.current`.
/// These tests read the real built Info.plist of the app under test.
@MainActor
final class ConfigurationTests: XCTestCase {
    static let supportURL = "https://littlesnowyowl.com/games/animal-pairs/support/"
    static let privacyPolicyURL = "https://littlesnowyowl.com/games/animal-pairs/privacy/"
    static let termsOfUseURL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

    func testBundledWebsiteLinksAreTheProductionPages() {
        let configuration = AppConfiguration.current
        XCTAssertEqual(configuration.supportURL?.absoluteString, Self.supportURL)
        XCTAssertEqual(configuration.privacyPolicyURL?.absoluteString, Self.privacyPolicyURL)
        XCTAssertEqual(configuration.termsOfUseURL?.absoluteString, Self.termsOfUseURL)
        XCTAssertTrue(configuration.missingRequiredLinks.isEmpty)
    }

    func testNoLinkPointsAtTheRetiredWebsiteHost() {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["APSupportURL", "APPrivacyPolicyURL", "APTermsOfUseURL"] {
            let value = info[key] as? String ?? ""
            XCTAssertFalse(value.contains("workers.dev"), "\(key) = \(value)")
            XCTAssertTrue(value.hasPrefix("https://"), "\(key) = \(value)")
        }
    }

    /// Kids Category: the shipped privacy manifest declares no tracking, no
    /// collected data, and a reason for each required-reason API the app uses
    /// (UserDefaults for settings; system uptime to time sounds).
    func testPrivacyManifestIsBundledAndDeclaresNoTrackingOrCollection() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                                  as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let apis = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).reduce(into: [String: [String]]()) {
            $0[$1["NSPrivacyAccessedAPIType"] as? String ?? ""] = $1["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(apis["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(apis["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }

    func testTheAppModelUsesTheBundledConfigurationByDefault() {
        // Parents reads every link from `model.configuration`; a model built
        // without an explicit configuration must use the bundled one.
        let model = AppModel(settings: SettingsStore(defaults: AppTestSupport.isolatedDefaults()),
                             history: SwiftDataCompletionStore.inMemory(),
                             snapshots: RoundSnapshotStore(directory: AppTestSupport.temporaryDirectory()),
                             playsOpeningVideo: false, audioSession: AppTestSupport.activeSession())
        XCTAssertEqual(model.configuration.supportURL?.absoluteString, Self.supportURL)
        XCTAssertEqual(model.configuration.privacyPolicyURL?.absoluteString, Self.privacyPolicyURL)
    }
}
