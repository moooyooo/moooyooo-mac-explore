# Assets and dependencies

| Component | Origin | Distribution |
| --- | --- | --- |
| Application source, translations, documentation and synthetic examples | This repository, maintained by moooyooo | [MIT](LICENSE) |
| Application icon | Original artwork generated for this project with OpenAI's built-in image generation tool; no reference images supplied | PNG master and ICNS distributed under [MIT](LICENSE); [prompt and reproduction](docs/app-icon.md) |
| Swift, Foundation, AppKit, CoreServices and UniformTypeIdentifiers | Apple / Swift toolchain and macOS SDK | Linked system frameworks; their licenses are separate from this project's MIT license |
| Toolbar symbols | SF Symbols requested through `NSImage(systemSymbolName:…)` | Resolved by macOS at runtime; no extracted symbol artwork is included |
| File and folder icons | `NSWorkspace` on the user's Mac | Resolved at runtime; no third-party icon set is copied into this repository |
| CI checkout action | [actions/checkout](https://github.com/actions/checkout), MIT | CI only, pinned by commit; not bundled in the app |
| CI artifact upload action | [actions/upload-artifact](https://github.com/actions/upload-artifact), [MIT](https://github.com/actions/upload-artifact/blob/v7.0.1/LICENSE) | CI only, pinned by commit; not bundled in the app |
| Sparkle 2.10.0 | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0) | Native update framework and installer helpers, pinned exactly via SwiftPM and its artifact checksum; [complete upstream notices](Licenses/Sparkle.txt) are bundled |
| Documentation screenshots | This app's AppKit views, using generated synthetic files | Include macOS-rendered controls, symbols and file icons as part of the UI; no standalone Apple artwork is extracted |

Sparkle is the only third-party Swift package dependency. Its notices include the
Sparkle MIT license and licenses for bsdiff, sais-lite, ed25519 and signature verification.
No embedded web runtime, downloaded font or separately imported artwork is bundled.
`StorageProbe`, `UpdateProbe` and `BrowserBenchmark` are test/development executables
and are not included in the `.app`. Sparkle's native framework/helpers add about 3 MiB
on disk in the initial 0.7.0 build; no always-running daemon is installed.
Screenshot provenance and reproduction are recorded in [docs/screenshots.md](docs/screenshots.md).

Windows Explorer informs the interaction design. This project is not affiliated
with Microsoft or Apple, and does not redistribute Explorer branding or artwork.
