#!/usr/bin/env bash
# TWO independent suites over the same script, appended - neither replaces the
# other. ORDER IS LOAD-BEARING: the qa-infra suite runs FIRST, in the pristine
# home helpers.sh exports; the crewdeputy suite runs SECOND and is insulated
# because it drives the digest with AC_HOME pointed at a home it creates
# itself. Swapped, the qa-infra suite would inherit a fake herdr on PATH and a
# crewdeputies/ dir under $AC_HOME that it was never written against.
#
# ac-session-start.test.sh - the per-project qa-infra reap sweep (the last
# ride-along before the fleet view) is BOUNDED: a wedged docker daemon
# (`docker ps -a` hangs, observed live 2026-07-28: 6m27s and still hung) must
# warn and CONTINUE the digest, never park session start forever. A fast,
# ordinary docker with nothing to reap must print no spurious warning (the
# reap pipeline ends in `| grep '^reaped'`, which exits 1 - the pre-existing
# no-match case - under `set -o pipefail`; only a real timeout (124) warns).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# A qa-eligible project: the sweep only looks at projects carrying .crew (see
# ac-session-start.sh's own gate), and ac-qa.sh itself requires a real git
# repo before it ever reaches the docker call.
proj="$AC_HOME/projects/proj1"
mkdir -p "$proj/.crew"
git init -q "$proj"

dstub="$TMP/dstub"; mkdir -p "$dstub"
export PATH="$dstub:$PATH"
export AC_SESSION_QA_TIMEOUT=1   # the production bound must not be sat out by a test

# (1) A HUNG docker (daemon wedged: `docker ps -a` never returns) is killed by
# the watchdog and the digest still completes past the bound instead of
# hanging forever.
cat >"$dstub/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"$TMP/hang.pid"
exec sleep 30
EOF
chmod +x "$dstub/docker"

"$BIN/ac-session-start.sh" >"$TMP/hung.out" 2>&1 &
sspid=$!
# A ceiling of the test's own: without it an unbounded sweep hangs the suite
# instead of failing it, and a hang proves nothing.
i=0
while [ "$i" -lt 50 ] && kill -0 "$sspid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$sspid" 2>/dev/null; then
  kill -9 "$sspid" 2>/dev/null || true
  fail "a hung docker parked session start at the qa-infra reap sweep"
fi
wait "$sspid" || fail "a hung docker must not fail session start"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
hung="$(cat "$TMP/hung.out")"
assert_contains "$hung" "proj1" "the warning names the stuck project"
assert_contains "$hung" "ac-qa.sh infra reap" "the warning names the recovery command"
assert_contains "$hung" "-- fleet --" "the digest continues past the hung sweep"

# (1b) The SAME hung docker (dstub/docker still the hanging stub from case
# (1)), but with session start's stdout captured through a PIPE (command
# substitution) rather than redirected to a file - the actual shape a chief
# uses every session (AGENTS.md section 3: run ac-session-start.sh and read
# its output, or a harness tool call capturing stdout). A file has no
# writer/EOF semantics, so case (1) alone cannot see an orphaned
# `grep '^reaped'` left holding a caller fd open; a pipe can, and does,
# unless the bounded child's fds are kept off the caller's entirely.
(
  piped_out="$("$BIN/ac-session-start.sh" 2>/dev/null)"
  printf '%s' "$piped_out" >"$TMP/piped.out"
  : >"$TMP/piped.done"
) &
pipedpid=$!
i=0
while [ "$i" -lt 50 ] && [ ! -f "$TMP/piped.done" ]; do sleep 0.2; i=$((i + 1)); done
if [ ! -f "$TMP/piped.done" ]; then
  kill -9 "$pipedpid" 2>/dev/null || true
  fail "a hung docker parked a PIPED session-start capture past the bound"
fi
wait "$pipedpid" || fail "a hung docker must not fail a piped session start"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
assert_contains "$(cat "$TMP/piped.out")" "-- fleet --" "a piped capture still completes past the hung sweep"

# (1c) The SAME hung docker again, captured with a MERGED `2>&1` pipe - the
# same shape case (2) below already uses for an ordinary run. stdout alone
# being redirected to a temp file (case 1b's fix) still leaves the bounded
# subshell's fd 2 inherited from the caller; an orphaned grep holding THAT
# open blocks a `2>&1` capture just as surely as fd 1 alone blocked case (1b).
rm -f "$TMP/hang.pid" "$TMP/piped.done"
(
  piped_out="$("$BIN/ac-session-start.sh" 2>&1)"
  printf '%s' "$piped_out" >"$TMP/piped2.out"
  : >"$TMP/piped.done"
) &
pipedpid=$!
i=0
while [ "$i" -lt 50 ] && [ ! -f "$TMP/piped.done" ]; do sleep 0.2; i=$((i + 1)); done
if [ ! -f "$TMP/piped.done" ]; then
  kill -9 "$pipedpid" 2>/dev/null || true
  fail "a hung docker parked a MERGED (2>&1) session-start capture past the bound"
fi
wait "$pipedpid" || fail "a hung docker must not fail a merged-capture session start"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
assert_contains "$(cat "$TMP/piped2.out")" "-- fleet --" "a merged capture still completes past the hung sweep"

# (2) An ordinary FAST docker with nothing to reap prints no warning - the
# reap pipeline's own no-match exit (grep '^reaped' finds nothing) must not
# be mistaken for a timeout.
cat >"$dstub/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$dstub/docker"
out="$("$BIN/ac-session-start.sh" 2>&1)"
case "$out" in
  *"WARN:"*"proj1"*) fail "an ordinary empty reap must not warn: $out" ;;
esac
assert_contains "$out" "-- fleet --" "the digest still completes"

rm -f "$dstub/docker"
unset AC_SESSION_QA_TIMEOUT

# ac-session-start.test.sh - the crewdeputy config-converge ride-along
# (bin/ac-session-start.sh:72-83) must resolve its PARENT config dir from the
# LIVE AC_HOME by walking `$home/../../config` - tests/ac-config-converge.test.sh
# only ever drives the underlying ac_config_converge_from_parent function with
# a hand-picked parent path, never through this script's own path derivation,
# and tests/ac-lock.test.sh/ac-learn.test.sh drive other digest blocks without
# ever using a crewdeputy home. An off-by-one here would silently starve every
# crewdeputy of its inherited config with nothing else to catch it.

make_fake_herdr
make_home

dep="$AC_HOME/crewdeputies/dep1"
mkdir -p "$dep/state" "$dep/config"
: >"$dep/.ac-crewdeputy-home"
printf 'opus\n' >"$AC_HOME/config/model"

out="$(AC_HOME="$dep" "$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$out" "-- config converge (from parent) --" "the ride-along header prints for a crewdeputy home"
assert_contains "$out" "converged: model" "it pulls a drifted inheritable knob from the REAL parent path"
assert_eq "$(cat "$dep/config/model")" "opus" "the value actually lands in the deputy's own config"

# --- the crewdomain routing block, and the detection that rides on it --------
# It prints UNCONDITIONALLY beside the crewdeputy block, and it carries one duty
# that block does not: `ac-domain.sh list` runs the provenance audit, so a row
# no `assign` stamped is surfaced at EVERY crewchief session start. Chief-only-
# add is only as strong as its detection, and this is where the detection lives.
mkdir -p "$AC_HOME/crewdomains/payments/records"
printf -- '- payments - the payments domain - scope: money (added 2026-08-02T00:00:00Z)\n' \
  >"$AC_HOME/records/crewdomains.md"
printf '# Backlog: payments\n\n## In flight\n\n## Queued\n\n- [ ] snuck-in - nobody assigned this (repo: alpha)\n\n## Done\n' \
  >"$AC_HOME/crewdomains/payments/records/backlog.md"

dig="$("$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$dig" "-- crewdomains (routing table) --" "the crewdomain block prints unconditionally"
assert_contains "$dig" "payments" "... naming the registered domain"
assert_contains "$dig" "UNAUTHORIZED" "... and surfacing a row no assign stamped"
assert_contains "$dig" "snuck-in" "... by id, so the chief can adopt or delete it"
assert_contains "$dig" "-- crewdeputies (routing table) --" "the crewdeputy block still prints beside it"

# A digest block may never take session start down: even a corrupt registry
# leaves the run exit 0, the rule ac-deputy.sh states for its own list.
printf 'not a registry line\n- broken\n' >"$AC_HOME/records/crewdomains.md"
"$BIN/ac-session-start.sh" >/dev/null 2>&1 \
  || fail "a corrupt crewdomain registry must not take session start down"
rm -f "$AC_HOME/records/crewdomains.md"

pass
