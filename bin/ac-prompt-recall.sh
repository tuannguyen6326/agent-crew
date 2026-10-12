#!/usr/bin/env bash
# ac-prompt-recall.sh - prompt-time fleet-memory recall for a HUMAN-DRIVEN
# session (claude and codex UserPromptSubmit; cursor through
# bin/ac-prompt-recall-cursor.sh; the opencode and pi surfaces): the top brain
# recall hits and their freshness, plus a chief's pending-wake count, as
# context for the model; silent for every other shape. The authoritative spec
# is the header of src/prompt-recall.ts; this entry only starts it through
# bin/ac-bun.sh's ac_bun_exec_hook, so every wiring keeps this path, and no
# bun on PATH, a module that cannot load or a crash exits 0 - it never blocks
# a prompt. Always exits 0. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" || exit 0
ac_bun_exec_hook src/prompt-recall.ts "$@"
