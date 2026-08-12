#!/usr/bin/env bash
# ac-fleet-new.test.sh - fleet home creation: answered knobs land in config/,
# an empty answer writes NO file (absence = the reader's default), enums re-ask
# instead of writing garbage, runtime workspace pins are never seeded, and every
# refusal happens before a single question is asked.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
container="$TMP/homes"

# --- every knob answered ------------------------------------------------------
home="$("$BIN/ac-fleet-new.sh" alpha --container "$container" 2>/dev/null <<'EOF'
TN
opus
ultracode
codex
gpt-5.6-sol
xhigh
always
staged
yes
EOF
)"

assert_eq "$home" "$container/alpha" "prints the home path on stdout"
for d in state data records config projects; do
  [ -d "$container/alpha/$d" ] || fail "missing $d/ in the seeded fleet"
done
assert_eq "$(cat "$container/alpha/config/backend")" "herdr" "backend seeded unasked - herdr is the fleet's only backend"
assert_eq "$(cat "$container/alpha/config/captain")" "TN" "captain knob"
assert_eq "$(cat "$container/alpha/config/model")" "opus" "model knob"
assert_eq "$(cat "$container/alpha/config/effort")" "ultracode" "effort knob"
assert_eq "$(cat "$container/alpha/config/gate-agent")" "codex" "gate-agent knob"
assert_eq "$(cat "$container/alpha/config/gate-model")" "gpt-5.6-sol" "gate-model knob"
assert_eq "$(cat "$container/alpha/config/gate-effort")" "xhigh" "gate-effort knob"
assert_eq "$(cat "$container/alpha/config/promote")" "always" "promote knob"
assert_eq "$(cat "$container/alpha/config/flow")" "staged" "flow knob"
assert_file "$container/alpha/CREWMATE.md" "per-fleet CREWMATE.md seeded on yes"
assert_contains "$(cat "$container/alpha/records/backlog.md")" "## In flight" "backlog skeleton"
assert_contains "$(cat "$container/alpha/records/projects.md")" "# Projects" "projects skeleton"
# The trap ac-home-seed.sh documents: a seeded workspace id would land this
# fleet's crew in whatever group that id names - another fleet's.
for k in herdr-workspace herdr-workspace-chiefs herdr-workspace-agents; do
  assert_no_file "$container/alpha/config/$k" "$k is a runtime pin - never seeded"
done

# --- every knob declined ------------------------------------------------------
printf '\n\n\n\n\n\n\n\n\n' | "$BIN/ac-fleet-new.sh" beta --container "$container" >/dev/null 2>&1

assert_eq "$(cat "$container/beta/config/backend")" "herdr" "backend is written even when everything else is declined"
for k in captain model effort gate-agent gate-model gate-effort promote flow; do
  assert_no_file "$container/beta/config/$k" "an empty answer writes no $k file - absence IS the reader's default"
done
assert_no_file "$container/beta/CREWMATE.md" "declined: the container-wide .claude/CLAUDE.md keeps applying"
assert_file "$container/beta/records/backlog.md" "skeletons are seeded regardless"

# --- a bad enum re-asks -------------------------------------------------------
# Ten answers for ten reads: the rejected `bogus` costs an extra one. Feeding
# nine let the run die on EOF at the last prompt while this assertion still
# passed off the earlier writes - the heredoc has to outlast every prompt.
printf '\n\n\nbogus\ncodex\n\n\n\n\n\n' | "$BIN/ac-fleet-new.sh" gamma --container "$container" >/dev/null 2>&1
assert_eq "$(cat "$container/gamma/config/gate-agent")" "codex" "a rejected enum re-asks rather than writing garbage into config/"

# --- refusals, all before the first question ----------------------------------
assert_fails "$BIN/ac-fleet-new.sh" alpha --container "$container"
assert_fails "$BIN/ac-fleet-new.sh" "bad name" --container "$container"
assert_fails "$BIN/ac-fleet-new.sh" delta --bogus-flag

# EOF on stdin must stop: taking the defaults would seed a fleet nobody
# described, and the run is unattended precisely when nobody is there to notice.
if "$BIN/ac-fleet-new.sh" delta --container "$container" </dev/null >/dev/null 2>&1; then
  fail "stdin at EOF must fail, not seed a fleet on silent defaults"
fi
assert_no_file "$container/delta" "a refused run leaves no half-seeded home behind"

# EOF landing on an ENUM prompt must fail exactly like EOF on a plain one.
# Separate case on purpose: errexit does not fire on a failing $()-assignment
# inside a function body running in a command substitution, so ask_enum has to
# propagate by hand. Without that it swallowed the EOF, read the empty result as
# "declined", and seeded the fleet anyway - green suite, silent defaults.
# Eight answers, so EOF lands on the LAST prompt, which is an enum. It has to be
# the last: EOF on an earlier enum is masked - the run dies moments later at the
# next PLAIN ask, where errexit does fire, so the exit code proves nothing.
if printf '\n\n\n\n\n\n\n\n' | "$BIN/ac-fleet-new.sh" epsilon --container "$container" >/dev/null 2>&1; then
  fail "EOF on an enum prompt must fail, not resolve to the declined default"
fi
assert_no_file "$container/epsilon" "the enum-EOF refusal leaves no home behind"

# A leading ~ must expand - a quoted --container never meets the caller shell's
# tilde expansion, and an unexpanded one seeds the fleet under a literal `~`
# directory in $PWD where nothing will ever look for it.
# shellcheck disable=SC2088  # passing an UNEXPANDED ~ is exactly what is under test
printf '\n\n\n\n\n\n\n\n\n' | HOME="$TMP" "$BIN/ac-fleet-new.sh" zeta --container '~/homes-tilde' >/dev/null 2>&1
[ -d "$TMP/homes-tilde/zeta" ] || fail "--container must expand a leading ~ against \$HOME"

pass
