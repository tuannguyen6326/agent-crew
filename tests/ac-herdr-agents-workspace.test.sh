#!/usr/bin/env bash
# ac-herdr-agents-workspace.test.sh - ac_herdr_agents_workspace (bin/ac-backend.sh)
# places a verification pane in its FAMILY's workspace (FAMILY WORKSPACE
# GROUPING): AC_WINDOW_FAMILY names the family and resolves adopt-by-label to
# "<fleet> · <family>"; absent/empty resolves to the fleet ROOT workspace
# "<fleet>". The retired config/herdr-workspace-agents knob is never read -
# a leftover knob file pointing at a foreign workspace must be inert.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
. "$BIN/ac-lib.sh"
. "$BIN/ac-backend.sh"

fleet="$(ac_fleet_name)"

mkws()   { herdr workspace create --label "$1" | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p'; }
wslabel() { herdr workspace get "$1" 2>/dev/null | sed -n 's/.*"label":"\([^"]*\)".*/\1/p'; }

# --- (1) a named family adopts its existing family workspace -------------------
famwid="$(mkws "$fleet · fam1")"
got="$(AC_WINDOW_FAMILY=fam1 ac_herdr_agents_workspace)"
assert_eq "$got" "$famwid" "a named family adopts the existing family workspace"

# --- (2) a family with no workspace yet creates one ----------------------------
got="$(AC_WINDOW_FAMILY=fam2 ac_herdr_agents_workspace)"
assert_eq "$(wslabel "$got")" "$fleet · fam2" "an absent family workspace is created with the family label"

# --- (3) absent/empty family resolves to the fleet ROOT workspace --------------
got="$(ac_herdr_agents_workspace)"
assert_eq "$(wslabel "$got")" "$fleet" "no family resolves to the fleet root workspace"
got2="$(AC_WINDOW_FAMILY="" ac_herdr_agents_workspace)"
assert_eq "$got2" "$got" "an empty family is the same root workspace (adopted, not duplicated)"

# --- (4) the retired knob is inert ---------------------------------------------
otherwid="$(mkws "other-fleet · fam1")"
printf '%s\n' "$otherwid" >"$AC_HOME/config/herdr-workspace-agents"
got="$(AC_WINDOW_FAMILY=fam1 ac_herdr_agents_workspace)"
[ "$got" != "$otherwid" ] \
  || fail "a leftover herdr-workspace-agents knob must never route the resolve"
assert_eq "$got" "$famwid" "resolution stays adopt-by-label with the knob present"

pass
