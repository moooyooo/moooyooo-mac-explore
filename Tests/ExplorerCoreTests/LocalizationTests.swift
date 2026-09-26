import Foundation
import Testing
@testable import ExplorerCore

@Test func languageResolutionUsesSupportedPreferencesAndEnglishFallback() {
    #expect(AppLanguage.resolve(.system, preferredLanguages: ["fr-FR", "ja-JP", "en"]) == .ja)
    #expect(AppLanguage.resolve(.system, preferredLanguages: ["en_GB", "ja"]) == .en)
    #expect(AppLanguage.resolve(.system, preferredLanguages: ["fr"]) == .en)
    #expect(AppLanguage.resolve(.ja, preferredLanguages: ["en"]) == .ja)
    #expect(LanguageSettings.argument(in: ["app", "--language", "en"]) == .en)
    #expect(LanguageSettings.argument(in: ["app", "--language"]) == nil)
    #expect(LanguageSettings.argument(in: ["app", "--language", "unknown"]) == nil)
}

@Test func translationsAreCompleteAndPluralizeCounts() {
    let en = Localizer(language: .en, region: "US")
    let ja = Localizer(language: .ja, region: "JP")
    for key in L10n.Key.allCases {
        #expect(en.text(key) != key.rawValue && !en.text(key).isEmpty)
        #expect(ja.text(key) != key.rawValue && !ja.text(key).isEmpty)
    }
    #expect(en.text(.menuFile) == "File")
    #expect(ja.text(.menuFile) == "ファイル")
    #expect(en.format(.itemCount, 0) == "0 items")
    #expect(en.format(.itemCount, 1) == "1 item")
    #expect(en.format(.itemCount, 2) == "2 items")
    #expect(en.format(.windowCount, 1) == "1 window")
    #expect(en.format(.windowCount, 2) == "2 windows")
    #expect(ja.format(.itemCount, 1) == "1 項目")
    #expect(ja.format(.itemCount, 2) == "2 項目")
    #expect(ja.format(.selectedCount, 2) == "2 項目を選択")
    #expect(en.locale.identifier == "en_US")
    #expect(ja.locale.identifier == "ja_JP")
}

@Test func localizedTemplatesPreserveUserTextAndProjectFormat() throws {
    let name = "資料 100% %@ 🗂️"
    let en = Localizer(language: .en)
    #expect(en.format(.recoveredName, name) == name + " (Recovered)")
    #expect(en.format(.unsupportedProject, 999).contains("999"))
    let document = ProjectDocument(name: name)
    let decoded = try ProjectDocument.decode(document.encoded())
    #expect(decoded.name == name)
    #expect(decoded.schemaVersion == 1)
    #expect(en.format(.diagnosticsBody, Int32(42), "test", 2, 3, 12.5, "macOS").contains("MDI windows: 2"))
}

@Test func languagePreferenceIsIsolatedAndDefaultsToSystem() throws {
    let name = "LocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(LanguageSettings.preference(in: defaults) == .system)
    defaults.set("ja", forKey: LanguageSettings.preferenceKey)
    #expect(LanguageSettings.preference(in: defaults) == .ja)
    defaults.set("unknown", forKey: LanguageSettings.preferenceKey)
    #expect(LanguageSettings.preference(in: defaults) == .system)
}
