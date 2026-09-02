#!/usr/bin/env bash
# ac-harness-hooks.test.sh - the NON-claude primary-harness guard wiring:
# .codex/hooks.json, .opencode/plugins/, .pi/extensions/. The guard STACK is
# claude-first (.claude/settings.json); these surfaces carry the same fleet
# guards to a chief running codex/opencode/pi, so the machine layer no longer
# exists on one harness only. This test is the drift fence: every wired
# script must exist and be executable, the codex guard set must not fall
# behind the claude set, and the plugin/extension sources must stay
# syntactically loadable.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd -P)"

# --- .codex/hooks.json -------------------------------------------------------
cx="$root/.codex/hooks.json"
[ -f "$cx" ] || fail "missing $cx - a codex chief has no guard wiring"
jq -e . "$cx" >/dev/null 2>&1 || fail ".codex/hooks.json is not valid JSON"

cx_cmds="$(jq -r '[.hooks[][] | .hooks[]?.command] | .[]' "$cx")"
for g in ac-watch-policy-hook.sh ac-delegation-guard.sh ac-ledger-guard.sh \
         ac-primary-guard.sh; do
  case "$cx_cmds" in *"$g"*) ;; *) fail "codex PreToolUse wiring misses $g" ;; esac
done
case "$(jq -r '[.hooks.Stop[]?.hooks[]?.command] | .[]' "$cx")" in
  *ac-turnend-guard.sh*) ;;
  *) fail "codex Stop wiring misses ac-turnend-guard.sh" ;;
esac
# Every hook carries a timeout so a wedged guard can never pin the harness.
n_hooks="$(jq '[.hooks[][] | .hooks[]?] | length' "$cx")"
n_timeouts="$(jq '[.hooks[][] | .hooks[]? | select(.timeout != null)] | length' "$cx")"
assert_eq "$n_timeouts" "$n_hooks" "every codex hook carries a timeout"

# DRIFT FENCE: every guard script wired for claude PreToolUse must be wired
# for codex too (the payload family is shared). Claude-ONLY surfaces are
# exempt by mechanism, not by list: SessionStart (nudge) and asyncRewake
# (watch-autoarm) do not exist on codex.
cl="$root/.claude/settings.json"
while IFS= read -r script; do
  case "$cx_cmds" in *"$script"*) ;; *) fail "claude wires $script but codex does not - the guard sets drifted" ;; esac
done < <(jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$cl" | grep -o 'ac-[a-z-]*\.sh')

# Every script referenced by ANY of the three surfaces exists and executes.
refs="$(cat "$cx" "$root"/.opencode/plugins/*.js "$root"/.pi/extensions/*.ts 2>/dev/null \
  | grep -o 'ac-[a-z-]*\.sh' | sort -u)"
[ -n "$refs" ] || fail "no script references found across the harness surfaces"
while IFS= read -r s; do
  [ -x "$root/bin/$s" ] || fail "wired script bin/$s is missing or not executable"
done <<<"$refs"

# --- .opencode/plugins -------------------------------------------------------
# ONE plugin file carries both duties (one root resolution, one runner).
f="$root/.opencode/plugins/ac-primary-guards.js"
[ -f "$f" ] || fail "missing $f"
grep -q "ac-turnend-guard.sh" "$f" \
  || fail "opencode plugin does not run the turn-end guard"
grep -q "ac-watch-policy-hook.sh" "$f" \
  || fail "opencode plugin does not run the watch policy"

# --- .cursor/hooks.json ------------------------------------------------------
cu="$root/.cursor/hooks.json"
[ -f "$cu" ] || fail "missing $cu - a cursor chief has no guard wiring"
jq -e . "$cu" >/dev/null 2>&1 || fail ".cursor/hooks.json is not valid JSON"
# The shell seatbelt rides beforeShellExecution through the cursor ADAPTER:
# cursor's native payload carries .command (no claude tool_name/tool_input),
# so piping it raw into the watch policy is an inert guard - the adapter
# synthesizes the claude hook shape, exactly as the opencode and pi surfaces
# do in-process.
case "$(jq -r '[.hooks.beforeShellExecution[]?.command] | .[]' "$cu")" in
  *ac-watch-policy-cursor.sh*) ;;
  *) fail "cursor beforeShellExecution wiring misses the watch-policy adapter" ;;
esac
cadapter="$root/bin/ac-watch-policy-cursor.sh"
[ -x "$cadapter" ] || fail "missing or non-executable $cadapter"
rc=0; err="$(printf '{"command":"pkill -f ac-watch"}' | "$cadapter" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2" "a watcher-killing shell command is denied through the adapter"
assert_contains "$err" "watch" "the deny carries the policys own reason"
rc=0; printf '{"command":"ls -la"}' | "$cadapter" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "a benign command passes the adapter"
rc=0; printf 'not json' | "$cadapter" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "an unparseable payload fails open"
case "$(jq -r '[.hooks.stop[]?.command] | .[]' "$cu")" in
  *ac-turnend-guard-cursor.sh*) ;;
  *) fail "cursor stop wiring misses the turn-end adapter" ;;
esac
case "$(jq -r '[.hooks.sessionStart[]?.command] | .[]' "$cu")" in
  *ac-sessionstart-nudge.sh*) ;;
  *) fail "cursor sessionStart wiring misses the nudge" ;;
esac
# Cursor's stop hook cannot block and only a follow-up bounds the nag loop:
# the registration MUST carry Cursor's own loop_limit ceiling (the bound that
# survives a broken adapter).
jq -e '.hooks.stop[0].loop_limit != null' "$cu" >/dev/null \
  || fail "cursor stop registration carries no loop_limit"

# The stop ADAPTER: exit 2 is a silent no-op on cursor's stop, so the guard
# verdict must come back as one {"followup_message": ...} object - and the
# adapter's own ceiling must bite below the registered loop_limit.
adapter="$root/bin/ac-turnend-guard-cursor.sh"
[ -x "$adapter" ] || fail "missing or non-executable $adapter"
stub="$TMP/stub-guard.sh"
printf '#!/usr/bin/env bash\nprintf "beacon stale\\n" >&2\nexit 2\n' >"$stub"
chmod +x "$stub"
out="$(printf '{"loop_count":0}' | AC_TURNEND_GUARD_BIN="$stub" "$adapter")" \
  || fail "the adapter must exit 0 even when the guard objects"
jq -e '.followup_message' <<<"$out" >/dev/null 2>&1 \
  || fail "an objecting guard must surface as followup_message JSON: $out"
case "$(jq -r '.followup_message' <<<"$out")" in
  *"beacon stale"*) ;;
  *) fail "the follow-up must carry the guard's own reason" ;;
esac
out="$(printf '{"loop_count":99}' | AC_TURNEND_GUARD_BIN="$stub" "$adapter")"
[ -z "$out" ] || fail "past the in-script ceiling the adapter must go silent, not nag: $out"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub"
out="$(printf '{"loop_count":0}' | AC_TURNEND_GUARD_BIN="$stub" "$adapter")"
[ -z "$out" ] || fail "a clean guard verdict must emit nothing: $out"

# --- .pi/extensions ----------------------------------------------------------
f="$root/.pi/extensions/ac-primary-turnend-guard.ts"
[ -f "$f" ] || fail "missing $f"
grep -q "ac-turnend-guard.sh" "$f" || fail "pi extension does not run the turn-end guard"
grep -q "ac-watch-policy-hook.sh" "$f" || fail "pi extension does not run the watch policy"

# Syntax: every plugin/extension must transpile (bun does not typecheck, so a
# missing pi types package cannot fail this - only real syntax errors do).
if command -v bun >/dev/null 2>&1; then
  for f in "$root"/.opencode/plugins/*.js "$root"/.pi/extensions/*.ts; do
    bun build --no-bundle "$f" >/dev/null 2>&1 \
      || fail "harness plugin/extension does not parse: $f"
  done
fi

pass
