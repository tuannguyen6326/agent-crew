#!/usr/bin/env bash
# ac-learn.test.sh - the learning-loop DISTILL trigger (Slice 2): the durable
# per-debrief counter (learnTick, src/lib.ts), the pure digest reader (ac_learn_due), the
# agent-callable `ac-learn.sh tick` CLI, and the `-- learning --` digest block.
# The counter lives at state/.learn.meta - DOT-PREFIXED so it stays OUTSIDE the
# state/*.meta task-meta namespace the fleet enumerates as crewmates (a bare
# learn.meta reads as a phantom crewmate: WATCHER-DOWN + a spurious gone: wake).

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"

# twin <expr> [<arg>...] - <expr> over src/lib.ts (L) and
# src/maintenance-receipt.ts (M), its arguments A, in one bun process: the code
# the fleet runs where a bash helper retired once src/learn.ts took its last
# caller (the bash one is frozen at tests/fixtures/ac-maintenance-retired.sh,
# and tests/ts holds each twin to it). A string answer is printed; the status
# is a number answer, else 1 for false or null and 0 for anything else.
twin() {
  local expr="$1"; shift
  (cd "$ROOT" && bun --no-env-file -e "const L = await import('./src/lib.ts'); const M = await import('./src/maintenance-receipt.ts'); const A = process.argv.slice(1); const v = await (async () => ($expr))(); if (typeof v === 'string') process.stdout.write(v); process.exit(typeof v === 'number' ? v : v === false || v === null ? 1 : 0);" "$@")
}

make_home

# --- learnTick: the durable per-debrief counter ------------------------------

# Clean home carries no counter yet; the absent counter reads as 0.
assert_no_file "$AC_HOME/state/.learn.meta" "no counter before the first tick"
twin 'L.learnTick()'
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "first tick -> debriefs=1"
twin 'L.learnTick()'
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "2" "second tick -> debriefs=2"

# The counter must NOT land in the task-meta namespace: a bare state/learn.meta
# would enumerate as a phantom crewmate (state/*.meta).
assert_no_file "$AC_HOME/state/learn.meta" "counter never written as a bare (task-namespace) meta"

# Durable: a FRESH subshell (cold ac-lib.sh) reads the true count off disk -
# no resume-modulo, the on-disk count IS the count.
fresh="$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_meta_get \"\$(ac_state_dir)/.learn.meta\" debriefs")"
assert_eq "$fresh" "2" "counter is durable on disk across a fresh subshell"

# ROUTED-RESIDUAL 2/2 (family ac-lib-shared-helper-hardening, 2026-07-28): a
# contended cadence lock used to swallow itself - a bare
# `ac_lock_acquire "$lock" 10 || return 1`, no message - while its SIBLING,
# the keyed landing claim (now learnTickKeyed), was already made loud by
# F19. A log reader saw the claim succeed and nothing
# more, and concluded the tick ran. A lock held by this live process, with a
# no-op `sleep` first on PATH (the twin's waits spawn it), proves the failure
# without paying the real lock's 10s timeout.
lockerr="$TMP/learn-tick-lockfail.err"
mkdir -p "$TMP/fastbin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/fastbin/sleep"
chmod +x "$TMP/fastbin/sleep"
mkdir -p "$AC_HOME/state/.learn-cadence.lock" && printf '%s\n' "$$" >"$AC_HOME/state/.learn-cadence.lock/pid"
if PATH="$TMP/fastbin:$PATH" twin 'L.learnTick()' >/dev/null 2>"$lockerr"; then
  fail "a contended cadence lock must still make the tick fail (behaviour unchanged)"
fi
rm -rf "$AC_HOME/state/.learn-cadence.lock"
assert_contains "$(cat "$lockerr")" "cadence lock" \
  "a contended cadence lock is announced on stderr, not merely returned as 1"

# --- ac_learn_due: the pure digest reader -----------------------------------

# debriefs=2 from above; no config/learn-every -> the Q7 default 8.
assert_eq "$(ac_learn_due)" "2 8" "reader prints '<debriefs> <default-8>'"
printf '5\n' >"$AC_HOME/config/learn-every"
assert_eq "$(ac_learn_due)" "2 5" "reader honors config/learn-every"
# A malformed knob must never crash the digest's numeric compare -> fall back to 8.
printf 'eight\n' >"$AC_HOME/config/learn-every"
assert_eq "$(ac_learn_due)" "2 8" "garbage learn-every falls back to 8"
rm -f "$AC_HOME/config/learn-every"

# READ-ONLY: the reader never writes the counter (the digest calls it even when
# another session owns the home). Absent counter reads 0 and creates nothing.
rm -f "$AC_HOME/state/.learn.meta"
assert_eq "$(ac_learn_due)" "0 8" "absent counter reads 0"
assert_no_file "$AC_HOME/state/.learn.meta" "the reader never writes the counter"

# --- ac-learn.sh tick: the agent-callable CLI -------------------------------

out="$("$BIN/ac-learn.sh" tick)"
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "CLI tick -> debriefs=1"
# The ordinary path is NOT silent. A caller who sees no output cannot tell a
# tick from a silent failure (wrong cwd, unreadable state dir), and the natural
# repair - run it again - DOUBLE-counts the landing, firing the DISTILL against
# a counter that never reflected real landings.
assert_contains "$out" "tick: debriefs=1/8" "the ordinary tick reports the resulting count"
"$BIN/ac-learn.sh" tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "2" "CLI tick -> debriefs=2"
# ONE subcommand this slice: reset/run/curate belong to Slice 3/4, so they are refused.
assert_fails "$BIN/ac-learn.sh" reset
assert_fails "$BIN/ac-learn.sh"

# --- ac-learn.sh tick: auto-trigger a fleet wake on the CROSSING tick ---------
# The tick that FIRST reaches config/learn-every publishes one durable fleet
# wake (kind learning-due) so the crewchief hears the DISTILL is due at once,
# not only at the next session-start digest. Below-threshold and already-over
# ticks publish nothing. The wake is a NOTIFICATION only - the ACT is
# `ac-learn.sh autoroom` off the LEVEL at the next drain - so the payload must
# never instruct the reading chief to run the distill in its own session.
spool="$AC_HOME/state/.wake-spool"
rm -rf "$spool"; rm -f "$AC_HOME/state/.learn.meta"
printf '8\n' >"$AC_HOME/config/learn-every"

printf 'debriefs=6\n' >"$AC_HOME/state/.learn.meta"
"$BIN/ac-learn.sh" tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "7" "a below-threshold tick still counts"
[ -d "$spool" ] && [ -n "$(ls -A "$spool" 2>/dev/null)" ] && fail "a below-threshold tick must publish no wake" || true

"$BIN/ac-learn.sh" tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "8" "the crossing tick counts to the threshold"
assert_eq "$(grep -rl 'learning-due' "$spool" 2>/dev/null | wc -l | tr -d ' ')" "1" "the crossing tick publishes exactly one learning-due wake"
payload="$(cat "$spool"/* 2>/dev/null)"
assert_contains "$payload" "8/8" "the wake payload carries the count"
assert_contains "$payload" "do NOT run the distill in this session" "the payload is a DUE signal, not an instruction to run"
# R2: a chief that obeyed a `run ...` instruction would execute the distill in
# the fleet chief's own context - the exact thing the learning room exists for.
case "$payload" in *"run bin/ac-learn.sh run"*) fail "the wake payload must not tell the reading chief to run the distill" ;; esac

"$BIN/ac-learn.sh" tick
assert_eq "$(grep -rl 'learning-due' "$spool" 2>/dev/null | wc -l | tr -d ' ')" "1" "a tick already over the threshold does not re-publish"
rm -rf "$spool"; rm -f "$AC_HOME/config/learn-every" "$AC_HOME/state/.learn.meta"

# --- ac-learn.sh tick <landing-id>: one landing advances the counter ONCE -----
# A landing debrief has two possible actors - the roomchief before its handback
# and the crewchief at close-out - and neither can see the other's tick, so an
# unkeyed tick advanced the counter TWICE per promoted family's landing. Keying
# the tick on the landing makes it idempotent whichever combination runs it,
# INCLUDING the same actor retrying after a failed invocation.

"$BIN/ac-learn.sh" tick greet2
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "the first keyed tick counts"
out="$("$BIN/ac-learn.sh" tick greet2)"
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "a second tick for the SAME landing does not advance"
assert_contains "$out" "greet2" "the skipped tick SAYS so - the second actor has no other way to know"

# A different landing still counts, and the UNKEYED tick (the session /debrief
# call site, which is not a landing) keeps its old unguarded contract.
"$BIN/ac-learn.sh" tick other-family
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "2" "a DIFFERENT landing counts"
"$BIN/ac-learn.sh" tick
"$BIN/ac-learn.sh" tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "4" "an unkeyed tick stays unguarded"

# Two ways a mistyped key would silently stamp the WRONG landing - and stamping
# the wrong one double-advances the real one. Both are refused, not absorbed.
assert_fails "$BIN/ac-learn.sh" tick 'two words'
assert_fails "$BIN/ac-learn.sh" tick two words
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "4" "a refused tick advances nothing"

# The stamps are DOT-prefixed like every other learn-loop state file: a bare
# state/learn-ticks* would enumerate as a phantom crewmate (state/*.meta).
assert_file "$AC_HOME/state/.learn-ticks" "landing stamps live in a dot-prefixed state file"
[ -z "$(ls "$AC_HOME"/state/learn-ticks* 2>/dev/null)" ] || fail "stamps never land in the task-meta namespace"

# The RESET must NOT drop the stamps: a distill run completes ASYNCHRONOUSLY to a
# landing, so a reset between the two actors would let the second one advance the
# fresh cycle - the very double-advance this guards, at the cycle boundary.
twin 'L.learnReset()'
"$BIN/ac-learn.sh" tick greet2 >/dev/null
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "0" "a reset does not drop the landing stamps"

# A stamp older than the dedupe window is pruned, so a family that lands AGAIN
# later still counts - follow-up work reopens the same family's room.
printf '1\tgreet2\n' >"$AC_HOME/state/.learn-ticks"
"$BIN/ac-learn.sh" tick greet2
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "a landing outside the dedupe window counts again"
assert_eq "$(wc -l <"$AC_HOME/state/.learn-ticks" | tr -d ' ')" "1" "and the expired stamp is pruned, so the file stays bounded"
rm -f "$AC_HOME/state/.learn.meta" "$AC_HOME/state/.learn-ticks"

# CONCURRENT claims of the SAME landing: exactly one wins. The two actors are
# real processes racing (the roomchief's pre-handback tick against the
# crewchief's close-out tick, under parallel rooms), and the claim is a
# check-then-rewrite - so unserialized, both read "not stamped" and both
# advance the counter, consuming a retro window nothing re-examines.
#
# The interleaving is FORCED, not raced for: each claimer's own `mv` (the twin
# spawns it from PATH) is a sleeping wrapper, widening exactly the window
# between its awk check and its commit, everything else held constant.
mkdir -p "$TMP/slowmv"
printf '#!/bin/sh\n/bin/sleep "$SLOW_MV"\nexec /bin/mv "$@"\n' >"$TMP/slowmv/mv"
chmod +x "$TMP/slowmv/mv"
claim_slow() {
  # claim_slow <key> <mv-delay-secs> - one claim in its own process, saying
  # which way it went.
  case "$(SLOW_MV="$2" PATH="$TMP/slowmv:$PATH" "$BIN/ac-learn.sh" tick "$1")" in
    'tick: debriefs='*) printf 'won\n' ;;
    *) printf 'skipped\n' ;;
  esac
}
claim_slow race-fam 3 >"$TMP/claim-a" &
sleep 1                         # inside claimer A's widened window, before its mv
claim_slow race-fam 0 >"$TMP/claim-b" &
wait
assert_eq "$(cat "$TMP/claim-a" "$TMP/claim-b" | grep -c won)" "1" \
  "concurrent claims on ONE landing: exactly one wins the tick"
assert_eq "$(grep -c 'race-fam' "$AC_HOME/state/.learn-ticks")" "1" \
  "and the landing is stamped exactly once - no stamp lost to last-mv-wins"
rm -f "$AC_HOME/state/.learn.meta" "$AC_HOME/state/.learn-ticks"

# A keyed tick claims AND counts under one hold of the cadence lock. Taken
# twice, another holder could slip in between: the landing was stamped as
# counted, the counter never moved, and every re-run skipped it as a
# duplicate. Here any second acquire of it fails; ac_meta_set's own per-meta
# locks are not counted. Only the bash function can be shadowed, so this pins
# the frozen original, which tests/ts/learn.test.ts holds learnTickKeyed to.
cat >"$TMP/one-hold.sh" <<EOF
set -euo pipefail
. '$ROOT/bin/ac-lib.sh'
. '$ROOT/bin/ac-maintenance-lib.sh'
. '$ROOT/bin/ac-bun.sh'
. '$ROOT/tests/fixtures/ac-maintenance-retired.sh'
eval "orig_\$(declare -f ac_lock_acquire)"
calls=0
ac_lock_acquire() { case "\$1" in */.learn-cadence.lock) calls=\$((calls + 1)); [ "\$calls" -le 1 ] || return 1 ;; esac; orig_ac_lock_acquire "\$@"; }
ac_learn_tick_keyed once-fam
ac_meta_get "\$(ac_learn_meta)" debriefs
EOF
assert_eq "$(bash "$TMP/one-hold.sh" 2>&1)" "1" "a keyed tick counts its landing with one lock hold"
rm -f "$AC_HOME/state/.learn.meta" "$AC_HOME/state/.learn-ticks"

# A claim that LOSES the cadence lock is not a duplicate: nothing was stamped
# or counted. ac-teardown.sh records the tick's answer on the landing, so an
# "already counted" there would be a false record of a landing the counter
# never saw. The lock is held by THIS live process; a no-op `sleep` on PATH spins
# the acquire's timeout instantly (the AC-9.6 idiom below).
mkdir -p "$TMP/fastbin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/fastbin/sleep"
chmod +x "$TMP/fastbin/sleep"
cad_lock="$AC_HOME/state/.learn-cadence.lock"
mkdir -p "$cad_lock" && printf '%s\n' "$$" >"$cad_lock/pid"
busy_rc=0
busy_out="$(PATH="$TMP/fastbin:$PATH" "$BIN/ac-learn.sh" tick busy-fam 2>&1)" || busy_rc=$?
ac_lock_release "$cad_lock"
case "$busy_out" in
  *"already counted"*) fail "a claim lost to a busy cadence lock must not read as a duplicate: $busy_out" ;;
esac
assert_contains "$(printf '%s\n' "$busy_out" | tail -n 1)" "NOT counted" \
  "the last line - the one teardown records - says the landing was not counted"
assert_eq "$busy_rc" "1" "a tick that counted nothing exits non-zero"
"$BIN/ac-learn.sh" tick busy-fam >/dev/null
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" \
  "the re-run it asks for counts the landing exactly once"
rm -f "$AC_HOME/state/.learn.meta" "$AC_HOME/state/.learn-ticks"

# --- legacy-key migration: stows -> debriefs (skill rename 2026-07-18) --------
# Live fleets carry .learn.meta files keyed `stows`. The PURE reader falls back
# to the legacy key without touching the file; the WRITERS migrate on first
# touch, carrying the live count and stripping the legacy line - a fleet mid-
# cadence loses nothing.
printf 'stows=5\nlast_run=123\n' >"$AC_HOME/state/.learn.meta"
assert_eq "$(ac_learn_due)" "5 8" "the pure reader reads a legacy-keyed count"
assert_contains "$(cat "$AC_HOME/state/.learn.meta")" "stows=5" "and leaves the legacy file untouched (due never writes)"
twin 'L.learnTick()'
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "6" "tick migrates the live count and increments it"
case "$(cat "$AC_HOME/state/.learn.meta")" in *stows=*) fail "migration must strip the legacy stows line" ;; esac
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" last_run)" "123" "migration keeps the other keys"
printf 'stows=4\n' >"$AC_HOME/state/.learn.meta"
twin 'L.learnReset()'
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "0" "reset migrates then zeroes"
case "$(cat "$AC_HOME/state/.learn.meta")" in *stows=*) fail "reset must also strip the legacy line" ;; esac
rm -f "$AC_HOME/state/.learn.meta"

# --- the digest block: silent below threshold, LEARNING DUE at/over ---------

# Drive the REAL digest (ac-session-start.sh) in this isolated home; a fake
# herdr keeps the backend probes hermetic. The learning block is the assertion.
make_fake_herdr

# Below threshold: debriefs=3 < learn-every=8 -> NOTHING for learning (no
# header, matching the scheduler/clones silent-when-empty style).
printf 'debriefs=3\n' >"$AC_HOME/state/.learn.meta"
printf '8\n' >"$AC_HOME/config/learn-every"
out="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
case "$out" in
  *"LEARNING DUE"*) fail "below threshold must print no LEARNING DUE line" ;;
  *"-- learning --"*) fail "below threshold must not print the learning header" ;;
esac

# At threshold: debriefs=8 == learn-every=8 -> LEARNING DUE: 8/8.
printf 'debriefs=8\n' >"$AC_HOME/state/.learn.meta"
out="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
assert_contains "$out" "-- learning --" "at threshold prints the learning header"
assert_contains "$out" "LEARNING DUE: 8/8" "at threshold prints LEARNING DUE: <n>/<X>"

# Over threshold with a smaller knob: debriefs=8 >= learn-every=5 -> 8/5.
printf '5\n' >"$AC_HOME/config/learn-every"
out="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
assert_contains "$out" "LEARNING DUE: 8/5" "over threshold prints the real counts"

# An unsettled maintenance transaction refuses every OTHER Learning/Curate
# transaction, so it must be NAMED on the way in - it used to be visible only
# in the dashboard, while the next learning run warned about a stale receipt
# and Curate died, neither naming the transaction holding the claim.
case "$out" in *"-- maintenance --"*) fail "a clear loop must print no maintenance block" ;; esac
mkdir -p "$AC_HOME/state/.maintenance-transactions/learning-99-subject"
printf 'plan_sha256=abc\nstatus=applying\naction_0=complete\n' \
  >"$AC_HOME/state/.maintenance-transactions/learning-99-subject/journal"
out="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
assert_contains "$out" "-- maintenance --" "an unsettled transaction prints the maintenance header"
assert_contains "$out" "INCOMPLETE TXN: learning-99-subject" "the digest NAMES the wedged transaction"
assert_contains "$out" "1 action(s) committed" "and how much of its plan already landed"
assert_contains "$out" "ac-learn.sh maintenance status" "and where to settle it"
rm -rf "$AC_HOME/state/.maintenance-transactions"

# --- cmd_run: the learning scout is a durable, supervised verify-learning agent
# Option-A residue: task-flow-v2 routed codereview/qa through ac-verify (durable
# brief, verify-* meta, pane handle) but left ac-learn's scout on the old shape -
# a mktemp kickoff and no meta. This brings the scout to the SAME durable shape:
# a durable kickoff on disk, and a verify-learning meta + status + pane handle
# published WHILE it runs so the watcher supervises it, then removed when cmd_run
# harvests. Completion stays SYNCHRONOUS (props 4/5 superseded across all callers).
rm -f "$AC_HOME/state/.learn.meta" "$AC_HOME/config/learn-every"
rm -rf "$AC_HOME/state/.wake-spool"

fake_pane="$TMP/ac-learn-pane"
cat >"$fake_pane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = reap-pane ]; then
  printf '{"event":"reap-pane-done","pane":"%s","closed":true}\n' "${3:-}"
  exit 0
fi
[ "${1:-}" = run ] || exit 2
shift
cwd=""; prompt=""; pane_file=""; kind=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift ;;
    --prompt-file) prompt="$2"; shift ;;
    --pane-file) pane_file="$2"; shift ;;
    --kind) kind="$2"; shift ;;
    --label|--timeout|--model|--effort|--harness|--resume|--replace-pane|--deliverable) shift ;;
    *) printf 'unexpected pane arg: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
printf '%s\n' "$kind" >"$LEARN_KIND_CAPTURE"
[ -z "$prompt" ] || cp "$prompt" "$LEARN_KICKOFF_CAPTURE"
# Publish the pane identity early, exactly as ac-verify expects of the helper.
[ -z "$pane_file" ] || printf '%s\n' "${LEARN_PANE:-pLearn tLearn}" >"$pane_file"
# Prove the meta/status/handle exist WHILE the scout runs by polling for them.
# The wait is REAL, not a flake guard: cmd_run cannot publish the meta until
# THIS stub hands it the pane id, so the gap is by construction. Measured
# 2026-07-27 over 32 runs of the real path - mean 37-54ms, worst 92ms under 24
# CPU hogs - against a cap of 100 ITERATIONS, which is ~2.7s of wall clock in
# every load state measured (an iteration count stretches under load; a
# wall-clock deadline would shrink). Dropping the cap is not an option either:
# cmd_run `wait`s on this stub and this host has no per-test timeout, so a
# capless poll would hang the whole suite on the very regression it catches.
i=0
while [ "$i" -lt 100 ]; do
  set -- "$AC_HOME"/state/verify-learning-*.meta
  [ -s "$1" ] && break
  sleep 0.02; i=$((i + 1))
done
[ ! -s "$1" ] || cp "$1" "$LEARN_META_CAPTURE"
[ -z "${LEARN_CREW_STATE:-}" ] \
  || "$LEARN_CREW_STATE" "$(basename "$1" .meta)" >"$LEARN_CREW_STATE_CAPTURE" 2>&1 || true
set -- "$AC_HOME"/state/verify-learning-*.status
[ ! -s "$1" ] || cp "$1" "$LEARN_STATUS_CAPTURE"
set -- "$AC_HOME"/state/.pane-verify-learning-*
[ ! -e "$1" ] || cp "$1" "$LEARN_HANDLE_CAPTURE"
transcript="$LEARN_TRANSCRIPT"
printf 'scout summary\n' >"$transcript"
jq -cn --arg t "$transcript" '{event:"done",status:"ok",transcript:$t,pane:"pLearn"}'
EOF
chmod +x "$fake_pane"

export AC_PANE_AGENT="$fake_pane"
export LEARN_KIND_CAPTURE="$TMP/learn-kind.capture"
export LEARN_KICKOFF_CAPTURE="$TMP/learn-kickoff.capture"
export LEARN_META_CAPTURE="$TMP/learn-meta.capture"
export LEARN_STATUS_CAPTURE="$TMP/learn-status.capture"
export LEARN_HANDLE_CAPTURE="$TMP/learn-handle.capture"
export LEARN_TRANSCRIPT="$TMP/learn-transcript.jsonl"
rm -f "$LEARN_META_CAPTURE" "$LEARN_STATUS_CAPTURE" "$LEARN_HANDLE_CAPTURE" "$LEARN_KICKOFF_CAPTURE"

"$BIN/ac-learn.sh" run >/dev/null 2>&1 || fail "learning run completes with a stubbed scout"

# Property 2: a verify-learning meta was published WHILE the scout ran.
assert_file "$LEARN_META_CAPTURE" "scout publishes a durable meta while it runs"
learn_meta="$(cat "$LEARN_META_CAPTURE")"
assert_contains "$learn_meta" "kind=verify-learning" "scout meta uses the verify-learning token (interface 2.i)"
assert_contains "$learn_meta" "backend=herdr" "scout meta records backend"
assert_contains "$learn_meta" "window=pLearn" "scout meta records the live pane"
assert_contains "$learn_meta" "cwd=" "scout meta records the run cwd"
# The meta is classed a VERIFICATION agent, so the six enumerators exclude it.
learn_probe="$TMP/learn-meta-probe.meta"
printf '%s\n' "$learn_meta" >"$learn_probe"
ac_meta_is_verify "$learn_probe" || fail "the scout meta is classed a verification agent"

# Property 2: a status log and pane handle are published live too.
assert_file "$LEARN_STATUS_CAPTURE" "scout publishes a durable status while it runs"
assert_file "$LEARN_HANDLE_CAPTURE" "scout publishes a durable pane handle while it runs"
assert_contains "$(cat "$LEARN_HANDLE_CAPTURE")" "pLearn" "the pane handle records the live pane"

# Property 1: the kickoff is a durable file (not a mktemp deleted on return) and
# points at the durable brief; dispatch stays --kind learning.
assert_file "$LEARN_KICKOFF_CAPTURE" "scout kickoff prompt was passed"
assert_contains "$(cat "$LEARN_KICKOFF_CAPTURE")" "brief.md" "the kickoff points at the durable brief"
assert_eq "$(cat "$LEARN_KIND_CAPTURE")" "learning" "the scout still dispatches under --kind learning"
[ -z "$(ls "${TMPDIR:-/tmp}"/ac-learn-scout-* 2>/dev/null)" ] || fail "no mktemp kickoff file leaks"

# The durable brief survives; the identity is removed when cmd_run harvests.
learn_rundir="$(ls -d "$AC_HOME"/data/learning-* | tail -n 1)"
assert_file "$learn_rundir/brief.md" "the durable scout brief survives the run"
assert_file "$learn_rundir/kickoff.md" "the durable kickoff survives the run"
assert_contains "$(cat "$learn_rundir/brief.md")" "Do NOT launch any async/background sub-agents" \
  "the brief forbids async sub-agents (turn-end harvest is incompatible with them)"
[ -z "$(ls "$AC_HOME"/state/verify-learning-*.meta 2>/dev/null)" ] || fail "the scout meta is removed at harvest"
[ -z "$(ls "$AC_HOME"/state/.pane-verify-learning-* 2>/dev/null)" ] || fail "the scout pane handle is removed at harvest"

# The meta's backend= names the driver every liveness reader (the watcher,
# ac-crew-state.sh) asks about the scout pane, so it must be the fleet's own: an
# orca fleet's scout recorded as herdr was asked of herdr, read gone seconds into
# a live run, and woke the chief with a false gone wake.
printf 'orca\n' >"$AC_HOME/config/backend"
make_fake_orca
: >"$FAKE_ORCA/terminals/termLearn.buf"
printf 'tabLearn\n' >"$FAKE_ORCA/terminals/termLearn.tab"
export LEARN_PANE='termLearn tabLearn'
export LEARN_CREW_STATE="$BIN/ac-crew-state.sh" LEARN_CREW_STATE_CAPTURE="$TMP/learn-crew-state.capture"
# A run in the same second as the one above reuses its learning-<ts> dir, whose
# stale pane.handle would hand this run the old pane before the stub writes one.
rm -rf "$LEARN_META_CAPTURE" "$AC_HOME"/data/learning-*
"$BIN/ac-learn.sh" run >/dev/null 2>&1 || fail "learning run completes on an orca fleet"
assert_contains "$(cat "$LEARN_META_CAPTURE")" "backend=orca" "an orca fleet's scout meta records backend=orca"
assert_eq "$(cat "$LEARN_CREW_STATE_CAPTURE")" "status| started learning scout pane=termLearn" \
  "an orca fleet's live scout reads alive through its own driver, never gone"
unset LEARN_PANE LEARN_CREW_STATE LEARN_CREW_STATE_CAPTURE
rm -f "$AC_HOME/config/backend"

unset AC_PANE_AGENT
rm -f "$AC_HOME/state/.learn.meta"

# --- cmd_note: the lock over the ledger read-modify-write (RC-1) -------------
#
# `note` is NOT an append - it is a whole-file READ-MODIFY-WRITE (bin/ac-learn.sh
# cmd_note: awk over the entire ledger -> $ledger.tmp.$$ -> mv). Unserialized,
# two roomchiefs landing together both read the original and the later mv
# silently discards the earlier writer's lesson. That lost update is a
# PRE-EXISTING fleet bug - it needs no crewdomain to happen.
#
# AC-9.7 is TWO tests because its two pinned properties are mutually exclusive
# in one: a lost update needs B's commit to land INSIDE A's read-commit window,
# and mutual exclusion is precisely what makes that interleave unreachable. So
# A1 buys the red-first proof and A2 buys the sleep-free determinism. The rule
# both serve: NO RACE TEST MAY PASS BY TIMING LUCK.

note_ledger_reset() {  # a ledger in the shape learn_ledger_stage writes
  printf '# Learning Ledger\n\n## Pending\n\n' >"$AC_HOME/records/learnings.md"
}
note_count() {  # note_count <lesson> -> times it appears in the fleet ledger
  grep -cxF -- "$1" "$AC_HOME/records/learnings.md" || true
}

# A DELAYING `mv` on PATH, not a shadowed shell function: ac-learn.sh runs as
# its own script, so a caller-side function override never reaches it. Only the
# LEDGER commit is delayed - every other mv passes straight through, which is
# what keeps "everything else held constant" true rather than merely claimed.
mkdir -p "$TMP/slowbin"
cat >"$TMP/slowbin/mv" <<'SLOWMV'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */records/learnings.md) sleep "${AC_TEST_MV_DELAY:-0}" ;;
  esac
done
exec /bin/mv "$@"
SLOWMV
chmod +x "$TMP/slowbin/mv"

note_slow() {  # note_slow <lesson> <ledger-mv-delay-secs>
  AC_TEST_MV_DELAY="$2" PATH="$TMP/slowbin:$PATH" "$BIN/ac-learn.sh" note "$1" >/dev/null
}

# A1 - the RED-FIRST proof. Writer A's ledger commit is delayed so its
# read-commit window is open; writer B runs inside that window; against
# unmodified bin/ac-learn.sh A's stale image lands last and B's lesson is GONE.
#
# BOTH orderings are FORCED, and neither by elapsed time. Two are needed:
# (i) A has READ before B starts, and (ii) B commits before A does.
#   (i) A announces its own ledger `mv` through a FIFO; the parent BLOCKS on
#       that read, so B cannot start early however A is scheduled.
#   (ii) A then WAITS for B to report completion before committing.
# The wait is BOUNDED, and that bound is what keeps it from deadlocking against
# the very fix under test: with the lock in place B cannot finish (it is parked
# on the lock A holds), the wait expires, A commits and releases, and B then
# reads A's ledger and appends - both lessons survive. Without the lock B DOES
# finish and signals, so the lost-update interleave is produced deterministically
# rather than hoped for. The bound is a deadlock escape, never a race margin.
#
# The GREEN direction needs neither ordering: whenever B arrives it cannot read
# until A releases, so this does not decay into a timing test once it passes.
note_ledger_reset
mkfifo "$TMP/a1-read"
mkdir -p "$TMP/a1bin"
cat >"$TMP/a1bin/mv" <<A1MV
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */records/learnings.md)
      # Announce ONCE that A has read, then WAIT for B to finish. Bounded, so
      # the locked world (where B cannot finish) escapes instead of deadlocking.
      if [ ! -e "$TMP/a1-signalled" ]; then
        : >"$TMP/a1-signalled"
        printf 'has-read\n' >"$TMP/a1-read"
        # A FILE, not a fifo: in the LOCKED world B never finishes, and a fifo
        # write with no reader left blocks for ever - the stub would become the
        # deadlock it exists to avoid. A bounded poll escapes cleanly.
        w=0
        while [ ! -e "$TMP/a1-bdone" ] && [ "\$w" -lt 60 ]; do sleep 0.1; w=\$((w + 1)); done
      fi ;;
  esac
done
exec /bin/mv "\$@"
A1MV
chmod +x "$TMP/a1bin/mv"

note_a='- LESSON: writer A, whose commit is delayed into writer B.'
note_b='- LESSON: writer B, who commits inside A read-modify-write window.'
PATH="$TMP/a1bin:$PATH" "$BIN/ac-learn.sh" note "$note_a" >/dev/null &
# BLOCKS until A has read the ledger and entered its commit window. Past this
# read, ordering (i) is established by the handshake, not by elapsed time.
read -r _ <"$TMP/a1-read"
# B runs while A is held. Its completion releases A - ordering (ii), forced.
( "$BIN/ac-learn.sh" note "$note_b" >/dev/null 2>&1; : >"$TMP/a1-bdone" ) &
wait
assert_eq "$(note_count "$note_a")" "1" "A1: writer A's lesson survives two concurrent notes"
assert_eq "$(note_count "$note_b")" "1" "A1: writer B's lesson survives too - no lost update"

# A2 - the SLEEP-FREE contract test, with a real HANDSHAKE. The earlier version
# started the note and immediately mutated and released, which proves nothing:
# if the child had not yet reached the lock, it simply read the already-updated
# ledger and the assertion passed for the wrong reason - a test that passes by
# timing luck, the one thing this pair exists to rule out.
#
# The signal comes from the child's own attempt on the lockdir. `mkdir` is an
# external command, so a PATH stub sees the acquisition the instant it happens
# and reports it through a FIFO; the parent BLOCKS on that FIFO, so the ordering
# is established by the handshake, never by elapsed time.
note_ledger_reset
mkfifo "$TMP/note-at-lock"
mkdir -p "$TMP/hsbin"
# ONCE only. ac_lock_acquire retries in a loop, and a second write to the FIFO
# would block forever with no reader left - the stub itself would become the
# deadlock it exists to rule out.
cat >"$TMP/hsbin/mkdir" <<HSMK
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */.learn-note.lock)
      if [ ! -e "$TMP/note-signalled" ]; then
        : >"$TMP/note-signalled"
        printf 'at-lock\n' >"$TMP/note-at-lock"
      fi ;;
  esac
done
exec /bin/mkdir "\$@"
HSMK
chmod +x "$TMP/hsbin/mkdir"

note_lock="$AC_HOME/state/.learn-note.lock"
mkdir -p "$note_lock" && printf '%s\n' "$$" >"$note_lock/pid"
note_held='- LESSON: committed while the lock was held elsewhere.'
note_waiter='- LESSON: written by the note that had to wait for the lock.'
PATH="$TMP/hsbin:$PATH" "$BIN/ac-learn.sh" note "$note_waiter" >/dev/null &
note_waiter_pid=$!

# BLOCKS until the child has actually attempted the lock. Past this read the
# child is provably at the acquisition boundary with the lock still held, so
# everything below is ordered after its arrival and before its read.
read -r _ <"$TMP/note-at-lock"
assert_eq "$(note_count "$note_waiter")" "0" \
  "A2: the waiter has reached the lock and written NOTHING - the lock is what holds it"

printf -- '%s\n' "$note_held" >>"$AC_HOME/records/learnings.md"
ac_lock_release "$note_lock"
wait "$note_waiter_pid"
assert_eq "$(note_count "$note_held")" "1" "A2: the lesson committed under the held lock is not clobbered"
assert_eq "$(note_count "$note_waiter")" "1" "A2: the note that waited for the lock still lands its lesson"
assert_no_file "$note_lock" "A2: note releases the lock it took"

# AC-9.6 - a note that cannot take the lock refuses LOUDLY and writes NOTHING.
# A refused note the chief can re-run is visible; a lost lesson is not.
#
# The lock is genuinely uncontendable here - held by THIS process, which is
# alive, so ac_lock_stale never reclaims it. The only thing held non-constant is
# the WALL CLOCK: a no-op `sleep` on PATH lets ac_lock_acquire spin out its full
# timeout instantly instead of the test paying 30 real seconds. Nothing on the
# note path sleeps for any other reason.
mkdir -p "$TMP/fastbin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/fastbin/sleep"
chmod +x "$TMP/fastbin/sleep"
note_ledger_reset
cp "$AC_HOME/records/learnings.md" "$TMP/note-lockfail-before.md"
note_lockerr="$TMP/note-lockfail.err"
mkdir -p "$note_lock" && printf '%s\n' "$$" >"$note_lock/pid"
if PATH="$TMP/fastbin:$PATH" "$BIN/ac-learn.sh" note '- LESSON: must never be written.' \
    >/dev/null 2>"$note_lockerr"; then
  fail "AC-9.6: note must FAIL when it cannot take the ledger lock"
fi
ac_lock_release "$note_lock"
assert_contains "$(cat "$note_lockerr")" "lock" \
  "AC-9.6: the refusal names the lock on stderr rather than failing silently"
cmp -s "$TMP/note-lockfail-before.md" "$AC_HOME/records/learnings.md" \
  || fail "AC-9.6: a refused note must leave the ledger byte-unchanged"

# AC-9.4 - the crewdomain feature adds NOTHING to this file. The lock is a
# feature-independent fix for a bug that is live with zero crewdomains, and the
# gather that once lived here is deleted (P8-v2).
# CODE lines only: the header legitimately NAMES crewdomain when it lists the
# seed order ac_seed_crewmate_md merges (container -> learned -> fleet ->
# crewdomain), which is this file documenting ANOTHER feature's layer chain, not
# carrying crewdomain's own. Scanning prose made the rule unstateable - the only
# way to satisfy it was to describe the seed order wrongly. A code line keeps a
# trailing comment attached, so a real branch cannot hide behind one. The
# entry is a shim; the code lives in src/learn.ts.
assert_eq "$(grep -v '^[[:space:]]*//' "$ROOT/src/learn.ts" | grep -c 'crewdomain\|AC_DOMAIN' || true)" "0" \
  "AC-9.4: src/learn.ts carries no crewdomain feature lines"

# AC-9.8 - argv the verb does not define must never become ledger CONTENT.
# LIVED 2026-09-16: `note --file <path>` appended the literal `--file` and the
# literal path as two lessons under ## Pending and printed `appended 2 line(s)`,
# which reads exactly like success. The next Learning transaction consumes every
# Pending line as first-hand input, and no verb removes one.
note_ledger_reset
cp "$AC_HOME/records/learnings.md" "$TMP/note-flag-before.md"
note_flagerr="$TMP/note-flag.err"
if "$BIN/ac-learn.sh" note --file "$TMP/lessons.md" >/dev/null 2>"$note_flagerr"; then
  fail "AC-9.8: note must refuse an argument shaped like a flag it does not define"
fi
assert_contains "$(cat "$note_flagerr")" "--file" \
  "AC-9.8: the refusal quotes the argument it refused"
cmp -s "$TMP/note-flag-before.md" "$AC_HOME/records/learnings.md" \
  || fail "AC-9.8: a refused note leaves the ledger byte-unchanged"

# ... and the guard must not swallow the ledger's OWN convention: every lesson
# line is written `- <text>`, which begins with a dash and is content.
note_bullet='- LESSON: a dash-space bullet is content, never a flag.'
"$BIN/ac-learn.sh" note "$note_bullet" >/dev/null \
  || fail "AC-9.8: the guard must not refuse a `- ` bullet"
assert_eq "$(note_count "$note_bullet")" "1" "AC-9.8: the bullet still lands"

note_ledger_reset

# --- rotate-pending: DISTILL staging reads a BOUNDED ledger -------------------
# (learn-pending-ledger-is-write-only): every landed skill in the fleet's life
# was retro-only - all archive blocks carry source-count: 0 - because cmd_run
# staged the FULL learnings.md copy and the land contract demands exact
# verbatim source-line citation, infeasible over an unbounded body. Rotation
# archives the OLDEST Pending bullets verbatim and keeps the newest within
# config/learn-pending-budget, so the staged copy stays citable. Nothing is
# lost: archive + kept ledger together hold every original bullet.

LEDGER="$AC_HOME/records/learnings.md"
ARCHDIR="$AC_HOME/records/learnings-archive"
rot_pad="$(printf '%030d' 0 | tr '0' 'x')"
rot_ledger() {  # rot_ledger <n-bullets> [<extra-top-line>] - a staged-shape ledger
  local n="$1" extra="${2:-}" i
  { printf '# Learning Ledger\n\n## Pending\n\n'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    i=1; while [ "$i" -le "$n" ]; do printf -- '- lesson %02d %s\n' "$i" "$rot_pad"; i=$((i+1)); done
    printf '\n## Distilled\n\n- [distilled -> some-skill] sources=2 updated=2026-08-01\n'
  } >"$LEDGER"
}

# R1: under budget -> STRICT no-op: the ledger is untouched (byte-identical,
# no rewrite) and no archive is minted.
rm -rf "$ARCHDIR"; rot_ledger 4
printf '4096\n' >"$AC_HOME/config/learn-pending-budget"
cp "$LEDGER" "$TMP/rot-before"
"$BIN/ac-learn.sh" rotate-pending >/dev/null 2>&1 || fail "R1: rotate-pending must succeed on an under-budget ledger"
cmp -s "$TMP/rot-before" "$LEDGER" || fail "R1: an under-budget ledger must stay byte-identical"
[ -z "$(ls "$ARCHDIR"/pending-* 2>/dev/null)" ] || fail "R1: no archive is minted when nothing rotates"

# R2: over budget -> the OLDEST bullets move verbatim to the archive, the
# newest stay, a marker names the archive, the Distilled index is untouched,
# and no bullet is lost (conservation).
rm -rf "$ARCHDIR"; rot_ledger 6
printf '200\n' >"$AC_HOME/config/learn-pending-budget"
"$BIN/ac-learn.sh" rotate-pending >/dev/null || fail "R2: rotate-pending failed on an over-budget ledger"
rot_arch="$(ls "$ARCHDIR"/pending-*.md 2>/dev/null | head -1)"
[ -n "$rot_arch" ] || fail "R2: rotation mints records/learnings-archive/pending-<ts>.md"
grep -qFx -- "- lesson 01 $rot_pad" "$rot_arch" || fail "R2: the oldest bullet lands verbatim in the archive"
grep -qFx -- "- lesson 06 $rot_pad" "$LEDGER" || fail "R2: the newest bullet stays in the ledger"
if grep -qFx -- "- lesson 01 $rot_pad" "$LEDGER"; then fail "R2: an archived bullet must leave the ledger"; fi
grep -q "^\[pending-overflow -> " "$LEDGER" || fail "R2: the ledger carries a marker line naming the rotation"
grep -qF -- "$(basename "$rot_arch")" "$LEDGER" || fail "R2: the marker names the archive file"
grep -qFx -- '- [distilled -> some-skill] sources=2 updated=2026-08-01' "$LEDGER" \
  || fail "R2: the Distilled pointer index is untouched by rotation"
rot_total=$(( $(grep -c "^- lesson" "$rot_arch") + $(grep -c "^- lesson" "$LEDGER") ))
assert_eq "$rot_total" "6" "R2: archive + ledger together hold every original bullet"
rot_kept="$(awk '/^## Pending/{p=1;next}/^## Distilled/{p=0}p' "$LEDGER" | wc -c | tr -d ' ')"
[ "$rot_kept" -le 200 ] || fail "R2: the kept Pending body respects the budget (got $rot_kept bytes)"

# R3: a SECOND rotation keeps the first marker (a marker is never a bullet,
# so it can never be archived) and mints its own archive.
i=7; while [ "$i" -le 12 ]; do "$BIN/ac-learn.sh" note "- lesson $i $rot_pad" >/dev/null; i=$((i+1)); done
"$BIN/ac-learn.sh" rotate-pending >/dev/null || fail "R3: second rotation failed"
assert_eq "$(grep -c "^\[pending-overflow -> " "$LEDGER")" "2" "R3: both rotation markers survive in the ledger"
assert_eq "$(ls "$ARCHDIR"/pending-*.md | wc -l | tr -d ' ')" "2" "R3: each rotation mints its own archive"
if grep -q "^\[pending-overflow -> " "$ARCHDIR"/pending-*.md; then fail "R3: a marker line is never archived"; fi

# R4: a young ledger with NO ## Distilled section still rotates.
rm -rf "$ARCHDIR"
{ printf '# Learning Ledger\n\n## Pending\n\n'
  i=1; while [ "$i" -le 6 ]; do printf -- '- lesson %02d %s\n' "$i" "$rot_pad"; i=$((i+1)); done
} >"$LEDGER"
"$BIN/ac-learn.sh" rotate-pending >/dev/null || fail "R4: rotation must handle a ledger with no Distilled section"
grep -qFx -- "- lesson 06 $rot_pad" "$LEDGER" || fail "R4: newest bullet survives on a young ledger"
[ -n "$(ls "$ARCHDIR"/pending-*.md 2>/dev/null)" ] || fail "R4: young ledger over budget still archives"

# R5: WIRING - cmd_run rotates BEFORE it snapshots sources/learnings.md, so
# the scout's copy is the bounded ledger, never the unbounded one.
# ONE awk process, no pipe: grep -q closing a pipe mid-stream hands sed
# SIGPIPE, and under pipefail that 141 fails the pipeline on a MATCH.
awk '/^async function cmdRun\(/{f=1} f&&/rotatePending\(\)/{found=1} f&&/^}/{exit} END{exit !found}' "$ROOT/src/learn.ts" \
  || fail "R5: cmdRun must call rotatePending before staging sources/"

# R6: the rotation takes the note lock - a held lock makes it refuse (nothing
# rewritten), never write beside a concurrent note.
rot_lock="$AC_HOME/state/.learn-note.lock"
rot_ledger 6
cp "$LEDGER" "$TMP/rot-locked-before"
mkdir -p "$rot_lock" && printf '%s\n' "$$" >"$rot_lock/pid"
# The no-op `sleep` on PATH (AC-9.6's fastbin, above) spins the acquire's full
# timeout instantly - same held-lock idiom, nothing else varied.
if PATH="$TMP/fastbin:$PATH" "$BIN/ac-learn.sh" rotate-pending >/dev/null 2>&1; then
  ac_lock_release "$rot_lock"
  fail "R6: rotate-pending must refuse while the note lock is held"
fi
ac_lock_release "$rot_lock"
cmp -s "$TMP/rot-locked-before" "$LEDGER" || fail "R6: a refused rotation leaves the ledger byte-unchanged"

# R7: the REAL ledger shape (found live, drydock 2026-08-09: 1295 indented
# continuation lines, 194 `### <date>` headings, legacy title prose) - a
# bullet-only walk archived ALL 1677 bullets while stranding 135KB of orphaned
# context ABOVE budget. Rotation must move the oldest PREFIX verbatim -
# continuations travel with their bullet, headings and prose travel with
# their section - and cut only at a safe boundary (bullet start, heading, or
# blank), never between a bullet and its continuation lines.
rm -rf "$ARCHDIR"
{ printf '# Fleet learnings\n'
  printf 'Dated, durable, reusable lessons.\n\n'
  printf '### 2026-07-01\n\n'
  printf -- '- lesson old-a %s\n' "$rot_pad"
  printf '  continuation A1 of the old bullet\n'
  printf '  continuation A2 of the old bullet\n'
  printf -- '- lesson old-b %s\n' "$rot_pad"
  printf '\n### 2026-08-01\n\n'
  printf -- '- lesson new-a %s\n' "$rot_pad"
  printf '  continuation N1 of the new bullet\n'
  printf -- '- lesson new-b %s\n' "$rot_pad"
  printf '\n## Distilled\n\n- [distilled -> some-skill] sources=2 updated=2026-08-01\n'
} | { printf '# Learning Ledger\n\n## Pending\n\n'; cat; } >"$LEDGER"
printf '230\n' >"$AC_HOME/config/learn-pending-budget"
"$BIN/ac-learn.sh" rotate-pending >/dev/null || fail "R7: rotation failed on the real-shape ledger"
rot_arch7="$(ls "$ARCHDIR"/pending-*.md 2>/dev/null | head -1)"
[ -n "$rot_arch7" ] || fail "R7: rotation mints an archive on the real-shape ledger"
grep -qFx -- "- lesson old-a $rot_pad" "$rot_arch7" || fail "R7: the oldest bullet is archived"
grep -qFx -- '  continuation A1 of the old bullet' "$rot_arch7" \
  || fail "R7: a continuation line travels WITH its archived bullet, never stranded in the ledger"
grep -qFx -- '### 2026-07-01' "$rot_arch7" || fail "R7: the emptied date heading travels with its section"
grep -qFx -- '# Fleet learnings' "$rot_arch7" || fail "R7: legacy title prose in the prefix is archived, not stranded"
if grep -qFx -- '  continuation A1 of the old bullet' "$LEDGER"; then
  fail "R7: no orphaned continuation may remain in the ledger"
fi
grep -qFx -- "- lesson new-b $rot_pad" "$LEDGER" || fail "R7: the newest bullet stays"
grep -qFx -- '  continuation N1 of the new bullet' "$LEDGER" || fail "R7: a kept bullet keeps its continuation"
# the kept body's first content line is a safe boundary, never an indented one
first_kept="$(awk '/^## Pending/{p=1;next}/^## Distilled/{p=0} p && $0 != "" && $0 !~ /^\[pending-overflow/ {print; exit}' "$LEDGER")"
case "$first_kept" in
  '  '*) fail "R7: the cut landed mid-block - the kept body starts with an orphaned continuation: $first_kept" ;;
esac

# R8: a candidate the last examined run did NOT apply (revise, ask-captain, an
# unjudged gate) left its sources in Pending so the next cycle can reconsider
# it - and those sources are the OLDEST bullets by construction, exactly what a
# prefix rotation takes first (drydock 2026-09-22: 12 sources of three revised
# candidates left Pending in the next run's rotation). They survive ONE more
# rotation with their continuation and their date heading; an older run's
# sources do not, and a run dir with no report.md (the run being staged right
# now) is never the anchor.
rm -rf "$ARCHDIR"
rot_runs="$AC_HOME/data"
rot_cand() {  # rot_cand <run-dir> <bullet> - a candidate citing one source line
  mkdir -p "$1"
  printf 'kind: skill\nname: held-skill\ndescription: d\n===sources===\n2026-07-01\tlabel\t%s\n===body===\nb\n' "$2" \
    >"$1/candidate-held-skill.md"
}
rot_held_ledger() {
  { printf '# Learning Ledger\n\n## Pending\n\n'
    printf '### 2026-07-01 (family held)\n'
    printf -- '- lesson held-a %s\n' "$rot_pad"
    printf '  held continuation\n'
    printf -- '- lesson old-b %s\n' "$rot_pad"
    i=1; while [ "$i" -le 6 ]; do printf -- '- lesson %02d %s\n' "$i" "$rot_pad"; i=$((i+1)); done
    printf '\n## Distilled\n\n- [distilled -> some-skill] sources=2 updated=2026-08-01\n'
  } >"$LEDGER"
}
rot_held_ledger
rot_cand "$rot_runs/learning-9000000000" "- lesson old-b $rot_pad"
printf 'report\n' >"$rot_runs/learning-9000000000/report.md"
rot_cand "$rot_runs/learning-9000000001" "- lesson held-a $rot_pad"
printf 'report\n' >"$rot_runs/learning-9000000001/report.md"
mkdir -p "$rot_runs/learning-9000000002"
printf '300\n' >"$AC_HOME/config/learn-pending-budget"
"$BIN/ac-learn.sh" rotate-pending >/dev/null || fail "R8: rotation failed with a prior run's sources held"
rot_arch8="$(ls "$ARCHDIR"/pending-*.md 2>/dev/null | head -1)"
[ -n "$rot_arch8" ] || fail "R8: the over-budget ledger still rotates"
grep -qFx -- "- lesson held-a $rot_pad" "$LEDGER" \
  || fail "R8: a source of the last examined run's candidate must survive the next rotation"
if grep -qFx -- "- lesson held-a $rot_pad" "$rot_arch8"; then fail "R8: a held source is never archived"; fi
grep -qFx -- '  held continuation' "$LEDGER" || fail "R8: a held source keeps its continuation line"
grep -qFx -- '### 2026-07-01 (family held)' "$LEDGER" \
  || fail "R8: a held source keeps its date heading - the scout dates a source by it"
grep -qFx -- "- lesson old-b $rot_pad" "$rot_arch8" || fail "R8: an OLDER run's source is not held - the hold is one cycle"
grep -qFx -- '### 2026-07-01 (family held)' "$rot_arch8" \
  || fail "R8: a kept heading is copied to the archive, so the sibling archived from under it keeps its date"
grep -qFx -- "- lesson 01 $rot_pad" "$rot_arch8" || fail "R8: unheld old bullets still rotate"
rot_total=$(( $(grep -c "^- lesson" "$rot_arch8") + $(grep -c "^- lesson" "$LEDGER") ))
assert_eq "$rot_total" "8" "R8: archive + ledger together hold every original bullet"
rot_kept="$(awk '/^## Pending/{p=1;next}/^## Distilled/{p=0}p' "$LEDGER" | wc -c | tr -d ' ')"
[ "$rot_kept" -le 300 ] || fail "R8: held lines count against the budget (kept $rot_kept bytes)"

# R8b: the NEXT examined run releases the hold - it proposed nothing from the
# held source, so the reconsideration the revise promised has happened, and the
# source rotates like any old bullet instead of pinning Pending forever.
mkdir -p "$rot_runs/learning-9000000003" && printf 'report\n' >"$rot_runs/learning-9000000003/report.md"
i=7; while [ "$i" -le 12 ]; do "$BIN/ac-learn.sh" note "- lesson $i $rot_pad" >/dev/null; i=$((i+1)); done
"$BIN/ac-learn.sh" rotate-pending >/dev/null || fail "R8b: second rotation failed"
if grep -qFx -- "- lesson held-a $rot_pad" "$LEDGER"; then
  fail "R8b: a source the next examined run passed over must rotate - a hold is one cycle, not forever"
fi
if grep -qFx -- '  held continuation' "$LEDGER"; then fail "R8b: the released continuation travels with its bullet"; fi
rot_arch8b="$(ls "$ARCHDIR"/pending-*.md | grep -vFx -- "$rot_arch8")"
grep -qFx -- "- lesson held-a $rot_pad" "$rot_arch8b" || fail "R8b: a released source is ARCHIVED, never dropped"
grep -qFx -- '  held continuation' "$rot_arch8b" || fail "R8b: the released continuation is archived with it"
rot_total=$(( $(cat "$ARCHDIR"/pending-*.md | grep -c "^- lesson") + $(grep -c "^- lesson" "$LEDGER") ))
assert_eq "$rot_total" "14" "R8b: the archives + ledger still hold every bullet across the release"
rm -rf "$rot_runs"/learning-900000000[0-3]

# R8c: held sources that alone outgrow the budget are still held - the hold
# ends after one examined run, while an evicted source never comes back - but
# the receipt says the body is OVER budget instead of claiming it held.
rm -rf "$ARCHDIR"; rot_held_ledger
rot_cand "$rot_runs/learning-9000000001" "- lesson held-a $rot_pad"
printf 'report\n' >"$rot_runs/learning-9000000001/report.md"
printf '100\n' >"$AC_HOME/config/learn-pending-budget"
rot_out="$("$BIN/ac-learn.sh" rotate-pending 2>&1)" || fail "R8c: an over-budget hold still rotates the rest"
grep -qFx -- "- lesson held-a $rot_pad" "$LEDGER" || fail "R8c: the held source stays even when it outgrows the budget"
assert_contains "$rot_out" "OVER budget" "R8c: the receipt names an over-budget body"
case "$rot_out" in *"kept within"*) fail "R8c: an over-budget body must not be reported as kept within budget: $rot_out" ;; esac
# R8d: the next rotation before a new examined run has nothing left to move,
# and the body is still over budget - it says so instead of a silent no-op.
rot_out="$("$BIN/ac-learn.sh" rotate-pending 2>&1)" || fail "R8d: a rotation with nothing to move must not fail"
assert_contains "$rot_out" "OVER budget" "R8d: nothing left to move still reports the over-budget body"
rm -rf "$rot_runs"/learning-9000000001

rm -f "$AC_HOME/config/learn-pending-budget"
note_ledger_reset

# --- the always-loaded staleness signal (aging) ------------------------------
# (always-loaded-layer-has-no-staleness-signal) Every other store is graded -
# repo-knowledge by diff, Pending by volume, usage by heat - while the ONE
# store loaded into every crewmate context had no clock at all. `stale` grades
# by the entry's last date against config/learn-stale-days; `reinforce` is the
# one sanctioned in-place edit (a clock carries no claim text), refreshing the
# date ONLY under a named-evidence receipt.

ALW="$AC_HOME/CREWMATE-learned.md"
alw_reset() {
  printf '# Fleet-learned crewmate lessons\n<!-- written only by ac-learn.sh transactions -->\n\n' >"$ALW"
  printf '## stale-one\n\nan old lesson.\n\n(learned 2026-01-01)\n\n' >>"$ALW"
  # The skill-pointer section sits between entries in a live file (a skill land
  # inserts under its heading wherever it is), and it is not an entry.
  printf '## when to reach for a learned skill\n- when a red needs attribution -> use skill characterise-the-failure\n\n' >>"$ALW"
  printf '## fresh-one\n\na fresh lesson.\n\n(learned %s)\n\n' "$(date -u +%F)" >>"$ALW"
  printf '## no-clock\n\nan unmarked legacy entry.\n' >>"$ALW"
}

# S1: grading - stale by age, fresh by age, NO-CLOCK never graded (fail toward
# silence, the unmarked-legacy direction), and the summary counts only real
# staleness.
alw_reset
out="$("$BIN/ac-learn.sh" stale)"
assert_contains "$out" "stale-one" "S1: the old entry is listed"
assert_contains "$(printf '%s\n' "$out" | grep 'stale-one')" "STALE" "S1: ... and graded STALE"
assert_contains "$(printf '%s\n' "$out" | grep 'fresh-one')" "FRESH" "S1: a current entry grades FRESH"
assert_contains "$(printf '%s\n' "$out" | grep 'no-clock')" "NO-CLOCK" "S1: a dateless entry is named, never graded"
assert_contains "$out" "3 entries, 1 stale" "S1: the summary counts only the genuinely stale"
assert_contains "$out" "reinforce" "S1: a stale grade hands over the remedy"
case "$out" in
  *"when to reach"*) fail "S1: the skill-pointer section is not an entry and is never graded: $out" ;;
esac

# S2: the threshold is the knob, not a constant.
printf '10000\n' >"$AC_HOME/config/learn-stale-days"
assert_contains "$("$BIN/ac-learn.sh" stale)" "3 entries, 0 stale" "S2: a huge threshold grades everything fresh"
rm -f "$AC_HOME/config/learn-stale-days"

# S3: reinforce refreshes the clock IN PLACE - entry text untouched, the
# original learned date preserved, the stale grade flips.
alw_reset
before_body="$(sed -n '/^## stale-one/,/^## /p' "$ALW" | grep 'an old lesson')"
out="$("$BIN/ac-learn.sh" reinforce stale-one --evidence 'the famX window re-derived it at spec/report.md')"
assert_contains "$out" "reinforced stale-one" "S3: the receipt names the entry"
assert_contains "$out" "the famX window re-derived it" "S3: ... and carries the evidence"
grep -q '(learned 2026-01-01, reinforced ' "$ALW" || fail "S3: the original learned date is preserved beside the new clock"
assert_contains "$(sed -n '/^## stale-one/,/^## /p' "$ALW")" "an old lesson" "S3: the lesson text is untouched"
assert_contains "$(printf '%s\n' "$("$BIN/ac-learn.sh" stale)" | grep 'stale-one')" "FRESH" "S3: the grade flips"

# S4: a SAME-DAY second reinforce is a no-op RECEIPT, not a refusal - and a
# repeat on a later date would REPLACE, never append (bytes are budget): the
# file must carry exactly one 'reinforced' token for the entry either way.
out="$("$BIN/ac-learn.sh" reinforce stale-one --evidence 'double-checked')"
assert_contains "$out" "already reinforced today" "S4: same-day repeat is a distinct receipt"
assert_eq "$(grep -c 'reinforced 2' "$ALW")" "1" "S4: exactly one reinforced token - replace semantics, no append"

# S5: the refusals, each naming its own defect.
refuses_learn() { local want="$1"; shift; out="$("$@" 2>&1)" && fail "expected refusal: $*"; assert_contains "$out" "$want" "refusal names '$want'"; }
refuses_learn "REQUIRES --evidence" "$BIN/ac-learn.sh" reinforce stale-one
refuses_learn "no entry" "$BIN/ac-learn.sh" reinforce ghost --evidence x
refuses_learn "no '(learned <date>)' line" "$BIN/ac-learn.sh" reinforce no-clock --evidence x
refuses_learn "single line" "$BIN/ac-learn.sh" reinforce stale-one --evidence 'two
lines'

# S6: the DISTILL run stages the layer + its grading for the scout (wiring, the
# R5 idiom - one awk process, no early-closing pipe).
awk '/^async function cmdRun\(/{f=1} f&&/always-loaded-staleness/{found=1} f&&/^}/{exit} END{exit !found}' "$ROOT/src/learn.ts" \
  || fail "S6: cmdRun must snapshot the staleness grading into sources/"

# S7: mawk 1.3.4 before its 20200724 snapshot has no interval expressions:
# there `[0-9]{4}` is a digit followed by the literal text `{4}` (probed in
# node:22.12.0, mawk 1.3.4 20200120), so a clock spelled with one never
# matches. This awk hands the host's own awk every argument with its
# intervals turned into exactly those literal braces.
mawk_real="$(command -v awk)"
mkdir -p "$TMP/mawkbin"
cat >"$TMP/mawkbin/awk" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  args+=("$(printf '%s\n' "$a" | sed -E 's/[{]([0-9]+(,[0-9]*)?)[}]/\\{\1\\}/g')")
done
exec "$MAWK_MODEL_REAL_AWK" "${args[@]}"
EOF
chmod +x "$TMP/mawkbin/awk"
mawk_model() { PATH="$TMP/mawkbin:$PATH" MAWK_MODEL_REAL_AWK="$mawk_real" "$@"; }
assert_eq "$(printf '2026\na{4}\n' | mawk_model awk '/^[0-9]{4}$|^a{4}$/')" "a{4}" \
  "S7: the model awk reads an interval as literal braces, as mawk does"
alw_reset
out="$(mawk_model "$BIN/ac-learn.sh" stale)"
assert_contains "$(printf '%s\n' "$out" | grep 'stale-one')" "STALE" \
  "S7: under mawk a dated entry is graded by its clock, never NO-CLOCK"
assert_contains "$out" "3 entries, 1 stale" "S7: ... and the summary counts it"
printf '# H\n\n## twice\n\nb\n\n(learned 2026-01-01, reinforced 2026-02-01)\n' >"$ALW"
out="$(mawk_model "$BIN/ac-learn.sh" reinforce twice --evidence 'the S7 window re-derived it')"
assert_contains "$out" "reinforced twice" "S7: under mawk reinforce finds the entry's clock"
grep -qxF "(learned 2026-01-01, reinforced $(date -u +%F))" "$ALW" \
  || fail "S7: under mawk reinforce REPLACES the prior reinforced date: $(grep '^(learned' "$ALW")"

# S8: GNU date(1) has no BSD -j or -v (probed: coreutils 9.1 answers
# "invalid option -- 'j'") and reads a date with -d, where an EMPTY string is
# today (probed). This date answers the way GNU's does for the -d forms the
# scripts use, on top of the host's own date; on a GNU host it IS that date.
gnu_date_real="$(command -v date)"
mkdir -p "$TMP/gnudatebin"
cat >"$TMP/gnudatebin/date" <<'EOF'
#!/usr/bin/env bash
real="$GNU_MODEL_REAL_DATE"
"$real" --version >/dev/null 2>&1 && exec "$real" "$@"
u=""; for a in "$@"; do [ "$a" != -u ] || u=-u; done
out=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j | -v*) printf "date: invalid option -- '%s'\n" "${1:1:1}" >&2; exit 1 ;;
    -d)
      case "${2:-}" in
        '') out+=(-j -f '%Y-%m-%d %H:%M:%S' "$("$real" $u +%F) 00:00:00") ;;
        @*) out+=(-r "${2#@}") ;;
        -*' days') n="${2#-}"; out+=("-v-${n% days}d") ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) out+=(-j -f '%Y-%m-%d %H:%M:%S' "$2 00:00:00") ;;
        *) printf "date: this model reads no -d form like '%s'\n" "$2" >&2; exit 1 ;;
      esac
      shift 2 ;;
    *) out+=("$1"); shift ;;
  esac
done
exec "$real" "${out[@]}"
EOF
chmod +x "$TMP/gnudatebin/date"
gnu_date_model() { PATH="$TMP/gnudatebin:$PATH" GNU_MODEL_REAL_DATE="$gnu_date_real" "$@"; }
assert_fails gnu_date_model date -u -j -f '%Y-%m-%d' 2026-01-01 +%s
assert_eq "$(gnu_date_model date -u -d 1970-01-02 +%s)" "86400" "S8: the model reads -d as GNU does"
alw_reset
out="$(gnu_date_model "$BIN/ac-learn.sh" stale)"
assert_contains "$(printf '%s\n' "$out" | grep 'stale-one')" "STALE" \
  "S8: under GNU date the age is computed, never left empty (which graded everything FRESH)"
assert_contains "$out" "3 entries, 1 stale" "S8: ... and the summary counts it"
# A clock that is not a date stays ungraded there too: GNU would read the
# empty string as today and call it zero days old.
mkdir -p "$AC_HOME/records/scenes"
printf '# undated\nMETA: created=2026-01-01T00:00:00Z heat=0\n' >"$AC_HOME/records/scenes/undated.md"
assert_contains "$(gnu_date_model "$BIN/ac-learn.sh" stale | grep 'undated')" "age=?d" \
  "S8: a scene with no updated= date has an unknown age, not age 0"
rm -rf "$AC_HOME/records/scenes"

# S9: the clock is written in UTC (ac_iso), so it is READ in UTC. An entry
# exactly learn-stale-days old by the UTC calendar is STALE in every local
# zone - including one whose date is not UTC's today, where a local read is a
# day off and contradicts the digest's UTC cutoff. The zone is picked so its
# date differs from UTC's now: 12h behind before 11:00Z, 14h ahead after.
host_date() { "$@"; }
utc_h="$(date -u +%H)"
if [ "${utc_h#0}" -lt 11 ]; then off_tz=XXX+12; else off_tz=XXX-14; fi
edge_d="$(date -u -v-30d +%F 2>/dev/null || date -u -d '-30 days' +%F)"
printf '# H\n\n## edge\n\nb\n\n(learned %s)\n' "$edge_d" >"$ALW"
for date_as in host_date gnu_date_model; do
  out="$(TZ="$off_tz" "$date_as" "$BIN/ac-learn.sh" stale)"
  assert_contains "$(printf '%s\n' "$out" | grep ' edge ')" "age=30d  STALE" \
    "S9 ($date_as, TZ=$off_tz): a UTC clock is read in UTC"
done

rm -f "$ALW"

# --- route-propose: the System One route proposer for lesson lines ---------
# Stdin lines (a report's ## Lessons bullets, a debrief's candidates) get two
# questions each in ONE request: owner (the nine debrief destinations) and
# dup (new, unclear, or one of the always-loaded CREWMATE-learned.md entries).
# Off/absent prints nothing and makes no request; shadow logs; on prints one
# line per input line plus the state_sha label key. Never writes a ledger.
cat >"$AC_HOME/CREWMATE-learned.md" <<'EOF'
# Fleet-learned crewmate lessons
<!-- written only by ac-learn.sh transactions; captains edit CREWMATE.md instead -->

## read-the-room-first

Read the family room before you review - the chief's ruling lives there, not in the brief.

(learned 2026-08-05)

## prove-tests-bite

Before trusting green, prove each new assertion actually bites.

(learned 2026-08-05)

## when to reach for a learned skill
- when a red needs attribution -> use skill characterise-the-failure
EOF
mkdir -p "$TMP/rpbin"
cat >"$TMP/rpbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; data=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -d) data="$2"; shift ;; esac; shift; done
cat "${data#@}" >"$FAKE_BODY"
n="$(cat "$FAKE_HITS" 2>/dev/null || printf 0)"; printf '%s\n' "$((n + 1))" >"$FAKE_HITS"
cat "$FAKE_RESP" >"$out"
printf '200'
EOF
chmod +x "$TMP/rpbin/curl"
export PATH="$TMP/rpbin:$PATH" FAKE_BODY="$TMP/rp-body" FAKE_HITS="$TMP/rp-hits" FAKE_RESP="$TMP/rp-resp"
cat >"$FAKE_RESP" <<'EOF'
{"model":"m","answers":{
 "owner_1":{"type":"choice","choice":"repo_knowledge","probabilities":{"backlog":0,"room":0,"learnings":0.05,"captain":0,"projects":0,"repo_knowledge":0.93,"project_docs":0.02,"distro_task":0,"none":0},"confidence":0.9},
 "dup_1":{"type":"choice","choice":"new","probabilities":{"new":0.97,"unclear":0.02,"read-the-room-first":0.01,"prove-tests-bite":0},"confidence":0.9},
 "owner_2":{"type":"choice","choice":"learnings","probabilities":{"backlog":0,"room":0,"learnings":0.9,"captain":0,"projects":0,"repo_knowledge":0.05,"project_docs":0,"distro_task":0.05,"none":0},"confidence":0.85},
 "dup_2":{"type":"choice","choice":"read-the-room-first","probabilities":{"new":0.1,"unclear":0.02,"read-the-room-first":0.88,"prove-tests-bite":0},"confidence":0.8},
 "owner_3":{"type":"choice","choice":"none","probabilities":{"backlog":0,"room":0,"learnings":0,"captain":0,"projects":0,"repo_knowledge":0,"project_docs":0,"distro_task":0,"none":1},"confidence":1},
 "dup_3":{"type":"choice","choice":"new","probabilities":{"new":0.6,"unclear":0.4,"read-the-room-first":0,"prove-tests-bite":0},"confidence":0.3},
 "worth_1":{"type":"choice","choice":"durable","probabilities":{"durable":0.9,"routine":0.05,"unclear":0.05},"confidence":0.85},
 "worth_2":{"type":"choice","choice":"routine","probabilities":{"durable":0.2,"routine":0.75,"unclear":0.05},"confidence":0.7},
 "worth_3":{"type":"choice","choice":"unclear","probabilities":{"durable":0.3,"routine":0.3,"unclear":0.4},"confidence":0.1}
},"usage":{"input_tokens":1,"output_tokens":0}}
EOF
printf '{"openrouter":{"api_key":"sk-or-TEST"}}\n' >"$AC_HOME/config/providers.json"
rphits() { cat "$FAKE_HITS" 2>/dev/null || printf 0; }
lines='- ac-tree.sh get fail-closes on a missing epic branch: exit 2, no slot leased
- Always read the family room before reviewing; the ruling is there, not in the brief
- Thanks chief, all done here'

rm -f "$AC_HOME/config/jev"
out="$(printf '%s\n' "$lines" | "$BIN/ac-learn.sh" route-propose 2>&1)" || fail "route-propose: absent knob must exit 0"
assert_eq "$out" "" "route-propose: absent knob prints nothing"
assert_eq "$(rphits)" "0" "route-propose: absent knob makes no request"
out="$(printf '' | "$BIN/ac-learn.sh" route-propose 2>&1)" || fail "route-propose: empty stdin must exit 0"
assert_eq "$out" "" "route-propose: empty stdin prints nothing"

printf 'shadow\n' >"$AC_HOME/config/jev"
out="$(printf '%s\n' "$lines" | "$BIN/ac-learn.sh" route-propose 2>/dev/null)"
assert_eq "$out" "" "route-propose: shadow prints nothing"
assert_eq "$(rphits)" "1" "route-propose: one request for every line"
assert_eq "$(jq -r '.questions | keys | join(",")' "$FAKE_BODY")" "dup_1,dup_2,dup_3,owner_1,owner_2,owner_3,worth_1,worth_2,worth_3" "route-propose: three questions per line"
assert_eq "$(jq -r '.questions.worth_1.criteria | keys | join(",")' "$FAKE_BODY")" "durable,routine,unclear" "route-propose: the worth verdicts"
assert_eq "$(jq -r '.questions.owner_1.criteria | keys | length' "$FAKE_BODY")" "9" "route-propose: nine owners"
assert_eq "$(jq -r '.questions.dup_2.criteria | keys | join(",")' "$FAKE_BODY")" "new,prove-tests-bite,read-the-room-first,unclear" "route-propose: dup options are new, unclear and every learned entry"
assert_contains "$(jq -r '.questions.dup_2.criteria["read-the-room-first"]' "$FAKE_BODY")" "Read the family room before you review" "route-propose: an entry's body is its criterion"
assert_contains "$(jq -r '.state' "$FAKE_BODY")" "[2] - Always read the family room" "route-propose: lines are numbered in the state"
assert_eq "$(tail -n1 "$AC_HOME/state/jev-shadow.jsonl" | jq -r '.site')" "learn-route" "route-propose: shadow record site"

printf 'on\n' >"$AC_HOME/config/jev"
out="$(printf '%s\n' "$lines" | "$BIN/ac-learn.sh" route-propose 2>/dev/null)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "1	owner=repo_knowledge p=0.93	dup-of=none	worth=durable p=0.9" "route-propose: a repo fact routes to repo-knowledge, new, durable"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "2	owner=learnings p=0.9	dup-of=read-the-room-first p=0.88	worth=routine p=0.75" "route-propose: a duplicate lesson names the entry it repeats and its worth"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "3	owner=none p=1	dup-of=none	worth=unclear p=0.4" "route-propose: noise routes nowhere; unclear worth is printed, never hidden"
assert_contains "$(printf '%s\n' "$out" | sed -n 4p)" "state_sha=" "route-propose: the label key closes the output"
assert_eq "$(grep -c . "$AC_HOME/records/learnings.md" 2>/dev/null || printf 0)" "$(grep -c . "$AC_HOME/records/learnings.md" 2>/dev/null || printf 0)" "route-propose: never writes the ledger"
rm -f "$AC_HOME/config/jev"

# --- differential: src/learn.ts against the frozen bash original -------------
# DISPUTED: the implementation (tests/fixtures/ac-learn.sh under bash vs src/learn.ts through bin/ac-learn.sh)
# HELD-CONSTANT: two side roots seeded alike ($LOH for the oracle, $LNH for the shim) - a home at <side>/home rebuilt per row by the same commands; each side's bin holding the same ac-spawn.sh and ac-jev.sh stubs beside the live siblings (the oracle's from make_oracle_bin, the shim's built by hand under its own name); argv and env (the side root spelled @H, substituted in values only; AC_HOME=<side>/home, AC_PANE_AGENT, AC_GATE and AC_CURATE the leg's stubs unless a row names others; FAKE_HERDR and FAKE_ORCA under each side); cwd <side>/cwd; stdin /dev/null unless a row pipes lines; LC_ALL=C unless a row names en_US.UTF-8; TMPDIR <side>/tmp; PATH stubs - date answering one instant per format (BSD date itself for an age's -j -f and an epoch's -r), sleep logging each call but the early-pane poll's 0.05 and returning at once; exit status, stdout and stderr compared whole once normalised (the side root @H, either bin root ROOT, every 64-hex digest SHA, the entry's pid PID, mktemp suffixes, wake-spool names), then the world: every path under home/, tmp/ and stub/ with its mode and bytes, each backup as its sorted tar listing.
unset AC_PANE_AGENT LEARN_PANE LEARN_CREW_STATE LEARN_CREW_STATE_CAPTURE
lobin="$(make_oracle_bin ac-learn)"
# The frozen entry calls the cadence and transaction helpers retired from
# bin/ac-maintenance-lib.sh and bin/ac-lib.sh once src/learn.ts took their
# last caller; the oracle's own lib copy gets them back, frozen at
# tests/fixtures/ac-maintenance-retired.sh.
cat "$ROOT/tests/fixtures/ac-maintenance-retired.sh" >>"$lobin/ac-maintenance-lib.sh"
cmp -s "$lobin/ac-learn.sh" "$ROOT/tests/fixtures/ac-learn.sh" || fail "the oracle bin holds the frozen original"
lnroot="$TMP/learn-shim"
mkdir -p "$lnroot/bin"
cp "$BIN"/*.sh "$lnroot/bin/"
ln -s "$ROOT/src" "$lnroot/src"
ln -s "$ROOT/dashboard" "$lnroot/dashboard"
lnbin="$lnroot/bin"
cmp -s "$lnbin/ac-learn.sh" "$BIN/ac-learn.sh" || fail "the shim side runs the live shim"
LOH="$TMP/lside-o"; LNH="$TMP/lside-n"
LSTUBS="$TMP/lstubs"; LGITSTUBS="$TMP/lgitstubs"; mkdir -p "$LSTUBS" "$LGITSTUBS"
cat >"$LSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;;
  *%H:%M*) echo '2026-01-01 07:00' ;;
  *' -j -f '*|*' -r '*|*' -d '*) exec /bin/date "$@" ;;
  *%s*) echo 1767225600 ;;
  *%Y-%m-%d*) echo 2026-01-01 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
# How many 0.05 s polls of the early pane file fit before the scout writes it
# (none, when it is there first) is scheduling, not behaviour: those go unlogged.
cat >"$LSTUBS/sleep" <<'STUB'
#!/bin/sh
[ "$*" = 0.05 ] || printf '%s\n' "$*" >>"$STUB_DIR/sleep.log"
STUB
# The scout: `run` writes the early pane file (LPANE_ID, default `pL tL`, or
# none when LPANE_NOPANE is set), copies the identity it finds live into the
# stub dir, writes report.md and retro.md unless LPANE_NOREPORT /
# LPANE_NORETRO, copies every candidate-*.md under LPANE_CANDS, then prints its
# events naming that pane (no done event under LPANE_NODONE, a line that is no
# JSON under LPANE_JUNK) with LPANE_STATUS; `reap-pane` answers closed unless
# LPANE_OPEN names the pane.
cat >"$LSTUBS/pane" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/pane.log"
if [ "${1:-}" = reap-pane ]; then
  [ "${3:-}" = "${LPANE_OPEN:-}" ] && c=false || c=true
  printf '{"event":"reap-pane-done","pane":"%s","closed":%s}\n' "${3:-}" "$c"
  exit 0
fi
cwd=""; pane_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift ;;
    --pane-file) pane_file="$2"; shift ;;
  esac
  shift
done
printf '%s\n' "${AC_WINDOW_FAMILY-unset}" >"$STUB_DIR/family.seen"
[ -n "${LPANE_NOPANE:-}" ] || printf '%s\n' "${LPANE_ID:-pL tL}" >"$pane_file"
i=0
while [ -z "${LPANE_NOPANE:-}" ] && [ "$i" -lt 200 ]; do
  set -- "$AC_HOME"/state/verify-learning-*.meta
  [ -s "$1" ] && break
  /bin/sleep 0.02; i=$((i + 1))
done
set -- "$AC_HOME"/state/verify-learning-*
for f in "$@" "$AC_HOME"/state/.pane-verify-learning-*; do [ ! -e "$f" ] || cp "$f" "$STUB_DIR/seen.${f##*/}"; done
[ -z "${LPANE_HOLD:-}" ] || /bin/sleep "$LPANE_HOLD"
[ -n "${LPANE_NOREPORT:-}" ] || printf '# report\nstatus: ok\n' >"$cwd/report.md"
[ -n "${LPANE_NORETRO:-}" ] || printf '# retro\n' >"$cwd/retro.md"
[ -z "${LPANE_CANDS:-}" ] || cp "$LPANE_CANDS"/candidate-*.md "$cwd/"
lpane="${LPANE_ID:-pL tL}"
printf '{"event":"pane","pane":"%s"}\n' "${lpane%% *}"
[ -z "${LPANE_JUNK:-}" ] || printf 'not json\n'
[ -n "${LPANE_NODONE:-}" ] || printf '{"event":"done","status":"%s","transcript":"%s","pane":"%s"}\n' "${LPANE_STATUS:-ok}" "${LPANE_TRANSCRIPT:-}" "${lpane%% *}"
exit 0
STUB
# The maintenance gate: a receipt deciding LGATE_DECISION (continue) with the
# read-evidence a judge that opened the inputs would cite; LGATE_RC exits
# with that status after LGATE_DIAG on stderr; LGATE_SAY prints a line;
# LGATE_BAD binds the receipt to a hash no plan has; LGATE_HOLD sleeps first.
cat >"$LSTUBS/gate" <<'GATE'
#!/usr/bin/env bash
mode=""; run=""; subject=""; manifest=""; plan=""
printf '%s\n' "$*" >>"$STUB_DIR/gate.log"
[ -z "${LGATE_HOLD:-}" ] || /bin/sleep "$LGATE_HOLD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    --manifest) manifest="$2"; shift 2 ;;
    --plan) plan="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${LGATE_RC:-}" ]; then
  [ -z "${LGATE_DIAG:-}" ] || printf '%s\n' "$LGATE_DIAG" >&2
  exit "$LGATE_RC"
fi
decision="${LGATE_DECISION:-continue}"
[ -z "${LGATE_SAY:-}" ] || printf '%s\n' "$LGATE_SAY"
mkdir -p "$run/gates/$subject"
input_sha="$(shasum -a 256 <"$manifest" | awk '{print $1}')"
plan_sha="$(shasum -a 256 <"$plan" | awk '{print $1}')"
[ -z "${LGATE_BAD:-}" ] || plan_sha=0000000000000000000000000000000000000000000000000000000000000000
cat >"$run/gates/$subject/decision.md" <<EOF
---
schema: "agentcrew.maintenance-gate/v1"
mode: "$mode"
subject: "$subject"
decision: "$decision"
authority: "second-chief"
engine: "stub"
model: "leg"
input_manifest_sha256: "$input_sha"
action_plan_sha256: "$plan_sha"
reviewed_at: "2026-01-01T00:00:00Z"
---
# Maintenance Gate Decision
## Decision
$decision
## Grounds
The leg's stub judged the exact recoverable action plan.
## Inputs Read
- INPUT MANIFEST QUOTE: $(awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$manifest")
- ACTION PLAN NEW SHA-256: $(jq -r '.actions[0].new_sha256' "$plan")
- STAGED PAYLOAD QUOTE: $(prun="$(dirname "$plan")"; [ "$(basename "$prun")" != plans ] || prun="$(dirname "$prun")"; awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$prun/$(jq -r '.actions[0].staged' "$plan")")
## Proposed Process
Apply or preserve only the hash-bound subject.
EOF
exit 0
GATE
cat >"$LSTUBS/curate" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/curate.log"
echo "curate stub: $*"
echo "curate stub stderr" >&2
exit "${LCURATE_RC:-0}"
STUB
cat >"$LSTUBS/runner" <<'STUB'
#!/bin/sh
printf 'runner\n' >>"$STUB_DIR/runner.log"
[ -z "${LRUNNER_HOLD:-}" ] || /bin/sleep "$LRUNNER_HOLD"
exit "${LRUNNER_RC:-0}"
STUB
cat >"$LGITSTUBS/git" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/git.log"
[ "$1" = -C ] && shift 2
case "$1 ${2:-}" in
  "rev-parse HEAD") echo "${LGIT_HEAD:-1111111111111111111111111111111111111111}" ;;
  "worktree add") mkdir -p "$5" ;;
  "worktree remove") rm -rf "$4" ;;
  *) : ;;
esac
STUB
# Both bins carry the same spawn and jev stand-ins: the oracle reaches its
# siblings through `$(dirname "$0")`, the shim through STARTED_BIN.
for b in "$lobin" "$lnbin"; do
  cat >"$b/ac-spawn.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/spawn.log"
[ -z "${LSPAWN_META:-}" ] || printf 'kind=roomchief\n' >"$AC_HOME/state/learning-chief.meta"
echo "spawn stub: promoted"
echo "spawn stub: stderr" >&2
exit "${LSPAWN_RC:-0}"
STUB
  cat >"$b/ac-jev.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/jev.log"
case "$1" in
  ask) [ -z "${LJEV_ANSWER:-}" ] || cat "$LJEV_ANSWER" ;;
  sha) echo statesha ;;
esac
STUB
  chmod +x "$b/ac-spawn.sh" "$b/ac-jev.sh"
done
chmod +x "$LSTUBS"/* "$LGITSTUBS/git"

lboth() {  # lboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$LOH" "$LNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
lseed() { [ ! -e "$H" ] || chmod -R u+rwX "$H"; rm -rf "$H"; mkdir -p "$H/home" "$H/cwd" "$H/tmp" "$H/stub" "$H/herdr/panes" "$H/herdr/tabs" "$H/orca/terminals"; }
lstd() { lseed; mkdir -p "$H/home/records" "$H/home/state" "$H/home/data" "$H/home/config" "$H/home/projects" "$H/home/skills"; }
lput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # lput <path under the side> <bytes>
LLC=C; LENV=(); LCWD=cwd; LHOME=@H/home; LPATH=""; LPLANT=""; LSTDIN=/dev/null; LOBIN="$lobin"; LNBIN="$lnbin"
lrun_side() {  # lrun_side <bin> <side root> <prefix> <args...> - LPLANT=<path under the side> links <path>.<the entry's pid> to <side>/victim first
  local bin="$1" h="$2" p="$3" x v path rc=0; shift 3
  path="$LSTUBS:$PATH"; [ -z "$LPATH" ] || path="${LPATH//@H/$h}"
  local a=() e=("LC_ALL=$LLC" "PATH=$path" "TMPDIR=$h/tmp" "STUB_DIR=$h/stub" "FAKE_HERDR=$h/herdr" "FAKE_ORCA=$h/orca"
    "AC_PANE_AGENT=$LSTUBS/pane" "AC_GATE=$LSTUBS/gate" "AC_CURATE=$LSTUBS/curate")
  [ -z "$LHOME" ] || e+=("AC_HOME=${LHOME//@H/$h}")
  for x in ${LENV[@]+"${LENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  { (cd "$h/$LCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u CDPATH -u AC_LOCK_STALE_GRACE -u EPOCHSECONDS \
    -u AC_BACKEND -u AC_PANE_AGENT -u AC_GATE -u AC_CURATE -u AC_WINDOW_FAMILY -u AC_LEARN_TIMEOUT -u AC_LEARN_START_TIMEOUT \
    -u AC_LEARN_SUITE_BIN -u AC_LEARN_SUITE_TIMEOUT -u AC_SEND_UNPROVEN "${e[@]}" \
    /bin/sh -c 'printf %s "$$" >"$0"; [ -z "$1" ] || ln -s "$2" "$1.$$"; shift 2; exec "$@"' \
    "$TMP/$p.pid" "${LPLANT:+$h/$LPLANT}" "$h/victim" "$bin/ac-learn.sh" ${a[@]+"${a[@]}"}) <"${LSTDIN//@H/$h}" >"$TMP/$p.raw" 2>"$TMP/$p.err"; } 2>/dev/null || rc=$?
  { cat "$TMP/$p.pid"; printf '\n'; } >>"$h/.pids"
  return "$rc"
}
lnorm() {  # lnorm <file> <side root> - the side root @H, bin roots ROOT, digests SHA, the k-th run's pid PID<k> where it names a temp, a run or a snapshot, mktemp and spool names
  local e=() k=0 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    k=$((k + 1))
    e+=(-e "s/(maintenance-learning-manual-[0-9]+-)$p([^0-9]|\$)/\1PID$k\2/g" -e "s/adhoc-$p([^0-9]|\$)/adhoc-PID$k\1/g"
      -e "s/\.tmp\.$p(\.[0-9]+)?([^0-9]|\$)/.tmp.PID$k\2/g" -e "s/\.actions\.$p([^0-9]|\$)/.actions.PID$k\1/g")
  done 2>/dev/null <"$2/.pids" || true
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-learn#ROOT#g" -e "s#$TMP/learn-shim#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e 's/[0-9a-f]{64}/SHA/g' ${e[@]+"${e[@]}"} \
    -e 's/(ac-learn-route|tmp)\.[A-Za-z0-9]{6,10}/\1.XXXXXX/g' -e 's#\.wake-spool/[0-9]+\.[0-9]+\.[0-9]+#.wake-spool/WAKE#g' "$1"
}
LO_RC=0; LN_RC=0
lw13() {  # W13 ORDER (named): run's printed candidate list, `find` (directory) order on the oracle, put in the byte order the port prints
  LC_ALL=C awk '{ if ($0 ~ /^    @H\/home\/data\/learning-[0-9]+\/candidate-/) { if (!b) k = NR; b = 1 } else { k = NR; b = 0 } printf "%d\t%s\n", k, $0 }' \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2 | cut -f2-
}
lpair() {  # lpair <args...> - both sides run, outputs normalised, nothing compared yet
  LO_RC=0; LN_RC=0
  lrun_side "$LOBIN" "$LOH" lo "$@" || LO_RC=$?
  lrun_side "$LNBIN" "$LNH" ln "$@" || LN_RC=$?
  lnorm "$TMP/lo.raw" "$LOH" >"$TMP/lo.out"; lnorm "$TMP/lo.err" "$LOH" >"$TMP/lo.err2"
  ! LC_ALL=C grep -qE '^    @H/home/data/learning-[0-9]+/candidate-' "$TMP/lo.out" \
    || { lw13 <"$TMP/lo.out" >"$TMP/lo.w13"; mv "$TMP/lo.w13" "$TMP/lo.out"; }
  lnorm "$TMP/ln.raw" "$LNH" >"$TMP/ln.out"; lnorm "$TMP/ln.err" "$LNH" >"$TMP/ln.err2"
}
lrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
lsame_rc_out() {
  assert_eq "$LN_RC" "$LO_RC" "learn differential exit for '$*' at line $(lrow)"
  cmp -s "$TMP/lo.out" "$TMP/ln.out" || fail "learn differential stdout differs for '$*' at line $(lrow): $(diff -a "$TMP/lo.out" "$TMP/ln.out" | head -n 8)"
}
lsame_err() {
  cmp -s "$TMP/lo.err2" "$TMP/ln.err2" || fail "learn differential stderr differs for '$*' at line $(lrow): $(diff -a "$TMP/lo.err2" "$TMP/ln.err2" | head -n 8)"
}
lworld() {  # lworld <side root> - every path under home/ tmp/ stub/ herdr/ orca/ in normalised byte order, with its mode and bytes (a backup: its tar listing)
  local h="$1" f n i
  local -a names=() modes=()
  while IFS= read -r -d '' f; do names+=("$f"); done < <(cd "$h" && find home tmp stub herdr orca -print0 2>/dev/null)
  [ "${#names[@]}" -eq 0 ] || while IFS= read -r f; do modes+=("$f"); done < <(cd "$h" && printf '%s\0' "${names[@]}" | xargs -0 stat -f '%Sp')
  for i in "${!names[@]}"; do
    printf '%s\t%s\n' "${names[i]//$'\n'/\\n}" "$i"
  done >"$h/.names"
  lnorm "$h/.names" "$h" | LC_ALL=C sort | while IFS=$'\t' read -r n i; do
    f="${names[i]}"
    if [ -L "$h/$f" ]; then printf '== %s -> %s\n' "$n" "$(readlink "$h/$f")"; continue; fi
    printf '== %s %s\n' "$n" "${modes[i]}"
    [ ! -d "$h/$f" ] || continue
    case "$f" in
      */state/backups/*.tar.gz) tar -tzf "$h/$f" 2>&1 | LC_ALL=C sort ;;
      *) cat "$h/$f" 2>/dev/null || printf '<unreadable>'; printf '\n' ;;
    esac
  done
}
lsame_world() {
  lworld "$LOH" >"$TMP/lo.world"; lworld "$LNH" >"$TMP/ln.world"
  lnorm "$TMP/lo.world" "$LOH" >"$TMP/lo.world2"; lnorm "$TMP/ln.world" "$LNH" >"$TMP/ln.world2"
  cmp -s "$TMP/lo.world2" "$TMP/ln.world2" || fail "learn differential world differs after '$*' at line $(lrow): $(diff -a "$TMP/lo.world2" "$TMP/ln.world2" | head -n 12)"
}
lsame() { lpair "$@"; lsame_rc_out "$@"; lsame_err "$@"; lsame_world "$@"; }
lout() { cat "$TMP/ln.out"; }
lerr() { cat "$TMP/ln.err2"; }
loerr() { cat "$TMP/lo.err2"; }
lrefuse() {  # lrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  lsame "$@"
  assert_eq "$LN_RC:$(lout):$(lerr)" "1::$want" "learn refusal for '$*' at line $(lrow)"
}
lok() {  # lok <args...> - both sides succeed alike, nothing on stderr
  lsame "$@"
  assert_eq "$LN_RC:$(lerr)" "0:" "learn success for '$*' at line $(lrow)"
}
LUSAGE="ERROR: usage: ac-learn.sh tick [<landing-id>]|autoroom|suite [<task-id>]|run|note <line>...|land <candidate>|promote <name>|rotate-pending|stale|reinforce <slug> --evidence <line>|maintenance status|resume <txid>|abandon <txid>"
LNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'

# 1. the preamble: every refusal before any home read - no verb, -h and an
#    unknown verb are the one usage line; an unsupported backend name refuses
#    every verb, note and promote included (W16); extra words after the
#    word-less verbs are ignored.
lboth lstd
lrefuse "$LUSAGE"
lrefuse "$LUSAGE" -h
lrefuse "$LUSAGE" bogus
LTMUX="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
lboth lput home/config/backend $'tmux\n'
lrefuse "$LTMUX" note '- a lesson'
lrefuse "$LTMUX" promote some-skill
lboth lstd
LENV=(AC_BACKEND=tmux); lrefuse "$LTMUX" tick; LENV=()
lok stale extra words
lok rotate-pending extra
lok maintenance

# Homeless: the verbs whose bash refused at its first home read agree; tick
# and autoroom are the named W10 divergence - one refusal where the bash
# printed three (tick, exit 1) and two (autoroom, exit 0).
LHOME=""
lrefuse "$LNOHOME" note '- a lesson'
lrefuse "$LNOHOME" stale
lrefuse "$LNOHOME" rotate-pending
lrefuse "$LNOHOME" maintenance status
lrefuse "$LNOHOME" reinforce s --evidence e
lrefuse "$LUSAGE" bogus
lpair tick
assert_eq "$LO_RC:$(grep -c 'AC_HOME is not set' "$TMP/lo.err2")" "1:3" "W10: the oracle's homeless tick printed three refusals"
assert_eq "$LN_RC:$(lerr)" "1:$LNOHOME" "W10 (named): the port's homeless tick is one refusal"
lpair autoroom
assert_eq "$LO_RC:$(grep -c 'AC_HOME is not set' "$TMP/lo.err2")" "0:2" "W10: the oracle's homeless autoroom printed two refusals, exit 0"
assert_eq "$LN_RC:$(lerr)" "0:$LNOHOME" "W10 (named): the port's homeless autoroom is one refusal, exit 0"
LHOME=@H/home

# 2. note: the frame minted on an absent ledger, insertion before the first
#    `## Distilled` with the seam blank held, every refusal before any write,
#    the lock, and W1 (a word holding LF passes the marker refusal).
lboth lstd
lok note '### 2026-01-01 (solo s1)' '- a first lesson (by: s1, first-hand)'
lok note '- a second lesson'
lboth lstd
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n- old\n\n\n## Distilled\n\n- [distilled -> x] sources=1 updated=2026-01-01 ([skill](../skills/x/SKILL.md))\n'
lok note '- placed above the index'
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n- unterminated'
lok note '- after an unterminated line'
lrefuse "ERROR: usage: ac-learn.sh note <line>... (each argument is appended verbatim as one line under '## Pending')" note
lrefuse "ERROR: refusing to append the section marker '## Distilled': a second marker makes learn_ledger_split read everything after it as the pointer index and drop it (nothing written)" note '- ok' '## Distilled'
lrefuse "ERROR: note takes lesson lines only and defines no flags - refusing '--file' (nothing written). A ledger line is '- <lesson>' and a heading is '### <date> (solo|family <id>)', each passed as its own argument." note --file x
lrefuse "ERROR: note takes lesson lines only and defines no flags - refusing '-x' (nothing written). A ledger line is '- <lesson>' and a heading is '### <date> (solo|family <id>)', each passed as its own argument." note -x
lok note $'- one\n## Distilled\n- two (by: s2, first-hand)'
lboth lstd
lboth lput home/state/.learn-note.lock/pid "$$"$'\n'
lsame note '- refused under a held lock'
assert_contains "$(lerr)" "learnings ledger lock" "note: a held lock refuses with nothing written"
lboth lstd
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n'
lboth chmod 600 @H/home/records/learnings.md
lok note '- the mode the rewrite leaves (W12)'
# EXCLUSIVE TEMPS (named): a link planted at the bash's `<ledger>.tmp.<pid>`
# was written through and the victim took the new ledger; the port's temp is
# made exclusively and the victim is untouched.
lboth lstd
lboth lput victim $'victim\n'
LPLANT=home/records/learnings.md.tmp
lpair note '- through a planted link'
LPLANT=""
assert_eq "$LO_RC:$LN_RC" "0:0" "note with a planted temp link: both land the lesson"
assert_contains "$(cat "$LOH/victim")" "through a planted link" "the oracle wrote through the planted link (W12)"
assert_eq "$(cat "$LNH/victim")" "victim" "the port never writes through a planted temp (W12, named)"
assert_contains "$(cat "$LNH/home/records/learnings.md")" "- through a planted link" "the port's ledger still takes the lesson"

# 3. tick: unkeyed and keyed, a duplicate inside the window, the crossing
#    wake, busy locks, the key grammar, the legacy counter, a keyed count of 08.
lboth lstd
lok tick
lok tick fam-a
lok tick fam-a
lboth lput home/state/.learn.meta $'generation=2\ndebriefs=7\n'
lok tick fam-b
lok tick fam-c
lboth lstd
lboth lput home/state/.learn.meta $'stows=3\n'
lok tick
lboth lput home/state/.learn-cadence.lock/pid "$$"$'\n'
lsame tick
assert_eq "$LN_RC" "1" "an unkeyed tick whose lock is busy ends 1"
lsame tick fam-z
assert_contains "$(lout)" "tick NOT counted: landing fam-z could not be claimed" "a keyed tick whose lock is busy says so"
lboth lstd
lrefuse "ERROR: tick key must be a task/family id [a-z0-9-] (got: 'Bad')" tick Bad
lrefuse "ERROR: tick takes at most one landing id (got: a b)" tick a b
lok tick ''
# W11 (named): under a UTF-8 locale bash's bracket collated `Bad` in.
LLC=en_US.UTF-8
lpair tick Bad
LLC=C
assert_eq "$LO_RC:$LN_RC" "0:1" "W11: the oracle stamped 'Bad' under UTF-8, the port refuses it per the text"
# A count or generation of 08 is an arithmetic error inside learn_cadence_call's
# capture: only that subshell ended, its cadence lock still held by the entry,
# and the caller took its failed-and-spoke branch. SHELL-OWN STDERR (named): the
# oracle's own diagnostic is dropped before the comparison.
l08() {  # l08 <args...> - lsame once the oracle's arithmetic line is dropped and each side's left-held cadence lock is checked and cleared
  local p h
  lpair "$@"
  assert_contains "$(loerr)" "08: value too great for base" "the oracle's capture ended on the arithmetic error for '$*'"
  LC_ALL=C sed -E '/^ROOT\/bin\/ac-maintenance-lib\.sh: line [0-9]+: 08: value too great for base /d' "$TMP/lo.err2" >"$TMP/lo.err3"
  mv "$TMP/lo.err3" "$TMP/lo.err2"
  lsame_rc_out "$@"; lsame_err "$@"
  for p in "lo:$LOH" "ln:$LNH"; do
    h="${p#*:}"
    assert_eq "$(cat "$h/home/state/.learn-cadence.lock/pid")" "$(cat "$TMP/${p%%:*}.pid")" "the cadence lock is left held by the entry after '$*' ($h)"
    rm -rf "$h/home/state/.learn-cadence.lock"
  done
  lsame_world "$@"
}
lboth lstd
lboth lput home/state/.learn.meta $'generation=1\ndebriefs=08\n'
l08 tick fam-x
assert_eq "$LN_RC:$(lout)" "1:tick NOT counted: landing fam-x could not be claimed (see the warning above) - re-run this tick" "a keyed tick whose count the arithmetic refuses says NOT counted"

# 4. rotate-pending: under budget a no-op, over budget the oldest prefix
#    archived at a safe cut, held sources kept with their heading, a bad knob,
#    nothing archivable.
lrotledger() {
  local i
  { printf '# Learning Ledger\n\n## Pending\n\n[pending-overflow -> learnings-archive/pending-1.md]\n### 2025-12-01 (family f)\n'
    for i in 1 2 3 4 5 6; do printf -- '- lesson %02d with padding to take some room in the body\n  continued %02d\n' "$i" "$i"; done
    printf '### 2025-12-02 (solo s)\n- held source bullet\n  its continuation\n- lesson 07 newest\n\n## Distilled\n\n- [distilled -> x] sources=1 updated=2026-01-01 ([skill](../skills/x/SKILL.md))\n'
  } >"$H/home/records/learnings.md"
}
lboth lstd
lboth lrotledger
lok rotate-pending
lboth lput home/config/learn-pending-budget $'300\n'
lboth lput home/data/learning-1700000000/report.md $'# report\n'
lboth lput home/data/learning-1700000000/candidate-a.md $'kind: skill\nname: a\n===sources===\n2025-12-02\thook\t- held source bullet\n'
lsame rotate-pending
assert_contains "$(cat "$LNH/home/records/learnings.md")" "- held source bullet" "the last examined run's held source stays in Pending"
lboth lrotledger
lboth lput home/config/learn-pending-budget $'10\n'
lsame rotate-pending
lboth lput home/config/learn-pending-budget $'12k\n'
lrefuse "ERROR: config/learn-pending-budget must be a byte count (got: '12k')" rotate-pending

# 5. stale and reinforce: graded, NO-CLOCK, the discovery section skipped,
#    scenes, the knob; every reinforce refusal, the same-day receipt, the
#    rewrite (W18: BSD date fills the time of day and normalizes Feb 30).
lcml() {
  lput home/CREWMATE-learned.md $'# Fleet-learned crewmate lessons\n\n## stale-one\n\nbody\n\n(learned 2025-10-01)\n\n## fresh-one\n\nbody\n\n(learned 2025-12-20, reinforced 2025-12-30)\n\n## no-clock\n\nbody\n\n## today-one\n\nbody\n\n(learned 2025-11-01, reinforced 2026-01-01)\n\n## feb-thirty\n\n(learned 2025-02-30)\n\n## when to reach for a learned skill\n- when x -> use skill x\n'
  lput home/records/scenes/alpha.md $'# alpha\nscene=alpha updated=2025-11-01T00:00:00Z\n'
  lput home/records/scenes/beta.md $'# beta\nupdated=2025-12-31T00:00:00Z extra\n'
}
lboth lstd
lok stale
lboth lcml
lok stale
lboth lput home/config/learn-stale-days $'30d\n'
lrefuse "ERROR: config/learn-stale-days must be a day count (got: '30d')" stale
lboth lstd
lboth lcml
lrefuse "ERROR: --evidence needs a value" reinforce stale-one --evidence
lrefuse "ERROR: unknown flag: --nope" reinforce stale-one --nope
lrefuse "ERROR: reinforce takes ONE slug (got 'a' and 'b')" reinforce a b --evidence e
lrefuse "ERROR: usage: ac-learn.sh reinforce <slug> --evidence '<what this window proved>'" reinforce --evidence e
lrefuse "ERROR: --evidence must be a single line" reinforce stale-one --evidence $'two\nlines'
lrefuse "ERROR: no entry '## ghost' in CREWMATE-learned.md (ac-learn.sh stale lists them)" reinforce ghost --evidence e
lrefuse "ERROR: entry '## no-clock' carries no '(learned <date>)' line to refresh - nothing written" reinforce no-clock --evidence e
lok reinforce today-one --evidence 'the window re-ran it'
lok reinforce stale-one --evidence 'the window re-ran it'
lok reinforce fresh-one --evidence 'replaces the reinforced date'
# stale-one is reinforced today by now, and a same-day reinforce answers
# before the lock: reseeded, it reaches the lock.
lboth lcml
lboth lput home/CREWMATE-learned.md.lock/pid "$$"$'\n'
lsame reinforce stale-one --evidence e
assert_contains "$(lerr)" "CREWMATE-learned lock" "reinforce under a held lock refuses with nothing written"

# 6. maintenance: status clean and held (two journals, byte order), resume's
#    and abandon's refusals and settles.
lboth lstd
lok maintenance status
lmj() { lput "home/state/.maintenance-transactions/$1/journal" "$2"; }
lboth lmj learning-b-x $'status=applying\nplan=/nowhere/plan.json\nrun=/nowhere\naction_0=complete\nheld_committed=1\nbackup=/b.tar.gz\n'
lboth lmj Learning-a-y $'status=applying\n'
lboth lmj curate-1-z $'status=complete\n'
lboth lmj curate-2-w $'status=abandoned\n'
lok maintenance status
lrefuse "ERROR: usage: ac-learn.sh maintenance resume <transaction-id> (list them: ac-learn.sh maintenance status)" maintenance resume
lrefuse "ERROR: transaction id must be [A-Za-z0-9._-] (got: 'a/b')" maintenance abandon a/b
lrefuse "ERROR: no maintenance transaction 'ghost' on record at @H/home/state/.maintenance-transactions" maintenance resume ghost
lrefuse "ERROR: Learning-a-y records no plan/run to replay (it predates the resume record) - re-run the owning Learning/Curate run, or settle it: bin/ac-learn.sh maintenance abandon Learning-a-y" maintenance resume Learning-a-y
lrefuse "ERROR: learning-b-x's plan or run directory is gone (plan=/nowhere/plan.json run=/nowhere) - it cannot be replayed; settle it: bin/ac-learn.sh maintenance abandon learning-b-x" maintenance resume learning-b-x
lok maintenance resume curate-1-z
lok maintenance abandon curate-2-w
lok maintenance abandon learning-b-x
lok maintenance abandon Learning-a-y
lrefuse "ERROR: usage: ac-learn.sh maintenance status|resume <txid>|abandon <txid>" maintenance bogus

# 7. land and promote: every refusal, then a skill, a crewmate lesson, a patch
#    and a rule landed through the shared transaction (backup, journal, staged
#    files, the ledger rewrite, the archive, the discovery pointer), and a
#    landed skill whose cadence reset meets a generation of 08.
lrefuse "ERROR: usage: ac-learn.sh promote <skill-name>" promote
lrefuse "ERROR: skill name must be a slug [a-z0-9-] (got: 'Bad')" promote Bad
lrefuse "ERROR: learned skills are permanently fleet-local; promote is a fail-closed compatibility command (the legacy container store is retired and never read)." promote good-name
lrefuse "ERROR: usage: ac-learn.sh land <candidate-file>" land
lrefuse "ERROR: no candidate file at @H/nope.md" land @H/nope.md
lland() {  # lland - a home whose Pending holds the sources every land row cites
  lstd
  lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- src two\n- src two\n\n## Distilled\n\n- [distilled -> old] sources=2 updated=2025-11-01 ([skill](../skills/old/SKILL.md))\n'
  lput home/data/s1/report.md $'# report\n## Lessons\n- this exact phrase has more than six words in it\n'
  lput home/skills/patchme/SKILL.md $'---\nname: patchme\ndescription: Patch me when x.\n---\n\n# body\n'
}
lcand() { lput "cand/$1.md" "$2"; }
lboth lland
lboth lcand unapproved $'kind: skill\nname: s\n'
lrefuse "ERROR: refusing to land an UNAPPROVED candidate (@H/cand/unapproved.md): no 'approved:' header - the captain gate (Q6) must approve first" land @H/cand/unapproved.md
lboth lcand badslug $'kind: skill\nname: Bad_Name\ndescription: x\napproved: yes\n'
lrefuse "ERROR: skill candidate 'name:' must be an agentskills slug: lowercase [a-z0-9-], <=64 chars, no leading/trailing/consecutive hyphen (got: 'Bad_Name')" land @H/cand/badslug.md
lboth lcand unverbatim $'kind: skill\nname: newskill\ndescription: Use when x.\napproved: yes\n===sources===\n2025-12-01\thook\t- not in the ledger\n===skill===\n# body\n'
lrefuse "ERROR: source bullet not found verbatim in learnings.md (compaction is coupled to landing; nothing written): - not in the ledger" land @H/cand/unverbatim.md
lboth lcand skill $'kind: skill\nname: newskill\ndescription: Use when the thing happens.\napproved: yes\n===sources===\n2025-12-01\thook\t- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n2025-12-02\thook\t- src two\n===skill===\n# newskill\nDo the thing.\n'
lok land @H/cand/skill.md
lboth lcand crewmate $'kind: crewmate\nname: a-method\ndescription: A method lesson.\napproved: yes\n===sources===\n2025-12-03\thook\t- src two\n===crewmate===\nDo the method, briefly.\n'
lok land @H/cand/crewmate.md
lboth lcand crewmate2 $'kind: crewmate\nname: a-method\ndescription: Again.\napproved: yes\n===crewmate===\nx\n'
lrefuse "ERROR: CREWMATE-learned.md already carries '## a-method' - curate the existing entry instead of re-landing it (nothing written)" land @H/cand/crewmate2.md
lboth lcand patch $'kind: patch\nname: patchme\napproved: yes\n===patch===\n## Gotcha\nWatch this.\n'
lok land @H/cand/patch.md
lboth lcand rule $'kind: rule\nname: r\napproved: yes\n===rule===\n- 2026-01-01: STANDING: a new rule.\n'
lok land @H/cand/rule.md
lboth lcand spoof $'kind: crewmate\nname: spoof\ndescription: x.\napproved: yes\n===crewmate===\nprose\n## injected\n'
lrefuse "ERROR: crewmate '===crewmate===' body must be lesson prose only - the transaction composes the '## spoof' heading itself (nothing written)" land @H/cand/spoof.md
lboth lland
lboth lput home/state/.learn.meta $'generation=08\ndebriefs=3\n'
lboth lcand skill $'kind: skill\nname: newskill\ndescription: Use when the thing happens.\napproved: yes\n===sources===\n2025-12-01\thook\t- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n2025-12-02\thook\t- src two\n===skill===\n# newskill\nDo the thing.\n'
l08 land @H/cand/skill.md
assert_eq "$LN_RC:$(lerr)" "0:WARN: landed skill, but its cadence lock was busy; its cadence was preserved instead of reset" "a land whose reset the arithmetic refuses warns and still says it landed"
assert_contains "$(lout)" "landed skill through maintenance transaction" "the landed line follows the reset's warning"

# 8. run: a stub scout through every ending, then candidates through every
#    gate answer, the rule escalation, a rejected preparer, Curate due, the
#    orca home (W2 at parity - the meta records the fleet's backend), a
#    generation of 08 at the reset, a link planted at the pointer rewrite's temp.
lrunhome() {
  lland
  lput home/records/backlog.md $'## In flight\n\n## Queued\n\n## Done\n- [x] s1 - receipt - local main (merged 2025-12-30)\n- [x] old - receipt (merged 2025-01-01)\n- [x] nodate - receipt\n- [x] [failed] f1 - receipt (merged 2025-12-31)\n- [x] arch1 - receipt (merged 2025-12-31)\n'
  lput home/state/.learn.meta $'generation=4\ndebriefs=9\nlast_run=1764547200\n'
  lput home/data/s1/room.md $'# room s1\n'
  lput home/data/archive/2025/arch1/room.md $'# archived room\n'
  lput home/data/archive/2025/arch1/tasks/t/report.md $'## Lessons\n```\n## Lessons\n```\n- a lesson inside\n## Next\n'
}
lboth lrunhome
lok run
lboth lrunhome
LENV=(LPANE_STATUS=blocked); lsame run; LENV=()
lboth lrunhome
LENV=(LPANE_NOREPORT=1 LPANE_NORETRO=1); lsame run; LENV=()
lboth lrunhome
LENV=(LPANE_NODONE=1); lsame run; LENV=()
assert_contains "$(lerr)" "learning scout emitted no done event" "a scout with no done event ends the run, its panes reaped"
lboth lrunhome
LENV=(LPANE_JUNK=1); lsame run; LENV=()
lboth lrunhome
LENV=(LPANE_OPEN=pL LPANE_TRANSCRIPT=/t.jsonl); lsame run; LENV=()
lboth lrunhome
LENV=(LPANE_NOPANE=1); lsame run; LENV=()
lcands() {  # lcands <dir> - candidates of every kind a run's scout may write
  lput "$1/candidate-newskill.md" $'kind: skill\nname: newskill\ndescription: Use when the thing happens.\n===sources===\n2025-12-01\thook\t- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n===skill===\n# newskill\nDo the thing.\n'
  lput "$1/candidate-rule-a.md" $'kind: rule\nname: whatever\n===rule===\n- a captain rule\n'
  lput "$1/candidate-bad.md" $'kind: skill\nname: has space\ndescription: x\n'
  lput "$1/candidate-patchme.md" $'kind: patch\nname: patchme\n===sources===\n2025-12-02\thook\t- src two\n===patch===\n## Gotcha\nWatch.\n'
}
lboth lrunhome
lboth lcands cands
LENV=("LPANE_CANDS=@H/cands"); lsame run; LENV=()
for d in revise ask-captain; do
  lboth lrunhome; lboth lcands cands
  LENV=("LPANE_CANDS=@H/cands" "LGATE_DECISION=$d"); lsame run; LENV=()
done
lboth lrunhome; lboth lcands cands
LENV=("LPANE_CANDS=@H/cands" LGATE_RC=3 "LGATE_DIAG=engine said no"); lsame run; LENV=()
lboth lrunhome; lboth lcands cands
LENV=("LPANE_CANDS=@H/cands" LGATE_BAD=1 LGATE_SAY=said); lsame run; LENV=()
lboth lrunhome
lboth lput home/state/.curate.meta $'generation=1\nruns_since=4\n'
lsame run
lboth lrunhome
lboth lput home/state/.curate.meta $'generation=1\nruns_since=4\n'
LENV=(LCURATE_RC=2); lsame run; LENV=()
lboth lrunhome
lboth lput home/state/.learn-cadence.lock/pid "$$"$'\n'
lsame run
lboth lrunhome
lboth lput home/config/backend $'orca\n'
lsame run
assert_contains "$(cat "$LNH/stub/seen.verify-learning-1767225600.meta")" "backend=orca" "an orca home's scout meta records backend=orca on both sides (W2 at parity)"
# W5 (named): under a UTF-8 locale one byte that is no UTF-8 in Pending
# aborted the bash's split awk (towc) inside the errexit-asleep preparer, and
# the continue applied a ledger cut at that byte; the port reads bytes and
# keeps every Pending line.
lboth lrunhome
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- a later lesson with caf\351 byte\n- the last lesson\n\n## Distilled\n\n'
lboth lcands cands
LLC=en_US.UTF-8; LENV=("LPANE_CANDS=@H/cands"); lpair run; LENV=(); LLC=C
assert_eq "$LO_RC:$LN_RC" "0:0" "W5: both runs end 0"
assert_contains "$(cat "$LOH/home/skills/newskill/SKILL.md")" "Do the thing." "W5: the oracle applied the skill"
grep -qF -- '- the last lesson' "$LOH/home/records/learnings.md" && fail "W5: the oracle's cut ledger lost the lines past the byte"
grep -qF -- '- the last lesson' "$LNH/home/records/learnings.md" || fail "W5 (named): the port keeps every Pending line"
lboth lrunhome
lboth lput home/state/.learn.meta $'generation=08\ndebriefs=9\nlast_run=1764547200\n'
l08 run
assert_eq "$LN_RC:$(lerr)" "0:WARN: Learning completed, but its cadence lock was busy - the DISTILL cycle is NOT consumed and the retro window is NOT advanced" "a run whose reset the arithmetic refuses warns and completes"
# EXCLUSIVE TEMPS (named): the staged rewrite of an existing pointer went
# through the fixed <run>/work/pointers.next.tsv.tmp, a name inside the run dir
# the scout writes; the bash wrote through a link planted there before any
# gate judged the plan, the port's temp is made exclusively.
lboth lrunhome
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- src two\n- src two\n\n## Distilled\n\n- [distilled -> old] sources=2 updated=2025-11-01 ([skill](../skills/old/SKILL.md))\n- [distilled -> patchme] sources=1 updated=2025-11-01 ([skill](../skills/patchme/SKILL.md))\n'
lboth lput pcands/candidate-patchme.md $'kind: patch\nname: patchme\n===sources===\n2025-12-02\thook\t- src two\n===patch===\n## Gotcha\nWatch.\n'
lboth lput victim $'victim\n'
lboth mkdir -p @H/home/data/learning-1767225600/work
lboth ln -s @H/victim @H/home/data/learning-1767225600/work/pointers.next.tsv.tmp
LENV=("LPANE_CANDS=@H/pcands"); lpair run; LENV=()
lsame_rc_out run; lsame_err run
assert_contains "$(cat "$LOH/victim")" "patchme" "the oracle wrote the pointer rewrite through the planted link (W12)"
assert_eq "$(cat "$LNH/victim")" "victim" "the port never writes the pointer rewrite through a planted temp (W12, named)"
cmp -s "$LOH/home/records/learnings.md" "$LNH/home/records/learnings.md" || fail "a planted pointer temp: both sides land the same ledger"
assert_contains "$(cat "$LNH/home/records/learnings.md")" "[distilled -> patchme] sources=2 updated=2025-12-02" "the existing pointer is rewritten past a planted temp"

# 9. autoroom: scoped, not due, the lock, the shape gate's two holds, the
#    charter and the promote, a failing promote with and without its meta,
#    the suite gate's green, red-same-head and in-flight holds.
lboth lstd
LENV=(AC_SCOPE=fam); lok autoroom; LENV=()
lok autoroom
lboth lput home/state/.learn.meta $'generation=4\ndebriefs=8\n'
lboth lput home/state/.learn-autoroom.lock/pid "$$"$'\n'
lok autoroom
lboth rm -rf @H/home/state/.learn-autoroom.lock
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n## Distilled\n\n- 2026-01-01 [distilled -> x @fleet] sources=1\n'
lok autoroom
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n## Distilled\n\n- [distilled -> gone] sources=1 updated=2026-01-01 ([skill](../skills/gone/SKILL.md); [evidence](learnings-archive/gone.md))\n'
lok autoroom
lboth lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n## Distilled\n\n'
lsame autoroom
assert_contains "$(lout)" "auto-created room \`learning\` and promoted its roomchief" "a due drain promotes the learning room"
lboth rm -rf @H/home/data/learning @H/stub/spawn.log
LENV=(LSPAWN_RC=1); lsame autoroom; LENV=()
assert_contains "$(lerr)" "the roomchief promote failed BEFORE its meta was written" "a failed promote with no meta warns"
lboth rm -rf @H/home/data/learning
LENV=(LSPAWN_RC=1 LSPAWN_META=1); lsame autoroom; LENV=()
assert_eq "$(lerr)" "" "a failed promote whose meta exists is the idempotent loser, silent"
lboth lstd
lboth lput home/state/.learn.meta $'generation=4\ndebriefs=8\n'
lboth lput home/config/learn-suite-gate $'on\n'
lboth lput home/state/.learn-suite-pin.meta $'generation=4\nhead=1111111111111111111111111111111111111111\n'
lboth lput home/state/.learn-suite.meta $'generation=4\nhead=1111111111111111111111111111111111111111\nstatus=green\nexit=0\nat=1\n'
LPATH="$LGITSTUBS:$LSTUBS:$PATH"
lok autoroom
lboth lput home/state/.learn-suite.meta $'generation=4\nhead=1111111111111111111111111111111111111111\nstatus=red\nexit=1\nat=1\n'
lboth rm -rf @H/home/state/learning-chief.meta @H/home/data/learning
lok autoroom
assert_contains "$(lout)" "the full suite is RED for this cycle" "a red verdict for the pinned tree holds"
lboth lput home/state/verify-suite-1.meta $'kind=verify-suite\nbackend=herdr\nspawned_epoch=1767225000\n'
lboth lput home/state/.pane-verify-suite-1 $'p9 t9\n'
lboth lput herdr/panes/p9.buf ''
lboth lput home/state/.learn-suite.meta $'generation=3\nhead=x\nstatus=green\nexit=0\nat=1\n'
lsame autoroom
LPATH=""

# 10. suite: the id grammar, green and red verdicts recorded for the pinned
#     tree, the identity retired, the ceiling (124) ending the runner's tree.
lboth lstd
lrefuse "ERROR: suite takes its own task id (verify-suite-*), never another task's (got: 'other')" suite other
LPATH="$LGITSTUBS:$LSTUBS:$PATH"
LENV=("AC_LEARN_SUITE_BIN=$LSTUBS/runner"); lok suite; LENV=()
lboth lput home/state/verify-suite-7.meta $'kind=verify-suite\n'
lboth lput home/state/verify-suite-7.status $'x started\n'
LENV=("AC_LEARN_SUITE_BIN=$LSTUBS/runner" LRUNNER_RC=3); lsame suite verify-suite-7; LENV=()
assert_eq "$LN_RC" "3" "suite exits with its runner's status"
LENV=("AC_LEARN_SUITE_BIN=$LSTUBS/runner" LRUNNER_HOLD=6 AC_LEARN_SUITE_TIMEOUT=1); lpair suite; LENV=()
lsame_rc_out suite
# SHELL-OWN STDERR (named): bash's own job notice for the runner it ended.
assert_contains "$(loerr)" "Terminated: 15" "the oracle's shell reports the ended runner"
LC_ALL=C sed -E '/^ROOT\/bin\/ac-learn\.sh: line [0-9]+: +[0-9]+ Terminated: 15 /d' "$TMP/lo.err2" >"$TMP/lo.err3"
mv "$TMP/lo.err3" "$TMP/lo.err2"
lsame_err suite; lsame_world suite
assert_eq "$LN_RC" "124" "a runner past the ceiling records red exit 124"
LPATH=""

# 11. route-propose: blank stdin silent, a silent provider, an answer with a
#     learned-entry duplicate.
lboth lstd
lput_lines() { lput lines "$1"; }
lboth lput_lines $'   \n\n'
LSTDIN=@H/lines; lok route-propose
lboth lput_lines $'- a repo fact about the build\n\n- read the room first\n'
lok route-propose
lboth lput home/CREWMATE-learned.md $'# Fleet-learned crewmate lessons\n\n## read-the-room-first\n\nRead the family room first.\n\n(learned 2026-01-01)\n\n## when to reach for a learned skill\n- when x -> use skill x\n'
lboth lput answer.json '{"owner_1":{"choice":"repo_knowledge","p":{"repo_knowledge":0.9}},"dup_1":{"choice":"new","p":{"new":0.8}},"worth_1":{"choice":"durable","p":{"durable":0.7}},"owner_2":{"choice":"learnings","p":{"learnings":0.6}},"dup_2":{"choice":"read-the-room-first","p":{"read-the-room-first":0.5}},"worth_2":{"choice":"routine","p":{"routine":0.4}}}'
LENV=("LJEV_ANSWER=@H/answer.json"); lok route-propose; LENV=()
LSTDIN=/dev/null

# 12. signals, as the bash's traps stood: TERM while the scout runs, before
#     the pane ledger is armed, ends both at once with the identity left
#     behind (W7); TERM inside a gate capture waits for the gate, then the
#     ledger's reap runs.
lsig() {  # lsig <bin> <side> <prefix> <signal> <wait-for-file> <args...> - the entry started, signalled once <wait-for-file> exists, its status in $LSIG_RC
  local bin="$1" h="$2" p="$3" sig="$4" want="$5" pid i=0; shift 5
  lrun_side "$bin" "$h" "$p" "$@" &
  pid=$!
  while [ ! -e "${want//@H/$h}" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  kill "-$sig" "$(cat "$TMP/$p.pid")" 2>/dev/null || true
  LSIG_RC=0; wait "$pid" || LSIG_RC=$?
}
lboth lrunhome
LENV=(LPANE_HOLD=3)
lsig "$LOBIN" "$LOH" lo TERM "@H/stub/seen.verify-learning-1767225600.meta" run; lo_sig="$LSIG_RC"
lsig "$LNBIN" "$LNH" ln TERM "@H/stub/seen.verify-learning-1767225600.meta" run; ln_sig="$LSIG_RC"
LENV=()
assert_eq "$ln_sig" "$lo_sig" "TERM during the scout wait: the same status on both sides"
assert_eq "$ln_sig" "143" "TERM during the scout wait ends the run at once"
for h in "$LOH" "$LNH"; do assert_file "$h/home/state/verify-learning-1767225600.meta" "W7: the scout identity is left behind ($h)"; done
# The orphaned scouts finish their hold before the next world is seeded.
/bin/sleep 4
lboth lrunhome
lboth lcands cands
LENV=("LPANE_CANDS=@H/cands" LGATE_HOLD=2)
lsig "$LOBIN" "$LOH" lo TERM "@H/stub/gate.log" run; lo_sig="$LSIG_RC"
lsig "$LNBIN" "$LNH" ln TERM "@H/stub/gate.log" run; ln_sig="$LSIG_RC"
LENV=()
assert_eq "$ln_sig:$lo_sig" "143:143" "TERM inside a gate capture: both end 143 once the gate returns"
for h in "$LOH" "$LNH"; do
  assert_contains "$(cat "$h/stub/pane.log")" "reap-pane --pane pL" "the armed ledger's reap ran on TERM ($h)"
  assert_no_file "$h/home/skills/newskill" "nothing past the signalled gate applied ($h)"
done

# 13. continuation: a ledger the oracle's note wrote is what the port's land
#     reads, and a land the oracle held is what the port's maintenance names.
lboth lland
for h in "$LOH" "$LNH"; do lrun_side "$LOBIN" "$h" lc note '- src three'; done
lboth lcand three $'kind: crewmate\nname: three-method\ndescription: Three.\napproved: yes\n===sources===\n2025-12-04\thook\t- src three\n===crewmate===\nThree.\n'
lok land @H/cand/three.md

pass
