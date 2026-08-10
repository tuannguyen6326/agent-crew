# Scripts reference

Each script's header comment is its authoritative spec; this table is the map.

| Script | Purpose |
|---|---|
| `ac-session-start.sh` | Ordered session-start digest: toolchain, wakes, fleet, backlog, projects, crewdeputy routing table, supervision block. Spec: `bin/ac-session-start.sh` header. |
| `ac-pool-health.sh [--repo <path>]...` | Session-start ride-along: per-repo worktree-pool slot health, naming the exact reclaim command for a stuck slot. Spec: `bin/ac-pool-health.sh` header. |
| `ac-standing-jobs.sh` | Session-start ride-along: each DECLARED standing job's state from `records/standing-jobs.md`. Spec: `bin/ac-standing-jobs.sh` header. |
| `ac-bootstrap.sh [--quiet]` | Toolchain doctor: `OK:`/`MISSING:`/`NEEDS_GH_AUTH:`/`OPTIONAL:` lines; exit 1 on missing required tools. Spec: `bin/ac-bootstrap.sh` header. |
| `ac-brief.sh <id> <project> [--scout \| --stage <s>] [--mode <m>] [--review yes\|no] [--captain-requested <ref>]` | Scaffold the authoritative brief layout and derive the task's recorded review obligation; the optional direct-flow raise to `review=yes` is refused unless `--captain-requested` declares whose call it was. Spec: `bin/ac-brief.sh` header. |
| `ac-spawn.sh <id> <project> [...]` | Lease an in-repo worktree, open a herdr tab, and launch one crewmate from its brief; also owns guarded roomchief and crewdeputy spawn/recovery. Spec: `bin/ac-spawn.sh` header. |
| `ac-self-task.sh start <id> <project>\|log <id> '<line>'` | Make a SMALL chief-side edit VISIBLE on herdr - the sanctioned exception to "real project work goes to a crewmate". Spec: `bin/ac-self-task.sh` header. |
| `ac-dispatch-select.sh [--list \| --rule <n> \| --pane <kind> ...]` | Resolve a crew-dispatch profile into `harness= model= effort=`. Spec: `bin/ac-dispatch-select.sh` header. |
| `ac-setup.sh` | One-off machine setup, INTERACTIVE (a captain tool). Spec: `bin/ac-setup.sh` header. |
| `ac-fleet-new.sh [<name>] [--container <dir>]` | Create a top-level FLEET home, INTERACTIVE (a captain tool). Spec: `bin/ac-fleet-new.sh` header. |
| `ac-home-seed.sh <name> --projects <csv>\|--no-projects` | Provision a persistent crewdeputy home with inherited config and project clones, registered with an EMPTY `scope:`. Spec: `bin/ac-home-seed.sh` header. |
| `ac-deputy.sh list` | Render the `-- crewdeputies (routing table) --` digest block with one liveness state per entry. Spec: `bin/ac-deputy.sh` header. |
| `ac-deputy.sh validate` | The strict twin of `list`: exit 1 naming every INVALID registry line. Spec: `bin/ac-deputy.sh` header. |
| `ac-deputy.sh report '<text>' [--doc <abs>]` | The crewdeputy -> parent RETURN CHANNEL, run INSIDE a deputy home. Spec: `bin/ac-deputy.sh` header. |
| `ac-deputy.sh handoff <deputy-id> <backlog-id>...` | Move named `## Queued` backlog lines byte-identically into the deputy's ledger, all-or-nothing. Spec: `bin/ac-deputy.sh` header. |
| `ac-domain.sh new\|assign\|unassign\|audit\|list\|validate` | The CREWDOMAIN verb layer: build the four-member package at `crewdomains/<name>/`, move fleet `## Queued` rows into its backlog (stamping `assigned:crewchief`) and back, report untokened rows, render the digest block, and check the registry plus the project view. Separate from `ac-deputy.sh` in every way - own registry, own root, own verbs. Spec: `bin/ac-domain.sh` header. |
| `ac-peek.sh <id> [<lines>]` | Bounded tail of a crewmate pane. Spec: `bin/ac-peek.sh` header. |
| `ac-send.sh <id> [--force] '<text>' \| --key <k>` | Send one literal line - typed, then submitted VERIFIED - or one named key; also the routed-order channel for a crewdeputy target. Spec: `bin/ac-send.sh` header. |
| `ac-crew-state.sh <id>` | One deterministic current-state line. Spec: `bin/ac-crew-state.sh` header. |
| `ac-fleet-view.sh` | One line per crewmate: id, kind, project, mode, state, window. Spec: `bin/ac-fleet-view.sh` header. |
| `ac-room.sh post\|show\|list\|close\|open\|pending\|handback\|gate-route\|gate-verify\|disposition` | Per-family captain thread (`data/<family>/room.md`): gates, asks, decisions, inbox, fail-closed close, consented redirect, deterministic per-report routing and gate receipts. Spec: `bin/ac-room.sh` header. |
| `ac-ship-watch.sh [--repo D] [--once]` | Live crew-ship run dashboard. Spec: `bin/ac-ship-watch.sh` header. |
| `ac-pane-agent.sh run\|close\|reap-pane\|reap\|steer` | Pane-turn helper shared by every independent pane agent: ONE agent turn in a herdr pane over an NDJSON protocol, in one of THREE ARMS. Spec: `bin/ac-pane-agent.sh` header. |
| `ac-gate.sh <family> <spec\|architecture\|plan\|design> [--round 1\|2] [--repo <project-or-path>] [--ref <git-ref>]` / `ac-gate.sh maintenance --mode <learning\|curate> --run <dir> --subject <id> --manifest <file> --plan <file>` | Conditional independent SECOND CHIEF from `panes.gate`, allowed only by `route=second-chief`; one fresh non-resumed one-shot turn, no engine fallback, and an immutable repo/context manifest; also the maintenance gate. Spec: `bin/ac-gate.sh` header. |
| `ac-gate-watch.sh [SECS] \| --tail [--family F] [--stage S] [--round 1\|2] [--self-pane ID] [--once]` | ACTIVE-run second-chief observer, HOME-scoped: shows only gates running right now. Spec: `bin/ac-gate-watch.sh` header. |
| `ac-ready.sh [queued \| watch-set <fam> \| validate <epic> \| overlap <path>...]` | Queued-work scheduler primitive (idempotent, read-only): READY/STUCK report, watch sets, epic validation, file-overlap check. Spec: `bin/ac-ready.sh` header. |
| `ac-relocate.sh <id> [--family <fam> \| --root]` | Move a live task window into a family workspace (default: its own family) or the fleet root workspace without losing its claude session. Spec: `bin/ac-relocate.sh` header. |
| `ac-dash.sh [--watch [<s>]]` | Captain dashboard IN the terminal. Spec: `bin/ac-dash.sh` header. |
| `ac-fleets.sh [--json] [<container>]` | Strictly read-only cross-fleet survey. Spec: `bin/ac-fleets.sh` header. |
| `ac-dashboard.sh [--port <N>]` | Launch the local Bun dashboard in the foreground; `bin/dashboard.ts` is the implementation and owns the route/API contracts. Spec: `bin/ac-dashboard.sh` header. |
| `ac-statusline.sh` | One-line fleet status for status bars. Spec: `bin/ac-statusline.sh` header. |
| `ac-watch.sh [--once \| --release <pid>]` | Zero-token watcher: polls panes and stage artifacts, publishes each wake durably to its scope's spool, and exits with one reason line. Spec: `bin/ac-watch.sh` header. |
| `ac-done.sh <id> <marker>` | The agent-side completion PUSH: publish ONE durable wake record and end the armed watcher's poll wait at once. Spec: `bin/ac-done.sh` header. |
| `ac-follow.sh <id>` | Realtime full-fidelity stream of a crewmate's claude transcript. Spec: `bin/ac-follow.sh` header. |
| `ac-session.sh <id> [--talk]` | Print a resume of the crewmate's session: forked safe view by default, `--talk` un-forked. Spec: `bin/ac-session.sh` header. |
| `ac-wake-drain.sh [ack <id>...]` | Atomically drain the wake store of THIS session's scope. Spec: `bin/ac-wake-drain.sh` header. |
| `ac-github.sh poll --repo <path>\|comment --repo <path> --pr <n> --body <text>` | GitHub intake DETECTOR: records new open issues/PRs durably and wakes the fleet spool; posts a caller-supplied verdict on a PR, idempotent per exact text. Never mints, verifies, or spawns. Spec: `bin/ac-github.sh` header. |
| `ac-remote.sh poll\|ingest\|show\|reply\|link\|followup\|push-pending\|gc` | Transport-agnostic remote captain orders (slack-mode core). Spec: `bin/ac-remote.sh` header. |
| `ac-sessionstart-nudge.sh` | Claude SessionStart hook: print the run-`ac-session-start.sh` reminder into a fresh session. Spec: `bin/ac-sessionstart-nudge.sh` header. |
| `ac-turnend-guard.sh` | Claude Stop hook: block a blind turn end, scoped to the session's own supervision obligations. Spec: `bin/ac-turnend-guard.sh` header. |
| `ac-tree.sh get\|list\|return\|prune\|remove` | In-repo pooled worktrees at `<repo>/.crew/worktrees/` with locked mutations, lease reclaim, remote-verified prune, gated remove. Spec: `bin/ac-tree.sh` header. |
| `ac-ship.sh start\|step\|findings\|meta\|cmd\|attest-test\|attest-check\|push\|base\|evidence-dir\|skip-remaining\|config\|fix-report\|review-agent\|status\|finish` | Deterministic 8-step crew-ship engine run by the execution crewmate that implemented the task. Spec: `bin/ac-ship.sh` header. |
| `ac-verify.sh codereview\|qa ...` | Synchronous independent-verification facade for exactly two kinds (codereview, qa). Spec: `bin/ac-verify.sh` header. |
| `ac-notify.sh <title> <msg>` | Best-effort captain notification over the `config/wedge-alarm` channel. Spec: `bin/ac-notify.sh` header. |
| `ac-review.sh open\|poll\|reply\|end\|url <file>.html` | Crewmate CLI for the dashboard's native annotate loop: thin curl shim over the review API - the dashboard owns sessions, anchors, and the viewer (`bin/dashboard.ts` review block). Spec: `bin/ac-review.sh` header. |
| `ac-review-diff.sh <id> [--stat]` | Crewmate change vs merge-base with the default branch. Spec: `bin/ac-review-diff.sh` header. |
| `ac-pr-check.sh <id> <url>` | Record PR + head SHA on the task meta. Spec: `bin/ac-pr-check.sh` header. |
| `ac-pr-merge.sh <id> <url> [-- flags]` | Merge the PR after captain approval, with the landing interlock. Spec: `bin/ac-pr-merge.sh` header. |
| `ac-merge-local.sh <id> [--no-ff]` | Fast-forward a local-only project's default branch to `crew/<id>`. Spec: `bin/ac-merge-local.sh` header. |
| `ac-teardown.sh <id> [--force]` | Fail-closed task teardown: prove landed work, archive state, close panes, sweep verifiers, release the lease. Spec: `bin/ac-teardown.sh` header. |
| `ac-promote.sh <id> [--mode <m>]` | Promote a scout to a ship task in place. Spec: `bin/ac-promote.sh` header. |
| `ac-lock.sh acquire\|status\|release` | Per-home chief session lock: one fleet-driving session at a time. Spec: `bin/ac-lock.sh` header. |
| `ac-sync.sh [<project>]` | Clone-freshness sweep. Spec: `bin/ac-sync.sh` header. |
| `ac-guard.sh` | Warn-only fleet advisory (WATCHER-DOWN / QUEUED-WAKES / TANGLE / WIP-TOOLING), always exit 0. Spec: `bin/ac-guard.sh` header. |
| `ac-harness.sh` | Sourced per-harness registry (known set, busy regex, instruction file, pane arm, startup key, recorded-opts policy); a 4th harness edits this file plus the two launch tables. Spec: `bin/ac-harness.sh` header. |
| `ac-watch-autoarm.sh` | Claude Stop hook: the fleet re-arms its OWN watcher instead of the chief remembering to. Spec: `bin/ac-watch-autoarm.sh` header. |
| `ac-watch-policy-hook.sh` | PreToolUse hook denying the broad process-kill patterns that would take down watchers cross-session; fails open. Spec: `bin/ac-watch-policy-hook.sh` header. |
| `ac-delegation-guard.sh` | PreToolUse hook refusing harness-native delegation from a chief's own checkout. Spec: `bin/ac-delegation-guard.sh` header. |
| `ac-ledger-guard.sh` | PreToolUse hook refusing a scoped session's write to `records/backlog.md` or `records/projects.md`. Spec: `bin/ac-ledger-guard.sh` header. |
| `ac-primary-guard.sh` | PreToolUse hook refusing a write that resolves inside the primary checkout but outside the session's own tree. Spec: `bin/ac-primary-guard.sh` header. |
| `ac-qa-watch.sh [--repo D] [--self-pane ID] [--once]` | Live qa run dashboard (the `ac-ship-watch.sh` role for qa). Spec: `bin/ac-qa-watch.sh` header. |
| `ac-qa.sh start\|step\|case\|visual\|findings\|testplan-amend\|fixture\|harness-classify\|regression-proposal\|curation\|store-install\|infra\|baseline\|serve\|health\|boundary-run\|boundary-register\|seed\|cmd\|config\|config-proposal\|config-install\|evidence-dir\|store-dir\|fix-report\|relay-report\|fetch-check\|agent\|status\|finish` | Behavioral QA state machine with a terminal completion gate, frozen coverage manifest, and immutable config/scope/store/routing bundle. Spec: `bin/ac-qa.sh` header. |
| `ac-project-mode.sh <name>` | Resolve the `+yolo` flag from `records/projects.md` - yolo ONLY: delivery mode is per-task (row contract pin / `--mode`, resolved by `ac-brief.sh`). Spec: `bin/ac-project-mode.sh` header. |
| `ac-know.sh add\|retire\|verify\|scope-proposal\|scope-install` | The per-project REPO-KNOWLEDGE record (`records/repo-knowledge/<name>.md`) plus the monorepo scope proposal/install path. Spec: `bin/ac-know.sh` header. |
| `ac-learn.sh tick [<landing-id>]\|autoroom\|suite [<task-id>]\|run\|note <line>...\|land\|promote\|maintenance status\|resume <txid>\|abandon <txid>` | Automatic fleet-local Learning: cadence tick, gated auto-room, scout run, the placing append of landing lessons under `## Pending`, staged skill/patch transaction. Spec: `bin/ac-learn.sh` header. |
| `ac-curate.sh learnings\|captain\|backlog\|projects\|skills-audit\|skills-consolidate\|run [--dry-run]` | Automatic records-wide Curate, paced by `state/.curate.meta` / `config/curate-every` and invoked by a complete Learning run when due. Spec: `bin/ac-curate.sh` header. |
| `ac-archive.sh archive [--dry-run]\|restore <family> [--dry-run]` | MANUAL ONLY (no automatic caller, by design): relocate CLOSED families to `data/archive/<year>/<family>/` and back. Spec: `bin/ac-archive.sh` header. |
| `ac-lint.sh [--all]` | Single owner of the lint definition (bash -n + shellcheck); by DEFAULT lints only the CHANGED files in its owned set. Spec: `bin/ac-lint.sh` header. |
| `ac-backend.sh` | Sourced session-backend primitives over herdr (the only backend): window new/alive/send/capture/kill, the WINDOW LIVENESS and CAPTAIN-WAIT STAMP contracts, plus the herdr pane-agent workspace/tab helpers (`ac_herdr_agents_workspace`, `ac_herdr_tab_open`, moved from `ac-lib.sh` by audit-f3). Spec: `bin/ac-backend.sh` header. |
| `ac-lib.sh` | Sourced CORE helpers, split by audit-f3 down to what every script needs: home/paths, meta files, locks, config, crewdeputy convergence + routing table, task data dirs, the backlog Done-line grammar, task state files, the landing ledger, crewmate seeding, and git helpers. Spec: `bin/ac-lib.sh` header. |
| `ac-wake-lib.sh` | Sourced helpers (audit-f3, split from `ac-lib.sh`): wake scope keying and the `ac_wake_publish` record protocol, the watcher nudge, room pending/handback accounting, the two CHIEF-QUIET predicates. Spec: `bin/ac-wake-lib.sh` header. |
| `ac-maintenance-lib.sh` | Sourced helpers (audit-f3, split from `ac-lib.sh`): the Learning DISTILL + Curate cadence gates, and the shared Learning/Curate maintenance transaction (hash-bound plan validate/apply). Spec: `bin/ac-maintenance-lib.sh` header. |
| `ac-qa-lib.sh` | Sourced helpers (audit-f3, split from `ac-lib.sh`): the `ac_qa_*` validation block - attestation/bundle/testplan/coverage/receipt validators and the merge-time qa gate. Spec: `bin/ac-qa-lib.sh` header. |
| `ac-pipeline-lib.sh` | Sourced helpers shared by the two pipeline state machines (`ac-ship.sh` + `ac-qa.sh`). Spec: `bin/ac-pipeline-lib.sh` header. |
| `ac-watch-dash.sh` | Sourced shared body of `ac-ship-watch.sh` and `ac-qa-watch.sh`. Spec: `bin/ac-watch-dash.sh` header. |
