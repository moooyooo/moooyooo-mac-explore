# Roadmap

Updated 2026-09-27. The [Japanese roadmap](roadmap.md) includes detailed acceptance criteria.

| Phase | Scope | Current state |
| --- | --- | --- |
| P0 | Requirements and Git | Complete |
| P1 | Native MDI and independent processes | Implemented; manual interaction and VoiceOver remain |
| P2 | Browsing and monitoring | Implemented; native display measurements pass; manual/environment checks remain |
| P3 | Projects, save ownership and recovery | Implemented through selection, viewport and history recovery; manual confirmations remain |
| P4 | Create, rename, copy, move, trash, drag-and-drop, Undo | Integrity, AppKit, separate APFS volume and real disk-full tests pass; Finder, physical/network volumes and disconnection remain |
| P5 | Performance, accessibility and OS qualification | Local performance budgets and 50 pane cycles pass; IME, VoiceOver, display environments and minimum OS remain |
| L10n | English/Japanese and language selection | Implemented; both workspace images reviewed; native panel/input checks remain |
| P6 | Public documentation, CI and release preparation | Local preparation implemented; in progress |

By request, multilingual support and P6 preparation precede P4/P5. General-release
criteria still include P4/P5. A browsing development preview may be published earlier
with its limitations clearly documented.

Completed locally: [English/Japanese captures](screenshots.md), release notes draft,
MIT/public documentation and verified development packaging.

Remaining: upstream creation and private security reports;
hosted CI; macOS 14, IME, display and VoiceOver checks; external-storage qualification;
Developer ID signing, notarization and first-download verification.

See [P5 verification](p5-verification.md), [P6 verification](p6-verification.md),
[release steps](releasing.md) and [localization](localization.md).
