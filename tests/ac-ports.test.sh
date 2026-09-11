#!/usr/bin/env bash
# ac-ports.test.sh - the fleet-wide port slot registry: every leased worktree
# gets one slot and a derived port range in <worktree>/.crew/ports.env, the
# same worktree keeps its slot across re-seeds, a released slot is reusable,
# a slot whose worktree vanished is reclaimed, and a self task's teardown
# releases its slot.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
repo="$(make_repo proj)"
state="$AC_HOME/state"

lib() { AC_HOME="$AC_HOME" bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; $1"; }

wt1="$TMP/wt1"; wt2="$TMP/wt2"; mkdir -p "$wt1" "$wt2"
r1="$(AC_PORT_BASE=30000 lib "ac_seed_ports_env '$wt1' alpha")"
r2="$(AC_PORT_BASE=30000 lib "ac_seed_ports_env '$wt2' beta")"
assert_eq "$r1" "30100-30199" "the first slot owns base+100..base+199"
assert_eq "$r2" "30200-30299" "a second worktree gets the next slot, whatever its project"
assert_contains "$(cat "$wt1/.crew/ports.env")" "AC_PORT_SLOT=1" "ports.env names the slot"
assert_contains "$(cat "$wt1/.crew/ports.env")" "PORT=30100" "ports.env names the first port for convenience"
assert_contains "$(cat "$wt1/.crew/ports.env")" "AC_PORT_RANGE=30100-30199" "ports.env names the range"
assert_eq "$(AC_PORT_BASE=30000 lib "ac_seed_ports_env '$wt1' alpha")" "30100-30199" \
  "re-seeding the same worktree keeps its slot"
assert_eq "$(wc -l <"$state/port-slots.tsv" | tr -d ' ')" "2" "one registry line per worktree"

# release frees the slot for the next allocation
lib "ac_port_slot_release '$wt1'"
wt3="$TMP/wt3"; mkdir -p "$wt3"
assert_eq "$(AC_PORT_BASE=30000 lib "ac_seed_ports_env '$wt3' gamma")" "30100-30199" \
  "a released slot is the lowest free one again"
lib "ac_port_slot_release '$TMP/never-seeded'"   # a no-op, never an error

# a vanished worktree's slot is reclaimed at the next allocation
rm -rf "$wt2"
wt4="$TMP/wt4"; mkdir -p "$wt4"
assert_eq "$(AC_PORT_BASE=30000 lib "ac_seed_ports_env '$wt4' delta")" "30200-30299" \
  "a slot whose worktree is gone is reclaimed"
case "$(cat "$state/port-slots.tsv")" in *"$wt2"*) fail "the vanished worktree's line must be dropped" ;; esac

# the seed rides a self-task start and the slot goes at teardown
"$BIN/ac-self-task.sh" start ps1 "$repo" >/dev/null
ps_wt="$(awk -F= '$1=="worktree"{print $2}' "$state/ps1.meta")"
assert_file "$ps_wt/.crew/ports.env" "a leased worktree carries .crew/ports.env"
assert_contains "$(cat "$state/port-slots.tsv")" "$ps_wt" "the lease is registered"
assert_eq "$(git -C "$ps_wt" status --porcelain)" "" "ports.env stays invisible to git status"
"$BIN/ac-teardown.sh" ps1 --force >/dev/null 2>&1
case "$(cat "$state/port-slots.tsv")" in *"$ps_wt"*) fail "teardown must release the slot" ;; esac

pass
