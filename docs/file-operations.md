# File operations / ファイル操作

0.4.0 development preview. Manual mouse/keyboard, Finder interoperability and
physical cross-volume qualification are still pending. Use synthetic data for evaluation.

## 操作

Explorer内の一覧またはツリーで項目を選び、ファイル／編集メニューまたは右クリックから操作します。
空白部分の右クリックでは、現在のフォルダへの作成と貼り付けができます。

| 操作 | キー |
| --- | --- |
| 新しいフォルダ | Cmd/Ctrl+Shift+N |
| 名前の変更 | F2（環境によりFn併用） |
| コピー／切り取り／貼り付け | Cmd/Ctrl+C / X / V |
| 元に戻す | Cmd/Ctrl+Z |
| ゴミ箱へ移動 | Delete→、内蔵キーボードならFn+⌫、またはCmd+⌫ |
| コンテキストメニュー | Shift+F10 |

コピーは、項目を選択してコピーし、移動先のExplorerで貼り付けます。
切り取りは貼り付けるまで元の項目を変更しません。
テキスト欄にフォーカスがある場合は文字編集になります。Shift+Deleteによる完全削除はありません。

## Conflicts, progress and Undo

- A collision offers **Keep Both / Skip / Replace / Cancel**. Folders are replaced
  as a whole, without merging. A replaced item goes to Trash.
- Copying stages and verifies the contents before publishing the destination.
  Source or destination changes abort that item; results identify partial completion.
- Cancel stops at file boundaries. An individual file being copied may finish first.
  Successfully committed earlier items remain available.
- Undo covers supported operations from this process, up to 20 groups. It checks
  contents, identities and access policy before changing anything. Replacement,
  restart and another process's operations are outside Undo's scope. External edits
  and collisions stop Undo; Undo never permanently deletes items.
- File URL dragging is connected: same-volume defaults to Move, otherwise Copy.
  Option requests Copy; Shift requests Move. Invalid descendants and same-folder
  moves are rejected. Drag validation runs away from the UI thread.
- App-created Cut requests use expiring private records and process locks. A
  consumed or interrupted request cannot move the same source again. If uncertain,
  check the destination and cut the remaining items again. Foreign file clipboards
  are copied; undocumented Finder cut markers are not interpreted.
- Cross-volume moves retain the verified destination if the original cannot be
  sent to Trash. This is reported as a warning, with the source preserved.
- Failed rollback/replacement cleanup retains its data and a private journal.
  **File → Interrupted File Operations** reveals retained staging folders.
  Compare source/destination with the retained payload before restoring it;
  a payload can be an original, an old destination or an incomplete copy.

同名時は「両方を残す／スキップ／置き換える／キャンセル」を選べます。置き換えは
フォルダ全体が対象で、既存項目はゴミ箱へ移動します。置き換え自体のUndoはありません。
進行中の操作は進捗ウィンドウから取り消せます。完了した項目は残ります。
失敗・取消・復元可能なデータの所在は結果画面で確認できます。
強制終了後のデータは「ファイル → 中断したファイル操作」から確認できます。

## Verification

Automated tests use isolated temporary fixtures; the native action tests also use
a private pasteboard. They do not operate on personal folders or the user's clipboard.
Covered: Unicode names, nested folders, symbolic links, permissions/ACLs, changed
contents with restored timestamps, exclusive destination commits, conflict choices,
failed/partial copy, cancellation, move rollback, failed Trash, retained replacement
backup, cross-volume failure injection, blocked Undo and two real processes claiming
one Cut request. Native AppKit tests drive creation/rename sheets and context menu
copy/cut/paste across panes, followed by move Undo.
The native Trash confirmation and Undo also run on a synthetic file through macOS's
actual Trash API. Post-move metadata settling is retried before registering Undo.

Actual disk-full/disconnection, physical cross-volume moves, Finder drag sequences,
large-file progress, keyboard/IME/VoiceOver and supported-OS visual checks remain.
Folders that cannot be read completely, unsupported special files, or attributes
larger than the bounded verification buffer are refused while retaining originals.

The native table integration follows Apple's
[drop validation](https://developer.apple.com/documentation/appkit/nstableviewdatasource/tableview(_:validatedrop:proposedrow:proposeddropoperation:))
and [drop acceptance](https://developer.apple.com/documentation/appkit/nstableviewdatasource/tableview(_:acceptdrop:row:dropoperation:))
interfaces; OS interaction still needs qualification.
