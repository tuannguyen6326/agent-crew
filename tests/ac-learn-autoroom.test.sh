#!/usr/bin/env bash
# ac-learn-autoroom.test.sh - the DISTILL auto-trigger: `ac-learn.sh autoroom`
# and its ride-along on the fleet drain (its SITE).
#
# The trigger is LEVEL-triggered - DUE, and no learning roomchief meta - so
# every assertion here is about durable state a fresh process re-reads, never
# about a wake or a crossing edge. That is the point of the design: an edge is
# lost if nobody acts on it, and a counter already carried past its threshold
# never crosses again.
#
# Its own file, matching how ac-spawn.sh's tests are already split by concern:
# the cap-ACCOUNTING half of the same change lives in ac-room-parallel-cap.test.sh.
#
# The fake herdr + a config/launch-fake template are armed because the FIRING
# path runs a real `ac-spawn.sh --roomchief` to completion - with a real herdr on
# PATH that would open a live harness window on the OPERATOR's server.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home

export AC_SPAWN_SETTLE=0
# Every pane here clears the composer-ready observation (bin/ac-spawn.sh
# kickoff_wait_input_ready) immediately - this suite is not testing that gate
# (tests/ac-spawn-kickoff-ready.test.sh owns it), it just needs the real
# --roomchief spawn the firing path runs to complete without a boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5
printf 'echo roomchief __ID__\n' >"$AC_HOME/config/launch-fake"
printf 'fake\n' >"$AC_HOME/config/crew-harness"

meta="$AC_HOME/state/learning-chief.meta"
room="$AC_HOME/data/learning/room.md"

due() { printf 'debriefs=%s\n' "$1" >"$AC_HOME/state/.learn.meta"; }
promotes() { grep -c 'PROMOTED:' "$room" 2>/dev/null || true; }
reset_family() { rm -f "$AC_HOME/state"/*-chief.meta; rm -rf "${AC_HOME:?}/data/learning"; }

# THE FULL-SUITE GATE: a promote also needs a GREEN
# tests/run-suite.sh verdict recorded for THIS cadence generation and THIS tree,
# so every case that expects a promote seeds one. Its own section near the
# bottom takes the record away again. generation=0 because `due` writes a
# counter file with no generation key, which ac_learn_generation reads as 0.
# The gate is FLEET-OPT-IN: config/learn-suite-gate=on.
# This suite exercises the gated behavior, so the fixture pins it on; the
# default-off contract has its own case below.
mkdir -p "$AC_HOME/config"
printf 'on\n' >"$AC_HOME/config/learn-suite-gate"
suite_rec="$AC_HOME/state/.learn-suite.meta"
suite_head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'no-head')"
suite_tasks() {
  # every suite-task meta that exists right now, one per line (none: no output)
  local m
  for m in "$AC_HOME"/state/verify-suite-*.meta; do
    [ -e "$m" ] && printf '%s\n' "$m"
  done
  return 0
}
suite_task_clear() { rm -f "$AC_HOME"/state/verify-suite-*.meta "$AC_HOME"/state/.pane-verify-suite-*; }
green_suite() {
  printf 'generation=0\nhead=%s\nstatus=green\nexit=0\nat=%s\n' \
    "$suite_head" "$(date +%s)" >"$suite_rec"
}

# -- FLEET OPT-IN: knob absent => the gate never holds -------------------------
# No config/learn-suite-gate and NO suite verdict at all: a DUE autoroom fires
# anyway - another fleet's DISTILL must never wait on this repo's suite.
rm -f "$AC_HOME/config/learn-suite-gate" "$suite_rec"
due 9
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "default-off: a due autoroom must exit 0: $out"
assert_file "$meta" "default-off: the roomchief meta exists despite no suite verdict"
assert_file "$room" "default-off: the room exists despite no suite verdict"
suite_task_clear
reset_family
printf 'on\n' >"$AC_HOME/config/learn-suite-gate"
green_suite

# -- not DUE: a silent no-op ---------------------------------------------------
due 2
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a not-due autoroom must exit 0: $out"
assert_eq "$out" "" "a not-due autoroom prints nothing"
assert_no_file "$meta" "a not-due autoroom creates no roomchief meta"
assert_no_file "$room" "a not-due autoroom creates no room"

# -- DUE: the room and its chief appear (AC-1, AC-7) ---------------------------
due 9
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a due autoroom must exit 0: $out"
assert_contains "$out" "learning DUE (9/8)" "the firing run names what it created"
assert_file "$meta" "AC-1: the learning roomchief meta exists"
assert_eq "$(awk -F= '$1=="kind"{print $2}' "$meta")" "roomchief" "AC-1: kind=roomchief"
assert_eq "$(awk -F= '$1=="initiated_by"{print $2}' "$meta")" "system" "AC-1: the origin is system - never a borrowed captain"
assert_file "$room" "AC-1: the family room exists"
r="$(cat "$room")"
assert_contains "$r" "PROMOTED:" "AC-1: the room carries the PROMOTED post"
assert_contains "$r" "DECIDED:" "AC-7: the room carries the promote receipt"
assert_contains "$r" "standing order:" "AC-7: the receipt names a STANDING order, not a request made now"
assert_contains "$r" "CAP-EXEMPT" "AC-7: the receipt cites the captain rule it carries out"
assert_contains "$r" "does NOT count toward room-parallel" "AC-7: the receipt states it consumes no slot"
# `--roomchief` takes no brief - the room IS the brief - and the roomchief prompt
# is generic, so the charter is the ONLY thing telling an auto-created chief what
# to do. Self-contained means: the command, independent scout/gate authority,
# automatic transaction boundary, and hand-back.
assert_contains "$r" "bin/ac-learn.sh run" "the charter names the command to execute"
assert_contains "$r" "maintenance-gate" "AC-8: the charter names the automatic hash-bound authority"
assert_contains "$r" "Do not add \`approved:\`" "AC-8: the charter refuses legacy manual authentication"
assert_contains "$r" "retro.md" "AC-9: the charter names the artifacts the chief must never author itself"
assert_contains "$r" "bin/ac-room.sh handback learning" "the charter names the hand-back"

# -- AC-2: still DUE, two more calls change nothing ----------------------------
n_before="$(promotes)"
for _ in 1 2; do
  out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "an already-fired autoroom must exit 0: $out"
  assert_eq "$out" "" "an already-fired autoroom is silent"
done
assert_eq "$(promotes)" "$n_before" "AC-2: no second PROMOTED post"
assert_eq "$(find "$AC_HOME/state" -name '*-chief.meta' | wc -l | tr -d ' ')" "1" "AC-2: exactly one roomchief meta"

# -- E2: two checkpoints racing -> exactly ONE room, and the loser is SILENT ---
# What GUARDS the pre-meta race and what THIS case OBSERVES are two different
# things; keep them apart.
#
# The guard is the spawn-owned ATOMIC CLAIM, not ac-spawn.sh's duplicate-meta
# refusal: that refusal is a plain [ -e ] test, and the whole backend half of a
# spawn - reap_orphan_window included - runs before the meta exists, so two
# callers can both pass it. spawn_meta_claim_acquire is what serializes that
# window.
#
# This case does NOT prove that, and must not be read as proving it. Both racers
# are LIVE here, so A holds .learn-autoroom.lock for the whole overlap and B
# exits at its own timeout-0 acquire - measured: B bails at the caller lock and
# never invokes ac-spawn.sh at all. What E2 pins is the CALLER-LOCK loser: one
# room, one charter, and silence. The SIGKILL half - where A is dead, its lock
# is reclaimed as stale with no grace, and the claim is the only thing left
# between B and A's not-yet-addressable window - is what exercises the claim,
# and it is tracked as its own backlog row.
#
# The overlap is SYNCHRONIZED on an OBSERVABLE point, not a sleep guess. Racer A
# takes the lock and posts the charter UNDER it, then parks in ac-spawn's
# pre-meta settle. The charter file appearing is proof A is inside the critical
# section holding the lock and has not yet written its meta - so racer B is
# launched to contend at a moment A demonstrably owns the lock, and B's
# timeout-0 acquire makes the loser bail at once.
reset_family
due 9
( AC_SPAWN_SETTLE=4 "$BIN/ac-learn.sh" autoroom >"$TMP/race-a.out" 2>&1; printf '%s\n' "$?" >"$TMP/race-a.rc" ) &
race_pid=$!
waited=0
until [ -f "$room" ] || [ "$waited" -ge 200 ]; do sleep 0.05; waited=$((waited + 1)); done
[ -f "$room" ] || fail "E2 barrier: racer A never reached the under-lock charter post"
assert_no_file "$meta" "E2 barrier: A is pre-meta (parked in ac-spawn's settle) when B contends"
set +e
race_b_out="$(AC_SPAWN_SETTLE=0 "$BIN/ac-learn.sh" autoroom 2>&1)"
race_b_rc=$?
set -e
wait "$race_pid"
assert_eq "$(cat "$TMP/race-a.rc")" "0" "E2: racer A exits 0"
assert_eq "$race_b_rc" "0" "E2: racer B exits 0 - a race is normal operation, not a fault"
assert_eq "$race_b_out" "" "E2: the loser is SILENT - not a refusal printed into the drain"
assert_contains "$(cat "$TMP/race-a.out")" "learning DUE (9/8)" "E2: the winner created the room"
assert_eq "$(find "$AC_HOME/state" -name '*-chief.meta' | wc -l | tr -d ' ')" "1" "E2: exactly one roomchief meta survives the race"
assert_eq "$(promotes)" "1" "E2: exactly one PROMOTED post"
assert_no_file "$AC_HOME/state/.learn-autoroom.lock" "the lock is released once the winner is done"
assert_no_file "$AC_HOME/state/.meta-claims/learning-chief" "the spawn-owned atomic claim is released once the winner is addressable"

if ! grep -q 'spawn_meta_claim_acquire' "$BIN/ac-spawn.sh"; then
  fail "ac-spawn.sh does not own the atomic pre-meta claim"
fi

# -- E2-SIGKILL: A dies INSIDE its pre-meta window and B contends for it -------
# The half E2 above cannot reach, and what makes the name check at :124 above
# behavioral. Racer A is SIGKILLed while its ac-spawn.sh child is parked
# pre-meta; that child SURVIVES; B starts at that instant, finds A's caller lock
# held by a DEAD pid, reclaims it with no grace (ac_lock_stale), re-reads DUE
# and still-no-meta, and launches a SECOND spawn into A's not-yet-addressable
# window. The atomic claim is the only thing left between B and that window:
# its owner pid is the ac-spawn.sh shell itself, a DESCENDANT of the killed
# caller and therefore still alive, so B blocks instead of reclaiming and then
# dies on the duplicate-meta check INSIDE the claim. Remove the claim and the
# harm reproduces - PROMOTED=2, DECIDED=2, the winner's window reaped out from
# under its own meta, B printing "reaping the orphan window".
#
# BOTH observations are INDEPENDENT of the guard under test, or a tree with no
# claim would red on the observation instead of on the race:
#   the barrier's child id is a walk DOWN the process table from A - never
#     state/.meta-claims/ - so it answers identically on a tree that has no
#     claim at all;
#   B's arrival is a pass-through `head` shim keyed on a read of config/model.
#     ac_config_read is `head -n1 <file>` (ac-lib.sh) and `ac_config_read model`
#     is executed by exactly ONE site on the spawn path (ac-spawn.sh:509, which
#     resolves the fleet defaults before any window or lease), so the record
#     means "racer B's ac-spawn.sh RAN" and nothing weaker. That is the false
#     green this case exists to exclude: if B bails at the caller lock it never
#     invokes ac-spawn.sh, the race never happens, and EVERY harm assertion
#     below passes. Same shape as F2's PATH shim, keyed on a different path.
#
# HOST SAFETY, each measured rather than argued
# (data/e2-sigkill-regression-test/spec/probes, plus the implement-stage runs):
#   - racer A is signalled ONLY through the job NUMBER captured at its launch.
#     A bare pid is unsafe even for a process this case forked - the pid of an
#     exited unwaited child IS reallocated here (96,765 forks, one wrap) - and
#     %%/%+ is a moving target: once ours was reaped it silently resolved to an
#     OLDER job and killed it. The captured number refuses with "no such job".
#   - job control stays OFF (nothing here runs `set -m`): under it the same
#     jobspec kill takes the whole process GROUP, including the child to spare.
#   - no background job is started between the launch and the kill, so the
#     captured number cannot be recycled onto a stranger.
#   - the DISCOVERED child is never signalled on a bare pid: it is WAITED out,
#     and escalation requires its ENVIRONMENT to name THIS run's throwaway
#     AC_HOME - never a basename, because this fleet's own ac-spawn.sh is alive
#     on the same host while the suite runs. The gate reads that environment at
#     runtime and is FAIL-CLOSED by construction: cannot read it, or it does not
#     match, means the case does NOT signal and fails loudly instead. Two
#     measured `ps` facts the gate depends on, and one open question, are
#     recorded in data/e2-sigkill-regression-test/implement/ (report section 6 +
#     probes/) rather than asserted here: `-p` is IGNORED when combined with
#     -e/-A, so `ps -eww -p <pid>` does not filter - it dumps every process, and
#     nothing may rely on it to select one; and `ps -Eww -p` shows no
#     environment. Whether `-eww` exposes a CHILD's environment on this host is
#     under dispute between two measurements and is NOT stated either way here,
#     because the gate's behaviour is identical under both readings.
#   - timeout(1) does not exist on this host, so every wait is a counted poll
#     and the suite fails rather than hangs.
reset_family
# The handle from an earlier case would satisfy the barrier before A opens
# anything at all.
rm -f "$AC_HOME/state/.pane-learning-chief"
due 9
# ac_config_read only runs `head` when the file EXISTS. Inert for harness=fake -
# a custom config/launch-<h> template consumes no model, and ac_record_launch_opts
# records none for it - so this fixture only arms the observer.
printf 'fixture-model\n' >"$AC_HOME/config/model"

e2k_claim="$AC_HOME/state/.meta-claims/learning-chief"
e2k_arrived="$TMP/e2k-b-invoked-spawn"
# Bound before the EXIT handler that reads them (set -u), and the ONLY handles
# the reap ever has.
e2k_a=""
e2k_job=""
e2k_child=""

e2k_head="$(command -v head)" || fail "E2-SIGKILL: no head on PATH - the arrival observer cannot pass through"
case "$e2k_head" in
  /*) ;;
  *) fail "E2-SIGKILL: head did not resolve to an absolute path ($e2k_head) - refusing to bake a relative pass-through" ;;
esac
mkdir -p "$TMP/e2k-shim"
cat >"$TMP/e2k-shim/head" <<SHIM
#!/usr/bin/env bash
# Records that a process in RACER B's tree read config/model - i.e. that B's
# ac-spawn.sh ran at all. Everything else passes straight through.
case "\$*" in *"/config/model") printf 'invoked\n' >>"$e2k_arrived" ;; esac
exec "$e2k_head" "\$@"
SHIM
chmod +x "$TMP/e2k-shim/head"

e2k_spawn_child_of() {
  # e2k_spawn_child_of <ancestor-pid> - the pid of a LIVE ac-spawn.sh descending
  # from it, from ONE process-table read. Depth-agnostic with a cap: ac-learn.sh
  # runs the spawn in a command substitution, so the exact depth is an
  # implementation detail and a single ppid compare would miss it.
  ps -Aww -o pid=,ppid=,args= | awk -v a="$1" '
    { line = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]*/, "", line)
      par[$1] = $2; argv[$1] = line; order[NR] = $1 }
    END {
      for (i = 1; i <= NR; i++) {
        p = order[i]
        if (argv[p] !~ /ac-spawn\.sh/) continue
        q = p
        for (d = 0; d < 8; d++) {
          if (!(q in par)) break
          q = par[q]
          if (q == a) { print p; exit }
          if (q <= 1) break
        }
      }
      exit 1
    }'
}

e2k_env_anchored() {
  # e2k_env_anchored <pid> - 0 only when that pid's ENVIRONMENT names THIS run's
  # throwaway AC_HOME, a token no live-fleet process can carry. Fails closed when
  # the environment cannot be read, and never prints what it read - the same
  # table carries other processes' environments.
  local e
  e="$(ps -eww 2>/dev/null | awk -v p="$1" '$1 == p')" || return 1
  [ -n "$e" ] || return 1
  case "$e" in *"AC_HOME=$AC_HOME"*) return 0 ;; esac
  return 1
}

e2k_stop_a() {
  # Signal what the case LAUNCHED through the shell's own job table and nothing
  # else - no read-then-act, and once bash has reaped the job the number REFUSES
  # rather than signalling a stranger. Idempotent; the number is dropped with
  # the job, so no later job can inherit it. With no number captured there is
  # nothing this case may safely signal, and it will NOT fall back to a pid.
  #
  # `wait` is reached only AFTER the pid is OBSERVED gone, so it can only
  # collect an already-dead child and can never block. A bare `wait` here was
  # the one foreground path outside the three ceilings the spec names, and bash
  # 3.2 has no `wait -t`, so a counted poll is the substitute - the same one
  # every other wait in this case uses. A zombie is invisible to `ps -p` on this
  # host, which is what makes the poll end promptly once the kill lands.
  local waited=0
  [ -n "$e2k_a" ] || return 0
  [ -z "$e2k_job" ] || kill -9 "%$e2k_job" 2>/dev/null || true
  while ps -p "$e2k_a" >/dev/null 2>&1 && [ "$waited" -lt 400 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if ps -p "$e2k_a" >/dev/null 2>&1; then
    printf 'E2-SIGKILL: racer A (pid %s, job %%%s) outlived the bounded stop poll - NOT signalled on a bare pid\n' \
      "$e2k_a" "${e2k_job:-none}" >&2
    return 1
  fi
  wait "$e2k_a" 2>/dev/null || true
  e2k_a=""
  e2k_job=""
  return 0
}

e2k_wait_settled() {
  # e2k_wait_settled <candidate-pid|""> - bounded poll until the candidate is
  # gone AND the claim dir is absent. The second predicate is DURABLE state (the
  # claim the child holds for its whole pre-meta life), so it needs no
  # case-local variable. Hard iteration ceiling because timeout(1) does not
  # exist on this host: the suite must fail rather than hang.
  local cand="$1" waited=0
  while [ "$waited" -lt 400 ]; do
    if { [ -z "$cand" ] || ! ps -p "$cand" >/dev/null 2>&1; } \
       && [ ! -e "$e2k_claim" ]; then
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

e2k_reap() {
  # The ONE reap, called from the case body AND from the EXIT trap.
  #
  # THE RULE, stated once instead of per path: this returns 0 ONLY when it has
  # OBSERVED settlement - candidate gone AND claim absent. Every other outcome -
  # racer A outliving its stop poll, the settle poll exhausting its cap, a
  # candidate still live, the claim still present, an escalation it could not
  # confirm - returns non-zero AND KEEPS the handle, so the EXIT retry waits on
  # the same candidate. Nothing here reports settled on state it did not observe,
  # which is the whole class three earlier patches died on.
  #
  # Its two callers differ only in what they do with that verdict, and they are
  # not in conflict because they bind different scopes: the case body FAILS
  # LOUDLY (the in-case reap is what spec section 5 Rule 3 governs), while the
  # EXIT net still runs cleanup unconditionally (helpers.sh's rule, which every
  # test file depends on and which is what keeps a failed reap from leaking $TMP).
  local cand rc=0
  e2k_stop_a || rc=1
  # The candidate is the barrier's identified child when there is one, ELSE the
  # claim file's pid - a case that failed BEFORE it identified a child must
  # still wait that child out. For WAITING only: waiting on a possibly-reused
  # pid can never hit the wrong process, only signalling can. The value is
  # validated, never a piped exit status.
  cand="$e2k_child"
  [ -n "$cand" ] || cand="$(cat "$e2k_claim/pid" 2>/dev/null || true)"
  case "$cand" in ''|*[!0-9]*) cand="" ;; esac
  if ! e2k_wait_settled "$cand"; then
    rc=1
    # Escalation is the only remaining action, and it is allowed ONLY under the
    # environment anchor - never on a bare pid, never on a basename. An
    # escalation that is not CONFIRMED is not a reap, so rc only clears when a
    # second bounded poll OBSERVES the candidate gone.
    if [ -n "$cand" ] && ps -p "$cand" >/dev/null 2>&1 \
       && ps -o args= -p "$cand" 2>/dev/null | grep -q 'ac-spawn\.sh' \
       && e2k_env_anchored "$cand"; then
      kill -9 "$cand" 2>/dev/null || true
      if e2k_wait_settled "$cand"; then rc=0; fi
    fi
  fi
  if [ "$rc" = 0 ]; then
    e2k_child=""
  else
    printf 'E2-SIGKILL: the reap did not OBSERVE settlement - candidate=%s claim=%s. Not signalled on an unverified identity; the handle is kept for the EXIT retry.\n' \
      "${cand:-none}" "$([ -e "$e2k_claim" ] && printf present || printf absent)" >&2
  fi
  return "$rc"
}

# bash keeps ONE handler per signal, so this chains helpers' cleanup LAST. The
# EXIT net runs cleanup UNCONDITIONALLY on purpose: at EXIT the status is already
# decided and a fail would be swallowed (the rule reap_hogs states), and a reap
# that could block the rm would leak $TMP for every file that chains this. The
# in-case reap is where an unobserved settlement is fatal. Same shape as
# tests/ac-lock.test.sh's kill_foreign.
e2k_exit() { e2k_reap || true; cleanup; }
trap e2k_exit EXIT

# Responsibility is fixed at LAUNCH, never at discovery: the handler above
# predates the launch and A's handles are captured by the launch statement
# itself, so every exit path from here - the very first barrier assertion
# included - enters the reap with valid handles.
AC_SPAWN_SETTLE=6 "$BIN/ac-learn.sh" autoroom >"$TMP/e2k-a.out" 2>&1 &
e2k_a=$!
e2k_job="$(jobs -l | awk -v p="$e2k_a" '/^\[/ { j = $1; sub(/^\[/, "", j); sub(/\].*/, "", j); for (i = 1; i <= NF; i++) if ($i == p) { print j; exit } }')"
[ -n "$e2k_job" ] || fail "E2-SIGKILL: racer A's job number was not captured - this case may not signal a bare pid"

# The barrier: the window is open (written before the settle and long before the
# meta), A is still pre-meta, and its ac-spawn.sh child is alive. Without the
# second, the harm assertions are vacuous - B would skip the spawn on its
# under-lock re-read; the third is the handle on the child to spare and wait out.
waited=0
until [ -e "$AC_HOME/state/.pane-learning-chief" ] || [ "$waited" -ge 500 ]; do
  sleep 0.02; waited=$((waited + 1))
done
assert_file "$AC_HOME/state/.pane-learning-chief" "E2-SIGKILL barrier: racer A's spawn opened its window"
assert_no_file "$meta" "E2-SIGKILL barrier: A is pre-meta (parked in ac-spawn's settle) when B contends"
e2k_child="$(e2k_spawn_child_of "$e2k_a")" || e2k_child=""
[ -n "$e2k_child" ] || fail "E2-SIGKILL barrier: no live ac-spawn.sh descends from racer A - there is no spared child to race"

# SIGKILL racer A's ac-learn.sh ONLY. Its ac-spawn.sh child outlives it, still
# parked pre-meta - that outliving child IS the failure shape.
e2k_stop_a || fail "E2-SIGKILL: racer A outlived its bounded stop poll - refusing to signal a bare pid, and the race cannot be run without A dead"

# B runs synchronously, with the arrival observer on ITS path only (A was
# launched before the shim existed, so A can never fire it).
set +e
e2k_b_out="$(PATH="$TMP/e2k-shim:$PATH" AC_SPAWN_SETTLE=0 "$BIN/ac-learn.sh" autoroom 2>&1)"
e2k_b_rc=$?
set -e
e2k_reap || fail "E2-SIGKILL: the reap did not OBSERVE the spared child settled - the assertions below would read a tree still being written"

# HARM - what actually breaks when the claim is gone. Measured on a
# pre-fix-equivalent tree: PROMOTED=2 DECIDED=2, window BROKEN, B not silent.
assert_eq "$(promotes)" "1" "E2-SIGKILL: exactly one PROMOTED post - the dead racer's window was not double-promoted"
assert_eq "$(grep -c 'DECIDED:' "$room" 2>/dev/null || true)" "1" "E2-SIGKILL: exactly one DECIDED receipt"
e2k_win="$(awk -F= '$1 == "window" { print $2 }' "$meta" 2>/dev/null || true)"
assert_file "$FAKE_HERDR/panes/${e2k_win#herdr:pane-}.buf" "E2-SIGKILL: the surviving meta still addresses a live pane - the loser did not reap the winner's window"
assert_eq "$e2k_b_out" "" "E2-SIGKILL: the loser is SILENT - not an orphan-window reap warning printed into the drain"
assert_eq "$e2k_b_rc" "0" "E2-SIGKILL: racer B exits 0 - a race is normal operation, not a fault"
# Measured 1 in BOTH legs, so it does NOT distinguish them: it pins the headline
# property (one roomchief per family), never claim coverage.
assert_eq "$(find "$AC_HOME/state" -name '*-chief.meta' | wc -l | tr -d ' ')" "1" "E2-SIGKILL: exactly one roomchief meta survives the race"
assert_no_file "$e2k_claim" "E2-SIGKILL: the spawn-owned atomic claim is released once the winner is addressable"

# VALIDITY, deliberately AFTER the harm assertions, and that order is what makes
# the bite proof mean anything: a CLAIM regression must red on the property under
# protection, a PRECONDITION regression on a message naming the precondition.
# Reversed, a bite proof would red with "B never reached the claim" and prove
# nothing about the double promote.
assert_no_file "$AC_HOME/state/.learn-autoroom.lock" "E2-SIGKILL validity: B reclaimed the DEAD owner's lock and released it - nothing else can remove it"
assert_file "$e2k_arrived" "E2-SIGKILL validity: racer B's ac-spawn.sh RAN - without this, every harm assertion above is vacuous"
rm -f "$AC_HOME/config/model"

# -- F2: the firing predicate is RE-READ under the lock ------------------------
# A caller that passed the cheap pre-lock DUE gate can be overtaken: another
# cycle completes, resets the counter and tears its room down, all before this
# caller takes the lock. Under a serializing lock the authoritative read happens
# INSIDE it, so the overtaken caller finds not-DUE and creates nothing.
# Deterministic, no timing: a mkdir shim flips the counter to not-DUE at the
# exact instant the lock is taken - between the pre-lock gate (already DUE) and
# the under-lock read.
reset_family
due 9
mkdir -p "$TMP/shimbin"
cat >"$TMP/shimbin/mkdir" <<SHIM
#!/usr/bin/env bash
# On the autoroom lock ONLY, land the F2 interleave - the cadence flips to
# not-DUE as the lock is taken - then make the dir for real. Everything else
# passes straight through.
case "\$*" in
  *"/.learn-autoroom.lock") printf 'debriefs=0\n' >"$AC_HOME/state/.learn.meta" ;;
esac
exec /bin/mkdir "\$@"
SHIM
chmod +x "$TMP/shimbin/mkdir"
set +e
stale_out="$(PATH="$TMP/shimbin:$PATH" "$BIN/ac-learn.sh" autoroom 2>&1)"
stale_rc=$?
set -e
assert_eq "$stale_rc" "0" "F2: an overtaken caller exits 0"
assert_eq "$stale_out" "" "F2: an overtaken caller is silent"
assert_no_file "$meta" "F2: a caller that reads DUE, then loses it before the lock, creates NO room"
assert_no_file "$room" "F2: it never even posts the charter - the under-lock read is decisive"
assert_no_file "$AC_HOME/state/.learn-autoroom.lock" "F2: the lock is released on the not-DUE-under-lock path"

# -- AC-3: the already-fired fact is DURABLE - a fresh process, cold ac-lib.sh,
#    reading only the home reaches the same conclusion. Nothing is held in
#    memory, so a restart between the crossing and the next checkpoint is a
#    non-event.
reset_family
due 9
"$BIN/ac-learn.sh" autoroom >/dev/null 2>&1

# -- AC-3: the already-fired fact is DURABLE - a fresh process, cold ac-lib.sh,
#    reading only the home reaches the same conclusion. Nothing is held in
#    memory, so a restart between the crossing and the next checkpoint is a
#    non-event.
fresh="$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; [ -e \"\$(ac_state_dir)/learning-chief.meta\" ] && printf fired")"
assert_eq "$fresh" "fired" "AC-3: the roomchief meta is the durable already-fired fact"

# -- AC-5: cap-exempt, truthfully ----------------------------------------------
# A counted chief fills room-parallel=1; the trigger fires anyway, and the
# counted population is UNCHANGED afterwards - the learning chief added nothing.
reset_family
printf '1\n' >"$AC_HOME/config/room-parallel"
printf 'kind=roomchief\nbackend=herdr\ninitiated_by=chief\n' >"$AC_HOME/state/other-chief.meta"
due 9
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "AC-5: a full cap must not refuse the learning room: $out"
assert_file "$meta" "AC-5: the learning room is promoted at a full cap"
out="$("$BIN/ac-spawn.sh" --roomchief third --harness fake 2>&1)" && fail "AC-5: an ordinary promote must still refuse at 1/1"
assert_contains "$out" "room-parallel cap reached: 1/1" "AC-5: the learning chief added nothing to the counted population"
rm -f "$AC_HOME/config/room-parallel"

# -- AC-10: a SCOPED session never promotes a fleet-level chief ----------------
# Promotion is a crewchief act, and a scoped session's AC_SCOPE would leak into
# the spawn.
reset_family
due 9
out="$(AC_SCOPE=fam "$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a scoped autoroom must exit 0: $out"
assert_eq "$out" "" "AC-10: a scoped autoroom is silent"
assert_no_file "$meta" "AC-10: a scoped session creates no learning roomchief"
assert_no_file "$room" "AC-10: a scoped session posts no charter either"

# -- AC-4: a failed create does not consume the crossing -----------------------
# config/crew-harness names a harness with no launch template, so the spawn dies
# exactly where a dead backend would.
printf 'nope\n' >"$AC_HOME/config/crew-harness"
set +e
out="$("$BIN/ac-learn.sh" autoroom 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "AC-4/AC-11: a failed create never fails its caller"
assert_no_file "$meta" "AC-4: a failed spawn writes no meta - firing is recorded on success, never on intent"
assert_contains "$out" "WARN" "AC-4: the failure is reported, never swallowed"
# The lock must be RELEASED by the failure too. A lock that outlived a failed
# create would disarm the loop until its stale-grace elapsed - so release it now
# rather than lean on recovery. (The NEXT-call assertion below is what actually
# proves the crossing was not consumed; this pins the immediate release.)
assert_no_file "$AC_HOME/state/.learn-autoroom.lock" "AC-4: a failed create releases its lock"
printf 'fake\n' >"$AC_HOME/config/crew-harness"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "AC-4: the next call must still attempt the create: $out"
assert_file "$meta" "AC-4: the failed attempt did not consume the crossing"

# -- E6/E7: DUE is read through ac_learn_due and nothing else ------------------
# A legacy `stows`-keyed counter and a garbage learn-every both resolve there -
# no second implementation of the read, which is the rule that keeps it so.
reset_family
printf 'stows=9\n' >"$AC_HOME/state/.learn.meta"
printf 'lots\n' >"$AC_HOME/config/learn-every"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "E6/E7: a legacy key + garbage knob must still fire: $out"
assert_file "$meta" "E6/E7: DUE reads through ac_learn_due (legacy stows key, clamped learn-every)"
rm -f "$AC_HOME/config/learn-every"

# -- AC-8: automatic code never calls the legacy compatibility verbs -----------
# `run` stages and applies through the maintenance boundary directly. No agent
# surface may authenticate automatic work by shelling back into `land` or
# `promote`; the former requires a legacy approved header and the latter refuses.
#
# What separates an INVOCATION from a mention, keyed on what FOLLOWS the verb -
# because the PRECEDING context cannot tell them apart: a shell command
# substitution `result=`bin/ac-learn.sh land "$c"`` and a markdown code span
# `\`bin/ac-learn.sh land\`` both put a backtick before the path, so a
# backtick-exclusion rule is either blind to the caller (on shell surfaces,
# where a backtick is command substitution) or misfires on the doc. What DOES
# separate them is the ARGUMENT: `land`/`promote` both require one, so a real
# invocation is followed by a shell argument (`"$c"`, a `/path`, a `$var`, a
# bareword), while EVERY documentation mention in this repo is followed by a
# `<placeholder>`, a closing backtick, or `)`. Keying on that is surface-
# agnostic - it needs no bin/-vs-prose split, catches a PATH-resolved bare
# `ac-learn.sh land ...` (no leading slash to anchor on) and a backtick command
# substitution alike, and a no-argument occurrence is doc by construction (a
# real land/promote with no argument dies immediately and loudly).
scan_invocations() {
  # scan_invocations <dir>... - THE check. A function so the bite cases below
  # exercise the same pipeline the real assertion runs; a second copy could
  # drift and then prove nothing about the guard actually in force.
  # ERE: an optional path segment (or none - a PATH-resolved bare call), then
  # ac-learn.sh, an optional closing quote, the verb, then an ARGUMENT-start
  # char (a quote, $, /, or an alphanumeric) - never `<`, a backtick, or `)`.
  local inv='(^|[^A-Za-z0-9._-])([A-Za-z0-9._${}"/-]*/)?ac-learn\.sh"?[[:space:]]+(land|promote)[[:space:]]+["'\''$/A-Za-z0-9]'
  grep -rEn "$inv" "$@" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
scan=""
for s in bin .agents hooks; do [ -d "$ROOT/$s" ] && scan="$scan $ROOT/$s"; done
# shellcheck disable=SC2086
callers="$(scan_invocations $scan)"
[ -z "$callers" ] \
  || fail "AC-8: automatic code may not invoke legacy ac-learn.sh land/promote: $callers"

# The guard must BITE - on every shape a regression could take, on any surface.
bite() {
  # bite <file> <line> - what the check makes of this one planted line, alone.
  rm -rf "$TMP/bite"; mkdir -p "$TMP/bite"
  printf '%s\n' "$2" >"$TMP/bite/$1"
  scan_invocations "$TMP/bite"
}
[ -n "$(bite planted.sh '  bin/ac-learn.sh land "$cand"')" ] \
  || fail "AC-8 guard is porous: a path-prefixed shell invocation is not caught"
[ -n "$(bite subst.sh '  result=`bin/ac-learn.sh land "$cand"`')" ] \
  || fail "AC-8 guard is porous: a backtick command-substitution invocation is not caught (backtick is not markdown on a shell surface)"
[ -n "$(bite path.sh '  ac-learn.sh promote "$name"')" ] \
  || fail "AC-8 guard is porous: a PATH-resolved invocation with no leading slash is not caught"
[ -n "$(bite prose.md 'Then run "$(dirname "$0")/ac-learn.sh" promote foo to finish.')" ] \
  || fail "AC-8 guard is porous: an invocation outside bin/ is not caught"
[ -z "$(bite doc.sh '# usage: bin/ac-learn.sh land <candidate>')" ] \
  || fail "AC-8 guard is noisy: a comment line is documentation, not an invocation"
[ -z "$(bite doc.md 'land it with `bin/ac-learn.sh land <candidate>` after the captain says yes')" ] \
  || fail "AC-8 guard is noisy: a backtick-quoted <placeholder> mention is documentation, not an invocation"
[ -z "$(bite dispatch.sh '  *) ac_die "usage: ac-learn.sh tick [<landing-id>]|autoroom|run|land <candidate>|promote <name>" ;;')" ] \
  || fail "AC-8 guard is noisy: the script's own usage string is documentation"

# ==== the ledger shape gate in front of the promote ===========================
# TWO consecutive DISTILL windows died on the same class (learning-1785257205,
# 2026-07-28, 7/7 revise; learning-1785752132, 2026-08-03, 5/5 revise): a
# records/learnings.md shape learn_ledger_stage cannot reproduce byte-for-byte
# outside a candidate's own edit, so EVERY per-candidate plan bundled a
# ledger-wide repair and the maintenance gate correctly refused it as
# over-broad. This gate sits in cmd_autoroom BEFORE the charter post/spawn -
# same site and contract as the full-suite gate below - so a bad shape holds
# the cycle before the scout pane ever runs, instead of after it has spent the
# cycle proposing candidates the gate was always going to refuse.
ledger="$AC_HOME/records/learnings.md"
mkdir -p "$AC_HOME/records/learnings-archive"

# -- class 1 (2026-07-28, 7/7 revise): un-canonicalized legacy pointer rows --
# Exact rows copied from state/backups/curate-1785259163.tar.gz:records/learnings.md
# (the pre-canonicalization ledger measured at intake: 183 legacy rows, 0 canonical).
reset_family
suite_task_clear
rm -f "$suite_rec"
due 9
cat >"$ledger" <<'LEDGER'
# Fleet learnings

Dated, durable, reusable lessons. One line each, newest at the bottom of each date.

## 2026-07-16 (family ac-fleets)

- 2026-07-16 [distilled -> local-landing-race @fleet] rebase in worktree, never primary checkout (see skills/local-landing-race/SKILL.md)
- 2026-07-16 [distilled -> scout-order-before-brief @fleet] order's named mechanism can be impossible (see skills/scout-order-before-brief/SKILL.md)
- 2026-07-20 [distilled -> probe-the-external-actor @container] the host enum costs one --help (see ../.claude/skills/probe-the-external-actor/SKILL.md)
LEDGER
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "an un-canonicalized legacy pointer row holds the promote"
assert_contains "$out" "HELD" "the hold is visible to the chief reading the drain"
assert_contains "$out" "legacy" "the hold names the legacy-pointer defect"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "0" \
  "the shape gate holds BEFORE the (expensive) suite task is ever started"

# -- class 2 (2026-08-03, 5/5 revise): a dangling [evidence] link ------------
# Exact rows copied from
# state/backups/learnings-pre-evidence-link-repair-20260803T104319Z.md.
cat >"$ledger" <<'LEDGER'
# Learning Ledger

## Pending

## Distilled

- [distilled -> probe-the-external-actor] sources=16 updated=2026-07-25 ([skill](../skills/probe-the-external-actor/SKILL.md); [evidence](learnings-archive/probe-the-external-actor.md))
- [distilled -> prove-tests-bite] sources=15 updated=2026-07-25 ([skill](../skills/prove-tests-bite/SKILL.md); [evidence](learnings-archive/prove-tests-bite.md))
LEDGER
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "a dangling [evidence] link holds the promote"
assert_contains "$out" "HELD" "the hold is visible to the chief reading the drain"
assert_contains "$out" "evidence" "the hold names the dangling-evidence defect"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "0" \
  "the shape gate holds BEFORE the (expensive) suite task is ever started"

# -- (a) NO FALSE POSITIVE: the awkward-but-fine accreted frames -------------
# repo-knowledge (ac-learn-ledger-transaction-accretes-blank-lines-and-
# publishes-archives-it-never-creates): these spacings cannot round-trip
# through learn_ledger_stage and are canonicalized, not defects - a check
# that flags them gets switched off, same as the privacy-scrub test this
# order warns against repeating.
cat >"$ledger" <<'LEDGER'
# Learning Ledger



## Pending

- a hand-edited lesson with extra blanks before it.

## Distilled

- [distilled -> real-skill] sources=1 updated=2026-07-18 ([skill](../skills/real-skill/SKILL.md))
LEDGER
green_suite
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "surplus blanks after the title must not hold: $out"
assert_file "$meta" "surplus blanks after the title are NOT a shape defect"
reset_family
suite_task_clear
rm -f "$suite_rec"

cat >"$ledger" <<'LEDGER'
# Learning Ledger

## Pending


## Distilled

- [distilled -> real-skill] sources=1 updated=2026-07-18 ([skill](../skills/real-skill/SKILL.md))
LEDGER
due 9
green_suite
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "an empty Pending 2 blanks from Distilled must not hold: $out"
assert_file "$meta" "an empty Pending exactly 2 blanks from Distilled is NOT a shape defect"
reset_family
suite_task_clear
rm -f "$suite_rec"

# -- (a) NO FALSE POSITIVE: today's real live ledger (trimmed, exact rows) ---
# Verbatim canonical pointer rows from drydock's records/learnings.md as of
# 2026-08-03 (post evidence-link repair, 0 dangling links) - the same real
# shape this order was raised against.
cat >"$ledger" <<'LEDGER'
# Learning Ledger

## Pending

## Distilled

- [distilled -> characterise-the-failure] sources=24 updated=2026-07-25 ([skill](../skills/characterise-the-failure/SKILL.md))
- [distilled -> close-the-ground] sources=11 updated=2026-07-22 ([skill](../skills/close-the-ground/SKILL.md))
- [distilled -> local-landing-race] sources=19 updated=2026-07-20 ([skill](../skills/local-landing-race/SKILL.md))
- [distilled -> pin-position-not-prose] sources=2 updated=2026-07-22 ([skill](../skills/pin-position-not-prose/SKILL.md))
- [distilled -> probe-the-external-actor] sources=16 updated=2026-07-25 ([skill](../skills/probe-the-external-actor/SKILL.md))
- [distilled -> verify-spawn-delivered] sources=11 updated=2026-07-20 ([skill](../skills/verify-spawn-delivered/SKILL.md))
LEDGER
due 9
green_suite
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "today's real live ledger shape must not hold: $out"
assert_file "$meta" "the live ledger's actual current shape is NOT a shape defect"
reset_family
suite_task_clear
rm -f "$suite_rec"
rm -f "$ledger"
green_suite

# ==== the full-suite gate in front of the promote =============================
# The standing rule "THE FULL SUITE MOVES TO A PERIODIC TASK RUN
# BEFORE LEARNING": the suite runs as its own periodic task immediately before
# each DISTILL, and "only a green suite releases the DISTILL run" - a retro
# reasoning about a fleet whose suite is red inherits the defect. The gate lives
# in THIS path because ac-wake-drain.sh calls autoroom unconditionally on every
# drain, so prose cannot block it.
#
# Every assertion here is about durable state a fresh process re-reads, like the
# rest of this file: the gate is LEVEL-triggered too, so a lost wake, a restart
# or a counter already past its threshold all reach the same decision.

# -- no verdict on record: no promote, and the suite TASK is started -----------
reset_family
suite_task_clear
rm -f "$suite_rec"
due 9
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "no suite verdict on record -> no learning roomchief"
assert_contains "$out" "HELD" "the hold is VISIBLE to the chief reading the drain"
suite_meta="$(suite_tasks)"
[ -f "$suite_meta" ] || fail "the gate must START the suite run: it is a TASK with its own pane and meta, never a chief-side shell call"
suite_id="$(basename "$suite_meta" .meta)"
assert_eq "$(awk -F= '$1=="kind"{print $2}' "$suite_meta")" "verify-suite" \
  "the suite task is a VERIFICATION meta - supervised like any pane, out of crew accounting"
assert_file "$AC_HOME/state/.pane-$suite_id" "the suite task has its own herdr pane"
assert_contains "$(cat "$(fake_pane_buf "$suite_id")")" "ac-learn.sh suite $suite_id" \
  "the suite RUNS IN ITS OWN PANE - not inside the drain, not in a chief's context"

# -- a run already in flight: the gate WAITS, it never starts a second ---------
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "a suite still running releases nothing"
assert_contains "$out" "in flight" "the hold says the run is already going"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "1" "no second suite run while one flies"

# -- a run that DIED: only a DEFINITE gone reclaims it ------------------------
# The one failure mode a presence check cannot heal. cmd_suite retires its own
# identity when it FINISHES, never when it is KILLED, so a SIGKILLed pane (a
# host reboot, a herdr restart) leaves a meta behind - and a presence-only gate
# would print "still in flight" on every drain for ever, waiting for a human to
# rm a file. A killed owner is a case this codebase RECOVERS from, like
# ac_lock_stale reclaiming a lock left by a dead pid.
reset_family
suite_task_clear
rm -f "$suite_rec"
dead=verify-suite-1
printf 'kind=verify-suite\nbackend=herdr\nwindow=x\n' >"$AC_HOME/state/$dead.meta"
# A handle naming a pane herdr does not have: `pane get` fails, `pane list`
# answers and does not carry it - the backend was REACHED and said gone.
printf 'pGONE tGONE\n' >"$AC_HOME/state/.pane-$dead"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$AC_HOME/state/$dead.meta" "a DEFINITE gone reclaims the dead run's meta"
assert_no_file "$AC_HOME/state/.pane-$dead" "and its pane handle"
assert_contains "$out" "started the full-suite run" "and a fresh run starts, with nobody standing watch"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "1" "exactly one suite task - the fresh one"
assert_no_file "$meta" "and still no promote until that run comes back green"

# -- a run that DIED leaves no snapshot behind either --------------------------
# The concrete leak the brief calls out: a SIGKILLed pane must not leave a git
# worktree registration behind. Simulate the run having reached the checkout
# step before it died by creating the exact worktree cmd_suite would have
# (learn_suite_snapshot_dir <id> = .crew/learn-suite-snapshots/<id>), then
# kill the pane the same way the case above does and confirm the reclaim path
# retires the worktree the same way it retires the meta/status/pane handle.
suite_task_clear
dead2=verify-suite-2
snap_dir="$ROOT/.crew/learn-suite-snapshots/$dead2"
git -C "$ROOT" worktree add --detach --quiet "$snap_dir" "$suite_head"
printf 'kind=verify-suite\nbackend=herdr\nwindow=x\n' >"$AC_HOME/state/$dead2.meta"
printf 'pGONE tGONE\n' >"$AC_HOME/state/.pane-$dead2"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
[ ! -e "$snap_dir" ] || fail "the killed-pane reclaim must remove the snapshot worktree it left behind"
git -C "$ROOT" worktree list | grep -q "learn-suite-snapshots/$dead2" \
  && fail "the killed-pane reclaim must also retire the worktree's git registration" || true
assert_contains "$out" "started the full-suite run" "and a fresh run starts"
suite_task_clear

# -- UNOBSERVABLE is not a death: HOLD, never reclaim -------------------------
# ac-backend.sh WINDOW LIVENESS: a backend that could not be READ is not a dead
# pane. Reclaiming there would start a second suite on top of a live one, and
# the two runs would race for the same verdict record.
suite_task_clear
printf 'kind=verify-suite\nbackend=herdr\nwindow=x\n' >"$AC_HOME/state/$dead.meta"
printf 'pGONE tGONE\n' >"$AC_HOME/state/.pane-$dead"
: >"$FAKE_HERDR/.pane-api-down"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
rm -f "$FAKE_HERDR/.pane-api-down"
assert_file "$AC_HOME/state/$dead.meta" "an UNREADABLE backend is not a death - the meta stays"
assert_contains "$out" "in flight" "and the gate keeps holding"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "1" "no second suite on top of a possibly-live one"
assert_no_file "$meta" "and no promote"
suite_task_clear

# -- a green from ANOTHER cycle, or another TREE, releases nothing -------------
suite_task_clear
printf 'generation=9\nhead=%s\nstatus=green\nexit=0\n' "$suite_head" >"$suite_rec"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "a green from a PREVIOUS cycle does not release this one"
suite_task_clear
printf 'generation=0\nhead=0000000000000000000000000000000000000000\nstatus=green\nexit=0\n' >"$suite_rec"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "a green taken against a DIFFERENT tree does not release this one"

# -- RED for this cycle: hold loudly, and do not re-run what just failed -------
suite_task_clear
printf 'generation=0\nhead=%s\nstatus=red\nexit=1\n' "$suite_head" >"$suite_rec"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_no_file "$meta" "a RED suite holds the DISTILL - the bug is fixed FIRST and Learning waits"
assert_contains "$out" "RED" "the red is VISIBLE to the chief reading the drain"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "0" \
  "a red does not busy-loop a fresh 6-minute suite run on every drain - the same tree gives the same answer"

# -- RED SELF-HEAL PRESERVED: a red whose live HEAD has since moved re-pins
# and launches a fresh attempt - the header's pre-existing promise ("the fix
# lands, HEAD moves, and the next checkpoint starts a fresh run by itself"),
# which the pinned-head fix above must not silently drop just because GREEN
# is now sticky. Simulated the same way as the regression above: seed the pin
# AND the red record with a fake, since-superseded sha so live HEAD
# ($suite_head) reads as "moved" without touching the real repo.
reset_family
suite_task_clear
stale_sha="0000000000000000000000000000000000000002"
printf 'generation=0\nhead=%s\n' "$stale_sha" >"$AC_HOME/state/.learn-suite-pin.meta"
printf 'generation=0\nhead=%s\nstatus=red\nexit=1\n' "$stale_sha" >"$suite_rec"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_contains "$out" "started the full-suite run" \
  "a red whose tree live HEAD has since moved re-pins and self-heals, same as before the fix"
assert_eq "$(awk -F= '$1=="head"{print $2}' "$AC_HOME/state/.learn-suite-pin.meta")" "$suite_head" \
  "the re-pin advances to the NEW live tree, not the stale red one"
suite_task_clear
rm -f "$AC_HOME/state/.learn-suite-pin.meta"

# -- GREEN for this cycle and this tree: the promote proceeds ------------------
green_suite
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a released autoroom must exit 0: $out"
assert_file "$meta" "a green suite for THIS cycle and tree releases the DISTILL"
assert_contains "$out" "learning DUE (9/8)" "and the release still names what it created"

# -- REGRESSION (measured 2026-08-11): a green earned against the tree THIS
# CYCLE PINNED must still release even though the LIVE checkout has since
# moved past it - the exact shape that discarded three consecutive green runs
# (1786430358, 1786432315, 1786436214) before agent-crew happened to sit still
# long enough for one to survive. Simulated without touching the real repo's
# HEAD, the same technique the mismatch case above already uses: the PIN is
# seeded directly with an arbitrary sha, standing in for "the tree the cycle
# already pinned before a commit landed underneath it." Against the CURRENT
# code (learn_suite_gate re-reads live HEAD at every consult) this fails: live
# HEAD is the real $suite_head, never the fake pinned sha, so the record's
# head can never match and the green is discarded exactly like the incident.
reset_family
suite_task_clear
rm -f "$suite_rec"
pinned_sha="0000000000000000000000000000000000000001"
printf 'generation=0\nhead=%s\n' "$pinned_sha" >"$AC_HOME/state/.learn-suite-pin.meta"
printf 'generation=0\nhead=%s\nstatus=green\nexit=0\n' "$pinned_sha" >"$suite_rec"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a released autoroom must exit 0: $out"
assert_file "$meta" "a green earned against the PINNED tree releases the DISTILL even though live HEAD ($suite_head) has since moved past it"
rm -f "$AC_HOME/state/.learn-suite-pin.meta"

# -- a send that never lands leaves NOTHING behind ----------------------------
# The fail direction that matters: a task meta with no run behind it would hold
# the gate at "in flight" for ever, so a non-zero send retires the whole
# identity - tab included - and the next checkpoint starts clean. Same
# next-pane-id idiom as tests/ac-spawn-teardown.test.sh's kickoff cases.
reset_family
suite_task_clear
rm -f "$suite_rec"
n="$(cat "$FAKE_HERDR/.n")"; spane="p$((n + 1))"
printf '99\n' >"$FAKE_HERDR/panes/$spane.drop-enters"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
assert_contains "$out" "could not be started" "an unacknowledged send is reported, not assumed delivered"
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "0" \
  "a stranded send leaves no task meta - one would hold the gate at 'in flight' for ever"
[ -z "$(ls "$AC_HOME"/state/.pane-verify-suite-* 2>/dev/null)" ] || fail "a stranded send leaves no pane handle either"
assert_no_file "$meta" "and still no learning roomchief"

# -- the suite TASK itself: one verdict for the cycle+tree it started on -------
# The runner is stubbed: what is under test is what the task RECORDS, and a real
# tests/run-suite.sh here would run the whole suite from inside the suite.
reset_family
suite_task_clear
rm -f "$suite_rec"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/suite-green"; chmod +x "$TMP/suite-green"
printf '#!/usr/bin/env bash\nexit 3\n' >"$TMP/suite-red"; chmod +x "$TMP/suite-red"

AC_LEARN_SUITE_BIN="$TMP/suite-green" "$BIN/ac-learn.sh" suite >/dev/null
assert_eq "$(awk -F= '$1=="status"{print $2}' "$suite_rec")" "green" "a passing suite records green"
assert_eq "$(awk -F= '$1=="head"{print $2}' "$suite_rec")" "$suite_head" "the verdict names the TREE it ran against"
assert_eq "$(awk -F= '$1=="generation"{print $2}' "$suite_rec")" "0" "and the cadence generation it answered for"

set +e
AC_LEARN_SUITE_BIN="$TMP/suite-red" "$BIN/ac-learn.sh" suite >/dev/null 2>&1
suite_rc=$?
set -e
assert_eq "$suite_rc" "3" "the task exits with the runner's own status - a hand-run caller is told"
assert_eq "$(awk -F= '$1=="status"{print $2}' "$suite_rec")" "red" "a failing suite records red"
assert_eq "$(awk -F= '$1=="exit"{print $2}' "$suite_rec")" "3" "and keeps the runner's status, so a runner that could not run (exit 2) is not read as a test failure"

# -- the task RETIRES its own identity, so a dead run is never mistaken for a
# live one: a checkpoint that finds neither a verdict nor a live task starts a
# fresh run, with no timer and no stamp to go stale.
suite_task_clear
rm -f "$suite_rec"
out="$("$BIN/ac-learn.sh" autoroom 2>&1)" || fail "a held autoroom must still exit 0: $out"
suite_id="$(basename "$(suite_tasks)" .meta)"
AC_LEARN_SUITE_BIN="$TMP/suite-green" "$BIN/ac-learn.sh" suite "$suite_id" >/dev/null
assert_eq "$(suite_tasks | wc -l | tr -d ' ')" "0" "the finished suite task removes its own meta"
assert_no_file "$AC_HOME/state/.pane-$suite_id" "and its own pane handle"
# A hand-typed id may never reach outside the suite task's own namespace: the
# cleanup is an rm, and the ids next to it are live crewmates.
: >"$AC_HOME/state/greet2.meta"
set +e
AC_LEARN_SUITE_BIN="$TMP/suite-green" "$BIN/ac-learn.sh" suite greet2 >/dev/null 2>&1
suite_rc=$?
set -e
assert_eq "$suite_rc" "1" "a non-suite task id is refused (ac_die), not obeyed"
assert_file "$AC_HOME/state/greet2.meta" "and a crewmate's meta is left alone"
rm -f "$AC_HOME/state/greet2.meta"

green_suite

# ==== the ride-along on the fleet drain (the trigger's SITE) ==================

# A drain in a DUE home creates the room AND keeps its own contract intact: its
# queued wakes still come out, and it still exits 0 (AC-11).
reset_family
due 9
mkdir -p "$AC_HOME/state/.wake-spool"
printf '1\treport\tt1\tdone: shipped\n' >"$AC_HOME/state/.wake-spool/1.1.000000"
out="$(env -u AC_SCOPE "$BIN/ac-wake-drain.sh" 2>&1)" || fail "the drain must exit 0: $out"
assert_contains "$out" "report t1 done: shipped" "AC-11: the drain still emits its queued wakes"
assert_file "$meta" "the ride-along creates the learning room when one is owed"

# A RED suite reaches the chief where the captain said it must: in the drain's
# own output, on a drain that still exits 0 and still emits its wakes.
reset_family
suite_task_clear
printf 'generation=0\nhead=%s\nstatus=red\nexit=1\n' "$suite_head" >"$suite_rec"
mkdir -p "$AC_HOME/state/.wake-spool"
printf '1\treport\tt2\tdone: shipped\n' >"$AC_HOME/state/.wake-spool/1.1.000001"
out="$(env -u AC_SCOPE "$BIN/ac-wake-drain.sh" 2>&1)" || fail "a held drain must exit 0: $out"
assert_contains "$out" "RED" "the red suite is VISIBLE in the drain output the chief reads"
assert_contains "$out" "report t2 done: shipped" "and the drain keeps its own contract"
assert_no_file "$meta" "a red suite holds the promote on the ride-along too"
green_suite

# A SCOPED drain runs no fleet ride-along at all (the same gate that already
# holds back the epic scheduler and the remote push).
reset_family
out="$(AC_SCOPE=fam "$BIN/ac-wake-drain.sh" 2>&1)" || fail "a scoped drain must exit 0: $out"
assert_no_file "$meta" "a scoped drain runs no fleet ride-along"

# A drain whose trigger FAILS still exits 0 and still prints its wakes.
printf 'nope\n' >"$AC_HOME/config/crew-harness"
mkdir -p "$AC_HOME/state/.wake-spool"
printf '1\treport\tt3\tdone: late work\n' >"$AC_HOME/state/.wake-spool/1.1.000002"
set +e
out="$(env -u AC_SCOPE "$BIN/ac-wake-drain.sh" 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "AC-11: a failing trigger never fails the drain"
assert_contains "$out" "report t3 done: late work" "AC-11: the drain still emits its wakes when the trigger fails"
assert_no_file "$meta" "the failed trigger recorded nothing"

pass
