# Getting started

This walk takes you from a fresh machine to a first landed task.
It assumes you already use a terminal coding agent such as Claude Code.
You play the **captain**: you give orders and approve outcomes, and the agents do the work.

## 1. Install the toolchain

Clone the distro.
The `ac` launcher in `docs/examples/ac.zsh` hardcodes `~/Work/agent-crew` and `~/Work/ac-homes`, so those paths need no edits:

```bash
git clone https://github.com/tuannguyen6326/agent-crew.git ~/Work/agent-crew
cd ~/Work/agent-crew
bin/ac-bootstrap.sh
```

`bin/ac-bootstrap.sh` is the toolchain doctor.
It prints one line per tool:

| Prefix | Meaning |
|---|---|
| `OK:` | Present and usable. |
| `MISSING:` | A required tool is absent - exit status 1. |
| `NEEDS_GH_AUTH:` | `gh` is installed but not authenticated; run `gh auth login`. |
| `OPTIONAL:` | An optional tool is absent, with what it would unlock. |
| `BELOW-FLOOR:` | Present, but older than the floor the fleet's code targets. |
| `NO-CAPABILITY:` | At or above the floor, but the one capability probe the fleet relies on failed. |
| `INERT:` | A newer copy sits later on `PATH` than the one that answers; diagnostic only. |

Required: `git` (floor 2.15.0), `jq` (floor 1.6), `gh`, and the CLI of the fleet's configured session backend - `herdr` (floor 0.8.0, the default) or `orca`.
Optional: `bun` (floor 1.3.5; the web dashboard), `node`, `docker`, `shellcheck`.
Pass `--quiet` to print problems only.

## 2. Set up the machine once

```bash
bin/ac-setup.sh
```

`bin/ac-setup.sh` is interactive and asks one line per decision; an empty answer takes the shown default.
It runs, in order:

1. the toolchain doctor;
2. an offer to install `herdr` and `wezterm` when they are absent (every install defaults to no);
3. the homes container, default `~/Work/ac-homes` (or `$AC_HOMES_CONTAINER`);
4. the `ac` launcher, copied from `docs/examples/ac.zsh` to a path you choose (default `~/.config/zsh/ac.zsh`).

It never edits your dotfiles.
Add the printed `source` line to `~/.zshrc` yourself, then `exec zsh`.
Re-running it is how you update an installed launcher.

## 3. Create a fleet home

A fleet home is the directory `AC_HOME` points at: its `state/`, `data/`, `records/`, `config/`, and `projects/` hold all of the fleet's persistent truth.
Run one fleet per domain of work.

```bash
bin/ac-fleet-new.sh lab
```

It refuses to overwrite an existing home, then asks one line per knob.
An empty answer writes no file, and the reader's default applies:

| Knob | Asks for | Default when empty |
|---|---|---|
| `captain` | The name the crewchief calls you. | "captain" |
| `model` | Fleet-wide crewmate model. | The harness picks. |
| `effort` | `low`, `medium`, `high`, `xhigh`, `max`, or `ultracode`. | The harness picks. |
| `gate-agent` | Design-gate judge engine: `codex`, `claude`, or `off`. | `codex` |
| `gate-model`, `gate-effort` | The judge's model and effort. | The engine picks. |
| `promote` | Roomchief promotion: `always`, `auto`, or `never`. | `always` |
| `flow` | Task flow: `auto`, `direct`, or `staged`. | `auto` |

It also asks whether to seed a per-fleet `CREWMATE.md` from `docs/examples/CREWMATE.md`.
It writes `config/backend` as `herdr`; set it to `orca` to run the fleet on Orca instead.
It seeds empty `records/projects.md` and `records/backlog.md`, and symlinks `bin/`, `AGENTS.md`, `CLAUDE.md`, and `.claude/` from the checkout into the home.
Every knob and its full meaning is in [configuration.md](configuration.md).

`AC_HOME` is required.
Without it the tooling refuses by name, so fleet state never lands in the checkout.

## 4. Start the crewchief

```bash
ac lab
```

The launcher runs your harness with its working directory set to the home and `AC_HOME` exported:

- On a `herdr` fleet it starts the herdr server if needed, opens the chief in a herdr tab, and attaches the herdr UI.
- On an `orca` fleet, or when you are already inside herdr, it runs the chief inline in the current terminal.

Useful launcher forms:

| Command | Effect |
|---|---|
| `ac` | Prints usage with your fleet names. |
| `ac lab --harness=codex` | Runs a different harness (default `claude`). |
| `ac lab --backend=orca` | Overrides the home's `config/backend` for where the chief opens. |
| `ac lab --solo` | Opens a solo session (section 10). |
| `ac dashboard` | Runs the web dashboard. |

Without the launcher, the equivalent is:

```bash
cd ~/Work/ac-homes/lab && AC_HOME="$PWD" claude
```

## 5. Run the session-start digest

The crewchief's first act every session is `bin/ac-session-start.sh`; on Claude Code a SessionStart hook reminds it.
The digest acquires the home's session lock, re-runs the toolchain doctor, drains queued wakes, and prints the fleet view, the backlog head, the project registry, and the supervision block.
When another live session already owns the home, the digest degrades to read-only and skips the drain.
Any `MISSING:`, `BELOW-FLOOR:`, or `NO-CAPABILITY:` line means fix the toolchain before anything is spawned.

## 6. Add a project

Tell the crewchief, for example:

> Add project myapp from https://github.com/example/myapp.git

The crewchief clones it into `projects/myapp` and registers one line in `records/projects.md`:

```markdown
- myapp - Customer-facing web app (added 2026-09-25)
```

The grammar is `- <name> [+yolo] - <one-line description> (added <date>)`.
`+yolo` lets the chief self-approve routine decisions for that project; it never waives your merge approval or a captain-required gate.
Do not pre-clone: the chief clones on your word.

Delivery mode is not a project property.
It is chosen per task at intake (section 7).

The `crew-ship` pipeline and QA read a per-project config at `projects/<name>.yaml` in the home, never in the product repo.
`docs/examples/project-config.yaml` shows its shape: test, lint, and format commands, auto-fix budgets, and the `qa:` block.
You do not have to write it: the task agent drafts a proposal (`bin/ac-qa.sh config-proposal`) and the chief installs it (`bin/ac-qa.sh config-install`).

## 7. Give a first order

Say what you want in plain words:

> Fix the login bug in myapp - the session cookie is dropped on redirect.

What the crewchief does, in order:

1. **Requirements check.**
   It drafts the deliverable, acceptance checks, boundary, and the authority for every decision.
   Anything it would have to guess becomes one bundled question to you; too many guesses and it proposes `/brainstorm` instead.
2. **Knowledge and overlap reads.**
   It recalls what the fleet already verified about the codebase (`bin/ac-know.sh recall`) and checks for in-flight work on the same files (`bin/ac-ready.sh overlap`).
3. **Triage.**
   It picks the flow (`direct` or `staged`), the delivery mode (`crew-ship`, `direct-pr`, `feature-pr`, or `local-only`), and whether review and QA are owed.
   The heavy values - `flow:staged`, `mode:crew-ship`, `qa:yes`, and a discretionary review - need your confirmation first, asked once with the reason.
4. **Receipt.**
   It records a backlog row in `records/backlog.md` and posts a `TRIAGE:` line with the why to the family room, `data/<family>/room.md`.
5. **Promotion.**
   By default (`promote=always`) the family gets its own roomchief thread, capped at `config/room-parallel` (default 5); the roomchief takes over steps 6-8 for that family.
6. **Brief.**
   `bin/ac-brief.sh` scaffolds the brief with the task, constraints, acceptance criteria, and recorded mode.
7. **Spawn.**
   `bin/ac-spawn.sh` leases a worktree (`<repo>/.crew/worktrees/<n>` on herdr, an Orca-managed worktree on orca) and launches the crewmate harness on the brief in its own pane.
8. **Supervise.**
   `bin/ac-watch.sh` runs as a background task of the harness, polls panes in bash, and wakes the chief only for actionable events; on Claude Code a Stop hook keeps it armed.
   A finished crewmate announces itself with `bin/ac-done.sh`.

To pin a flow yourself, use `/order-direct`, `/order-staged`, or `/order-design` with your order.

## 8. Watch the work

| Where | What you see |
|---|---|
| Your chief thread | Receipts, questions, and outcomes in chat. |
| The herdr sidebar | One workspace per task family, labelled `<fleet> · <family>`, holding its chief, crewmates, and verifier panes. |
| `bin/ac-room.sh list` | Every room; `PENDING` rooms hold a gate or ask waiting on you. |
| `bin/ac-room.sh show <family>` | The family's full narrative. |
| `bin/ac-fleets.sh` | A read-only survey of every fleet under the homes container. |
| `bin/ac-dashboard.sh` | The web dashboard at `http://127.0.0.1:8787` (needs `bun`); `start`, `stop`, and `status` run it as a daemon. |

Run the `bin/` commands from the home (`AC_HOME` set), or just ask the chief.
When a crewmate needs you, the question comes through the chief (or the family's roomchief) with the options and a recommendation.
Answer in its thread; the room records your answer as `DECIDED:`.

## 9. Review, land, and tear down

Before anything merges, the chief reviews the delivered change with `bin/ac-review-diff.sh <id>`.
Review rounds, when owed, run as independent exact-ref pane agents; a `fix` verdict loops back to the crewmate, and an `ask-user` verdict comes to you.

Landing depends on the mode:

| Mode | How it lands |
|---|---|
| `local-only` | The chief merges `crew/<id>` into the project's local default branch with `bin/ac-merge-local.sh <id>` (fast-forward only unless `--no-ff`); never pushed. |
| `direct-pr` | The crewmate pushes and opens a PR after a docs pass; you approve and merge. |
| `crew-ship` | The crewmate runs the 8-step `crew-ship` pipeline, which ends in a PR; never merge one whose run did not reach `checks-passed`. |
| `feature-pr` | Members land locally on a recorded feature branch, which ships once as one PR per repo via `bin/ac-feature.sh ship`. |

For PR modes the chief records the PR with `bin/ac-pr-check.sh <id> <url>`, and after your approval can merge it with `bin/ac-pr-merge.sh <id> <url>` (squash by default).
Whether a verified local-only land waits for your approval per merge is a standing rule you record in `records/captain.md`.

`bin/ac-teardown.sh <id>` then ends the task: it archives the task state, closes the pane, returns the worktree to the pool, and deletes a merged `crew/<id>` branch.
It is fail-closed: it refuses while the work is unlanded or the worktree is dirty.
A PR task does not have to wait for the merge: when the PR is ready, your acceptance lands it through `--pr-ready '<your words>'`.
`--force` means you are explicitly discarding the work.

At landing the chief also records the run's lessons (`bin/ac-learn.sh note`) and verified repo facts (`bin/ac-know.sh add`), moves the backlog row to `## Done`, and closes the room once its inbox is empty.

## 10. Pair-code in a solo session

When you want to write code yourself alongside an agent, open a solo session beside the chief:

```bash
ac lab --solo
```

It runs in the current terminal with `AC_SOLO=1`, never takes the chief's session lock, and runs the session-start digest read-only.
It never spawns crew, steers panes, drains wakes, arms watchers, or answers gates - those stay with the chief.
To hand crew work to the chief from a solo session, use `bin/ac-remote.sh order '<text>'`.

Each slice of code goes through one command:

```bash
bin/ac-self-task.sh start <id> <project> [--mode <m>] [--harness <h>]
bin/ac-self-task.sh log <id> '<progress line>'
```

`start` leases a worktree, seeds the crewmate instructions into it, opens a pane tailing the progress log, and records the slice as a task every fleet view lists.
The default mode is `local-only`, which lands with `bin/ac-merge-local.sh <id>`; pass a PR mode to land through a PR instead.
`bin/ac-teardown.sh <id>` refuses to close a solo slice until its knowledge loop exists: a lesson, a repo fact, and a `## Done` row.
Waive the first two on the record with `--no-lesson '<why>'` or `--no-fact '<why>'`; the Done row is never waived.

## Where to go next

- [concepts.md](concepts.md) - flows, modes, rooms, gates, and roles in depth.
- [architecture.md](architecture.md) - components and data flow.
- [configuration.md](configuration.md) - every config knob and environment variable.
- [scripts.md](scripts.md) - the map of every `bin/` script.
- [worktrees.md](worktrees.md) - the worktree pool.
- [validate-pipeline.md](validate-pipeline.md) - the `crew-ship` pipeline.
- [qa-attestation.md](qa-attestation.md) - QA evidence and merge attestation.
- [staged-design-flow-spec.md](staged-design-flow-spec.md) - the staged design reports and gates.
- [backlog.md](backlog.md) - the backlog grammar.
- [AGENTS.md](../AGENTS.md) - the law the crewchief follows.
