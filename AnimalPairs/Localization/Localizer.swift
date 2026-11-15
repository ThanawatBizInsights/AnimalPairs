import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case english = "en"
    case thai = "th"

    var id: String { rawValue }

    /// Shown in its own language so a parent can always find it.
    var nativeName: String {
        switch self {
        case .system: "—"
        case .english: "English"
        case .thai: "ไทย"
        }
    }
}

/// Looks up strings from the compiled String Catalog (Localizable.xcstrings)
/// in the language chosen in the app, independent of the device language.
@MainActor
@Observable
final class Localizer {
    private(set) var language: AppLanguage
    private(set) var resolvedCode: String
    private var bundle: Bundle
    private let fallback: Bundle
    private let host: Bundle

    init(language: AppLanguage, host: Bundle = .main) {
        self.host = host
        self.language = language
        self.fallback = Self.bundle(for: "en", host: host)
        self.resolvedCode = Self.resolve(language, host: host)
        self.bundle = Self.bundle(for: resolvedCode, host: host)
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        resolvedCode = Self.resolve(language, host: host)
        bundle = Self.bundle(for: resolvedCode, host: host)
    }

    var locale: Locale { Locale(identifier: resolvedCode) }

    /// Display name for the language currently in use for `.system`.
    func displayName(for option: AppLanguage) -> String {
        option == .system ? self["language.system"] : option.nativeName
    }

    subscript(_ key: String) -> String {
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: "Localizable")
        if value != "\u{0}" { return value }
        let english = fallback.localizedString(forKey: key, value: "\u{0}", table: "Localizable")
        return english == "\u{0}" ? key : english
    }

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        arguments.isEmpty ? self[key] : String(format: self[key], locale: locale, arguments: arguments)
    }

    private static func resolve(_ language: AppLanguage, host: Bundle) -> String {
        switch language {
        case .english: return "en"
        case .thai: return "th"
        case .system:
            let preferred = Bundle.preferredLocalizations(from: ["en", "th"], forPreferences: Locale.preferredLanguages)
            return preferred.first ?? "en"
        }
    }

    private static func bundle(for code: String, host: Bundle) -> Bundle {
        guard let path = host.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return host }
        return bundle
    }
}
