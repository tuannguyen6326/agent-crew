---
name: crew-qa
description: Verify a delivered change end-to-end by driving the QA pipeline through ac-verify qa - freeze an AC-to-UT/IT/E2E coverage manifest, reuse ship UT evidence without rerunning tests, boot task-scoped infra and the live service, execute API/DB/workflow/web cases plus the final full flow, capture evidence, and return a machine-readable verdict. Standalone from code review. Use when the user asks to QA or verify a change, or invokes /crew-qa. Never fixes anything.
---

# crew-qa

Behavioral verification with evidence, STANDALONE from code review. You prove
the change WORKS (or does not) by exercising the REAL
system - reading the diff is code-review's job, running the unit suites is
the ship pipeline's job. You never fix, amend, or push: you verify,
someone else fixes.

EXECUTION SURFACE: the execution crewmate calls `ac-qa.sh agent`, a policy
adapter over `ac-verify qa`. Before the pane exists, the caller selects any
routed `panes.qa` rule and freezes the complete profile bundle: trusted config,
closed scope map, selected store files, exact refs, and the routing receipt.
The facade validates that bundle, prepares isolated exact-ref lease(s), launches
one fresh pane for one profile round, derives the verdict from durable run
state, publishes the canonical stage report, exports run state plus the
transport relay report, then reaps. Invalid, mismatched, timed-out, or
incomplete state is preserved for chief recovery. Do not brief or spawn a QA
crewmate, a plan reviewer, or per-step QA agents.

You drive `bin/ac-qa.sh` - a durable state machine (state at
`<repo>/.crew/qa/<run-id>/`, exportable before verifier teardown; its header is
the authoritative spec). Steps in order:
`pin testplan baseline infra serve cases e2e evidence verdict`.
Mark each step `running` -> `completed|skipped|failed` as you go
(`ac-qa.sh step <name> <status> [--note ...]`), EXCEPT the two OWNED
transitions: `baseline` and `serve` are recorded by their own commands,
which publish the proof the pass gate reads, and a direct completion of
either refuses.
THE POLICY THIS RUN OBEYS (`bin/ac-qa.sh`'s BOUNDARY
POLICY block is the spec): QA evidence comes only from the client-facing,
API, integration, E2E, and database boundaries of the BOOTED deliverable;
QA never executes, re-runs, or counts unit tests for this round; a passing
round proves behavior from outside the delivered runtime's process.
An environment failure HOLDS the run (fix the environment, re-run the held step); a failing CASE
is a ledger row + finding, never a reason to stop verifying the rest.

## Procedure

1. **pin.** `ac-qa.sh start --target <ref> --task <id>
   [--scope <name> --app <name>]`. Run the start line your brief bakes
   VERBATIM. The fixed `.crew/qa/profile-runtime/` handoff is the complete
   runtime input; a sanctioned pane does not resolve `AC_HOME`, re-read fleet
   config, or accept a live store path. `start` validates and atomically consumes
   the handoff into `<run>/profile/`. Verify from a clean context: a fresh pool
   worktree detached at the target commit, never the implementer's tree;
   `git status` stays clean the whole way.
   `start` ENFORCES this (TARGET-CHECKOUT BINDING, `bin/ac-qa.sh` header):
   it refuses unless the worktree's HEAD IS `--target` with a clean tracked
   tree, and `finish passed` re-proves it before minting the pass - so the
   attestation can never key a commit the run did not exercise.
   Criteria: the accepted spec's matrix when one exists, else the
   PR body, else derive observable checks from the diff and SAY you
   derived them. SECURITY: the project repo is never a config source; the
   preflight snapshot is already hash-bound before this pane starts.
   SCOPED PROJECTS (a monorepo whose qa config is keyed by scope+app): every
   run names BOTH `--scope` and `--app`, always - there is no one-member
   inference, and the pair is what makes the run record say which profile it
   proved. Your chief NAMES the scope; never derive it from the diff. `start`
   refuses by name if you omit either, or name one that does not exist, and
   it never falls back to a repo-level value - so a refusal here is the
   mechanism working, not a workaround to route around. The contract and the
   full refusal chain live in `bin/ac-qa.sh`'s SCOPED CONFIG header block.
   RESOLVED PROFILE (normal execution): a fresh verifier never discovers or
   drafts config itself. `ac-qa.sh agent`'s PROFILE RESOLVE preflight
   compiles, validates, and freezes the profile from the two durable
   sources BEFORE this pane exists - a missing/stale/conflicting durable
   source returns `needs-profile`/`profile-stale`/`profile-conflict` with
   NO pane spawned, so `start` never runs against an unconfigured or
   ambiguous project. Onboarding a project with no config yet is a
   separate, chief-owned repair path off that status
   (`ac-qa.sh config-proposal`/`config-install`, drafted by a discovery
   agent/tool and installed by the chief) - never something you do inside
   a normal round. If the frozen profile you were handed still proves
   insufficient once you are running, REPORT it as a structured finding -
   never silently repair, widen, or draft a replacement yourself; the
   chief re-resolves and a fresh pane picks up the retry.
2. **testplan.** LOAD THE FROZEN KNOWLEDGE SNAPSHOT FIRST -
   `ac-qa.sh store-dir` resolves only `<run>/profile/store/` for a sanctioned
   round. The versioned manifest is always present, including an explicit empty
   manifest when no shared store exists. Never read the live fleet store or
   substitute another path after publication.
   Then read `guide.md` (how THIS project boots, runs e2e, its accounts and
   selectors - trust it over re-deriving) and `catalog.md` (the reusable
   case index). For each catalog case whose surface overlaps this change:
   check staleness (`git diff --stat <verified-sha>..HEAD -- <surface
   paths>` non-empty, or verified > 30 days, = SUSPECT); ADOPT fresh cases
   as-is into the plan (mark them `store`), re-verify suspects, and derive
   only the DELTA cases this change actually needs - the store is why run
   N+1 is cheaper than run 1, never a substitute for covering NEW
   behavior. An empty manifest means derive the current plan fresh and record
   curation as skipped with a reason after the verdict. Then write
   `testplan.md` next to your report (the task data dir) - an `## Infra`
   block, the machine-readable coverage declarations below, then one row per case:
   `| id | priority | tier | rw | precondition | steps | expected | AC-ref |`
   ```md
   ## Coverage
   coverage: <ac-id> | ut | <repo-relative-test-reference> | -
   coverage: <ac-id> | it | - | <case-id>
   coverage: <ac-id> | e2e | - | <case-id>

   ## Full Flow
   full-flow: <case-id>
   ```
   Run `ac-qa.sh step testplan completed` only after both exact sections
   are complete. It atomically freezes `<run>/testplan-manifest.json`
   (`agentcrew.qa-testplan-manifest/v1`). `boundary-run`,
   `boundary-register`, `fixture`, `cmd e2e`, and `case` all refuse before
   this freeze.
   - INFRA DECLARATION - the `## Infra` block ABOVE the table lists the
     services THIS run needs (step 4's ladder resolves them), one line
     each, each with its one-line why, derived from the change's
     behavioral surface: `- postgres - TC-3 asserts the order row is
     persisted`. Needs no backend? Say that: `- (none) - <why>`.
   - `rw` marks state effects: `ro` (read-only/idempotent - safe to run
     CONCURRENTLY) vs `rw` (mutates DB/mocks/service state - sequential).
   - PARALLELISM, resolve-then-record: `ac-qa.sh infra up` now boots the
     block you declared, so it can no longer start before it. Resolve the
     services FIRST, write the small `## Infra` block, kick `infra up` off
     as a BACKGROUND task, THEN write the case rows while images pull -
     the rows are the slow half, so the overlap survives. Baseline is a
     receipt READ and costs nothing; only serve/health/seed onward are
     strictly sequential.
   - tier is YOUR judgment of which CLIENT BOUNDARY each case needs, from
     the closed set: `api` (drive the live service over HTTP/gRPC/CLI and
     assert the response), `db` (the same stimuli, asserted on durable
     state via psql/redis-cli against the crew-qa infra), `workflow` (a
     workflow start/signal, queue message, or scheduled trigger consumed by
     a running worker), `web` (full user flow in a real browser). There is
     no `unit` tier: unit coverage belongs to the ship suite, which this
     round only READS through the frozen receipt.
   - Derive from the acceptance criteria + brief + diff surface; add
     negative/boundary cases per `references/adversarial-checklist.md`.
   - COVERAGE LADDER: map each acceptance criterion to the lowest evidence
     rung that genuinely proves it. `ut` cites a regular tracked test blob
     (optionally `#selector`) at the exact target SHA and creates no QA case.
     Use it only when the frozen ship receipt qualifies. Otherwise escalate
     that AC to `it`; use `e2e` when IT cannot prove the cross-system path.
     Every IT/E2E mapping cites one planned case. An unmapped criterion means
     the plan is not done.
   - FULL-FLOW CAP: declare at least one IT/E2E case that re-proves the
     assembled primary path after the component cases. A full-flow id must
     also appear in the coverage declarations.
   - DECLARATION GATE: every service in the `## Infra` block carries its
     why, and NOTHING outside that block ever boots. A service listed
     without a why is not a declaration, it is a habit - and the habit
     costs the run: slower boots, resource conflicts, flakier runs,
     noisier failures. Declaring it because the stack usually has one is
     the evasion this gate exists to kill; if you cannot name the case
     that needs it, it is not needed. The declaration is what `infra up`
     boots, and `bin/ac-qa.sh`'s header owns the containment rule that
     makes it stick.
   - The plan is the record: any case you execute is in the plan first.
   - Case ids are greppable test titles (`TC-<n>-<slug>`) so api/db cases
     map 1:1 onto e2e spec titles. The slug names the STIMULUS, never the
     expected conclusion - a self-asserting label (`...-retry-accepted`)
     repeats itself into every evidence file, directory name, and log
     line, and is the first rung of label inflation.
3. **baseline (a RECEIPT CHECK, never a re-run).** `ac-qa.sh baseline`,
   and nothing else - a direct `step baseline completed|skipped` refuses.
   It validates the frozen exact-SHA ship test receipt the caller froze
   into the profile bundle and records `qualifies:<reason>` or
   `not-qualifies:<reason>`. You NEVER run, re-run, or count a unit suite:
   unit-suite health is the ship pipeline's business and reaches this round
   only through that receipt. The recorded state is
   informational when the frozen manifest has no `ut` row. When a `ut` row
   exists, its cited exact-tree test reference plus a qualifying exact-SHA
   receipt is the row's required evidence; an unqualified receipt refuses
   `testplan completed` and the AC must move to IT. Do not "help" by running
   the suite.
4. **infra.** Boot ONLY what the service needs - never the full stack.
   Resolve the service list in this order: (a) `qa.infra` when the captain
   pinned it - read the list YOURSELF from the frozen `<run>/config.yaml`
   (agent-read, not scalar); (b) else `ac-qa.sh infra detect` (scans deps/
   compose/env for postgres/redis/temporal) and SANITY-CHECK it against the
   diff and code you are testing - add a service the detector missed
   (e.g. wiremock when the change calls an external HTTP API you must mock),
   drop one the change never exercises; (c) a service that needs no backend
   boots NOTHING - run `ac-qa.sh infra up` with no `--services`: it
   allocates the service port AND declares that this run needs no backend,
   which binds like any other declaration. (c) is a whole resolution, never
   a preliminary to run "while you think" - otherwise:
   `ac-qa.sh infra up --services <resolved,list>`.
   Either form IS the declaration act: it boots exactly your step-2
   `## Infra` block and REFUSES anything wider for the rest of the run -
   step 2 is the contract.
   Task-scoped docker (postgres/redis/temporal/wiremock profiles from the
   skill's `assets/compose.yaml`); ports land in `<run>/ports.env`.
   Docker absent, or a service a case turns out to need that you never
   declared -> that case PARKS WITH ITS REASON (`ac-qa.sh case <id>
   unverifiable --tier <t> --classification environment --note '<what was
   missing>'`) and the stack is NEVER widened to rescue it. This is
   mechanical, not aspirational: `infra up` refuses the widening. A need
   you got wrong is re-declared DELIBERATELY - fix the `## Infra` block
   and start a fresh run - never by booting more mid-run.
5. **serve (the boot the whole verdict rests on).** `ac-qa.sh serve` then
   `ac-qa.sh health` then `ac-qa.sh seed` (seed no-ops with exit 4 when
   unconfigured - note it). `serve` OWNS its step transition (a direct
   `step serve completed` refuses) and `health` publishes the runtime boot
   receipt that every later case binds to. No booted runtime, no pass:
   there is no re-issue inside a round, so if the runtime dies or restarts,
   finish the round honestly and re-prove in a fresh one. PRE-FLIGHT GATE:
   inventory the service's resolved outbound dependencies; anything not
   pointing at localhost/crew-qa containers/declared mocks makes the
   affected cases `unverifiable` - never exercise a real backend. Stub
   per-case mock behavior via the wiremock admin API (`$QA_MOCK_URL`,
   POST `/__admin/mappings`, reset between cases).
6. **cases.** Execute the testplan inside this one QA pane; run `rw` cases
   sequentially and use supervised subprocesses for any safe `ro` concurrency:
   - HARD PREREQUISITE: cases only start AFTER infra+serve+health+seed -
     every tier hits the LIVE service, so nothing runs until it is up.
   - Run cheap `ro` cases directly. When several expensive independent cases
     justify concurrency, launch ordinary project commands as supervised
     subprocesses from this pane, give each its own evidence directory, wait
     for every process, then record the rows. Do not create subagents, pane
     agents, or separate review sessions. They would split one attested profile
     round across multiple authorities.
   - Run `rw` cases (DB writes, wiremock stub changes, anything
     order-dependent) yourself, one at a time, resetting shared state
     between them.
   - THE BOUNDARY RULE: every case stimulates the BOOTED deliverable from
     OUTSIDE its process. Constructing the product's service classes inside
     your own harness (a dependency-injection recipe), or writing straight
     to the database, is NOT behavioral evidence - it proves the classes
     assemble, not that the delivered runtime behaves. When no client
     boundary can reach an accepted criterion, the case is `unverifiable`
     with an `ask-user` finding NAMING the missing boundary. Never
     substitute.
   - Tiers are closed: `api | db | workflow | web`. `api` =
     request/exit-surface assertions, `db` = the same stimuli asserted on
     durable state, `workflow` = a workflow start/signal, queue message, or
     scheduled trigger consumed by a RUNNING worker, `web` = a real browser.
     There is no QA `unit` tier or unit boundary. UT is a non-executed
     manifest reference backed by the ship receipt; if it cannot qualify,
     escalate the AC to a client-boundary IT case.
   - api/db/workflow tiers: real requests against `$QA_BASE_URL` (exact
     commands, raw outputs); DB assertions attach the query + result. Drive
     them through `ac-qa.sh boundary-run --case <id> --boundary <b>
     --evidence <path> -- <command>`, which runs the client under the frozen
     runtime descriptor and prints the execution receipt path.
   - web tier: drive the flow in the REAL browser - Chrome MCP when the
     session provides it (interactive/authenticated flows), else
     `npx playwright screenshot` per checkpoint. A SCREENSHOT per web
     case is REQUIRED evidence.
   - Record every result: `ac-qa.sh case <id> <pass|fail|unverifiable>
     --tier <t> [--classification defect|flaky|test-maintenance|environment]
     [--confidence 0..1] [--grade A|B|C|D] --evidence <path>
     --boundary <b> --receipt <path>`. A `pass` or `fail` row REQUIRES the
     boundary and its receipt - compose it directly:
     `--receipt "$(ac-qa.sh boundary-run --case <id> --boundary http
     --evidence <path> -- curl -sS "$QA_BASE_URL/x")"`. An `unverifiable`
     row may omit them; the missing boundary is often its whole reason.
   - web cases: register the browser run with
     `ac-qa.sh boundary-register --case <id> --boundary web --transcript
     <path> --visual <path>` (it links the screenshot too, and may run
     before the final case row exists), then bind the receipt it prints.
   - EVIDENCE LADDER: grade what the evidence PROVES - A real end-to-end
     system proof, B service-level proof, C component/renderer-only,
     D handler-only. A web case without a screenshot caps at C.
   - Register each screenshot with `ac-qa.sh visual <path> --case <id>` as
     you take it, while the stack is still up. Every RUN owes at least one
     visual artifact whatever its tiers - step 8 is the contract.
   - Failing non-acceptance cases re-run twice: a flip = classification
     `flaky` (warning finding with both transcripts), never a silent pass.
7. **e2e (testplan-driven).** Map every api/db case onto the EXISTING e2e
   specs (project e2e dir, or the e2e repo worktree named in `## Inputs`):
   covered -> select the mapped ledger ids with
   `ac-qa.sh cmd e2e --cases <id>[,<id>...]`. The command is the execution
   receipt boundary: it runs only the chief-installed frozen command under the
   minimal environment and owns the E2E step transition. Never mark a successful
   E2E step completed by hand. The ledger-first order is: record each selected
   case provisionally (`unverifiable --note pending-e2e-execution`, no
   receipt), run `cmd e2e --cases ...`, wrap each one with
   `ac-qa.sh boundary-register --case <id> --boundary e2e --upstream-receipt
   <path> --evidence <path>`, then overwrite the row with its final
   `pass|fail`, boundary, evidence, and wrapper path. A provisional row is an
   execution-planning state, not a verdict: it cannot satisfy `finish passed`,
   and it needs no `ask-user` finding unless the approved E2E boundary is
   genuinely unavailable. When no current case needs E2E, use
   `step e2e skipped --note '<reason>'`. Uncovered -> create a test-only
   proposal patch and register it with `regression-proposal`; it cannot satisfy
   this round. Execution lands and reviews the test, then a fresh exact-ref QA
   round executes it.
   After every rung-specific component check, execute the manifest's declared
   full-flow case or final group in its own final invocation. Mechanically,
   the earliest effective full-flow receipt `started_at` must be at or after
   the latest non-full-flow receipt `completed_at`. A late component retry
   therefore requires re-running and rebinding the full-flow group.
8. **evidence.** Per-case artifacts at `$(ac-qa.sh evidence-dir)/cases/<id>/`
   (transcripts, screenshots). Render ONE consolidated rich-review HTML evidence
   page linking every case row to its artifacts - that page is the captain's
   review surface.
   - VISUAL FLOOR - every run owes >=1 portable visual artifact, whatever
     its tiers. `web` is not the only tier that owes a picture: an
     all-api/db run SCREENSHOTS ITS TEST REPORT (the Playwright HTML
     report, the suite summary) and registers that. On the run that made
     this rule, the report screenshot was the single most convincing
     artifact - and the captain had to ask for it.
     The floor is MECHANICAL, not etiquette: `ac-qa.sh visual <path>
     [--case <id>] [--note <text>]` admits an artifact only if its MAGIC
     BYTES say png/jpeg/gif/webp (a renamed text file is refused), and
     `finish passed` REFUSES with none on record - it re-reads every
     registered file, so an artifact you deleted stops counting. Register
     as you capture: `step evidence completed` refuses without one too,
     while the live stack can still produce it. `bin/ac-qa.sh`'s header
     owns this contract. The per-web-case screenshot rule of step 6 still
     stands on top of it - one picture per run is the FLOOR, not the goal.
   - SECRET SCRUB - scrub before anything enters evidence (raw serve/infra
     logs stay in `.crew/qa/`), and NEVER trust a text grep of a bundled
     report: Playwright's HTML report inlines its data as base64/zip, so
     grepping it for a JWT returns ZERO matches while the token is fully
     present in the artifact. Redact at RENDER time - in the DOM, before
     you capture - then verify the ARTIFACT itself by strings-scanning the
     PNG binaries. `references/gotchas.md` has the why.
   - PRIVATE-REPO HOSTING - so the captain SEES the evidence in the PR
     instead of a path they cannot open. Push the PNGs to a side branch
     `evidence/<family>` via the contents API, then embed them as
     `https://github.com/<org>/<repo>/blob/<ref>/<path>.png?raw=true`.
     GitHub leaves those unproxied in `body_html`, renders them for any
     authenticated repo viewer, and they never pollute the PR diff.
     Do NOT re-derive the failed alternatives: `gh` cannot attach images at
     all (the user-attachments CDN is web-UI only), and
     raw.githubusercontent / camo do not serve private content.
     Before posting, run `ac-qa.sh fetch-check <url>...` on every URL built
     this way - it refuses on any non-200, so a bad embed is caught here
     instead of by the captain finding a 404.
9. **verdict.** Findings via `ac-qa.sh findings <step>` (ac-ship schema;
   every product defect is action `fix`, and every finding carries
   `authority_class` + `authority` - a `fix` with no authority is
   DOWNGRADED to `ask-user` by the shared normalizer). A case `fail
   --classification defect` whose EXPECTED behavior is something an actor
   OUTSIDE the system under test does (partner, client library, DB,
   network) must cite documentation, an in-repo spec, or a captain
   ruling - pass it as `--authority '<file:line | URL | captain <date>>'`;
   with nothing citable it is `unverifiable` with a `--note`, never a
   defect, and `case` REFUSES the defect without it. Each
   fail-classified-defect case ships an executable `repro-<id>.sh` (exits
   non-zero while the bug exists) that holds everything constant except
   the disputed variable and DECLARES it in two header lines,
   `# DISPUTED: <the one variable>` and `# HELD-CONSTANT: <everything the
   two legs share, named>`; pass it as `--repro <path>` - `case` refuses a
   missing, non-executable, or header-less one. `bin/ac-qa.sh`'s
   FINDING AUTHORITY header owns the contract; comparing the headers
   against the script body is a reader's job (adversarial checklist).
   Re-post a decided `ask-user` finding through the same findings command with
   its non-empty `decision`; do not invent a QA-only decision wire. Then
   `ac-qa.sh finish <passed|failed|unverifiable>` records the durable outcome.
   For `passed`, the completion gate runs before teardown: every fixed step is
   completed or explicitly skipped with a note, findings are resolved, every
   case is a graded pass with durable in-root evidence AND a coherent
   client-boundary execution receipt bound to this run's booted runtime, every
   `ut` row has a qualifying exact-SHA ship receipt and exact-tree test
   reference, every mapped IT/E2E case passes, the full-flow group is
   effective-last, every web case has a linked visual, a
   completed E2E step has its zero-exit receipt, and every task-local harness
   is classified. The gate's last act before teardown is to re-prove the
   process group and re-run the frozen health probe into an immutable runtime
   gate receipt: no ready system at that instant, no pass. A sanctioned pass publishes only a
   parser-validated atomic v2 attestation. The facade, not this pane's JSON,
   derives the exported verdict from `run.meta`.
10. **curate.** After the behavioral verdict, attempt curation without changing
    that verdict. Never edit the shared store directly. Write a complete
    candidate below the exported run, including `store/` plus the base frozen
    manifest hash. Classify every new executable harness exactly once with
    `harness-classify`: `repo-regression`, `e2e-regression`, `fixture-pack`,
    `evidence-only`, or `retire`. Reusable common setup belongs in one fixture
    pack with reviewed selectors; a read-write selector must declare and
    implement idempotent retry behavior. Record the result with
    `ac-qa.sh curation completed`, or `skipped|failed --note '<reason>'`.
    Curation is non-gating. The chief may later install a reviewed candidate
    with `store-install`, whose base-manifest check refuses concurrent
    overwrite.
11. **report and relay.** `ac-verify qa` atomically publishes the canonical
    stage `report.md` beside the QA charter. Its first line is the durable
    `verdict:` and its coverage/full-flow tables come from the frozen manifest
    plus validated effective receipts. `relay-report.md` surfaces the full-flow
    ids and canonical-report reference but is only the caller transport
    checklist. The caller relays both artifacts plus exported evidence; neither
    replaces the other.

## Rules

- Fresh eyes only: if you implemented the change, you do not QA it.
- Never fix; never weaken a test to green. You may author only caller-owned
  test/fixture proposals and evidence, never production changes or commits.
- One profile round has one QA pane. Retrying an idempotent command or fixture
  selector is allowed while the original harness process and frozen refs,
  profile, route, model, scope, and authority remain unchanged. Any ref,
  profile, route/model/harness, authority, terminal outcome, or capacity-limit
  change requires a fresh round and fresh pane.
- A completed test plan is hash-frozen. If an expected behavior changes, use
  `testplan-amend` with every affected case, an accepted authority, and a
  reason. Before any case evidence, authority may change coverage/full-flow
  selection and regenerate the manifest. After any boundary, fixture, E2E, or
  case evidence exists, selection changes require a fresh round; prose-only
  amendments must preserve both arrays. Current implementation behavior alone
  is not oracle authority.
- Durable-workflow projects reuse chief-installed worker/startup/health,
  teardown, time-control, event-history, and retry-safe fixture mechanics.
  Each mutable case uses an isolated workflow identity and records event
  history plus relevant service/worker logs and side effects; do not rediscover
  topology or split the profile into per-service agents.
- Silence is not verification: every acceptance criterion appears in the
  ledger with an observed result; environment gaps are `unverifiable`
  carrying their reason (`--note`), not passes and not silent skips.
- Never stop/kill a process or container this run did not create; an
  occupied port is a `blocked:` finding. Prune commands are forbidden.
- Write ONLY to `data/<family>/qa/` (report, testplan, evidence). You do
  NOT post to the PR, the room, or the captain, and you do NOT merge -
  staying off those surfaces is part of your independence. The caller that
  invoked you carries your report outward under the RELAY CONTRACT, which
  `bin/ac-qa.sh`'s header owns and `ac-qa.sh relay-report` renders.
- Read `references/gotchas.md` before the infra/serve phases.
