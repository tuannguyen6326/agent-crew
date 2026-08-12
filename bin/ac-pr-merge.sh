#!/usr/bin/env bash
# ac-pr-merge.sh - merge a crewmate's PR after captain approval.
#
# Usage: ac-pr-merge.sh <id> <github-pr-url> [-- <gh merge flags>]
# Default merge method is --squash; flags after -- are passed to `gh pr merge`
# (e.g. -- --merge or -- --rebase). --repo/-R overrides are rejected: the URL
# is the single source of truth for where the merge lands.
#
# Landing interlock (contract: ac-lib.sh's landing-ledger block): BEFORE the
# merge it prints one LANDING-OVERLAP warning per PR file another family
# landed <24h ago (warn-only), and after it it records every landed file to
# the state/.landings ledger. The file list comes from `gh pr diff
# --name-only`, best-effort: a gh that cannot print it never blocks the merge.
# It also prints the KNOWLEDGE-GAP flag when this family recorded no
# repo-knowledge entry for the project (ac_knowledge_warn, warn-only, NOT
# behind the landed[] guard - an unresolvable file list is still a landing).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
# ...and its documented sibling, AFTER it: the qa merge gate reads the
# project yaml through ac_yaml_has, which lives there. Without this line
# the gate is an unbound command on the one path that must never be
# ambiguous. No cycle - ac-lib.sh loads nothing from it, and the call is
# resolved at RUN time, after both files are loaded.
. "$(dirname "$0")/ac-pipeline-lib.sh"
. "$(dirname "$0")/ac-qa-lib.sh"   # ac_qa_required/ac_qa_gate_matrix/ac_qa_gate_ok: the merge-time qa gate
ac_require gh

id="${1:-}"; url="${2:-}"; shift 2 || true
[ -n "$id" ] && [ -n "$url" ] || ac_die "usage: ac-pr-merge.sh <id> <pr-url> [-- <gh flags>]"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
case "$url" in
  https://github.com/*/*/pull/[0-9]*) ;;
  *) ac_die "not a full GitHub PR URL: $url" ;;
esac

extra=()
if [ "${1:-}" = "--" ]; then
  shift
  extra=("$@")
fi

# Every expansion of extra is guarded on its length: under `set -u` (bash 3.2)
# "${extra[@]}" on an empty array is an unbound-variable error, and the
# "${extra[@]:-}" workaround injects one spurious empty-string argument that
# `gh pr merge` rejects ("accepts at most 1 arg").
method="--squash"
if [ "${#extra[@]}" -gt 0 ]; then
  for f in "${extra[@]}"; do
    case "$f" in
      --repo|--repo=*|-R|-R*) ac_die "--repo/-R overrides are not allowed; the PR URL decides" ;;
      --merge|--rebase|--squash) method="" ;;
    esac
  done
fi

# qa.require_for_ship gate, FAIL CLOSED: when the merge target enforces qa, a
# passing crew-qa run must be on record for the EXACT head being merged. The
# enforced/not-enforced decision is read from the target WITHOUT a head
# (ac_qa_required), so an unresolvable head can never SILENTLY SKIP the gate:
# if qa is required and the head SHA cannot be resolved (gh error OR empty),
# the merge is REFUSED. Binding to the resolved head also refuses on DRIFT - a
# pass recorded for an old sha does not authorize a head that changed since the
# qa run (ac_qa_gate_ok finds no marker for the new sha). When qa is not
# required this is a clean no-op with no gh dependency.
project_dir="$(ac_meta_get "$meta" project_dir)"
if [ -n "$project_dir" ] && [ -d "$project_dir" ] && ac_qa_required "$project_dir"; then
  head_sha="$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  [ -n "$head_sha" ] || ac_die "merge blocked: qa.require_for_ship is enforced but the PR head SHA could not be resolved (gh pr view failed or returned empty) - run crew-qa and retry once the head resolves"
  # The task id lets the gate adjudicate a required-profile MANIFEST when the
  # task declared one - EVERY required profile must have a passing attestation
  # at this exact head, not merely any one pair (ac_qa_gate_ok / ac_qa_gate_matrix).
  ac_qa_gate_ok "$project_dir" "$head_sha" "$id" \
    || ac_die "merge blocked by qa.require_for_ship (see message above)"
fi

# Landing interlock: warn on <24h foreign-family overlaps before the merge,
# record the landed files after it (header + ac-lib.sh landing-ledger block).
family="$(ac_family_of_id "$id")"
landed=()
while IFS= read -r p; do landed+=("$p"); done \
  < <(gh pr diff "$url" --name-only 2>/dev/null || true)
[ "${#landed[@]}" -eq 0 ] || ac_landing_warn "$family" "${landed[@]}"
# The KNOWLEDGE-GAP flag rides the same checkpoint but NOT the landed[] guard:
# `gh pr diff` failing into `|| true` is exactly a landing whose file list is
# empty, and that landing owes its knowledge entry like any other. Warn-only,
# always returns 0 (ac-lib.sh owns the contract).
ac_knowledge_warn "$family" "$project_dir"

merge_args=(pr merge "$url")
if [ -n "$method" ]; then merge_args+=("$method"); fi
if [ "${#extra[@]}" -gt 0 ]; then merge_args+=("${extra[@]}"); fi
gh "${merge_args[@]}"
[ "${#landed[@]}" -eq 0 ] || ac_landing_record "$family" "${landed[@]}"
ac_meta_set "$meta" pr "$url"
ac_meta_set "$meta" pr_merged 1
ac_status_append "$id" "merged: $url"
printf 'merged %s\n' "$url"
