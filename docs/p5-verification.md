# P5 quality and performance verification

Updated 2026-09-27. Version 0.5.0 is a development preview. P5 remains in progress
because manual input, accessibility, display and supported-OS checks are outstanding.

## Functional additions

- Private session snapshots now preserve selected names, a visible-row anchor,
  horizontal/vertical position and validated back/forward history. Native AppKit
  tests restore these into a fresh window, including an inserted file before the
  anchor and Forward navigation after recovery. Selection/scrolling do not dirty
  the project; old recovery records and project schema version 1 remain compatible.
- Explorer/Mac shortcut presets update immediately. A stored choice propagates
  when another process becomes active; launch overrides remain process-specific.
  Core tests cover native Control editing, IME protection and VoiceOver modifiers.
  VoiceOver spoken output has not been qualified.
- Undo menus display operation/count and reasons for unavailable groups.
- File actions stay disabled until the new directory's projection is ready.
  Watcher registration has its own cancellable task, so cancelling a read cannot
  leave its URL marked as watched without an active subscription.
- Regression testing exposed transient lock retention when file operations overlap
  process launches. Leases now explicitly unlock/close, with idempotent release and
  immediate reacquisition tests. Cut claims have explicit closure and refuse reuse.

## Measurement method

Reference environment: Mac14,6 / Apple M2 Max / 64 GiB RAM / internal APFS SSD /
macOS 26.5 (25F71) / Swift 6.3.2, Command Line Tools.

`scripts/benchmark-ui.sh` builds Release and writes reports under ignored `.local/`.
Native listing/lifecycle tests use Japanese; packaged application tests explicitly
use English and the Explorer preset. No preview or third-party runtime is involved.
Fixtures contain generated small UTF-8 text files. Filesystem caches are warm.

Listing timing starts at path confirmation and ends after sorted rows, native layout,
`displayIfNeeded` and Core Animation submission. Startup includes the NSWorkspace
launch request through that same readiness point, using ten launches after one
discarded warmup. Neither measure claims physical monitor scanout latency.
App memory is sampled after a three-second settling interval.
Idle CPU uses process CPU-time deltas for at least 60 seconds; one logical core is 100%.
Test framework overhead is excluded from packaged app memory.

### Listing and lifecycle results

| Check | Observed | Target/result |
| --- | --- | --- |
| 1,000 items, ten runs | p95 46.52 ms | ≤300 ms; pass |
| 10,000 items, ten runs | p95 166.31 ms | ≤1 second; pass |
| 100,000 items | 1.414 seconds | Separate large-folder measurement |
| Main actor heartbeat gap during 100,000-item load | Maximum 55.69 ms | 10 ms requested cadence; <250 ms responsiveness guard |
| 50 pane open/close cycles, 1,000 items each | Every browser deallocated; watch count returns to 0 after every close | Pass |
| Closed-pane test process footprint | Last-ten vs first-ten median +0.438 MiB | <16 MiB growth guard; no persistent browser/watch retention |

The 100,000-item test process footprint was 163.13 MiB, including Swift Testing.
It is not the single-pane packaged app memory result.
Raw [listing](metrics/0.5.0/listing.json) and [lifecycle](metrics/0.5.0/lifecycle.json)
samples are preserved without private paths.

### Packaged app results

The application series verifies one parent/one pane and two parents/six panes.
The final multi-pane series uses six distinct 1,000-item directories across two
saved projects. A single-pane and a six-pane process remain open together during
idle measurement, with their individual and total load recorded.

| Check | Observed | Target/result |
| --- | --- | --- |
| Warm launch, ten runs | p95 377.69 ms | ≤1 second; pass |
| One parent / one pane | 34.11 MiB | ≤150 MiB; pass |
| Two parents / six distinct folders | 89.00 MiB | ≤350 MiB; pass |
| Concurrent one-pane + six-pane processes | 123.11 MiB combined | Per-process values above |
| Idle CPU, 60.84 seconds | One pane 0.000%, six panes 0.0164%; total 0.0164% | Each <1%; pass |
| Apple Silicon .app, regular-file byte total | 2.03 MiB | ≤50 MiB; pass |

The zero CPU delta is below the `ps` CPU-time reporting resolution; it does not
mean the process never executes instructions. [Raw application samples](metrics/0.5.0/application.json)
include each startup value, single-pane footprints and both idle samples.

## Reproduction and gates

`scripts/test.sh --integration` passed in 8.148 seconds with 81 declared tests:
75 ran without failures and six opt-in volume/performance tests were skipped.
The three APFS volume tests and three Release performance tests run separately.
Native AppKit tests invoke controls/actions, not physical mouse/keyboard input.
English/Japanese resource checking covers 222 keys. The final volume run passed
all three tests in 0.432 seconds. The Release performance suite passed all three
tests in 139.762 seconds; the packaged-app series was then repeated with six
distinct folders and passed in 108.239 seconds.

The final Release 0.5.0 (5) bundle passes metadata, arm64 architecture, English/Japanese
resources, bundled license and ad-hoc signature checks. The public-source scan
finds no known developer home-path, private-key or common token patterns. It is a
bounded pattern check, not a guarantee against all security defects.

`scripts/test-volumes.sh` creates a dedicated 128 MiB APFS image, verifies copy,
move, native Trash, Undo and an actual out-of-space error, then detaches it.
Originals and an existing destination survive the capacity failure. The CI definition
now includes this command; hosted CI has not run.

The opt-in performance suite is kept separate from CI timing gates because shared
runner load is not a stable baseline. The method and budgets are in
[requirements](requirements.md). Performance samples are local observations on
this hardware, not guarantees for all Macs or storage devices.

## Remaining qualification

- Physical mouse/keyboard, JIS/US, IME composition, real MDI focus and save-confirmation flows.
- Finder/app and independent-process drag sequences, live modifier changes and cursor feedback.
- Physical removable/network drives, unplugging during I/O, large-file cancellation/progress.
- VoiceOver reading/navigation, contrast, light/dark appearances and display scale changes.
- macOS 14 and hosted CI; Intel remains unqualified.
- Developer ID, notarization, first download and upstream publication (see [P6](p6-verification.md)).

Computer Use was retried on 2026-09-27 and still reports pending Accessibility/Screen
Recording permissions. Automated AppKit actions and content-rendered screenshots
do not constitute verification of those missing desktop interactions.
