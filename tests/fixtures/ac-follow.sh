#!/usr/bin/env bash
# ac-follow.sh - realtime, full-fidelity stream of a crewmate's claude
# session (the captain's x-ray: full tool inputs/results, not the 40-line
# pane tail ac-peek gives).
#
# Usage:
#   ac-follow.sh <id>              # follow the crewmate's transcript live
#   ac-follow.sh --render <jsonl>  # one-shot render of a transcript (tests)
#
# Resolution: the task meta gives worktree= (claude keys transcripts by cwd:
# <ac_claude_transcript_root>/<slugified-worktree>/) and session_id=. The stream
# follows the DIRECTORY, auto-switching to the newest transcript when the
# crewmate forks/starts sub-sessions. ctrl-c to stop; the crewmate is
# never touched (read-only). The renderer is src/follow.ts, started through
# bin/ac-bun.sh; its header is the spec for what is printed.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-bun.sh"

if [ "${1:-}" = "--render" ]; then
  f="${2:?usage: ac-follow.sh --render <jsonl>}"
  [ -f "$f" ] || ac_die "no such transcript: $f"
  ac_bun_exec src/follow.ts file "$f"
fi

id="${1:-}"
[ -n "$id" ] || ac_die "usage: ac-follow.sh <id> | --render <jsonl>"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || meta="$(ac_state_dir)/archive/$id/meta"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
worktree="$(ac_meta_get "$meta" worktree)"
[ -n "$worktree" ] || ac_die "meta for $id has no worktree"
[ "$(ac_meta_get "$meta" harness)" = "claude" ] \
  || ac_die "$id is not a claude crewmate; use ac-peek.sh instead"

# claude slugs the cwd: / and . become -
slug="$(printf '%s' "$worktree" | sed 's/[/.]/-/g')"
proj="$(ac_claude_transcript_root)/$slug"
[ -d "$proj" ] || ac_warn "no transcripts yet at $proj (crewmate still booting?)"
printf '%s\n' "following $id ($proj) - ctrl-c to stop" >&2
ac_bun_exec src/follow.ts dir "$proj"
