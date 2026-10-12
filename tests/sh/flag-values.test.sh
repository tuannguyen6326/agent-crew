#!/usr/bin/env bash
# flag-values.test.sh - a value flag given as the last word fails loudly.
# `--x) v="${2:-}"; shift 2 ;;` reads the missing value as empty, and the
# `shift 2` then fails: under set -e the script exits 1 with no message, and
# without it the flag loop never advances. Every such arm guards its shift.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

hits="$(LC_ALL=C grep -n -E '\$\{2:?-[^}]*\}.*shift 2' "$BIN"/*.sh \
  | LC_ALL=C grep -v -E '\|\||^[^:]+:[0-9]+:[[:space:]]*#' || true)"
assert_eq "$hits" "" "every flag arm that reads a missing value as empty guards its shift"

rc=0; out="$("$BIN/ac-know.sh" add --fact 2>&1)" || rc=$?
assert_eq "$rc" "1" "a trailing --fact fails"
assert_contains "$out" "--fact needs a value" "... naming the flag"

rc=0; out="$("$BIN/ac-brain.sh" recall --home 2>&1)" || rc=$?
assert_eq "$rc" "1" "a trailing --home fails ac-brain.sh"
assert_contains "$out" '"error":"invalid_params"' "... in ac-brain.sh's JSON error contract"
assert_contains "$out" "--home needs a value" "... naming the flag"

pass
