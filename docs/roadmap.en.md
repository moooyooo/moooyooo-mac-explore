# Roadmap

0.7.2 fixes browsing directory symbolic links, including the startup disk under Volumes.
See the [release record](releases/0.7.2.md).

0.7.1 adds the application icon and preserves sidebar selection/scrolling during refresh.
The user confirmed that the file-list/tree shaking was resolved in the installed
0.7.1 app; I-07 is closed. See [verification and scope](releases/0.7.1.md).

Updated 2026-09-28. The [Japanese roadmap](roadmap.md) includes detailed acceptance criteria.
The [current backlog](backlog.md) separates implementation work, known issues and maintainer actions.

| Phase | Scope | Current state |
| --- | --- | --- |
| P0 | Requirements and Git | Complete |
| P1 | Native MDI and independent processes | Implemented; manual interaction and VoiceOver remain |
| P2 | Browsing and monitoring | View/column menus and pane-local recovery added in 0.6.0; disconnected/deleted-path distinction and manual/environment checks remain |
| P3 | Projects, save ownership and recovery | Implemented through selection, viewport and history recovery; manual confirmations remain |
| P4 | Create, rename, copy, move, trash, drag-and-drop, Undo | Integrity, AppKit, separate APFS volume and real disk-full tests pass; Finder, physical/network volumes and disconnection remain |
| P5 | Performance, accessibility and OS qualification | Local performance budgets and 50 pane cycles pass; IME, VoiceOver, display environments and minimum OS remain |
| L10n | English/Japanese and language selection | Implemented; both workspace images reviewed; native panel/input checks remain |
| P6 | Public documentation, CI and release preparation | Source public, private security reporting enabled; 0.7.2 passed macOS 14/26 CI; I-06 investigation, signed distribution and manual acceptance remain |
| Updates | Signed feeds/archives, process coordination and workspace handoff | Implemented in 0.7.0 with real disposable-host update and tamper tests; Developer ID/notarized distribution remains pending |

By request, multilingual support and P6 preparation precede P4/P5. General-release
criteria still include P4/P5. A browsing development preview may be published earlier
with its limitations clearly documented.

Completed locally: [English/Japanese captures](screenshots.md), release notes draft,
MIT/public documentation and verified development packaging.

Public upstream: [moooyooo/moooyooo-mac-explore](https://github.com/moooyooo/moooyooo-mac-explore),
with private vulnerability reporting enabled.

Hosted macOS 14/26 CI for 0.7.2 passed builds, integration and APFS-volume tests,
signed updates, native sidebar checks and archive verification. The intermittent
I-06 from earlier runs remains under investigation. See the [current results](releases/0.7.2.md).

Remaining: manual minimum-OS, IME, display and VoiceOver checks; external-storage qualification;
replacement for the retiring macOS 14 runner;
Developer ID signing, notarization and first-download verification.
The maintainer is not yet enrolled in Apple Developer Program and requested
development validation first. The signed public update feed remains empty.

See [P5 verification](p5-verification.md), [P6 verification](p6-verification.md),
[release steps](releasing.md) and [localization](localization.md).
