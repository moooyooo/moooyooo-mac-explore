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
recovery claims and symlink handling. The app has no telemetry, update server,
embedded browser or network service. User-selected directories may be network mounts.
Project storage is currently restricted to local regular files.
