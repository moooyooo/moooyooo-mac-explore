# Security reporting

This is development software. Only the current development branch receives fixes;
there is no supported stable release yet.

## Report privately

The planned upstream is `moooyooo/moooyooo-mac-explore`. Before the first public
release, the maintainer must enable **Private vulnerability reporting** on GitHub.
Once enabled, use **Security → Advisories → Report a vulnerability** in the upstream
repository. See [GitHub's reporting setup](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).

**Current status: no upstream repository or private reporting endpoint has been
set up by this project yet.** Until it is enabled, contact moooyooo through an
existing private channel. Do not publish sensitive exploit details in an Issue.
Activation and verification of the reporting endpoint is a source-publication gate.

Include the app version/commit, macOS version, impact, and minimal reproduction
steps using synthetic files. Do not attach credentials, signing keys, private file
contents, home directory listings, recovery files or unredacted `.mexplore` files.
Projects can contain absolute paths and bookmark data.

## Scope

Relevant areas include project decoding, bookmarks, save replacement, process locks,
recovery claims and symlink handling. The app has no telemetry, update server,
embedded browser or network service. User-selected directories may be network mounts.
Project storage is currently restricted to local regular files.
