# Synthetic workspace

Generate a real two-pane project using synthetic files:

```sh
python3 scripts/create-demo.py /tmp/MacExplore-Demo
open -n "build/Moooyooo Mac Explore.app" --args \
  --language en \
  --project /tmp/MacExplore-Demo/Development.mexplore \
  --support-directory /tmp/MacExplore-Demo/AppState
```

The generator refuses to overwrite an existing destination. Choose another fresh
directory for a second run. The generated project contains absolute local URLs and
no bookmark data; it is generated locally instead of committing machine-specific
project files. All source, documents and output files are invented. Modification
dates are fixed to 2026-09-25 09:00 UTC; the saved window is 1440 × 820 points.

For screenshots, use the neutral `/tmp/MacExplore-Demo` location rather than your
home folder. Capture only the app window. Check the address bars, breadcrumbs,
sidebar, recent-project menu, desktop and menu bar for private information before
adding a screenshot to the repository. Never use daily-work files as fixtures.

The `--support-directory` override isolates recent projects and recovery records.
Use the same override for every process participating in this demo.

## Reproduce the documentation images

```sh
python3 scripts/capture-screenshots.py --output .local/screenshots
```

This builds a separate debug app, creates a temporary fixture, exports both languages,
and closes only the app processes it starts. Existing images are never overwritten.
It needs a macOS GUI session. See [capture details](../docs/screenshots.md) for the
reviewed images, output metadata and the distinction from a desktop screenshot.
