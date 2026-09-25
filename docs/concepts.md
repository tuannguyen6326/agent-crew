# Concepts

This page is the conceptual model of agent-crew: what you need in your head before the [architecture map](architecture.md) makes sense.
It serves both operators and contributors.
Every concept is short on purpose and ends with a pointer to the file that owns it; when this page and the owner disagree, the owner wins.

## The law layout

agent-crew is an agent distro, not an app: instructions, skills and bash tooling, run by an LLM harness pointed at a fleet home (`AC_HOME`).
The law is split into three layers, and each contract lives in exactly one of them.
[`AGENTS.md`](../AGENTS.md) is the short muscle-memory index the chief keeps loaded: identity, prime directives, one-line summaries, and a table naming which skill to load before which act.
The skills under `.agents/skills/` hold the step-by-step law; when a row of the `AGENTS.md` section-12 table matches, the chief loads that skill and its text binds exactly as if it were in `AGENTS.md`.
Each `bin/` script's header comment is the authoritative spec of that script's behavior.
Everything else, this page included, points to the owner instead of restating it.

Owner: [`AGENTS.md`](../AGENTS.md) sections 12-13.

## Roles

### Captain

The captain is the human the fleet serves.
The captain owns every captain-required gate, every PR merge, and every decision the crew could not make on its own.
`config/captain` overrides the default address.

Owner: [`AGENTS.md`](../AGENTS.md) section 1.

### Crewchief

The crewchief is the harness session running at the fleet home on `AGENTS.md`.
It triages orders, writes briefs, spawns and supervises workers, and lands their work.
Real project work goes to a crewmate; the one exception is a visible self-task (`bin/ac-self-task.sh`), a small chief-side edit made in a leased worktree.
It is read-only over `projects/` except for a short list of sanctioned writes (fetch, safe fast-forward syncs, `bin/ac-merge-local.sh`, pool operations via `bin/ac-tree.sh`, and the deferred push inside `bin/ac-feature.sh ship`).

Owner: [`AGENTS.md`](../AGENTS.md) section 1.

### Roomchief and threads

A roomchief is a scoped crewchief for one task family, promoted with `bin/ac-spawn.sh --roomchief <family>` and running in its own resumable session (its thread).
By default every family is promoted at intake, up to the `config/room-parallel` cap; `config/promote` and the captain's words can change that.
Once a family is promoted, the crewchief neither works, inspects nor relays it - two chiefs on one family is a role violation.
A roomchief ends its tenure by handing back with `bin/ac-room.sh handback`, which posts `HANDBACK:` and queues a durable wake for the crewchief.
A roomchief is barred from the fleet ledgers by `bin/ac-ledger-guard.sh`.

Owner: [`rooms-threads`](../.agents/skills/rooms-threads/SKILL.md) skill.

### Crewmate

A crewmate is a disposable worker agent: one task or stage, one leased git worktree, one backend pane.
It follows its brief, not the chief law, and signals through `done:`, `blocked:`, `needs-decision:` and `failed:` lines plus a push via `bin/ac-done.sh`.
`crew/<id>` is the one branch a crewmate may create.
Fleet-wide crewmate instructions are seeded into the instruction file the spawned harness actually loads.

Owners: [`task-lifecycle`](../.agents/skills/task-lifecycle/SKILL.md) skill, [`docs/examples/CREWMATE.md`](examples/CREWMATE.md).

### Pane agents and the second chief

A verification pane agent is one agent turn in a backend pane (`bin/ac-pane-agent.sh`), not a crewmate, stage or backlog row.
Code review rounds, QA rounds and gate judges all run this way, each round in a fresh pane at an exact ref.
The second chief is the gate judge: a fresh, non-resumed model run by `bin/ac-gate.sh` (one engine, no fallback) only when a design report's gate route says `second-chief`.
It gives advisory R1/R2 decisions; the owning chief still decides, and the judged crewmate never runs its own judge.

Owners: [`staged-gates`](../.agents/skills/staged-gates/SKILL.md) and [`delivery-review`](../.agents/skills/delivery-review/SKILL.md) skills.

### Self-task, solo chief and solo session

These are the only sanctioned ways a chief-side or captain-driven session writes code itself.
A self-task (`bin/ac-self-task.sh start`) is a small chief-side edit made visible: a leased worktree, a labelled pane and a `kind=self` meta written before the first edit.
A solo chief is a roomchief promoted with `--solo` that works its family's slices itself through self-tasks, with independent review mandatory on every slice.
A solo session (`AC_SOLO=1`, opened with `ac <fleet> --solo`) is the captain pair-coding directly beside the chief; it never spawns, steers, drains wakes or arms watchers, and hands crew work to the chief with `bin/ac-remote.sh order`.
A solo slice's teardown refuses until its knowledge loop (lesson, repo fact, Done row) is recorded or explicitly waived.

Owner: [`solo-session`](../.agents/skills/solo-session/SKILL.md) skill.

### Crewdeputies and crewdomains

A crewdeputy is a persistent domain supervisor in its own nested home, with its own clones and session, routed to by the `scope:` text in `records/crewdeputies.md`.
A crewdomain is lighter: a knowledge package plus a routing line inside this fleet, whose work is a `domain:<name>`-tokened slice of the fleet backlog worked by a domainchief (an ordinary roomchief bound by that token).
Pick a deputy for isolation, a domain for a knowledge slice over the fleet's own clones.

Owner: [`deputies-domains`](../.agents/skills/deputies-domains/SKILL.md) skill.

## Flows and triage

Every captain order is triaged at intake, before any brief, along several coupled dimensions.
Precedence is always the captain's own words first, then a config pin, then the chief's triage.

### The two flows

```
direct:  crewchief -> execution crewmate
staged:  crewchief -> design crewmate -> execution crewmate
         design = spec / architecture / plan reports with gates
         execution = IMPLEMENT + DELIVERY
```

Direct gives the whole order to one execution crewmate.
Staged puts one design crewmate first, which writes the admitted spec, architecture and plan reports in order and waits at every gate; implementation starts only after the pre-implement gate.
A direct task that sprouts requirement questions is upgraded to staged; the chief never downgrades on its own.
An order with several independently-landable deliverables, or deliverables in more than one repo, is an epic and is decomposed into stories.

Owners: [`intake-triage`](../.agents/skills/intake-triage/SKILL.md) and [`staged-gates`](../.agents/skills/staged-gates/SKILL.md) skills, `config/flow`.

### Delivery mode

Mode is chosen per task and recorded as the backlog row's `mode:<m>` token; `bin/ac-brief.sh` refuses an unspecified mode.
- `crew-ship` - the 8-step validation pipeline, then a PR the captain merges; for shared, production or risky work.
- `direct-pr` - a PR without the pipeline; for small, low-risk changes.
- `feature-pr` - local merges onto a recorded feature integration branch, published once as one PR per repo by `bin/ac-feature.sh ship`.
- `local-only` - merged into the local default branch after approval, never pushed.

Owner: [`intake-triage`](../.agents/skills/intake-triage/SKILL.md) skill.

### Review, QA and promote

Review is a derived obligation, not a stage: `yes` for staged work and `crew-ship`, `no` by default for the other direct modes (the captain may raise it).
QA is optional behavioral proof after delivery, triaged at intake; it gates the merge, not the push.
Promote decides whether the family gets its own roomchief thread (default: always).
The chief states every choice in the backlog line and posts a `TRIAGE:` receipt to the family room.

Owners: [`intake-triage`](../.agents/skills/intake-triage/SKILL.md) and [`delivery-review`](../.agents/skills/delivery-review/SKILL.md) skills.

### The escalation gate

The time-expensive values - `flow:staged`, `mode:crew-ship`, `qa:yes` and a discretionary `rev:yes` - need the captain's confirmation before use, asked once as one bundled question with the reason for each.
A contract token already pinned on the row is pre-consent and is never re-asked.
`bin/ac-brief.sh` enforces this mechanically: a heavy value with no row pin needs `--captain-requested` plus `--reason`, recorded on the brief's `Escalation:` line.
The cheap path (direct, `direct-pr`/`local-only`, no review, no QA) stays autonomous.

Owner: [`intake-triage`](../.agents/skills/intake-triage/SKILL.md) skill, `bin/ac-brief.sh` header.

### Requirements check

Before any brief, the chief drafts the deliverable, acceptance, boundary and decision-authority lines and cites a source for each.
A line with no citable source is a guess: zero guesses proceeds, one to four become one bundled clarify exchange, and five or more mean the order needs `/brainstorm` first.
Flows with a design stage turn the answers into a captain-accepted `data/<family>/requirements.md` before any spec work starts.

Owner: [`intake-triage`](../.agents/skills/intake-triage/SKILL.md) skill.

## Rooms and receipts

Every family has a room, `data/<family>/room.md`, written with `bin/ac-room.sh post`.
Chat is the transport; the room is the record.
The receipt verbs are machine-parsed and stay English verbatim:
- `TRIAGE:` - the intake decisions and why.
- `GATE:` - a decision genuinely awaiting the captain.
- `ASK:` - an escalated question for the captain.
- `DECIDED:` - the captain's answer, recorded the moment it lands.
- `SELF-APPROVED:` - an intermediate gate the chief approved itself, with grounds.
- `GATE-LOOPED:` - a rejected gate looped back to the crewmate without the captain.
- `HANDBACK:` - a roomchief ending its tenure.

Only an unanswered `GATE:` or `ASK:` is pending; the pending set across rooms is the captain's inbox, and `HANDBACK:` pends for the crewchief.
Receipts are also said in chat, because a decision the captain has to discover in a file was not reported.
A 2-4 option ask goes out as a select with the recommendation first.

Owner: [`rooms-threads`](../.agents/skills/rooms-threads/SKILL.md) skill, `bin/ac-room.sh` header.

## Supervision

### The zero-token watcher

`bin/ac-watch.sh` polls every pane in bash, absorbs benign output, and exits with one reason line only when something is actionable.
Reasons include `report:`, `gone:`, `ask:`, `ended:`, `stale:`, `push:`, `unobservable:` and `heartbeat`; `unobservable` means the backend could not be read, never that the agent died.
The watcher must run as the harness's own background task so its exit wakes the chief; on claude the Stop hook `bin/ac-watch-autoarm.sh` holds and re-arms it automatically.

Owners: `bin/ac-watch.sh` header, [`task-lifecycle`](../.agents/skills/task-lifecycle/SKILL.md) skill.

### The wake spool and push completion

Every actionable event is published durably to a wake spool, `state/.wake-spool/` for the fleet or `state/.wake-spool.<family>/` for a promoted family, one record per file.
`bin/ac-wake-drain.sh` claims and emits them; after acting, the chief re-arms before the turn ends.
Agents also push their own completion with `bin/ac-done.sh <id> '<marker>'`, which publishes the same record and ends the watcher's poll wait, so a completion arrives in milliseconds.
The watcher stays as the backup that catches an agent which crashed or forgot, and one completion still wakes the chief once.

Owners: `bin/ac-done.sh` and `bin/ac-wake-lib.sh` headers.

### Hooks

Harness hooks turn the most-violated rules into mechanical checks; on claude they are wired in `.claude/settings.json`.
- Stop: `bin/ac-turnend-guard.sh` blocks a turn end that would leave crew in flight unwatched or wakes undrained; `bin/ac-watch-autoarm.sh` keeps a watcher armed; `bin/ac-compact-advise.sh --hook` may advise a `/compact`.
- PreToolUse: `bin/ac-delegation-guard.sh` refuses harness-native subagents from a chief-shaped session; `bin/ac-ledger-guard.sh` refuses a scoped session writing the fleet ledgers; `bin/ac-primary-guard.sh` refuses a crewmate or roomchief editing the primary checkout; `bin/ac-watch-policy-hook.sh` denies broad pattern-based watcher kills.
- UserPromptSubmit: `bin/ac-prompt-recall.sh` hands a human-driven session the top fleet-memory hits before the model reads the prompt.
- SessionStart: `bin/ac-sessionstart-nudge.sh` reminds a fresh chief session to run `bin/ac-session-start.sh`, and re-orients a compacted one.

Owners: each script's header.

## Truth on disk

All persistent truth lives on disk and in the backend session; conversation memory is only a cache, and a restart is a non-event.
- `state/` - volatile runtime signals: `<id>.meta`, `<id>.status`, the wake spools, watcher beacons.
- `records/` - fleet ledgers: `backlog.md`, `projects.md`, `captain.md`, `learnings.md`, plus `repo-knowledge/` and `scenes/`.
- `data/` - task dirs with briefs and reports, and each family's `room.md`.
- `records/backlog.md` - the single task ledger (In flight, Queued, Done), moved with `bin/ac-task.sh` or by hand.

`bin/ac-session-start.sh` rebuilds the chief's picture at every session start and drains queued wakes.
After a compaction, the SessionStart hook tells a chief to rebuild footing from disk with `bin/ac-brain.sh context_pack` and reload the skill for the work in flight, and tells a crewmate to re-read its brief and status log.

Owners: [`AGENTS.md`](../AGENTS.md) section 2, `bin/ac-brief.sh` header, [`docs/backlog.md`](backlog.md), `bin/ac-sessionstart-nudge.sh` header.

## The knowledge loop

Learning happens at landing, never deferred to a manual debrief.
- Repo knowledge: a fact verified about a codebase goes to `records/repo-knowledge/<project>.md` via `bin/ac-know.sh add`, with provenance, so the next family reads it instead of re-deriving it.
- Learnings ledger: a method lesson goes under `## Pending` in `records/learnings.md` via `bin/ac-learn.sh note`; crewmate `## Lessons` lines are folded verbatim.
- Learning DISTILL: a keyed `bin/ac-learn.sh tick` per landing advances a cadence, and at the `config/learn-every` crossing a Learning run distills Pending lessons into the always-loaded `CREWMATE-learned.md` layer or learned skills.
- Scenes: `bin/ac-scene.sh` keeps one consolidated topic file per subject between raw facts and the always-loaded layer, so a topic restores in one read.
- `bin/ac-brain.sh` is the per-home memory engine (hybrid recall with citations, working-memory facts, `context_pack`); it is additive and never replaces the reads above.

At intake the chief reads by the order's question with `bin/ac-know.sh recall` and cites what it used; citing is what bumps an entry's heat.

Owners: [`task-lifecycle`](../.agents/skills/task-lifecycle/SKILL.md) skill, the `bin/ac-know.sh`, `bin/ac-learn.sh`, `bin/ac-scene.sh` and `bin/ac-brain-engine.ts` headers.

## Review and QA as obligations

### Exact-ref review rounds

Each review round is one fresh pane agent reviewing a committed tree at an exact ref, through `bin/ac-verify.sh codereview`.
Round 1 reviews the full base-to-ref diff; later rounds verify the previous round's open findings and review only the interdiff.
Any commit after review, docs included, invalidates the receipt and needs a fresh round.
A `fix` verdict loops back to the execution crewmate; `ask-user` holds delivery and is relayed to the captain; the reviewer never edits.
Past `review.max_rounds` the loop holds for the owning chief's decision.
Inside `crew-ship`, the pipeline's review step fulfills the obligation, and `push` refuses a stale `reviewed_ref`.

Owners: [`delivery-review`](../.agents/skills/delivery-review/SKILL.md) skill, `bin/ac-verify.sh` and `bin/ac-ship.sh` headers, [`docs/validate-pipeline.md`](validate-pipeline.md).

### crew-qa

QA is not a crewmate the chief spawns: the execution crewmate that finished delivery calls the independent QA verifier (`bin/ac-qa.sh agent`).
Its evidence comes only from the booted deliverable's client-facing, API, integration, E2E and database boundaries, and it never runs a unit suite.
The verdict lives in durable run state, not in pane prose, and QA never posts or merges on its own.
A project can set `qa.require_for_ship: true` so merge helpers refuse a head with no passing QA run.

Owners: [`crew-qa`](../.agents/skills/crew-qa/SKILL.md) skill, `bin/ac-qa.sh` header, [`docs/qa-attestation.md`](qa-attestation.md).

## The four judgment rules

These bind every chief and crewmate; the full text is in one skill.
- Finding-authority - every defect names the authority for its expected behavior, and the author has read it; an outside actor's behavior needs a citable authority or becomes a question, never a defect.
  Findings carry `authority_class` and `authority`, and an unfounded `fix` is downgraded to `ask-user`.
- Evidence-class - every review request names the act that must settle it (`MUST BE SETTLED BY:`), plus a `DISPUTED:` block when the requester already ruled on the matter.
- Financial-code proof - a crew resolution on money paths without the captain carries proof matched to its question (compile-forced with the refusing construct named, byte-identical, or a test-demonstrated invariant); no proof means `needs-decision:`.
- Verify-before-assert - no claim about a mechanism, rule or authority without running the check first and citing what was read, and a self-correction meets the same bar.

Owner: [`judgment-rules`](../.agents/skills/judgment-rules/SKILL.md) skill.

## System One (Jev)

System One is a small-model adapter that answers closed-set questions with calibrated probabilities, behind one per-fleet knob.
`bin/ac-jev.sh` reads `AC_JEV`, then `config/jev`, then defaults to `off`:
- `off` - no key read, no request, no output.
- `shadow` - the request is made and the answer logged to `state/jev-shadow.jsonl`, but nothing is printed, so callers behave exactly as under `off`.
- `on` - as shadow, plus the validated answer on stdout.

Every failure prints one `jev:` reason on stderr and nothing on stdout, so a caller never depends on the network to succeed.
`ac-jev.sh label` records the decision the chief really made next to a logged answer, which is how agreement is measured before a site is turned on.
Its answers are proposals only, and they are asked at five sites:
- `watch` - on quiet `ended:`/`stale:` wakes, a note on whether the pane looks done.
- `dispatch` - `bin/ac-dispatch-select.sh --propose` suggests a dispatch rule beside the list.
- `overlap` - `bin/ac-ready.sh overlap --semantic` proposes related open backlog rows.
- `learn-route` - `bin/ac-learn.sh` proposes where a lesson belongs and whether it is worth keeping.
- `compact` - the compact adviser below.

`config/jev-provider` selects the provider.

Owner: `bin/ac-jev.sh` header, [`docs/configuration.md`](configuration.md).

### The compact adviser

`bin/ac-compact-advise.sh` answers "should this session `/compact` now?" at the `compact` site.
It scores the session from its transcript and context usage against a floor that slides with usage, and prints one `compact=advise` line only when the score clears the floor.
As a claude Stop hook it judges only human-read sessions (a solo session, or a chief at the fleet home) and shows its advice to the human, not the model.
Crewmates are judged by the watcher instead, which appends the note to a quiet wake; the chief decides whether to send `/compact`.

Owner: `bin/ac-compact-advise.sh` header.

## Where to go next

- [`architecture.md`](architecture.md) - the component map.
- [`configuration.md`](configuration.md) - every config file and environment variable.
- [`scripts.md`](scripts.md) - the script index.
- [`backlog.md`](backlog.md) - the backlog grammar.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) - how to change any of this.
