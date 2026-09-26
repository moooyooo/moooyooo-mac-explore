import Foundation

private final class LocalizationAnchor: NSObject {}

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, ja

    public static func resolve(_ preference: Self, preferredLanguages: [String]) -> Self {
        if preference != .system { return preference }
        for identifier in preferredLanguages {
            let base = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            if let base, let language = Self(rawValue: String(base)), language != .system { return language }
        }
        return .en
    }
}

public enum LanguageSettings {
    public static let preferenceKey = "ApplicationLanguage"

    public static func preference(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    public static func argument(in arguments: [String] = CommandLine.arguments) -> AppLanguage? {
        guard let index = arguments.lastIndex(of: "--language"), arguments.indices.contains(index + 1) else { return nil }
        return AppLanguage(rawValue: arguments[index + 1])
    }

    /// Run before NSApplication is created. The override is process-local; it never changes macOS preferences.
    public static func bootstrap() {
        // Select the language before loading any localization bundle.
        let language = AppLanguage.resolve(argument() ?? preference(), preferredLanguages: Locale.preferredLanguages)
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["AppleLanguages"] = [language.rawValue]
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}

/// Immutable for the lifetime of a process, including background directory readers.
public struct Localizer: Sendable {
    public let language: AppLanguage
    public let locale: Locale
    private let bundle: Bundle

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages,
                region: String? = Locale.current.region?.identifier) {
        self.language = AppLanguage.resolve(language, preferredLanguages: preferredLanguages)
        locale = Locale(identifier: self.language.rawValue + (region.map { "_" + $0 } ?? ""))
        let resources = Self.resourceBundle
        let path = resources.path(forResource: self.language.rawValue, ofType: "lproj")!
        bundle = Bundle(path: path)!
    }

    // Resolve relative to the running product. SwiftPM's generated accessor embeds the
    // developer's absolute build path; do not reference it in a distributable executable.
    public static var resourceBundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("MacExplore_ExplorerCore.bundle"),
                  let bundled = Bundle(url: url) else {
                preconditionFailure("The app's localization resource bundle is missing. Rebuild the app with scripts/build-app.sh.")
            }
            return bundled
        }
        // Swift Testing may run inside a toolchain helper whose main bundle is unrelated
        // to the loaded test executable. Resolve that executable's bundle first.
        for origin in [Bundle(for: LocalizationAnchor.self).bundleURL, Bundle.main.bundleURL] {
            var directory = origin
            for _ in 0..<5 {
                if let bundled = Bundle(url: directory.appendingPathComponent("MacExplore_ExplorerCore.bundle")) { return bundled }
                directory.deleteLastPathComponent()
            }
        }
        preconditionFailure("Localization resources must be next to the command-line executable or test bundle.")
    }

    public func text(_ key: L10n.Key) -> String {
        bundle.localizedString(forKey: key.rawValue, value: nil, table: "Localizable")
    }

    public func format(_ key: L10n.Key, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

public enum L10n {
    public static let current = Localizer(language: LanguageSettings.argument() ?? LanguageSettings.preference())
    public static var locale: Locale { current.locale }
    public static func text(_ key: Key) -> String { current.text(key) }
    public static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: current.text(key), locale: current.locale, arguments: arguments)
    }
}
