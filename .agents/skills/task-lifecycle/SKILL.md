---
name: task-lifecycle
description: The chief's step-by-step task mechanics from backlog row to teardown: brief scaffolding, spawn (backend, model/effort, dispatch, instruction seeding per harness), supervision, review of the delivered diff, landing per mode, fail-closed teardown, the landing-time learning duties (ledger notes, repo facts, keyed tick, DISTILL, Curate), the worktree pool, and the full supervision protocol (watcher arming, wake reasons, drain). Load before scaffolding a brief, spawning, handling a wake, landing, tearing down, or recording learnings at landing.
---

# task-lifecycle

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Steps 1-8

When the family is promoted at intake, steps 2-3 belong to its ROOMCHIEF, not to you: promote first, hand it the order, and let it scaffold the brief and spawn its own crewmate.
A crewmate the crewchief spawns instead carries no family scope for its whole life, so its completions push-file to the fleet spool and reach the roomchief only through a manual forward.

1. Record the task in `records/backlog.md` (section 9) and pick a short id (`[a-z0-9-]`).
2. `bin/ac-brief.sh <id> <project> [--scout | --stage <spec|architecture|plan|design|implement|qa>] [--mode <m>] [--review yes|no] [--captain-requested <ref>]` scaffolds the brief (flat `data/<id>/brief.md`, or nested `data/<family>/<stage>/brief.md` for staged flows), resolves the mode (row pin > `--mode`; REQUIRED for non-scout work - the registry default is gone), runs the escalation gate (a heavy value needs a row pin, or `--captain-requested` + `--reason`, the `intake-triage` skill's escalation clause), derives and records the review obligation, and refuses normal `code-review`/`ship` stages; edit it with the real task, constraints, acceptance criteria, and stage inputs before spawning. `ac-spawn.sh` reads the brief's recorded `Mode:` - ONE resolver; a contradicting spawn flag refuses.
3. `bin/ac-spawn.sh <id> <project> [--scout] [--harness <h>] [--model <m>] [--effort <e>] [--backend <b>]` leases the task's worktree and opens its pane, both per the fleet's session backend (`config/backend`): a herdr fleet leases a pooled worktree INSIDE the project repo (`<repo>/.crew/worktrees/<n>`) and opens a herdr tab in the task FAMILY's workspace - every pane of one family (chief, crewmates, verification panes, watch tabs) co-tenants one `<fleet> · <family>` workspace, fleet-level panes the root `<fleet>` one (`bin/ac-backend.sh` FAMILY WORKSPACE GROUPING owns the contract) - while an orca fleet leases an Orca-managed worktree per task on `crew/<id>` from the local default branch (`bin/ac-backend-orca.sh` orca_worktree_lease; removed at teardown) and opens an Orca terminal (chief-kind panes under the home's node, worker panes under their worktree's node). Either way the harness launches on the brief.
   Model and effort are fleet-wide defaults: absent `--model`/`--effort` fall back to `config/model` and `config/effort`; the `--effort` FLAG (`low|medium|high|xhigh|max|ultracode`) is claude-only, while the effort VALUE also reaches codex as its `-c model_reasoning_effort=<tier>` config override and pi as `--thinking <tier>` (verified pi 0.84.2), and opencode ignores it.
   `--effort ultracode` launches claude at `xhigh` and types `/effort ultracode` into the built-in claude TUI to add the workflow-orchestration layer (claude built-in only; `AC_ULTRACODE_SETTLE` gates the pause before the kickoff prompt).
   When `config/crew-dispatch.json` exists, spawn refuses to guess: read `bin/ac-dispatch-select.sh --list`, judge which `when` clause matches the task, resolve it with `--rule <n>`, and pass the profile explicitly.
   Fleet-wide crewmate instructions are seeded automatically into the instruction file the SPAWNED HARNESS actually loads - `AGENTS.md` for codex (verified: codex loads that file and nothing else at session start), for opencode (verified on a live opencode 1.18.5 pane 2026-07-27: it loads that file and does NOT load `.claude/CLAUDE.md`), for pi (verified pi 0.84.2 on this host: its `--no-context-files` switch names AGENTS.md and CLAUDE.md discovery, so a bare launch discovers the worktree AGENTS.md itself), and for cursor (doc-cited: cursor.com/docs/context/rules places AGENTS.md agent instructions at the project root; the live probe upgrades this once cursor-agent is logged in), the worktree's `.claude/CLAUDE.md` for every remaining harness. A repo-shipped copy of the target wins outright; otherwise the seed MERGES `<container>/.claude/CLAUDE.md` (the baseline shared by every fleet under the homes container) first with `$AC_HOME/CREWMATE.md` (the fleet-specific layer) after it - a single available source is copied as-is. Consequence a chief must know: in a repo that ships its OWN root `AGENTS.md` (this distro does - it is the chief law), a codex crewmate reads that shipped file and NOT the fleet crewmate layer; the fleet-wide rules it still needs are the ones stated in this file. A claude crewmate here reads BOTH: the tracked root `CLAUDE.md` symlinks to this file, so it carries the chief law - including the "never do project work yourself" identity block - alongside the seeded `.claude/CLAUDE.md` crewmate layer in the same context; its brief is its contract, not this file's identity block. The fleet harness settings (enabled plugins, permission allowlists) are seeded the same way into the worktree's `.claude/settings.json` (repo-shipped wins, then `$AC_HOME/.claude/settings.json`, then the container copy) - copied, never symlinked, so a crewmate's own permission grants stay local to its worktree. Starter at `docs/examples/CREWMATE.md`.
   They carry the runtime-skill rule for EVERY stage: crewmates discover and prefer the skills their session provides (project plugins first) instead of any pre-defined list - the brief stays the contract.
4. Supervise (section 7); steer with `bin/ac-send.sh <id> '<text>'`, inspect with `bin/ac-peek.sh <id>` and `bin/ac-crew-state.sh <id>`.
5. Review the delivered change with `bin/ac-review-diff.sh <id>` before anything merges.
   Chiefs verifying a crewmate's delivered tree accept a FRESH `bin/ac-ship.sh attest-check` (run in the worktree) instead of re-running the suite; re-run only when it reports stale or no attestation.
6. Land it: crew-ship/direct-pr tasks end in a PR (`bin/ac-pr-check.sh` to record it, captain approves, `bin/ac-pr-merge.sh` to merge); local-only tasks land via `bin/ac-merge-local.sh <id>`; feature-pr members land the same local way onto the recorded feature branch, and the feature exits once through `bin/ac-feature.sh ship`.
7. `bin/ac-teardown.sh <id>` - fail-closed: it refuses while work is unlanded; `--force` is the captain explicitly discarding work.
   Done does not wait for the PR merge: when a PR task's PR is ready to merge (CI green, review done), ask the captain, and their acceptance lands the task via `--pr-ready '<the captain's words>'` - the merge stays the captain's own act.
   The exception is a task other open rows are `blocked-by`: a dependent starts from the merged tree, so a depended-on task lands only by the real merge (the flag refuses it).
8. Update the backlog and record learnings - AUTOMATICALLY, as part of
   LANDING, never deferred to a captain /debrief: the moment a task/family
   lands, exactly ONE actor appends the run's durable lessons to
   records/learnings.md with `bin/ac-learn.sh note` - never by hand: it
   PLACES them under `## Pending`, the only section the next Learning
   transaction reads, while an append at end-of-file lands after
   `## Distilled`, where that transaction deletes it - the roomchief,
   BEFORE its handback, for a promoted family; the crewchief for
   unpromoted work, and also for a promoted family whose roomchief
   ended WITHOUT handing back (the handback is the observable
   signal the roomchief's debrief happened; absent it, the crewchief writes
   rather than letting the lessons die with the dead session) (a stage
   report's method lessons about the crew's own work count too, not only
   what the room recorded). A report's `## Lessons` lines (the section
   contract every crewmate carries - docs/examples/CREWMATE.md) are folded
   VERBATIM, never paraphrased, each suffixed `(by: <task-id>, first-hand)`:
   the experiencer authors the words, the chief only holds the pen - the
   ledger stays single-writer, but nothing is lost in translation. The
   chief's own observed lessons ride beside them as before.
   SPLIT THE REPO FACTS OUT FIRST, before the note: a `## Lessons` line stating
   something VERIFIED ABOUT THE CODEBASE (a call graph, a column's nullability,
   what a decorator actually emits) belongs in
   `records/repo-knowledge/<project>.md` via `bin/ac-know.sh add` with its
   provenance, and only the METHOD half of that line goes to the ledger - one
   line often carries both. `add` REFUSES a subject a live entry already
   covers, printing that entry and two exits - `--supersede '<phrase>'`
   (retire the old and add yours in one locked write) or `--new` (declare it
   genuinely distinct): two live claims about one subject is the defect, and
   the record's whole purpose is that the next family reads rather than
   re-derives. The crewmate is already told to do this before it
   hands back (docs/examples/CREWMATE.md), so this is the chief's backstop, not
   a second author. It matters because nothing downstream recovers a repo fact
   that lands in the ledger by mistake: Learning's scout routes a lesson to
   `patch`, `crewmate` or `skill` and has no repo tier, so the fact is simply
   not landed and is archived with the rest of the consumed window - lost,
   though a crewmate had proved it. The two records also answer different
   questions: repo-knowledge carries a freshness marker so a later family can
   re-check a fact against a moved tree, while the always-loaded crewmate layer
   is fleet-wide and would serve one repo's fact to every other repo's crewmate
   out of a 4096-byte budget.
   Also move the backlog line to Done, update
   captain.md/projects.md if the session changed them, and run
   `bin/ac-learn.sh tick <family>` - KEYED on the landing.
   The key still keeps the counter at exactly one per landing even though
   both the roomchief (before handback) and the crewchief (at landing) may
   each run the tick, because neither can see the other's tick.
   Whoever gets there second is told its tick skipped, and changes nothing.
   The UNKEYED `bin/ac-learn.sh tick` stays unguarded and belongs to the
   session /debrief, which is not a landing.
   The DISTILL run AUTO-TRIGGERS at the crossing - nobody decides it
   (LEVEL-triggered on durable state, so a lost wake, a restart, or a counter
   already past threshold still fires; a SCOPED session never fires it -
   promotion is the crewchief's act). The FULL SUITE gate is FLEET-OPT-IN:
   only a fleet that pins `config/learn-suite-gate=on` is gated - whether a
   fleet's DISTILL waits on this repo's suite is that fleet's own rule, and
   the default is off. In a gated fleet the trigger releases a promote only
   on a GREEN `tests/run-suite.sh` verdict recorded for the current cadence
   generation AND tree, otherwise it starts that suite as its own paned task
   and HOLDS, saying so on the drain - a red is fixed FIRST and Learning
   waits, because a retro reasoning about a fleet whose suite is red inherits
   the defect. The promoted
   `learning` roomchief is
   `initiated_by=system`, CAP-EXEMPT (never consumes a `config/room-parallel`
   slot), and its `DECIDED:` receipt names the standing captain order it carries
   out, never claims the captain asked now. The fresh-eyes `learning` scout
   proposes and NEVER mutates fleet state; only a real
   `ask-captain`/unavailable gate/contradiction/rule proposal asks the captain.
   Learning runs no QA or unit tests. Learned skills remain fleet-local.
   Learning's output routes by USE, not by habit:
   a method/reasoning lesson lands as a `kind: crewmate` entry in the
   machine-owned `$AC_HOME/CREWMATE-learned.md` - seeded into every crew
   worktree as its own always-loaded layer, captain's CREWMATE.md reading
   later and winning on conflict - while `kind: skill` is reserved for
   demonstrated procedures, each landing with a discovery-pointer line in
   that same file; grammar, budgets, and guards are owned by the
   `bin/ac-learn.sh` header. The
   spawn claim, firing predicate, scout, canonical ledger/archive, gate,
   transaction, and migration contracts are owned by the
   `bin/ac-learn.sh`/`bin/ac-lib.sh` headers.
   Each DISTILL run is also the records-wide CURATE "tick" (session-start flags
   `CURATE DUE: <n>/<X>` at/over `config/curate-every`). On CURATE DUE the
   Learning runs `bin/ac-curate.sh run` automatically; its `--dry-run` is fully
   read-only and project clones are never deleted.
   CURATE HAS NO FIRING PATH OF ITS OWN, and the counter above counts DISTILL
   RUNS, not landings - so with `curate-every` materially smaller than
   `learn-every` the threshold is reached long before the next DISTILL is, and
   the flag then stands up for the rest of that interval with nothing able to
   discharge it (e.g. `CURATE DUE: 3/2` standing while landings sit mid-interval).
   That is not a defect to fix by inventing a second scheduler: the digest names
   the distance to the DISTILL that will run it and the manual
   `bin/ac-curate.sh run` for a chief that wants it now, so a standing DUE flag
   is readable rather than noise.
   Unresolved `ask-captain` subjects keep Curate due. The exact policies are
   owned by the `bin/ac-curate.sh` header.
   /debrief stays the manual catch-all (route + curate uncaptured knowledge,
   reconcile rooms and fleet state fail-closed, return a reset verdict); landing
   remains the primary mechanism.

Ship tasks deliver a project change AND a `report.md` handback note next to their brief - its only required section is `## Lessons`, unconditional across every ending; scout tasks deliver ONLY a `report.md` next to their brief (the full report contract) and never open a PR.
`crew/<id>` is the one branch a crewmate may create.

## Worktrees (section 6)

`bin/ac-tree.sh` pools detached-HEAD worktrees inside each project repo under `.crew/worktrees/<n>`, auto-gitignored - the HERDR fleets' lease mechanism; an orca fleet leases Orca-managed worktrees instead (step 3 above).
Worktrees are reused, not deleted: `return` resets to the freshest default branch and releases; ignored caches survive.
`get --repo <p> --id <task> --holder crew:<id>` is what spawn uses; leases live in `.crew/slots/<n>.meta`, are durable, and survive restarts.
An available-but-dirty slot is never silently reset: acquire and prune skip it, and only `remove --force` discards it.
`bin/ac-session-start.sh` surfaces any such stuck slot in a `-- pool (worktree health) --` block (via `bin/ac-pool-health.sh`), naming the exact `remove --force <path>` to reclaim it; the block is silent when every pool is healthy.
`list` shows the pool; `prune --yes` removes idle merged slots (dry-run without `--yes`); `remove` is deliberate single-slot removal.
`lease <slot> --repo <p> --id <task> --holder <h>` durably leases an EXISTING slot state-only (no reset, no fetch) - the way to keep a long-lived tree (QA infra, a parked investigation) from `get` and `prune` without leaving it dirty for pool health to report as stuck; `return` releases it like any other lease (the `LEASE` block in `bin/ac-tree.sh` owns the contract).
Editor access: open the generated `<repo>/.crew/<repo>.code-workspace` (regenerated on every slot mutation) - it lists the repo plus every currently leased worktree as folders, so VSCode/Cursor shows active task trees as repositories without idle pool slots filling the Git tab; return removes a slot from the generated file and the next lease adds it back with the new task label. `ac-tree.sh` does not control a live editor window, so reopen/reload when the editor does not apply external workspace-file changes itself.
Never create worktrees by hand in a project repo.

## Supervision (section 7)

The watcher is your eyes; it costs zero tokens while nothing happens.
Arm it whenever crew is in flight: the watcher MUST be the harness's OWN background task - the harness runs `bin/ac-watch.sh`, tracks it, and is woken by its exit.
On claude the Stop hook `bin/ac-watch-autoarm.sh` (asyncRewake) now does that FOR you: while supervision is owed it holds a watcher in its own process tree, re-arms silently on every `heartbeat`, and wakes you with the reason on anything actionable - so a heartbeat no longer costs a wake plus a re-arm turn, and forgetting is no longer a way to go blind.
It never takes a watcher you armed yourself (`already running` -> it stands aside), and it says so loudly when it hands coverage back; the rule above stays your fallback whenever it is not running - another harness, a session that did not load the hook, or a handback message from the hook itself.
NEVER `nohup`/`&`/`disown` it inside a tool call: that orphans the watcher (the harness tracks the wrapper, which returns instantly), so its exit reason wakes no one and it silently degrades from your real-time eyes to a note found only at the next turn boundary.
It polls panes, absorbs benign output, and exits with one reason line - the full vocabulary (it also covers a remote-order poll's own outcomes and a TERM/INT signal) is owned by the header of `bin/ac-watch.sh`, next to the printf sites that emit it; what matters here is what you DO on each - `report:<id>` (a captain-relevant line appeared, or a stage `report.md` appeared/advanced - the artifact channel wakes with no pane cooperation), `gone:<id>`, `unobservable:<id>` (the BACKEND could not be read, so the pane's liveness is UNKNOWN - this is NOT a death and no work is lost: fix the backend, never tear the crew down; `bin/ac-backend.sh`'s WINDOW LIVENESS owns why a `gone` verdict now requires a definite answer from a reachable backend), `ask:<id>` (the backend says the agent is BLOCKED on an interactive prompt - answer or steer it at once), `ended:<id>` (the pane ENDED ITS TURN with no marker - it is waiting on you with an ask the marker regex cannot see, so read the pane), `stale:<id>` (merely quiet while working - the soft signal - OR a pane that read BUSY past `AC_BUSY_MAX` with no turn end, the busy-stall bound: busy is evidence of a process, never of progress, so a pane hung inside a single tool call wakes once per busy run instead of staying invisible), `push:<id>` (an agent announced its OWN completion with `bin/ac-done.sh` - the record is already in the spool, so drain and act), or `heartbeat` - after publishing the wake durably to its scope's spool (`state/.wake-spool[.<family>]/`, one record per file; the drain claims and emits them - a promoted family's spool is drained only by its roomchief).
A quiet pane whose last status-log line is the worker's own wait declaration (`paused:` or a captain-wait marker), or whose latest review findings hold an undecided `ask-user`, is DEFERRED once per declaration instead of reported stale - the idle clock restarts, and a full window of silence after that still reports it (the STALE DEFERRAL block in `bin/ac-watch.sh`'s header owns the rule).
Deep inspection: `bin/ac-follow.sh <id>` streams the crewmate's full claude transcript (read-only); `bin/ac-session.sh <id>` prints a safe forked resume, `--talk` an un-forked one (refused mid-turn) whose words persist into a later `--resume-from`.
On any wake: `bin/ac-wake-drain.sh`, act on each wake (peek, steer, unblock, escalate, teardown), then RE-ARM the watcher before the turn ends.
`bin/ac-watch.sh --once` is the bounded foreground checkpoint when a background task is not available.
Crewmates signal through their pane: `done:`, `blocked:`, `needs-decision:`, `failed:` lines (AC_CAPTAIN_RE) are what wake you.
The watcher is the BACKUP channel: every agent also PUSHES its completion (`bin/ac-done.sh <id> '<marker>'`, taught by the brief seed and CREWMATE.md), which publishes the same durable record and ends the watcher's poll wait at once - so a completion reaches you in milliseconds, and the watcher is what catches an agent that crashed or forgot. One completion still wakes you exactly once.
A `kind=self` meta (`bin/ac-self-task.sh`, section 5) is the ONE class excluded from supervision: its pane holds a `tail -f` and no agent, so the watcher does not poll it and it owes no watcher coverage - it can never emit a marker, and waking you about your own typing is a self-loop that would also pin your turn while you edit.
It stays in ACCOUNTING (every fleet view lists it), and nothing about `ship`/`scout`/`roomchief`/`crewdeputy`/`verify-*` supervision changes; `ac_meta_is_self` in `bin/ac-lib.sh` owns the contract.
