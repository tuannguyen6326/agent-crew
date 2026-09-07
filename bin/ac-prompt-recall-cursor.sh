#!/usr/bin/env bash
# ac-prompt-recall-cursor.sh - cursor `beforeSubmitPrompt` adapter for the
# prompt-time recall hook. Cursor hands this step the prompt as .prompt and
# reads ONE JSON object back: {"continue": true} lets the prompt through and
# an "additional_context" string rides into the model's context (the same
# carrier its sessionStart step uses). Plain stdout is not context on cursor,
# so bin/ac-prompt-recall.sh's block is wrapped here; every path emits the
# continue envelope and exits 0 - a recall must never hold a prompt.
# AC_PROMPT_RECALL_BIN overrides the hook path for tests only.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
hook="${AC_PROMPT_RECALL_BIN:-$(dirname "$0")/ac-prompt-recall.sh}"
block=""
if command -v jq >/dev/null 2>&1 && [ -x "$hook" ]; then
  block="$(printf '%s' "$payload" | "$hook" 2>/dev/null || true)"
fi
if [ -n "$block" ] && command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$block" '{continue: true, additional_context: $c}'
else
  printf '{"continue":true}\n'
fi
exit 0
