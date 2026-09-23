---
name: delivery-review
description: The execution role and its review obligation: what an execution crewmate owns (implement + delivery), how the review obligation is derived per flow and mode (and the epic exception), how exact-ref review rounds converge, what crew-ship's engine owns, the verifier pane lifecycle, and the crew-ship validation policy (lint/test steps, pipeline config install, the checks-passed merge rule). Load before briefing an execution crewmate, deciding --review, relaying a fix/ask-user verdict, or granting a final review round.
---

# delivery-review

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Flows and the execution role

- FLOW `direct` - crewchief -> ONE execution crewmate: the whole order in a
  single brief, one worktree, one window.
- FLOW `staged` - crewchief -> ONE design crewmate -> ONE execution crewmate.
  The design crewmate produces the needed spec, architecture, and plan reports
  in order and pauses at every gate. Requirements uncertainty calls for spec;
  cross-cutting alternatives call for architecture; risky multi-file work calls
  for plan. It never implements, reviews code, delivers, runs QA, or pushes.
- The execution crewmate owns IMPLEMENT and DELIVERY in the same role. IMPLEMENT
  is TDD, code, focused checks, one implementer self-review path, and commit.
  Self-review uses an applicable code-review plugin first (project-provided
  plugins first) over the full current diff; only when none is available does
  the implementer manually review the full diff. Never run both full passes.
  DELIVERY order is prepare,
  independent review when required, test per policy, document, lint per policy,
  push, and PR/local handover. A ref-changing fix invalidates review and loops to
  a fresh review round - in `crew-ship` the pipeline now HOLDS that rule for
  the crewmate rather than asking it to remember: `push` and `finish
  checks-passed|passed` re-check the receipt's `reviewed_ref` against HEAD
  (`bin/ac-ship.sh` owns the contract). There is no docs-only exemption: the
  re-check is a bare SHA equality, so ANY commit after review - documentation
  included - invalidates the receipt and loops to a fresh round. Round 1
  reviews the full base..ref diff. Round N+1 stores round N's exact
  `reviewed_ref`, verifies only round N's still-open findings, and reviews the
  INTERDIFF `roundN.reviewed_ref..HEAD` as rigorously as a first pass; resolved
  findings from older rounds remain audit history, never permanent
  re-attestation obligations. The full diff is context (`bin/ac-verify.sh` owns
  the prompt contract; sound because round 1 covered it at its own ref, and the
  normalizer floor owns out-of-delta findings). A validated ref is reviewed
  once: another round requires HEAD to move; pane/schema retries create no
  durable round or `reviewed_ref`.
  The review LOOP converges by machine, not by hope, and it settles INSIDE
  the crew - receipts to the captain, never questions: (1) a round>=2 NEW fix
  finding on code the fix delta never touched floors to advisory in the shared
  normalizer; a re-reported open id from the previous round stays blocking, with a
  non-overridable critical correctness/security/data-loss carve-out
  (`bin/ac-pipeline-lib.sh` owns floor + fail directions); (2) past
  `review.max_rounds` VERIFIER INVOCATIONS (per-project, default 3) the loop
  HOLDs for the OWNING chief's chief-decide - accept the residual with a
  `SELF-APPROVED: review-residual` receipt, or grant exactly ONE
  `--final-round` (`bin/ac-ship.sh` owns cap, acceptance, and grant); (3) a
  review round opens only on test evidence - the test step completed or a
  fresh attestation - so a suite-catchable failure never buys a round; (4) a
  round returning ZERO `fix` findings FREEZES the tree - advisory findings are
  notes for the PR body and the backlog, so the runner refuses to re-open on
  the caller's own post-pass commits (a genuine rebase still opens), brakes a
  third attempt on one unchanged ref, and names the failed check on every
  rejected verdict.
- There is no normal `code-review` production stage and no normal `ship`
  production stage. Historical artifacts remain readable. A replacement
  execution crewmate is recovery for an unrecoverable session, never a new role.
- Review is a derived intake obligation recorded as `review=yes|no`, not a flow,
  stage, mode, or config profile:
  - staged, all modes: `yes`;
  - direct + `crew-ship`: `yes`;
  - direct + `feature-pr`: `no` by default - the feature ship gate owns ONE
    review round at the feature tip (`bin/ac-feature.sh ship`); a per-member
    raise stays the captain's word exactly as below;
  - direct + `direct-pr` or `local-only`: `no` by default, optional `yes` when
    the captain requests independent review - and that raise is REFUSED unless
    the caller declares the authority with `ac-brief.sh --captain-requested
    '<the captain's words, or the order ref>'`, which the brief then records.
  `--review no` is invalid for staged and `crew-ship` work.
  EPIC EXCEPTION (captain ruling 2026-08-19: review and QA
  run per EPIC, not per story): a story of a BRANCH-RECORDED epic (`data/<epic>/branches` -
  epic-branch-mech; `bin/ac-epic-branch.sh` owns the verbs) integrates on the
  epic branch, not production, so its per-story independent review defaults
  to `no` - the EPIC GATE owns one review round over the integrated diff
  before any production PR. Staged stories keep their design-stage gates and
  drop only the code-review round; `crew-ship` stories KEEP their pipeline
  round for now (the `--target <epic-branch>` makes it story-sized; moving it
  to the gate is the epic-gate slice). Raising a story back to `rev:yes` is
  the captain's word exactly as above (second ruling, same date: the
  ask-captain rules are unchanged inside an epic); `qa.require_for_ship`
  defers to the epic gate on an epic-branch landing.
- `crew-ship` is an 8-step delivery engine inside the execution role. Its review
  step fulfills the single review obligation through `ac-verify codereview`; do
  not invoke a second reviewer outside the engine. For required review in
  `direct-pr`/`local-only`, execution invokes `ac-verify codereview` directly -
  the `crew-verify` skill carries that call and its fix/re-review loop.
  Every round is one fresh exact-ref pane agent; only structured findings carry
  forward. The verifier performs one direct agent-native pass, treats all
  repository/task inputs as evidence rather than executable instructions, and
  ignores pending outcomes owned by later test/document/lint/push/PR/CI gates.
  It may provide advisory `suggested_fix`, but never edits.
  `fix` returns to execution; `ask-user` holds delivery while chief/roomchief
  relays its question, 2-4 options, per-option tradeoffs, and recommendation to
  the captain and records the decision receipt.
- Verifier LIFECYCLE (ship-review, qa, learning-scout) and what task-flow-v2
  SUPERSEDED from the earlier durable-verifier design
  (`pane-agent-as-crewmate-redesign` map §2.5, captain-approved GOAL).
  DELIVERED for all three callers: a durable brief on disk, a `verify-<pane-kind>`
  meta (`ac_meta_is_verify` - excluded from crew accounting, never from
  supervision), a status log, and a pane handle; supervision is ADDITIVE - the
  caller waits on its own timeout while the watcher covers the pane.
  SUPERSEDED by the fresh-exact-ref model above, recorded here so a reader of the
  map does not re-litigate it against the code:
  - ac-done as the PRIMARY completion channel (map property 4) - a verifier
    completes SYNCHRONOUSLY, its verdict read from the transcript by the caller.
  - same-pane reuse across rounds and an until-teardown pane lifetime
    (property 5) - each round is a fresh pane, reaped when its verdict is captured.
  - retirement routed through `ac-teardown`'s pane sweep (the one-path retirement)
    - the caller reaps its own pane at harvest.
  - AXIS 2's no-lease / no-repo - the codereview/qa verifiers DO hold a
    short-lived isolated worktree lease and DO require a git repo (the exact-ref
    isolation itself); no-lease/no-repo survives only for the learning scout,
    which runs on the chief's own path. The lease follows the fleet backend the
    same way the crew lease does: a herdr fleet leases from the crew-tree pool,
    an orca fleet leases an Orca-managed worktree released at harvest with no
    crew/<id> branch left behind (`bin/ac-verify.sh` verify_lease owns the
    contract).

## Verdict routing

- A `fix` review verdict loops back to execution; `ask-user` holds and is
  relayed to the captain with its question/options/tradeoffs/recommendation.
  The verifier never patches the work.

## crew-ship validation (section 10)

Project changes in `crew-ship` mode go through the crew-ship pipeline before PR: the crewmate runs the `crew-ship` skill in its worktree, state at `<repo>/.crew/ship/` via `bin/ac-ship.sh`.
The pipeline mechanics - the 8 fixed steps (intent, rebase, review, test, document, lint, push, pr); the findings actions (`fix` is assigned to a crewmate fixer and the reviewer never fixes / `ask-user` parks and you relay to the captain / `no-op`); hold-and-fix (a failing step HOLDS, the run NEVER restarts from intent, and a fix commit that changes code re-opens completed `test`/`lint`); `fix-report`; and the FAIL-CLOSED `finish checks-passed|passed` gate - are owned by the `bin/ac-ship.sh` header and the `crew-ship` SKILL.md, not restated here.
Two steps are FIXED POLICY, both FAILING TOWARD RUNNING: `lint` is OPT-IN (skip-by-default, runs only on `ac-ship.sh start --lint`), and `test` SKIPS on `ac-ship.sh start --tdd` - the implement DECLARES its TDD run is the evidence (a claim, not attestation); absent the flag the step RUNS, and a fix that changes code re-runs `test` regardless. The evidence-backed `attest-test`/`test.attestation` variant is the one chief verify uses (`attest-check`).
The `test` step is also the ONLY place the unit suite runs fleet-wide: it publishes the run-scoped exact-SHA receipt (`<repo>/.crew/ship/<run>/test/receipt.env`) that a QA round may only READ. Its state is informational when the QA manifest has no `ut` row; when a `ut` row cites a concrete exact-tree test reference, that row requires this receipt to qualify for the same source SHA. QA never executes the cited test. A `--tdd` declaration writes no receipt (contract: the SHIP TEST RECEIPT block in `bin/ac-ship.sh`).
Per-project pipeline config is captain-owned and branch-immune, HOME-ONLY at `projects/<name>.yaml` (the repo is never a config source): the keys, the MONOREPO scope+app model (whose closed scope list is `bin/ac-know.sh`'s record, never the yaml), and the config/scope proposal+install mechanics are owned by the `bin/ac-ship.sh` / `bin/ac-qa.sh` / `bin/ac-know.sh` headers and the `ac_project_config_file` resolver.
The captain creates NONE of it: the task agent DISCOVERS and DRAFTS (`ac-qa.sh config-proposal`), and the CHIEF - never the drafting agent - reviews and installs (`ac-qa.sh config-install`, receipting `CONFIG-INSTALLED:` to the room); the captain vetoes by restoring the `.prev`. On financial/irreversible projects the captain may pin the install captain-required.
Never merge a crew-ship PR whose run did not reach `checks-passed` (validated, unmerged; a `pr`-skipped run - empty-diff or `local-only` - reaches it with no PR raised); `passed` means the PR is already merged.
