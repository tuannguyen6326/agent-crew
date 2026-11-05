# SDLC Flow Specification

Status: Accepted
Date: 2026-10-29

## Problem

The staged flow produces spec, architecture and plan reports, but they live in the fleet home.
The project repository keeps no record of what was asked, what was decided, how it was planned, or how it was proven.
An AI-native SDLC ends every stage by committing an artifact the next stage reads, so the chain of commits is the audit trail.
The fleet needs a flow whose output is the code AND that record, in the project repository, inside the same change.

## Objective

Define the `sdlc` flow: the staged flow plus an artifact chain committed into the main repository.

The flow must:

- reuse the staged flow's stages, gates, receipts, review and QA machinery unchanged;
- make intent, spec and plan mandatory, and architecture evidence-admitted as in staged;
- commit every accepted artifact into the main repository under one change directory;
- carry one plan per participating code repository, committed in that repository;
- keep the live feature documents in sync when a change lands, without rewriting the snapshot;
- serve a product that is one repository and a product that spans several with the same artifact shape.

## Non-Goals

- Replace or alter the direct, staged, epic or feature-pr flows.
- Validate service contracts, generate the live requirement documents, or diagnose incidents in version 1.
- Add a feature registry to the fleet home; the intent artifact names the repositories.
- Deploy or roll back anything; the plan records the order and the rollback path, people run them.
- Change who merges: the captain merges every PR, in the order the plan records.

## Definitions

- **Feature**: a product capability with a directory of live documents in the main repository, `docs/features/<feature>/`.
- **Change**: one unit of work on a feature, identified by `<YYYY-MM-DD>-<slug>`, which is also its backlog family id.
- **Main repository**: the one repository that holds the feature's live documents and every change snapshot.
  The captain names it at intake, never the chief by inference.
- **Participating repository**: a code repository the change modifies.
  The main repository may be one of them.
- **Single-repo product**: the main repository is the only participating repository, so the record and the code ride one branch and one PR.
- **Multi-repo product**: the change is an epic whose stories are one record story on the main repository and one code story per participating repository.
- **Artifact chain**: the ordered files of one change snapshot, `intent.md`, `spec.md`, `contracts/`, `plan.md`, `qa/test-plan.md`, `qa/qa-report.md`.
- **Record branch**: the crew branch on the main repository that receives every accepted artifact of the chain: `crew/<change>` in a single-repo change, the record story's own `crew/<family>` in a multi-repo change. The change id names the snapshot directory, never a branch; every crewmate commits on the branch its brief names.
- **Live documents**: the feature's documents that stay current across changes, beside `changes/`: the requirement documents (business and product), the technical design, the service contracts, the regression cases and the incident records. Their file names are the project's own; the layout below shows the default names the `sdlc` skill assumes, and a project's `.claude/skills/sdlc/` override may rename or drop any live document, never a snapshot file.
- **Snapshot**: the change directory, written while the change runs and never rewritten after it lands.
- **based_on**: the earlier change a delta spec builds on, named in `intent.md`; the first change of a feature carries none and writes a full spec.

## Repository layout

Main repository (the live documents carry the default names; the snapshot names are fixed):

```text
docs/features/<feature>/
  BRD.md                         live, business requirement
  PRD.md                         live, problem, users, requirements, compliance, acceptance criteria
  tech/architecture.md           live
  tech/db.md                     live
  qa/regression.md               live
  contracts/<name>.yaml|md       live service contracts
  incidents/<date>-<slug>.md     post-mortem and lessons
  changes/<change>/
    intent.md                    what is wanted, why, for which role, for which repositories
    spec.md                      requirements and design, full for the first change, a delta after
    contracts/                   only the contract files this change alters
    plan.md                      repositories, order of work, deploy order, rollback, PR list
    qa/test-plan.md              written before build
    qa/qa-report.md              written after build
```

Each participating code repository that is not the main repository:

```text
docs/features/<feature>/changes/<change>/plan.md
```

A project may pin a different root than `docs/features` in its `.claude/skills/sdlc/` override; the shape below the root never changes.

## Core Flow

```text
intake: the SDLC clarify (captain answers)
        |
        v
intent.md  -> captain accepts (DECIDED:)
        |
        v
one design crewmate (report-only; artifacts written beside the reports)
        +-- spec (+ contracts/) -> inline self-review -> stage gate
        +-- architecture        -> inline self-review -> stage gate -> folded into spec.md
        +-- plan (+ repo plans, test-plan) -> inline self-review -> pre-implement gate
        |
        v
one execution crewmate per participating repository
        first commits: the accepted chain, one commit per artifact, before any code
        (multi-repo: the record story commits the chain, pauses at the release
         checkpoint, and only then are the code stories spawned; a repository
         that is not the main one commits only its own plan.md)
        TDD, plan sync, review against intent, spec and plan, ship, PR
        |
        v
QA verifier runs qa/test-plan.md -> qa/qa-report.md committed on the record branch
        |
        v
document step syncs the live documents on the record branch -> record PR
        |
        v
captain merges the PRs in the plan's deploy order
```

## Intake: the SDLC clarify

The requirements check of the `intake-triage` skill grows one mandatory bundled ask for every `sdlc` order, put to the captain before `intent.md` is drafted.
The ask is read before it is asked: the chief first recalls what the fleet and the main repository already record, so the captain confirms and corrects instead of answering from nothing.

Before the ask, the chief reads:

- `bin/ac-know.sh recall` and `bin/ac-brain.sh recall` by the feature's name and the order's subject, as every intake does;
- in the main repository, when `docs/features/<feature>/` already exists, the latest change's `intent.md` and `plan.md`: they name the main repository, the participating repositories and the feature, and that change is the default `based_on`;
- the order itself, for the ticket and the slug.

Every item the read answers is put to the captain as a statement with its source, to confirm or correct; only an item nothing answers is an open question.
The chief never infers an answer: reading a record is a citation, guessing is not, and a captain's correction outranks any record.

The ask names:

- the main repository, by its name in `records/projects.md`;
- every participating repository, so the chief knows whether the change is single-repo or multi-repo;
- the feature, as the directory name under `docs/features/`;
- the change slug, so the family id `<YYYY-MM-DD>-<slug>` is minted from the captain's word;
- the earlier change this one builds on, or none;
- the external record, such as a ticket id, or none.

The answers are recorded `DECIDED:` in the family room, each with its source (the record read or the captain's word); `intent.md` then states each one as a fact of the change, never as a quotation - the artifact contract below owns that rule.

Single-repo: the family is one staged family on the main repository; the record branch is the crew branch, and the code PR carries the chain.

Multi-repo: the family is an epic.
The record story targets the main repository and owns the record branch.
Each code story targets one participating repository and carries that repository's `plan.md` as its first commit.
The release checkpoint for the code stories is the record branch holding the committed pre-build chain: the record story's execution crewmate commits the chain first, then prints `paused: sdlc chain committed @<sha> - resumes when every code story has landed`, and the owning chief spawns the code stories on that line and nothing earlier.
Code stories are blocked by each other only where the plan records an ordering edge.
The scheduler blocks on landed stories, so the record story is never a `blocked-by` of a code story: it needs the built code to finish its QA report, and the chief steers it back once the code has landed.

## Artifact contract

Every artifact is a markdown file written from the template of the `sdlc` crew skill, or from the project's `.claude/skills/sdlc/` override when one exists.
Every artifact states its content as a fact of the change: it never quotes the captain, an order, a room receipt or a dated ruling, it names roles rather than people, and it carries no fleet identifier and no local fact (family ids, receipts, paths under a user home, a fleet home, a worktree or the family's data dir, digest commands, fleet tool names) - the only paths it names are repository-relative; the provenance of every statement stays in the family room, where `DECIDED:` and the gate receipts cite the captain's word.
The `sdlc` skill carries the mechanical check for it, run before a report is announced and again before the first commit.
Every artifact carries a `status:` line and the Trace IDs of the staged design flow, so `spec.md` traces to `intent.md` lines and `plan.md` tasks trace to spec requirements.

### intent.md

Mandatory.
Written by the owning chief from the SDLC clarify, as the PO step of the `intake-triage` skill writes `requirements.md`; in this flow the file is `data/<family>/intent.md`, and the execution crewmate commits it into the snapshot as the first commit of the chain.
Content: the external record, the feature, the main repository, the participating repositories, the problem, the proposed outcome, the affected users and systems, the constraints, `based_on`, the open questions, and `status: draft|accepted`.
Gate: the captain's live acceptance, recorded `DECIDED:`.
No design stage starts before `intent.md` is accepted.

### spec.md and contracts/

Mandatory.
Produced by the design crewmate's spec stage under the staged design flow's spec contract.
The first change of a feature writes the full requirements and design.
A later change writes a delta against `based_on`: what changes, what stays, and why.
A contract the change alters is copied into `contracts/` in its new form, and only an altered contract appears there.
Gate: the staged flow's stage gate and routing matrix.
An architecture stage, when admitted, delivers its report under the staged contract; its accepted content is folded into `spec.md`'s design section and, at landing, into `tech/`.

### plan.md

Mandatory.
Produced by the design crewmate's plan stage under the staged design flow's plan contract, with these additions.
The main plan names every participating repository, the order of work across them, the deploy order, the rollback path per repository, and the PR each repository will raise.
Each participating repository that is not the main repository receives its own `plan.md` holding only that repository's tasks, files, tests and TDD shape, referencing the main plan by path; a main repository that is also a code repository folds those sections into the main plan instead.
Gate: the three-tier pre-implement gate of the `staged-gates` skill, judged on the main plan.

### qa/test-plan.md

Mandatory, written before build.
The design crewmate writes it at the end of the plan stage from the spec's acceptance criteria and the plan's tasks: one test case per acceptance criterion, the profile it runs under, and the evidence that proves it.
Gate: the captain accepts it together with the plan, at the pre-implement gate.
It is committed on the record branch by the record story's execution crewmate before the release checkpoint, so no code story commits before it.

### Build

One execution crewmate per participating repository, briefed as the staged execution stage is.
Its first commit is that repository's `plan.md`, so the plan is in the branch before any code.
When implementation departs from the plan, the same commit updates `plan.md`; a plan the diff contradicts is a review finding.
The review round reads `intent.md`, `spec.md` and the repository's `plan.md` as the expected behavior, so a compliance finding cites them.
Delivery follows the mode the row pins, crew-ship included.

### qa/qa-report.md

Written after build by the QA verifier of the `crew-qa` skill, run against `qa/test-plan.md`.
The verdict, the evidence per test case and the source SHA per repository are written into the report and committed on the record branch.
A failed case loops to the owning execution crewmate; the report is rewritten when the round passes.

### Live document sync

The `document` step of the record story updates the live documents the change makes stale: the requirement documents, the technical design, the contracts, the regression cases.
The snapshot is never edited by this step.
The record PR carries the snapshot and the live document updates together.

## Who commits what

- The owning chief writes the accepted `intent.md` beside the family room; the chief itself never writes a project repository.
- The design crewmate writes each artifact beside its stage report in the family dir and lists it, with its digest, in the report's `## Artifacts` section: the gate hashes only the report, so that list is what binds the artifact to the acceptance. The digest covers every byte but the `status:` line (`grep -v '^status:' <file> | shasum -a 256`), because that line is the one a later owner moves. It commits nothing, because its worktree is pooled and the family branch belongs to the execution crewmate.
- The execution crewmate of the record branch verifies each artifact against the digest its accepted report lists and runs the local-fact check on the snapshot, sets `status: accepted`, then commits the accepted chain, one commit per artifact in chain order, before any code: the chain is in git before the first line of implementation, and each commit names the stage whose gate accepted its artifact, never the receipt's text. A digest mismatch is a `needs-decision:`, never a commit. After acceptance the only authorized edits are the `status:` line and, on `plan.md`, the `## Departures from plan` section.
- Each execution crewmate of another participating repository commits that repository's `plan.md` first, then its code and tests, on its own crew branch.
- The QA verifier's report is committed by the record story's execution crewmate.
- Every push and PR follows the row's mode; the captain merges.

## Gate and authority

- `flow:sdlc` is a heavy token: it needs the captain's word or a row pin, exactly as `flow:staged`.
- Review is mandatory, as in staged; `rev:no` with `flow:sdlc` is a contract lint violation.
- `intent.md` and `qa/test-plan.md` are captain gates; `spec.md` and `plan.md` follow the staged gate matrix.
- Product, behavior, scope, financial and irreversible decisions stay the captain's; a chief or second chief never substitutes.

## Acceptance Criteria

### SDLC-AC-01: Record in the repository

A landed change leaves the full artifact chain under `docs/features/<feature>/changes/<change>/` in the main repository, and a `plan.md` under the same path in every other participating repository.

### SDLC-AC-02: Clarify before intent

No `intent.md` exists for a change whose room carries no `DECIDED:` naming the main repository and the participating repositories.

### SDLC-AC-03: Accepted before committed

Every artifact on the record branch has a gate receipt or a `DECIDED:` acceptance older than its commit, and its digest with the `status:` line excluded equals the one listed in the accepted report that produced it; the later `## Departures from plan` lines of `plan.md` are the one authorized addition.

### SDLC-AC-04: Chain before code

In every participating repository, every commit of the accepted chain precedes the first code commit of the change's crew branch, and a non-main repository's first commit adds its `plan.md`.

### SDLC-AC-05: Plan sync

A merged diff that departs from `plan.md` carries the plan update in the same commit, or the review round reported the departure.

### SDLC-AC-06: Test plan before build, report after

`qa/test-plan.md` is committed on the record branch before the first code commit of any participating repository, and `qa/qa-report.md` names the source SHA of every participating repository at the passing round.

### SDLC-AC-07: Snapshot immutability

No commit after the record PR merges touches files under the change directory.

### SDLC-AC-08: One shape, two use cases

A single-repo change and a multi-repo change produce the same artifact chain; the only difference is how many crew branches and PRs carry it.

## Assumptions

- The captain plays product owner, tech lead and QA approver; crewmates draft, the captain accepts.
- The main repository is registered in `records/projects.md` before the first `sdlc` order on it.
- The `sdlc` crew skill holds the artifact templates and is seeded into every crew worktree like the other crew skills.
- Version 1 treats `contracts/` as plain files of the spec stage and leaves `incidents/` to a later change.
