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
# the pane from publishing a SECOND record; the stale .seen-hash-<id> of an
# earlier wake must go with it, or the watcher's re-wake branch would fire on
# the new marker's first poll.
printf 'old-hash\n' >"$state/.seen-hash-c2"
push c2 'blocked: waiting on the captain' >/dev/null
assert_eq "$(cat "$state/.seen-c2")" "blocked: waiting on the captain" \
  "the pushed marker is stamped as seen"
assert_no_file "$state/.seen-hash-c2" "the previous wake's pane-hash discriminator is dropped"

# --- no watcher armed: quiet success, the record still waits in the spool ----
rm -rf "$state"/.wake-spool* "$state"/.watch*.lock.d
out="$(push c3 'done: nobody is watching')"
assert_contains "$out" "no armed watcher" "an unwatched push says so instead of failing"
assert_contains "$(spool_records)" "done: nobody is watching" "the record is durable either way"

# --- the nudge: the watcher's poll sleep ends early --------------------------
# A stand-in whose command line is a watcher's and whose child is the poll
# `sleep` - exactly what poll_wait runs. Killing that child alone ends the
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

# --- differential: src/done.ts against the frozen bash original ---------------
# DISPUTED: the implementation (tests/fixtures/ac-done.sh under bash vs src/done.ts through bin/ac-done.sh)
# HELD-CONSTANT: two state dirs seeded alike ($OS for the oracle, $NS for the shim), argv, cwd, no AC_HOME/AC_SCOPE unless a row sets one, LC_ALL=C, one PATH `date` stub answering `+%s%N` with $STUB_STAMP on both sides; exit status, stdout (a nudge's pid numbers spelled P and C) and stderr (the state dir spelled STATE, a home HOME) compared whole, then every `.seen-*` stamp and `.wake-*` entry left behind - names with the pid spelled PID and mktemp's suffix RANDOM - with their bytes.
obin="$(make_oracle_bin ac-done)"
OS="$TMP/os"; NS="$TMP/ns"; OH="$TMP/oh"; NH="$TMP/nh"
mkdir -p "$OS" "$NS" "$OH" "$NH" "$TMP/stub"
cat >"$TMP/stub/date" <<'EOF'
#!/bin/sh
case "$1" in +%s%N) printf '%s\n' "$STUB_STAMP" ;; *) exec /bin/date "$@" ;; esac
EOF
chmod +x "$TMP/stub/date"
STUB_STAMP=1700000000123456789
run_side() {  # run_side <bin> <state> <home> <cwd> <out> <err> <args...> - one side, as a crewmate runs it
  local b="$1" s="$2" h="$3" c="$4" o="$5" e="$6"; shift 6
  (cd "$c" && env -u AC_HOME -u AC_SCOPE ${h:+AC_HOME=$h} LC_ALL=C PATH="$TMP/stub:$PATH" \
    STUB_STAMP="$STUB_STAMP" AC_FLEET_STATE="$s" AC_FLEET_SCOPE="${SCOPE-}" "$b/ac-done.sh" "$@") >"$o" 2>"$e"
}
norm() {  # norm <file> <state> <home> - the paths spelled STATE/HOME, a nudge's numbers P and C
  LC_ALL=C sed -E -e "s#$2#STATE#g" -e "s#$3#HOME#g" -e 's/pid=[0-9]+/pid=P/' -e 's/sleep [0-9]+/sleep C/' "$1"
}
snap() {  # snap <state> <out> - every stamp and spool entry under <state>, byte order, name then bytes
  : >"$2"
  [ -d "$1" ] || return 0
  (cd "$1" && find . -mindepth 1 \( -name '.seen-*' -o -path './.wake-*' \) | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s\n' "$f" | LC_ALL=C sed -E -e 's/\.[0-9]+\.([0-9]{6})$/.PID.\1/' -e 's/\.wake-tmp\.[A-Za-z0-9]{8}$/.wake-tmp.RANDOM/'
    [ ! -f "$f" ] || cat "$f"
  done) >"$2"
}
tree_of() {  # tree_of <state-arg> <home> <cwd> - where that side's state dir really is
  local t="$1"
  [ -n "$t" ] || t="${2:-/nonexistent}/state"
  case "$t" in /*) ;; *) t="$3/$t" ;; esac
  printf '%s\n' "$t"
}
same() {  # same <args...> - oracle on $OS and shim on $NS answer and leave byte-identical trees
  local o_rc=0 n_rc=0 o_s="${O_STATE-$OS}" n_s="${N_STATE-$NS}" o_c="${O_CWD:-$TMP}" n_c="${N_CWD:-$TMP}"
  run_side "$obin" "$o_s" "${O_HOME-}" "$o_c" "$TMP/o.raw" "$TMP/o.rawerr" "$@" || o_rc=$?
  run_side "$BIN" "$n_s" "${N_HOME-}" "$n_c" "$TMP/n.raw" "$TMP/n.rawerr" "$@" || n_rc=$?
  norm "$TMP/o.raw" "$(tree_of "$o_s" "${O_HOME-}" "$o_c")" "$OH" >"$TMP/o.out"
  norm "$TMP/o.rawerr" "$(tree_of "$o_s" "${O_HOME-}" "$o_c")" "$OH" >"$TMP/o.err"
  norm "$TMP/n.raw" "$(tree_of "$n_s" "${N_HOME-}" "$n_c")" "$NH" >"$TMP/n.out"
  norm "$TMP/n.rawerr" "$(tree_of "$n_s" "${N_HOME-}" "$n_c")" "$NH" >"$TMP/n.err"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  [ "${ERR-}" = own ] || cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
  snap "$(tree_of "$o_s" "${O_HOME-}" "$o_c")" "$TMP/o.tree"
  snap "$(tree_of "$n_s" "${N_HOME-}" "$n_c")" "$TMP/n.tree"
  [ "${TREE-}" = bytes ] || cmp -s "$TMP/o.tree" "$TMP/n.tree" || fail "differential state tree differs for '$*': $(diff "$TMP/o.tree" "$TMP/n.tree" | head -n 6)"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
oracle_err() { cat "$TMP/o.err"; }
shim_tree() { cat "$TMP/n.tree"; }
reset_sides() { rm -rf "$OS" "$NS"; mkdir -p "$OS" "$NS"; }
seed() {  # seed <relpath> <printf-format> - the same file under both state dirs
  local s; for s in "$OS" "$NS"; do mkdir -p "$(dirname "$s/$1")"; printf -- "$2" >"$s/$1"; done
}

# 1. usage: no args, one arg, an empty marker
same
assert_eq "$(shim_err)" "ERROR: usage: ac-done.sh <id> <marker>" "usage refusal"
same c1
same c1 ''
assert_eq "$(shim_tree)" "" "a refused push writes nothing"

# 2. the state dir: homeless; AC_HOME fallback (state/ minted); a missing dir;
#    a FILE; a trailing slash; a relative path against the caller's cwd
O_STATE= N_STATE= same c2 'done: no home at all'
assert_eq "$(shim_err)" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" "homeless refusal"
O_STATE= N_STATE= O_HOME="$OH" N_HOME="$NH" same c2 'done: home fallback'
assert_file "$NH/state/.seen-c2" "the fallback rung mints state/ under AC_HOME and stamps there"
assert_contains "$(shim_tree)" "== ./.wake-spool/1700000000123456789.PID.000000" "and publishes there"
# Named divergence: an AC_HOME that cannot be entered dies on the shell's own
# `cd:` line in the original; the port names the variable. Same exit, nothing written.
ERR=own O_STATE= N_STATE= O_HOME="$TMP/missing-home" N_HOME="$TMP/missing-home" same c2 'done: bad home'
assert_contains "$(oracle_err)" "cd: $TMP/missing-home: No such file or directory" "the original's cd noise"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: $TMP/missing-home" "the port's refusal"
O_STATE="$TMP/missing" N_STATE="$TMP/missing" same c2 'done: missing dir'
assert_eq "$(shim_err)" "ERROR: fleet state dir not found: STATE (AC_FLEET_STATE)" "a missing state dir"
: >"$TMP/afile"
O_STATE="$TMP/afile" N_STATE="$TMP/afile" same c2 'done: a file'
assert_eq "$(shim_err)" "ERROR: fleet state dir not found: STATE (AC_FLEET_STATE)" "a file where the dir should be"
O_STATE="$OS/" N_STATE="$NS/" same c2 'done: trailing slash'
assert_contains "$(shim_tree)" "== ./.seen-c2
done: trailing slash" "a trailing slash on the state dir changes nothing"
reset_sides
mkdir -p "$TMP/ro/state" "$TMP/rn/state"
O_STATE=state N_STATE=state O_CWD="$TMP/ro" N_CWD="$TMP/rn" same c2 'done: relative'
assert_file "$TMP/rn/state/.seen-c2" "a relative AC_FLEET_STATE resolves against the caller's cwd"
assert_contains "$(shim_tree)" "== ./.wake-spool/1700000000123456789.PID.000000
1700000000	report	c2	done: relative" "and the record lands under it"

# 3. a plain push: the line, the stamp, the record, the name, no litter
reset_sides
same c1 'done: shipped'
assert_eq "$(shim_out)" "pushed c1 scope=fleet - no armed watcher for this scope - the record waits in the spool" "the pushed line"
assert_eq "$(shim_tree)" "== ./.seen-c1
done: shipped
== ./.wake-spool
== ./.wake-spool/1700000000123456789.PID.000000
1700000000	report	c1	done: shipped" "the whole tree a push leaves: stamp, spool, one record, no .wake-tmp"
assert_eq "$(ls "$NS/.wake-spool")" "1700000000123456789.$(ls "$NS/.wake-spool" | cut -d. -f2).000000" "the name is <stamp>.<pid>.000000"
assert_eq "$(ls -l "$NS/.wake-spool"/* | cut -c1-10)" "-rw-------" "the record carries mktemp's 0600 through the link"

# 4. scopes: a legal family files for its roomchief; a malformed one lands on
#    the fleet while `scope=` prints the raw scalar (the bash's reading, kept)
reset_sides
SCOPE=f1 same f1-t1 'done: family work'
assert_contains "$(shim_tree)" "== ./.wake-spool.f1/1700000000123456789.PID.000000" "a legal scope's own spool"
assert_eq "$(shim_out)" "pushed f1-t1 scope=f1 - no armed watcher for this scope - the record waits in the spool" "scope= names it"
for s in 'a/b' '.x' 'f 1' ''; do
  reset_sides
  SCOPE="$s" same c4 "done: scope [$s]"
  assert_contains "$(shim_tree)" "== ./.wake-spool/1700000000123456789.PID.000000" "scope '$s' lands on the fleet spool"
  assert_eq "$(shim_out)" "pushed c4 scope=${s:-fleet} - no armed watcher for this scope - the record waits in the spool" "scope '$s' printed raw"
done
case "$(cd "$NS" && ls -A)" in *".wake-spool."*) fail "a malformed scope must never mint a family spool" ;; esac

# 5. markers: TAB and LF (stamp raw, record folded); 4096 bytes; `-n`; `%s%s`;
#    padding kept in both files
reset_sides
same c5 "$(printf 'done:\tx\ny')"
assert_eq "$(od -c "$NS/.seen-c5" | head -n 1)" "$(printf 'done:\tx\ny\n' | od -c | head -n 1)" "the stamp keeps TAB and LF raw"
assert_eq "$(cat "$NS/.wake-spool"/*)" "$(printf '1700000000\treport\tc5\tdone: x y')" "the record folds them to spaces"
reset_sides
big="$(head -c 4096 /dev/zero | tr '\0' a)"
same c5 "$big"
assert_eq "$(wc -c <"$NS/.seen-c5" | tr -d ' ')" "4097" "a 4 KB marker is stamped whole"
reset_sides
same c5 -n
same c6 '%s%s'
same c7 '  padded  '
assert_contains "$(shim_tree)" "== ./.seen-c7
  padded  " "padding kept in the stamp"
assert_contains "$(shim_tree)" "c7	  padded  " "and in the record"
# Named divergence: a marker byte that is not UTF-8. Under LC_ALL=C the bash
# carries the byte; bun's argv decoding hands the module U+FFFD, so the port
# stamps and records EF BF BD there. Exit and the rest of the tree agree.
reset_sides
run_side "$obin" "$OS" "" "$TMP" "$TMP/o.raw" "$TMP/o.rawerr" c8 "$(printf 'done: caf\351 ok')"
run_side "$BIN" "$NS" "" "$TMP" "$TMP/n.raw" "$TMP/n.rawerr" c8 "$(printf 'done: caf\351 ok')"
cmp -s "$TMP/o.raw" "$TMP/n.raw" || fail "a non-UTF-8 marker: stdout must still agree"
assert_eq "$(od -An -tx1 "$OS/.seen-c8" | tr -d ' \n')" "646f6e653a20636166e9206f6b0a" "the original stamps the byte"
assert_eq "$(od -An -tx1 "$NS/.seen-c8" | tr -d ' \n')" "646f6e653a20636166efbfbd206f6b0a" "the port stamps U+FFFD (bun's argv decoding)"
# Named divergence, bash defect for the ledger: under the crewmate's UTF-8
# locale the original's `tr` stops at that byte and the record carries a
# TRUNCATED payload with exit 0; the port keeps every byte it was handed.
reset_sides
(cd "$TMP" && env -u AC_HOME -u AC_SCOPE -u LC_ALL LANG=en_US.UTF-8 PATH="$TMP/stub:$PATH" STUB_STAMP="$STUB_STAMP" AC_FLEET_STATE="$OS" "$obin/ac-done.sh" c8 "$(printf 'done: caf\351 ok')") >/dev/null 2>"$TMP/o.rawerr" || fail "the original exits 0 even as tr truncates"
assert_eq "$(cat "$OS/.wake-spool"/*)" "$(printf '1700000000\treport\tc8\tdone: caf')" "the original's record is cut at the byte"
assert_contains "$(cat "$TMP/o.rawerr")" "tr: Illegal byte sequence" "tr says so on stderr"
(cd "$TMP" && env -u AC_HOME -u AC_SCOPE -u LC_ALL LANG=en_US.UTF-8 PATH="$TMP/stub:$PATH" STUB_STAMP="$STUB_STAMP" AC_FLEET_STATE="$NS" "$BIN/ac-done.sh" c8 'done: café ok') >/dev/null 2>&1 || fail "the port pushes a UTF-8 marker"
assert_eq "$(cat "$NS/.wake-spool"/*)" "$(printf '1700000000\treport\tc8\tdone: café ok')" "the port's record keeps the whole marker"

# 6. the dedup stamps: a stale pane hash goes, an older stamp is overwritten
reset_sides
seed .seen-hash-c2 'old-hash\n'
seed .seen-c2 'done: older words\n'
same c2 'blocked: waiting on the captain'
assert_eq "$(shim_tree)" "== ./.seen-c2
blocked: waiting on the captain
== ./.wake-spool
== ./.wake-spool/1700000000123456789.PID.000000
1700000000	report	c2	blocked: waiting on the captain" "the hash stamp is gone and the marker stamp replaced"

# 7. ids: `/` cannot be stamped (nothing written); `..` and spaces are stamped as spelled
reset_sides
# Named divergence: the original dies on the shell's own redirection line; the
# port names the stamp it could not write. Same exit, same empty tree.
ERR=own same a/b 'done: slash'
assert_contains "$(oracle_err)" "line 83: STATE/.seen-a/b: No such file or directory" "the original's redirection noise"
assert_eq "$(shim_err)" "ERROR: cannot write the dedup stamp STATE/.seen-a/b: ENOENT" "the port's refusal"
assert_eq "$(shim_tree)" "" "nothing is written when the stamp fails"
same .. 'done: dots'
assert_contains "$(shim_tree)" "== ./.seen-..
done: dots" "id .. stamps .seen-.."
same 'a b' 'done: spaces'
assert_contains "$(shim_tree)" "== ./.seen-a b
done: spaces" "an id with spaces stamps as spelled"
assert_contains "$(shim_tree)" "	a b	done: spaces" "and is the record's id field"

# 8. an unwritable state dir: the stamp fails first, nothing published (skipped as root)
if [ "$(id -u)" != 0 ]; then
  reset_sides
  chmod 555 "$OS" "$NS"
  ERR=own same c8 'done: read-only'
  chmod 755 "$OS" "$NS"
  assert_contains "$(oracle_err)" "line 83: STATE/.seen-c8: Permission denied" "the original's redirection noise"
  assert_eq "$(shim_err)" "ERROR: cannot write the dedup stamp STATE/.seen-c8: EACCES" "the port's refusal"
  assert_eq "$(shim_tree)" "" "an unwritable state dir gets no stamp and no record"
fi

# 9. the clock: garbage refuses AFTER the stamp (deliberate) with no litter; a
#    date without %N keeps its literal N in the name and ten digits in the record
reset_sides
STUB_STAMP=garbage same c9 'done: broken clock'
assert_eq "$(shim_err)" "ERROR: wake NOT published for c9 - the completion is not durable; say so in the pane" "a broken clock refuses loudly"
assert_eq "$(shim_tree)" "== ./.seen-c9
done: broken clock" "the stamp has already advanced; no record, no litter"
reset_sides
STUB_STAMP=1700000000N same c9 'done: second resolution'
assert_eq "$(shim_tree)" "== ./.seen-c9
done: second resolution
== ./.wake-spool
== ./.wake-spool/1700000000N.PID.000000
1700000000	report	c9	done: second resolution" "the literal N stays in the name, the record's stamp is ten digits"
# EEXIST stepping: the after-write seam's hook plants `<stamp>.<its parent's
# pid>.000000` - its parent IS the publisher on both sides - so the link
# collides and the record lands at 000001.
reset_sides
cat >"$TMP/plant" <<EOF
#!/bin/sh
mkdir -p "\$AC_FLEET_STATE/.wake-spool"
: >"\$AC_FLEET_STATE/.wake-spool/\$STUB_STAMP.\$PPID.000000"
EOF
chmod +x "$TMP/plant"
AC_WAKE_SEAM_AT=after-write AC_WAKE_SEAM_RUN="$TMP/plant" same c9 'done: stepped'
assert_eq "$(shim_tree)" "== ./.seen-c9
done: stepped
== ./.wake-spool
== ./.wake-spool/1700000000123456789.PID.000000
== ./.wake-spool/1700000000123456789.PID.000001
1700000000	report	c9	done: stepped" "a taken name is stepped past to 000001"

# 10. the spool path taken by a FILE: mkdir's own line, the refusal, the stamp
#     written and the record RETAINED as .wake-tmp.* litter
reset_sides
seed .wake-spool ''
same c10 'done: spool is a file'
assert_eq "$(shim_err)" "mkdir: STATE/.wake-spool: File exists
ERROR: wake NOT published for c10 - the completion is not durable; say so in the pane" "mkdir's line then the refusal"
assert_eq "$(shim_tree)" "== ./.seen-c10
done: spool is a file
== ./.wake-spool
== ./.wake-tmp.RANDOM
1700000000	report	c10	done: spool is a file" "one .wake-tmp.* holds the record"

# 11. lock-file shapes that are no watcher: trailing space, leading 0, letters,
#     empty, no pid file, no lock dir
reset_sides
for shape in "$$ " "0$$" abc ""; do
  seed .watch.lock.d/pid "$shape"
  same c11 'done: odd pid file'
  assert_contains "$(shim_out)" "no armed watcher for this scope" "pid file '$shape' is no watcher"
done
rm -f "$OS/.watch.lock.d/pid" "$NS/.watch.lock.d/pid"
same c11 'done: no pid file'
assert_contains "$(shim_out)" "no armed watcher for this scope" "a lock dir with no pid file"
rm -rf "$OS/.watch.lock.d" "$NS/.watch.lock.d"
same c11 'done: no lock dir'
assert_contains "$(shim_out)" "no armed watcher for this scope" "no lock dir at all"

# 12. a live stand-in with a poll sleep, one per side (a nudge ends it)
mkdir -p "$TMP/dfake"
cat >"$TMP/dfake/ac-watch.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30 &
wait $! 2>/dev/null || true
printf 'wait ended\n' >"$1"
EOF
chmod +x "$TMP/dfake/ac-watch.sh"
arm_side() {  # arm_side <lockdir> <flag> - a stand-in watcher, its pid where ac-watch.sh publishes it
  bash "$TMP/dfake/ac-watch.sh" "$2" >/dev/null 2>&1 &
  armed_pid=$!
  mkdir -p "$1"
  printf '%s\n' "$armed_pid" >"$1/pid"
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -n "$(pgrep -P "$armed_pid" 2>/dev/null || true)" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "the differential stand-in never started its sleep child"
}
woke() {  # woke <flag> - the stand-in's wait ended within 5s
  local i=0
  while [ ! -f "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  assert_file "$1" "the nudge ended the stand-in's wait"
}
reset_sides
arm_side "$OS/.watch.lock.d" "$TMP/o.woke"; o_pid=$armed_pid
arm_side "$NS/.watch.lock.d" "$TMP/n.woke"; n_pid=$armed_pid
same c12 'done: nudge me'
assert_eq "$(shim_out)" "pushed c12 scope=fleet - nudged watcher pid=P (poll sleep C ended early)" "the nudged line"
woke "$TMP/o.woke"; woke "$TMP/n.woke"
wait "$o_pid" "$n_pid" 2>/dev/null || true
rm -f "$TMP/o.woke" "$TMP/n.woke"
rm -rf "$OS/.watch.lock.d" "$NS/.watch.lock.d"

# 13. a watcher whose child is not a sleep (one stand-in serves both sides);
#     a REUSED pid (a bare sleep); a dead pid
reset_sides
cat >"$TMP/dfake/ac-watch.sh" <<'EOF'
#!/usr/bin/env bash
tail -f /dev/null &
wait $! 2>/dev/null || true
EOF
bash "$TMP/dfake/ac-watch.sh" >/dev/null 2>&1 & busy_pid=$!
i=0; child=""
while [ "$i" -lt 50 ]; do
  child="$(pgrep -P "$busy_pid" 2>/dev/null || true)"
  [ -n "$child" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$child" ] || fail "the busy stand-in never started its child"
seed .watch.lock.d/pid "$busy_pid\n"
same c13 'done: mid-poll'
assert_eq "$(shim_out)" "pushed c13 scope=fleet - watcher pid=P is mid-poll, nothing to nudge - the record waits in the spool" "the mid-poll line"
sleep 0.3
kill -0 "$child" 2>/dev/null || fail "a non-sleep child must NEVER be signalled (differential)"
kill "$busy_pid" "$child" 2>/dev/null || true
wait "$busy_pid" 2>/dev/null || true
sleep 30 >/dev/null 2>&1 & victim=$!
seed .watch.lock.d/pid "$victim\n"
same c13 'done: reused pid'
assert_contains "$(shim_out)" "no armed watcher for this scope" "a reused pid is no watcher"
sleep 0.3
kill -0 "$victim" 2>/dev/null || fail "a reused pid must NEVER be signalled (differential)"
kill "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
same c13 'done: dead pid'
assert_contains "$(shim_out)" "no armed watcher for this scope" "a dead pid is no watcher"
rm -rf "$OS/.watch.lock.d" "$NS/.watch.lock.d"

# 14. a scoped lock: its own family's push nudges it; another legal scope
#     consults only ITS lock (the fleet lock is not a fallback)
cat >"$TMP/dfake/ac-watch.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30 &
wait $! 2>/dev/null || true
printf 'wait ended\n' >"$1"
EOF
reset_sides
arm_side "$OS/.watch-only-f2.lock.d" "$TMP/o.woke"; o_pid=$armed_pid
arm_side "$NS/.watch-only-f2.lock.d" "$TMP/n.woke"; n_pid=$armed_pid
SCOPE=f2 same f2-t1 'done: scoped nudge'
assert_eq "$(shim_out)" "pushed f2-t1 scope=f2 - nudged watcher pid=P (poll sleep C ended early)" "the scoped watcher is nudged"
woke "$TMP/o.woke"; woke "$TMP/n.woke"
wait "$o_pid" "$n_pid" 2>/dev/null || true
rm -f "$TMP/o.woke" "$TMP/n.woke"
rm -rf "$OS/.watch-only-f2.lock.d" "$NS/.watch-only-f2.lock.d"
arm_side "$OS/.watch.lock.d" "$TMP/o.woke"; o_pid=$armed_pid
arm_side "$NS/.watch.lock.d" "$TMP/n.woke"; n_pid=$armed_pid
SCOPE=f3 same f3-t1 'done: other family'
assert_eq "$(shim_out)" "pushed f3-t1 scope=f3 - no armed watcher for this scope - the record waits in the spool" "a legal scope never nudges the fleet watcher"
sleep 0.3
[ ! -f "$TMP/o.woke" ] && [ ! -f "$TMP/n.woke" ] || fail "the fleet stand-ins must be left alone"
kill $(pgrep -P "$o_pid" 2>/dev/null || true) $(pgrep -P "$n_pid" 2>/dev/null || true) "$o_pid" "$n_pid" 2>/dev/null || true
wait "$o_pid" "$n_pid" 2>/dev/null || true
rm -f "$TMP/o.woke" "$TMP/n.woke"
rm -rf "$OS/.watch.lock.d" "$NS/.watch.lock.d"

# 15. two pushes of one id: the second overwrites the stamp and adds a second
#     record under its own pid, sequence 000000 again (one record per process).
#     Two same-stamp names sort by pid, which the sides do not share, so the
#     records are compared as a sorted set of bytes rather than as one tree.
reset_sides
same c15 'done: first'
TREE=bytes same c15 'done: second'
assert_eq "$(cat "$NS/.seen-c15")" "done: second" "the second push's stamp"
assert_eq "$(cat "$NS/.wake-spool"/* | LC_ALL=C sort)" "$(cat "$OS/.wake-spool"/* | LC_ALL=C sort)" "the same two records on both sides"
assert_eq "$(ls "$NS/.wake-spool" | LC_ALL=C sed -E 's/\.[0-9]+\./.PID./')" "1700000000123456789.PID.000000
1700000000123456789.PID.000000" "each record is 000000 under its own pid"

pass
