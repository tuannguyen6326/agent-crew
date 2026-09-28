#!/usr/bin/env bash
# src.test.sh - runs every Bun unit test in tests/ts/ (tests/ts/*.test.ts, the pure
# layer of the TypeScript under src/) as part of the canonical suite;
# tests/run-suite.sh --changed maps src/*.ts and tests/ts/*.test.ts here. No
# bun-absent skip, unlike dashboard.test.sh: bun is a required tool since bin/
# runs the TypeScript under src/ on it - the ported entries and the helpers
# other scripts start (bin/ac-bootstrap.sh).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

bun test "$ROOT"/tests/ts/*.test.ts
pass
