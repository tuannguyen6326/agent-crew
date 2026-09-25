# Scripts reference

Every executable and library under `bin/` has one row below, grouped by area.
Each script's header comment is its authoritative spec; this page is only the map, and a row that disagrees with its header is a doc bug.
The usage column lists every verb the script dispatches; the header owns the contract.
Rows name fail-closed behavior, the callers that matter, and where a script refuses a SOLO session (`AC_SOLO=1`).

## Fleet and session

| Script | What it does |
|---|---|
| `ac-session-start.sh` | The ordered session-start digest: lock, config convergence, toolchain doctor, wake drain and watcher health, clone and pool hints, fleet view, backlog head, registry and supervision block. When another live session owns the home it degrades to READ-ONLY (no drain, no qa reap); a SOLO session always runs read-only, skipping the lock, wake drain, qa reap and config converge. Spec: `bin/ac-session-start.sh` header. |
| `ac-lock.sh acquire \| status \| release` | Per-home chief session lock (`state/.session-lock`): one fleet-driving session at a time, keyed on the harness pid plus a command fingerprint so pid reuse reads as stale. A scoped session (`AC_SCOPE`) skips `acquire` without locking; a live foreign holder refuses with exit 2. Spec: `bin/ac-lock.sh` header. |
| `ac-standing-jobs.sh [--ids]` | Session-start ride-along: each DECLARED standing job from `records/standing-jobs.md` with its exact re-create action; it never claims a job is live (CronCreate is session-only). `--ids` prints the ids for `ac-rig.sh`. Spec: `bin/ac-standing-jobs.sh` header. |
| `ac-pool-health.sh [--repo <path>]...` | Session-start ride-along: per project repo, worktree-pool slots that are stuck available-dirty, broken, or aged-leased, each with the exact command to run; reads only `ac-tree.sh list`, never reclaims, silent when healthy, always exits 0. Spec: `bin/ac-pool-health.sh` header. |
| `ac-rig.sh drift` | Compares the hand-written rig manifest `records/rig.json` (home, distro checkout, config knobs, standing-job ids) against reality with three verdicts, `OK` / `DRIFT` / `UNVERIFIABLE`. Exit 1 on drift, 2 on usage or an unreadable or wrong-home manifest, never graded clean. Spec: `bin/ac-rig.sh` header. |
| `ac-guard.sh` | Warn-only advisory riding at the start of `ac-send`, `ac-peek`, `ac-spawn`, `ac-review-diff` and `ac-merge-local`: WATCHER-DOWN, QUEUED WAKES, TANGLE, WIP-TOOLING and DISTRO-LAG, scoped and rate-limited per session. Always exits 0. Spec: `bin/ac-guard.sh` header. |
| `ac-fleet-view.sh` | One line per crewmate: id, kind, project, mode, state, window. Spec: `bin/ac-fleet-view.sh` header. |
| `ac-fleets.sh [--json \| --paths] [<container>]` | Strictly read-only survey of every fleet home under the homes container, deputies included, never touching the backend; `--json` feeds the dashboard, `--paths` is home discovery only. Spec: `bin/ac-fleets.sh` header. |
| `ac-dash.sh [--watch [<s>]]` | Captain dashboard in the terminal: fleet header, crew states, rooms inbox, backlog counts and per-project worktree pools; `--watch` redraws every `<s>` seconds (default 5). Spec: `bin/ac-dash.sh` header. |
| `ac-statusline.sh` | One-line fleet status for terminal status bars (`⚓<fleet> <n>▶ <m>⚑[ WATCH!]`), file reads only so it stays fast; the pending count uses the shared `ac_room_pending` matcher. Spec: `bin/ac-statusline.sh` header. |
| `ac-notify.sh <title> <message...>` | Best-effort captain notification over the `config/wedge-alarm` channel (`off`, `auto`, `herdr`, `osascript`, `bell`, `command:<cmd>`); never fails and always exits 0. Spec: `bin/ac-notify.sh` header. |
| `ac-sync.sh [<project>]` | Clone-freshness sweep: time-bounded fetch, fast-forward of a clean default branch, prune of local branches whose upstream is gone (keeping pool-leased `crew/*` branches). A dirty, off-default or diverged clone is reported `STUCK` and never touched; exit 1 on any STUCK or FAILED. Spec: `bin/ac-sync.sh` header. |
| `ac-repo-pull.sh <repo-root>` | Fetch plus FAST-FORWARD-ONLY sync of one clone's default branch, the dashboard Pull button's whole authority; a diverged branch, dirty tree or detached HEAD fetches only and mutates nothing. Spec: `bin/ac-repo-pull.sh` header. |

## Task lifecycle

| Script | What it does |
|---|---|
| `ac-brief.sh <id> <project> [--scout \| --stage <spec\|architecture\|plan\|implement\|design\|qa>] [--mode <crew-ship\|direct-pr\|local-only\|feature-pr>] [--review yes\|no] [--captain-requested <ref>] [--reason <line>] [--qa-required-profile <p>]...` | Scaffolds a brief and owns the task-data layout (flat, staged-nested, scoped fan-out under `data/<family>/tasks/`). Derives the review obligation; `--review yes` on a direct `direct-pr`/`local-only` task is refused without `--captain-requested`, and a captain-authorized time-expensive choice also needs `--reason`. Refuses to overwrite a brief. Spec: `bin/ac-brief.sh` header. |
| `ac-spawn.sh <id> <project> [--scout] [--mode <m>] [--harness <h>] [--model <m>] [--effort <e>] [--backend <b>] [--resume-from <old-id>] [--base-branch <b>]`; `--recover`; `--roomchief <family> [--solo] [--captain-initiated\|--system-initiated\|--over-cap <ref>]`; `<id> --crewdeputy [--recover]` | Leases the worktree, opens the pane per the fleet backend and launches the harness on `<task-dir>/kickoff.md`. Also owns roomchief promotion (capped at `config/room-parallel`, fail-closed), the `--solo` chief, crewdeputy spawn and recovery, the branch-collision refusal, and refuses to guess a profile when `config/crew-dispatch.json` exists. Refused in a SOLO session. Spec: `bin/ac-spawn.sh` header. |
| `ac-self-task.sh start <id> <project> [--mode <m>] [--harness <h>] [--base-branch <b>] \| log <id> '<line>'` | Makes a small chief-side edit VISIBLE: lease, crewmate-layer seed, a labelled pane tailing the progress log, and a `kind=self` meta, all before the first edit, with the same branch-collision refusal as spawn. A SOLO session uses it per slice with no size cap, and a solo chief uses it for its family's slices. Spec: `bin/ac-self-task.sh` header. |
| `ac-promote.sh <id> --mode <crew-ship\|direct-pr\|local-only> [--captain-requested '<ref>' --reason '<line>']` | Promotes a scout to a ship task in place (`kind=ship`, `mode=` set), after which teardown demands full landed proof. `--mode` is required, and promoting into `crew-ship` needs the captain's word. Spec: `bin/ac-promote.sh` header. |
| `ac-teardown.sh <id> [--force] [--pr-ready '<captain acceptance>'] [--no-lesson '<why>'] [--no-fact '<why>']` | Fail-closed teardown: proves landed work and a clean worktree, then archives state, closes panes, returns every lease and deletes a merged `crew/<id>`. `--pr-ready` is refused while an open row is blocked-by the task; a `kind=self` slice must also have its lesson, repo fact and Done row (or waivers) before it lands. `--force` means the captain discards the work. Spec: `bin/ac-teardown.sh` header. |
| `ac-tree.sh get \| lease \| list \| return \| prune \| remove` | The herdr fleets' in-repo worktree pool at `<repo>/.crew/worktrees/<n>`: detached-HEAD trees reset on acquire and reused, `lease` for a state-only lease, dry-run `prune`, gated `remove`. The first lease installs the pre-commit and commit-msg guard hooks; a dirty available slot is never silently reset. Spec: `bin/ac-tree.sh` header. |
| `ac-relocate.sh <id> [--family <fam> \| --root]` | Moves a live task window to another herdr workspace (default: its own family's) and resumes its recorded session there. Refuses an unknown task, a non-herdr backend, a missing `session_id` and a busy agent. Spec: `bin/ac-relocate.sh` header. |
| `ac-dispatch-select.sh --list \| [--rule <n>] \| --pane <kind> [--lanes \| --list \| --rule <n\|default> \| --receipt <n\|default>] \| --propose <brief-file>` | Resolves a `config/crew-dispatch.json` profile into TAB-separated `harness= model= effort=`; the chief judges the prose `when` clauses, this script never does. An absent pane entry prints nothing; a malformed one dies. `--propose` prints a System One rule hint only under `config/jev=on`. Spec: `bin/ac-dispatch-select.sh` header. |
| `ac-project-mode.sh <project>` | Resolves the `+yolo` flag from `records/projects.md` (`yolo=<on\|off>`) and nothing else - delivery mode is per task and resolved by `ac-brief.sh`. Spec: `bin/ac-project-mode.sh` header. |
| `ac-archive.sh archive [--dry-run] \| restore <family> [--dry-run]` | MANUAL ONLY, with no automatic caller by design: relocates families whose room carries `CLOSED:` to `data/archive/<year>/<family>/` and back; a closed room with no resolvable year is refused and exits 1. Idempotent and byte-reversible. Spec: `bin/ac-archive.sh` header. |

## Backends and panes

| Script | What it does |
|---|---|
| `ac-backend.sh` | Sourced session-backend primitives: one `backend_*` contract with two drivers routed per call (herdr here, orca in `ac-backend-orca.sh`); any other `AC_BACKEND`/`config/backend` value is refused. Owns WINDOW LIVENESS (unreadable is never dead), delivery verification, the captain-wait stamp and family workspace grouping. Spec: `bin/ac-backend.sh` header. |
| `ac-backend-orca.sh` | The orca driver, sourced by `ac-backend.sh`: same surface and return codes over the `orca` CLI, plus the per-task Orca worktree lease/release. Spec: `bin/ac-backend-orca.sh` header. |
| `ac-harness.sh` | Sourced per-harness registry: known set, busy regex, seeded instruction file, pane-agent arm, startup-dialog key and recorded-opts policy, each facet failing closed or answering a documented conservative default. A new harness edits this file plus the two launch tables. Spec: `bin/ac-harness.sh` header. |
| `ac-pane-agent.sh run \| close \| reap-pane \| reap \| steer` | Runs ONE agent turn in a pane for the verifying mechanisms (codereview, qa, learning scout, gate) in one of three arms: claude session, crewmate TUI, or `--exec` one-shot. The profile is dispatched per `--kind` from the `panes` block. Spec: `bin/ac-pane-agent.sh` header. |
| `ac-send.sh <id> [--force] '<text>' \| <id> --key <Enter\|Escape\|C-c>` | Sends one literal line (submit and arrival verified) or one named key to a pane; also the marked order channel to a crewdeputy. Refuses a missing pane, text into a blocked prompt or dead shell without `--force`, and a refuted arrival. Refused in a SOLO session. Spec: `bin/ac-send.sh` header. |
| `ac-peek.sh <id> [<lines>]` | Bounded tail of a crewmate pane (default 40 lines). Spec: `bin/ac-peek.sh` header. |
| `ac-crew-state.sh <id>` | One deterministic current-state line: ship step, then gone/unobservable window, busy pane, last status line, idle. Spec: `bin/ac-crew-state.sh` header. |
| `ac-follow.sh <id> \| --render <jsonl>` | Read-only realtime stream of a crewmate's claude transcript, following the transcript directory as sessions fork. Spec: `bin/ac-follow.sh` header. |
| `ac-session.sh <id> [--talk]` | Prints a claude resume of a crewmate's session: forked safe view by default, `--talk` un-forked and refused while the crewmate is busy; works on archived tasks. Spec: `bin/ac-session.sh` header. |

## Supervision and wakes

| Script | What it does |
|---|---|
| `ac-watch.sh [--once \| --release <pid>]` | Zero-token watcher: polls panes and stage `report.md` artifacts, publishes each actionable wake durably to its scope's spool, and exits with one reason line. Refused in a SOLO session. Spec: `bin/ac-watch.sh` header. |
| `ac-done.sh <id> <marker>` | The agent-side completion PUSH: publishes one durable `report` wake and nudges the covering watcher, stamping the watcher's dedup so one completion wakes once; a failed publish dies loudly. Spec: `bin/ac-done.sh` header. |
| `ac-wake-drain.sh [ack <id>...]` | Atomically drains the calling session's own spool (per-record rename), reports unacknowledged completions and warns WATCHER-DOWN; the fleet chief also drains orphaned family spools. Both forms are refused in a SOLO session. Spec: `bin/ac-wake-drain.sh` header. |

## Rooms and ledger

| Script | What it does |
|---|---|
| `ac-room.sh post \| show \| list \| close \| open \| pending \| handback \| gate-route \| gate-verify \| disposition` | Per-family captain thread at `data/<family>/room.md`: append-only entries, the pending inbox, fail-closed `close`, consented `open`, `handback` with a durable wake, and the structured `GATE-ROUTING`, `GATE-VERIFY` and `R1-DISPOSITION` receipts; `post` refuses a malformed GATE/ASK/DECIDED opener. Spec: `bin/ac-room.sh` header. |
| `ac-task.sh add \| start \| done \| hold \| unhold \| update-note \| prune` | Every routine `records/backlog.md` mutation as a verb: locked tmp+rename writes touching one row, the row narrative as an indented body, `hold --until <date>`, and `prune --keep <n>` into a dated archive. Idempotent, and hand-editing stays legal. Spec: `bin/ac-task.sh` header. |
| `ac-ready.sh [queued \| watch-set <fam> \| validate <epic> \| overlap <path>... \| overlap --semantic '<order>']` | Read-only scheduler over the backlog: READY / STUCK / HELD report (a malformed blocked-by never reads READY), pipeable `queued`, a roomchief's `watch-set`, epic validation, the file-overlap check, and the System One fold-or-mint proposer. Spec: `bin/ac-ready.sh` header. |

## Delivery: ship, verify, qa, PR and merge

| Script | What it does |
|---|---|
| `ac-ship.sh start \| step \| findings \| meta \| cmd \| attest-test \| attest-check \| push \| base \| evidence-dir \| skip-remaining \| config \| fix-report \| review-agent \| review-residual \| status \| finish` | The 8-step crew-ship engine the execution crewmate runs: `lint` opt-in (`--lint`), `test` skipped on `--tdd`, `intent`/`review` unskippable, `--target` for a non-default branch. Past `review.max_rounds` it holds for `review-residual accept` or one `review-agent --final-round`. Spec: `bin/ac-ship.sh` header. |
| `ac-ship-watch.sh [--repo DIR] [--self-pane ID] [--interval SECS] [--once]` | Read-only live dashboard of a crew-ship run; `ac-ship.sh start` opens it and it self-closes when the run finishes or idles. Spec: `bin/ac-ship-watch.sh` header. |
| `ac-verify.sh codereview \| qa` | Synchronous exact-ref verification facade for two kinds: leases an isolated worktree at the exact commit, neutralizes its instruction files for the round, runs one pane agent, releases everything at harvest. `--history` narrows round 2+ to the interdiff. Spec: `bin/ac-verify.sh` header. |
| `ac-qa.sh start \| step \| case \| visual \| findings \| testplan-amend \| fixture \| harness-classify \| regression-proposal \| curation \| store-install \| store-curate \| store-label \| store-calibration \| infra \| baseline \| serve \| health \| boundary-run \| boundary-register \| seed \| cmd \| config \| config-proposal \| config-install \| evidence-dir \| store-dir \| fix-report \| relay-report \| fetch-check \| agent \| status \| finish` | Behavioral QA state machine: frozen coverage manifest, immutable config/scope/store/routing bundle, boundary policy (proof only from the booted deliverable's boundaries, never a unit-suite run), fail-closed terminal gate; `agent` adapts `ac-verify qa`. Spec: `bin/ac-qa.sh` header. |
| `ac-qa-watch.sh [--repo DIR] [--self-pane ID] [--interval SECS] [--once]` | Read-only live dashboard of a qa run, including the case ledger; `ac-qa.sh start` opens it and it self-closes on finish or idle. Spec: `bin/ac-qa-watch.sh` header. |
| `ac-review-diff.sh <id> [--stat \| --live \| --uncommitted \| --untracked \| --graph] [--tree <worktree>]` | A crewmate's change against the merge-base with the default branch; the default is committed-only, the chief's delivered-change review. The body also documents `--graph-data` for the dashboard. Spec: `bin/ac-review-diff.sh` header. |
| `ac-pr-check.sh <id> <github-pr-url>` | Records `pr=` and `pr_head=` on the task meta; informational, since teardown gates on `pr_merged=1`. Spec: `bin/ac-pr-check.sh` header. |
| `ac-pr-merge.sh <id> <github-pr-url> [-- <gh merge flags>]` | Merges a PR after captain approval (squash by default, `--repo` rejected), warning on landing overlaps and recording the landing ledger. Spec: `bin/ac-pr-merge.sh` header. |
| `ac-merge-local.sh <id> [--no-ff]` | Lands a local-only task from `crew/<id>` into the clone's default branch: fast-forward only by default, refusing up front when not an ancestor; `--no-ff` lands a conflict-free merge and aborts cleanly on conflict. Spec: `bin/ac-merge-local.sh` header. |
| `ac-feature.sh create \| verify \| show \| retire \| ship` | Feature integration-branch verbs over `data/<feature>/branches` (`push=deferred`): `create` cuts locally and never pushes, `verify` judges the local ref, `ship` is the gated exit (members terminal, one review round at the tip, qa when pinned, no target drift) ending in one push and one PR per repo. Mutating verbs are chief-only. Spec: `bin/ac-feature.sh` header. |
| `ac-epic-branch.sh create\|verify <epic> <repo> \| show\|retire <epic>` | Per-epic integration-branch verbs over `data/<epic>/branches`: `create` cuts at the freshest default tip and never moves an existing branch, `verify` is quiet enough to gate on, `retire` marks the record's end. Mutating verbs are chief-only. Spec: `bin/ac-epic-branch.sh` header. |
| `ac-epic-ship.sh <epic> <repo> [--dry-run]` | The epic gate and 2-PR exit: stories terminal, captain receipts for failed/abandoned stories, a zero-fix review at the exact tip, qa when pinned; then `branch -> staging`, and `branch -> default` only once PR-1 is proven merged. Never merges. Spec: `bin/ac-epic-ship.sh` header. |
| `ac-push-gate.sh hook \| check <range>` | Pre-push privacy gate: scans outgoing diffs, messages and idents against an operator-owned pattern file outside the repo; exit 1 on a match, or on no patterns under `AC_PUSH_GATE_REQUIRE=1`. A floor, never proof. Spec: `bin/ac-push-gate.sh` header. |

## Gates

| Script | What it does |
|---|---|
| `ac-gate.sh <family> <spec\|architecture\|plan\|design> [--round 1\|2] [--rule <n\|default>] [--repo <p>] [--ref <ref>]` / `ac-gate.sh maintenance --mode <learning\|curate> --run <dir> --subject <id> --manifest <file> --plan <file>` | One advisory second-chief decision in a fresh non-resumed session (`panes.gate` profile), allowed only when `ac-room.sh gate-route` derived `route=second-chief` for the exact report; the maintenance form judges one hash-bound Learning/Curate plan. Spec: `bin/ac-gate.sh` header. |
| `ac-gate-watch.sh [SECS] \| --tail [--family F] [--stage S] [--round 1\|2] [--self-pane ID] [--interval SECS] [--once]` | Read-only, home-scoped observer of second-chief gates running right now; it shows only bytes the harness actually emitted. `ac-gate.sh` opens a per-run `--tail` board. Spec: `bin/ac-gate-watch.sh` header. |

## Knowledge and learning

| Script | What it does |
|---|---|
| `ac-know.sh add \| retire \| cite \| recall \| verify \| scope-proposal \| scope-install` | The per-project repo-knowledge record `records/repo-knowledge/<name>.md`: provenance and freshness per entry, `add` refusing a covered subject (unless `--supersede` or `--new`), `cite` bumping heat, tiered `recall`, and the chief-installed monorepo scope path. Spec: `bin/ac-know.sh` header. |
| `ac-scene.sh new \| update \| merge \| show \| list` | The L2 scene store `records/scenes/<slug>.md`, heat-tracked and capped by `config/scene-max` (default 30): `new` refuses near the cap, `update`/`merge` always work, and `merge` moves sources verbatim to `scenes-archive/`. Spec: `bin/ac-scene.sh` header. |
| `ac-learn.sh tick \| autoroom \| suite \| run \| note \| route-propose \| land \| promote \| maintenance status\|resume\|abandon \| rotate-pending \| stale \| reinforce` | Automatic fleet-local Learning: keyed cadence tick, the gated auto-room (ledger-shape gate, then full-suite gate), the scout run, `note` placing lessons under `## Pending`, and the maintenance transaction. `route-propose` is the System One hint; `land`/`promote` are compatibility-only. `rotate-pending` bounds the Pending body, `stale` grades the always-loaded layer, `reinforce` refreshes an entry on stated evidence. Spec: `bin/ac-learn.sh` header. |
| `ac-curate.sh learnings \| captain [--apply] \| backlog [--apply] \| projects \| skills-audit \| skills-consolidate [--apply] \| run [--dry-run]` | Records-wide Curate: `run`, called by a complete Learning run when `config/curate-every` is due, applies deterministic moves through the maintenance transaction and routes semantic subjects to the gate or the captain; `--dry-run` writes nothing. Spec: `bin/ac-curate.sh` header. |
| `ac-brain.sh sync \| recall \| remember \| forget \| entity \| context_pack \| delta \| links-to \| synthesize \| stats \| doctor \| serve` | CLI wrapper for the per-home memory engine: resolves the home (`--home` > `AC_HOME`) and execs bun; every verb prints one JSON value. The engine's header is the authoritative spec. Spec: `bin/ac-brain.sh` header. |
| `ac-brain-engine.ts` | The memory engine: a rebuildable SQLite index over the home's markdown plus the `state/facts.md` ledger, hybrid recall with citations, provenance-required `remember`, MCP `serve`; usage lines record `by` (`solo` under `AC_SOLO=1`). Spec: `bin/ac-brain-engine.ts` header. |

## System One

| Script | What it does |
|---|---|
| `ac-jev.sh ask \| label \| sha \| status` | The System One adapter: closed-set questions in, validated typed answers out, behind `config/jev` (`off` default, `shadow` logs only, `on` also prints). Every failure prints one `jev:` reason on stderr, nothing on stdout, and exits 0; answers are logged to `state/jev-shadow.jsonl`. Spec: `bin/ac-jev.sh` header. |
| `ac-compact-advise.sh <transcript.jsonl> --role chief\|crew \| --hook` | "Should this session /compact now?" at the System One `compact` site, ported from compact-adviser (MIT). As a Stop hook it judges only a SOLO session or a fleet-home chief; every failure prints nothing and exits 0. Spec: `bin/ac-compact-advise.sh` header. |

## Hooks

| Script | What it does |
|---|---|
| `ac-sessionstart-nudge.sh` | SessionStart hook (claude and cursor): prints the run-session-start reminder, the SOLO-session notice under `AC_SOLO=1`, and the inert-hooks notice for a chief-shaped session without `AC_HOME`; silent in a linked worktree or a home whose lock is held live. Always exits 0. Spec: `bin/ac-sessionstart-nudge.sh` header. |
| `ac-turnend-guard.sh` | Stop hook blocking a blind turn end (own wakes pending, own watcher beacon stale, or a remote-wired idle fleet unwatched), carried to other harnesses by their own surfaces. Under `AC_SOLO=1` it never blocks and only notices a slice worktree with uncommitted changes. Fails open. Spec: `bin/ac-turnend-guard.sh` header. |
| `ac-turnend-guard-cursor.sh` | Cursor `stop` adapter for the turn-end guard: cursor's stop cannot block, so it emits at most one bounded `followup_message` and always exits 0. Spec: `bin/ac-turnend-guard-cursor.sh` header. |
| `ac-watch-autoarm.sh` | Claude Stop hook (`asyncRewake`) holding the watcher while supervision is owed: re-arms silently on `heartbeat`, stands aside for a running watcher, wakes the chief on anything else. A SOLO session never arms. Spec: `bin/ac-watch-autoarm.sh` header. |
| `ac-watch-policy-hook.sh` | PreToolUse (Bash) hook denying pattern-based watcher kills (`pkill`/`killall`/pgrep-fed `kill` naming watch); a plain `kill <pid>` stays allowed. Fails open. Spec: `bin/ac-watch-policy-hook.sh` header. |
| `ac-watch-policy-cursor.sh` | Cursor `beforeShellExecution` adapter that reshapes the payload for `ac-watch-policy-hook.sh` and passes its exit code through. Fails open. Spec: `bin/ac-watch-policy-cursor.sh` header. |
| `ac-delegation-guard.sh` | PreToolUse hook refusing harness-native delegation (tool shapes `Task`, `*Agent*`, `*Workflow*`) from a chief-shaped session (fleet home, primary checkout, or a chief that lost `AC_HOME`); crewmate worktrees and SOLO sessions are exempt. Spec: `bin/ac-delegation-guard.sh` header. |
| `ac-ledger-guard.sh` | PreToolUse hook refusing a scoped session's (`AC_SCOPE`) Edit/Write to `records/backlog.md`, `records/projects.md` or `records/captain.md`; Bash-tool writes are a stated residual. Fails open. Spec: `bin/ac-ledger-guard.sh` header. |
| `ac-primary-guard.sh` | PreToolUse hook refusing a crewmate (`AC_CREW_ID`) or roomchief (`AC_SCOPE`) edit that resolves inside the primary checkout but outside its own tree; the captain is never fenced. Fails open. Spec: `bin/ac-primary-guard.sh` header. |
| `ac-prompt-recall.sh` | Prompt-submit hook handing a SOLO session or a fleet-home chief the top brain recall hits and freshness (a stale brain triggers a catch-up sync), plus a pending-wake count for chiefs; silent in crewmate worktrees and under `config/brain-prompt-recall=off`. Never blocks a prompt. Spec: `bin/ac-prompt-recall.sh` header. |
| `ac-prompt-recall-cursor.sh` | Cursor `beforeSubmitPrompt` adapter wrapping `ac-prompt-recall.sh` output in cursor's continue envelope; always exits 0. Spec: `bin/ac-prompt-recall-cursor.sh` header. |

## Dashboard

| Script | What it does |
|---|---|
| `ac-dashboard.sh [--port <N>] \| start \| stop \| restart \| status [--port <N>]` | Launches the Bun web dashboard: bare is foreground (default port 8787); the daemon verbs run it detached with pid and log under `$AC_HOME/state/`, idempotent and recycled-pid-safe. Spec: `bin/ac-dashboard.sh` header. |
| `dashboard.ts` | Launcher shim keeping the stable entry path `ac-dashboard.sh` execs; the implementation and its route/API contracts live in `dashboard/app.ts`. Spec: `bin/dashboard.ts` header. |
| `ac-review.sh open \| poll \| reply \| end \| url <file>` | Crewmate CLI for the dashboard's native annotate loop over an `.html` or `.md` artifact; `poll` long-polls, and a down dashboard is a loud refusal. Spec: `bin/ac-review.sh` header. |
| `ac-page-lint.sh` | Page-syntax lint: boots its own dashboard, extracts every inline `<script>` from a fixed page list and compiles each with `bun build --no-bundle`. Exit 1 on a confirmed syntax error, 3 when only tooling failed. Spec: `bin/ac-page-lint.sh` header. |

## Remote

| Script | What it does |
|---|---|
| `ac-remote.sh poll \| ingest \| order \| show \| reply \| link \| followup \| ack \| thread-post \| done-stamp \| push-pending \| gc` | Remote captain orders over user-owned `config/` hooks; `poll` is a hard no-op without an executable `config/remote-poll`. Stashes orders under `state/remote-inbox/` with one fleet wake per rid; `order` is how a SOLO session hands work to the chief; `gc` is manual. Spec: `bin/ac-remote.sh` header. |
| `ac-github.sh poll --repo <path> \| comment --repo <path> --pr <n> --body <text>` | GitHub intake DETECTOR: records new open issues/PRs of the clone's `origin` and publishes one `github` fleet wake each; `comment` posts a caller-supplied verdict, idempotent per text. Never mints, verifies, spawns or merges; fails closed on any `gh` error. Spec: `bin/ac-github.sh` header. |

## Domains and deputies

| Script | What it does |
|---|---|
| `ac-domain.sh new \| assign \| unassign \| queue \| qa-repo \| list \| validate \| retire` | Crewdomain verbs: build the package under `crewdomains/<name>/`, stamp or strip `domain:<name>` on backlog rows in place, print a domain's slice, declare its e2e repository (`qa-repo`), list ORPHAN-TOKENs, retire fail-closed. Shares nothing with `ac-deputy.sh`. Spec: `bin/ac-domain.sh` header. |
| `ac-deputy.sh list \| validate \| report '<text>' [--doc <abs>] \| handoff <deputy-id> <backlog-id>...` | Crewdeputy routing layer: renders the full routing table with one liveness state per entry, `validate` as its strict twin, `report` as the deputy-to-parent return channel, and `handoff` moving queued rows all-or-nothing. Spec: `bin/ac-deputy.sh` header. |
| `ac-home-seed.sh <name> (--projects <p1,p2> \| --no-projects)` | Provisions a crewdeputy home (inherited knobs, runtime symlinks, clones from the parent's) registered with an EMPTY, never-routable scope. Refuses an existing home. Spec: `bin/ac-home-seed.sh` header. |

## Setup and tooling

| Script | What it does |
|---|---|
| `ac-setup.sh` | One-off machine setup, INTERACTIVE captain tool: toolchain doctor, optional captain tools, homes container, `ac` launcher; never edits dotfiles. Spec: `bin/ac-setup.sh` header. |
| `ac-fleet-new.sh [<name>] [--container <dir>]` | Creates a top-level fleet home, INTERACTIVE captain tool: one prompt per knob, a knob file written only when a value was typed, `config/backend` seeded as `herdr`. Refuses an existing home. Spec: `bin/ac-fleet-new.sh` header. |
| `ac-bootstrap.sh [--quiet]` | Toolchain doctor with stable line prefixes (`OK:`, `MISSING:`, `BELOW-FLOOR:`, `NO-CAPABILITY:`, `OPTIONAL:`, ...); exit 1 only when a required tool is missing, below floor or lacking its capability, or the backend compat check fails. Spec: `bin/ac-bootstrap.sh` header. |
| `ac-lint.sh [--all]` | The single lint definition (`bash -n` plus shellcheck) over its owned script set; by default only changed files, `--all` for the full set. Spec: `bin/ac-lint.sh` header. |

## Libraries sourced by others

| Script | What it does |
|---|---|
| `ac-lib.sh` | Core helpers every script sources: home and paths (`AC_HOME` required), meta files, locks, config, crewdeputy routing grammar, task data dirs, marker regexes, `AC_DONELINE_AWK`, the landing ledger, crewmate seeding, git helpers. It does not source the sub-libs below. Spec: `bin/ac-lib.sh` header. |
| `ac-wake-lib.sh` | Wake scope keying and the `ac_wake_publish` record protocol, the watcher nudge, room pending/handback matchers, and the chief-quiet predicates. Spec: `bin/ac-wake-lib.sh` header. |
| `ac-maintenance-lib.sh` | Learning DISTILL and Curate cadence gates plus the shared hash-bound maintenance transaction and its receipt validator. Spec: `bin/ac-maintenance-lib.sh` header. |
| `ac-qa-lib.sh` | The `ac_qa_*` validators (attestation, bundle, testplan, coverage, receipts) and the merge-time qa gate read by `ac-merge-local.sh` and `ac-pr-merge.sh`. Spec: `bin/ac-qa-lib.sh` header. |
| `ac-pipeline-lib.sh` | Shared by `ac-ship.sh` and `ac-qa.sh`: the YAML subset reader, the fail-closed findings normalizer and summary, and the transcript-final and verdict-JSON readers. Spec: `bin/ac-pipeline-lib.sh` header. |
| `ac-watch-dash.sh` | Shared rendering and loop body of `ac-ship-watch.sh` and `ac-qa-watch.sh`; sourced only. Spec: `bin/ac-watch-dash.sh` header. |
