#!/usr/bin/env bash
# ac-github.sh - the GitHub intake DETECTOR: polls a project clone's own
# `origin` remote for open issues/PRs and posts a crew-authored verdict back
# to a PR. It is a detector only - AGENTS.md section 5's L1-L4 design
# constraints bind every call here:
#
#   L1 it never mints a records/backlog.md row itself (fold-or-mint needs
#      judgement a shell script cannot make - the crewchief does it on drain).
#   L2 it never verifies an item and never authors a verdict - `comment`
#      posts a verdict the caller (the crew, through the ordinary flow)
#      already produced, and owns only that comment's idempotence.
#   L3 it never spawns a crewmate - the crewchief spawns the fix on its own
#      drain, under config/room-parallel.
#   L4 it never merges a PR - the captain always does.
#
# Usage:
#   ac-github.sh poll --repo <path>
#   ac-github.sh comment --repo <path> --pr <n> --body <text>
#
# IDEMPOTENCE KEY, stated here because this is the one place it is decided:
# durable state lives under `$(ac_state_dir)/.github/<slug>/`, where <slug> is
# the project clone's own `origin` remote (host+owner+repo, `/`/`:` folded to
# `-` - ac_slug below), so two different clones of two different repos can
# never collide. Inside that directory:
#   seen-issue-<n> / seen-pr-<n>   an open item already recorded and woken;
#                                  a second `poll` finding the SAME open item
#                                  writes nothing and wakes nobody.
#   commented-pr-<n>-<cksum>       a verdict (keyed by its own exact text)
#                                  already posted on that PR; a second
#                                  `comment` call with byte-identical text is
#                                  a no-op, one with different text posts a
#                                  new comment (a revised verdict is not a
#                                  duplicate of the old one).
# Nothing here is ever deleted: an item stays "seen" once open-and-polled,
# even after the crew folds/mints/fixes it - re-detecting a long-closed loop
# is not this script's job, and the durable record is what makes a second
# `poll` a clean no-op instead of a second wake.
#
# WAKE: `poll` publishes through ac_wake_publish (ac-wake-lib.sh) into the
# FLEET spool (scope ""), kind `github`, id `issue-<n>`/`pr-<n>`, payload a
# single sanitized line naming the kind, number, title, author and URL. This
# reuses the existing wake/drain/nudge machinery byte-for-byte - no new
# orchestration layer, per AGENTS.md's Karpathy rule.
#
# UNTRUSTED INPUT: every issue/PR field (`title`, `author.login`) is remote
# text, never an instruction. It is extracted through `jq --json`, and
# title/login are stripped of control bytes INSIDE that same jq filter (its
# `clean` def: explode/select/implode on codepoint, never a shell regex)
# before they ever reach a shell variable - so a hostile title can carry
# ANSI/marker bytes and still never execute, steer anything, or corrupt the
# field split (fields join on ASCII RS 0x1e, not a tab: bash `read` collapses
# an EMPTY field between two IFS-whitespace tabs, which a missing author
# would trigger; RS is not IFS whitespace, and cleaning happens before the
# join so a hostile value can never contain the delimiter it would need to
# shift). The ONLY value ever used to build a file path or an `--pr`/comment
# target is the JSON `number` field, and it is validated to be a bare
# non-negative integer first; a missing number, url or author login REFUSES
# that one item (never guessed, never silently dropped from view - it is
# reported on stderr) without touching any other item in the same poll.
#
# FAIL-CLOSED ON GITHUB: no `gh`, no `jq`, a non-array `gh ... --json`
# response, or a non-zero `gh` exit (network, rate-limit, auth) all refuse
# loudly with the reason gh gave, before any record is written and before any
# wake is published - never a half-written record, never a silent success.
# PAGE SIZE is likewise never a silent success: `gh pr|issue list` defaults to
# 30 items with no error when more exist, so `poll` passes an explicit
# `--limit` and, when a list comes back exactly at that limit (the page may be
# truncated - there is no cheaper way to tell "truncated" from "exactly N
# open"), says so loudly on stderr rather than silently missing item 31+.
# This is a LOUD, uncapped-in-practice page size, never real pagination - the
# fleet does not need that machinery today.
#
# HOSTING: this script has no daemon of its own - CronCreate is session-only
# (records/standing-jobs.md and bin/ac-standing-jobs.sh's header own that
# contract). A fleet that wants it polled regularly declares it there, in the
# same grammar as every other standing job, and re-creates the CronCreate job
# at session start like any other.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

usage() {
  printf 'usage: ac-github.sh poll --repo <path>\n'
  printf '       ac-github.sh comment --repo <path> --pr <n> --body <text>\n'
}

_ac_github_slug() {
  # _ac_github_slug <repo> - a filesystem-safe, collision-free key for the
  # clone's own `origin` remote (never a captain-configured knob - nobody
  # asked for one). Handles both the ssh (`git@host:owner/repo.git`) and
  # https (`https://host/owner/repo.git`) forms gh itself accepts.
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  url="${url%.git}"
  url="${url#*://}"
  url="${url#*@}"
  url="$(printf '%s' "$url" | tr '/:' '--')"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

_ac_github_poll_items() {
  # _ac_github_poll_items <store> <kind: issue|pr> <json-array> <page_limit> -
  # see the header's UNTRUSTED INPUT block for why fields are cleaned inside
  # jq and joined on RS rather than a tab, and its PAGE SIZE block for why a
  # full page is called out loudly rather than trusted as complete.
  local store="$1" kind="$2" json="$3" page_limit="$4"
  local number url login title key seenfile payload count
  printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || ac_die "gh returned a malformed $kind list (not a JSON array) - refusing to poll"
  count="$(printf '%s' "$json" | jq 'length')"
  if [ "$count" -ge "$page_limit" ]; then
    printf 'ac-github.sh poll: the %s list came back at exactly its --limit %s - there may be MORE open %ss than this poll saw; re-run with a higher limit to be sure none are missed\n' \
      "$kind" "$page_limit" "$kind" >&2
  fi
  while IFS=$'\x1e' read -r number url login title; do
    [ -n "$number" ] || continue
    case "$number" in
      *[!0-9]*)
        printf 'ac-github.sh poll: refusing an unattributable %s (bad number %s) - never guess\n' \
          "$kind" "$number" >&2
        continue ;;
    esac
    if [ -z "$url" ] || [ -z "$login" ]; then
      printf 'ac-github.sh poll: refusing %s #%s - missing author or url, never guess\n' \
        "$kind" "$number" >&2
      continue
    fi
    key="$kind-$number"
    seenfile="$store/seen-$key"
    [ -e "$seenfile" ] && continue
    payload="$kind #$number: $title ($login) $url"
    ac_wake_publish "$(ac_state_dir)" "" github "$key" "$payload"
    printf '%s\n' "$payload" >"$seenfile"
    printf 'ac-github.sh poll: recorded %s and woke the crewchief\n' "$key"
  done < <(printf '%s' "$json" | jq -r '
    def clean: explode | map(select(. > 31 and . != 127)) | implode;
    .[] | [
      (.number | tostring),
      ((.url // "") | clean),
      ((.author.login // "") | clean),
      ((.title // "") | clean)
    ] | join("")
  ')
}

cmd_poll() {
  local repo_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo_arg="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1 (ac-github.sh poll takes --repo <path>)" ;;
    esac
  done
  [ -n "$repo_arg" ] || ac_die "usage: ac-github.sh poll --repo <path>"
  [ -d "$repo_arg/.git" ] || ac_die "not a git repo: $repo_arg"
  command -v gh >/dev/null 2>&1 || ac_die "gh not found on PATH - cannot poll GitHub"
  command -v jq >/dev/null 2>&1 || ac_die "jq not found on PATH - cannot poll GitHub"

  local slug store prs issues
  local page_limit=100
  slug="$(_ac_github_slug "$repo_arg")" || ac_die "could not resolve the origin remote of $repo_arg"

  # gh runs BEFORE the store directory is ever created: a failed poll (no
  # gh, no auth, no network, rate-limited) must leave no trace on disk at
  # all, not even an empty directory - a half-written record is the one
  # thing this refusal must never produce. --limit is EXPLICIT: gh's own
  # default (30) would otherwise silently drop item 31+ with no error - see
  # the header's PAGE SIZE block.
  if ! prs="$(cd "$repo_arg" && gh pr list --state open --limit "$page_limit" --json number,title,url,author 2>&1)"; then
    ac_die "gh pr list failed: $prs"
  fi
  if ! issues="$(cd "$repo_arg" && gh issue list --state open --limit "$page_limit" --json number,title,url,author 2>&1)"; then
    ac_die "gh issue list failed: $issues"
  fi

  store="$(ac_state_dir)/.github/$slug"
  mkdir -p "$store"

  # Clause 2 (a PR IS an item that "has a PR") before clause 3 (a plain open
  # issue has none) - same order the captain's pipeline states them in.
  _ac_github_poll_items "$store" pr "$prs" "$page_limit"
  _ac_github_poll_items "$store" issue "$issues" "$page_limit"
}

cmd_comment() {
  local repo_arg="" pr="" body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo_arg="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --body) body="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1 (ac-github.sh comment takes --repo <path> --pr <n> --body <text>)" ;;
    esac
  done
  [ -n "$repo_arg" ] && [ -n "$pr" ] && [ -n "$body" ] \
    || ac_die "usage: ac-github.sh comment --repo <path> --pr <n> --body <text>"
  case "$pr" in
    *[!0-9]*) ac_die "refusing an unattributable PR number: $pr" ;;
  esac
  [ -d "$repo_arg/.git" ] || ac_die "not a git repo: $repo_arg"
  command -v gh >/dev/null 2>&1 || ac_die "gh not found on PATH - cannot comment"

  local slug store hash donefile out
  slug="$(_ac_github_slug "$repo_arg")" || ac_die "could not resolve the origin remote of $repo_arg"
  store="$(ac_state_dir)/.github/$slug"
  mkdir -p "$store"
  hash="$(printf '%s' "$body" | cksum | awk '{print $1}')"
  donefile="$store/commented-pr-$pr-$hash"
  if [ -e "$donefile" ]; then
    printf 'ac-github.sh comment: this exact verdict is already posted on PR #%s - no-op\n' "$pr"
    return 0
  fi
  if ! out="$(cd "$repo_arg" && gh pr comment "$pr" --body "$body" 2>&1)"; then
    ac_die "gh pr comment failed for PR #$pr: $out"
  fi
  printf '%s\n' "$body" >"$donefile"
  printf 'ac-github.sh comment: posted verdict on PR #%s\n' "$pr"
}

case "${1:-}" in
  poll) shift; cmd_poll "$@" ;;
  comment) shift; cmd_comment "$@" ;;
  -h|--help|"") usage ;;
  *) ac_die "unknown verb: $1" ;;
esac
