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
for s in ac-send.sh ac-peek.sh ac-spawn.sh ac-review-diff.sh ac-merge-local.sh; do
  grep -q 'ac-guard.sh' "$BIN/$s" || fail "guard call-site missing in $s"
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

# --- differential: src/guard.ts against the frozen bash original -------------
# DISPUTED: the implementation (tests/fixtures/ac-guard.sh under bash vs src/guard.ts through bin/ac-guard.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home, scratch repos under <side>, a stub dir <side>/stub first on PATH (`date +%s` answering <side>/stub/clock, a herdr and an orca keyed on files there, each call logged; every other date call is /bin/date's), the caller's cwd <side>/cwd - argv, env (every knob the guard reads scrubbed, then AC_HOME, AC_GUARD_ROOT=<side>/repo and the row's, the side root spelled HOME), stdin (/dev/null unless the row names a file), LC_ALL=C on both sides; exit status, stdout, stderr, the state/ listing, every stamp's bytes and the stub log compared whole (the side root spelled HOME, a temp's pid spelled PID).
unset AC_GUARD_ROOT
obin="$(make_oracle_bin ac-guard)"
OH="$TMP/side-o"; NH="$TMP/side-n"
T=1700000000
GD_ENV=(); GD_CWD=cwd; HOMELESS=0; NOROOT=0; NOISE=0
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL=C "PATH=$h/stub:$PATH")
  [ "$HOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  [ "$NOROOT" = 1 ] || e+=("AC_GUARD_ROOT=$h/repo")
  for x in ${GD_ENV[@]+"${GD_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  rm -f "$h/stub/log"
  (cd "$h/$GD_CWD" && env -u AC_HOME -u AC_SCOPE -u AC_GUARD_ROOT -u AC_GUARD_QUIET -u AC_GUARD_GRACE -u AC_BACKEND \
    -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u EPOCHSECONDS "${e[@]}" "$bin/${GD_ENTRY:-ac-guard.sh}" ${a[@]+"${a[@]}"}) \
    <"${GD_STDIN:-/dev/null}" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() { LC_ALL=C sed -e "s#$1#HOME#g" -E -e 's/\.tmp\.[0-9]+(\.[0-9]+)?/.tmp.PID/g'; }
snap() {  # snap <side root> - the state/ listing, every stamp's bytes (a directory's listing), the stub log
  local h="$1" f
  (cd "$h/home/state" 2>/dev/null && ls -A) || printf '(no state/)\n'
  for f in "$h/home/state"/.guard-stamp*; do
    [ -e "$f" ] || continue
    printf '== %s\n' "${f##*/}"
    if [ -d "$f" ]; then ls -A "$f"; else cat "$f" 2>/dev/null || printf '(unreadable)\n'; fi
  done
  printf '== log\n'; cat "$h/stub/log" 2>/dev/null || true
}
compare() {  # compare <o_rc> <n_rc> <what> - both sides' answers, normalized, byte-identical
  norm "$OH" <"$TMP/o.raw" >"$TMP/o.out"; norm "$OH" <"$TMP/o.err" >"$TMP/o.err2"
  norm "$NH" <"$TMP/n.raw" >"$TMP/n.out"; norm "$NH" <"$TMP/n.err" >"$TMP/n.err2"
  if [ "$NOISE" = 1 ]; then
    # Named (SHELL-OWN STDERR): the original's own `<script>: line N: ...` lines.
    /usr/bin/grep -Eq '^/[^ ]*: line [0-9]+: ' "$TMP/o.err2" || fail "differential: no shell noise to drop for $3"
    LC_ALL=C sed -E '/^\/[^ ]*: line [0-9]+: /d' "$TMP/o.err2" >"$TMP/o.err3"; mv "$TMP/o.err3" "$TMP/o.err2"
  fi
  snap "$OH" | norm "$OH" >"$TMP/o.snap"; snap "$NH" | norm "$NH" >"$TMP/n.snap"
  assert_eq "$2" "$1" "differential exit for $3"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for $3: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for $3: $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
  cmp -s "$TMP/o.snap" "$TMP/n.snap" || fail "differential state differs for $3: $(diff "$TMP/o.snap" "$TMP/n.snap" | head -n 8)"
}
NBIN="$BIN"
same() {  # same <args...> - the oracle on $OH and the shim on $NH answer byte-identically
  local o_rc=0 n_rc=0
  run_side "$obin" "$OH" o "$@" || o_rc=$?
  run_side "$NBIN" "$NH" n "$@" || n_rc=$?
  compare "$o_rc" "$n_rc" "'$*' (${GD_ENV[*]+${GD_ENV[*]}}) at line ${BASH_LINENO[0]}"
}
shim_err() { cat "$TMP/n.err2"; }
shim_snap() { cat "$TMP/n.snap"; }
shim_calls() { sed -n '/^== log$/,$p' "$TMP/n.snap" | /usr/bin/grep -E '^(herdr|orca) ' || true; }  # the backend calls the shim's run made
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
g() { git -C "$H/$1" -c user.email=t@t -c user.name=t "${@:2}"; }
fresh0() {  # a clean side: home/state, cwd, the stubs, the clock at T, the primary repo on main
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

# 1. the run: all clear is silent, exit 0, whatever the arguments (none are
#    read); homeless, an empty AC_HOME and one that cannot be entered are
#    silent 0 with nothing minted; a relative AC_HOME is the caller's cwd's.
both fresh
same
same -h
same bogus x
assert_eq "$(shim_err)" "" "row 1: all clear is silent"
HOMELESS=1; same; HOMELESS=0
GD_ENV=("AC_HOME="); same
GD_ENV=("AC_HOME=HOME/missing"); same
[ ! -e "$NH/missing" ] || fail "row 1: an unenterable home mints nothing"
noguard() { rm -rf "$H/home/state"; }
both noguard
GD_ENV=("AC_HOME=home"); GD_CWD=.
same
assert_eq "$(shim_err)" "" "row 1: a relative AC_HOME resolves from the caller's cwd (state/ minted, nothing in flight)"
[ -d "$NH/home/state" ] || fail "row 1: state/ is minted"
GD_ENV=(); GD_CWD=cwd

# 2. W1: a backend name that is neither herdr nor orca exits 1 with NOTHING
#    printed and nothing minted - from AC_BACKEND, config/backend, and the
#    AC_FLEET_STATE rung; an unreadable rung reads as none and the run goes on.
nostate() { fresh; rm -rf "$H/home/state"; mkdir -p "$H/fs/state" "$H/fs/config"; printf 'wezterm x\n' >"$H/fs/config/backend"; }
both nostate
GD_ENV=("AC_BACKEND=bogus"); same
assert_eq "$(cat "$TMP/n.raw" "$TMP/n.err")" "" "row 2 (W1): silent"
GD_ENV=("AC_FLEET_STATE=HOME/fs/state"); same
GD_ENV=("AC_FLEET_STATE=HOME/fs/state/"); same
cfgtmux() { mkdir -p "$H/home/config"; printf 'tmux\n' >"$H/home/config/backend"; }
both cfgtmux
GD_ENV=(); same
o_rc=0; run_side "$obin" "$OH" o || o_rc=$?
assert_eq "$o_rc" "1" "row 2 (W1): the original exits 1"
[ ! -e "$NH/home/state" ] || fail "row 2 (W1): nothing minted"
GD_ENV=("AC_BACKEND=orca"); same
[ -d "$NH/home/state" ] || fail "row 2: AC_BACKEND outranks config/backend"
if [ "$(id -u)" != 0 ]; then
  unreadable() { rm -f "$H/home/config/backend"; chmod 000 "$H/fs/config/backend"; crew; }
  both unreadable
  GD_ENV=("AC_FLEET_STATE=HOME/fs/state"); same
  assert_contains "$(shim_err)" "WATCHER-DOWN" "row 2: an unreadable fleet-state backend reads as none, the run goes on"
  readable() { chmod 644 "$H/fs/config/backend"; }
  both readable
fi
GD_ENV=()

# 3. WATCHER-DOWN: the line and the stamp's exact bytes; a repeat inside the
#    window is silent and leaves the stamp (the window runs from the FIRST
#    print); AC_GUARD_QUIET=0 reprints; a fresh beacon is silent and removes
#    the stamp.
seed3() { fresh; crew; }
both seed3
same
assert_eq "$(shim_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh" "row 3: the line"
assert_contains "$(shim_snap)" "== .guard-stamp
sig= watcher-down
at=$T" "row 3: the stamp keeps the token's leading space"
later() { clock "$((T + 59))\n"; }
both later
same
assert_eq "$(shim_err)" "" "row 3: a repeat inside the window is silent"
assert_contains "$(shim_snap)" "at=$T" "row 3: ... and leaves the stamp"
GD_ENV=("AC_GUARD_QUIET=0"); same; GD_ENV=()
assert_contains "$(shim_snap)" "at=$((T + 59))" "row 3: quiet=0 reprints and restamps"
fresh3() { beat "$((T + 59))"; }
both fresh3
same
assert_eq "$(shim_err)" "" "row 3: a fresh beacon is silent"
case "$(shim_snap)" in *"== .guard-stamp"*) fail "row 3: all-clear removes the stamp" ;; esac

# 4. the supervision set (crewMetas: verify and self skipped, chiefs counted,
#    the LAST kind= wins, CR kept - W8) and the meta list's arms: a directory
#    named *.meta ends the list with awk's own two lines (W6), a dangling
#    FIRST entry hides every meta, a later one counts (W7).
for body in 'kind=verify-qa\n' 'kind=self\n' 'kind=roomchief\n' 'kind=crewdeputy\n' 'kind=self\r\n' 'kind=self\nkind=ship\n' 'kind=ship\nkind=self\n' 'kind=ship\nkind=\n' 'project=p\n'; do
  seed4() { fresh; m k "$body"; }
  both seed4
  same
done
dirfirst() { fresh; mkdir "$H/home/state/a.meta"; crew; }
both dirfirst
same
assert_eq "$(shim_err)" "awk: i/o error occurred on HOME/home/state/a.meta
 source line number 7" "row 4 (W6): a directory first lists nothing, awk's own lines"
dirlast() { fresh; crew; mkdir "$H/home/state/z.meta"; }
both dirlast
same
assert_contains "$(shim_err)" "WATCHER-DOWN" "row 4 (W6): a directory after a crewmate still counts it"
danglefirst() { fresh; crew; ln -s nowhere "$H/home/state/a.meta"; }
both danglefirst
same
assert_eq "$(shim_err)" "" "row 4 (W7): a dangling first entry hides every meta"
danglemid() { fresh; m a 'kind=verify-x\n'; ln -s nowhere "$H/home/state/m.meta"; m z 'kind=self\n'; }
both danglemid
same
assert_contains "$(shim_err)" "WATCHER-DOWN" "row 4 (W7): a later dangling meta counts, kind-less"

# 5. the grace in `[ -gt ]`'s grammar, a beacon 400 s old (W2): blanks, a
#    sign and a leading zero are numbers; hex, a suffix, 2^63+ and an empty
#    string under `:-` are not / the default.
seed5() { fresh; crew; beat "$((T - 400))"; }
both seed5
for gr in ' 600 ' ' 399 ' '+600' '+399' '010' '0x10' '600abc' '99999999999999999999' '-5' '' '399' '400'; do
  GD_ENV=("AC_GUARD_QUIET=0" "AC_GUARD_GRACE=$gr")
  case "$gr" in 0x10|600abc|99999999999999999999) NOISE=1 ;; esac
  same
  NOISE=0
done
GD_ENV=("AC_GUARD_QUIET=0" "AC_GUARD_GRACE=0x10"); NOISE=1; same; NOISE=0
assert_eq "$(shim_err)" "" "row 5 (W2): a grace that is no number never fires"
GD_ENV=("AC_GUARD_QUIET=0" "AC_GUARD_GRACE=010"); same
assert_contains "$(shim_err)" "WATCHER-DOWN" "row 5 (W2): 010 is ten to [ -gt ]"
GD_ENV=()

# 6. the quiet window in `[ -lt ]`'s grammar, the same sig stamped 9 s ago
#    (W3): a value that is no number never suppresses.
for q in abc '' ' 600 ' '0x10' '1e3' '+20' '5' '010'; do
  seed6() { fresh; crew; stampf "sig= watcher-down\nat=$((T - 9))\n"; }
  both seed6
  GD_ENV=("AC_GUARD_QUIET=$q")
  case "$q" in abc|0x10|1e3) NOISE=1 ;; esac
  same
  NOISE=0
done
GD_ENV=("AC_GUARD_QUIET=abc"); both seed6; NOISE=1; same; NOISE=0
assert_contains "$(shim_err)" "WATCHER-DOWN" "row 6 (W3): a quiet that is no number never suppresses"
GD_ENV=("AC_GUARD_QUIET=010"); both seed6; same
assert_eq "$(shim_err)" "" "row 6 (W3): 010 is ten - suppressed"
GD_ENV=()

# 7. the stamp's at= through `$(( ))` (W4), the clock at 1000: a leading 0 is
#    OCTAL (01000 is 512 - it prints where a decimal 1000 would not), 0099 an
#    evaluation error (no suppression), 2^64+ wraps (suppressed), a value with
#    a non-digit reads 0.
for at in 01000 0012 0099 00 '-5' 99999999999999999999 abc 990 ' 990' 01750; do
  seed7() { fresh; clock '1000\n'; crew; stampf "sig= watcher-down\nat=$at\n"; }
  both seed7
  [ "$at" = 0099 ] && NOISE=1
  same
  NOISE=0
done
clk7() { clock '1000\n'; stampf 'sig= watcher-down\nat=01000\n'; }; both clk7
same
assert_contains "$(shim_err)" "WATCHER-DOWN" "row 7 (W4): at=01000 is octal 512 - outside the window"
clk7b() { stampf 'sig= watcher-down\nat=99999999999999999999\n'; }; both clk7b
same
assert_eq "$(shim_err)" "" "row 7 (W4): a wrapped at= suppresses"

# 8. QUEUED WAKES: the fleet spool's records (a subdirectory counts; a
#    dotfile, a dangling link, a spool that is a file do not), a roomchief's
#    own spool only, and a MALFORMED scope asks the fleet's spool and never
#    the orphans (W5).
q1() { fresh; spoolrec; }
q2() { fresh; mkdir -p "$H/home/state/.wake-spool"; : >"$H/home/state/.wake-spool/.dot"; }
q3() { fresh; mkdir -p "$H/home/state/.wake-spool"; ln -s nowhere "$H/home/state/.wake-spool/l"; }
q4() { fresh; mkdir -p "$H/home/state/.wake-spool/sub"; }
q5() { fresh; : >"$H/home/state/.wake-spool"; }
for q in q1 q2 q3 q4 q5; do both "$q"; same; done
both q1; same
assert_eq "$(shim_err)" "QUEUED WAKES: run bin/ac-wake-drain.sh" "row 8: a record nudges"
scoped() { fresh; spoolrec; spoolrec fam2; }
both scoped
GD_ENV=("AC_SCOPE=fam1"); same
assert_eq "$(shim_err)" "" "row 8: a roomchief ignores the fleet's and a sibling's spools"
own() { spoolrec fam1; }
both own
same
assert_contains "$(shim_snap)" "== .guard-stamp.fam1" "row 8: a roomchief stamps its own"
w5() { fresh; spoolrec orph; }
both w5
GD_ENV=("AC_SCOPE=a.b"); same
assert_eq "$(shim_err)" "" "row 8 (W5): a malformed scope never hears an orphan family"
w5b() { spoolrec; }
both w5b
same
assert_contains "$(shim_snap)" "== .guard-stamp
sig= wake-queue" "row 8 (W5): ... but asks the fleet spool, on the fleet stamp"
GD_ENV=()

# 9. orphans through backendCall: a family spool with no chief meta is an
#    orphan with no backend call; with one, only the driver's 0 is live -
#    herdr's pane get, then pane list (an empty list: gone), then status
#    server (running:false gone, true unreadable - both orphans); no pane
#    handle (no call), orca's terminal show, a refused backend name (no call),
#    a configured session (argv and HERDR_SESSION), a hung herdr bounded by
#    AC_HERDR_RPC_TIMEOUT. The answering family sorts LAST; a chief meta is
#    crew in flight (kind-less counts), so every side has a fresh beacon.
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
for o in o1 o2 o3 o4 o5 o6 o7 o8 o9 o10; do both "$o"; same; done
both o2
same
assert_eq "$(shim_err)" "" "row 9: a live family's spool is its chief's"
assert_eq "$(shim_calls)" "herdr pane get pzz []" "row 9: one pane get"
both o3
same
assert_eq "$(shim_err)" "QUEUED WAKES: run bin/ac-wake-drain.sh" "row 9: an orphan family's records nudge the fleet"
both o9
same
assert_eq "$(shim_calls)" "" "row 9: a refused backend name is an orphan, no call"
both o3
GD_ENV=("AC_HERDR_SESSION=s1"); same
assert_contains "$(shim_snap)" "herdr pane get pzz --session s1 [s1]" "row 9: the session rides argv and HERDR_SESSION"
hang() { : >"$H/stub/hang"; }
both hang
GD_ENV=("AC_HERDR_RPC_TIMEOUT=1" "AC_GUARD_QUIET=0"); same
assert_eq "$(shim_calls)" "herdr pane get pzz []
herdr pane list []
herdr status server --json []" "row 9: a hung herdr - three bounded calls, an orphan"
assert_eq "$(shim_err)" "QUEUED WAKES: run bin/ac-wake-drain.sh" "row 9: ... nudged, exit 0"
GD_ENV=()

# Named (THE ORPHAN SCAN RACE): past the answering orphan, the original's
# liveness producer went on probing after the guard had exited; the port
# stops at the answer.
race() { fresh; spoolrec aa; chief aa 'backend=herdr\n' paa; chief bb 'backend=herdr\n' pbb; mkdir -p "$H/home/state/.wake-spool.bb"; }
both race
o_rc=0; run_side "$obin" "$OH" o || o_rc=$?
n_rc=0; run_side "$NBIN" "$NH" n || n_rc=$?
# The producer's last call lands after the guard is gone: wait it out, so no
# late write reaches the next row's log.
i=0; until [ "$(/usr/bin/grep -c . "$OH/stub/log" 2>/dev/null)" = 4 ]; do i=$((i + 1)); [ "$i" -lt 100 ] || break; sleep 0.1; done
assert_eq "$o_rc $n_rc $(cat "$TMP/o.err") | $(cat "$TMP/n.err")" "0 0 QUEUED WAKES: run bin/ac-wake-drain.sh | QUEUED WAKES: run bin/ac-wake-drain.sh" "row 9 (race): the same answer"
assert_contains "$(cat "$OH/stub/log")" "herdr pane get pbb" "row 9 (race): the original probed past its answer"
case "$(cat "$NH/stub/log")" in *pbb*) fail "row 9 (race): the port stops at the answer" ;; esac
# The herdr driver backgrounds the CLI inside the original's subshell, where
# bash hands it /dev/null: a herdr that reads stdin reads nothing on either
# side, the caller's stdin included.
swallow() { fresh; chief aa 'backend=herdr\n' paa; mkdir -p "$H/home/state/.wake-spool.aa"; spoolrec bb; : >"$H/stub/readstdin"; }
both swallow
printf 'caller-stdin\n' >"$TMP/stdin9"
GD_STDIN="$TMP/stdin9"; same; unset GD_STDIN
assert_contains "$(shim_snap)" "herdr stdin=[]" "row 9 (stdin): herdr reads nothing"
assert_eq "$(shim_err)" "QUEUED WAKES: run bin/ac-wake-drain.sh" "row 9 (stdin): every family is scanned"
# Named: the orca CLI ran in a command substitution whose stdin was the
# family-list pipe - an orca that reads stdin swallowed the families after
# it, so they went unheard; the port's driver children read /dev/null.
swallow_orca() { fresh; chief aa 'backend=orca\n' haa; mkdir -p "$H/home/state/.wake-spool.aa"; spoolrec bb; : >"$H/stub/readstdin"; }
both swallow_orca
o_rc=0; run_side "$obin" "$OH" o || o_rc=$?
n_rc=0; run_side "$NBIN" "$NH" n || n_rc=$?
assert_contains "$(cat "$OH/stub/log")" "orca stdin=[$OH/home/state/.wake-spool.bb]" "row 9 (orca stdin): the original's orca read the rest of the family list"
assert_contains "$(cat "$NH/stub/log")" "orca stdin=[]" "row 9 (orca stdin): the port's reads nothing (named)"
assert_eq "$o_rc $n_rc $(cat "$TMP/o.err") | $(cat "$TMP/n.err")" "0 0  | QUEUED WAKES: run bin/ac-wake-drain.sh" "row 9 (orca stdin): the swallowed family went unheard there"

fresh() { fresh0; }

# 10. TANGLE / WIP-TOOLING / DISTRO-LAG over scratch repos: the primary on
#     main, on a feature branch, detached; a repo with only `feat`; a leased
#     linked worktree two behind; one ahead; origin/HEAD naming `dev` with no
#     local dev; all five lines at once.
t1() { fresh; }
t2() { fresh; g repo checkout -q -b feature; }
t3() { fresh; g repo checkout -q --detach; }
t4() { fresh; rm -rf "$H/repo"; git init -q -b feat "$H/repo"; g repo commit -q --allow-empty -m i; }
t5() { fresh; g repo worktree add -q --detach "$H/leased" main; g repo commit -q --allow-empty -m 2; g repo commit -q --allow-empty -m 3; }
t6() { fresh; g repo worktree add -q --detach "$H/leased" main; g leased commit -q --allow-empty -m ahead; }
t7() { fresh; g repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev; }
for t in t1 t2 t3 t4 t7; do both "$t"; same; done
both t3; same
assert_eq "$(shim_err)" "TANGLE: distro checkout on 'detached HEAD', not 'main' - fleet tooling may be mid-edit" "row 10: detached"
both t7; same
assert_eq "$(shim_err)" "TANGLE: distro checkout on 'main', not 'dev' - fleet tooling may be mid-edit" "row 10: origin/HEAD with no local ref, no LAG"
GD_ENV=("AC_GUARD_ROOT=HOME/leased")
both t5; same
assert_eq "$(shim_err)" "WIP-TOOLING: running bin/ from 'HOME/leased', not the primary 'HOME/repo' - this may be a crewmate's leased worktree copy
DISTRO-LAG: running tree is 2 behind main" "row 10: leased, two behind"
both t6; same
assert_eq "$(shim_err)" "WIP-TOOLING: running bin/ from 'HOME/leased', not the primary 'HOME/repo' - this may be a crewmate's leased worktree copy" "row 10: ahead is no lag"
all5() { t5; g repo checkout -q -b feature; crew; spoolrec; }
both all5; same
assert_eq "$(shim_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
QUEUED WAKES: run bin/ac-wake-drain.sh
TANGLE: distro checkout on 'feature', not 'main' - fleet tooling may be mid-edit
WIP-TOOLING: running bin/ from 'HOME/leased', not the primary 'HOME/repo' - this may be a crewmate's leased worktree copy
DISTRO-LAG: running tree is 2 behind main" "row 10: all five, in order"
assert_contains "$(shim_snap)" "sig= watcher-down wake-queue tangle wip-tooling distro-lag
at=$T" "row 10: the sig's token order"
GD_ENV=()

# 11. W10: any spelling of the primary but git's fires WIP-TOOLING - a
#     trailing slash, a symlink, a subdirectory; a path that is no repo, or
#     not there, is silent.
w10() { fresh; mkdir -p "$H/repo/sub" "$H/plain"; ln -s "$H/repo" "$H/link"; }
both w10
for r in 'HOME/repo/' 'HOME/link' 'HOME/repo/sub' 'HOME/plain' 'HOME/nope'; do GD_ENV=("AC_GUARD_ROOT=$r" "AC_GUARD_QUIET=0"); same; done
GD_ENV=("AC_GUARD_ROOT=HOME/repo/" "AC_GUARD_QUIET=0"); same
assert_contains "$(shim_err)" "WIP-TOOLING: running bin/ from 'HOME/repo/', not the primary 'HOME/repo'" "row 11 (W10): a trailing slash"
GD_ENV=("AC_GUARD_ROOT=repo" "AC_GUARD_QUIET=0"); GD_CWD=.; same; GD_CWD=cwd
assert_contains "$(shim_err)" "WIP-TOOLING: running bin/ from 'repo', not the primary 'HOME/repo'" "row 11 (W10): a relative root, from the caller's cwd"
GD_ENV=()

# 12. W9: a directory at the stamp path - the temps are moved INTO it and
#     nothing suppresses the rerun; an all-clear run prints rm's own line.
w9() { fresh; crew; mkdir "$H/home/state/.guard-stamp"; }
both w9
same
same
assert_contains "$(shim_snap)" "== .guard-stamp
.guard-stamp.tmp.PID" "row 12 (W9): the temp moved into the directory"
assert_contains "$(shim_err)" "WATCHER-DOWN" "row 12 (W9): no suppression"
w9b() { rm -f "$H/home/state/t1.meta"; }
both w9b
same
assert_eq "$(shim_err)" "rm: HOME/home/state/.guard-stamp: is a directory" "row 12 (W9): rm's own line"

# 13. W13 (named): an unreadable stamp - both print; the original rewrote it
#     as a fresh 0644 file, the port leaves it unreadable.
if [ "$(id -u)" != 0 ]; then
  w13() { fresh; crew; stampf 'sig= watcher-down\nat=1\n'; chmod 000 "$H/home/state/.guard-stamp"; }
  both w13
  o_rc=0; run_side "$obin" "$OH" o || o_rc=$?
  n_rc=0; run_side "$NBIN" "$NH" n || n_rc=$?
  assert_eq "$o_rc $n_rc $(cat "$TMP/o.err") | $(cat "$TMP/n.err")" "0 0 WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh | WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh" "row 13 (W13): both print"
  assert_eq "$(cat "$OH/home/state/.guard-stamp")" "sig= watcher-down
at=$T" "row 13 (W13): the original rewrote it"
  assert_eq "$(stat -f %Lp "$NH/home/state/.guard-stamp" 2>/dev/null || stat -c %a "$NH/home/state/.guard-stamp")" "0" "row 13 (W13): the port left it (named)"
  chmod 644 "$NH/home/state/.guard-stamp"
fi

# 14. the clock: date's text through `$(( ))` - empty is 0 (no WATCHER-DOWN
#     with no beacon), `12abc` an evaluation error (WATCHER-DOWN dropped, the
#     rest printed, at=12abc kept raw), `garbage` set -u's abort (exit 0,
#     nothing printed, no stamp - W12); date reads the caller's stdin, once
#     per call. W11: an exported EPOCHSECONDS IS the clock on both sides (bash
#     3.2 has no such builtin) - no date call, its text stamped raw, one that
#     is no number read as date's text is.
c1() { fresh; crew; spoolrec; clock ''; }
c2() { fresh; crew; spoolrec; clock '12abc\n'; }
c3() { fresh; crew; spoolrec; clock 'garbage\n'; }
c4() { fresh; crew; spoolrec; clock ' 77 \n'; }
both c1; same
assert_eq "$(shim_err)" "QUEUED WAKES: run bin/ac-wake-drain.sh" "row 14: an empty clock is 0"
both c2; NOISE=1; same; NOISE=0
assert_contains "$(shim_snap)" "at=12abc" "row 14: the clock's text is stamped raw"
both c3; NOISE=1; same; NOISE=0
assert_eq "$(shim_err)" "" "row 14 (W12): set -u's abort prints nothing"
case "$(shim_snap)" in *"== .guard-stamp"*) fail "row 14 (W12): no stamp" ;; esac
both c4; same
c5() { fresh; spoolrec; stampf 'sig= wake-queue\nat=5\n'; clock 'garbage\n'; }
both c5; NOISE=1; same; NOISE=0
assert_eq "$(shim_err)" "" "row 14 (W12): the abort at the window too"
c6() { fresh; crew; : >"$H/stub/date-reads"; }
both c6
printf 'one\ntwo\nthree\n' >"$TMP/stdin14"
GD_STDIN="$TMP/stdin14"; same; unset GD_STDIN
assert_contains "$(shim_snap)" "date stdin=one
date +%s
date stdin=two" "row 14: each date reads the caller's stdin in turn"
c7() { fresh; crew; beat "$T"; }
both c7
GD_ENV=("EPOCHSECONDS=9999999999"); same
assert_eq "$(shim_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh" "row 14 (W11): the variable is the clock"
assert_eq "$(sed -n '/^== .guard-stamp$/,$p' "$TMP/n.snap")" "== .guard-stamp
sig= watcher-down
at=9999999999
== log" "row 14 (W11): stamped from it, no date call"
c8() { fresh; crew; }
both c8
GD_ENV=("EPOCHSECONDS=garbage"); NOISE=1; same; NOISE=0
assert_eq "$(shim_err)" "" "row 14 (W11, W12): a clock variable that is no number aborts alike"
GD_ENV=()

# 15. THE ROOT SEAM: a lab copy of bin/ inside a scratch repo on a feature
#     branch, AC_GUARD_ROOT unset or empty - each side names ITS lab root,
#     where import.meta.dir would name the distro checkout.
lab() {  # lab <bin to copy> - <side>/lab: a repo on `feature` holding bin/ and a src link
  fresh; git init -q -b main "$H/lab"; g lab commit -q --allow-empty -m init; g lab checkout -q -b feature
  mkdir "$H/lab/bin"; cp "$1"/*.sh "$H/lab/bin/"; ln -s "$ROOT/src" "$H/lab/src"
}
H="$OH"; lab "$obin"; H="$NH"; lab "$BIN"
NOROOT=1
o_rc=0; run_side "$OH/lab/bin" "$OH" o || o_rc=$?
n_rc=0; run_side "$NH/lab/bin" "$NH" n || n_rc=$?
compare "$o_rc" "$n_rc" "row 15: the lab root"
assert_eq "$(shim_err)" "TANGLE: distro checkout on 'feature', not 'main' - fleet tooling may be mid-edit" "row 15: the lab's own branch"
GD_ENV=("AC_GUARD_ROOT=" "AC_GUARD_QUIET=0")
o_rc=0; run_side "$OH/lab/bin" "$OH" o || o_rc=$?
n_rc=0; run_side "$NH/lab/bin" "$NH" n || n_rc=$?
compare "$o_rc" "$n_rc" "row 15: an empty AC_GUARD_ROOT is the started root"
assert_contains "$(shim_err)" "TANGLE: distro checkout on 'feature'" "row 15: ... named again"
NOROOT=0; GD_ENV=()

# 16. the ride-along: ac-send.sh (bash) runs the guard beside it - the
#     advisory before its own usage die; a reader that closed stderr ends the
#     guard at the write, 141, no stamp; a closed stderr is exit 0 and a
#     stamp of sig= and at= alone on both sides. The original's block write
#     fails into the pipe bash 3.2 left on the free fd 2, and its bytes stay
#     in the printf builtin's buffer until the next builtin output with a
#     redirection: once that was ac_meta_set's temp, so the stamp took the
#     block; now it is the meta lock's pid file, which the next writer
#     reclaims as a dead owner's.
s16() { fresh; crew; }
both s16
GD_ENTRY=ac-send.sh; same; GD_ENTRY=
assert_eq "$(shim_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
ERROR: usage: ac-send.sh <id> [--force] '<text>' | --key <key>" "row 16: the advisory, then ac-send's own line"
both s16
epipe() {  # epipe <bin> <side root> - the guard's status with stderr a pipe nobody reads
  (cd "$2/cwd" && env -u AC_SCOPE -u AC_GUARD_QUIET -u AC_GUARD_GRACE -u AC_BACKEND -u EPOCHSECONDS AC_HOME="$2/home" AC_GUARD_ROOT="$2/repo" PATH="$2/stub:$PATH" LC_ALL=C \
    python3 -c 'import os, signal, sys
r, w = os.pipe(); os.close(r); os.dup2(w, 2); os.close(w)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execvp("bash", ["bash", "-c", "\"$0\"; echo $?", sys.argv[1]])' "$1/ac-guard.sh") </dev/null
}
assert_eq "$(epipe "$obin" "$OH") $(epipe "$NBIN" "$NH")" "141 141" "row 16: a closed reader is 141 on both sides"
assert_no_file "$OH/home/state/.guard-stamp" "row 16: no stamp (original)"
assert_no_file "$NH/home/state/.guard-stamp" "row 16: no stamp (port)"
closed() {  # closed <bin> <side root> - the guard's status with stderr closed
  (cd "$2/cwd" && env -u AC_SCOPE -u AC_GUARD_QUIET -u AC_GUARD_GRACE -u AC_BACKEND -u EPOCHSECONDS AC_HOME="$2/home" AC_GUARD_ROOT="$2/repo" PATH="$2/stub:$PATH" LC_ALL=C \
    bash -c '"$0" 2>&-; echo $?' "$1/ac-guard.sh") </dev/null
}
assert_eq "$(closed "$obin" "$OH") $(closed "$NBIN" "$NH")" "0 0" "row 16: a closed stderr exits 0 on both sides"
assert_eq "$(cat "$OH/home/state/.guard-stamp")" "sig= watcher-down
at=$T" "row 16: the original's stamp holds sig= and at="
assert_eq "$(cat "$NH/home/state/.guard-stamp")" "sig= watcher-down
at=$T" "row 16: the port's holds sig= and at="
assert_eq "$(ls -A "$OH/home/state") | $(ls -A "$NH/home/state")" ".guard-stamp
t1.meta | .guard-stamp
t1.meta" "row 16: no meta lock left on either side"

# 17. the stamp's writes are silent as the original's `2>/dev/null` made them:
#     a state/ the meta lock cannot be taken in prints the warnings alone and
#     stamps nothing; an mv that fails after moving prints nothing of its own.
if [ "$(id -u)" != 0 ]; then
  rostate() { fresh; crew; chmod 555 "$H/home/state"; }
  both rostate
  same
  assert_eq "$(shim_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh" "row 17: no lock refusal line"
  rwstate() { chmod 755 "$H/home/state"; }
  both rwstate
fi
failmv() { fresh; crew; printf '#!/bin/sh\n/bin/mv "$@"\necho "mv: refused" >&2\nexit 1\n' >"$H/stub/mv"; chmod +x "$H/stub/mv"; }
both failmv
same
assert_eq "$(shim_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh" "row 17: no line from a failing mv"
assert_contains "$(shim_snap)" "== .guard-stamp
sig= watcher-down
at=$T" "row 17: the stamp mv moved is kept"

# --- differential: src/watch-policy-hook.ts against the frozen bash original -
# DISPUTED: the implementation (tests/fixtures/ac-watch-policy-hook.sh under bash vs src/watch-policy-hook.ts through bin/ac-watch-policy-hook.sh)
# HELD-CONSTANT: the payload bytes on stdin, the environment (PATH; LC_ALL=C unless a row says otherwise), the cwd ($TMP); stdout, stderr and exit status compared whole
wpobin="$(make_oracle_bin ac-watch-policy-hook)"
cmp -s "$wpobin/ac-watch-policy-hook.sh" "$ROOT/tests/fixtures/ac-watch-policy-hook.sh" \
  || fail "the policy oracle bin must hold the frozen original"
wp_pl() { printf "$1" >"$TMP/wp.pl"; }  # wp_pl <printf format> - the payload bytes of the rows after it
wp_same() {  # wp_same [env words...] - both sides judge alike; the port's status lands in wp_rc
  local o_rc=0
  wp_rc=0
  (cd "$TMP" && env "$@" LC_ALL="${WP_LC:-C}" "$wpobin/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpo.out" 2>"$TMP/wpo.err" || o_rc=$?
  (cd "$TMP" && env "$@" LC_ALL="${WP_LC:-C}" "$BIN/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpn.out" 2>"$TMP/wpn.err" || wp_rc=$?
  assert_eq "$wp_rc" "$o_rc" "policy differential exit ($*): $(cat "$TMP/wp.pl")"
  cmp -s "$TMP/wpo.out" "$TMP/wpn.out" || fail "policy differential stdout differs ($*): $(diff "$TMP/wpo.out" "$TMP/wpn.out" | head -n 4)"
  cmp -s "$TMP/wpo.err" "$TMP/wpn.err" || fail "policy differential stderr differs ($*): $(diff "$TMP/wpo.err" "$TMP/wpn.err" | head -n 4)"
}
wp_verdict() {  # wp_verdict <0|2> [env words...] - wp_same, and the verdict itself pinned
  local want="$1"
  shift
  wp_same "$@"
  assert_eq "$wp_rc" "$want" "policy verdict ($*): $(cat "$TMP/wp.pl")"
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

# 1. the black-box cases, and each test's own reason.
for c in "${deny_cases[@]}"; do wp_cmd 2 "$c"; done
for c in "${allow_cases[@]}"; do wp_cmd 0 "$c"; done
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
# AT PARITY: the command is jq's text, and a second value joins the name.
for p in '{"tool_name":"Bash","tool_input":{"command":["pkill","-f","ac-watch"]}}' \
         '{"tool_name":"Bash","tool_input":{"command":"pkill -f ac-watch"}}{"tool_name":"Bash","tool_input":{"command":"ls"}}'; do
  wp_pl "$p"
  wp_verdict 0
done
# AT PARITY: grep reads lines, so a continued line carries the target past it.
wp_cmd 0 "$(printf 'pkill -f \\\nac-watch')"
wp_cmd 2 "$(printf 'ls\npkill -f ac-watch')"
# a missing jq allows on both sides.
wp_pl '{"tool_name":"Bash","tool_input":{"command":"pkill -f ac-watch"}}'
wp_path "$TMP/wp-nojq" bash env cat dirname tr grep bun
wp_verdict 0 PATH="$TMP/wp-nojq"

# --- named divergences: each row asserts both sides ---------------------------
# SHELL-OWN STDERR: tr or grep that cannot start reads as no text or no match
# on both sides, so the command is allowed; the `command not found` line is
# bash's.
for missing in tr grep; do
  case "$missing" in tr) keep=grep ;; grep) keep=tr ;; esac
  wp_path "$TMP/wp-no$missing" bash env cat dirname jq bun "$keep"
  o_rc=0; (cd "$TMP" && PATH="$TMP/wp-no$missing" LC_ALL=C "$wpobin/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpo.out" 2>"$TMP/wpo.err" || o_rc=$?
  n_rc=0; (cd "$TMP" && PATH="$TMP/wp-no$missing" LC_ALL=C "$BIN/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpn.out" 2>"$TMP/wpn.err" || n_rc=$?
  assert_eq "$o_rc $n_rc" "0 0" "SHELL-OWN: no $missing allows on both sides"
  assert_eq "$(cat "$TMP/wpo.out" "$TMP/wpn.out")" "" "SHELL-OWN: no $missing prints nothing on stdout"
  assert_contains "$(cat "$TMP/wpo.err")" "$missing: command not found" "SHELL-OWN: the original's line is bash's"
  assert_eq "$(cat "$TMP/wpn.err")" "" "SHELL-OWN: the port adds no line of its own (no $missing)"
done
# BUN: no bun on PATH - the shim denies at once, naming bun, where the
# original (bash, jq, tr and grep) judged.
wp_path "$TMP/wp-nobun" bash env cat dirname jq tr grep
o_rc=0; (cd "$TMP" && PATH="$TMP/wp-nobun" LC_ALL=C "$wpobin/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpo.out" 2>"$TMP/wpo.err" || o_rc=$?
n_rc=0; (cd "$TMP" && PATH="$TMP/wp-nobun" LC_ALL=C "$BIN/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpn.out" 2>"$TMP/wpn.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "2 2" "BUN: the original and the shim both deny with no bun on PATH"
assert_contains "$(cat "$TMP/wpo.err")" "ac-watch-policy: denied: pkill/killall pattern targets a watcher" "BUN: the original's refusal"
assert_eq "$(cat "$TMP/wpn.out")" "" "BUN: the shim's denial writes nothing on stdout"
assert_contains "$(cat "$TMP/wpn.err")" "ac-watch-policy-hook.sh: REFUSED - bun is not on PATH" "BUN: the shim's denial names bun"
# BUN: a module that cannot load is the shim's no-op, never a refusal.
wp_lf="$TMP/wp-loadfail"
mkdir -p "$wp_lf/bin" "$wp_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-watch-policy-hook.sh" "$wp_lf/bin/"
printf 'throw new Error("watch policy cannot load");\n' >"$wp_lf/src/watch-policy-hook.ts"
n_rc=0; (cd "$TMP" && LC_ALL=C "$wp_lf/bin/ac-watch-policy-hook.sh" <"$TMP/wp.pl") >"$TMP/wpn.out" 2>"$TMP/wpn.err" || n_rc=$?
assert_eq "$n_rc" "0" "BUN: a module that cannot load allows"
assert_eq "$(cat "$TMP/wpn.out")" "" "BUN: a module that cannot load prints nothing on stdout"
assert_contains "$(cat "$TMP/wpn.err")" "watch policy cannot load" "BUN: the load failure is bun's own diagnosis"
assert_contains "$(cat "$TMP/wpn.err")" "ac-watch-policy-hook.sh: src/watch-policy-hook.ts exited 1 - this hook did nothing" "BUN: the shim says it did nothing"
case "$(cat "$TMP/wpn.err")" in *"ac-watch-policy:"*) fail "BUN: a module that cannot load must never print the refusal" ;; esac

pass
