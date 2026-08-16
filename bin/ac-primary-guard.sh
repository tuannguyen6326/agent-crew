#!/usr/bin/env bash
# ac-primary-guard.sh - PreToolUse hook: refuse a crewmate/roomchief EDITING a
# file that lives in the PRIMARY checkout but outside its own tree.
#
# Wired in .claude/settings.json under hooks.PreToolUse; reads the hook payload
# JSON on stdin and inspects .tool_name / .tool_input. Pure bash + jq, no other
# runtime - the sibling of ac-ledger-guard.sh and ac-delegation-guard.sh.
#
# WHY IT EXISTS. @da5a33c closed the COMMIT door (ac-tree.sh's pre-commit
# guard); the EDIT door stayed open and @ad60acb covered it in PROSE only (the
# execution brief seed makes a primary edit a STOP+REPORT). On 2026-07-27 that
# prose failed for the first MEASURED time: a crewmate Edited the primary's
# AGENTS.md by absolute path while running its checks in its own worktree, saw
# an empty diff there, and spent minutes on a false "my Read was cached"
# diagnosis - it was writing one tree and verifying another. The hazard behind
# it is the TIDY-UP the mistake invites: `git checkout --` / `git restore` /
# `git reset --hard` in the primary silently destroy uncommitted captain work.
#
# A SECOND LAYER, NOT A REPLACEMENT. The prose stays and remains the ONLY layer
# covering codex and opencode: a PreToolUse hook is claude-only, which is why
# this direction was rejected on COVERAGE grounds 2026-07-25 and re-ordered by
# accepted (direction B) with that residual EYES OPEN - it stops
# the harness that actually failed, and claude is this fleet's default crewmate
# harness. RESIDUAL, unchanged by this file: codex/opencode crewmates, and
# crewmates in a project whose repo ships no .claude/settings.json, are covered
# by the prose alone.
#
# WHERE (D1, reused from the commit guard verbatim): git-common-dir's PARENT is
# the PRIMARY checkout, shared by every linked worktree; --show-toplevel is the
# session's OWN tree. Deny when the target resolves under the primary and NOT
# under the own tree. A leased worktree is a SUBTREE of the primary
# (<repo>/.crew/worktrees/<n>), so the own-tree test is checked FIRST - and in
# the primary itself the two are the same tree, so a chief's legitimate primary
# write passes by geometry rather than by a special case.
# WHO (D2, likewise): AC_CREW_ID (a crewmate, ac-spawn.sh:1282) or AC_SCOPE (a
# roomchief, ac-spawn.sh:1022) - the captain carries neither and is never fenced,
# even when their own session runs inside a leased worktree.
#
# Fails open: neither crew scalar, a non-matching tool, missing jq, an
# unparseable payload, an empty path, a target whose parent directory does not
# exist, or a rev-parse that errors - all exit 0. A broken guard must never
# wedge the harness. Exit codes: 0 allow, 2 deny. Files: none.
#
# RESIDUAL: like its two siblings, this covers the claude harness's
# Edit/Write/NotebookEdit tools only. A write performed through the Bash tool
# (sed, echo >, a heredoc) still gets through - as do the fleet's own shell
# writes to the primary, e.g. ensure_gitignore (ac-tree.sh:120), which is why
# they need no exemption here.

set -uo pipefail

[ -n "${AC_CREW_ID:-}" ] || [ -n "${AC_SCOPE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$tool" ] || exit 0
case "$tool" in mcp__*) exit 0 ;; esac

path=""
case "$tool" in
  Edit|Write) path="$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null || true)" ;;
  NotebookEdit) path="$(jq -r '.tool_input.notebook_path // empty' <<<"$payload" 2>/dev/null || true)" ;;
  *) exit 0 ;;
esac
[ -n "$path" ] || exit 0

# Resolve the target PHYSICALLY, so a relative path, a `..` climb and a symlink
# all land on the same footing as git's own absolute answers below. The last
# component need not exist (a Write creates it); its parent must.
case "$path" in */*) dir="${path%/*}"; base="${path##*/}" ;; *) dir="."; base="$path" ;; esac
[ -n "$dir" ] || dir=/
dir="$(cd "$dir" 2>/dev/null && pwd -P)" || exit 0
target="${dir%/}/$base"

here="$(pwd -P 2>/dev/null || true)"
[ -n "$here" ] || exit 0
own="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || true)"
common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -n "$own" ] && [ -n "$common" ] || exit 0
primary="${common%/*}"

case "$target" in "$own"/*) exit 0 ;; esac
case "$target" in "$primary"/*) : ;; *) exit 0 ;; esac

printf 'ac-primary-guard: REFUSED %s on %s - that path is in the PRIMARY checkout (%s), not in YOUR tree (%s).\n' \
  "$tool" "$target" "$primary" "$own" >&2
printf 'ac-primary-guard: you probably meant %s/%s - edit YOUR tree, and verify with git -C "$(git rev-parse --show-toplevel)".\n' \
  "${own%/}" "${target#"$primary"/}" >&2
printf 'ac-primary-guard: already edited the primary? STOP and REPORT it - do NOT tidy up. `git checkout --`, `git restore` and `git reset --hard` there silently DESTROY uncommitted captain work, and nothing needs cleaning (a lease resets from a REF).\n' >&2
exit 2
