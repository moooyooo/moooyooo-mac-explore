# English and Japanese screenshots

These images show version **0.6.0** using a generated project and synthetic files.
They were captured and visually reviewed on **2026-09-27**, on macOS 26.5 / Apple
M2 Max, in light and dark appearances. All four images are **2880 × 1576 pixels**.

## English

![English workspace with two tiled Explorer panes](images/workspace-en.png)

## 日本語

![日本語のワークスペース：左右に整列した2つのExplorer画面](images/workspace-ja.png)

## Dark / ダーク

![English workspace in dark appearance](images/workspace-en-dark.png)

![日本語のダーク表示](images/workspace-ja-dark.png)

日英とも実際のAppKit画面を描画して保存しています。ファイル・フォルダ・プロジェクト名は
合成データなので共通です。言語を変えてもユーザーが付けた名前は翻訳しません。
表示される `/tmp/MacExplore-…/Demo` は撮影専用の一時フォルダです。

## Capture scope and review

The debug app exports its own window content through AppKit's
[`NSView.cacheDisplay(in:to:)`](https://developer.apple.com/documentation/appkit/nsview/cachedisplay%28in%3Ato%3A%29).
It renders the same workspace controllers and localization resources used by the
release app. These are native view exports, not desktop screen recordings or mockups.
The macOS title bar, menu bar, other apps and desktop are outside the captured region.

The two panes, toolbar, trees, paths, breadcrumbs, table headers, file kinds, sizes
and status counts were reviewed in both images. Table columns fit their contents.
Only invented file content and neutral temporary paths are visible. No personal
home paths, project history or credentials are included.

[English metadata](images/workspace-en.json) and [Japanese metadata](images/workspace-ja.json)
record language, dimensions, rendering method, appearance and pane count.
[English dark metadata](images/workspace-en-dark.json) and
[Japanese dark metadata](images/workspace-ja-dark.json) record the dark exports.
Their menu titles describe the running app but are not shown in the PNGs.
No post-capture compositing, redrawing or image generation was applied.

These images do not verify mouse/keyboard behavior, menu interaction, native file
dialogs, IME, VoiceOver or other display scales. Those checks
remain on the [roadmap](roadmap.en.md).

## Reproduce

From a macOS GUI session with the project's build prerequisites installed:

```sh
python3 scripts/capture-screenshots.py --output .local/screenshots --appearance both
```

The script:

1. Builds a separate debug app under `build/capture/`.
2. Generates a temporary project using [`create-demo.py`](../scripts/create-demo.py).
3. Starts English and Japanese processes sequentially for each appearance, with isolated recovery data.
4. Waits for directory loading, exports PNG/JSON pairs, and closes its own processes.
5. Removes the temporary fixture after all exports finish.

Existing PNG/JSON files are never overwritten; choose a fresh `--output` directory
for another run. Pixel dimensions can vary with display scale and available screen
size. Temporary folder identifiers vary. Review all outputs before replacing the
published images.

`--capture-window` and `--capture-dark` are compiled only in debug builds. Release verification checks
that this flag is absent from the distributed executable. The capture script passes
`MACEXPLORE_APP_OUTPUT` to the build script to keep its debug bundle separate from
the normal release bundle. It reads no desktop or other application's screen content.

The local Computer Use service still reported missing permissions during this
session. The native view export above does not use that service or the screen
recording API. See [P6 verification](p6-verification.md) for the remaining UI checks.
