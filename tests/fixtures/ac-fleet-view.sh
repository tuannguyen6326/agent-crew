#!/usr/bin/env bash
# ac-fleet-view.sh - render the fleet as one line per crewmate.
#
# Usage: ac-fleet-view.sh
# Columns: id  kind  project  mode  state  window

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"
state_dir="$(ac_state_dir)"

# The meta list rides FD 3: the body shells ac-crew-state.sh (backend calls),
# and a body command that reads stdin would otherwise eat the list.
found=0
while IFS= read -r meta <&3; do
  found=1
  id="$(basename "$meta" .meta)"
  state="$("$bin_dir/ac-crew-state.sh" "$id" 2>/dev/null || printf 'unknown')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" \
    "$(ac_meta_get "$meta" kind)" \
    "$(ac_meta_get "$meta" project)" \
    "$(ac_meta_get "$meta" mode)" \
    "$state" \
    "$(ac_meta_get "$meta" window)"
done 3< <(ac_crew_metas "$state_dir" verify)
[ "$found" = 0 ] && printf 'no crewmates in flight\n'
exit 0
