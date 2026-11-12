#!/usr/bin/env bash
# ac-learn.test.sh - the learning-loop DISTILL trigger (Slice 2): the durable
# per-debrief counter (learnTick, src/lib-learn.ts), the pure digest reader (ac_learn_due), the
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
# caller. A string answer is printed; the status is a number answer, else 1
# for false or null and 0 for anything else.
twin() {
  local expr="$1"; shift
  (cd "$ROOT" && bun --no-env-file -e "const L = { ...await import('./src/lib.ts'), ...await import('./src/lib-learn.ts') }; const M = await import('./src/maintenance-receipt.ts'); const A = process.argv.slice(1); const v = await (async () => ($expr))(); if (typeof v === 'string') process.stdout.write(v); process.exit(typeof v === 'number' ? v : v === false || v === null ? 1 : 0);" "$@")
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

# ac-wake-drain.sh runs `ac-learn.sh autoroom` as an unconditional ride-along
# on every real drain (src/wake-drain.ts), and this fresh fixture home holds
# no live-session lock, so ac-session-start.sh never degrades to read-only
# here. Pre-claiming the autoroom lock makes `cmdAutoroom`'s own `lock(lk, 0)`
# fail instantly for every call below, before it ever reaches a real
# `ac-spawn.sh --roomchief learning` - a pane spawn make_fake_herdr never
# serves, so it would wait out the pane-readiness budget.
autoroom_lock="$AC_HOME/state/.learn-autoroom.lock"
mkdir -p "$autoroom_lock" && printf '%s\n' "$$" >"$autoroom_lock/pid"

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

assert_no_file "$AC_HOME/state/learning-chief.status" \
  "the held autoroom lock must keep the digest calls off a real roomchief spawn the fake herdr cannot serve"
ac_lock_release "$autoroom_lock"

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
# The 4096-byte budget binds reinforce too (W4, fixed): a refresh that would
# grow the file past it refuses with nothing written, while one that fits
# exactly still lands.
alw_fill() {  # alw_fill <final size of the reinforced file>
  printf '# H\n\n## old-one\n\nb\n\n(learned 2026-01-01)\n\n## pad\n\n' >"$ALW"
  local grow=$(( ${#date_today} + 13 ))
  head -c $(( $1 - grow - $(wc -c <"$ALW") - 23 )) /dev/zero | tr '\0' 'x' >>"$ALW"
  printf '\n\n(learned 2026-09-01)\n' >>"$ALW"
}
date_today="$(date -u +%F)"
alw_fill 4097
alw_before="$(cat "$ALW")"
refuses_learn "reinforce would grow CREWMATE-learned.md to 4097 bytes, past its 4096-byte always-loaded budget (nothing written)" \
  "$BIN/ac-learn.sh" reinforce old-one --evidence x
assert_eq "$(cat "$ALW")" "$alw_before" "W4: an over-budget reinforce leaves the file untouched"
assert_no_file "$ALW.lock" "W4: ... and releases its lock"
alw_fill 4096
"$BIN/ac-learn.sh" reinforce old-one --evidence x >/dev/null || fail "W4: a reinforce landing at exactly 4096 bytes fits"
assert_eq "$(wc -c <"$ALW" | tr -d ' ')" "4096" "W4: ... at exactly the budget"

# --- retire: the 4096-budget wall's named remedy is performable -------------
# RT1 proves it from reinforce's own caller (--retire, including when the
# reinforced slug's own clock is already today); RT2 proves it from a
# crewmate land's (the candidate's own `retire:` header) - each cutting and
# archiving the named stale entry in the same locked rewrite or transaction
# the new entry lands through.

# RT1: reinforce --retire validates its target, then cuts and archives the
# WHOLE named entry (heading, body, date line) in the SAME locked rewrite -
# never a silent drop.
alw_reset
printf '## drop-me\n\na superseded lesson.\n\n(learned 2025-01-01)\n' >>"$ALW"
alw_before_rt="$(cat "$ALW")"
refuses_learn "no entry '## ghost'" "$BIN/ac-learn.sh" reinforce stale-one --retire ghost --evidence x
assert_eq "$(cat "$ALW")" "$alw_before_rt" "RT1: an unknown --retire target leaves the file untouched"
refuses_learn "--retire cannot name the same slug being reinforced ('stale-one')" \
  "$BIN/ac-learn.sh" reinforce stale-one --retire stale-one --evidence x
out="$("$BIN/ac-learn.sh" reinforce stale-one --retire drop-me --evidence 'the window re-derived stale-one; drop-me is superseded')"
assert_contains "$out" "reinforced stale-one" "RT1: the reinforce half still receipts"
assert_contains "$out" "retired drop-me (archived to records/learnings-archive/drop-me.md)" \
  "RT1: ... and the retire half receipts too"
case "$(cat "$ALW")" in
  *"## drop-me"*) fail "RT1: the retired entry must leave the always-loaded file: $(cat "$ALW")" ;;
esac
grep -qxF -- "## drop-me" "$ARCHDIR/drop-me.md" || fail "RT1: the retired body must survive in its own archive, never silently lost"
assert_contains "$(cat "$ARCHDIR/drop-me.md")" "a superseded lesson." "RT1: ... with its own text intact"
assert_contains "$(printf '%s\n' "$("$BIN/ac-learn.sh" stale)" | grep 'stale-one')" "FRESH" "RT1: the reinforce half still flips the grade"

# RT1b: the wall itself - a reinforce that refuses ALONE past budget (W4
# above) fits once paired with a retire that frees enough bytes in the SAME
# call, and the no-loss destination is 'pad's own archive.
alw_fill 4097
"$BIN/ac-learn.sh" reinforce old-one --retire pad --evidence 'frees room for the refresh' >/dev/null \
  || fail "RT1b: reinforce --retire must fit once retiring 'pad' frees enough bytes"
case "$(cat "$ALW")" in
  *"## pad"*) fail "RT1b: the retired 'pad' entry must be gone: $(cat "$ALW")" ;;
esac
grep -qxF -- "## pad" "$ARCHDIR/pad.md" || fail "RT1b: pad's filler body must survive in its own archive"
grep -qxF "(learned 2026-01-01, reinforced $(date -u +%F))" "$ALW" || fail "RT1b: old-one is still reinforced"

# RT1c: --retire must still act when the reinforce half is a same-day no-op -
# the EARLY "already reinforced today" return is for a BARE reinforce only,
# never a silent way to skip a requested retire.
printf '# Fleet-learned crewmate lessons\n<!-- written only by ac-learn.sh transactions -->\n\n' >"$ALW"
printf '## today-one\n\nb\n\n(learned 2026-01-01, reinforced %s)\n\n' "$(date -u +%F)" >>"$ALW"
printf '## drop-me\n\na superseded lesson.\n\n(learned 2025-01-01)\n' >>"$ALW"
out="$("$BIN/ac-learn.sh" reinforce today-one --retire drop-me --evidence 'drop-me is superseded')"
assert_contains "$out" "already at $(date -u +%F) - unchanged" "RT1c: the reinforce half still reports its real (no) effect"
assert_contains "$out" "retired drop-me (archived to records/learnings-archive/drop-me.md)" "RT1c: ... but the retire half still ran"
case "$(cat "$ALW")" in
  *"## drop-me"*) fail "RT1c: drop-me must be gone even though today-one's clock did not move: $(cat "$ALW")" ;;
esac
grep -qxF -- "## drop-me" "$ARCHDIR/drop-me.md" || fail "RT1c: drop-me's body must still be archived"

# RT1d: --retire only ever names a real entry - never the skill-pointer
# section (which holds spaces and is not an entry, learnedSlugs' own filter).
alw_reset
alw_before_rt1d="$(cat "$ALW")"
refuses_learn "no entry '## when to reach for a learned skill'" \
  "$BIN/ac-learn.sh" reinforce stale-one --retire 'when to reach for a learned skill' --evidence x
assert_eq "$(cat "$ALW")" "$alw_before_rt1d" "RT1d: the pointer section survives an attempted retire, nothing written"

# RT2: a crewmate land's own `retire:` header closes the SAME wall from the
# OTHER caller - the candidate pairs its new entry with a named stale one,
# and the land cuts, archives and lands both in one transaction.
alw_reset
printf '## old-method\n\na superseded method.\n\n(learned 2025-01-01)\n' >>"$ALW"
mkdir -p "$AC_HOME/cand"
printf 'kind: crewmate\nname: new-method\ndescription: A replacement method.\nretire: ghost\napproved: yes\n===crewmate===\nDo the new thing instead.\n' \
  >"$AC_HOME/cand/rt2-badretire.md"
refuses_learn "crewmate candidate 'retire: ghost' names no existing '## ghost' entry" \
  "$BIN/ac-learn.sh" land "$AC_HOME/cand/rt2-badretire.md"
printf 'kind: crewmate\nname: self-loop\ndescription: x\nretire: self-loop\napproved: yes\n===crewmate===\nx\n' \
  >"$AC_HOME/cand/rt2-selfretire.md"
refuses_learn "crewmate candidate 'retire:' cannot name its own 'self-loop'" \
  "$BIN/ac-learn.sh" land "$AC_HOME/cand/rt2-selfretire.md"
printf 'kind: crewmate\nname: new-method\ndescription: A replacement method.\nretire: old-method\napproved: yes\n===crewmate===\nDo the new thing instead.\n' \
  >"$AC_HOME/cand/rt2-ok.md"
out="$("$BIN/ac-learn.sh" land "$AC_HOME/cand/rt2-ok.md")" || fail "RT2: a crewmate land pairing a retire must land: $out"
assert_contains "$out" "landed crewmate through maintenance transaction" "RT2: the land still receipts normally"
grep -qxF -- "## new-method" "$ALW" || fail "RT2: the new entry must land"
case "$(cat "$ALW")" in
  *"## old-method"*) fail "RT2: the retired entry must leave the always-loaded file: $(cat "$ALW")" ;;
esac
grep -qxF -- "## old-method" "$ARCHDIR/old-method.md" || fail "RT2: the retired body must survive in its own archive"
assert_contains "$(cat "$ARCHDIR/old-method.md")" "a superseded method." "RT2: ... with its own text intact"

# RT2c: a candidate's `retire:` header is held to the same real-entry-only
# rule as --retire - the skill-pointer section can never be named.
printf 'kind: crewmate\nname: another-method\ndescription: y\nretire: when to reach for a learned skill\napproved: yes\n===crewmate===\ny\n' \
  >"$AC_HOME/cand/rt2c-pointerretire.md"
refuses_learn "crewmate candidate 'retire: when to reach for a learned skill' names no existing '## when to reach for a learned skill' entry" \
  "$BIN/ac-learn.sh" land "$AC_HOME/cand/rt2c-pointerretire.md"
grep -qxF -- "## when to reach for a learned skill" "$ALW" || fail "RT2c: the pointer section must survive the refused land"

# RT2b: the wall itself, from the land side - a NEW entry that refuses over
# budget alone fits once its candidate pairs a `retire:` big enough to free
# the room, and the refusal it hit first names a path that now exists.
rt2b_fill() {  # rt2b_fill <filler bytes> - one '## pad' entry of that size
  printf '# Fleet-learned crewmate lessons\n<!-- written only by ac-learn.sh transactions -->\n\n## pad\n\n' >"$ALW"
  head -c "$1" /dev/zero | tr '\0' 'x' >>"$ALW"
  printf '\n\n(learned 2025-01-01)\n' >>"$ALW"
}
rt2b_fill 4000
printf 'kind: crewmate\nname: new-method\ndescription: A replacement method.\napproved: yes\n===crewmate===\nShort lesson.\n' \
  >"$AC_HOME/cand/rt2b-noretire.md"
refuses_learn "pair the new entry with a retire of one of: pad (nothing written) - a crewmate candidate's own 'retire: <slug>' header" \
  "$BIN/ac-learn.sh" land "$AC_HOME/cand/rt2b-noretire.md"
case "$(cat "$ALW")" in
  *"## new-method"*) fail "RT2b: an over-budget land must write nothing: $(cat "$ALW")" ;;
esac
rt2b_fill 4000
printf 'kind: crewmate\nname: new-method\ndescription: A replacement method.\nretire: pad\napproved: yes\n===crewmate===\nShort lesson.\n' \
  >"$AC_HOME/cand/rt2b-retire.md"
"$BIN/ac-learn.sh" land "$AC_HOME/cand/rt2b-retire.md" >/dev/null \
  || fail "RT2b: pairing the SAME land with 'retire: pad' must fit and land"
grep -qxF -- "## new-method" "$ALW" || fail "RT2b: the new entry must land once pad is retired"
case "$(cat "$ALW")" in
  *"## pad"*) fail "RT2b: pad must be gone once retired: $(cat "$ALW")" ;;
esac
grep -qxF -- "## pad" "$ARCHDIR/pad.md" || fail "RT2b: pad's filler body must survive in its own archive"

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
ledger_before="$(cksum <"$AC_HOME/records/learnings.md")"
out="$(printf '%s\n' "$lines" | "$BIN/ac-learn.sh" route-propose 2>/dev/null)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "1	owner=repo_knowledge p=0.93	dup-of=none	worth=durable p=0.9" "route-propose: a repo fact routes to repo-knowledge, new, durable"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "2	owner=learnings p=0.9	dup-of=read-the-room-first p=0.88	worth=routine p=0.75" "route-propose: a duplicate lesson names the entry it repeats and its worth"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "3	owner=none p=1	dup-of=none	worth=unclear p=0.4" "route-propose: noise routes nowhere; unclear worth is printed, never hidden"
assert_contains "$(printf '%s\n' "$out" | sed -n 4p)" "state_sha=" "route-propose: the label key closes the output"
assert_eq "$(cksum <"$AC_HOME/records/learnings.md")" "$ledger_before" "route-propose: never writes the ledger"
rm -f "$AC_HOME/config/jev"

# --- the entry end to end, one scenario per row ------------------------------
# One side root ($H): a home at $H/home rebuilt per row; a bin holding an
# ac-spawn.sh stub beside the live siblings; AC_HOME=$H/home,
# AC_PANE_AGENT, AC_GATE and AC_CURATE the leg's stubs unless a row names
# others; FAKE_HERDR and FAKE_ORCA under $H; cwd $H/cwd; stdin /dev/null;
# LC_ALL=C unless a row names en_US.UTF-8; TMPDIR $H/tmp; PATH stubs - date
# answering one instant per format (BSD date itself for an age's -j -f and an
# epoch's -r), sleep logging each call but the early-pane poll's 0.05 and
# returning at once. A row reads the run's exit status, stdout and stderr (the
# side root spelled @H, the bin root ROOT, every 64-hex digest SHA) and what it
# left under $H.
unset AC_PANE_AGENT LEARN_PANE LEARN_CREW_STATE LEARN_CREW_STATE_CAPTURE
lnroot="$TMP/learn-shim"
mkdir -p "$lnroot/bin"
cp "$BIN"/*.sh "$lnroot/bin/"
ln -s "$ROOT/src" "$lnroot/src"
ln -s "$ROOT/dashboard" "$lnroot/dashboard"
lnbin="$lnroot/bin"
cmp -s "$lnbin/ac-learn.sh" "$BIN/ac-learn.sh" || fail "the shim side runs the live shim"
H="$TMP/lside"
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
# LGATE_BAD binds the receipt to a hash no plan has; LGATE_HOLD sleeps first;
# LGATE_NOTE notes that line through $LGATE_NOTE_BIN while it judges, logging
# whether the note lock was held to gate-lock.log; LGATE_EDIT deletes that
# line from the ledger.
cat >"$LSTUBS/gate" <<'GATE'
#!/usr/bin/env bash
mode=""; run=""; subject=""; manifest=""; plan=""
printf '%s\n' "$*" >>"$STUB_DIR/gate.log"
[ -z "${LGATE_HOLD:-}" ] || /bin/sleep "$LGATE_HOLD"
if [ -n "${LGATE_NOTE:-}" ]; then
  if [ -d "$AC_HOME/state/.learn-note.lock" ]; then echo held; else echo free; fi >>"$STUB_DIR/gate-lock.log"
  "$LGATE_NOTE_BIN/ac-learn.sh" note "$LGATE_NOTE" >>"$STUB_DIR/gate-note.log" 2>&1
fi
if [ -n "${LGATE_EDIT:-}" ]; then
  grep -vxF -- "$LGATE_EDIT" "$AC_HOME/records/learnings.md" >"$STUB_DIR/edit.tmp"
  cat "$STUB_DIR/edit.tmp" >"$AC_HOME/records/learnings.md"
fi
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
# The bin's spawn stand-in, reached through STARTED_BIN.
cat >"$lnbin/ac-spawn.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/spawn.log"
[ -z "${LSPAWN_META:-}" ] || printf 'kind=roomchief\n' >"$AC_HOME/state/learning-chief.meta"
echo "spawn stub: promoted"
echo "spawn stub: stderr" >&2
exit "${LSPAWN_RC:-0}"
STUB
chmod +x "$lnbin/ac-spawn.sh"
chmod +x "$LSTUBS"/* "$LGITSTUBS/git"

lseed() { [ ! -e "$H" ] || chmod -R u+rwX "$H"; rm -rf "$H"; mkdir -p "$H/home" "$H/cwd" "$H/tmp" "$H/stub" "$H/herdr/panes" "$H/herdr/tabs" "$H/orca/terminals"; }
lstd() { lseed; mkdir -p "$H/home/records" "$H/home/state" "$H/home/data" "$H/home/config" "$H/home/projects" "$H/home/skills"; }
lput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # lput <path under the side> <bytes>
LLC=C; LENV=(); LHOME=@H/home; LPATH=""; LPLANT=""; LN_RC=0
lrun() {  # lrun <args...> - one run of the entry; @H in an argument or an LENV value is the side root; LPLANT=<path under the side> links <path>.<the entry's pid> to <side>/victim first
  local x v path a=() e
  path="$LSTUBS:$PATH"; [ -z "$LPATH" ] || path="${LPATH//@H/$H}"
  e=("LC_ALL=$LLC" "PATH=$path" "TMPDIR=$H/tmp" "STUB_DIR=$H/stub" "FAKE_HERDR=$H/herdr" "FAKE_ORCA=$H/orca"
    "AC_PANE_AGENT=$LSTUBS/pane" "AC_GATE=$LSTUBS/gate" "AC_CURATE=$LSTUBS/curate")
  [ -z "$LHOME" ] || e+=("AC_HOME=${LHOME//@H/$H}")
  for x in ${LENV[@]+"${LENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$H}"); done
  for x in "$@"; do a+=("${x//@H/$H}"); done
  LN_RC=0
  { (cd "$H/cwd" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u CDPATH -u AC_LOCK_STALE_GRACE -u EPOCHSECONDS \
    -u AC_BACKEND -u AC_PANE_AGENT -u AC_GATE -u AC_CURATE -u AC_WINDOW_FAMILY -u AC_LEARN_TIMEOUT -u AC_LEARN_START_TIMEOUT \
    -u AC_LEARN_SUITE_BIN -u AC_LEARN_SUITE_TIMEOUT -u AC_SEND_UNPROVEN "${e[@]}" \
    /bin/sh -c 'printf %s "$$" >"$0"; [ -z "$1" ] || ln -s "$2" "$1.$$"; shift 2; exec "$@"' \
    "$TMP/l.pid" "${LPLANT:+$H/$LPLANT}" "$H/victim" "$lnbin/ac-learn.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/l.raw" 2>"$TMP/l.rawerr"; } 2>/dev/null || LN_RC=$?
  lnorm "$TMP/l.raw" >"$TMP/l.out"; lnorm "$TMP/l.rawerr" >"$TMP/l.err"
}
lnorm() { LC_ALL=C sed -E -e "s#$H#@H#g" -e "s#$lnroot#ROOT#g" -e "s#$ROOT#ROOT#g" -e 's/[0-9a-f]{64}/SHA/g' "$1"; }
lout() { cat "$TMP/l.out"; }
lerr() { cat "$TMP/l.err"; }
lrefuse() {  # lrefuse <stderr> <args...> - exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  lrun "$@"
  assert_eq "$LN_RC:$(lout):$(lerr)" "1::$want" "learn refusal for '$*'"
}
lok() {  # lok <args...> - exit 0, nothing on stderr
  lrun "$@"
  assert_eq "$LN_RC:$(lerr)" "0:" "learn success for '$*'"
}
LUSAGE="ERROR: usage: ac-learn.sh tick [<landing-id>]|autoroom|suite [<task-id>]|run|note <line>...|land <candidate>|promote <name>|rotate-pending|stale|reinforce <slug> --evidence <line>|maintenance status|resume <txid>|abandon <txid>"
LNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'

# 1. the preamble: every refusal before any home read - no verb, -h and an
#    unknown verb are the one usage line; an unsupported backend name refuses
#    every verb, note and promote included (W16); extra words after the
#    word-less verbs are ignored.
lstd
lrefuse "$LUSAGE"
lrefuse "$LUSAGE" -h
lrefuse "$LUSAGE" bogus
LTMUX="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
lput home/config/backend $'tmux\n'
lrefuse "$LTMUX" note '- a lesson'
lrefuse "$LTMUX" promote some-skill
lstd
LENV=(AC_BACKEND=tmux); lrefuse "$LTMUX" tick; LENV=()
lok stale extra words
assert_eq "$(lout)" "always-loaded (CREWMATE-learned.md), stale past 30 days:
  (no file yet)" "stale ignores extra words"
lok rotate-pending extra
assert_eq "$(lout)" "" "rotate-pending ignores extra words"
assert_no_file "$H/home/records/learnings.md" "... and an absent ledger is left absent"
LNOTX="no incomplete maintenance transaction - the Learning/Curate loop is clear"
lok maintenance
assert_eq "$(lout)" "$LNOTX" "a bare maintenance is its status"

# Homeless: one refusal at the first home read, exit 1 (autoroom: exit 0).
LHOME=""
lrefuse "$LNOHOME" note '- a lesson'
lrefuse "$LNOHOME" stale
lrefuse "$LNOHOME" rotate-pending
lrefuse "$LNOHOME" maintenance status
lrefuse "$LNOHOME" reinforce s --evidence e
lrefuse "$LUSAGE" bogus
lrefuse "$LNOHOME" tick
lrun autoroom
assert_eq "$LN_RC:$(lout):$(lerr)" "0::$LNOHOME" "a homeless autoroom is one refusal, exit 0"
LHOME=@H/home

# 2. note: the frame minted on an absent ledger, insertion before the first
#    `## Distilled` with the seam blank held, every refusal before any write,
#    the lock, a link planted at the rewrite's temp.
LLEDGER="$H/home/records/learnings.md"
lstd
lok note '### 2026-01-01 (solo s1)' '- a first lesson (by: s1, first-hand)'
assert_eq "$(lout)" "appended 2 line(s) under ## Pending in @H/home/records/learnings.md" "note says what it appended"
assert_eq "$(cat "$LLEDGER")" $'# Learning Ledger\n\n## Pending\n### 2026-01-01 (solo s1)\n- a first lesson (by: s1, first-hand)' "note mints the frame on an absent ledger"
lok note '- a second lesson'
assert_eq "$(cat "$LLEDGER")" $'# Learning Ledger\n\n## Pending\n### 2026-01-01 (solo s1)\n- a first lesson (by: s1, first-hand)\n- a second lesson' "note appends at the end of the Pending body"
lstd
lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n- old\n\n\n## Distilled\n\n- [distilled -> x] sources=1 updated=2026-01-01 ([skill](../skills/x/SKILL.md))\n'
lok note '- placed above the index'
assert_eq "$(cat "$LLEDGER")" $'# Learning Ledger\n\n## Pending\n\n- old\n- placed above the index\n\n\n## Distilled\n\n- [distilled -> x] sources=1 updated=2026-01-01 ([skill](../skills/x/SKILL.md))' "note inserts above the index, the seam blanks held"
lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n- unterminated'
lok note '- after an unterminated line'
assert_eq "$(cat "$LLEDGER")" $'# Learning Ledger\n\n## Pending\n- unterminated\n- after an unterminated line' "note terminates an unterminated last line first"
lrefuse "ERROR: usage: ac-learn.sh note <line>... (each argument is appended verbatim as one line under '## Pending')" note
lrefuse "ERROR: refusing to append the section marker '## Distilled': a second marker makes learn_ledger_split read everything after it as the pointer index and drop it (nothing written)" note '- ok' '## Distilled'
lrefuse "ERROR: note takes lesson lines only and defines no flags - refusing '-x' (nothing written). A ledger line is '- <lesson>' and a heading is '### <date> (solo|family <id>)', each passed as its own argument." note -x
assert_eq "$(cat "$LLEDGER")" $'# Learning Ledger\n\n## Pending\n- unterminated\n- after an unterminated line' "the refused notes wrote nothing"
lstd
lput home/state/.learn-note.lock/pid "$$"$'\n'
lrun note '- refused under a held lock'
assert_eq "$LN_RC:$(lout)" "1:" "note under a held lock refuses"
assert_contains "$(lerr)" "ERROR: learnings ledger lock @H/home/state/.learn-note.lock could not be acquired within 30s - NOTHING was written" "note: a held lock refuses with nothing written"
assert_no_file "$LLEDGER" "... and mints no ledger"
# EXCLUSIVE TEMPS: a link planted at `<ledger>.tmp.<pid>` is never written
# through.
lstd
lput victim $'victim\n'
LPLANT=home/records/learnings.md.tmp
lok note '- through a planted link'
LPLANT=""
assert_eq "$(cat "$H/victim")" "victim" "note never writes through a planted temp"
assert_contains "$(cat "$LLEDGER")" "- through a planted link" "the ledger still takes the lesson"

# 3. tick: the key grammar under C and UTF-8, and an empty key is unkeyed.
lstd
lrefuse "ERROR: tick key must be a task/family id [a-z0-9-] (got: 'Bad')" tick Bad
LLC=en_US.UTF-8
lrefuse "ERROR: tick key must be a task/family id [a-z0-9-] (got: 'Bad')" tick Bad
LLC=C
lok tick ''
assert_eq "$(lout)" "tick: debriefs=1/8" "an empty key ticks unkeyed"
assert_no_file "$H/home/state/.learn-ticks" "... stamping no landing"

# 4. rotate-pending: a bad knob.
lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n- a lesson\n'
lput home/config/learn-pending-budget $'12k\n'
lrefuse "ERROR: config/learn-pending-budget must be a byte count (got: '12k')" rotate-pending

# 5. stale and reinforce: the discovery section skipped, scenes, the knob;
#    every reinforce refusal, a reinforced date replaced, the lock.
lcml() {
  lput home/CREWMATE-learned.md $'# Fleet-learned crewmate lessons\n\n## stale-one\n\nbody\n\n(learned 2025-10-01)\n\n## fresh-one\n\nbody\n\n(learned 2025-12-20, reinforced 2025-12-30)\n\n## no-clock\n\nbody\n\n## today-one\n\nbody\n\n(learned 2025-11-01, reinforced 2026-01-01)\n\n## when to reach for a learned skill\n- when x -> use skill x\n'
  lput home/records/scenes/alpha.md $'# alpha\nscene=alpha updated=2025-11-01T00:00:00Z\n'
  lput home/records/scenes/beta.md $'# beta\nupdated=2025-12-31T00:00:00Z extra\n'
}
lstd
lcml
lok stale
assert_contains "$(lout)" "  -- 4 entries, 1 stale --" "stale grades every entry, the discovery section aside"
case "$(lout)" in *"when to reach"*) fail "the discovery section is no entry" ;; esac
assert_contains "$(lout | grep '^  alpha ')" "STALE (merge or update it - ac-scene.sh)" "a scene past the window is STALE"
assert_contains "$(lout | grep '^  beta ')" "FRESH" "a scene inside the window is FRESH"
lput home/config/learn-stale-days $'30d\n'
lrefuse "ERROR: config/learn-stale-days must be a day count (got: '30d')" stale
lstd
lcml
lrefuse "ERROR: --evidence needs a value" reinforce stale-one --evidence
lrefuse "ERROR: unknown flag: --nope" reinforce stale-one --nope
lrefuse "ERROR: reinforce takes ONE slug (got 'a' and 'b')" reinforce a b --evidence e
lrefuse "ERROR: usage: ac-learn.sh reinforce <slug> --evidence '<what this window proved>'" reinforce --evidence e
lok reinforce fresh-one --evidence 'replaces the reinforced date'
assert_eq "$(lout)" "reinforced fresh-one (clock -> 2026-01-01) on evidence: replaces the reinforced date
post the evidence to the owning room/report - the file deliberately does not store it" "reinforce says what it refreshed"
assert_contains "$(cat "$H/home/CREWMATE-learned.md")" $'## fresh-one\n\nbody\n\n(learned 2025-12-20, reinforced 2026-01-01)\n' "a reinforced date is replaced, the learned date kept"
lcml
lput home/CREWMATE-learned.md.lock/pid "$$"$'\n'
lrun reinforce stale-one --evidence e
assert_eq "$LN_RC:$(lout):$(lerr)" "1::ERROR: CREWMATE-learned lock @H/home/CREWMATE-learned.md.lock could not be acquired within 30s - nothing written" "reinforce under a held lock refuses"
assert_contains "$(cat "$H/home/CREWMATE-learned.md")" $'## stale-one\n\nbody\n\n(learned 2025-10-01)\n' "... with nothing written"

# 6. maintenance: status clean and held (two journals, byte order), resume's
#    and abandon's refusals and settles.
lstd
lok maintenance status
assert_eq "$(lout)" "$LNOTX" "a clean status"
lok maintenance ''
assert_eq "$(lout)" "$LNOTX" "an empty subverb is status"
lmj() { lput "home/state/.maintenance-transactions/$1/journal" "$2"; }
lmj learning-b-x $'status=applying\nplan=/nowhere/plan.json\nrun=/nowhere\naction_0=complete\nheld_committed=1\nbackup=/b.tar.gz\n'
lmj Learning-a-y $'status=applying\n'
lmj curate-1-z $'status=complete\n'
lmj curate-2-w $'status=abandoned\n'
lok maintenance status
assert_eq "$(lout)" "INCOMPLETE maintenance transaction(s) - every other Learning/Curate transaction refuses until settled:
  Learning-a-y status=applying committed=0 plan=-
    resume: bin/ac-learn.sh maintenance resume Learning-a-y
    drop:   bin/ac-learn.sh maintenance abandon Learning-a-y
  learning-b-x status=applying committed=1 plan=/nowhere/plan.json
    resume: bin/ac-learn.sh maintenance resume learning-b-x
    drop:   bin/ac-learn.sh maintenance abandon learning-b-x" "status names each unsettled transaction, in byte order"
lrefuse "ERROR: usage: ac-learn.sh maintenance resume <transaction-id> (list them: ac-learn.sh maintenance status)" maintenance resume
lrefuse "ERROR: transaction id must be [A-Za-z0-9._-] (got: 'a/b')" maintenance abandon a/b
lrefuse "ERROR: no maintenance transaction 'ghost' on record at @H/home/state/.maintenance-transactions" maintenance resume ghost
lrefuse "ERROR: Learning-a-y records no plan/run to replay (it predates the resume record) - re-run the owning Learning/Curate run, or settle it: bin/ac-learn.sh maintenance abandon Learning-a-y" maintenance resume Learning-a-y
lrefuse "ERROR: learning-b-x's plan or run directory is gone (plan=/nowhere/plan.json run=/nowhere) - it cannot be replayed; settle it: bin/ac-learn.sh maintenance abandon learning-b-x" maintenance resume learning-b-x
lok maintenance resume curate-1-z
assert_eq "$(lout)" "curate-1-z already reached complete - nothing to settle" "resume of a complete transaction settles nothing"
lok maintenance abandon curate-2-w
assert_eq "$(lout)" "curate-2-w was already abandoned - it blocks nothing" "abandon of an abandoned transaction"
lok maintenance abandon learning-b-x
assert_eq "$(lout)" "abandoned learning-b-x - it no longer blocks the loop.
NOTHING was rolled back: 1 action(s) of this plan are still committed to disk.
The pre-mutation backup of records/ + skills/ is at /b.tar.gz" "abandon says what is still committed and where the backup is"
assert_contains "$(cat "$H/home/state/.maintenance-transactions/learning-b-x/journal")" $'status=abandoned\nabandoned_at=1767225600' "abandon settles the journal"
lok maintenance abandon Learning-a-y
assert_eq "$(lout)" "abandoned Learning-a-y - it no longer blocks the loop.
NOTHING was rolled back: an unrecorded number of action(s) of this plan are still committed to disk." "abandon of a journal recording no actions"
lok maintenance status
assert_eq "$(lout)" "$LNOTX" "every transaction settled"
lrefuse "ERROR: usage: ac-learn.sh maintenance status|resume <txid>|abandon <txid>" maintenance bogus

# 7. land and promote: the refusals no other suite names.
lrefuse "ERROR: usage: ac-learn.sh promote <skill-name>" promote
lrefuse "ERROR: skill name must be a slug [a-z0-9-] (got: 'Bad')" promote Bad
lrefuse "ERROR: usage: ac-learn.sh land <candidate-file>" land
lrefuse "ERROR: no candidate file at @H/nope.md" land @H/nope.md
lland() {  # lland - a home whose Pending holds the sources every land row cites
  lstd
  lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- src two\n- src two\n\n## Distilled\n\n- [distilled -> old] sources=2 updated=2025-11-01 ([skill](../skills/old/SKILL.md))\n'
  lput home/data/s1/report.md $'# report\n## Lessons\n- this exact phrase has more than six words in it\n'
  lput home/skills/patchme/SKILL.md $'---\nname: patchme\ndescription: Patch me when x.\n---\n\n# body\n'
}
lland
lput cand/badslug.md $'kind: skill\nname: Bad_Name\ndescription: x\napproved: yes\n'
lrefuse "ERROR: skill candidate 'name:' must be an agentskills slug: lowercase [a-z0-9-], <=64 chars, no leading/trailing/consecutive hyphen (got: 'Bad_Name')" land @H/cand/badslug.md
assert_no_file "$H/home/skills/Bad_Name" "a refused slug writes no skill"

# 8. run: the orca home (the meta records the fleet's backend), bytes under
#    UTF-8, a link planted at the pointer rewrite's temp, two candidates on one
#    name, a note or an edit while the gate judges.
lrunhome() {
  lland
  lput home/records/backlog.md $'## In flight\n\n## Queued\n\n## Done\n- [x] s1 - receipt - local main (merged 2025-12-30)\n- [x] old - receipt (merged 2025-01-01)\n- [x] nodate - receipt\n- [x] [failed] f1 - receipt (merged 2025-12-31)\n- [x] arch1 - receipt (merged 2025-12-31)\n'
  lput home/state/.learn.meta $'generation=4\ndebriefs=9\nlast_run=1764547200\n'
  lput home/data/s1/room.md $'# room s1\n'
  lput home/data/archive/2025/arch1/room.md $'# archived room\n'
  lput home/data/archive/2025/arch1/tasks/t/report.md $'## Lessons\n```\n## Lessons\n```\n- a lesson inside\n## Next\n'
}
lcands() {  # lcands <dir> - candidates of every kind a run's scout may write
  lput "$1/candidate-newskill.md" $'kind: skill\nname: newskill\ndescription: Use when the thing happens.\ntrigger: Use when the thing happens\n===sources===\n2025-12-01\thook\t- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n===skill===\n# newskill\nDo the thing.\n'
  lput "$1/candidate-rule-a.md" $'kind: rule\nname: whatever\n===rule===\n- a captain rule\n'
  lput "$1/candidate-bad.md" $'kind: skill\nname: has space\ndescription: x\n'
  lput "$1/candidate-patchme.md" $'kind: patch\nname: patchme\n===sources===\n2025-12-02\thook\t- src two\n===patch===\n## Gotcha\nWatch.\n'
}
lrunhome
lput home/config/backend $'orca\n'
lok run
assert_contains "$(cat "$H/stub/seen.verify-learning-1767225600.meta")" "backend=orca" "an orca home's scout meta records backend=orca"
# W5 BYTES: under a UTF-8 locale a byte that is no UTF-8 in Pending is read as
# a byte, and every Pending line is kept.
lrunhome
lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- a later lesson with caf\351 byte\n- the last lesson\n\n## Distilled\n\n'
lcands cands
LLC=en_US.UTF-8; LENV=("LPANE_CANDS=@H/cands"); lok run; LENV=(); LLC=C
assert_contains "$(lout)" "auto-applied: newskill" "W5: the skill applies"
assert_contains "$(cat "$H/home/skills/newskill/SKILL.md")" "Do the thing." "W5: ... its body landed"
grep -qF -- '- the last lesson' "$LLEDGER" || fail "W5: every Pending line is kept"
LC_ALL=C grep -qF -- $'- a later lesson with caf\351 byte' "$LLEDGER" || fail "W5: ... the line holding the byte too"
# EXCLUSIVE TEMPS: the staged rewrite of an existing pointer is made through a
# temp in the run dir the scout writes, before any gate judges the plan; a link
# planted at its name is never written through.
lrunhome
lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- src two\n- src two\n\n## Distilled\n\n- [distilled -> old] sources=2 updated=2025-11-01 ([skill](../skills/old/SKILL.md))\n- [distilled -> patchme] sources=1 updated=2025-11-01 ([skill](../skills/patchme/SKILL.md))\n'
lput pcands/candidate-patchme.md $'kind: patch\nname: patchme\n===sources===\n2025-12-02\thook\t- src two\n===patch===\n## Gotcha\nWatch.\n'
lput victim $'victim\n'
mkdir -p "$H/home/data/learning-1767225600/work"
ln -s "$H/victim" "$H/home/data/learning-1767225600/work/pointers.next.tsv.tmp"
LENV=("LPANE_CANDS=@H/pcands"); lok run; LENV=()
assert_contains "$(lout)" "auto-applied: patchme" "the patch applies past a planted pointer temp"
assert_eq "$(cat "$H/victim")" "victim" "the pointer rewrite never writes through a planted temp"
assert_contains "$(cat "$LLEDGER")" "[distilled -> patchme] sources=2 updated=2025-12-02" "the existing pointer is rewritten past a planted temp"
# TWO CANDIDATES ON ONE NAME: the later claimant is keyed patchme.2, with its
# own gates/ dir, plan, staged copy and transaction.
lpatch2() {
  lrunhome
  lput pcands/candidate-patchme-a.md $'kind: patch\nname: patchme\n===sources===\n2025-12-01\thook\t- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n===patch===\n## First\nOne.\n'
  lput pcands/candidate-patchme-b.md $'kind: patch\nname: patchme\n===sources===\n2025-12-02\thook\t- src two\n===patch===\n## Second\nTwo.\n'
}
lpatch2
LENV=("LPANE_CANDS=@H/pcands"); lok run; LENV=()
assert_contains "$(lout)" $'auto-applied: patchme\n  auto-applied: patchme.2' "the second patch applies under its own subject"
for s in patchme patchme.2; do
  assert_file "$H/home/data/learning-1767225600/gates/$s/decision.md" "the run keeps the receipt of $s"
  assert_file "$H/home/data/learning-1767225600/plans/$s.json" "the run keeps the plan of $s"
  assert_contains "$(cat "$H/home/state/.maintenance-transactions/learning-1767225600-$s/journal")" "status=complete" "the transaction of $s completes"
done
assert_contains "$(cat "$H/home/skills/patchme/SKILL.md")" $'## First\nOne.\n\n## Second\nTwo.' "both patches land on the skill, in byte order"
assert_contains "$(cat "$H/home/state/.learn.meta")" "last_run=1767225600" "the settled run advances the retro window"
lpatch2
LENV=("LPANE_CANDS=@H/pcands" LGATE_DECISION=revise); lok run; LENV=()
assert_contains "$(lout)" "revise: patchme.2" "revise on both: the run judges the second candidate as its own subject"
for s in patchme patchme.2; do
  assert_contains "$(cat "$H/home/data/learning-1767225600/gates/$s/decision.md")" 'decision: "revise"' "revise on both: the run keeps the receipt of $s"
done
# W3 ONE LOCK ORDER: no lock is held across the gate; lines a note added while
# the gate judged a ledger plan are lifted out for the hash-bound apply and put
# back verbatim. Any other ledger change refuses the plan before its first
# action.
lnotehome() {
  lrunhome
  lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n### 2025-12-01 (solo s1)\n- src one (by: s1, first-hand) "this exact phrase has more than six words in it"\n- src two\n- an unrelated lesson\n\n## Distilled\n\n- [distilled -> old] sources=2 updated=2025-11-01 ([skill](../skills/old/SKILL.md))\n'
  lput pcands/candidate-patchme.md $'kind: patch\nname: patchme\n===sources===\n2025-12-02\thook\t- src two\n===patch===\n## Gotcha\nWatch.\n'
}
lnoted='- a lesson noted while the gate judged'
lrun3="data/learning-1767225600"
ltxn3="state/.maintenance-transactions/learning-1767225600-patchme/journal"
lnotehome
LENV=("LPANE_CANDS=@H/pcands" "LGATE_NOTE=$lnoted" "LGATE_NOTE_BIN=$BIN"); lrun run; LENV=()
assert_eq "$(cat "$H/stub/gate-lock.log")" "free" "W3: no note lock is held while the gate judges"
assert_eq "$LN_RC:$(lerr)" "0:" "W3: the run applies with the note kept, nothing warned"
assert_contains "$(lout)" "auto-applied: patchme" "W3: the patch applies past the note"
assert_contains "$(cat "$H/home/$ltxn3")" "status=complete" "W3: the transaction completes"
assert_contains "$(cat "$H/home/state/.learn.meta")" "last_run=1767225600" "W3: the settled run advances the retro window"
assert_eq "$(cat "$H/home/$lrun3/work/patchme.notes-replayed")" "$lnoted" "W3: the lifted lines are kept beside the run"
mkdir -p "$TMP/lw3/records" "$TMP/lw3/state"
cp "$H/home/$lrun3/staged/patchme/records/learnings.md" "$TMP/lw3/records/learnings.md"
env -u AC_SOLO AC_HOME="$TMP/lw3" "$BIN/ac-learn.sh" note "$lnoted" >/dev/null
cmp -s "$TMP/lw3/records/learnings.md" "$LLEDGER" \
  || fail "W3: the ledger is the staged rewrite with the note inserted: $(diff -a "$TMP/lw3/records/learnings.md" "$LLEDGER" | head -n 8)"
lnotehome
LENV=("LPANE_CANDS=@H/pcands" "LGATE_EDIT=- an unrelated lesson"); lrun run; LENV=()
assert_eq "$LN_RC" "0" "W3: a refused plan still ends the run 0"
assert_contains "$(lerr)" "not by a note alone - the plan was refused before its first action" "W3: a non-note ledger change refuses the plan"
assert_eq "$(cat "$H/home/skills/patchme/SKILL.md")" $'---\nname: patchme\ndescription: Patch me when x.\n---\n\n# body' "W3: the refused plan committed nothing"
assert_no_file "$H/home/state/.maintenance-transactions/learning-1767225600-patchme" "W3: the refused plan was never claimed"
assert_contains "$(cat "$H/home/state/.learn.meta")" "last_run=1764547200" "W3: the refused plan withholds the cadence"
# STAGING UNDER THE NOTE LOCK: a note landing between the preparer's read of
# the ledger and its hash for the rewrite waits for the lock, so the apply
# never deletes the noted line. The jq that writes the archive action - after
# that read, before that hash - notes the line: in the foreground when the
# note lock is free, else in the background, which waits.
mkdir -p "$TMP/ljq"
cat >"$TMP/ljq/jq" <<STUB
#!/bin/sh
case " \$* " in
  *" append-archive "*)
    if [ ! -e "\$STUB_DIR/jq-noted" ]; then
      : >"\$STUB_DIR/jq-noted"
      if [ -d "\$AC_HOME/state/.learn-note.lock" ]; then
        echo held >"\$STUB_DIR/jq-lock.log"
        ( PATH="$PATH" "$BIN/ac-learn.sh" note "\$LJQ_NOTE" >"\$STUB_DIR/jq-note.log" 2>&1; : >"\$STUB_DIR/jq-note.done" ) </dev/null >/dev/null 2>&1 &
      else
        echo free >"\$STUB_DIR/jq-lock.log"
        PATH="$PATH" "$BIN/ac-learn.sh" note "\$LJQ_NOTE" </dev/null >"\$STUB_DIR/jq-note.log" 2>&1
        : >"\$STUB_DIR/jq-note.done"
      fi
    fi ;;
esac
exec "$(command -v jq)" "\$@"
STUB
chmod +x "$TMP/ljq/jq"
lnotehome
LPATH="$TMP/ljq:$LSTUBS:$PATH"
LENV=("LPANE_CANDS=@H/pcands" "LJQ_NOTE=$lnoted"); lrun run; LENV=()
LPATH=""
i=0; while [ ! -e "$H/stub/jq-note.done" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.1; i=$((i + 1)); done
assert_eq "$(cat "$H/stub/jq-lock.log")" "held" "staging: the ledger is staged under the note lock"
assert_eq "$LN_RC:$(sed -n '/^## Distilled$/q;p' "$LLEDGER" | grep -cxF -- "$lnoted")" "0:1" "staging: the noted line lands once under Pending"
assert_contains "$(cat "$H/home/$ltxn3")" "status=complete" "staging: the transaction completes"

# 9. autoroom: a failing promote with and without its meta, and a failing
#    `workspace list` walked past by the suite launch.
lstd
lput home/state/.learn.meta $'generation=4\ndebriefs=8\n'
lput home/records/learnings.md $'# Learning Ledger\n\n## Pending\n\n## Distilled\n\n'
LENV=(LSPAWN_RC=1); lrun autoroom; LENV=()
assert_eq "$LN_RC" "0" "a failed promote never fails autoroom"
assert_contains "$(lerr)" "WARN: learning DUE (8/8) but the roomchief promote failed BEFORE its meta was written, so the next checkpoint retries" "a failed promote with no meta warns"
rm -rf "$H/home/data/learning"
LENV=(LSPAWN_RC=1 LSPAWN_META=1); lrun autoroom; LENV=()
assert_eq "$LN_RC:$(lerr)" "0:" "a failed promote whose meta exists is the idempotent loser, silent"
lstd
lput home/state/.learn.meta $'generation=4\ndebriefs=8\n'
lput home/config/learn-suite-gate $'on\n'
mkdir -p "$TMP/lwsfail"
printf '#!/bin/sh\n[ "$1 $2" != "workspace list" ] || exit 1\nexec "%s/stubbin/herdr" "$@"\n' "$TMP" >"$TMP/lwsfail/herdr"
chmod +x "$TMP/lwsfail/herdr"
LPATH="$TMP/lwsfail:$LGITSTUBS:$LSTUBS:$PATH"
lok autoroom
assert_contains "$(lout)" "HELD: started the full-suite run verify-suite-" "a failing workspace list still starts the suite run"
LPATH=""

# 10. signals: TERM while the scout runs, before the pane ledger is armed,
#     ends the run at once; TERM inside a gate capture waits for the gate,
#     then the ledger's reap runs.
lsig() {  # lsig <signal> <wait-for-file> <args...> - the entry started, signalled once <wait-for-file> exists, its status in $LSIG_RC
  local sig="$1" want="$2" pid i=0; shift 2
  rm -f "$TMP/l.pid"
  ( lrun "$@"; exit "$LN_RC" ) &
  pid=$!
  while [ ! -e "${want//@H/$H}" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  kill "-$sig" "$(cat "$TMP/l.pid")" 2>/dev/null || true
  LSIG_RC=0; wait "$pid" || LSIG_RC=$?
}
lrunhome
LENV=(LPANE_HOLD=3)
lsig TERM "@H/stub/seen.verify-learning-1767225600.meta" run
LENV=()
assert_eq "$LSIG_RC" "143" "TERM during the scout wait ends the run at once"
# The orphaned scout finishes its hold before the next world is seeded.
/bin/sleep 4
lrunhome
lcands cands
LENV=("LPANE_CANDS=@H/cands" LGATE_HOLD=2)
lsig TERM "@H/stub/gate.log" run
LENV=()
assert_eq "$LSIG_RC" "143" "TERM inside a gate capture ends 143 once the gate returns"
assert_contains "$(cat "$H/stub/pane.log")" "reap-pane --pane pL" "the armed ledger's reap ran on TERM"
assert_no_file "$H/home/skills/newskill" "nothing past the signalled gate applied"

pass
