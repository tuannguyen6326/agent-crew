# QA Attestation Contract

This document summarizes the public runtime contract implemented by
`bin/ac-qa.sh`, `bin/ac-verify.sh`, and the merge helpers. The script headers
remain authoritative for command-level details.

## Independent QA boundary

QA is an independent behavioral verifier. It may execute the delivered product,
approved local services, browsers, workflow workers, and approved E2E suites.
It may write evidence, test-only proposal patches, fixture/store candidates,
and the QA report. It must not fix production code, commit, push, merge, weaken
an oracle to match current implementation, or edit the shared QA store.

The execution caller resolves one profile and, when `panes.qa` is routed,
selects one rule before a QA pane exists:

```text
ac-dispatch-select.sh --pane qa --list
ac-qa.sh agent ... --qa-rule <number|default>
```

`when` is caller guidance, `use` is one atomic harness/model/effort profile,
and `why` is operator-visible rationale. The shell does not evaluate prose.
Dispatch remains model routing only: the selected rule cannot choose a
coverage rung, authorize UT execution, or relax a QA evidence gate.
The selected rule, profile, and dispatch-config hash are frozen in the profile,
run metadata, result, report, and relay envelope. A routed profile is passed
explicitly through `ac-verify qa`; the homeless pane never re-resolves it.
The dashboard derives numbered QA rule cards directly from `when`, `use`, and
`why`, and renders the bare default separately without UI-only config fields.
The tracked example sets that explicit default to `opencode` with
`openrouter/qwen/qwen3.7-plus`.

## One profile round, one pane

Profile resolution, route selection, and worktree allocation are synchronous
preflight operations, not agent sessions. One fresh QA pane owns the complete
round:

```text
test plan + frozen coverage manifest -> baseline -> infra/service/workers
          -> component cases -> final full-flow case/group
          -> evidence -> findings/verdict -> curation receipt
```

Project commands and safe concurrent checks are supervised subprocesses in that
pane. They are not crewmates, subagents, or separately reviewed sessions.
Idempotent retries may stay in the pane while the original harness process,
exact refs, profile hash, route/model/harness, selected scope, and accepted
authority remain unchanged.

A fresh round and pane are required after a source or test ref changes, a
profile/route/model/harness/scope/authority changes, the process exits, a
terminal outcome is recorded, or a context/tool/capability limit closes the
round. Capacity exhaustion is recorded with:

```text
ac-qa.sh finish unverifiable \
  --retry-reason <context-limit|tool-limit|capability-limit>
```

The execution caller may use that structured reason when choosing the next
configured rule. There is no mid-pane model switch or automatic fallback.

## Frozen runtime bundle

Every sanctioned round publishes one immutable bundle:

```text
agent-<task>-r<N>.profile/
├── profile.json
├── config.yaml
├── scopes.tsv
├── ship/
│   └── test-receipt.env
└── store/
    ├── manifest.json
    └── <selected files>
```

`profile_sha256` binds exact source/E2E refs, resolved commands, scope/app,
fixture reference names, routing receipt, config/scope hashes, the frozen
ship-test-receipt hash, and the store manifest plus entry hashes. It excludes timestamps, local allocation paths,
ports, pane identity, and raw secrets.

`ac-verify qa` validates the bundle and atomically copies it to the fixed
source-lease handoff. `ac-qa.sh start` validates and consumes that handoff into
`<run>/profile/`. A profiled run reads execution values and store files only
from that consumed bundle; it does not re-read fleet config, repo knowledge, or
the live shared store. A missing project store is represented by an explicit
empty versioned manifest.

## Boundary policy (captain ruling, 2026-07-25)

Verbatim policy:

```text
QA policy:
  client-facing / API / integration / E2E / Database
  khong dung hoac rerun UT
QA phai boot service roi kiem tra behavior qua client/API/integration boundary.
```

What it changes, mechanically:

- every behavioral case stimulates the BOOTED deliverable from outside its
  process - an HTTP/gRPC request against the served endpoint (an SDK or CLI
  acting only as its client counts), a queue/workflow/schedule trigger consumed
  by a running worker, a real browser, or the approved E2E suite. Database and
  cache reads are ASSERTION surfaces, never the stimulus; an in-process
  dependency-injection harness is not evidence and the case is `unverifiable`
  with an `ask-user` finding naming the missing boundary;
- the closed tier set is `api | db | workflow | web`. QA has no `unit` case
  tier or execution boundary. QA may still author a non-executed test-only unit regression PROPOSAL; execution lands it and the ship pipeline runs it;
- `baseline` is a receipt CHECK. `ac-qa.sh agent --ship-run <run-id>` freezes
  that run's `<repo>/.crew/ship/<run>/test/receipt.env`
  (`agentcrew.ship-test-receipt/v1`) into the profile bundle before the
  verifier lease exists; the mutable ship `current` symlink is never consulted.
  `ac-qa.sh baseline` validates the frozen copy and records
  `qualifies:<reason>` or `not-qualifies:<reason>` in the step note. QA never
  runs the suite in either direction. The state is informational when the
  frozen coverage manifest has no `ut` row. A `ut` row reuses this receipt as
  its execution evidence and therefore requires `qualifies:<reason>` for the
  exact target SHA; otherwise that AC must move to IT;
- `serve` and `baseline` are OWNED transitions - the commands that publish the
  proof record the step, and a direct `step baseline|serve completed` refuses.
  `health` stays a command and owns no step; its proof is
  `<run>/runtime/receipt.env` (`agentcrew.qa-runtime-receipt/v1`), publishable
  only by a zero-exit probe against a live process group, and never re-issued
  inside one round;
- every terminal case binds one immutable
  `<run>/boundaries/<case-id>/<ts>-<pid>.env`
  (`agentcrew.qa-boundary-receipt/v1`) through `ac-qa.sh boundary-run`
  (shell clients), `boundary-register --boundary web` (a browser transcript
  plus its visual, registrable before the final case row exists), or
  `boundary-register --boundary e2e` (a runtime-bound wrapper over the existing
  immutable E2E receipt, valid only for the cases that receipt names).

What it does not claim: shell cannot decide whether arbitrary command text is
semantically a good test. The receipts prove an approved driver ran against the
recorded ready runtime and produced the registered artifacts; rejecting
in-process construction dressed as a client call remains verifier and captain
judgment.

## Frozen coverage ladder

Before any case-producing command, `testplan.md` must contain exactly one of
each machine-readable section:

```md
## Coverage
coverage: <ac-id> | ut | <repo-relative-test-reference> | -
coverage: <ac-id> | it | - | <case-id>
coverage: <ac-id> | e2e | - | <case-id>

## Full Flow
full-flow: <case-id>
```

`ac-qa.sh step testplan completed` validates the grammar, resolves UT paths as
regular blobs in the exact target Git tree, checks any UT row against the
frozen exact-SHA ship receipt, and atomically publishes
`<run>/testplan-manifest.json` with schema
`agentcrew.qa-testplan-manifest/v1`. Declaration order is preserved and
`run.meta` records both plan and manifest hashes. `boundary-run`,
`boundary-register`, fixture registration, `cmd e2e`, and `case` refuse until
the manifest is frozen and still matches the plan.

The evidence ladder is:

1. `ut`: a concrete test reference plus a qualifying ship receipt; no QA case
   exists or runs.
2. `it`: a passing `api`, `db`, or `workflow` case against the booted
   deliverable.
3. `e2e`: a passing `web` case or a case carrying the existing E2E wrapper
   receipt.
4. A declared IT/E2E full-flow case or final group re-proves the assembled
   primary path after component cases.

Coverage/full-flow selection may change through an authority-backed
`testplan-amend` only before any boundary, fixture, E2E, or case evidence
exists. After evidence, amendments outside those sections are allowed only
when the extracted arrays remain identical.

Full-flow ordering reads timestamps from each effective ledger-bound receipt:

```text
minimum(full-flow receipt `started_at`)
  >= maximum(non-full-flow receipt `completed_at`)
```

Every timestamp must be valid UTC and each receipt must complete at or after
its start. A late component retry requires re-running and rebinding the
full-flow case/group.

## Completion gate

`finish passed` runs one completion gate before outcome mutation, teardown, or
attestation publication. Passing requires:

- every fixed step is `completed` or `skipped`;
- every skipped step has a non-empty durable note;
- every finding is `no-op`, or a decided `ask-user`; `fix` blocks;
- the `serve` step is `completed` and a valid runtime boot receipt is on record
  whose process group is still alive;
- at least one unique case, all with status `pass`, valid tier from the closed
  set `api|db|workflow|web`, grade A-D, existing evidence below the declared
  evidence root, and one coherent client-boundary execution receipt bound to
  the runtime boot receipt;
- each web case has a valid visual linked to that case id, in addition to the
  run-level visual floor;
- the current checkout still equals the exact source ref and is clean;
- a completed E2E step has a zero-exit immutable receipt bound to the frozen
  command, cases, profile, and exact refs;
- the frozen manifest still matches the current plan and recorded hashes;
- every UT row has a valid exact-tree reference and qualifying exact-SHA ship
  receipt, every mapped IT/E2E case satisfies its rung, and every declared
  full-flow case is passing and effective-last;
- every oracle change is covered by an authority-backed amendment;
- every executable task-local harness has exactly one regression-promotion
  classification; and
- as the gate's final act before teardown, the recorded process group is still
  alive and the frozen health probe exits zero again, published as an immutable
  `agentcrew.qa-runtime-gate/v1` receipt. Post-teardown reconciliation
  validates that record and never requires a terminated process to be alive.

`step <name> skipped --note '<reason>'` is the only skip path. `start --skip`
is rejected. E2E approval is project-level: the chief installs the stable
repository/ref/command/workdir/endpoint/fixture mechanics. The QA pane performs
task-level case selection with:

```text
ac-qa.sh cmd e2e --cases <case-id>[,<case-id>...]
```

That command owns the E2E step transition and receipt. Routine case selection
does not create a per-run approval gate. A missing approved command for a
selected E2E case makes the case unverifiable and produces an `ask-user`
finding; a proposed E2E test cannot satisfy the current exact-ref round.

Failed, unverifiable, and cancelled outcomes remain recordable even with
incomplete downstream work. Failed and unverifiable outcomes complete the
verdict step atomically. The facade refuses final export while any step remains
`running` or `fixing`.

## Durable verdict and reports

`run.meta outcome` is the sole verdict authority. The pane supplies narrative
summary and evidence candidates. A pane verdict claim is optional; when present
it must match durable state. The facade validates exact refs, profile identity,
ledgers, evidence paths, and the v2 marker before deriving:

```json
{
  "verdict": "passed|failed|unverifiable",
  "summary": "one paragraph",
  "evidence": ["caller-owned paths"],
  "verified_ref": "<exact-source-sha>",
  "report": "<absolute-stage-report>"
}
```

`retry_reason` appears only for an unverifiable capacity-limited round.
Evidence paths exist below the caller-owned export after leases are returned.

Every terminal facade path atomically publishes `report.md` beside the QA
`brief.md`. A normal report begins with the durable product verdict and renders
steps, cases, frozen coverage rows, ship qualification, full-flow ids and
effective receipt timestamps, findings/decisions, visuals, exact refs,
profile/routing identity, curation, oracle amendments, and regression
candidates from run state. A facade failure begins with `verdict: error`, names
the target and phase, records caller result absence and any preserved state,
and never represents a product pass.

`relay-report.md` surfaces the full-flow ids and canonical-report reference but
is only the transport checklist for the caller. It does not replace the
canonical stage report, and evidence files replace neither.

## Atomic v2 merge attestation

A sanctioned pass stages a complete
`agentcrew.qa-attestation/v2` marker in the final marker directory, validates it
with the same parser used by merge gates, then atomically renames it.

All merge-gate arms validate the body, including flat projects. They require a
passing schema/outcome, exact source SHA, non-empty profile/config identity,
positive equal case counts, scoped body/filename agreement, a valid optional QA
rule, and matching optional profile/E2E pins. Empty, partial, malformed, legacy,
off-head, or renamed scoped markers do not authorize a required QA merge.

## Store reuse, fixtures, and oracle amendments

The frozen store snapshot is the only runtime knowledge source. Store cases
enter the behavioral ledger only when the current test plan maps them to an
accepted requirement or justified regression boundary. Store health,
retirement, and maintenance are curation-only and cannot downgrade the product
verdict.

A fixture pack owns common setup, selectors, assets, deterministic cleanup, and
retry behavior. Paths are relative and path-closed. A read-write selector must
be idempotent under retry. Execute a reviewed selector with:

```text
ac-qa.sh fixture <pack-id> --selector <name> \
  --case <id> [--case <id> ...]
```

The receipt binds the exact source, profile, store manifest, selector, mapped
cases, mutation/retry declaration, timestamps, and exit code.

Completing `testplan` freezes its content hash and canonical coverage manifest.
A changed expectation requires:

```text
ac-qa.sh testplan-amend \
  --case <id> [--case <id> ...] \
  --authority '<accepted source>' \
  --reason '<why the prior oracle was wrong>'
```

Before evidence exists, accepted authority may regenerate the selected coverage
and full-flow arrays. After any boundary, fixture, E2E, or case evidence exists,
those arrays are immutable and a selection change requires a fresh round;
prose-only amendments must preserve them. Current implementation behavior alone
is not authority. Without an accepted contract, record `unverifiable` or an
`ask-user` finding.

Every new task-local harness is classified as `repo-regression`,
`e2e-regression`, `fixture-pack`, `evidence-only`, or `retire`. QA may export
one test-only `regression-proposal.patch`; execution applies/refines and reviews
it, then a fresh QA round proves the landed test and product behavior.

## Non-gating curation

After recording the product outcome, QA attempts curation and writes a complete
candidate below the exported run. It records:

```text
ac-qa.sh curation <completed|skipped|failed> [--note '<reason>']
```

The pane never edits the shared store. A chief may install a reviewed candidate
with `store-install`; the candidate's base-manifest hash prevents overwriting a
concurrent accepted update. Missing curation exports as
`failed/not-recorded`. Curation never changes the behavioral verdict or
creates/invalidates an attestation.

## Durable workflow engines

Workflow-engine projects keep stable startup, worker readiness, namespace/task
routing references, time control, teardown, event-history export, and
retry-safe seed/cleanup mechanics in the chief-owned profile and reviewed
fixture packs. Task plans select only affected behavior. Each mutable case uses
an isolated workflow/run identity and records exact refs, command receipts,
event history, worker/service logs, and asserted DB/cache/external side effects.
Static inspection alone is not workflow evidence.

## Opt-in real-harness smoke

The unit tests use deterministic fakes and are not production proof. On a host
with a configured pane runtime and a deliberately disposable local fixture
repository, run one opt-in smoke:

```text
AC_QA_LIVE_SMOKE=1 \
bin/ac-qa.sh agent \
  --home <absolute-fleet-home> \
  --target <fixture-exact-sha> \
  --task qa-attestation-live-smoke \
  --brief <absolute-fixture-qa-brief> \
  --evidence <absolute-disposable-evidence-dir> \
  [--qa-rule <number|default>]
```

The fixture must use only local/test services and no production credentials.
Verify the exported `verdict.json`, canonical `report.md`, relay report, run
state, exact refs, routing receipt when routed, and v2 marker. Then tamper a
copied bundle or marker and confirm validation fails closed. If no configured
harness/pane runtime is available, record the smoke as unavailable; do not
simulate that environment and call it production proof.
