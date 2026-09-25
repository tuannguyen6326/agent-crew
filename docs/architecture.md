# Architecture

This page is the contributor's map of agent-crew: which components exist, how data moves between them, where state lives, and which file owns each contract.
It does not explain why the fleet works this way - read [`concepts.md`](concepts.md) first for roles, flows, rooms, supervision and the judgment rules.
Script usage lives in [`scripts.md`](scripts.md), and every config file and environment variable in [`configuration.md`](configuration.md).
When this page and an owner disagree, the owner wins: each `bin/` script's header comment is its own spec.

## The shape of the system

agent-crew has no application server of its own.
It is bash scripts (plus a few Bun/TypeScript files) over files on disk, with a session backend as the message bus and an LLM harness as the runtime.
Every component either writes durable state under the fleet home (`$AC_HOME`) or a project repo's `.crew/`, or reads it back.

```text
 captain (human)
    |  chat, dashboard, optional remote channel (config hooks)
    v
 crewchief session  -- harness at the fleet home, on AGENTS.md
    |   \
    |    +-- roomchief sessions (<family>-chief, AC_SCOPE=<family>), one per promoted family
    v          v
 crewmates (one per task/stage)          verification pane agents (one turn each)
 bin/ac-spawn.sh                         bin/ac-pane-agent.sh via ac-verify / ac-qa / ac-gate / ac-learn
    |                                         |
    +------------------+----------------------+
                       v
 session backend: bin/ac-backend.sh (herdr driver) | bin/ac-backend-orca.sh (orca driver)
                       v
 worktrees: herdr fleets -> pooled <repo>/.crew/worktrees/<n> (bin/ac-tree.sh)
            orca fleets  -> one Orca-managed worktree per task

 back-channel:
 panes --poll--> bin/ac-watch.sh --publish--> state/.wake-spool[.<family>]/ --> bin/ac-wake-drain.sh --> chief
 agent --push--> bin/ac-done.sh  --publish--^
```

The watcher and the push land in the same durable spool, so a chief that restarts loses nothing.
`bin/ac-session-start.sh` rebuilds a session's picture from disk.

## The fleet home and runtime links

A fleet home holds the fleet's state, not code; `AGENTS.md` section 2 lists its directories.

| Path | Holds | Owner |
|---|---|---|
| `state/` | Task metas, status logs, wake spools, watcher beacons, locks, dot-prefixed counters. | `bin/ac-lib.sh`, `bin/ac-wake-lib.sh`, `bin/ac-maintenance-lib.sh` |
| `data/` | Task dirs (`brief.md`, `report.md`, `kickoff.md`, `timeline.log`) and each family's `room.md`. | `bin/ac-brief.sh` header (the layout spec) |
| `records/` | Ledgers (`backlog.md`, `projects.md`, `captain.md`, `learnings.md`, `crewdeputies.md`, `crewdomains.md`), `repo-knowledge/`, `scenes/`, `standing-jobs.md`, `rig.json`. | Each file's own `bin/` script |
| `config/` | Per-fleet knobs and user-owned hooks. | [`configuration.md`](configuration.md) |
| `projects/` | Project clones plus each one's captain-owned `<name>.yaml`. | `ac_project_config_file` in `bin/ac-lib.sh` |
| `skills/` | Fleet-learned skills, plus the reserved `skills-archive/`. | `bin/ac-learn.sh`, `bin/ac-curate.sh` |
| `crewdomains/`, `crewdeputies/` | Domain packages and nested deputy homes. | `bin/ac-domain.sh`, `bin/ac-home-seed.sh` |
| `whiteboards/` | Excalidraw scenes and redraw receipts. | `dashboard/app.ts` |

Scripts run from the distro checkout that owns `bin/` and read and write fleet state under `$AC_HOME`, which is required: `ac_home` refuses rather than fall back to the checkout.
A caller that legitimately runs homeless, as every crewmate pane does, uses the rungs built for it instead (`bin/ac-lib.sh` header).

`ac_seed_runtime_links` symlinks the executable core - `bin`, `CLAUDE.md`, `.claude`, `AGENTS.md` - into a home, so a chief session runs with cwd = home while the code stays in the checkout.
A real (non-symlink) entry is a per-home override and is left alone, a stale symlink is repointed, and `docs/` and `tests/` are never linked.
`bin/ac-fleet-new.sh` and `bin/ac-home-seed.sh` call it for a new fleet home or crewdeputy home.
`state/.ac-root` (`ac_seed_root_pointer`) records the checkout, so a hook deployed under `config/` can find `bin/ac-lib.sh` from any cwd.

`bin/ac-lib.sh` is the core library every script sources.
Its satellites are sourced directly by the callers that need them:
- `bin/ac-wake-lib.sh` - wake scope and publication, the watcher nudge, the room pending/handback matchers, the chief-quiet predicates.
- `bin/ac-maintenance-lib.sh` - the Learning/Curate cadence counters and the shared maintenance transaction.
- `bin/ac-qa-lib.sh` - QA validation.
- `bin/ac-pipeline-lib.sh` - the YAML subset reader, the findings normalizer and the transcript reader shared by `ac-ship.sh` and `ac-qa.sh`.
- `bin/ac-harness.sh` - the per-harness registry, sourced by `ac-lib.sh` itself.

## Session backends

The backend is one contract with two drivers: herdr (`bin/ac-backend.sh`, the reference implementation) and orca (`bin/ac-backend-orca.sh`).
Both expose the same `backend_*` verbs keyed by task id - window create, liveness, verified send, key, capture, kill, wait stamp, startup dialogs - with the same return codes; the `bin/ac-backend.sh` header lists the surface.

`ac_backend` resolves the driver per call: `AC_BACKEND` (exported from the task meta's `backend=`) > `$AC_HOME/config/backend` > the fleet config found through `AC_FLEET_STATE` > herdr, refusing any other value.
Per-call resolution lets one teardown, send or watch process serve tasks of both kinds.
The `AC_FLEET_STATE` rung exists because a crewmate pane carries no `AC_HOME`, only the `AC_FLEET_*` variables on its launch line.

The `bin/ac-backend.sh` header owns these contracts:
- WINDOW LIVENESS - alive, gone or unobservable, and only a definite answer from a reachable backend may become `gone`.
- HARNESS CAME-UP PROBE - did a harness take the pane's foreground, or did it fall back to a shell.
- CAPTAIN-WAIT STAMP, KILL OWNERSHIP PROOF, LAST-TAB FALLBACK and HUNG RPC.
- FAMILY WORKSPACE GROUPING - a family's panes share one herdr workspace `<fleet> · <family>`, fleet-level panes the root `<fleet>` one.

The orca driver states each divergence at its function (`bin/ac-backend-orca.sh` header): panes group under Orca sidebar nodes instead of workspaces, the captain-wait stamp is the file alone, the came-up probe reads Orca's own agent detection and the terminal title, startup dialogs are answered by name, and liveness comes from `terminal show`'s `.connected` because a closed terminal still serves scrollback.

`bin/ac-backend.sh` also owns the launch line every mechanism types into a pane (`ac_build_launch`) and the crew-dispatch profile resolution behind it (`ac_resolve_profile`).
Tests drive the herdr driver through a fake `herdr` CLI shipped in `tests/helpers.sh`.

A task's primary tree is leased by the fleet's backend.
A herdr fleet leases a pooled detached-HEAD worktree (`<repo>/.crew/worktrees/<n>`, slot leases in `<repo>/.crew/slots/`) through `bin/ac-tree.sh`; slots are reused and returned, never deleted ([`worktrees.md`](worktrees.md)).
An orca fleet leases one Orca-managed worktree per task on `crew/<id>`, which teardown removes rather than returns (the meta's `worktree_backend=orca`).
The exact-ref verifier lease follows the same fork (`verify_lease` in `bin/ac-verify.sh`).

## Spawn and instruction seeding

`bin/ac-spawn.sh` turns a brief into a running agent.
It also owns roomchief promotion (`--roomchief`, including `--solo`) and crewdeputy spawn and recovery.
A roomchief runs in the agent-crew checkout with no worktree and no brief - the room is its brief - with `AC_SCOPE=<family>` exported, and the promote refuses while the room holds no entry (THE ORDER GATE).

One crewmate spawn:
- `bin/ac-brief.sh` has already written the brief and recorded `Mode:` and the review obligation.
- The profile comes from `--harness`, else `config/crew-dispatch.json` through `bin/ac-dispatch-select.sh`, else `config/model` and `config/effort`.
- The worktree is leased per backend and recorded in `state/<id>.meta` (the LEASES block in the header owns the grammar).
- The worktree is seeded: `ac_seed_crewmate_md`, `ac_seed_crew_settings`, `ac_seed_crew_skills`, `ac_seed_ports_env`.
- The pane opens and the harness launches bare, with `AC_FLEET_*` variables (state dir, fleet name, scope, per-role knobs) on its launch line.
- `deliver_kickoff` waits for the harness and its composer, answers startup dialogs, writes the prompt to `<task-dir>/kickoff.md`, and types one pointer line naming it.
- Submit and arrival are both checked: a dead pane kills the spawn, and a swallowed kickoff leaves a status line and a `kickoff-unverified` wake.

`bin/ac-self-task.sh start` runs the same four seeding calls for a chief-side edit.

`bin/ac-harness.sh` is the one place a harness's facets live: the known set, the TUI busy regex, the instruction file, the pane-agent arm, the startup-dialog key and the recorded launch options.
Every facet fails closed or answers a documented default.
The two launch command tables stay at their arms (`ac_build_launch`, and `oneshot_launch` in `bin/ac-pane-agent.sh`), so a new harness edits the registry, those two arms and its entry in the `harness-operations` skill's `references/harness-facts.md`.
A captain's custom template (`config/launch-<h>`) launches without joining the registry.

`ac_seed_crewmate_md` installs the crewmate layer where the harness reads it (`ac_harness_instruction_file`): `AGENTS.md` for codex, opencode, pi and cursor, `.claude/CLAUDE.md` for claude and for an existing custom template, and a refusal for anything else.
The available layers are concatenated in read order - container baseline (`<container>/.claude/CLAUDE.md`), `$AC_HOME/CREWMATE-learned.md`, `$AC_HOME/CREWMATE.md`, then the crewdomain's `CREWMATE.md` when the spawner is domain-bound - so the most specific word reads last.
A repo-shipped file wins outright and the layer lands at a fallback path that the kickoff names; a file the seed wrote is refreshed when its sources move, and seeded paths go to the repo's `info/exclude`.

`ac_seed_crew_settings` copies, never symlinks, `$AC_HOME/.claude/settings.json` (else the container copy) to `<worktree>/.claude/settings.json`, so a crewmate's permission grants stay local.
A home `.claude` that is the runtime symlink into the distro is skipped, because it holds the chief's hook wiring.

`ac_seed_crew_skills` symlinks skills into the directory the harness scans (`.agents/skills` for codex, `.claude/skills` otherwise): first the built-ins in `AC_CREW_SKILLS` (default `crew-ship crew-verify crew-qa domain-e2e document`) from the container store or this checkout, then every fleet-learned package except `skills-archive`.
A repo-shipped skill of the same name wins, and dangling links from retired skills are removed first.

## Task state on disk

`state/<id>.meta` is the key=value task record (window, worktree, leases, project, kind, mode, session id, backend, PR), last write wins.
The path is a namespace - every enumerator reads a file there as an agent in flight - which is why counters in `state/` are dot-prefixed.
Two meta classes are defined once in `bin/ac-lib.sh`:
- `ac_meta_is_verify` - `kind=verify-*` (`verify-codereview`, `verify-qa`, `verify-learning`, `verify-suite`) is excluded from crew accounting, never from supervision.
- `ac_meta_is_self` - `kind=self` is excluded from supervision, never from accounting.

`state/<id>.status` is the append-only event log; `ac_status_append` mirrors each line to a durable `timeline.log` in the task's data dir.
`state/.landings` is the landing ledger the merge helpers append and warn from, and `bin/ac-ready.sh overlap` reads it at intake.
`state/.session-lock` records which harness process drives the home (`bin/ac-lock.sh`); a second session gets a read-only digest.

`bin/ac-teardown.sh` is fail-closed: it refuses while work is unlanded or the worktree is dirty, and on success archives the task's state files under `state/archive/<id>/` before releasing its pane and leases.
Local landings go through `bin/ac-merge-local.sh` (fast-forward by default), PR landings through `bin/ac-pr-check.sh` and `bin/ac-pr-merge.sh`.

## The wake pipeline

Producers all publish through one primitive, `ac_wake_publish` in `bin/ac-wake-lib.sh` (a private write plus one atomic `ln`, one record per file):
- `bin/ac-watch.sh` on an actionable pane event.
- `bin/ac-done.sh`, the agent's push of its own completion, which stamps the watcher's marker dedup so one completion wakes once, then nudges the covering watcher.
- `bin/ac-room.sh handback`, `bin/ac-remote.sh`, `bin/ac-github.sh poll`, the learning-due wake in `bin/ac-learn.sh`, and the dashboard's whiteboard Notify-crew route.

`ac_wake_spool_path` keys the store by consumer: `state/.wake-spool/` for the crewchief, `state/.wake-spool.<family>/` for a promoted family's roomchief.
A watcher files wakes under its own `AC_SCOPE`, so two sessions cannot swallow each other's wakes; hand-backs and remote orders always go to the fleet spool.

`bin/ac-wake-drain.sh` claims each record by an atomic rename and prints `<kind> <id> <payload>`, with at most one status context line.
The fleet chief also drains, in place, the spool of any family whose roomchief is not live.
Records of a drainer that died mid-claim return to the spool: exactly-once normally, at-least-once across crashes.
The drain then reports unacknowledged completions and prints `WATCHER-DOWN` when crew flies under a stale beacon.

`bin/ac-watch.sh` costs no tokens while nothing happens; its header owns every arm and reason (marker, artifact, push, `gone`/`unobservable`, `ask`, `ended`, `stale`, `heartbeat`).
Each watcher stamps `state/.last-watcher-beat[.<family>]` and stands it down on exit, and records its `AC_WATCH_SKIP` in `state/.watcher-config[<suffix>]` so an arm with a different config refuses.
A roomchief arms with `AC_WATCH_ONLY` from `bin/ac-ready.sh watch-set <family>`; the fleet watcher revalidates its skip set every poll and covers a family directly when its roomchief is gone.
A blocking caller (`ac-gate.sh`, `ac-verify.sh`) writes a self-expiring `state/.chief-busy-until.<family>` so a live roomchief inside one long call keeps its skip.

Chief-side enforcement:
- `bin/ac-watch-autoarm.sh` - a claude Stop hook with `asyncRewake` that holds a watcher while supervision is owed, re-arms on `heartbeat`, and wakes the session on anything actionable.
- `bin/ac-turnend-guard.sh` - blocks a turn end while this session's wakes are pending or its watcher's beacon is stale; the two hooks are separate on purpose (both headers).
- `bin/ac-guard.sh` - a warn-only advisory at the start of `ac-send`, `ac-peek`, `ac-spawn`, `ac-review-diff` and `ac-merge-local`.

## Hooks per harness

The guards are plain scripts reading a claude-shaped payload, and each harness gets a thin adapter.
Claude wires them in `.claude/settings.json`:

| Event | Script | Duty |
|---|---|---|
| SessionStart | `bin/ac-sessionstart-nudge.sh` | Remind a fresh chief to run session-start; re-orient after compact. |
| UserPromptSubmit | `bin/ac-prompt-recall.sh` | Give a human-driven session the top fleet-memory hits. |
| PreToolUse (Bash) | `bin/ac-watch-policy-hook.sh` | Deny broad pattern-based watcher kills. |
| PreToolUse | `bin/ac-delegation-guard.sh` | Refuse harness-native subagents from a chief-shaped session. |
| PreToolUse | `bin/ac-ledger-guard.sh` | Refuse a scoped session writing the backlog, projects or captain ledger. |
| PreToolUse | `bin/ac-primary-guard.sh` | Refuse a crewmate or roomchief editing the primary checkout. |
| Stop | `bin/ac-turnend-guard.sh` | Block a blind turn end. |
| Stop | `bin/ac-compact-advise.sh --hook` | Advise a `/compact` to the human. |
| Stop (`asyncRewake`) | `bin/ac-watch-autoarm.sh` | Keep a watcher armed. |

Other harnesses carry a subset:
- codex - `.codex/hooks.json`: prompt recall, the four PreToolUse guards, the turn-end guard.
- cursor - `.cursor/hooks.json`: the nudge, `bin/ac-prompt-recall-cursor.sh`, `bin/ac-watch-policy-cursor.sh`, and `bin/ac-turnend-guard-cursor.sh` (a follow-up message, since cursor's stop cannot block).
- opencode - `.opencode/plugins/ac-primary-guards.js`: watch policy, turn-end guard on `session.idle`, prompt recall.
- pi - `.pi/extensions/ac-primary-turnend-guard.ts`: watch policy, turn-end guard on `agent_settled`, prompt recall.

Every adapter fails open and the guards self-scope, so hooks copied into a crewmate worktree stay inert there.
The non-claude wirings ship with live probes pending, and `tests/ac-harness-hooks.test.sh` fences them.

## Rooms and the ledger machinery

`records/backlog.md` is the fleet-wide task index and `data/<family>/room.md` is one family's narrative; they never merge.

`bin/ac-room.sh` owns rooms: `post`, `show`, `list`, `close`, `open`, `pending`, `handback`, and the gate-receipt verbs `gate-route`, `gate-verify`, `disposition`.
`post` refuses a malformed `GATE:`/`ASK:`/`DECIDED:` opening (`ac_room_marker_malformed`).
The captain's inbox count is one matcher, `ac_room_pending`, and the HANDBACK state another, `ac_room_handback_families`, both in `bin/ac-wake-lib.sh`; the digest, the dashboard and the guards all call them.

The backlog grammar is [`backlog.md`](backlog.md), parsed by one awk block, `AC_DONELINE_AWK` in `bin/ac-lib.sh`, which `ac-ready.sh`, `ac-curate.sh` and `ac-learn.sh` each prepend to their own program.
`ac_contract_lint` judges contract-token values; the parser only extracts them.
The dashboard's `parseBacklogLine` (`dashboard/lib.ts`) is held byte-identical to it by a differential test.

- `bin/ac-task.sh` - every routine backlog mutation as a verb, under the lock `records/.backlog.md.lock`, re-read inside the lock and published by tmp+rename, with a row's narrative as an indented body.
- `bin/ac-ready.sh` - the read-only scheduler primitive: READY/STUCK/HELD, `queued`, `watch-set`, `validate <epic>`, and `overlap`.
- `bin/ac-ledger-guard.sh` - keeps scoped sessions out of the fleet ledgers, so only the crewchief moves rows.

Integration branches keep their own records: `data/<epic>/branches` (`bin/ac-epic-branch.sh`, exit through `bin/ac-epic-ship.sh`) and `data/<feature>/branches` (`bin/ac-feature.sh`), fenced at lease time by `ac-tree.sh get`.

## The delivery engines

All independent verification is a pane agent: one agent turn in a backend pane, run by `bin/ac-pane-agent.sh` on one of three arms - a claude session, the crewmate contract for TUI harnesses, or a one-shot `--exec` command.
Its harness/model/effort comes from the `panes` block of `config/crew-dispatch.json`, keyed by `--kind` (PANE PROFILE in the header).

```text
execution crewmate
   |-- crew-ship: bin/ac-ship.sh (<repo>/.crew/ship/<run>/)
   |      review step -> ac-ship.sh review-agent -> ac-verify.sh codereview
   |-- direct-pr / local-only with review -> ac-verify.sh codereview (crew-verify skill)
   '-- QA after delivery -> ac-qa.sh agent -> ac-verify.sh qa (<repo>/.crew/qa/<run>/)

ac-verify.sh: exact-ref lease -> neutralize instruction files -> ac-pane-agent.sh run -> capture -> reap
```

`bin/ac-verify.sh` accepts only `codereview` and `qa`.
It leases an isolated worktree at the exact commit, stubs the project's instruction files there (restoring them before release), runs one fresh pane agent, captures the result, and reaps pane, lease and meta on every exit path.
Its meta is `kind=verify-<kind>`, and round history carries forward only as structured findings.

`bin/ac-ship.sh` is the crew-ship state machine driven by the `crew-ship` skill; its steps, findings, hold-and-fix, round cap and `checks-passed` gate are in [`validate-pipeline.md`](validate-pipeline.md), with `bin/ac-ship-watch.sh` as its board.
`bin/ac-qa.sh` is the QA state machine whose durable run state owns the verdict and whose atomic attestation `qa.require_for_ship` gates on; see [`qa-attestation.md`](qa-attestation.md), with `bin/ac-qa-watch.sh` as its board.
`ac_findings_normalize` in `bin/ac-pipeline-lib.sh` is the single enforcement point for the findings wire, including the downgrade of an unfounded `fix` to `ask-user`.

## Gates

`bin/ac-room.sh gate-route` appends a `GATE-ROUTING:` receipt for one exact report: captain authority routes to `captain`, else uncertainty or high consequence to `second-chief`, else `chief`.
`bin/ac-gate.sh <family> <stage>` opens only on `route=second-chief`.

The second chief is one fresh, non-resumed turn on one engine with no fallback.
Its profile is a valid `panes.gate`, else `config/gate-agent` (default `codex`) with its model and effort knobs; an invalid `panes.gate` fails before a pane opens.
Its context is bound by `gate-context-rN.json`, and it writes `second-chief-rN.md` (the latest also as `second-chief.md`) and `gate-prompt.md` in the stage dir.
R1 is advisory `continue|revise|ask-captain`, R2 is terminal `continue|chief-decide|ask-captain`, and the owning chief decides.
While it runs, `data/<family>/.gate-running` exists and `bin/ac-gate-watch.sh` shows the live turn.

`ac-gate.sh maintenance --mode learning|curate` judges one immutable Learning or Curate plan and writes a hash-bound `agentcrew.maintenance-gate/v1` receipt.
The gate law is the `staged-gates` skill; report contents are [`staged-design-flow-spec.md`](staged-design-flow-spec.md).

## The knowledge stack

| Layer | Store | Owner |
|---|---|---|
| L0 narrative | `data/<family>/room.md` | `bin/ac-room.sh` |
| L1 facts | `records/repo-knowledge/<project>.md`, one line per fact with provenance and freshness | `bin/ac-know.sh` |
| L1 lessons | `records/learnings.md` `## Pending` | `bin/ac-learn.sh note` |
| L2 scenes | `records/scenes/<slug>.md`, pull-only, never seeded | `bin/ac-scene.sh` |
| L3 always-loaded | `$AC_HOME/CREWMATE-learned.md` and `$AC_HOME/skills/` | `bin/ac-learn.sh` transactions |
| Index | `state/brain.sqlite` over the home's markdown, facts in `state/facts.md` | `bin/ac-brain-engine.ts` |

`ac-know.sh recall` walks scenes then facts, ranks by terms matched then `heat:`, and caps its output; `cite` (and `ac-scene.sh show --cite`) bumps heat.

Learning (`bin/ac-learn.sh`):
- `tick` advances the cadence; a keyed tick is idempotent through `state/.learn-ticks`.
- At `config/learn-every` (default 8) the drain runs `autoroom`, which promotes a cap-exempt `learning` roomchief through spawn's atomic `.meta-claims`.
- `autoroom` holds on the ledger shape gate and, only where `config/learn-suite-gate=on`, until `tests/run-suite.sh` is green for the current generation and tree.
- `run` snapshots the retro window into `data/learning-<epoch>/` and launches a fresh `panes.learning` scout that proposes and never mutates.
- Each candidate becomes an immutable plan plus input manifest, and only a validated maintenance-gate `continue` authorizes its apply.

Each complete Learning run ticks Curate, and at `config/curate-every` (default 5) Learning runs `bin/ac-curate.sh run`, which archives retired captain rules and old Done rows verbatim and gates anything non-deterministic.
Neither has a cron or daemon.
Both mutate knowledge only through the maintenance transaction in `bin/ac-maintenance-lib.sh` - a fleet lock, a pre-write backup, a closed schema, staged hashes, atomic replacement and a journal under `state/.maintenance-transactions/` - and `ac_maintenance_receipt_validate` re-derives every hash rather than trust a writer.
`ac-learn.sh maintenance status|resume|abandon` settles a held transaction.

The brain database is disposable: markdown stays the system of record (`bin/ac-brain-engine.ts` header).
`ac_brain_freshen` fires one throttled catch-up sync from the watcher and the prompt-recall hook when the database exists and `config/brain-auto-sync` is not `off`.
Landing stays the primary learning mechanism; the manual `/debrief` is the reset-time catch-all, and its `debrief` skill owns knowledge routing and curation, room and fleet reconciliation, the resume pointer and the reset verdict.

## System One

`bin/ac-jev.sh` answers closed-set questions with calibrated probabilities behind one knob (`AC_JEV` > `config/jev` > `off`).
`shadow` logs to `state/jev-shadow.jsonl` and prints nothing; `on` also prints the validated answer.
`config/jev-provider` picks `openrouter` (default), `typesafe`, `opencode` or `laya`, with keys from `config/providers.json`.
Every failure is one `jev:` line on stderr and empty stdout, and `ac-jev.sh label` records the decision the chief actually made.
Its sites, each a proposal only: the watcher's notes on quiet wakes, `ac-dispatch-select.sh --propose`, `ac-ready.sh overlap --semantic`, `ac-learn.sh route-propose`, and `bin/ac-compact-advise.sh` (site `compact`, a Stop hook for human-read sessions and a watcher note for crewmates).

## The dashboard

`bin/ac-dashboard.sh` runs it in the foreground by default, or detached with `start|stop|restart|status` (pid and log in `$AC_HOME/state/`).
It runs `bin/dashboard.ts`, a shim that re-exports `dashboard/app.ts` and calls `dashboardMain()`, under Bun with no build step.

| File | Role |
|---|---|
| `dashboard/app.ts` | The server: routes (listed in its header), data layer, sanctioned writes, websockets, security checks. |
| `dashboard/lib.ts` | The pure layer - parsers, theme tokens, board joiners - with no IO and no imports. |
| `dashboard/page.ts` | The SPA shell, one template of inline CSS and vanilla JS that interpolates `lib.ts` functions so the browser runs tested code. |
| `dashboard/watch.ts` | File watchers on `state/`, `records/backlog.md` and room files that drop the snapshot memo early. |
| `dashboard/assets/` | Vendored xterm.js. |

The server shells out only to fixed survey scripts (`ac-fleets.sh --json`, `ac-room.sh list|show`, `ac_domain_tally`) and never re-derives a count.
Its writes are the ones its header names: one allowlisted config knob, the fixed-name dispatch table, whiteboard scenes and their Notify-crew wake, review sessions, and the fast-forward-only project pull through `bin/ac-repo-pull.sh`.
Paths are gated by `realpathSync` against the home, and requests by local `Host` and `Origin` checks (`localHostOk`, `originOk`).
`bin/ac-review.sh` and the `rich-review` skill drive its review API; `bin/ac-fleets.sh` and `bin/ac-dash.sh` are the terminal views of the same survey.

## Remote orders and GitHub intake

`bin/ac-remote.sh` is the durable state machine around a transport it never builds in: user-owned hooks (`config/remote-poll`, `remote-reply`, optional `remote-ack`) carry Slack or anything else, and every verb degrades safely without them.
`poll` stashes each new order at `state/remote-inbox/<rid>.json` (the rid is the idempotency key) and publishes one `remote-order <rid>` wake to the fleet spool.
`order` stashes a local order the same way, which is how a solo session hands work to the chief; replies land at `state/remote-inbox/<rid>.replies.md`.
Only the fleet-scoped watcher owned by the session-lock holder runs the poll slot (LOCK GATE in `bin/ac-watch.sh`).
The chief's handling is the `remote-orders` skill; an example transport is `docs/examples/slack-remote`.

`bin/ac-github.sh poll` only detects: it records open PRs and issues from a clone's `origin` under `state/.github/<slug>/` and publishes a `github` wake, never minting, verifying, spawning or merging; `comment` posts a verdict the crew already produced.

## Crewdeputies and crewdomains

The two share no registry, root, script or verb.

A crewdeputy is a nested home with its own clones and standing session, provisioned by `bin/ac-home-seed.sh` under `crewdeputies/<name>/` and registered in `records/crewdeputies.md` (grammar: the `crewdeputy routing table` block of `bin/ac-lib.sh`).
`bin/ac-deputy.sh` renders the table with liveness (`list`), checks it (`validate`), returns a routed order's outcome to the parent (`report`), and moves queued rows over (`handoff`).
Orders go out through `bin/ac-send.sh`, and recovery is `ac-spawn.sh <id> --crewdeputy --recover`.

A crewdomain is state inside this fleet: a package at `crewdomains/<name>/` plus one line in `records/crewdomains.md`.
The package holds `records/projects.md`, `CREWMATE.md` (the last seeded layer) and `projects/` (symlinks into the fleet's own clones), plus an optional `qa-repo`.
Its work is the `domain:<name>`-tokened slice of the fleet backlog, worked by a domainchief - an ordinary roomchief whose meta gains `domain=` and whose launch line gains `AC_DOMAIN`, derived from the row token at promote.
`bin/ac-domain.sh` owns every verb and the package layout; choosing between the two is the `deputies-domains` skill.

## The skills layer

`AGENTS.md` is the index the chief keeps loaded, and its section-12 table names the skill to load before each act ([`concepts.md`](concepts.md), "The law layout").
`.agents/skills/<name>/SKILL.md` holds the step-by-step law, and `.claude/skills` is a tracked symlink to it.
Skills hold judgment and operating sequence; script headers hold syntax, state transitions and fail-closed mechanics.

- Crew-seeded (`AC_CREW_SKILLS`): `crew-ship`, `crew-verify`, `crew-qa`, `domain-e2e`, `document`.
- Chief law, never seeded: `intake-triage`, `delivery-review`, `staged-gates`, `judgment-rules`, `task-lifecycle`, `solo-session`, `rooms-threads`, `deputies-domains`, `epic-intake`, `gate-review`, `diagnostic-reasoning`, `stuck-crewmate-recovery`, `project-management`, `harness-operations`, `remote-orders`.
- Captain-invocable and chief-facing: `order-direct`, `order-staged`, `order-design`, `rich-review`, `bearings`, `debrief`, `ac-brain`, `domain-knowledge`, `diagram-design`, and `brainstorm` (captain ideation with a dedicated roomchief that drafts rows and a `requirements.md` for the chief to mint on the captain's yes, leaving a scene and a Done record row; its risk-scaled design cadence asks one decision at a time on architectural topics and stays lightweight otherwise).

Learned skills live only in `$AC_HOME/skills/`, are written only by Learning transactions, and are seeded as the second class by `ac_seed_crew_skills`.
Every tracked package follows the Agent Skills spec, enforced by `tests/ac-skills-catalog.test.sh`.

## Contract owners

| Concern | Authoritative file |
|---|---|
| Home, metas, locks, config reads, seeding, meta classes, landing ledger | `bin/ac-lib.sh` |
| Backlog parsing and mutation | `AC_DONELINE_AWK` in `bin/ac-lib.sh`, `bin/ac-task.sh`; grammar in [`backlog.md`](backlog.md) |
| Task-data layout | `bin/ac-brief.sh` |
| Closed-family relocation to `data/archive/<year>/` | `bin/ac-archive.sh` (manual only) |
| Harness facets | `bin/ac-harness.sh` |
| Backend contract and launch line | `bin/ac-backend.sh`, `bin/ac-backend-orca.sh` |
| Worktree pool | `bin/ac-tree.sh` |
| Spawn, kickoff, leases grammar | `bin/ac-spawn.sh` |
| Watcher, wake keying, push, drain | `bin/ac-watch.sh`, `bin/ac-wake-lib.sh`, `bin/ac-done.sh`, `bin/ac-wake-drain.sh` |
| Rooms and gate receipts | `bin/ac-room.sh` |
| Pane agents, exact-ref verification | `bin/ac-pane-agent.sh`, `bin/ac-verify.sh` |
| crew-ship and QA pipelines | `bin/ac-ship.sh`, `bin/ac-qa.sh`, `bin/ac-pipeline-lib.sh` |
| Second chief and maintenance gate | `bin/ac-gate.sh` |
| Knowledge, scenes, brain | `bin/ac-know.sh`, `bin/ac-scene.sh`, `bin/ac-brain-engine.ts` |
| Learning, Curate, maintenance transaction | `bin/ac-learn.sh`, `bin/ac-curate.sh`, `bin/ac-maintenance-lib.sh` |
| System One | `bin/ac-jev.sh`, `bin/ac-compact-advise.sh` |
| Dashboard | `dashboard/app.ts` |
| Remote orders, GitHub intake | `bin/ac-remote.sh`, `bin/ac-github.sh` |
| Deputies, domains | `bin/ac-deputy.sh`, `bin/ac-domain.sh` |
| Rig manifest, standing jobs, pre-push gate | `bin/ac-rig.sh`, `bin/ac-standing-jobs.sh`, `bin/ac-push-gate.sh` |
