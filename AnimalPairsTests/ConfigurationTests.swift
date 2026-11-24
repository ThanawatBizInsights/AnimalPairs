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
