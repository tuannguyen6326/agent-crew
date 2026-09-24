---
name: intake-triage
description: Crewchief and roomchief intake judgment for every captain order, before any brief: choosing flow (direct/staged), delivery mode, review and qa obligations, the escalation gate for heavy tokens, the TRIAGE receipt, the requirements check and PO step, the overlap and knowledge reads, the upgrade rule and captain re-route, epic detection, and GitHub intake. Load BEFORE triaging any new order, re-routing a task, answering a crewmate needs-decision about scope, or folding a drained github wake.
---

# intake-triage

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Delivery mode (section 4)

MODE IS PER-TASK, never a registry property:
the delivery mode is chosen at intake per task and RECORDED as the row's
contract token `mode:<m>` (section 9 owns the grammar); `ac-brief.sh`
refuses an unspecified mode - row pin > `--mode` flag > refuse, never a
default - so the choice is always explicit and on the record. A legacy
`[<mode>]` on a registry line is tolerated, ignored content. Pick by the
task's DELIVERY TARGET and RISK, not by habit:
- `crew-ship`: ship pipeline -> PR -> captain merges. For a shared or production repo, a remote+team-reviewed PR, or ANY risky/substantial change (even a task on a repo that usually takes `direct-pr`/`local-only` work) - the 8-step pipeline's independent review, tests, docs and guarded push are the gate the change earns. A TIME-EXPENSIVE choice: the section 5 escalation clause applies.
- `direct-pr`: PR without the pipeline (a ship-docs pass, then push + PR). For a change small and low-risk enough that the pipeline is overkill, or a project carrying no pipeline config (`projects/<name>.yaml`).
- `feature-pr`: crew branch merged LOCALLY into a captain-recorded FEATURE integration branch that several tasks accumulate on, published ONCE at ship as one PR PER REPO to the recorded target (feature-branch-mech; "single PR" means no staging chain - a multi-repo feature ships one PR per repo, recorded per repo). The record is `data/<feature>/branches` (`<repo> <branch> [target=<t>] push=deferred`), member rows bind with `feature:<name>`, `bin/ac-feature.sh` owns the verbs and the gated ship. For a batch of related tasks aimed at one target branch (a release channel, or the default) that must not publish piecemeal.
- `local-only`: crew branch merged into the LOCAL default branch by you after approval, NEVER pushed. For a project with no remote, or the distro's own tooling / captain-side work the captain merges in place.
`+yolo` stays per-project - the ONE thing `bin/ac-project-mode.sh` still
answers.

## Flow, escalation gate and requirements check

Two flows exist; pick one for EVERY captain order, AT INTAKE, before any
brief is written. Precedence: (1) the captain's own words in the order,
(2) `config/flow` (`direct` / `staged` pin it for the whole home),
(3) `auto` (default) - the triage below decides. In `auto` YOU triage -
and the TIME-EXPENSIVE choices ask first:
using ANY of `flow:staged`, `mode:crew-ship`, `qa:yes`, or a
discretionary `rev:yes` requires the captain's confirmation BEFORE use,
carried as ONE bundled ask (section 8 etiquette) whose question states
the REASON each heavy value is warranted (the signal: financial surface,
behavioral surface, multi-file risk, ...), unless the row's contract
group already pins that token - a pin is pre-consent and is never
re-asked. The cheap path (`direct`, `direct-pr`/`local-only`, `rev:no`,
`qa:no`) stays fully autonomous. `ac-brief.sh` enforces this
mechanically (the escalation gate): a heavy value with neither a row pin
nor `--captain-requested '<the captain's words>'` refuses to scaffold -
and the declared path also REQUIRES `--reason '<the justification you
gave the captain>'`, recorded on the brief's `Escalation:` line, so the
why survives the conversation it was asked in (a pin needs no reason: no
ask happened - the pin is the captain's own act).
The captain's answer is written onto the row as contract tokens, so the
ask happens at most once per task ever. A STANDING captain rule may
pre-authorize a CLASS of rows (the captain's words, recorded in
`records/captain.md`) - you mint the tokens from it and cite the rule;
chief judgment alone never mints a heavy token.
State the chosen flow in the backlog line so the decision is on record,
AND post the reasoning to the family room the moment you triage:
`TRIAGE: flow=<f> mode=<m> promote=<p> - why: <one line per non-obvious
choice>`. The backlog line is the index; the room entry is how the
captain LEARNS WHY without asking. The captain corrects you in either
place. Only when you genuinely
CANNOT decide (conflicting triage signals, missing context you cannot
scout out yourself) do you ask the captain - and then you must say WHY
you could not decide, list the options, and give your one-line lean so
the captain picks with one word.
The dimensions COUPLE - triage them from ONE read of the order, not as
independent flips, because the same signals move several at once. An
irreversible, financial, or product-behavior change pulls `staged`
(usually from `spec`), a `qa` gate, and the captain-required
pre-implement gate together; a trivial, mechanical change with clear
requirements is `direct`, no `qa`, a cheap mode, unpromoted. When
one dimension lands out of step with the rest - `staged` design but no
`qa` on a financial change, or a captain gate on a trivial one - that
mismatch is the tell you mis-read a signal, so re-read before you
receipt. Per-dimension criteria stay authoritative in their own
sections (flow/qa here, mode section 4, promote section 8); this is
only how their signals move together.
REQUIREMENTS CHECK - at intake, BEFORE any
brief, FLOW-AGNOSTIC (it judges the ORDER, not the flow) and binding
crewchief and roomchief alike: the brief-without-guessing test. Draft
the brief's four load-bearing lines - the DELIVERABLE (one sentence:
what exists after landing that does not now), the ACCEPTANCE checks
(how the captain verifies, each traceable to the order or a standing
rule), the BOUNDARY (what is in, plus the nearest thing explicitly
OUT), and the AUTHORITY of every product/behavior decision the work
will force (answered by the order, by a recorded ruling, or genuinely
technical) - and every line must CITE its source: the captain's words
verbatim, captain.md, the room, ac-know, or an accepted report. A line
with no citable source is a GUESS, and each guess is a question for
the captain, never a silent invention. Route by the guess count:
0 -> proceed to brief/spawn; 1-4 -> ONE bundled clarify exchange with
the captain FIRST (section 8 select etiquette; answers recorded
`DECIDED:` in the room and quoted verbatim into the brief); >=5, or
the DELIVERABLE line itself a guess -> the order is not
underspecified but unthought - propose `/brainstorm` and stop.
For flows that RUN A DESIGN STAGE (staged, and design-first via
/order-design), the check grows into the PO STEP and the answers
become an ARTIFACT (the PO step): the OWNING chief - the
roomchief IN ITS OWN THREAD when the family is promoted, the
crewchief in the fleet chat otherwise - interviews the captain as
product owner and writes `data/<family>/requirements.md`, every line
cite-carrying (the order verbatim, clarify answers already recorded
`DECIDED:` in the room, standing rules). The captain's LIVE
acceptance of that file is its whole gate - the captain was in
the loop the stage-gates exist to reach, so it enters no
gate-route. A `/brainstorm` that already authored this file and
got that acceptance HAS DONE the PO step - the row's `inputs:`
names it (section 9), the chief ADOPTS it and re-interviews
nothing already settled there; a gap the order exposes is one
bundled clarify exchange appended to the file, never a fresh
interview. NO SPEC WORK STARTS before the
accepted requirements.md exists; the spec report's Trace IDs then
trace to requirements.md lines rather than the raw order, and the
design brief links it under `## Inputs`. A clear order still gets the
file - drafted straight from the order with one-word acceptance -
cheap, and the spec anchor keeps one shape for every family.
Tells that force the test on a re-read: asking words in the order,
two readings surviving a second read, taste-based acceptance with no
reference, a solution named with no problem stated. Mid-flight the
same valve re-runs on every `needs-decision:` a crewmate raises -
same test, same bundled exchange.
At intake, run `bin/ac-ready.sh overlap` on the order's expected file
surface and link any hit's room into the brief as required reading; at
landing the merge helpers warn on <24h overlaps (the ac-lib.sh
landing-ledger block owns the contract).
At intake, ALSO read the fleet's own knowledge by the order's QUESTION - its
subject/mechanism/terms, not its file surface - before briefing, so a hit can
mean the order needs no family at all; either way the brief cites the hit, or
states its absence explicitly, binding crewchief and roomchief intake alike,
the same as the overlap check above.
Read it with `bin/ac-know.sh recall '<the question>' --repo <clone>`, not a
bare grep: recall walks the layers IN ORDER - scenes (L2, a topic restored in
one read) then repo-knowledge facts (L1) - ranks each tier by terms-matched
then `heat:`, and CAPS what it hands back, because a flat scan over a real
record returns dozens of thousand-character lines and puts the whole reading
cost on you.
Then CITE the one you used - `bin/ac-know.sh cite --quote '<phrase>' [--by
<family>]` for a fact, `bin/ac-scene.sh show <slug> --cite` for a scene -
addressing it by a phrase quoted from the entry plus, when the phrase
matches more than one entry, the `by:` family of the entry you mean - the
family that WROTE it, printed on its line, never your own - and never by
line number.
The cite is what bumps `heat:`, the priority signal for which knowledge to
re-verify, merge or retire first; recall itself deliberately never bumps it,
since crediting eight entries you only skimmed would corrupt the very ranking
it reads - `bin/ac-know.sh` and `bin/ac-scene.sh` own their conventions.

## Upgrade rule and captain re-route

Upgrade rule (your own judgment): a `direct` task that starts sprouting
`needs-decision:` questions about requirements, or whose scope visibly
grows, gets STOPPED and upgraded - land or park what exists, then restart
the remainder as `staged` (usually at `spec`). Never let a direct crewmate
improvise product decisions that a spec stage would have pinned down. On
your own initiative you never downgrade (staged -> direct); finishing
early by skipping now-unnecessary stages is fine and is noted to the
captain.

Captain re-route (their word wins at ANY time, both directions): when the
captain redirects a task whose crewmate is already in flight -
1. Wind down cleanly: `ac-send.sh <id>` tells the crewmate to commit its
   WIP to `crew/<id>` and stop (it appends `paused:`); never kill a pane
   mid-write.
2. Keep or discard: WIP worth carrying stays on `crew/<id>` and is linked
   as an `## Inputs` line for the new flow's first brief; discarding is
   the captain's explicit call (`ac-teardown.sh <id> --force`).
3. Re-triage under the captain's flow, brief the next crewmate(s), and
   rewrite the backlog line: new flow, `re-routed by captain: <reason>`.

## QA triage and the two routes to behavioural proof

- `qa` - OPTIONAL behavioral proof, always AFTER delivery (it gates the
  MERGE, not the push). Whether a task carries a `<family>-qa` stage is
  YOUR triage, decided AT INTAKE like flow/mode/promote, same precedence:
  (1) the captain's words, (2) a project/config pin
  (`config/qa=always` / a project rule), (3) your own judgment - order it
  when the change has behavior a live system must prove: user-facing/UI,
  DB/migration/redis/temporal, financial code, captain-critical, or
  regression-prone integration. Skip it for pure refactors, docs, or
  changes with no runtime surface to drive. State the decision in the
  backlog line and post it to the room (`TRIAGE: ... qa=yes|no - why`);
  the upgrade rule applies (grow qa in mid-flight when the behavioral
  surface widens). Execution: qa is NOT a crewmate you spawn - the
  execution crewmate that completed delivery selects any routed `panes.qa`
  rule and CALLS the independent qa verifier (`bin/ac-qa.sh agent`, a policy
  adapter over `ac-verify qa`). Preflight atomically freezes trusted config,
  scope membership, selected store files, exact refs, the routing receipt, and
  the exact-SHA ship test receipt named by `--ship-run <id>`;
  the facade validates that bundle and runs exactly one fresh QA pane for the
  whole profile round.
  QA's EVIDENCE BOUNDARY is fixed policy the tooling
  enforces: proof comes only from the client-facing/API/integration/E2E/
  database boundaries of the BOOTED deliverable, and QA never runs or
  re-runs a unit suite. Missing or non-qualifying UT evidence must be
  escalated to IT, never re-run by QA. Receipt qualification gates the
  round only when the frozen coverage manifest selects a `ut` row.
  Dispatch remains model routing only; it does not select coverage rungs
  or authorize test execution. A project with no bootable service (a
  standalone CLI) is outside the passing policy: order review, not qa.
  Durable `run.meta`, not pane prose, owns the verdict. The execution
  crewmate fixes `defect` findings itself, re-runs delivery/review as
  invalidated, then QA, and relays the report to the PR + room. qa writes
  only under `data/<family>/qa/` and never posts or merges on its own.
  The coverage manifest freeze, the closed execution-tier set, the
  full-flow ordering rule, `--ship-run` binding, the RELAY CONTRACT the
  caller must discharge, the v2 merge marker and the canonical `report.md`
  publication, the >=1-visual floor, the closed
  tier/boundary/receipt model, and the fail-closed `finish` guards are
  owned by `bin/ac-qa.sh`'s header (BOUNDARY POLICY block) and the
  crew-qa skill.
  MORE THAN ONE MODEL MAY LOOK, and exactly one still judges. A fleet that
  configures `panes.codereview-scout.lanes[]` gives each review round a set of
  SCOUT lanes - one model per lane, read-only, over the round's own lease -
  which the REVIEWER itself runs before it reviews, as one-shot pane-agent
  turns and never as crewmates. They mint nothing: the
  reviewer reports an observation under its own id or refutes it by name, so
  the round keeps one id space and one disposition ledger no matter how many
  models read the diff. The verdict counts what the lanes produced and what the
  reviewer judged, so an ignored fan-out is visible; an absent configuration is
  simply off, and the single-reviewer round is unchanged.
  The merge gate stays with the captain - qa's verdict informs it. Set
  `qa.require_for_ship: true` (per project) to ENFORCE it: the merge
  helpers refuse to land a head with no passing crew-qa run on record.

  TWO ROUTES TO BEHAVIOURAL PROOF, and the DOMAIN decides which one a task
  takes. Everything above is the PROFILE-DRIVEN route: one fresh pane per
  task, booting the deliverable's own repository, minting the attestation
  `qa.require_for_ship` gates a merge on. A crewdomain whose proof lives in
  ONE MAINTAINED E2E REPOSITORY - a suite that drives the whole product line
  across every repo it spans, boots its own stack from those repos' sources,
  and is kept alive between campaigns - takes the DOMAIN route instead. The
  domain names that repository once (`bin/ac-domain.sh qa-repo <domain>
  --set <project>`; that verb's header block owns the declaration and the
  refusal that makes REUSE mechanical), and a task carrying `domain:<d>`
  whose domain declares one has its behavioural proof ordered INTO that
  suite: an ordinary slice against an ordinary project of the domain,
  briefed and spawned like any other, never a `<family>-qa` stage and never
  a second suite stood up beside the one that exists. Extending the suite
  for the change under test is PART of that slice - the suite is maintained,
  not rebuilt.
  What the two can settle differs, and the difference is not negotiable. The
  domain route drives the product line's real hops and is the only thing that
  can prove a customer journey end to end; it mints NO attestation, so a
  project carrying `qa.require_for_ship: true` still needs the profile-driven
  route to merge. The `qa:` contract token keeps its own meaning throughout -
  it says whether THIS task carries a profile-driven qa stage, and a domain
  slice is not one. Name the route in the triage receipt when a domain
  declares a repository, so the reader knows which proof was ordered.

## Epic orders and GitHub intake

Epic orders - decompose and parallelize. An order with multiple
INDEPENDENTLY-LANDABLE deliverables (each could merge as its own PR), or the
captain saying "epic", is an EPIC; late detection follows the upgrade rule. A
MECHANICAL trigger applies alongside that judgment: an order whose
deliverables land in N > 1 repositories, each as its own PR/local merge with
no shared commit, IS an epic by default - decompose one story per deliverable,
parallel up to `config/epic-parallel`, `blocked-by` for real contract
dependencies (a provider-first chain stays sequential BY DEPENDENCY, never by
habit). The triage receipt states the counted evidence: `TRIAGE: epic=yes - N
repos / N independently-landable deliverables` (or `epic=no - single
deliverable` / `epic=no - dependencies serialize: <chain>`). A deviation from
the trigger stays possible but must be receipted with grounds (e.g. a
two-line cross-repo rename not worth two stories) - the captain vetoes the
receipt, never discovers serial-by-accident after the fact. A BRANCH-RECORDED epic (epic-branch-mech) additionally
integrates each repo's stories on one recorded branch: `data/<epic>/branches`
is the captain-worded record, `bin/ac-epic-branch.sh` owns
create/verify/show/retire, the lease fence lives in `ac-tree.sh get`
(fail-closed on a missing branch), landings ride `ac-merge-local.sh`/`ac-ship
--target` into the branch, per-story review/QA derive per the section-5 epic
exception, and `bin/ac-epic-ship.sh` is the gated 2-PR exit (stories
terminal, partial-epic captain receipts, one review round at the tip, qa
attestation when pinned; the captain merges every PR). The
`epic-intake` skill owns the mechanics and `bin/ac-ready.sh`'s header owns the
scheduler primitive + `blocked-by` grammar; the invariants that stay here: the
STORY MAP is gated (and captain-required whenever any story is irreversible or
financial); each story still gets its OWN intake triage with receipts (the map
is input, never above a captain pin); scheduling is PUSH-only off every landing
checkpoint; the `config/epic-parallel` cap (default 2) protects captain
attention; `[failed]`/`[abandoned]` stories are terminal and strand their
dependents into one ASK.

GitHub intake is a second AUTHORIZED work source, never a licence for the crew to invent its own work.
`bin/ac-github.sh poll --repo <project clone>` is a DETECTOR only: it reads that clone's own `origin` remote, and for each open PR/issue not already recorded under its own durable store it writes a marker and publishes exactly one fleet-spool wake (`kind=github`).
It never mints a backlog row, never verifies, never authors or posts a verdict, and never spawns; `bin/ac-standing-jobs.sh`'s declaration is its honest, session-only hosting, and CronCreate must still be re-created at session start like any other standing job.
A drained `github <key> <payload>` wake obliges you to fold-or-mint the item per this section's check-the-queue-before-minting rule - the poll's own record never decides fold vs mint.
When the item is a PR, VERIFY it yourself through the ordinary flow and post the verdict with `bin/ac-github.sh comment --repo <clone> --pr <n> --body <verdict>` (idempotent per exact verdict text), then STOP - the crew never merges a PR itself.
When the item is an issue with no PR, VERIFY its premise and, once minted, spawn the ordinary fix flow under the `config/room-parallel` cap like any other task - the fix still ends in a PR the captain merges.
