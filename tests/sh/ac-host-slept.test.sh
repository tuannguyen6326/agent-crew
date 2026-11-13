#!/usr/bin/env bash
# ac-host-slept.test.sh - bin/ac-host-slept.sh's own contract: slept <N> /
# slept / awake / unknown over [start, end]. Every case stubs `pmset` (or
# removes it from PATH, or stubs `uname`) so no assertion here depends on
# this host's real pmset log - the test seam the brief requires.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# ac-host-slept.sh's own non-macOS path is a one-line `unknown` (asserted
# below on a macOS host, by stubbing `uname`); everything ELSE this file
# proves is pmset LOG PARSING, which only exists on macOS, and this file's
# own fixtures build their [start, end] window with BSD `date -j -f`
# (README.md's "Prerequisites" section lists Linux as supported, where that
# flag refuses).
[ "$(uname -s 2>/dev/null)" = Darwin ] || skip "ac-host-slept.sh's pmset parsing is macOS-only; nothing to exercise here"

SCRIPT="$BIN/ac-host-slept.sh"
assert_file "$SCRIPT" "ac-host-slept.sh must exist"
BASH_BIN="$(command -v bash)"

run_check() {
  # run_check <start> <end> - the script's one output line. An absolute bash
  # path: a case below restricts PATH down to nothing but `uname`, and `bash
  # "$SCRIPT"` would then need PATH to find bash itself to exec it.
  "$BASH_BIN" "$SCRIPT" "$1" "$2"
}

s="$(date -j -f "%Y-%m-%d %H:%M:%S %z" "2030-01-02 03:00:00 +0000" +%s)"
e="$(date -j -f "%Y-%m-%d %H:%M:%S %z" "2030-01-02 03:10:00 +0000" +%s)"

# --- no pmset reachable at all -----------------------------------------------
nopmset="$TMP/nopmset"
mkdir -p "$nopmset"
ln -s "$(command -v uname)" "$nopmset/uname"
out="$(PATH="$nopmset" run_check "$s" "$e")"
assert_eq "$out" "unknown" "no pmset on PATH must fail closed to unknown"

# --- pmset present but failing ------------------------------------------------
stub="$TMP/stub"
mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/pmset"
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "unknown" "a failing pmset must fail closed to unknown"

# --- a pmset that hangs and ignores TERM is bounded, not awaited forever ----
# A caller of this script (run-suite.sh's own watchdog, the Learning gate's
# suite task) is itself a bound someone else is waiting on - a wedged pmset
# must never become the one unbounded wait in the chain. The stub traps TERM
# away so only the KILL ends it.
hang_pid_file="$TMP/pmset-hang.pid"
rm -f "$hang_pid_file"
cat >"$stub/pmset" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"$hang_pid_file"
trap '' TERM
while :; do sleep 1; done
STUB
chmod +x "$stub/pmset"
t0="$(date +%s)"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
elapsed=$(( $(date +%s) - t0 ))
assert_eq "$out" "unknown" "a pmset that never returns must fail closed to unknown, not hang the caller"
[ "$elapsed" -lt 30 ] || fail "the pmset call must be bounded, not awaited past its own cut (took ${elapsed}s)"
if [ -s "$hang_pid_file" ] && kill -0 "$(cat "$hang_pid_file")" 2>/dev/null; then
  kill -KILL "$(cat "$hang_pid_file")" 2>/dev/null || true
  fail "a pmset that outlived its bound must actually be killed, not merely given up on"
fi

# --- pmset succeeds but prints garbage ---------------------------------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
printf 'not a pmset log\njust noise\n'
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "unknown" "output with no recognizable pmset-log line must fail closed to unknown"

# --- pmset succeeds, empty output --------------------------------------------
printf '#!/usr/bin/env bash\ntrue\n' >"$stub/pmset"
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "unknown" "empty pmset output is no evidence - unknown, not awake"

# --- dated lines, no Sleep entry at all --------------------------------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 00:00:00 +0000 DarkWake            	from Deep Idle 9 secs
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "awake" "dated lines with no Sleep entry must read awake"

# --- a Sleep entry wholly outside the window ---------------------------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 01:00:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep' 50 secs
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "awake" "a Sleep entry that never overlaps the window must read awake, not slept"

# --- a Sleep entry fully inside the window -----------------------------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 03:02:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep' 123 secs
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "slept 123" "a Sleep entry inside the window must report its overlap"

# --- a Sleep entry only partially overlapping the window is clipped ---------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 02:59:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep' 120 secs
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "slept 60" "a Sleep entry straddling the window start must clip the overlap to the window"

# --- two overlapping Sleep entries sum ----------------------------------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 03:00:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep' 100 secs
2030-01-02 03:02:00 +0000 DarkWake            	from Deep Idle 5 secs
2030-01-02 03:05:00 +0000 Sleep               	Entering Sleep state due to 'Maintenance Sleep' 200 secs
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "slept 300" "two overlapping Sleep entries must sum their overlap"

# --- a Sleep entry with an unreadable duration, plausibly inside the window:
#     sleep confirmed, amount unknown -----------------------------------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 03:04:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:50%) weird
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "slept" "a Sleep entry with no readable duration, plausibly inside the window, must still say slept"

# --- the same shape, but started AFTER the window closed: cannot have
#     overlapped it, so it must not even make the verdict ambiguous ----------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 04:00:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:50%) weird
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "awake" "an unreadable-duration entry that started after the window closed cannot have overlapped it"

# --- the same shape, but started BEFORE the window opened: the caller
#     measured win_start while THIS process was running, so the host was
#     awake then - a sleep that started earlier had already ended by
#     win_start, no matter how old or undated its own end is. A real pmset
#     log carries lines in exactly this shape (no trailing "N secs" at all,
#     from a sleep pmset never closed out), dated days earlier - every one
#     of them must stay irrelevant, not poison every later window forever.
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2026-11-11 13:29:02 +0700 Sleep               	Entering DarkWake state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:100%)
LOG
STUB
chmod +x "$stub/pmset"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "awake" "an undated-duration entry from days before the window must not make every later window ambiguous"

# --- non-macOS: unknown even with a perfectly good pmset on PATH ------------
cat >"$stub/pmset" <<'STUB'
#!/usr/bin/env bash
cat <<'LOG'
2030-01-02 03:02:00 +0000 Sleep               	Entering Sleep state due to 'Clamshell Sleep' 123 secs
LOG
STUB
chmod +x "$stub/pmset"
cat >"$stub/uname" <<'STUB'
#!/usr/bin/env bash
echo Linux
STUB
chmod +x "$stub/uname"
out="$(PATH="$stub:$PATH" run_check "$s" "$e")"
assert_eq "$out" "unknown" "a non-macOS uname must fail closed to unknown regardless of pmset"
rm -f "$stub/uname"

# --- malformed args: fail closed, never a crash ------------------------------
out="$(bash "$SCRIPT" abc 200)"
assert_eq "$out" "unknown" "a non-numeric start must fail closed to unknown"
out="$(bash "$SCRIPT" 100)"
assert_eq "$out" "unknown" "a missing end argument must fail closed to unknown"

pass
