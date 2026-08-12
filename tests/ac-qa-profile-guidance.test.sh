#!/usr/bin/env bash
# ac-qa-profile-guidance.test.sh - contract checks for slice 4 of the
# qa-profile-resolve design: a fresh QA verifier receives an already-resolved
# profile and never repeats repository/infra onboarding discovery itself
# (discovery/drafting is a chief-owned onboarding path off `needs-profile`,
# triggered before this pane ever exists), and crew-ship's post-ship qa retry
# uses a fresh pane per round rather than a resumed session.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

qa_skill="$(<"$ROOT/.agents/skills/crew-qa/SKILL.md")"
ship_skill="$(<"$ROOT/.agents/skills/crew-ship/SKILL.md")"
config_doc="$(<"$ROOT/docs/configuration.md")"

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-assert_not_contains}: '$2' found" ;;
  esac
}

assert_not_contains "$qa_skill" 'CONFIG SELF-DISCOVERY' \
  "normal-run config self-discovery removed from crew-qa verifier instructions"
assert_not_contains "$qa_skill" 'Drafting for a SCOPED project' \
  "scoped-project drafting guidance removed from crew-qa verifier instructions"
assert_contains "$qa_skill" 'RESOLVED PROFILE' \
  "crew-qa states the fresh verifier receives an already-resolved profile"
assert_contains "$qa_skill" 'PROFILE RESOLVE preflight' \
  "crew-qa points at the preflight that gates pane creation on profile-ready"
assert_contains "$qa_skill" 'never something you do inside' \
  "crew-qa states discovery/drafting is not normal-round verifier work"

assert_not_contains "$ship_skill" 'durable per-task session resumes' \
  "crew-ship no longer describes qa retries as a resumed durable session"
assert_contains "$ship_skill" 'a FRESH pane per round' \
  "crew-ship states each qa retry is a fresh pane, never a resumed session"

assert_not_contains "$config_doc" 'The crew-qa and crew-ship skills own the discovery guidance' \
  "config doc no longer attributes normal-run discovery ownership to crew-qa"
assert_contains "$config_doc" 'a chief-owned repair path, never normal verifier execution' \
  "config doc reconciles discovery ownership to the chief-owned onboarding path"

# --- QA coverage ladder (captain 2026-07-25): guidance carries the four-tier
# execution set, conditional UT receipt reuse, frozen manifest grammar, and
# final full-flow requirement without turning dispatch into behavior policy.
qa_doc="$(<"$ROOT/docs/qa-attestation.md")"
agents_doc="$(<"$ROOT/AGENTS.md")"

assert_contains "$qa_skill" 'api | db | workflow | web' \
  "crew-qa names the closed tier set"
assert_not_contains "$qa_skill" 'api | db | workflow | web | unit' \
  "crew-qa does not reintroduce unit as a QA execution tier"
assert_not_contains "$qa_skill" 'LAST RUNG' \
  "crew-qa does not retain superseded last-rung unit guidance"
assert_not_contains "$qa_skill" 'boundary-run --boundary unit' \
  "crew-qa never routes a unit test through a QA boundary command"
assert_contains "$qa_skill" 'boundary-run' \
  "crew-qa routes shell-driven cases through the boundary receipt command"
assert_contains "$qa_skill" 'CLIENT BOUNDARY' \
  "crew-qa states tiers are client boundaries of the booted deliverable"
assert_contains "$qa_skill" '## Coverage' \
  "crew-qa documents the machine-readable coverage section"
assert_contains "$qa_skill" '## Full Flow' \
  "crew-qa documents the required final-flow section"
assert_contains "$qa_skill" 'testplan-manifest.json' \
  "crew-qa names the frozen manifest that gates case execution"
assert_contains "$ship_skill" 'A declaration writes NO receipt' \
  "crew-ship states --tdd declarations create no ship test receipt"
assert_contains "$ship_skill" 'never infers' \
  "crew-ship states the QA freeze never infers a receipt"
assert_contains "$qa_doc" 'non-executed test-only unit regression PROPOSAL' \
  "public QA doc states the unit-proposal exception"
assert_contains "$qa_doc" 'the closed tier set is `api | db | workflow | web`' \
  "public QA doc names the closed tier set"
assert_contains "$qa_doc" '`agentcrew.qa-testplan-manifest/v1`' \
  "public QA doc names the frozen coverage manifest schema"
assert_contains "$qa_doc" 'minimum(full-flow receipt `started_at`)' \
  "public QA doc states the mechanical final-group ordering rule"
assert_contains "$agents_doc" 'BOOTED deliverable' \
  "AGENTS.md carries the booted-boundary evidence rule"
assert_contains "$agents_doc" 'only when the frozen coverage manifest selects a `ut` row' \
  "AGENTS.md makes ship-receipt qualification conditional on UT coverage"
assert_contains "$agents_doc" 'Dispatch remains model routing only' \
  "AGENTS.md keeps dispatch rules out of QA behavior policy"

printf 'ok - qa-profile-guidance doc/skill reconciliation\n'
