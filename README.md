# agent-crew

A thread per task. A fleet that ships.

agent-crew is an **agent distro**: a portable directory of instructions, skills, and bash tooling that turns a terminal coding agent (Claude Code first) into a fleet orchestrator.
You command it through threads: one fleet-level crewchief, plus a roomchief thread per promoted task family.
Every task is delegated to disposable crewmate agents, each in its own herdr tab and its own git worktree, supervised by a zero-token watcher, delivering reviewed PRs, local merges, or reports.
There is no app and no build step - the checkout is the product.

## The crew

| Role | Job |
|---|---|
| **captain** | You. Approves PRs, answers escalations, owns every irreversible call. |
| **crewchief** | Your fleet-level thread. Triages orders, promotes families to roomchiefs, merges nothing without your word. |
| **roomchief** | A scoped crewchief owning one promoted task family in its own thread (`ac-spawn.sh --roomchief <family>`). |
| **crewmate** | Disposable worker: one task, one in-repo worktree, one herdr tab, then teardown. |
| **pane agent** | One visible agent turn in its own tab - runs the independent code reviewer and the QA agent. |
| **second chief** | Independent model invoked for uncertain or high-consequence design decisions in one fresh session per round - advises, never applies. |
| **crewdeputy / crewdomain** | Domain supervision: a deputy runs its own nested fleet home (isolation); a domain is durable backlog + knowledge state inside this fleet (no session). |

## Prerequisites

- macOS or Linux with `bash` and `git`
- `herdr` - the session backend (`brew install herdr`); nothing spawns without it
- `jq`, and `gh` (authenticated) for the PR steps
- A harness: Claude Code first-class; `codex` and `opencode` are supported crewmate harnesses
- Optional: `bun` (web dashboard), `docker` (crew-qa infra), `node` (QA screenshots), `shellcheck` (lint)

`bin/ac-bootstrap.sh` is the toolchain doctor - it re-checks all of this any time.

## Quick start

```bash
git clone https://github.com/tuannguyen6326/agent-crew.git && cd agent-crew
bin/ac-fleet-new.sh lab                       # creates ~/Work/ac-homes/lab
AC_HOME=~/Work/ac-homes/lab claude            # or your harness - AGENTS.md is the operating manual it reads
```

The checkout is the tooling, never the home: `AC_HOME` is required, and the tooling refuses by name rather than writing fleet state into the checkout.
Then, to the crewchief:

1. "Add project myapp" - it clones into `projects/myapp` and registers it in `records/projects.md`.
2. "Fix the login bug" - it writes a brief, spawns a crewmate in `projects/myapp/.crew/worktrees/1`, and supervises.
3. The crewmate validates through the crew-ship pipeline and opens a PR; you approve; the crewchief merges and tears down.

To run SEVERAL fleets - each its own home, backlog and crew - set the machine up once and add a fleet per domain:

```bash
bin/ac-setup.sh          # toolchain doctor, homes container, the `ac` launcher
bin/ac-fleet-new.sh lab  # asks one line per config knob, then: ac lab
```

Both are interactive captain tools and ask before they write.

## Web dashboard

```bash
bin/ac-dashboard.sh          # Bun, no build step -> http://127.0.0.1:8787
```

Every fleet's processes, backlog, artifacts, review sessions, whiteboards, records, domains, learning and config in a browser - read-only except a few guarded writes.
It also hosts the native rich-review loop: the captain pins comments onto an HTML or markdown artifact at `/review`, the agent receives them over a blocking poll (`bin/ac-review.sh`), and mermaid diagrams open in an embedded Excalidraw editor.
Screenshots live in `docs/overview.html` (the visual overview).

## How it works

```
captain (you)
   │ talks to
crewchief (harness on a fleet home)   state/ data/ records/ = truth on disk
   │ promotes & routes                herdr panes           = message bus
roomchiefs (one per task family)
   │ brief, spawn & supervise
crewmates (one herdr tab + one in-repo worktree each)
   │ validate via crew-ship pipeline
PRs / local merges / reports

flows (picked per order):
  direct:  chief -> execution (IMPLEMENT + DELIVERY)
  staged:  chief -> design (spec + architecture + plan, gated) -> execution
  epic:    order -> story map (gated) -> stories, push-scheduled
  review:  required for staged and crew-ship; optional for direct-pr/local-only
  qa:      optional behavioral proof after delivery; gates merge, not push
```

- **One home per fleet**: a home (`state/`, `data/`, `records/`, `config/`, `projects/`) is whatever `AC_HOME` points at, one per domain under a container. It is REQUIRED - unset is refused, never silently this checkout. `bin/ac-fleet-new.sh` creates one; the `ac` launcher opens it.
- **Worktrees in-repo**: `bin/ac-tree.sh` pools detached-HEAD worktrees under `<repo>/.crew/worktrees/<n>`, auto-gitignored; returning resets and reuses instead of deleting, so build caches survive between tasks.
- **Push-first completion**: a finished agent announces itself with `bin/ac-done.sh` - one durable wake record plus a nudge that ends the watcher's poll wait - so the orchestrator wakes in milliseconds. The watcher stays as the backup that catches an agent which crashed or forgot.
- **Zero-token watcher**: `bin/ac-watch.sh` polls panes in bash, absorbs noise, and wakes the chief only for actionable events - published durably to `state/.wake-spool/`, one file per record, one spool per consumer scope.
- **Rooms keep many tasks legible to one captain**: every task family gets `data/<family>/room.md` - gates, escalations and decisions on the record rather than lost in chat; `bin/ac-room.sh list` is the captain's inbox.
- **Design reports are risk-routed**: the chief records `GATE-ROUTING` for every report; uncertainty or high consequence invokes one fresh second-chief agent, clear low-risk work stays chief-owned, and captain-owned choices go directly to the captain. Invoked R1/R2 rounds are hash-bound to the same decision context the chief has.
- **Fail-closed everywhere**: `bin/ac-teardown.sh` refuses to destroy unlanded work; a Stop hook blocks any turn that would leave crew in flight unwatched; merge helpers can require a passing QA attestation.
- **Validation pipeline**: crewmates run the `crew-ship` skill - 8 hold-and-fix steps (intent, rebase, review, test, document, lint, push, pr) executed agent-side with durable state in `<repo>/.crew/ship/`.

## Docs

- `AGENTS.md` - the operating manual (what the crewchief actually follows); `CLAUDE.md` symlinks to it.
- `docs/overview.html` - self-contained animated visual overview (open in a browser, or review with `/rich-review`).
- `docs/architecture.md` - components and data flow.
- `docs/scripts.md` - the map of every `bin/` script; each script's own header stays its authoritative spec.
- `docs/configuration.md` - every config file and env var.
- `docs/worktrees.md` - the in-repo worktree pool.
- `docs/validate-pipeline.md` - the crew-ship pipeline reference.
- `docs/qa-attestation.md` - the QA evidence and attestation contract.
- [CONTRIBUTING.md](CONTRIBUTING.md) - ground rules, which file owns what, and the dev loop.

## License

MIT - see [LICENSE](LICENSE).
