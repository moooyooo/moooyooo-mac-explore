# Contributing

English and Japanese contributions are welcome. Maintainer: [moooyooo](https://github.com/moooyooo).
This is a development preview; see the [roadmap](docs/roadmap.en.md).

Read the [requirements](docs/requirements.md), [UX](docs/ux.md) and
[architecture](docs/architecture.md), currently in Japanese. Keep MDI panes,
independent processes and projects working together. Prefer system frameworks;
document the size and runtime impact of new dependencies.

Use a focused branch. Code and identifiers use English, four-space indentation,
UTF-8 and LF. Put app-owned interface text in the shared [localization catalog](docs/localization.md).

## Verification

```sh
python3 scripts/check-localizations.py
scripts/build-app.sh release
scripts/test.sh --integration
python3 scripts/verify-app.py
git diff --check
```

Integration tests require an active macOS GUI session. They create and terminate
their own app processes; they do not synthesize mouse/keyboard input. Distinguish
model tests, AppKit controller checks and manual interaction in your report.

Use temporary directories and synthetic data for file-operation tests. Changes
affecting saving, locks, cancellation or recovery need failure-path coverage.
Preserve original files on failure. UI changes require keyboard, IME and accessibility
checks in both languages; record untested cases. Measure performance in release builds.

## Pull requests

Describe the problem, changed behavior, requirement/issue, verification and remaining
limitations. Update README, changelog and related design documents. Do not mark
roadmap stages complete based only on implementation.

Never commit credentials, signing keys, personal projects/recovery records, private
paths or unreviewed screenshots. Use [synthetic fixtures](examples/README.md).
Use your own Git identity; the original maintainer identity is moooyooo.
Report vulnerabilities through [SECURITY.md](SECURITY.md).

Contributions are made under this repository's [MIT license](LICENSE).
