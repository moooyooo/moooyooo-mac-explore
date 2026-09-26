# Assets and dependencies

| Component | Origin | Distribution |
| --- | --- | --- |
| Application source, translations, documentation and synthetic examples | This repository, maintained by moooyooo | [MIT](LICENSE) |
| Swift, Foundation, AppKit, CoreServices and UniformTypeIdentifiers | Apple / Swift toolchain and macOS SDK | Linked system frameworks; their licenses are separate from this project's MIT license |
| Toolbar symbols | SF Symbols requested through `NSImage(systemSymbolName:…)` | Resolved by macOS at runtime; no extracted symbol artwork is included |
| File and folder icons | `NSWorkspace` on the user's Mac | Resolved at runtime; no third-party icon set is copied into this repository |
| CI checkout action | [actions/checkout](https://github.com/actions/checkout), MIT | CI only, pinned by commit; not bundled in the app |

There are no third-party Swift package dependencies, embedded web runtimes,
downloaded fonts or external artwork. `StorageProbe` and `BrowserBenchmark`
are test/development executables and are not included in the `.app`.

Windows Explorer informs the interaction design. This project is not affiliated
with Microsoft or Apple, and does not redistribute Explorer branding or artwork.
