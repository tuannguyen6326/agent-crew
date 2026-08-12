#!/usr/bin/env bash
# dashboard.test.sh - thin wrapper so bin/dashboard.test.ts (Bun) runs as part
# of the canonical suite. Before this file, the dashboard's write-endpoint
# security assertions (isEditableConfig, applyConfigWrite/applyDispatchWrite
# refusing writes, parseArtifactPath traversal rejection, ...) were reachable
# only by a manual `bun test`, so a regression in any of them kept
# tests/run-suite.sh green (repo-deep-review F21).
#
# Skips cleanly - never a failure - when bun is absent: same house style as
# the timeout/gtimeout probe at tests/run-suite.sh:153-159, a missing tool
# must never read as a test failure.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v bun >/dev/null 2>&1 || { printf 'SKIP: bun not available - bin/dashboard.test.ts skipped\n'; exit 0; }

bun test "$ROOT/bin/dashboard.test.ts"
pass
