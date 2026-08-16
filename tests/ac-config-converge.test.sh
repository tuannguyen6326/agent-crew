#!/usr/bin/env bash
# ac-config-converge.test.sh - crewdeputy config pull-convergence: declared
# knobs copy on drift and mirror parent absence, undeclared keys stay local,
# a second run is silent, and crewdeputy-home detection uses the seed marker.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"

make_home

parent="$TMP/parent-config"
mkdir -p "$parent"

# -- changed declared key converges (parent value wins) -------------------------
printf 'opus\n' >"$parent/model"
printf 'sonnet\n' >"$AC_HOME/config/model"
out="$(ac_config_converge_from_parent "$parent")"
assert_contains "$out" "converged: model" "drifted key reported"
assert_eq "$(cat "$AC_HOME/config/model")" "opus" "parent value wins"

# -- declared key missing downstream is copied in (non-flat name too) -----------
printf '{"rules":[]}\n' >"$parent/crew-dispatch.json"
out="$(ac_config_converge_from_parent "$parent")"
assert_contains "$out" "converged: crew-dispatch.json" "absent-downstream key copied"
assert_file "$AC_HOME/config/crew-dispatch.json" "copy landed"

# -- the gate judge's knobs travel as a SET: engine, model AND effort ------------
# gate-effort reached ac-gate.sh without reaching this list (2026-07-17), which
# left a crewdeputy judging with the parent's engine and model but its OWN
# effort - a quieter judge than the fleet pinned, silently. Pin the whole triple
# so a half-inherited judge cannot come back.
printf 'codex\n' >"$parent/gate-agent"
printf 'gpt-5.6-sol\n' >"$parent/gate-model"
printf 'xhigh\n' >"$parent/gate-effort"
out="$(ac_config_converge_from_parent "$parent")"
for k in gate-agent gate-model gate-effort; do
  assert_contains "$out" "converged: $k" "$k converges to the crewdeputy"
done
assert_eq "$(cat "$AC_HOME/config/gate-effort")" "xhigh" "the judge's effort pin reaches the crewdeputy"

# -- the two VERIFICATION roles travel as full triples too, same shape as gate --
# codereview/qa gained agent+effort knobs beside their model one and the pair was
# renamed to the gate-* shape (captain ruling, routed-pane-rules-for-gate-
# codereview-roomchief TASK 2). All three of each role must converge for the same
# reason gate-effort had to: a crewdeputy reviewing on its OWN harness or effort
# while inheriting the parent's model is a half-inherited judge, silently.
printf 'codex\n'       >"$parent/codereview-agent"
printf 'gpt-5.6-sol\n' >"$parent/codereview-model"
printf 'xhigh\n'       >"$parent/codereview-effort"
printf 'claude\n'      >"$parent/qa-agent"
printf 'opus\n'        >"$parent/qa-model"
printf 'high\n'        >"$parent/qa-effort"
out="$(ac_config_converge_from_parent "$parent")"
for k in codereview-agent codereview-model codereview-effort qa-agent qa-model qa-effort; do
  assert_contains "$out" "converged: $k" "$k converges to the crewdeputy"
done
assert_eq "$(cat "$AC_HOME/config/codereview-agent")" "codex" "the reviewer's harness pin reaches the crewdeputy"
assert_eq "$(cat "$AC_HOME/config/qa-effort")" "high" "the qa role's effort pin reaches the crewdeputy"
# The pre-rename names are NOT inheritable any more - a stale key left at a
# parent must not travel, or a deputy would keep reading a knob nothing resolves.
printf 'haiku\n' >"$parent/model-codereview"
printf 'haiku\n' >"$parent/model-qa"
out="$(ac_config_converge_from_parent "$parent")"
case "$out" in *"model-codereview"*|*"model-qa"*) fail "the pre-rename keys must not converge" ;; esac
assert_no_file "$AC_HOME/config/model-codereview" "the pre-rename codereview key never lands downstream"
assert_no_file "$AC_HOME/config/model-qa" "the pre-rename qa key never lands downstream"
rm -f "$parent/model-codereview" "$parent/model-qa"

# -- learn-every travels too (learning-loop tempo converges parent->crewdeputy) --
# Q7 pins learn-every into AC_INHERITABLE_CONFIG so a crewdeputy self-improves at
# the fleet's tempo; assert it converges (proves membership behaviorally).
printf '8\n' >"$parent/learn-every"
out="$(ac_config_converge_from_parent "$parent")"
assert_contains "$out" "converged: learn-every" "learn-every is inheritable"
assert_eq "$(cat "$AC_HOME/config/learn-every")" "8" "the fleet learning tempo reaches the crewdeputy"

# -- absent at parent -> removed downstream (absence-mirroring) ------------------
printf 'high\n' >"$AC_HOME/config/effort"
out="$(ac_config_converge_from_parent "$parent")"
assert_contains "$out" "removed: effort (absent at parent)" "absence mirrored"
assert_no_file "$AC_HOME/config/effort" "downstream key removed"

# -- undeclared keys are never touched, in either direction ----------------------
printf 'TN\n' >"$AC_HOME/config/captain"
printf 'my launch\n' >"$AC_HOME/config/launch-claude"
printf 'parent captain\n' >"$parent/captain"
printf 'parent launch\n' >"$parent/launch-codex"
out="$(ac_config_converge_from_parent "$parent")"
assert_eq "$(cat "$AC_HOME/config/captain")" "TN" "captain stays local"
assert_file "$AC_HOME/config/launch-claude" "local launch-* kept"
assert_no_file "$AC_HOME/config/launch-codex" "parent launch-* not pulled"
assert_file "$AC_HOME/config/wedge-alarm" "local override untouched"

# -- idempotent: converged state yields a silent run -----------------------------
out="$(ac_config_converge_from_parent "$parent")"
assert_eq "$out" "" "second run silent"

# -- missing parent dir refused ---------------------------------------------------
assert_fails ac_config_converge_from_parent "$TMP/no-such-dir"

# -- crewdeputy-home detection: seeded home yes, primary home no ------------------
assert_fails ac_is_crewdeputy_home   # primary home carries no marker
dep="$("$BIN/ac-home-seed.sh" dep1 --no-projects 2>/dev/null)"
assert_file "$dep/.ac-crewdeputy-home" "seed drops the marker"
(export AC_HOME="$dep"; ac_is_crewdeputy_home) || fail "seeded home not detected"

pass
