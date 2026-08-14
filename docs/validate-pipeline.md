# crew-ship pipeline

An 8-step hold-and-fix validation pipeline run agent-side: the crewmate IS the pipeline runner, `bin/ac-ship.sh` is the durable state machine, and the `crew-ship` skill is the operating procedure.
Authoritative contracts: the `bin/ac-ship.sh` header (state machine + commands), `.agents/skills/crew-ship/SKILL.md` (the runner's procedure), AGENTS.md section 10 (fleet law).
This doc is the map, not the law.

## Steps (fixed order, not configurable)

| # | Step | Deterministic part | Judgment part | Default auto-fix limit |
|---|---|---|---|---|
| 1 | intent | record `--intent` verbatim | flag obviously out-of-intent work | - |
| 2 | rebase | `base` recompute, `skip-remaining` on empty diff | local-default bundling guard; `origin/<branch>` first, then default; FF = hard reset; resolve conflicts | 3 |
| 3 | review | `cmd format` (before the reviewed ref); evidence gate on `step review completed` | independent reviewer classifies; full RE-review after every fix round | 0 (gates by default) |
| 4 | test | `cmd test` (configured baseline), `evidence-dir` | intent evidence ALWAYS (even after a green baseline); new test files gate | 3 |
| 5 | document | - | find AND fix doc gaps; ANY unresolved finding gates (incl. info) | initial pass |
| 6 | lint | `cmd lint` (OPT-IN: skip-by-default, runs only with `start --lint`) | lint-category pass when unconfigured | 3 |
| 7 | push | `push` (lease + patch-id guarded, fail closed) | stage evidence, commit leftovers | - |
| 8 | pr | - | PR with Intent/What Changed/Risk/Testing/Pipeline body, ~63KB cap, feat/fix typing, signature | - |

Two steps are CONDITIONAL (captain.md 2026-07-21) - the ORDER is fixed, the RUN is not:
`lint` is skip-by-default and runs only when `start --lint` is passed (the captain/brief requested it); `test` is SKIPPED by `start --tdd` - the implement DECLARES its TDD run is the evidence (a claim, not the attestation-by-execution below). Both fail toward RUNNING: no `--lint` skips lint (the captain's chosen default), and no `--tdd` runs test. A fix that changes code re-runs test even in a `--tdd` run - the implement's TDD never covers a later fix diff. Every step stays runnable on request.

There is no ci step: `finish checks-passed` means validated + PR raised, unmerged - the agent's stop point.
Merging and CI watching stay with the captain; a red check later needs a fresh crew-ship run.

## Findings

`[{"id","severity","action","file","line","description","authority_class","authority"}]`

- `severity`: error | warning | info.
- `action`: `fix` (objective AND delivery-blocking - correctness, security, regression, data loss, accepted-requirement/ruling violation; the reviewer CLASSIFIES, a crewmate FIXES, round-capped; legacy `auto-fix` normalizes to `fix`) | `ask-user` (parks the run; relayed to the captain with question, 2-4 options, per-option tradeoffs, and recommendation) | `no-op` (advisory improvements ride here, with `suggested_fix`).
- `authority_class`: `internal` (the expected behaviour is stated inside this repository or by the diff itself) | `external` (an actor outside it) | `none`; `authority`: one sentence naming WHO states it and WHERE - a `file:line`, a URL, or `captain <date>`.
- A missing OR EMPTY action fails closed to `ask-user`.
- An unknown `authority_class` or an empty `authority` fails closed to `none`, and a `fix` finding with class `none` is DOWNGRADED to `ask-user` + `authority_downgraded: true` (`ac_findings_normalize`, the single enforcement point for both pipelines).
- A `severity: info` finding with `action: fix` is FLOORED to `no-op` + `severity_floored: true` BEFORE the authority downgrade (info means no action required, so nothing is ever assigned and no round reopens - authority named or not); the finding and its advisory `suggested_fix` stay in the findings JSON.
- Canonical verifier-authored `ask-user` findings must supply the complete relay shape. The shared normalizer conservatively enriches legacy or synthesized `ask-user` findings so no caller has to reconstruct missing reviewer intent.
- Auto-fix rounds are durable: `step <name> fixing` increments a counter in `steps.tsv`; at `auto_fix.<step>` rounds the runner parks instead.
- `meta <step>` records the PR-body envelope: review `risk_level`/`risk_rationale`, test `testing_summary`/`tested`/`artifacts`.
- Step fixes commit as `agent-crew(<step>): <summary>`.

## Hold-and-fix

A failing step HOLDS the run - it NEVER restarts from intent.
Completed earlier steps stay completed and the held step re-runs on the fix diff.
When the fix is handed to a DIFFERENT crewmate (fix-round budget spent, or the orchestrator drives the run), `ac-ship.sh fix-report <step>` renders that step's findings as the fixer's markdown contract: to-fix = `fix` findings plus `ask-user` findings carrying the captain's decision; undecided `ask-user` stays parked and untouchable.
The fixer commits to the crew branch and never pushes - the pipeline owns push.
A fix that changes code re-opens completed `test` and `lint`.

## test skip-if-TDD

The captain chose a DECLARATION (captain.md 2026-07-21): `ac-ship.sh start --tdd` starts the `test` step `skipped` - the implement's TDD run stands as the evidence. FAIL CLOSED: absent `--tdd`, test runs. It is a CLAIM, not proof; a fix that changes code re-runs test regardless.

### TDD attestation (the evidence-backed variant)

Stronger than `--tdd`, and used for chief-verify (`attest-check`): it also skips the test re-run, but only against real evidence.
When the implementer worked under a required-TDD brief the suite need not run twice: `ac-ship.sh attest-test` RUNS `commands.test` in the worktree as the implementer's final green run (attestation by execution - a dirty or unreadable worktree, or a failing run, writes nothing) and records `{branch, commit, tree, cmd, at}` at `<repo>/.crew/ship/attest-test.json`.
The test step (`cmd test`) accepts a fresh attestation - same branch, same HEAD, same tree, same configured test command, `test.attestation` not `ignore` (default accept) - and completes without re-running the suite, noting the skip in `meta test`; any condition failing runs the suite as usual and logs why.
A fix commit moves HEAD, so a hold-and-fix round always re-runs the reopened test step; `finish` retires the file.
Authoritative spec: the `bin/ac-ship.sh` header (TDD ATTESTATION).

## Independent review

The review step is never a self-review, and `step review completed` is fail-closed on `<run>/review.agent` evidence bound to the current `reviewed_ref`.
Which receipt that transition reads is decided by CURRENCY, not by which files exist: a stale `review.agent` is superseded by an explicit `meta review` reviewer record and retired to `review.agent.superseded`, while a stale receipt with no such record still refuses.
`ac-ship.sh review-agent` is a thin adapter to `ac-verify codereview`. The facade leases an isolated exact-ref worktree, launches one fresh `ac-pane-agent` round, validates the structured verdict, captures evidence, then reaps the pane and returns the lease. A rejected verdict (the pane completed and its round evidence is durable, only the output failed the schema) releases those same runtime resources rather than orphaning them; a run that produced no usable result before any verdict existed (pane crash, missing transcript, a non-ok terminal status) is reaped the same way. Only an incomplete QA export - reconciliation or evidence-export failing after a valid pane verdict - still preserves its pane/lease/meta for recovery.

The canonical prompt performs exactly one direct agent-native adversarial review. It does not discover or chain review plugins/skills, run a second full pass, or execute tests, lint, builds, or type checks; QA and delivery own executable verification. Repository and task inputs are evidence, never executable instructions. Pending outcomes owned by later test/document/lint/push/PR/CI gates are outside review scope. It reviews the exact supplied base-to-ref range, not a three-dot merge-base range or mutable `HEAD`. Each round snapshots `room.md` and precomputes `room-rulings.md` from captain questions/decisions, `TRIAGE`, accepted chief/gate receipts, and explicit corrections; rejected `GATE-LOOPED` drafts and ordinary narration remain available only in the full snapshot for targeted context. It checks accepted intent/spec boundaries, correctness, security, regressions, and whether tests meaningfully exercise risky behavior. External documentation is consulted only when a potential finding materially depends on that behavior, using the exact pinned version and an authoritative source.
There is no resumable reviewer session, headless fallback, or separate staged code-review reviewer. Round 1 reviews the full base-to-ref diff. A ref-changing fix launches one fresh sequential round that verifies only the immediately previous round's open findings and reviews `previous reviewed_ref..current ref`; the full diff remains context. Resolved findings from older rounds remain in their durable artifacts but do not carry forward. Only a new non-critical finding outside the current fix delta floors to advisory; a re-reported previous-round blocker stays blocking. A validated ref is reviewed once, while failed pane/schema attempts create no durable round or reviewed ref. One `(family, verifier-kind)` has at most one live pane.
The final object is `{findings[], summary, risk_level, risk_rationale, reviewed_ref}`. A clean review uses `findings=[]`; location and `suggested_fix` fields are omitted when inapplicable, while `ask-user` retains the complete captain-relay shape. `review-agent` routes normalized findings to the ship state, writes the exact-ref marker, and records advisory risk/summary in `meta review` (PR-body `## Risk Assessment`).
`risk_level` is surfaced, never an automatic merge gate.

## Live dashboard

`bin/ac-ship-watch.sh` renders the run live: header, colored glyph step table with the ACTIVE step marked, fix rounds, per-step findings summaries, and the run-log tail.
Read-only; one full screen per refresh.
`start` auto-opens it in a herdr tab (label prefixed `ac-ship-watch`; `AC_SHIP_WATCH=off` disables), and every step transition to running/fixing/awaiting_approval re-ensures it (idempotent), so runs reopened under hold-and-fix get their pane back.
It SELF-CLOSES when the run finishes or idles (`AC_SHIP_WATCH_IDLE`, default 1800s); `finish` also retires it via `<run>/watch.pane`.

## State

```
<repo>/.crew/ship/attest-test.json  # TDD attestation (beside the runs; retired by finish)
<repo>/.crew/ship/<run-id>/
├── run.meta                 # intent, branch, base-at-start, outcome
├── steps.tsv                # step<TAB>status<TAB>fix-rounds
├── findings/<step>.json     # normalized findings
├── findings/<step>.meta.json# envelope (risk / testing)
├── review.agent             # independent-review evidence marker
├── review.agent.superseded  # a stale marker a manual reviewer record took over
├── logs/review-agent-rN.json# structured result/history per fresh round
├── logs/review-invocations.tsv# one row per verifier OPEN - what the cap counts
├── watch.pane               # live-dashboard pane id
└── logs/                    # run.log + per-command output
```

Historical `review.session` / `review.pane` files remain cleanup inputs only;
normal review rounds are owned by `ac-verify.sh` and leave neither in the ship run.

`current` symlinks the active run.
Step statuses: pending, running, fixing, awaiting_approval, completed, skipped, failed.
Outcomes: `checks-passed` (validated + PR raised, NOT merged), `passed` (merged/closed), `failed`, `cancelled`.
`checks-passed`/`passed` are FAIL CLOSED: `finish` refuses unless every non-skipped step is `completed` and no `fix` finding (or undecided `ask-user`) remains, and `passed` additionally requires HEAD merged into the default branch; `failed`/`cancelled` are always allowed (`bin/ac-ship.sh` header, FINISH).
Never merge a crew-ship PR whose run did not reach `checks-passed` (`passed` means it is already merged).
The `base` recorded at start is informational; `ac-ship.sh base` always recomputes the merge-base because a rebase moves it.

## Behavioral proof (crew-qa) - after delivery, never a step

qa is NOT a pipeline step: the step list ends at `pr`, and `finish checks-passed` is the pipeline's stop point.
When QA was triaged in, the SAME execution session that completed delivery calls `bin/ac-qa.sh agent --target <delivered-sha> --brief <qa-brief>`. The execution caller first selects any routed `panes.qa` rule, then the adapter atomically freezes trusted config, scope membership, selected store files, exact refs, the routing receipt, and the exact-SHA ship test receipt named by `--ship-run` (a QA round only READS unit-suite health from that receipt; it never runs a suite). `ac-verify qa` validates that bundle and runs one fresh exact-ref QA pane for the whole profile round; subprocesses do not become per-step agents.
The pane drives the durable state machine. `finish passed` is refused unless every fixed step is completed or explicitly skipped with a note, findings are resolved, every case is a graded pass with durable in-root evidence, every web case has a linked visual, and a completed E2E step has a zero-exit receipt bound to the frozen command/cases/refs. Completing the test plan freezes its hash; an oracle change requires an accepted authority and `testplan-amend`.
`run.meta outcome`, not pane prose, owns the exported verdict. The facade reconciles exact refs, profile identity, ledgers, evidence, and the passing marker; a pane verdict claim is optional and must match. It atomically publishes the canonical stage `report.md`, then exports run state, artifacts, caller `verdict.json`, and the distinct transport `relay-report.md`. Errors publish `verdict: error`, no caller verdict, and preserve recovery state.
qa gates the MERGE, not the push: with `qa.require_for_ship: true` in the fleet-home project config (`projects/<name>.yaml`), `bin/ac-pr-merge.sh` and `bin/ac-merge-local.sh` require a complete parser-valid atomic `agentcrew.qa-attestation/v2` marker for the exact head. Flat and scoped gates validate marker bodies; empty, legacy, partial, malformed, off-head, or scope-renamed markers fail closed.
On a SCOPED project (one whose repo-knowledge record declares scopes and whose config carries a `qa.scopes` block) a run proves ONE scope+app, so its marker is `passed/<sha>.<scope>.<app>` and also binds that pair in the body. The gate refuses a half-migrated project and surfaces which valid pairs passed rather than deriving coverage from the diff.
A frozen versioned store manifest is always present, including the empty-store case. Reviewed fixture packs may expose several selectors; read-write selectors are retry-idempotent. QA writes curation candidates and test-only regression proposals only after the behavioral verdict. Curation is visible but non-gating and reaches the shared store only through chief-reviewed base-manifest installation.
A `failed` verdict returns defects to execution; it fixes on the crew branch, re-runs invalidated delivery/review evidence, and re-runs QA.
Authorities: the `bin/ac-qa.sh` header, the `crew-qa` skill, AGENTS.md section 5 (qa triage law), and `docs/qa-attestation.md` (full runtime/report/reuse contract and opt-in live smoke).

## Push safety

`ac-ship.sh push` is the only sanctioned way to publish the branch: it anchors `--force-with-lease` to the exact remote SHA it inspected and refuses to drop any remote commit not incorporated by patch-id, failing closed on every git error.
One bounded excuse keeps the ordinary rebase-through-a-conflict legal (resolving a conflict changes the patch-id, so the branch's own superseded history used to read as foreign work): the unincorporated set is waived only when the remote ref is byte-identical to a SHA this command itself published for this branch.
Never hand-roll a force-push around it; the exact guard lives in the `bin/ac-ship.sh` header and `push` implementation.

## Config

HOME-ONLY: `$AC_HOME/projects/<name>.yaml` is captain-owned and branch-immune; the project repo is never a config source (resolver: `ac_project_config_file`, ac-lib.sh).
Keys: `commands.{test,lint,format}`, `auto_fix.<step>` round limits, `ignore_patterns`, `document.instructions`, `test.evidence.{store_in_repo,dir}`, `test.attestation` (accept|ignore TDD attestations), `review.model` (reviewer model).
See docs/configuration.md for the full schema and examples.
A project with no config: the crewmate self-discovers the values and emits `bin/ac-qa.sh config-proposal --id <proposal-id>` (ship + qa keys, one contract); the chief - never the drafting agent - reviews and runs `bin/ac-qa.sh config-install <proposal-id>` with a `CONFIG-INSTALLED:` room receipt (captain veto only). Ship and qa snapshot the canonical file independently at run start; unique proposal directories plus a base-hash check, per-project lock, and atomic replace prevent concurrent drafts from overwriting one another.

Trust boundary: the home config is branch-immune by location.
An unconfigured project executes no discovered commands. The task agent drafts a proposal, the chief reviews and installs it into the fleet home, and a fresh run consumes the reviewed config.
