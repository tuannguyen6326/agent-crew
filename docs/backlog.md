# Backlog grammar

Moved verbatim from `AGENTS.md` section 9, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

`records/backlog.md` is the single task ledger:

```markdown
## In flight
- [ ] <id> - <one line> (repo: <name>, since <date>)
- [ ] <epic-id> [EPIC] - <one line> stories: <s1>,<s2>,<s3> | rollup: <n>/<m> done; flying: ...; waiting-on-captain: ... (repo: <name>, since <date>)
- [ ] <story-id> - <one line>; epic:<epic-id> (repo: <name>, since <date>)

## Queued
- [ ] <id> - <one line> (repo: <name>) blocked-by: <id1>,<id2> - <reason>
- [ ] <story-id> - <one line>; epic:<epic-id> (repo: <name>) blocked-by: <id1>,<id2> - <reason>
- [ ] <id> [@held] - <one line> (repo: <name>) - <why the captain held it>

## Done
- [x] <id> - <one line> - <PR url | local main | path to report.md> (<merged|reported> <date>)
- [x] <id> [failed] - <one line> - <why> (<date>)
- [x] <id> [abandoned] - <one line> - <why> (<date>)
```

`[failed]`/`[abandoned]` are terminal but NEVER satisfy a blocker.
`[@held]`, as one of a row's `[...]` groups in the LEADING RUN right after the
id - contiguous bracket groups, nothing but whitespace between them, not
necessarily the first one there (a row already carrying another bracket tag,
e.g. `[CAPTAIN-ORDERED ...]`, still takes `[@held]` in a second contiguous
group) - is a CAPTAIN HOLD: `bin/ac-ready.sh` refuses to offer that row
(reported `HELD`, never `READY`, never in `ac-ready.sh queued`), the same
fail-closed direction as an unreadable `blocked-by` - a mis-typed hold-shaped
group anywhere on the line still reads as HELD, never as no-hold, whether the
sentinel is present but wrong (`[@hold]`, `[@HELD]`, `[@Held]`, ...) or
forgotten outright (`[held]`, `[hold]`, `[on-hold]`, ... - a bracket group
whose ENTIRE content is one word, no whitespace, needs no sentinel to be
recognized as a hold attempt, because a one-word group can never be a
free-text tag's prose). It is not the dependency token (no blocker id, no
STUCK semantics) and not terminal (nothing lands to clear it). Releasing it is
a CAPTAIN act: no tooling strips `[@held]` automatically, so a chief removes it
from the line by hand only on the captain's word - `bin/ac-task.sh unhold` is
that hand, never a scheduler's.
The DATED arm `[@held until <YYYY-MM-DD>]` is the one hold that releases
ITSELF: `bin/ac-ready.sh` reports it HELD before that date and READY on and
after it, so a hold the captain meant to be time-bound ("not before the
migration lands, 2026-09-01") costs no later hand-edit. Everything else about
it is the bare token's: same leading-run position, same sentinel, same
code-span exemption, and the same fail-closed direction for a slip - a date
that is not exactly `YYYY-MM-DD` is not a dated hold at all but a mis-typed
one, reported `hold malformed`, never an accidental release. The parser
extracts the date (`AC_DONELINE_AWK`'s `f["hold_until"]`), `bin/ac-ready.sh`
is the one that compares it to today. When an expired-dated row STARTS,
`bin/ac-task.sh start` strips the spent token - the date was the captain's
own release, and a leftover hold token on an In-flight line would still read
as waiting-on-captain in every display.
Detection scans every top-level `[...]` group on the line and matches on the
`@` SENTINEL, not the bare word: a live ledger row measurably false-positived
on an earlier bracket-syntax-only design, because this grammar's OTHER
bracket tags (`[SLICE ...]`, `[CAPTAIN ORDER LANDED ...]`) carry free-text
prose that uses "held"/"hold" as an ordinary English verb ("the guardrail
held", "Held until now on a verified collision") - bracket syntax alone
cannot tell a token from a sentence inside a free-text tag. `@` immediately
before the word is the part ordinary prose never writes, so matching on it
keeps the hold token distinguishable from a free-text tag's own prose while
staying structural (still requires `[...]`) - deliberately NOT a whole-line
substring scan like `blocked-by`'s.
Sentinel and bracket syntax still cannot tell a real token from a QUOTATION of
one - this very paragraph has to WRITE `[@held]` to document it, and a
whole-line scan would silently hold this row too, the same self-trip a prior
round already hit. Two more context signals close it: POSITION - only the
leading run (above) carries authority, so a group deeper in the row's own
prose, even spelled exactly `[@held]`, is never the real token - and a CODE
SPAN - a group wrapped in backticks (`` `[@held]` ``, `` `[held]` ``) is a
documentation mention, exempt from both hold and malformed wherever it sits,
the same backtick-wrap convention the roomchief prompt in `bin/ac-spawn.sh` already uses so a
narrative marker verb never trips its own detector. The two combine to close
both directions: a bare (unquoted) token-shaped group outside the leading run
still reads HELD hold malformed, never READY - position denies it authority,
but a real hold mis-placed by one keystroke must not silently schedule
either.
The DELIVERY-CONTRACT token group: ONE leading-run `[...]` group whose
EVERY whitespace-separated token is `key:value` from the closed key set
`src|flow|mode|rev|qa|promote` - e.g.
`[src:cap flow:direct mode:local-only rev:no qa:no]`. The all-tokens-keyed
shape is the discriminator: a leading-run group with any non-`key:value`
content keeps its existing class (provenance prose, `[EPIC]`, `[@held]`).
`AC_DONELINE_AWK` (`f["contract"]`) is the ONE parser; `ac_contract_lint`
(ac-lib.sh) the one value judge; `bin/ac-ready.sh` displays the group on
READY lines and WARNs on violations - display and judgment, never a
scheduling condition; the enforcement point is `ac-brief.sh`'s escalation
gate (section 5). `src` values: `cap` (captain order), `chief`
(chief-minted), `mon` (monitor), `gh` (github), `crew` (routed up),
`learn` (Learning/Curate). A heavy token (`flow:staged`, `mode:crew-ship`,
`rev:yes`, `qa:yes`) on a row is the captain's PIN - writing one without
the captain's word is exactly the drift this grammar exists to stop.

A row `bin/ac-domain.sh assign` stamps carries the `domain:<name>` token in
the position the grammar gives `epic:<id>` (crewdomain-token) - authoritative
ONLY there (before a trailing `(repo: ...)` group, or at end of line); a
`domain:`-shaped run anywhere else unquoted is MALFORMED, fail-visible, and a
backtick-wrapped one is a documentation mention. `epic:<id>` and
`domain:<name>` coexist on one row; a story with no token of its own inherits
its epic row's, and a disagreement is a `validate` refusal - one family, one
domain. `unassign` strips the token from a Queued row; a Done row keeps it as
durable per-domain provenance - re-stamped at END of line when the landing
rewrite gives the row a new trailing `(merged ...)` group, since that group
is not a `(repo: ...)` arm. Only the crewchief stamps (the verb is
chief-only and the ledger guard fences the file), and the token is
deliberately date-free - `ac_doneline`'s date fallback would otherwise adopt
a timestamp as the row's date and verb. `AC_DONELINE_AWK`'s `f["domain"]` is
the ONE parser.

`blocked-by` grammar is machine-read by `bin/ac-ready.sh`: comma-joined ids
with NO spaces, then ` - <reason>`. Story membership is the `epic:<epic-id>`
token on the story line - never an id prefix. FEATURE membership is the
`feature:<name>` token in the same anywhere-matched shape (feature-branch-mech,
`AC_DONELINE_AWK`'s `f["feature"]`); one row never carries both - two
integration targets is a ledger defect the shared resolver orders epic-first
and `ac-feature.sh ship` refuses outright.

`inputs: <path>[, <path>]` is a row's ARTIFACT LINK - home-relative paths to
what the row already stands on and its first brief must read
(`data/<family>/requirements.md`, an accepted `spec/report.md`), written
where the grammar puts `epic:`/`domain:`: before a trailing `(repo: ...)`
group, or at end of line. It is free text to every parser - no scheduler
reads it and none may - and it exists so an artifact minted upstream of the
brief (a `/brainstorm` requirements.md, a design report a re-routed task
carried over) is found by reading the row instead of guessing a path. The
brief lifts each path into its `## Inputs`; a path that no longer resolves is
fixed on the row, never silently dropped.

Before minting a new row, read the open rows (In flight + Queued) and look for one related to it - related means the same file surface, the same mechanism, or the same defect class, not the same wording.
Only a Queued row is foldable: fold the new material into it and name what was added and when.
An In flight row is OFF LIMITS - its crewmate is already working the scope it was briefed on, and folding into it changes that scope mid-run, which is the one thing a brief must not do.
Material overlapping a flying task instead mints a new row, tagged with the overlap and the flying task's id, so whoever picks it up rebases after that task lands.
Folding merges the landing surface only - it does not license scope growth inside the folded row, and each part still gets the smallest diff that solves it.
This binds the crewchief, every roomchief, and every automatic writer of the ledger (monitor sweeps, Learning, Curate).

A RECORD ROW is the one row born in `## Done`, never passing through In
flight or Queued: a `/brainstorm` writes `- [x] brainstorm-<slug> - <outcome>
- <path to its room.md> (reported <date>)` at close. It is not a task -
nothing spawns and nothing lands - and its most valuable outcome ("no rows")
would otherwise leave the ledger silent about a question already thought
through. It carries no delivery-contract group: no flow, mode or review was
ever chosen for it.

Keep it current: at spawn the chief moves an item to In flight; at teardown the chief moves it to Done or back to Queued (`bin/ac-spawn.sh` and `bin/ac-teardown.sh` never write the ledger themselves).

Make those routine moves with `bin/ac-task.sh` (its header is the authoritative
spec) rather than by re-generating markdown: `add`, `start`, `done`, `hold`,
`unhold`, `update-note` and `prune` each touch ONLY the targeted row, take an
advisory lock and publish by tmp+rename, and are idempotent with a one-line
`ok:`/`already:` receipt. Two of its properties change how a row is WRITTEN,
not just edited: a row's narrative belongs in its BODY - indented lines
directly under the bullet, which every parser here ignores, so the LINE stays
the index it is defined to be and a replaced body is archived rather than
rewritten in place - and a Done section that has outgrown the file is pruned
into a dated archive (`prune --keep <n>`) instead of being trimmed by hand.
Hand-editing stays fully legal: the CLI owns no state, re-reads the file on
every verb, and tolerates rows nobody typed through it.
