#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
scripts/build-app.sh release
mkdir -p .local
report_dir="$(mktemp -d "$project_dir/.local/performance.XXXXXX")"
export MACEXPLORE_PERFORMANCE_DIRECTORY="$report_dir"
export MACEXPLORE_TEST_APP="$project_dir/build/Moooyooo Mac Explore.app"
printf 'Qualification reports: %s\n' "$report_dir"
scripts/test.sh -c release --filter "UIQualificationTests${1:+/$1}"
printf 'Qualification reports: %s\n' "$report_dir"
