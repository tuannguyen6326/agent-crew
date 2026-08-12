#!/usr/bin/env bash
# ac-setup.test.sh - machine setup: container and launcher land where the
# captain says, dotfiles are never touched, a mismatched container is warned
# about rather than silently installed, and no fleet is created.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
make_fake_herdr        # ac-setup re-runs the toolchain doctor, which needs the backend

container="$TMP/homes"
dest="$TMP/zsh/ac.zsh"
printf '# untouched\n' >"$TMP/.zshrc"

# Stub the captain tools PRESENT, so the prompt count is a property of this test
# and not of the box: every absent tool adds an install offer, and on a machine
# without wezterm those offers would silently eat the container and launcher
# answers below, leaving the run to die on EOF somewhere unrelated.
printf '#!/bin/sh\n' >"$TMP/stubbin/wezterm"; chmod +x "$TMP/stubbin/wezterm"

# HOME is redirected into $TMP so a wrong default can only ever hit the sandbox.
# The doctor's exit status rides out of ac-setup (gh may be unauthenticated on
# any given box), so the run is tolerated - the install steps are what is asserted.
out="$(printf '%s\n%s\n' "$container" "$dest" | HOME="$TMP" "$BIN/ac-setup.sh" 2>&1 || true)"

[ -d "$container" ] || fail "container not created at the asked path"
# The captain's own tools are reported by setup, not by the doctor: the doctor
# gates every session start, where a line about either would be noise the crew
# cannot act on. Asserted per BRANCH, because the box running the suite may well
# have them - wezterm is probed via /Applications/WezTerm.app too, which no $PATH
# can hide. Either way the tool must be named, so deleting the check still fails.
case "$out" in
  *"OK: wezterm"*) ;;
  *"OPTIONAL: wezterm missing - brew install --cask wezterm"*) ;;
  *) fail "setup must report wezterm - present, or missing with the cask command" ;;
esac
# Advisory, never fatal: the gap blocks no fleet, so it may not be reported
# as MISSING (which is the doctor's word for "nothing runs without this").
case "$out" in *"MISSING: wezterm"*) fail "captain tools are optional - herdr renders anywhere" ;; esac

# Forced-missing run on a restricted PATH: nothing is present and neither brew
# nor npm exists, so setup has nothing to offer and must fall back to advice.
# No installer means no prompt, which keeps this run's answer count fixed.
bare="$(printf '%s\n%s\n' "$TMP/homes2" "$TMP/zsh2/ac.zsh" | PATH=/usr/bin:/bin HOME="$TMP" "$BIN/ac-setup.sh" 2>&1 || true)"
assert_contains "$bare" "brew install herdr" "a missing backend says how to install it - the old hint named config/backend and left the operator stuck"
assert_contains "$bare" "no brew here" "with no installer there is nothing to offer, only advice"

# The install path itself, driven against a STUB brew so the suite never
# installs anything. herdr is the captain tool a $PATH can fully hide: wezterm
# is probed via /Applications/WezTerm.app too, which no PATH can take away.
#
# PATH is pinned to stubbin + the system dirs rather than just dropping the
# stub: the box's REAL herdr lives in a brew bin dir on the inherited PATH, so
# removing the stub would hide nothing, no offer would be made, and the `yes`
# below would be swallowed by the container prompt - which then makes a
# directory called `yes`.
mv "$TMP/stubbin/herdr" "$TMP/herdr.saved"
cat >"$TMP/stubbin/brew" <<EOF
#!/bin/sh
printf 'brew %s\n' "\$*" >>"$TMP/brew.log"
EOF
chmod +x "$TMP/stubbin/brew"
SETUP_PATH="$TMP/stubbin:/usr/bin:/bin"

: >"$TMP/brew.log"
printf 'yes\n%s\n%s\n' "$TMP/homes3" "$TMP/zsh3/ac.zsh" | PATH="$SETUP_PATH" HOME="$TMP" "$BIN/ac-setup.sh" >/dev/null 2>&1 || true
assert_contains "$(cat "$TMP/brew.log")" "brew install herdr" "an accepted offer runs the installer"
[ -d "$TMP/homes3" ] || fail "the answers after an offer must still land - the offer must not eat them"

# Declining must install nothing - the default, so an unattended run is inert.
: >"$TMP/brew.log"
printf 'no\n%s\n%s\n' "$TMP/homes4" "$TMP/zsh4/ac.zsh" | PATH="$SETUP_PATH" HOME="$TMP" "$BIN/ac-setup.sh" >/dev/null 2>&1 || true
case "$(cat "$TMP/brew.log")" in *"install herdr"*) fail "a declined offer must not install" ;; esac
: >"$TMP/brew.log"
printf '\n%s\n%s\n' "$TMP/homes5" "$TMP/zsh5/ac.zsh" | PATH="$SETUP_PATH" HOME="$TMP" "$BIN/ac-setup.sh" >/dev/null 2>&1 || true
case "$(cat "$TMP/brew.log")" in *"install herdr"*) fail "an empty answer defaults to no - setup must never install unasked" ;; esac
mv "$TMP/herdr.saved" "$TMP/stubbin/herdr"
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
