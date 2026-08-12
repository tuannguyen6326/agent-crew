#!/usr/bin/env bash
# stress.test.sh - the stress harness's accounting. A stress runner that cannot
# report failure is decoration: helpers.sh sets errexit, the fan-out subshell
# inherits it, and a red run aborted before writing its .rc - so the failures
# went missing and the tally still read green. This pins that a red run is
# COUNTED, that every run lands in exactly one column, and the exit status.
#
# Hogs are 0 here on purpose: the accounting is the subject, and this file has
# no business loading the box to prove it.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

printf '#!/usr/bin/env bash\n. "%s/tests/helpers.sh"\npass\n' "$ROOT" >"$TMP/green.test.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/helpers.sh"\nfail "deliberately red"\n' "$ROOT" >"$TMP/red.test.sh"

run_stress() {
  # run_stress <file> - prints "<rc>|<output>"; never lets a red run kill us.
  # AC_STRESS_LOAD1=0 injects an idle host: without it the preflight would
  # refuse whenever the box happens to be busy, making this file load-flaky -
  # the exact sin the harness exists to fix.
  local out rc
  set +e
  out="$(AC_STRESS_LOAD1=0 bash "$ROOT/tests/stress.sh" "$1" 2 2 0 2>&1)"
  rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}

# A red run is COUNTED as a fail - the defect this file exists for.
res="$(run_stress "$TMP/red.test.sh")"
assert_contains "${res#*|}" "0 pass, 2 fail (of 2)" "a red run is counted, not lost"
assert_contains "${res#*|}" "deliberately red" "the failure text is surfaced"
assert_eq "${res%%|*}" "1" "stress exits non-zero when a run fails"

# ... and a green one still reads green, so the fix did not just invert it.
res="$(run_stress "$TMP/green.test.sh")"
assert_contains "${res#*|}" "2 pass, 0 fail (of 2)" "green runs tally"
assert_eq "${res%%|*}" "0" "stress exits 0 when every run passes"

# The survivor gate must still RUN when a run dies without printing FAIL - a
# crash, an OOM kill, an unbound var, which is the class stress exists to
# surface. The ^FAIL grep finds nothing, and under pipefail+errexit that
# aborted the script before the reap and the gate ever ran. The red case above
# cannot see this: `fail` prints FAIL, so the grep matches and the abort never
# fires.
printf '#!/usr/bin/env bash\n. "%s/tests/helpers.sh"\nexit 3\n' "$ROOT" >"$TMP/crash.test.sh"
res="$(run_stress "$TMP/crash.test.sh")"
assert_contains "${res#*|}" "0 pass, 2 fail (of 2)" "a silent crash is counted"
assert_contains "${res#*|}" "hogs:" "the survivor gate runs even with no FAIL token to grep"

# Host budget: refuse a busy host, and never take more than half the cores.
# The load is injected, not spun up - a test that manufactured real load to
# prove the refusal would be the thing this harness exists to prevent.
set +e
out="$(AC_STRESS_LOAD1=9999 bash "$ROOT/tests/stress.sh" "$TMP/green.test.sh" 2 2 0 2>&1)"
rc=$?
set -e
assert_eq "$rc" "2" "a busy host is refused"
assert_contains "$out" "refusing" "the refusal says why"

out="$(AC_STRESS_LOAD1=0 bash "$ROOT/tests/stress.sh" "$TMP/green.test.sh" 1 1 9999 2>&1)"
assert_contains "$out" "capping hogs 9999" "the hog count is capped, never all cores"

# repo-deep-review F54: an unreadable (non-numeric) load1 must refuse, not
# fail open. `[ "${load1%%.*}" -gt "$half" ] 2>/dev/null` used to swallow the
# arithmetic error on garbage input, so the refusal never fired and the load
# generator ran on a host whose load could not be read.
set +e
out="$(AC_STRESS_LOAD1=n/a bash "$ROOT/tests/stress.sh" "$TMP/green.test.sh" 2 2 0 2>&1)"
rc=$?
set -e
assert_eq "$rc" "2" "an unreadable load1 must refuse, not fail open"
assert_contains "$out" "refusing" "the refusal says why"

pass
