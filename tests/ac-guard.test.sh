#!/usr/bin/env bash
# ac-guard.test.sh - warn-only advisory (ac-guard.sh): watcher-down banner,
# queued-wakes warning, tangle warning, stamp rate-limiting, always-exit-0;
# watcher kill-policy hook (ac-watch-policy-hook.sh) deny/allow; guard
# call-sites wired and surviving a missing guard.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

guard() { "$BIN/ac-guard.sh" 2>&1; }

# Pin the tangle check to a throwaway repo on its default branch so these
# tests never depend on the real checkout's branch.
root_repo="$(make_repo guard-root)"
export AC_GUARD_ROOT="$root_repo"

# -- all clear: silent, exit 0 --------------------------------------------------
out="$(guard)" || fail "guard must exit 0 when all clear"
assert_eq "$out" "" "all-clear is silent"

# -- watcher-down: crew in flight, no beacon ------------------------------------
printf 'kind=ship\n' >"$AC_HOME/state/t1.meta"
out="$(guard)" || fail "guard must exit 0 while warning"
assert_contains "$out" "WATCHER-DOWN" "banner fires with crew and no beacon"
assert_file "$AC_HOME/state/.guard-stamp" "warning stamps"

# A verifier is supervised runtime, not a crewmate that owes fleet coverage.
rm -f "$AC_HOME/state/t1.meta" "$AC_HOME/state/.guard-stamp"
printf 'kind=verify-qa\n' >"$AC_HOME/state/vfy.meta"
assert_eq "$(AC_GUARD_QUIET=0 guard)" "" "a verifier alone does not raise WATCHER-DOWN"
rm -f "$AC_HOME/state/vfy.meta"
printf 'kind=ship\n' >"$AC_HOME/state/t1.meta"
guard >/dev/null

# -- rate-limit: same warning set is suppressed ----------------------------------
out="$(guard)"
assert_eq "$out" "" "back-to-back repeat suppressed"

# -- changed set prints immediately: a queued wake appears ------------------------
mkdir -p "$AC_HOME/state/.wake-spool"
printf 'report\tt1\n' >"$AC_HOME/state/.wake-spool/1.1.000000"
out="$(guard)"
assert_contains "$out" "QUEUED WAKES" "queued-wakes warning"
assert_contains "$out" "WATCHER-DOWN" "changed set reprints the whole block"

# -- AC_GUARD_QUIET=0 disables suppression ---------------------------------------
out="$(AC_GUARD_QUIET=0 guard)"
assert_contains "$out" "QUEUED WAKES" "quiet=0 reprints"

# -- fresh beacon + empty spool: silent again, stamp cleared ----------------------
date +%s >"$AC_HOME/state/.last-watcher-beat"
rm -rf "$AC_HOME/state/.wake-spool"
out="$(guard)"
assert_eq "$out" "" "fresh beacon and no queued wake is silent"
assert_no_file "$AC_HOME/state/.guard-stamp" "all-clear clears the stamp"

# -- a spool record nudges; an empty spool dir is litter -------------------------
mkdir -p "$AC_HOME/state/.wake-spool"
out="$(AC_GUARD_QUIET=0 guard)"
assert_eq "$out" "" "an empty spool dir never nudges"
printf '1\treport\tt1\tdone: x\n' >"$AC_HOME/state/.wake-spool/1.1.000000"
out="$(AC_GUARD_QUIET=0 guard)"
assert_contains "$out" "QUEUED WAKES" "a spool record nudges"
rm -rf "$AC_HOME/state/.wake-spool"
out="$(guard)"
assert_eq "$out" "" "drained spool goes silent again"

# -- beacon staleness honors AC_GUARD_GRACE (default 300, ac_watcher_down's ---
# -- ONE default - the guard's old lone 90 made it fire during the ordinary ---
# -- exit->re-arm gap the other consumers already tolerated; audit-f4) --------
printf '%s\n' "$(( $(date +%s) - 400 ))" >"$AC_HOME/state/.last-watcher-beat"
out="$(guard)"
assert_contains "$out" "WATCHER-DOWN" "beacon past default grace is stale"
out="$(AC_GUARD_QUIET=0 AC_GUARD_GRACE=600 guard)"
assert_eq "$out" "" "beacon within grace is fine"
out="$(AC_GUARD_QUIET=0 AC_GUARD_GRACE=0 guard)"
assert_contains "$out" "WATCHER-DOWN" "an explicit tighter grace still fires"

# -- tangle: distro checkout on a non-default branch -----------------------------
git -C "$root_repo" checkout -qb feature-x
out="$(AC_GUARD_QUIET=0 guard)"
assert_contains "$out" "TANGLE" "non-default distro branch warns"
git -C "$root_repo" checkout -q main
rm -f "$AC_HOME/state/.guard-stamp"

# -- tangle: resolves the PRIMARY checkout, not whichever bin/ was invoked -------
# A leased/pooled worktree is a linked worktree off the primary and is never on
# the default branch itself (detached HEAD, or crew/<id>) - the check must
# inspect the PRIMARY's branch (git-common-dir's parent), not the anchor it was
# invoked from, or it fires TANGLE unconditionally for every crewmate/roomchief.
rm -f "$AC_HOME/state"/.guard-stamp* "$AC_HOME/state"/*.meta "$AC_HOME/state"/.last-watcher-beat*
wt_primary="$(make_repo guard-wt-primary)"
wt_leased="$TMP/guard-wt-primary-leased"
git -C "$wt_primary" worktree add -q --detach "$wt_leased" main >/dev/null
out="$(AC_GUARD_QUIET=0 AC_GUARD_ROOT="$wt_leased" guard)"
case "$out" in *"TANGLE"*) fail "TANGLE must not fire from a leased-worktree anchor while the primary is on its default branch" ;; esac

git -C "$wt_primary" checkout -qb feature-y
out="$(AC_GUARD_QUIET=0 AC_GUARD_ROOT="$wt_leased" guard)"
assert_contains "$out" "TANGLE" "TANGLE still fires when the PRIMARY itself is on a non-default branch, proven from a leased-worktree anchor"
git -C "$wt_primary" checkout -q main
git -C "$wt_primary" worktree remove -f "$wt_leased" >/dev/null 2>&1 || true
rm -f "$AC_HOME/state/.guard-stamp"

# -- WIP-TOOLING: the invoked bin/ itself lives in a leased worktree, not the --
# -- primary - a chief that cd's into a pool slot and keeps calling bin/       --
# -- relatively runs that worktree's OWN copy of the tooling                  --
wip_primary="$(make_repo guard-wip-primary)"
wip_leased="$TMP/guard-wip-primary-leased"
git -C "$wip_primary" worktree add -q --detach "$wip_leased" main >/dev/null
out="$(AC_GUARD_QUIET=0 AC_GUARD_ROOT="$wip_leased" guard)"
assert_contains "$out" "WIP-TOOLING" "an anchor inside a leased worktree warns WIP-TOOLING"
rm -f "$AC_HOME/state/.guard-stamp"
out="$(AC_GUARD_QUIET=0 AC_GUARD_ROOT="$wip_primary" guard)"
case "$out" in *"WIP-TOOLING"*) fail "an anchor at the primary itself must not warn WIP-TOOLING" ;; esac
git -C "$wip_primary" worktree remove -f "$wip_leased" >/dev/null 2>&1 || true
rm -f "$AC_HOME/state/.guard-stamp"

# -- DISTRO-LAG: the running tree (anchor) behind the default branch -------------
# Silent when 0 - guard's whole contract is that quiet means healthy; only
# session-start prints the in-sync case.
lag_root="$(make_repo guard-lag-root)"
out="$(AC_GUARD_QUIET=0 AC_GUARD_ROOT="$lag_root" guard)"
case "$out" in *"DISTRO-LAG"*) fail "an anchor in sync with its default branch must not warn DISTRO-LAG: $out" ;; esac
rm -f "$AC_HOME/state/.guard-stamp"

# The anchor lags once the default branch moves ahead of it - the ordinary
# shape inside a leased pool worktree that has not synced since it was cut.
lag_primary="$(make_repo guard-lag-primary)"
lag_leased="$TMP/guard-lag-primary-leased"
git -C "$lag_primary" worktree add -q --detach "$lag_leased" main >/dev/null
git -C "$lag_primary" commit -q --allow-empty -m second
out="$(AC_GUARD_QUIET=0 AC_GUARD_ROOT="$lag_leased" guard)"
assert_contains "$out" "DISTRO-LAG: running tree is 1 behind main" "an anchor behind the default branch warns with the exact count"
# Note the interaction, not a suppression rule (AGENTS.md task note): inside a
# leased worktree this fires beside WIP-TOOLING - both honest, neither hides
# the other.
assert_contains "$out" "WIP-TOOLING" "DISTRO-LAG and WIP-TOOLING both fire for the same leased-worktree anchor"
git -C "$lag_primary" worktree remove -f "$lag_leased" >/dev/null 2>&1 || true
rm -f "$AC_HOME/state/.guard-stamp"

# -- scope: the advisory mirrors what THIS session drains ------------------------
# ac-guard rides ac-send/ac-peek/ac-spawn/ac-review-diff, so it runs inside
# roomchief sessions too. It must nudge each session about ITS OWN wakes and
# keep its own quiet-window bookkeeping.
rm -f "$AC_HOME/state"/.guard-stamp* "$AC_HOME/state"/*.meta
rm -rf "$AC_HOME/state"/.wake-spool*
rm -f "$AC_HOME/state"/.last-watcher-beat*
sguard() {
  # sguard <scope> - the advisory as seen by a scoped session ('' = fleet).
  if [ -n "$1" ]; then AC_SCOPE="$1" "$BIN/ac-guard.sh" 2>&1
  else env -u AC_SCOPE "$BIN/ac-guard.sh" 2>&1; fi
}

# A roomchief is nudged about its own queue, never the fleet's or a sibling's.
mkdir -p "$AC_HOME/state/.wake-spool" "$AC_HOME/state/.wake-spool.fam2"
printf 'report\tt1\n' >"$AC_HOME/state/.wake-spool/1.1.000000"
printf 'report\tfam2-t1\n' >"$AC_HOME/state/.wake-spool.fam2/1.1.000000"
assert_eq "$(AC_GUARD_QUIET=0 sguard fam1)" "" "a roomchief is not nudged about the fleet's or a sibling's wakes"
mkdir -p "$AC_HOME/state/.wake-spool.fam1"
printf 'report\tfam1-t1\n' >"$AC_HOME/state/.wake-spool.fam1/1.1.000000"
assert_contains "$(AC_GUARD_QUIET=0 sguard fam1)" "QUEUED WAKES" "a roomchief is nudged about its own wakes"

# Per-scope stamps: a fleet nudge inside the quiet window must not suppress a
# roomchief's genuine nudge (they used to share one stamp and one sig).
rm -f "$AC_HOME/state"/.guard-stamp*
assert_contains "$(sguard '')" "QUEUED WAKES" "fleet nudge prints"
assert_contains "$(sguard fam1)" "QUEUED WAKES" "a roomchief nudge is not suppressed by the fleet's"
assert_file "$AC_HOME/state/.guard-stamp" "the fleet keeps its own stamp"
assert_file "$AC_HOME/state/.guard-stamp.fam1" "a roomchief keeps its own stamp"
# Each scope still rate-limits itself.
assert_eq "$(sguard fam1)" "" "a roomchief's own repeat is suppressed"

# A roomchief's all-clear clears ONLY its own stamp.
rm -rf "$AC_HOME/state/.wake-spool.fam1"
assert_eq "$(sguard fam1)" "" "roomchief all-clear is silent"
assert_no_file "$AC_HOME/state/.guard-stamp.fam1" "roomchief all-clear clears its own stamp"
assert_file "$AC_HOME/state/.guard-stamp" "a roomchief all-clear never clears the fleet's stamp"

# The fleet advisory mirrors the fleet drain: an ORPHAN family spool is the
# fleet's to drain (so it warns), a LIVE family's spool is not.
rm -f "$AC_HOME/state"/.guard-stamp*
rm -rf "$AC_HOME/state/.wake-spool"
gstub="$TMP/gstub"; mkdir -p "$gstub"
cat >"$gstub/herdr" <<'EOF'
#!/usr/bin/env bash
# Liveness only: `pane get <p>` succeeds iff the sentinel exists.
if [ "${1:-} ${2:-}" = "pane get" ]; then
  [ -e "$AC_HOME/state/.mock-win-${3:-}" ] || exit 1
fi
exit 0
EOF
chmod +x "$gstub/herdr"
mkdir -p "$AC_HOME/state/.wake-spool.fam2"
printf 'report\tfam2-t1\n' >"$AC_HOME/state/.wake-spool.fam2/1.1.000000"
printf 'window=crew:fam2-chief\nbackend=herdr\n' >"$AC_HOME/state/fam2-chief.meta"
printf 'fam2-chief t0\n' >"$AC_HOME/state/.pane-fam2-chief"
: >"$AC_HOME/state/.mock-win-fam2-chief"
date +%s >"$AC_HOME/state/.last-watcher-beat"
assert_eq "$(PATH="$gstub:$PATH" AC_GUARD_QUIET=0 sguard '')" "" \
  "the fleet is not nudged about a LIVE family's wakes"
rm -f "$AC_HOME/state/.mock-win-fam2-chief"   # chief window died -> orphan
assert_contains "$(PATH="$gstub:$PATH" AC_GUARD_QUIET=0 sguard '')" "QUEUED WAKES" \
  "the fleet is nudged about an ORPHAN family's wakes (it drains them)"

# A roomchief reads its own watcher's beacon (H9 symmetry with the hard gate).
rm -f "$AC_HOME/state"/.guard-stamp*
rm -rf "$AC_HOME/state"/.wake-spool*
rm -f "$AC_HOME/state"/*chief.meta "$AC_HOME/state"/.mock-win-*
printf 'kind=ship\n' >"$AC_HOME/state/fam1-t1.meta"
date +%s >"$AC_HOME/state/.last-watcher-beat"
printf '%s\n' "$(( $(date +%s) - 900 ))" >"$AC_HOME/state/.last-watcher-beat.fam1"
assert_contains "$(AC_GUARD_QUIET=0 sguard fam1)" "WATCHER-DOWN" \
  "a roomchief sees its own watcher down despite a fresh fleet beat"
date +%s >"$AC_HOME/state/.last-watcher-beat.fam1"
assert_eq "$(AC_GUARD_QUIET=0 sguard fam1)" "" "a fresh family beat keeps the roomchief quiet"
# Hand the fixture back as this section found it: crew in flight (t1.meta),
# no stamps, no queues, no beacons - the call-site checks below build on it.
rm -f "$AC_HOME/state"/.guard-stamp* "$AC_HOME/state"/*.meta "$AC_HOME/state"/.last-watcher-beat*
printf 'kind=ship\n' >"$AC_HOME/state/t1.meta"

# -- policy hook: denies broad watcher kills (exit 2, reason on stderr) -----------
hook_payload() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# shellcheck disable=SC2016  # fixtures are LITERAL command text, never expanded here
deny_cases=(
  'pkill -f ac-watch'
  'pkill -9 -f "ac-watch.sh"'
  'killall ac-watch.sh'
  'kill $(pgrep -f ac-watch)'
  'WPID=$(pgrep -f watch); kill $WPID'
  'kill "$WATCH_PID"'
)
for c in "${deny_cases[@]}"; do
  rc=0
  hook_payload "$c" | "$BIN/ac-watch-policy-hook.sh" 2>"$TMP/hook-err" || rc=$?
  assert_eq "$rc" "2" "deny exit code for: $c"
  assert_contains "$(cat "$TMP/hook-err")" "ac-watch-policy" "reason on stderr for: $c"
done

allow_cases=(
  'kill 1234'
  'kill -TERM 999'
  'pkill -f some-other-daemon'
  'git commit -m "watch out for edge cases"'
  'bin/ac-watch.sh --once'
  'pgrep -f ac-watch'
)
for c in "${allow_cases[@]}"; do
  hook_payload "$c" | "$BIN/ac-watch-policy-hook.sh" || fail "hook must allow: $c"
done

# non-Bash payloads and garbage stdin fail open
jq -n '{tool_name:"Read", tool_input:{file_path:"/tmp/pkill -f ac-watch"}}' \
  | "$BIN/ac-watch-policy-hook.sh" || fail "non-Bash tool must pass"
printf 'not json' | "$BIN/ac-watch-policy-hook.sh" || fail "garbage payload must fail open"

# hook is registered in .claude/settings.json alongside the Stop hook
settings="$ROOT/.claude/settings.json"
jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("ac-watch-policy-hook.sh")' \
  "$settings" >/dev/null || fail "PreToolUse hook not registered"
jq -e '.hooks.Stop[0].hooks[0].command | contains("ac-turnend-guard.sh")' \
  "$settings" >/dev/null || fail "Stop hook must be preserved"

# -- call sites: wired, advisory surfaces, and survive a missing guard ------------
for s in ac-send.sh ac-peek.sh ac-spawn.sh ac-review-diff.sh ac-merge-local.sh; do
  grep -q 'ac-guard.sh' "$BIN/$s" || fail "guard call-site missing in $s"
done

# advisory rides along on a real call site (stderr, before the usage die)
printf '%s\n' "$(( $(date +%s) - 900 ))" >"$AC_HOME/state/.last-watcher-beat"
rm -f "$AC_HOME/state/.guard-stamp"
err="$("$BIN/ac-send.sh" 2>&1 || true)"
assert_contains "$err" "WATCHER-DOWN" "advisory surfaces through ac-send"
assert_contains "$err" "usage: ac-send.sh" "host command still runs its own checks"

# a bin copy WITHOUT ac-guard.sh still works (guard line is fully optional)
mkdir -p "$TMP/bin2"
cp "$BIN"/*.sh "$TMP/bin2/"
rm -f "$TMP/bin2/ac-guard.sh"
err="$("$TMP/bin2/ac-send.sh" 2>&1 || true)"
assert_contains "$err" "usage: ac-send.sh" "call site survives a missing guard"
case "$err" in *"No such file"*) fail "missing guard must not spill errors" ;; esac

pass
