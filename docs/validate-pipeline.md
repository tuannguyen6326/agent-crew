# crew-ship pipeline

crew-ship is the 8-step, hold-and-fix validation pipeline a crewmate runs before its work reaches the push target.
The crewmate IS the runner: it performs the judgment steps and records their outcomes, while `bin/ac-ship.sh` keeps durable step state and runs the deterministic parts.

This page is a map, not the law.
The authorities are:

- the `bin/ac-ship.sh` header - the state machine, every command, and the named contract blocks (TDD ATTESTATION, SHIP TEST RECEIPT, PUSH INCORPORATION, FINISH, OVERRIDE MARKER, REVIEW-ROUND CONVERGENCE);
- `.agents/skills/crew-ship/SKILL.md` - the runner's step-by-step procedure;
- the `delivery-review` skill - when a task takes crew-ship at all, and the review obligation it fulfils.

Related: [concepts.md](concepts.md), [configuration.md](configuration.md), [scripts.md](scripts.md), [qa-attestation.md](qa-attestation.md).

## Starting a run

Run from inside the worktree being validated:

```
bin/ac-ship.sh start --intent "<goal verbatim>" [--skip <a,b>] [--target <branch>] [--lint] [--tdd]
```

- State lives at `<repo>/.crew/ship/<run-id>/`, with a `current` symlink to the active run.
- `--target <branch>` pins a delivery target other than the repo default (a prelive or release branch); review diff, test/lint reopen scope, push checks and the finish gate then compute against `origin/<branch>`.
  Pushing the target branch itself is refused, like the default branch.
- `--skip` is the only skip path and must come from the user; `intent` and `review` refuse `--skip` outright.
- `--lint` opts lint in; `--tdd` declares the implement's TDD run as the test evidence (see [Conditional steps](#conditional-steps)).
- `start` freezes the run's config, and refuses when it cannot resolve the fleet home rather than freeze an empty one.

The runner marks each step `running` before it begins and `completed`, `failed` or `skipped` after, with `bin/ac-ship.sh step <name> <status>`.

## The steps

The order is fixed and not configurable.

| # | Step | Deterministic part | Judgment part |
|---|---|---|---|
| 1 | intent | record `--intent` verbatim | surface obviously out-of-intent work as `ask-user` |
| 2 | rebase | `base` recomputes the merge-base; `skip-remaining` on an empty diff | guard against bundling unpushed local-default commits; rebase onto `origin/<branch>` first, then the freshest default; resolve conflicts |
| 3 | review | `cmd format` before the reviewed ref; `review-agent` runs the independent verifier | classify findings; fix, then a fresh round on the new ref |
| 4 | test | `cmd test` (baseline, scoped, or accepted attestation) and its receipt | intent evidence always; record what actually executed in `meta test` |
| 5 | document | - | find and fix doc gaps; any unresolved finding gates, including `info` |
| 6 | lint | `cmd lint`, opt-in | lint-category pass when no command is configured |
| 7 | push | `push` (lease plus patch-id guard, fail closed) | stage in-repo evidence, commit leftovers |
| 8 | pr | - | create the PR against the run's target; body from recorded meta; signature line |

There is no CI or QA step: `finish checks-passed` (validated, PR raised, unmerged) is the runner's stop point, and merging and CI watching stay with the captain.

### Step notes

- **rebase** - an empty `git diff $(bin/ac-ship.sh base)...HEAD` after rebasing means nothing ships: run `skip-remaining`, which marks every still-pending step `skipped`, and finish.
  `ac-ship.sh base` always recomputes the merge-base, because a rebase moves it.
- **review** - the formatter runs here, before the reviewer, and its commit lands before the reviewed ref.
  A formatting commit later in the run would move HEAD past `reviewed_ref`, which `push` and `finish` refuse.
  Fix-round commits are formatted the same way, so the ref each round reviews is the ref that ships.
- **test** - `meta test.testing_summary` must say what actually executed; a cache hit, an accepted attestation, or "no tests found" are not green.
  New test files force an `ask-user` gate even when green.
- **push** - nothing reformats here; never hand-roll a force-push around a refusal.
- **pr** - `gh pr create --base <target>`, where `<target>` is the run's `target=` from `status`, else the repo default; an existing PR is updated through the REST `PATCH`, not `gh pr edit`.
  The body (`## Intent`, `## What Changed`, `## Risk Assessment`, `## Testing`, `## Pipeline`) stays under about 63,000 bytes and ends with `Validated by agent-crew crew-ship`, or the passed-with-override form (see [Overrides](#overrides)).
  The skill owns the full PR recipe.

## Conditional steps

The ORDER is fixed; two steps may not RUN, and both fail toward running:

- **lint is opt-in.**
  Without `start --lint` the step starts `skipped`, finish accepts it, and it stays skipped across fix rounds.
  With `--lint` it runs `cmd lint`.
- **test skips on `--tdd`.**
  `--tdd` is a declaration, not proof: no re-run and no tree check.
  Without it, test runs.
  A fix that changes code re-runs test regardless, because the implement's TDD never covers a later fix diff.

### TDD attestation (the evidence-backed variant)

`bin/ac-ship.sh attest-test` runs the configured `commands.test` in the worktree and, only on exit 0, writes `<repo>/.crew/ship/attest-test.json` (branch, commit, tree, command, timestamps, output hash).
A dirty or unreadable worktree is refused before and after the run.

`cmd test` accepts a fresh attestation and completes the step without re-running the suite when all of these hold: `test.attestation` is absent or `accept`, and the branch, HEAD, tree, configured command and log hash all still match.
Any other value of `test.attestation` than `accept` or `ignore` fails closed to running the suite.
A fix commit moves HEAD, so the attestation goes stale by construction.

`attest-check` is the chief's freshness query over the same conditions: `attested: fresh` (exit 0), `stale:` (exit 1), or `no attestation` (exit 2); a fresh one means the chief need not re-run the suite.

### Scoped tests

`commands.test-changed` is an opt-in command template that must carry a `{files}` placeholder.
`cmd test` then runs it on the base-to-HEAD changed set instead of the full suite.
Precedence: a fresh attestation first, then the scoped run when the key is set and the changed set is non-empty, then the full suite.
A scoped green completes the step, but its receipt says `not-qualifies:scoped`: a partial run is never suite proof.

### The test receipt

The test step is the only place the unit suite runs in the whole crew.
`cmd test` publishes one run-scoped receipt at `<repo>/.crew/ship/<run>/test/receipt.env` (schema `agentcrew.ship-test-receipt/v1`), keyed to HEAD:

- replaced with `not-qualifies:incomplete` before the command runs;
- then `qualifies:executed` on a zero exit, `not-qualifies:non-zero` otherwise, or `qualifies:execution-attestation` for an accepted attestation.

A `--tdd` declaration, a plain `step test completed`, and legacy runs write no receipt.
A QA round only reads the receipt, by exact run id and SHA; when a task carries a QA gate, run `cmd test` (or land an accepted `attest-test`) even under `--tdd` and pass the run id as `ac-qa.sh agent --ship-run <run-id>`.

## Findings

Every judgment step reports a JSON array through `ac-ship.sh findings <step>` (stdin; a tty is refused):

```
[{"id","severity","action","file","line","description","authority_class","authority"}]
```

- `severity`: `error` | `warning` | `info`.
- `action`: `fix` | `ask-user` | `no-op`.
  - `fix` is reserved for delivery-blocking findings: correctness, security, regression, data loss, or an accepted requirement or ruling violated.
    It is assigned to a crewmate fixer; the reviewer never fixes.
  - `ask-user` parks the run and is relayed to the captain with a question, 2-4 options, one tradeoff per option, and a recommendation.
  - `no-op` is informational; advisory improvements ride here with an optional `suggested_fix`.
- `authority_class`: `internal` | `external` | `none`; `authority`: one sentence naming who states the expected behavior and where (a `file:line`, a URL, or `captain <date>`).

The shared normalizer `ac_findings_normalize` (`bin/ac-pipeline-lib.sh`) fails closed:

- a missing, empty or unknown action, including the retired `auto-fix` alias, becomes `ask-user`;
- a `fix` with `severity: info` is floored to `no-op` (`severity_floored: true`) first;
- an unknown class or empty authority becomes `none`, and a `fix` with class `none` is downgraded to `ask-user` (`authority_downgraded: true`).

`meta <step>` records the PR-body envelope: review `risk_level`/`risk_rationale`, test `testing_summary`/`tested`/`artifacts`.
Step fixes commit as `agent-crew(<step>): <summary>`.

## Hold-and-fix

A failing step HOLDS the run; it never restarts from intent.
Completed earlier steps stay completed, and the held step re-runs on the fix diff.

- `step <name> fixing` increments that step's durable fix-round counter (the third column of `steps.tsv`); at `auto_fix.<step>` rounds the runner stops fixing and parks the rest as `ask-user`.
- When the fix goes to another crewmate, `ac-ship.sh fix-report <step>` renders its contract: `fix` findings plus captain-decided `ask-user` findings; undecided ones stay parked.
  The fixer commits to the crew branch and never pushes.
- A fix that changes code re-opens completed `test` and `lint`.

## Independent review

The review step is never a self-review.
`ac-ship.sh review-agent` is a thin adapter over `bin/ac-verify.sh codereview`, which leases an isolated worktree at the exact ref, runs one fresh reviewer pane, validates the verdict object `{findings[], summary, risk_level, risk_rationale, reviewed_ref}`, captures the evidence, then reaps the pane and returns the lease.
There is no resumable reviewer session, no headless fallback, and no second reviewer outside the engine.
The `ac-verify.sh` header owns the reviewer prompt and the round itself.

- **Receipt binding.** `<run>/review.agent` binds the verdict to `reviewed_ref`.
  `step review completed` refuses when HEAD differs, and `push` and `finish checks-passed|passed` re-check the same binding, so a commit after review cannot be pushed or recorded as validated.
  The re-check is a bare SHA equality, so a documentation commit invalidates it too.
- **Rounds.** Round 1 reviews the full base-to-ref diff.
  Round N+1 receives only round N's validated result as history, verifies its still-open findings, and reviews the interdiff `roundN.reviewed_ref..HEAD`, with the full diff as context.
- **Floor.** From round 2, a new non-critical finding outside the fix delta floors to advisory; a re-reported open id from the previous round stays blocking.
- **Risk is advisory.** `risk_level` feeds the PR's `## Risk Assessment` and never gates finish or merge by itself.

### Convergence gates

`review-agent` enforces four gates, so the loop converges by machine:

- **Entry.** A round opens only after the test step completed in this run or on a fresh attestation; a bare `--tdd` declaration does not qualify.
- **Post-pass freeze.** A round with zero `fix` findings freezes the tree; `review-agent` refuses to re-open on the caller's own post-pass commits, while a genuine rebase still opens a round.
- **Same-ref brake.** A third invocation on one unchanged ref holds and names both earlier attempts.
- **Cap.** Past `review.max_rounds` verifier invocations per run (project YAML, default 3; rejected attempts count) the loop holds for the owning chief, who either runs `review-residual accept --grounds '<why>'` (refused below the cap, and refused while a critical correctness, security or data-loss finding remains) or grants exactly one `review-agent --final-round`.


## Push safety

`ac-ship.sh push` is the only sanctioned way to publish the branch.
It anchors `--force-with-lease` to the exact remote SHA it read and refuses to drop remote commits this branch has not incorporated by patch-id, failing closed on git errors, a detached HEAD, and the default or target branch.

Resolving a conflict during a rebase changes a commit's patch-id, so one bounded excuse keeps that ordinary step legal: the unincorporated set is waived only when the remote ref is byte-identical to a SHA this command itself published for this branch, recorded in `<repo>/.crew/ship/pushed.tsv`.
Anything another actor pushed is still refused; the header's PUSH INCORPORATION block states the exact guard and its residual.

## Finishing

```
bin/ac-ship.sh finish <checks-passed|passed|failed|cancelled>
```

- `checks-passed` = validated but unmerged, the crew's stop point.
- `passed` = merged; it additionally requires HEAD reachable from the run's delivery target (the default ref when no `--target` was pinned), so a squash merge fails closed and should use `checks-passed`.
- Both refuse unless every non-skipped step is `completed`, no `fix` finding or undecided `ask-user` remains, and a completed review still covers HEAD.
- `failed` and `cancelled` are always allowed.

Never merge a crew-ship PR whose run did not reach `checks-passed`.

### Overrides

Two sanctioned releases let a run finish without the evidence a step exists for: `review-residual accept` and `--tdd`.
Each writes a row to `<run>/override` (`review-residual` or `tdd-declared`), cleared when the real evidence arrives (a fresh review round, or the test step completing).
`status` prints the rows, `finish` appends `attestation=passed-with-override:<kinds>` to `run.meta`, and the PR signature carries them, so an approved failure never reads as clean green; they never block finish.

## State

```
<repo>/.crew/ship/
├── attest-test.json          # TDD attestation; outlives runs
├── pushed.tsv                # <branch>\t<sha> per landed push
├── current -> <run-id>
└── <run-id>/
    ├── run.meta              # intent, branch, target, outcome, attestation
    ├── steps.tsv             # step<TAB>status<TAB>fix-rounds
    ├── findings/<step>.json  # normalized findings
    ├── findings/<step>.meta.json  # PR-body envelope
    ├── test/receipt.env      # the ship test receipt
    ├── review.agent          # exact-ref review receipt
    ├── review.final-round    # the one granted final round
    ├── override              # passed-with-override rows
    ├── watch.pane            # live dashboard pane id
    └── logs/                 # run.log, review-agent-rN.json, review-invocations.tsv
```

Step statuses: `pending`, `running`, `fixing`, `awaiting_approval`, `completed`, `skipped`, `failed`.
`bin/ac-ship.sh status` is the single source of run state.

## Live dashboard

`start` auto-opens `bin/ac-ship-watch.sh` in a herdr tab labelled `ac-ship-watch` in the family's workspace (`AC_SHIP_WATCH=off` disables).
It shows the active step, fix rounds, findings and the run-log tail, and closes when the run finishes or idles (`AC_SHIP_WATCH_IDLE`, default 1800s).
Without herdr, run `ac-ship-watch.sh` in any terminal.

## Config

Config is HOME-ONLY: `$AC_HOME/projects/<name>.yaml`, captain-owned and branch-immune; the project repo is never a config source (resolver: `ac_project_config_file` in `bin/ac-lib.sh`).
Ship keys: `commands.{test,lint,format}`, `commands.test-changed`, `auto_fix.<step>`, `ignore_patterns`, `document.instructions`, `test.evidence.{store_in_repo,dir}`, `test.attestation`, `review.max_rounds`.
`cmd <test|lint|format>` returns the command's own exit code, or 4 when nothing is configured.
See [configuration.md](configuration.md) for the schema and an example.

A project with no config is never guessed at: the task agent drafts values with `bin/ac-qa.sh config-proposal`, and the chief, never the drafting agent, installs them with `bin/ac-qa.sh config-install` and a `CONFIG-INSTALLED:` room receipt, for a fresh run to consume.

## After delivery: QA

QA is not a pipeline step.
When a task was triaged with a QA gate, the same execution session that reached `checks-passed` calls `bin/ac-qa.sh agent ... --ship-run <run-id>`, which runs one fresh, independent QA pane over the delivered head.
QA gates the merge, not the push; with `qa.require_for_ship: true` the merge helpers require a passing attestation for the exact head.
The full contract is in [qa-attestation.md](qa-attestation.md).
