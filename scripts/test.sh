#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" == "--integration" ]]; then
    export MACEXPLORE_TEST_APP="$project_dir/build/Moooyooo Mac Explore.app"
    if [[ ! -x "$MACEXPLORE_TEST_APP/Contents/MacOS/MacExplore" ]]; then
        echo "Run scripts/build-app.sh release before integration tests." >&2
        exit 2
    fi
    shift
fi
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_runtime="$developer_dir/Library/Developer/usr/lib"

# Some Command Line Tools releases ship Swift Testing without SwiftPM's search paths.
# Full Xcode uses SwiftPM's normal configuration.
if [[ -d "$testing_frameworks/Testing.framework" && -f "$testing_runtime/lib_TestingInterop.dylib" ]]; then
    swift test -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_runtime" "$@"
else
    swift test "$@"
fi
