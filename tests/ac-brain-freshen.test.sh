#!/usr/bin/env bash
# ac-brain-freshen.test.sh - the watcher's brain-freshen slot: index freshness
# rides the MACHINE-guaranteed component (the watcher the Stop hook re-arms),
# not the chief's memory of a session-only CronCreate. A stale
# state/.brain-last-sync marker past the interval fires ONE fire-and-forget
# catch-up sync per interval; config/brain-auto-sync=off is the valve, and a
# home with no brain.sqlite never fires.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v bun >/dev/null 2>&1 || { printf 'SKIP: bun not available\n'; exit 0; }

make_home
printf 'the fleet learned a thing\n' >"$AC_HOME/records/learnings.md"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# 1) sync writes the freshness marker the bash side stats
"$BIN/ac-brain.sh" sync --home "$AC_HOME" --compact >/dev/null 2>&1
marker="$AC_HOME/state/.brain-last-sync"
[ -f "$marker" ] || fail "sync writes state/.brain-last-sync"

# 2) stale marker past the interval -> the watcher cycle fires a catch-up sync
touch -t 202601010000 "$marker"
old="$(mtime "$marker")"
AC_BRAIN_SYNC_IV=60 AC_POLL=1 "$BIN/ac-watch.sh" --once >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 150 ]; do
  [ "$(mtime "$marker")" -gt "$old" ] && break
  sleep 0.1; i=$((i + 1))
done
[ "$(mtime "$marker")" -gt "$old" ] || fail "stale marker fires a catch-up sync from the watcher"

# 3) valve off -> stale marker fires nothing
touch -t 202601010000 "$marker"
rm -f "$AC_HOME/state/.brain-freshen-attempt"
printf 'off\n' >"$AC_HOME/config/brain-auto-sync"
old="$(mtime "$marker")"
AC_BRAIN_SYNC_IV=60 AC_POLL=1 "$BIN/ac-watch.sh" --once >/dev/null 2>&1 || true
sleep 2
[ "$(mtime "$marker")" = "$old" ] || fail "brain-auto-sync=off is a real valve"
rm -f "$AC_HOME/config/brain-auto-sync"

# 4) one attempt per interval even when sync cannot move the marker: the
# attempt stamp throttles refires, so a broken sync never becomes a fork bomb
touch -t 202601010000 "$marker"
AC_BRAIN_SYNC_IV=3600 AC_POLL=1 "$BIN/ac-watch.sh" --once >/dev/null 2>&1 || true
attempt="$AC_HOME/state/watch/.brain-freshen-attempt"
[ -f "$attempt" ] || attempt="$(find "$AC_HOME/state" -name '.brain-freshen-attempt' 2>/dev/null | head -1)"
[ -n "$attempt" ] && [ -f "$attempt" ] || fail "an attempt stamp exists after a fire"
a1="$(mtime "$attempt")"
AC_BRAIN_SYNC_IV=3600 AC_POLL=1 "$BIN/ac-watch.sh" --once >/dev/null 2>&1 || true
sleep 1
assert_eq "$(mtime "$attempt")" "$a1" "a second cycle inside the interval does not refire"

# 5) no brain.sqlite -> never fires (DB existence is the opt-in)
rm -rf "$AC_HOME/state/brain.sqlite" "$marker"
AC_BRAIN_SYNC_IV=60 AC_POLL=1 "$BIN/ac-watch.sh" --once >/dev/null 2>&1 || true
sleep 1
assert_no_file "$marker" "no DB means the slot never fires"

pass
