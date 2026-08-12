#!/usr/bin/env bash
# ac-lint.sh - single owner of the lint definition.
#
# Usage: ac-lint.sh [--all]
# Runs `bash -n` syntax checks then shellcheck (when present) over the scripts
# ac-lint owns: bin/*.sh, tests/*.test.sh, tests/stress.sh, and the
# docs/examples/slack-remote/remote-* hooks.
#
# By DEFAULT it lints only the CHANGED files in that set - staged, unstaged, and
# untracked vs HEAD - so an edit-lint cycle stays fast. `--all` lints the whole
# set (the pre-release / CI sweep). Outside a git repo, or with no HEAD yet, it
# falls back to the whole set. A clean tree lints nothing and exits 0.
# Set AC_LINT_ALLOW_MISSING=1 to tolerate a missing shellcheck locally.
#
# Findings are enforced down to INFO level, and that set MOVES between releases:
# 0.11 dropped SC2015 (`A && B || C`), which older builds still emit across seven
# files here, plus SC2119/SC2317 in four more. The definition assumes 0.11+; an
# older local build will report findings this repo does not consider defects.
#
# Beware one trap when editing the comments above: a line may not BEGIN with the
# linter's own name, because that prefix is its directive syntax - the sentence
# is then parsed as a directive and dies SC1073, while `bash -n` waves it
# through, valid bash and invalid lint at the same time.

set -euo pipefail
cd "$(dirname "$0")/.."

all=0
case "${1:-}" in
  --all) all=1 ;;
  -h|--help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) printf 'ac-lint.sh: unknown arg: %s (use --all)\n' "$1" >&2; exit 2 ;;
esac

# The lint set: the files ac-lint owns. A changed file is linted only if it
# matches one of these - a changed README or config is not ours to check.
in_lint_set() {
  case "$1" in
    bin/*.sh | tests/*.test.sh | tests/stress.sh) return 0 ;;
    docs/examples/slack-remote/remote-*) return 0 ;;
  esac
  return 1
}

files=()
if [ "$all" = 1 ] || ! git rev-parse --git-dir >/dev/null 2>&1; then
  # --all, or not a git repo: the whole set (the historical behavior).
  for f in bin/*.sh tests/*.test.sh tests/stress.sh docs/examples/slack-remote/remote-*; do
    [ -e "$f" ] && files+=("$f")
  done
else
  # Default: only files that DIFFER from HEAD (staged + unstaged, deletions
  # excluded) plus untracked files, narrowed to the lint set. A missing HEAD
  # (fresh repo) leaves the diff empty and lints just the untracked additions.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$f" ] && in_lint_set "$f" && files+=("$f")
  done < <(
    { git diff --name-only --diff-filter=d HEAD 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true; } | sort -u
  )
fi

if [ "${#files[@]}" -eq 0 ]; then
  printf 'ac-lint: no changed lint targets (use --all to lint everything)\n'
  exit 0
fi

rc=0
for f in "${files[@]}"; do
  bash -n "$f" || { printf 'syntax error: %s\n' "$f" >&2; rc=1; }
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -P SCRIPTDIR "${files[@]}" || rc=1
elif [ "${AC_LINT_ALLOW_MISSING:-0}" != 1 ]; then
  printf 'shellcheck not found (install it, or set AC_LINT_ALLOW_MISSING=1)\n' >&2
  rc=1
fi
exit "$rc"
