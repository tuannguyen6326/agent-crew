#!/usr/bin/env bash
# ac-harness.test.sh - the per-harness registry (bin/ac-harness.sh, sourced by
# ac-lib.sh): the known set + its ERE twin, the FAIL-CLOSED instruction-file
# mapping (the audit-f5 defect: the old `*)` arm handed .claude/CLAUDE.md to
# any unknown harness, a file it never reads), the pane-arm map, the
# startup-dialog key, and the recorded-launch-opts policy (moved here from
# ac-lib.sh with the function).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

lib() { bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; $1"; }

# --- the known set and its ERE alternation stay in lockstep ------------------
for h in claude codex opencode; do
  lib "ac_harness_known $h" || fail "$h is a registry harness"
  case "$h" in
    claude | codex | opencode) ;;
  esac
  printf '%s' "$h" | grep -qE "^($(lib 'printf %s "$AC_HARNESS_RE"'))$" \
    || fail "AC_HARNESS_RE matches registry member $h"
done
lib "ac_harness_known tmux" && fail "a removed backend name is not a harness"
lib "ac_harness_known fake" && fail "an unregistered harness is unknown"

# --- instruction file: verified mappings, fail-closed unknown ----------------
assert_eq "$(lib "ac_harness_instruction_file claude")" ".claude/CLAUDE.md" "claude loads .claude/CLAUDE.md"
assert_eq "$(lib "ac_harness_instruction_file codex")" "AGENTS.md" "codex loads AGENTS.md and nothing else"
assert_eq "$(lib "ac_harness_instruction_file opencode")" "AGENTS.md" "opencode loads AGENTS.md (verified 2026-07-27)"
assert_eq "$(lib "ac_harness_instruction_file ''")" ".claude/CLAUDE.md" "an empty harness is the claude default"

# The audit-f5 defect, pinned: an unknown harness with NO custom launch
# template DIES at seed time instead of silently receiving a file it never
# reads - and the error names both the registry and the template escape.
assert_fails lib "ac_harness_instruction_file mysteryharness"
unk_err="$(lib "ac_harness_instruction_file mysteryharness" 2>&1 || true)"
assert_contains "$unk_err" "ac-harness.sh" "the refusal names the registry"
assert_contains "$unk_err" "launch-mysteryharness" "the refusal names the custom-template escape"

# A CUSTOM harness (config/launch-<h> exists) keeps .claude/CLAUDE.md by the
# template owner's documented convention - launchable without joining the set.
printf 'echo custom\n' >"$AC_HOME/config/launch-myharness"
assert_eq "$(lib "ac_harness_instruction_file myharness")" ".claude/CLAUDE.md" \
  "a custom launch-template harness keeps the claude-file convention"
rm -f "$AC_HOME/config/launch-myharness"

# --- pane arm: claude is a session, the crewmate pair is verified, rest refuse
assert_eq "$(lib "ac_harness_pane_arm claude")" "session" "claude arms as a pane session"
assert_eq "$(lib "ac_harness_pane_arm codex")" "crewmate" "codex arms through the crewmate contract"
assert_eq "$(lib "ac_harness_pane_arm opencode")" "crewmate" "opencode arms through the crewmate contract"
lib "ac_harness_pane_arm fake" 2>/dev/null && fail "an unverified harness gets no interactive arm"

# --- startup key: codex's dialog Enter, nothing anywhere else ----------------
assert_eq "$(lib "ac_harness_startup_key codex")" "Enter" "codex's startup dialog takes a bare Enter"
assert_eq "$(lib "ac_harness_startup_key claude")" "" "claude has no startup dialog"
assert_eq "$(lib "ac_harness_startup_key opencode")" "" "opencode has no startup dialog"
assert_eq "$(lib "ac_harness_startup_key someharness")" "" "an unknown harness gets no blind keypress"

# --- ac_record_launch_opts: the meta records only what the launch APPLIED ----
# (moved here from ac-lib.test.sh with the function, audit-f5)
rec() {
  # rec <harness> <model> <effort> [applied-effort] -> "model=<m> effort=<e>"
  local f="$TMP/rec.meta"
  rm -f "$f"
  lib "ac_record_launch_opts '$f' '$1' '$2' '$3' '${4:-}'"
  printf 'model=%s effort=%s\n' \
    "$(lib "ac_meta_get '$f' model")" "$(lib "ac_meta_get '$f' effort")"
}

assert_eq "$(rec claude cmod max)" "model=cmod effort=max" \
  "claude records both: --model and --effort are on its launch line"
assert_eq "$(rec codex xmod high)" "model=xmod effort=high" \
  "codex records effort too: -c model_reasoning_effort carries it to the process"
assert_eq "$(rec opencode omod high)" "model=omod effort=" \
  "opencode records model only: its interactive TUI has no --variant"
# effort=ultracode is a claude PRESET. ac-spawn.sh maps it to xhigh before the
# launch mote and types the '/effort ultracode' TUI line for claude ONLY, so a
# codex spawn at ultracode genuinely runs at xhigh - recording the raw preset
# would be exactly the false claim this contract exists to prevent.
assert_eq "$(rec codex xmod ultracode xhigh)" "model=xmod effort=xhigh" \
  "codex records the APPLIED tier, never the ultracode preset"
assert_eq "$(rec claude cmod ultracode xhigh)" "model=cmod effort=ultracode" \
  "claude records the raw preset: its TUI really is told 'ultracode'"

pass
