# Localization / 多言語対応

## Using the app

The app supports English and Japanese. The initial setting follows macOS preferred
languages; English is the fallback when neither supported language is present.
Choose **Moooyooo Mac Explore → Language / 言語** to select **Follow System**,
**English** or **日本語**. The selection takes effect on the next launch. Existing
windows and other running processes retain their language.

For an isolated launch without changing the saved preference:

```sh
open -n "build/Moooyooo Mac Explore.app" --args --language en
open -n "build/Moooyooo Mac Explore.app" --args --language ja
open -n "build/Moooyooo Mac Explore.app" --args --language system
```

Priority: `--language` → saved app preference → macOS language order → English.
Invalid or incomplete language arguments are ignored. An explicit launch override
is inherited by new processes launched from that instance; selecting a language
in the menu removes that override for subsequent child processes.

日本語・英語に対応しています。初期状態はmacOSの優先言語に従います。
アプリ名メニューの「言語 / Language」で切り替え、次回起動から反映します。
既に開いている別プロセスには影響しません。

## Translation scope

Menus, tooltips, accessibility labels, table headers, status counts, app-owned errors,
project confirmation sheets and help text use the shared catalog. File kinds,
dates and byte counts use the selected language with the current macOS region.
Native panels use a process-local `AppleLanguages` override established before
`NSApplication` is created. macOS system language preferences are never changed.
OS error details and UI supplied by external applications remain system-controlled;
native panel appearance still needs manual validation on supported macOS versions.

File names, paths, project names, filter text and bookmarks are user data and are
preserved. New projects receive a localized “Untitled” name; switching language
does not rename existing projects. The JSON schema remains version 1.
Shortcuts and serialized command/column identifiers do not depend on language.

## Adding translations

1. Add a semantic case to `Sources/ExplorerCore/LocalizationKey.swift`.
2. Add matching entries to both `Resources/en.lproj/Localizable.strings` and
   `Resources/ja.lproj/Localizable.strings` inside `Sources/ExplorerCore`.
3. Use `L10n.text` for labels and `L10n.format` for complete sentences.
   Keep printf types compatible; never use user text as a format string.
4. Put count-based messages in `Localizable.stringsdict`. English requires
   singular and plural forms. Add count tests for new patterns.
5. Run `python3 scripts/check-localizations.py`, build, and run integration tests.
6. Review layout, keyboard focus and VoiceOver in both languages.

To add another supported language, also extend `AppLanguage`, the language menu,
`CFBundleLocalizations`, the packaging loop and validation tests. This release
supports English and Japanese only; the extension points are explicit.

Resources are managed by SwiftPM with English as `defaultLocalization`.
The packaged app loads its own `Contents/Resources/MacExplore_ExplorerCore.bundle`.
Command-line tools and tests resolve the bundle relative to their executable;
the distributable never falls back to a developer's absolute build directory.
See [Apple's package localization guidance](https://developer.apple.com/documentation/xcode/localizing-package-resources).
