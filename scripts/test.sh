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

swift_options=(test)
# Some Command Line Tools releases ship Swift Testing without SwiftPM's search paths.
# Full Xcode uses SwiftPM's normal configuration.
if [[ -d "$testing_frameworks/Testing.framework" && -f "$testing_runtime/lib_TestingInterop.dylib" ]]; then
    swift_options+=(-Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_runtime")
fi

for argument in "$@"; do
    case "$argument" in
        --help|-help|-h|--version|list|last|--list-tests|-l|--show-codecov-path|--show-code-coverage-path)
            exec swift "${swift_options[@]}" "$@" ;;
    esac
done

run_tests() (
    test_log="$(mktemp "${TMPDIR:-/tmp}/macexplore-tests.XXXXXX")"
    trap 'rm -f "$test_log"' EXIT
    swift "${swift_options[@]}" "$@" 2>&1 | tee "$test_log"
    python3 scripts/check-test-completion.py "$test_log"
)

# Swift 6.2+ can exit 0 with async main unfinished if AppKit stops its run loop
# (swiftlang/swift#91716). A completed test total is mandatory.
run_tests "$@"
