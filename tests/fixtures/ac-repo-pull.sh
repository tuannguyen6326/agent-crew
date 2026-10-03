#!/usr/bin/env bash
# ac-repo-pull.sh <repo-root> - fetch + FAST-FORWARD-ONLY sync of a project
# clone's default branch: the dashboard Pull button's whole authority, and
# exactly the sanctioned chief write (fetch, ff-sync - AGENTS.md section 1).
#
# Behavior, fail-toward-fetch-only:
# - always `git fetch --prune origin`;
# - then the DEFAULT branch (the clone's own HEAD ref) fast-forwards to
#   origin/<default> ONLY when that is a pure ff and the working tree is
#   clean when checked out - a diverged branch, a dirty tree, or a detached
#   HEAD fetches and reports `fetched only (<why>)`, mutating nothing.
# Prints one line: `synced <branch> -> <sha7>` or `fetched only (...)`.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

root="${1:-}"
[ -n "$root" ] || ac_die "usage: ac-repo-pull.sh <repo-root>"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || ac_die "not a git repo: $root"

git -C "$root" fetch --prune origin >/dev/null 2>&1 || ac_die "fetch failed (no origin, or network down)"

def="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)"
if [ -z "$def" ]; then
  printf 'fetched only (detached HEAD)\n'; exit 0
fi
if ! git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$def"; then
  printf 'fetched only (origin has no %s)\n' "$def"; exit 0
fi
if ! git -C "$root" merge-base --is-ancestor "$def" "origin/$def" 2>/dev/null; then
  # Ahead and diverged both refuse the sync, but the operator's next move
  # differs - say which one it is.
  if git -C "$root" merge-base --is-ancestor "origin/$def" "$def" 2>/dev/null; then
    printf 'fetched only (local %s ahead of origin - nothing to pull)\n' "$def"; exit 0
  fi
  printf 'fetched only (%s diverged from origin)\n' "$def"; exit 0
fi
if [ -n "$(git -C "$root" status --porcelain)" ]; then
  printf 'fetched only (working tree dirty)\n'; exit 0
fi
git -C "$root" merge --ff-only "origin/$def" >/dev/null 2>&1 \
  || { printf 'fetched only (fast-forward refused)\n'; exit 0; }
printf 'synced %s -> %s\n' "$def" "$(git -C "$root" rev-parse --short HEAD)"
