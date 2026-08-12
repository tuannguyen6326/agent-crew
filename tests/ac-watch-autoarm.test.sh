#!/usr/bin/env bash
# ac-watch-autoarm.test.sh - the Stop-hook watcher continuity: scope, the
# "supervision owed" predicate, silent re-arm on heartbeat, translation of an
# actionable close into a wake, standing out of another watcher's way, the
# budget handback, and fail-open on every missing dependency.
#
# ac-watch.sh is STUBBED throughout: this suite owns the hook's translation
# logic, not the watcher's own behaviour (tests/ac-watch.test.sh owns that).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# A private bin/ whose ac-watch.sh is a stub, so the hook's own resolution
# (dirname "$0") picks the stub up exactly as it would the real one.
lab="$TMP/autoarm-bin"
mkdir -p "$lab"
cp "$BIN/ac-watch-autoarm.sh" "$lab/"
for f in ac-lib.sh ac-ready.sh; do cp "$BIN/$f" "$lab/"; done
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
# stdout whatever the status (ac-watch.sh:565 - stderr carries the arm log and
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

# The home must look like a primary checkout, or the scope test exits 0 first.
git -C "$AC_HOME" init -q . 2>/dev/null || true
git -C "$AC_HOME" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null || true

# --- nothing owed -----------------------------------------------------------
# No crew, no remote transport: the hook must not arm anything at all.
stub_watch 'heartbeat'
assert_eq "$(run_hook)" "0" "an idle fleet arms nothing"
assert_eq "$(calls)" "0" "and never calls the watcher"

# --- an actionable close is translated into a wake --------------------------
inflight_meta t1
stub_watch 'report:t1'
assert_eq "$(run_hook)" "2" "an actionable close wakes the chief"
assert_contains "$(cat "$TMP/hook.err")" "report:t1" "the reason reaches the chief verbatim"
assert_contains "$(cat "$TMP/hook.err")" "ac-wake-drain.sh" "and it names the next move"

# --- heartbeat re-arms SILENTLY, which is the whole point -------------------
# Three heartbeats then a real signal: the chief is woken ONCE, at the signal,
# and the watcher was re-armed in between with no turn spent.
stub_watch 'heartbeat' 'heartbeat' 'heartbeat' 'ask:t1'
assert_eq "$(run_hook)" "2" "the hook keeps going until something actionable"
assert_eq "$(calls)" "4" "each heartbeat re-armed the watcher in-process"
assert_contains "$(cat "$TMP/hook.err")" "ask:t1" "only the actionable close is reported"
case "$(cat "$TMP/hook.err")" in *heartbeat*) fail "a heartbeat must never reach the chief" ;; esac

# --- another watcher already holds the singleton ----------------------------
stub_watch 'already running'
assert_eq "$(run_hook)" "0" "the hook stands out of a live watcher's way"

# --- a config-swap refusal is a LIVE watcher, not an absent one -------------
# ac-watch.sh refuses a second arm carrying a DIFFERENT AC_WATCH_SKIP than the
# running singleton (ac-watch.sh:881, exit 2). It reaches that branch only when
# the lock is held by a LIVE process - a dead or stale one is reclaimed first -
# so the refusal carries exactly the fact `already running` carries, and the
# hook must stand aside instead of reporting the watcher absent.
stub_watch_refusal 2 'refused: a live watcher (pid 55739) holds a DIFFERENT watch-config (running AC_WATCH_SKIP=[], new AC_WATCH_SKIP=[fam]); release THAT ONE with: bin/ac-watch.sh --release 55739'
assert_eq "$(run_hook)" "0" "a config-swap refusal stands aside: the singleton is alive"
assert_eq "$(cat "$TMP/hook.err")" "" "and a beating watcher is never reported as missing"

# --- every OTHER refusal still reaches the chief, with its own reason -------
# The owner gate (another session holds the home, ac-watch.sh:854) refuses with
# NOTHING armed: that one must still wake the chief, and say why.
stub_watch_refusal 2 'refused: fleet watcher not armed - another session owns this home'
assert_eq "$(run_hook)" "2" "a refusal that armed nothing wakes the chief"
assert_contains "$(cat "$TMP/hook.err")" "another session owns this home" "with the refusal's own reason"

# --- a watcher that dies mute is reported whatever its exit status ----------
stub_watch_refusal 3 ''
assert_eq "$(run_hook)" "2" "a mute non-zero close still hands coverage back"
assert_contains "$(cat "$TMP/hook.err")" "NOT covered" "and still says coverage is not in place"

# --- a mute watcher is handed back, never spun on ---------------------------
stub_watch ''
assert_eq "$(run_hook)" "2" "a watcher that closed with no reason hands back"
assert_contains "$(cat "$TMP/hook.err")" "NOT covered" "and says coverage is not in place"
assert_eq "$(calls)" "1" "it does not retry a mute watcher"

# --- the budget is bounded, and running out is REPORTED ---------------------
# With crew still in flight, a spent budget must wake the chief rather than
# let coverage lapse in silence.
stub_watch 'heartbeat'
rc=0
( cd "$AC_HOME" && printf '{}' | AC_AUTOARM_BUDGET=0 "$hook" >/dev/null 2>"$TMP/hook.err" ) || rc=$?
assert_eq "$rc" "2" "a spent budget with crew in flight hands coverage back"
assert_contains "$(cat "$TMP/hook.err")" "budget spent" "and says so"
assert_contains "$(cat "$TMP/hook.err")" "crew still in flight" \
  "and names the crew-in-flight branch specifically"

# --- the same exhaustion, but owed() fires on its OTHER branch --------------
# owed() is also true with ZERO crew in flight when unscoped and standing
# remote-poll coverage is wired (config/remote-poll executable). The message
# above would be a fabrication here - the crewchief burned two turns hunting
# crew that did not exist because the old message named "crew still in
# flight" unconditionally (captain-approved ride-along, 2026-08-01).
rm -f "$AC_HOME"/state/*.meta
printf '#!/usr/bin/env bash\n' >"$AC_HOME/config/remote-poll"
chmod +x "$AC_HOME/config/remote-poll"
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
assert_eq "$(run_hook)" "0" "work finishing mid-loop ends the hook silently"
assert_eq "$(cat "$TMP/hook.err")" "" "with nothing said to the chief"

# --- the arm ENV is reconstructed per session kind ---------------------------
# A chief arming by hand sets AC_WATCH_SKIP=<promoted families> on the FLEET
# watcher and AC_WATCH_ONLY=<watch set> on a scoped one (AGENTS.md section 7).
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
printf '## In flight\n- [ ] famA - a promoted family (repo: p, since 2026-07-27)\n' \
  >"$AC_HOME/records/backlog.md"
rc=0
( cd "$AC_HOME" && printf '{}' | AC_SCOPE=famA "$hook" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "2" "the scoped arm still translates its close"
assert_eq "$(cat "$TMP/watch.env.only")" "famA" \
  "a roomchief arms with its own watch set"
assert_eq "$(cat "$TMP/watch.env.skip")" "" \
  "... and never a skip: a scoped watcher exists to cover that family"

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
# running` at T+0 with the incumbent LIVE -> the incumbent's stand_down_beacon
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

# --- scope: a crewmate's linked worktree is never armed from ----------------
inflight_meta t2
stub_watch 'report:t2'
linked="$TMP/linked"
git -C "$AC_HOME" worktree add -q --detach "$linked" HEAD 2>/dev/null
if [ -d "$linked" ]; then
  rc=0
  ( cd "$linked" && printf '{}' | AC_HOME="$linked" "$hook" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$rc" "0" "a linked worktree (crewmate) never arms the fleet watcher"
fi

# --- a crewdeputy home is left to its own fleet -----------------------------
touch "$AC_HOME/.ac-crewdeputy-home"
assert_eq "$(run_hook)" "0" "a crewdeputy home is out of scope"
rm -f "$AC_HOME/.ac-crewdeputy-home"

# --- fail open: a broken dependency must never wedge the harness ------------
mv "$lab/ac-watch.sh" "$lab/ac-watch.sh.away"
assert_eq "$(run_hook)" "2" "a missing watcher is reported, not swallowed"
mv "$lab/ac-watch.sh.away" "$lab/ac-watch.sh"
mv "$lab/ac-lib.sh" "$lab/ac-lib.sh.away"
assert_eq "$(run_hook)" "0" "a missing ac-lib.sh fails OPEN"
mv "$lab/ac-lib.sh.away" "$lab/ac-lib.sh"

pass
