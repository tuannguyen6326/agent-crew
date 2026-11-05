---
name: sdlc
description: SDLC artifact chain: templates, paths, commit order. Use when a brief says Flow: sdlc or on /sdlc.
---

# sdlc

The `sdlc` flow is the staged flow whose record leaves the fleet home: every accepted artifact of a change is committed into the main repository, so the PR carries the code AND its record.
`docs/sdlc-flow.md` in the distro is the authoritative contract (stages, gates, who commits what, acceptance criteria); this skill owns only the templates, the paths, and the order in which a crewmate writes and commits them.

## Paths

The snapshot of one change lives at `docs/features/<feature>/changes/<change>/` in the main repository:

```text
intent.md            what is wanted, why, for which role, for which repositories
spec.md              requirements and design - full on the first change, a delta after
contracts/           only the contract files this change alters, in their new form
plan.md              repositories, order of work, deploy order, rollback, PR list
qa/test-plan.md      written before build
qa/qa-report.md      written after build
```

Every other participating repository carries only `docs/features/<feature>/changes/<change>/plan.md`, from `templates/repo-plan.md`.
`<feature>`, `<change>`, the main repository and the participating repositories come from the brief's `## Inputs`, which quote the accepted `intent.md` - never invent them.
A project may ship its own copy of this skill at `.claude/skills/sdlc/` with other templates or another root; a repo-shipped skill wins over the seeded one, and the shape below the root never changes.
The seeded copy sits where your harness scans skills (`.claude/skills/sdlc/` for claude, `.agents/skills/sdlc/` for codex); reach for it by name, never by path.

## Templates

Copy the template, keep every heading, replace every `<placeholder>`, and delete none of the frontmatter-style lines at the top.
Write every line as a fact of the change: an artifact never quotes the captain, an order, a room receipt or a ruling, names roles rather than people, and carries no fleet identifier and no local fact - no path under a user home, a fleet home, a worktree or `data/<family>`, no digest command, no fleet tool name; the only paths an artifact names are repository-relative - the provenance stays in the family room.
The check is mechanical, run on the artifact files before a report is announced and again before the first commit:

```
grep -rnE '/Users/|/home/|ac-homes|\.crew/|data/[a-z0-9-]+/|shasum|ac-[a-z-]+\.sh' <artifact files>
```

It must print nothing.
The templates:

- `assets/templates/intent.md` - written by the owning chief from the SDLC clarify; the crewmate only commits it.
- `assets/templates/spec.md` - the spec stage; `based_on: none` writes a full spec, anything else a delta.
- `assets/templates/plan.md` - the plan stage, change level.
- `assets/templates/repo-plan.md` - the plan stage, one per participating repository.
- `assets/templates/test-plan.md` - the end of the plan stage.
- `assets/templates/qa-report.md` - the QA verifier's verdict after build.

`status:` moves `draft` -> `accepted` (gate receipt or captain acceptance) -> `implemented` (the code PR is raised) -> `verified` (the QA report passes); only the owner of that step moves it.

## Design stage (report-only crewmate)

You still deliver each stage report at `data/<family>/<stage>/report.md` under the staged design flow's report contract; the gate judges the report.
Beside it you write the ARTIFACT the report produces, from the template, with `status: draft`:

- spec stage: `data/<family>/spec/spec.md`, plus `data/<family>/spec/contracts/<file>` for every contract the change alters;
- plan stage: `data/<family>/plan/plan.md`, one `data/<family>/plan/plan.<repository>.md` per participating repository, and `data/<family>/plan/test-plan.md`.

Write the artifact in the same pass as the report, before you announce the report ready, and end the report with an `## Artifacts` section listing every artifact as `<path relative to the stage dir> <digest>`, where the digest is `grep -v '^status:' <file> | shasum -a 256`: the gate hashes only the report, so that list is what binds each artifact to the acceptance, and the `status:` line is excluded because it is the one line a later owner moves.
You commit nothing and push nothing: your worktree is pooled, and the execution crewmate commits the accepted chain.
The list and the digest rule live in the report only; an artifact never carries them, and the check above runs on every artifact before the report is announced.
A gate revision revises the artifact with the report, and the list with it.
When the main repository is also a code repository, do not write a separate `plan.<main repository>.md`: the main `plan.md` carries that repository's `## Tasks` and `## Departures from plan` sections from `templates/repo-plan.md` after its own sections.

## Execution stage (first commits, then code)

Your `## Inputs` name the accepted reports by absolute path with their `report_sha256`, and each report's `## Artifacts` section names its artifacts with their sha256; read every one before your first commit.
Your branch is the one your brief names (`crew/<family>`): in a single-repo change that is `crew/<change>`; in a multi-repo change each story has its own family and branch, and the snapshot id `<change>` never names a branch.
On that branch in YOUR repository, before any code:

1. Verify each accepted artifact against the digest its report lists, with the same command (`grep -v '^status:' <file> | shasum -a 256`); a mismatch is a `needs-decision:` to your chief, never a copy. Then copy it into the snapshot path and set `status: accepted` - the only edit acceptance authorizes, which the digest ignores by construction.
   Run the local-fact check above on the snapshot directory; a hit means the accepted artifact is wrong at its source, so it is a `needs-decision:` to your chief for a design revision, never a silent edit.
2. Commit them in chain order, one commit per artifact: `intent.md`, then `spec.md` with its `contracts/`, then `plan.md`, then `qa/test-plan.md`.
   In a participating repository that is not the main repository, the chain is only that repository's `plan.md`.
   Commit message shape: `sdlc(<change>): <artifact> accepted at the <stage> gate` - the stage, never the receipt's or the captain's words.
   In a multi-repo change the record story's execution crewmate commits the chain first and then prints `paused: sdlc chain committed @<sha> - resumes when every code story has landed` and pushes it with `ac-done.sh`: that line is the release checkpoint the chief spawns the code stories on, so no code commit anywhere precedes the committed chain; the chief steers it back (`ac-send`) once the code has landed, for the QA report and the live-document sync.
   A code story names that chain sha in its first commit message (`sdlc(<change>): plan.md accepted at the plan gate - chain @<sha>`), never inside the accepted plan, whose bytes stay as accepted.
3. Only then IMPLEMENT with TDD, as the brief's working rules say.

Plan sync: when the implementation departs from `plan.md`, the same commit that departs adds a dated line under `## Departures from plan`; a diff that contradicts the plan with no such line is a review finding.
The review round reads `intent.md`, `spec.md` and your repository's `plan.md` as the expected behavior.
`status: implemented` is set on `plan.md` in the commit that raises the PR.

## After build

The QA verifier runs `qa/test-plan.md` through the `crew-qa` skill and returns its verdict; the record story's execution crewmate writes it into `qa/qa-report.md` from the template, naming the exact `source_sha` of every participating repository, and commits it on the record branch.
A failed case returns to IMPLEMENT; the report is rewritten on the passing round, never appended.
The `document` step then syncs the live documents under `docs/features/<feature>/` that this change made stale - the requirement documents, the technical design, the contracts, the regression cases, under whatever names the project keeps them (the defaults are `PRD.md`, `tech/`, `contracts/`, `qa/regression.md`) - in the same branch.

## Never

- Never commit code before the chain in your repository is committed, and never commit an artifact whose digest (status line excluded) differs from the one its accepted report lists; after acceptance the only authorized edits are the `status:` line and, on `plan.md` after its first commit, the `## Departures from plan` section.
- Never edit a snapshot that has landed: a landed change directory is never rewritten; a correction is a new change with `based_on`.
- Never move `status:` on an artifact you do not own at that step.
- Never infer the main repository or the participating repositories; they come from `intent.md`, which came from the captain.
- Never quote the captain, an order or a receipt inside an artifact or a commit message, and never name a person where a role will do.
- Never write a local path, a fleet-home path, a family data path, a digest command or a fleet tool name into an artifact; those belong to the report and the room.
