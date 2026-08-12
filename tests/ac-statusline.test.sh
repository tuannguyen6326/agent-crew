#!/usr/bin/env bash
# ac-statusline.test.sh - the status-bar one-liner: fleet name, in-flight
# count, pending-captain rooms, and the unwatched-fleet warning.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 0▶ 0⚑" "idle fleet"

# One crewmate in flight with a fresh beacon: no warning.
printf 'window=x\n' >"$AC_HOME/state/t1.meta"
date +%s >"$AC_HOME/state/.last-watcher-beat"
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 0⚑" "in-flight counted"

# Verifier panes are visible to supervision but excluded from crew accounting
# and the human-oriented crewmate list.
printf 'kind=verify-codereview\nwindow=vfy\n' >"$AC_HOME/state/vfy.meta"
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 0⚑" "verifier excluded from in-flight count"
case "$("$BIN/ac-fleet-view.sh")" in
  *vfy*) fail "verifier must not render as a crewmate in fleet view" ;;
esac

# Stale beacon while crew flies: WATCH! warning.
printf '0\n' >"$AC_HOME/state/.last-watcher-beat"
assert_contains "$("$BIN/ac-statusline.sh")" "WATCH!" "unwatched fleet flagged"

# The indicator tracks the watcher serving THIS session. A roomchief always
# has AC_SCOPE in env, so reading the fleet beat would show it someone else's
# liveness - the deception the per-scope beacon exists to remove, on the most
# glanceable surface.
date +%s >"$AC_HOME/state/.last-watcher-beat"          # fleet watcher: alive
printf '0\n' >"$AC_HOME/state/.last-watcher-beat.fam1" # its OWN watcher: dead
assert_contains "$(AC_SCOPE=fam1 "$BIN/ac-statusline.sh")" "WATCH!" \
  "a roomchief sees its OWN watcher down despite a fresh fleet beat"
assert_eq "$(env -u AC_SCOPE "$BIN/ac-statusline.sh")" "⚓home 1▶ 0⚑" \
  "and the fleet session is not flagged by a family's dead watcher"
date +%s >"$AC_HOME/state/.last-watcher-beat.fam1"
printf '0\n' >"$AC_HOME/state/.last-watcher-beat"
assert_eq "$(AC_SCOPE=fam1 "$BIN/ac-statusline.sh")" "⚓home 1▶ 0⚑" \
  "a fresh family beat keeps the roomchief unflagged while the fleet's is stale"
rm -f "$AC_HOME/state/.last-watcher-beat.fam1"
date +%s >"$AC_HOME/state/.last-watcher-beat"

# Open gate raises the pending count; DECIDED clears it.
"$BIN/ac-room.sh" post t1 crewchief "GATE: spec awaiting captain" >/dev/null
assert_contains "$("$BIN/ac-statusline.sh")" "1⚑" "pending gate counted"
"$BIN/ac-room.sh" post t1 captain "DECIDED: approve" >/dev/null
assert_contains "$("$BIN/ac-statusline.sh")" "0⚑" "decided clears pending"

# The badge must accept the ATTRIBUTED form too. It is not exotic: section 8's
# attribution echo and the remote-orders skill both MANDATE `DECIDED <family>:`,
# so on a remote fleet effectively every ruling wears it. A badge that cannot
# count it is stuck forever - room.md is append-only and `close` does not erase
# the phantom - which contradicts `ac-room.sh list` on the same bytes and trains
# the captain to stop reading the one surface AGENTS.md:650 needs at zero.
# Reuse t1: the statusline SUMS every room, so a fresh family would shift the
# total. assert_eq on the WHOLE string - "0⚑" alone also matches "10⚑".
"$BIN/ac-room.sh" post t1 crewchief "GATE: plan awaiting captain" >/dev/null
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 1⚑" "second gate counted"
"$BIN/ac-room.sh" post t1 captain "DECIDED t1: approve" >/dev/null
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 0⚑" "attributed decision clears pending"

# The colon is the verb: a bare `DECIDED` settles nothing (ac_room_pending's
# contract, ac-lib.sh). Pinned so widening the grammar never loosens it.
# `post` itself now REFUSES to author this malformed line (ac-room.sh
# cmd_post's write-time guard), so it is appended directly here, bypassing
# post, to prove the READ-side matcher (ac_room_pending, what the statusline
# reads) still tolerates a malformed line already on disk.
"$BIN/ac-room.sh" post t1 crewchief "ASK: which database?" >/dev/null
assert_fails "$BIN/ac-room.sh" post t1 captain "DECIDED postgres, no colon here"
printf -- '- [%s] captain> DECIDED postgres, no colon here\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>"$AC_HOME/data/t1/room.md"
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 1⚑" "a colonless DECIDED settles nothing"
"$BIN/ac-room.sh" post t1 captain "DECIDED t1: postgres" >/dev/null
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 0⚑" "and the attributed form settles the ask"

# The badge is the authoritative accounting or it is a lie: pin it to
# `ac-room.sh pending` on the very same bytes. This is what actually catches
# the next drift - the two surfaces may never disagree.
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ $("$BIN/ac-room.sh" pending t1)⚑" \
  "the badge agrees with the authoritative pending count"

# Item 2 (perf audit): the statusline must call ac_room_pending ONCE, batched
# over every room.md, not once per room in a loop - ac-lib.sh's own docstring
# on ac_room_pending exists to prevent exactly that ("a per-room fork would
# grow without bound on a hook that always runs"). A second room with its own
# open gate must still sum correctly with t1's, proving the batched call
# reproduces the old per-file-sum result across MULTIPLE rooms, not just one.
"$BIN/ac-room.sh" post t2 crewchief "GATE: spec awaiting captain" >/dev/null
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 1▶ 1⚑" "a second room's pending gate sums with t1's"

# Prove it is actually ONE call, not two summed in bash: shim `awk` (what
# ac_room_pending forks) to count its own invocations, with zero crew metas
# in flight so the inflight loop contributes none, isolating the count to
# the pending-rooms computation alone. Two rooms exist (t1, t2) above.
rm -f "$AC_HOME/state/t1.meta" "$AC_HOME/state/vfy.meta"
awkcount="$TMP/awk-calls"
mkdir -p "$TMP/awkstub"
: >"$awkcount"
cat >"$TMP/awkstub/awk" <<STUB
#!/usr/bin/env bash
printf '.' >>"$awkcount"
exec /usr/bin/awk "\$@"
STUB
chmod +x "$TMP/awkstub/awk"
PATH="$TMP/awkstub:$PATH" "$BIN/ac-statusline.sh" >/dev/null
assert_eq "$(wc -c <"$awkcount" | tr -d ' ')" "1" \
  "ac-statusline.sh forks awk exactly once for 2 rooms, not once per room"

"$BIN/ac-room.sh" post t2 captain "DECIDED t2: approve" >/dev/null
assert_eq "$("$BIN/ac-statusline.sh")" "⚓home 0▶ 0⚑" "and t2's own decision clears t2's pending, leaving both rooms settled"

# --- ac_watcher_down agreement: WATCH! and WATCHER-DOWN share ONE predicate --
# (audit-f4) The same AC_GUARD_GRACE env used to carry TWO defaults - the
# guard's 90 against the fleet-wide 300 - and two in-flight sets, so a beacon
# aged inside the ordinary exit->re-arm gap raised WATCHER-DOWN while the
# status bar stayed calm about the same fleet. Both surfaces now call
# ac_watcher_down (ac-wake-lib.sh); these pin the agreement in BOTH regimes.
export AC_GUARD_ROOT="$(make_repo sl-guard-root)"   # pin the guard's tangle check off the real checkout
guard_sl() { AC_GUARD_QUIET=0 "$BIN/ac-guard.sh" 2>&1; }

printf 'kind=ship\n' >"$AC_HOME/state/ag1.meta"
printf '%s\n' "$(( $(date +%s) - 150 ))" >"$AC_HOME/state/.last-watcher-beat"
case "$("$BIN/ac-statusline.sh")" in *WATCH!*) fail "150s beacon is inside the unified 300s grace - no WATCH!" ;; esac
case "$(guard_sl)" in *WATCHER-DOWN*) fail "guard must agree: 150s is inside the unified 300s grace" ;; esac

printf '%s\n' "$(( $(date +%s) - 400 ))" >"$AC_HOME/state/.last-watcher-beat"
assert_contains "$("$BIN/ac-statusline.sh")" "WATCH!" "past the grace both surfaces fire: WATCH!"
assert_contains "$(guard_sl)" "WATCHER-DOWN" "past the grace both surfaces fire: WATCHER-DOWN"

# A chief SELF TASK owes no watcher (the SELF-TASK block, ac-lib.sh) but stays
# in ACCOUNTING: alone it raises neither surface while still rendering as 1▶.
rm -f "$AC_HOME/state/ag1.meta" "$AC_HOME/state/.last-watcher-beat" "$AC_HOME/state/.guard-stamp"
printf 'kind=self\n' >"$AC_HOME/state/selft.meta"
out_sl="$("$BIN/ac-statusline.sh")"
assert_contains "$out_sl" "1▶" "a self task still renders in the accounting count"
case "$out_sl" in *WATCH!*) fail "a self task alone owes no watcher - no WATCH!" ;; esac
case "$(guard_sl)" in *WATCHER-DOWN*) fail "guard agrees: a self task alone raises no WATCHER-DOWN" ;; esac
rm -f "$AC_HOME/state/selft.meta"

pass
