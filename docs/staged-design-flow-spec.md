# Staged Design Flow Specification

Status: Accepted  
Date: 2026-08-10

## Problem

The staged flow already lets one design crewmate produce specification,
architecture, and implementation-plan reports before execution. Its current
report contract is intentionally small, but it does not define enough
cross-stage traceability, self-review, or exit criteria to make report quality
consistent across harnesses.

The flow must become more reliable without adding mandatory plugins, more
production agents, unconditional independent review, or document ceremony that
costs more than the decision warrants.

## Objective

Define a native Agent Crew design flow that balances token cost, elapsed time,
and safety, with efficiency as the primary optimization target.

The flow must:

- remain fully usable when no external plugin or optional skill is installed;
- reuse one active design session across all required design stages unless that
  session is unrecoverable;
- make each stage independently reviewable before downstream work begins;
- scale report depth to task complexity and consequence;
- preserve chief, second-chief, and captain authority boundaries; and
- hand execution a complete, traceable contract without repeating whole prior
  reports.

## Non-Goals

- Replace the direct, epic, execution, delivery, code-review, or QA flows.
- Add a plugin registry, plugin-routing state, or plugin-specific artifact path.
- Require every staged task to produce all three design reports.
- Require an independent reviewer for routine design decisions.
- Require implementation code in a plan.
- Introduce a new report parser or durable workflow state machine in version 1.
- Change the existing second-chief round protocol or captain merge authority.

## Definitions

- **Design crewmate**: the single active report-only crewmate that may produce
  the required design reports in one session. A replacement after an
  unrecoverable session is recovery, not an additional role.
- **Stage**: one of `spec`, `architecture`, or `plan`.
- **Stage admission**: the evidence-based decision that a stage is required.
- **Inline self-review**: the design crewmate checking its own report against
  the stage checklist. It is not independent review and creates no pane.
- **Stage gate**: the owning chief's mandatory review and routing decision for
  one report.
- **Decision boundary**: a statement of who may resolve an open choice: the
  design crewmate, chief, second chief, or captain.
- **Trace ID**: a stage-owned, family-stable identifier: `R#` for requirements,
  `AC#` for acceptance criteria, `D#` for architecture decisions, and `T#` for
  plan tasks. IDs are append-only across revisions: a revision never renumbers
  or reuses an ID, and a removed item's ID is retired with a one-line note.
  Active downstream content must not reference a retired ID.
- **Valid room receipt**: an entry-anchored, parser-valid receipt authored by
  the owning `<family>-chief`, for the exact family and stage: the receipt is
  the entry's own text under the room grammar `- [<utc>] <actor>> <text>`,
  never a marker found inside text. A quoted, relayed, malformed, wrong-actor,
  or wrong-stage receipt is never valid.

## Core Flow

```text
intake and triage
        |
        v
one design crewmate
        |
        +-- spec ---------> inline self-review -> stage gate
        |
        +-- architecture -> inline self-review -> stage gate
        |
        +-- plan ---------> inline self-review -> pre-implement gate
        |
        v
one execution crewmate
```

The diagram shows all three stages admitted; the pre-implement gate always
binds to the last admitted report (Gate and Authority Contract).

The design crewmate performs one initial context scan and reuses that context
for every admitted stage. It must stop after each report and wait for the owning
chief's approval or revision feedback. A rejected report is revised in the same
session when that session is recoverable - otherwise by a fresh design crewmate
briefed with the prior report and the gate feedback verbatim - before any
downstream report begins.

## Stage Admission

The owning chief selects only the stages that add decision value:

| Signal | Required stage |
| --- | --- |
| Requirements, behavior, scope, or success are unclear | `spec` |
| The change has cross-cutting boundaries or viable technical alternatives | `architecture` |
| Execution is risky, dependency-sensitive, or spans multiple ordered changes | `plan` |

Rules:

1. Before the first report is produced, the owning chief records one valid room
   receipt for each of the three stages:

   ```text
   STAGE-ADMISSION: stage=<spec|architecture|plan> decision=<admit|skip> grounds=<one line>
   ```

2. The latest valid `STAGE-ADMISSION:` receipt for each stage is the canonical
   stage set. Silence is neither admission nor a skip.
3. Admitted stages run in `spec -> architecture -> plan` order.
4. A stage may be skipped when its signal is absent, including in staged flow.
   Its skip receipt must contain concrete grounds.
5. A later valid receipt may change `skip` to `admit` when new evidence reveals
   that the stage is required. Once an admitted stage has produced a report, a
   later `skip` receipt for that stage is invalid; the stage remains admitted.
6. A downstream report must reference every prior admitted report by path and
   the `report_sha256` from the latest valid `GATE-ROUTING:` receipt that binds
   the accepted report version. Route-specific approval still follows the Gate
   and Authority Contract; routing alone is not approval.
7. A newly discovered upstream ambiguity stops downstream work and returns to
   the earliest affected stage.

## Shared Report Contract

Every report must contain:

1. **Inputs**: the captain order, repository revision, and prior report
   references used.
2. **Summary**: the decision-ready result, not a transcript of the analysis.
3. **Evidence**: concrete repository references for brownfield claims.
4. **Needs Decisions**: unresolved questions with owner, options, trade-offs,
   and the report author's recommendation.
5. **Risks**: only risks material to the current stage.
6. **Self-Review**: a compact pass/fail receipt for the stage exit criteria.

Rules shared by all reports:

- A repository fact uses `file:line` evidence.
- Missing product behavior becomes `needs-decision:`; it is never invented.
- Prior report content is referenced by Trace ID instead of copied wholesale.
- A revision lists every added, changed, and retired Trace ID. Retiring an ID
  invalidates any active downstream content that references it.
- Report depth scales with risk and complexity; there is no minimum length.
- A required section with nothing material to report records one line,
  `n/a: <reason>`; that is a complete section, not a missing one.
- Optional tools may assist the author, but the report must be complete and
  valid without naming, invoking, or depending on them.

## Specification Stage

### Required Content

- Problem, intent, and available evidence.
- Desired outcome and measurable success.
- In-scope and out-of-scope behavior.
- Functional requirements identified as `R1`, `R2`, and so on.
- Testable acceptance criteria identified as `AC1`, `AC2`, and so on, each
  mapped to one or more requirements.
- Material non-functional requirements only.
- Edge cases that change observable behavior.
- Assumptions, each marked confirmed or unresolved.
- Decision boundaries for unresolved product or policy choices.
- `needs-decision:` entries for questions the repository cannot answer.

### Boundary

The specification describes what and why. It must not select components,
libraries, file paths, architectural patterns, or implementation tasks.

### Exit Criteria

- Every requirement is observable and unambiguous.
- Every requirement is covered by acceptance criteria, or carries an explicit
  rationale for why direct acceptance coverage does not apply.
- Non-goals and decision boundaries are explicit.
- No placeholder, contradiction, or unresolved question is hidden in prose.
- The scope fits one independently deliverable task family; otherwise the
  report recommends decomposition.

## Architecture Stage

### Required Content

- Referenced requirement, acceptance, and non-functional Trace IDs when a
  specification exists; otherwise, referenced captain-order clauses and the
  recorded specification-skip rationale.
- Existing-system constraints supported by repository evidence.
- Architectural drivers, ordered by decision impact.
- Components and their responsibilities.
- Interfaces, dependencies, and data flow.
- Error and failure behavior at affected boundaries.
- Viable alternatives with trade-offs and a recommendation. If only one option
  is viable, the report states why the alternatives were invalidated.
- Chosen decisions identified as `D1`, `D2`, and so on.
- Compatibility, migration, rollback, and operational consequences when
  applicable.
- A coverage map from requirements - or, when the specification was skipped,
  from captain-order clauses - to decisions or components.
- The smallest useful architecture diagram when the Diagram Rule applies.

### Diagram Rule

The architecture report includes a diagram when any of these conditions holds:

- three or more affected components participate in the same flow;
- the design crosses a process, service, repository, deployment, or trust
  boundary;
- asynchronous messages, events, queues, callbacks, or retries are material;
- state transitions or execution order are material to correctness; or
- the affected relationships, ownership, or failure flow cannot be understood
  as clearly from a short paragraph or table.

Use one source-editable Mermaid or ASCII diagram embedded in the report. It must
show only the affected scope and label the material components, boundaries,
directions, and data or control flow. Mark asynchronous or trust boundaries when
they affect a decision, and reference the applicable `D#` IDs in the diagram or
its immediately adjacent explanation.

A diagram supplements rather than replaces the interfaces, failure behavior,
and trade-off analysis. When no trigger applies, the report still contains a
Diagram section with `n/a: <why a diagram would add no decision value>`.

### Boundary

Architecture defines system shape and durable technical decisions. It must not
expand product scope or turn into a step-by-step implementation plan.

### Exit Criteria

- Every affected requirement - or captain-order clause when the specification
  was skipped - has architectural support.
- Component responsibilities do not overlap ambiguously.
- Every changed boundary has a defined interface and failure behavior.
- Each affected component is understandable through its contract without reading its internals.
- Each affected component's internals can change without breaking consumers that honor that contract.
- The recommendation follows from the stated drivers and trade-offs.
- Consequences and irreversible actions are explicit.
- No architecture decision silently resolves captain-owned product behavior.
- The Diagram Rule is satisfied: a required diagram matches the written
  components, interfaces, flows, and `D#` decisions, or the report records a
  reasoned `n/a`.

## Plan Stage

### Required Content

- Ordered tasks identified as `T1`, `T2`, and so on.
- For each task, all applicable `R#`, `AC#`, and `D#` inputs. When an upstream
  stage was skipped, reference the captain-order clauses and recorded skip
  rationale instead of inventing missing Trace IDs.
- Exact files and relevant symbols to create or modify.
- Dependencies and blockers.
- Interfaces consumed and produced when another task relies on them.
- The smallest useful test strategy and expected result for the task.
- A TDD sequence for every behavior-changing task.
- Documentation changes required by the behavior.
- Material risks, mitigations, rollback, and abort conditions.
- A final coverage map from acceptance criteria to tasks and tests. When the
  specification was skipped, the map runs from captain-order clauses to tasks
  and tests instead.

### Granularity

A task is the smallest independently testable deliverable worth a separate
implementation checkpoint. Setup, scaffolding, configuration, and documentation
belong to the task whose deliverable needs them.

Plans do not include full implementation code by default. Exact signatures,
schemas, or short code sketches are included only when a new or high-risk
interface would otherwise remain ambiguous.

### TDD Shape

Every behavior-changing task defines this sequence:

1. **RED**: exact test file and case to add or change, the targeted command to
   run, and the specific failure expected before implementation.
2. **GREEN**: exact implementation files and symbols to change, limited to the
   minimum behavior needed to satisfy the failing test.
3. **VERIFY**: the targeted command to rerun and the expected passing result.
4. **REFACTOR**: the cleanup boundary and affected checks to rerun, or
   `n/a: no cleanup is warranted after the minimal change`.

The plan does not need to reproduce full test or implementation code. It must
name enough test behavior and expected failure evidence for the execution
crewmate to distinguish a real RED step from a missing-file, syntax, fixture, or
environment failure.

A documentation-only, generated-artifact, or purely mechanical task may record
`TDD: n/a: <reason>`, but it must provide an alternative validation command or
inspection and its expected result. A behavior change cannot use this exception.

### Exit Criteria

- Every acceptance criterion maps to an implementation task and test strategy.
  When the specification was skipped, every referenced captain-order clause
  maps to an implementation task and test strategy instead.
- Every named file and symbol exists at the bound repository revision or is
  explicitly marked for creation.
- Task order respects dependencies and avoids forward references.
- Interfaces and names are consistent across tasks.
- Every behavior-changing task has an executable RED -> GREEN -> VERIFY ->
  REFACTOR sequence; every permitted `TDD: n/a` has replacement verification.
- No placeholder delegates a material decision to the implementer.
- The execution crewmate can begin without rediscovering scope or architecture.

## Self-Review Contract

Inline self-review always runs before a report is announced ready. It checks:

1. **Placeholder scan**: no `TBD`, `TODO`, vague instruction, or missing
   section; a one-line `n/a: <reason>` section is complete.
2. **Consistency**: no internal contradiction or mismatch with accepted prior
   reports.
3. **Scope**: no unrequested expansion and no hidden independent subsystem.
4. **Ambiguity**: no material statement with multiple plausible meanings.
5. **Coverage**: the current stage's required mappings are complete; the plan
   additionally covers every applicable upstream Trace ID.
6. **Evidence**: brownfield claims cite the bound repository state.
7. **Retirement**: no active content references a retired Trace ID.
8. **Diagram**: the architecture report contains an accurate diagram when a
   trigger applies, or a reasoned `n/a` when none does.
9. **TDD**: every behavior-changing plan task defines a genuine expected RED
   failure and subsequent verification, and every exception is permitted and
   carries replacement evidence.

The receipt lists only failures found and fixed, then records `pass`. A failure
the author cannot fix alone never records `pass`: an unresolved product or
policy choice becomes a `needs-decision:` entry, and a contradiction with an
accepted upstream report returns work to the earliest affected stage under
stage-admission rule 7; the receipt names the failure and the exit taken. The
receipt does not repeat the report and does not dispatch another agent.

## Gate and Authority Contract

The owning chief reads every report against the captain's original order before
releasing the next stage.

Routing remains evidence-derived:

```text
captain-owned authority                -> captain
uncertainty or high consequence        -> second chief
otherwise                              -> chief
```

- A chief-routed report consumes no independent-review pane.
- A second chief is advisory and never replaces captain authority.
- A captain gate presents the decision, options, trade-offs, and the chief's
  recommendation in one review surface when the task is substantial.
- The last admitted report receives the existing three-tier pre-implement gate.
- Every accepted report version carries a valid `GATE-ROUTING:` receipt whose
  `report_sha256` matches it: a revision requires a fresh routing receipt
  before approval.
- A report change after approval invalidates that report's approval and every
  later admitted stage's approval. Later report files may remain unchanged, but
  the owning chief must re-review and re-route them in stage order before
  implementation; an independent second-chief round occurs only when the new
  routing requires it.
- Detection is mechanical: at the pre-implement gate the owning chief resolves
  the canonical stage set from valid `STAGE-ADMISSION:` receipts, re-hashes every
  admitted report, and compares each hash with the latest valid, exact-stage
  `GATE-ROUTING:` receipt that binds its accepted version. Any mismatch reopens
  the earliest mismatched report and all later admitted stage gates before
  implementation starts. A stage with no valid `STAGE-ADMISSION:` receipt
  fails closed: the gate blocks until the owning chief records one.

## Efficiency Constraints

- Scan common repository context once per design session.
- Reference prior reports by Trace ID; do not restate them.
- Do not require external research when repository evidence resolves the issue.
- Do not dispatch an independent reviewer for a clear, low-consequence report.
- Do not produce an architecture report for a single-component change with no
  meaningful design choice.
- Do not produce a plan merely to restate an obvious single-step implementation.
- Use one smallest useful architecture diagram; add another view only when it
  resolves a different material relationship that the first view cannot show.
- Prefer the least detailed report that satisfies its exit criteria.
- Stop analysis when another question would not materially change scope,
  architecture, execution order, or authority routing.

## Plugin Independence

The staged design flow has no runtime plugin dependency.

- Agent Crew owns stage admission, report schemas, gates, paths, receipts, and
  handoff semantics.
- No report requirement may name a plugin command or plugin-specific file.
- The absence, disabling, upgrade, or removal of any plugin must not change the
  flow's observable behavior or acceptance criteria.
- Optional tools may improve an author's reasoning, but they confer no authority
  and create no additional mandatory review pass.

## Acceptance Criteria

### FLOW-AC-01: Selective stages

Given a staged task with unclear behavior but no cross-cutting design choice or
non-obvious execution sequence, the design crewmate produces a specification,
passes its gate, and hands off to execution only after the family room contains
valid chief-authored `admit` for specification and reasoned `skip` receipts for
architecture and plan.

### FLOW-AC-02: Ordered correction

Given a rejected specification, the design crewmate revises the same report in
the same session when it is recoverable - otherwise a fresh design crewmate is
briefed with the prior report and the gate feedback verbatim - and architecture
does not begin until the revised specification passes its gate.

### FLOW-AC-03: Cross-stage traceability

Given all three admitted stages, every plan task maps to accepted requirement,
acceptance, and architecture-decision Trace IDs, and every acceptance criterion
maps to at least one task and test strategy. Given a skipped specification, every
captain-order clause referenced by architecture or plan maps to the applicable
decision, task, and test strategy instead.

### FLOW-AC-04: Evidence before invention

Given missing product behavior that the repository cannot establish, the report
contains a captain-owned `needs-decision:` entry instead of an invented default.

### FLOW-AC-05: Inline self-review

Given any completed design report, its self-review receipt shows that
placeholder, consistency, scope, ambiguity, coverage, evidence, retired-ID,
diagram, and TDD checks passed, and no `verify-*` meta or extra pane was
created in `state/` for the stage.

### FLOW-AC-06: Conditional second chief

Given a clear low-consequence report with no captain-owned choice, the chief may
self-approve it with evidence and no second-chief pane is created. Given material
uncertainty or high consequence, the existing second-chief route is required.

### FLOW-AC-07: Plugin-free operation

Given a session with no optional plugin installed or enabled, the design
crewmate can produce every admitted report, pass every applicable gate, and hand
off the same canonical artifacts.

### FLOW-AC-08: Efficient plan detail

Given a routine implementation whose interfaces are already established, the
plan names exact files, tasks, dependencies, and tests without reproducing full
implementation code.

### FLOW-AC-09: Change invalidation

Given a post-approval change to an upstream report, the pre-implement re-hash
against its latest valid routing receipt detects the drift, invalidates that
stage and every later admitted stage, and implementation remains blocked until
the owning chief re-reviews and re-routes those stages in order.

### FLOW-AC-10: Receipt authenticity

Given a receipt-like string inside quoted or relayed prose, a wrong actor, a
malformed receipt, or a receipt for another stage, stage admission and the
pre-implement hash check ignore it. Only a valid room receipt may select a stage
or supply the pre-implement routing hash anchor.

### FLOW-AC-11: Conditional architecture diagram

Given an architecture report whose affected flow has at least three components,
crosses a material boundary, uses asynchronous behavior, depends on state or
execution order, or is otherwise materially clearer visually, the report embeds
one source-editable Mermaid or ASCII diagram showing the affected boundaries and
directional flow and ties it to the applicable `D#` decisions. Given a simple
single-component change with no material relationship or flow change, the
Diagram section records a reasoned `n/a` instead.

### FLOW-AC-12: TDD-ready plan tasks

Given a plan task that changes behavior, the task names the exact test file and
case, targeted RED command and expected behavior failure, minimum GREEN files
and symbols, passing VERIFY command and result, and REFACTOR boundary. Given a
documentation-only, generated-artifact, or purely mechanical task, `TDD: n/a`
is accepted only with a concrete reason and replacement verification evidence.

## Assumptions

- The existing `data/<family>/{spec,arch,plan}/report.md` layout remains
  canonical.
- The existing chief, second-chief, and captain routing protocol remains
  authoritative.
- Version 1 enforces this specification through briefs, operating guidance, and
  focused regression tests rather than a new report parser.
- The `STAGE-ADMISSION:` receipt is hand-posted in version 1; a write-side
  `ac-room.sh stage-admission` helper is the intended follow-up hardening,
  matching how `gate-route` authors `GATE-ROUTING:`.
- Existing optional-tool behavior outside the design stages remains out of
  scope.
