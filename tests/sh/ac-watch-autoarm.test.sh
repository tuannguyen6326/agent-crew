#!/usr/bin/env bash
# ac-watch-autoarm.test.sh - the Stop-hook watcher continuity: scope, the
# "supervision owed" predicate, silent re-arm on heartbeat, translation of an
# actionable close into a wake, standing out of another watcher's way, the
# budget handback, and fail-open on every missing dependency.
#
# ac-watch.sh is STUBBED in every row but "the real watcher": this suite owns
# the hook's translation logic, not the watcher's own behaviour
# (tests/sh/ac-watch.test.sh owns that), and that row only proves the real
# entry's line reaches it. The differential leg at the end holds
# src/watch-autoarm.ts to the frozen bash original.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# A private bin/ whose ac-watch.sh is a stub, so the hook's own resolution
# (the bin/ its module was started from) picks the stub up exactly as it would
# the real one. Its root links src/, where the shim finds the module.
labroot="$TMP/autoarm-root"
lab="$labroot/bin"
mkdir -p "$lab"
ln -s "$ROOT/src" "$labroot/src"
cp "$BIN/ac-watch-autoarm.sh" "$BIN/ac-bun.sh" "$lab/"
# ac-ready.sh runs its verbs in src/ready.ts, which ac-bun.sh finds beside its
# own bin/ - a copy here would find none and fail every watch-set.
printf '#!/bin/sh\nexec "%s/ac-ready.sh" "$@"\n' "$BIN" >"$lab/ac-ready.sh"
chmod +x "$lab/ac-ready.sh"
hook="$lab/ac-watch-autoarm.sh"

# stub_watch <line> [<line2> ...] - each invocation prints the next line and
# exits; the call count is recorded so a silent re-arm is provable.
stub_watch() {
  : >"$TMP/watch.calls"
  printf '%s\n' "$@" >"$TMP/watch.script"
  # Paths are baked in: the hook runs the stub in its own process, which does
  # not inherit the suite's $TMP.
  cat >"$lab/ac-watch.sh" <<EOF
#!/usr/bin/env bash
n=\$(( \$(wc -l <"$TMP/watch.calls" 2>/dev/null | tr -d ' ') + 1 ))
printf 'call\n' >>"$TMP/watch.calls"
line="\$(sed -n "\${n}p" "$TMP/watch.script")"
[ -n "\$line" ] || line="\$(tail -n 1 "$TMP/watch.script")"
printf '%s\n' "\$line"
EOF
  chmod +x "$lab/ac-watch.sh"
}
calls() { wc -l <"$TMP/watch.calls" 2>/dev/null | tr -d ' '; }

# stub_watch_env <line> - one invocation that RECORDS the arm env (one file per
# variable, so an unset one reads as empty) and then prints <line>.
stub_watch_env() {
  : >"$TMP/watch.calls"
  cat >"$lab/ac-watch.sh" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$TMP/watch.calls"
printf '%s' "\${AC_WATCH_SKIP:-}" >"$TMP/watch.env.skip"
printf '%s' "\${AC_WATCH_ONLY:-}" >"$TMP/watch.env.only"
printf '%s' "\${AC_AUTOARM:-}" >"$TMP/watch.env.autoarm"
printf '%s\n' '$1'
EOF
  chmod +x "$lab/ac-watch.sh"
}

# stub_watch_refusal <rc> <line> - one invocation printing <line> on STDOUT and
# exiting <rc>: the shape every ac-watch.sh REFUSAL takes. The reason travels on
# stdout whatever the status (src/watch.ts watchLog - stderr carries the arm log and
# "NEVER stdout: that channel carries the exit reason and nothing else").
stub_watch_refusal() {
  : >"$TMP/watch.calls"
  cat >"$lab/ac-watch.sh" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$TMP/watch.calls"
printf '%s\n' '$2'
exit $1
EOF
  chmod +x "$lab/ac-watch.sh"
}

# run_hook -> exit code, with stderr captured to $TMP/hook.err
run_hook() {
  local rc=0
  ( cd "$AC_HOME" && printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
      | "$hook" >"$TMP/hook.out" 2>"$TMP/hook.err" ) || rc=$?
  printf '%s\n' "$rc"
}

inflight_meta() { printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/$1.meta"; }

# TRACE (state/.stop-hooks.log, stop-hooks-had-zero-effect-and-leave-no-trace):
# every branch below that reaches a real verdict appends one durable,
# file-only line - see last_trace/trace_lines below and hookTrace in
# src/lib.ts (linked beside $lab above, so the hook resolves the SAME function
# it would in production).
trace_log="$AC_HOME/state/.stop-hooks.log"
last_trace() { tail -n 1 "$trace_log" 2>/dev/null; }
trace_lines() { wc -l <"$trace_log" 2>/dev/null | tr -d ' '; }

# The home must look like a primary checkout, or the scope test exits 0 first.
git -C "$AC_HOME" init -q . 2>/dev/null || true
git -C "$AC_HOME" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null || true

# --- nothing owed -----------------------------------------------------------
# No crew, no remote transport: the hook must not arm anything at all.
rm -f "$trace_log"
stub_watch 'heartbeat'
assert_eq "$(run_hook)" "0" "an idle fleet arms nothing"
assert_eq "$(trace_lines)" "1" "A2/R4: autoarm's owed || exit 0 is traced - one line, not zero"
assert_contains "$(last_trace)" "hook=watch-autoarm" "the line names the hook"
assert_contains "$(last_trace)" "verdict=stood-aside" "and the nothing-owed stand-aside"
assert_contains "$(last_trace)" "reason=nothing-owed" "...distinguishably from every other stand-aside"

# A live roomchief is owed the FLEET watcher - its pane reports to the
# crewchief - so the crewchief's hook arms for it; the roomchief's own scoped
# hook does not count its own pane, which its scoped watcher never covers.
printf 'kind=roomchief\n' >"$AC_HOME/state/famR-chief.meta"
stub_watch 'report:famR-chief'
assert_eq "$(run_hook)" "2" "a live roomchief is supervision owed to the fleet session"
rc=0
( cd "$AC_HOME" && printf '{}' | AC_SCOPE=famR "$hook" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "...but not to its own scoped session"
assert_contains "$(last_trace)" "reason=nothing-owed" "...which stands aside as nothing owed"
rm -f "$AC_HOME/state/famR-chief.meta"

# A SOLO session (AC_SOLO=1) NEVER arms: supervision is the chief's obligation,
# and a solo hook that took the watcher would steal the chief's wake channel.
# It also never reaches a supervision verdict - untraced (see header TRACE).
inflight_meta tsolo
stub_watch 'report:tsolo'
rm -f "$trace_log"
rc=0
( cd "$AC_HOME" && printf '{}' | AC_SOLO=1 "$hook" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a solo session declines silently even with crew in flight"
assert_eq "$(calls)" "0" "...and never runs the watcher"
assert_no_file "$trace_log" "a solo session owes no supervision, so it writes no trace line either"
rm -f "$AC_HOME"/state/tsolo.meta
assert_eq "$(calls)" "0" "and never calls the watcher"

# --- an argument is a hand run, never a firing ------------------------------
# The Stop hook passes none, and a hand run from the chief's own tool passes
# the lock-holder ancestry test - so `--help` would hold that tool call inside
# the owed-loop for the whole budget.
inflight_meta targs
stub_watch 'report:targs'
for a in --help -h; do
  rc=0
  ( cd "$AC_HOME" && printf '{}' | "$hook" "$a" >"$TMP/hook.out" 2>"$TMP/hook.err" ) || rc=$?
  assert_eq "$rc" "0" "$a exits 0"
  assert_contains "$(cat "$TMP/hook.out")" "Stop-hook watcher continuity" "$a prints the header"
done
# The module refuses it with 1, which the fail-open shim answers 0 (F7, named
# in the differential leg below); the refusal line and the empty call log are
# the contract.
rc=0
( cd "$AC_HOME" && printf '{}' | "$hook" --bogus >/dev/null 2>"$TMP/hook.err" ) || rc=$?
assert_eq "$rc" "0" "an unknown argument is refused"
assert_contains "$(cat "$TMP/hook.err")" "--bogus" "...naming it"
assert_eq "$(calls)" "0" "no argument ever reaches the watcher"
rm -f "$AC_HOME"/state/targs.meta

# --- an actionable close is translated into a wake --------------------------
inflight_meta t1
stub_watch 'report:t1'
rm -f "$trace_log"
assert_eq "$(run_hook)" "2" "an actionable close wakes the chief"
assert_contains "$(cat "$TMP/hook.err")" "report:t1" "the reason reaches the chief verbatim"
assert_contains "$(cat "$TMP/hook.err")" "ac-wake-drain.sh" "and it names the next move"
assert_eq "$(trace_lines)" "2" "R5: a firing that enters the owed-loop traces TWICE - its start (a) and its end (b)"
assert_contains "$(sed -n '1p' "$trace_log")" "verdict=armed" "(a) the START line: this firing decided to run the watch loop"
assert_contains "$(sed -n '2p' "$trace_log")" "verdict=handed-back" "(b) the END line: how it closed"
assert_contains "$(sed -n '2p' "$trace_log")" "reason=actionable-close" "...naming the branch"
assert_contains "$(sed -n '2p' "$trace_log")" "detail=report:t1" "R1: the file may carry what stderr also carries - this is the FILE, never stdout/stderr itself"
# R1: the trace write must not touch this invocation's own stdout/stderr - the
# chief-facing reason must be byte-for-byte what it was before the trace
# existed.
assert_eq "$(cat "$TMP/hook.out")" "" "R1: stdout carries nothing (ac-watch-autoarm.sh never writes it)"
assert_eq "$(cat "$TMP/hook.err")" \
  "$(printf 'ac-watch-autoarm: report:t1\nac-watch-autoarm: drain it (bin/ac-wake-drain.sh); the watcher is re-armed automatically at your next turn end.\n')" \
  "R1: stderr is exactly the hook's own two lines, nothing from the trace"

# --- heartbeat re-arms SILENTLY, which is the whole point -------------------
# Three heartbeats then a real signal: the chief is woken ONCE, at the signal,
# and the watcher was re-armed in between with no turn spent.
stub_watch 'heartbeat' 'heartbeat' 'heartbeat' 'ask:t1'
assert_eq "$(run_hook)" "2" "the hook keeps going until something actionable"
assert_eq "$(calls)" "4" "each heartbeat re-armed the watcher in-process"
assert_contains "$(cat "$TMP/hook.err")" "ask:t1" "only the actionable close is reported"
case "$(cat "$TMP/hook.err")" in *heartbeat*) fail "a heartbeat must never reach the chief" ;; esac

# ...but never over a record already in this session's spool: a push that
# lands while the watcher is mid-cycle finds no sleep to interrupt, the
# watcher closes heartbeat, and the NEXT watcher's arm snapshot files that
# record as old backlog - a silent re-arm would sit on it for the whole budget.
cat >"$lab/ac-watch.sh" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$TMP/watch.calls"
mkdir -p "$AC_HOME/state/.wake-spool"
printf '3\treport\tt9\tdone: pushed mid-cycle\n' >"$AC_HOME/state/.wake-spool/9.1.000000"
printf 'heartbeat\n'
EOF
chmod +x "$lab/ac-watch.sh"; : >"$TMP/watch.calls"
rc=0
( cd "$AC_HOME" && printf '{}' | AC_AUTOARM_BUDGET=5 AC_HEARTBEAT=1 "$hook" >/dev/null 2>"$TMP/hook.err" ) || rc=$?
assert_eq "$rc" "2" "a record left in the spool by the closing cycle hands back"
assert_eq "$(calls)" "1" "...at once, not after re-arming over it: $(cat "$TMP/hook.err")"
assert_contains "$(cat "$TMP/hook.err")" "queued wakes" "...naming the queued wake"
rm -rf "$AC_HOME/state/.wake-spool"

# --- another watcher already holds the singleton ----------------------------
rm -f "$trace_log"
stub_watch 'already running'
assert_eq "$(run_hook)" "0" "the hook stands out of a live watcher's way"
assert_eq "$(trace_lines)" "2" "A2: this firing also armed then stood aside - both traced"
assert_contains "$(sed -n '2p' "$trace_log")" "verdict=stood-aside" "A2: stood-aside-because-a-watcher-is-live"
assert_contains "$(sed -n '2p' "$trace_log")" "reason=already-running" "...distinguishably from nothing-owed"

# --- a config-swap refusal is a LIVE watcher, not an absent one -------------
# ac-watch.sh refuses a second arm carrying a DIFFERENT AC_WATCH_SKIP than the
# running singleton (ac-watch.sh's config-aware re-arm refusal, exit 2). It reaches that branch only when
# the lock is held by a LIVE process - a dead or stale one is reclaimed first -
# so the refusal carries exactly the fact `already running` carries, and the
# hook must stand aside instead of reporting the watcher absent.
stub_watch_refusal 2 'refused: a live watcher (pid 55739) holds a DIFFERENT watch-config (running AC_WATCH_SKIP=[], new AC_WATCH_SKIP=[fam]); release THAT ONE with: bin/ac-watch.sh --release 55739'
assert_eq "$(run_hook)" "0" "a config-swap refusal stands aside: the singleton is alive"
assert_eq "$(cat "$TMP/hook.err")" "" "and a beating watcher is never reported as missing"

# --- every OTHER refusal still reaches the chief, with its own reason -------
# The owner gate (another session holds the home, ac-watch.sh's `refused: fleet watcher not armed` branch) refuses with
# NOTHING armed: that one must still wake the chief, and say why.
stub_watch_refusal 2 'refused: fleet watcher not armed - another session owns this home'
assert_eq "$(run_hook)" "2" "a refusal that armed nothing wakes the chief"
assert_contains "$(cat "$TMP/hook.err")" "another session owns this home" "with the refusal's own reason"

# --- a watcher that dies mute is reported whatever its exit status ----------
stub_watch_refusal 3 ''
assert_eq "$(run_hook)" "2" "a mute non-zero close still hands coverage back"
assert_contains "$(cat "$TMP/hook.err")" "NOT covered" "and still says coverage is not in place"

# --- a mute watcher is handed back, never spun on ---------------------------
rm -f "$trace_log"
stub_watch ''
assert_eq "$(run_hook)" "2" "a watcher that closed with no reason hands back"
assert_contains "$(cat "$TMP/hook.err")" "NOT covered" "and says coverage is not in place"
assert_eq "$(calls)" "1" "it does not retry a mute watcher"
assert_contains "$(last_trace)" "verdict=handed-back" "the mute close is traced as handed-back"
assert_contains "$(last_trace)" "reason=no-reason-line" "...distinguishably from an actionable close"

# --- the budget is bounded, and running out is REPORTED ---------------------
# With crew still in flight, a spent budget must wake the chief rather than
# let coverage lapse in silence.
rm -f "$trace_log"
stub_watch 'heartbeat'
rc=0
( cd "$AC_HOME" && printf '{}' | AC_AUTOARM_BUDGET=0 "$hook" >/dev/null 2>"$TMP/hook.err" ) || rc=$?
assert_eq "$rc" "2" "a spent budget with crew in flight hands coverage back"
assert_contains "$(cat "$TMP/hook.err")" "budget spent" "and says so"
assert_contains "$(cat "$TMP/hook.err")" "crew still in flight" \
  "and names the crew-in-flight branch specifically"
assert_contains "$(last_trace)" "verdict=handed-back" "the budget handback is traced too"
assert_contains "$(last_trace)" "reason=budget-spent-crew-in-flight" "...naming the branch that actually fired"

# The budget bounds the LAST arm too: an arm lasts at least AC_HEARTBEAT, so
# one started with less than that left can run past the hook's own timeout,
# and a hook killed at its timeout wakes nobody.
stub_watch 'heartbeat' 'heartbeat' 'ask:t1'
rc=0
( cd "$AC_HOME" && printf '{}' | AC_AUTOARM_BUDGET=100 AC_HEARTBEAT=600 "$hook" >/dev/null 2>"$TMP/hook.err" ) || rc=$?
assert_eq "$rc" "2" "a budget too short for another arm hands coverage back"
assert_eq "$(calls)" "0" "no arm starts that could not end inside the budget, the first one included"
assert_contains "$(cat "$TMP/hook.err")" "budget spent" "and the handback says why"

# --- the same exhaustion, but owed() fires on its OTHER branch --------------
# owed() is also true with ZERO crew in flight when unscoped and standing
# remote-poll coverage is wired (config/remote-poll executable). The message
# above would be a fabrication here - the crewchief burned two turns hunting
# crew that did not exist because the old message named "crew still in
# flight" unconditionally.
rm -f "$AC_HOME"/state/*.meta
printf '#!/usr/bin/env bash\n' >"$AC_HOME/config/remote-poll"
chmod +x "$AC_HOME/config/remote-poll"
rm -f "$trace_log"
stub_watch 'heartbeat'
rc=0
( cd "$AC_HOME" && printf '{}' | AC_AUTOARM_BUDGET=0 "$hook" >/dev/null 2>"$TMP/hook.err" ) || rc=$?
assert_eq "$rc" "2" "a spent budget with only standing remote-poll coverage still hands coverage back"
assert_contains "$(cat "$TMP/hook.err")" "budget spent" "and says so"
assert_contains "$(cat "$TMP/hook.err")" "remote-poll" \
  "and names the remote-poll branch, not crew"
case "$(cat "$TMP/hook.err")" in
  *"crew still in flight"*) fail "no crew is in flight; the message must not claim there is" ;;
esac
assert_contains "$(last_trace)" "reason=budget-spent-remote-poll" \
  "the trace also names the remote-poll branch specifically, not crew"
rm -f "$AC_HOME/config/remote-poll"
# Restore the crew-in-flight precondition the next test depends on - this
# block's own `rm -f state/*.meta` above must not silently defang it.
inflight_meta t1

# --- work that finished during the loop ends the hook quietly ---------------
# heartbeat, and by the next predicate check the meta is gone: nothing is owed,
# so there is nothing to tell the chief.
cat >"$lab/ac-watch.sh" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$TMP/watch.calls"
rm -f "$AC_HOME/state/t1.meta"
printf 'heartbeat\n'
EOF
chmod +x "$lab/ac-watch.sh"
: >"$TMP/watch.calls"
rm -f "$trace_log"
assert_eq "$(run_hook)" "0" "work finishing mid-loop ends the hook silently"
assert_eq "$(cat "$TMP/hook.err")" "" "with nothing said to the chief"
assert_contains "$(last_trace)" "verdict=stood-aside" "...but it is still traced: nothing left to supervise"
assert_contains "$(last_trace)" "reason=work-finished" "...distinguishably from every other stand-aside"

# --- the arm ENV is reconstructed per session kind ---------------------------
# A chief arming by hand sets AC_WATCH_SKIP=<promoted families> on the FLEET
# watcher and AC_WATCH_ONLY=<watch set> on a scoped one (rooms-threads skill).
# With the hook owning the arm, an UNSKIPPED fleet watcher covers a promoted
# family's panes alongside that family's own scoped watcher, and the two share
# the per-id dedup marker - so the family's wake lands in whichever spool won
# the race instead of the one its roomchief drains.
# DISPUTED: the session's scope (unscoped crewchief vs AC_SCOPE=famA roomchief).
# HELD-CONSTANT: the home, the promoted metas, the in-flight crew meta, the
# stub watcher and the close it prints.
rm -f "$AC_HOME"/state/*.meta
inflight_meta t9
printf 'kind=roomchief\n' >"$AC_HOME/state/famB-chief.meta"
printf 'kind=roomchief\n' >"$AC_HOME/state/famA-chief.meta"
printf 'kind=ship\n' >"$AC_HOME/state/notachief.meta"
stub_watch_env 'report:t9'
assert_eq "$(run_hook)" "2" "the unscoped arm still translates its close"
assert_eq "$(cat "$TMP/watch.env.skip")" "famA,famB" \
  "the crewchief arm carries the promoted families as AC_WATCH_SKIP"
assert_eq "$(cat "$TMP/watch.env.only")" "" \
  "... and never an AC_WATCH_ONLY, which would scope the fleet watcher"

stub_watch_env 'report:t9'
printf '## In flight\n- [ ] famA - a promoted family (repo: p, since 2026-07-27)\n- [ ] famA-s1 epic:famA - a story (repo: p, since 2026-07-27)\n' \
  >"$AC_HOME/records/backlog.md"
rc=0
( cd "$AC_HOME" && printf '{}' | AC_SCOPE=famA "$hook" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "2" "the scoped arm still translates its close"
assert_eq "$(cat "$TMP/watch.env.only")" "famA,famA-s1" \
  "a roomchief arms with its own watch set - its family and its in-flight stories"
assert_eq "$(cat "$TMP/watch.env.skip")" "" \
  "... and never a skip: a scoped watcher exists to cover that family"

# The scoped exit-2 handback ALSO types the wake into its own chief pane.
# asyncRewake delivery is a harness contract (measured on Claude Code 2.1.220;
# the host has moved on): when the rewake is swallowed the chief sleeps on a
# durable spool (measured: 101 minutes, woken by a human). A keystroke is a
# turn on every backend; with no pane on the meta or no herdr to type through
# the nudge fails silently - the scoped exit-2 case above proves that
# fail-open by running with neither.
make_fake_herdr
printf 'kind=roomchief\nwindow=crew:famA-chief\nbackend=herdr\n' >"$AC_HOME/state/famA-chief.meta"
printf 'pFAC tFAC\n' >"$AC_HOME/state/.pane-famA-chief"
printf 'pFAC\n' >"$FAKE_HERDR/tabs/tFAC"
: >"$FAKE_HERDR/panes/pFAC.buf"
stub_watch_env 'report:t9'
rc=0
( cd "$AC_HOME" && printf '{}' | AC_SCOPE=famA "$hook" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "2" "the nudging handback still exits 2"
assert_contains "$(cat "$(fake_pane_buf famA-chief)")" "wake:" \
  "the scoped handback types the wake into its own chief pane"

# A demoted family drops off the set at the very next re-arm, because the set is
# recomputed from the live chief metas on every pass - the same reason the
# scoped arm recomputes its watch set.
rm -f "$AC_HOME/state/famA-chief.meta"
stub_watch_env 'report:t9'
assert_eq "$(run_hook)" "2" "the arm keeps translating after a demote"
assert_eq "$(cat "$TMP/watch.env.skip")" "famB" \
  "a demoted family leaves the skip at the next re-arm"
rm -f "$AC_HOME"/state/*.meta

# --- every arm this hook owns is MARKED BOUNDED ------------------------------
# rearm-stands-aside-for-a-watcher-that-then-exits: the watcher this hook arms
# runs in the FOREGROUND of one Stop-hook firing and dies with it at the budget
# handback; a chief's hand arm is a harness background task and carries no such
# bound. ac-watch.sh cannot tell the two owners apart unless it is told, and
# until it was, a chief's re-arm read `already running` for a watcher this hook
# was about to retire. MEASURED 2026-08-06, one instrumented run, every stamp
# taken from the process that produced it: the hand arm printed `already
# running` at T+0 with the incumbent LIVE -> the incumbent's beacon stand-down
# at T+2.513s -> this hook's budget handback at T+2.536s -> the turn-end guard
# blocking on the stood-down beacon at T+2.602s.
# BOTH branches of owed() are covered, because BOTH arm a bounded watcher: crew
# in flight is the PRIMARY case (an uncovered turn costs a crewmate's
# done/blocked wake, the supervision guarantee the watcher exists for) and
# standing remote-poll coverage with zero crew is the secondary one.
# DISPUTED: which branch of owed() fired.
# HELD-CONSTANT: the home, the session kind (unscoped), the stub watcher and the
# close it prints, and the hook invocation.
inflight_meta t7
stub_watch_env 'report:t7'
assert_eq "$(run_hook)" "2" "the crew-in-flight arm still translates its close"
assert_eq "$(cat "$TMP/watch.env.autoarm")" "1" \
  "the crew-in-flight arm is marked bounded, so a chief's hand arm is never told that coverage is its own"

rm -f "$AC_HOME"/state/*.meta
printf '#!/usr/bin/env bash\n' >"$AC_HOME/config/remote-poll"
chmod +x "$AC_HOME/config/remote-poll"
stub_watch_env 'remote:r1'
assert_eq "$(run_hook)" "2" "the standing remote-poll arm still translates its close"
assert_eq "$(cat "$TMP/watch.env.autoarm")" "1" \
  "... and the idle fleet's arm is marked bounded too: its coverage dies with this firing just the same"
rm -f "$AC_HOME/config/remote-poll"

# The flag must not change what THIS hook reads back. A firing standing aside
# from a PREDECESSOR firing's watcher still classifies on the `already running`
# prefix and exits 0 - ac-watch.sh keeps that path untouched for an arm that
# carries AC_AUTOARM, which is the whole reason the discriminator is the CALLER
# and not the incumbent alone.
inflight_meta t7
stub_watch 'already running - pending: your inbox is empty - nothing waiting'
assert_eq "$(run_hook)" "0" "a marked arm still stands aside from a live predecessor"
assert_eq "$(cat "$TMP/hook.err")" "" "... and still says nothing to the chief"
rm -f "$AC_HOME"/state/*.meta

# --- not the lock holder: an unscoped session stands aside, traced ----------
# The symmetric case of ac-turnend-guard.sh's read-only-lock exemption (R4
# names that one explicitly as a stand-aside verdict that MUST be traced -
# this hook's own analog gets the same treatment). A live FOREIGN pid holds
# the lock - hold_open/hold_close (helpers.sh) stand in for it.
rm -rf "$AC_HOME"/state/*.meta
inflight_meta t8
rm -f "$trace_log"
hold_open aalockhold; aalockpid=$HOLD_PID
printf 'pid=%s\nsince=now\n' "$aalockpid" >"$AC_HOME/state/.session-lock"
run_hook >/dev/null
hold_close aalockhold "$aalockpid"
rm -f "$AC_HOME/state/.session-lock"
assert_eq "$(trace_lines)" "1" "not-lock-holder is a single early stand-aside, never entering the owed-loop"
assert_contains "$(last_trace)" "verdict=stood-aside" "...and it is traced"
assert_contains "$(last_trace)" "reason=not-lock-holder" "...distinguishably from every other stand-aside"
rm -f "$AC_HOME"/state/t8.meta

# --- a scoped session whose family was demoted stands aside, traced ---------
# rearm-outlives-its-own-family: the chief meta is the family's liveness: its
# absence means this firing's own family is gone and it must not arm for
# another family's crew.
rm -f "$trace_log"
rc=0
( cd "$AC_HOME" && printf '{}' | AC_SCOPE=famghost "$hook" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a scoped hook whose family has no live chief meta stands aside"
assert_eq "$(trace_lines)" "1" "one line, traced before entering the owed-loop"
assert_contains "$(last_trace)" "verdict=stood-aside" "...stood-aside"
assert_contains "$(last_trace)" "reason=family-demoted" "...distinguishably named"

# --- scope: a crewmate's linked worktree is never armed from ----------------
inflight_meta t2
stub_watch 'report:t2'
linked="$TMP/linked"
git -C "$AC_HOME" worktree add -q --detach "$linked" HEAD 2>/dev/null
if [ -d "$linked" ]; then
  rc=0
  ( cd "$linked" && printf '{}' | AC_HOME="$linked" "$hook" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$rc" "0" "a linked worktree (crewmate) never arms the fleet watcher"
  assert_no_file "$linked/state/.stop-hooks.log" "R4: a linked worktree must never write a trace line"
fi

# --- a crewdeputy home arms its own watcher, like any fleet home -----------
# A crewdeputy is a chief running its own home; its crew is its own to cover.
rm -f "$trace_log"
touch "$AC_HOME/.ac-crewdeputy-home"
assert_eq "$(run_hook)" "2" "a crewdeputy home with crew in flight is supervision owed to its own session"
assert_contains "$(last_trace)" "verdict=" "...and the verdict is traced"
rm -f "$AC_HOME/.ac-crewdeputy-home"

# --- fail open: a broken dependency must never wedge the harness ------------
rm -f "$trace_log"
mv "$lab/ac-watch.sh" "$lab/ac-watch.sh.away"
assert_eq "$(run_hook)" "2" "a missing watcher is reported, not swallowed"
assert_contains "$(last_trace)" "verdict=handed-back" \
  "A5: a broken dependency is still traceable, and never changes the hook's own verdict"
mv "$lab/ac-watch.sh.away" "$lab/ac-watch.sh"
# The floor the original's missing ac-lib.sh was is now a module that cannot
# load: the shim answers 0 before anything could resolve a home.
rm -f "$trace_log"
mv "$labroot/src" "$labroot/src.away"
mkdir "$labroot/src"
printf 'throw new Error("autoarm cannot load");\n' >"$labroot/src/watch-autoarm.ts"
assert_eq "$(run_hook)" "0" "a module that cannot load fails OPEN"
assert_no_file "$trace_log" "R4: nothing can trace when the module cannot load - the honest floor"
rm -rf "$labroot/src"
mv "$labroot/src.away" "$labroot/src"

# --- the real watcher -----------------------------------------------------------
# Every row above stubs ac-watch.sh; this one runs the real entry - the shim and
# the module it execs - under the hook, so the line the hook classifies is the
# watcher's own: a crewmate with no pane on record reads `gone:` and is handed
# back.
if command -v bun >/dev/null 2>&1; then
  rm -f "$AC_HOME"/state/*.meta "$trace_log"
  inflight_meta treal
  printf '#!/bin/sh\nexec "%s/ac-watch.sh" "$@"\n' "$BIN" >"$lab/ac-watch.sh"
  chmod +x "$lab/ac-watch.sh"
  rc="$(AC_LOCK_PID=$$ AC_POLL=1 AC_HEARTBEAT=30 run_hook)"
  assert_eq "$rc" "2" "the real watcher's actionable close is handed back"
  assert_contains "$(cat "$TMP/hook.err")" "ac-watch-autoarm: gone:treal" "the hook relays the real watcher's reason line"
  assert_contains "$(last_trace)" "detail=gone:treal" "...and traces it"
  assert_contains "$(cat "$AC_HOME/state/treal.status")" "failed: window gone" "the real watcher ran its pane pass"
  assert_no_file "$AC_HOME/state/.watch.lock.d" "and released its lock on the way out"
fi

# --- differential: src/watch-autoarm.ts against the frozen bash original -----
# DISPUTED: the implementation (tests/fixtures/ac-watch-autoarm.sh under bash vs src/watch-autoarm.ts through bin/ac-watch-autoarm.sh)
# HELD-CONSTANT: two side roots seeded alike ($AO for the oracle, $AN for the shim) - a root whose bin/ holds every live script (the oracle's entry the frozen original) beside a stub ac-watch.sh scripted per row (logging each call and the arm env it saw) and an ac-ready.sh wrapper of the live one, its src/ linked; a git-inited home at <side>/home; a stub dir <side>/stub first on PATH (`date -u +%s` answering <side>/stub/clock with the status in <side>/stub/clock.rc, the ISO stamp fixed, a herdr logging every call and answering only send-text); the cwd the home; stdin the Stop payload; env scrubbed of every knob the hook, the backend driver and the stub read, then AC_HOME=<side>/home, AC_SEND_SETTLE=0 and the row's; LC_ALL=C on both sides; exit status, stdout, stderr, the trace log, the watcher's call log, the herdr send-text lines and the state/ listing compared whole (the side root spelled ROOT, a temp's pid PID).
aobin="$(make_oracle_bin ac-watch-autoarm)"
cmp -s "$aobin/ac-watch-autoarm.sh" "$ROOT/tests/fixtures/ac-watch-autoarm.sh" \
  || fail "the oracle bin must hold the frozen original"
AO="$TMP/aa-o"; AN="$TMP/aa-n"
aa_side() {  # aa_side <side root> <bin to copy> - the root, its home and its stubs
  local s="$1"
  mkdir -p "$s/root/bin" "$s/home/state" "$s/home/config" "$s/home/records" "$s/stub"
  cp "$2"/*.sh "$s/root/bin/"
  rm "$s/root/bin/ac-watch.sh"
  ln -s "$ROOT/src" "$s/root/src"
  printf '#!/bin/sh\nexec "%s/ac-ready.sh" "$@"\n' "$BIN" >"$s/root/bin/ac-ready.sh"
  printf '#!/bin/sh\ncase "$*" in\n  *%%s*) cat "%s/stub/clock"; exit "$(cat "%s/stub/clock.rc")" ;;\n  *%%Y*) printf "2026-10-10T00:00:00Z\\n" ;;\n  *) exec /bin/date "$@" ;;\nesac\n' "$s" "$s" >"$s/stub/date"
  printf '#!/bin/sh\nprintf "herdr %%s\\n" "$*" >>"%s/stub/herdr.log"\ncase "$1 $2" in "pane send-text") exit 0 ;; esac\nexit 1\n' "$s" >"$s/stub/herdr"
  chmod +x "$s/root/bin/ac-ready.sh" "$s/stub/date" "$s/stub/herdr"
  git -C "$s/home" init -q . 2>/dev/null
  git -C "$s/home" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
}
aa_side "$AO" "$aobin"; aa_side "$AN" "$BIN"
AA_ARGS=()
aa_each() {  # aa_each <shell text> - run <text> once per side, SIDE spelled as that side's root
  local s
  for s in "$AO" "$AN"; do bash -c "${1//SIDE/$s}" || fail "aa_each: seeding failed on $s: $1"; done
}
aa_fresh() {  # a fresh world: no metas, spools, lock, records, remote-poll; the clock at T, status 0
  aa_each 'rm -rf SIDE/home/state SIDE/home/records SIDE/home/config SIDE/home/.ac-crewdeputy-home SIDE/calls SIDE/stub/herdr.log
    mkdir -p SIDE/home/state SIDE/home/records SIDE/home/config
    printf "1700000000\n" >SIDE/stub/clock; printf 0 >SIDE/stub/clock.rc
    cp '"$BIN"'/ac-backend.sh '"$BIN"'/ac-backend-orca.sh SIDE/root/bin/'
}
aa_stub() {  # aa_stub <body> - every side's ac-watch.sh: log the call and its arm env, then <body>
  aa_each 'printf "%s\n" "#!/usr/bin/env bash" "printf \"call skip=[%s] only=[%s] autoarm=[%s]\\n\" \"\${AC_WATCH_SKIP-unset}\" \"\${AC_WATCH_ONLY-unset}\" \"\${AC_AUTOARM-unset}\" >>SIDE/calls" >SIDE/root/bin/ac-watch.sh
    cat >>SIDE/root/bin/ac-watch.sh <<'"'AA_BODY'"'
'"$1"'
AA_BODY
    chmod +x SIDE/root/bin/ac-watch.sh'
}
aa_lines() {  # aa_lines <line...> - the stub prints the next line per call, the last one again past the end, and a numeric clock moves 1000s on
  local l
  : >"$TMP/aa.script"
  for l in "$@"; do printf '%s\n' "$l" >>"$TMP/aa.script"; done
  aa_stub "n=\$(wc -l <SIDE/calls | tr -d ' '); line=\"\$(sed -n \"\${n}p\" $TMP/aa.script)\"; [ -n \"\$line\" ] || line=\"\$(tail -n 1 $TMP/aa.script)\"; printf '%s\\n' \"\$line\"
c=\"\$(cat SIDE/stub/clock)\"; case \"\$c\" in '' | *[!0-9]*) ;; *) printf '%s\\n' \"\$((c + 1000))\" >SIDE/stub/clock ;; esac"
}
aa_run() {  # aa_run <side root> <o|n> [env words...] - one firing, the call and herdr logs fresh; its status in $TMP/aa.<o|n>.rc
  local s="$1" p="$2" x v rc=0
  shift 2
  rm -f "$s/calls" "$s/stub/herdr.log"
  local e=(LC_ALL=C "PATH=$s/stub:$PATH" "AC_HOME=$s/home" AC_SEND_SETTLE=0)
  for x in "$@"; do v="${x#*=}"; e+=("${x%%=*}=${v//SIDE/$s}"); done
  (cd "$s/${AA_CWD:-home}" && printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
    | env -u AC_SOLO -u AC_SCOPE -u AC_HOME -u AC_FLEET_STATE -u AC_BACKEND -u AC_AUTOARM -u AC_AUTOARM_BUDGET \
        -u AC_HEARTBEAT -u AC_STOPHOOK_LOG_KEEP -u AC_WATCH_SKIP -u AC_WATCH_ONLY -u AC_HERDR_SESSION \
        -u AC_HERDR_RPC_TIMEOUT -u AC_SEND_UNPROVEN -u AC_LOCK_PID "${e[@]}" \
        perl -e 'alarm 60; exec @ARGV' "$s/root/bin/ac-watch-autoarm.sh" ${AA_ARGS[@]+"${AA_ARGS[@]}"}) \
    >"$TMP/aa.$p.out" 2>"$TMP/aa.$p.err" || rc=$?
  printf '%s' "$rc" >"$TMP/aa.$p.rc"
}
aa_norm() { LC_ALL=C sed -e "s#$1#ROOT#g" -E -e 's/\.tmp\.[0-9]+(\.[0-9]+)?/.tmp.PID/g'; }
aa_snap() {  # aa_snap <side root> - the trace, the watcher's calls, herdr's send-text lines, state/
  local s="$1"
  printf '== trace\n'; cat "$s/home/state/.stop-hooks.log" 2>/dev/null || printf '(none)\n'
  printf '== calls\n'; cat "$s/calls" 2>/dev/null || printf '(none)\n'
  printf '== herdr\n'; sed -n '/send-text/p' "$s/stub/herdr.log" 2>/dev/null || true
  printf '== state\n'; (cd "$s/home/state" 2>/dev/null && ls -A) || printf '(no state/)\n'
}
aa_both() {  # aa_both [env words...] - one firing per side, both answers normalized
  aa_run "$AO" o "$@"; aa_run "$AN" n "$@"
  aa_norm "$AO" <"$TMP/aa.o.out" >"$TMP/aa.o.out2"; aa_norm "$AO" <"$TMP/aa.o.err" >"$TMP/aa.o.err2"
  aa_norm "$AN" <"$TMP/aa.n.out" >"$TMP/aa.n.out2"; aa_norm "$AN" <"$TMP/aa.n.err" >"$TMP/aa.n.err2"
  if [ "${AA_NOISE:-0}" = 1 ]; then
    # Named (SHELL-OWN STDERR): bash's own `<script>: line N: ...` lines.
    /usr/bin/grep -Eq '^ROOT/root/bin/[^ ]*: line [0-9]+: ' "$TMP/aa.o.err2" || fail "differential: no shell noise to drop ($*)"
    LC_ALL=C sed -E '/^ROOT\/root\/bin\/[^ ]*: line [0-9]+: /d' "$TMP/aa.o.err2" >"$TMP/aa.o.err3"
    mv "$TMP/aa.o.err3" "$TMP/aa.o.err2"
  fi
  aa_snap "$AO" | aa_norm "$AO" >"$TMP/aa.o.snap"; aa_snap "$AN" | aa_norm "$AN" >"$TMP/aa.n.snap"
}
aa_same() {  # aa_same <want rc> [env words...] - both sides answer alike, and the status is <want rc>
  local want="$1"
  shift
  aa_both "$@"
  assert_eq "$(cat "$TMP/aa.n.rc")" "$(cat "$TMP/aa.o.rc")" "differential exit ($*)"
  assert_eq "$(cat "$TMP/aa.n.rc")" "$want" "differential verdict ($*)"
  cmp -s "$TMP/aa.o.out2" "$TMP/aa.n.out2" || fail "differential stdout differs ($*): $(diff "$TMP/aa.o.out2" "$TMP/aa.n.out2" | head -n 6)"
  cmp -s "$TMP/aa.o.err2" "$TMP/aa.n.err2" || fail "differential stderr differs ($*): $(diff "$TMP/aa.o.err2" "$TMP/aa.n.err2" | head -n 6)"
  cmp -s "$TMP/aa.o.snap" "$TMP/aa.n.snap" || fail "differential files differ ($*): $(diff "$TMP/aa.o.snap" "$TMP/aa.n.snap" | head -n 8)"
}
aa_meta() {  # aa_meta <id> <body printf format> - the same meta on both sides
  aa_each "printf '$2' >SIDE/home/state/$1.meta"
}

# 1. scope: who arms at all.
aa_fresh; aa_lines 'report:t1'
aa_same 0
aa_meta t1 'kind=ship\nproject=p\n'
aa_same 2
aa_same 0 AC_SOLO=1
aa_same 2 AC_SOLO=0
aa_same 0 AC_HOME=
aa_same 0 AC_HOME=SIDE/nowhere
# A relative AC_HOME from a caller cwd with no name: the original's cd from
# there reached nothing; bun sits in the distro root then, and must not resolve
# the name against it (a home owing an arm is planted where it would land).
for s in "$AO" "$AN"; do
  mkdir -p "$s/root/rel/state" "$s/gone"
  printf 'kind=ship\n' >"$s/root/rel/state/t1.meta"
  rm -f "$s/calls"
  rc=0
  (cd "$s/gone" && rmdir "$s/gone" && printf '{}' | env -u AC_SOLO -u AC_SCOPE LC_ALL=C "PATH=$s/stub:$PATH" AC_HOME=rel \
    "$s/root/bin/ac-watch-autoarm.sh") >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "a relative home from a nameless cwd stands aside ($s)"
  assert_no_file "$s/root/rel/state/.stop-hooks.log" "a relative home from a nameless cwd is never traced ($s)"
  assert_no_file "$s/calls" "a relative home from a nameless cwd arms nothing ($s)"
  rm -rf "$s/root/rel"
done
aa_each 'rm -rf SIDE/home/state'
aa_same 0
aa_each 'mkdir SIDE/home/state; printf "kind=ship\n" >SIDE/home/state/t1.meta'
aa_each 'git -C SIDE/home worktree add -q --detach SIDE/linked HEAD 2>/dev/null; mkdir -p SIDE/linked/state; cp SIDE/home/state/t1.meta SIDE/linked/state/'
AA_CWD=linked aa_same 0 AC_HOME=SIDE/linked
aa_each 'touch SIDE/home/.ac-crewdeputy-home'
aa_same 2
aa_each 'mkdir -p SIDE/home/sub'
AA_CWD=home/sub aa_same 2 AC_HOME=SIDE/home/sub/..

# 2. the lock: an ancestor holds it, a stranger does, nobody does (W4: 0 and
#    -1 are process groups kill -0 always reaches).
aa_fresh; aa_lines 'report:t1'; aa_meta t1 'kind=ship\n'
for holder in "$$" "$$x" abc '' -2147483647 2147483648; do
  aa_each "printf 'pid=%s\nsince=now\n' '$holder' >SIDE/home/state/.session-lock"
  aa_same 2
done
hold_open aaholder; aaholdpid=$HOLD_PID
for holder in "$aaholdpid" " $$" 0 -1; do
  aa_each "printf 'since=now\npid=%s\npid=1\n' '$holder' >SIDE/home/state/.session-lock"
  aa_same 0
done
hold_close aaholder "$aaholdpid"
sh -c 'exit 0' & aadead=$!; wait "$aadead"
aa_each "printf 'pid=$aadead\n' >SIDE/home/state/.session-lock"
aa_same 2
aa_each 'printf "pid=1\n" >SIDE/home/state/.session-lock; chmod 000 SIDE/home/state/.session-lock'
aa_same 2
aa_each 'rm -f SIDE/home/state/.session-lock'

# 3. what supervision is owed to, and the scoped family's liveness.
aa_fresh; aa_lines 'report:x'
aa_meta v1 'kind=verify-qa\n'; aa_meta s1 'kind=self\n'; aa_meta d1 'kind=crewdeputy\n'
aa_meta .hidden 'kind=ship\n'
aa_same 0
aa_meta famR-chief 'kind=roomchief\n'
aa_same 2
aa_same 0 AC_SCOPE=famR
aa_same 0 AC_SCOPE=famghost
aa_each 'mkdir SIDE/home/state/x.meta'
aa_same 2 AC_SCOPE=famR
aa_each 'rmdir SIDE/home/state/x.meta; ln -s nowhere SIDE/home/state/dangling.meta'
aa_same 0 AC_SCOPE=famR
aa_meta t2 'kind=ship\n'; aa_meta t1 'kind=verify-x\n'
aa_each 'chmod 000 SIDE/home/state/t1.meta'
aa_same 2 AC_SCOPE=famR
aa_meta t3 'kind=self\0x\n'
aa_each 'rm -f SIDE/home/state/t2.meta; chmod 644 SIDE/home/state/t1.meta'
aa_same 0 AC_SCOPE=famR
aa_fresh; aa_lines 'report:x'
aa_each 'printf "#!/bin/sh\n" >SIDE/home/config/remote-poll; chmod +x SIDE/home/config/remote-poll'
aa_same 2
aa_same 0 AC_SCOPE=famR
aa_each 'chmod -x SIDE/home/config/remote-poll'
aa_same 0
aa_each 'rm SIDE/home/config/remote-poll; mkdir SIDE/home/config/remote-poll'
aa_same 2

# 4. how the watcher closed: the reason line classifies, never the status.
aa_fresh; aa_meta t1 'kind=ship\n'
for l in 'report:t1' 'already running' 'already running - pending: x' 'refused: a live watcher (pid 1) holds a DIFFERENT watch-config' \
         'refused: fleet watcher not armed - another session owns this home' '' ' heartbeat' 'heartbeatx' 'ALREADY RUNNING' '%s %d \n'; do
  aa_lines "$l"
  case "$l" in 'already running'* | 'refused: a live'*) want=0 ;; *) want=2 ;; esac
  aa_same "$want"
done
aa_lines 'heartbeat' 'heartbeat' 'ask:t1'
aa_same 2
aa_stub 'printf "one\n\nlast line\n\n\n"; exit 3'
aa_same 2
aa_stub 'printf "a\000b\351c"; exit 2'
aa_same 2
aa_stub 'printf "\n\n"; exit 0'
aa_same 2
aa_stub 'exit 1'
aa_same 2
aa_each 'rm SIDE/root/bin/ac-watch.sh'
aa_same 2
aa_each 'printf "#!/bin/sh\nexit 0\n" >SIDE/root/bin/ac-watch.sh'
aa_same 2
# the watcher's own stdin is the drained payload, and its stderr is dropped
aa_stub 'cat >SIDE/watch.stdin; printf "noise\n" >&2; printf "report:%s\n" "$(wc -c <SIDE/watch.stdin | tr -d " ")"'
aa_same 2

# 5. the heartbeat: silent re-arm, a queued wake, work finishing mid-loop.
aa_fresh; aa_meta t1 'kind=ship\n'
aa_stub 'mkdir -p SIDE/home/state/.wake-spool; printf "3\treport\tt9\tdone: x\n" >SIDE/home/state/.wake-spool/9.1.000000; printf "heartbeat\n"'
aa_same 2
aa_fresh; aa_meta famA-chief 'kind=roomchief\n'; aa_meta t1 'kind=ship\n'
aa_stub 'mkdir -p SIDE/home/state/.wake-spool.famA; printf "3\treport\tt9\tdone: x\n" >SIDE/home/state/.wake-spool.famA/9.1.000000; printf "heartbeat\n"'
aa_same 2 AC_SCOPE=famA
aa_fresh; aa_meta t1 'kind=ship\n'
aa_stub 'rm -f SIDE/home/state/t1.meta; printf "heartbeat\n"'
aa_same 0
aa_each 'printf "#!/bin/sh\n" >SIDE/home/config/remote-poll; chmod +x SIDE/home/config/remote-poll'
aa_meta t1 'kind=ship\n'
aa_stub 'rm -f SIDE/home/state/t1.meta; printf "%s\n" "$(( $(wc -l <SIDE/calls) )) " | sed "s/^1 $/heartbeat/; s/^2 $/remote:r1/"'
aa_same 2

# 6. the budget: the clock is date's, the sum bash's (W2), the handback named.
aa_fresh; aa_meta t1 'kind=ship\n'; aa_lines 'heartbeat' 'report:t1'
aa_same 2
for env in AC_AUTOARM_BUDGET=0 AC_AUTOARM_BUDGET=599 AC_AUTOARM_BUDGET=600 AC_AUTOARM_BUDGET= "AC_AUTOARM_BUDGET= 600 " \
           AC_AUTOARM_BUDGET=-1 AC_HEARTBEAT=3001 AC_HEARTBEAT=3000 AC_HEARTBEAT=-9999 AC_HEARTBEAT=010 AC_HEARTBEAT=0x10 \
           "AC_HEARTBEAT=64#z" AC_HEARTBEAT=; do
  aa_same 2 "$env"
done
aa_each 'printf "1700000000 \n" >SIDE/stub/clock'
aa_same 2
aa_each 'printf "" >SIDE/stub/clock'
aa_same 2
aa_each 'rm SIDE/home/state/t1.meta; printf "#!/bin/sh\n" >SIDE/home/config/remote-poll; chmod +x SIDE/home/config/remote-poll'
aa_same 2 AC_AUTOARM_BUDGET=0
AA_NOISE=1 aa_same 2 AC_AUTOARM_BUDGET=abc
AA_NOISE=1 aa_same 2 "AC_HEARTBEAT=1 2"
AA_NOISE=1 aa_same 2 AC_HEARTBEAT=09
AA_NOISE=1 aa_same 0 AC_HEARTBEAT=abc
aa_each 'printf "1 2\n" >SIDE/stub/clock'
AA_NOISE=1 aa_same 2
aa_each 'printf "abc\n" >SIDE/stub/clock'
AA_NOISE=1 aa_same 0
aa_each 'printf "1700000000\n" >SIDE/stub/clock; printf 2 >SIDE/stub/clock.rc'
AA_NOISE=1 aa_same 2 AC_HEARTBEAT=abc
aa_each 'printf 0 >SIDE/stub/clock.rc'

# 7. the arm env: skip, only, the bounded mark, rebuilt every pass.
aa_fresh; aa_lines 'heartbeat' 'report:t9'
aa_meta t9 'kind=ship\n'; aa_meta famB-chief 'kind=roomchief\n'; aa_meta famA-chief 'kind=roomchief\n'
aa_meta -chief 'kind=roomchief\n'; aa_meta famC-chief 'kind=ship\n'; aa_meta notachief 'kind=roomchief\n'
aa_same 2
aa_same 2 AC_WATCH_ONLY=inherited
aa_each 'printf "## In flight\n- [ ] famA - a promoted family (repo: p, since 2026-07-27)\n- [ ] famA-s1 epic:famA - a story (repo: p, since 2026-07-27)\n" >SIDE/home/records/backlog.md'
aa_same 2 AC_SCOPE=famA
aa_same 2 AC_SCOPE=famA AC_WATCH_SKIP=inherited
aa_each 'printf "#!/bin/sh\nexit 3\n" >SIDE/root/bin/ac-ready.sh'
aa_same 2 AC_SCOPE=famA
aa_each 'rm SIDE/root/bin/ac-ready.sh'
aa_same 2 AC_SCOPE=famA
aa_each "printf '#!/bin/sh\nexec \"%s/ac-ready.sh\" \"\$@\"\n' '$BIN' >SIDE/root/bin/ac-ready.sh; chmod +x SIDE/root/bin/ac-ready.sh"
aa_stub 'printf "%s\n" "$(( $(wc -l <SIDE/calls) )) " | sed "s/^1 $/heartbeat/; s/^2 $/report:t9/"; rm -f SIDE/home/state/famA-chief.meta'
aa_same 2

# 8. the nudge: a scoped handback types the wake into its own chief pane.
aa_fresh; aa_meta t1 'kind=ship\n'
aa_meta famA-chief 'kind=roomchief\nwindow=crew:famA-chief\nbackend=herdr\n'
aa_each 'printf "pFAC tFAC\n" >SIDE/home/state/.pane-famA-chief'
for l in 'report:t1' '' 'heartbeat'; do
  aa_lines "$l"
  aa_same 2 AC_SCOPE=famA AC_AUTOARM_BUDGET=600
done
assert_contains "$(cat "$TMP/aa.n.snap")" "herdr pane send-text pFAC wake: auto-arm budget spent with crew still in flight - coverage handed back - run bin/ac-wake-drain.sh" "the budget handback's nudge names its branch"
# Valid UTF-8 reaches the chief pane as its bytes: the watcher's reason, and a
# scope naming its own chief's pane.
aa_lines "$(printf 'gone:famA-t\303\251st')"
aa_same 2 AC_SCOPE=famA
assert_contains "$(cat "$TMP/aa.n.snap")" "$(printf 'herdr pane send-text pFAC wake: gone:famA-t\303\251st - run')" "a UTF-8 reason is typed as its bytes"
aa_fe="$(printf 'fam\303\251')"
aa_each "printf 'kind=roomchief\nbackend=herdr\n' >SIDE/home/state/$aa_fe-chief.meta; printf 'pFEC tFEC\n' >SIDE/home/state/.pane-$aa_fe-chief"
aa_lines 'report:t1'
aa_same 2 "AC_SCOPE=$aa_fe"
assert_contains "$(cat "$TMP/aa.n.snap")" "herdr pane send-text pFEC wake: report:t1 - run" "a UTF-8 scope's nudge reaches its own chief pane"
aa_each "rm -f SIDE/home/state/$aa_fe-chief.meta SIDE/home/state/.pane-$aa_fe-chief"
aa_stub 'mkdir -p SIDE/home/state/.wake-spool.famA; printf "3\treport\tt9\tdone: x\n" >SIDE/home/state/.wake-spool.famA/9.1.000000; printf "heartbeat\n"'
aa_same 2 AC_SCOPE=famA
aa_lines 'report:t1'
aa_meta famA-chief 'kind=roomchief\nbackend=bogus\n'
aa_same 2 AC_SCOPE=famA
aa_each 'chmod 000 SIDE/home/state/famA-chief.meta'
aa_same 2 AC_SCOPE=famA
aa_each 'chmod 644 SIDE/home/state/famA-chief.meta'
aa_meta famA-chief 'kind=roomchief\n'
# AT PARITY (W3): a fleet backend name the driver refuses ends a scoped
# handback 1 at the nudge, before its trace and its exit 2 - the wake is
# lost; the shim answers the 1 as 0 (F7).
aa_each 'rm -f SIDE/home/state/.stop-hooks.log'
aa_both AC_SCOPE=famA AC_BACKEND=bogus
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "1 0" "W3: a refused backend name ends the run 1 (the shim's 0)"
cmp -s "$TMP/aa.o.err2" "$TMP/aa.n.err2" || fail "W3: both print the handback before the nudge"
cmp -s "$TMP/aa.o.snap" "$TMP/aa.n.snap" || fail "W3: neither traces the handback: $(diff "$TMP/aa.o.snap" "$TMP/aa.n.snap" | head -n 6)"
case "$(cat "$TMP/aa.n.snap")" in *handed-back*) fail "W3: the handback was traced" ;; esac
aa_each 'printf "orca\n" >SIDE/home/config/backend'
aa_same 2 AC_SCOPE=famA
aa_each 'printf "tmux\n" >SIDE/home/config/backend'
aa_both AC_SCOPE=famA
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "1 0" "W3: config/backend's refused name too"

# 9. the trace and its trim (W1: the keep knob's arithmetic).
aa_fresh; aa_meta t1 'kind=ship\n'; aa_lines 'report:t1'
aa_each 'for i in 1 2 3 4 5; do printf "old %s\n" $i >>SIDE/home/state/.stop-hooks.log; done'
aa_same 2 AC_STOPHOOK_LOG_KEEP=2
aa_same 2 AC_STOPHOOK_LOG_KEEP=3
aa_same 2 AC_STOPHOOK_LOG_KEEP=0
aa_same 2 AC_STOPHOOK_LOG_KEEP=
aa_each 'mkdir SIDE/home/state/.stop-hooks.log.d; rm SIDE/home/state/.stop-hooks.log; mv SIDE/home/state/.stop-hooks.log.d SIDE/home/state/.stop-hooks.log'
AA_NOISE=1 aa_same 2
aa_each 'rmdir SIDE/home/state/.stop-hooks.log'
AA_NOISE=1 aa_same 0 "AC_STOPHOOK_LOG_KEEP=1 2"
assert_eq "$(sed -n '/^== trace$/,/^== calls$/p' "$TMP/aa.n.snap" | grep -c 'hook=watch-autoarm')" "4" "W1: a handback falls through to budget-spent and work-finished"
AA_NOISE=1 aa_same 0 AC_STOPHOOK_LOG_KEEP=abc
aa_each 'rm -f SIDE/home/state/t1.meta SIDE/home/state/.stop-hooks.log'
AA_NOISE=1 aa_same 0 "AC_STOPHOOK_LOG_KEEP=1 2"
AA_NOISE=1 aa_same 0 AC_STOPHOOK_LOG_KEEP=abc
aa_meta famA-chief 'kind=roomchief\n'; aa_meta t1 'kind=ship\n'
AA_NOISE=1 aa_same 0 "AC_STOPHOOK_LOG_KEEP=1 2" AC_SCOPE=famZ
aa_each 'printf "pid=0\n" >SIDE/home/state/.session-lock'
AA_NOISE=1 aa_same 0 "AC_STOPHOOK_LOG_KEEP=1 2"
aa_each 'rm SIDE/home/state/.session-lock'

# --- named divergences: each row asserts both sides ---------------------------
aa_fresh; aa_meta t1 'kind=ship\n'; aa_lines 'report:t1'
# F7 STATUS: an unknown argument is refused 1 by the module, which the shim
# answers 0; the refusal line is the same on both sides.
AA_ARGS=(--bogus); aa_both; AA_ARGS=()
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "1 0" "F7: the module's 1 is the shim's 0"
cmp -s "$TMP/aa.o.err2" "$TMP/aa.n.err2" || fail "F7: the refusal line differs: $(diff "$TMP/aa.o.err2" "$TMP/aa.n.err2")"
assert_eq "$(cat "$TMP/aa.n.err2")" "ERROR: unknown argument: --bogus (the hook takes none; -h prints its header)" "F7: the line itself"
cmp -s "$TMP/aa.o.snap" "$TMP/aa.n.snap" || fail "F7: an argument arms and traces nothing on either side"
AA_ARGS=("" extra); aa_same 2; AA_ARGS=()
# F7 STATUS: an identifier in the heartbeat ends the run with the clock date's
# status - 3 there, the shim's 0.
aa_each 'printf 3 >SIDE/stub/clock.rc'
AA_NOISE=1 aa_both AC_HEARTBEAT=abc
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "3 0" "F7: the clock's status is the shim's 0"
cmp -s "$TMP/aa.o.snap" "$TMP/aa.n.snap" || fail "F7: both end after the armed line"
aa_each 'printf 0 >SIDE/stub/clock.rc'
# USAGE HEADER: -h prints the module's header on the port's side.
for a in -h --help; do
  AA_ARGS=("$a"); aa_both; AA_ARGS=()
  assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "0 0" "USAGE HEADER: $a exits 0 on both sides"
  assert_contains "$(cat "$TMP/aa.o.out")" "Stop-hook watcher continuity" "USAGE HEADER: the original's header"
  assert_eq "$(cat "$TMP/aa.n.out")" "$(sed -n '/^\/\//!q; s|^// \{0,1\}||p' "$ROOT/src/watch-autoarm.ts")" "USAGE HEADER: the module's header, byte for byte"
done
# EXPRESSIONS: a heartbeat that is an expression arms on the original's side
# and reads as malformed on the port's - the budget handback at once.
aa_both AC_HEARTBEAT='60*10'
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "2 2" "EXPRESSIONS: both hand back"
assert_contains "$(cat "$TMP/aa.o.err")" "ac-watch-autoarm: report:t1" "EXPRESSIONS: the original armed (60*10 = 600)"
assert_contains "$(cat "$TMP/aa.n.err")" "auto-arm budget spent with crew still in flight" "EXPRESSIONS: the port read it malformed"
aa_both AC_HEARTBEAT=HOME
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "2 0" "EXPRESSIONS: a set variable's value is bash's, an unbound name the port's"
# NUDGE DRIVER: with no ac-backend.sh beside the hook the original skips the
# nudge; the port's driver is its own.
aa_meta famA-chief 'kind=roomchief\n'
aa_each 'printf "pFAC tFAC\n" >SIDE/home/state/.pane-famA-chief; rm SIDE/root/bin/ac-backend.sh'
aa_both AC_SCOPE=famA
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "2 2" "NUDGE DRIVER: both hand back"
assert_eq "$(sed -n '/send-text/p' "$AO/stub/herdr.log" 2>/dev/null)" "" "NUDGE DRIVER: the original typed nothing"
assert_contains "$(cat "$AN/stub/herdr.log")" "pane send-text pFAC wake: report:t1 - run bin/ac-wake-drain.sh" "NUDGE DRIVER: the port typed the wake"
aa_each 'cp '"$BIN"'/ac-backend.sh SIDE/root/bin/'
# EXCLUSIVE TEMP: a tail that refuses the keep leaves its temp on both sides -
# the original's second trace line truncated the same `$f.tmp.$$`, the port's
# takes the next name.
aa_each 'printf "old\nold\nold\n" >SIDE/home/state/.stop-hooks.log'
aa_both "AC_STOPHOOK_LOG_KEEP=2#1"
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "2 2" "EXCLUSIVE TEMP: both hand back"
cmp -s "$TMP/aa.o.err2" "$TMP/aa.n.err2" || fail "EXCLUSIVE TEMP: the handback is the same on both sides"
assert_eq "$(ls -A "$AO/home/state" | grep -c '^\.stop-hooks\.log\.tmp\.')" "1" "EXCLUSIVE TEMP: the original reused one temp"
assert_eq "$(ls -A "$AN/home/state" | grep -c '^\.stop-hooks\.log\.tmp\.')" "2" "EXCLUSIVE TEMP: the port took a second name"
aa_each 'rm -f SIDE/home/state/.stop-hooks.log*'
# BYTES: a scope byte that is not UTF-8 is the original's, U+FFFD the port's.
aa_both AC_SCOPE="$(printf 'f\351m')"
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "0 0" "BYTES: both stand aside (no such family)"
assert_contains "$(od -An -tx1 "$AO/home/state/.stop-hooks.log" | tr -d ' \n')" "73636f70653d66e96d0a" "BYTES: the original traces the byte"
assert_contains "$(od -An -tx1 "$AN/home/state/.stop-hooks.log" | tr -d ' \n')" "73636f70653d66efbfbd6d0a" "BYTES: the port traces U+FFFD"
# BYTES: a reason byte that is not UTF-8 is typed by the nudge as U+FFFD; its
# stderr line and its trace keep the byte on both sides.
aa_each 'rm -f SIDE/home/state/.stop-hooks.log'
aa_lines "$(printf 'gone:t\351x')"
aa_both AC_SCOPE=famA
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "2 2" "BYTES: both hand back the reason"
aa_wake="$(printf 'wake: gone:t' | od -An -tx1 | tr -d ' \n')"
assert_contains "$(od -An -tx1 "$AO/stub/herdr.log" | tr -d ' \n')" "${aa_wake}e978" "BYTES: the original types the byte"
assert_contains "$(od -An -tx1 "$AN/stub/herdr.log" | tr -d ' \n')" "${aa_wake}efbfbd78" "BYTES: the port types U+FFFD"
cmp -s "$TMP/aa.o.err2" "$TMP/aa.n.err2" || fail "BYTES: the handback's stderr keeps the byte on both sides"
aa_detail="$(printf 'detail=gone:t' | od -An -tx1 | tr -d ' \n')"
assert_contains "$(od -An -tx1 "$AO/home/state/.stop-hooks.log" | tr -d ' \n')" "${aa_detail}e9780a" "BYTES: the original traces the byte"
assert_contains "$(od -An -tx1 "$AN/home/state/.stop-hooks.log" | tr -d ' \n')" "${aa_detail}e9780a" "BYTES: the port traces the byte"
# BUN: no bun on PATH - the shim exits 0 at once, arming nothing, where the
# original armed.
aa_nobun="$TMP/aa-nobun"
aa_path=""
IFS=: read -r -a aa_dirs <<<"$PATH"
for d in "${aa_dirs[@]}"; do
  if [ -e "$d/bun" ]; then
    m="$aa_nobun/$(printf '%s' "$d" | tr '/' '_')"
    mkdir -p "$m"
    for t in "$d"/*; do [ "${t##*/}" = bun ] || ln -sf "$t" "$m/${t##*/}"; done
    d="$m"
  fi
  aa_path="$aa_path${aa_path:+:}$d"
done
aa_fresh; aa_meta t1 'kind=ship\n'; aa_lines 'report:t1'
aa_run "$AO" o PATH="$AO/stub:$aa_path"; aa_run "$AN" n PATH="$AN/stub:$aa_path"
assert_eq "$(cat "$TMP/aa.o.rc") $(cat "$TMP/aa.n.rc")" "2 0" "BUN: the original hands back with no bun on PATH, the shim exits 0"
assert_contains "$(cat "$TMP/aa.o.err")" "ac-watch-autoarm: report:t1" "BUN: the original armed"
assert_eq "$(cat "$TMP/aa.n.out" "$TMP/aa.n.err")" "" "BUN: the shim says nothing"
assert_no_file "$AN/calls" "BUN: the shim arms nothing"
assert_no_file "$AN/home/state/.stop-hooks.log" "BUN: the shim traces nothing"
# BUN: a module that cannot load is the shim's no-op: 0, bun's diagnosis, no trace.
aa_lf="$TMP/aa-loadfail"
mkdir -p "$aa_lf/bin" "$aa_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-watch-autoarm.sh" "$aa_lf/bin/"
printf 'throw new Error("autoarm cannot load");\n' >"$aa_lf/src/watch-autoarm.ts"
rc=0
(cd "$AN/home" && printf '{}' | AC_HOME="$AN/home" LC_ALL=C "$aa_lf/bin/ac-watch-autoarm.sh") >"$TMP/aa.n.out" 2>"$TMP/aa.n.err" || rc=$?
assert_eq "$rc" "0" "BUN: a module that cannot load exits 0"
assert_eq "$(cat "$TMP/aa.n.out")" "" "BUN: a module that cannot load prints nothing on stdout"
assert_contains "$(cat "$TMP/aa.n.err")" "autoarm cannot load" "BUN: the load failure is bun's own diagnosis"
case "$(cat "$TMP/aa.n.err")" in *"ac-watch-autoarm:"*) fail "BUN: a module that cannot load must never hand back" ;; esac
assert_no_file "$AN/home/state/.stop-hooks.log" "BUN: a module that cannot load traces nothing"

pass
