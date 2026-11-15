import Foundation

/// Looks up the app's text from the compiled String Catalog
/// (Localizable.xcstrings). The app is English only: text, dates and numbers
/// are always English, whatever the device language.
@MainActor
final class Localizer {
    /// Fixed English formatting locale for dates and numbers.
    let locale = Locale(identifier: "en_US")
    private let bundle: Bundle

    init(host: Bundle = .main) {
        if let path = host.path(forResource: "en", ofType: "lproj"), let english = Bundle(path: path) {
            bundle = english
        } else {
            bundle = host
        }
    }

    subscript(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        arguments.isEmpty ? self[key] : String(format: self[key], locale: locale, arguments: arguments)
    }
}
