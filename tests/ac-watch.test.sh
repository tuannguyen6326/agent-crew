#!/usr/bin/env bash
# ac-watch.test.sh - watcher semantics: the durable wake queue + drain +
# turn-end guard predicate (backend-free), then scope routing, liveness and
# marker passes driven through the file-backed fake herdr CLI (helpers.sh).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
state="$AC_HOME/state"

fleet_spool() {
  # The fleet spool's records, concatenated ('' when none) - producers
  # publish one record per file (ac_wake_publish), so content asserts read
  # the spool where they used to read the legacy queue file.
  cat "$state"/.wake-spool/* 2>/dev/null || true
}

fam_spool() {
  # fam_spool <fam> - a family spool's records, concatenated.
  cat "$state/.wake-spool.$1"/* 2>/dev/null || true
}

# Drain with nothing queued.
assert_contains "$("$BIN/ac-wake-drain.sh")" "no queued wakes" "empty drain"

# Queued wakes drain atomically, oldest first, then the spool is empty.
mkdir -p "$state/.wake-spool"
printf '1\treport\tt1\tdone: shipped\n' >"$state/.wake-spool/1.1.000000"
printf '2\tstale\tt2\tquiet for 300s\n' >"$state/.wake-spool/1.1.000001"
out="$("$BIN/ac-wake-drain.sh")"
assert_contains "$out" "report t1 done: shipped" "wake 1"
assert_contains "$out" "stale t2 quiet for 300s" "wake 2"
assert_eq "$(find "$state/.wake-spool" -type f | wc -l | tr -d ' ')" "0" "spool consumed"

# Guard: nothing in flight -> allow (exit 0).
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "guard should allow with no crew"

# Guard: crew in flight + stale beacon -> block (exit 2).
printf 'window=crew:t9\n' >"$state/t9.meta"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "guard blocks on stale beacon"

# Guard: fresh beacon -> allow.
date +%s >"$state/.last-watcher-beat"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "guard should allow with fresh beacon"

# Guard: queued wakes always block, even with a fresh beacon.
printf '3\treport\tt9\tdone: x\n' >"$state/.wake-spool/1.1.000002"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "guard blocks on queued wakes"

# Guard: stop_hook_active loop protection -> allow.
printf '{"stop_hook_active":true}' | "$BIN/ac-turnend-guard.sh" || fail "loop guard"

# Guard: an EMPTY spool dir is litter and never blocks - [ -s ] on a
# directory is true, and that trap must not leak into the predicate.
rm -f "$state/.wake-spool"/*
mkdir -p "$state/.wake-spool"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "an empty spool dir must not block a turn end"
printf '3\treport\tt9\tdone: x\n' >"$state/.wake-spool/3.1.000000"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "guard blocks on queued spool records"
rm -rf "$state/.wake-spool"

# Guard: a roomchief/crewdeputy meta is NOT crew-in-flight - a chief pane must
# not count ITSELF and be nagged for coverage it does not owe. Only ship/scout
# (and any unknown/absent kind, counted fail-safe) demand coverage.
rm -f "$state"/*.meta "$state/.last-watcher-beat"
printf 'kind=roomchief\nwindow=crew:fam1-chief\n' >"$state/fam1-chief.meta"
printf 'kind=crewdeputy\n' >"$state/dep.meta"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "roomchief/crewdeputy metas alone are not crew in flight"
printf 'kind=verify-codereview\n' >"$state/vfy.meta"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "a verifier meta alone is supervised runtime, not crew in flight"
mkdir -p "$state/.wake-spool"
printf '3\treport\tvfy\tdone: inspect verifier\n' >"$state/.wake-spool/1.1.000003"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "a queued verifier wake still blocks turn end"
rm -rf "$state/.wake-spool"
printf 'kind=ship\n' >"$state/t9.meta"
err="$TMP/verifier-plus-crew.err"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>"$err" || rc=$?
assert_eq "$rc" "2" "a real ship meta still counts as crew in flight"
assert_contains "$(cat "$err")" "1 crewmate(s)" "verifier is excluded from the mixed inflight count"
# Restore the fixture this section found: a crew meta in flight + fresh beacon.
rm -f "$state"/*.meta
printf 'window=crew:t9\n' >"$state/t9.meta"
date +%s >"$state/.last-watcher-beat"

# Guard: session-lock exemption - a FOREIGN live holder makes this session
# READ-ONLY (it must not drain), so the guard allows even with queued wakes.
mkdir -p "$state/.wake-spool"
printf '3\treport\tt9\tdone: x\n' >"$state/.wake-spool/1.1.000004"
sleep 300 & flk=$!
printf 'pid=%s\nsince=now\n' "$flk" >"$state/.session-lock"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "guard must exempt a session that does not hold the live lock"
# OWN lock (holder pid in our ancestry - this shell's pid): guard applies.
printf 'pid=%s\nsince=now\n' "$$" >"$state/.session-lock"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "guard still blocks the lock-holding session"
# DEAD holder: a stale lock is no exemption.
kill "$flk" 2>/dev/null; wait "$flk" 2>/dev/null || true
printf 'pid=%s\nsince=now\n' "$flk" >"$state/.session-lock"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "dead-holder lock does not exempt"
rm -f "$state/.session-lock"; rm -rf "$state/.wake-spool"

# --- the guard's NO-BEAT branches (behavior: turnend-guard-prints-the-epoch) -
# beat=0 makes the fire condition true, which is exactly right when there is no
# beat - only the printed NUMBER was nonsense: `now - 0` rendered a 56-year age
# that reads as a live outage, and an EMPTY read (a beacon caught mid-write)
# rendered the raw epoch the same way. Every no-beat state says so, and the
# three are distinguishable because they need opposite responses.
guard_err() {
  rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>"$TMP/guard.err" || rc=$?
  printf '%s\n' "$rc"
}
rm -f "$state"/*.meta "$state/.last-watcher-beat"
printf 'window=crew:t9\n' >"$state/t9.meta"
assert_eq "$(guard_err)" "2" "an ABSENT beacon with crew in flight still blocks"
assert_contains "$(cat "$TMP/guard.err")" "no beat on record" \
  "... and reports no beat rather than an age measured from epoch 0"
assert_contains "$(cat "$TMP/guard.err")" "no beacon" \
  "... naming the ABSENT case: nothing has ever armed here"
case "$(cat "$TMP/guard.err")" in
  *[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]s*) fail "an absent beacon must never print an epoch-sized age" ;;
esac
: >"$state/.last-watcher-beat"
assert_eq "$(guard_err)" "2" "an EMPTY beacon blocks exactly as before"
assert_contains "$(cat "$TMP/guard.err")" "no beat on record" \
  "... and an empty read prints no age either"
assert_contains "$(cat "$TMP/guard.err")" "unreadable" \
  "... naming the EMPTY case, which is not the same as absent"
case "$(cat "$TMP/guard.err")" in
  *[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]s*) fail "an empty beacon must never print an epoch-sized age" ;;
esac
printf '0\n' >"$state/.last-watcher-beat"
assert_eq "$(guard_err)" "2" "a STOOD-DOWN beacon blocks exactly as before"
assert_contains "$(cat "$TMP/guard.err")" "no beat on record" "... with the same convention"
assert_contains "$(cat "$TMP/guard.err")" "stood its beacon down" \
  "... naming the routine case: a watcher exited, drain and re-arm"
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat"
assert_eq "$(guard_err)" "2" "a genuinely stale beat still blocks"
# age is `date +%s - beat` computed AT ASSERT TIME (bin/ac-turnend-guard.sh:165),
# not derived from a frozen clock - asserting the literal '9999s' races a second
# ticking over between the stamp above and this read (renders 10000s and reds a
# passing guard). Assert the SHAPE plus a lower/upper bound instead: elapsed
# time only grows from the injected staleness, and a five-digit ceiling still
# rejects a raw wall-clock epoch or a missing/blank render.
err="$(cat "$TMP/guard.err")"
rendered="${err#*stale (}"; rendered="${rendered%%)*}"
secs="${rendered%s}"
case "$secs" in
  ''|*[!0-9]*) fail "a real beat must render its age as digits+'s': '$rendered' in: $err" ;;
esac
[ "$secs" -ge 9999 ] \
  || fail "a real beat's rendered age must be at least the injected staleness (9999s), got ${rendered} in: $err"
[ "$secs" -lt 100000 ] \
  || fail "a real beat's rendered age looks like a raw epoch, not elapsed seconds: ${rendered} in: $err"
date +%s >"$state/.last-watcher-beat"
assert_eq "$(guard_err)" "0" "a fresh beat still allows the turn end"
rm -f "$state"/*.meta "$state/.last-watcher-beat"

# --- the beacon is PUBLISHED, never truncated in place -----------------------
# ac-watch.sh wrote the beacon with `printf >file`, which truncates first: a
# reader that cat(1)s inside that window reads an EMPTY file, and `now - ""` is
# arithmetic on 0 - the raw epoch the guard printed live 2026-07-27 while the
# watcher was beating 1s earlier. A hard-linked witness is the deterministic
# probe: a truncate-in-place write updates it (same inode), a tmp+rename write
# leaves it holding the value a reader already had.
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"
printf '111\n' >"$state/.last-watcher-beat"
ln "$state/.last-watcher-beat" "$TMP/beat-witness"
AC_LOCK_PID=$$ bash "$BIN/ac-watch.sh" --once >/dev/null 2>&1 || true
assert_eq "$(cat "$TMP/beat-witness")" "111" \
  "a poll publishes the beacon by rename - the old file a reader holds is never truncated"
case "$(cat "$state/.last-watcher-beat")" in
  111|'') fail "the poll must still publish a fresh beat" ;;
esac
assert_eq "$(ls "$state"/.last-watcher-beat.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "and it leaves no temp behind"
rm -f "$TMP/beat-witness" "$state"/.last-watcher-beat*

# The stand-down half of the same writer is asserted with the live-watcher
# helpers, further down (search: stand-down publishes the same way).
# Restore the fixture this section found: one crew meta in flight.
printf 'window=crew:t9\n' >"$state/t9.meta"

# Drain warns when crew is in flight and the beacon went stale.
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat"
rm -rf "$state/.wake-spool"
assert_contains "$("$BIN/ac-wake-drain.sh")" "WATCHER-DOWN" "stale beacon warning"

# --- standing remote coverage: idle mode, interval config, guard rule --------
rm -f "$state"/*.meta "$state/.last-watcher-beat"; rm -rf "$state/.wake-spool"
hook="$AC_HOME/config/remote-poll"
polllog="$TMP/idle-poll.log"
cat >"$hook" <<EOF
#!/bin/sh
printf 'hit\n' >>"$polllog"
EOF
chmod +x "$hook"

# IDLE MODE: zero crew + hook + lock-holding fleet watcher -> stays up past
# the poll interval, runs the slot on it, and heartbeat still bounds the loop.
out="$(AC_LOCK_PID=$$ AC_REMOTE_POLL=1 AC_POLL=1 AC_HEARTBEAT=3 bash "$BIN/ac-watch.sh")"
assert_contains "$out" "heartbeat" "idle watcher stays up to heartbeat"
[ -s "$polllog" ] || fail "idle watcher never ran the remote poll slot"

# A remote order arriving while idle exits remote:<rid> exactly like today.
cat >"$hook" <<'EOF'
#!/bin/sh
printf '{"rid":"idle1","text":"go","author":"cap","thread":"1.2"}\n'
EOF
chmod +x "$hook"
out="$(AC_LOCK_PID=$$ AC_REMOTE_POLL=1 AC_POLL=1 AC_HEARTBEAT=10 bash "$BIN/ac-watch.sh")"
assert_contains "$out" "remote:idle1" "idle watcher surfaces a remote order"
assert_contains "$(fleet_spool)" "remote-order idle1" "remote wake published from idle"
rm -rf "$state/.wake-spool" "$state/remote-inbox"

# Interval resolution: config/remote-poll-interval drives the slot when
# AC_REMOTE_POLL is unset (the 300 default would stay quiet in this window);
# the AC_REMOTE_POLL env override still wins, 0 = off.
cat >"$hook" <<EOF
#!/bin/sh
printf 'hit\n' >>"$polllog"
EOF
chmod +x "$hook"
printf '1\n' >"$AC_HOME/config/remote-poll-interval"
: >"$polllog"
out="$(AC_LOCK_PID=$$ AC_REMOTE_POLL='' AC_POLL=1 AC_HEARTBEAT=3 bash "$BIN/ac-watch.sh")"
assert_contains "$out" "heartbeat" "config-interval idle run bounded by heartbeat"
[ -s "$polllog" ] || fail "config/remote-poll-interval=1 did not drive the poll slot"
: >"$polllog"
out="$(AC_LOCK_PID=$$ AC_REMOTE_POLL=0 AC_POLL=1 AC_HEARTBEAT=2 bash "$BIN/ac-watch.sh")"
assert_contains "$out" "heartbeat" "env-off idle run bounded by heartbeat"
[ ! -s "$polllog" ] || fail "AC_REMOTE_POLL=0 must beat config/remote-poll-interval (slot off)"
rm -f "$AC_HOME/config/remote-poll-interval"

# Standing coverage is FLEET business, and idle mode does not widen it: a
# roomchief's watcher must never poll the remote channel (one poller
# fleet-wide), not even idling with the hook wired and the lock in its
# ancestry. Its wakes and its beat stay under its own scope throughout.
cat >"$hook" <<EOF
#!/bin/sh
printf 'hit\n' >>"$polllog"
EOF
chmod +x "$hook"
: >"$polllog"
rm -f "$state"/.last-watcher-beat*
out="$(AC_LOCK_PID=$$ AC_SCOPE=fam1 env -u AC_WATCH_ONLY AC_REMOTE_POLL=1 AC_POLL=1 AC_HEARTBEAT=3 \
  bash "$BIN/ac-watch.sh" 2>/dev/null)"
assert_contains "$out" "heartbeat" "an idle scoped watcher is bounded by heartbeat like any other"
[ ! -s "$polllog" ] || fail "a scoped watcher must NEVER poll remote orders, idle or not"
assert_file "$state/.last-watcher-beat.fam1" "an idle scoped watcher beats its OWN beacon"
assert_no_file "$state/.last-watcher-beat" "and never the fleet's - the fleet's coverage is not its to claim"
rm -f "$state"/.last-watcher-beat*

# Idle WITHOUT a hook: exits as today (idles to heartbeat, nothing to poll).
rm -f "$hook"
out="$(AC_LOCK_PID=$$ AC_POLL=1 AC_HEARTBEAT=2 bash "$BIN/ac-watch.sh")"
assert_contains "$out" "heartbeat" "idle watcher without a remote hook exits as today"

# Guard STANDING-COVERAGE rule: idle fleet + wired hook + this session
# holding the live lock + no live beacon -> block turn end.
printf '#!/bin/sh\nexit 0\n' >"$hook"
chmod +x "$hook"
rm -f "$state"/*.meta "$state/.last-watcher-beat"; rm -rf "$state/.wake-spool"
printf 'pid=%s\nsince=now\n' "$$" >"$state/.session-lock"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>"$TMP/guard-standing.err" || rc=$?
assert_eq "$rc" "2" "standing coverage blocks the idle lock-holder with hook + no beacon"
assert_contains "$(cat "$TMP/guard-standing.err")" "nothing is polling" "standing-coverage reason"
# A stale beacon is no coverage either.
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "stale beacon is not standing coverage"
# A fresh beacon (idle watcher up) satisfies the rule.
date +%s >"$state/.last-watcher-beat"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "fresh beacon satisfies standing coverage"
# Standing coverage is FLEET business and must not leak into a roomchief: it
# never holds the home lock and its watcher never polls remote, so an idle
# family with nothing queued parks freely - the fleet's unpolled channel is
# not the roomchief's turn to block on.
rm -f "$state/.last-watcher-beat"
printf '{}' | AC_SCOPE=fam1 "$BIN/ac-turnend-guard.sh" \
  || fail "standing coverage must not fire for a scoped session"
# ... while the same idle state still blocks the unscoped lock holder.
rc=0; printf '{}' | env -u AC_SCOPE "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "standing coverage still blocks the unscoped lock holder"
# But a roomchief IS blocked by its own family's queued wakes, idle or not.
mkdir -p "$state/.wake-spool.fam1"
printf '%s\treport\tfam1-t1\tdone: x\n' "$(date +%s)" >"$state/.wake-spool.fam1/1.1.000000"
rc=0; printf '{}' | AC_SCOPE=fam1 "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "a roomchief still blocks on its own queued wakes with an idle fleet"
rm -rf "$state"/.wake-spool*
date +%s >"$state/.last-watcher-beat"
# Non-holders stay exempt, hook or not.
rm -f "$state/.last-watcher-beat"
sleep 300 & slk=$!
printf 'pid=%s\nsince=now\n' "$slk" >"$state/.session-lock"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "standing coverage never blocks a non-holder"
kill "$slk" 2>/dev/null; wait "$slk" 2>/dev/null || true
# No live lock held at all -> no standing-coverage block.
rm -f "$state/.session-lock"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "no live lock held -> no standing-coverage block"
# No remote hook -> exactly as today: an idle fleet may park unwatched.
rm -f "$hook"
printf 'pid=%s\nsince=now\n' "$$" >"$state/.session-lock"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "no hook -> idle fleet may park unwatched"
rm -f "$state/.session-lock" "$state/.watcher-owner"

# AC_CAPTAIN_RE contract (default from ac-lib.sh): status markers
# (done/needs-decision/blocked/failed/paused/merged/checks-passed) anchored to
# line start with TUI-prefix tolerance; the prefix class rejects alpha AND
# digits/+ (so a diff/line-number gutter can't front a marker); the marker colon
# must be followed by whitespace or EOL (so a soft-wrapped "done:/blocked:" token
# list doesn't wake); displayed code/docs quoting a marker never match. The
# regex is now FULLY anchored - the retired bare phrase markers (PR ready/checks
# green/ready in branch, which no producer ever emitted to a pane) are gone,
# replaced by the anchored checks-passed: marker the crew-ship finish emits.
re="$(bash -c ". '$BIN/ac-lib.sh'; printf '%s' \"\$AC_CAPTAIN_RE\"")"
re_match() { printf '%s\n' "$2" | grep -qE "$1"; }
re_match "$re" 'done: x' || fail "plain done: at line start wakes"
re_match "$re" '⏺ done: report ready' || fail "TUI bullet + done: wakes"
re_match "$re" '⏺ needs-decision: pick A or B' || fail "TUI bullet + needs-decision: wakes"
re_match "$re" '  ⎿ blocked: waiting on API key' || fail "indented box-drawing + blocked: wakes"
re_match "$re" 'paused: WIP committed to crew/t1' || fail "paused: wind-down wakes"
re_match "$re" 'merged: local main' || fail "real merged: status wakes"
# The real crew-ship completion line (ac-ship.sh finish checks-passed) wakes.
re_match "$re" 'checks-passed: demo-ship PR raised, awaiting merge' || fail "anchored checks-passed: marker wakes"
re_match "$re" '⏺ checks-passed: demo-ship PR raised, awaiting merge' || fail "TUI bullet + checks-passed: wakes"
# A pane merely DISPLAYING the retired phrases or the marker word mid-prose
# (docs/config regex dump, skill text) must NOT wake - the residue this fixes.
assert_fails re_match "$re" 'crew-ship passed: checks green, PR ready at https://x'
assert_fails re_match "$re" 'the pipeline emits checks-passed on success'
assert_fails re_match "$re" '| done:\|blocked:\|checks-passed: | wake lines |'
assert_fails re_match "$re" '  printf "done: %s"'
assert_fails re_match "$re" 'echo "done:"'
assert_fails re_match "$re" '"done:" inside a displayed string'
# shellcheck disable=SC2016  # literal backticks: a doc line quoting the protocol
assert_fails re_match "$re" '- `done:` lines (AC_CAPTAIN_RE) are what wake you'
assert_fails re_match "$re" '# done: comment leader'
assert_fails re_match "$re" 'AC_RE=done:|blocked:'
# Retired: bare "merged"-in-prose no longer wakes (merged is now anchored merged:).
assert_fails re_match "$re" 'PR #12 was merged'
# The 4 observed false wakes (drydock, 1h) must all STOP matching.
# shellcheck disable=SC2016  # literal $id/$default in a displayed code line
assert_fails re_match "$re" '      121 +Mode local-only: leave the work committed and merged-ready on'
# shellcheck disable=SC2016
assert_fails re_match "$re" '      50  ac_status_append "$id" "merged: local $default"'
# shellcheck disable=SC2016
assert_fails re_match "$re" '     report retire-only-pool-gitignore-dirt       50  ac_status_append "$id" "merged: local $default"'
assert_fails re_match "$re" '    done:/blocked:/gate.'
# Env override still wins over the default.
custom="$(AC_CAPTAIN_RE='CUSTOMWAKE' bash -c ". '$BIN/ac-lib.sh'; printf '%s' \"\$AC_CAPTAIN_RE\"")"
assert_eq "$custom" "CUSTOMWAKE" "AC_CAPTAIN_RE override wins"

# --- scope-aware turn-end guard (+ the lock-exemption reconciliation) ------
# No turn ends blind, per SCOPE: each session is gated on the wakes IT must
# drain. Two shapes matter and are pinned in both directions here. From here
# down every backend-touching pass runs against the fake herdr CLI: a pane is
# alive while its files exist, its buffer file is the pane text.
rm -f "$state"/*.meta "$state"/.session-lock
rm -rf "$state"/.wake-spool*
rm -f "$state"/.last-watcher-beat*
make_fake_herdr

seed_pane() {
  # seed_pane <id> <p> <t> - a live fake pane for <id>: handle + tab + empty
  # buffer (the ac-backend.test.sh p90/t90 idiom). Inject pane text by
  # appending to "$(fake_pane_buf <id>)"; rm the pane files to vanish it.
  printf '%s %s\n' "$2" "$3" >"$state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
}

guard() {
  # guard <scope> -> exit code of the Stop-hook predicate ('' = fleet).
  # Its stdout is dropped: the non-blocking parked reminder prints there, and
  # this helper answers about the exit code alone.
  local rc=0
  if [ -n "$1" ]; then
    printf '{}' | AC_SCOPE="$1" "$BIN/ac-turnend-guard.sh" >/dev/null 2>&1 || rc=$?
  else
    printf '{}' | env -u AC_SCOPE "$BIN/ac-turnend-guard.sh" >/dev/null 2>&1 || rc=$?
  fi
  printf '%s\n' "$rc"
}

# (a) H5 - demoting the LAST chief leaves an orphan wake pending exactly as
# inflight hits 0. The queued predicate must therefore be judged BEFORE the
# "nothing in flight" exit, or the fleet ends blind on that wake.
rm -f "$state"/*.meta "$state/.pane-fam1-chief"   # chief demoted, nothing in flight
# An EMPTY orphan spool dir is litter and pins nothing; a RECORD in it pins
# the fleet turn even with nothing in flight, so the queued predicate must be
# judged BEFORE the "nothing in flight" exit.
mkdir -p "$state/.wake-spool.fam1"
assert_eq "$(guard '')" "0" "an EMPTY orphan spool dir never pins the fleet turn"
printf '%s\treport\tfam1-t1\tdone: orphaned record\n' "$(date +%s)" >"$state/.wake-spool.fam1/1.1.000000"
assert_eq "$(guard '')" "2" "fleet turn blocks on an orphaned family's spool record"
# A LIVE family's spool is NOT the fleet's to drain, so it must not pin the
# fleet's turn. (Fresh fleet beat: isolate the queued predicate from the
# watcher-liveness one, which the chief meta would otherwise trip.)
printf 'window=crew:fam1-chief\nbackend=herdr\n' >"$state/fam1-chief.meta"
seed_pane fam1-chief pG1 tG1
date +%s >"$state/.last-watcher-beat"
assert_eq "$(guard '')" "0" "a LIVE family's spool never pins the fleet turn"
rm -f "$state/fam1-chief.meta" "$state/.pane-fam1-chief"; rm -rf "$state"/.wake-spool*

# (b)+(c) The session-lock exemption and scoping, reconciled. A session that
# does not hold the home lock is READ-ONLY and exempt - but a ROOMCHIEF never
# holds the home lock (ac-lock.sh skips scoped sessions) and DOES own its
# family queue, so the exemption must not silence it. Foreign live holder,
# built with a fifo-blocked reader (a live pid, no sleep, no polling).
hold_open hold; flk=$HOLD_PID
printf 'pid=%s\nsince=now\n' "$flk" >"$state/.session-lock"
printf 'window=crew:fam1-t1\n' >"$state/fam1-t1.meta"
date +%s >"$state/.last-watcher-beat"
date +%s >"$state/.last-watcher-beat.fam1"

# (b) an UNSCOPED read-only fleet session stays exempt (guards 3f7cce3).
mkdir -p "$state/.wake-spool"
printf '%s\treport\tt9\tdone: x\n' "$(date +%s)" >"$state/.wake-spool/1.1.000000"
assert_eq "$(guard '')" "0" "an unscoped read-only session stays exempt from fleet wakes"
# (c) a ROOMCHIEF under the SAME foreign lock is NOT exempt: its own spool
# records block its turn.
mkdir -p "$state/.wake-spool.fam1"
printf '%s\treport\tfam1-t1\tdone: mine\n' "$(date +%s)" >"$state/.wake-spool.fam1/1.1.000000"
assert_eq "$(guard fam1)" "2" "a roomchief is not exempted by the foreign lock - its own wakes block it"
# (d) ... and it is gated ONLY on its own scope: neither the fleet spool nor
# a sibling's is its to drain.
rm -rf "$state/.wake-spool.fam1"
mkdir -p "$state/.wake-spool.fam2"
printf '%s\treport\tfam2-t1\tdone: sibling\n' "$(date +%s)" >"$state/.wake-spool.fam2/1.1.000000"
assert_eq "$(guard fam1)" "0" "a roomchief never blocks on the fleet's or a sibling's wakes"
rm -rf "$state"/.wake-spool*

# Per-scope beacon: a roomchief whose OWN family watcher died must see
# WATCHER-DOWN even while the fleet watcher beats freshly, and vice versa.
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat.fam1"
date +%s >"$state/.last-watcher-beat"
assert_eq "$(guard fam1)" "2" "roomchief blocks on ITS OWN stale watcher despite a fresh fleet beat"
date +%s >"$state/.last-watcher-beat.fam1"
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat"
assert_eq "$(guard fam1)" "0" "a fresh family beat keeps the roomchief quiet while the fleet's is stale"

hold_close hold "$flk"
rm -f "$state/.session-lock" "$state"/*.meta "$state"/.last-watcher-beat*; rm -rf "$state"/.wake-spool*

# --- P1 scope routing + scoped beacon + single-family arm assert -----------
# A wake is filed for its intended CONSUMER: the fleet watcher publishes to
# state/.wake-spool/, a promoted family's watcher (AC_SCOPE=<fam>, inherited
# from ac-spawn.sh) publishes to state/.wake-spool.<fam>/, which only that
# roomchief drains. Driven through the fake herdr so both scopes are
# exercised hermetically - no real pane, no sleep.
rm -f "$state"/*.meta "$state"/.last-watcher-beat*
rm -f "$state"/.hash-* "$state"/.seen-* "$state"/.change-* "$state"/.stale-*
rm -rf "$state"/.wake-spool*

watch_once() {
  # watch_once <scope> - one bounded watcher pass, with AC_SCOPE set to
  # <scope> ('' = the fleet watcher).
  if [ -n "$1" ]; then
    AC_SCOPE="$1" bash "$BIN/ac-watch.sh" --once
  else
    env -u AC_SCOPE bash "$BIN/ac-watch.sh" --once
  fi
}

printf 'window=crew:c1\nbackend=herdr\n' >"$state/c1.meta"
seed_pane c1 pC1 tC1
printf 'done: fleet work\n' >>"$(fake_pane_buf c1)"

# Fleet watcher (AC_SCOPE unset) -> the FLEET spool and the FLEET beacon.
assert_contains "$(watch_once '')" "report:c1" "fleet watcher reports"
assert_contains "$(fleet_spool)" "done: fleet work" "fleet wake -> fleet spool"
assert_file "$state/.last-watcher-beat" "fleet watcher stamps the fleet beacon"
assert_no_file "$state/.last-watcher-beat.fam1" "fleet watcher stamps no family beacon"
rm -f "$state/.seen-c1" "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*

# Family watcher (AC_SCOPE=fam1) -> the FAMILY spool and the FAMILY beacon.
# The pane is one of fam1's own: a scoped watcher watches its family and
# files for it, which are the same set by construction (see the mirror-case
# assert below). The fleet spool must stay untouched: this is the wake the
# fleet chief used to steal.
printf 'window=crew:fam1-t1\nbackend=herdr\n' >"$state/fam1-t1.meta"
seed_pane fam1-t1 pF1 tF1
printf 'done: family work\n' >>"$(fake_pane_buf fam1-t1)"
assert_contains "$(watch_once fam1)" "report:fam1-t1" "family watcher reports its own crewmate"
assert_contains "$(fam_spool fam1)" "done: family work" "scoped wake -> family spool"
assert_no_file "$state/.wake-spool" "scoped wake never touches the fleet spool"
assert_file "$state/.last-watcher-beat.fam1" "family watcher stamps its own beacon"
assert_no_file "$state/.last-watcher-beat" "family watcher never stamps the fleet beacon"
rm -f "$state/.seen-fam1-t1" "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*
rm -f "$state/fam1-t1.meta" "$state/.pane-fam1-t1"

# A malformed AC_SCOPE routes to the FLEET spool and leaks no stray store.
# Such a watcher IS a fleet watcher, so its watch set is never narrowed to
# the unusable scope either - it still reports fleet panes.
assert_contains "$(watch_once 'foo/bar')" "report:c1" "malformed scope still reports"
assert_contains "$(fleet_spool)" "done: fleet work" "malformed scope -> fleet spool"
assert_eq "$(find "$state" -name '.wake-spool.*' | wc -l | tr -d ' ')" "0" \
  "malformed scope creates no stray family store"
rm -f "$state/.seen-c1" "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*

# A <fam>-chief pane is FLEET-scoped (in_scope excludes it), so its hand-back
# wake is produced by the fleet watcher and lands on the fleet spool.
printf 'window=crew:fam1-chief\nbackend=herdr\n' >"$state/fam1-chief.meta"
seed_pane fam1-chief pFC tFC
printf 'done: family landed\n' >>"$(fake_pane_buf fam1-chief)"
rm -f "$state/c1.meta" "$state/.pane-c1"
assert_contains "$(watch_once '')" "report:fam1-chief" "fleet watcher owns the chief pane"
assert_contains "$(fleet_spool)" "done: family landed" "chief wake -> fleet spool"
assert_no_file "$state/.wake-spool.fam1" "a chief wake is never filed to its family"
rm -f "$state/fam1-chief.meta" "$state/.pane-fam1-chief" "$state/.seen-fam1-chief"
rm -f "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*

# H10 - a SCOPED watcher FILES its wakes under AC_SCOPE, so AC_WATCH_ONLY must
# CONTAIN AC_SCOPE or those wakes land under a consumer that never drains them.
# An AC_WATCH_ONLY that does NOT contain AC_SCOPE is refused (exit 2); the
# single-family case (the HARD FENCE) and AC_WATCH_ONLY holding AC_SCOPE plus
# extra story families (an epic roomchief) both arm
# (epic-roomchief-watch-only-omits-story-ids).
arm() { AC_WATCH_ONLY="$1" AC_SCOPE="$2" bash "$BIN/ac-watch.sh" 2>&1; }
rc=0; out="$(arm fam1 fam2)" || rc=$?
assert_eq "$rc" "2" "AC_WATCH_ONLY not containing AC_SCOPE refuses to arm"
assert_contains "$out" "refused" "the refusal says so"
rc=0; out="$(arm 'fam2,fam3' fam1)" || rc=$?
assert_eq "$rc" "2" "a multi-family AC_WATCH_ONLY that OMITS AC_SCOPE still refuses"
assert_contains "$out" "refused" "the omit-scope refusal says so"
assert_eq "$(find "$state" -name '.wake-spool*' | wc -l | tr -d ' ')" "0" \
  "a refused arm queues nothing"

# The refusal must cover --once too: the documented bounded foreground
# checkpoint files wakes exactly like the armed watcher does.
rc=0; out="$(AC_WATCH_ONLY=fam1 AC_SCOPE=fam2 bash "$BIN/ac-watch.sh" --once 2>&1)" || rc=$?
assert_eq "$rc" "2" "--once cannot bypass the containment assert"
assert_eq "$(find "$state" -name '.wake-spool*' | wc -l | tr -d ' ')" "0" \
  "a refused --once checkpoint queues nothing"

# ACCEPT, single-family (the HARD FENCE): AC_WATCH_ONLY == AC_SCOPE still arms,
# byte-identical to the pre-epic behavior - the live epic's running scoped
# watcher (AC_WATCH_ONLY=<epic> == AC_SCOPE) must not be broken by this relax.
rc=0; out="$(AC_WATCH_ONLY=fam1 AC_SCOPE=fam1 bash "$BIN/ac-watch.sh" --once 2>&1)" || rc=$?
assert_eq "$rc" "0" "the single-family case (fence) still arms"
case "$out" in *refused*) fail "the single-family case must never be refused" ;; esac

# ACCEPT, epic-plus-stories: AC_WATCH_ONLY holding AC_SCOPE plus extra story
# families arms, so an epic roomchief covers its story crewmate panes.
rc=0; out="$(AC_WATCH_ONLY='fam1,story1,story2' AC_SCOPE=fam1 bash "$BIN/ac-watch.sh" --once 2>&1)" || rc=$?
assert_eq "$rc" "0" "AC_WATCH_ONLY containing AC_SCOPE plus extra story families arms"
case "$out" in *refused*) fail "a scope-containing multi-family set must not be refused" ;; esac

# The MIRROR case: AC_SCOPE set, AC_WATCH_ONLY UNSET. These are NOT equal by
# construction - AC_SCOPE rides the launch line as real env (bin/ac-spawn.sh's
# backend_send_line call, the AC_SCOPE=... it appends after the prompt) while
# AC_WATCH_ONLY is only prompt text the roomchief must remember to type (that
# same launch's roomchief kickoff prompt, the "Arm your watcher...
# AC_WATCH_ONLY=..." sentence), so a roomchief following the generic "arm
# bin/ac-watch.sh" lands here. Unguarded it would watch every pane
# FLEET-wide while filing every wake to .wake-spool.<fam>/. The scope is the
# authoritative signal, so the watch set defaults from it.
printf 'window=crew:c1\nbackend=herdr\n' >"$state/c1.meta"
printf 'window=crew:fam1-t1\nbackend=herdr\n' >"$state/fam1-t1.meta"
seed_pane c1 pC2 tC2
seed_pane fam1-t1 pF2 tF2
printf 'done: fleet pane\n' >>"$(fake_pane_buf c1)"
printf 'done: family pane\n' >>"$(fake_pane_buf fam1-t1)"
out="$(AC_SCOPE=fam1 env -u AC_WATCH_ONLY bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:fam1-t1" "a scoped watcher with no AC_WATCH_ONLY watches its own family"
case "$out" in *report:c1*) fail "a scoped watcher must not watch panes outside its family" ;; esac
assert_contains "$(fam_spool fam1)" "done: family pane" "its wake is filed for its own family"
assert_no_file "$state/.wake-spool" "and it files nothing to the fleet spool"
rm -f "$state"/*.meta "$state"/.pane-* "$state"/.seen-* \
  "$state"/.hash-* "$state"/.change-* "$state"/.stale-* "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*

# Intra-family fan-out (AGENTS.md section 5): a roomchief that spawns one
# execution crewmate per independently-landable sub-deliverable arms with
# AC_WATCH_ONLY=$(ac-ready.sh watch-set <family>) - for a non-epic family
# (no backlog stories) that computes to EXACTLY the family id, and
# in_scope's <fam>-* prefix match already admits ANY suffix, fan-out ids
# (<family>-<slug>) included - no new grammar needed. check_fleet reports
# at most ONE actionable pane per --once pass, so each fan-out id (and the
# scope boundary against a same-slug outsider) is proven in its own pass.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' >"$AC_HOME/records/backlog.md"
watch_only="$("$BIN/ac-ready.sh" watch-set fanfam)"
assert_eq "$watch_only" "fanfam" "watch-set for a non-epic fan-out family is exactly the family id"

printf 'window=crew:fanfam-frontend\nbackend=herdr\n' >"$state/fanfam-frontend.meta"
printf 'window=crew:otherfam-frontend\nbackend=herdr\n' >"$state/otherfam-frontend.meta"
seed_pane fanfam-frontend pFF tFF
seed_pane otherfam-frontend pOF tOF
printf 'done: frontend shipped\n' >>"$(fake_pane_buf fanfam-frontend)"
printf 'done: unrelated family\n' >>"$(fake_pane_buf otherfam-frontend)"
out="$(AC_SCOPE=fanfam AC_WATCH_ONLY="$watch_only" bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:fanfam-frontend" "the scoped watcher covers a fan-out sub-deliverable pane"
case "$out" in *report:otherfam-frontend*) fail "a fan-out watcher must not cover a same-slug outsider family" ;; esac
assert_contains "$(fam_spool fanfam)" "done: frontend shipped" "the fan-out wake files under the family, not the outsider"
rm -f "$state"/*.meta "$state"/.pane-* "$state"/.seen-* \
  "$state"/.hash-* "$state"/.change-* "$state"/.stale-* "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*

printf 'window=crew:fanfam-backend\nbackend=herdr\n' >"$state/fanfam-backend.meta"
seed_pane fanfam-backend pFB tFB
printf 'done: backend shipped\n' >>"$(fake_pane_buf fanfam-backend)"
out="$(AC_SCOPE=fanfam AC_WATCH_ONLY="$watch_only" bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:fanfam-backend" "the scoped watcher covers a second, differently-slugged fan-out pane"
assert_contains "$(fam_spool fanfam)" "done: backend shipped" "the second fan-out wake files under the family"
rm -f "$state"/*.meta "$state"/.pane-* "$state"/.seen-* \
  "$state"/.hash-* "$state"/.change-* "$state"/.stale-* "$state"/.last-watcher-beat*
rm -rf "$state"/.wake-spool*

# --- external kills: TERM/INT trap, stale-lock reclaim, arm attribution -----
# Observed on drydock: external SIGTERMs land on the watcher's poll wait. An
# untrapped SIGTERM kills bash by its DEFAULT disposition, so the EXIT trap
# never runs and the lock dir LEAKS - and a leaked dir whose pid file never
# got published made every later re-arm false-positive `already running`
# while NOTHING watched the fleet. Both halves are pinned here.
rm -f "$state"/*.meta "$state"/.last-watcher-beat* \
  "$state/.session-lock" "$state/.watcher-owner" "$state/.watcher-arm.log"
rm -rf "$state"/.wake-spool*
lockd="$state/.watch.lock.d"
rm -rf "$lockd"

lock_try() {
  # lock_try <lockdir> [<timeout>] - ac_lock_acquire in a throwaway shell,
  # printing its exit code. The shell exits immediately on success, so a
  # successful acquire leaves a DEAD-pid lock dir behind by construction.
  local rc=0
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_lock_acquire '$1' '${2:-0}'" \
    >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# (1) The CONFIRMED drydock shape: lock dir present, pid file never published
# (killed between `mkdir` and the `printf` that writes it). Aged past the
# grace with a FIXED past stamp - deterministic, no sleep.
mkdir -p "$lockd"
touch -t 202001010000 "$lockd"
assert_eq "$(lock_try "$lockd")" "0" "an aged EMPTY lock dir is stale and gets reclaimed"
rm -rf "$lockd"

# (2) ... but the SAME shape moments old is a live acquirer still inside its
# `mkdir`->`printf` publish window, NOT a corpse. Reclaiming it would let two
# watchers each believe they hold the lock, so it must fail closed.
mkdir -p "$lockd"
assert_eq "$(lock_try "$lockd")" "1" "a FRESH empty lock dir is a live acquirer mid-publish, never stale"
rm -rf "$lockd"

# (3) Dead-pid shape: reclaimed (this half already worked; pin it so the
# rewrite keeps it).
mkdir -p "$lockd"
sleep 0 & deadpid=$!
wait "$deadpid" 2>/dev/null || true
printf '%s\n' "$deadpid" >"$lockd/pid"
assert_eq "$(lock_try "$lockd")" "0" "a dead-pid lock dir is stale and gets reclaimed"
rm -rf "$lockd"

# (4) FAIL-CLOSED on a LIVE pid: a real running watcher keeps its lock. Held
# by a fifo-blocked reader - a live pid with no sleep and no polling.
hold_open lockhold; livepid=$HOLD_PID
mkdir -p "$lockd"
printf '%s\n' "$livepid" >"$lockd/pid"
assert_eq "$(lock_try "$lockd")" "1" "a LIVE owner pid keeps its lock - reclaim fails closed"
# ... and end to end: the second arm still refuses, exactly as today.
out="$(AC_LOCK_PID=$$ AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
assert_contains "$out" "already running" "a LIVE watcher lock still refuses the second arm"
hold_close lockhold "$livepid"
rm -rf "$lockd"

# (5) End to end, the bug as it was reported: an aged EMPTY lock dir must not
# wedge the re-arm. This ran `already running` forever while the fleet was
# blind.
mkdir -p "$lockd"
touch -t 202001010000 "$lockd"
out="$(AC_LOCK_PID=$$ AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
assert_contains "$out" "heartbeat" "a watcher re-arms over a stale empty lock (was: permanent 'already running')"
assert_no_file "$lockd" "and releases it again on the way out"

sleep_child() {
  # sleep_child <watcher-pid> - the pid of the watcher's poll `sleep`, empty
  # when it is not in the poll wait. The SLEEP specifically: check_fleet forks
  # `date` on every pass, so "has any child" is no proof of the poll wait.
  ps -eo pid,ppid,comm | awk -v p="$1" '$2==p && $3 ~ /(^|\/)sleep$/ {print $1; exit}'
}
in_poll_wait() {
  # in_poll_wait <watcher-pid> <beat-file> - block until the watcher is armed
  # (beacon stamped => the loop is running) AND sitting in its poll sleep;
  # print that sleep's pid. Returns 1 if it never gets there. Sync on the
  # CONDITION, never on a guessed interval.
  local w="$1" beat="$2" sp
  for _ in $(seq 1 400); do
    if [ -s "$beat" ]; then
      sp="$(sleep_child "$w")"
      [ -n "$sp" ] && { printf '%s\n' "$sp"; return 0; }
    fi
    sleep 0.05
  done
  return 1
}
dead_within() {
  # dead_within <pid> <secs> - 0 once <pid> is gone, 1 if it outlives the
  # bound. A kill is asynchronous, so poll rather than assume.
  local p="$1" n=$(( ${2:-3} * 20 ))
  for _ in $(seq 1 "$n"); do
    ps -p "$p" >/dev/null 2>&1 || return 0
    sleep 0.05
  done
  return 1
}

# The stand-down publishes the same way - it is the same writer (see "the
# beacon is PUBLISHED, never truncated in place" above for the probe).
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$TMP/standdown.out" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the stand-down watcher never reached its poll wait"
beat_at_arm="$(cat "$state/.last-watcher-beat")"
ln -f "$state/.last-watcher-beat" "$TMP/beat-witness"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null || true
assert_eq "$(cat "$state/.last-watcher-beat")" "0" "the exit still stands the beacon down"
assert_eq "$(cat "$TMP/beat-witness")" "$beat_at_arm" \
  "... by rename too, so a concurrent reader sees the old beat or the 0, never an empty file"
rm -f "$TMP/beat-witness" "$state/.session-lock" "$state/.watcher-owner" \
  "$state"/.last-watcher-beat* "$state/.watcher-arm.log"

# (6) The TERM trap, fired where every observed kill landed: INSIDE the poll
# wait. AC_POLL is the lever for the whole block: every assertion below is
# a mutation test against the poll wait's shape, and each is impossible to
# pass with a plain foreground `sleep "$1"`. It is set HIGH and read from a
# variable because it is also the SIZE of the deferred-trap signature (6b)
# measures against - see there.
rm -f "$state"/.last-watcher-beat* "$state/.watcher-arm.log"
sigout="$TMP/sig.out"
# The pair is declared together because only their RATIO means anything: a
# deferred trap exits at its own poll tick, so sig_bound must stay far below
# sig_poll or (6b) stops biting. sig_poll is also the lifetime of the watcher
# this block leaks on every fail path AHEAD of (6b)'s kill (each `fail` exits
# the file with it still armed), so it buys the ratio without buying an orphan
# that outlives the run by more than minutes.
sig_poll=120
sig_bound=20
AC_LOCK_PID=$$ AC_POLL="$sig_poll" AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>"$TMP/sig.err" &
wpid=$!
sp1="$(in_poll_wait "$wpid" "$state/.last-watcher-beat")" \
  || fail "the watcher never armed and reached its poll wait"
[ -d "$lockd" ] || fail "an armed watcher holds the lock"

# (6a) A kill aimed at the poll `sleep` CHILD alone is ABSORBED - the loop
# just polls again. This is the drydock shape: bash outlives the kill (it is
# what prints `Terminated: 15  sleep`), and under a FOREGROUND sleep `set -e`
# takes the child's 143 and silently exits the watcher. Absorbing it is only
# possible because the wait is `sleep &` + `wait || true`.
kill -TERM "$sp1"
sp2="$(in_poll_wait "$wpid" "$state/.last-watcher-beat")" \
  || fail "a kill on the poll sleep CHILD must be absorbed - the watcher died instead of polling again"
ps -p "$wpid" >/dev/null 2>&1 || fail "the watcher must survive a kill aimed only at its sleep child"
[ "$sp2" != "$sp1" ] || fail "the watcher must enter a NEW poll wait after its sleep child is killed"

# (6b) TERM to the WATCHER: the trap must fire while it sits in the sleep, so
# the exit is immediate. Under a foreground `sleep` bash defers the trap until
# the child finishes - the watcher would linger out the rest of AC_POLL.
#
# The observable is that the watcher dies AT ALL well inside its own poll
# deadline, never how many seconds it took: an elapsed-seconds budget cannot
# tell a deferred trap from a descheduled host, and blamed the former for the
# latter (SIGSTOPping this watcher for 12s across the TERM reds `elapsed < 10`
# with the trap firing exactly where it should). $sig_poll is what a DEFERRED
# trap costs and the fixture owns it, so the two outcomes sit orders of
# magnitude apart - 120s against 0.03s measured on a box at load 13/12 - with
# the bound between them; dead_within also REPORTS at the bound instead of
# waiting the whole poll out. It reads $wpid, OUR OWN child: bash reaps a dead
# background child in its SIGCHLD handler, so ps stops matching it without a
# `wait` - the `wait` below is only for the status.
kill -TERM "$wpid"
if ! dead_within "$wpid" "$sig_bound"; then
  # The red case is exactly the one still holding a live watcher and a live
  # poll `sleep`, and fail exits the file - reap both HERE, or the honest red
  # leaves them running for the rest of AC_POLL against a deleted $TMP.
  kill -9 "$wpid" "$sp2" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  fail "the TERM trap must fire INSIDE the poll wait: the watcher outlived the kill by ${sig_bound}s of a ${sig_poll}s poll (deferred trap)"
fi
rc=0; wait "$wpid" || rc=$?
assert_eq "$rc" "0" "a TERM'd watcher exits cleanly instead of dying by default disposition"
assert_contains "$(cat "$sigout")" "signal:TERM" "the kill prints ONE reason line naming the signal"
assert_contains "$(cat "$sigout")" "pid=$wpid" "... the watcher pid"
assert_contains "$(cat "$sigout")" "target=fleet" "... and the poll target"
assert_eq "$(grep -c . "$sigout" | tr -d ' ')" "1" "exactly one reason line, nothing else on stdout"
assert_no_file "$lockd" "a TERM'd watcher RELEASES its lock (the confirmed leak)"
# ... and it takes its sleep child with it, rather than orphaning that `sleep`
# for the rest of $sig_poll.
dead_within "$sp2" 3 || fail "on_signal must kill the poll sleep child, not orphan it for the rest of AC_POLL"

# (7) Attribution on arm: the watcher pid + its parent chain, so the next
# external kill is attributable to a NAMED process. Never on stdout - that
# channel carries the exit reason and nothing else.
armlog="$state/.watcher-arm.log"
assert_file "$armlog" "arming logs an attribution line"
assert_contains "$(cat "$armlog")" "arm pid=$wpid" "attribution names the watcher pid"
assert_contains "$(cat "$armlog")" "chain=$wpid(" "attribution carries the parent chain, watcher first"
selfpid=$$   # via a variable: "$$(" reads as a command substitution to bash
assert_contains "$(cat "$armlog")" " < $selfpid(" "... and names the parent that could reap it"
assert_contains "$(cat "$armlog")" "signal:TERM" "the kill itself is logged beside the arm - the trail is the evidence"
assert_contains "$(cat "$TMP/sig.err")" "arm pid=$wpid" "attribution is echoed to stderr for the pane"

# INT runs the same handler, printing its own name. Job control is REQUIRED to
# test it: a shell backgrounding a job WITHOUT job control must set SIGINT to
# SIG_IGN in that child (POSIX), and a signal ignored on entry can never be
# trapped - so an ARMED watcher (always a background task) cannot trap INT at
# all, and only ever sees TERM. `set -m` gives the child its own process group
# and a deliverable SIGINT, which is the foreground/Ctrl-C shape the INT trap
# actually exists for.
rm -f "$state"/.last-watcher-beat* "$state/.watcher-arm.log"
set -m
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
set +m
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the INT watcher never reached its poll wait"
kill -INT "$wpid"
rc=0; wait "$wpid" || rc=$?
assert_eq "$rc" "0" "an INT'd watcher exits cleanly too"
assert_contains "$(cat "$sigout")" "signal:INT" "INT names itself on the reason line"
assert_no_file "$lockd" "an INT'd watcher releases its lock"

# A SCOPED watcher names its own poll target on the way out.
rm -f "$state"/.last-watcher-beat*
AC_SCOPE=fam1 AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat.fam1" >/dev/null \
  || fail "the scoped watcher never reached its poll wait"
kill -TERM "$wpid"
rc=0; wait "$wpid" || rc=$?
assert_contains "$(cat "$sigout")" "target=only:fam1" "a scoped watcher names ITS OWN poll target"
assert_no_file "$state/.watch-only-fam1.lock.d" "a scoped watcher releases its own scoped lock"
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"

# An EPIC roomchief's scoped watcher watches its story panes too
# (AC_WATCH_ONLY=<epic>,<story>...), but its LOCK is keyed on the ONE family it
# FILES for (AC_SCOPE), not the full set - so its name stays
# .watch-only-<epic>.lock.d and ac-done's push (ac_watcher_pid, which rebuilds
# that name from AC_FLEET_SCOPE) still finds it to nudge, and the name never
# shifts as the story set evolves across re-arms
# (epic-roomchief-watch-only-omits-story-ids).
rm -f "$state"/*.meta "$state"/.last-watcher-beat*
AC_SCOPE=ep AC_WATCH_ONLY='ep,st1,st2' AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat.ep" >/dev/null \
  || fail "the epic scoped watcher never reached its poll wait"
[ -d "$state/.watch-only-ep.lock.d" ] || fail "the lock keys on AC_SCOPE (the epic), not the multi-family watch set"
assert_no_file "$state/.watch-only-ep_st1_st2.lock.d" "the story set never appears in the lock name"
found_pid="$(bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-wake-lib.sh'; ac_watcher_pid '$state' ep" 2>/dev/null || true)"
assert_eq "$found_pid" "$wpid" "ac_watcher_pid (ac-done's push path) finds the epic watcher by its family scope"
kill -TERM "$wpid"
rc=0; wait "$wpid" || rc=$?
assert_no_file "$state/.watch-only-ep.lock.d" "the epic scoped watcher releases its family-keyed lock"
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"

# --- owner-marked release (behavior: watcher-owner-term-quiet) --------------
# Every TERM used to read `watcher killed externally`, whatever the sender - so
# the OWNER'S OWN config-swap release (read the live watcher's pid, TERM it,
# re-arm a different AC_WATCH_SKIP) was indistinguishable in the log from a
# hostile kill, and cost two families four days of false investigation.
# `--release <pid>` stamps the intent and sends the TERM in ONE command, so the
# two can never drift apart; the exiting watcher reads the marker naming ITSELF
# and says so calmly. Everything else about the exit is unchanged, and every
# OTHER TERM stays exactly as alarming as it was.

# (8a) Owner-marked TERM -> the calm wording, on the same reason-line shape.
rm -f "$state"/.last-watcher-beat* "$state/.watcher-arm.log"
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the released watcher never reached its poll wait"
relout="$(bash "$BIN/ac-watch.sh" --release "$wpid" 2>/dev/null)"
rc=0; wait "$wpid" || rc=$?
assert_eq "$rc" "0" "an owner-released watcher exits cleanly like any other"
assert_contains "$relout" "released: pid=$wpid" "--release names the pid it stamped and TERM'd"
assert_contains "$(cat "$sigout")" "signal:TERM pid=$wpid" "the reason line keeps its shape"
assert_contains "$(cat "$sigout")" "config-swap by owner (released by pid=" \
  "an owner-marked TERM reads as the release it is"
case "$(cat "$sigout")" in
  *"killed externally"*) fail "an owner-marked TERM must not read as a hostile kill" ;;
esac
assert_contains "$(cat "$state/.watcher-arm.log")" "config-swap by owner" \
  "the arm log - the trail the investigation reads - carries the same wording"
assert_no_file "$state/.watcher-release-$wpid" "the marker is consumed by the exit it explains"
assert_no_file "$lockd" "an owner-released watcher still releases its lock"

# (8b) A FOREIGN (unmarked) TERM keeps today's wording, byte for byte - that
# text is what the hardening refusal and the fleet monitor key on.
rm -f "$state"/.last-watcher-beat* "$state/.watcher-arm.log"
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the foreign-TERM watcher never reached its poll wait"
kill -TERM "$wpid"
rc=0; wait "$wpid" || rc=$?
assert_eq "$rc" "0" "an unmarked TERM still exits cleanly"
assert_contains "$(cat "$sigout")" "watcher killed externally" \
  "an unmarked TERM is as alarming as it ever was"
assert_contains "$(cat "$state/.watcher-arm.log")" "watcher killed externally" \
  "... in the arm log too"

# (8c) A marker must never become a SILENCER: one left over from an earlier
# release is STALE by the time bound and quiets nothing, and it is consumed on
# the way out so it cannot mute a later kill either.
rm -f "$state"/.last-watcher-beat* "$state/.watcher-arm.log"
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the stale-marker watcher never reached its poll wait"
printf 'releaser=%s\ntarget=%s\nreason=config-swap\nepoch=%s\n' \
  "$$" "$wpid" "$(( $(date +%s) - 9999 ))" >"$state/.watcher-release-$wpid"
kill -TERM "$wpid"
rc=0; wait "$wpid" || rc=$?
assert_contains "$(cat "$sigout")" "watcher killed externally" \
  "a STALE marker never quiets a genuine external kill"
assert_no_file "$state/.watcher-release-$wpid" \
  "... and it is consumed anyway, so it cannot mute a later kill either"

# (8d) A release that could not deliver its TERM WITHDRAWS its marker - a
# marker outliving its kill is exactly the silencer (8c) exists to prevent.
sleep 0 & deadpid=$!
wait "$deadpid" 2>/dev/null || true
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$deadpid" 2>&1)" || rc=$?
assert_eq "$rc" "2" "releasing a pid that is not there refuses"
assert_no_file "$state/.watcher-release-$deadpid" "a failed release leaves no marker behind"
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"

# (8e-orphan) THE ORPHAN EXCEPTION. The (8e) refusal protects a family's
# real-time coverage on behalf of its roomchief - and when that roomchief has
# been DEMOTED the premise it prints out loud ("until its roomchief notices and
# re-arms") is false: nobody is left to notice, so the guard was protecting a
# watcher for a family that no longer exists while the operator had NO
# sanctioned way to stop it (measured live 2026-08-09: an arm log still showing
# `target=only:<family>` ten minutes after that family was demoted and its room
# closed, with --release refusing on exactly that false premise).
#
# The signal is the ROOM, not the chief meta: absence of <family>-chief.meta is
# NOT family liveness in this codebase - (8e) below holds a LIVE scoped watcher
# with no chief meta on disk - so keying on it would release a working watcher.
# Demotion WRITES to the room, and that is what is read.
mkdir -p "$AC_HOME/data/famdead"
printf '# Room: famdead\n\n- [2026-08-09T10:00:00Z] crewchief> PROMOTED: opened\n' \
  >"$AC_HOME/data/famdead/room.md"
AC_SCOPE=famdead AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
opid=$!
in_poll_wait "$opid" "$state/.last-watcher-beat.famdead" >/dev/null \
  || fail "the orphan-candidate watcher never reached its poll wait"

# While the room's last tenure marker is PROMOTED, it is NOT an orphan: the
# guard must still refuse, or a live family loses coverage to this exception.
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$opid" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a scoped watcher whose room still reads PROMOTED is refused"
assert_contains "$out" "belongs to that family" "... with the ordinary refusal"
kill -0 "$opid" 2>/dev/null || fail "the refused watcher must survive untouched"

# Demotion posts DEMOTED to the room - now the same release is ALLOWED, and it
# must actually take the watcher down.
printf -- '- [2026-08-09T10:20:00Z] crewchief> DEMOTED: roomchief closed\n' \
  >>"$AC_HOME/data/famdead/room.md"
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$opid" 2>&1)" || rc=$?
assert_eq "$rc" "0" "once the room records DEMOTED, the orphan IS releasable"
assert_contains "$out" "DEMOTED/CLOSED" "the note says WHY it was allowed"
assert_contains "$out" "famdead" "... and names the family"
dead_within "$opid" 20 || { kill -9 "$opid" 2>/dev/null; wait "$opid" 2>/dev/null; \
  fail "the released orphan must actually die - a release that only prints is no remedy"; }
wait "$opid" 2>/dev/null || true

# A re-PROMOTED family is protected again: the LAST marker decides, so a
# demote-then-promote cycle never leaves the exception standing open.
printf -- '- [2026-08-09T11:00:00Z] crewchief> PROMOTED: reopened\n' \
  >>"$AC_HOME/data/famdead/room.md"
AC_SCOPE=famdead AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
opid2=$!
in_poll_wait "$opid2" "$state/.last-watcher-beat.famdead" >/dev/null \
  || fail "the re-promoted family's watcher never reached its poll wait"
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$opid2" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a re-PROMOTED family is protected again - the LAST marker decides"
kill "$opid2" 2>/dev/null; wait "$opid2" 2>/dev/null || true
rm -rf "$AC_HOME/data/famdead"
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log" "$state"/.watcher-release-*

# (8e) SCOPED-TARGET REFUSAL (behavior: watcher-release-scope). --release is the
# FLEET watcher's remedy; a scoped watcher belongs to its roomchief, and the
# crewchief's config-swap loop (read every ac-watch pid -> release each) TERM'd
# those too, costing a family real-time coverage until its roomchief noticed and
# re-armed (7 re-arms in one session, 2026-07-21). The fleet half stays exactly
# as (8a) proved it; only a scoped target is refused, and it must SURVIVE the
# refusal untouched.
AC_SCOPE=fam1 AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat.fam1" >/dev/null \
  || fail "the scoped watcher never reached its poll wait"
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$wpid" 2>&1)" || rc=$?
assert_eq "$rc" "2" "--release on a SCOPED watcher is refused"
assert_contains "$out" "scoped watcher" "the refusal says WHAT it refused"
assert_contains "$out" "fam1" "... and names the family it belongs to"
assert_no_file "$state/.watcher-release-$wpid" "a refused release stamps no marker"
ps -p "$wpid" >/dev/null 2>&1 \
  || fail "a refused release must leave the scoped watcher ALIVE - that is the whole point"
assert_file "$state/.watch-only-fam1.lock.d/pid" "... and its lock untouched, so its roomchief still owns it"
assert_contains "$(cat "$state/.watcher-arm.log")" "release REFUSED pid=$wpid" \
  "the refusal joins the arm log - the trail an investigation reads"
kill -TERM "$wpid"
wait "$wpid" 2>/dev/null || true
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"

# (8f) The scoped refusal covers the WRAPPER too (behavior:
# watcher-release-wrapper-orphan). The harness arms a watcher inside a wrapper
# shell it tracks (`chain=<watcher>(bash) < <wrapper>(zsh) < ...`), so a release
# aimed at the WRAPPER pid slipped past (8e)'s guard: the wrapper died, the real
# watcher lived on reparented to PPID=1, still polling but with an exit that
# wakes no one - the orphan AGENTS.md section 7 forbids. Observed live on
# drydock 2026-07-21: wrapper 67124 released while scoped watcher 67150 was
# refused, leaving 67150 orphaned. Wrapper and watcher are ONE unit to --release.
lock_pid_within() {
  # lock_pid_within <lock-dir> - the pid recorded under <lock-dir> once the
  # watcher gets there ('' if it never does). A wrapped watcher's pid is not
  # the one $! reports, and the lock is where --release reads it from anyway.
  local d="$1" p
  for _ in $(seq 1 400); do
    p="$(cat "$d/pid" 2>/dev/null || true)"
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    sleep 0.05
  done
  return 1
}
# DISPUTED: the watcher's scope - AC_SCOPE=fam1 here, unset in (8g) - which is
# the ONE thing --release is supposed to decide on for a wrapped unit.
# HELD-CONSTANT with (8g): the arm (AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300),
# the wrapper shape, the release command, and the pids read from the lock.
# AC_LOCK_PID rides both legs even though the scoped one never consults it -
# ac-lock.sh's do_acquire returns before self_pid on any AC_SCOPE session
# (ac-lock.sh:186) - so the two legs differ by the disputed variable alone
# instead of by scope AND lock identity.
AC_SCOPE=fam1 AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash -c \
  'bash "$1" >"$2" 2>/dev/null & wait' _ "$BIN/ac-watch.sh" "$sigout" &
wrapper=$!
wpid="$(lock_pid_within "$state/.watch-only-fam1.lock.d")" \
  || fail "the wrapped scoped watcher never armed"
in_poll_wait "$wpid" "$state/.last-watcher-beat.fam1" >/dev/null \
  || fail "the wrapped scoped watcher never reached its poll wait"
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$wrapper" 2>&1)" || rc=$?
assert_eq "$rc" "2" "--release on the WRAPPER of a scoped watcher is refused too"
assert_contains "$out" "wrapper" "the refusal says it is the wrapper it refused"
assert_contains "$out" "fam1" "... and names the family the unit belongs to"
assert_no_file "$state/.watcher-release-$wrapper" "a refused wrapper release stamps no marker"
ps -p "$wrapper" >/dev/null 2>&1 \
  || fail "the wrapper must survive - TERMing it is exactly what orphans the watcher"
ps -p "$wpid" >/dev/null 2>&1 \
  || fail "the scoped watcher must survive a release aimed at its wrapper"
assert_contains "$(cat "$state/.watcher-arm.log")" "release REFUSED pid=$wrapper" \
  "the wrapper refusal joins the arm log like the watcher one"
kill -TERM "$wpid" 2>/dev/null || true
kill -TERM "$wrapper" 2>/dev/null || true
wait "$wrapper" 2>/dev/null || true
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"

# (8g) The FLEET watcher's wrapper stays releasable - the refusal above is
# scoped-only, and --release remains the fleet watcher's own remedy however the
# caller names its unit.
# DISPUTED: the watcher's scope - unset here, AC_SCOPE=fam1 in (8f).
# HELD-CONSTANT with (8f): everything else on the arm line, the wrapper shape,
# the release command, and the pids read from the lock (see 8f's note for why
# AC_LOCK_PID is constant across the pair rather than a second variable).
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash -c \
  'bash "$1" >"$2" 2>/dev/null & wait' _ "$BIN/ac-watch.sh" "$sigout" &
wrapper=$!
wpid="$(lock_pid_within "$lockd")" || fail "the wrapped fleet watcher never armed"
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the wrapped fleet watcher never reached its poll wait"
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$wrapper" 2>&1)" || rc=$?
assert_eq "$rc" "0" "the FLEET watcher's wrapper stays releasable"
assert_contains "$out" "released: pid=$wrapper" "... and the release names the pid it TERM'd"
kill -TERM "$wpid" 2>/dev/null || true
wait "$wrapper" 2>/dev/null || true
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log" "$state/.watcher-release-$wrapper"

# (8h) HOME-CROSSING REFUSAL (behavior:
# watcher-release-crosses-home-boundaries) - a REAL 2026-08-05 incident: an
# operator pattern-matched the process list for a watcher pid, released it by
# exact number, and could not prove afterward which home it belonged to (every
# home on the box runs the same command line). --release must refuse ANY pid
# that is not THIS home's own fleet-watcher UNIT (the lock pid or its direct
# parent) - even while this home's own fleet watcher IS armed and healthy, a
# foreign pid must never be reachable just because ours happens to be running.
# Proven with a throwaway fixture process this test spawns and reaps itself -
# never a real machine pid, never a pattern match over the live process list.
rm -f "$state"/.last-watcher-beat* "$state/.watcher-arm.log"
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >"$sigout" 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the home-crossing fixture watcher never reached its poll wait"
sleep 100 & foreign=$!
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$foreign" 2>&1)" || rc=$?
assert_eq "$rc" "2" \
  "--release refuses a pid that is not this home's own fleet watcher, even with one armed"
assert_contains "$out" "not this home" \
  "the refusal says it is not this home's fleet watcher"
assert_contains "$out" ".watch.lock.d/pid" \
  "... and names where the caller can find the pid it probably wanted"
assert_no_file "$state/.watcher-release-$foreign" "a refused release stamps no marker"
ps -p "$foreign" >/dev/null 2>&1 \
  || fail "a refused release must leave the foreign pid untouched"
ps -p "$wpid" >/dev/null 2>&1 \
  || fail "this home's own fleet watcher must survive a foreign-pid release too"
assert_contains "$(cat "$state/.watcher-arm.log")" "release REFUSED pid=$foreign" \
  "the refusal joins the arm log - the trail an investigation reads"
kill -TERM "$foreign" 2>/dev/null || true
wait "$foreign" 2>/dev/null || true
kill -TERM "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null || true
rm -f "$state/.session-lock" "$state/.watcher-owner" "$state"/.last-watcher-beat* \
  "$state/.watcher-arm.log"

# (8i) NO FLEET WATCHER ARMED AT ALL IN THIS HOME - fail CLOSED, never fall
# through to the kill just because our own record is missing.
sleep 100 & foreign=$!
rc=0; out="$(bash "$BIN/ac-watch.sh" --release "$foreign" 2>&1)" || rc=$?
assert_eq "$rc" "2" \
  "--release refuses when this home has no fleet watcher armed at all"
assert_contains "$out" "not this home" \
  "the refusal says it is not this home's fleet watcher"
assert_no_file "$state/.watcher-release-$foreign" "a refused release stamps no marker"
ps -p "$foreign" >/dev/null 2>&1 \
  || fail "a refused release must leave the foreign pid untouched"
kill -TERM "$foreign" 2>/dev/null || true
wait "$foreign" 2>/dev/null || true
rm -f "$state/.watcher-arm.log"

# End to end against the backend code path: a captain-relevant line in a
# live pane's buffer wakes the watcher once (the launch-to-capture plumbing
# is backend_capture over the fake CLI - synchronous, no settle sleeps).
rm -rf "$state/.wake-spool"
printf 'window=crew:w1\nbackend=herdr\n' >"$state/w1.meta"
seed_pane w1 pW1 tW1
printf 'done: shipped the widget\n' >>"$(fake_pane_buf w1)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:w1" "watcher exit reason"
assert_contains "$(fleet_spool)" "done: shipped the widget" "wake published"
assert_contains "$(cat "$state/w1.status")" "done: shipped the widget" "status appended"
# The same marker is absorbed on the next pass (no duplicate wake).
rm -rf "$state/.wake-spool"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "marker absorbed once seen"
assert_no_file "$state/.wake-spool" "no duplicate wake"
# A pane merely DISPLAYING code that quotes a marker does not wake.
printf 'window=crew:w2\nbackend=herdr\n' >"$state/w2.meta"
seed_pane w2 pW2 tW2
printf '%s\n' '  printf "done: %s"' >>"$(fake_pane_buf w2)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "displayed code marker absorbed"
assert_no_file "$state/.wake-spool" "no false-positive wake"

# A FAILED publish is loud, never silent: by the time queue_wake runs, the
# dedup marker has already advanced (and errexit is off inside the
# `if check_fleet` condition), so a swallowed failure would lose the wake
# with no trace and no retry. With the clock broken (empty `date +%s%N`
# output -> ac_wake_publish refuses), the pass still prints its reason line
# (stdout stays the exit reason's alone) and the failure lands in the arm
# log AND on stderr - the header's out-of-band channel.
badclock="$TMP/badclock-watch"
mkdir -p "$badclock"
cat >"$badclock/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s%N" ]; then exit 0; fi   # prints NOTHING, exits 0
exec /bin/date "$@"
EOF
chmod +x "$badclock/date"
rm -f "$state/.watcher-arm.log"
printf 'window=crew:w3\nbackend=herdr\n' >"$state/w3.meta"
seed_pane w3 pW3 tW3
printf 'done: publish will fail\n' >>"$(fake_pane_buf w3)"
out="$(PATH="$badclock:$PATH" bash "$BIN/ac-watch.sh" --once 2>"$TMP/badclock.err")"
assert_contains "$out" "report:w3" "the reason line still prints when the publish fails"
assert_contains "$(cat "$state/.watcher-arm.log")" "wake-publish FAILED" \
  "the failed publish is logged loudly in the arm log"
assert_contains "$(cat "$TMP/badclock.err")" "wake-publish FAILED" "... and on stderr"
assert_no_file "$state/.wake-spool" "no record was published by the failed pass"

# A DECISION marker (needs-decision:/blocked:) stamps the pane BLOCKED in the
# herdr UI until answered; any later non-decision marker clears the stamp,
# and the stamp itself never re-wakes the watcher as an ask: (contract:
# ac-backend.sh CAPTAIN-WAIT STAMP; captain order 2026-07-17).
rm -rf "$state/.wake-spool"
printf 'window=crew:w4\nbackend=herdr\n' >"$state/w4.meta"
seed_pane w4 pW4 tW4
printf 'needs-decision: keep or drop the cache?\n' >>"$(fake_pane_buf w4)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:w4" "decision marker wakes"
assert_eq "$(cat "$FAKE_HERDR/panes/pW4.reported")" "blocked" "decision marker stamps the pane blocked"
assert_file "$state/.captain-wait-w4" "stamp ownership recorded"
rm -rf "$state/.wake-spool"
out="$(bash "$BIN/ac-watch.sh" --once)"
case "$out" in *ask:w4*) fail "a fleet stamp must never produce an ask: wake" ;; esac
printf 'done: decision applied\n' >>"$(fake_pane_buf w4)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:w4" "the later marker still wakes"
assert_no_file "$FAKE_HERDR/panes/pW4.reported" "a non-decision marker releases the stamp"
assert_no_file "$state/.captain-wait-w4" "stamp ownership file removed"

# Reconcile: a pane still PARKED on an already-seen captain-wait marker but
# carrying no stamp is re-stamped silently (no wake); a BUSY pane whose tail
# still shows an old marker is left alone; and the delivery-await marker
# (checks-passed: from crew-ship finish) stamps like the decision verbs - it
# waits on the captain's merge.
rm -rf "$state/.wake-spool"
printf 'window=crew:w5\nbackend=herdr\n' >"$state/w5.meta"
seed_pane w5 pW5 tW5
printf 'needs-decision: pick color\n' >>"$(fake_pane_buf w5)"
printf 'needs-decision: pick color\n' >"$state/.seen-w5"
printf 'window=crew:w6\nbackend=herdr\n' >"$state/w6.meta"
seed_pane w6 pW6 tW6
printf 'needs-decision: pick shape\nesc to interrupt\n' >>"$(fake_pane_buf w6)"
printf 'needs-decision: pick shape\n' >"$state/.seen-w6"
printf 'window=crew:w7\nbackend=herdr\n' >"$state/w7.meta"
seed_pane w7 pW7 tW7
printf 'checks-passed: w7-ship PR raised, awaiting merge\n' >>"$(fake_pane_buf w7)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_file "$state/.captain-wait-w5" "parked pane reconciled to a stamp"
assert_eq "$(cat "$FAKE_HERDR/panes/pW5.reported")" "blocked" "reconciled pane reported blocked"
case "$out" in *report:w5*) fail "a reconcile must not wake - the marker was already seen" ;; esac
assert_no_file "$state/.captain-wait-w6" "busy pane never reconcile-stamped"
assert_contains "$out" "report:w7" "a delivery-await marker wakes"
assert_file "$state/.captain-wait-w7" "a delivery-await marker stamps - it waits on the captain's merge"

# BUSY-PANE STAMP GUARD (crewmate-pane-absent-from-herdr-grouped-agents): only a
# PARKED pane is stamped. The stamp takes herdr's agent lifecycle authority and
# MASKS herdr's own detection; the release that must follow a busy stamp is the
# STALE-STAMP SUPERSESSION, which fires ONLY while busy - so it lands with no
# state transition ahead of it and leaves the pane with NO agent identity until
# the turn ends. That is what emptied the grouped agents panel (measured: ~20min
# on w1F:p3K, 9m43s on w1F:p3M). The guard sits on the backend_mark_wait CALL
# alone: the status append and the wake stay UNCONDITIONAL, because a dropped
# captain wake is worse than the defect. The colour is not lost, it is DEFERRED
# to the Reconcile branch above, which stamps once the pane reads non-busy -
# exactly the idle precondition ac-backend.sh's CAPTAIN-WAIT STAMP states.
rm -rf "$state/.wake-spool"
printf 'window=crew:w8\nbackend=herdr\n' >"$state/w8.meta"
seed_pane w8 pW8 tW8
printf 'needs-decision: keep the index?\nesc to interrupt\n' >>"$(fake_pane_buf w8)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:w8" "a busy pane's decision marker still WAKES - the guard never touches the wake"
assert_contains "$(cat "$state/w8.status")" "needs-decision: keep the index?" \
  "... and still appends the durable status line every fleet view renders"
assert_no_file "$FAKE_HERDR/panes/pW8.reported" "a BUSY pane is never stamped blocked"
assert_no_file "$state/.captain-wait-w8" "... so the fleet records no stamp ownership it would have to release mid-work"

# The DEFERRED colour: same pane, same marker still in its tail, now non-busy.
rm -rf "$state/.wake-spool"
: >"$(fake_pane_buf w8)"
printf 'needs-decision: keep the index?\n' >>"$(fake_pane_buf w8)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_file "$state/.captain-wait-w8" "the stamp is DEFERRED to the moment the pane parks, never dropped"
assert_eq "$(cat "$FAKE_HERDR/panes/pW8.reported")" "blocked" "the deferred stamp reports blocked"
case "$out" in *report:w8*) fail "the deferred stamp must not re-wake - the marker was already seen" ;; esac

# === supervision-liveness (watcher-liveness, 2026-07-18) ======================
# Four surgical fixes for "work goes pending while no live watcher covers it".
reset_state() {
  rm -f "$state"/*.meta "$state"/.pane-* "$state"/.seen-* \
    "$state"/.hash-* "$state"/.change-* "$state"/.stale-* "$state"/.gone-* \
    "$state"/.unobservable-* \
    "$state"/.report-hash-* "$state"/.superseded-* \
    "$state"/.last-watcher-beat* "$state"/.skip-revoked-* "$state"/.skip-stale-since-* \
    "$state"/.chief-busy-until* \
    "$state"/.watcher-arm.log \
    "$state"/.watcher-config* "$state"/.session-lock "$state"/.watcher-owner
  rm -rf "$state"/.wake-spool* "$state/.watch.lock.d"
  rm -f "$AC_HOME/config/remote-poll"
}

# --- (1) AC_WATCH_SKIP revalidation: the skip's justification IS a live scoped
# watcher. A skipped family is honored only while its roomchief is live AND its
# beacon fresh; when either is gone the fleet watcher covers its panes directly
# and logs the takeover once (watcher-skip-staleness).
reset_state
mkdir -p "$AC_HOME/data/rf"                             # rf is a real family here
printf 'window=crew:rf-chief\nbackend=herdr\n' >"$state/rf-chief.meta"
seed_pane rf-chief pRFC tRFC                            # live roomchief
printf 'window=crew:rf-t1\nbackend=herdr\n' >"$state/rf-t1.meta"
seed_pane rf-t1 pRF1 tRF1
printf 'done: family work\n' >>"$(fake_pane_buf rf-t1)"

# Coverage LIVE (chief live + fresh beacon) -> rf-t1 is skipped (happy path).
date +%s >"$state/.last-watcher-beat.rf"
out="$(AC_WATCH_SKIP=rf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a live scoped family is still skipped (happy path)"
case "$out" in *report:rf-t1*) fail "a live scoped family must not be watched by the fleet" ;; esac
assert_no_file "$state/.skip-revoked-rf" "no revoke while coverage is live"

# RE-ARM GRACE (roomchief-scoped-watcher-blindness): a LIVE roomchief whose
# scoped watcher just heartbeat-exited stood its beacon DOWN (0) - the normal
# exit->re-arm gap, not lost coverage. The fleet must HOLD the skip: not cover
# rf-t1, not touch the shared .seen-rf-t1 dedup marker, not revoke - so the
# family's done wake is never stolen to the fleet spool.
rm -f "$state/.skip-revoked-rf" "$state/.skip-stale-since-rf" "$state/.seen-rf-t1"
printf '0\n' >"$state/.last-watcher-beat.rf"                 # stand-down (d52ec6a #4)
out="$(AC_WATCH_SKIP=rf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a live roomchief mid re-arm keeps its skip (re-arm grace)"
case "$out" in *report:rf-t1*) fail "the fleet must not steal a re-arming family's pane" ;; esac
assert_no_file "$state/.skip-revoked-rf" "no revoke during the re-arm grace"
assert_no_file "$state/.seen-rf-t1" "the shared dedup marker is untouched, so the scoped watcher can still re-emit"
assert_file "$state/.skip-stale-since-rf" "the re-arm gap is tracked"

# The re-armed scoped watcher then delivers the done to the FAMILY spool -
# proof the wake was held for the roomchief, not stolen to the fleet.
out="$(AC_SCOPE=rf AC_WATCH_ONLY=rf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:rf-t1" "the re-armed scoped watcher catches the done"
assert_eq "$(find "$state/.wake-spool.rf" -type f 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "the done lands in the FAMILY spool, not the fleet's"

# Beacon stale PAST the re-arm grace -> the roomchief is genuinely not
# re-arming; the fleet revokes as a fail-safe and covers rf-t1.
rm -f "$state/.skip-revoked-rf" "$state/.seen-rf-t1"
printf '0\n' >"$state/.last-watcher-beat.rf"
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.skip-stale-since-rf"   # gap opened long ago
out="$(AC_WATCH_SKIP=rf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:rf-t1" "a beacon stale past the grace is covered directly"
assert_file "$state/.skip-revoked-rf" "the revoke is marked once"
assert_contains "$(cat "$state/.watcher-arm.log")" "skip revoked: rf" "the takeover is logged"

# Coverage back (fresh beacon) -> skip honored again, both trackers cleared.
date +%s >"$state/.last-watcher-beat.rf"
rm -f "$state/.seen-rf-t1"
out="$(AC_WATCH_SKIP=rf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "restored coverage is skipped again"
assert_no_file "$state/.skip-revoked-rf" "the revoke marker is cleared when coverage returns"
assert_no_file "$state/.skip-stale-since-rf" "the re-arm gap tracker is cleared when coverage returns"

# An UNREADABLE beacon - present but non-numeric - is a beacon state
# ac_watcher_beat_read already names and classifies ("present but empty or
# non-numeric", ac-wake-lib.sh), so it must read as NO BEAT here, exactly like
# the stand-down 0 above. Read raw, its text reaches `$(( now - beat ))`, where
# bash evaluates the VALUE as an arithmetic expression, looks its first
# identifier up as a variable and dies under set -u - naming a variable that
# exists nowhere in this script, and killing fleet supervision SILENTLY.
# Observed live 2026-08-05: fleet watcher pid 66812 printed nothing but
# "bin/ac-watch.sh: line 957: signal: unbound variable" and was gone.
rm -f "$state/.seen-rf-t1"
printf 'signal:TERM pid=1 target=fleet - watcher killed externally\n' >"$state/.last-watcher-beat.rf"
rc=0
out="$(AC_WATCH_SKIP=rf bash "$BIN/ac-watch.sh" --once)" || rc=$?
assert_eq "$rc" "0" "an unreadable beacon must not kill the fleet watcher"
assert_contains "$out" "check:quiet" "an unreadable beacon leaves the watcher polling"
assert_file "$state/.skip-stale-since-rf" "an unreadable beacon reads as no beat, so the re-arm gap opens"

# Coverage down via a GONE roomchief (chief meta archived by teardown, beacon
# still fresh) -> revoked IMMEDIATELY, with NO re-arm grace (there is no
# roomchief left to re-arm). The fresh beacon is restored here rather than
# inherited, because the unreadable-beacon case above leaves a poisoned one.
date +%s >"$state/.last-watcher-beat.rf"
rm -f "$FAKE_HERDR/panes/pRFC.buf" "$FAKE_HERDR/tabs/tRFC" "$state/.pane-rf-chief" \
  "$state/rf-chief.meta" "$state/.seen-rf-t1" "$state/.skip-revoked-rf" "$state/.skip-stale-since-rf"
out="$(AC_WATCH_SKIP=rf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:rf-t1" "a family whose roomchief is gone is covered directly"
assert_file "$state/.skip-revoked-rf" "a gone roomchief revokes immediately (no grace)"

# --- (1a) BUSY DECLARATION (skip-grace-too-short-for-a-chief-inside-a-long-
# synchronous-gate): the re-arm grace is sized for a roomchief mid re-arm, but a
# roomchief blocked inside ONE synchronous ac-gate.sh call cannot take a turn at
# all for up to AC_GATE_TIMEOUT (600s) - longer than AC_GUARD_GRACE (300s) - so a
# HEALTHY chief used to lose its skip merely for being busy. The gate DECLARES
# that bounded window; the fleet holds the skip while it is unexpired, and
# revokes exactly as before once it is not.
reset_state
mkdir -p "$AC_HOME/data/bf"
printf 'window=crew:bf-chief\nbackend=herdr\n' >"$state/bf-chief.meta"
seed_pane bf-chief pBFC tBFC                            # live roomchief, inside a gate
printf 'window=crew:bf-t1\nbackend=herdr\n' >"$state/bf-t1.meta"
seed_pane bf-t1 pBF1 tBF1
printf 'done: family work\n' >>"$(fake_pane_buf bf-t1)"
printf '0\n' >"$state/.last-watcher-beat.bf"                              # scoped watcher stood down
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.skip-stale-since-bf"  # gap opened PAST the re-arm grace

# An UNEXPIRED declaration holds the skip even though the beacon has been stale
# past the grace: the chief is BUSY, not dead, and the fleet's takeover would buy
# nothing (the blocked roomchief cannot act on the wake, and the crewchief does
# not own the family and may not).
printf '%s\n' "$(( $(date +%s) + 300 ))" >"$state/.chief-busy-until.bf"
out="$(AC_WATCH_SKIP=bf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a live roomchief inside a declared bounded gate keeps its skip"
case "$out" in *report:bf-t1*) fail "the fleet must not steal the pane of a family whose chief declared a live busy window" ;; esac
assert_no_file "$state/.skip-revoked-bf" "no revoke while the declaration is unexpired"
assert_no_file "$state/.seen-bf-t1" "the shared dedup marker is untouched, so the scoped watcher can still re-emit"

# The other direction, (a): an EXPIRED declaration is no declaration. A gate
# killed with no chance to clean up must not hold the skip forever - past the
# declared bound, revocation resumes exactly as today.
printf '%s\n' "$(( $(date +%s) - 1 ))" >"$state/.chief-busy-until.bf"
out="$(AC_WATCH_SKIP=bf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:bf-t1" "an EXPIRED declaration revokes exactly as today"
assert_file "$state/.skip-revoked-bf" "the takeover is marked once past the declared bound"

# The other direction, (b): a GONE roomchief revokes IMMEDIATELY whatever it
# declared - the declaration extends the BUSY case only, never overrides liveness.
rm -f "$FAKE_HERDR/panes/pBFC.buf" "$FAKE_HERDR/tabs/tBFC" "$state/.pane-bf-chief" \
  "$state/bf-chief.meta" "$state/.seen-bf-t1" "$state/.skip-revoked-bf"
printf '%s\n' "$(( $(date +%s) + 300 ))" >"$state/.chief-busy-until.bf"
out="$(AC_WATCH_SKIP=bf bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:bf-t1" "a GONE roomchief is covered directly whatever it declared"
assert_file "$state/.skip-revoked-bf" "a gone roomchief revokes immediately despite a live declaration"

# --- (1b) STORY-PANE skip (epic-roomchief-watch-only-omits-story-ids): an EPIC
# roomchief's scoped watcher covers its STORY crewmate panes, whose family ids
# DIFFER from the epic's. A story pane matches the fleet's skip by its meta
# fleet_scope (the epic), not by the <fam>/<fam>-* id grammar - so the fleet
# skips it while the EPIC's coverage is live (revalidated against the EPIC, not
# the story id) and RE-COVERS it when that coverage is gone.
reset_state
mkdir -p "$AC_HOME/data/ep"                              # ep is the promoted epic
printf 'window=crew:ep-chief\nbackend=herdr\n' >"$state/ep-chief.meta"
seed_pane ep-chief pEPC tEPC                             # live epic roomchief
# st is a STORY family: its id matches neither ep nor ep-* by the grammar, but
# its meta fleet_scope names the epic (ac-spawn records it at spawn time).
printf 'window=crew:st\nbackend=herdr\nfleet_scope=ep\n' >"$state/st.meta"
seed_pane st pST1 tST1
printf 'done: story work\n' >>"$(fake_pane_buf st)"

# Coverage LIVE (epic roomchief live + fresh EPIC beacon) -> the fleet SKIPS
# the story pane: its epic's own scoped watcher owns it, so a done with no
# ac-done routes to the epic spool, not the fleet's.
date +%s >"$state/.last-watcher-beat.ep"
out="$(AC_WATCH_SKIP=ep bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a story pane under a LIVE epic roomchief is skipped by the fleet"
case "$out" in *report:st*) fail "the fleet must not cover a story pane its epic roomchief owns" ;; esac
assert_no_file "$state/.seen-st" "the shared dedup marker is untouched, so the epic's scoped watcher can still emit"

# Coverage GONE (epic roomchief torn down) -> the fleet RE-COVERS the story
# pane, so the story's no-ac-done completion is never stranded.
rm -f "$FAKE_HERDR/panes/pEPC.buf" "$FAKE_HERDR/tabs/tEPC" "$state/.pane-ep-chief" \
  "$state/ep-chief.meta"
out="$(AC_WATCH_SKIP=ep bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:st" "a story pane whose epic roomchief is gone is covered directly"

# --- (2) config-aware re-arm: a second arm with a DIFFERENT AC_WATCH_SKIP than
# the live singleton must WIN, never silently no-op. Refuse loudly (exit 2)
# naming both configs; an IDENTICAL arm stays idempotent (already running).
reset_state
mkdir -p "$AC_HOME/data/ska" "$AC_HOME/data/skb"       # both known to this home
lockd="$state/.watch.lock.d"
hold_open cfg-hold; cfgpid=$HOLD_PID
mkdir -p "$lockd"; printf '%s\n' "$cfgpid" >"$lockd/pid"  # a LIVE watcher holds it
printf 'ska\n' >"$state/.watcher-config"                  # its recorded config
rc=0; out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=skb AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a differing-config second arm refuses instead of silently no-oping"
assert_contains "$out" "refused" "the refusal says so"
assert_contains "$out" "ska" "... names the running config"
assert_contains "$out" "skb" "... and the new config"
# The remedy names the OWNER-MARKED release command, not a bare `kill` - the
# log a bare kill produces says `killed externally`, which is what sent two
# families chasing a hostile actor (watcher-owner-term-quiet).
assert_contains "$out" "--release $cfgpid" "... and the exact single-target release command (named-release-target)"
assert_contains "$out" "pkill" "... warning that a pattern kill reaps other homes' watchers"
assert_contains "$(cat "$state/.watcher-arm.log")" "--release $cfgpid" "the arm log records the named release target too"
out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>&1)"
assert_contains "$out" "already running" "an identical second arm stays idempotent"
assert_eq "$(cat "$state/.watcher-config")" "ska" "a refused/idempotent arm leaves the singleton's config intact"
hold_close cfg-hold "$cfgpid"

# --- (2a) AC_WATCH_SKIP is compared as a SET, not a string (behavior:
# watch-skip-compared-as-a-string-not-a-set): the two producers of this list
# disagree on ORDER by construction (a chief types its own order,
# ac-watch-autoarm.sh's promoted_families() enumerates via a glob the shell
# sorts alphabetically), so a same-membership re-arm in a different order
# must not read as a config swap.
reset_state
mkdir -p "$AC_HOME/data/ska" "$AC_HOME/data/skb" "$AC_HOME/data/skc"
lockd="$state/.watch.lock.d"
hold_open set-hold; setpid=$HOLD_PID
mkdir -p "$lockd"; printf '%s\n' "$setpid" >"$lockd/pid"  # a LIVE watcher holds it
printf 'ska,skb\n' >"$state/.watcher-config"               # its recorded config

# SAME SET, DIFFERENT ORDER: accepted, incumbent left alone. This is the bug.
out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=skb,ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>&1)"
assert_contains "$out" "already running" "same set, different order is accepted, not a config swap"
assert_eq "$(cat "$state/.watcher-config")" "ska,skb" "a same-set re-arm leaves the incumbent's recorded config untouched"

# DUPLICATE-only difference: still the same set.
out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska,skb,skb AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>&1)"
assert_contains "$out" "already running" "a duplicate-only difference is the same set"

# SUBSET: NOT the same set - still refused. Proves the fix is not a loosening.
rc=0; out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a genuine subset is still refused"
assert_contains "$out" "refused: a live watcher" "... with the unchanged refusal prefix"
assert_contains "$out" "ska,skb" "... naming the running config"

# GENUINELY DIFFERENT SET (same size, different membership): still refused.
rc=0; out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska,skc AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a genuinely different set is still refused, exit 2"
assert_contains "$out" "refused: a live watcher" "... with the unchanged refusal prefix"
assert_contains "$out" "ska,skb" "... naming the running config"
assert_contains "$out" "ska,skc" "... and the new config"

hold_close set-hold "$setpid"

# --- (2b) arm-refusal-says-nothing-about-pending-work: a re-arm refusal must
# say whether the arming session's own inbox is non-empty, on the REAL
# concurrent situation - a LIVE watcher holding the lock CONCURRENTLY with a
# wake record sitting in the spool. Coverage-exists must not read as
# nothing-to-do. Both refusal paths (idempotent already-running, and
# config-mismatch) are covered, and the autoarm consumer's classification
# prefix (ac-watch-autoarm.sh:203) must still match on a single line - a
# refusal that BECOMES a second line breaks that hook's `tail -n 1` reduction
# of the reason, so the pending state must ride the SAME line, never a new one.
reset_state
mkdir -p "$AC_HOME/data/ska" "$AC_HOME/data/skb"
lockd="$state/.watch.lock.d"
hold_open pend-hold; pendpid=$HOLD_PID
mkdir -p "$lockd"; printf '%s\n' "$pendpid" >"$lockd/pid"   # a LIVE watcher holds it
printf 'ska\n' >"$state/.watcher-config"
mkdir -p "$state/.wake-spool"
printf '1\treport\tt1\tdone: shipped\n' >"$state/.wake-spool/1.1.000000"   # a wake sits in the spool

# Idempotent path (identical config) with a pending wake: still "already
# running" (idempotent, exit 0 unchanged), but now says a wake is waiting.
# stdout only (2>/dev/null), the same channel ac-watch-autoarm.sh:195 reads -
# stderr carries the unrelated lock-acquire owner_note, never the reason.
out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
case "$out" in
  'already running'*) : ;;
  *) fail "the idempotent prefix must stay exactly 'already running' - the autoarm consumer keys on it" ;;
esac
assert_contains "$out" "ac-wake-drain.sh" "a pending wake names the drain, not just coverage"

# Config-mismatch path with the SAME pending wake: still refuses (exit 2,
# unchanged lock/config-swap semantics), and now also names the pending wake.
rc=0; out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=skb AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)" || rc=$?
assert_eq "$rc" "2" "the config-mismatch refusal still exits 2"
case "$out" in
  'refused: a live watcher'*) : ;;
  *) fail "the config-mismatch prefix must stay exactly 'refused: a live watcher' - the autoarm consumer keys on it" ;;
esac
assert_contains "$out" "ac-wake-drain.sh" "a pending wake names the drain here too"

# Empty inbox: the SAME idempotent path, but no wake anywhere - the refusal
# must say the inbox is empty, plainly, rather than leaving it to infer.
rm -rf "$state/.wake-spool"
out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
case "$out" in
  'already running'*) : ;;
  *) fail "the idempotent prefix must stay exactly 'already running' with an empty inbox too" ;;
esac
case "$out" in *ac-wake-drain.sh*) fail "an empty inbox must not point to the drain" ;; esac
assert_contains "$out" "empty" "an empty inbox is stated plainly, not left to infer"
hold_close pend-hold "$pendpid"
rm -rf "$state/.wake-spool"

# --- (2c) rearm-stands-aside-for-a-watcher-that-then-exits: a HAND arm must not
# report coverage that belongs to the auto-arm hook's own watcher.
# THE MEASURED ORDER behind this, one instrumented run with per-process stamps
# (2026-08-06): the hand arm printed `already running` with the incumbent LIVE at
# T+0; the incumbent's stand_down_beacon landed at T+2.513s (the beacon inode's
# own mtime); ac-watch-autoarm.sh handed its budget back at T+2.536s; the
# turn-end guard read the stood-down beacon and blocked at T+2.602s. The
# incumbent was retired by its OWNER, on schedule - so "does a watcher exist
# right now" was never the question the hand arm needed answered.
# What the arm branches on is OWNERSHIP, not a beacon state: at the instant of
# the arm the incumbent is beating normally (a real beat, state 4 of
# ac_watcher_beat_read's four), and every beacon state reads healthy.
reset_state
mkdir -p "$AC_HOME/data/ska"
lockd="$state/.watch.lock.d"
hold_open own-hold; ownpid=$HOLD_PID
mkdir -p "$lockd"; printf '%s\n' "$ownpid" >"$lockd/pid"   # a LIVE watcher holds it
printf 'ska\n' >"$state/.watcher-config"                   # ... with an IDENTICAL config
: >"$lockd/autoarm"                                        # ... and the hook armed it

rc=0; out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)" || rc=$?
assert_eq "$rc" "2" "a hand arm over a hook-armed watcher refuses: nothing it did covers the next turn end"
case "$out" in
  'already running'*) fail "a hand arm must not report 'already running' for a watcher the auto-arm hook retires at its own handback" ;;
esac
assert_contains "$out" "auto-arm" "the refusal names WHOSE watcher is covering"
assert_contains "$out" "--release $ownpid" "... and the exact single-target release command (named-release-target)"
assert_contains "$out" "pkill" "... warning that a pattern kill reaps other homes' watchers"
assert_contains "$out" "empty" "... and still carries the pending-inbox note, on the SAME line"
assert_eq "$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')" "1" \
  "the refusal stays ONE line - ac-watch-autoarm.sh reduces this stdout to its LAST non-empty line before classifying"

# The HOOK's own stand-aside is the untouched path, and it is the one whose
# prefix ac-watch-autoarm.sh:203 globs on: same incumbent, same lock, exit 0.
out="$(AC_AUTOARM=1 AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
case "$out" in
  'already running'*) : ;;
  *) fail "the hook standing aside from its own predecessor must keep the exact 'already running' prefix it classifies on" ;;
esac

# ... and over a HAND-armed (durable) incumbent the idempotent contract stands:
# that coverage outlives the turn, so reporting it is not a lie.
rm -f "$lockd/autoarm"
out="$(AC_LOCK_PID=$$ AC_WATCH_SKIP=ska AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
case "$out" in
  'already running'*) : ;;
  *) fail "a durable (hand-armed) incumbent still answers an identical second arm idempotently" ;;
esac
hold_close own-hold "$ownpid"
rm -rf "$lockd"

# A SCOPED hand arm keeps `already running` too, and the bound is deliberate,
# not an oversight: the refusal's remedy is `--release`, which the SCOPED
# TARGETS guard REFUSES for a scoped pid ("only the fleet watcher is releasable
# via --release") - so a roomchief would be handed a command that exits 2. And a
# family already has the backstop the fleet lacks: the fleet watcher revalidates
# AC_WATCH_SKIP every poll and covers the family's panes directly once its
# beacon stays stale past the re-arm grace.
reset_state
scopedlock="$state/.watch-only-fam1.lock.d"
hold_open sco-hold; scopid=$HOLD_PID
mkdir -p "$scopedlock"; printf '%s\n' "$scopid" >"$scopedlock/pid"
: >"$state/.watcher-config-only-fam1"
: >"$scopedlock/autoarm"
out="$(AC_SCOPE=fam1 AC_WATCH_ONLY=fam1 AC_POLL=1 AC_HEARTBEAT=1 bash "$BIN/ac-watch.sh" 2>/dev/null)"
case "$out" in
  'already running'*) : ;;
  *) fail "a SCOPED hand arm must stay idempotent - --release is fleet-only, so a refusal here names a remedy that refuses" ;;
esac
hold_close sco-hold "$scopid"
rm -rf "$scopedlock" "$state/.watcher-config-only-fam1"

# The WRITER half. The marker lives INSIDE the lock dir, so ac_lock_release's
# `rm -rf` retires it with the lock: it can never outlive the watcher it
# describes, and there is no second lifetime to leak.
reset_state
AC_AUTOARM=1 AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" \
  >/dev/null 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the hook-armed watcher never reached its poll wait"
assert_file "$state/.watch.lock.d/autoarm" "a hook arm records its boundedness in its own lock dir"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null || true
assert_no_file "$state/.watch.lock.d" "... and the marker dies with the lock"

reset_state
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=300 bash "$BIN/ac-watch.sh" >/dev/null 2>/dev/null &
wpid=$!
in_poll_wait "$wpid" "$state/.last-watcher-beat" >/dev/null \
  || fail "the hand-armed watcher never reached its poll wait"
assert_no_file "$state/.watch.lock.d/autoarm" "a hand arm records nothing: its coverage is not budget-bounded"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null || true
reset_state

# --- (3) AC_WATCH_SKIP home guard: a skip naming a family absent from THIS home
# is refused loudly at arm (foreign-family). Runs for --once too.
reset_state
rc=0; out="$(AC_WATCH_SKIP=ghostfam bash "$BIN/ac-watch.sh" --once 2>&1)" || rc=$?
assert_eq "$rc" "2" "a foreign AC_WATCH_SKIP family refuses to arm"
assert_contains "$out" "refused" "the refusal says so"
assert_contains "$out" "ghostfam" "... naming the offending entry"
mkdir -p "$AC_HOME/data/realfam"
rc=0; out="$(AC_WATCH_SKIP=realfam,ghostfam bash "$BIN/ac-watch.sh" --once 2>&1)" || rc=$?
assert_eq "$rc" "2" "a foreign entry among valid ones still refuses"
assert_contains "$out" "ghostfam" "... naming the foreign entry"
out="$(AC_WATCH_SKIP=realfam bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a valid skip of a real family arms and runs"

# --- (4) idle-chief-deaf resurrection: an armed watcher STANDS ITS BEACON DOWN
# on exit, so a just-exited heartbeat can no longer leave a deceptively-fresh
# beacon that lets an idle chief park deaf. The turn-end guard then blocks the
# post-exit turn until the watcher is re-armed.
reset_state
out="$(AC_LOCK_PID=$$ AC_POLL=1 AC_HEARTBEAT=2 bash "$BIN/ac-watch.sh" 2>/dev/null)"
assert_contains "$out" "heartbeat" "the armed watcher heartbeat-exited"
assert_eq "$(cat "$state/.last-watcher-beat")" "0" "an exited watcher stands its beacon down (was: left fresh)"
printf 'kind=ship\n' >"$state/t-live.meta"              # crew now in flight, no watcher
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "the guard blocks the post-exit turn until the watcher re-arms"
reset_state

# --- landing-receipt reminder (PART 2b) ---------------------------------------
# Under mirror=chief/on, a NEW backlog Done line whose family lacks a landing-
# receipt stamp means a done-report may be unposted. The guard reminds ONCE
# (exit 2) at an otherwise-clean turn end - so it never masks a wake/coverage
# block - and records every current Done id as seen so the same line never
# re-fires. Fail-safe (missing deps -> silent), and fleet-scope only (the
# backlog is the crewchief's; a roomchief never edits it).
rm -f "$state/.landing-seen" "$state/.landing-receipt-stamp"
printf 'chief\n' >"$AC_HOME/config/remote-mirror"
lrbacklog="$AC_HOME/records/backlog.md"

# First run SEEDS the baseline silently: nothing is "new" before a baseline.
cat >"$lrbacklog" <<'EOF'
## Done
- [x] old1 - shipped a thing - local main (merged 2026-07-18)
EOF
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "first run seeds the baseline silently"
assert_file "$state/.landing-seen" "the seen-set baseline is recorded"

# A NEW Done line whose family has NO stamp -> block once with the reminder.
printf -- '- [x] greet2 - greeting shipped - local main (merged 2026-07-19)\n' >>"$lrbacklog"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>"$TMP/lr.err" || rc=$?
assert_eq "$rc" "2" "a new unstamped Done family blocks the turn"
assert_contains "$(cat "$TMP/lr.err")" "greet2" "the reminder names the owed family"
assert_contains "$(cat "$TMP/lr.err")" "done-stamp" "the reminder points at the done-stamp verb"

# It fires ONCE: the same Done line is now seen -> silent.
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "the same Done line never re-fires (recorded as seen)"

# A new Done line whose family IS stamped -> silent (staged: audit-ship -> audit).
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real audit-ship task always has one,
# since ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/audit/ship"
"$BIN/ac-remote.sh" done-stamp audit >/dev/null
printf -- '- [x] audit-ship - audit delivered - local main (merged 2026-07-19)\n' >>"$lrbacklog"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "a stamped family does not remind"

# mirror=off -> the check is inert even with a fresh unstamped Done line.
printf 'off\n' >"$AC_HOME/config/remote-mirror"
printf -- '- [x] offtask - no slack owed - local main (merged 2026-07-19)\n' >>"$lrbacklog"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "mirror=off owes no done-report -> silent"

# Fail-safe: a missing backlog is nothing-new, never a false-block.
printf 'chief\n' >"$AC_HOME/config/remote-mirror"
rm -f "$lrbacklog"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "a missing backlog stays silent (fail-safe)"

# A roomchief (scoped) never runs the check - the backlog is the crewchief's.
rm -f "$state/.landing-seen"
cat >"$lrbacklog" <<'EOF'
## Done
- [x] famX-ship - scoped landing - local main (merged 2026-07-19)
EOF
printf '{}' | AC_SCOPE=famX "$BIN/ac-turnend-guard.sh" \
  || fail "a scoped roomchief does not run the landing-receipt check"
assert_no_file "$state/.landing-seen" "a scoped session never writes the fleet seen-set"

rm -f "$AC_HOME/config/remote-mirror" "$lrbacklog" \
  "$state/.landing-seen" "$state/.landing-receipt-stamp"
reset_state

# --- HANDBACK block -----------------------------------------------------------
# A room whose hand-back is neither demoted nor closed blocks the fleet turn
# end: a STATE check, so it catches the failure whatever the cause (a lost or
# ignored wake, a drain consumed unread). Persistent, not fire-once; fleet
# only (a roomchief cannot clear its own hand-back); and it never masks the
# wake/coverage predicates ahead of it.
hbroom="$AC_HOME/data/hbfam/room.md"
mkdir -p "$(dirname "$hbroom")"
printf '# Room: hbfam\n\n- [%s] hbfam-chief> HANDBACK: landed, please demote and close\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$hbroom"
# A second room, globbed AFTER the one in handback, with no hand-back at all:
# the whole room set is read in ONE awk pass, so a per-file state that failed to
# reset would name this quiet room too.
mkdir -p "$AC_HOME/data/hbzquiet"
printf '# Room: hbzquiet\n\n- [%s] crewchief> spawned hbzquiet\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/data/hbzquiet/room.md"

rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>"$TMP/hb.err" || rc=$?
assert_eq "$rc" "2" "a room in HANDBACK blocks the idle-fleet turn end"
assert_contains "$(cat "$TMP/hb.err")" "hbfam" "the refusal names the waiting family"
case "$(cat "$TMP/hb.err")" in *hbzquiet*) fail "a quiet room must never be named in the refusal" ;; esac
assert_contains "$(cat "$TMP/hb.err")" "ac-teardown.sh" "... and the demote command"
assert_contains "$(cat "$TMP/hb.err")" "ac-room.sh close" "... and the close command"
assert_contains "$(cat "$TMP/hb.err")" "HANDBACK-REFUSED" "... and the refusal exit, so a refusing chief is not steered toward the other two"

# PERSISTENT: an unheeded block fires again on the next turn end.
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "the HANDBACK block is not fire-once"

# It fires on the in-flight path too (crew alive + fresh beacon = clean).
printf 'kind=ship\n' >"$state/hb-live.meta"
date +%s >"$state/.last-watcher-beat"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "the HANDBACK block also fires past the in-flight coverage path"

# It never masks the queued-wake predicate judged ahead of it.
mkdir -p "$state/.wake-spool"
printf '9\treport\thb-live\tdone: x\n' >"$state/.wake-spool/1.1.000000"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>"$TMP/hb-mask.err" || rc=$?
assert_eq "$rc" "2" "a queued wake still blocks"
assert_contains "$(cat "$TMP/hb-mask.err")" "queued wakes" "the queued-wake reason wins - HANDBACK masks nothing"
rm -rf "$state/.wake-spool"; rm -f "$state/hb-live.meta"

# A SCOPED session is never blocked by it: a roomchief that just posted its own
# hand-back cannot demote itself, so this would wedge that very turn forever.
printf '{}' | AC_SCOPE=hbfam "$BIN/ac-turnend-guard.sh" \
  || fail "a scoped roomchief is never blocked by its own hand-back"

# HANDBACK-REFUSED: reproduces tonight's incident - the crewchief refused a
# hand-back (mis-recorded authority, three remedies required) and the OLD
# guard then demanded demote+close for an hour, the two exits that were both
# wrong: accepting work already rejected, or destroying the chief mid-remedy.
# A live roomchief meta stands in for "the chief is still alive"; if the old
# demote-or-close message were followed it would be torn down (meta gone) and
# the room would carry a DEMOTED:/CLOSED: entry neither of which may happen.
printf 'kind=roomchief\n' >"$state/hbfam-chief.meta"
printf -- '- [%s] hbfam-chief> HANDBACK-REFUSED: mis-recorded authority, three remedies required\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$hbroom"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "HANDBACK-REFUSED clears the block with no demote and no close"
case "$(cat "$hbroom")" in
  *DEMOTED:*|*CLOSED:*) fail "a refusal must never be recorded as a demote or a close" ;;
esac
assert_file "$state/hbfam-chief.meta" "the roomchief's own state is untouched - refusing never destroys the chief"
rm -f "$state/hbfam-chief.meta"

# NO-OP: HANDBACK-REFUSED: with no prior HANDBACK: changes nothing.
noopfam="$AC_HOME/data/hbnoop/room.md"
mkdir -p "$(dirname "$noopfam")"
printf '# Room: hbnoop\n\n- [%s] crewchief> spawned hbnoop\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$noopfam"
printf -- '- [%s] crewchief> HANDBACK-REFUSED: nothing was ever handed back\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$noopfam"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "a HANDBACK-REFUSED with no prior HANDBACK is a no-op, not a block"
rm -rf "$AC_HOME/data/hbnoop"

# RE-HAND-BACK: a NEW HANDBACK: posted after a refusal blocks again - the
# refuse -> remedy -> re-hand-back cycle, never a permanent retirement.
printf -- '- [%s] hbfam-chief> HANDBACK: remedies done, please demote and close\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$hbroom"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "a re-hand-back after a refusal blocks the turn end again"

# DEMOTED: alone settles it - no captain, no close needed.
printf -- '- [%s] crewchief> DEMOTED: roomchief torn down\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$hbroom"
printf '{}' | "$BIN/ac-turnend-guard.sh" || fail "DEMOTED alone clears the HANDBACK block"
rm -rf "$AC_HOME/data/hbfam" "$AC_HOME/data/hbzquiet"
reset_state

# --- PARKED reminder ----------------------------------------------------------
# At a genuinely parked turn end - no crew in flight, captain inbox 0, no READY
# item - the guard PROMPTS the chief to /debrief and end the session. It is a
# reminder, never a law: one JSON systemMessage on stdout at exit 0, so it can
# never block, refuse or wedge a turn. SILENCE is the load-bearing direction:
# while a READY item exists the captain's standing order is to take the next
# one, so a reminder then would say stop at exactly the wrong moment.
pkbacklog="$AC_HOME/records/backlog.md"
: >"$pkbacklog"

out="$(printf '{}' | "$BIN/ac-turnend-guard.sh")" || fail "the parked reminder must never block"
assert_contains "$out" "systemMessage" "it rides the non-blocking JSON channel"
assert_contains "$out" "/debrief" "it names the verb the chief must run"
# Asserted AFTER the two above on purpose: `jq -e` on EMPTY input exits 0, so
# alone it could never catch a silent guard.
printf '%s' "$out" | jq -e . >/dev/null || fail "the reminder must be parseable JSON"

# A READY item, everything else identical -> SILENT.
cat >"$pkbacklog" <<'EOF'
## Queued
- [ ] pknext - a startable item (repo: demo)
EOF
assert_eq "$(printf '{}' | "$BIN/ac-turnend-guard.sh")" "" "a READY item keeps the reminder silent"

# An unanswered captain gate is the third condition. The room set is read in ONE
# batched pass, so a quiet room globbed AFTER the pending one (its DECIDED:
# settles its own room only) must not cancel that room's open GATE.
: >"$pkbacklog"
mkdir -p "$AC_HOME/data/pkfam" "$AC_HOME/data/pkzquiet"
printf '# Room: pkfam\n\n- [%s] crewchief> GATE: spec ready, approve?\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/data/pkfam/room.md"
printf '# Room: pkzquiet\n\n- [%s] crewchief> DECIDED: unrelated, already settled\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/data/pkzquiet/room.md"
assert_eq "$(printf '{}' | "$BIN/ac-turnend-guard.sh")" "" \
  "an unanswered captain gate keeps the reminder silent"
rm -rf "$AC_HOME/data/pkfam" "$AC_HOME/data/pkzquiet"

# Crew in flight is not parked, and a roomchief never ends the fleet session.
printf 'kind=ship\n' >"$state/pk-live.meta"
date +%s >"$state/.last-watcher-beat"
assert_eq "$(printf '{}' | "$BIN/ac-turnend-guard.sh")" "" "crew in flight is not parked"
rm -f "$state/pk-live.meta"
assert_eq "$(printf '{}' | AC_SCOPE=pkfam "$BIN/ac-turnend-guard.sh")" "" \
  "a scoped roomchief is never reminded to end the fleet session"
rm -f "$pkbacklog"
reset_state

# --- artifact wake channel (watch-artifact-wake) ------------------------------
# A stage's report.md appearing or ADVANCING is a completion in its own right,
# so the watcher must wake on it WITHOUT any pane cooperation - the channel the
# drain's report_completions could only report at a turn boundary. Dedup is by
# CONTENT hash, so a touched-but-identical report is not new work while a
# revision that rewrites it wakes again. The stage layout is resolved by
# ac_task_dir (the nested data/<family>/<stage>/ shape), never guessed.
mkdir -p "$AC_HOME/data/aw/plan"
printf '# brief\n' >"$AC_HOME/data/aw/plan/brief.md"
printf 'window=crew:aw-plan\nbackend=herdr\n' >"$state/aw-plan.meta"
seed_pane aw-plan pAW1 tAW1

# (1) report.md appears, pane says NOTHING -> actionable exit + durable wake.
printf '# plan report\n' >"$AC_HOME/data/aw/plan/report.md"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:aw-plan" "a report.md appearing wakes with no pane marker at all"
assert_contains "$(fleet_spool)" "$AC_HOME/data/aw/plan/report.md" \
  "the artifact wake is published durably, naming the report"

# (3) UNCHANGED artifact: a touched-but-identical report is not new work.
rm -rf "$state"/.wake-spool*
touch "$AC_HOME/data/aw/plan/report.md"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a touched-but-identical report does not re-wake (content hash, not mtime)"
assert_no_file "$state/.wake-spool" "no duplicate artifact wake"

# (4) A revision rewriting the report to DIFFERENT content wakes again.
printf '# plan report, revised\n' >"$AC_HOME/data/aw/plan/report.md"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:aw-plan" "a rewritten report wakes again"
assert_contains "$(fleet_spool)" "aw-plan" "the revision wake is published too"

# (2) A pane marker already seen (deduped, or consumed by another watcher) must
# NOT suppress the artifact wake - the placement hazard: the marker branch
# cannot `continue` past this channel. The pane is SETTLED first (one pass
# consumes the tail change), since a repeat marker on a pane that just MOVED is
# a wake in its own right - the marker re-wake channel below.
rm -rf "$state"/.wake-spool*
printf 'done: plan ready\n' >>"$(fake_pane_buf aw-plan)"
printf 'done: plan ready\n' >"$state/.seen-aw-plan"
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
printf '# plan report, revised twice\n' >"$AC_HOME/data/aw/plan/report.md"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:aw-plan" "an already-seen pane marker never suppresses the artifact wake"
assert_contains "$(fleet_spool)" "report.md" "the suppressed-marker pass still publishes the artifact wake"

# (5) BUSY-PANE DEBOUNCE (watch-artifact-wake-debounce). A real agent revising a
# long report writes it MANY times - every Edit is a new content hash - so the
# per-write wake cost the chief a drain, a re-arm and a turn PER EDIT, every one
# a no-op with the scout mid-sentence. A report only ever changes while an agent
# is WRITING it, so the pane the chief would be woken to read is by definition
# busy and already covered by the pane channel: while the tail matches
# AC_BUSY_RE the artifact wake is DEFERRED, and the first quiet poll wakes ONCE
# with the report as it finally stands.
rm -rf "$state"/.wake-spool*
anchored="$(cat "$state/.report-hash-aw-plan")"
printf 'esc to interrupt\n' >>"$(fake_pane_buf aw-plan)"
for n in 1 2 3 4 5; do
  printf 'revision round, edit %s\n' "$n" >>"$AC_HOME/data/aw/plan/report.md"
  assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
    "a busy pane's report write does not wake the chief (edit $n)"
done
assert_no_file "$state/.wake-spool" "five writes during one revision round publish NO wake"
assert_eq "$(cat "$state/.report-hash-aw-plan")" "$anchored" \
  "a suppressed pass never stamps the hash - the wake is deferred, never swallowed"

# (6) Item 4 (perf audit): the busy-pane predicate (AC_BUSY_RE against the
# captured $tail) must be computed ONCE per pane per poll and reused, not
# forked once per branch that needs it (it was forked 6x over the SAME tail).
# aw-plan is still busy ("esc to interrupt" from the block above). Count real
# `grep -E` calls carrying AC_BUSY_RE specifically - the pass also greps the
# same tail for AC_CAPTAIN_RE/AC_DECISION_RE, which must NOT be counted here.
busy_re_val="$(bash -c ". '$BIN/ac-lib.sh'; printf '%s' \"\$AC_BUSY_RE\"")"
grepcount="$TMP/busyre-calls"
mkdir -p "$TMP/grepstub"
realgrep="$(command -v grep)"
cat >"$TMP/grepstub/grep" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "$busy_re_val" ]; then
    printf '.' >>"$grepcount"
    break
  fi
done
exec "$realgrep" "\$@"
STUB
chmod +x "$TMP/grepstub/grep"
: >"$grepcount"
out="$(PATH="$TMP/grepstub:$PATH" bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "the busy pane still reads quiet with the shimmed grep on PATH"
assert_eq "$(wc -c <"$grepcount" | tr -d ' ')" "1" \
  "the AC_BUSY_RE predicate is forked exactly once per pane per poll, not once per branch that reads it"

# ... and the moment the round ends, ONE wake carrying the report as it now is.
printf 'done: plan ready\n' >"$(fake_pane_buf aw-plan)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:aw-plan" \
  "the first quiet poll after the round wakes"
assert_eq "$(fleet_spool | grep -c 'report.md' || true)" "1" \
  "five writes collapse to exactly ONE wake, not five"
assert_eq "$(cat "$state/.report-hash-aw-plan")" \
  "$(cksum <"$AC_HOME/data/aw/plan/report.md" | awk '{print $1}')" \
  "the one wake carries the FINAL report, not the first edit of the round"

# (6) The property this channel EXISTS for survives the debounce, and the busy
# tail is the ONLY thing that defers it: a scout that died or finished without
# printing any marker leaves a SILENT pane, so its report wakes the chief on the
# very next poll - no quiet period, no delay.
mkdir -p "$AC_HOME/data/aw2/plan"
printf '# brief\n' >"$AC_HOME/data/aw2/plan/brief.md"
printf 'window=crew:aw2-plan\nbackend=herdr\n' >"$state/aw2-plan.meta"
seed_pane aw2-plan pAW2 tAW2
printf 'esc to interrupt\n' >>"$(fake_pane_buf aw2-plan)"
rm -rf "$state"/.wake-spool*
printf '# report, still being written\n' >"$AC_HOME/data/aw2/plan/report.md"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "a report APPEARING under a busy pane is deferred like any other write"
: >"$(fake_pane_buf aw2-plan)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:aw2-plan" \
  "the same report on a SILENT pane wakes on the very first poll (the crashed-scout case)"
reset_state
rm -rf "$AC_HOME/data/aw" "$AC_HOME/data/aw2"

# --- marker re-wake channel (watch-marker-rewake) -----------------------------
# A pane that re-announces the SAME marker AFTER doing new work is new news:
# that is the shape of every gate loop past round 1, where the crewmate revises
# and re-prints a byte-identical `done:`. The discriminator is the pane-tail
# hash recorded AT THE LAST WAKE (state/.seen-hash-<id>): different means the
# pane moved since the chief was last told. A STATIC parked pane and a BUSY one
# still carrying an old marker in its tail stay silent.
mkdir -p "$AC_HOME/data/mrw"
printf 'window=crew:mrw\nbackend=herdr\n' >"$state/mrw.meta"
seed_pane mrw pMRW tMRW
printf 'done: report ready\n' >>"$(fake_pane_buf mrw)"

# The first announce is today's behavior, and it records the pane hash.
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:mrw" "the first marker wakes as always"
assert_eq "$(cat "$state/.seen-hash-mrw")" "$(cat "$state/.hash-mrw")" \
  "the pane-tail hash at the moment of the wake is recorded"

# (2) STATIC parked pane on the same marker: exactly ONE wake, however many
# polls run.
rm -rf "$state"/.wake-spool*
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "a static pane on an already-seen marker stays silent"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "... however many polls run"
assert_no_file "$state/.wake-spool" "a parked pane publishes no duplicate wake"

# (1) The gate loop: the crewmate does new work and re-prints the
# BYTE-IDENTICAL marker -> a SECOND wake.
printf 'revising the report\ndone: report ready\n' >>"$(fake_pane_buf mrw)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:mrw" "a repeat marker after new pane work wakes again"
assert_contains "$(fleet_spool)" "done: report ready" "the re-wake is published durably"
assert_eq "$(cat "$state/.seen-mrw")" "done: report ready" \
  ".seen-<id> semantics are untouched by the re-wake"

# (3) A BUSY pane still carrying the old marker in its tail: no extra wake,
# however much its tail moves.
rm -rf "$state"/.wake-spool*
printf 'esc to interrupt\n' >>"$(fake_pane_buf mrw)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "a busy pane still showing an old marker never re-wakes"
assert_no_file "$state/.wake-spool" "a working pane publishes no wake"
reset_state
rm -rf "$AC_HOME/data/mrw"

# --- ended-turn loud wake (watch-idle-loud-wake) ------------------------------
# A pane past AC_STALE with no marker is TWO situations, and one stale: signal
# for both is precisely what chiefs learn to discount: a pane that ENDED ITS
# TURN is waiting on the chief (the live case: a real decision raised as PROSE
# inside a long summary), while a pane merely quiet while WORKING is not news.
# The discriminator is the backend's own agent status, the same field the ask
# path reads - `idle` alone is an ended turn, everything else FAILS CLOSED to
# today's stale:.
# This is the CREWMATE case, and the SUPERVISING-CHIEF QUIET suppression (which
# now covers the ended arm too) cannot reach it: ac_chief_child_live's `*-chief`
# case gate returns false for every non-chief id, so a crewmate whose only
# channel to its chief IS this pane keeps waking loudly at the DEFAULT AC_STALE.
mkdir -p "$AC_HOME/data/elw"
printf 'window=crew:elw\nbackend=herdr\n' >"$state/elw.meta"
seed_pane elw pELW tELW
printf 'summarising the change\nshould I also drop the legacy path?\n' >>"$(fake_pane_buf elw)"
printf 'window=crew:elw2\nbackend=herdr\n' >"$state/elw2.meta"
seed_pane elw2 pELW2 tELW2
# Neither tail matches AC_BUSY_RE - that render heuristic is exactly what these
# two panes look identical under, which is why the agent status decides.
printf 'comparing the two candidate paths\n' >>"$(fake_pane_buf elw2)"
# Settle both panes: one pass records their tail hashes and change stamps, so
# the backdating below is the only thing that makes them stale.
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
now="$(date +%s)"
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-elw"
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-elw2"

# (1) An IDLE (ended-turn) pane wakes LOUDLY and is stamped BLOCKED.
printf 'idle\n' >"$FAKE_HERDR/panes/pELW.status"
# (2) A WORKING pane keeps today's soft stale: and nothing more. Both panes are
# stale in the SAME pass, so the two paths are compared under one clock.
printf 'working\n' >"$FAKE_HERDR/panes/pELW2.status"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ended:elw" "an ended-turn pane wakes loudly, not as stale:"
case "$out" in *stale:elw*) fail "an ended turn must never report as stale: - that is the signal chiefs discount" ;; esac
assert_contains "$(fleet_spool)" "ended its turn" "the loud wake is published durably"
assert_eq "$(cat "$FAKE_HERDR/panes/pELW.reported")" "blocked" \
  "the ended-turn pane is stamped BLOCKED in the herdr UI"
assert_file "$state/.captain-wait-elw" "stamp ownership recorded"
assert_contains "$(cat "$state/elw.status")" "ended its turn" "the ended turn is in the task's status log"
# The loud pass exits on its own wake, so drive the second pane's pass now.
rm -rf "$state"/.wake-spool*
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "stale:elw2" "a working pane still produces today's stale:"
case "$out" in *ended:elw2*) fail "a working pane must never produce the loud ended: wake" ;; esac
assert_no_file "$FAKE_HERDR/panes/pELW2.reported" "a merely-quiet working pane is never stamped"
assert_contains "$(fleet_spool)" "quiet for" "the stale wake payload is unchanged"
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status
rm -rf "$AC_HOME/data/elw"

# --- done-but-unreaped pane goes quiet (stale-signal-costs-a-hard-wake) -------
# A DONE-but-not-reaped pane keeps costing a HARD wake once its done: marker
# scrolls past the bounded 25-line tail: marker goes empty, the pane falls into
# the ENDED-TURN LOUD WAKE, and its only guard (.stale-<id>) is cleared by any
# cosmetic TUI redraw - so it re-fires forever. The report: already fired once
# and told the chief; a done-but-unreaped pane must go QUIET after it, the same
# once-only shape as the push-channel anchor. But a GENUINELY NEW completion
# must still wake, and a re-task must re-arm the ended-turn net.
mkdir -p "$AC_HOME/data/dbu"
printf 'window=crew:dbu\nbackend=herdr\n' >"$state/dbu.meta"
seed_pane dbu pDBU tDBU

# First sight: a fresh done: wakes and is recorded seen (invariant B, first half).
printf 'done: shipped the change\n' >>"$(fake_pane_buf dbu)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:dbu" "a fresh completion wakes on first sight"
assert_eq "$(cat "$state/.seen-dbu")" "done: shipped the change" "the completion is recorded seen"
rm -rf "$state"/.wake-spool*

# The marker scrolls out of the tail (a redraw leaves only later, marker-free
# scrollback). That redraw changes the tail hash, which clears .stale-<id> - the
# exact re-arm that made the loud ended: wake re-fire every quiet window.
: >"$(fake_pane_buf dbu)"
printf 'reviewing the final diff\nall the checks are green now\n' >>"$(fake_pane_buf dbu)"
bash "$BIN/ac-watch.sh" --once >/dev/null       # settle the redrawn tail hash
rm -rf "$state"/.wake-spool*
now="$(date +%s)"
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-dbu"
printf 'idle\n' >"$FAKE_HERDR/panes/pDBU.status"

# (A) The done-but-unreaped pane does NOT re-emit a hard wake; it anchors quiet.
out="$(bash "$BIN/ac-watch.sh" --once)"
case "$out" in *ended:dbu*) fail "invariant A: a done pane whose marker scrolled out must not re-fire ended:" ;; esac
assert_eq "$(fleet_spool)" "" "invariant A: no wake published for an already-reported completion"
assert_file "$state/.stale-dbu" "invariant A: the completion is anchored silently"
assert_no_file "$FAKE_HERDR/panes/pDBU.reported" "invariant A: no BLOCKED stamp for an already-reported completion"

# (B) A genuinely NEW completion printed back into the tail still wakes.
printf 'done: shipped the follow-up\n' >>"$(fake_pane_buf dbu)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:dbu" "invariant B: a genuinely new completion still wakes"
assert_contains "$(fleet_spool)" "done: shipped the follow-up" "invariant B: the new completion is published"
rm -rf "$state"/.wake-spool*

# (residual) A re-task busies the pane (its completion marker already scrolled
# out): the completion memory is forgotten, so a later PROSE-only ask still wakes
# the chief - done -> quiet, but re-task -> busy -> new work re-arms the net.
: >"$(fake_pane_buf dbu)"
printf 'esc to interrupt\n' >>"$(fake_pane_buf dbu)"
printf 'working\n' >"$FAKE_HERDR/panes/pDBU.status"
bash "$BIN/ac-watch.sh" --once >/dev/null        # observes BUSY -> forgets the completion
assert_no_file "$state/.seen-dbu" "residual: a re-task busies the pane and forgets the reported completion"
: >"$(fake_pane_buf dbu)"
printf 'summarising the change\nshould I also migrate the old rows?\n' >>"$(fake_pane_buf dbu)"
printf 'idle\n' >"$FAKE_HERDR/panes/pDBU.status"
bash "$BIN/ac-watch.sh" --once >/dev/null        # settle the prose-only tail hash
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-dbu"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "ended:dbu" \
  "residual: a re-tasked pane's prose-only ask still wakes the chief"
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status
rm -rf "$AC_HOME/data/dbu"

# --- supervising-chief quiet (watch-chief-child-quiet) ------------------------
# A wake IS the watcher's EXIT, so every stale: costs the chief the full
# hard-wake cycle (drain, peek, ack, re-arm). A <fam>-chief quiet BECAUSE its
# own crewmate is working buys nothing with that cycle - and the .stale-<id>
# dedup marker cannot settle it, since the chief's own turn output clears the
# marker and the identical non-news re-trips on the next quiet window. So the
# suppression is a LIVE question re-asked every poll (ac_chief_gate_parked's
# sibling), never a remembered marker.
mkdir -p "$AC_HOME/data/scq"
printf 'window=crew:scq-chief\nbackend=herdr\n' >"$state/scq-chief.meta"
seed_pane scq-chief pSCQC tSCQC
# A member by its meta fleet_scope: `-t1` is in no closed suffix rule, so the
# id names no family - the shape of an epic STORY pane, whose scope ac-spawn.sh
# records on disk (bin/ac-spawn.sh:1374). Membership is read from that, never
# from an id prefix.
printf 'window=crew:scq-t1\nbackend=herdr\nfleet_scope=scq\n' >"$state/scq-t1.meta"
seed_pane scq-t1 pSCQ1 tSCQ1
# The chief reads WORKING, not idle: the ended turn is the OTHER arm, and case
# (4) below pins that this suppression now guards it too.
printf 'working\n' >"$FAKE_HERDR/panes/pSCQC.status"
printf 'working\n' >"$FAKE_HERDR/panes/pSCQ1.status"
printf 'waiting on scq-t1\n' >>"$(fake_pane_buf scq-chief)"
printf 'editing the file\n' >>"$(fake_pane_buf scq-t1)"
# Settle both panes (one pass records their tail hashes and change stamps), then
# backdate ONLY the chief - the crewmate is working and must not be stale yet.
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
now="$(date +%s)"
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-chief"

# (1) A chief quiet because its crewmate is LIVE produces no wake at all - and
# consumes no dedup marker, which is what keeps (5) below able to wake.
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a chief supervising a live crewmate is not news"
case "$out" in *scq-chief*) fail "a supervising chief must not cost a hard wake" ;; esac
assert_no_file "$state/.wake-spool" "no wake is published for a supervising chief"
assert_no_file "$state/.stale-scq-chief" "the suppressed pass consumes no dedup marker"

# (2) THE RE-TRIP, closed: the chief takes a turn (its own output is exactly what
# removes .stale-<id>) and goes quiet again. Under a dedup-marker fix this is the
# pass that wakes the chief a second time with the same non-news.
printf 'still waiting on scq-t1\n' >>"$(fake_pane_buf scq-chief)"
bash "$BIN/ac-watch.sh" --once >/dev/null           # absorbs the chief's own turn
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "the same non-news never re-trips on the next quiet window"
assert_no_file "$state/.wake-spool" "... and publishes nothing the second time either"

# (3) CHIEF-SCOPED: the crewmate is not a chief and still goes stale exactly as
# before. Both panes are stale in the SAME pass, under one clock.
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-t1"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "stale:scq-t1" "a crewmate pane is untouched by the chief suppression"
case "$out" in *scq-chief*) fail "the supervising chief still must not wake" ;; esac

# (4) `ended:` IS SUPPRESSED TOO - a deliberate REVERSAL of what this case
# asserted before ("an ended turn is never suppressed by a live crewmate",
# watch-idle-loud-wake). The reversal closes a RULE CONFLICT: the roomchief
# charter injected into every chief prompt (bin/ac-spawn.sh:1021, AGENTS.md
# section 8) ORDERS the chief to keep AC_CAPTAIN_RE marker verbs out of its pane
# prose, while the only quiet path an ended turn had - COMPLETION ALREADY
# REPORTED - REQUIRES exactly such a marker in .seen-<id>. A chief that OBEYS
# its charter therefore never qualified, so it woke the crewchief forever.
# The CREWMATE net is untouched: ac_chief_child_live returns false for every
# non-chief id, so case (1) of the ended-turn block above still pins the loud
# wake at the DEFAULT threshold for the crewmate case the wake was built for.
rm -rf "$state"/.wake-spool*
printf 'idle\n' >"$FAKE_HERDR/panes/pSCQC.status"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "a chief that ENDED its turn while its crewmate is live is not news either"
case "$out" in *scq-chief*) fail "an ended-turn supervising chief must not cost a hard wake" ;; esac
assert_no_file "$state/.wake-spool" "no wake is published for an ended-turn supervising chief"
assert_no_file "$state/.stale-scq-chief" "the suppressed ended-turn pass consumes no dedup marker either"
assert_no_file "$FAKE_HERDR/panes/pSCQC.reported" "... and the pane is never stamped BLOCKED for it"

# (4b) THE LOOP, CLOSED - the defect itself, at the DEFAULT AC_STALE and never a
# raised one: the chief acks in PROSE (no AC_CAPTAIN_RE marker, hence no
# .seen-<id> and no COMPLETION-ALREADY-REPORTED anchor), and its own ack output
# is the pane change that clears .stale-<id>. Before the fix that re-armed the
# loud wake every quiet window, forever.
printf 'acked, still waiting on scq-t1\n' >>"$(fake_pane_buf scq-chief)"
bash "$BIN/ac-watch.sh" --once >/dev/null           # absorbs the chief's own ack
assert_no_file "$state/.seen-scq-chief" "a chief reporting in PROSE has no completion marker to anchor on"
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "the ended-turn wake never re-fires on the next quiet window"
assert_no_file "$state/.wake-spool" "... and publishes nothing the second time either"

# (5) FAILS TOWARD WAKING, on BOTH arms now: the last family task dies and the
# very next quiet window wakes the chief with nothing swallowed - the suppression
# held no marker back. The ENDED arm first (the chief pane is still idle).
rm -f "$FAKE_HERDR/panes/pSCQ1.buf" "$FAKE_HERDR/tabs/tSCQ1"
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ended:scq-chief" "the poll after the last family task dies wakes an ended-turn chief LOUDLY"
assert_contains "$(fleet_spool)" "ended its turn" "the loud wake is published durably"

# ... and the stale arm, unchanged: a merely-quiet chief with no live family.
rm -f "$FAKE_HERDR/panes/pSCQC.reported"            # release the ended-turn stamp
printf 'working\n' >"$FAKE_HERDR/panes/pSCQC.status"
printf 'scq-t1 handed back\n' >>"$(fake_pane_buf scq-chief)"
bash "$BIN/ac-watch.sh" --once >/dev/null           # absorbs the chief turn, reports gone:
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "stale:scq-chief" "the poll after the last family task dies wakes as always"
assert_contains "$(fleet_spool)" "quiet for" "the stale wake payload is unchanged"

# (6) MEMBERSHIP IS AUTHORITATIVE, NEVER AN ID PREFIX. An UNRELATED family whose
# id merely STARTS WITH this one is no more this chief's crew than no family at
# all. The open `<fam>-*` glob read a stranger's live pane as a family member,
# so the suppression held and the wake this arm exists to deliver was SWALLOWED -
# the same prefix collision that made a roomchief undemotable, failing in the
# OPPOSITE and worse direction: a blocked action announces itself, silence does
# not.
rm -rf "$state"/.wake-spool*
printf 'window=crew:scq-curate-automation\nbackend=herdr\n' >"$state/scq-curate-automation.meta"
seed_pane scq-curate-automation pSCQA tSCQA
printf 'working\n' >"$FAKE_HERDR/panes/pSCQA.status"
printf 'editing the file\n' >>"$(fake_pane_buf scq-curate-automation)"
printf 'still nothing back\n' >>"$(fake_pane_buf scq-chief)"
bash "$BIN/ac-watch.sh" --once >/dev/null           # absorbs both panes' turns
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-scq-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "stale:scq-chief" "a prefix-collision family is not this chief's crew"
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status
rm -rf "$AC_HOME/data/scq"

# --- the VERIFICATION-agent class (verify-meta-namespace) ---------------------
# A verification pane agent writes a state/<id>.meta so the watcher can
# supervise it, but it is NOT crew. The split this pins: EXCLUDED FROM
# ACCOUNTING (ac_chief_child_live), NEVER FROM SUPERVISION (the poll loop).

# (1) ACCOUNTING: a chief whose only family member is a VERIFIER is not
# supervising a crewmate - it is quiet with nobody working for it, so the
# stale: wake it needs must still fire.
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real vfy-review task always has one,
# since ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/vfy/review"
printf 'kind=roomchief\nwindow=crew:vfy-chief\nbackend=herdr\n' >"$state/vfy-chief.meta"
seed_pane vfy-chief pVFC tVFC
printf 'kind=verify-codereview\nwindow=crew:vfy-review\nbackend=herdr\n' >"$state/vfy-review.meta"
seed_pane vfy-review pVFR tVFR
printf 'working\n' >"$FAKE_HERDR/panes/pVFC.status"
printf 'working\n' >"$FAKE_HERDR/panes/pVFR.status"
printf 'waiting on the reviewer\n' >>"$(fake_pane_buf vfy-chief)"
printf 'reading the diff\n' >>"$(fake_pane_buf vfy-review)"
bash "$BIN/ac-watch.sh" --once >/dev/null          # settle both panes
rm -rf "$state"/.wake-spool*
now="$(date +%s)"
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-vfy-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "stale:vfy-chief" "a live VERIFIER is not a live family child"
# ... and the same pane under a crewmate kind DOES suppress it, so the skip is
# the class and not a broken predicate.
printf 'kind=ship\nwindow=crew:vfy-review\nbackend=herdr\n' >"$state/vfy-review.meta"
rm -f "$state/.stale-vfy-chief"
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( now - 1000 ))" >"$state/.change-vfy-chief"
out="$(bash "$BIN/ac-watch.sh" --once)"
case "$out" in *stale:vfy-chief*) fail "a live CREWMATE child must still suppress the chief's stale" ;; esac

# (2) SUPERVISION, never excluded: a verifier pane whose window vanished still
# produces gone: - the accounting split must never blind the watcher to it.
rm -f "$state/vfy-chief.meta" "$state/.pane-vfy-chief" "$state/.change-vfy-chief" \
  "$state/.stale-vfy-chief" "$state/.hash-vfy-chief"
rm -f "$FAKE_HERDR/panes/pVFC.buf" "$FAKE_HERDR/tabs/tVFC"
printf 'kind=verify-codereview\nwindow=crew:vfy-review\nbackend=herdr\n' >"$state/vfy-review.meta"
rm -f "$FAKE_HERDR/panes/pVFR.buf" "$FAKE_HERDR/tabs/tVFR"
rm -rf "$state"/.wake-spool*
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:vfy-review" "a verifier is still POLLED: its vanished window wakes the chief"
assert_contains "$(fleet_spool)" "gone	vfy-review" "the gone wake is published durably for a verifier too"
assert_contains "$(cat "$state/vfy-review.status")" "failed: window gone" \
  "ac_status_append still records a verifier's events"
reset_state
rm -f "$state"/*.status

# --- push channel (agent-done-push) -------------------------------------------
# An agent that announces its own completion (bin/ac-done.sh) must wake the
# chief NOW, not at the next poll tick: the record lands in this watcher's
# spool and the push kills the poll `sleep` child, so the top-of-cycle check
# runs at once and the watcher EXITS. The three properties that make that safe
# are pinned here: it is MEASURED (not at the tick), an already-present record
# never spins a fresh arm, and one completion announced on BOTH channels wakes
# the chief exactly once.

await_poll_wait() {
  # await_poll_wait - block until the armed watcher is demonstrably INSIDE its
  # poll wait, PROVEN by its `sleep` CHILD. poll_wait's backgrounded `sleep` is
  # the only one ac-watch.sh forks, so it is the discriminator - and ac-done.sh's
  # nudge picks the child to kill exactly this way. An UNFILTERED `pgrep -P` is
  # not that proof: check_fleet's own transient children (a pane capture, a
  # command substitution) satisfy it too, so it returns while the pane pass is
  # still running. That is what made the push+artifact case below flake 3/20
  # under tests/stress.sh - the test wrote its report.md into an in-flight pass,
  # the ARTIFACT channel saw it first, and the watcher exited `report:` before
  # the push it was supposed to wake on ever landed.
  local lpid
  for _ in $(seq 1 200); do
    lpid="$(cat "$state/.watch.lock.d/pid" 2>/dev/null || true)"
    if [ -n "$lpid" ] && [ -n "$(pgrep -P "$lpid" -x sleep 2>/dev/null || true)" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# (1) MEASUREMENT: a pushed record wakes the armed watcher AT ONCE, not at the
# poll tick and not at the heartbeat - so neither way of failing to wake can
# pass as success, and a regression fails the suite instead of hanging it.
# The FIXTURE owns the deadline (same remedy as (6b) at @dcb5ca3): assert the
# push woke the watcher AT ALL inside a bound we chose, never how many seconds
# it took. An elapsed-seconds budget cannot tell the property from a descheduled
# host, so it reds on a loaded box and names the wrong cause. The separation the
# bound needs is built here rather than inherited: a working build exits in
# milliseconds, and BOTH ways of not-waking are pushed far past the bound -
# push_poll for "waited for the tick", the heartbeat for "never woke at all".
push_poll=600
push_hb=600
push_bound=60
outf="$TMP/push-watch.out"
AC_LOCK_PID=$$ AC_POLL="$push_poll" AC_HEARTBEAT="$push_hb" bash "$BIN/ac-watch.sh" >"$outf" 2>/dev/null &
wpid=$!
await_poll_wait || fail "the watcher never armed into its poll wait"
env -u AC_HOME -u AC_SCOPE AC_FLEET_STATE="$state" "$BIN/ac-done.sh" pw1 'done: pushed' >/dev/null
if ! dead_within "$wpid" "$push_bound"; then
  # Same reaping duty as (6b): fail exits the file, so a live watcher and its
  # poll sleep would run on against a deleted $TMP.
  kill -9 "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  fail "the push must wake the chief at once: the watcher outlived it by ${push_bound}s of a ${push_poll}s poll"
fi
wait "$wpid" 2>/dev/null || true
assert_contains "$(cat "$outf")" "push:pw1" "a pushed record exits the watcher, naming the task"
# PUSH-ONLY: pw1 has no report.md, so the exit anchors NOTHING - the artifact
# channel must still wake on the first report this task ever writes.
assert_no_file "$state/.report-hash-pw1" \
  "a push with no report leaves the artifact channel unanchored"

# (2) RE-ARM SPIN: the record is still in the spool (the chief has not drained
# it), and a fresh arm must NOT exit on it instantly, forever - a record
# already present at arm is not news.
out="$(AC_LOCK_PID=$$ AC_POLL=1 AC_HEARTBEAT=3 bash "$BIN/ac-watch.sh" 2>/dev/null)"
assert_contains "$out" "heartbeat" "an undrained record present at arm never re-exits the watcher"
case "$out" in *push:*) fail "a re-arm must not spin on the record it armed with" ;; esac
reset_state

# (3) ONE COMPLETION, ONE WAKE. The pane carries the same completion, so the
# push's dedup stamp must absorb the poll that later reads it off the pane -
# including the TUI glyph the pane renders it behind, which the pushed marker
# text cannot carry.
mkdir -p "$AC_HOME/data/pd1"
printf 'window=crew:pd1\nbackend=herdr\n' >"$state/pd1.meta"
seed_pane pd1 pPD1 tPD1
env -u AC_HOME -u AC_SCOPE AC_FLEET_STATE="$state" "$BIN/ac-done.sh" pd1 'done: pushed and printed' >/dev/null
printf '⏺ done: pushed and printed\n' >>"$(fake_pane_buf pd1)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "the pane marker of an already-pushed completion wakes nobody twice"
assert_eq "$(fleet_spool | grep -c 'pushed and printed' || true)" "1" \
  "one completion leaves exactly one record, push and poll combined"
# PUSH ADOPT: the push cannot know the pane hash, so the first poll anchors the
# re-wake discriminator silently instead of treating its absence as movement.
assert_eq "$(cat "$state/.seen-hash-pd1")" "$(cat "$state/.hash-pd1")" \
  "the first poll after a push adopts the pane it found"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "... and stays silent however many polls run"

# The re-wake channel is only ANCHORED by the adopt, never disabled: a pane
# that does new work and re-prints the same marker still wakes.
rm -rf "$state"/.wake-spool*
printf 'revising\n⏺ done: pushed and printed\n' >>"$(fake_pane_buf pd1)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:pd1" \
  "a pushed marker re-printed after new pane work still wakes"
reset_state
rm -rf "$AC_HOME/data/pd1"

# (4) STALE-READ INTERLEAVING. The dedup stamp read at the TOP of the marker
# branch is stale by the time that branch publishes: between the two sit the
# status append and a BACKEND call costing tens of milliseconds, and a push
# landing in THAT window used to make the watcher publish against a read it had
# already invalidated - two records for one completion. The `pane report-agent`
# hook runs the push exactly there, so this pins the interleaving with no
# sleeps and no racing processes. (An ARMED watcher would then exit `push:` at
# its next loop top; `--once` exits quiet and its caller drains - either way,
# ONE record.)
mkdir -p "$AC_HOME/data/pd2"
printf 'window=crew:pd2\nbackend=herdr\n' >"$state/pd2.meta"
seed_pane pd2 pPD2 tPD2
# Indented exactly as a real capture renders it - the pushed text is the bare
# line, so the stamp the push leaves is a SUFFIX of what the pane shows.
printf '   needs-decision: keep or drop the cache?\n' >>"$(fake_pane_buf pd2)"
cat >"$FAKE_HERDR/.hook-report-agent" <<EOF
#!/usr/bin/env bash
env -u AC_HOME -u AC_SCOPE AC_FLEET_STATE="$state" \
  "$BIN/ac-done.sh" pd2 'needs-decision: keep or drop the cache?' >/dev/null
EOF
chmod +x "$FAKE_HERDR/.hook-report-agent"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_eq "$(fleet_spool | grep -c 'keep or drop the cache' || true)" "1" \
  "a push landing inside the marker branch still yields ONE record"
assert_contains "$out" "check:quiet" "the watcher does not also wake on the pane it was beaten to"
assert_eq "$(cat "$state/.seen-pd2")" "needs-decision: keep or drop the cache?" \
  "the push's stamp stands - the watcher never clobbers it back after losing the race"
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status "$FAKE_HERDR/.hook-report-agent.used"
rm -rf "$AC_HOME/data/pd2"

# (5) PUSH + ARTIFACT, ONE WAKE. A scout that finishes properly does BOTH: it
# writes its stage report.md and it pushes. The push is the wake, so the report
# that came with it is the same completion - but the artifact channel dedups on
# a THIRD stamp (.report-hash-<id>) that ac-done.sh cannot write (a crewmate has
# no AC_HOME), so the chief's very next poll used to publish a SECOND record for
# it. The push EXIT anchors that stamp instead. The interleaving is the live
# one and is pinned without sleeps: the watcher is armed and demonstrably inside
# its poll wait before the report and the push land, so the exit is the push's.
mkdir -p "$AC_HOME/data/pa/plan"
printf '# brief\n' >"$AC_HOME/data/pa/plan/brief.md"
printf 'window=crew:pa-plan\nbackend=herdr\n' >"$state/pa-plan.meta"
seed_pane pa-plan pPA1 tPA1
outf="$TMP/push-artifact.out"
AC_LOCK_PID=$$ AC_POLL=30 AC_HEARTBEAT=25 bash "$BIN/ac-watch.sh" >"$outf" 2>/dev/null &
wpid=$!
await_poll_wait || fail "the watcher never armed into its poll wait"
printf '# plan report\n' >"$AC_HOME/data/pa/plan/report.md"
env -u AC_HOME -u AC_SCOPE AC_FLEET_STATE="$state" "$BIN/ac-done.sh" pa-plan 'done: plan ready' >/dev/null
wait "$wpid" 2>/dev/null || true
assert_contains "$(cat "$outf")" "push:pa-plan" "the push is the wake for a completion that also wrote its report"
assert_eq "$(cat "$state/.report-hash-pa-plan")" \
  "$(cksum <"$AC_HOME/data/pa/plan/report.md" | awk '{print $1}')" \
  "the push exit anchors the artifact hash to the report it was pushed with"
# The chief drains and re-arms: the artifact channel must NOT re-announce the
# completion the chief was just handed.
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "the poll after a push does not wake a second time off the same report"
assert_eq "$(fleet_spool | grep -c 'pa-plan' || true)" "1" \
  "one completion, pushed and reported, leaves exactly ONE record"

# The artifact channel is only ANCHORED by the adopt, never disabled: a report
# REWRITTEN after the push is new news and wakes as always.
rm -rf "$state"/.wake-spool*
printf '# plan report, revised\n' >"$AC_HOME/data/pa/plan/report.md"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:pa-plan" \
  "a report rewritten after the push still wakes"
reset_state
rm -rf "$AC_HOME/data/pa"

# === STALE-STAMP SUPERSESSION ================================================
# A captain-wait marker parks a pane and the .status line it writes is DURABLE:
# every fleet view renders the NEWEST line of that file (ac-fleets.sh,
# ac-crew-state.sh), so a crewmate that is demonstrably WORKING kept reporting
# `blocked` until a human steered it. Demonstrated later progress supersedes an
# unanswered marker.
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status
. "$BIN/ac-lib.sh"                          # AC_CAPTAIN_RE, to prove the new line is not one
printf 'window=crew:ss1\nbackend=herdr\n' >"$state/ss1.meta"
seed_pane ss1 pSS1 tSS1
printf 'needs-decision: keep or drop the cache?\n' >>"$(fake_pane_buf ss1)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:ss1" "the marker wakes and parks the pane"
assert_file "$state/.captain-wait-ss1" "the pane is stamped"

# The EVIDENCE of later progress: BUSY while the fleet's own wait stamp still
# stands - disk + tail, both already in hand each poll.
rm -rf "$state"/.wake-spool*
printf 'esc to interrupt\n' >>"$(fake_pane_buf ss1)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "check:quiet" \
  "supersession tells the chief nothing new - it never wakes"
assert_no_file "$state/.captain-wait-ss1" "the herdr wait stamp is released"
assert_no_file "$FAKE_HERDR/panes/pSS1.reported" "... and the pane's reported state with it"
sup_line="$(tail -n1 "$state/ss1.status" | cut -d' ' -f2-)"   # what both renderers show
assert_contains "$sup_line" "superseded" "the newest status line supersedes the marker"
case "$sup_line" in "needs-decision:"*) \
  fail "a working pane must not still report its marker as its current state" ;; esac
if grep -qE "$AC_CAPTAIN_RE" <<<"$sup_line"; then
  fail "the superseding line must never itself match AC_CAPTAIN_RE"
fi

# RE-STAMP OSCILLATION: the Reconcile branch re-stamps an already-seen
# captain-wait marker still sitting in the tail the moment the pane reads
# non-busy - without the durable per-marker record it would re-park the pane
# supersession had just freed.
printf 'needs-decision: keep or drop the cache?\nthe run carries on\n' >"$(fake_pane_buf ss1)"
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_no_file "$state/.captain-wait-ss1" \
  "a superseded marker must never re-park the pane it just freed"

# The record is per-MARKER, never a permanent immunity: a NEW captain-wait
# marker parks the pane again...
rm -rf "$state"/.wake-spool*
printf 'needs-decision: which branch do I target?\n' >>"$(fake_pane_buf ss1)"
assert_contains "$(bash "$BIN/ac-watch.sh" --once)" "report:ss1" "a new marker still wakes"
assert_file "$state/.captain-wait-ss1" "a new captain-wait marker re-parks a superseded pane"
# ...and the superseded marker itself becomes news again the moment the pane
# RE-ANNOUNCES it: the record must die with it, or the answering steer's clear
# could never be reconciled back to a stamp.
rm -rf "$state"/.wake-spool*
printf 'needs-decision: keep or drop the cache?\n' >>"$(fake_pane_buf ss1)"
bash "$BIN/ac-watch.sh" --once >/dev/null
"$BIN/ac-send.sh" ss1 'keep the cache' >/dev/null   # the answering steer clears the stamp
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_file "$state/.captain-wait-ss1" \
  "a re-announced marker reconciles again - its supersession record died with it"

# FAIL TOWARD KEEPING THE STAMP: a genuinely parked pane, and a pane with no
# evidence either way, keep both marker and stamp - a false "superseded" hides a
# real captain-wait, which is the worse error.
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status
printf 'window=crew:ss2\nbackend=herdr\n' >"$state/ss2.meta"
seed_pane ss2 pSS2 tSS2
printf 'blocked: waiting on the captain\n' >>"$(fake_pane_buf ss2)"
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_file "$state/.captain-wait-ss2" "a parked pane is stamped"
rm -rf "$state"/.wake-spool*
printf 'nothing new here\n' >>"$(fake_pane_buf ss2)"
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_file "$state/.captain-wait-ss2" "a quiet pane keeps its stamp - no evidence of progress"
assert_contains "$(tail -n1 "$state/ss2.status")" "blocked: waiting on the captain" \
  "... and its marker stays its current state"
reset_state
rm -f "$state"/.captain-wait-* "$state"/*.status

# --- an UNREADABLE backend is never a death record ------------------------------
# Contract: ac-backend.sh WINDOW LIVENESS. LIVED 2026-07-25: a herdr client/server
# protocol mismatch failed every socket call, and this branch stamped BOTH live
# agents of a family `failed: window gone` within 50s - one of them went on to
# commit its fix through the same blind transport. The backend being unreadable
# is no evidence about the pane, so it may produce no failure state.
printf 'window=crew:ub1\nbackend=herdr\n' >"$state/ub1.meta"
seed_pane ub1 pUB1 tUB1
bash "$BIN/ac-watch.sh" --once >/dev/null    # settle the pane
rm -rf "$state"/.wake-spool*
rm -f "$state"/*.status

# DISPUTED: whether the backend can answer. HELD-CONSTANT: the pane's own files
# (handle, tab, buffer) are untouched - the pane is demonstrably still there.
touch "$FAKE_HERDR/.unreachable"
out="$(bash "$BIN/ac-watch.sh" --once)"
rm -f "$FAKE_HERDR/.unreachable"
assert_contains "$out" "unobservable:ub1" "an unreadable backend wakes the chief as UNOBSERVABLE"
case "$out" in *gone:ub1*) fail "an unreadable backend must never be reported as a gone pane" ;; esac
assert_contains "$(cat "$state/ub1.status")" "unobservable:" "the status records what actually happened"
case "$(cat "$state/ub1.status")" in *"failed:"*) \
  fail "THE REGRESSION: an unreadable backend must write no death record" ;; esac
assert_contains "$(fleet_spool)" "unobservable	ub1" "the wake is published durably like every other"
assert_no_file "$state/.gone-ub1" "the gone dedup marker is untouched - a real death is still news"

# Once-only while the outage lasts: the watcher keeps polling and stays quiet.
rm -rf "$state"/.wake-spool*
touch "$FAKE_HERDR/.unreachable"
out="$(bash "$BIN/ac-watch.sh" --once)"
rm -f "$FAKE_HERDR/.unreachable"
case "$out" in *unobservable:ub1*) fail "a standing outage must not re-wake every poll" ;; esac
assert_eq "$(grep -c 'unobservable:' "$state/ub1.status")" "1" "one outage, one status line"

# Recovery needs no re-arm, and re-arms the wake for the NEXT outage.
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_no_file "$state/.unobservable-ub1" "a readable backend clears the outage marker"
rm -rf "$state"/.wake-spool*
touch "$FAKE_HERDR/.unreachable"
out="$(bash "$BIN/ac-watch.sh" --once)"
rm -f "$FAKE_HERDR/.unreachable"
assert_contains "$out" "unobservable:ub1" "a LATER outage wakes the chief again"

# THE OTHER HALF: a real death is still detected, and still says so.
rm -rf "$state"/.wake-spool*
rm -f "$state"/*.status "$state/.unobservable-ub1"
rm -f "$FAKE_HERDR/panes/pUB1.buf" "$FAKE_HERDR/tabs/tUB1"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:ub1" "a reachable backend that does not know the pane is still GONE"
assert_contains "$(cat "$state/ub1.status")" "failed: window gone" "a real death still records the failure"
assert_contains "$(fleet_spool)" "gone	ub1" "the gone wake is unchanged"

# F14 (repo-deep-review): `.gone-<id>` must clear on the next ALIVE pass,
# symmetric with `.unobservable-<id>` above - crewdeputy `--recover`
# deliberately skips teardown (the only OTHER remover of `.gone-<id>`), so a
# recovered crewdeputy's SECOND death must still wake, not go silent forever.
rm -rf "$state"/.wake-spool*
seed_pane ub1 pUB1 tUB1              # "recovery": the window is alive again
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_no_file "$state/.gone-ub1" "a recovered (alive) pane clears the gone dedup marker"
rm -rf "$state"/.wake-spool*
rm -f "$FAKE_HERDR/panes/pUB1.buf" "$FAKE_HERDR/tabs/tUB1"    # the second death
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:ub1" "a SECOND death after recovery wakes again"
assert_contains "$(fleet_spool)" "gone	ub1" "the second gone wake is published durably"

reset_state
rm -f "$state"/*.status

# --- queue_wake never notifies - the notify moved to the blocked-by-captain
# --- edge in bin/ac-room.sh's cmd_post -------------------------------------
# CAPTAIN 2026-07-28 first cut this to ask/gone/unobservable+handback (a
# notification on every durable wake was noise on a busy fleet). CAPTAIN
# 2026-07-30 ("k co gi thi dung co chay ac-notify" / "block boi captain")
# went further: ask/gone/unobservable are chief-owned events too - the chief
# answers or steers them, none of them is captain-approval - so queue_wake no
# longer calls ac-notify.sh for ANY kind. The one thing that genuinely waits
# on the captain (a room GATE:/ASK:) now notifies from bin/ac-room.sh's
# cmd_post instead (tests/ac-room.test.sh), on ac_room_pending's edge into
# >0. The durable wake record and the printed exit reason are UNCHANGED for
# every kind here (the WAKE PUBLISH PATH IS UNTOUCHED) - asserted per kind
# below alongside the notify assert, never just the removal in isolation.
notify_log="$TMP/notify.log"
notify_hook="$TMP/notify-hook.sh"
cat >"$notify_hook" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$AC_NOTIFY_TITLE" >>"$notify_log"
EOF
chmod +x "$notify_hook"
printf 'command:%s\n' "$notify_hook" >"$AC_HOME/config/wedge-alarm"
: >"$notify_log"
notified() { grep -c "^crew $1\$" "$notify_log" 2>/dev/null || true; }

# report (the ordinary marker path).
printf 'window=crew:nk-rep\nbackend=herdr\n' >"$state/nk-rep.meta"
seed_pane nk-rep pNKR tNKR
printf 'done: shipped\n' >>"$(fake_pane_buf nk-rep)"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "report:nk-rep" "report still wakes"
assert_contains "$(fleet_spool)" "done: shipped" "report wake still publishes durably"
assert_eq "$(notified report)" "0" "report no longer notifies"
rm -rf "$state"/.wake-spool*

# gone.
rm -f "$state"/*.meta
printf 'window=crew:nk-gone\nbackend=herdr\n' >"$state/nk-gone.meta"
seed_pane nk-gone pNKG tNKG
rm -f "$FAKE_HERDR/panes/pNKG.buf" "$FAKE_HERDR/tabs/tNKG"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:nk-gone" "gone still wakes"
assert_contains "$(fleet_spool)" "gone	nk-gone" "gone wake still publishes durably"
assert_eq "$(notified gone)" "0" "gone no longer notifies (chief-owned, not blocked-by-captain)"
rm -rf "$state"/.wake-spool*

# ask.
rm -f "$state"/*.meta
printf 'window=crew:nk-ask\nbackend=herdr\n' >"$state/nk-ask.meta"
seed_pane nk-ask pNKA tNKA
printf 'blocked\n' >"$FAKE_HERDR/panes/pNKA.status"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ask:nk-ask" "ask still wakes"
assert_contains "$(fleet_spool)" "ask	nk-ask" "ask wake still publishes durably"
assert_eq "$(notified ask)" "0" "ask no longer notifies (chief-owned, not blocked-by-captain)"
rm -rf "$state"/.wake-spool*
rm -f "$FAKE_HERDR/panes/pNKA.status"

# stale (working, quiet past AC_STALE).
rm -f "$state"/*.meta
mkdir -p "$AC_HOME/data/nk-stale"
printf 'window=crew:nk-stale\nbackend=herdr\n' >"$state/nk-stale.meta"
seed_pane nk-stale pNKS tNKS
printf 'comparing candidate paths\n' >>"$(fake_pane_buf nk-stale)"
bash "$BIN/ac-watch.sh" --once >/dev/null   # settle the tail hash/change stamp
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( $(date +%s) - 1000 ))" >"$state/.change-nk-stale"
printf 'working\n' >"$FAKE_HERDR/panes/pNKS.status"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "stale:nk-stale" "stale still wakes"
assert_contains "$(fleet_spool)" "quiet for" "stale wake still publishes durably"
assert_eq "$(notified stale)" "0" "stale no longer notifies"
rm -rf "$state"/.wake-spool*

# ended (idle, quiet past AC_STALE).
rm -f "$state"/*.meta
mkdir -p "$AC_HOME/data/nk-ended"
printf 'window=crew:nk-ended\nbackend=herdr\n' >"$state/nk-ended.meta"
seed_pane nk-ended pNKE tNKE
printf 'summarising the change\n' >>"$(fake_pane_buf nk-ended)"
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
printf '%s\n' "$(( $(date +%s) - 1000 ))" >"$state/.change-nk-ended"
printf 'idle\n' >"$FAKE_HERDR/panes/pNKE.status"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ended:nk-ended" "ended still wakes"
assert_contains "$(fleet_spool)" "ended its turn" "ended wake still publishes durably"
assert_eq "$(notified ended)" "0" "ended no longer notifies"
rm -rf "$state"/.wake-spool*

# unobservable - the backend-unreadable state. Captain 2026-07-28 had added
# it to the (now-removed) keep-list; 2026-07-30 removes it along with
# ask/gone - it is chief-owned (the chief checks the backend), not
# captain-approval.
rm -f "$state"/*.meta
printf 'window=crew:nk-unobs\nbackend=herdr\n' >"$state/nk-unobs.meta"
seed_pane nk-unobs pNKU tNKU
bash "$BIN/ac-watch.sh" --once >/dev/null   # settle the pane
rm -rf "$state"/.wake-spool*
rm -f "$state"/*.status
touch "$FAKE_HERDR/.unreachable"
out="$(bash "$BIN/ac-watch.sh" --once)"
rm -f "$FAKE_HERDR/.unreachable"
assert_contains "$out" "unobservable:nk-unobs" "unobservable still wakes"
assert_contains "$(fleet_spool)" "unobservable	nk-unobs" "unobservable wake still publishes durably"
assert_eq "$(notified unobservable)" "0" "unobservable no longer notifies (chief-owned, not blocked-by-captain)"
rm -rf "$state"/.wake-spool*

reset_state
rm -f "$state"/*.status "$notify_log" "$notify_hook"
printf 'off\n' >"$AC_HOME/config/wedge-alarm"

# --- ask-alert resume line (ask-alert-never-clears-its-status-line) ----------
# The else branch used to do exactly one thing - `rm -f` the .ask-<id> latch -
# and appended NOTHING on the way back out, so a resumed pane kept rendering
# its stale needs-decision: line forever (bin/ac-fleets.sh renders tail -n1 of
# state/<id>.status). The measured incident: three panes all showed the
# IDENTICAL stale line while carrying three DIFFERENT live states - blocked
# (true), idle (turn complete, line lied), working (agent resumed, line
# lied). The fix must render three DIFFERENT lines - a single generic
# "no longer blocked" append would still fail the bar, because the idle pane
# and the working pane would then read identically.

# Pane A stays blocked: the needs-decision line is unchanged and true.
rm -f "$state"/*.meta
mkdir -p "$AC_HOME/data/ral-b"
printf 'window=crew:ral-b\nbackend=herdr\n' >"$state/ral-b.meta"
seed_pane ral-b pRALB tRALB
printf 'blocked\n' >"$FAKE_HERDR/panes/pRALB.status"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ask:ral-b" "a still-blocked pane still wakes ask:"
assert_contains "$(cat "$state/ral-b.status")" "needs-decision: pane blocked on an interactive prompt" \
  "a still-blocked pane keeps the needs-decision line"
assert_file "$state/.ask-ral-b" "the latch stays set while the pane stays blocked"
rm -rf "$state"/.wake-spool*

# Pane B was blocked, then its turn ended (idle): a DIFFERENT line from A.
rm -f "$state"/*.meta
mkdir -p "$AC_HOME/data/ral-i"
printf 'window=crew:ral-i\nbackend=herdr\n' >"$state/ral-i.meta"
seed_pane ral-i pRALI tRALI
printf 'blocked\n' >"$FAKE_HERDR/panes/pRALI.status"
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
assert_file "$state/.ask-ral-i" "pane B latched blocked before it resumed"
printf 'idle\n' >"$FAKE_HERDR/panes/pRALI.status"
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_no_file "$state/.ask-ral-i" "resuming clears the ask latch"
# Message only, timestamp stripped (ac_status_append's own "<ts> <line>"
# shape) - a real re-block/resume pair legitimately differs by wall-clock
# second, so comparing full lines below would pass even if two different
# live states rendered the SAME message.
idle_line="$(tail -n1 "$state/ral-i.status" | cut -d' ' -f2-)"
case "$idle_line" in
  *"needs-decision: pane blocked"*) fail "an idle pane must not keep showing the stale blocked line" ;;
esac
rm -rf "$state"/.wake-spool*

# An already-resumed idle pane must never append a SECOND resume line -
# ac_status_append has no dedupe of its own (bin/ac-lib.sh:989), so the latch
# existing-then-dropped edge is the ONLY thing standing between this and one
# line per pane per poll forever.
before="$(wc -l <"$state/ral-i.status")"
bash "$BIN/ac-watch.sh" --once >/dev/null
after="$(wc -l <"$state/ral-i.status")"
assert_eq "$after" "$before" "an already-resumed idle pane never appends a second resume line"
rm -rf "$state"/.wake-spool*

# Pane C was blocked, then resumed WORKING (not idle): a THIRD line,
# distinguishable from both A and B.
rm -f "$state"/*.meta
mkdir -p "$AC_HOME/data/ral-w"
printf 'window=crew:ral-w\nbackend=herdr\n' >"$state/ral-w.meta"
seed_pane ral-w pRALW tRALW
printf 'blocked\n' >"$FAKE_HERDR/panes/pRALW.status"
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
printf 'working\n' >"$FAKE_HERDR/panes/pRALW.status"
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_no_file "$state/.ask-ral-w" "resuming clears the ask latch (working too)"
working_line="$(tail -n1 "$state/ral-w.status" | cut -d' ' -f2-)"
case "$working_line" in
  *"needs-decision: pane blocked"*) fail "a working pane must not keep showing the stale blocked line" ;;
esac
rm -rf "$state"/.wake-spool*

# THE ACCEPTANCE BAR ITSELF: three panes, three DIFFERENT rendered lines.
blocked_line="$(tail -n1 "$state/ral-b.status" | cut -d' ' -f2-)"
if [ "$idle_line" = "$working_line" ]; then
  fail "idle and working resumes render identically - collapses two live states into one"
fi
if [ "$idle_line" = "$blocked_line" ] || [ "$working_line" = "$blocked_line" ]; then
  fail "a resumed pane's line must differ from the still-blocked pane's line"
fi

# --- ask-alert resume line must NOT fire under a captain-wait mask ---------
# backend_agent_blocked reads FALSE while a CAPTAIN-WAIT STAMP
# (state/.captain-wait-<id>) is live (bin/ac-backend.sh:866) - a MASK, not a
# real resume. bin/ac-room.sh:262 stamps it on any room GATE/ASK pending
# edge 0 -> >0, independent of this watcher's own poll loop, so the latch can
# still be live when the stamp lands. Without this guard, a pane genuinely
# still blocked (now on the captain) would render "working: ... agent
# resumed" - trading the old lie (stale blocked forever) for a new one
# (resumed while still blocked).
rm -f "$state"/*.meta
mkdir -p "$AC_HOME/data/ral-cw"
printf 'window=crew:ral-cw\nbackend=herdr\n' >"$state/ral-cw.meta"
seed_pane ral-cw pRALCW tRALCW
printf 'blocked\n' >"$FAKE_HERDR/panes/pRALCW.status"
bash "$BIN/ac-watch.sh" --once >/dev/null
rm -rf "$state"/.wake-spool*
assert_file "$state/.ask-ral-cw" "pane latched blocked before the captain-wait stamp lands"

# The stamp lands (bin/ac-room.sh cmd_post's backend_mark_wait, simulated
# directly): herdr reports the pane blocked and the wait file is touched.
printf 'blocked\n' >"$FAKE_HERDR/panes/pRALCW.reported"
touch "$state/.captain-wait-ral-cw"
before="$(wc -l <"$state/ral-cw.status")"
bash "$BIN/ac-watch.sh" --once >/dev/null
after="$(wc -l <"$state/ral-cw.status")"
assert_eq "$after" "$before" "a captain-wait-masked pane appends NO resume line - it is still genuinely blocked"
assert_file "$state/.ask-ral-cw" "the latch stays live while the mask is up, so it re-arms honestly later"
masked_line="$(tail -n1 "$state/ral-cw.status" | cut -d' ' -f2-)"
case "$masked_line" in
  *"agent resumed"*|*"turn complete"*) fail "a captain-wait-masked pane must never claim it resumed" ;;
esac
rm -rf "$state"/.wake-spool*

# The stamp clears AND the pane has genuinely resumed: the honest line lands.
rm -f "$FAKE_HERDR/panes/pRALCW.reported" "$state/.captain-wait-ral-cw"
printf 'idle\n' >"$FAKE_HERDR/panes/pRALCW.status"
bash "$BIN/ac-watch.sh" --once >/dev/null
assert_no_file "$state/.ask-ral-cw" "a genuine resume after the stamp clears finally releases the latch"
resumed_line="$(tail -n1 "$state/ral-cw.status" | cut -d' ' -f2-)"
case "$resumed_line" in
  *"idle: pane no longer blocked"*) ;;
  *) fail "a genuine resume after the mask clears must append the honest idle/working line, got: $resumed_line" ;;
esac
rm -rf "$state"/.wake-spool*

reset_state
rm -f "$state"/*.status

pass
