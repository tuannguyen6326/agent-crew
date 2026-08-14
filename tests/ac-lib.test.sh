#!/usr/bin/env bash
# ac-lib.test.sh - the shared wake scope helpers: spool path routing
# (incl. malformed-scope fallback), the family enumerator's glob filter
# (the fleet spool, drain claim dirs and stray files excluded), the pending
# predicate (an empty spool DIR is litter, not pending),
# roomchief liveness, the landing-overlap path-list transport (a >=2-path
# call is parsed, not fatal), and the purity contract (no helper may create
# state).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
sd="$AC_HOME/state"

lib() {
  # lib <script> - run a body with ac-lib.sh + its wake/qa sub-libs sourced
  # (audit-f3: ac_wake_*/ac_room_*/ac_roomchief_live/ac_qa_* now live in
  # ac-wake-lib.sh/ac-qa-lib.sh, not ac-lib.sh).
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-wake-lib.sh'; . '$BIN/ac-qa-lib.sh'; $1"
}

# --- ac_wake_spool_path: scope -> spool dir ---------------------------------

assert_eq "$(lib "ac_wake_spool_path '$sd' ''")" "$sd/.wake-spool" \
  "empty scope routes to the fleet spool"
assert_eq "$(lib "ac_wake_spool_path '$sd' 'fam1'")" "$sd/.wake-spool.fam1" \
  "valid scope routes to its family spool"
assert_eq "$(lib "ac_wake_spool_path '$sd'")" "$sd/.wake-spool" \
  "absent scope argument routes to the fleet spool"
# A malformed scope must never build a stray path segment: fall back to fleet.
assert_eq "$(lib "ac_wake_spool_path '$sd' 'foo/bar'")" "$sd/.wake-spool" \
  "slash-bearing scope falls back to the fleet spool"
assert_eq "$(lib "ac_wake_spool_path '$sd' 'a.b'")" "$sd/.wake-spool" \
  "dot-bearing scope falls back to the fleet spool"
assert_eq "$(lib "ac_wake_spool_path '$sd' '../evil'")" "$sd/.wake-spool" \
  "traversal scope falls back to the fleet spool"
assert_eq "$(lib "ac_wake_spool_path '$sd' 'a b'")" "$sd/.wake-spool" \
  "space-bearing scope falls back to the fleet spool"
assert_eq "$(lib "ac_wake_spool_path '$sd' 'A-Za-z_0-9'")" "$sd/.wake-spool.A-Za-z_0-9" \
  "the full legal family charset routes to its family spool"

# --- ac_watcher_beat_path: scope -> beacon file ----------------------------

assert_eq "$(lib "ac_watcher_beat_path '$sd' ''")" "$sd/.last-watcher-beat" \
  "empty scope reads the fleet beacon"
assert_eq "$(lib "ac_watcher_beat_path '$sd' 'fam1'")" "$sd/.last-watcher-beat.fam1" \
  "scoped watcher stamps its own beacon"
assert_eq "$(lib "ac_watcher_beat_path '$sd' 'foo/bar'")" "$sd/.last-watcher-beat" \
  "malformed scope falls back to the fleet beacon"

# --- ac_wake_family_spools: the family enumerator ---------------------------

# Seed: two real family spools, a family literally NAMED spool (a bare token -
# legal; tokens can never be blacklisted, only namespaces separate), the fleet
# spool, a drain claim dir and a stray file in the namespace.
mkdir -p "$sd/.wake-spool" "$sd/.wake-spool.fam1" "$sd/.wake-spool.fam2" \
  "$sd/.wake-spool.spool" "$sd/.wake-spool-draining.4242"
: >"$sd/.wake-spool.strayfile"

# Bare family spool DIRS only - the fleet spool (no dot suffix) and the claim
# dirs (dash, not dot) are outside the glob structurally, and a stray FILE in
# the namespace is excluded by [ -d ].
spools="$(lib "ac_wake_family_spools '$sd'" | sed "s|^$sd/||" | sort | tr '\n' ' ')"
assert_eq "$spools" ".wake-spool.fam1 .wake-spool.fam2 .wake-spool.spool " \
  "spool enumerator keeps bare family dirs only (incl. one named 'spool')"

# The exclusions above, stated one by one so a regression names itself.
case "$spools" in
  *".wake-spool-draining.4242"*) fail "a drain claim dir must not enumerate as a family" ;;
  *".wake-spool.strayfile"*) fail "a stray FILE in the namespace is not a family spool" ;;
  *".wake-spool "*) fail "the fleet spool itself is not a family spool" ;;
esac
rm -rf "$sd"/.wake-spool*

# Nullglob-safe: a state dir with no family spools enumerates NOTHING.
empty="$TMP/emptystate"
mkdir -p "$empty"
assert_eq "$(lib "ac_wake_family_spools '$empty'" | wc -l | tr -d ' ')" "0" \
  "no family spools -> no output (nullglob-safe, no literal glob)"

# --- EINTR-safety: the two loop emitters must survive a signal mid-write ----
#
# ac_wake_family_spools (the producer) and ac_wake_orphan_files (the
# consumer) each used to emit their list with one printf PER entry inside
# their loop, unretried - a real ac-wake-drain.sh run hit "printf: write
# error: Interrupted system call" (EINTR) there twice (bash builtins write
# via direct write(), not libc stdio buffering: repo-knowledge, src:
# tests/run-suite.sh:93). Under the set -e every real caller runs under
# (lib() above included), an interrupted printf's nonzero status aborts the
# REST of the enumeration silently - errexit does not fire on a command used
# as an if/while/until CONDITION, so a retrying `until printf ...; do ...;
# done` sidesteps it, but a bare `printf` statement in a for/while BODY does
# not.
#
# Reproduced with a REAL blocked write, not a stub: the target's stdout goes
# to a FIFO whose only reader holds the read end open without ever draining
# it, so once the accumulated output exceeds the pipe's kernel buffer the
# write genuinely blocks. A trapped SIGUSR1 (no-op handler, so the writer
# survives to prove what happens next) is delivered once the writer is
# confirmed still alive; 2000 family dirs under a mktemp path comfortably
# exceed any real pipe capacity well before the last entry, which is what
# makes "still alive after a moment" a reliable block signal instead of a
# race on fork/exec - the same role the precedent fixture's `ps -o comm=`
# poll plays for its own child (repo-knowledge "DIAGNOSED+FIXED the
# run-suite signal-fixture flake", src: tests/run-suite.test.sh:112).
#
# Assertion is COMPLETENESS (every expected entry present), not exact set
# equality: this bash/kernel combination measurably (verified live, retried
# 3.2.57(1)-release arm64-apple-darwin24) sometimes reports EINTR on a write
# that had ALREADY landed - a false failure - so a retry can rarely re-emit
# an already-delivered line. That duplicate is harmless to every real
# consumer (each acts per family, and re-draining an already-drained spool
# is a no-op) and is not the defect this task fixes - the defect is a
# MISSING line, never an extra one.
eintr_emit() {
  # eintr_emit <fn-call> - run <fn-call> (a full statement invoking one of
  # the two loop emitters) with its stdout piped through a withheld FIFO,
  # interrupt it mid-write with a trapped SIGUSR1 once confirmed blocked,
  # then drain and print whatever eventually arrived.
  local body="$1" fifo="$TMP/eintr.fifo" out="$TMP/eintr.out" wpid rpid tries=0
  rm -f "$fifo" "$out"
  mkfifo "$fifo"
  set -m
  # Reader: opens the FIFO (pairs with the writer's own open below), then
  # withholds every byte long enough to cover the confirm+signal steps,
  # draining only afterward - the non-consuming hold this reproduction
  # depends on.
  bash -c "exec 3<'$fifo'; sleep 1; cat <&3 >'$out'" &
  rpid=$!
  bash -c "set -euo pipefail
    . '$BIN/ac-lib.sh'; . '$BIN/ac-wake-lib.sh'
    trap ':' USR1
    $body" >"$fifo" 2>/dev/null &
  wpid=$!
  sleep 0.5
  kill -0 "$wpid" 2>/dev/null \
    || fail "eintr_emit: producer finished before it could block - raise the volume"
  kill -USR1 "$wpid" 2>/dev/null || true
  # Bounded wait for the producer to settle (errexit-killed, or - once fixed -
  # still retrying); never unbounded (host-impact rule).
  while kill -0 "$wpid" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -ge 40 ] && break
    sleep 0.05
  done
  wait "$rpid" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  set +m
  cat "$out" 2>/dev/null
}

eintr_sd="$TMP/eintr-state"
mkdir -p "$eintr_sd"
eintr_expected="$TMP/eintr-expected"
: >"$eintr_expected"
for n in $(seq 1 2000); do
  d="$eintr_sd/.wake-spool.f$(printf '%04d' "$n")"
  mkdir -p "$d"
  printf '%s\n' "$d" >>"$eintr_expected"
done
sort -o "$eintr_expected" "$eintr_expected"

missing="$(comm -23 "$eintr_expected" <(eintr_emit "ac_wake_family_spools '$eintr_sd'" | sort -u))"
[ -z "$missing" ] || fail "ac_wake_family_spools: complete family list survives a signal delivered mid-write - missing $(printf '%s\n' "$missing" | wc -l | tr -d ' '), e.g. $(printf '%s\n' "$missing" | head -1)"
missing="$(comm -23 "$eintr_expected" <(eintr_emit "ac_wake_orphan_files '$eintr_sd'" | sort -u))"
[ -z "$missing" ] || fail "ac_wake_orphan_files: complete orphan list survives a signal delivered mid-write (no backend sourced -> every entry reads not-live, i.e. orphaned) - missing $(printf '%s\n' "$missing" | wc -l | tr -d ' '), e.g. $(printf '%s\n' "$missing" | head -1)"

rm -rf "$eintr_sd" "$eintr_expected" "$TMP/eintr.fifo" "$TMP/eintr.out"

# Retry EXHAUSTION on one entry must skip only that entry, never abort the
# rest of the enumeration - the same defect this task fixes, one level up,
# if a bare `return` replaced the retry loop's `break`. Deterministic, no
# signal/timing involved: shadow the printf builtin so ONE specific line
# always fails, and prove every OTHER entry - including ones that glob
# AFTER it - still gets out.
exdir="$TMP/exhaust-state"
mkdir -p "$exdir/.wake-spool.famA" "$exdir/.wake-spool.famB" "$exdir/.wake-spool.famC"
exhaust_out="$(bash -c "
  set -euo pipefail
  . '$BIN/ac-lib.sh'; . '$BIN/ac-wake-lib.sh'
  printf() {
    if [ \"\$1\" = '%s\n' ] && [ \"\$2\" = '$exdir/.wake-spool.famB' ]; then
      return 1
    fi
    command printf \"\$@\"
  }
  ac_wake_family_spools '$exdir'
" 2>/dev/null)" || true
assert_contains "$exhaust_out" "$exdir/.wake-spool.famA" \
  "retry exhaustion on famB must not drop famA (glob-earlier)"
assert_contains "$exhaust_out" "$exdir/.wake-spool.famC" \
  "retry exhaustion on famB must not drop famC (glob-later - the return-vs-break regression)"
case "$exhaust_out" in
  *".wake-spool.famB"*) fail "famB itself (the one entry that truly exhausted retries) must still be absent" ;;
esac
rm -rf "$exdir"

# --- ac_spool_has_record: the one spool-non-emptiness predicate --------------

# The primitive behind ac_wake_pending, ac_wake_orphan_pending and the drain's
# "anything here?": given the GLOBBED spool entries, 0 iff at least one names an
# existing record. An empty (or absent) spool expands to the literal glob, which
# [ -e ] reads as absent - never the [ -s ]-on-a-dir trap.
hr="$TMP/hasrec"
mkdir -p "$hr"
assert_fails lib "ac_spool_has_record '$hr'/*"
assert_fails lib "ac_spool_has_record '$TMP/nosuchspool'/*"
printf '1\treport\tt1\tdone: x\n' >"$hr/1.1.000000"
lib "ac_spool_has_record '$hr'/*" || fail "a spool holding a record reads present"

# --- ac_wake_pending: the one per-scope non-emptiness predicate --------------

# A spool record reads pending; an EMPTY spool dir is litter, not pending -
# the [ -s ]-on-a-directory trap ([ -s ] is true for any dir) must never leak
# in here.
pd="$TMP/pendstate"
mkdir -p "$pd"
assert_fails lib "ac_wake_pending '$pd' ''"
mkdir -p "$pd/.wake-spool"
assert_fails lib "ac_wake_pending '$pd' ''"
printf '1\treport\tt1\tdone: x\n' >"$pd/.wake-spool/1.1.000000"
lib "ac_wake_pending '$pd' ''" || fail "a fleet spool record reads pending"
rm -f "$pd/.wake-spool/1.1.000000"
assert_fails lib "ac_wake_pending '$pd' ''"
mkdir -p "$pd/.wake-spool.fam1"
printf '1\treport\tfam1-t1\tdone: y\n' >"$pd/.wake-spool.fam1/1.1.000000"
lib "ac_wake_pending '$pd' 'fam1'" || fail "a family spool record reads pending for its own scope"
assert_fails lib "ac_wake_pending '$pd' ''"

# --- ac_roomchief_live: meta + window, both signals ------------------------

stub="$TMP/stubbin"
mkdir -p "$stub"
# Stub herdr: `pane get` succeeds exactly when the sentinel exists, so a
# test drives chief liveness with a file and no real backend, no sleep.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
# Liveness only: `pane get <p>` succeeds iff the sentinel exists.
if [ "${1:-} ${2:-}" = "pane get" ]; then
  [ -e "$AC_HOME/state/.mock-win-${3:-}" ] || exit 1
fi
exit 0
EOF
chmod +x "$stub/herdr"

live() {
  # live <fam> - ac_roomchief_live under the stub backend; prints live|dead.
  PATH="$stub:$PATH" bash -c "
    set -uo pipefail
    . '$BIN/ac-lib.sh'; . '$BIN/ac-wake-lib.sh'; . '$BIN/ac-backend.sh'
    if ac_roomchief_live '$sd' '$1'; then printf 'live\n'; else printf 'dead\n'; fi"
}

# meta ABSENT (teardown archived it) -> NOT LIVE, without probing a backend.
rm -f "$sd/famL-chief.meta" "$sd/.mock-win-famL-chief"
assert_eq "$(live famL)" "dead" "meta archived -> not live (drainable orphan)"

# meta PRESENT + window alive -> LIVE.
printf 'window=crew:famL-chief\nbackend=herdr\n' >"$sd/famL-chief.meta"
printf 'famL-chief t0\n' >"$sd/.pane-famL-chief"
: >"$sd/.mock-win-famL-chief"
assert_eq "$(live famL)" "live" "meta present + window alive -> live"

# meta PRESENT + window dead -> NOT LIVE.
rm -f "$sd/.mock-win-famL-chief"
assert_eq "$(live famL)" "dead" "meta present + window dead -> not live"

# Fail-safe: with no backend layer sourced at all, a family reads NOT LIVE
# (an orphan drains to the fleet chief - a wake is never stranded silently).
: >"$sd/.mock-win-famL-chief"
assert_eq "$(PATH="$stub:$PATH" bash -c "
  set -uo pipefail
  . '$BIN/ac-lib.sh'
  . '$BIN/ac-wake-lib.sh'
  if ac_roomchief_live '$sd' 'famL'; then printf 'live\n'; else printf 'dead\n'; fi")" \
  "dead" "no backend layer sourced -> not live (fail-safe, never stranded)"
rm -f "$sd/famL-chief.meta" "$sd/.mock-win-famL-chief"

# --- lock primitives: liveness, staleness, owner-checked release -----------

# ac_pid_alive prefers `ps` because bare `kill -0` reports EPERM (a process this
# user may not signal) as DEAD; restricted runtimes exercise the guarded
# fallback below.
lib "ac_pid_alive $$" || fail "ac_pid_alive: a live pid reads alive"
sleep 0 & gone=$!
wait "$gone" 2>/dev/null || true
assert_fails lib "ac_pid_alive $gone"
assert_fails lib 'ac_pid_alive ""'
assert_fails lib 'ac_pid_alive 0'
assert_fails lib 'ac_pid_alive 00'
# The EPERM shape - the ONLY reason this helper exists. A pid that is alive but
# NOT ours to signal answers rc=1 to `kill -0` (permission denied reads as
# dead) and rc=0 to `ps`. Without this case, `kill -0` and `ps` are
# indistinguishable here and the whole point of the helper is untested.
# pid 1 (launchd/init) is the portable instance; skipped, never faked, where
# the shape cannot exist (running as root, or a PID-namespaced pid 1).
if ps -p 1 >/dev/null 2>&1 && ! kill -0 1 2>/dev/null; then
  lib "ac_pid_alive 1" \
    || fail "ac_pid_alive: a LIVE pid we may not signal (EPERM) must read alive, not dead"
else
  printf 'SKIP: no EPERM shape on this platform (pid 1 is signalable here)\n' >&2
fi
# The verifier lock near-miss: in restricted harnesses, `ps -p <live pid>` can
# itself be denied. A denied ps must not turn a LIVE owner into a stale lock,
# but dead pids still have to self-heal through kill -0's ESRCH.
ps_deny_bin="$TMP/ps-deny-bin"
mkdir -p "$ps_deny_bin"
cat >"$ps_deny_bin/ps" <<'EOF'
#!/usr/bin/env bash
printf 'ps: Operation not permitted\n' >&2
exit 126
EOF
chmod +x "$ps_deny_bin/ps"
PATH="$ps_deny_bin:$PATH" lib "ac_pid_alive $$" \
  || fail "ac_pid_alive: ps denial for a live pid must fail closed as alive"
assert_fails env PATH="$ps_deny_bin:$PATH" "$BASH" -c ". '$BIN/ac-lib.sh'; ac_pid_alive '$gone'"

# ac_file_mtime: epoch seconds, and portable - BSD `stat -f` and GNU `stat -c`
# disagree, and the losing form must not leak its output into the winner's.
mstamp="$TMP/mtime-probe"
: >"$mstamp"
# TZ pinned: `touch -t` reads its stamp in the LOCAL zone, so an unpinned
# stamp asserts a different epoch on every machine.
TZ=UTC touch -t 202001010000 "$mstamp"
assert_eq "$(lib "ac_file_mtime '$mstamp'")" "1577836800" "ac_file_mtime prints a plain epoch stamp"
assert_fails lib "ac_file_mtime '$TMP/definitely-absent'"

# ac_lock_stale - the ONE staleness rule the reclaim path acts on.
sd_l="$TMP/lockstate"
mkdir -p "$sd_l"
stale() {
  # stale <lockdir> - prints stale|held.
  if lib "ac_lock_stale '$1'"; then printf 'stale\n'; else printf 'held\n'; fi
}
mkdir -p "$sd_l/live.d"
printf '%s\n' "$$" >"$sd_l/live.d/pid"
assert_eq "$(stale "$sd_l/live.d")" "held" "a live owner pid is never stale"
mkdir -p "$sd_l/dead.d"
printf '%s\n' "$gone" >"$sd_l/dead.d/pid"
assert_eq "$(stale "$sd_l/dead.d")" "stale" "a dead owner pid is stale"
# Absent/empty pid file: the shape an external kill leaves between `mkdir` and
# the `printf` that publishes the pid. Only AGE separates that corpse from a
# live acquirer still inside the same window, so young fails closed.
mkdir -p "$sd_l/young.d"
assert_eq "$(stale "$sd_l/young.d")" "held" "a young pid-less lock dir is a live acquirer, not stale"
mkdir -p "$sd_l/aged.d"
touch -t 202001010000 "$sd_l/aged.d"
assert_eq "$(stale "$sd_l/aged.d")" "stale" "an aged pid-less lock dir is stale"
mkdir -p "$sd_l/emptypid.d"
: >"$sd_l/emptypid.d/pid"
touch -t 202001010000 "$sd_l/emptypid.d"
assert_eq "$(stale "$sd_l/emptypid.d")" "stale" "an aged EMPTY pid file is stale like an absent one"
# A garbage pid file is corruption, not a holder.
mkdir -p "$sd_l/junk.d"
printf 'not-a-pid\n' >"$sd_l/junk.d/pid"
assert_eq "$(stale "$sd_l/junk.d")" "stale" "a garbage pid file is stale"
# An unstattable lock dir must never read stale (fail closed).
assert_eq "$(stale "$sd_l/never-existed.d")" "held" "an unstattable lock dir is never stale"

# ac_lock_release only removes a lock this process still OWNS. The reclaim
# path (rm -rf + re-mkdir) can hand the dir to another acquirer between our
# acquire and our release; a blind `rm -rf` would then delete a LIVE holder's
# lock and let a third acquirer in.
mkdir -p "$sd_l/foreign.d"
printf '424242\n' >"$sd_l/foreign.d/pid"
lib "ac_lock_release '$sd_l/foreign.d'"
assert_file "$sd_l/foreign.d/pid" "release never deletes a lock another pid owns"
lib "ac_lock_acquire '$sd_l/mine.d' 0; ac_lock_release '$sd_l/mine.d'"
assert_no_file "$sd_l/mine.d" "release removes the lock this process does own"
mkdir -p "$sd_l/nopid.d"
lib "ac_lock_release '$sd_l/nopid.d'"
assert_no_file "$sd_l/nopid.d" "a pid-less lock dir is still releasable (unchanged)"

# --- ac_now: $EPOCHSECONDS (bash 5+, no fork) with a date +%s fallback ------

# Item 4 (perf audit): ac-watch.sh's poll loop calls ac_now() several times
# per pane per tick, each forking `date +%s`. Bash 5's $EPOCHSECONDS is a
# builtin, no fork - referenced fresh each time, not a shell-startup
# snapshot, so it stays a live clock read wherever it exists. When set (bash
# 5+, or here just a caller-set var - ${VAR:-fallback} does not care why it
# is set) ac_now must use it and never fork date.
assert_eq "$(lib "EPOCHSECONDS=1234567890 ac_now")" "1234567890" \
  "ac_now uses \$EPOCHSECONDS when present, never forking date"

# When EPOCHSECONDS is unset (bash < 5 - this host's own /bin/bash is 3.2.57
# and exercises exactly this path), ac_now must fall back to `date +%s` and
# stay a live clock read, not a stale/fixed value.
now_real="$(date +%s)"
now_ac="$(lib "unset EPOCHSECONDS; ac_now")"
diff=$(( now_ac - now_real ))
[ "$diff" -ge -2 ] && [ "$diff" -le 2 ] || \
  fail "ac_now (EPOCHSECONDS unset) should read close to date +%s: got $now_ac vs $now_real"

# --- ac_landing_overlaps: the path list reaches awk intact ------------------

# The list must never travel through `-v`: awk rejects a literal newline in a
# -v assignment and exits 2, which made the check FATAL for every land
# touching >=2 files (it is the RHS of a final `||`, where set -e is not
# suspended). ONE path hid the bug - the command substitution strips the lone
# trailing newline, so the list arrived newline-free.
now_l="$(date +%s)"
printf '%s\tfam-a\tone.txt\n%s\tfam-b\ttwo.txt\n%s\tfam-c\tthree.txt\n' \
  "$((now_l - 3600))" "$((now_l - 7200))" "$((now_l - 60))" >"$sd/.landings"
hits="$(lib "ac_landing_overlaps 86400 '' one.txt two.txt")" \
  || fail "ac_landing_overlaps: a >=2-path call must be PARSED, not fatal"
# Family and path only: the age column is recomputed against the function's
# own ac_now, so pinning it verbatim would flake on a second boundary.
assert_eq "$(printf '%s\n' "$hits" | awk -F'\t' '{ printf "%s %s ", $1, $3 }')" \
  "fam-a one.txt fam-b two.txt " \
  "a >=2-path list is parsed: both matches print, the unasked path stays out"

# --- ac_landing_record: concurrent landings keep BOTH families' records -----
#
# The ledger's write is a read-modify-write (prune to tmp, append, mv), and
# with room-parallel roomchiefs landing autonomously two of them run it at
# once: both read the ledger before either commits, and the second mv discards
# the first's records. Nothing fails - the <24h LANDING-OVERLAP warn just
# silently stops firing for the lost files, which is the ledger's whole point.
#
# The interleaving is FORCED, never raced for: `mv` is shadowed with a
# sleeping wrapper in each writer's own shell, which widens exactly the
# window between the read and the commit and holds everything else constant.
# Unserialized, the second writer's read predates the first's mv by
# construction.
rm -f "$sd/.landings"
land_slow() {
  # land_slow <family> <path> <mv-delay-secs> - one ac_landing_record whose
  # commit is delayed, run in its own process (the writers are processes).
  bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    mv() { sleep $3; command mv \"\$@\"; }
    ac_landing_record '$1' '$2'"
}
land_slow fam-x x.txt 2 &
sleep 0.3                       # inside fam-x's widened window, before its mv
land_slow fam-y y.txt 0 &
wait
assert_eq "$(awk -F'\t' '$2 == "fam-x"' "$sd/.landings" | wc -l | tr -d ' ')" "1" \
  "the slower concurrent landing's record survives"
assert_eq "$(awk -F'\t' '$2 == "fam-y"' "$sd/.landings" | wc -l | tr -d ' ')" "1" \
  "the faster concurrent landing's record survives too"
rm -f "$sd/.landings"

# --- ac_orphan_snapshot_scan: the orphan-busy-loop detection backstop -------
#
# Surfaces ppid==1 Claude shell-snapshot processes burning CPU - the incident
# was a `jobs -p` cleanup that reaped nothing and left 77 busy loops at ~760%
# CPU. ps is FAKED: the host-impact law forbids spawning real hogs to test
# load detection, so the one seam (ac_orphan_snapshot_ps) is shadowed with a
# canned table on stdin.
scan() {
  # scan - run the detector with the ps table read from stdin (the fixture).
  bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    ac_orphan_snapshot_ps() { cat; }
    ac_orphan_snapshot_scan"
}
hdr='  PID  PPID  %CPU COMMAND'
snap='/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval while : ; do : ; done'

# Fires on an orphan busy loop: ppid==1, high cpu, snapshot command.
out="$(printf '%s\n%s\n' "$hdr" " 1834     1  99.0 $snap" | scan)"
assert_contains "$out" "WARNING" "detector fires on an orphaned snapshot busy loop"
assert_contains "$out" "1 orphaned" "one orphan counted"

# Silent otherwise - each of these is a false-alarm path that would scream
# every healthy session and MUST be ignored: a LIVE snapshot shell (ppid != 1,
# the normal running tool shell); an IDLE orphan (ppid==1 but ~0% cpu, nothing
# burning); a high-cpu NON-snapshot process (ppid==1 but not ours to flag).
clean="$(printf '%s\n%s\n%s\n%s\n' "$hdr" \
  " 2001  1500  95.0 $snap" \
  " 2002     1   0.0 $snap" \
  " 2003     1  99.0 /usr/sbin/somedaemon --busy" | scan)"
assert_eq "$clean" "" "detector is silent when no orphan snapshot is burning cpu"

# Counts every orphan, not just the first.
two="$(printf '%s\n%s\n%s\n' "$hdr" \
  " 3001     1  99.0 $snap" \
  " 3002     1  88.0 $snap" | scan)"
assert_contains "$two" "2 orphaned" "both orphans are counted"

# --- purity: no helper may create state ------------------------------------

# Every helper must be callable from the read-only ac-fleets.sh and from the
# mkdir-avoiding turnend guard, so none of them may mkdir or touch anything.
ghost="$TMP/ghoststate"
lib "ac_wake_spool_path '$ghost' 'fam1'" >/dev/null
lib "ac_wake_spool_path '$ghost' ''" >/dev/null
lib "ac_watcher_beat_path '$ghost' 'fam1'" >/dev/null
lib "ac_wake_family_spools '$ghost'" >/dev/null
lib "ac_wake_pending '$ghost' 'fam1'" >/dev/null || true
lib "ac_roomchief_live '$ghost' 'fam1'" >/dev/null || true
assert_no_file "$ghost" "path helpers create NOTHING (pure: no mkdir, no touch)"

# A config READ mints nothing either. ac_config_read used to resolve through
# ac_config_dir, whose mkdir grew a stray config/ inside every checkout and
# pool worktree a homeless pane agent read a knob from.
noconf="$TMP/nohome"
mkdir -p "$noconf"
assert_eq "$(AC_HOME="$noconf" bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_config_read model deflt")" \
  "deflt" "ac_config_read answers the default for an absent knob"
assert_no_file "$noconf/config" "ac_config_read creates no config/ (a READ mints nothing)"

# --- ac_fleet_name: the fleet token in a herdr workspace label --------------

# The label must never be DERIVED from whichever checkout happens to own bin/.
# Pane agents run from crewmate panes, which carry no AC_HOME by design
# (ac-qa.sh header); before ac_home refused, its ac_root fallback named the group after a
# pool worktree ("1 (pane-agent)") or the distro repo ("agent-crew
# (pane-agent)") - a bogus group per repo, growing run after run.
assert_eq "$(lib "ac_fleet_name")" "home" "AC_HOME names the fleet"

# AC_HOME outranks the threaded name: a home in THIS process is first-hand
# evidence of the fleet it belongs to, while AC_FLEET_NAME is the hand-me-down
# for callers that have none. A crewdeputy pane is launched with its OWN
# AC_HOME and must group under its own fleet, whatever name ever reached it.
assert_eq "$(AC_FLEET_NAME=other lib "ac_fleet_name")" "home" \
  "AC_HOME outranks the threaded fleet name"

# The homeless rung runs from a $TMP COPY of bin/, never $BIN. Defect class,
# now closed at its source: with AC_HOME unset ac_home() ANSWERED ac_root() -
# the checkout owning the bin/ being sourced - so any ac_{config,state,data}_dir
# call on that path did its mkdir -p inside a REAL checkout (the config/ litter 82afdc0 retired in
# tests/ac-qa.test.sh, and tests/ac-pane-agent.test.sh before it). Here the
# leak is LATENT, not actual: ac_fleet_name's homeless branch is a bare printf
# and sourcing ac-lib.sh mints nothing - measured, byte-identical. The copy
# means the rung can never resolve into a checkout at all.
# The fixed name is still what is proven, and MORE strictly than before: the
# fixture is deliberately not named "agent-crew", so a basename-derived answer
# reds here - against $BIN in the primary checkout it would have passed
# vacuously on that checkout's own basename.
nohome_root="$TMP/fleetname-checkout"
mkdir -p "$nohome_root/bin"
# ac-lib.sh sources its sibling harness registry (audit-f5), so the minimal
# fake checkout ships both.
cp "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$nohome_root/bin/"
snap_root_dirs() { ( cd "$ROOT" && find config state data 2>/dev/null || true ) | LC_ALL=C sort; }
root_before="$(snap_root_dirs)"
assert_eq "$(env -u AC_HOME bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; ac_fleet_name")" \
  "agent-crew" "no AC_HOME: a fixed name, never a checkout or worktree basename"
# The threaded name (ac-spawn.sh puts it on every crewmate launch line) sits
# BETWEEN those two rungs: a homeless caller that was told its fleet answers it,
# so the observation tabs a crewmate opens land in ITS fleet's workspace instead
# of the one fallback group every fleet on the box shares.
assert_eq "$(env -u AC_HOME AC_FLEET_NAME=drydock bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; ac_fleet_name")" \
  "drydock" "no AC_HOME: the threaded fleet name answers"
assert_eq "$(env -u AC_HOME AC_FLEET_NAME= bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; ac_fleet_name")" \
  "agent-crew" "an EMPTY threaded name is no name: the fallback still answers"
# Zero-writes guard, scoped to the three dirs this defect class can create:
# it reds if anyone ever points the invocation above back at $BIN.
assert_eq "$(snap_root_dirs)" "$root_before" \
  "no AC_HOME: the rung must mint nothing in the agent-crew checkout ($ROOT)"

# --- ac_home: no AC_HOME FAILS CLOSED, it never adopts the checkout ---------
# ac_home used to answer ac_root() - the checkout that owns bin/ - whenever
# AC_HOME was unset, so the DISTRO CHECKOUT silently became a fleet home and
# every ac_{state,data,records,config,projects,skills}_dir call mkdir -p'd into
# it. That phantom home accumulated a REAL fleet's runtime state (a wake spool,
# watcher beacons, whole family data dirs) in a directory no fleet's
# session-start, turn-end guard or watcher ever drains, gitignored so nothing
# surfaced it. A caller that genuinely needs a home and has none has a BUG;
# every caller that legitimately runs homeless already carries its OWN rung
# (ac_fleet_name's fixed name above, ac_home_resolve's empty answer,
# ac_config_read's default), so none of them asks ac_home at all.
# Run from the $TMP copy of bin/, never $BIN, for the same reason the
# ac_fleet_name rung above does: a regression here must not be able to write
# into a real checkout.
assert_fails_with "AC_HOME" -- \
  env -u AC_HOME bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; ac_home"
# The refusal must NAME WHAT TO SET, not merely fail: a bare non-zero exit
# leaves the operator with a homeless script and no next move.
assert_fails_with "AC_HOME=" -- \
  env -u AC_HOME bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; ac_home"
# An EMPTY AC_HOME is no home either - it took the same fallback branch.
assert_fails_with "AC_HOME" -- \
  env AC_HOME= bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; ac_home"

# The point of the refusal: the WRITE helpers can no longer mint a phantom home.
# Each is asserted on its own - they are six separate mkdir sites, and
# ac_records_dir composes its path differently from the other five.
for helper in ac_state_dir ac_data_dir ac_records_dir ac_config_dir ac_projects_dir ac_skills_dir; do
  assert_fails_with "AC_HOME" -- \
    env -u AC_HOME bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; $helper"
done
# ...in the CALLING CONTEXT that matters, not just at top level. Every real
# caller reads these helpers through `$(...)`, and in that context bash (3.2,
# measured) does NOT fire errexit for the helper's own inner assignment - so a
# guard that only aborts at top level lets the helper run on to mkdir "/state"
# and hand the caller "/state" with status 0, a filesystem-root path instead of
# a refusal. Each case asserts BOTH halves: non-zero, and NOTHING on stdout.
for helper in ac_state_dir ac_data_dir ac_records_dir ac_config_dir ac_projects_dir ac_skills_dir; do
  rc=0
  out="$(env -u AC_HOME bash -c "set -euo pipefail; . '$nohome_root/bin/ac-lib.sh'; v=\"\$($helper)\"; printf '%s' \"\$v\"" 2>/dev/null)" || rc=$?
  [ "$rc" != 0 ] || fail "$helper read through \$( ) must FAIL with no AC_HOME, not fall through"
  assert_eq "$out" "" "$helper read through \$( ) prints no path when it refuses"
done

# ...and mint nothing on the way out. $nohome_root is the checkout ac_root would
# have answered, so this is the phantom-home assertion itself.
for d in state data records config projects skills; do
  assert_no_file "$nohome_root/$d" "no AC_HOME: $d/ is never minted in the checkout"
done
assert_eq "$(snap_root_dirs)" "$root_before" \
  "no AC_HOME: the refusal mints nothing in the agent-crew checkout ($ROOT) either"

# A REAL home still resolves unchanged - the other direction, and the one that
# turns a working fleet into a dead one if the guard is too strict.
assert_eq "$(lib "ac_home")" "$AC_HOME" "a real home still resolves unchanged"
assert_eq "$(lib "ac_state_dir")" "$AC_HOME/state" "a real home still resolves state/"
assert_eq "$(lib "ac_records_dir")" "$AC_HOME/records" "a real home still resolves records/"
# A home reached through a symlink still canonicalizes (cd + pwd -P), the one
# behavior of the surviving branch this change could have dropped.
ln -s "$AC_HOME" "$TMP/home-link"
assert_eq "$(AC_HOME="$TMP/home-link" bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_home")" \
  "$AC_HOME" "a symlinked AC_HOME still canonicalizes to its real path"
# A home shaped like a bare fleet - dirs and nothing else - resolves too: the
# refusal keys on the ABSENCE OF AC_HOME, never on what the directory contains,
# so no real home can be false-refused for lacking a knob, a record or a marker.
bare_home="$TMP/bare-fleet-home"
mkdir -p "$bare_home"
assert_eq "$(AC_HOME="$bare_home" bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_home")" \
  "$bare_home" "an EMPTY directory named by AC_HOME is still a home (content is never the test)"

# --- ac_project_config_file: the retired legacy path fails CLOSED ------------
# The pipeline config lives at the canonical $AC_HOME/projects/<name>.yaml.
# The legacy config/projects/<name>.yaml location is RETIRED (audit-f7): it is
# never read, and its mere presence dies with the exact mv - a legacy-only home
# must never silently lose require_for_ship, the merge gate's reason to
# resolve this file at all.
pcf() { bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_project_config_file '$1'"; }
pcrepo="$(make_repo pcfgproj)"
pc_new="$AC_HOME/projects/pcfgproj.yaml"
pc_old="$AC_HOME/config/projects/pcfgproj.yaml"
mkdir -p "$AC_HOME/projects" "$AC_HOME/config/projects"

# NEW-only: the settled state resolves the canonical path, silently.
: >"$pc_new"; rm -f "$pc_old"
assert_eq "$(pcf "$pcrepo" 2>/dev/null)" "$pc_new" "new-only: resolves the canonical projects/ path"
assert_eq "$(pcf "$pcrepo" 2>&1 >/dev/null)" "" "new-only: no warning at the canonical path"

# LEGACY present (with or without a canonical copy): REFUSED, fail-closed,
# naming the retired path and the exact mv; nothing on stdout, no silent pick.
: >"$pc_old"
assert_fails pcf "$pcrepo"
assert_eq "$(pcf "$pcrepo" 2>/dev/null)" "" "legacy present: prints nothing - it never resolves the retired path"
leg_err="$(pcf "$pcrepo" 2>&1 >/dev/null || true)"
assert_contains "$leg_err" "RETIRED" "legacy present: the error names the path as retired"
assert_contains "$leg_err" "$pc_old" "legacy present: the error names the legacy path"
assert_contains "$leg_err" "mv " "legacy present: the error prints the migrate command"
rm -f "$pc_new"
assert_fails pcf "$pcrepo"
assert_contains "$(pcf "$pcrepo" 2>&1 >/dev/null || true)" "RETIRED" \
  "legacy-only: dies rather than silently losing the config"

# NONE: an unconfigured project returns non-zero, no output, no spurious warning.
rm -f "$pc_old"
assert_fails pcf "$pcrepo"
assert_eq "$(pcf "$pcrepo" 2>&1)" "" "none: unconfigured project is silent"

# The merge gate inherits the refusal: a legacy copy fails ac_qa_required CLOSED
# (its ac_die propagates through the direct guard), so no merge proceeds.
qreq() { bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_required '$1'"; }
printf 'qa:\n  require_for_ship: true\n' >"$pc_new"
printf 'qa:\n  require_for_ship: true\n' >"$pc_old"
# The named ac_die must SURFACE (not just any non-zero): a fail-open that merely
# returned "not required" would carry no "RETIRED", so this discriminates the
# fail-closed guard from a swallowed one - removing the direct guard reds here.
assert_contains "$(qreq "$pcrepo" 2>&1 || true)" "RETIRED" "legacy copy: ac_qa_required fails CLOSED with the named error"
rm -f "$pc_old"
qreq "$pcrepo" || fail "canonical-only: require_for_ship reads from the canonical path"
rm -f "$pc_new"

# --- ac_qa_gate_ok: the two-sided, fail-closed merge gate --------------------
# The mode is read from BOTH sides (the repo-knowledge scope map and the
# project yaml), because a map-only reading is fail-OPEN under partial
# migration: with qa.scopes in the yaml and the map absent, it classifies the
# project FLAT and accepts a legacy bare marker - at the last gate.
# These are UNIT tests and they source ac-pipeline-lib.sh themselves, so they
# would pass even with the merge helpers' source line missing. That bug is
# caught one level up, in ac-merge-local.test.sh / ac-pr-merge.test.sh, which
# drive the SCRIPTS. This is the one test whose LOCATION is load-bearing.
gate() {
  # gate <repo> <sha> - ac_qa_gate_ok with both libs loaded, output merged.
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$1' '$2'" 2>&1
}
gate_ok() { gate "$@" >/dev/null; }

grepo="$(make_repo graterepo)"
gsha="$(git -C "$grepo" rev-parse HEAD)"
gcfg="$AC_HOME/projects/graterepo.yaml"
grecdir="$AC_HOME/records/repo-knowledge"
gpassed="$grepo/.crew/qa/passed"
mkdir -p "$AC_HOME/projects" "$grecdir" "$gpassed"

flat_cfg() { printf 'qa:\n  require_for_ship: true\n  serve: "true"\n' >"$gcfg"; }
scoped_cfg() {
  printf 'qa:\n  require_for_ship: true\n  serve: "true"\n  scopes:\n    orchid:\n      seed: "true"\n' >"$gcfg"
}
declare_map() {
  { printf '# Repo knowledge: graterepo\n\n'
    printf '%s\n' "$@"
    printf '\n## Superseded\n\n'; } >"$grecdir/graterepo.md"
}
orchid_line='- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
v2_marker() {
  # v2_marker <path> <sha> <scope> <app> <profile-sha> [<e2e-sha>]
  {
    printf 'schema=agentcrew.qa-attestation/v2\noutcome=passed\n'
    printf 'run=test-run\ntask=test-task\ncompleted_at=2026-07-24T00:00:00Z\n'
    printf 'source_sha=%s\n' "$2"
    printf 'profile_key=graterepo%s\n' "$([ -n "$3" ] && printf '/%s/%s' "$3" "$4")"
    printf 'profile_sha256=%s\nconfig_sha256=config-hash\n' "$5"
    printf 'cases_passed=1\ncases_total=1\n'
    [ -z "$3" ] || { printf 'scope=%s\n' "$3"; printf 'app=%s\n' "$4"; }
    [ -z "${6:-}" ] || { printf 'e2e_repo=test-e2e\n'; printf 'e2e_sha=%s\n' "$6"; }
  } >"$1"
}
marker_parse() {
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_attestation_parse '$1' '$2' '${3:-}' '${4:-}'"
}

# AC30 + AC31(flat): a FLAT project's bare marker is accepted exactly as
# before, and its absence refuses exactly as before.
flat_cfg
rm -f "$grecdir/graterepo.md"
assert_fails bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$grepo' '$gsha'"
: >"$gpassed/$gsha"
assert_fails gate "$grepo" "$gsha"
v2_marker "$gpassed/$gsha" "$gsha" "" "" flat-profile
gate_ok "$grepo" "$gsha" || fail "AC30: a flat project's valid bare v2 marker opens the gate"

# Optional marker keys are validated by PRESENCE, not only by a non-empty
# parsed value. Empty optional fields must not masquerade as absence.
bad_marker="$TMP/qa-marker-empty-optional"
v2_marker "$bad_marker" "$gsha" "" "" flat-profile
printf 'qa_rule=\n' >>"$bad_marker"
assert_fails marker_parse "$bad_marker" "$gsha"
v2_marker "$bad_marker" "$gsha" "" "" flat-profile
printf 'e2e_repo=\ne2e_sha=\n' >>"$bad_marker"
assert_fails marker_parse "$bad_marker" "$gsha"

# Unequal or zero case counts refuse: a marker claiming 0/0 or 1/2 proved
# nothing the gate may honour.
bad_counts="$TMP/qa-marker-bad-counts"
v2_marker "$bad_counts" "$gsha" "" "" flat-profile
sed 's/^cases_passed=1$/cases_passed=0/; s/^cases_total=1$/cases_total=0/' \
  "$bad_counts" >"$bad_counts.t" && mv "$bad_counts.t" "$bad_counts"
assert_fails marker_parse "$bad_counts" "$gsha"
v2_marker "$bad_counts" "$gsha" "" "" flat-profile
sed 's/^cases_total=1$/cases_total=2/' "$bad_counts" >"$bad_counts.t" \
  && mv "$bad_counts.t" "$bad_counts"
assert_fails marker_parse "$bad_counts" "$gsha"

# The marker BODY binds scope/app: a body naming another scope/app cannot
# satisfy the expected pair (a renamed marker), and a flat marker carrying
# scope/app keys is malformed rather than quietly scoped.
mismatch="$TMP/qa-marker-scope-mismatch"
v2_marker "$mismatch" "$gsha" other other-app x-profile
assert_fails marker_parse "$mismatch" "$gsha" orchid orchid-service
flat_scoped="$TMP/qa-marker-flat-carrying-scope"
v2_marker "$flat_scoped" "$gsha" "" "" flat-profile
printf 'scope=orchid\napp=orchid-service\n' >>"$flat_scoped"
assert_fails marker_parse "$flat_scoped" "$gsha"

# AC31 + D14: the SAME bare marker on a SCOPED project REFUSES, and the
# message says the marker names no scope+app. Honouring it "for
# compatibility" would keep the gate lying for exactly the heads most likely
# to carry one.
scoped_cfg
declare_map "$orchid_line"
out="$(gate "$grepo" "$gsha")" && fail "AC31: a bare marker must not satisfy a SCOPED project's gate"
assert_contains "$out" "bare sha-only marker IS on disk" "AC31: the refusal says the marker names no profile"
assert_contains "$out" "names no scope+app" "AC31: and says why that is not enough"

# The gate CHECKS ITS OWN DEPENDENCY. The yaml side reads ac_yaml_has, which
# lives in ac-pipeline-lib.sh; in a caller that sourced only ac-lib.sh that is
# a command-not-found INSIDE an &&-list - which errexit does not catch and
# which reads exactly like "the yaml declares no scopes". With no scope map
# either, that steered a SCOPED project into the FLAT arm, where the bare
# sha-only marker below satisfies the gate: the exact fail-open the two-sided
# read exists to refuse. Both callers must refuse the SAME head.
scoped_cfg
rm -f "$grecdir/graterepo.md"
v2_marker "$gpassed/$gsha" "$gsha" "" "" flat-profile
out="$(gate "$grepo" "$gsha")" && fail "fully-loaded: a half-declared project must refuse"
assert_contains "$out" "MODE MISMATCH" "fully-loaded, the refusal is the mode-mismatch one"
out="$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$grepo' '$gsha'" 2>&1)" \
  && fail "a caller sourcing only ac-lib.sh reached the FLAT arm and accepted a bare marker"
assert_contains "$out" "ac-pipeline-lib.sh" \
  "the refusal names the sibling the caller failed to source"
rm -f "$gpassed/$gsha"
declare_map "$orchid_line"

# ...and a scope+app-bearing marker for that same head opens it, printing the
# pairs so a human judges coverage (AC26). Coverage is SURFACED, never
# adjudicated: refusing for incomplete coverage would need to know which
# scopes the head changed, which is diff derivation.
: >"$gpassed/$gsha.orchid.orchid-service"
out="$(gate "$grepo" "$gsha")" && fail "an empty scoped marker must not open the gate"
assert_contains "$out" "Malformed markers ignored" "an empty scoped marker is named as invalid"
v2_marker "$gpassed/$gsha.orchid.orchid-service" "$gsha" orchid orchid-service orchid-profile
out="$(gate "$grepo" "$gsha")" || fail "AC31: a scoped marker opens the gate for the same head"
assert_contains "$out" "passed profiles" "AC26: the gate surfaces which profiles passed"
assert_contains "$out" "orchid/orchid-service" "AC26: naming the pair"

# AC25: two runs at ONE sha for different scopes coexist - neither overwrites
# the other, and both are surfaced.
: >"$gpassed/$gsha.orchid.orchid-worker"
v2_marker "$gpassed/$gsha.orchid.orchid-worker" "$gsha" orchid orchid-worker worker-profile
out="$(gate "$grepo" "$gsha")"
assert_contains "$out" "orchid/orchid-service" "AC25: the first run's marker survives"
assert_contains "$out" "orchid/orchid-worker" "AC25: alongside the second's"

# AC26: a head with NO marker at all still refuses, exactly as today.
assert_fails bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$grepo' '0000000000000000000000000000000000000000'"

# The STRICT marker reader. Every candidate clears three tests or it is
# SKIPPED and NAMED - it can never authorise a merge, and it can never block
# one that has a genuine pair beside it.
rm -f "$gpassed/$gsha".*
mkdir -p "$gpassed/$gsha.dir.x"                      # a directory, not a file
: >"$gpassed/$gsha.orchid"                              # one component
: >"$gpassed/$gsha.a.b.c"                            # three components
: >"$gpassed/$gsha.zl p.svc"                         # outside the name grammar
out="$(gate "$grepo" "$gsha")" && fail "no malformed marker may satisfy the gate"
assert_contains "$out" "Malformed markers ignored" "a malformed marker reads as ignored, not as no run at all"
assert_contains "$out" "$gsha.orchid" "the one-component marker is named as skipped"
assert_contains "$out" "$gsha.a.b.c" "the three-component marker is named as skipped"
case "$out" in *"$gsha.dir.x"*) fail "a DIRECTORY must not even be considered a candidate" ;; esac
# ...and a genuine pair beside them still opens the gate.
: >"$gpassed/$gsha.orchid.orchid-service"
v2_marker "$gpassed/$gsha.orchid.orchid-service" "$gsha" orchid orchid-service orchid-profile
gate_ok "$grepo" "$gsha" || fail "a stray file must not block a merge that has a real pair"
rm -rf "$gpassed/$gsha.dir.x" "$gpassed/$gsha".*

# MODE MISMATCH refuses, in BOTH directions, and never falls to the FLAT arm.
# This is the state a migration passes through, and the arm r1 got fail-open.
: >"$gpassed/$gsha"
rm -f "$grecdir/graterepo.md"                        # yaml scoped, map absent
out="$(gate "$grepo" "$gsha")" && fail "scoped yaml + absent map + bare marker must REFUSE"
assert_contains "$out" "MODE MISMATCH" "the half-migrated state is named"
assert_contains "$out" "record declares NONE" "and says which side is missing"
flat_cfg
declare_map "$orchid_line"                              # map scoped, yaml flat
out="$(gate "$grepo" "$gsha")" && fail "scoped map + flat yaml must REFUSE"
assert_contains "$out" "MODE MISMATCH" "the other direction is named too"

# ...and an EMPTY `qa.scopes:` block counts as PRESENT here too. Read as
# absent, this gate lands in the FLAT arm and accepts the bare marker sitting
# right there - the half-migrated state the two-sided read exists to refuse.
printf 'qa:\n  require_for_ship: true\n  serve: "true"\n  scopes:\n' >"$gcfg"
rm -f "$grecdir/graterepo.md"
rm -f "$gpassed/$gsha".*
: >"$gpassed/$gsha"
out="$(gate "$grepo" "$gsha")" && fail "F2: an empty qa.scopes block must not reach the FLAT arm"
assert_contains "$out" "MODE MISMATCH" "an empty block is present, so the gate sees exactly one side"

# An AMBIGUOUS map refuses the merge rather than degrading - the same
# fail-closed answer `start` gives, so the two ends of the system agree.
scoped_cfg
declare_map "$orchid_line" '- scope orchid = imposter | src: cmd:true | at: deadbeef 2026-07-21 | by: forger'
out="$(gate "$grepo" "$gsha")" && fail "an ambiguous map must refuse the merge"
assert_contains "$out" "AMBIGUOUS" "the ambiguity is named at the gate too"

# AC27, asserted as an ABSENCE and deliberately: NO test here claims the gate
# refuses for incomplete coverage. Deciding which scopes a head OUGHT to have
# covered requires knowing which scopes it changed - diff derivation, which
# this system does not do. One scope's pass opens the gate for a head that
# spans two, and the chief and captain judge that with the pairs in hand.
declare_map "$orchid_line" '- scope cedar = cedar-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
printf 'qa:\n  require_for_ship: true\n  scopes:\n    orchid:\n      seed: "true"\n    cedar:\n      seed: "true"\n' >"$gcfg"
rm -f "$gpassed/$gsha"
: >"$gpassed/$gsha.orchid.orchid-service"
v2_marker "$gpassed/$gsha.orchid.orchid-service" "$gsha" orchid orchid-service orchid-profile
gate_ok "$grepo" "$gsha" || fail "AC27: one scope's pass opens the gate; coverage is the human's call"
rm -f "$gcfg" "$grecdir/graterepo.md"

# --- ac_qa_gate_ok: the required-profile MATRIX (Story 4) ---------------------
# When the task declares an explicit required-profile manifest, the gate
# adjudicates the whole SET: every required profile must have a PROFILED passing
# attestation at exactly this head - not merely any one passing scope/app pair.
# The matrix arm short-circuits BEFORE the two-sided flat/scoped read, so its
# fixture needs only require_for_ship - the required set comes from the manifest.
mgate() { bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$1' '$2' '$3'" 2>&1; }
mgate_ok() { mgate "$@" >/dev/null; }

printf 'qa:\n  require_for_ship: true\n' >"$gcfg"
rm -f "$grecdir/graterepo.md" "$gpassed/$gsha" "$gpassed/$gsha".*
mfam=mtask
mman="$AC_HOME/data/$mfam/qa/manifest.json"
mkdir -p "$AC_HOME/data/$mfam/qa"
oldsha=1111111111111111111111111111111111111111
reset_markers() { rm -f "$gpassed/$gsha" "$gpassed/$gsha".* "$gpassed/$oldsha" "$gpassed/$oldsha".*; }
mk_marker() {
  # mk_marker <sha> <scope>.<app> <profile_sha256> [<e2e_sha>] - a PROFILED
  # attestation: filename keys the source sha + scope/app, body binds them.
  local scope="${2%%.*}" app="${2#*.}"
  v2_marker "$gpassed/$1.$2" "$1" "$scope" "$app" "$3" "${4:-}"
}
manifest() { printf '{"task":"%s","source_ref":"","required_profiles":%s}\n' "$mfam" "$1" >"$mman"; }

# M1: three required profiles, only one passing marker -> REFUSE.
reset_markers
manifest '[{"profile_key":"graterepo/orchid/orchid-service"},{"profile_key":"graterepo/cedar/cedar-service"},{"profile_key":"graterepo/maple/maple-core"}]'
mk_marker "$gsha" orchid.orchid-service aaaa
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M1: three required profiles cannot merge after only one passes"
assert_contains "$out" "cedar/cedar-service" "M1: the refusal names an unmet required profile"
assert_contains "$out" "no passing crew-qa attestation" "M1: and says it lacks an attestation at this head"

# M2: every required profile has a profiled marker at this head -> OPEN.
mk_marker "$gsha" cedar.cedar-service bbbb
mk_marker "$gsha" maple.maple-core cccc
out="$(mgate "$grepo" "$gsha" "$mfam")" || fail "M2: all required profiles present opens the gate"
assert_contains "$out" "required profile" "M2: the passing arm names the satisfied set"
assert_contains "$out" "graterepo/orchid/orchid-service" "M2: naming each satisfied profile"

# M3: a PASS for an OLDER source SHA does not satisfy the current head.
reset_markers
manifest '[{"profile_key":"graterepo/orchid/orchid-service"}]'
mk_marker "$oldsha" orchid.orchid-service aaaa
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M3: a marker for a different sha does not satisfy this head"
assert_contains "$out" "no passing crew-qa attestation" "M3: the head under merge has no attestation"
# ...and an attestation at the head FILENAME whose BODY binds a different
# source sha is rejected (doc: every attestation matches the merge-head SHA).
v2_marker "$gpassed/$gsha.orchid.orchid-service" "$oldsha" orchid orchid-service aaaa
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M3b: an attestation whose body binds a different source sha is rejected"
assert_contains "$out" "source_sha mismatch" "M3b: the refusal says the body sha is not the head"

# M4: a different PROFILE REVISION does not satisfy. Manifest pins the hash.
reset_markers
manifest '[{"profile_key":"graterepo/orchid/orchid-service","profile_sha256":"EXPECTED-REV"}]'
mk_marker "$gsha" orchid.orchid-service GOT-DIFFERENT-REV
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M4: a pass for a different profile revision does not satisfy"
assert_contains "$out" "profile hash mismatch" "M4: the refusal names the revision mismatch"
mk_marker "$gsha" orchid.orchid-service EXPECTED-REV
mgate_ok "$grepo" "$gsha" "$mfam" || fail "M4: the matching profile revision satisfies"

# M5: a different explicitly requested E2E ref does not satisfy. Manifest pins it.
reset_markers
manifest '[{"profile_key":"graterepo/orchid/orchid-service","profile_sha256":"EXPECTED-REV","e2e_sha":"E2E-WANT"}]'
mk_marker "$gsha" orchid.orchid-service EXPECTED-REV E2E-GOT
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M5: a pass for a different E2E ref does not satisfy"
assert_contains "$out" "E2E hash mismatch" "M5: the refusal names the E2E mismatch"
mk_marker "$gsha" orchid.orchid-service EXPECTED-REV E2E-WANT
mgate_ok "$grepo" "$gsha" "$mfam" || fail "M5: the matching E2E ref satisfies"

# M6: a LEGACY marker (no profile hash) cannot satisfy a required manifest,
# even at the exact head; nor can a bare sha-only marker.
reset_markers
manifest '[{"profile_key":"graterepo/orchid/orchid-service"}]'
{ printf 'source_sha=%s\n' "$gsha"; printf 'cases=1/1\n'; } >"$gpassed/$gsha.orchid.orchid-service"
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M6: a legacy marker with no profile hash cannot satisfy a required manifest"
assert_contains "$out" "invalid" "M6: the refusal says the marker is legacy/unprofiled"
reset_markers
: >"$gpassed/$gsha"
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M6: a bare sha-only marker matches no required profile"
assert_contains "$out" "no passing crew-qa attestation" "M6: a bare marker is not a profiled attestation for the key"

# M7: NO manifest -> the matrix arm is skipped and the FLAT arm is byte-for-byte
# the no-task behavior (criterion: a flat single-profile project is unchanged).
reset_markers
rm -f "$mman"
: >"$gpassed/$gsha"
v2_marker "$gpassed/$gsha" "$gsha" "" "" flat-profile
mgate_ok "$grepo" "$gsha" "$mfam" || fail "M7: with no manifest, a flat project's valid v2 marker opens the gate"

# M8: a present-but-empty or malformed manifest fails CLOSED - never falls
# through to the any-pair arm against an undefined required set.
reset_markers
: >"$gpassed/$gsha"
manifest '[]'
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M8: an empty required set must refuse, not merge against nothing"
assert_contains "$out" "empty or unreadable" "M8: the refusal names the undefined required set"
printf 'not json' >"$mman"
out="$(mgate "$grepo" "$gsha" "$mfam")" && fail "M8: a malformed manifest must refuse"
assert_contains "$out" "empty or unreadable" "M8: a malformed manifest fails closed"

reset_markers
rm -rf "$AC_HOME/data/$mfam"
rm -f "$gcfg"

# (the ac_record_launch_opts cases moved to tests/ac-harness.test.sh with the
# function - audit-f5; run-suite's name mapping keeps test and owner together.)

# --- ac_meta_is_verify: the VERIFICATION-agent class ---------------------------
# The one definition every crew-ness filter branches on (through ac_crew_metas'
# skip-classes since audit-f4). It reads the
# meta's OWN kind and matches the `verify-*` PREFIX - never the id, never an
# enumerated list - and anything else fails CLOSED to "crewmate".

isv() {
  # isv <kind-line...> -> yes|no for a meta carrying those lines
  local f="$TMP/isv.meta"
  rm -f "$f"
  [ -n "${1:-}" ] && printf '%s\n' "$@" >"$f"
  lib "ac_meta_is_verify '$f' && printf yes || printf no"
}

assert_eq "$(isv 'kind=verify-codereview')" "yes" "verify-* prefix is the class"
assert_eq "$(isv 'kind=verify-qa')" "yes" "a second verify-* kind needs no code change"
assert_eq "$(isv 'kind=verify-whatever-lands-next')" "yes" \
  "a prefix, not a list: a fifth pane kind is covered the day someone adds it"
# Every kind on disk TODAY fails closed to crewmate - that is what makes the
# behaviour byte-identical before any verifier writes a meta.
assert_eq "$(isv 'kind=ship')" "no" "ship fails closed to crewmate"
assert_eq "$(isv 'kind=scout')" "no" "scout fails closed to crewmate"
assert_eq "$(isv 'kind=roomchief')" "no" "roomchief fails closed to crewmate"
assert_eq "$(isv 'kind=crewdeputy')" "no" "crewdeputy fails closed to crewmate"
# Fail-closed edges: no kind at all, a bare `verify` (the prefix needs its dash),
# a kind that merely CONTAINS the token, and a missing file.
assert_eq "$(isv 'project=agent-crew')" "no" "a meta with no kind is a crewmate"
assert_eq "$(isv 'kind=verify')" "no" "bare 'verify' is not the verify- prefix"
assert_eq "$(isv 'kind=preverify-qa')" "no" "the match is anchored at the start"
assert_eq "$(isv)" "no" "an absent meta is a crewmate, never a verifier"

# --- ac_crew_branch: the ONE crew-branch derivation, shared by ac-brief.sh and
# ac-merge-local.sh, so a family-scoped id never needs a hand-made alias branch.
assert_eq "$(lib "ac_crew_branch 'foo'")" "crew/foo" \
  "a flat id (id == family) yields crew/<id>, unchanged from today"
assert_eq "$(lib "ac_crew_branch 'foo-r2'")" "crew/foo" \
  "a family-scoped id (revision suffix) yields crew/<family>, not crew/<id>"
assert_eq "$(lib "ac_crew_branch 'foo-r2'")" "$(lib "printf 'crew/%s\\n' \"\$(ac_family_of_id 'foo-r2')\"")" \
  "ac_crew_branch always agrees with ac_family_of_id - the one family-grammar authority"

# --- ac_family_of_id: a stage suffix is trusted only when its nested brief dir
# actually exists on disk (family-of-id-suffix-collision) - a flat id merely
# COLLIDING with a stage suffix (dash-review, no data/dash/) must stay its own
# family instead of reading as a stage of a family nobody ever created.
assert_eq "$(lib "ac_family_of_id 'dash-review'")" "dash-review" \
  "a flat id colliding with a stage suffix resolves to itself when no nested brief exists"
mkdir -p "$AC_HOME/data/foo/spec"
assert_eq "$(lib "ac_family_of_id 'foo-spec'")" "foo" \
  "a genuine staged id (nested brief dir present) still resolves to its family"
# A STAGED revision checks the BASE stage dir (no -rN), not a revision-
# specific one: a genuine revision's base stage was already briefed, so
# data/foo/spec (created above) is what foo-spec-r2 must find too.
assert_eq "$(lib "ac_family_of_id 'foo-spec-r2'")" "foo" \
  "a staged revision resolves to its family when the BASE stage dir exists"
rm -rf "$AC_HOME/data/foo"
# ... and with NO base stage dir at all, a revision of a suffix-colliding flat
# id must land on the SAME family as the un-revised flat id - never a
# different one, and never the over-stripped family either: ac-merge-local.sh
# ffs crew/<family>, so a revision disagreeing with its own base id's family
# is a silent landing hazard (the defect class this fix exists to close).
assert_eq "$(lib "ac_family_of_id 'dash-review-r2'")" "dash-review" \
  "a revision of a suffix-colliding flat id stays on that SAME flat family"
assert_eq "$(lib "ac_family_of_id 'dash-review'")" "$(lib "ac_family_of_id 'dash-review-r2'")" \
  "a flat id and its own revision must never disagree on family/branch"
# A bare implement revision (no stage suffix at all) keeps its unconditional
# strip - there is no stage to doubt, and a direct task's own
# data/<id>/implement never exists to check against.
assert_eq "$(lib "ac_family_of_id 'foo-r2'")" "foo" \
  "a bare implement-revision id keeps stripping to its family with no disk check"
# -chief is now an ordinary stage-suffix arm (board-detail-shows-every-
# artifact part B), same disk-gate as every other suffix: with no nested
# data/foo/chief dir on disk, it still resolves to itself.
assert_eq "$(lib "ac_family_of_id 'foo-chief'")" "foo-chief" \
  "with no data/foo/chief on disk, a -chief id still resolves to itself"

# --- -chief roomchief dirs nest under their family (board-detail-shows-every-
# artifact part B): ac_stage_dir_for_id maps <family>-chief to <family>/chief
# like every other suffix arm; ac_family_of_id/ac_task_dir still gate on disk,
# so a family whose OWN name happens to end in -chief (no parent data/<base>/
# dir) is unaffected.
assert_eq "$(lib "ac_stage_dir_for_id 'foo-chief'")" "foo/chief" \
  "-chief is an ordinary stage-suffix arm, mapping to <family>/chief"
mkdir -p "$AC_HOME/data/foo/chief"
assert_eq "$(lib "ac_family_of_id 'foo-chief'")" "foo" \
  "once a roomchief's nested chief dir exists, -chief resolves to its family"
rm -rf "$AC_HOME/data/foo"

# A genuine family whose OWN name ends in -chief (not a roomchief) has no
# parent data/<base>/ dir - the ac-gate-second-chief shape on disk, cited in
# the board-detail-shows-every-artifact brief.
mkdir -p "$AC_HOME/data/real-second-chief"
: >"$AC_HOME/data/real-second-chief/plan.md"
assert_eq "$(lib "ac_family_of_id 'real-second-chief'")" "real-second-chief" \
  "a real family whose name ends in -chief, with no parent data/real-second/ dir, stays itself"
assert_eq "$(lib "ac_task_dir 'real-second-chief'")" "$AC_HOME/data/real-second-chief" \
  "and its task dir stays the flat dir - the -chief suffix alone never redirects it"
rm -rf "$AC_HOME/data/real-second-chief"

# ac_task_dir accepts the brief-less chief dir once its FAMILY already exists
# on disk (a promoted family always has data/<family>/room.md before its
# roomchief is ever spawned) - even though the chief dir itself has not been
# created yet (the mirror's own mkdir is what creates it: chicken-and-egg,
# the resolver must not require the dir to already exist).
mkdir -p "$AC_HOME/data/bar"
: >"$AC_HOME/data/bar/room.md"
assert_eq "$(lib "ac_task_dir 'bar-chief'")" "$AC_HOME/data/bar/chief" \
  "a roomchief's task dir nests under its family even before the chief dir itself exists"
# the deliberate ambiguity die still fires when a flat brief ALSO exists
mkdir -p "$AC_HOME/data/bar-chief"
: >"$AC_HOME/data/bar-chief/brief.md"
out="$(lib "ac_task_dir 'bar-chief' 2>&1" || true)"
assert_contains "$out" "ambiguous task data" \
  "briefs at both the nested chief dir's family and a flat dir still die (deliberate ambiguity)"
rm -rf "$AC_HOME/data/bar" "$AC_HOME/data/bar-chief"

# --- ac_meta_get: "empty if absent" must hold at BOTH instants ----------------
# Contract and reasoning: ac_meta_get's own comment block (bin/ac-lib.sh). What
# these cases pin: a VANISH mid-read is empty+0, a present-but-unreadable file
# still ABORTS (fail-closed), and the ordinary reads are unchanged. The vanish
# case is the load-sensitive red at tests/ac-lock.test.sh:470 - 17% of stale
# races under 5-way load, 0% quiet - so it needs a deterministic fixture, below.
real_awk="$(command -v awk)"
mkdir -p "$TMP/metabin"
# The reaper's rm (bin/ac-lock.sh:233), made deterministic: one shim that deletes
# the target AFTER ac_meta_get's `-f` test has passed and BEFORE the real awk
# opens it - no load, no second process, no timing. Same PATH-stub technique as
# make_fake_herdr's fake CLI. Scoped to *.vanish.meta so no other awk call moves.
cat >"$TMP/metabin/awk" <<SHIM
#!/usr/bin/env bash
t="\${*: -1}"
case "\$t" in *.vanish.meta) rm -f "\$t" ;; esac
exec "$real_awk" "\$@"
SHIM
chmod +x "$TMP/metabin/awk"

vf="$TMP/gone.vanish.meta"
printf 'pid=4242\n' >"$vf"
rc=0
out="$(PATH="$TMP/metabin:$PATH" lib "v=\"\$(ac_meta_get '$vf' pid)\"; printf 'v=%s\n' \"\$v\"" 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "a meta file removed mid-read never aborts its caller"
assert_eq "$out" "v=" "a meta file removed mid-read reads empty, exactly like an absent one"

# Fail-closed PRESERVED: present but unopenable is a real error, not a vanish.
uf="$TMP/unreadable.meta"
printf 'pid=7\n' >"$uf"
chmod 000 "$uf"
rc=0
lib "v=\"\$(ac_meta_get '$uf' pid)\"" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "a present-but-unreadable meta must still abort its caller (fail-closed)"
chmod 644 "$uf"

# No regression on the ordinary reads.
nf="$TMP/normal.meta"
printf 'pid=99\nsince=2026-01-01T00:00:00Z\n' >"$nf"
rc=0; out="$(lib "ac_meta_get '$nf' pid")" || rc=$?
assert_eq "$rc" "0" "a normal read still exits 0"
assert_eq "$out" "99" "a normal read still returns the value"
assert_eq "$(lib "ac_meta_get '$nf' nosuch")" "" "an absent KEY still reads empty"
rc=0; out="$(lib "ac_meta_get '$TMP/no-such-file.meta' pid")" || rc=$?
assert_eq "$rc" "0" "an absent FILE still exits 0"
assert_eq "$out" "" "an absent FILE still reads empty"

# --- QA coverage manifest parser -----------------------------------------------
# The parser is shared by the QA recorder and the independent verifier. Keep
# its closed grammar and exact-tree UT reference checks locked here without
# invoking a QA runtime or any project test command.
qmr="$(make_repo qa-manifest)"
mkdir -p "$qmr/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$qmr/tests/example.test.sh"
chmod +x "$qmr/tests/example.test.sh"
ln -s example.test.sh "$qmr/tests/link.test.sh"
git -C "$qmr" add -A
git -C "$qmr" commit -qm 'add manifest fixtures'
qsha="$(git -C "$qmr" rev-parse HEAD)"
qplan="$TMP/testplan.md"
qmanifest="$TMP/testplan-manifest.json"

qrender() {
  bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    if ! ac_qa_testplan_manifest_render "$3" "$4" "$5"; then
      printf "%s\n" "$AC_QA_MANIFEST_ERROR" >&2
      exit 1
    fi
  ' _ "$BIN/ac-lib.sh" "$BIN/ac-qa-lib.sh" "$qmr" "$qsha" "$1"
}

cat >"$qplan" <<'EOF'
# QA test plan

The inline text `coverage: ignored | ut | nope | -` is prose.

```md
## Coverage
coverage: FENCED | nope | - | BAD
## Full Flow
full-flow: BAD
```

> coverage: quoted | it | - | QUOTED
- full-flow: LISTED

## Coverage
coverage: AC-UT | ut | tests/example.test.sh#direct_case | -
coverage: AC-IT | it | - | IT-1
coverage: AC-E2E | e2e | - | E2E-1

## Full Flow
full-flow: E2E-1
EOF
qrender "$qplan" >"$qmanifest" || fail "the canonical coverage manifest must render"
assert_eq "$(jq -r .schema "$qmanifest")" "agentcrew.qa-testplan-manifest/v1" \
  "the coverage manifest carries its closed schema"
assert_eq "$(jq -r '.coverage | map(.ac) | join(",")' "$qmanifest")" \
  "AC-UT,AC-IT,AC-E2E" "declaration order is canonical and fenced/prose examples are ignored"
assert_eq "$(jq -r '.full_flow | join(",")' "$qmanifest")" "E2E-1" \
  "only the exact full-flow declaration is frozen"
qrender "$qplan" >"$TMP/testplan-manifest.second.json"
cmp -s "$qmanifest" "$TMP/testplan-manifest.second.json" \
  || fail "re-rendering the same test plan must produce identical manifest bytes"
qmanifest_sha="$(shasum -a 256 <"$qmanifest" | awk '{print $1}')"
bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  ac_qa_testplan_manifest_validate "$3" "$4" "$5" "$6" "$7"
' _ "$BIN/ac-lib.sh" "$BIN/ac-qa-lib.sh" "$qmr" "$qsha" "$qplan" "$qmanifest" "$qmanifest_sha" \
  || fail "the frozen manifest and recorded hash must revalidate"
assert_fails bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  ac_qa_testplan_manifest_validate "$3" "$4" "$5" "$6" WRONG
' _ "$BIN/ac-lib.sh" "$BIN/ac-qa-lib.sh" "$qmr" "$qsha" "$qplan" "$qmanifest"

cat >"$qplan" <<'EOF'
## Coverage
coverage: AC-1 | it | - | C-1
EOF
assert_fails qrender "$qplan"

cat >"$qplan" <<'EOF'
## Coverage
coverage: AC-1 | it | - | C-1
coverage: AC-1 | it | - | C-1

## Full Flow
full-flow: C-1
EOF
assert_fails qrender "$qplan"

cat >"$qplan" <<'EOF'
## Coverage
coverage: AC-1 | ut | tests/link.test.sh | -
coverage: assembled | it | - | C-1

## Full Flow
full-flow: C-1
EOF
assert_fails qrender "$qplan"

cat >"$qplan" <<'EOF'
## Coverage
coverage: AC-1 | ut | ../tests/example.test.sh | -
coverage: assembled | it | - | C-1

## Full Flow
full-flow: C-1
EOF
assert_fails qrender "$qplan"

# --- QA boundary policy receipt validators --------------------------------------
# The closed tier/boundary table and the receipt validators are shared by three
# actors (ac-qa records and gates, ac-verify reconciles, the merge gate reads),
# so they are tested where they live rather than through each caller.
coh() { lib "ac_qa_boundary_coherent '$1' '$2'"; }
coh api http    || fail "api accepts an http stimulus"
coh api e2e     || fail "api accepts the approved e2e boundary"
coh db workflow || fail "db accepts a workflow-stimulated durable assertion"
coh workflow queue || fail "workflow accepts a queue message"
coh web web     || fail "web accepts a real browser"
! coh api web      || fail "api must not be satisfied by a browser transcript"
! coh web http     || fail "web must not be satisfied by a plain request"
! coh workflow http || fail "workflow must not be satisfied by a plain request"
! coh api bogus    || fail "an unknown boundary is never coherent"
! coh api unit     || fail "unit is not a QA execution boundary"

rt="$TMP/runtime-receipt.env"
{
  printf 'schema=agentcrew.qa-runtime-receipt/v1\n'
  printf 'source_sha=SRC\nprofile_sha256=PROF\n'
  printf 'serve_command_sha256=SERVE\nhealth_command_sha256=HEALTH\n'
  printf 'runtime_descriptor_sha256=DESC\n'
  printf 'serve_started_at=2026-07-25T00:00:00Z\nhealth_completed_at=2026-07-25T00:00:01Z\n'
  printf 'process_group=4242\n'
} >"$rt"
lib "ac_qa_runtime_receipt_validate '$rt' SRC PROF SERVE HEALTH DESC" \
  || fail "a complete boot receipt validates"
! lib "ac_qa_runtime_receipt_validate '$rt' OTHER PROF SERVE HEALTH DESC" \
  || fail "a boot receipt for another source must refuse"
! lib "ac_qa_runtime_receipt_validate '$rt' SRC PROF CHANGED HEALTH DESC" \
  || fail "a changed serve command must refuse"
! lib "ac_qa_runtime_receipt_validate '$rt' SRC PROF SERVE HEALTH CHANGED" \
  || fail "a changed runtime descriptor must refuse"
! lib "ac_qa_runtime_receipt_validate '$TMP/nope.env' SRC PROF SERVE HEALTH DESC" \
  || fail "an absent boot receipt must refuse"
# Liveness is deliberately NOT part of the validator: post-teardown
# reconciliation validates the immutable record, and a normally terminated
# process must never invalidate an honest run.
sed -i.bak 's/^process_group=.*/process_group=0/' "$rt"
! lib "ac_qa_runtime_receipt_validate '$rt' SRC PROF SERVE HEALTH DESC" \
  || fail "a receipt with no positive process group must refuse"
sed -i.bak 's/^process_group=.*/process_group=4242/' "$rt"

br="$TMP/boundary-receipt.env"
{
  printf 'schema=agentcrew.qa-boundary-receipt/v1\n'
  printf 'source_sha=SRC\nprofile_sha256=PROF\nruntime_receipt_sha256=RT\n'
  printf 'case_id=C-1\nboundary=http\ndriver=command\n'
  printf 'stimulus_sha256=STIM\nevidence_sha256=EV\nupstream_receipt_sha256=-\n'
  printf 'started_at=2026-07-25T00:00:02Z\ncompleted_at=2026-07-25T00:00:03Z\nexit_code=0\n'
} >"$br"
lib "ac_qa_boundary_receipt_validate '$br' C-1 api pass SRC PROF RT" \
  || fail "a coherent zero-exit boundary receipt validates a passing case"
! lib "ac_qa_boundary_receipt_validate '$br' C-2 api pass SRC PROF RT" \
  || fail "a receipt naming another case must refuse"
! lib "ac_qa_boundary_receipt_validate '$br' C-1 web pass SRC PROF RT" \
  || fail "an incoherent tier/boundary pair must refuse"
! lib "ac_qa_boundary_receipt_validate '$br' C-1 api pass SRC PROF OTHER" \
  || fail "a receipt bound to another runtime must refuse"
sed -i.bak 's/^exit_code=.*/exit_code=2/' "$br"
! lib "ac_qa_boundary_receipt_validate '$br' C-1 api pass SRC PROF RT" \
  || fail "a passing case cannot bind a non-zero execution"
lib "ac_qa_boundary_receipt_validate '$br' C-1 api fail SRC PROF RT" \
  || fail "a failing case may bind a non-zero execution"

gt="$TMP/runtime-gate.env"
{
  printf 'schema=agentcrew.qa-runtime-gate/v1\n'
  printf 'source_sha=SRC\nprofile_sha256=PROF\nruntime_receipt_sha256=RT\n'
  printf 'process_group=4242\nhealth_command_sha256=HEALTH\n'
  printf 'validated_at=2026-07-25T00:00:04Z\nalive=1\nhealth_exit_code=0\n'
} >"$gt"
lib "ac_qa_runtime_gate_validate '$gt' SRC PROF RT HEALTH 4242" \
  || fail "a complete gate receipt validates"
! lib "ac_qa_runtime_gate_validate '$gt' SRC PROF OTHER HEALTH 4242" \
  || fail "a gate bound to another boot receipt must refuse"
sed -i.bak 's/^health_exit_code=.*/health_exit_code=1/' "$gt"
! lib "ac_qa_runtime_gate_validate '$gt' SRC PROF RT HEALTH 4242" \
  || fail "a gate whose final probe failed must refuse"

# --- ac_crew_metas: the one crew enumerator and its named skip classes -------
# (audit-f4) Every "is this crew?" glob loop names its policy as skip-classes
# against class definitions that live in ONE place; kind reads last-write-wins
# (ac_meta_get's rule) and a kind-less meta is counted fail-safe.
cmdir="$TMP/cmstate"; mkdir -p "$cmdir"
printf 'kind=ship\n' >"$cmdir/a.meta"
printf 'kind=verify-qa\n' >"$cmdir/b.meta"
printf 'kind=self\n' >"$cmdir/c.meta"
printf 'kind=roomchief\n' >"$cmdir/d.meta"
printf 'kind=crewdeputy\n' >"$cmdir/e.meta"
: >"$cmdir/f.meta"
printf 'kind=scout\nkind=verify-codereview\n' >"$cmdir/g.meta"
cm() { lib "ac_crew_metas '$cmdir' $1" | wc -l | tr -d ' '; }
assert_eq "$(cm "")" "7" "no skip class: every meta prints, the empty one included"
assert_eq "$(cm "verify")" "5" "verify skips the prefix class - the LAST kind write wins (g.meta)"
assert_eq "$(cm "self")" "6" "self skips exactly the kind=self meta"
assert_eq "$(cm "chiefs")" "5" "chiefs skips roomchief AND crewdeputy"
assert_eq "$(cm "verify self chiefs")" "2" "all three classes: the ship task and the kind-less meta remain"
assert_eq "$(lib "ac_crew_metas '$TMP/no-such-state-dir'")" "" "an absent dir prints nothing, exit 0"
! lib "ac_crew_metas '$cmdir' crew" 2>/dev/null \
  || fail "an unknown skip-class must die rather than silently filter nothing"

# --- ac_task_stamps: the authoritative per-id stamp reap list ----------------
# (audit-f4) Teardown iterates THIS list; the hand copy it replaced had leaked
# twice (.change-* orphans live, then .seen-hash-/.report-hash-/.superseded-
# added with no reaper at all).
stamps="$(lib "ac_task_stamps /sd tid1")"
for b in hash change seen seen-hash stale gone ask unobservable report-hash superseded; do
  assert_contains "$stamps" "/sd/.$b-tid1" "stamp list carries .$b-<id>"
done
assert_eq "$(printf '%s\n' "$stamps" | wc -l | tr -d ' ')" "10" "exactly the ten stamp kinds, no strays"

# --- crewdomain routing table: a SECOND registry, disjoint from the deputy one
# The crewdomain feature is ADDITIVE - records/crewdeputies.md and
# ac_deputy_parse are untouched, and the two parsers never read each other's
# file. Grammar: `- <id> - <charter> - scope: <text> (added <iso>)`, three
# fields, VALID/INVALID only (no LEGACY class - nothing has ever written this
# file, and no liveness - a crewdomain has no session to be alive).

dreg="$AC_HOME/records/crewdomains.md"
dparse() { lib "ac_domain_parse '$dreg'"; }
dfield() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NR == 1 { print $n }'; }

assert_eq "$(lib "ac_domain_registry")" "$AC_HOME/records/crewdomains.md" \
  "ac_domain_registry names records/crewdomains.md"

# The three-field line, with spaces preserved everywhere: routing is the CHIEF
# reading the scope text, so a field-split bug that truncates it misroutes.
printf '# Crewdomains\n\n- payments - payments domain, ledger and payouts - scope: anything touching money movement - balances, interest (added 2026-08-02T00:00:00Z)\n' >"$dreg"
rec="$(dparse)"
assert_eq "$(dfield "$rec" 1)" "VALID" "the three-field line is VALID"
assert_eq "$(dfield "$rec" 2)" "payments" "id"
assert_eq "$(dfield "$rec" 3)" "payments domain, ledger and payouts" "charter keeps its spaces"
assert_eq "$(dfield "$rec" 4)" "anything touching money movement - balances, interest" \
  "scope keeps its spaces AND an embedded ' - ' (it is the last field)"

# An EMPTY scope parses VALID and is simply not routable - the chief may not
# invent scope text for it, so the entry has to be visible rather than absent.
printf -- '- payments - a charter - scope:  (added 2026-08-02T00:00:00Z)\n' >"$dreg"
rec="$(dparse)"
assert_eq "$(dfield "$rec" 1)" "VALID" "an empty scope: is VALID"
assert_eq "$(dfield "$rec" 4)" "" "and its scope is empty - the field that makes it non-routable"

# AC-2.1 - an unknown field is INVALID and the reason NAMES it. A crewdomain has
# no home and no projects list, so the two deputy fields are exactly the shapes
# an operator is most likely to copy across; the check is general, not a
# two-name blocklist. On INVALID the id field carries the verbatim source line,
# mirroring ac_deputy_parse, so a typo is fixable from the digest.
printf -- '- payments - a charter - home: /h/crewdomains/payments - scope: money (added 2026-08-02T00:00:00Z)\n' >"$dreg"
rec="$(dparse)"
assert_eq "$(dfield "$rec" 1)" "INVALID" "a line carrying home: is INVALID"
assert_contains "$(dfield "$rec" 5)" "home:" "and the reason NAMES the unknown field"
assert_contains "$(dfield "$rec" 2)" "- payments - a charter - home:" \
  "an INVALID record carries the verbatim source line where the id would be"

printf -- '- payments - a charter - scope: money - projects: alpha,beta (added 2026-08-02T00:00:00Z)\n' >"$dreg"
rec="$(dparse)"
assert_eq "$(dfield "$rec" 1)" "INVALID" "a projects: field is INVALID even trailing the scope text"
assert_contains "$(dfield "$rec" 5)" "projects:" "and the reason names it"

printf -- '- payments - a charter (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_contains "$(dfield "$(dparse)" 5)" "scope:" "a line with no scope: field is INVALID, naming it"

printf -- '- payments - scope: money (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_contains "$(dfield "$(dparse)" 5)" "charter" "a line with no charter is INVALID, naming it"

printf -- '- pay ments - a charter - scope: money (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_contains "$(dfield "$(dparse)" 5)" "id charset" "a bad id charset is INVALID"

printf -- '- payments - a charter - scope: money\n' >"$dreg"
assert_contains "$(dfield "$(dparse)" 5)" "(added" "a line with no (added ...) group is INVALID"

printf -- '- payments - one - scope: a (added 2026-08-02T00:00:00Z)\n- payments - two - scope: b (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_contains "$(printf '%s\n' "$(dparse)" | awk -F'\t' 'NR == 2 { print $5 }')" "duplicate id" \
  "a duplicate id is INVALID on the SECOND line, not the first"

# Non-entry lines are IGNORED, never parsed and never reported - the same
# tolerance ac_deputy_parse has, so a heading or a blank never becomes a finding.
printf '# Crewdomains\n\nsome prose\n- payments - a charter - scope: money (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_eq "$(dparse | wc -l | tr -d ' ')" "1" "headings, blanks and prose are ignored"

# PURE: reads, writes nothing, probes nothing - safe under a read-only session.
rm -f "$dreg"
assert_eq "$(dparse)" "" "an absent registry yields no records"
assert_no_file "$dreg" "parsing never creates the registry"

# AC-2.4 (first half) - the two parsers are disjoint. ac_deputy_parse still
# reads its own file exactly as it does today, INCLUDING the legacy shape the
# crewdomain grammar has no class for, and neither parser reaches the other's
# registry. The deputy suites run unchanged as the rest of that proof.
kreg="$AC_HOME/records/crewdeputies.md"
printf -- '- demo - home: /h/crewdeputies/demo - no projects (added 2026-07-16T09:46:38Z)\n' >"$kreg"
assert_eq "$(lib "ac_deputy_parse '$kreg'")" \
  "$(printf 'LEGACY\tdemo\t/h/crewdeputies/demo\t(none)\t\tnone\t')" \
  "AC-2.4: the deputy parser is byte-unchanged on its own legacy line"
assert_eq "$(lib "ac_domain_parse '$kreg'" | cut -f1)" "INVALID" \
  "a deputy line handed to the crewdomain parser is INVALID - no shared grammar"
assert_eq "$(lib "ac_deputy_parse '$dreg'")" "" \
  "and the deputy parser never reads the crewdomain registry"
rm -f "$kreg"

# --- ac_status_append: durable timeline.log mirror (task-timeline) ------------
# Every lifecycle line ac_status_append writes to the VOLATILE state/<id>.status
# is ALSO mirrored to a DURABLE $(ac_task_dir <id>)/timeline.log, so a task's
# timeline survives teardown (state/ is reaped). The mirror is fail-SOFT: it
# never breaks the status write and skips a verifier / a metaless id.
tdata="$AC_HOME/data"
mkdir -p "$tdata/t1"
printf 'kind=ship\nworktree=%s\n' "$TMP/wt1" >"$AC_HOME/state/t1.meta"
lib "ac_status_append t1 'working: spawned'"
assert_contains "$(cat "$AC_HOME/state/t1.status")" "working: spawned" \
  "volatile status file still gets the line"
assert_file "$tdata/t1/timeline.log" "durable timeline.log is written"
assert_contains "$(cat "$tdata/t1/timeline.log")" "working: spawned" \
  "durable timeline.log mirrors the same line"
assert_eq "$(awk '{print $1}' "$AC_HOME/state/t1.status")" \
  "$(awk '{print $1}' "$tdata/t1/timeline.log")" \
  "status and timeline share the one ac_iso timestamp (no double clock read)"

# a roomchief's durable timeline now nests under its family instead of a
# phantom data/<family>-chief/ sibling (board-detail-shows-every-artifact part
# B) - the family dir (room.md) already exists before the roomchief is ever
# spawned; its meta is the ordinary <family>-chief id.
mkdir -p "$tdata/rc-fam"
: >"$tdata/rc-fam/room.md"
printf 'kind=roomchief\nworktree=%s\n' "$TMP/wtrc" >"$AC_HOME/state/rc-fam-chief.meta"
lib "ac_status_append rc-fam-chief 'working: promoted'"
assert_file "$tdata/rc-fam/chief/timeline.log" \
  "the roomchief's durable timeline nests at data/<family>/chief/timeline.log"
assert_no_file "$tdata/rc-fam-chief/timeline.log" \
  "no more phantom data/<family>-chief/ sibling dir"
rm -rf "$tdata/rc-fam"

# a verify-* pane owns no durable task dir - mirror is skipped, status still written
printf 'kind=verify-codereview\n' >"$AC_HOME/state/vf.meta"
mkdir -p "$tdata/vf"
lib "ac_status_append vf 'started review'"
assert_contains "$(cat "$AC_HOME/state/vf.status")" "started review" \
  "verify pane still gets its volatile status"
assert_no_file "$tdata/vf/timeline.log" "a verify-* pane writes no durable timeline"

# an id with no meta and no data dir: soft-skip, status still written, no crash,
# no phantom dir
lib "ac_status_append ghost 'poof'"
assert_contains "$(cat "$AC_HOME/state/ghost.status")" "poof" \
  "a metaless id still gets its volatile status"
assert_no_file "$tdata/ghost/timeline.log" "no phantom durable dir for a metaless id"

# --- ac_status_append: the PRIMARY write's own exit status (status-append-
#     dies-on-directory-status-path) --------------------------------------------
# The mirror is fail-soft on its own account, but it must not launder the
# primary write's failure into an always-0 return. Exercised the same way the
# real caller (bin/ac-spawn.sh:1152) exercises it - `ac_status_append ... ||
# ...` - because a BARE unguarded call already aborts on its own redirect
# error regardless of this function's return value, so it cannot tell the
# fixed function from the broken one.
mkdir -p "$sd/dirstatus.status"
out="$(lib "ac_status_append dirstatus x || printf GUARD-FIRED")"
assert_contains "$out" "GUARD-FIRED" \
  "the caller's own guard must see the primary write's real failure, not a manufactured 0"
out="$(lib "ac_status_append t1 'working: still zero on a normal write' && printf ZERO-OK")"
assert_contains "$out" "ZERO-OK" \
  "ac_status_append must still return 0 on an ordinary write"

# --- ac_room_file: the READ-side room resolver, live then archive -------------
rdata="$(bash -c ". '$BIN/ac-lib.sh'; ac_data_dir")"

# a live room resolves to the live path
mkdir -p "$rdata/liveroom"
printf '# Room: liveroom\n' >"$rdata/liveroom/room.md"
assert_eq "$(lib "ac_room_file liveroom")" "$rdata/liveroom/room.md" \
  "a live room resolves to data/<family>/room.md"

# an ARCHIVED family resolves to its archived room
mkdir -p "$rdata/archive/2026/oldroom"
printf '# Room: oldroom\n' >"$rdata/archive/2026/oldroom/room.md"
assert_eq "$(lib "ac_room_file oldroom")" "$rdata/archive/2026/oldroom/room.md" \
  "an archived family resolves to data/archive/<year>/<family>/room.md"

# the LIVE room wins when both exist: a re-opened family is live again, and the
# resolver must never silently answer with the stale archived copy
mkdir -p "$rdata/bothroom" "$rdata/archive/2025/bothroom"
printf '# Room: bothroom live\n' >"$rdata/bothroom/room.md"
printf '# Room: bothroom archived\n' >"$rdata/archive/2025/bothroom/room.md"
assert_eq "$(lib "ac_room_file bothroom")" "$rdata/bothroom/room.md" \
  "the live room outranks an archived copy of the same family"

# neither exists: the LIVE path, so a caller that CREATES a room still writes live
assert_eq "$(lib "ac_room_file newroom")" "$rdata/newroom/room.md" \
  "an unknown family resolves to the live path (nothing to read, create lands live)"

# a family outside the [a-zA-Z0-9_-] charset ac-room.sh enforces never reaches
# the archive glob - `*` would otherwise match a foreign family's room
mkdir -p "$rdata/archive/2026/victim"
printf '# Room: victim\n' >"$rdata/archive/2026/victim/room.md"
assert_eq "$(lib "ac_room_file '*'")" "$rdata/*/room.md" \
  "an unsafe family name never globs into some other family's archived room"

# --- ac_domain_tally: done means REAL done, not Done-section membership ------
# same-done-miscount-in-three-more-surfaces: a [failed]/[abandoned] row in a
# crewdomain's own Done section must not inflate the "done" field - same defect
# class board-rollup-and-overlay-count-failed-as-done fixed for the epic
# rollup, reusing AC_DONELINE_AWK's terminal detection instead of a second
# marker parser.
mkdir -p "$AC_HOME/crewdomains/fx-dom1/records" "$AC_HOME/crewdomains/fx-dom2/records"
cat >"$AC_HOME/crewdomains/fx-dom1/records/backlog.md" <<'EOF'
# Backlog: fx-dom1

## In flight
- [ ] fx-a - a thing (repo: fx)

## Queued
- [ ] fx-b - another thing (repo: fx)
- [ ] fx-c - yet another (repo: fx)

## Done
- [x] fx-done - real success (merged 2026-08-03)
- [x] fx-failed [failed] - did not land (2026-08-03)
- [x] fx-abandoned [abandoned] - dropped (2026-08-03)
EOF
assert_eq "$(lib "ac_domain_tally fx-dom1")" "2 1 1" \
  "a [failed]/[abandoned] Done row must not count toward the done field"

cat >"$AC_HOME/crewdomains/fx-dom2/records/backlog.md" <<'EOF'
# Backlog: fx-dom2

## In flight

## Queued

## Done
- [x] fx-other-done - real success (merged 2026-08-03)
EOF
assert_eq "$(lib "ac_domain_tally")" "2 1 2" \
  "the no-name summed tally also excludes failed/abandoned rows across every package"
rm -rf "$AC_HOME/crewdomains/fx-dom1" "$AC_HOME/crewdomains/fx-dom2"

pass
