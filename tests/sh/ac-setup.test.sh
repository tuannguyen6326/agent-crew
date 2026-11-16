#!/usr/bin/env bash
# ac-setup.test.sh - machine setup: container and launcher land where the
# captain says, dotfiles are never touched, a mismatched container is warned
# about rather than silently installed, and no fleet is created.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
make_fake_orca        # ac-setup re-runs the toolchain doctor, which needs the backend

container="$TMP/homes"
dest="$TMP/zsh/ac.zsh"
printf '# untouched\n' >"$TMP/.zshrc"

# HOME is redirected into $TMP so a wrong default can only ever hit the sandbox.
# The doctor's exit status rides out of ac-setup (gh may be unauthenticated on
# any given box), so the run is tolerated - the install steps are what is asserted.
out="$(printf '%s\n%s\n' "$container" "$dest" | HOME="$TMP" "$BIN/ac-setup.sh" 2>&1 || true)"

[ -d "$container" ] || fail "container not created at the asked path"
assert_file "$dest" "launcher installed at the asked path"
assert_contains "$(cat "$dest")" "_ac_home" "the installed launcher is the repo's docs/examples/ac.zsh"
assert_contains "$out" "source $dest" "prints the source line for the captain to paste"
assert_eq "$(cat "$TMP/.zshrc")" "# untouched" "never edits a dotfile - the captain pastes the line themselves"
assert_eq "$(ls "$container")" "" "setup creates no fleet - that is ac-fleet-new.sh's job"
# The launcher hardcodes ~/Work/ac-homes; installed against another container it
# would fail later as "ac: no fleet at ...", so the mismatch has to be said now.
assert_contains "$out" "hardcodes" "a container off the launcher's hardcoded path is warned about"

# Re-running is how an installed launcher is UPDATED: the repo copy wins.
printf 'stale\n' >"$dest"
printf '%s\n%s\n' "$container" "$dest" | HOME="$TMP" "$BIN/ac-setup.sh" >/dev/null 2>&1 || true
assert_contains "$(cat "$dest")" "_ac_home" "re-running overwrites an installed launcher from the repo copy"

# A typed ~ must expand: the answer never meets the shell's own tilde
# expansion, so an unexpanded one mkdir's a literal `~` dir under $PWD and
# reports success for a path the launcher will never read.
# shellcheck disable=SC2088  # feeding an UNEXPANDED ~ is exactly what is under test
printf '~/homes-tilde\n~/zsh-tilde/ac.zsh\n' | HOME="$TMP" "$BIN/ac-setup.sh" >/dev/null 2>&1 || true
[ -d "$TMP/homes-tilde" ] || fail "a typed ~ container must expand against \$HOME"
assert_file "$TMP/zsh-tilde/ac.zsh" "a typed ~ launcher path must expand too"

# EOF on stdin must stop rather than install against silent defaults. HOME stays
# redirected for the CHECK itself: the whole point is that this path writes a
# container and a launcher, so a regressed guard must land in the sandbox and
# not overwrite the operator's real ~/.config/zsh while proving it regressed.
if HOME="$TMP" "$BIN/ac-setup.sh" </dev/null >/dev/null 2>&1; then
  fail "stdin at EOF must fail, not run on silent defaults"
fi
assert_fails "$BIN/ac-setup.sh" --bogus-flag

pass
