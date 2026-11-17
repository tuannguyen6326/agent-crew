#!/usr/bin/env bash
# ac-launcher.test.sh - the `ac` zsh launcher (docs/examples/ac.zsh): the
# ORCA chief path only. docs/ is out of scope for this suite, so the
# launcher's herdr branch - which sources bin/ac-backend.sh and calls
# herdr_resolve_workspace/herdr_close_default_tabs, neither of which that
# file defines - is dead on arrival (bash's 127 under `set -e`) and left
# unfixed and unproven here.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v zsh >/dev/null 2>&1 || skip 'zsh not available'

home="$TMP/h"
mkdir -p "$home/Work/ac-homes/lab/state" "$home/Work/ac-homes/lab/config"
# The launcher resolves the distro at ~/Work/agent-crew, the installed layout.
ln -s "$ROOT" "$home/Work/agent-crew"

# config/compact-pct lowers the CHIEF's own auto-compact threshold on both
# chief paths; a solo session is the captain's own and keeps the default.
printf '80\n' >"$home/Work/ac-homes/lab/config/compact-pct"
chief_env() { # chief_env <solo> - the environment the orca chief execs with
  env -u HERDR_ENV -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE HOME="$home" PATH="$TMP/stubbin:$PATH" \
    zsh -f -c "source '$ROOT/docs/examples/ac.zsh'; _ac_home lab env '' orca '$1'" 2>/dev/null
}
assert_contains "$(chief_env '')" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80" "the orca chief runs with the threshold"
case "$(chief_env 1)" in
  *CLAUDE_AUTOCOMPACT_PCT_OVERRIDE*) fail "a solo session must keep the default threshold" ;;
esac

pass
