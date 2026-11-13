#!/usr/bin/env bash
# ac-host-slept.sh <start-epoch> <end-epoch> - the ONE check for whether this
# host entered sleep during [start, end]. tests/run-suite.sh's per-test
# timeout path and src/learn.ts's suite-gate verdict both shell out here
# instead of each parsing `pmset -g log` on their own, so a gate bound and
# the suite record it feeds never disagree about what the host did while it
# ran. macOS only (`pmset -g log` is the only evidence source available): any
# other host, a missing or failing pmset, or output with no recognizable
# pmset-log line all fail-closed to `unknown` - a public distro cannot assume
# pmset exists or behaves, and a laptop's lid-close sleep is unprovable
# without it. Read-only: never runs a pmset/caffeinate SETTER.
#
# Output (stdout, exactly one line; exit is always 0 - the caller reads the
# line, never the exit status):
#   slept <seconds>   a Sleep entry's interval overlapped the window; the
#                      number is the overlap, summed across every
#                      overlapping entry
#   slept              a Sleep entry plausibly overlapped the window but its
#                      duration could not be read - sleep confirmed, the
#                      overlap is not
#   awake              pmset read cleanly and no Sleep entry overlapped
#   unknown            no evidence source: non-macOS, no pmset on PATH,
#                      pmset failed, or its output had no recognizable
#                      pmset-log line
set -euo pipefail

start="${1:-}"
end="${2:-}"
case "$start" in '' | *[!0-9]*) printf 'unknown\n'; exit 0 ;; esac
case "$end" in '' | *[!0-9]*) printf 'unknown\n'; exit 0 ;; esac

if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
  printf 'unknown\n'
  exit 0
fi
pmset_bin="$(command -v pmset 2>/dev/null)" || { printf 'unknown\n'; exit 0; }

# Bounded, not `log="$(pmset -g log)"` unguarded: a caller that waits on this
# line (run-suite.sh's own watchdog, the Learning gate's suite task) must
# never be the one thing a wedged pmset can hang forever - 10s is generous
# for a command measured at ~1.3s even against a 30k-line log.
pmset_out="$(mktemp 2>/dev/null)" || { printf 'unknown\n'; exit 0; }
trap 'rm -f "$pmset_out"' EXIT
set -m
"$pmset_bin" -g log >"$pmset_out" 2>/dev/null &
pm_pid=$!
set +m
waited=0
while kill -0 "$pm_pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
if kill -0 "$pm_pid" 2>/dev/null; then
  kill -TERM -- "-$pm_pid" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-$pm_pid" 2>/dev/null || true
fi
wait "$pm_pid" 2>/dev/null || { printf 'unknown\n'; exit 0; }
log="$(cat "$pmset_out" 2>/dev/null)"
[ -n "$log" ] || { printf 'unknown\n'; exit 0; }

awk -v win_start="$start" -v win_end="$end" '
BEGIN {
  FS = "\t"
  saw_dated = 0
  any_sleep = 0
  ambiguous = 0
  overlap = 0
}
{
  n = split($1, w, " ")
  if (n < 4) next
  d = w[1]; t = w[2]; tz = w[3]
  if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
  if (t !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) next
  if (tz !~ /^[+-][0-9][0-9][0-9][0-9]$/) next
  saw_dated = 1
  kind = w[4]
  for (i = 5; i <= n; i++) kind = kind " " w[i]
  if (kind != "Sleep") next
  any_sleep = 1
  # the trailing "<N> secs" on a Sleep line is how long THIS sleep actually
  # lasted (verified against a real pmset log: the trailing number on each
  # Sleep line matches the gap to its next DarkWake).
  dur = -1
  if (NF >= 2 && match($2, /[0-9]+ secs[ \t]*$/)) {
    numtxt = substr($2, RSTART, RLENGTH)
    sub(/ secs[ \t]*$/, "", numtxt)
    dur = numtxt + 0
  }
  cmd = "date -j -f \"%Y-%m-%d %H:%M:%S %z\" \"" d " " t " " tz "\" +%s 2>/dev/null"
  epoch = ""
  cmd | getline epoch
  close(cmd)
  if (epoch !~ /^[0-9]+$/) { ambiguous = 1; next }
  s = epoch + 0
  if (dur < 0) {
    # A start time with no readable duration: ambiguous only if it could
    # still be the sleep the window is asking about. The caller measured
    # win_start while THIS process was running, i.e. the host was awake at
    # win_start - so any Sleep entry that started BEFORE win_start had
    # already ended by then and is irrelevant, no matter how old or
    # undated its own end is. A real pmset log carries years of such
    # duration-less lines (e.g. a line pmset never closed out before a
    # later reboot), and without this bound every one of them would make
    # every later window read ambiguous forever.
    if (s >= win_start && s <= win_end) ambiguous = 1
    next
  }
  e = s + dur
  lo = (s > win_start) ? s : win_start
  hi = (e < win_end) ? e : win_end
  if (hi > lo) overlap += (hi - lo)
}
END {
  if (!saw_dated) { print "unknown"; exit }
  if (overlap > 0) { printf "slept %d\n", overlap; exit }
  if (any_sleep && ambiguous) { print "slept"; exit }
  print "awake"
}
' <<<"$log"
