# Changelog

## 0.6.0 — in development (not published)

- Add View-menu sorting, column order/width editing and reset, navigation visibility
  and hidden-item toggles, plus Go → Home. Invalid column values stay in the sheet
  with an explanation and Apply disabled until corrected.
- Save navigation visibility as an optional version-1 project field; older projects
  default to a visible navigation tree.
- Show a pane-local recovery view for unreadable folders with Retry, Open Folder
  and Return to Current Folder; prevent file commands/dragging from stale rows.
- Keep custom workspace backgrounds, dividers and pane borders in sync with appearance changes.
- Keep folder-selection dialogs attached to the Explorer that opened them.
- Add native control-action and compatibility tests, and reject incomplete Swift
  Testing runs even if the runtime exits 0.
- Refresh English/Japanese workspace captures in light and dark appearances.
- Record current issues, remaining qualification and maintainer publication actions.

## 0.5.0 — 2026-09-27 (development; not published)

- Recover selections, viewport anchors and navigation history in private session
  records; retain selection/position when navigating back and forward.
- Add Explorer/Mac keyboard presets, process overrides and VoiceOver modifier pass-through.
- Show Undo operation/count and explain unavailable replacement or incomplete groups.
- Keep file actions disabled until a newly loaded directory's projection is ready.
- Tie watcher registration to its own cancellable task and release operation/Cut
  leases explicitly, including when process launches overlap filesystem work.
- Add real APFS-volume copy/move/Trash/Undo and actual disk-full preservation tests.
- Add reproducible Release measurements for native listing/startup, memory, idle CPU
  and 50 pane lifecycle cycles; record local results in P5 documentation.
- Keep project schema version 1. Manual, Finder, physical/network-storage, minimum-OS
  and general release qualification remain open.

## 0.4.0 — 2026-09-26 (development; not published)

- Add folder creation, rename, file/folder copy and move, Trash, and bounded process-local Undo.
- Add Explorer shortcuts, selection/empty-area context menus and native file URL drag-and-drop.
- Add conflict choices (replace, skip, keep both), progress, file-boundary cancellation and partial-result reports.
- Coordinate mutations and clipboard Cut requests across processes with durable claims and kernel locks.
- Preserve staged originals after interrupted moves and expose retained data through a recovery menu.
- Preserve existing project ACLs during saves and remove inherited permissions from private new files.
- Extend English/Japanese UI and add integrity, concurrent-process and native AppKit action tests.
- Finder, physical cross-volume, manual input, accessibility and release qualification remain open.

## 0.3.0 — 2026-09-26 (development; not published)

- Add English/Japanese menus, browser controls, help, errors and accessibility labels.
- Add language selection, system fallback and a per-process launch override.
- Localize dates, byte counts and plural messages; adapt the toolbar for long labels.
- Bundle translations and MIT notices; test both languages in a relocated app.
- Add translation checks and expanded macOS CI.
- Prepare public documentation, Issue templates, security policy and synthetic demos.
- Add verified development ZIPs, SHA-256/build metadata and a notarization path.
- Add visually reviewed English/Japanese screenshots, a reproducible debug-only
  AppKit capture command and draft development release notes.
- Preserve verified CI development archives for 14 days when the workflow runs.
- Preserve project schema version 1 and user-supplied names and paths.
- Hosted CI, notarization and platform/manual qualification remain pending.

## 0.2.0 — 2026-09-25 (development)

- Add lazy folder trees, breadcrumbs, favorites and shared filesystem monitoring.
- Save and restore MDI projects, view settings and window placement.
- Add project switching, recent projects and unsaved-change confirmation.
- Protect project saves with process locks, external-change checks and atomic replacement.
- Add per-instance workspace recovery and versioned project validation.
- Add process, persistence and AppKit restoration tests and a browsing benchmark.
- File mutations and release qualification remain on the roadmap.

## 0.1.0 — 2026-09-25 (development)

- Add native AppKit MDI workspaces and independent application instances.
- Add directory listings, navigation history, sorting, filtering and keyboard routing.
- Add local app packaging, tests and macOS CI configuration.
