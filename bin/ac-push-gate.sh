#!/usr/bin/env bash
# ac-push-gate.sh - the PRE-PUSH PRIVACY GATE: refuse a push whose OUTGOING
# commits carry a private identifier - in a diff, a commit message, or an
# author/committer ident - BEFORE anything leaves the machine.
#
# WHY A GATE: a push is the irreversible step. A tree scrub fixes the checkout
# but every pushed commit stays readable forever (and force-pushed-away objects
# stay fetchable-by-SHA on the server), so the only place a leak is cheap to
# stop is the outgoing range, at push time, mechanically.
#
# PATTERNS LIVE OUTSIDE THE REPO - this is load-bearing, not a convenience:
# the pattern list IS the private identifiers, so tracking it in the repo
# would leak exactly what it guards. The gate reads one ERE per line
# (blank lines and `#` comments skipped, matched case-insensitively) from
#   $AC_PUSH_GATE_PATTERNS  (default: ~/.config/agent-crew/push-gate.patterns)
# A missing/empty pattern file PASSES with a note (a public user without a
# private-client history has nothing to list) - unless AC_PUSH_GATE_REQUIRE=1,
# the strict mode an operator's own hook install pins so a lost pattern file
# can never silently disarm the gate.
#
# MODES
#   ac-push-gate.sh hook           - pre-push hook mode: reads the
#     `<local-ref> <local-sha> <remote-ref> <remote-sha>` lines git feeds a
#     pre-push hook on stdin; scans each pushed range (a branch deletion is
#     skipped; an unknown/zero remote sha scans the full local history).
#   ac-push-gate.sh check <range>  - manual scan of an explicit rev range
#     (anything `git log` accepts), same verdict and exit codes.
#
# WHAT ONE SCAN COVERS: `git log -p` over the range with idents prepended -
# every diff hunk, every commit message, every author AND committer ident.
# A scan is a FLOOR, never proof of absence: the refusal and the pass both
# say so, and the operator's read of the outgoing diff stays the real gate.
#
# Exit: 0 clean (or no patterns and not required), 1 match found or strict
# mode unsatisfied, 2 usage.
set -u

pat_file="${AC_PUSH_GATE_PATTERNS:-$HOME/.config/agent-crew/push-gate.patterns}"
mode="${1:-}"

usage() { printf 'usage: ac-push-gate.sh hook | check <range>\n' >&2; exit 2; }

# active_patterns - the usable pattern lines, or empty output when none.
active_patterns() {
  [ -f "$pat_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$pat_file" || true
}

patterns="$(active_patterns)"
if [ -z "$patterns" ]; then
  if [ "${AC_PUSH_GATE_REQUIRE:-0}" = "1" ]; then
    printf 'push-gate: REFUSED - no usable patterns in %s and AC_PUSH_GATE_REQUIRE=1\n' "$pat_file" >&2
    printf 'push-gate: restore the pattern file (one ERE per line) or unset the strict pin deliberately.\n' >&2
    exit 1
  fi
  printf 'push-gate: no pattern file (%s) - nothing to scan, passing.\n' "$pat_file" >&2
  exit 0
fi

# scan_range <range> - print offending lines (capped), return 1 on any hit.
scan_range() {
  local range="$1" hits
  hits="$(git log --format='commit %H%nAuthor: %an <%ae>%nCommit: %cn <%ce>%n%B' -p "$range" 2>/dev/null \
    | grep -inE -f <(printf '%s\n' "$patterns") | head -20)" || true
  [ -z "$hits" ] && return 0
  printf 'push-gate: REFUSED - private identifier in outgoing range %s:\n' "$range" >&2
  printf '%s\n' "$hits" >&2
  printf 'push-gate: patterns: %s. A scan is a floor, never proof of absence.\n' "$pat_file" >&2
  return 1
}

zeros=0000000000000000000000000000000000000000

case "$mode" in
  check)
    [ -n "${2:-}" ] || usage
    scan_range "$2" || exit 1
    printf 'push-gate: clean over %s (floor scan - still read the diff).\n' "$2" >&2
    ;;
  hook)
    rc=0
    while read -r _lref lsha _rref rsha; do
      [ -n "${lsha:-}" ] || continue
      [ "$lsha" = "$zeros" ] && continue   # deletion - nothing outgoing
      if [ "${rsha:-$zeros}" != "$zeros" ] && git rev-parse -q --verify "$rsha^{commit}" >/dev/null 2>&1; then
        scan_range "$rsha..$lsha" || rc=1
      else
        scan_range "$lsha" || rc=1          # new/unknown remote ref - full history
      fi
    done
    exit "$rc"
    ;;
  *) usage ;;
esac
