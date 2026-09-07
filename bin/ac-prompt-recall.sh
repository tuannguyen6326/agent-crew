#!/usr/bin/env bash
# ac-prompt-recall.sh - prompt-time fleet-memory recall for a HUMAN-DRIVEN
# session. Runs between the captain's prompt and the model's first read (the
# claude/codex UserPromptSubmit hook; cursor's beforeSubmitPrompt through
# bin/ac-prompt-recall-cursor.sh; pi before_agent_start and opencode
# chat.message through their extension/plugin), so a chief or solo session
# meets the home's history before it acts instead of remembering to ask -
# the knowledge law names `ac-brain.sh recall` at intake, and a law with no
# machine behind it measurably went unused for whole sessions.
#
# Stdin: the harness payload; the prompt is read from .prompt (claude, codex,
# cursor) with .user_message/.text as fallbacks. Stdout: at most ONE short
# block - the top hits with path, trust label and snippet, plus a freshness
# line - which the harness hands the model as context. Empty stdout is the
# common case and means "nothing to add".
#
# SCOPE is the session's SHAPE, never the registration: the fleet settings
# file is copied into every crewmate worktree (ac_seed_crew_settings), so
# this hook runs there too and must self-scope. It fires for the two shapes
# a human types into - a solo session (AC_SOLO=1, any cwd) and a chief whose
# cwd is the fleet home (crewchief or a scoped roomchief) - and is silent
# for everything else: a crewmate's prompts are briefs the chief already
# grounded and cited, and recalling again there is noise on top of cost.
#
# NOISE GATES, because a per-prompt reader pays context on every turn: no
# brain (DB existence is the opt-in), config/brain-prompt-recall=off (the
# valve), slash and bang prompts, prompts under 12 chars or with fewer than
# two content words, and zero hits all print nothing. AC_PROMPT_RECALL_LIMIT
# caps the hits (default 3); snippets are cut at 140 chars.
#
# FRESHNESS: the block names the marker's age, calls it STALE past
# AC_BRAIN_SYNC_IV, and fires the shared catch-up sync (ac_brain_freshen,
# one throttle with the watcher) so a stale brain is at most one turn old
# by the next prompt. Solo sessions never sync otherwise - a solo home with
# no chief measurably sat 11 days stale.
#
# Attribution: the usage line says who asked - solo, <fam>-chief under
# AC_SCOPE, else crewchief. Fails OPEN on every missing dependency and never
# blocks a prompt: exit 0 always.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "$0")/ac-lib.sh" 2>/dev/null || exit 0
home="$(ac_home 2>/dev/null)" || exit 0

# Shape gate.
by=""
if [ "${AC_SOLO:-}" = 1 ]; then
  by=solo
else
  here="$(pwd -P 2>/dev/null || true)"
  home_p="$(cd "$home" 2>/dev/null && pwd -P || true)"
  [ -n "$here" ] && [ "$here" = "$home_p" ] || exit 0
  by="${AC_SCOPE:+${AC_SCOPE}-chief}"; by="${by:-crewchief}"
fi

[ -f "$home/state/brain.sqlite" ] || exit 0
[ "$(ac_config_read brain-prompt-recall on)" = on ] || exit 0

prompt="$(jq -r '(.prompt // .user_message // .text // empty) | tostring' <<<"$payload" 2>/dev/null || true)"
prompt="$(printf '%s' "$prompt" | tr '\n\r\t' '   ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
[ -n "$prompt" ] || exit 0
case "$prompt" in /*|!*) exit 0 ;; esac
[ "${#prompt}" -ge 12 ] || exit 0
words="$(printf '%s' "$prompt" | tr -c '[:alnum:]' '\n' | awk 'length($0) >= 3' | wc -l | tr -d ' ')"
[ "$words" -ge 2 ] || exit 0

iv="${AC_BRAIN_SYNC_IV:-1800}"
age="$(ac_brain_marker_age)"
fired="$(ac_brain_freshen)"

limit="${AC_PROMPT_RECALL_LIMIT:-3}"
case "$limit" in ''|*[!0-9]*) limit=3 ;; esac
res="$("$(ac_root)/bin/ac-brain.sh" recall --home "$home" --query "$prompt" \
  --limit "$limit" --by "$by" --compact 2>/dev/null)" || exit 0
hits="$(jq -r '
  (.results // [])[] | select(.path != null)
  | "- " + .path + " [" + (.trust // "?") + "; " + (.evidence // "?") + "] "
    + ((.snippet // "") | gsub("\n"; " ") | .[0:140])' <<<"$res" 2>/dev/null || true)"
[ -n "$hits" ] || exit 0

if [ "$age" -lt 0 ]; then
  fresh="never synced"
elif [ "$age" -ge "$iv" ]; then
  if [ "$age" -ge 86400 ]; then fresh="STALE - last sync $(( age / 86400 ))d ago"
  else fresh="STALE - last sync $(( age / 3600 ))h ago"; fi
  [ -z "$fired" ] || fresh="$fresh, catch-up sync fired"
else
  fresh="synced $(( age / 60 ))m ago"
fi

printf 'ac-brain recall for this prompt (fleet memory, by %s; %s):\n%s\nUse a hit only after reading its path; cite path + quote when it shapes the answer. A STALE brain is missing history after its last sync.\n' \
  "$by" "$fresh" "$hits"
exit 0
