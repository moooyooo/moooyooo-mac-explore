# Roadmap

Updated 2026-09-26. The [Japanese roadmap](roadmap.md) includes detailed acceptance criteria.

| Phase | Scope | Current state |
| --- | --- | --- |
| P0 | Requirements and Git | Complete |
| P1 | Native MDI and independent processes | Implemented; manual interaction and VoiceOver remain |
| P2 | Browsing and monitoring | Implemented; manual checks and rendering measurements remain |
| P3 | Projects, save ownership and recovery | Implemented and tested; manual confirmations and selection/scroll/history recovery remain |
| P4 | Create, rename, copy, move, trash, drag-and-drop, Undo | Not started |
| P5 | Performance, accessibility and OS qualification | Full qualification not started |
| L10n | English/Japanese and language selection | Implemented before P6; native panel and visual review remain |
| P6 | Public documentation, CI and release preparation | Local preparation implemented; in progress |

By request, multilingual support and P6 preparation precede P4/P5. General-release
criteria still include P4/P5. A browsing development preview may be published earlier
with its limitations clearly documented.

Remaining: English screenshots; upstream creation and private security reports;
hosted CI; macOS 14, IME and VoiceOver checks; performance qualification;
Developer ID signing, notarization and first-download verification.

See [P6 verification](p6-verification.md), [release steps](releasing.md) and [localization](localization.md).
