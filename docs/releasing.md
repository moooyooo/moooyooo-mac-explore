# Release preparation

**0.3.0 is a development preview.** Browsing/project persistence are available;
file operations and full P5 qualification remain incomplete.

## Source publication checklist

- [x] MIT license, English/Japanese README and contribution guidance.
- [x] English/Japanese app resources and translation checks.
- [x] Issue templates, security policy and dependency/asset provenance.
- [x] Local build/tests, archive verification and development packaging.
- [x] Synthetic sample generator and screenshot instructions.
- [ ] Review and capture English screenshots.
- [ ] Confirm upstream `moooyooo/moooyooo-mac-explore` and approve publication.
- [ ] Review tracked files/history for private data.
- [ ] Create upstream and enable/verify private vulnerability reporting.
- [ ] Push the reviewed branch, run CI on macOS 14/26 and record results.

No remote was configured during this preparation. GitHub authentication has been
checked as moooyooo. Repository creation and public push are separate publication actions.

## Local verification

```sh
python3 scripts/check-localizations.py
scripts/build-app.sh release
scripts/test.sh --integration
python3 scripts/verify-app.py
git diff --check
```

Verification checks bundle metadata, translations, notices, architecture, code
signature and accidental developer home paths. Relocated-app tests check that the
app loads its own translations. Integration tests need a macOS GUI session.
The CI workflow includes them but has not run on GitHub yet.
See [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Record Swift/OS versions and repeat a native build from a clean checkout.
macOS 14 is a deployment target until runtime validation succeeds. Builds use the
host architecture; do not label them universal.

## Development archive

```sh
scripts/package-release.sh --development
```

Ignored `dist/` contains `Moooyooo-Mac-Explore-0.3.0-arm64-dev.zip` (host architecture),
a `.sha256` checksum and `.build.txt` with version, commit, dirty/clean state and toolchain.
The script rebuilds, stages, archives, extracts and verifies the extracted app.
Existing artifacts are never overwritten; move old artifacts before repeating it.
Ad-hoc signing is for development and is not Developer ID signing or notarization.

Check an archive from its directory:

```sh
shasum -a 256 -c Moooyooo-Mac-Explore-0.3.0-arm64-dev.sha256
```

## Developer ID and notarization

**Not executed: this Mac currently has no valid signing identity.** The notarization
branch is prepared and syntax-checked; it needs real credentials and end-to-end verification.

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
No signing secrets go to pull-request CI. No nested executable/framework is bundled,
so signing does not use `--deep`.

Reports stay in ignored `.local/notarization/`. For a rejection or timeout, use
`notarytool info/log` with the submission ID and the same profile. Resolve the failure
before repackaging; do not distribute an unaccepted artifact or bypass Gatekeeper.
Follow Apple's [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Version and release notes

Update `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`,
the changelog and README together. Project schema version 1 is unchanged in 0.3.0.
UI language does not alter saved names, serialized keys or bookmark bytes.

Verify the exact clean commit before tagging `v0.3.0` (or a named prerelease).
Release notes must include tested platforms, incomplete features, known issues,
installation steps and checksums. Signing timestamps prevent byte-for-byte
reproducibility; retain the commit/toolchain record instead of promising identical hashes.

## First-download acceptance

Download the notarized artifact in a browser on a fresh Mac:

- Verify checksum, extract, install in Applications and launch with quarantine intact.
- Check Finder's name/type, Gatekeeper and the About version.
- Verify both languages, open/save dialogs and language selection.
- Exercise multiple MDI windows/processes and save/switch a synthetic project.
- Confirm save ownership, cancellation and recovery.
- Quit, replace the app with the next version and reopen a version-1 project.
- Removing the app must leave user files/projects intact. Preferences and recovery
  are stored separately under the app bundle identifier; delete them only deliberately.

Record OS, hardware, architecture, checksum, steps and results. Use synthetic content
in screenshots. Full P4/P5 acceptance is needed for a general-use file-manager release.
