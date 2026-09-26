# P4 implementation and verification

Updated 2026-09-26. Version 0.4.0 is a development preview; P4 qualification remains open.

## Implemented

- Folder creation, Unicode/case-only rename, copy/cut/paste, same-volume move,
  copy/verify/Trash cross-volume path, Trash and bounded process-local Undo.
- English/Japanese menus, native name-entry/confirmation sheets, context menus,
  Explorer shortcuts, progress/cancellation and per-item error reports.
- Copy staging, exclusive publication, non-merging replacement with retained
  originals, source/destination checks, private interrupted-operation journals.
- Durable Cut claims and mutation locks shared by independent app processes.
- File URL drag sources and asynchronous drop validation/acceptance.
- ACL-preserving project replacement and private access policy for new save files.

## Observed results

Environment: macOS 26.5 / Apple M2 Max / Swift 6.3.2 / Command Line Tools.

| Check | Result |
| --- | --- |
| `scripts/test.sh --integration` | 66 tests passed, 8.227 seconds |
| Copy integrity | Nested folders, Unicode names, symlinks, permission preservation and changed contents detected |
| Failure injection | Partial copy, target/source changes, cancellation, move rollback, failed Trash and replacement backups preserve originals |
| Undo | Create → rename → Undo twice, case-only rename, move restore and edited-output refusal |
| Cut concurrency | Two real child processes consume one request once; changed sources and interrupted claims are refused |
| Native AppKit actions | Context menus and sheets create/rename folders, copy/cut/paste across panes and undo a move |
| Actual macOS Trash | Synthetic file moved using native Trash API and restored with Undo; retry unstable post-move metadata before registering Undo |
| Project save permissions | Existing owner/group/mode/ACL preserved; inherited read ACL removed before new private file data is written |
| Languages | 209 keys checked in English/Japanese; relocated-app integration tests pass |
| Local app | Release 0.4.0 (4), arm64, ad-hoc signature, bundled licenses verified; bundle about 1.9 MiB |
| Smoke launch | Separate Japanese process restored the synthetic two-pane project with translated menu titles |
| Public-source scan | 100 tracked/new source files checked for known personal path, token and private-key patterns; no matches |

These AppKit checks invoke actual native menu actions and controls; they are not
physical mouse/keyboard, visual, or VoiceOver tests. Computer Use still reports
pending Accessibility/Screen Recording permissions. Existing user app instances
were not terminated. Test data and pasteboards are isolated.

## Remaining qualification

- Finder ↔ app and app ↔ independent process drag sequences, default operation
  cursor feedback and modifier changes during dragging.
- Physical cross-volume moves, removable/network volumes, permission boundaries,
  actual full disks and disconnection. Cross-volume failure logic has injection tests.
- Large-file cancellation/progress, manual JIS/US/IME input, focus, VoiceOver and
  supported macOS versions.
- Interrupted-operation recovery usability and performance qualification.

See [user-facing operations and limits](file-operations.md) and the [roadmap](roadmap.md).
