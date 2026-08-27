#!/usr/bin/env bash
# ac-root-symlink.test.sh - ac_root resolves the PHYSICAL checkout when a
# script is invoked through a symlinked bin/ (a fleet home symlinks the
# distro's bin/ so the chief runs with cwd = home; ac_root must keep naming
# the repo, not the home, or every "$(ac_root)/bin/..." reference in briefs
# and dispatch calls breaks).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
repo_root="$(cd "$BIN/.." && pwd -P)"

fakehome="$TMP/symlink-home"
mkdir -p "$fakehome"
ln -s "$BIN" "$fakehome/bin"

out="$(bash -c ". '$fakehome/bin/ac-lib.sh'; ac_root")"
assert_eq "$out" "$repo_root" "ac_root through a symlinked bin/ names the physical checkout"

# The direct (non-symlinked) invocation keeps its answer.
out="$(bash -c ". '$BIN/ac-lib.sh'; ac_root")"
assert_eq "$out" "$repo_root" "ac_root direct invocation unchanged"

pass
