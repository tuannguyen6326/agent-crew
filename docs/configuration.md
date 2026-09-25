# Configuration

This page is the reference for everything a fleet reads as configuration: the fleet home's `config/` files, the records the captain owns, the per-project pipeline yaml, the environment variables, and the toolchain floors.
Each row says what a knob controls, its values and default, and which script header owns the full contract.
When a row and a script header disagree, the header wins and the row is a doc bug.

## Fleet home `config/` files

Every file lives under `$AC_HOME/config/` and is local and gitignored.
A plain-text knob is read by `ac_config_read` (`bin/ac-lib.sh`): the first line of the file, trimmed, or the default when the file is absent.
A read never creates the file or the directory, so a homeless reader (a crewmate pane) simply gets the default.

### Identity and flow policy

| File | Controls |
| --- | --- |
| `config/captain` | How the fleet addresses the human, e.g. `echo Alex > config/captain`; absent = `captain`. Shown in the session-start digest and stamped into briefs (`ac_captain`, `bin/ac-lib.sh`). |
| `config/flow` | Default task flow: `auto` (default: the chief triages each order), `direct` or `staged`. Printed in the session-start digest; the chief applies it at intake. |
| `config/promote` | Room promotion policy: `always` (default: every family gets a roomchief at intake, up to `config/room-parallel`), `auto` (the chief triages promotion per family) or `never` (rooms stay records). Printed in the session-start digest; the chief applies it at intake. |
| `config/epic-parallel` | Max stories of one epic in flight at once; default 2. Read by `bin/ac-ready.sh`. |
| `config/room-parallel` | Max roomchiefs in flight at once; default 5. `ac-spawn.sh --roomchief` refuses past it; the exemptions (`--captain-initiated`, `--system-initiated`, `--over-cap`) are in the `bin/ac-spawn.sh` header. |

### Crewmate launch: harness, model, effort

| File | Controls |
| --- | --- |
| `config/crew-harness` | Default crewmate harness; absent = `claude`. The built-in registry is `AC_HARNESS_RE` in `bin/ac-harness.sh` (`claude`, `codex`, `opencode`, `pi`, `cursor-agent`); any other name needs its own `config/launch-<h>` template. |
| `config/model` | Fleet-wide default crewmate model when `--model` is absent; absent = the harness default. A per-spawn `--model` always wins. Also the last rung for non-verification pane agents (`bin/ac-pane-agent.sh`: flag > `AC_FLEET_MODEL` > `config/model`). |
| `config/effort` | Fleet-wide default reasoning effort when `--effort` is absent: `low`, `medium`, `high`, `xhigh`, `max` or `ultracode`; absent = the harness default. An invalid value fails the spawn. Per-harness mapping (claude `--effort`, codex `model_reasoning_effort`, pi `--thinking`) and the `ultracode` slash-line behavior are in the `bin/ac-spawn.sh` header. |
| `config/launch-<harness>` | Launch command template that replaces the built-in one for that harness. Placeholders `__BRIEF__` and `__ID__` are substituted; a custom template may also read `$AC_PROMPT` (the kickoff prompt). Owner: the `bin/ac-spawn.sh` header. |
| `config/crew-dispatch.json` | Dispatch rules for crewmates and pane agents; see [Dispatch rules](#dispatch-rules-configcrew-dispatchjson) below. |

### Verification panes: codereview, qa, gate

The codereview and qa panes each have an agent/model/effort triple that is chosen together as one rung, so a model is never composed onto a harness a different rung picked.
A dispatched `panes.<kind>` profile in `config/crew-dispatch.json` supersedes the whole triple.

| File | Controls |
| --- | --- |
| `config/codereview-agent` | Harness for the `ac-verify codereview` pane; absent = `claude`. Precedence: `--harness` > `AC_FLEET_AGENT_CODEREVIEW` > this file > `claude`. |
| `config/codereview-model` | Model for the codereview pane; absent = `opus`. Precedence: `--model` > `AC_FLEET_MODEL_CODEREVIEW` > this file > `opus`. It does not inherit `config/model`. |
| `config/codereview-effort` | Effort for the codereview pane. Precedence: `--effort` > `AC_FLEET_EFFORT_CODEREVIEW` > this file > the fleet effort ladder (`AC_FLEET_EFFORT` > `config/effort`). |
| `config/qa-agent` | Harness for an unrouted qa pane; absent = `claude`. Same shape as `codereview-agent` (`AC_FLEET_AGENT_QA`). |
| `config/qa-model` | Model for an unrouted qa pane; absent = `opus`. A routed `panes.qa.rules[]` selection is passed explicitly by the caller and never combined with this file. |
| `config/qa-effort` | Effort for an unrouted qa pane; same shape as `codereview-effort` (`AC_FLEET_EFFORT_QA`). |
| `config/gate-agent` | Second-chief engine for a report routed `second-chief`: a registry harness (default `codex`) or `off`. `off` is read from this file alone and disables the gate (exit 4, never approval). One engine, no fallback. Owner: the `bin/ac-gate.sh` header. |
| `config/gate-model` | Model for the gate judge; absent = the engine default. `AC_GATE_MODEL` overrides per call. |
| `config/gate-effort` | Effort for the gate judge; absent = the engine default. `AC_GATE_EFFORT` overrides per call. |

A dispatched `panes.gate` profile outranks `gate-agent`/`gate-model`/`gate-effort` and is atomic: its empty model or effort means that engine's own default.
`AC_GATE_AGENT` outranks the profile's harness; when it names a different engine, nothing is taken from the profile.

### Session backend

| File | Controls |
| --- | --- |
| `config/backend` | Session backend for new tasks: `herdr` (default) or `orca`. Recorded per task at spawn, so changing it never re-routes an in-flight task. Resolution ladder: `AC_BACKEND` row below. |
| `config/herdr-session` | herdr only: the named herdr session to talk to; absent = no `--session` flag (the ship/qa/gate watch openers pass `default`). |
| `config/herdr-rpc-timeout` | herdr only: seconds one herdr RPC may run before it is killed with its process group; default 2, and anything that is not a positive integer falls back to 2. A killed RPC reads as unobservable, never as a dead pane. Owner: HUNG RPC in the `bin/ac-backend.sh` header. |
| `config/orca-node` | Orca only: the full Orca worktree selector (`id:<repo-id>::<path>[::workspace:<id>]` or `path:<path>`) that chief-kind home panes attach to; absent = the nearest registered ancestor of the home path. Read only when a family tab is created. Owner: `bin/ac-backend-orca.sh`. |

The former `config/herdr-workspace`, `herdr-workspace-agents` and `herdr-workspace-chiefs` pins are retired and read by nothing; herdr tabs now group by family (FAMILY WORKSPACE GROUPING in the `bin/ac-backend.sh` header).

### Learning, curation and knowledge

| File | Controls |
| --- | --- |
| `config/learn-every` | Learning DISTILL cadence: once the counter advanced by `bin/ac-learn.sh tick` reaches this value, the session-start digest flags `LEARNING DUE` and the automatic `learning` room opens; default 8. Owner: the `bin/ac-learn.sh` and `bin/ac-maintenance-lib.sh` headers. |
| `config/curate-every` | Curate cadence in settled Learning runs; default 5. At the threshold Learning runs `bin/ac-curate.sh run`, whose header owns the policies. |
| `config/learn-suite-gate` | `on` makes the DISTILL trigger wait for a green `tests/run-suite.sh` verdict for the current generation and tree; anything else (default) = off. |
| `config/learn-pending-budget` | Byte budget for the learnings ledger's `## Pending` body at DISTILL staging; default 131072. Older bullets past it are archived verbatim to `records/learnings-archive/` (`ac-learn.sh rotate-pending`). |
| `config/learn-stale-days` | Age in days past which an always-loaded `CREWMATE-learned.md` entry or a scene grades stale; default 30. Grading is read-only (`ac-learn.sh stale`, the session-start `-- knowledge --` block). |
| `config/scene-max` | Tiered file-count cap on the L2 scene store `records/scenes/`; default 30. It gates `new` only; `update` and `merge` stay legal. Owner: the `bin/ac-scene.sh` header. |
| `config/codegraph` | Automatic CodeGraph indexing of each leased crew worktree: `on` (default) or `off`. Background and best-effort; needs `codegraph` on PATH. |

### Memory engine (brain)

| File | Controls |
| --- | --- |
| `config/brain-auto-sync` | Valve for the shared brain-freshen slot (fleet watcher cycle and prompt-time recall): `on` (default) or `off`. The slot fires only when `state/brain.sqlite` exists, at most once per `AC_BRAIN_SYNC_IV`. |
| `config/brain-prompt-recall` | Valve for prompt-time recall (`bin/ac-prompt-recall.sh`): `on` (default) or `off`. It fires only for a solo session or a chief whose cwd is the fleet home, and prints at most `AC_PROMPT_RECALL_LIMIT` hits. |
| `config/brain.json` | Brain engine settings: `embedding` (`provider`, `model`, `dims`, `base_url`), `reranker`, `synthesize.api`, and the `excludes` list for sync. Edited from the dashboard's brain config panel. Owner: the `bin/ac-brain-engine.ts` header. |
| `config/brain-agent`, `config/brain-model`, `config/brain-effort` | Harness, model and effort for `ac-brain synthesize` when `crew-dispatch.json` has no `panes.brain` entry; absent = `config/crew-harness` + `config/model`. `AC_BRAIN_SYNTH_CMD` overrides all of it. |
| `config/providers.json` | Per-home secret store for LLM provider keys, one entry per provider name holding `api_key`. The brain engine reads an env var first, then this file; `bin/ac-jev.sh` reads its bearer key only from here. Edited from the dashboard's Providers panel. Keep it operator-only. |

### System One adapter (jev) and compact advice

| File | Controls |
| --- | --- |
| `config/jev` | The System One adapter `bin/ac-jev.sh`: `off` (default: no key read, no request, no output), `shadow` (requests are made and logged to `state/jev-shadow.jsonl`, stdout stays empty) or `on` (as shadow, plus the validated answer on stdout as a proposal the caller may add). The model never decides. `AC_JEV` overrides per session. Callers and their outputs: the `bin/ac-jev.sh` header. |
| `config/jev-provider` | Provider `ac-jev.sh` talks to: `openrouter` (default), `typesafe`, `opencode` or `laya` (the loopback sandbox, no key). Each maps to an endpoint, a `providers.json` entry and a model id listed in the `bin/ac-jev.sh` header. |
| `config/jev-laya-port` | Loopback port of the `laya` sandbox (`http://127.0.0.1:<port>/v1/systemone`); default 8765. |
| `config/compact-window` | Context-window size in tokens that `bin/ac-compact-advise.sh` divides a session's context by; default 200000. `AC_COMPACT_WINDOW` wins. |

### Remote orders and notifications

| File | Controls |
| --- | --- |
| `config/remote-poll` | Executable transport hook that prints new captain messages as JSON lines for `ac-remote.sh poll`. Its presence turns remote mode on (the watcher's poll slot, the drain's `push-pending`, the turn-end guard's standing-coverage rule). Owner: the `bin/ac-remote.sh` header. |
| `config/remote-reply` | Executable hook that posts stdin into the remote thread (`AC_REMOTE_RID`, `AC_REMOTE_THREAD`). Required by `ac-remote.sh reply` and `followup`. |
| `config/remote-ack` | Optional executable hook run at each order lifecycle edge (`AC_REMOTE_ACK_STATE` = `ingested`, `working`, `done`). Absent = no-op; a failure is one warning, never a block. |
| `config/remote-poll-interval` | Seconds between the fleet watcher's remote polls when `AC_REMOTE_POLL` is unset; default 300 when `config/remote-poll` is executable. Non-numeric or `0` = slot off. |
| `config/remote-poll-timeout` | Seconds one remote poll may run before the watcher kills it; default 120, non-positive values fall back to 120. Keep it plus `AC_POLL` under `AC_GUARD_GRACE`. Owner: HUNG POLL in the `bin/ac-watch.sh` header. |
| `config/remote-mirror` | Task-thread narrative: `off` (default), `chief` (the owning chief posts its own thread narrative via `ac-remote.sh thread-post`) or `on` (every room post and spawn announce is mirrored automatically). |
| `config/slack-channel`, `config/slack-captain-id` | Slack transport only: control channel id, and the captain member id(s) one per line (also used for `<@id>` pings). Read by the example hooks in `docs/examples/slack-remote/` and the dashboard; setup guide in that directory's README. |
| `config/wedge-alarm` | Captain notification when a room gate or ask is pending on them: `off`, `auto` (default: herdr when herdr is the backend and installed, else osascript, else bell), `herdr`, `osascript`, `bell` or `command:<cmd>` (receives `AC_NOTIFY_TITLE` and `AC_NOTIFY_MESSAGE`). Owner: the `bin/ac-notify.sh` header. |

### Misc

| File | Controls |
| --- | --- |
| `config/dash-port` | Port `bin/ac-review.sh` expects the dashboard on; default 8787, `AC_DASH_PORT` overrides. Keep it in agreement with `ac-dashboard.sh --port`. |
| `config/sync-timeout` | Per-project fetch watchdog in seconds for `bin/ac-sync.sh`; default 60, `AC_SYNC_TIMEOUT` overrides. A hung remote is reported FAILED. |

### Crewdeputy convergence

A crewdeputy home pulls the knobs listed in `AC_INHERITABLE_CONFIG` from its parent at session start, absence included (`ac_config_converge_from_parent`, `bin/ac-lib.sh`).
Identity and local knobs (`captain`, `launch-*`, `herdr-*`) are never copied.

## Dispatch rules (`config/crew-dispatch.json`)

Example: `docs/examples/crew-dispatch.json`.
Owner: the `bin/ac-dispatch-select.sh` header.

- Top level: `rules[]` (each a prose `when`, an atomic `use` of `harness`/`model`/`effort`, and a non-empty `why`) plus a `default`.
  When the file exists, `ac-spawn.sh` refuses to guess: the chief reads `ac-dispatch-select.sh --list`, judges which `when` matches, and resolves it with `--rule <n>`.
- `panes.<kind>` configures pane agents.
  The routable kinds are `qa`, `gate`, `codereview` and `roomchief`; each takes either a flat profile or a routed `rules[]` + `default`.
  `gate`, `codereview` and `roomchief` require a routed `default`; for `qa` it stays optional and an unselected routed lookup resolves nothing.
- `panes.qa` rules are chosen by the execution caller (`ac-qa.sh agent --qa-rule <number|default>`) and frozen into the QA profile.
- `panes.codereview-scout.lanes[]` lists read-only scout lanes the code reviewer runs before it judges (`ac-dispatch-select.sh --pane <kind> --lanes`); absent = off. Owner: SCOUT LANES in the `bin/ac-verify.sh` header.
- `panes.brain` sets the `ac-brain synthesize` harness profile.
- An entry that exists but fails validation dies rather than falling back; an absent entry falls through to the pane agent's own ladder.
- A file with only `panes` still makes `ac-spawn.sh` require explicit crewmate dispatch, so keep top-level `rules`/`default` if crewmates use the same file.

## Records the captain owns

These files live under `$AC_HOME/records/` (resolved by `ac_records_dir`) and are hand-edited unless noted.

| File | Purpose |
| --- | --- |
| `records/captain.md` | The captain's standing rules and preferences, including `STANDING (domain:<name>):` lines for crewdomains. Read by intake and many guards; scoped sessions may not edit it (`bin/ac-ledger-guard.sh`). `bin/ac-curate.sh` archives only fully superseded or non-standing blocks. |
| `records/projects.md` | Project registry, one line per project: `- <name> [+yolo] - <description> (added <date>)`. Delivery mode is per task, not per project; a legacy `[<mode>]` is ignored. Grammar owner: the `bin/ac-project-mode.sh` header. |
| `records/crewdeputies.md` | Crewdeputy routing table: one line per deputy home with charter, `home:`, `scope:` and clones. Grammar owner: the `crewdeputy routing table` block in `bin/ac-lib.sh`; strict check `bin/ac-deputy.sh validate`. |
| `records/standing-jobs.md` | Declared standing jobs (id, cadence, on/off, re-create action) reported in the session-start digest. Grammar owner: the `bin/ac-standing-jobs.sh` header. |
| `records/rig.json` | Rig manifest: the home's declared identity, distro checkout, config-knob inventory and standing-job ids. Read only by `bin/ac-rig.sh drift`, whose header owns the grammar. |

## Crewmate instruction and settings layers

| File | Purpose |
| --- | --- |
| `$AC_HOME/CREWMATE.md` | Fleet-wide crewmate instructions, seeded at spawn into the file the harness loads: `AGENTS.md` for codex, opencode, pi and cursor, `.claude/CLAUDE.md` for claude and custom harnesses (`ac_harness_instruction_file`, `bin/ac-harness.sh`). Starter: `docs/examples/CREWMATE.md`. |
| `$AC_HOME/CREWMATE-learned.md` | Machine-owned learned layer, written only by `bin/ac-learn.sh`; never edit it by hand. |
| `<container>/.claude/CLAUDE.md` | Baseline shared by every fleet under the homes container (e.g. `~/Work/ac-homes/.claude/CLAUDE.md`). |
| `<container>/.claude/settings.json`, `$AC_HOME/.claude/settings.json` | Harness settings copied into each worktree's `.claude/settings.json`: repo-shipped > per-fleet > container. A copy, never a symlink. |
| `<container>/.claude/skills/<name>` | Overrides the distro's built-in crewmate skill of the same name when seeding (`ac_seed_crew_skills`). |

Seeding merges the available layers in the order container, learned, fleet, then the crewdomain's `CREWMATE.md` when the session is domain-bound; a single available layer is copied as is.
A repo-shipped instruction file wins outright, and the merged layer then lands at `.claude/CREWMATE.md`, which the kickoff prompt names as required reading.
Owner: `ac_seed_crewmate_md` in `bin/ac-lib.sh`.

## Per-project pipeline config (`projects/<name>.yaml`)

The file lives at `$AC_HOME/projects/<name>.yaml`, where `<name>` is the project clone's directory basename; a pool worktree resolves to its main repo.
It is home-only, captain-owned and branch-immune: the project repo is never a config source, so the branch under test cannot change its own commands or merge gate.
Resolver: `ac_project_config_file` (`bin/ac-lib.sh`); the legacy `config/projects/<name>.yaml` location is no longer read.
Example: `docs/examples/project-config.yaml`.
Authoritative key contracts: the `bin/ac-ship.sh` header (ship keys) and the `bin/ac-qa.sh` header (`qa.*` keys).

```yaml
commands:
  test: "npm test"
  lint: "npm run lint"
  format: "npm run format"

ignore_patterns:
  - "*.generated.*"
  - "vendor/**"

auto_fix:
  rebase: 3
  review: 3
  test: 3
  document: 3
  lint: 3

test:
  attestation: accept
  evidence:
    store_in_repo: false

qa:
  require_for_ship: true
  serve: "make dev"
  health: "curl -fsS $QA_BASE_URL/healthz"
  health_timeout: 60
  seed: "make db-seed"
  infra: [postgres, redis]
```

`ac-ship.sh config <dotted.key>` reads scalar values only; lists such as `ignore_patterns` and `qa.infra` are read by the agent.

### Ship keys

| Key | Controls |
| --- | --- |
| `commands.test`, `commands.lint`, `commands.format` | Commands `ac-ship.sh cmd <test\|lint\|format>` runs; exit 4 = not configured. |
| `commands.test-changed` | Optional scoped test template that must contain `{files}`; `cmd test` runs it on the changed set instead of the full suite. A scoped green completes the step but its receipt says `not-qualifies:scoped`. Owner: SCOPED TEST in the `bin/ac-ship.sh` header. |
| `auto_fix.<step>` | Fix-attempt budget per pipeline step. |
| `ignore_patterns` | Agent-read list of path patterns. |
| `document.instructions` | Project-specific guidance for the document step. |
| `test.attestation` | `accept` (default) lets a fresh `ac-ship.sh attest-test` run satisfy the test step while branch, HEAD, tree and test command still match; `ignore` always re-runs; any other value fails closed to running the suite. Owner: TDD ATTESTATION in the `bin/ac-ship.sh` header. |
| `test.evidence.store_in_repo`, `test.evidence.dir` | Where test evidence is written (`ac-ship.sh evidence-dir`). |
| `review.max_rounds` | Verifier invocations before the review loop holds for the owning chief's decision; default 3. |

### QA keys

The `qa:` block configures stable, approved execution mechanics; it is frozen from the fleet home at run start.
QA pane routing belongs to `config/crew-dispatch.json`, not to this yaml.

| Key | Controls |
| --- | --- |
| `qa.require_for_ship` | `true` makes both merge helpers require a parser-valid atomic v2 attestation for the exact head; file existence or a legacy marker is not enough. |
| `qa.serve` | Command that boots the service; it must honor `$QA_PORT`. App-level in a scoped project. |
| `qa.health` | Readiness probe; app-level in a scoped project. |
| `qa.health_timeout` | Seconds the bounded health poll waits; default 60. |
| `qa.seed` | Seed command run once after health; scope-level in a scoped project. |
| `qa.infra` | Infra compose profiles to boot (agent-read list, e.g. `postgres`, `redis`, `temporal`, `wiremock`); absent boots nothing. |
| `qa.mocks_compose` | Optional extra compose file for mocks; safety-linted. |
| `qa.fixtures.profile`, `qa.fixtures.resolver` | Approved fixture reference names, resolved before the pane starts; never raw secrets. |
| `qa.e2e.command` | Approved E2E runner; the QA pane selects cases with `ac-qa.sh cmd e2e --cases <ids>`. |
| `qa.e2e.repo` | Separate E2E repository: a local clone (a project name under `$AC_HOME/projects`, or a path) that must already exist. QA leases a second worktree at a frozen SHA. |
| `qa.e2e.ref_policy` | How the E2E SHA is chosen; only `configured-default-branch-head` today. |
| `qa.e2e.workdir`, `qa.e2e.endpoint_env`, `qa.e2e.fixture_profile` | E2E product mapping: the workdir inside the E2E worktree (default `.`), an explicit map from the suite's own env vars to runtime URLs, and a fixture profile name. Scope-level in a scoped project. |
| `qa.scopes.<scope>` | Monorepo only: per-scope `seed` and `e2e` mapping, and `apps.<app>.serve`/`health`. |

In a monorepo the closed list of scopes lives in the repo-knowledge record (`bin/ac-know.sh`), never in the yaml, and every scoped invocation names both `--scope` and `--app`; there is no inference.
Owner: SCOPED CONFIG and SEPARATE E2E REPOSITORY in the `bin/ac-qa.sh` header.

A project with no QA config goes through the proposal path: a task agent drafts with `ac-qa.sh config-proposal`, and the chief reviews and installs it with `ac-qa.sh config-install`.
This onboarding is a chief-owned repair path, never normal verifier execution.

PROFILE RESOLVE: before any lease or pane exists, `ac-qa.sh agent` freezes one immutable profile bundle (config, scopes, selected store files, exact refs, the routing receipt and the exact-SHA ship test receipt named by `--ship-run`).
It returns `profile-ready`, `needs-profile`, `profile-conflict`, `profile-stale` or `ask-user`, and only `profile-ready` creates a pane.
Owner: the `bin/ac-qa.sh` header; completion-gate and attestation details are in `docs/qa-attestation.md`.

REQUIRED-PROFILE MATRIX: `ac-brief.sh --qa-required-profile <project>/<scope>/<app>` (repeatable) records a required set in `data/<family>/qa/manifest.json`.
With that manifest present and `qa.require_for_ship` enforced, every required profile needs a profiled passing attestation at the merge-head SHA.
Owner: `ac_qa_gate_ok` and `ac_qa_gate_matrix` in `bin/ac-qa-lib.sh`.

DOMAIN E2E REPOSITORY: a crewdomain may name the project holding its maintained end-to-end suite with `bin/ac-domain.sh qa-repo <domain> --set <project>`, stored as `$AC_HOME/crewdomains/<domain>/qa-repo`.
It configures no execution mechanics and mints no attestation, so `qa.require_for_ship` still needs the profile-driven route above.

## Environment variables

Defaults shown as `config/<x>, else <v>` mean the env var wins over the file, which wins over the built-in value.
Variables marked "launch line" are set by `ac-spawn.sh` on a crewmate's launch line; a crewmate pane has no `AC_HOME`, so these are its only channel back to the fleet.

| Var | Default | Meaning |
| --- | --- | --- |
| `AC_HOME` | required | The fleet home holding `config/`, `state/`, `data/`, `records/`, `projects/`. Unset is refused for writes. Convention: one fleet per subdirectory of `~/Work/ac-homes`, launched with `ac <fleet>` (`docs/examples/ac.zsh`). |
| `AC_HOMES_CONTAINER` | `~/Work/ac-homes` | Fleet-homes container used by `ac-setup.sh`, `ac-fleets.sh` and `ac-fleet-new.sh`. |
| `AC_SCOPE` | unset | Session identity of a roomchief: its family. Scopes the watcher, drain and guards. |
| `AC_DOMAIN` | unset | Session identity of a domainchief: its crewdomain, derived from the family row's `domain:<name>` token at promote. Consumers resolve it through `ac_domain_binding` (`bin/ac-lib.sh`). |
| `AC_SOLO` | unset | `1` marks a solo session (`ac <fleet> --solo`). `ac-session-start.sh` runs read-only (no lock, no drain); `ac-wake-drain.sh`, `ac-watch.sh`, `ac-spawn.sh` and `ac-send.sh` refuse; `ac-watch-autoarm.sh` stands down; the turn-end guard only gives a notice about uncommitted slice worktrees; the delegation guard exempts it; `ac-compact-advise.sh` (under `config/jev=on`) and `ac-prompt-recall.sh` still act on it. Contract: the `solo-session` skill. |
| `AC_BACKEND` | `config/backend`, else the `config/backend` beside `AC_FLEET_STATE`, else `herdr` | Session backend (`herdr` or `orca`), resolved per call by `ac_backend`. Scripts export it from the task meta so a task stays on its recorded backend. |
| `AC_HERDR_SESSION` | `config/herdr-session`, else none | herdr session name every herdr-touching script uses. Refused under the orca backend. |
| `AC_HERDR_RPC_TIMEOUT` | `config/herdr-rpc-timeout`, else 2 | Seconds one herdr RPC may run before its process group is killed. |
| `AC_WINDOW_FAMILY` | unset | herdr family-workspace routing: non-empty = that family's workspace, empty = the fleet root workspace, unset = derived from the task id. Set by the scripts that open panes. |
| `AC_STARTUP_DIALOG_BUDGET` | 15 | Seconds the startup-dialog sequence keeps polling a pane that is still unobservable (`bin/ac-backend.sh`). |
| `AC_SEND_SETTLE` | 0.4 | Seconds between the submit-verify probes after typing into a pane, and the pace of arrival re-reads. Owner: delivery verification in the `bin/ac-backend.sh` header. |
| `AC_SPAWN_SETTLE` | 8 | Seconds `ac-spawn.sh` waits after the launch line before typing the kickoff prompt; also the window of its came-up gate. Do not pin it to 0 outside tests. |
| `AC_ULTRACODE_SETTLE` | 2 | Seconds `ac-spawn.sh` waits after typing `/effort ultracode` before the kickoff prompt. |
| `AC_KICKOFF_READY_BUDGET` | 60 | Seconds `ac-spawn.sh` waits for the harness to report ready before delivering the kickoff prompt. |
| `AC_SPAWN_META_CLAIM_STALE_GRACE` | 15 | Seconds after which a dead claimant's spawn meta-claim is reclaimable. |
| `AC_SPAWN_META_CLAIM_TIMEOUT` | 30 | Seconds a spawn waits on a live meta-claim before refusing. |
| `AC_ROOM_OVERCAP_REASON` | unset | Same as `ac-spawn.sh --roomchief --over-cap`: a captain sanction that promotes one chief past `config/room-parallel` for this spawn only. |
| `AC_CLAUDE_TRANSCRIPT_ROOT` | `~/.claude/projects` | Root `ac_claude_transcript_path` globs to confirm a prompt arrived in a claude session. The test suite pins it to an empty directory. |
| `AC_CREW_SKILLS` | `crew-ship crew-verify crew-qa domain-e2e document` | Built-in skills symlinked into each crew worktree (`.claude/skills`, or `.agents/skills` for codex). |
| `AC_MAX_TREES` | `<repo>/.crew/config` `max_trees=`, else 8 | Worktree pool cap per project repo (`bin/ac-tree.sh`). |
| `AC_PORT_BASE` | 20000 | Base of the per-worktree port slots: slot `n` owns `AC_PORT_BASE + n*100` through `+99`, written to `<worktree>/.crew/ports.env`. |
| `AC_POLL` | 15 | Watcher poll interval in seconds. |
| `AC_HEARTBEAT` | 600 | Seconds with nothing actionable before the watcher exits `heartbeat`. |
| `AC_STALE` | 240 | Quiet-pane seconds before a wake: `ended:` when the pane ended its turn, else `stale:`. |
| `AC_BUSY_MAX` | 2700 | Seconds a pane may read busy with no turn end before one `stale:` wake per busy run; `0` disables. |
| `AC_BUSY_RE` | built-in spinner patterns | Pane content that means "still working". |
| `AC_DECISION_RE` | built-in | Captain-wait marker regex (the BLOCKED-stamp class, `bin/ac-lib.sh`). |
| `AC_WATCH_ONLY` | unset, defaulted to `AC_SCOPE` | Families a scoped watcher watches (`fam1,fam2`), normally from `ac-ready.sh watch-set <fam>`. With `AC_SCOPE` set it must contain it. Disables the remote poll slot. |
| `AC_WATCH_SKIP` | unset | Families the fleet watcher skips (promoted rooms). Self-revoking when the roomchief is gone or its beacon stays stale. Owner: the `bin/ac-watch.sh` header. |
| `AC_GUARD_GRACE` | 300 | Max watcher-beacon age before any surface treats the watcher as down (turn-end guard, `ac-guard.sh`, skip revalidation, statusline). |
| `AC_GUARD_QUIET` | 60 | Seconds `ac-guard.sh` stays silent before repeating an unchanged warning set. |
| `AC_GUARD_ROOT` | the resolved checkout | Anchor for `ac-guard.sh`'s checkout checks; tests pin it. |
| `AC_ARMLOG_KEEP` | 200 | Trim floor of the watcher arm log `state/.watcher-arm.log`. |
| `AC_STOPHOOK_LOG_KEEP` | 200 | Trim floor of the Stop-hook trace log `state/.stop-hooks.log`. |
| `AC_AUTOARM_BUDGET` | 3000 | Seconds `ac-watch-autoarm.sh` holds a watcher before handing coverage back. |
| `AC_CURSOR_TURNEND_CEILING` | 3 | Max consecutive turn-end objections a cursor primary receives before the stop adapter goes quiet (`bin/ac-turnend-guard-cursor.sh`). |
| `AC_LOCK_HARNESS_RE` | `$AC_HARNESS_RE` | Process names `ac-lock.sh` accepts as the chief harness when walking ancestry. |
| `AC_LOCK_STALE_GRACE` | 5 | Seconds before a mkdir-lock with a dead owner is reclaimed. |
| `AC_TASK_LOCK_TIMEOUT` | 10 | Seconds `ac-task.sh` waits for the backlog lock before refusing with nothing written. |
| `AC_REMOTE_POLL` | `config/remote-poll-interval`, else 300 when `config/remote-poll` is executable, else off | Seconds between remote-order polls; non-numeric or `0` = off. Only the lock-holding fleet watcher polls. |
| `AC_REMOTE_POLL_TIMEOUT` | `config/remote-poll-timeout`, else 120 | Seconds one remote poll may run before the watcher kills its process group and queues a `remote-timeout` wake. |
| `AC_REMOTE_ACK_TIMEOUT` | 20 | Seconds one `config/remote-ack` call may run. |
| `AC_REMOTE_ACK_BUDGET` | 30 | Total seconds one `ac-remote.sh` run may spend in `config/remote-ack`; further calls are skipped with one warning. |
| `AC_DASH_PORT` | `config/dash-port`, else 8787 | Port `ac-review.sh` reaches the dashboard on. |
| `AC_SHIP_WATCH` | `auto` | `off` disables the live ship board `ac-ship.sh start` opens. |
| `AC_SHIP_WATCH_IDLE` | 1800 | Idle seconds before the ship board closes itself. |
| `AC_QA_WATCH` | `auto` | `off` disables the live qa board `ac-qa.sh start` opens. |
| `AC_QA_WATCH_IDLE` | 1800 | Idle seconds before the qa board closes itself. |
| `AC_GATE_WATCH` | `auto` | `off` disables the gate watch board `ac-gate.sh` opens. |
| `AC_GATE_WATCH_IDLE` | 1800 | Idle seconds before the gate board closes itself. |
| `AC_GATE_AGENT` | `config/gate-agent`, else `codex` | Per-call gate engine override; it also outranks a `panes.gate` profile's harness. |
| `AC_GATE_MODEL` | `config/gate-model`, else engine default | Per-call gate model override. |
| `AC_GATE_EFFORT` | `config/gate-effort`, else engine default | Per-call gate effort override. |
| `AC_GATE_TIMEOUT` | 600 | Seconds the gate judge's pane turn may run; also sizes the chief busy declaration. |
| `AC_PANE_AGENT` | `bin/ac-pane-agent.sh` | Pane-turn helper used by the gate, the ship reviewer and the learning scout; tests swap it. |
| `AC_PANE_SCROLLBACK_LINES` | 400 | Lines harvested from pane scrollback when no transcript resolves (`bin/ac-pane-agent.sh`). |
| `AC_PANE_STALL_MAX` | 2700 | Seconds a pane-agent turn may show no transcript progress before it escalates; `0` disables. |
| `AC_PANE_SETTLE_TRIES` | 6 | Transcript re-reads when a turn ends with no final text yet. |
| `AC_PANE_SETTLE_SLEEP` | 0.5 | Seconds between those re-reads. |
| `AC_VERIFY_TIMEOUT` | 7200 | `ac-verify.sh` pane turn timeout; also sizes the chief busy declaration. |
| `AC_VERIFY_START_TIMEOUT` | 30 | `ac-verify.sh` pane start deadline. |
| `AC_VERIFY_LOCK_TIMEOUT` | 10 | `ac-verify.sh` family/kind serialization lock wait. |
| `AC_VERIFY_SCOUT_TIMEOUT` | 900 | Seconds one code-review scout lane may take; a lane past it is recorded as dropped. |
| `AC_VERIFY_CORRECTION_TIMEOUT` | 900 | Seconds the one correction turn may take when a verdict fails an envelope check. Owner: ONE CORRECTION TURN in the `bin/ac-verify.sh` header. |
| `AC_LEARN_TIMEOUT` | 7200 | `learning` scout pane turn timeout (`ac-learn.sh run`). |
| `AC_LEARN_START_TIMEOUT` | 30 | `learning` scout pane start deadline. |
| `AC_LEARN_SUITE_BIN` | `<snapshot>/tests/run-suite.sh` | Runner the full-suite gate task executes; a test seam. |
| `AC_CURATE_KEEP` | 20 | Done lines `ac-curate.sh` keeps before archiving the rest. |
| `AC_CURATE_STALE_DAYS` | 90 | Age in days past which Curate reads a signal as stale. |
| `AC_SESSION_QA_TIMEOUT` | 10 | Per-project watchdog for the session-start qa-infra reap sweep. |
| `AC_ORPHAN_CPU` | 50 | Min %cpu for the session-start sweep to flag an orphaned shell-snapshot process (read-only, never kills). |
| `AC_SYNC_TIMEOUT` | `config/sync-timeout`, else 60 | Per-project fetch watchdog for `ac-sync.sh`. |
| `AC_INHERITABLE_CONFIG` | `model effort backend crew-harness codereview-agent codereview-model codereview-effort qa-agent qa-model qa-effort gate-agent gate-model gate-effort epic-parallel room-parallel promote flow learn-every curate-every crew-dispatch.json` | Knobs a crewdeputy converges from its parent at session start. |
| `AC_BRAIN_SYNC_IV` | 1800 | Seconds between brain-freshen syncs, and the age past which prompt-time recall calls the brain stale. |
| `AC_BRAIN_EMBED_TIMEOUT` | 60 | Seconds one embedding call inside `ac-brain.sh sync` may take; past it the sync completes keyword-only. |
| `AC_BRAIN_RERANK_TIMEOUT` | 10 | Seconds the rerank call inside `ac-brain.sh recall` may take; past it the fused order is returned unreranked. |
| `AC_BRAIN_SYNTH_CMD` | unset | Overrides the one-shot command `ac-brain synthesize` runs, ahead of `panes.brain` and `config/brain-*`. |
| `AC_BRAIN_PATTERN_FILE` | `~/.config/agent-crew/push-gate.patterns` | Pattern file the brain's pattern floor reads (`bin/ac-brain-engine.ts`). |
| `AC_PROMPT_RECALL_LIMIT` | 3 | Max hits in the prompt-time recall block. |
| `AC_JEV` | `config/jev`, else `off` | Per-session override of the System One adapter (`off`, `shadow`, `on`). |
| `AC_JEV_ENDPOINT` | the provider's endpoint | Overrides only the URL `ac-jev.sh` posts to (tests, a local relay). |
| `AC_COMPACT_WINDOW` | `config/compact-window`, else 200000 | Context-window tokens `ac-compact-advise.sh` divides by; set it to the model's real window (e.g. 1000000). |
| `AC_PUSH_GATE_PATTERNS` | `~/.config/agent-crew/push-gate.patterns` | Pre-push privacy gate pattern file: one ERE per line, blank lines and `#` comments skipped. Kept outside the repo on purpose. |
| `AC_PUSH_GATE_REQUIRE` | 0 | `1` makes `bin/ac-push-gate.sh` fail closed when the pattern file is missing or empty. |
| `AC_ALLOW_DELEGATION` | unset | `1` is the delegation guard's deliberate escape hatch (`bin/ac-delegation-guard.sh`). |
| `AC_LINT_ALLOW_MISSING` | 0 | Tolerate a missing shellcheck in `ac-lint.sh`. |
| `AC_BOOTSTRAP_PROBE_TIMEOUT` | 10 | Seconds `ac-bootstrap.sh` allows its one backend probe. |
| `AC_FLEET_STATE` | unset (launch line) | Absolute path of the fleet's `state/`: where `ac-done.sh` publishes completions, and the anchor several scripts resolve state and the fleet backend from. |
| `AC_FLEET_SCOPE` | unset (launch line) | The family whose scoped watcher supervises this crewmate; set only by a roomchief's spawn. |
| `AC_FLEET_NAME` | unset (launch line) | The fleet token used for pane grouping and titles (`ac_fleet_name`: `AC_HOME` basename > this > `agent-crew`). |
| `AC_FLEET_MODEL` | unset (launch line) | The fleet's `config/model`, the middle rung of `ac-pane-agent.sh`'s model ladder. |
| `AC_FLEET_EFFORT` | unset (launch line) | The fleet's `config/effort`, raw, same rung as `AC_FLEET_MODEL`. |
| `AC_FLEET_HOME_CHECKED` | unset (launch line) | Always `1` on a crewmate: a real `AC_HOME` already resolved the project config, so `ac-ship.sh start` trusts `AC_FLEET_PROJECT_CONFIG`. |
| `AC_FLEET_PROJECT_CONFIG` | unset (launch line) | The resolved `$AC_HOME/projects/<name>.yaml`, set only when one exists. |
| `AC_FLEET_AGENT_<ROLE>` | unset (launch line) | Per-role pane harness from `config/<role>-agent` (`<ROLE>` = `CODEREVIEW` or `QA`), set only when the file is set. |
| `AC_FLEET_MODEL_<ROLE>` | unset (launch line) | Per-role pane model from `config/<role>-model`. |
| `AC_FLEET_EFFORT_<ROLE>` | unset (launch line) | Per-role pane effort from `config/<role>-effort`. |
| `AC_FLEET_PROFILE_<KIND>` | unset (launch line) | Static dispatched pane profile from `panes.<kind>` (`CODEREVIEW` or `QA`), one TAB-separated `harness=<h> model=<m> effort=<e>` value so the triple stays atomic. A routed qa selection is passed explicitly through `ac-verify qa` instead. |

This table is enforced: `tests/ac-config-surface.test.sh` diffs it against every `AC_*` name read in `bin/`.
A new tunable needs a row here, with the name in backticks as the first cell and a dynamic family written as one templated row such as `AC_X_<...>`.
Internal wire variables and test seams take no row; they are declared with a one-line reason inside that test.

## Toolchain

`bin/ac-bootstrap.sh` audits the toolchain and prints one line per check (`OK:`, `MISSING:`, `BELOW-FLOOR:`, `NO-CAPABILITY:`, `OPTIONAL:`, ...); a `MISSING:` exits 1.

- Required: `git`, `jq`, `gh` (authenticated for PR and CI steps), and the backend `config/backend` names: `herdr` with its server running, or `orca` with its runtime ready.
- Optional: `bun` (dashboard and native review loop), `node` (npx-driven helpers), `shellcheck` (`bin/ac-lint.sh`), `docker` (QA infra).

Version floors, each tied to a call the fleet makes (FLOOR TABLE in the `bin/ac-bootstrap.sh` header):

| Tool | Floor | Why |
| --- | --- | --- |
| `herdr` | 0.8.0 | `status server --json` reporting `.running`, which `bin/ac-backend.sh` reads. |
| `git` | 2.15.0 | `git interpret-trailers --parse`, used by the commit-msg guard `bin/ac-tree.sh` installs. |
| `jq` | 1.6 | `--args` / `$ARGS`, used by `bin/ac-brief.sh`. |
| `bun` | 1.3.5 | `Bun.Terminal`, the dashboard's native terminal; optional tier, so advisory. |
