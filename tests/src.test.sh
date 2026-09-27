#!/usr/bin/env bash
# src.test.sh - runs every Bun unit test in tests/ (tests/*.test.ts, the pure
# layer of the TypeScript under src/) as part of the canonical suite;
# tests/run-suite.sh --changed maps src/*.ts and tests/*.test.ts here. No
# bun-absent skip, unlike dashboard.test.sh: bun is a required tool since the
# ported entries in bin/ exec it (bin/ac-bootstrap.sh).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

bun test "$ROOT"/tests/*.test.ts
pass
