# Security reporting

This is development software. Only the current development branch receives fixes;
there is no supported stable release yet.

## Report privately

Use [Report a vulnerability](https://github.com/moooyooo/moooyooo-mac-explore/security/advisories/new)
in the upstream repository, or choose **Security → Advisories → Report a vulnerability**.
Private vulnerability reporting was enabled and verified on 2026-09-27.
Do not publish sensitive exploit details in an Issue.

Include the app version/commit, macOS version, impact, and minimal reproduction
steps using synthetic files. Do not attach credentials, signing keys, private file
contents, home directory listings, recovery files or unredacted `.mexplore` files.
Projects can contain absolute paths and bookmark data.

## Scope

Relevant areas include project decoding, bookmarks, save replacement, process locks,
recovery claims, symlink handling and the Sparkle update integration. The app has
no telemetry or listening network service. With update checking enabled, it requests
the signed feed from GitHub and downloads updates from GitHub Releases over HTTPS.
Automatic checks/downloads are opt-in; no system profile, project paths or file
contents are sent. GitHub receives ordinary network metadata such as IP address
and HTTP user agent. Sparkle uses the system WebKit for its release-note view.
User-selected directories may be network mounts.
Project storage is currently restricted to local regular files.

The pinned Sparkle dependency validates Ed25519 signatures before extraction.
The app also rejects appcast items whose feed signature did not succeed, invalid
build numbers and archive URLs outside the moooyooo repository's release path.
The production private key lives in the maintainer's login Keychain. Only its
public key and signed appcast are in Git. A compromised maintainer signing key
is outside this trust boundary; treat key backup and release access as sensitive.
The update checkpoint is private local data and must never be attached to Issues.
See [updates and recovery](docs/updates.md) and [upstream Sparkle security](https://sparkle-project.org/documentation/security-and-reliability/).
