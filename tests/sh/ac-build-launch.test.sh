#!/usr/bin/env bash
# ac-build-launch.test.sh - the SHARED harness-launch mote (bin/ac-backend.sh):
# ac_build_launch composes the per-harness launch command for every mechanism
# that starts an agent (ac-spawn's crewmates, ac-pane-agent's verification
# panes), and ac_resolve_profile is the one crew-dispatch resolution both of
# them share. Byte-level assertions: the whole point of the extraction is that
# the two mechanisms emit the SAME line for the same knobs.
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

lib() {
  # lib <script> - source the libs and run the script body.
  bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    . '$BIN/ac-backend.sh'
    $1
  "
}

# --- ac_build_launch: claude ---------------------------------------------------

assert_eq "$(lib 'ac_build_launch claude "" ""')" \
  "claude --permission-mode auto" "bare claude: no model, no effort, no session pin"
assert_eq "$(lib 'ac_build_launch claude opus high')" \
  "claude --permission-mode auto --model opus --effort high" "claude model+effort"

# The session PIN is the caller's, not the helper's: ac-spawn needs a known id
# to record in the meta, a one-shot pane turn harvests its id from the
# transcript instead. The helper owns only WHERE the flag sits.
assert_eq "$(lib 'ac_build_launch claude opus high "" s-123')" \
  "claude --permission-mode auto --session-id s-123 --model opus --effort high" \
  "a pinned session id lands before the model/effort flags"

# A resume ALWAYS wins over a pin: one claude line never carries both.
assert_eq "$(lib 'ac_build_launch claude opus high r-9')" \
  "claude --permission-mode auto --resume r-9 --model opus --effort high" "claude resume"
assert_eq "$(lib 'ac_build_launch claude "" "" r-9 s-123')" \
  "claude --permission-mode auto --resume r-9" "resume beats a session pin"

# --- ac_build_launch: the other built-ins --------------------------------------
# codex takes -m, and its effort rides its CONFIG override rather than a flag:
# codex has no --effort (verified `codex --help`, codex-cli 0.144.6), so the
# fleet's effort would otherwise be silently DROPPED and whatever the host's
# ~/.codex/config.toml pins would decide the reasoning tier.
# Every codex line also switches its startup update prompt off: codex 0.157
# takes the keys typed at that prompt as its options while herdr reads it idle,
# so a kickoff typed there lost its head up to the first `2` (Skip), and a `1`
# would run `brew upgrade` (harness-facts.md, codex UPDATE PROMPT).
assert_eq "$(lib 'ac_build_launch codex cmod high')" \
  "codex -c check_for_update_on_startup=false -m cmod -c model_reasoning_effort=high" \
  "codex gets -m plus the effort as a -c config override"
case "$(lib 'ac_build_launch codex cmod high')" in
  *--effort*) fail "codex must never get --effort: the flag does not exist" ;;
esac
assert_eq "$(lib 'ac_build_launch codex "" high')" \
  "codex -c check_for_update_on_startup=false -c model_reasoning_effort=high" \
  "codex effort stands alone when no model is pinned"
assert_eq "$(lib 'ac_build_launch codex cmod ""')" "codex -c check_for_update_on_startup=false -m cmod" \
  "an unset effort passes nothing, leaving codex's own default in charge"
assert_eq "$(lib 'ac_build_launch codex "" ""')" "codex -c check_for_update_on_startup=false" \
  "bare codex still launches with the update prompt off"
# opencode takes -m as well (`-m, --model <provider>/<model>`, `opencode --help`
# on opencode 1.18.4), but its effort has NO route into the interactive TUI the
# crewmate is launched with: `--variant` exists only on the `run` subcommand, so
# an effort passes nothing here and the exact-match below is what proves it.
assert_eq "$(lib 'ac_build_launch opencode omod high')" "opencode -m omod" \
  "opencode gets -m, and the effort is dropped for want of a TUI flag to ride"
assert_eq "$(lib 'ac_build_launch opencode "" ""')" "opencode" "bare opencode"

# pi (0.84.2, verified via its own --help): regular-TUI pin always, --model and
# --thinking ride when set - the fleet effort vocabulary passes through as the
# thinking tier unchanged.
assert_eq "$(lib 'ac_build_launch pi pmod xhigh')" "pi --tui-mode regular --model pmod --thinking xhigh" \
  "pi gets --model and --thinking with the regular-TUI pin"
assert_eq "$(lib 'ac_build_launch pi "" ""')" "pi --tui-mode regular" "bare pi keeps the TUI pin alone"

# cursor (cursor-agent 2026.05.05, verified via its own --help): the agent CLI
# is cursor-agent (bare `cursor` is the IDE launcher); --yolo always, --model
# when set, and effort is DROPPED - no flag exists (thinking rides model names).
assert_eq "$(lib 'ac_build_launch cursor cmod high')" "cursor-agent --yolo --model cmod" \
  "cursor gets --model on cursor-agent --yolo, and the effort is dropped"
assert_eq "$(lib 'ac_build_launch cursor "" ""')" "cursor-agent --yolo" "bare cursor launch"

# An unknown harness is refused, and the refusal names the way out.
err="$(lib 'ac_build_launch nope "" ""' 2>&1 || true)"
assert_contains "$err" "no launch template for harness 'nope'" "unknown harness refused"
assert_contains "$err" "launch-nope" "the refusal names the config template to create"

# --- ac_resolve_profile --------------------------------------------------------
# The shared wrapper over ac-dispatch-select.sh. An explicit knob always wins;
# with a dispatch table configured and no harness named it REFUSES to guess.

assert_eq "$(lib 'ac_resolve_profile')" $'harness=claude\tmodel=\teffort=' \
  "no config, no flag: claude"
printf 'codex\n' >"$AC_HOME/config/crew-harness"
assert_eq "$(lib 'ac_resolve_profile')" $'harness=codex\tmodel=\teffort=' \
  "no dispatch table: config/crew-harness"
assert_eq "$(lib 'ac_resolve_profile --harness claude')" $'harness=claude\tmodel=\teffort=' \
  "an explicit harness wins over config/crew-harness"
rm -f "$AC_HOME/config/crew-harness"

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {"when": "needs fresh web context", "use": {"harness": "grok", "model": "g1", "effort": "high"}}
  ],
  "default": {"harness": "codex", "model": "gpt", "effort": "medium"}
}
EOF

err="$(lib 'ac_resolve_profile' 2>&1 || true)"
assert_contains "$err" "ac-dispatch-select" "a configured dispatch table refuses to be guessed at"
assert_eq "$(lib 'ac_resolve_profile --harness claude --model opus --effort max')" \
  $'harness=claude\tmodel=opus\teffort=max' "named knobs never consult the dispatch table"
assert_eq "$(lib 'ac_resolve_profile --rule 1')" $'harness=grok\tmodel=g1\teffort=high' \
  "--rule resolves through ac-dispatch-select.sh"
assert_eq "$(lib 'ac_resolve_profile --rule 1 --model opus')" \
  $'harness=grok\tmodel=opus\teffort=high' "an explicit knob overrides the resolved rule, per knob"
# Callers capture the profile with $(...), where bash drops errexit, so a
# refused rule must stop the caller by status - not hand it an empty profile.
out="$(lib 'p="$(ac_resolve_profile --rule 9)"; printf "reached [%s]\n" "$p"' 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "1" "a refused --rule stops a caller that captures the profile"
assert_contains "$out" "ERROR: no rule 9" "the dispatcher's own refusal reaches the caller's stderr"
case "$out" in *reached*) fail "a refused --rule must not yield a profile: $out" ;; esac

# --- ac_pane_profile -----------------------------------------------------------
# The KEYED half of the same resolution, for the mechanisms that cannot judge a
# prose `when`. Its whole discipline is that ABSENT is silent and successful:
# every pane agent falls through to its own ladder on an empty answer, so a die
# or a stray word here would break the fleet that configured nothing.
pane_absent() {
  local out rc=0
  out="$(lib "ac_pane_profile $1" 2>/dev/null)" || rc=$?
  assert_eq "$rc" "0" "${2:-absent}: must exit 0, not die"
  assert_eq "$out" "" "${2:-absent}: must print nothing"
}
# A dispatch table WITHOUT a panes block never speaks for a pane: the rules[]
# above must not be borrowed for one.
pane_absent codereview "a rules-only dispatch table"

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "panes": {
    "codereview": {"harness": "claude", "model": "opus", "effort": "xhigh"},
    "qa": {"harness": "codex"}
  }
}
EOF
assert_eq "$(lib 'ac_pane_profile codereview')" $'harness=claude\tmodel=opus\teffort=xhigh' \
  "a panes entry resolves as the same triple every other rung speaks"
assert_eq "$(lib 'ac_pane_profile qa')" $'harness=codex\tmodel=\teffort=' \
  "harness-only stays harness-only: no model is inherited from anywhere"
pane_absent learning "a kind with no entry"
rm -f "$AC_HOME/config/crew-dispatch.json"
pane_absent codereview "no dispatch table at all"

pass
