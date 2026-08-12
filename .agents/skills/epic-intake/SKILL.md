---
name: epic-intake
description: Decompose a multi-deliverable order into an epic - a gated story map with a dependency DAG, per-story intake, push-driven scheduling via ac-ready.sh, a parallelism cap, and a file-overlap backstop. Use when an order carries several independently-landable deliverables (or the captain says "epic"), or when a staged task's design stage reveals separable deliverables.
---

# epic-intake

Epics decompose an order into independently-landable stories, each intaken
as its own direct/staged task and push-scheduled off landing checkpoints.
AGENTS.md section 5 holds the invariants (epic = multi-landable, the map is
gated, scheduling is push-only, the cap protects captain attention); this
skill is the full mechanics. `bin/ac-ready.sh`'s header owns the scheduler
primitive and the `blocked-by` grammar.

## Detection (at intake)

An order carrying multiple INDEPENDENTLY-LANDABLE deliverables (or the
captain says "epic") is an EPIC. Late detection follows the upgrade rule: a
staged task whose design stage reveals separable deliverables is STOPPED and
re-intaken as an epic. A MECHANICAL trigger applies too: an order landing in
N > 1 repositories, each as its own PR/local merge with no shared commit, is
an epic by default with counted evidence in the triage receipt (AGENTS.md
section 5).

Independently-landable = each deliverable could merge as its OWN PR. Sharing
a subsystem or even a FILE never collapses deliverables into one task -
shared files are ORDERING edges in the map; the DAG exists for exactly that.
Tie-breaker (one big staged task vs an epic): would the captain benefit from
partial landings - some value shipped while the rest cooks? Yes -> EPIC. For
financial code the tie-breaker nearly always says epic: several small
independently-reviewed PRs beat one large one.

## The story map (a gated artifact)

A design crewmate delivers it:
- STORIES, each with acceptance criteria and a SINGLE-TOKEN family id.
  Membership comes from the REGISTRY (`epic:<id>` on the story's backlog
  line), NEVER from an id prefix. Ids colliding with reserved suffixes
  (`-spec -arch -plan -review -ship -design -chief -rN`) are invalid.
- The dependency DAG (blocked-by edges, including code-overlap ordering
  edges).
- A suggested flow/mode and a DECLARED promote decision per story (the
  captain vetoes those at the map gate).
- The epic's integration-verification plan.

The map passes `bin/ac-ready.sh validate <epic>` (mechanical: acyclicity,
ids exist, id grammar), then ac-gate, then the three-tier gate - and if ANY
story touches irreversible or financial paths, the WHOLE map is
captain-required.

Map suggestions are SUGGESTIONS: each story still gets its own intake triage
with receipts in the STORY's room, under the standard precedence (captain's
words > config pins > your triage; the map ranks as input to your triage,
never above a pin).

## Scheduling (push-driven, never polled)

Independent stories start immediately (respecting the cap); every story ends
with the standard handback/teardown, and THAT landing checkpoint is the
scheduler - run `bin/ac-ready.sh` (ac-wake-drain and the session-start
digest also run it) and start every story it lists READY. An interrupted
checkpoint heals at the next run - the primitive is idempotent.

A blocker is satisfied only when its line is DONE in the backlog (merged /
merged-local / reported) - dependents therefore serialize on captain merges;
when several merge gates pend at once, bundle them in ONE message ordered by
how many stories each merge unblocks.

CAP: at most `config/epic-parallel` (default 2) stories of one epic in flight
at once, promoted or NOT - the cap protects captain attention, not window
count; the captain's order overrides it.

## Failure, amendments, backstop

- FAILURE is first-class: a story that fails or is discarded moves to Done as
  `[failed]`/`[abandoned]`; ac-ready reports its dependents as STUCK and you
  raise ONE ASK in the epic room with options (re-point the edge / respawn
  the blocker / cancel the dependent).
- Any map change (split/add/cancel a story, new edge) is a MAP-AMEND: delta
  re-gate through ac-gate; additions and cancellations always go to the
  captain.
- OVERLAP BACKSTOP at every landing: intersect the landed story's changed
  files with every in-flight sibling's branch; on any hit that sibling must
  rebase and re-validate before its merge gate.

## The epic's own record

The epic has its OWN room (umbrella: map gate, amendments, cross-story
decisions) and its own backlog line whose rollup you refresh at every landing
checkpoint. The epic flips Done only when ALL stories are terminal AND the
map's integration verification ran.

PREREQUISITE for epic scheduling to survive a promoted roomchief's own
watcher going dark: NOT that you hold the per-home session lock to RUN
scheduling - a promoted epic roomchief's watcher is SCOPED
(`AC_WATCH_ONLY`), and `bin/ac-watch.sh`'s owner gate exempts scoped
watchers by design. What the lock-holding fleet watcher (`bin/ac-lock.sh`)
still protects: the roomchief's OWN `<fam>-chief` pane (which stays
fleet-scoped so its handback reaches the crewchief) and backstop coverage
of a story's panes if the roomchief's own scoped watcher goes stale or dies.
