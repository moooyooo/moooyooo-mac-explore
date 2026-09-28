# Release preparation

**0.7.2 is a development preview.** Browsing, projects, session recovery, basic
file operations and signed updates are available. Local performance targets pass; manual, external-storage
and supported-OS qualification remain incomplete.

## Source publication checklist

- [x] MIT license, English/Japanese README and contribution guidance.
- [x] English/Japanese app resources and translation checks.
- [x] Issue templates, security policy and dependency/asset provenance.
- [x] Local build/tests, archive verification and development packaging.
- [x] Synthetic sample generator and screenshot instructions.
- [x] Review and capture English/Japanese window content using synthetic files.
- [x] Draft development release notes and configure retention of verified CI artifacts.
- [x] Confirm upstream `moooyooo/moooyooo-mac-explore` and approve publication.
- [x] Review source/history for known private-data patterns and inspect screenshot metadata.
- [x] Create upstream and enable/verify private vulnerability reporting.
- [x] Push the reviewed branch, run CI on macOS 14/26 and record results.

The maintainer authorized public source publication on 2026-09-27. The upstream is
[moooyooo/moooyooo-mac-explore](https://github.com/moooyooo/moooyooo-mac-explore),
with `main` as its default branch and `origin` as the local remote.
Private vulnerability reporting, secret scanning and push protection are enabled.
Both matrix jobs passed in [the verified run](https://github.com/moooyooo/moooyooo-mac-explore/actions/runs/36286852444).
The [P6 verification record](p6-verification.md) records versions, test counts and scope.
For 0.7.1, macOS 14 passed but I-06 recurred in the macOS 26 two-process project test.
The [0.7.2 release record](releases/0.7.2.md) documents a successful follow-up on both OS versions.
The cause of intermittent I-06 remains unresolved; continue its investigation
before declaring the app qualified for general distribution.

## Local verification

```sh
python3 scripts/check-localizations.py
python3 -m unittest discover -s Tests/ScriptTests
scripts/build-app.sh release
scripts/test.sh --integration
scripts/test-volumes.sh
python3 scripts/test-updates.py
python3 scripts/test-sidebar.py
python3 scripts/verify-app.py
git diff --check
```

Verification checks bundle metadata, translations, notices, architecture, code
signature and accidental developer home paths. Relocated-app tests check that the
app loads its own translations. Integration tests need a macOS GUI session.
The [CI workflow](https://github.com/moooyooo/moooyooo-mac-explore/actions/workflows/ci.yml)
includes them. The test wrapper also requires a successful final Swift Testing total;
exit status 0 alone is not a passing run.
See [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Run `scripts/benchmark-ui.sh` separately on the reference Mac with a GUI session.
It includes 60 seconds of idle sampling and creates only synthetic files.
Timing budgets are not CI runner gates: shared runner load is not a stable
performance baseline. See the 0.5.0 baseline and 0.6.0 qualification notes in [P5 measurements](p5-verification.md).

The [English/Japanese screenshots](screenshots.md) show real AppKit window content
using synthetic files. Their debug-only export command is excluded from release
executables and checked by `verify-app.py`. Visual review of these images does not
replace input, accessibility or native-dialog testing.

Record Swift/OS versions and repeat a native build from a clean checkout.
macOS 14 is a deployment target until runtime validation succeeds. Builds use the
host architecture; do not label them universal.

## Development archive

```sh
scripts/package-release.sh --development
```

Ignored `dist/` contains `Moooyooo-Mac-Explore-0.7.2-arm64-dev.zip` (host architecture),
a `.sha256` checksum and `.build.txt` with version, commit, dirty/clean state and toolchain.
The script rebuilds, stages, archives, extracts and verifies the extracted app.
Existing artifacts are never overwritten; move old artifacts before repeating it.
Ad-hoc signing is for development and is not Developer ID signing or notarization.

Check an archive from its directory:

```sh
shasum -a 256 -c Moooyooo-Mac-Explore-0.7.2-arm64-dev.sha256
```

## Retrieve CI artifacts

After a workflow succeeds, open **Actions → macOS build
and test → the run → Artifacts**. Each matrix job uploads
`development-<runner OS>-<architecture>` containing the development ZIP, checksum
and build record. The retention period is 14 days. Sign in to GitHub to download
workflow artifacts.

Extract the artifact download first, then check the inner app ZIP with its
`.sha256` file. Compare the commit and `source_state=clean` in `.build.txt` with the
reviewed run. The inner ZIP preserves the app bundle's executable permissions.
Keep the build record with any retained archive. This workflow does not sign with
Developer ID, submit to Apple, tag a release or publish a GitHub Release.
See [GitHub's artifact download instructions](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

## Developer ID and notarization

**Not executed: the maintainer confirmed on 2026-09-28 that Apple Developer Program
enrollment is pending.** This Mac has no valid signing identity. The notarization
branch needs real credentials and end-to-end verification.

1. Install the maintainer's Developer ID Application certificate in Keychain.
2. Store credentials interactively with `xcrun notarytool store-credentials`.
   Use a dedicated Keychain profile. Do not put secrets in Git or shell history.
3. Commit reviewed changes; notarized packaging requires a clean worktree.
4. Set the certificate name and profile, then explicitly request notarization:

```sh
export MACEXPLORE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export MACEXPLORE_NOTARY_PROFILE='MacExplore-Notary'
scripts/package-release.sh --notarize
```

This uploads a signed archive to Apple. The script enables Hardened Runtime and a
secure timestamp, waits for Accepted, staples/validates the ticket, checks Gatekeeper,
then repackages the stapled app. It operates on a staged copy of the local app.
No signing secrets go to pull-request CI. `scripts/sign-app.sh` signs Sparkle's
XPC services, Autoupdate tool, Updater.app and framework before the outer app.
It preserves the downloader's entitlements, uses Hardened Runtime/timestamps for
Developer ID, and uses `--deep` only for verification.

Reports stay in ignored `.local/notarization/`. For a rejection or timeout, use
`notarytool info/log` with the submission ID and the same profile. Resolve the failure
before repackaging; do not distribute an unaccepted artifact or bypass Gatekeeper.
Follow Apple's [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Version and release notes

Update `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`,
the changelog and README together. Project schema version 1 is unchanged in 0.7.2.
UI language does not alter saved names, serialized keys or bookmark bytes.
The [0.7.2 release notes draft](releases/0.7.2.md) lists features, known limitations
and local build instructions; add the actual publication/CI/artifact information
when it exists.

Verify the exact clean commit before tagging `v0.7.2` (or a named prerelease).
Release notes must include tested platforms, incomplete features, known issues,
installation steps and checksums. Signing timestamps prevent byte-for-byte
reproducibility; retain the commit/toolchain record instead of promising identical hashes.

## Automatic update publication

See [updates](updates.md) for moooyooo's Keychain account, first manual installation,
the signed feed, and `scripts/prepare-update.py`. The latter accepts only a
notarized archive from a clean checkout and prepares local upload artifacts.
Publish and anonymously verify the GitHub Release ZIP before committing the signed
appcast to `main`. Do not edit signed XML afterward. The current feed contains no releases.
Only the public key is tracked; private keys must not enter source or CI.

## First-download acceptance

Download the notarized artifact in a browser on a fresh Mac:

- Verify checksum, extract, install in Applications and launch with quarantine intact.
- Check Finder's name/type, Gatekeeper and the About version.
- Verify both languages, open/save dialogs and language selection.
- Exercise multiple MDI windows/processes and save/switch a synthetic project.
- Confirm save ownership, cancellation and recovery.
- Test both manual replacement and an in-app signed update to the next build.
  Exercise busy operations, other processes, cancellation, workspace restoration,
  installation permission failure and interrupted downloads.
- Removing the app must leave user files/projects intact. Preferences and recovery
  are stored separately under the app bundle identifier; delete them only deliberately.

Record OS, hardware, architecture, checksum, steps and results. Use synthetic content
in screenshots. Full P4/P5 acceptance is needed for a general-use file-manager release.
