---
name: project-management
description: Crewchief fleet-level project lifecycle judgment - add, clone, create, initialize, change the +yolo posture of, retire, or remove a project registered in records/projects.md. Load before any such lifecycle action. Removal is destructive and always requires explicit captain confirmation after the exact target and its unlanded-work preflight are resolved. Does not own per-task delivery-mode triage (AGENTS.md section 4) or CrewDeputy home clones (CrewDeputy provisioning and convergence own them).
---

# project-management

Judgment for the fleet-level lifecycle of a registered project: add, clone, create, initialize, change the `+yolo` posture of, retire, or remove it.
The registry format, the parser, and every command belong to `records/projects.md` and the `bin/ac-project-mode.sh` header; this skill owns only the lifecycle judgment and its consent and destructive-action boundaries.

## When to load - and what this skill does NOT own

Load before adding, cloning, creating, initializing, changing the `+yolo` posture of, retiring, or removing a registered project.

Out of scope - keep these with their owners:

- delivery-mode choice entirely: mode is PER-TASK - the row's contract pin / `--mode` at intake, `AGENTS.md` sections 4-5; the registry answers `+yolo` only;
- CrewDeputy home clones stay part of CrewDeputy provisioning and convergence (`bin/ac-home-seed.sh`, `bin/ac-spawn.sh --crewdeputy`), not this skill's lifecycle judgment.

## Prime directive still binds

Loading this skill never widens your authority over `projects/`.
You stay read-only over `projects/` except the sanctioned writes (`git fetch`, `bin/ac-tree.sh` pool operations, `bin/ac-merge-local.sh` fast-forwards, teardown branch deletion).
You never edit project files, run project builds, or commit project work - that is delegated to a crewmate.

## Add and clone

`records/projects.md` and the `bin/ac-project-mode.sh` header remain the authoritative registry format and parser contract.
Before adding a project, resolve: the source or creation intent; the unused local name and destination; the `+yolo` posture only when explicitly requested; and whether the repo carries an origin remote (a remoteless repo can only ever take `local-only` tasks).

- Clone existing projects into `projects/<name>` only after confirming the destination is unused.
- Treat the clone and the `records/projects.md` entry as one operation from the captain's perspective - a clone with no registry line, or a line with no clone, is a half-done add.
- If a later setup step fails, report the exact partial state and roll back only the artifacts that incomplete operation created, and only when rollback is safe and authorized.
- Never overwrite, repurpose, or silently adopt an existing path.

## Create (remote repository) - outward-facing consent

Creating a remote repository is outward-facing and needs explicit captain consent first.

- Before remote creation, the captain must approve the repository name, the owner or organization, and the visibility.
- Visibility defaults to private when the captain has not selected one.
- Use the currently installed approved GitHub tooling and consult its live help before constructing the operation - do not hard-code flags from memory.
- A local-only project may be initialized locally under an unused path with no remote when that is what the captain ordered.
- Do not create an unrelated commit merely to record tool setup.

## Mode changes and retirement

- The registry carries NO delivery mode: a task's mode lives on its backlog row (contract pin) or its brief - never write one into `records/projects.md`. Change `+yolo` only when the captain changes the project's standing posture.
- Project removal is destructive and always requires explicit captain confirmation, after the exact target is resolved. Never infer the target from an ambiguous name.
- Before removal, inspect for unlanded evidence: live and archived task state; queued backlog work; open rooms and gates; CrewDeputy project ownership; linked worktrees; dirty files; unpushed commits; branches; open or unmerged pull requests; and any other unlanded work.
- If a dependency or unlanded work exists, stop and report it before touching the registry or the clone.
- Agent Crew has no guarded project-removal helper. Expose that implementation gap to the captain rather than reaching for an unguarded recursive deletion command; a removal that cannot be done safely is a `needs-decision:`, not a `rm -rf`.
- `/debrief` may RECORD an already completed project lifecycle change, but never performs project creation, removal, or `+yolo` mutation as cleanup.
