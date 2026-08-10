#!/usr/bin/env bash
# staged-design-flow.test.sh - the staged-design-flow spec's v1 enforcement
# wiring (docs/staged-design-flow-spec.md, Assumptions: briefs + operating
# guidance + focused regression tests, no new parser). The brief-side channel
# is covered by ac-brief.test.sh; this file pins the other two: the spec doc
# is tracked and Accepted, and the guidance channel (AGENTS.md section 5)
# carries the stage-admission receipt grammar, the hash-anchor freshness
# obligation, and the fail-closed mechanical pre-implement re-hash.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

spec_doc="$ROOT/docs/staged-design-flow-spec.md"
assert_file "$spec_doc"
spec="$(cat "$spec_doc")"
assert_contains "$spec" "Status: Accepted" "the spec is accepted, not proposed"
assert_contains "$spec" "STAGE-ADMISSION: stage=<spec|architecture|plan>" \
  "the spec owns the stage-admission receipt grammar"
assert_contains "$spec" "Valid room receipt" \
  "the spec owns the valid-receipt semantics"

agents="$(cat "$ROOT/AGENTS.md")"
assert_contains "$agents" "STAGE-ADMISSION: stage=<spec|architecture|plan>" \
  "guidance carries the stage-admission receipt grammar"
assert_contains "$agents" "silence is neither admission nor a skip" \
  "guidance carries the no-inference admission rule"
assert_contains "$agents" "a revision requires a fresh \`gate-route\`" \
  "guidance carries the accepted-version freshness obligation"
assert_contains "$agents" "re-hash every admitted report" \
  "guidance carries the mechanical pre-implement drift check"
assert_contains "$agents" "a stage with none blocks the gate" \
  "the pre-implement gate fails closed on a missing admission receipt"
assert_contains "$agents" "docs/staged-design-flow-spec.md" \
  "guidance points at the authoritative contract file"

pass
