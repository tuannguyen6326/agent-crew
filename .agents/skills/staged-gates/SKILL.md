---
name: staged-gates
description: Staged-flow design gates: the design crewmate's spec/architecture/plan sub-stages, STAGE-ADMISSION receipts, gate-route matrix, second-chief R1/R2 via ac-gate.sh, the three-tier pre-implement gate, +yolo limits, and reopening an earlier stage. Load whenever a staged family is in flight - before admitting stages, reading a design report, routing or approving a gate, or releasing implement.
---

# staged-gates

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Staged flow and stage gates

Staged flow has at most two production crewmates: design then execution.
Spec/architecture/plan are
ELABORATION, not verification - spawn `<task>-design` (scout-kind,
brief via `--stage design`) and it produces each needed report IN
ORDER, printing `done: <sub-stage> report ready (awaiting gate)` and
WAITING. Merging the body never merges the stage decisions: YOU review and
route every report before releasing the next
sub-stage with ac-send (a wrong spec must die before architecture is
built on it), and the pre-implement policy still applies to the last report
produced. Verification roles are lightweight
`verify-codereview` / `verify-qa` pane agents, not crewmates, stages, backlog
rows, or recursive delegation. Family naming is `<task>-design` and `<task>`
(execution); `<task>-qa` is only a QA charter/artifact namespace.
Staged-flow task data nests under the family dir: design reports remain in
`spec/`, `arch/`, and `plan/`, execution material in `implement/`, and QA
material in `qa/`. Historical `review/` and `ship/` dirs are readable but are
never created by the normal flow.
Family-level files stay at `data/<family>/` root: `room.md` and gate artifacts.
Direct tasks and plain scouts stay flat at `data/<id>/` (`ac-brief.sh` is the authoritative layout spec).
Stage admission is receipted, never inferred: BEFORE the first design report,
the owning chief posts one `STAGE-ADMISSION: stage=<spec|architecture|plan>
decision=<admit|skip> grounds=<one line>` per stage to the family room
(hand-posted via `ac-room.sh post` in v1). The latest valid receipt per stage
is the canonical stage set; silence is neither admission nor a skip; a `skip`
may later flip to `admit` on new evidence, and an admitted stage that has
produced a report never flips back. The full design-report contract - shared
report sections, per-stage required content and exit criteria, Trace IDs,
inline self-review, valid-receipt semantics - is owned by
`docs/staged-design-flow-spec.md`; the design-kind brief scaffolds carry it
to the crewmate.
Stage gates - who reviews before the next stage spawns:
- YOU review every stage report, always, against the captain's original
  order. Never spawn the next stage on an unread report.
- `spec` / `architecture` / `plan`: after reading the report, record the
  current per-report route with `bin/ac-room.sh gate-route`. The command derives
  the route from this matrix: `authority=captain` -> `route=captain`;
  otherwise `uncertainty=yes` OR `consequence=high` ->
  `route=second-chief`; otherwise `route=chief`. Report existence alone never
  consumes another pane. Product/behavior/scope/financial/irreversible
  authority belongs to the captain; a second chief may clarify options but
  never substitutes for that authority.
  Every accepted report version carries a `GATE-ROUTING:` receipt whose
  `report_sha256` matches it - a revision requires a fresh `gate-route`
  before approval, and routing alone is never approval. Downstream reports
  reference each accepted upstream report by path plus that receipt's sha.
  A `route=chief` report receives no second-chief pane: self-approve with
  evidence and record `SELF-APPROVED: <stage> - route=chief - grounds: <...>`.
  A `route=captain` report becomes a real pending `GATE:` with the choice,
  options, and your lean. Only `route=second-chief` runs
  `bin/ac-gate.sh <family> <stage>`. YOU run it - the gate belongs to the
  approver, and the crewmate under judgment never runs its own judge. The
  judge's pane remains steer-guarded by `bin/ac-pane-agent.sh`.
  The independent second chief runs ONE engine, NO fallback, in one FRESH
  non-resumed session per invoked round. It sees the same immutable decision
  context as the owning chief: current brief/report, prior stage
  reports, full room, captain preferences, exact repository commit, and R1
  evidence on R2. `gate-context-rN.json` records those paths/hashes and the
  review frontmatter binds the manifest SHA-256. Independence is the fresh
  session, not a starved context; there is no persistent all-round pane.
  Before each invoked round the roomchief verifies the current report itself.
  A rejection loops locally and consumes no round; a pass is recorded with
  `bin/ac-room.sh gate-verify`. R1 returns advisory
  `continue|revise|ask-captain`; before R2 the roomchief records
  `R1-DISPOSITION:`. R2 is terminal and returns
  `continue|chief-decide|ask-captain`; the owning chief makes the final call.
  There is no R3. Record a final decision with the advice and grounds; never
  silently override `revise` or `ask-captain`. A local R1 revision uses the
  non-pending `GATE-LOOPED:` receipt; only a decision genuinely awaiting the
  captain uses pending `GATE:`.
  If the selected engine fails (exit 3) or is disabled (exit 4), the second
  chief is unavailable, never approved. Gather new evidence and record a new
  route only if uncertainty/consequence genuinely changed; otherwise retry the
  peer or escalate to the captain. Never silently downgrade a still-valid
  `route=second-chief` to chief-only approval.
  Gate the artifact, receipt the routing. Triage decisions
  (flow/mode/promote) need no machine gate. Every approval the captain did not
  make reaches them with its reasoning as a vetoable receipt, never as silence.
- Pre-implement gate, THREE-TIERED - judged on the last report before
  `implement` (`plan` when present, else `architecture`, else `spec`):
  FIRST, mechanically: resolve the canonical stage set from valid
  `STAGE-ADMISSION:` receipts (a stage with none blocks the gate,
  fail-closed) and re-hash every admitted report against the `report_sha256`
  on its latest `GATE-ROUTING:` receipt - any mismatch reopens the earliest
  mismatched report and every later admitted stage gate before implement
  may start. Then, by tier:
  AUTO tier (routine tasks): either a valid `route=chief` plus chief pass, or a
  valid `route=second-chief` where YOUR review concurs with `continue`, lets
  implement PROCEED without waiting. Post a `GATE-PASSED (auto):` receipt that
  names the route and evidence to the chat AND the room. Implement is reversible
  (crew branch, no push)
  and the merge gate still guards the exit - the captain's attention is
  spent where it decides something.
  CAPTAIN-REQUIRED tier - implement does NOT start until the captain
  explicitly approves, whenever ANY of these holds:
  1. `GATE-ROUTING` selected `route=captain`, or the second chief's decision is
     `ask-captain`;
  2. the disagreement is captain-owned/mixed, outside approved scope, or
     otherwise not resolved by an R2 `chief-decide` receipt;
  3. the report contains irreversible steps or touches financial paths
     (its risks section is non-empty: migrations, data changes,
     breaking changes, payments/interest);
  4. the captain flagged the task at intake ("gate this for me");
  5. a required second chief could not run (ac-gate exit 3/4);
     unavailability does not change the routing evidence.
  For captain-required gates on substantial tasks, offer the rich path -
  ONE consolidated review page (self-contained HTML reviewed in rich-review)
  that lets the captain decide without asking anything back: the
  `gate-review` skill owns its nine-section spec and the annotate/poll/
  apply loop. "Approve" said in chat or rich-review IS the gate - never
  silence. The captain-required tier is not waived by `+yolo`.
- `+yolo` projects use the same routing matrix; it never falsifies uncertainty,
  consequence, or captain authority. Chief-owned shaky closure after that
  routing may become an intermediate self-approval with a logged note; a
  `route=captain`, the captain-required pre-implement tier, and the PR merge
  still belong to the captain.
- Gate feedback that reopens an earlier stage - hybrid rule:
  SAME-stage revisions RESUME the original crewmate's session when they
  can: `ac-spawn.sh <stage-id>-r2 <project> --scout --resume-from
  <stage-id>` reopens the recorded claude session in a fresh worktree
  (old context intact, cache warm, cheap) and you send the captain's
  feedback VERBATIM plus the revision brief path. Role changes NEVER
  resume. Review rounds also never resume: `ac-verify` launches a fresh
  exact-ref pane and carries only structured finding history. No design session to
  resume (other harness, missing session_id)? Fresh design crewmate briefed
  with the old report + the feedback verbatim. Either way the
  pre-implement gate runs again.

## Execution inputs

Brief execution with every accepted design report linked under `## Inputs`.
