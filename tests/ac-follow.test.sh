#!/usr/bin/env bash
# ac-follow.test.sh - transcript renderer: text, tool calls, results,
# errors, clipping; meta resolution errors for non-claude/missing tasks.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

fx="$TMP/session.jsonl"
long="$(python3 -c 'print("x" * 2000)')"
cat >"$fx" <<EOF
{"type":"user","message":{"content":"read the brief and begin"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the spec now."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash tests/greet.test.sh"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"ALL PASS (14 cases)"}],"is_error":false}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"boom"}],"is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"$long"}}]}}
EOF

out="$("$BIN/ac-follow.sh" --render "$fx")"
assert_contains "$out" "user: read the brief" "user line"
assert_contains "$out" "Reading the spec now." "assistant text"
assert_contains "$out" "tool Bash" "tool call named"
assert_contains "$out" "ALL PASS (14 cases)" "tool result"
assert_contains "$out" "ERR boom" "error result marked"
assert_contains "$out" "chars]" "huge payloads clipped"

# Meta resolution: non-claude refused, missing meta refused.
printf 'worktree=/tmp/x\nharness=fake\n' >"$AC_HOME/state/f1.meta"
assert_fails "$BIN/ac-follow.sh" f1
assert_fails "$BIN/ac-follow.sh" nosuch

# The followed dir sits under the transcript root the pane's claude wrote to -
# CLAUDE_CONFIG_DIR's, not a hard-wired ~/.claude. A stub python3 stands in
# for the (endless) dir-mode renderer and just echoes what it was handed.
fpy="$TMP/fakepy"; mkdir -p "$fpy"
printf '#!/bin/sh\necho "renderer $*"\n' >"$fpy/python3"; chmod +x "$fpy/python3"
printf 'worktree=/tmp/wt.x\nharness=claude\n' >"$AC_HOME/state/f2.meta"
out="$(env -u AC_CLAUDE_TRANSCRIPT_ROOT PATH="$fpy:$PATH" CLAUDE_CONFIG_DIR="$TMP/cfg" "$BIN/ac-follow.sh" f2 2>&1)"
assert_contains "$out" "renderer -u - dir $TMP/cfg/projects/-tmp-wt-x" "follows the transcripts under CLAUDE_CONFIG_DIR"

pass
