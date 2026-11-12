#!/usr/bin/env bash
# ac-done.test.sh - the agent-side completion PUSH (bin/ac-done.sh): a durable
# record in the spool of the scope whose watcher supervises the task, the
# marker dedup stamp that keeps one completion to ONE wake, and the
# wrong-kill guard on the watcher nudge (a dead, reused or non-sleeping
# target is never signalled).
#
# Every case runs ac-done.sh the way a CREWMATE does: with no AC_HOME at all,
# reaching the fleet only through the narrow scalars ac-spawn.sh threads.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
state="$AC_HOME/state"

push() {
  # push <id> <marker> [<scope>] - ac-done.sh as a homeless crewmate runs it.
  env -u AC_HOME -u AC_SCOPE \
    AC_FLEET_STATE="$state" AC_FLEET_SCOPE="${3:-}" \
    "$BIN/ac-done.sh" "$1" "$2"
}

spool_records() { cat "$state/.wake-spool"/* 2>/dev/null || true; }

# --- usage -------------------------------------------------------------------
assert_fails push "" ""
assert_fails env -u AC_HOME AC_FLEET_STATE="$state" "$BIN/ac-done.sh" onlyid

# --- the record: same format, same kind, same drain as the watcher's own -----
out="$(push c1 'done: shipped the widget')"
assert_contains "$out" "c1" "the push names the task it announced"
assert_contains "$(spool_records)" "done: shipped the widget" "the marker is in the record"
drained="$(env -u AC_SCOPE "$BIN/ac-wake-drain.sh")"
assert_contains "$drained" "report c1 done: shipped the widget" \
  "an ordinary drain emits the pushed record like any other wake"

# --- scope: a promoted family's push lands in ITS spool, not the fleet's -----
push f1-t1 'done: family work' f1 >/dev/null
assert_contains "$(cat "$state/.wake-spool.f1"/* 2>/dev/null || true)" "done: family work" \
  "a family-scoped push files for the roomchief that drains it"
assert_eq "$(spool_records)" "" "and never in the fleet spool"
rm -rf "$state"/.wake-spool*

# --- dedup: the push stamps the watcher's OWN marker dedup ------------------
# .seen-<id> is what keeps the poll that later reads the same completion off
# the pane from publishing a SECOND record; the stale .seen-hash-<id> and
# .rewake-<id> of an earlier wake must go with it, or the watcher's re-wake
# branch would fire - or stay latched shut - on the new marker's first poll.
printf 'old-hash\n' >"$state/.seen-hash-c2"
: >"$state/.rewake-c2"
push c2 'blocked: waiting on the captain' >/dev/null
assert_eq "$(cat "$state/.seen-c2")" "blocked: waiting on the captain" \
  "the pushed marker is stamped as seen"
assert_no_file "$state/.seen-hash-c2" "the previous wake's pane-hash discriminator is dropped"
assert_no_file "$state/.rewake-c2" "the previous marker's re-wake latch is dropped too"

# --- no watcher armed: quiet success, the record still waits in the spool ----
rm -rf "$state"/.wake-spool* "$state"/.watch*.lock.d
out="$(push c3 'done: nobody is watching')"
assert_contains "$out" "no armed watcher" "an unwatched push says so instead of failing"
assert_contains "$(spool_records)" "done: nobody is watching" "the record is durable either way"

# --- the nudge: the watcher's poll sleep ends early --------------------------
# A stand-in whose command line is a watcher's and whose child is the poll
# `sleep` - exactly what the watcher's poll wait runs. Killing that child alone ends the
# wait; the stand-in records that it returned.
mkdir -p "$TMP/fakewatch"
flag="$TMP/fakewatch/woke"
cat >"$TMP/fakewatch/ac-watch.sh" <<EOF
#!/usr/bin/env bash
sleep 30 &
wait \$! 2>/dev/null || true
printf 'wait ended\n' >"$flag"
EOF
chmod +x "$TMP/fakewatch/ac-watch.sh"

arm_fake() {
  # arm_fake <lockdir> - run the stand-in and record its pid where ac-watch.sh
  # publishes it, then wait for its sleep child to exist. Every background job
  # here is detached from the suite's stdout: an inherited pipe outlives a
  # failing assert and hangs whatever reads the suite's output.
  bash "$TMP/fakewatch/ac-watch.sh" >/dev/null 2>&1 &
  fake_pid=$!
  mkdir -p "$1"
  printf '%s\n' "$fake_pid" >"$1/pid"
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -n "$(pgrep -P "$fake_pid" 2>/dev/null || true)" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "the stand-in watcher never started its sleep child"
}

arm_fake "$state/.watch.lock.d"
out="$(push c4 'done: nudge me')"
assert_contains "$out" "nudged" "a live watcher is nudged"
i=0; while [ ! -f "$flag" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_file "$flag" "the nudge ended the watcher's poll wait"
wait "$fake_pid" 2>/dev/null || true
rm -f "$flag"
rm -rf "$state/.watch.lock.d"

# The scoped watcher takes its own lock, so a family push nudges THAT one.
arm_fake "$state/.watch-only-f2.lock.d"
push f2-t1 'done: scoped nudge' f2 >/dev/null
i=0; while [ ! -f "$flag" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_file "$flag" "a family push nudges the family's own scoped watcher"
wait "$fake_pid" 2>/dev/null || true
rm -f "$flag"
rm -rf "$state/.watch-only-f2.lock.d"

# The ported watcher runs as `bun --no-env-file <root>/src/watch.ts <cwd>`, a
# command line that never names ac-watch: the push must still find and nudge it.
mkdir -p "$TMP/portwatch/src"
cat >"$TMP/portwatch/src/watch.ts" <<EOF
const s = Bun.spawn(["sleep", "30"], { stdout: "ignore", stderr: "ignore" });
await s.exited;
await Bun.write("$flag", "wait ended\\n");
EOF
bun --no-env-file "$TMP/portwatch/src/watch.ts" "$TMP" >/dev/null 2>&1 &
fake_pid=$!
mkdir -p "$state/.watch.lock.d"
printf '%s\n' "$fake_pid" >"$state/.watch.lock.d/pid"
i=0
while [ "$i" -lt 50 ] && [ -z "$(pgrep -P "$fake_pid" 2>/dev/null || true)" ]; do sleep 0.1; i=$((i + 1)); done
out="$(push c4p 'done: nudge the port')"
assert_contains "$out" "nudged watcher pid=$fake_pid" "a ported watcher (/src/watch.ts) is found and nudged"
i=0; while [ ! -f "$flag" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_file "$flag" "the nudge ended the ported watcher's poll wait"
wait "$fake_pid" 2>/dev/null || true
rm -f "$flag"
rm -rf "$state/.watch.lock.d"

# --- wrong-kill guard: a REUSED pid is never signalled -----------------------
# The recorded pid is alive but runs something else entirely (the shape pid
# reuse leaves behind). Killing it would be the sharp edge of this whole
# story, so the command line is confirmed to be a watcher's first.
sleep 30 >/dev/null 2>&1 & victim=$!
mkdir -p "$state/.watch.lock.d"
printf '%s\n' "$victim" >"$state/.watch.lock.d/pid"
out="$(push c5 'done: reused pid')"
assert_contains "$out" "no armed watcher" "a reused pid is treated as no watcher at all"
sleep 0.3
kill -0 "$victim" 2>/dev/null || fail "a reused pid must NEVER be signalled"
kill "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true

# A DEAD recorded pid is the same quiet no-op, and never a failure.
printf '%s\n' "$victim" >"$state/.watch.lock.d/pid"
out="$(push c6 'done: dead pid')"
assert_contains "$out" "no armed watcher" "a dead watcher pid nudges nothing"
assert_contains "$(spool_records)" "done: dead pid" "and the record is still durable"

# --- wrong-kill guard: only the poll SLEEP is a legal target -----------------
# A real watcher busy inside a poll pass has no sleep child; whatever child it
# does have is none of the push's business.
cat >"$TMP/fakewatch/ac-watch.sh" <<'EOF'
#!/usr/bin/env bash
tail -f /dev/null &
wait $! 2>/dev/null || true
EOF
chmod +x "$TMP/fakewatch/ac-watch.sh"
bash "$TMP/fakewatch/ac-watch.sh" >/dev/null 2>&1 & busy_pid=$!
i=0; child=""
while [ "$i" -lt 50 ]; do
  child="$(pgrep -P "$busy_pid" 2>/dev/null || true)"
  [ -n "$child" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$child" ] || fail "the busy stand-in never started its child"
printf '%s\n' "$busy_pid" >"$state/.watch.lock.d/pid"
out="$(push c7 'done: watcher is mid-poll')"
assert_contains "$out" "nothing to nudge" "a watcher with no poll sleep is left alone"
sleep 0.3
kill -0 "$child" 2>/dev/null || fail "a non-sleep child must NEVER be signalled"
kill "$busy_pid" "$child" 2>/dev/null || true
wait "$busy_pid" 2>/dev/null || true
assert_contains "$(spool_records)" "done: watcher is mid-poll" \
  "an un-nudgeable watcher still leaves the record for the next drain"

# --- the CLI contract, byte for byte -----------------------------------------
# One PATH `date` stub answers `+%s%N` with $STUB_STAMP, so a record's name and
# stamp are known; stdout and stderr are read with the state dir spelled STATE,
# and the tree a push leaves - every `.seen-*`, `.rewake-*` stamp and `.wake-*`
# entry - with the publisher's pid spelled PID and mktemp's suffix RANDOM.
S="$TMP/s"; H="$TMP/h"
mkdir -p "$S" "$H" "$TMP/stub"
cat >"$TMP/stub/date" <<'EOF'
#!/bin/sh
case "$1" in +%s%N) printf '%s\n' "$STUB_STAMP" ;; *) exec /bin/date "$@" ;; esac
EOF
chmod +x "$TMP/stub/date"
STUB_STAMP=1700000000123456789
snap() {  # snap <state> - every stamp and spool entry under <state>, name then bytes
  [ -d "$1" ] || return 0
  local f
  (cd "$1" && find . -mindepth 1 \( -name '.seen-*' -o -name '.rewake-*' -o -path './.wake-*' \)) | LC_ALL=C sort \
    | while IFS= read -r f; do
        printf '== %s\n' "$f" | LC_ALL=C sed -E -e 's/\.[0-9]+\.([0-9]{6})$/.PID.\1/' -e 's/\.wake-tmp\.[A-Za-z0-9]{8}$/.wake-tmp.RANDOM/'
        [ ! -f "$1/$f" ] || cat "$1/$f"
      done
}
run() {  # run <args...> - one push as a crewmate runs it; sets rc, out, err, tree
  local s="${STATE-$S}" c="${CWD:-$TMP}" t
  rc=0
  (cd "$c" && env -u AC_HOME -u AC_SCOPE ${HOME_DIR:+AC_HOME=$HOME_DIR} LC_ALL=C PATH="$TMP/stub:$PATH" \
    STUB_STAMP="$STUB_STAMP" AC_FLEET_STATE="$s" AC_FLEET_SCOPE="${SCOPE-}" "$BIN/ac-done.sh" "$@") >"$TMP/raw.out" 2>"$TMP/raw.err" || rc=$?
  t="$s"
  [ -n "$t" ] || t="${HOME_DIR:-/nonexistent}/state"
  case "$t" in /*) ;; *) t="$c/$t" ;; esac
  out="$(LC_ALL=C sed -E -e "s#$t#STATE#g" -e 's/pid=[0-9]+/pid=P/' -e 's/sleep [0-9]+/sleep C/' "$TMP/raw.out")"
  err="$(LC_ALL=C sed -E -e "s#$t#STATE#g" "$TMP/raw.err")"
  tree="$(snap "$t")"
}
reset_state() { rm -rf "$S"; mkdir -p "$S"; }
no_watcher="no armed watcher for this scope - the record waits in the spool"

# usage: no args, one arg, an empty marker
run
assert_eq "$rc" "1" "usage refusal exits 1"
assert_eq "$err" "ERROR: usage: ac-done.sh <id> <marker>" "usage refusal"
run c1
assert_eq "$err" "ERROR: usage: ac-done.sh <id> <marker>" "one argument is a usage refusal"
run c1 ''
assert_eq "$err" "ERROR: usage: ac-done.sh <id> <marker>" "an empty marker is a usage refusal"
assert_eq "$tree" "" "a refused push writes nothing"

# the state dir: homeless; AC_HOME fallback (state/ minted); an unenterable
# home; a missing dir; a FILE; a trailing slash; a relative path
STATE= run c2 'done: no home at all'
assert_eq "$rc" "1" "homeless exits 1"
assert_eq "$err" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" "homeless refusal"
STATE= HOME_DIR="$H" run c2 'done: home fallback'
assert_eq "$rc" "0" "the AC_HOME fallback pushes"
assert_file "$H/state/.seen-c2" "the fallback rung mints state/ under AC_HOME and stamps there"
assert_contains "$tree" "== ./.wake-spool/1700000000123456789.PID.000000" "and publishes there"
STATE= HOME_DIR="$TMP/missing-home" run c2 'done: bad home'
assert_eq "$rc" "1" "an unenterable home exits 1"
assert_eq "$err" "ERROR: AC_HOME is not a readable directory: $TMP/missing-home" "an unenterable home is named"
[ ! -e "$TMP/missing-home" ] || fail "an unenterable home must not be minted"
STATE="$TMP/missing" run c2 'done: missing dir'
assert_eq "$rc" "1" "a missing state dir exits 1"
assert_eq "$err" "ERROR: fleet state dir not found: STATE (AC_FLEET_STATE)" "a missing state dir"
: >"$TMP/afile"
STATE="$TMP/afile" run c2 'done: a file'
assert_eq "$err" "ERROR: fleet state dir not found: STATE (AC_FLEET_STATE)" "a file where the dir should be"
STATE="$S/" run c2 'done: trailing slash'
assert_file "$S/.seen-c2" "a trailing slash on the state dir changes nothing"
mkdir -p "$TMP/rel/state"
STATE=state CWD="$TMP/rel" run c2 'done: relative'
assert_file "$TMP/rel/state/.seen-c2" "a relative AC_FLEET_STATE resolves against the caller's cwd"
assert_contains "$tree" "== ./.wake-spool/1700000000123456789.PID.000000
1700000000	report	c2	done: relative" "and the record lands under it"

# a plain push: the line, the stamp, the record, the name, no litter
reset_state
run c1 'done: shipped'
assert_eq "$rc" "0" "a push exits 0"
assert_eq "$out" "pushed c1 scope=fleet - $no_watcher" "the pushed line"
assert_eq "$tree" "== ./.seen-c1
done: shipped
== ./.wake-spool
== ./.wake-spool/1700000000123456789.PID.000000
1700000000	report	c1	done: shipped" "the whole tree a push leaves: stamp, spool, one record, no .wake-tmp"
assert_eq "$(ls -l "$S/.wake-spool"/* | cut -c1-10)" "-rw-------" "the record carries mktemp's 0600 through the link"

# scopes: a malformed one lands on the fleet spool while `scope=` prints the
# raw scalar
reset_state
SCOPE=f1 run f1-t1 'done: family work'
assert_eq "$out" "pushed f1-t1 scope=f1 - $no_watcher" "scope= names a legal family"
for s in 'a/b' '.x' 'f 1' ''; do
  reset_state
  SCOPE="$s" run c4 "done: scope [$s]"
  assert_contains "$tree" "== ./.wake-spool/1700000000123456789.PID.000000" "scope '$s' lands on the fleet spool"
  assert_eq "$out" "pushed c4 scope=${s:-fleet} - $no_watcher" "scope '$s' printed raw"
done
case "$(cd "$S" && ls -A)" in *".wake-spool."*) fail "a malformed scope must never mint a family spool" ;; esac

# markers: TAB and LF (stamp raw, record folded); 4096 bytes; words a shell
# builtin would eat; padding kept in both files; a byte that is not UTF-8
reset_state
run c5 "$(printf 'done:\tx\ny')"
assert_eq "$(od -c "$S/.seen-c5" | head -n 1)" "$(printf 'done:\tx\ny\n' | od -c | head -n 1)" "the stamp keeps TAB and LF raw"
assert_eq "$(cat "$S/.wake-spool"/*)" "$(printf '1700000000\treport\tc5\tdone: x y')" "the record folds them to spaces"
reset_state
big="$(head -c 4096 /dev/zero | tr '\0' a)"
run c5 "$big"
assert_eq "$(wc -c <"$S/.seen-c5" | tr -d ' ')" "4097" "a 4 KB marker is stamped whole"
reset_state
run c5 -n
assert_eq "$(cat "$S/.seen-c5")" "-n" "a marker spelled -n is stamped, not read as an option"
run c6 '%s%s'
assert_eq "$(cat "$S/.seen-c6")" "%s%s" "a marker is never a format string"
run c7 '  padded  '
assert_contains "$tree" "== ./.seen-c7
  padded  " "padding kept in the stamp"
assert_contains "$tree" "c7	  padded  " "and in the record"
# bun decodes argv before the module sees it, so a byte that is not UTF-8
# arrives as U+FFFD; the push must still land rather than die on it.
reset_state
run c8 "$(printf 'done: caf\351 ok')"
assert_eq "$rc" "0" "a non-UTF-8 marker still pushes"
assert_eq "$(od -An -tx1 "$S/.seen-c8" | tr -d ' \n')" "646f6e653a20636166efbfbd206f6b0a" "the byte is stamped as U+FFFD"

# the dedup stamps: an older marker stamp is overwritten
reset_state
printf 'done: older words\n' >"$S/.seen-c2"
run c2 'blocked: waiting on the captain'
assert_eq "$(cat "$S/.seen-c2")" "blocked: waiting on the captain" "an older stamp is replaced"

# ids: `/` cannot be stamped (nothing written); `..` and spaces are stamped as spelled
reset_state
run a/b 'done: slash'
assert_eq "$rc" "1" "an id with a slash exits 1"
assert_eq "$err" "ERROR: cannot write the dedup stamp STATE/.seen-a/b: ENOENT" "the stamp that could not be written is named"
assert_eq "$tree" "" "nothing is written when the stamp fails"
run .. 'done: dots'
assert_contains "$tree" "== ./.seen-..
done: dots" "id .. stamps .seen-.."
run 'a b' 'done: spaces'
assert_contains "$tree" "== ./.seen-a b
done: spaces" "an id with spaces stamps as spelled"
assert_contains "$tree" "	a b	done: spaces" "and is the record's id field"

# an unwritable state dir: the stamp fails first, nothing published (skipped as root)
if [ "$(id -u)" != 0 ]; then
  reset_state
  chmod 555 "$S"
  run c8 'done: read-only'
  chmod 755 "$S"
  assert_eq "$rc" "1" "an unwritable state dir exits 1"
  assert_eq "$err" "ERROR: cannot write the dedup stamp STATE/.seen-c8: EACCES" "the unwritable stamp is named"
  assert_eq "$tree" "" "an unwritable state dir gets no stamp and no record"
fi

# the clock: garbage refuses AFTER the stamp (deliberate) with no litter; a
# date without %N keeps its literal N in the name and ten digits in the record
reset_state
STUB_STAMP=garbage run c9 'done: broken clock'
assert_eq "$rc" "1" "a broken clock exits 1"
assert_eq "$err" "ERROR: wake NOT published for c9 - the completion is not durable; say so in the pane" "a broken clock refuses loudly"
assert_eq "$tree" "== ./.seen-c9
done: broken clock" "the stamp has already advanced; no record, no litter"
reset_state
STUB_STAMP=1700000000N run c9 'done: second resolution'
assert_eq "$tree" "== ./.seen-c9
done: second resolution
== ./.wake-spool
== ./.wake-spool/1700000000N.PID.000000
1700000000	report	c9	done: second resolution" "the literal N stays in the name, the record's stamp is ten digits"
# EEXIST stepping: the after-write seam's hook plants `<stamp>.<its parent's
# pid>.000000` - its parent IS the publisher - so the link collides and the
# record lands at 000001.
reset_state
cat >"$TMP/plant" <<EOF
#!/bin/sh
mkdir -p "\$AC_FLEET_STATE/.wake-spool"
: >"\$AC_FLEET_STATE/.wake-spool/\$STUB_STAMP.\$PPID.000000"
EOF
chmod +x "$TMP/plant"
AC_WAKE_SEAM_AT=after-write AC_WAKE_SEAM_RUN="$TMP/plant" run c9 'done: stepped'
assert_eq "$tree" "== ./.seen-c9
done: stepped
== ./.wake-spool
== ./.wake-spool/1700000000123456789.PID.000000
== ./.wake-spool/1700000000123456789.PID.000001
1700000000	report	c9	done: stepped" "a taken name is stepped past to 000001"

# the spool path taken by a FILE: the refusal, the stamp written and the record
# RETAINED as .wake-tmp.* litter
reset_state
: >"$S/.wake-spool"
run c10 'done: spool is a file'
assert_eq "$rc" "1" "a spool that cannot be made exits 1"
assert_contains "$err" "ERROR: wake NOT published for c10 - the completion is not durable; say so in the pane" "the refusal"
assert_eq "$tree" "== ./.seen-c10
done: spool is a file
== ./.wake-spool
== ./.wake-tmp.RANDOM
1700000000	report	c10	done: spool is a file" "one .wake-tmp.* holds the record"

# lock-file shapes that are no watcher: trailing space, leading 0, letters,
# empty, no pid file
reset_state
mkdir -p "$S/.watch.lock.d"
for shape in "$$ " "0$$" abc ""; do
  printf '%s' "$shape" >"$S/.watch.lock.d/pid"
  run c11 'done: odd pid file'
  assert_eq "$out" "pushed c11 scope=fleet - $no_watcher" "pid file '$shape' is no watcher"
done
rm -f "$S/.watch.lock.d/pid"
run c11 'done: no pid file'
assert_eq "$out" "pushed c11 scope=fleet - $no_watcher" "a lock dir with no pid file"

# a legal scope consults only ITS lock: the fleet watcher is not a fallback
cat >"$TMP/fakewatch/ac-watch.sh" <<EOF
#!/usr/bin/env bash
sleep 30 &
wait \$! 2>/dev/null || true
printf 'wait ended\n' >"$flag"
EOF
reset_state
arm_fake "$S/.watch.lock.d"
SCOPE=f3 run f3-t1 'done: other family'
assert_eq "$out" "pushed f3-t1 scope=f3 - $no_watcher" "a legal scope never nudges the fleet watcher"
sleep 0.3
[ ! -f "$flag" ] || fail "the fleet stand-in must be left alone"
kill $(pgrep -P "$fake_pid" 2>/dev/null || true) "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
rm -f "$flag"

# two pushes of one id: the second overwrites the stamp and adds a second
# record under its own pid, sequence 000000 again (one record per process)
reset_state
run c15 'done: first'
run c15 'done: second'
assert_eq "$(cat "$S/.seen-c15")" "done: second" "the second push's stamp"
assert_eq "$(cat "$S/.wake-spool"/* | LC_ALL=C sort)" "1700000000	report	c15	done: first
1700000000	report	c15	done: second" "both records are kept"
assert_eq "$(ls "$S/.wake-spool" | LC_ALL=C sed -E 's/\.[0-9]+\./.PID./')" "1700000000123456789.PID.000000
1700000000123456789.PID.000000" "each record is 000000 under its own pid"

pass
