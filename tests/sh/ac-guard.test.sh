#!/usr/bin/env bash
# ac-guard.test.sh - warn-only advisory (ac-guard.sh): watcher-down banner,
# queued-wakes warning, tangle warning, stamp rate-limiting, always-exit-0;
# watcher kill-policy hook (ac-watch-policy-hook.sh) deny/allow; guard
# call-sites wired and surviving a missing guard.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
for m in send peek spawn review-diff merge-local; do
  awk '!/^ *\/\// && /ac-guard\.sh/ { found = 1 } END { exit !found }' "$ROOT/src/$m.ts" || fail "guard call-site missing in src/$m.ts"
done

# advisory rides along on a real call site (stderr, before the usage die)
printf '%s\n' "$(( $(date +%s) - 900 ))" >"$AC_HOME/state/.last-watcher-beat"
rm -f "$AC_HOME/state/.guard-stamp"
err="$("$BIN/ac-send.sh" 2>&1 || true)"
assert_contains "$err" "WATCHER-DOWN" "advisory surfaces through ac-send"
assert_contains "$err" "usage: ac-send.sh" "host command still runs its own checks"

# a bin copy WITHOUT ac-guard.sh still works (guard line is fully optional);
# the copy's root links src/, where the ac-send.sh shim finds its module
mkdir -p "$TMP/lab2/bin"
cp "$BIN"/*.sh "$TMP/lab2/bin/"
ln -s "$ROOT/src" "$TMP/lab2/src"
rm -f "$TMP/lab2/bin/ac-guard.sh"
err="$("$TMP/lab2/bin/ac-send.sh" 2>&1 || true)"
assert_contains "$err" "usage: ac-send.sh" "call site survives a missing guard"
case "$err" in *"No such file"*) fail "missing guard must not spill errors" ;; esac

# --- the advisory, row by row ---------------------------------------------------
# One side root ($NH): a home at $NH/home, scratch repos beside it, a stub dir
# first on PATH (`date +%s` answering $NH/stub/clock, a herdr and an orca keyed
# on files there, each call logged; every other date call is /bin/date's), the
# caller's cwd $NH/cwd; every knob the guard reads scrubbed, then AC_HOME,
# AC_GUARD_ROOT=$NH/repo and the row's; stdin /dev/null unless the row names a
# file; LC_ALL=C. HOME in an argument or an env value is the side root, and the
# side root reads HOME in what a run printed.
unset AC_GUARD_ROOT
NH="$TMP/side-n"; H="$NH"; NBIN="$BIN"
T=1700000000
GD_ENV=(); GD_CWD=cwd; HOMELESS=0; NOROOT=0; G_RC=0
run_guard() {  # run_guard <args...> - the guard from the caller's cwd; sets G_RC, $TMP/n.err2 and $TMP/n.snap
  local h="$NH" x v
  local a=() e=(LC_ALL=C "PATH=$h/stub:$PATH")
  [ "$HOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  [ "$NOROOT" = 1 ] || e+=("AC_GUARD_ROOT=$h/repo")
  for x in ${GD_ENV[@]+"${GD_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  rm -f "$h/stub/log"
  G_RC=0
  (cd "$h/$GD_CWD" && env -u AC_HOME -u AC_SCOPE -u AC_GUARD_ROOT -u AC_GUARD_QUIET -u AC_GUARD_GRACE -u AC_BACKEND \
    -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u EPOCHSECONDS "${e[@]}" "$NBIN/ac-guard.sh" ${a[@]+"${a[@]}"}) \
    <"${GD_STDIN:-/dev/null}" >"$TMP/n.raw" 2>"$TMP/n.err" || G_RC=$?
  norm <"$TMP/n.err" >"$TMP/n.err2"
  snap | norm >"$TMP/n.snap"
}
says() {  # says <stderr> <args...> - exit 0, nothing on stdout, exactly these warnings
  local want="$1"; shift
  run_guard "$@"
  assert_eq "$G_RC:$(cat "$TMP/n.raw"):$(shim_err)" "0::$want" "the guard's answer for '$*' (${GD_ENV[*]+${GD_ENV[*]}}) at line ${BASH_LINENO[0]}"
}
norm() { LC_ALL=C sed -e "s#$NH#HOME#g" -E -e 's/\.tmp\.[0-9]+(\.[0-9]+)?/.tmp.PID/g'; }
snap() {  # the state/ listing, every stamp's bytes (a directory's listing), the stub log
  local h="$NH" f
  (cd "$h/home/state" 2>/dev/null && ls -A) || printf '(no state/)\n'
  for f in "$h/home/state"/.guard-stamp*; do
    [ -e "$f" ] || continue
    printf '== %s\n' "${f##*/}"
    if [ -d "$f" ]; then ls -A "$f"; else cat "$f" 2>/dev/null || printf '(unreadable)\n'; fi
  done
  printf '== log\n'; cat "$h/stub/log" 2>/dev/null || true
}
shim_err() { cat "$TMP/n.err2"; }
shim_snap() { cat "$TMP/n.snap"; }
shim_calls() { sed -n '/^== log$/,$p' "$TMP/n.snap" | /usr/bin/grep -E '^(herdr|orca) ' || true; }  # the backend calls the run made
g() { git -C "$H/$1" -c user.email=t@t -c user.name=t "${@:2}"; }
fresh0() {  # a clean side root: home/state, cwd, the stubs, the clock at T, the primary repo on main
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/cwd" "$H/stub"
  printf '%s\n' "$T" >"$H/stub/clock"
  cat >"$H/stub/date" <<EOF
#!/bin/sh
if [ "\$1" = +%s ]; then
  printf 'date %s\n' "\$*" >>"$H/stub/log"
  [ ! -e "$H/stub/date-reads" ] || { IFS= read -r l; printf 'date stdin=%s\n' "\$l" >>"$H/stub/log"; }
  cat "$H/stub/clock"
  exit 0
fi
exec /bin/date "\$@"
EOF
  cat >"$H/stub/herdr" <<EOF
#!/bin/sh
d="$H/stub"
printf 'herdr %s [%s]\n' "\$*" "\${HERDR_SESSION:-}" >>"\$d/log"
[ ! -e "\$d/hang" ] || exec sleep 5
[ ! -e "\$d/readstdin" ] || printf 'herdr stdin=[%s]\n' "\$(cat)" >>"\$d/log"
case "\$1 \$2" in
  "pane get") [ -e "\$d/win-\$3" ] ;;
  "pane list") [ ! -e "\$d/list-fails" ] || exit 1; printf '{"result":{"panes":[]}}\n' ;;
  "status server") printf '{"running":%s}\n' "\$(cat "\$d/running" 2>/dev/null || echo true)" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$H/stub/orca" <<EOF
#!/bin/sh
d="$H/stub"
printf 'orca %s\n' "\$*" >>"\$d/log"
[ ! -e "\$d/readstdin" ] || printf 'orca stdin=[%s]\n' "\$(cat)" >>"\$d/log"
case "\$1 \$2" in
  "terminal show") printf '{"ok":true,"result":{"terminal":{"connected":%s}}}\n' "\$([ -e "\$d/win-\$4" ] && echo true || echo false)" ;;
  *) printf '{"ok":true}\n' ;;
esac
EOF
  chmod +x "$H/stub/date" "$H/stub/herdr" "$H/stub/orca"
  git init -q -b main "$H/repo"; g repo commit -q --allow-empty -m init
}
fresh() { fresh0; }
m() { printf "$2" >"$H/home/state/$1.meta"; }  # m <name> <printf format> - one meta
crew() { m t1 'kind=ship\n'; }
beat() { printf '%s\n' "$1" >"$H/home/state/.last-watcher-beat${2:+.$2}"; }  # beat <epoch> [<scope>]
clock() { printf "$1" >"$H/stub/clock"; }
stampf() { printf "$1" >"$H/home/state/.guard-stamp${2:+.$2}"; }  # stampf <printf format> [<scope>]
spoolrec() { mkdir -p "$H/home/state/.wake-spool${1:+.$1}"; printf 'x\n' >"$H/home/state/.wake-spool${1:+.$1}/1.1.000000"; }
chief() {  # chief <fam> <meta body> [<pane>] - a family's chief meta and pane handle
  printf "$2" >"$H/home/state/$1-chief.meta"
  [ -z "${3:-}" ] || printf '%s t\n' "$3" >"$H/home/state/.pane-$1-chief"
}
win() { : >"$H/stub/win-$1"; }

WD='WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh'
QW='QUEUED WAKES: run bin/ac-wake-drain.sh'

# 1. the run: all clear is silent, exit 0, whatever the arguments (none are
#    read); homeless, an empty AC_HOME and one that cannot be entered are
#    silent 0 with nothing minted; a relative AC_HOME is the caller's cwd's.
fresh
says ""
says "" -h
says "" bogus x
HOMELESS=1; says ""; HOMELESS=0
GD_ENV=("AC_HOME="); says ""
GD_ENV=("AC_HOME=HOME/missing"); says ""
[ ! -e "$NH/missing" ] || fail "row 1: an unenterable home mints nothing"
rm -rf "$NH/home/state"
GD_ENV=("AC_HOME=home"); GD_CWD=.
says ""
[ -d "$NH/home/state" ] || fail "row 1: a relative AC_HOME resolves from the caller's cwd (state/ minted)"
GD_ENV=(); GD_CWD=cwd

# 2. the backend rungs: an unreadable one reads as none and the run goes on.
if [ "$(id -u)" != 0 ]; then
  fresh; crew
  mkdir -p "$NH/fs/state" "$NH/fs/config"; printf 'wezterm x\n' >"$NH/fs/config/backend"; chmod 000 "$NH/fs/config/backend"
  GD_ENV=("AC_FLEET_STATE=HOME/fs/state"); says "$WD"
  chmod 644 "$NH/fs/config/backend"
fi
GD_ENV=()

# 3. WATCHER-DOWN: the line and the stamp's exact bytes; a repeat inside the
#    window is silent and leaves the stamp (the window runs from the FIRST
#    print); AC_GUARD_QUIET=0 reprints; a fresh beacon is silent and removes
#    the stamp.
fresh; crew
says "$WD"
assert_contains "$(shim_snap)" "== .guard-stamp
sig= watcher-down
at=$T" "row 3: the stamp keeps the token's leading space"
clock "$((T + 59))\n"
says ""
assert_contains "$(shim_snap)" "at=$T" "row 3: a repeat inside the window leaves the stamp"
GD_ENV=("AC_GUARD_QUIET=0"); says "$WD"; GD_ENV=()
assert_contains "$(shim_snap)" "at=$((T + 59))" "row 3: quiet=0 reprints and restamps"
beat "$((T + 59))"
says ""
case "$(shim_snap)" in *"== .guard-stamp"*) fail "row 3: all-clear removes the stamp" ;; esac

# 4. the supervision set (crewMetas): verify and self skipped, chiefs counted,
#    the LAST kind= wins.
while IFS='|' read -r body want <&3; do
  fresh; m k "$body"
  says "$want"
done 3<<EOF
kind=verify-qa\n|
kind=self\n|
kind=roomchief\n|$WD
kind=crewdeputy\n|$WD
kind=self\nkind=ship\n|$WD
kind=ship\nkind=self\n|
EOF

# 5. the grace in `[ -gt ]`'s grammar, a beacon 400 s old: blanks, a sign and
#    a leading zero are decimal numbers, and an empty string is the default 300.
fresh; crew; beat "$((T - 400))"
while IFS='|' read -r gr want <&3; do
  GD_ENV=("AC_GUARD_QUIET=0" "AC_GUARD_GRACE=$gr")
  says "$want"
done 3<<EOF
 600 |
 399 |$WD
+600|
+399|$WD
010|$WD
-5|$WD
|$WD
399|$WD
400|
EOF
GD_ENV=()

# 6. the quiet window in `[ -lt ]`'s grammar, the same sig stamped 9 s ago:
#    empty is the default 60, and 010 is ten.
while IFS='|' read -r q want <&3; do
  fresh; crew; stampf "sig= watcher-down\nat=$((T - 9))\n"
  GD_ENV=("AC_GUARD_QUIET=$q")
  says "$want"
done 3<<EOF
|
 600 |
+20|
5|$WD
010|
EOF
GD_ENV=()

# 7. the stamp's at= through `$(( ))`, the clock at 1000 and the window 60: a
#    leading 0 is OCTAL (01000 is 512 - it prints where a decimal 1000 would
#    not; 01750 is 1000), 0099 an evaluation error (no suppression), 2^64+
#    wraps (suppressed), a value with a non-digit reads 0.
while IFS='|' read -r at want <&3; do
  fresh; clock '1000\n'; crew; stampf "sig= watcher-down\nat=$at\n"
  says "$want"
done 3<<EOF
01000|$WD
0012|$WD
0099|$WD
00|$WD
-5|$WD
99999999999999999999|
abc|$WD
990|
 990|$WD
01750|
EOF

# 8. QUEUED WAKES: the fleet spool's records (a subdirectory counts; a
#    dotfile, a dangling link, a spool that is a file do not), and a
#    roomchief's own spool only.
fresh; spoolrec
says "$QW"
fresh; mkdir -p "$NH/home/state/.wake-spool"; : >"$NH/home/state/.wake-spool/.dot"
says ""
fresh; mkdir -p "$NH/home/state/.wake-spool"; ln -s nowhere "$NH/home/state/.wake-spool/l"
says ""
fresh; mkdir -p "$NH/home/state/.wake-spool/sub"
says "$QW"
fresh; : >"$NH/home/state/.wake-spool"
says ""
fresh; spoolrec; spoolrec fam2
GD_ENV=("AC_SCOPE=fam1"); says ""
spoolrec fam1
says "$QW"
assert_contains "$(shim_snap)" "== .guard-stamp.fam1" "row 8: a roomchief stamps its own"
GD_ENV=()

# 9. orphans through backendCall: a family spool with no chief meta is an
#    orphan with no backend call; with one, only the driver's 0 is live -
#    herdr's pane get, then pane list (an empty list: gone), then status
#    server (running:false gone, true unreadable - both orphans); no pane
#    handle (no call), orca's terminal show, a refused backend name (no call),
#    a configured session (argv and HERDR_SESSION), a hung herdr bounded by
#    AC_HERDR_RPC_TIMEOUT. The answering family sorts LAST; a chief meta is
#    crew in flight, so every world has a fresh beacon.
fresh() { fresh0; beat "$T"; }
o1() { fresh; spoolrec zz; }
o2() { fresh; spoolrec zz; chief zz 'backend=herdr\n' pzz; win pzz; }
o3() { fresh; spoolrec zz; chief zz 'kind=roomchief\n' pzz; }
o4() { fresh; spoolrec zz; chief zz 'backend=herdr\n' pzz; : >"$H/stub/list-fails"; printf false >"$H/stub/running"; }
o5() { fresh; spoolrec zz; chief zz 'backend=herdr\n' pzz; : >"$H/stub/list-fails"; }
o6() { fresh; spoolrec zz; chief zz 'backend=herdr\n'; }
o7() { fresh; spoolrec zz; chief zz 'backend=orca\n' hzz; win hzz; }
o8() { fresh; spoolrec zz; chief zz 'backend=orca\n' hzz; }
o9() { fresh; spoolrec zz; chief zz 'backend=tmux\n' pzz; win pzz; }
o10() { fresh; mkdir -p "$H/home/state/.wake-spool.aa"; chief aa 'backend=herdr\n' paa; spoolrec bb; chief bb 'backend=herdr\n' pbb; win pbb; spoolrec zz; chief zz 'backend=herdr\n' pzz; }
for o in o3 o4 o5 o8 o10; do "$o"; says "$QW"; done
o1; says "$QW"
assert_eq "$(shim_calls)" "" "row 9: no chief meta, no backend call"
o6; says "$QW"
assert_eq "$(shim_calls)" "" "row 9: no pane handle, no backend call"
o9; says "$QW"
assert_eq "$(shim_calls)" "" "row 9: a refused backend name is an orphan, no call"
o2; says ""
assert_eq "$(shim_calls)" "herdr pane get pzz []" "row 9: a live family's spool is its chief's - one pane get"
o7; says ""
o3
GD_ENV=("AC_HERDR_SESSION=s1"); says "$QW"
assert_contains "$(shim_snap)" "herdr pane get pzz --session s1 [s1]" "row 9: the session rides argv and HERDR_SESSION"
: >"$NH/stub/hang"
GD_ENV=("AC_HERDR_RPC_TIMEOUT=1" "AC_GUARD_QUIET=0"); says "$QW"
assert_eq "$(shim_calls)" "herdr pane get pzz []
herdr pane list []
herdr status server --json []" "row 9: a hung herdr - three bounded calls, an orphan"
GD_ENV=()
# The scan stops at the answering orphan.
fresh; spoolrec aa; chief aa 'backend=herdr\n' paa; chief bb 'backend=herdr\n' pbb; mkdir -p "$NH/home/state/.wake-spool.bb"
says "$QW"
case "$(cat "$NH/stub/log")" in *pbb*) fail "row 9: the scan stops at the answer" ;; esac
# The driver's children read /dev/null: a herdr or an orca that reads stdin
# swallows neither the caller's stdin nor the families after it.
printf 'caller-stdin\n' >"$TMP/stdin9"
fresh; chief aa 'backend=herdr\n' paa; mkdir -p "$NH/home/state/.wake-spool.aa"; spoolrec bb; : >"$NH/stub/readstdin"
GD_STDIN="$TMP/stdin9"; says "$QW"; unset GD_STDIN
assert_contains "$(shim_snap)" "herdr stdin=[]" "row 9 (stdin): herdr reads nothing"
fresh; chief aa 'backend=orca\n' haa; mkdir -p "$NH/home/state/.wake-spool.aa"; spoolrec bb; : >"$NH/stub/readstdin"
says "$QW"
assert_contains "$(cat "$NH/stub/log")" "orca stdin=[]" "row 9 (stdin): orca reads nothing"

fresh() { fresh0; }

# 10. TANGLE / WIP-TOOLING / DISTRO-LAG over scratch repos: the primary on
#     main, on a feature branch, detached; a repo with only `feat`; a leased
#     linked worktree two behind; one ahead; origin/HEAD naming `dev` with no
#     local dev; all five lines at once.
t5() { fresh; g repo worktree add -q --detach "$H/leased" main; g repo commit -q --allow-empty -m 2; g repo commit -q --allow-empty -m 3; }
fresh
says ""
fresh; g repo checkout -q -b feature
says "TANGLE: distro checkout on 'feature', not 'main' - fleet tooling may be mid-edit"
fresh; g repo checkout -q --detach
says "TANGLE: distro checkout on 'detached HEAD', not 'main' - fleet tooling may be mid-edit"
fresh; rm -rf "$NH/repo"; git init -q -b feat "$NH/repo"; g repo commit -q --allow-empty -m i
says ""
fresh; g repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev
says "TANGLE: distro checkout on 'main', not 'dev' - fleet tooling may be mid-edit"
GD_ENV=("AC_GUARD_ROOT=HOME/leased")
t5
says "WIP-TOOLING: running bin/ from 'HOME/leased', not the primary 'HOME/repo' - this may be a crewmate's leased worktree copy
DISTRO-LAG: running tree is 2 behind main"
fresh; g repo worktree add -q --detach "$NH/leased" main; g leased commit -q --allow-empty -m ahead
says "WIP-TOOLING: running bin/ from 'HOME/leased', not the primary 'HOME/repo' - this may be a crewmate's leased worktree copy"
t5; g repo checkout -q -b feature; crew; spoolrec
says "$WD
$QW
TANGLE: distro checkout on 'feature', not 'main' - fleet tooling may be mid-edit
WIP-TOOLING: running bin/ from 'HOME/leased', not the primary 'HOME/repo' - this may be a crewmate's leased worktree copy
DISTRO-LAG: running tree is 2 behind main"
assert_contains "$(shim_snap)" "sig= watcher-down wake-queue tangle wip-tooling distro-lag
at=$T" "row 10: the sig's token order"
GD_ENV=()

# 11. an AC_GUARD_ROOT that is no repo, or not there, is silent.
fresh; mkdir -p "$NH/plain"
for r in 'HOME/plain' 'HOME/nope'; do GD_ENV=("AC_GUARD_ROOT=$r" "AC_GUARD_QUIET=0"); says ""; done
GD_ENV=()

# 12. an unreadable stamp suppresses nothing and is left as it is (metaSet
#     refuses to rewrite what it cannot read).
if [ "$(id -u)" != 0 ]; then
  fresh; crew; stampf 'sig= watcher-down\nat=1\n'; chmod 000 "$NH/home/state/.guard-stamp"
  says "$WD"
  assert_eq "$(stat -f %Lp "$NH/home/state/.guard-stamp" 2>/dev/null || stat -c %a "$NH/home/state/.guard-stamp")" "0" "row 12: the stamp is left unreadable"
  chmod 644 "$NH/home/state/.guard-stamp"
fi

# 13. the clock: date reads the caller's stdin, once per call.
fresh; crew; : >"$NH/stub/date-reads"
printf 'one\ntwo\nthree\n' >"$TMP/stdin14"
GD_STDIN="$TMP/stdin14"; says "$WD"; unset GD_STDIN
assert_contains "$(shim_snap)" "date stdin=one
date +%s
date stdin=two" "row 13: each date reads the caller's stdin in turn"

# 14. THE ROOT SEAM: a lab copy of bin/ inside a scratch repo on a feature
#     branch, AC_GUARD_ROOT unset or empty - the lab names ITS root, where
#     import.meta.dir would name the distro checkout.
fresh; git init -q -b main "$NH/lab"; g lab commit -q --allow-empty -m init; g lab checkout -q -b feature
mkdir "$NH/lab/bin"; cp "$BIN"/*.sh "$NH/lab/bin/"; ln -s "$ROOT/src" "$NH/lab/src"
NOROOT=1; NBIN="$NH/lab/bin"
says "TANGLE: distro checkout on 'feature', not 'main' - fleet tooling may be mid-edit"
GD_ENV=("AC_GUARD_ROOT=" "AC_GUARD_QUIET=0")
says "TANGLE: distro checkout on 'feature', not 'main' - fleet tooling may be mid-edit"
NOROOT=0; NBIN="$BIN"; GD_ENV=()

# 15. a reader that closed stderr ends the guard at the write, 141, no stamp;
#     a closed stderr is exit 0 and a stamp of sig= and at= alone, no meta
#     lock left.
fresh; crew
epipe() {  # the guard's status with stderr a pipe nobody reads
  (cd "$NH/cwd" && env -u AC_SCOPE -u AC_GUARD_QUIET -u AC_GUARD_GRACE -u AC_BACKEND -u EPOCHSECONDS AC_HOME="$NH/home" AC_GUARD_ROOT="$NH/repo" PATH="$NH/stub:$PATH" LC_ALL=C \
    python3 -c 'import os, signal, sys
r, w = os.pipe(); os.close(r); os.dup2(w, 2); os.close(w)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execvp("bash", ["bash", "-c", "\"$0\"; echo $?", sys.argv[1]])' "$BIN/ac-guard.sh") </dev/null
}
assert_eq "$(epipe)" "141" "row 15: a closed reader is 141"
assert_no_file "$NH/home/state/.guard-stamp" "row 15: no stamp"
closed() {  # the guard's status with stderr closed
  (cd "$NH/cwd" && env -u AC_SCOPE -u AC_GUARD_QUIET -u AC_GUARD_GRACE -u AC_BACKEND -u EPOCHSECONDS AC_HOME="$NH/home" AC_GUARD_ROOT="$NH/repo" PATH="$NH/stub:$PATH" LC_ALL=C \
    bash -c '"$0" 2>&-; echo $?' "$BIN/ac-guard.sh") </dev/null
}
assert_eq "$(closed)" "0" "row 15: a closed stderr exits 0"
assert_eq "$(cat "$NH/home/state/.guard-stamp")" "sig= watcher-down
at=$T" "row 15: the stamp holds sig= and at="
assert_eq "$(ls -A "$NH/home/state")" ".guard-stamp
t1.meta" "row 15: no meta lock left"

# 16. the stamp's writes are silent: a state/ the meta lock cannot be taken in
#     prints the warnings alone and stamps nothing; an mv that fails after
#     moving prints nothing of its own.
if [ "$(id -u)" != 0 ]; then
  fresh; crew; chmod 555 "$NH/home/state"
  says "$WD"
  chmod 755 "$NH/home/state"
  assert_no_file "$NH/home/state/.guard-stamp" "row 16: nothing stamped"
fi
fresh; crew; printf '#!/bin/sh\n/bin/mv "$@"\necho "mv: refused" >&2\nexit 1\n' >"$NH/stub/mv"; chmod +x "$NH/stub/mv"
says "$WD"
assert_contains "$(shim_snap)" "== .guard-stamp
sig= watcher-down
at=$T" "row 16: the stamp mv moved is kept"

# --- the watcher-kill policy hook, case by case --------------------------------
# The payload bytes on stdin, the cwd $TMP, LC_ALL=C unless a row says otherwise.
wp_pl() { printf "$1" >"$TMP/wp.pl"; }  # wp_pl <printf format> - the payload bytes of the rows after it
wp_verdict() {  # wp_verdict <0|2> [env words...] - the hook's status on the payload, nothing on stdout
  local want="$1"
  shift
  wp_rc=0
  (cd "$TMP" && env "$@" LC_ALL="${WP_LC:-C}" "$BIN/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpn.out" 2>"$TMP/wpn.err" || wp_rc=$?
  assert_eq "$wp_rc:$(cat "$TMP/wpn.out")" "$want:" "policy verdict ($*): $(cat "$TMP/wp.pl")"
}
wp_cmd() {  # wp_cmd <0|2> <command> [env words...] - a Bash payload carrying <command>
  local want="$1"
  jq -cn --arg c "$2" '{tool_name:"Bash", tool_input:{command:$c}}' >"$TMP/wp.pl"
  shift 2
  wp_verdict "$want" "$@"
}
wp_path() {  # wp_path <dir> <tool...> - a PATH dir holding exactly these host tools
  local d="$1" t
  shift
  mkdir -p "$d"
  for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
}

# 1. each test's own reason.
wp_cmd 2 'killall -9 watchdog'
assert_contains "$(cat "$TMP/wpn.err")" "denied: pkill/killall pattern targets a watcher" "test 1 names its reason"
wp_cmd 2 'for p in $(pgrep x); do kill $p; done # watch'
assert_contains "$(cat "$TMP/wpn.err")" "denied: kill of pgrep-derived pids mentioning watch" "test 2 names its reason"
wp_cmd 2 'kill -9 ${my_watch}'
assert_contains "$(cat "$TMP/wpn.err")" "denied: kill of a watch-named variable" "test 3 names its reason"
wp_cmd 0 'mypkill -f ac-watch'
wp_cmd 2 'x;pkill ac-watch'
wp_cmd 0 'pkill -f x | grep watch'
wp_cmd 0 'kill $other; echo $watch'

# 2. the fold is tr's under the caller's locale, and [:alnum:] is grep's.
wp_cmd 2 'PKILL -F AC-WATCH'
WP_LC=en_US.UTF-8 wp_cmd 2 'PKILL -F AC-WATCH'
wp_cmd 2 'épkill -f ac-watch'
WP_LC=en_US.UTF-8 wp_cmd 0 'épkill -f ac-watch'

# 3. what reaches the tests, and the fail-open reads.
for p in '{"tool_name":"Read","tool_input":{"command":"pkill -f ac-watch"}}' \
         '{"tool_name":"Bash","tool_input":{"command":""}}' '{"tool_name":"Bash","tool_input":{}}' \
         '{"tool_name":"Bash"}' 'not json' '' '\n\n'; do
  wp_pl "$p"
  wp_verdict 0
done
for p in '{"tool_input":{"command":"pkill -f ac-watch"}}' \
         '{"tool_name":"Bash","tool_input":{"command":"pk\\u0000ill -f ac-watch"}}' \
         '{"tool_name":"Bash","tool_input":{"command":"pkill -f ac-watch"}} junk' \
         '{"tool_name":"Bash","tool_input":{"command":"x\351 pkill -f ac-watch"}}'; do
  wp_pl "$p"
  wp_verdict 2
done
wp_cmd 2 "$(printf 'ls\npkill -f ac-watch')"
# a command that is no JSON string denies on its TYPE, never judged by jq's
# text of it; a second JSON value in the payload is multiple documents, not a
# wider Bash name; a watch-naming argument past a line continuation is still
# one logical command, not a line of its own.
for p in '{"tool_name":"Bash","tool_input":{"command":["pkill","-f","ac-watch"]}}' \
         '{"tool_name":"Bash","tool_input":{"command":"pkill -f ac-watch"}}{"tool_name":"Bash","tool_input":{"command":"ls"}}'; do
  wp_pl "$p"
  wp_verdict 2
done
wp_cmd 2 "$(printf 'pkill -f \\\nac-watch')"
# a BARE LF is a statement separator, same as `;` - two unrelated lines must
# stay apart, or an everyday multi-line script (a plain kill on one line, an
# unrelated --watch dev command on another) would be denied for sharing a word
# across lines that were never one command.
wp_cmd 0 "$(printf 'kill 1234\necho $watchdir')"
# a missing jq allows.
wp_pl '{"tool_name":"Bash","tool_input":{"command":"pkill -f ac-watch"}}'
wp_path "$TMP/wp-nojq" bash env cat dirname tr grep bun
wp_verdict 0 PATH="$TMP/wp-nojq"

# --- the shim's own answers ----------------------------------------------------
# No bun on PATH: the shim denies at once, naming bun.
wp_path "$TMP/wp-nobun" bash env cat dirname jq tr grep
wp_verdict 2 PATH="$TMP/wp-nobun"
assert_contains "$(cat "$TMP/wpn.err")" "ac-watch-policy-hook.sh: REFUSED - bun is not on PATH" "no bun: the shim's denial names bun"
# A module that cannot load is the shim's no-op, never a refusal.
wp_lf="$TMP/wp-loadfail"
mkdir -p "$wp_lf/bin" "$wp_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-watch-policy-hook.sh" "$wp_lf/bin/"
printf 'throw new Error("watch policy cannot load");\n' >"$wp_lf/src/watch-policy-hook.ts"
n_rc=0; (cd "$TMP" && LC_ALL=C "$wp_lf/bin/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpn.out" 2>"$TMP/wpn.err" || n_rc=$?
assert_eq "$n_rc" "0" "a module that cannot load allows"
assert_eq "$(cat "$TMP/wpn.out")" "" "a module that cannot load prints nothing on stdout"
assert_contains "$(cat "$TMP/wpn.err")" "watch policy cannot load" "the load failure is bun's own diagnosis"
assert_contains "$(cat "$TMP/wpn.err")" "ac-watch-policy-hook.sh: src/watch-policy-hook.ts exited 1 - this hook did nothing" "the shim says it did nothing"
case "$(cat "$TMP/wpn.err")" in *"ac-watch-policy:"*) fail "a module that cannot load must never print the refusal" ;; esac

pass
