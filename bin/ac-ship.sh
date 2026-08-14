#!/usr/bin/env bash
# ac-ship.sh - state machine + deterministic runner for the crew-ship
# pipeline.
#
# Run from inside the target repo/worktree being validated. State lives at
# <repo>/.crew/ship/<run-id>/ with a `current` symlink.
#
# Usage:
#   ac-ship.sh start --intent <text> [--skip <a,b,...>] [--target <branch>] [--lint] [--tdd]
#
# LEAN PIPELINE (captain.md 2026-07-21) - two steps are conditional, both
# FAILING TOWARD RUNNING:
#   - `lint` is OPT-IN: skip-by-default, and RUNS only when `--lint` is passed
#     (the captain/brief requests it).
#   - `test` SKIPS on `--tdd`: the implement DECLARES its TDD run is the test
#     evidence. FAIL CLOSED - absent `--tdd`, test RUNS. `--tdd` is a DECLARATION,
#     not attestation-by-execution: no re-run, no `commands.test` needed, and no
#     tree check, so it is only as good as the claim. A fix that changes code
#     re-runs test regardless (the fix-reopen rule) - the implement's TDD never
#     covers a later fix diff. `intent` and `review` refuse `--skip` outright at
#     `cmd_start` (F4, captain-decided): one flag used to be able to mint a
#     validated run with zero steps done, including these two, so both are
#     machine-unskippable rather than resting on convention. `skip-remaining`
#     is a separate command and is unaffected - it still marks any step that
#     is still pending/running `skipped` after an empty-diff rebase.
# Every step stays RUNNABLE on request. (The separate `attest-test` /
# `test.attestation` machinery is the EVIDENCE-backed variant, used for chief
# verify via `attest-check`; `--tdd` is the lightweight declaration the captain
# chose for the lean skip.)
#
# --target <branch> pins the run's DELIVERY TARGET when it is not the repo
# default branch (a prelive/release-vN PR): every base-derived step - review
# diff, test/lint reopen scope, push incorporation, the finish `passed`
# merged-evidence gate - computes against origin/<branch> (local fallback;
# mistyped = loud refusal), recorded as target= in run.meta and recomputed
# each round for rebase drift. Omitted = origin/HEAD, byte-compatible with
# every existing run. Pushing the target branch itself is refused exactly
# like the default branch.
#   ac-ship.sh step <name> <status> [--note <text>]
#   ac-ship.sh findings <step>            (JSON array on stdin; refuses a tty)
#   ac-ship.sh findings <step> --show     (print stored findings, writes nothing)
#   ac-ship.sh meta <step>                (JSON object on stdin, refuses a tty:
#                                              risk_level, risk_rationale,
#                                              testing_summary, tested, artifacts)
#   ac-ship.sh cmd <test|lint|format>
#   ac-ship.sh attest-test                (implementer's final TDD run;
#                                              green -> attestation on disk)
#   ac-ship.sh attest-check               (verifier's freshness query:
#                                              0 fresh / 1 stale / 2 none)
#   ac-ship.sh push                       (lease + patch-id guarded push)
#   ac-ship.sh base                       (fresh merge-base vs default)
#   ac-ship.sh evidence-dir               (resolved test-evidence dir)
#   ac-ship.sh skip-remaining             (empty diff: skip what's left)
#   ac-ship.sh config <dotted.key>
#   ac-ship.sh fix-report <step>          (markdown handoff for a fixer)
#   ac-ship.sh review-agent               (independent exact-ref verifier)
#   ac-ship.sh status
#   ac-ship.sh finish <checks-passed|passed|failed|cancelled>
#
# LIVE DASHBOARD: start auto-opens ac-ship-watch.sh in a herdr tab (label
# ac-ship-watch, agents workspace; AC_SHIP_WATCH=off disables) - it marks the
# active step, shows fix rounds + findings, tails the run log, and SELF-CLOSES
# when the run finishes or idles; finish also retires it via <run>/watch.pane.
#
# Steps (fixed order):
#   intent rebase review test document lint push pr
# Step statuses: pending running fixing awaiting_approval completed skipped failed
# `step <name> fixing` also increments the step's durable auto-fix round
# counter (third steps.tsv column) - compare it against auto_fix.<step>. The
# review CAP and the review ROUND NUMBER do not read it (see REVIEW-ROUND
# CONVERGENCE below); fix-report numbering and auto_fix still do.
#
# INDEPENDENT REVIEW: the review step is never self-review. `review-agent` is a
# policy adapter over `ac-verify codereview`; the facade owns one fresh pane,
# one exact-ref isolated lease, the canonical prompt, verdict validation, and
# durable capture-before-reap. review-agent passes only the immediately previous
# validated round (`logs/review-history-rN.json`, machine-built so the fixer
# never authors what steers its reviewer) as --history; ac-verify turns it into
# an interdiff attention map plus fail-closed disposition of that round's open
# ids. crew-ship never
# resumes a reviewer session, replaces a pane, or invokes a headless fallback.
# `<run>/review.agent` binds the receipt to `reviewed_ref`; `step review
# completed` refuses when HEAD differs, and `push` and `finish
# checks-passed|passed` re-check the SAME binding (assert_review_current), so a
# fix landing after review cannot be pushed or recorded as validated - the
# completed transition proved currency at one instant, not at delivery.
# The manual `meta review` path stamps reviewed_ref = HEAD into
# review.meta.json at the SAME `step review completed` transition (F8), so it
# is bound exactly like the review-agent path from then on. Which receipt that
# transition reads is decided by CURRENCY, not by which files exist (F8b): a
# review.agent bound to HEAD wins; a STALE one does not veto the manual
# channel, it is SUPERSEDED by an explicit reviewer record and retired to
# `<run>/review.agent.superseded` (renamed, never deleted) so delivery reads
# the receipt that was actually stamped - assert_review_current prefers
# review.agent and is left byte-unchanged. A stale receipt with NO manual
# record still refuses, unchanged. A completed
# review whose receipt STILL carries no reviewed_ref (a legacy run recorded
# before F8 landed) warns rather than blocks: enforce-when-present, so those
# older runs stay finishable. Historical review.session/review.pane files
# remain cleanup inputs only. The validated object routes `.findings` to
# `findings review` and advisory risk fields to `meta review`.
#
# REVIEW-ROUND CONVERGENCE (captain 2026-08-05; AGENTS.md section 5 carries
# the policy, this header the mechanics). Three gates on review-agent:
# - ENTRY: a round opens only with the test step completed this run or a
#   FRESH attestation (attest_conditions; a bare --tdd declaration does not
#   qualify) - machine-catchable failures never buy a review round. The
#   8-step order is unchanged; this is a precondition on entering review.
# - POST-PASS FREEZE: a round that returned ZERO `fix` findings (verdict
#   `pass`) FREEZES the tree - its advisory findings are notes for the PR body
#   and the backlog, never a licence to commit - so review-agent REFUSES to
#   re-open while the delta since that reviewed_ref is DECIDABLY the caller's
#   own post-pass commits, naming the ref that passed and the two remedies
#   (land it, or have the chief mint a follow-up task). Decidability is the
#   whole guard (review_delta_is_caller_polish): an unresolvable ref, a
#   rewritten history, upstream commits in the delta, or a failed git call all
#   OPEN the round, because a crewmate jammed after a genuine rebase is a worse
#   failure than one wasted round. The crewmate-side law it enforces is seeded
#   from docs/examples/CREWMATE.md; the bare-SHA receipt re-check that makes a
#   post-pass commit expensive is deliberately untouched.
# - SAME-REF BRAKE: a THIRD invocation on ONE `--ref` within a run HOLDs, ahead
#   of the cap. Two attempts on an unchanged ref already failed, so the next
#   one fails the same way: that is an infrastructure or validator signal, and
#   the cap's remedies (accept the residual, grant a final round) are the wrong
#   advice for it. The refusal names BOTH prior attempts with their outcomes
#   (`ok` / `dead-pane` / `rejected-verdict` / `opened` for one killed
#   mid-flight, from the same invocation ledger the cap counts) plus where to
#   read them: the family's ac-verify round evidence (transcript.jsonl,
#   pane-result.ndjson[.tmp]) resolved through AC_FLEET_STATE, and this run's
#   own rejection lines in logs/run.log.
# - CAP: past review.max_rounds (project yaml, default 3) the loop HOLDs for
#   the OWNING CHIEF's chief-decide. What it COUNTS is verifier INVOCATIONS in
#   this run - rows in <run>/logs/review-invocations.tsv, appended before the
#   verifier runs, so a REJECTED attempt counts too (a dead pane costs the
#   same) - never `step review fixing` ticks: nothing but an explicit call ever
#   ticks that column, so a run whose verdicts needed no fix piled up
#   invocations while the counter read round 1. `review.max_rounds` therefore
#   means invocations per run, and `review-residual` reads the SAME counter, or
#   the release the cap points at would be unreachable. The ROUND NUMBER is a
#   separate count - durable round results (logs/review-agent-rN.json) + 1 - so
#   a rejected round's retry stays the same round while still costing a slot.
#   The `fixing` tick keeps its own consumers (fix-report numbering, auto_fix).
#   `review-residual accept --grounds` turns
#   the remaining fix findings advisory (residual_accepted + grounds on the
#   wire, receipt printed for the room; refused below the cap, refused
#   outright while the residual holds a critical correctness/security/
#   data-loss finding - that carve-out is non-overridable). `review-agent
#   --final-round` grants exactly ONE extra round; the durable
#   <run>/review.final-round marker refuses a second grant.
# - REJECTION TRACE: a verdict this adapter refuses writes ONE line to
#   logs/run.log naming the check that failed (findings shape, HEAD binding,
#   verdict/risk enum, unparseable JSON), and the refused verdict itself is
#   kept at logs/review-agent-rN.json.rejected. The verifier writes the same
#   kind of line on ITS side (bin/ac-verify.sh). Before this, a rejected round
#   left no trace of why, so the caller's only move was to re-run the same ref.
# - FLOOR METADATA: round 2+ passes AC_FINDINGS_ROUND + AC_FINDINGS_DELTA
#   (files changed since the IMMEDIATELY PREVIOUS round's reviewed ref) plus
#   AC_FINDINGS_PRIOR_OPEN (that round's blocking ids) into
#   ac_findings_normalize. Only NEW out-of-delta findings floor; an unresolved
#   previous finding never becomes advisory merely because its file was not in
#   the latest fix delta. bin/ac-pipeline-lib.sh owns the floor directions.
#
# Findings JSON (per step):
#   [{"id","severity","action","file","line","description",
#     "authority_class","authority"}]
#   severity: error|warning|info    action: fix|ask-user|no-op
#   authority_class: internal|external|none   authority: one sentence
# `fix` = objective, ASSIGNED to a crewmate fixer (the reviewer never fixes;
# the runner fixes under hold-and-fix, or the orchestrator dispatches a
# fixer via fix-report). A finding with a missing, EMPTY, or unknown action
# (including the retired `auto-fix` alias, which no producer emits) fails
# closed to ask-user - it reaches the captain instead of a fixer.
# `fix` is RESERVED for delivery-blocking findings - correctness, security,
# regression, data loss, accepted-requirement/ruling violation (captain order
# 2026-07-30): every fix finding forces a fresh fix-and-rereview round, so
# advisory improvements ride as no-op with suggested_fix - recorded in the
# findings and the PR, never looping the pipeline. The reviewer prompt
# (ac-verify.sh) carries the same rule; action stays the ONE loop lever.
# FINDING AUTHORITY (same fail-closed shape, same normalizer): `authority`
# names WHO states the finding's EXPECTED behaviour and WHERE - a file:line,
# a URL, or `captain <date>`; `internal` = stated inside this repo or by the
# diff itself, `external` = an actor outside it. An unknown class or an empty
# `authority` normalizes to `none`, and a `fix` finding with class `none` is
# DOWNGRADED to ask-user with `authority_downgraded: true` - so a statement
# nobody can source reaches the captain instead of a fixer. Only `fix` is
# bound, so a legacy run of no-op/ask-user findings finishes unchanged.
# SEVERITY FLOOR (same normalizer, checked first): a `fix` finding with
# `severity: info` is DOWNGRADED to `no-op` with `severity_floored: true` -
# info means no action required, so it never reopens a review round,
# authority-named or not.
# `meta <step>` records the envelope data the PR body needs (review:
# risk_level/risk_rationale; test: testing_summary/tested/artifacts).
#
# TDD ATTESTATION (attestation by execution - never an honor claim):
# `attest-test` is the implementer's final TDD green run: it RUNS the
# configured commands.test in this worktree (output teed to
# <repo>/.crew/ship/attest-test.log) and, ONLY on exit 0, atomically
# writes <repo>/.crew/ship/attest-test.json {branch, commit: HEAD sha,
# tree: HEAD tree hash, cmd: the exact configured test command, at: ISO,
# duration_s, output_sha256: hash of the log}. A failing run writes
# NOTHING and propagates the command's exit code; a worktree with
# uncommitted changes is REFUSED before anything runs, and a test run
# that itself dirties the tree is REFUSED after it (a mutating suite
# proves nothing about the committed state either way). A worktree state
# that cannot be READ is refused at BOTH points: an unreadable status is
# not evidence of a clean one, and this attestation is what lets the test
# step skip the suite.
# `cmd test` ACCEPTS the attestation - marks the test step completed
# WITHOUT re-running the suite, records empty findings plus a
# testing_summary meta note - only when ALL hold: config test.attestation
# is absent/accept (the literal `ignore` disables it, and any OTHER value
# fails CLOSED: the suite runs, with a warning about the unknown value);
# attest-test.json exists; its branch == the current branch; its commit ==
# the current HEAD; its tree == HEAD's tree; its cmd == the currently-
# configured commands.test; and when output_sha256 is present the log
# still hashes to it. ANY condition failing -> the suite runs exactly as
# before, and the rejection reason is logged when an attestation file
# exists. Hold-and-fix stays consistent by construction: a fix commit
# moves HEAD, the attestation goes STALE, and the reopened test step RUNS
# the suite. `finish` retires the file; a leftover from an abandoned
# (never-finished) run is honored only while branch/HEAD/tree/cmd still
# match. TRUST BOUNDARY: the attestation lives in the implementer's own
# worktree - an actor who could forge it has strictly easier lies
# available already; the independent reviewer and crew-qa remain the
# cross-checks.
# `attest-check` is the VERIFIER's freshness query (run-independent, like
# attest-test): it validates the existing attest-test.json against the
# CURRENT tree using the exact acceptance conditions above (ONE
# implementation, attest_conditions, shared with `cmd test`) and prints
# `attested: fresh @<short-sha> (<cmd>)` exit 0, `stale: <why>` exit 1,
# or `no attestation` exit 2. It is NOT gated by test.attestation - that
# key only governs the pipeline's auto-accept, and a query never skips
# anything by itself. Chief-verify usage: a verifier (roomchief or
# crewchief) runs attest-check in the delivered worktree; FRESH means the
# implementer's green run already covers this exact tree - do NOT re-run
# the suite; anything else -> run it. A rebase or fix commit moves HEAD
# and stales the attestation automatically.
#
# SHIP TEST RECEIPT (authoritative - every other mention points HERE by name):
# unit-suite health is the ship pipeline's business EXCLUSIVELY, and a QA round
# may only READ it (QA boundary policy, captain 2026-07-25: QA never executes or
# re-runs unit tests). `cmd test` therefore publishes ONE run-scoped receipt at
# <repo>/.crew/ship/<run>/test/receipt.env, schema
# agentcrew.ship-test-receipt/v1, atomically:
#   BEFORE the command runs, any prior receipt is replaced with
#   `not-qualifies:incomplete` - so a second attempt, an interruption, or a
#   crash can never leave an earlier success current for a later QA freeze;
#   a zero-exit managed execution then replaces it with
#   `qualifies:executed`, a non-zero one with `not-qualifies:non-zero`, and an
#   ACCEPTED attestation with `qualifies:execution-attestation` carrying the
#   attestation's own exact execution identity (command hash, output hash, and
#   the append-only started_at/completed_at pair attest-test now records).
# The receipt is keyed to `git rev-parse HEAD` at write time; a QA round freezes
# it by exact run id and target SHA, never through the mutable `current`
# symlink. Declaration-only `--tdd`, a plain `step test completed`, and legacy
# run metadata create NO receipt - they are claims, and the whole point of the
# receipt is that it is an execution record. ac_qa_ship_receipt_status
# (ac-qa-lib.sh) is the ONE reader that decides whether a receipt qualifies; this
# script only writes what actually happened.
#
# PUSH INCORPORATION (authoritative - the guard's exact shape):
# `push` refuses to force-push over remote commits this branch has not
# incorporated, computed by patch-id
# (`rev-list --cherry-pick --right-only HEAD...<remote> ^<fresh_base>`).
# That check alone had NO LEGAL PATH for the most ordinary step of a multi-PR
# chain: resolving a conflict during a rebase REWRITES that commit's diff, so
# its patch-id changes, --cherry-pick stops cancelling the pre-rebase commit,
# and the branch's own superseded history reads as foreign remote work. A clean
# rebase preserves the patch-id and was never affected. Measured cost: chiefs
# approving manual force-push-with-lease to do the routine thing - a guard that
# is routinely bypassed is no longer a guard.
# THE EXCUSE, and its exact bound: a non-empty unincorporated set is excused
# ONLY when `<remote>` is BYTE-IDENTICAL to a sha THIS command published for
# THIS branch, recorded in <repo>/.crew/ship/pushed.tsv (`<branch>\t<sha>`,
# appended after each push actually lands, run-independent like
# attest-test.json because a chain rebases in run N+1 over what run N pushed).
# Equality, not ancestry: it is the tightest statement of "nothing has touched
# the ref since we published it", and it avoids merge-base --is-ancestor's
# conflation of 1 (not an ancestor) with 128 (unreadable sha).
# It is NOT an operator declaration and cannot be minted by timing: the only way
# to be excused is to have pushed that sha through this command, so anything
# ANOTHER actor pushed moves the ref off every published sha and is still
# refused - whether or not this branch ever held it locally. The lease
# (--force-with-lease=<ref>:<remote>) re-verifies the same sha at write time.
# Everything else is unchanged: the lease, the detached-HEAD refusal, the
# default-branch and delivery-target refusals, and the fail-closed remote read.
# FAILS CLOSED, one push at a time: a branch whose current head this pipeline
# never published (a first push after this landed, a fresh worktree lease, a
# hand-rolled push) is refused exactly as before, and the next pipeline push
# records it.
# RESIDUAL, stated rather than hidden: the excuse also lets the pipeline
# republish over ITS OWN previously published commits that the rebase DROPPED
# (`rebase --skip`, an abandoned `reset --hard`). No git primitive distinguishes
# "conflict-resolved" from "dropped" - both are "the old patch is not in the new
# history" - so closing it needs a fuzzy matcher (commit-subject or range-diff),
# which is not a safety boundary worth building.
# The excuse keys ONLY on a sha this pipeline published, and never on one only
# another actor pushed - but "published" INCLUDES another actor's commit once we
# incorporated it and pushed a head containing it. From that moment dropping it
# falls inside this residual too (reproduced), so the bound is on the sha's
# provenance, not on whose work the commit was.
#
# FINISH - FAIL CLOSED (checks-passed|passed only): `finish` REFUSES to mint a
# validated outcome for a fresh or incomplete run (the proven bypass was `start`
# then `finish checks-passed`, minting a passed run with zero steps done). It
# gates on the EXISTING step + finding state - no new state machine:
#   1. every pipeline step that was NOT user-skipped must be `completed`; any
#      pending/running/fixing/awaiting_approval/failed step is NAMED and finish
#      dies (skip-remaining's skips count as skipped, so an empty-diff run
#      still finishes);
#   2. no unresolved finding may remain across findings/<step>.json - any `fix`
#      finding (resolution is the reviewer's re-run dropping it, never an
#      in-place flag - machine-held for the review step specifically: `cmd_findings`
#      refuses a plain re-post that drops a recorded `fix` finding, F9), or any
#      `ask-user` finding without a recorded captain `decision`, is NAMED and blocks;
#   3. a COMPLETED review must still cover HEAD (assert_review_current): the
#      reviewed_ref on the receipt is re-compared here, so a fix commit landing
#      after the review transition cannot be recorded as validated. A `skipped`
#      review, or a receipt carrying no reviewed_ref, does not block (the
#      latter warns);
#   4. the documented checks-passed vs passed split is enforced -
#      checks-passed = validated but UNMERGED (the crew's stop
#      point; needs 1+2+3 only), passed = MERGED and so ADDITIONALLY requires
#      merged evidence: HEAD reachable from the default ref (ac_default_ref).
#      A squash merge rewrites history and is not an ancestor, so `passed` then
#      fails CLOSED - use checks-passed; the merge helpers own the merge record.
# failed and cancelled are ALWAYS allowed - a crew must never be trapped unable
# to record a failure. The merge helpers (ac-pr-merge, ac-merge-local) stay
# consistent by construction: they act on a real PR / crew branch that exists
# only once a genuine run reached this gate, so a run that never reached
# checks-passed has nothing for them to merge.
#
# Config, HOME-ONLY (resolver: ac-lib.sh ac_project_config_file):
# $AC_HOME/projects/<name>.yaml is captain-owned and branch-immune.
# The project repo is never a config source.
# Keys: commands.{test,lint,format}, commands.test-changed (see SCOPED TEST),
# auto_fix.<step>,
# ignore_patterns, document.instructions, test.evidence.{store_in_repo,dir},
# test.attestation (accept|ignore, default accept - see TDD ATTESTATION).
# `cmd` exit codes: the command's own code; 4 = no command configured.
# `start` FREEZE: trusts AC_FLEET_HOME_CHECKED/AC_FLEET_PROJECT_CONFIG (threaded
# by ac-spawn.sh, which resolved the file with a real AC_HOME) over its own
# bare ac_project_config_file when present, else resolves normally under a
# real AC_HOME, else REFUSES - a homeless, unchecked caller freezing an empty
# config would be indistinguishable from a project verified to have none,
# silently dropping any key the captain pinned (ship-config-and-know-citation-
# blind-spots).
#
# SCOPED TEST (captain order 2026-07-30 - prefer changed-file tests over the
# full suite): commands.test-changed is an OPT-IN per-project command template
# that MUST carry a {files} placeholder (refused loud otherwise); `cmd test`
# replaces it with the shell-quoted base-to-HEAD changed set (same recomputed
# fresh_base as review, deletions excluded) and runs it INSTEAD of the full
# commands.test. Precedence inside `cmd test`: a fresh TDD attestation is
# accepted first (a full green run beats everything and stays qualifying);
# then the scoped run when the key is set and the changed set is non-empty;
# the full suite remains the fallback (no key, or an empty changed set -
# failing toward running). Fix commits extend base..HEAD, so the fix-reopen
# re-run scopes to them automatically. EVIDENCE HONESTY: a scoped green
# completes the test step but its receipt says `not-qualifies:scoped` - a
# partial run is pipeline evidence, never suite proof, so QA's UT bridge
# escalates instead of freezing it; full-suite evidence remains attest-test
# or the full commands.test run.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-pipeline-lib.sh"
. "$(dirname "$0")/ac-backend.sh"   # ac_herdr_agents_workspace/ac_herdr_tab_open
ac_require git jq

# Resolved ONCE, here, while the cwd is still the caller's: the watch dashboard
# is handed to a pane that runs in a DIFFERENT directory (--cwd "$repo"), so a
# caller-relative "$(dirname "$0")" would not resolve there.
bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

STEPS="intent rebase review test document lint push pr"
STATUSES="pending running fixing awaiting_approval completed skipped failed"

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || ac_die "not inside a git repo"
vdir="$repo/.crew/ship"
current="$vdir/current"

config_file() {
  # A started run is immutable: every command reads its frozen config snapshot.
  # Before the first run, resolve the HOME-ONLY installed config directly.
  local rd
  if [ -L "$current" ]; then
    rd="$(run_dir)"
    if [ -s "$rd/config.yaml" ]; then printf '%s\n' "$rd/config.yaml"; return 0; fi
    [ -f "$rd/config.yaml" ] && return 1
  fi
  ac_project_config_file "$repo"
}

require_run() { [ -L "$current" ] || ac_die "no active crew-ship run; ac-ship.sh start first"; }

ensure_crew_excluded() {
  # Exclude .crew/ via info/exclude (shared with all worktrees; the pool
  # manager normally did this already, standalone repos need it too).
  # DEGRADE as ONE unit: all this entry buys is .crew/ staying out of
  # `git status`, so an unresolvable common dir, an uncreatable info/, or an
  # unwritable exclude warns and continues - unguarded, any of the three killed
  # a whole `start`/`attest-test` over an ignore line. Mirrors ac-lib.sh
  # ac_repo_root, which returns 1 on the same rev-parse.
  # The && CHAIN is what short-circuits, NOT the subshell: errexit is suppressed
  # inside any non-final command of an AND-OR list, and the subshell INHERITS
  # that suppression, so a bare sequence would run on past the first failure -
  # with an empty $common that means addressing /info/exclude at FILESYSTEM
  # ROOT, which on a writable-root box (root, container, CI image) SUCCEEDS and
  # reports 0, so the warning never fires. The underlying error is left on
  # stderr ahead of the warning, and the callers' own dirty-tree refusals stay
  # fail-closed either way.
  ( common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" \
    && mkdir -p "$common/info" \
    && { grep -qx '\.crew/' "$common/info/exclude" 2>/dev/null \
         || printf '.crew/\n' >>"$common/info/exclude"; } ) \
    || ac_warn "could not add .crew/ to info/exclude - it stays visible in git status"
}
run_dir() { readlink "$current" >/dev/null || ac_die "broken current symlink"; printf '%s/%s\n' "$vdir" "$(readlink "$current")"; }

resolve_target() {
  # resolve_target <branch> - the DELIVERY-TARGET ref for `start --target`:
  # origin/<branch> when the remote has it (freshest, the ac_default_ref
  # idiom), else the local branch, else a loud refusal - a mistyped target
  # must never silently fall back to the default and review the wrong diff.
  local t="$1"
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$t"; then
    printf 'origin/%s\n' "$t"
  elif git -C "$repo" show-ref --verify --quiet "refs/heads/$t"; then
    printf '%s\n' "$t"
  else
    ac_die "start: --target branch not found (neither origin/$t nor $t): $t"
  fi
}

fresh_base() {
  # Recomputed merge-base against the run's DELIVERY TARGET when one was
  # pinned (start --target -> target= in run.meta), else the repo default
  # ref - a task delivering into prelive/release-vN must review/test the
  # diff vs THAT branch, not vs origin/HEAD (live miss: PR #3856 reviewed 8
  # files instead of 145). Recomputed each call: the base drifts after a
  # rebase, so never trust the value frozen at start. An explicit $1 serves
  # cmd_start, which runs before run.meta exists.
  local ref="${1:-}"
  if [ -z "$ref" ] && readlink "$current" >/dev/null 2>&1; then
    ref="$(sed -n 's/^target=//p' "$vdir/$(readlink "$current")/run.meta" 2>/dev/null | head -n 1)"
  fi
  [ -n "$ref" ] || ref="$(ac_default_ref "$repo")"
  # FAIL CLOSED on a genuine merge-base failure (e.g. unrelated histories):
  # falling back to HEAD used to make every consumer compute a HEAD-vs-HEAD
  # delta - a review or test run that inspected nothing, reported green.
  git -C "$repo" merge-base "$ref" HEAD 2>/dev/null \
    || ac_die "fresh_base: merge-base against '$ref' failed - refusing to fall back to HEAD"
}

cmd_start() {
  local intent="" skip="" s target_in="" tref="" config_source="" config_sha want_lint=0 tdd=0 lintnote="" tddnote=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --intent) intent="$2"; shift 2 ;;
      --skip) skip="$2"; shift 2 ;;
      --target) target_in="$2"; shift 2 ;;
      --lint) want_lint=1; shift ;;
      --tdd) tdd=1; shift ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  [ -z "$target_in" ] || tref="$(resolve_target "$target_in")"
  [ -n "$intent" ] || ac_die "--intent is required (pass the captain's goal verbatim)"
  # Unknown skip names must fail loudly, not silently skip nothing.
  if [ -n "$skip" ]; then
    local tok
    for tok in ${skip//,/ }; do
      case " $STEPS " in *" $tok "*) ;; *) ac_die "unknown --skip step: $tok" ;; esac
      # F4 (captain-decided, breaking change): intent and review can never be
      # skipped via this flag - it is what let one flag mint a validated run
      # with zero steps done. cmd_skip_remaining is a SEPARATE command and
      # does not go through this validation, so the empty-diff flow is
      # unaffected.
      case "$tok" in
        intent|review) ac_die "--skip $tok is refused: $tok can never be skipped (the intent-evidence pass is never skipped; crew-ship review is always required, AGENTS.md section 5)" ;;
      esac
    done
  fi
  local id rd branch base status
  id="$(date +%Y%m%d-%H%M%S)-$$"
  rd="$vdir/$id"
  mkdir -p "$rd/logs" "$rd/findings"
  ensure_crew_excluded

  # Freeze one immutable project config per run. Concurrent ship/qa runs may
  # share the canonical home file, but never observe an update mid-run.
  #
  # ac_project_config_file resolves through ac_home(), which REFUSES when
  # AC_HOME is unset - the crewmate pane's normal state, BY DESIGN (a crewmate
  # never carries AC_HOME; the path rides its launch line instead, ac-spawn.sh
  # AC_FLEET_PROJECT_CONFIG below). Before it refused it answered ac_root, the
  # config-less distro checkout.
  # That phantom miss is INDISTINGUISHABLE from a project that genuinely has
  # no installed config, so resolving it bare would silently drop every key
  # the captain pinned (review.max_rounds among them) whenever a crewmate's
  # AC_HOME happens to be unset - not a rare race, the crewmate's every run.
  # AC_FLEET_HOME_CHECKED is the positive signal that ac-spawn.sh ALREADY ran
  # this resolution with a real AC_HOME and is handing over its answer -
  # AC_FLEET_PROJECT_CONFIG present or not, both trusted. Absent that signal,
  # a real AC_HOME still resolves normally (a homed caller: roomchief,
  # self-task, manual invocation); only when NEITHER a checked answer NOR a
  # real AC_HOME exists is the ambiguity genuine, and it refuses loudly rather
  # than defaulting to an empty config nobody can tell apart from a verified
  # "none".
  if [ -n "${AC_FLEET_HOME_CHECKED:-}" ]; then
    config_source="${AC_FLEET_PROJECT_CONFIG:-}"
    if [ -n "$config_source" ]; then
      [ -f "$config_source" ] \
        || ac_die "AC_FLEET_PROJECT_CONFIG names a missing file: $config_source"
      cp "$config_source" "$rd/config.yaml"
    else
      : >"$rd/config.yaml"
    fi
  elif config_source="$(ac_project_config_file "$repo")"; then
    cp "$config_source" "$rd/config.yaml"
  elif [ -n "${AC_HOME:-}" ]; then
    config_source=""
    : >"$rd/config.yaml"
  else
    ac_die "cannot resolve the project's pipeline config: AC_HOME is unset and no AC_FLEET_PROJECT_CONFIG was threaded by ac-spawn.sh - freezing an empty config here would be indistinguishable from a project that genuinely has none installed, silently dropping any captain-pinned key. Re-spawn through bin/ac-spawn.sh (it resolves this with a real AC_HOME and hands the answer over), or export AC_HOME before running start directly."
  fi
  config_sha="$(ac_config_sha256 "$rd/config.yaml")"

  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')"
  base="$(fresh_base "$tref")"
  {
    printf 'intent=%s\n' "$intent"
    printf 'branch=%s\n' "$branch"
    printf 'base=%s\n' "$base"
    [ -z "$tref" ] || printf 'target=%s\n' "$tref"
    printf 'config_source=%s\n' "${config_source:-none}"
    printf 'config_sha256=%s\n' "$config_sha"
    printf 'created_at=%s\n' "$(ac_iso)"
    printf 'outcome=running\n'
  } >"$rd/run.meta"
  for s in $STEPS; do
    status=pending
    # lint is OPT-IN (captain.md 2026-07-21, crew-ship-lean-pipeline): skip-by-
    # default, runs ONLY when --lint is requested. An explicit --skip below still
    # wins, so a requested lint can also be skipped and the two never contradict.
    [ "$s" = lint ] && [ "$want_lint" = 0 ] && status=skipped
    # test SKIPS on --tdd - the implement DECLARES its TDD run is the evidence
    # (captain.md 2026-07-21). FAIL CLOSED: absent --tdd, test stays pending and
    # RUNS. It is a claim, not attestation-by-execution; a fix that changes code
    # re-runs test regardless (the skill's fix-reopen rule), because the
    # implement's TDD never covers a later fix diff.
    [ "$s" = test ] && [ "$tdd" = 1 ] && status=skipped
    case ",$skip," in *",$s,"*) status=skipped ;; esac
    printf '%s\t%s\t0\n' "$s" "$status"
  done >"$rd/steps.tsv"
  ln -sfn "$id" "$current"
  watch_open "$rd" "$branch"
  # Surface each skip so a green run is never mistaken for a linted or tested one.
  [ "$want_lint" = 0 ] && lintnote=' (lint skip-by-default: pass --lint to run it)'
  [ "$tdd" = 1 ] && tddnote=' (test skipped: --tdd declares the implement covered it)'
  printf 'started run %s branch=%s base=%s%s%s%s\n' "$id" "$branch" "${base:0:12}" "${tref:+ target=$tref}" "$lintnote" "$tddnote"
}

watch_open() {
  # Auto-open the live run dashboard in a herdr tab: idempotent (skips when
  # an ac-ship-watch pane already exists),
  # never fails the start, disabled with AC_SHIP_WATCH=off. The watch
  # self-closes when the run finishes or idles (see ac-ship-watch.sh);
  # finish also closes it via <run>/watch.pane.
  local rd="$1" branch="$2" ses ws out p label
  [ "${AC_SHIP_WATCH:-auto}" = off ] && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  ses="${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}"
  herdr --session "$ses" pane list 2>/dev/null | grep -q '"label":"ac-ship-watch"' && return 0
  label="ac-ship-watch-$(printf '%s' "$branch" | tr '/' '-')"
  # The watch tab joins its FAMILY's workspace (ac-backend.sh FAMILY
  # WORKSPACE GROUPING): family from the crew/<id> branch's id, through the
  # scope ladder (a scoped caller's AC_SCOPE/AC_FLEET_SCOPE still wins).
  ws="$(AC_WINDOW_FAMILY="$(ac_window_family "${branch#crew/}")" \
    ac_herdr_agents_workspace 2>/dev/null || true)"
  out="$(ac_herdr_tab_open "$ses" "$label" "$repo" "$ws")" || return 0
  p="${out%% *}"
  # DEGRADE, per the "never fails the start" contract above: the tab is already
  # open by now, so a rename/run that fails (pane gone, herdr wedged) must cost
  # the run its DASHBOARD, never its progress - unguarded they aborted `start`
  # and `step` silently, after the run dir and `current` symlink already existed.
  # Continue rather than return: the pane handle below is how finish retires the
  # tab that WAS created, so an early return would leak it.
  herdr --session "$ses" pane rename "$p" ac-ship-watch >/dev/null 2>&1 || true
  herdr --session "$ses" pane run "$p" \
    "'$bin_dir/ac-ship-watch.sh' --repo '$repo' --self-pane $p" >/dev/null 2>&1 || true
  printf '%s\n' "$p" >"$rd/watch.pane"
  if [ -n "$ws" ]; then
    herdr --session "$ses" tab list 2>/dev/null | WSID="$ws" python3 -c "
import sys, json, os
try:
    for t in json.load(sys.stdin)['result']['tabs']:
        if t.get('workspace_id') == os.environ['WSID'] and t.get('label') == '1':
            print(t['tab_id'])
except Exception:
    pass
" 2>/dev/null | while read -r jt; do
      # Same DEGRADE class: tidying herdr's default tab away is cosmetic, and
      # this close is what the whole pipeline's exit status reports.
      herdr --session "$ses" tab close "$jt" >/dev/null 2>&1 || true
    done
  fi
  return 0
}

cmd_step() {
  require_run
  local name="${1:-}" status="${2:-}" note=""
  shift 2 || ac_die "usage: ac-ship.sh step <name> <status> [--note <text>]"
  if [ "${1:-}" = "--note" ]; then
    note="${2:-}"
  fi
  case " $STEPS " in *" $name "*) ;; *) ac_die "unknown step: $name" ;; esac
  case " $STATUSES " in *" $status "*) ;; *) ac_die "unknown status: $status" ;; esac
  local rd tmp
  rd="$(run_dir)"
  # Fail-closed independence gate: review only completes with evidence that
  # a FRESH mind reviewed (review-agent marker, or a harness subagent
  # recorded via `meta review` with a "reviewer" field). Never self-review.
  if [ "$name" = review ] && [ "$status" = completed ]; then
    # Selected by CURRENCY, not by mere existence (F8b). Picking the agent
    # receipt whenever the FILE was present made the manual branch below
    # unreachable for the rest of a run that had ever used review-agent -
    # dead precisely when a fix had landed and the verifier had become
    # unusable, while the no-evidence refusal at the bottom went on naming
    # that same manual channel as a remedy.
    local reviewed_ref current_ref
    reviewed_ref="$(sed -n 's/^reviewed_ref=//p' "$rd/review.agent" 2>/dev/null | tail -n 1)" || reviewed_ref=""
    current_ref="$(git -C "$repo" rev-parse HEAD)"
    if [ -n "$reviewed_ref" ] && [ "$reviewed_ref" = "$current_ref" ]; then
      : # a CURRENT agent receipt is authoritative and needs no stamp
    elif [ -f "$rd/findings/review.meta.json" ] \
         && jq -e '(.reviewer // "") != ""' "$rd/findings/review.meta.json" >/dev/null; then
      # Manual reviewer path: stamp reviewed_ref = current HEAD at THIS
      # transition, mirroring the review-agent path above (F8) - so a
      # ref-changing fix afterward is REFUSED by assert_review_current,
      # not merely warned about.
      local mtmp
      mtmp="$(mktemp "$rd/findings/.review.meta.XXXXXX")" \
        || ac_die "step: mktemp failed while stamping reviewed_ref"
      if jq --arg ref "$current_ref" '.reviewed_ref = $ref' \
           "$rd/findings/review.meta.json" >"$mtmp"; then
        mv "$mtmp" "$rd/findings/review.meta.json"
      else
        rm -f "$mtmp"
        ac_die "step: could not stamp reviewed_ref into review.meta.json"
      fi
      # RETIRE the superseded agent receipt rather than leaving it to win at
      # delivery: assert_review_current prefers review.agent and falls back
      # only when its ref is EMPTY, so a precedence change here alone would
      # complete review and then refuse push for the same stale ref. Renamed,
      # never deleted - the round's evidence outlives the takeover.
      [ ! -f "$rd/review.agent" ] \
        || mv "$rd/review.agent" "$rd/review.agent.superseded" \
        || ac_die "step: could not retire the superseded review.agent receipt"
    elif [ -f "$rd/review.agent" ]; then
      ac_die "review receipt is stale: reviewed ${reviewed_ref:-none}, current HEAD $current_ref - run a fresh independent review"
    else
      ac_die "review has no independent-reviewer evidence: run ac-ship.sh review-agent, or record meta review with a \"reviewer\" field after a clean-context subagent reviewed"
    fi
  fi
  tmp="$(mktemp)"
  # Locked read-modify-write: test and lint may be driven by CONCURRENT
  # subagents (the skill fans them out), and two unlocked writers to
  # steps.tsv lose a row. `fixing` increments the durable round counter (col 3).
  ac_lock_acquire "$rd/.steps.lock" 30 || ac_die "steps ledger lock timeout"
  # ABORT, never fall through: the ledger IS the state machine's truth, and
  # `awk >tmp && mv` is a non-final AND-OR element, which errexit EXEMPTS (and
  # pipefail does not cover - it is not a pipeline). Unguarded, a failed read or
  # a failed swap left the ledger unchanged, leaked the staged temp file, and
  # still printed `<step> -> <status>`. The lock is released on the refusal path
  # too: ac_die exits, and a held .steps.lock would then stall every concurrent
  # writer for its full 30s timeout before they, too, refused.
  if ! { awk -F'\t' -v OFS='\t' -v s="$name" -v st="$status" '
      $1 == s { $2 = st; if (st == "fixing") $3 = ($3 + 0) + 1 }
      { print }' "$rd/steps.tsv" >"$tmp" && mv "$tmp" "$rd/steps.tsv"; }; then
    rm -f "$tmp"
    ac_lock_release "$rd/.steps.lock"
    ac_die "step: could not update the steps ledger ($rd/steps.tsv) - failing closed"
  fi
  ac_lock_release "$rd/.steps.lock"
  printf '%s step=%s status=%s%s\n' "$(ac_iso)" "$name" "$status" "${note:+ note=$note}" >>"$rd/logs/run.log"
  # Ensure the live dashboard whenever a step goes ACTIVE - start-only
  # auto-open missed runs that reopen after finish (hold-and-fix) or lose
  # their watch pane mid-run. watch_open is idempotent and never fails.
  case "$status" in
    running|fixing|awaiting_approval)
      watch_open "$rd" "$(sed -n 's/^branch=//p' "$rd/run.meta" | head -n 1)" ;;
  esac
  local rounds
  rounds="$(awk -F'\t' -v s="$name" '$1 == s { print $3 }' "$rd/steps.tsv")"
  if [ "$status" = "fixing" ]; then
    printf '%s -> %s (auto-fix round %s)\n' "$name" "$status" "$rounds"
  else
    printf '%s -> %s\n' "$name" "$status"
  fi
}

cmd_findings() {
  require_run
  local step="${1:-}" rd f json newf dropped
  case " $STEPS " in *" $step "*) ;; *) ac_die "unknown step: $step" ;; esac
  case "${2:-}" in
    --show) ;;
    "") ;;
    *) ac_die "usage: ac-ship.sh findings <step> [--show]" ;;
  esac
  rd="$(run_dir)"
  f="$rd/findings/$step.json"
  if [ "${2:-}" = "--show" ]; then
    [ -f "$f" ] || ac_die "no findings recorded for step $step"
    cat "$f"
    return 0
  fi
  [ -t 0 ] && ac_die "findings $step reads a JSON array on stdin - refusing a tty (pipe JSON in, or use --show to view)"
  json="$(cat)"
  jq -e 'type == "array"' <<<"$json" >/dev/null || ac_die "findings must be a JSON array"
  newf="$(mktemp "$rd/findings/.$step.XXXXXX")" || ac_die "findings $step: mktemp failed"
  if ! ac_findings_normalize "$newf" <<<"$json"; then
    rm -f "$newf"
    ac_die "findings $step: normalize failed"
  fi
  # The review step's resolution model (header: Findings JSON) is a fresh
  # review-agent round dropping a `fix` finding, never an in-place re-post.
  # F8 machine-held the reviewed_ref half of that; this holds the other half -
  # a plain re-post may never silently erase a recorded `fix` finding. Only the
  # TRUSTED internal caller (cmd_review_agent, which IS the resolution: a fresh
  # independent round) sets _ac_findings_trusted for its own call.
  if [ "$step" = review ] && [ "${_ac_findings_trusted:-0}" != 1 ] && [ -f "$f" ]; then
    dropped="$(jq -n --slurpfile old "$f" --slurpfile new "$newf" -r '
      ([$old[0][]? | select(.action == "fix") | (.id // "?")]) as $o
      | ([$new[0][]? | select(.action == "fix") | (.id // "?")]) as $n
      | ($o - $n) | join(", ")
    ')"
    if [ -n "$dropped" ]; then
      rm -f "$newf"
      ac_die "findings review refused (fail-closed): re-post drops fix finding(s) [$dropped] with no resolution - only ac-ship.sh review-agent may resolve a fix finding (re-review it, or record its captain decision)"
    fi
  fi
  mv "$newf" "$f"
  ac_findings_summary "$f"
}

cmd_meta() {
  # Envelope data the PR body needs: review risk, test evidence summary.
  require_run
  local step="${1:-}" rd f json tmp
  case " $STEPS " in *" $step "*) ;; *) ac_die "unknown step: $step" ;; esac
  rd="$(run_dir)"
  f="$rd/findings/$step.meta.json"
  [ -t 0 ] && ac_die "meta $step reads a JSON object on stdin - refusing a tty"
  json="$(cat)"
  jq -e 'type == "object"' <<<"$json" >/dev/null || ac_die "meta must be a JSON object"
  tmp="$(mktemp "$f.XXXXXX")" || ac_die "meta $step: mktemp failed"
  if jq . <<<"$json" >"$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    ac_die "meta $step: write failed"
  fi
  jq -r 'keys | join(" ")' "$f"
}

cmd_attest_test() {
  # The implementer's final TDD green run - attestation by execution, spec
  # in the header (TDD ATTESTATION). Run-independent: it may (and normally
  # does) run BEFORE `start`. Writes <repo>/.crew/ship/attest-test.json
  # atomically on green; a failing run writes nothing and propagates.
  local cf c branch head tree tmp rc dirty
  # Attestation is normally created before `start`, so it resolves the current
  # installed home config directly. The following run freezes that same source.
  cf="$(ac_project_config_file "$repo")" || { printf '(no config file)\n' >&2; exit 4; }
  c="$(ac_yaml_get "$cf" commands.test)"
  [ -n "$c" ] || { printf '(no commands.test configured - nothing to attest)\n' >&2; exit 4; }
  ensure_crew_excluded
  # `[ -z "$(git status)" ]` reads a FAILED status as a CLEAN tree - the test is
  # on the OUTPUT, and a git that cannot run produces none. Both dirty checks
  # below therefore capture first and test second: an unreadable worktree state
  # is not evidence of a clean one, and attestation by execution has no room for
  # a guess (a wrongly-accepted attestation makes the test step skip the suite).
  dirty="$(git -C "$repo" status --porcelain)" \
    || ac_die "attest-test: cannot read the worktree state (failing closed)"
  [ -z "$dirty" ] \
    || ac_die "attest-test: worktree has uncommitted changes - an attestation must describe the COMMITTED state; commit first"
  mkdir -p "$vdir"
  [ ! -d "$vdir/attest-test.json" ] \
    || ac_die "attest-test: $vdir/attest-test.json is a directory - remove it first"
  local log="$vdir/attest-test.log" secs sha started ended
  printf '$ %s\n' "$c" >&2
  secs=$SECONDS
  started="$(ac_iso)"
  set +e
  ( cd "$repo" && sh -c "$c" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  ended="$(ac_iso)"
  secs=$((SECONDS - secs))
  if [ "$rc" -ne 0 ]; then
    printf 'attest-test: test command failed (exit %s) - no attestation written\n' "$rc" >&2
    exit "$rc"
  fi
  # A suite that mutates tracked files attests nothing about the commit.
  dirty="$(git -C "$repo" status --porcelain)" \
    || ac_die "attest-test: cannot read the worktree state (failing closed)"
  [ -z "$dirty" ] \
    || ac_die "attest-test: the test run left the worktree dirty - refusing to attest (does commands.test mutate tracked files?)"
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')"
  head="$(git -C "$repo" rev-parse HEAD)"
  tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
  sha="$(shasum -a 256 <"$log" | awk '{print $1}')"
  tmp="$(mktemp "$vdir/.attest-XXXXXX")"
  # started_at/completed_at are APPEND-ONLY additions (header: TDD ATTESTATION):
  # attest_conditions never reads them, so an older attestation still validates,
  # while the ship test receipt copied from a fresh one carries the real
  # execution window the QA boundary policy requires.
  jq -n --arg branch "$branch" --arg commit "$head" --arg tree "$tree" \
    --arg cmd "$c" --arg at "$(ac_iso)" --arg sha "$sha" --argjson secs "$secs" \
    --arg started "$started" --arg ended "$ended" \
    '{branch: $branch, commit: $commit, tree: $tree, cmd: $cmd, at: $at, output_sha256: $sha, duration_s: $secs, started_at: $started, completed_at: $ended}' >"$tmp"
  mv "$tmp" "$vdir/attest-test.json"
  printf 'attested: commands.test green @%s (branch %s) - the test step will honor this until HEAD or the command changes\n' \
    "${head:0:12}" "$branch"
}

attest_conditions() {
  # attest_conditions <attest-file> <configured-test-cmd> - prints the
  # rejection reason; empty output = every acceptance condition holds
  # (spec in the header, TDD ATTESTATION). The ONE implementation of the
  # conditions; consumers: attest_accept (pipeline auto-accept) and
  # cmd_attest_check (verifier query).
  local af="$1" c="$2" why=""
  local abranch acommit atree acmd asha branch head tree
  abranch="$(jq -r '.branch // ""' "$af" 2>/dev/null)" || abranch=""
  acommit="$(jq -r '.commit // ""' "$af" 2>/dev/null)" || acommit=""
  atree="$(jq -r '.tree // ""' "$af" 2>/dev/null)" || atree=""
  acmd="$(jq -r '.cmd // ""' "$af" 2>/dev/null)" || acmd=""
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')"
  head="$(git -C "$repo" rev-parse HEAD)"
  tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
  if [ -z "$acommit" ] || [ -z "$atree" ] || [ -z "$acmd" ]; then
    why="unreadable or incomplete attestation file"
  elif [ "$abranch" != "$branch" ]; then
    why="branch moved (attested $abranch, on $branch)"
  elif [ "$acommit" != "$head" ]; then
    why="commit moved (attested ${acommit:0:12}, HEAD ${head:0:12})"
  elif [ "$atree" != "$tree" ]; then
    why="tree mismatch (attested ${atree:0:12}, HEAD tree ${tree:0:12})"
  elif [ "$acmd" != "$c" ]; then
    why="commands.test changed since attestation"
  else
    asha="$(jq -r '.output_sha256 // ""' "$af" 2>/dev/null)" || asha=""
    if [ -n "$asha" ]; then
      if [ ! -f "$vdir/attest-test.log" ] \
        || [ "$(shasum -a 256 <"$vdir/attest-test.log" | awk '{print $1}')" != "$asha" ]; then
        why="attestation log missing or does not hash to output_sha256"
      fi
    fi
  fi
  printf '%s' "$why"
}

cmd_attest_check() {
  # The verifier's freshness query - spec in the header (TDD ATTESTATION).
  # Run-independent, and deliberately NOT gated by test.attestation: a
  # query skips nothing by itself.
  local af="$vdir/attest-test.json" cf c="" why head
  [ -f "$af" ] || { printf 'no attestation\n'; exit 2; }
  if cf="$(config_file)"; then c="$(ac_yaml_get "$cf" commands.test)"; fi
  why="$(attest_conditions "$af" "$c")"
  if [ -n "$why" ]; then
    printf 'stale: %s\n' "$why"
    exit 1
  fi
  head="$(git -C "$repo" rev-parse HEAD)"
  printf 'attested: fresh @%s (%s)\n' "${head:0:12}" "$c"
}

attest_accept() {
  # attest_accept <run-dir> <configured-test-cmd> <config-file> ->
  # 0 = attestation accepted (test step completed, empty findings + meta
  # recorded, suite NOT run); 1 = no acceptance, run the suite.
  # The acceptance conditions live in attest_conditions (header: TDD
  # ATTESTATION); this adds the pipeline's test.attestation config gate.
  local rd="$1" c="$2" cf="$3" af="$vdir/attest-test.json" mode why="" head
  mode="$(ac_yaml_get "$cf" test.attestation)"
  case "$mode" in
    ""|accept) ;;
    ignore)
      if [ -f "$af" ]; then
        printf 'test attestation present but test.attestation=ignore - running the suite\n' >&2
        printf '%s test attestation skipped: test.attestation=ignore\n' "$(ac_iso)" >>"$rd/logs/run.log"
      fi
      return 1 ;;
    *)
      # Unknown values fail CLOSED for a skip-guard: run the suite.
      printf 'test.attestation=%s is not accept|ignore - failing closed, running the suite\n' "$mode" >&2
      printf '%s test attestation skipped: unknown test.attestation value %s\n' "$(ac_iso)" "$mode" >>"$rd/logs/run.log"
      return 1 ;;
  esac
  [ -f "$af" ] || return 1
  why="$(attest_conditions "$af" "$c")"
  head="$(git -C "$repo" rev-parse HEAD)"
  if [ -n "$why" ]; then
    printf 'attestation not accepted: %s - running the suite\n' "$why" >&2
    printf '%s test attestation rejected: %s\n' "$(ac_iso)" "$why" >>"$rd/logs/run.log"
    return 1
  fi
  printf '[]\n' >"$rd/findings/test.json"
  jq -n --arg s "TDD attestation @${head:0:12}, suite not re-run" \
    --arg t "$c green at attestation ($(jq -r '.at // ""' "$af"))" \
    '{testing_summary: $s, tested: [$t], artifacts: []}' >"$rd/findings/test.meta.json"
  cmd_step test completed --note "TDD attestation accepted" >/dev/null
  printf '%s test attestation accepted commit=%s - suite not re-run\n' "$(ac_iso)" "${head:0:12}" >>"$rd/logs/run.log"
  printf 'test: TDD attestation accepted @%s - suite not re-run\n' "${head:0:12}"
  return 0
}

test_receipt_write() {
  # test_receipt_write <run-dir> <qualification> <reason> [cmd-sha] [out-sha]
  #                    [started] [completed] [exit-code]
  # Publish the run-scoped exact-SHA test receipt (header: SHIP TEST RECEIPT)
  # through a temp file plus atomic rename, so a reader never sees a half
  # receipt and an interrupted attempt cannot leave an earlier success current.
  local rd="$1" qual="$2" reason="$3" tmp
  local cmd_sha="${4:--}" out_sha="${5:--}" started="${6:--}" ended="${7:--}" code="${8:--}"
  mkdir -p "$rd/test"
  tmp="$(mktemp "$rd/test/.receipt.XXXXXX")"
  {
    printf 'schema=agentcrew.ship-test-receipt/v1\n'
    printf 'source_sha=%s\n' "$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf '-')"
    printf 'qualification=%s\n' "$qual"
    printf 'reason=%s\n' "$reason"
    printf 'ship_run=%s\n' "$(basename "$rd")"
    printf 'command_sha256=%s\n' "$cmd_sha"
    printf 'output_sha256=%s\n' "$out_sha"
    printf 'started_at=%s\n' "$started"
    printf 'completed_at=%s\n' "$ended"
    printf 'exit_code=%s\n' "$code"
  } >"$tmp"
  mv "$tmp" "$rd/test/receipt.env" \
    || { rm -f "$tmp"; ac_die "cmd test could not publish its run-scoped test receipt"; }
}

cmd_cmd() {
  require_run
  local name="${1:-}" cf c rd started tc changed cfile esc quoted scoped=0
  case "$name" in test|lint|format) ;; *) ac_die "usage: ac-ship.sh cmd <test|lint|format>" ;; esac
  cf="$(config_file)" || { printf '(no config file)\n' >&2; exit 4; }
  c="$(ac_yaml_get "$cf" "commands.$name")"
  [ -n "$c" ] || { printf '(no commands.%s configured)\n' "$name" >&2; exit 4; }
  rd="$(run_dir)"
  if [ "$name" = test ]; then
    # A second attempt invalidates an earlier qualifying receipt BEFORE the
    # command runs (header: SHIP TEST RECEIPT). An interruption therefore
    # leaves `incomplete`, never a stale success a QA round could freeze.
    test_receipt_write "$rd" not-qualifies incomplete
    if attest_accept "$rd" "$c" "$cf"; then
      test_receipt_from_attestation "$rd" "$c"
      exit 0
    fi
    # SCOPED TEST (captain order 2026-07-30, header: SCOPED TEST): with
    # commands.test-changed configured, the test step prefers the changed-file
    # run over the full suite. {files} is replaced by the shell-quoted
    # base-to-HEAD changed set (deletions excluded); an empty changed set
    # falls back to the full commands.test - failing toward running, like the
    # test step itself. A scoped green is pipeline evidence only: its receipt
    # says not-qualifies:scoped, so QA's UT bridge can never mistake a partial
    # run for suite proof (full-suite evidence stays attest-test/full cmd).
    tc="$(ac_yaml_get "$cf" commands.test-changed)"
    if [ -n "$tc" ]; then
      case "$tc" in *"{files}"*) ;; *) ac_die "commands.test-changed must carry a {files} placeholder" ;; esac
      changed="$(git -C "$repo" diff --name-only --diff-filter=d "$(fresh_base)" HEAD)"
      if [ -n "$changed" ]; then
        quoted=""
        while IFS= read -r cfile; do
          esc="$(printf '%s' "$cfile" | sed "s/'/'\\\\''/g")"
          quoted="$quoted '$esc'"
        done <<<"$changed"
        c="${tc//\{files\}/$quoted}"
        scoped=1
        printf '(scoped test: %s changed files)\n' "$(printf '%s\n' "$changed" | grep -c .)" >&2
      fi
    fi
  fi
  printf '$ %s\n' "$c" >&2
  started="$(ac_iso)"
  set +e
  ( cd "$repo" && sh -c "$c" ) 2>&1 | tee "$rd/logs/$name.log"
  rc="${PIPESTATUS[0]}"
  set -e
  printf '%s cmd=%s exit=%s\n' "$(ac_iso)" "$name" "$rc" >>"$rd/logs/run.log"
  if [ "$name" = test ]; then
    if [ "$rc" = 0 ]; then
      if [ "$scoped" = 1 ]; then
        test_receipt_write "$rd" not-qualifies scoped \
          "$(printf '%s' "$c" | shasum -a 256 | awk '{print $1}')" \
          "$(shasum -a 256 <"$rd/logs/test.log" | awk '{print $1}')" \
          "$started" "$(ac_iso)" 0
      else
        test_receipt_write "$rd" qualifies executed \
          "$(printf '%s' "$c" | shasum -a 256 | awk '{print $1}')" \
          "$(shasum -a 256 <"$rd/logs/test.log" | awk '{print $1}')" \
          "$started" "$(ac_iso)" 0
      fi
    else
      test_receipt_write "$rd" not-qualifies non-zero \
        "$(printf '%s' "$c" | shasum -a 256 | awk '{print $1}')" \
        "$(shasum -a 256 <"$rd/logs/test.log" | awk '{print $1}')" \
        "$started" "$(ac_iso)" "$rc"
    fi
  fi
  exit "$rc"
}

test_receipt_from_attestation() {
  # test_receipt_from_attestation <run-dir> <configured-test-cmd> - copy the
  # accepted attestation's EXACT execution identity into the run-scoped
  # receipt. An attestation written before this field pair existed carries no
  # start/end timestamps, so it normalizes to `not-qualifies` at the reader
  # (ac_qa_ship_receipt_status) rather than being repaired here: the receipt
  # states what the attestation actually recorded, nothing more.
  local rd="$1" c="$2" af="$vdir/attest-test.json" started ended out_sha
  [ -f "$af" ] || { test_receipt_write "$rd" not-qualifies invalid; return 0; }
  started="$(jq -r '.started_at // "-"' "$af" 2>/dev/null)" || started="-"
  ended="$(jq -r '.completed_at // "-"' "$af" 2>/dev/null)" || ended="-"
  out_sha="$(jq -r '.output_sha256 // "-"' "$af" 2>/dev/null)" || out_sha="-"
  if [ "$started" = "-" ] || [ -z "$started" ] || [ "$ended" = "-" ] || [ -z "$ended" ] \
    || [ "$out_sha" = "-" ] || [ -z "$out_sha" ]; then
    test_receipt_write "$rd" not-qualifies invalid \
      "$(printf '%s' "$c" | shasum -a 256 | awk '{print $1}')" \
      "${out_sha:--}" "${started:--}" "${ended:--}" 0
    return 0
  fi
  test_receipt_write "$rd" qualifies execution-attestation \
    "$(printf '%s' "$c" | shasum -a 256 | awk '{print $1}')" \
    "${out_sha:--}" "${started:--}" "${ended:--}" 0
}

published_head() {
  # published_head <branch> <sha> - 0 when THIS pipeline pushed exactly that sha
  # for that branch. Run-independent on purpose (the attest-test.json
  # precedent): a multi-PR chain rebases in run N+1 over what run N published.
  [ -f "$vdir/pushed.tsv" ] || return 1
  awk -F'\t' -v b="$1" -v c="$2" '$1 == b && $2 == c { hit = 1 } END { exit !hit }' \
    "$vdir/pushed.tsv"
}

record_push() {
  # Appended only after the push actually landed, so the file states what the
  # remote HAS, never what someone intends it to have.
  printf '%s\t%s\n' "$1" "$2" >>"$vdir/pushed.tsv"
}

cmd_push() {
  # Deterministic push with a data-loss guard: refuse to
  # force-push over remote commits not incorporated by patch-id, anchor the
  # lease to the exact remote SHA, and FAIL CLOSED on any git error.
  require_run
  # Fail closed, never HANG: on a repo whose credentials are not cached, an
  # unset GIT_TERMINAL_PROMPT makes ls-remote/fetch/push sit at a username
  # prompt forever, wedging the agent's tool call - the opposite of the "any
  # git error dies" contract above. 0 turns that prompt into an immediate,
  # catchable failure. GIT_OPTIONAL_LOCKS=0 keeps a read-only probe from
  # churning the index. Exported (git reads the env), scoped to this function.
  export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0
  local rd branch ref head remote_sha base unincorporated
  rd="$(run_dir)"
  # Before ANY remote-touching command: what gets pushed is what was reviewed.
  # A refusal here has published nothing.
  assert_review_current "$rd" "push"
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)" \
    || ac_die "push: refusing from a detached HEAD"
  [ "$branch" != "$(ac_default_branch "$repo")" ] \
    || ac_die "push: refusing to push the default branch"
  # A pinned delivery target is protected exactly like the default branch:
  # the crew branch delivers INTO it via PR, never becomes it.
  local tname
  tname="$(sed -n 's/^target=//p' "$rd/run.meta" 2>/dev/null | head -n 1)"
  tname="${tname#origin/}"
  [ -z "$tname" ] || [ "$branch" != "$tname" ] \
    || ac_die "push: refusing to push the delivery target branch ($tname)"
  git -C "$repo" remote get-url origin >/dev/null 2>&1 \
    || ac_die "push: no origin remote"
  ref="refs/heads/$branch"
  head="$(git -C "$repo" rev-parse HEAD)"
  remote_sha="$(git -C "$repo" ls-remote origin "$ref" | awk '{print $1}')" \
    || ac_die "push: cannot read the remote (failing closed)"
  if [ -z "$remote_sha" ]; then
    git -C "$repo" push -u origin "$branch" \
      || ac_die "push: plain push of new branch failed"
    record_push "$branch" "$head"
    printf 'pushed new branch %s\n' "$branch"
  elif [ "$remote_sha" = "$head" ]; then
    printf 'up-to-date: origin/%s == HEAD\n' "$branch"
  else
    git -C "$repo" fetch --no-tags origin "$ref" 2>/dev/null \
      || ac_die "push: fetch of $ref failed (failing closed)"
    base="$(fresh_base)"
    # Remote-only commits whose patches are NOT in our history = data loss.
    unincorporated="$(git -C "$repo" rev-list --cherry-pick --right-only \
      "HEAD...$remote_sha" ^"$base" 2>/dev/null)" \
      || ac_die "push: incorporation check failed (failing closed)"
    if [ -n "$unincorporated" ]; then
      # A rebase that RESOLVED A CONFLICT rewrites that commit's diff, so its
      # patch-id changes and --cherry-pick stops cancelling the pre-rebase
      # commit: the branch's own superseded history then reads as foreign remote
      # work, and the most ordinary step of a multi-PR chain has no legal path.
      # EXCUSED ONLY when the remote ref is byte-identical to a head this
      # pipeline published from this branch - then everything on it came from
      # here, and the lease below re-verifies that same sha at write time.
      # This is not an operator DECLARATION: the only way to be excused is to
      # have pushed it through this command, so a commit another actor pushed
      # moves the ref off every published sha and is still refused.
      if published_head "$branch" "$remote_sha"; then
        printf 'push: origin/%s is the head this pipeline published (%s) - rebased, not diverged\n' \
          "$branch" "${remote_sha:0:12}"
      else
        printf 'push: origin/%s has commits not incorporated by this branch:\n' "$branch" >&2
        printf '%s\n' "$unincorporated" | head -10 >&2
        ac_die "push: refusing to force-push over unincorporated remote commits"
      fi
    fi
    git -C "$repo" push --force-with-lease="$ref:$remote_sha" origin "$branch" \
      || ac_die "push: lease-guarded push failed (remote moved; re-run)"
    record_push "$branch" "$head"
    printf 'pushed %s with lease %s\n' "$branch" "${remote_sha:0:12}"
  fi
  printf '%s push branch=%s\n' "$(ac_iso)" "$branch" >>"$rd/logs/run.log"
}

cmd_base() { fresh_base; }

cmd_evidence_dir() {
  # Resolve where test evidence goes. In-repo only when the config says so
  # AND the dir is safe (relative, repo-contained, not gitignored) -
  # anything else falls back to a temp dir.
  require_run
  local rd slug store dir target
  rd="$(run_dir)"
  slug="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null | tr '/' '-' || printf 'detached')"
  store="$(cmd_config test.evidence.store_in_repo 2>/dev/null || true)"
  dir="$(cmd_config test.evidence.dir 2>/dev/null || true)"
  if [ "$store" = "true" ]; then
    dir="${dir:-.agent-crew/evidence}"
    case "$dir" in
      /*|*..*) ac_warn "evidence dir unsafe ($dir); using temp" ;;
      *)
        target="$repo/$dir/$slug"
        if git -C "$repo" check-ignore -q "$dir" 2>/dev/null; then
          ac_warn "evidence dir is gitignored ($dir); using temp"
        else
          mkdir -p "$target"
          printf '%s\n' "$target"
          return 0
        fi
        ;;
    esac
  fi
  target="${TMPDIR:-/tmp}/agent-crew-evidence/$(basename "$rd")"
  mkdir -p "$target"
  printf '%s\n' "$target"
}

cmd_skip_remaining() {
  # Empty diff after rebase: nothing to ship, everything left is skipped.
  require_run
  local rd tmp
  rd="$(run_dir)"
  tmp="$(mktemp)"
  # Same errexit-exempt AND-OR shape as cmd_step, and the sharper of the two:
  # unguarded, a failed ledger write still printed "remaining steps skipped" and
  # exited 0 having skipped nothing - so the caller moved on to a finish gate
  # that would then refuse on steps it believed were already resolved.
  if ! { awk -F'\t' -v OFS='\t' '
      $2 == "pending" || $2 == "running" { $2 = "skipped" }
      { print }' "$rd/steps.tsv" >"$tmp" && mv "$tmp" "$rd/steps.tsv"; }; then
    rm -f "$tmp"
    ac_die "skip-remaining: could not update the steps ledger ($rd/steps.tsv) - failing closed"
  fi
  printf '%s skip-remaining (empty diff)\n' "$(ac_iso)" >>"$rd/logs/run.log"
  printf 'remaining steps skipped\n'
}

cmd_config() {
  # The GENERIC config reader never exits: `exit` inside a $(...) subshell
  # kills it before any `|| true` INSIDE the substitution can run, so a
  # config-less repo silently killed whole set -e callers (live: the
  # base=prelive review on a fresh detached checkout died with no message
  # at the review.model read). `return 1` lets every caller decide
  # criticality itself - `|| true` degrades to defaults, `|| ac_die`
  # demands config. The cmd/test paths that legitimately REQUIRE config
  # keep their own loud exit-4 (cmd_cmd, attest-test).
  local cf
  cf="$(config_file)" || return 1
  ac_yaml_get "$cf" "${1:?dotted key required}"
}


review_rounds_recorded() {
  # review_rounds_recorded <run-dir> - how many DURABLE verifier round results
  # this run holds: the contiguous logs/review-agent-rN.json series. A REJECTED
  # round writes none (the retry is the same round), so this counts VALIDATED
  # rounds only - which is exactly what "the previous round's verdict" means.
  local rd="$1" n=0
  while [ -s "$rd/logs/review-agent-r$((n + 1)).json" ]; do n=$((n + 1)); done
  printf '%s\n' "$n"
}

retire_rejected_result() {
  # retire_rejected_result <result> - a round result NOTHING validated is not a
  # durable round result: left in place it would burn the round number (the
  # retry is the SAME round) and let the post-pass guard read a verdict no
  # check ever accepted. RENAMED, never deleted - the rejected JSON is the
  # first thing anyone diagnosing the rejection wants to read.
  [ -e "$1" ] || return 0
  mv -f "$1" "$1.rejected" 2>/dev/null || rm -f "$1"
}

review_invocations_recorded() {
  # review_invocations_recorded <run-dir> - how many verifier invocations this
  # run has already OPENED: rows in the durable per-run ledger, appended before
  # the verifier runs so an attempt that dies mid-flight still counts as the
  # spend it was. This is what review.max_rounds bounds - `step review fixing`
  # ticks are a different thing, and nothing but an explicit call ever ticks
  # them, which is how a run could pile up invocations at counter 1.
  local rd="$1"
  [ -s "$rd/logs/review-invocations.tsv" ] || { printf '0\n'; return 0; }
  awk 'END { print NR }' "$rd/logs/review-invocations.tsv"
}

review_invocation_record() {
  # review_invocation_record <run-dir> <round> <ref> - one row per OPEN,
  # `opened` until the attempt ends. A row left `opened` is an attempt killed
  # mid-flight, and it stays honest: it spent a verifier either way.
  printf '%s\t%s\t%s\t%s\n' "$(ac_iso)" "$2" "$3" opened \
    >>"$1/logs/review-invocations.tsv"
}

review_invocation_outcome() {
  # review_invocation_outcome <run-dir> <outcome> - stamp how the LAST recorded
  # attempt ended: `ok`, `dead-pane` (no usable result came back at all), or
  # `rejected-verdict` (a completed round the caller refused). Rewritten in
  # place, never appended, so one row stays one attempt and the count the cap
  # reads never drifts.
  local rd="$1" f tmp n
  f="$rd/logs/review-invocations.tsv"
  [ -s "$f" ] || return 0
  n="$(awk 'END { print NR }' "$f")"
  tmp="$f.tmp"
  awk -F'\t' -v OFS='\t' -v n="$n" -v o="$2" 'FNR == n { $4 = o } { print }' "$f" >"$tmp" \
    && mv "$tmp" "$f" || rm -f "$tmp"
}

review_ref_attempts() {
  # review_ref_attempts <run-dir> <ref> - the prior attempts on exactly this
  # ref, one `attempt N (round R, <iso>) <outcome>` per line. Empty (exit 0)
  # before the run has opened anything: the first invocation must not read as
  # a failure to its errexit caller.
  [ -s "$1/logs/review-invocations.tsv" ] || return 0
  awk -F'\t' -v ref="$2" '$3 == ref {
    printf "attempt %d (round %s, %s) %s\n", ++n, $2, $1, ($4 == "" ? "unknown" : $4)
  }' "$1/logs/review-invocations.tsv"
}

review_verify_evidence_dir() {
  # review_verify_evidence_dir <family> - where ac-verify keeps each round's
  # evidence (transcript.jsonl, pane-result.ndjson[.tmp]), one timestamped dir
  # per attempt, newest last. Derived exactly as ac-verify derives it, from the
  # AC_FLEET_STATE ac-spawn threads into every crew pane; without it, name the
  # path RELATIVE to the fleet home rather than print a wrong absolute one.
  local st="${AC_FLEET_STATE:-}"
  case "$st" in
    */state) printf '%s/data/%s/verify/codereview\n' "${st%/state}" "$1" ;;
    *) printf 'data/%s/verify/codereview (under the fleet home)\n' "$1" ;;
  esac
}

review_delta_is_caller_polish() {
  # review_delta_is_caller_polish <reviewed_ref> <head> <base> - exit 0 ONLY
  # when the delta since <reviewed_ref> is DECIDABLY this run's own post-pass
  # commits: the ref resolves, it is still an ancestor of HEAD (nothing
  # rewrote history), and every commit in the delta is unreachable from the
  # run's fresh base (no upstream commits arrived). Anything else - an
  # unresolvable ref, a rewritten history, upstream commits in the delta, a
  # git call that failed - is UNDECIDABLE and exits 1, which OPENS the round.
  # That fail direction is pinned: written too tight, a genuine rebase would
  # leave a crewmate with no way forward, which is worse than one wasted round.
  local reviewed="$1" head="$2" base="$3" total own
  [ -n "$reviewed" ] && [ -n "$head" ] && [ -n "$base" ] || return 1
  git -C "$repo" rev-parse -q --verify "$reviewed^{commit}" >/dev/null 2>&1 || return 1
  git -C "$repo" merge-base --is-ancestor "$reviewed" "$head" 2>/dev/null || return 1
  total="$(git -C "$repo" rev-list --count "$reviewed..$head" 2>/dev/null)" || return 1
  own="$(git -C "$repo" rev-list --count "$reviewed..$head" "^$base" 2>/dev/null)" || return 1
  [ -n "$total" ] && [ "$total" = "$own" ]
}

cmd_review_agent() {
  # Compatibility/policy adapter only. ac-verify owns exact-ref isolation,
  # fresh pane rounds, prompts, verdict validation, and pane/lease cleanup.
  # review-round-convergence (captain 2026-08-05) adds three gates here:
  # the test-evidence entry precondition, the review.max_rounds cap with the
  # once-only --final-round grant, and the round/fix-delta metadata that arms
  # the shared normalizer's late-finding floor.
  require_run
  local rd round base head intent intent_file result result_tmp verify caller family
  local json reviewed findings_json risk_meta risk
  local prior ledger history_file
  local final_round=0 max_rounds marker test_state af tc cf why floor_ref delta
  local prev prev_n prev_verdict prev_ref prior_open_ids invocation attempts reject_why remedy
  local -a args
  [ "${1:-}" != --final-round ] || final_round=1
  rd="$(run_dir)"
  base="$(fresh_base)"
  head="$(git -C "$repo" rev-parse HEAD)"
  intent="$(sed -n 's/^intent=//p' "$rd/run.meta" | head -n 1)"
  # ROUND NUMBER (B1): the count of DURABLE round results + 1, never the
  # steps.tsv `fixing` column - a verdict that needed no fix never ticks that
  # column, so the old derivation stuck at round 1 and silently OVERWROTE
  # logs/review-agent-r1.json on every later invocation. A rejected round
  # writes no result, so its retry is still the same round (unchanged).
  prev_n="$(review_rounds_recorded "$rd")"
  round="$(( prev_n + 1 ))"

  caller="${AC_CREW_ID:-}"
  if [ -z "$caller" ]; then
    caller="$(sed -n 's/^branch=crew\///p' "$rd/run.meta" | head -n 1)"
  fi
  case "$caller" in ''|DETACHED|*[!a-z0-9-]*) ac_die "review-agent needs AC_CREW_ID from ac-spawn (got '${caller:-empty}')" ;; esac
  family="${AC_FLEET_SCOPE:-}"
  if [ -z "$family" ]; then
    case "$caller" in *-implement) family=${caller%-implement} ;; *) family=$caller ;; esac
  fi

  # ENTRY PRECONDITION (S3): a review round is the expensive judgment check,
  # so it opens only on machine evidence the suite is green - the test step
  # completed this run, or a FRESH TDD attestation (attest_conditions; the
  # bare --tdd declaration is a claim, not evidence, and does not qualify).
  # The 8-step ORDER is unchanged - this gates entering review, so a fix for
  # a suite-catchable failure can never invalidate a review that never ran.
  test_state="$(awk -F'\t' '$1 == "test" { print $2 }' "$rd/steps.tsv")"
  if [ "$test_state" != completed ]; then
    af="$vdir/attest-test.json"
    tc=""
    if cf="$(config_file 2>/dev/null)"; then tc="$(ac_yaml_get "$cf" commands.test)"; fi
    if [ ! -f "$af" ]; then why="no attestation"; else why="$(attest_conditions "$af" "$tc")"; fi
    [ -z "$why" ] || ac_die "review-agent refuses to open without test evidence ($why): complete the test step first (ac-ship.sh cmd test; ac-ship.sh step test completed) or record a fresh attestation (ac-ship.sh attest-test) - a suite-catchable failure must never burn a review round (review-round-convergence)"
  fi

  # POST-PASS FREEZE (A1): a round that returned ZERO `fix` findings FREEZES
  # the tree - its advisory (no-op) findings are notes for the PR body and the
  # backlog, never a licence to commit. A crewmate that polishes one kills its
  # own receipt (the bare-SHA re-check, documentation included) and buys a
  # whole fresh round, which is how a landable run spins forever on PASS
  # verdicts. So refuse to re-open on the caller's OWN post-pass commits, and
  # name the remedy. review_delta_is_caller_polish owns the fail direction:
  # anything undecidable opens the round.
  if [ "$prev_n" -gt 0 ]; then
    prev="$rd/logs/review-agent-r$prev_n.json"
    prev_verdict="$(jq -r '.verdict // ""' "$prev" 2>/dev/null)" || prev_verdict=""
    prev_ref="$(jq -r '.reviewed_ref // ""' "$prev" 2>/dev/null)" || prev_ref=""
    # One exact ref receives one validated review round. Re-running the same
    # SHA cannot prove a fix that was never committed, cannot settle an
    # ask-user finding better than its captain decision, and cannot improve a
    # pass. Infrastructure/schema retries have no durable result and therefore
    # still reach the same-ref attempt brake below.
    if [ -n "$prev_ref" ] && [ "$prev_ref" = "$head" ]; then
      case "$prev_verdict" in
        pass) remedy="complete delivery at this ref; advisory findings belong in the PR/backlog" ;;
        fix) remedy="apply the blocking fix and commit it before requesting the next round" ;;
        ask-user) remedy="record the captain decision; commit only if that decision requires a code change" ;;
        *) remedy="change the reviewed ref before requesting another round" ;;
      esac
      ac_die "review-agent refuses to re-open: round $prev_n already reviewed current HEAD ${head:0:12} with verdict ${prev_verdict:-unknown} - $remedy"
    fi
    if [ "$prev_verdict" = pass ] && review_delta_is_caller_polish "$prev_ref" "$head" "$base"; then
      ac_die "review-agent refuses to re-open: round $prev_n returned a PASS verdict (zero fix findings) at ${prev_ref:0:12}, and every commit since is this run's own - a 0-fix verdict FREEZES the tree, so advisory (no-op) findings are notes for the PR body and the backlog, never a licence to commit. Reset the crew branch back to ${prev_ref:0:12} and land, or ask your chief to mint a follow-up task for the advisory. A genuine rebase re-opens the round by itself."
    fi
  fi

  # SAME-REF RETRY BRAKE (C1): a THIRD attempt on ONE ref is not a review
  # problem - two attempts on an unchanged ref already failed, so the next one
  # fails the same way. Measured live: one ref retried x3 and another x4, one
  # pane dead mid-write and the rest completed verdicts the caller rejected,
  # every retry silent. HOLD ahead of the cap: the cap's remedies (accept the
  # residual, grant a final round) are the wrong advice for a dead pane or a
  # validator mismatch, and the chief needs the evidence, not another round.
  attempts="$(review_ref_attempts "$rd" "$head")"
  if [ "$(printf '%s' "$attempts" | grep -c .)" -ge 2 ]; then
    ac_die "review-agent refuses a THIRD invocation on ref ${head:0:12} - $(printf '%s\n' "$attempts" | awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }'). A repeated failure on ONE ref is an infrastructure or validator signal, and more model spend never fixes it. Diagnose before retrying: the verifier round evidence under $(review_verify_evidence_dir "$family") (transcript.jsonl and pane-result.ndjson[.tmp], newest dir last) and this run's own rejection lines in $rd/logs/run.log. Report this hold with a blocked: line so the chief wakes."
  fi

  # ROUND CAP (S2, counting rewritten by B1): past review.max_rounds
  # (projects/<name>.yaml, default 3) the loop HOLDs for the OWNING CHIEF's
  # chief-decide - never the captain's. The chief either accepts the residual
  # (review-residual accept, receipted) or grants exactly ONE final targeted
  # round; the grant marker is durable, so a second --final-round refuses
  # whatever the pane claims. What the cap COUNTS is verifier INVOCATIONS in
  # this run, including a rejected one - a dead pane costs the same as a
  # verdict - so `review.max_rounds` means invocations per run.
  invocation="$(( $(review_invocations_recorded "$rd") + 1 ))"
  max_rounds="$(cmd_config review.max_rounds 2>/dev/null || true)"
  case "$max_rounds" in '' | *[!0-9]* | 0) max_rounds=3 ;; esac
  if [ "$invocation" -gt "$max_rounds" ]; then
    marker="$rd/review.final-round"
    if [ "$final_round" = 1 ]; then
      [ ! -f "$marker" ] || ac_die "review-agent: the one --final-round is already spent ($(head -n 1 "$marker")) - the residual is the owning chief's call: accept it (ac-ship.sh review-residual accept --grounds '<...>') or the captain re-routes the task"
      printf 'granted_at_round=%s at=%s\n' "$round" "$(ac_iso)" >"$marker"
    else
      ac_die "review-agent: verifier invocation $invocation exceeds review.max_rounds=$max_rounds - the loop HOLDs for the owning chief's chief-decide (review-round-convergence): the chief accepts the residual as advisory (ac-ship.sh review-residual accept --grounds '<grounds>', which prints the SELF-APPROVED receipt to post to the room) or orders exactly ONE targeted final round (ac-ship.sh review-agent --final-round). Report this hold with a blocked: line so the chief wakes."
    fi
  fi
  verify="${AC_VERIFY_BIN:-$(dirname "$0")/ac-verify.sh}"
  [ -x "$verify" ] || ac_die "verifier facade is not executable: $verify"

  intent_file="$rd/logs/review-intent-r$round.md"
  printf '%s\n' "$intent" >"$intent_file"
  result="$rd/logs/review-agent-r$round.json"
  args=(codereview --repo "$repo" --ref "$head" --base "$base"
        --family "$family" --caller "$caller" --intent "$intent_file"
        --output "$result")
  # Previous-round handoff only: round N verifies the findings emitted by round
  # N-1 and reviews exactly N-1.reviewed_ref..HEAD. Findings resolved in N-1 do
  # not become permanent re-attestation obligations in N+1. Every complete
  # round remains durable in its own review-agent-rN.json for audit.
  if [ "$prev_n" -gt 0 ]; then
    prior="$rd/logs/review-agent-r$prev_n.json"
    [ -s "$prior" ] || ac_die "review-agent: previous round result is missing: $prior"
    ledger="$(jq -c --argjson round "$prev_n" \
      '[. | {round: $round, reviewed_ref, verdict, risk_level, findings,
             resolved_ids: (.resolved_ids // [])}]' "$prior")" \
      || ac_die "review-agent: previous round result is unreadable: $prior"
    history_file="$rd/logs/review-history-r$round.json"
    printf '%s\n' "$ledger" >"$history_file"
    args+=(--history "$history_file")
  fi
  review_invocation_record "$rd" "$round" "$head"
  "$verify" "${args[@]}" >/dev/null \
    || { review_invocation_outcome "$rd" dead-pane; retire_rejected_result "$result"; ac_die "independent review round $round failed; inspect the verifier round evidence under $(review_verify_evidence_dir "$family")"; }
  [ -s "$result" ] \
    || { review_invocation_outcome "$rd" dead-pane; ac_die "independent review round $round returned no durable result"; }

  # VERDICT VALIDATION (D1): ONE jq that NAMES the first failing check instead
  # of a compound predicate whose failure said only "invalid or does not bind
  # current HEAD" - the same decision, and a rejected round no longer leaves
  # nothing to read. Same clauses in the same order; only the report is new.
  json="$(cat "$result")"
  reject_why="$(jq -r --arg ref "$head" '
    if type != "object" then "not-a-json-object"
    elif (.findings | type) != "array" then "findings-not-an-array (\(.findings | type))"
    elif .reviewed_ref != $ref then "reviewed_ref-does-not-bind-HEAD (\(.reviewed_ref // "missing"))"
    elif (.verdict as $v | ["pass","fix","ask-user"] | index($v)) == null then "verdict-not-in-enum (\(.verdict // "missing"))"
    elif (.risk_level as $r | ["low","medium","high"] | index($r)) == null then "risk_level-not-in-enum (\(.risk_level // "missing"))"
    elif (.risk_rationale | type) != "string" then "risk_rationale-not-a-string (\(.risk_rationale | type))"
    else "" end
  ' <<<"$json" 2>/dev/null)" || reject_why="unparseable-json"
  if [ -n "$reject_why" ]; then
    printf '%s review-agent round %s: verdict REJECTED - failed check: %s\n' \
      "$(ac_iso)" "$round" "$reject_why" >>"$rd/logs/run.log"
    review_invocation_outcome "$rd" rejected-verdict
    retire_rejected_result "$result"
    ac_die "verifier result rejected - failed check: $reject_why; the verdict is kept at ${result}.rejected"
  fi

  review_invocation_outcome "$rd" ok
  findings_json="$(jq -c '.findings' <<<"$json")"
  # LATE-FINDING FLOOR METADATA (S1): use the SAME immediately previous
  # reviewed ref that ac-verify used for this round's interdiff. From round 3
  # onward, using round 1 here would keep files touched by an older fix inside
  # the delta forever and let late findings on them buy unnecessary rounds.
  # An unreadable or non-ancestor previous ref arms nothing - the floor fails
  # toward reviewing too much, matching ac-verify's scope fallback.
  floor_ref=""
  delta=""
  prior_open_ids='[]'
  if [ "$round" -ge 2 ] && [ -n "${prev_ref:-}" ]; then
    prior_open_ids="$(jq -c '[.findings[]?
      | select(.action == "fix" or .action == "ask-user")
      | .id | select(type == "string")] | unique' "$prev" 2>/dev/null)" \
      || prior_open_ids=""
    floor_ref="$(git -C "$repo" rev-parse --verify "${prev_ref}^{commit}" 2>/dev/null || true)"
    if [ -n "$floor_ref" ] \
      && ! git -C "$repo" merge-base --is-ancestor "$floor_ref" "$head" 2>/dev/null; then
      floor_ref=""
    fi
  fi
  # A fresh independent review round IS the resolution a `fix` finding is
  # waiting for (F9): trust this one internal call to replace review findings
  # wholesale, including dropping resolved `fix` ids.
  if [ -n "$floor_ref" ] && [ -n "$prior_open_ids" ] \
    && delta="$(git -C "$repo" diff --name-only "$floor_ref" "$head" -- 2>/dev/null)"; then
    AC_FINDINGS_ROUND="$round" AC_FINDINGS_DELTA="$delta" \
      AC_FINDINGS_PRIOR_OPEN="$prior_open_ids" \
      _ac_findings_trusted=1 cmd_findings review <<<"$findings_json" >/dev/null
  else
    _ac_findings_trusted=1 cmd_findings review <<<"$findings_json" >/dev/null
  fi
  # The per-round artifact is the handoff to the NEXT round, so persist the
  # policy-normalized findings (including severity/authority/late-round floors)
  # and re-derive its verdict. The facade's raw pane result remains available in
  # the verifier evidence dir; carrying its pre-floor `fix` forward would revive
  # a finding this round already classified as advisory.
  result_tmp="$(mktemp "$rd/logs/.review-agent-r$round.XXXXXX")" \
    || ac_die "review-agent: could not stage normalized round result"
  if jq --slurpfile findings "$rd/findings/review.json" '
      .findings = $findings[0]
      | .verdict = (if ([.findings[].action] | index("ask-user")) != null then "ask-user"
                    elif ([.findings[].action] | index("fix")) != null then "fix"
                    else "pass" end)' <<<"$json" >"$result_tmp"; then
    mv "$result_tmp" "$result"
  else
    rm -f "$result_tmp"
    ac_die "review-agent: could not persist normalized round result"
  fi
  json="$(cat "$result")"
  risk_meta="$(jq -c '{risk_level, risk_rationale, reviewed_ref}
                        + (if (.summary // "") != "" then {summary: .summary} else {} end)' <<<"$json")"
  cmd_meta review <<<"$risk_meta" >/dev/null
  reviewed="$(jq -r '.reviewed_ref' <<<"$json")"
  risk="$(jq -r '.risk_level' <<<"$json")"
  {
    printf 'reviewer=ac-verify\n'
    printf 'round=%s\nreviewed_ref=%s\n' "$round" "$reviewed"
    printf 'result=%s\ncompleted_at=%s\n' "$result" "$(ac_iso)"
  } >"$rd/review.agent"
  printf 'review-agent round %s: %s risk=%s reviewed_ref=%s\n' \
    "$round" "$(ac_findings_summary "$rd/findings/review.json")" "$risk" "$reviewed"
}

cmd_review_residual() {
  # review-residual accept --grounds '<text>' - the OWNING CHIEF's
  # chief-decide on a review loop that hit review.max_rounds
  # (review-round-convergence, captain 2026-08-05): the remaining fix
  # findings become advisory no-ops (residual_accepted, grounds recorded) so
  # the run can complete, and the command PRINTS the SELF-APPROVED receipt
  # the chief posts to the family room - the captain's veto surface, never a
  # question. Refused below the cap (the normal fix loop is not skippable),
  # and refused OUTRIGHT while the residual holds a critical
  # correctness/security/data-loss finding - that carve-out is
  # non-overridable; only --final-round or a captain re-route remains.
  require_run
  local action="${1:-}" grounds="" rd f rounds max_rounds carve nfix tmp
  [ "$action" = accept ] || ac_die "usage: ac-ship.sh review-residual accept --grounds '<text>'"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --grounds) grounds="${2:-}"; shift 2 || ac_die "--grounds needs a value" ;;
      *) ac_die "review-residual: unknown argument $1" ;;
    esac
  done
  [ -n "$grounds" ] || ac_die "review-residual: --grounds is required - the receipt is the captain's veto surface, and a receipt with no grounds records nothing"
  rd="$(run_dir)"
  f="$rd/findings/review.json"
  [ -f "$f" ] || ac_die "review-residual: no review findings recorded"
  # The SAME counter the cap uses (B1): acceptance releases a loop the cap
  # held, so the two must count the same thing or the release is unreachable.
  rounds="$(review_invocations_recorded "$rd")"
  max_rounds="$(cmd_config review.max_rounds 2>/dev/null || true)"
  case "$max_rounds" in '' | *[!0-9]* | 0) max_rounds=3 ;; esac
  [ "$rounds" -ge "$max_rounds" ] || ac_die "review-residual: acceptance is only for a loop AT the cap (rounds=$rounds, review.max_rounds=$max_rounds) - run the normal fix loop"
  carve="$(jq '[.[] | ((.class // "") | tostring) as $c
    | select(.action == "fix" and ((.severity // "") | tostring) == "error"
             and ((["correctness","security","data-loss"] | index($c)) != null))] | length' "$f")"
  [ "$carve" = 0 ] || ac_die "review-residual: the residual holds $carve critical correctness/security/data-loss finding(s) - acceptance is refused (non-overridable carve-out); grant ac-ship.sh review-agent --final-round or the captain re-routes"
  nfix="$(jq '[.[] | select(.action == "fix")] | length' "$f")"
  [ "$nfix" -gt 0 ] || ac_die "review-residual: no fix residual to accept - complete the review step normally"
  tmp="$(mktemp "$rd/findings/.review.residual.XXXXXX")" || ac_die "review-residual: mktemp failed"
  if jq --arg g "$grounds" '[.[]
      | if .action == "fix"
        then .action = "no-op" | .residual_accepted = true | .residual_grounds = $g
        else . end]' "$f" >"$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    ac_die "review-residual: rewrite failed - findings left untouched"
  fi
  printf '%s review residual accepted (%s finding(s)) at rounds=%s grounds=%s\n' \
    "$(ac_iso)" "$nfix" "$rounds" "$grounds" >>"$rd/logs/run.log"
  printf 'review-residual: %s finding(s) accepted as advisory - post this receipt to the family room:\n' "$nfix"
  printf 'SELF-APPROVED: review-residual r%s - decision: accepted - grounds: %s\n' "$rounds" "$grounds"
}

cmd_fix_report() {
  # Render a held step's findings as the markdown FIX REPORT - the handoff
  # contract a fixer crewmate is briefed on.
  # Machine truth stays in findings/<step>.json; this is a VIEW, never a
  # second source. To-fix = action fix, plus ask-user findings carrying
  # a captain `decision` field; undecided ask-user stays parked (listed,
  # untouchable); no-op findings are omitted.
  require_run
  local step="${1:-}" rd f intent branch sha rounds cap nfix
  case " $STEPS " in *" $step "*) ;; *) ac_die "unknown step: $step" ;; esac
  rd="$(run_dir)"
  f="$rd/findings/$step.json"
  [ -f "$f" ] || ac_die "no findings recorded for step $step (pipe them to: ac-ship.sh findings $step)"
  intent="$(sed -n 's/^intent=//p' "$rd/run.meta" | head -n 1)"
  branch="$(sed -n 's/^branch=//p' "$rd/run.meta" | head -n 1)"
  sha="$(git -C "$repo" rev-parse --short HEAD)"
  rounds="$(awk -F'\t' -v s="$step" '$1 == s { print $3 + 0 }' "$rd/steps.tsv")"
  cap="$(cmd_config "auto_fix.$step" 2>/dev/null || true)"
  nfix="$(jq '[.[] | select(.action == "fix" or (.action == "ask-user" and ((.decision // "") != "")))] | length' "$f")"

  printf '# Fix report: %s - run %s, step %s (fix round %s/%s)\n\n' \
    "$(basename "$repo")" "$(basename "$rd")" "$step" "$((rounds + 1))" "${cap:--}"
  printf 'Intent: %s\nBranch: %s @ %s\n\n' "$intent" "$branch" "$sha"

  printf '## Findings to fix (%s)\n' "$nfix"
  jq -r '
    def loc: if (.file // "") != "" then "\(.file)\(if (.line // "") != "" and .line != null then ":\(.line)" else "" end) - " else "" end;
    def tag: if (.id // "") != "" then " (\(.id))" else "" end;
    def auth: if (.authority // "") != "" then " - authority: \(.authority)" else "" end;
    .[] | select(.action == "fix" or (.action == "ask-user" and ((.decision // "") != "")))
        | "- [\(.severity // "info")] \(loc)\(.description)\(tag)\(if (.decision // "") != "" then " - DECIDED: \(.decision)" else "" end)\(auth)"
  ' "$f"

  if jq -e '[.[] | select(.action == "ask-user" and ((.decision // "") == ""))] | length > 0' "$f" >/dev/null; then
    printf '\n## Parked - awaiting captain (do NOT act on these)\n'
    jq -r '
      def loc: if (.file // "") != "" then "\(.file)\(if (.line // "") != "" and .line != null then ":\(.line)" else "" end) - " else "" end;
      .[] | select(.action == "ask-user" and ((.decision // "") == ""))
          | "- [\(.severity // "info")] \(loc)\(.description)\(if .authority_downgraded then " - NO AUTHORITY NAMED (downgraded from fix)" else "" end)"
    ' "$f"
  fi

  printf '\n## Contract\n'
  printf -- '- Fix ONLY the findings above; no scope creep, no refactors.\n'
  printf -- '- Commit to the crew branch. Do NOT push - the pipeline owns push.\n'
  printf -- '- When done print: done: fixed %s findings\n' "$nfix"
  printf -- '- The run stays HELD at %s and re-runs on your diff; earlier completed steps do not re-run.\n' "$step"
}

cmd_status() {
  require_run
  local rd
  rd="$(run_dir)"
  printf 'run: %s\n' "$(basename "$rd")"
  sed 's/^/  /' "$rd/run.meta"
  printf 'steps:\n'
  awk -F'\t' '{ printf "  %-10s %-18s %s\n", $1, $2, ($3 + 0 > 0 ? "fix-rounds=" $3 : "") }' "$rd/steps.tsv"
  local f
  for f in "$rd/findings/"*.json; do
    [ -e "$f" ] || continue
    case "$f" in
      *.meta.json)
        printf 'meta %s: %s\n' "$(basename "$f" .meta.json)" "$(jq -r 'keys | join(" ")' "$f")" ;;
      *)
        printf 'findings %s: %s\n' "$(basename "$f" .json)" "$(ac_findings_summary "$f")" ;;
    esac
  done
}

assert_review_current() {
  # assert_review_current <run-dir> <what> - the reviewed ref must still BE
  # HEAD. `step review completed` proves review was current at that INSTANT and
  # nothing re-checked it afterwards, so a fix commit landing after it left the
  # run free to push and finish code no reviewer ever saw. The rule that closes
  # this ("a ref-changing fix invalidates review") lived only in AGENTS.md and
  # the crew-ship skill - an instruction to the crewmate, not a machine check.
  # The crewmate is then carrying a rule the pipeline could carry for it.
  #
  # Binds ONLY a completed review: `skipped` is a run that legitimately has
  # none, and any other state is the finish gate's own business (it refuses a
  # non-completed step by itself).
  #
  # ENFORCE WHEN PRESENT: the manual reviewer path (`meta review` with a
  # reviewer field) now stamps reviewed_ref itself at the completed transition
  # (F8), same as review-agent - but a run recorded before that fix landed has
  # none, and failing closed on its absence would invalidate those legacy
  # runs. A receipt with no ref warns instead - loudly, so the hole is visible
  # where it still exists.
  local rd="$1" what="$2" state reviewed current
  state="$(awk -F'\t' '$1 == "review" { print $2 }' "$rd/steps.tsv" 2>/dev/null)" || return 0
  [ "$state" = completed ] || return 0
  # Absent review.agent is the ORDINARY manual-receipt case, not an error: sed
  # exits non-zero on a missing file and errexit would kill the run over it.
  reviewed="$(sed -n 's/^reviewed_ref=//p' "$rd/review.agent" 2>/dev/null | tail -n 1)" || reviewed=""
  if [ -z "$reviewed" ] && [ -f "$rd/findings/review.meta.json" ]; then
    reviewed="$(jq -r '.reviewed_ref // ""' "$rd/findings/review.meta.json" 2>/dev/null)" || reviewed=""
  fi
  if [ -z "$reviewed" ]; then
    ac_warn "$what: the review receipt records no reviewed_ref - review currency is UNPROVEN for this run"
    return 0
  fi
  current="$(git -C "$repo" rev-parse HEAD)" \
    || ac_die "$what: cannot read HEAD (failing closed)"
  [ "$reviewed" = "$current" ] \
    || ac_die "$what refused (fail-closed): HEAD moved since review - reviewed ${reviewed:0:12}, current ${current:0:12}. The diff was never reviewed at this commit; run a fresh independent review (ac-ship.sh review-agent)."
}

finish_gate() {
  # finish_gate <run-dir> <outcome> - FAIL CLOSED for checks-passed|passed
  # (spec in the header's FINISH block). Gates ONLY on the existing step +
  # finding state; it invents no transition machinery. failed/cancelled never
  # reach here - a run may always record a failure.
  local rd="$1" outcome="$2" outstanding resid f step bad dref
  # 1. Every step that was not user-skipped must be completed.
  outstanding="$(awk -F'\t' '$2 != "completed" && $2 != "skipped" { printf "%s(%s) ", $1, $2 }' "$rd/steps.tsv")"
  [ -z "$outstanding" ] \
    || ac_die "finish $outcome refused (fail-closed): pipeline steps not completed: ${outstanding% } - complete or --skip them, or finish failed/cancelled"
  # 2. No unresolved finding: a `fix` finding, or an `ask-user` without a
  #    captain `decision`, blocks (the fix-report resolution model). meta files
  #    are envelope data, not findings - skipped.
  resid=""
  for f in "$rd/findings/"*.json; do
    [ -e "$f" ] || continue
    case "$f" in *.meta.json) continue ;; esac
    step="$(basename "$f" .json)"
    # FAIL CLOSED on a read failure too (F32): an unreadable/corrupt findings
    # file must never be read as "zero unresolved findings" - the one
    # predicate in this otherwise fail-closed gate that used to fail open.
    bad="$(jq -r '[.[] | select(.action == "fix" or (.action == "ask-user" and ((.decision // "") | tostring) == ""))]
                   | map((.id // "?") + "[" + (.action // "?") + "]") | join(", ")' "$f" 2>/dev/null)" \
      || bad="UNREADABLE ($step findings file is corrupt or not valid JSON)"
    [ -z "$bad" ] || resid="${resid}${resid:+; }$step: $bad"
  done
  [ -z "$resid" ] \
    || ac_die "finish $outcome refused (fail-closed): unresolved findings - $resid (fix the fix-findings, or record a captain decision on the ask-user ones)"
  # 3. The reviewed ref must still be HEAD: step 1 proves review COMPLETED,
  #    not that it covers the commit being recorded as validated. A fix
  #    landing after review would otherwise finish as checks-passed with
  #    unreviewed code in the PR (see assert_review_current).
  assert_review_current "$rd" "finish $outcome"
  # 4. passed = MERGED: additionally require merged evidence (HEAD reachable
  #    from the run's delivery target when pinned, else the default ref).
  #    checks-passed is the unmerged stop point.
  if [ "$outcome" = passed ]; then
    dref="$(sed -n 's/^target=//p' "$rd/run.meta" 2>/dev/null | head -n 1)"
    [ -n "$dref" ] || dref="$(ac_default_ref "$repo")"
    git -C "$repo" merge-base --is-ancestor HEAD "$dref" 2>/dev/null \
      || ac_die "finish passed refused (fail-closed): HEAD is not merged into $dref - use checks-passed for a raised-but-unmerged PR; passed records a MERGED run"
  fi
}

cmd_finish() {
  require_run
  local outcome="${1:-}" rd
  case "$outcome" in
    checks-passed|passed|failed|cancelled) ;;
    *) ac_die "usage: ac-ship.sh finish <checks-passed|passed|failed|cancelled>" ;;
  esac
  rd="$(run_dir)"
  # Fail-closed gate for the validated outcomes (header: FINISH). Runs BEFORE
  # anything is retired or recorded, so a refusal leaves the run fully intact.
  # failed/cancelled skip it - a run may always record a failure.
  case "$outcome" in
    checks-passed|passed) finish_gate "$rd" "$outcome" ;;
  esac
  # Retire the pane reviewer with the run (nm model: finished runs never
  # leave historical reviewer panes behind. New verifier rounds reap earlier,
  # but old review.pane artifacts remain cleanup inputs for compatibility.
  if [ -f "$rd/review.pane" ]; then
    local helper="${AC_PANE_AGENT:-$(dirname "$0")/ac-pane-agent.sh}"
    [ -x "$helper" ] && "$helper" close --pane "$(cat "$rd/review.pane")" >/dev/null 2>&1 || true
    rm -f "$rd/review.pane"
  fi
  if [ -f "$rd/watch.pane" ] && command -v herdr >/dev/null 2>&1; then
    herdr --session "${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}" \
      pane close "$(cat "$rd/watch.pane")" >/dev/null 2>&1 || true
    rm -f "$rd/watch.pane"
  fi
  # Retire the TDD attestation with the run - a new run must attest afresh.
  rm -f "$vdir/attest-test.json" "$vdir/attest-test.log"
  printf 'outcome=%s\n' "$outcome" >>"$rd/run.meta"
  printf 'finished_at=%s\n' "$(ac_iso)" >>"$rd/run.meta"
  printf 'run %s: %s\n' "$(basename "$rd")" "$outcome"
  # The crew-ship completion signal: an anchored checks-passed: marker
  # (AC_CAPTAIN_RE) that wakes the chief and stamps the pane as awaiting the
  # captain's merge (AC_DECISION_RE). Only checks-passed - passed means already
  # merged, failed/cancelled route through the crewmate's own status line.
  # F33: word it on what the RUN actually did - a `pr` step that was skipped
  # (an explicit --skip, or skip-remaining's empty-diff flow) raised no PR, so
  # the wording must not claim one exists.
  if [ "$outcome" = checks-passed ]; then
    local pr_status
    pr_status="$(awk -F'\t' '$1 == "pr" { print $2 }' "$rd/steps.tsv")"
    if [ "$pr_status" = completed ]; then
      printf 'checks-passed: %s PR raised, awaiting the captain'\''s merge\n' "$(basename "$rd")"
    else
      printf 'checks-passed: %s validated, no PR raised (pr step %s) - awaiting the captain\n' \
        "$(basename "$rd")" "$pr_status"
    fi
  fi
  return 0
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  step) shift; cmd_step "$@" ;;
  findings) shift; cmd_findings "$@" ;;
  meta) shift; cmd_meta "$@" ;;
  cmd) shift; cmd_cmd "$@" ;;
  attest-test) shift; cmd_attest_test "$@" ;;
  attest-check) shift; cmd_attest_check "$@" ;;
  push) shift; cmd_push "$@" ;;
  base) shift; cmd_base "$@" ;;
  evidence-dir) shift; cmd_evidence_dir "$@" ;;
  skip-remaining) shift; cmd_skip_remaining "$@" ;;
  config) shift; cmd_config "$@" ;;
  fix-report) shift; cmd_fix_report "$@" ;;
  review-agent) shift; cmd_review_agent "$@" ;;
  review-residual) shift; cmd_review_residual "$@" ;;
  status) shift; cmd_status "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  *) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
