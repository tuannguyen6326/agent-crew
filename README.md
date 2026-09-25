# agent-crew

A thread per task. A fleet that ships.

agent-crew is an **agent distro**: a directory of instructions, skills, and bash tooling that turns a terminal coding agent (Claude Code first) into a fleet orchestrator.
There is no app and no build step - the checkout is the product.
Running a supported harness in a fleet home, with `AC_HOME` pointed at that home, IS the installation.
You talk to one crewchief thread, plus one roomchief thread per task family.
Every task is delegated to a disposable crewmate agent in its own git worktree and its own backend pane, supervised by a zero-token bash watcher, and delivered as a reviewed PR, a local merge, or a report.

## Roles

| Role | Job |
|---|---|
| **captain** | You. Approves PRs, answers escalations, owns every irreversible call. |
| **crewchief** | Your fleet-level thread. Triages every order, writes the backlog, promotes families to roomchiefs, and hands real project work to crewmates - its only own code is a visible self-task. |
| **roomchief** | A scoped crewchief owning one task family in its own thread (`bin/ac-spawn.sh --roomchief <family>`). Promoted with `--solo` it is a **solo chief**: for a family too small to cost a crewmate, it works the slices itself through `bin/ac-self-task.sh`, under mandatory independent review. |
| **crewmate** | Disposable worker: one task, one worktree, one pane, then teardown. |
| **pane agent** | One visible, one-shot agent turn in its own pane - runs the independent code reviewer and the QA verifier. Never a crewmate, never a backlog row. |
| **second chief** | An independent model invoked in a fresh session per round for uncertain or high-consequence design gates - advises, never applies. |
| **crewdeputy / crewdomain** | Domain supervision. A crewdeputy runs its own nested fleet home with its own clones and session (isolation); a crewdomain is durable knowledge plus a routed slice of this fleet's backlog (no session). |
| **solo session** | A second session beside the chief (`AC_SOLO=1`, opened with `ac <fleet> --solo`) for pair-coding with the captain one slice at a time. It never spawns, steers, or supervises crew. |

## Prerequisites

- macOS or Linux with `bash`, `git`, and `jq`.
- `gh`, authenticated, for the PR steps.
- A session backend, chosen per fleet in `config/backend`:
  - `herdr` (the default, `brew install herdr`);
  - `orca` (install the Orca app - its CLI ships with it).
- A harness: `claude` (first-class), `codex`, `opencode`, `pi`, or `cursor`; a custom harness is launchable through a `config/launch-<harness>` template.
- Optional: `bun` (web dashboard and review loop), `docker` (crew-qa infra), `node` (QA screenshots), `shellcheck` (opt-in lint).
- `zsh` for the optional `ac` launcher (`docs/examples/ac.zsh`).

`bin/ac-bootstrap.sh` is the toolchain doctor.
It prints one `OK:`/`MISSING:`/`OPTIONAL:` line per tool and exits non-zero when a required tool is missing.
It also enforces a floor table - `git` 2.15.0, `jq` 1.6, `herdr` 0.8.0, and `bun` 1.3.5 (optional tier) - and reports an older build as `BELOW-FLOOR:` or a failed capability probe as `NO-CAPABILITY:`.
Every session start re-runs it.

## Quick start

```bash
git clone https://github.com/tuannguyen6326/agent-crew.git ~/Work/agent-crew
cd ~/Work/agent-crew
bin/ac-setup.sh          # toolchain doctor, homes container, the `ac` launcher (asks before it writes)
source ~/.config/zsh/ac.zsh   # or the path you chose; add it to ~/.zshrc yourself
bin/ac-fleet-new.sh lab  # asks one line per config knob, creates ~/Work/ac-homes/lab
ac lab                   # opens the crewchief on the lab fleet
```

Then tell the crewchief what to do, for example "add project myapp from <git url>" and then "fix the login bug in myapp".

`AC_HOME` is required: the tooling refuses to run without it rather than writing fleet state into the checkout.
The full first-run walk - projects, the first order, watching, landing, and the solo session - is in [docs/getting-started.md](docs/getting-started.md).

## How it works

- **One home per fleet.** A home (`state/`, `data/`, `records/`, `config/`, `projects/`) is whatever `AC_HOME` points at; it symlinks the executable core (`bin/`, `AGENTS.md`, `CLAUDE.md`, `.claude/`) back to the checkout, and all persistent truth lives on disk there.
- **Triage before work.** Every order gets a flow (`direct` or `staged`), a delivery mode (`crew-ship`, `direct-pr`, `feature-pr`, `local-only`), and review/qa obligations, receipted to the family room; heavy choices ask the captain first.
- **Pooled in-repo worktrees.** `bin/ac-tree.sh` leases detached-HEAD worktrees under `<repo>/.crew/worktrees/<n>` and reuses them, so build caches survive between tasks (orca fleets lease Orca-managed worktrees instead).
- **Push-first completion, zero-token watcher.** A finished agent announces itself with `bin/ac-done.sh`; `bin/ac-watch.sh` polls panes in bash and wakes the chief only for actionable events, as durable records in a wake spool.
- **Rooms keep many tasks legible.** Each family has `data/<family>/room.md` holding its triage, gates, asks, and decisions; `bin/ac-room.sh list` is the captain's inbox.
- **Guarded delivery.** `crew-ship` runs an 8-step hold-and-fix pipeline (intent, rebase, review, test, document, lint, push, pr); reviews are exact-ref pane agents; QA is optional behavioral proof after delivery.
- **Fail-closed everywhere.** `bin/ac-teardown.sh` refuses to destroy unlanded work, and harness hooks block a turn that would leave crew in flight unwatched.

The concepts behind each bullet are in [docs/concepts.md](docs/concepts.md).

## Web dashboard

```bash
bin/ac-dashboard.sh      # Bun, no build step -> http://127.0.0.1:8787 (foreground; start|stop|status for a daemon)
```

It shows every fleet's crew, backlog, rooms, artifacts, and config in a browser, and hosts the native rich-review loop (`/review`) and the whiteboard (`/whiteboard`).
It is read-only over task state except a few guarded writes.

## Docs

| Doc | What it covers |
|---|---|
| [docs/getting-started.md](docs/getting-started.md) | The full first-run walk for a user. |
| [docs/concepts.md](docs/concepts.md) | Roles, flows, modes, rooms, gates, and the ideas behind them. |
| [docs/architecture.md](docs/architecture.md) | Components and data flow. |
| [docs/configuration.md](docs/configuration.md) | Every config file, per-project yaml key, and environment variable. |
| [docs/scripts.md](docs/scripts.md) | The map of every `bin/` script; each script's header stays its authoritative spec. |
| [docs/worktrees.md](docs/worktrees.md) | The in-repo worktree pool. |
| [docs/validate-pipeline.md](docs/validate-pipeline.md) | The crew-ship pipeline reference. |
| [docs/qa-attestation.md](docs/qa-attestation.md) | The QA evidence and attestation contract. |
| [docs/staged-design-flow-spec.md](docs/staged-design-flow-spec.md) | Spec/architecture/plan report contracts, stage admission, and gates. |
| [docs/backlog.md](docs/backlog.md) | The `records/backlog.md` grammar. |
| [docs/overview.html](docs/overview.html) | A self-contained visual overview; open it in a browser. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Ground rules, which file owns what, and the dev loop. |
| [AGENTS.md](AGENTS.md) | The chief's law: a ~15 KB index the crewchief follows, pointing into the skills under `.agents/skills/`. `CLAUDE.md` symlinks to it. |

## License

MIT - see [LICENSE](LICENSE).
