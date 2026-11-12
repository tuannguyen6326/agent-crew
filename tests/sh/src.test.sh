#!/usr/bin/env bash
# src.test.sh - runs the Bun unit tests in tests/ts/ (tests/ts/*.test.ts, the pure
# layer of the TypeScript under src/) as part of the canonical suite;
# tests/run-suite.sh --changed maps src/*.ts and tests/ts/*.test.ts here. Every
# test runs unless AC_SRC_TESTS names the basenames to run (run-suite's BUN
# NARROWING hands them over; the line printed says which of the two
# happened); a name with no file under tests/ts is a runner defect and is
# refused, exit 2 - never read as "all" and never dropped. No bun-absent
# skip, unlike dashboard.test.sh: bun is a required tool since bin/ runs the
# TypeScript under src/ on it - the ported entries and the helpers other
# scripts start (bin/ac-bootstrap.sh).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

all=("$ROOT"/tests/ts/*.test.ts)
if [ -n "${AC_SRC_TESTS-}" ]; then
  files=()
  for n in $AC_SRC_TESTS; do
    [ -e "$ROOT/tests/ts/$n" ] || { printf 'src.test.sh: AC_SRC_TESTS names no Bun test under tests/ts: %s\n' "$n" >&2; exit 2; }
    files+=("$ROOT/tests/ts/$n")
  done
  [ "${#files[@]}" -gt 0 ] || { printf 'src.test.sh: AC_SRC_TESTS is set but names nothing\n' >&2; exit 2; }
  printf 'src.test.sh: %s of %s Bun tests (narrowed by run-suite --changed)\n' "${#files[@]}" "${#all[@]}"
  bun test "${files[@]}"
else
  printf 'src.test.sh: all %s Bun tests\n' "${#all[@]}"
  bun test "${all[@]}"
fi
pass
