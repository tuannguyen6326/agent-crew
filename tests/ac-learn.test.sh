#!/usr/bin/env bash
# ac-learn.test.sh - the learning-loop DISTILL trigger (Slice 2): the durable
# per-debrief counter (ac_learn_tick), the pure digest reader (ac_learn_due), the
# agent-callable `ac-learn.sh tick` CLI, and the `-- learning --` digest block.
# The counter lives at state/.learn.meta - DOT-PREFIXED so it stays OUTSIDE the
# state/*.meta task-meta namespace the fleet enumerates as crewmates (a bare
# learn.meta reads as a phantom crewmate: WATCHER-DOWN + a spurious gone: wake).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"

make_home

# --- ac_learn_tick: the durable per-debrief counter -------------------------

# Clean home carries no counter yet; the absent counter reads as 0.
assert_no_file "$AC_HOME/state/.learn.meta" "no counter before the first tick"
ac_learn_tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "first tick -> debriefs=1"
ac_learn_tick
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
# `ac_lock_acquire "$lock" 10 || return 1`, no message - while its SIBLING
# ac_learn_tick_claim (called two lines apart in ac-learn.sh cmd_tick) was
# already made loud by F19. A log reader saw the claim succeed and nothing
# more, and concluded the tick ran. Shadowing ac_lock_acquire (the same
# forced-outcome technique the concurrent-claim race test below uses) proves
# the failure without paying the real lock's 10s timeout.
lockerr="$TMP/learn-tick-lockfail.err"
if bash -c "
  set -euo pipefail
  . '$BIN/ac-lib.sh'
  . '$BIN/ac-maintenance-lib.sh'
  ac_lock_acquire() { return 1; }
  ac_learn_tick
" >/dev/null 2>"$lockerr"; then
  fail "a contended cadence lock must still make ac_learn_tick return 1 (behaviour unchanged)"
fi
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
ac_learn_reset
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
# The interleaving is FORCED, not raced for: each claimer's own `mv` is
# shadowed by a sleeping wrapper, widening exactly the window between its awk
# check and its commit, everything else held constant.
claim_slow() {
  # claim_slow <key> <mv-delay-secs> - one claim in its own process, saying
  # which way it went.
  bash -c "
    set -euo pipefail
    . '$ROOT/bin/ac-lib.sh'
    . '$ROOT/bin/ac-maintenance-lib.sh'
    mv() { sleep $2; command mv \"\$@\"; }
    if ac_learn_tick_claim '$1'; then printf 'won\n'; else printf 'skipped\n'; fi"
}
claim_slow race-fam 2 >"$TMP/claim-a" &
sleep 0.3                       # inside claimer A's widened window, before its mv
claim_slow race-fam 0 >"$TMP/claim-b" &
wait
assert_eq "$(cat "$TMP/claim-a" "$TMP/claim-b" | grep -c won)" "1" \
  "concurrent claims on ONE landing: exactly one wins the tick"
assert_eq "$(grep -c 'race-fam' "$AC_HOME/state/.learn-ticks")" "1" \
  "and the landing is stamped exactly once - no stamp lost to last-mv-wins"
rm -f "$AC_HOME/state/.learn.meta" "$AC_HOME/state/.learn-ticks"

# --- legacy-key migration: stows -> debriefs (skill rename 2026-07-18) --------
# Live fleets carry .learn.meta files keyed `stows`. The PURE reader falls back
# to the legacy key without touching the file; the WRITERS migrate on first
# touch, carrying the live count and stripping the legacy line - a fleet mid-
# cadence loses nothing.
printf 'stows=5\nlast_run=123\n' >"$AC_HOME/state/.learn.meta"
assert_eq "$(ac_learn_due)" "5 8" "the pure reader reads a legacy-keyed count"
assert_contains "$(cat "$AC_HOME/state/.learn.meta")" "stows=5" "and leaves the legacy file untouched (due never writes)"
ac_learn_tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "6" "tick migrates the live count and increments it"
case "$(cat "$AC_HOME/state/.learn.meta")" in *stows=*) fail "migration must strip the legacy stows line" ;; esac
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" last_run)" "123" "migration keeps the other keys"
printf 'stows=4\n' >"$AC_HOME/state/.learn.meta"
ac_learn_reset
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
[ -z "$pane_file" ] || printf 'pLearn tLearn\n' >"$pane_file"
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

unset AC_PANE_AGENT
rm -f "$AC_HOME/state/.learn.meta"

# --- cmd_note: the lock over the ledger read-modify-write (RC-1) -------------
#
# `note` is NOT an append - it is a whole-file READ-MODIFY-WRITE (bin/ac-learn.sh
# :726-741: awk over the entire ledger -> $ledger.tmp.$$ -> mv). Unserialized,
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
# trailing comment attached, so a real branch cannot hide behind one.
assert_eq "$(grep -v '^[[:space:]]*#' "$BIN/ac-learn.sh" | grep -c 'crewdomain\|AC_DOMAIN' || true)" "0" \
  "AC-9.4: bin/ac-learn.sh carries no crewdomain feature lines"

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
awk '/^cmd_run\(\)/{f=1} f&&/learn_rotate_pending/{found=1} f&&/^}/{exit} END{exit !found}' "$BIN/ac-learn.sh" \
  || fail "R5: cmd_run must call learn_rotate_pending before staging sources/"

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
awk '/^cmd_run\(\)/{f=1} f&&/always-loaded-staleness/{found=1} f&&/^}/{exit} END{exit !found}' "$BIN/ac-learn.sh" \
  || fail "S6: cmd_run must snapshot the staleness grading into sources/"

rm -f "$ALW"

pass
