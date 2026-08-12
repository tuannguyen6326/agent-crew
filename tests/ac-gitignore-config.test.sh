#!/usr/bin/env bash
# .gitignore must ignore config/ as a DIRECTORY, never by exact filename.
# The per-filename list drifted every time a knob shipped (codereview-agent,
# qa-*, gate-*, room-parallel, learn-every, ... were all unignored), and a
# `git add -A` sweep is one commit away from leaking a local pin. Behavioral
# assertions only: git's own answer for a knob that does not exist yet is the
# contract, not the .gitignore's text.
set -u
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# A knob that no .gitignore filename list could have anticipated is ignored.
future_knob="config/knob-invented-after-this-test-$$"
status="$(git -C "$REPO_ROOT" check-ignore -q "$future_knob"; printf '%s' "$?")"
assert_eq "$status" "0" "a future config knob is ignored without a .gitignore edit"

# Every knob name the tooling reads today is ignored, including the drifted
# set the filename list missed (AC_INHERITABLE_CONFIG in bin/ac-lib.sh names
# most of them; the rest appear in bin/ headers).
for knob in backend crew-harness crew-dispatch.json launch-claude \
  herdr-session herdr-workspace herdr-workspace-chiefs herdr-workspace-agents \
  wedge-alarm captain flow promote model effort \
  codereview-agent codereview-model codereview-effort \
  qa-agent qa-model qa-effort gate-agent gate-model gate-effort \
  epic-parallel room-parallel learn-every curate-every \
  remote-poll remote-mirror; do
  git -C "$REPO_ROOT" check-ignore -q "config/$knob" \
    || fail "config/$knob is not ignored"
done

# Nothing under config/ is tracked - the directory switch strands no file.
assert_eq "$(git -C "$REPO_ROOT" ls-files config/ | wc -l | tr -d ' ')" "0" \
  "no tracked file lives under config/"

pass
