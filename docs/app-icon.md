# アプリアイコン

0.7.1で、黄色いフォルダと青い重なったウィンドウを表した専用アイコンを追加した。
Explorer形式のファイラと、複数の作業画面を扱える特徴を表す。

<img src="../Resources/AppIcon.png" width="256" alt="黄色いフォルダと青い重なったウィンドウのアプリアイコン">

- 原稿: [Resources/AppIcon.png](../Resources/AppIcon.png)（1254 × 1254、RGBA、透過背景）。
- 配布用: [Resources/AppIcon.icns](../Resources/AppIcon.icns)（16〜1024 px、標準／Retinaの10サイズ）。
- `CFBundleIconFile`とビルドスクリプトから参照する。PNG原稿はアプリへ重複して同梱しない。
- OpenAIの組み込み`image_gen`で新規生成。参考画像や既存ブランドの図案は入力していない。
  このリポジトリのアセットとして[MIT](../LICENSE)で提供する。実行時の依存関係は増やさない。

## 再生成

図案の変更には原稿PNGを更新する。サイズ変換とICNS化はmacOS標準の`sips`・`iconutil`を使う。
透明部分を維持し、通常のビルドではコミット済みのICNSをそのままコピーする。

```sh
scripts/build-icon.sh
scripts/build-app.sh release
python3 scripts/verify-app.py
```

## 生成に使った最終プロンプト

生成方式: 組み込み`image_gen`（CLI/APIキーによる生成は使用していない）。

```text
Use case: logo-brand
Asset type: production macOS application icon for a lightweight native file manager, not a mockup.
Primary request: an original polished file explorer icon, with a large warm golden-yellow open folder in front of two clearly overlapping blue application windows. The overlapping windows suggest multiple independent workspaces. The folder is the dominant instantly recognizable silhouette.
Style: refined contemporary macOS app icon, simple sculpted shapes, restrained soft dimensionality, crisp edges, subtle material gradients and soft edge highlights. Friendly practical desktop utility, not a game icon.
Composition: one centered front-facing icon in a 1024 by 1024 square canvas. Rich blue rounded-square backplate occupies about 84 percent of the canvas, with a consistent transparent margin. In front of it, two offset lighter blue window cards with simple title bars, and one dominant golden folder. Keep all forms large and legible at 32px. Use actual alpha transparency outside the rounded-square shape, including corners. No opaque white background.
Lighting: gentle top-left illumination and a modest soft shadow, no dramatic glow.
Constraints: no text, no letters, no monogram, no badge, no magnifying glass, no arrow, no Windows logo, no Finder face, no stock artwork or copied brand icon. No checkerboard drawn into the image. Only one complete finished icon, no grid or presentation board.
```

