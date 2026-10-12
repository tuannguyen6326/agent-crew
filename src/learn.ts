// learn.ts - automatic fleet-local Learning. The entry is bin/ac-learn.sh (a
// shim that starts this file through bin/ac-bun.sh); THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-learn.sh as the oracle the differential leg of
// tests/sh/ac-learn.test.sh holds this module to.
//
//
// Usage:
//   ac-learn.sh tick [<landing-id>]
//   ac-learn.sh autoroom
//   ac-learn.sh suite [<task-id>]
//   ac-learn.sh run
//   ac-learn.sh note <line>...          # place landing lessons under `## Pending`
//   ac-learn.sh route-propose < lines    # System One owner/dup proposal per line (config/jev)
//   ac-learn.sh land <candidate-file>   # compatibility-only manual landing
//   ac-learn.sh promote <skill-name>    # fail-closed compatibility command
//   ac-learn.sh maintenance status|resume <txid>|abandon <txid>
//   ac-learn.sh rotate-pending          # archive Pending past config/learn-pending-budget
//   ac-learn.sh stale                   # report-only age grade of the always-loaded layer
//   ac-learn.sh reinforce <slug> --evidence '<line>'  # refresh one learned entry's clock
//
// `tick` advances the lock-protected Learning generation/cadence and reports the
// resulting count. A keyed landing tick is idempotent through state/.learn-ticks.
// The first threshold crossing publishes one learning-due wake; `autoroom`
// evaluates the durable level and uses ac-spawn.sh's atomic `.meta-claims`
// protocol, so concurrent drains can create at most one learning chief.
//
// A DUE `autoroom` promotes nothing until records/learnings.md clears the
// LEDGER SHAPE GATE (shapeGate, checked FIRST, before the suite
// gate below - two greps versus a whole pane run): an un-canonicalized legacy
// rung-qualified pointer row, or a canonical `[distilled -> ...]` row whose
// `[evidence]` link names a records/learnings-archive/<name>.md that does not
// exist, each force every per-candidate plan to bundle a ledger-wide repair
// that the maintenance gate then correctly refuses as over-broad - spending the
// whole DISTILL cycle on candidates it was always going to lose (measured
// twice: 2026-07-28 7/7 revise, 2026-08-03 5/5 revise). Neither shape is
// auto-repaired; the gate HOLDS and prints the one line naming the defect and
// its remedy, same contract as the suite gate.
//
// In a fleet that pins config/learn-suite-gate=on (default off), a DUE
// `autoroom` ALSO promotes nothing until the FULL SUITE is green for the
// current cycle and tree: it starts `suite` as its own paned task and HOLDS,
// printing what it is waiting on. `suite` runs the bare tests/run-suite.sh and
// records one verdict. The gate's contract is the FULL-SUITE GATE block below.
//
// `run` snapshots the retro window, active fleet-local learned skills, and the
// fleet ledgers into data/learning-<epoch>/. A fresh `panes.learning` scout
// writes retro.md, report.md, and candidate files only inside that run. A run is
// complete only when both retro.md and report.md are non-empty and the report
// declares status ok; an incomplete scout cannot advance either cadence.
//
// EXAMINED accounting - the second, independent condition on top of scout
// completeness: the DISTILL cycle (and the retro-window anchor `last_run`)
// resets only when every gated candidate also settled with a genuine
// judgment. `continue`, `revise` (even when its free-text grounds happen to
// name an environment problem - the token layer cannot tell a masked
// environment failure apart from a content verdict, so this is a deliberate
// residual, not a defect this file closes), and the deterministic local
// escalations that never reach the gate at all (`kind: rule`; a malformed
// candidate/plan) are each a rendered judgment and count as examined. A gate
// that could not even run (non-zero exit), a receipt that fails hash/schema
// validation, and a gate that honestly answers `ask-captain` are each an
// ABSENCE of judgment - indistinguishable from each other at this layer - and
// withhold the cycle instead: any one such subject holds the WHOLE run's
// cadence due and leaves `last_run` unmoved, so the next drain re-fires the
// DISTILL rather than silently burning a window nothing was actually read for.
// This is paid even by a perfectly healthy gate raising a genuine
// captain-owned `ask-captain` question - DISTILL keeps re-firing at every
// drain on that same subject, by design, until the captain answers or
// otherwise resolves it and a later run finally settles the cycle.
//
// Each skill/patch/crewmate candidate is converted to one immutable closed action plan
// plus input manifest. The independent explicit maintenance gate
// (`ac-gate.sh maintenance --mode learning`) binds its receipt to both hashes.
// A matching `continue` receipt authorizes the shared backup-first, journaled,
// idempotent maintenance transaction. `revise` preserves Pending without asking
// the captain. `ask-captain`, an unavailable/invalid gate, contradictory input,
// or `kind: rule` emits a durable room question with the exact plan hash; captain
// silence never approves. Learning never invokes QA, unit tests, or service
// validation.
//
// Successful skill/patch transactions write only <fleet>/skills/<name>/SKILL.md
// (a crewmate transaction its CREWMATE-learned.md rewrite instead),
// append source evidence verbatim to records/learnings-archive/<name>.md, remove
// consumed records from `## Pending`, and maintain one canonical fleet-local
// pointer under `## Distilled`:
//   - [distilled -> <name>] sources=<n> updated=<date> (...)
// The archive block is also where a source's QUOTES are checked: a `(by: <id>,
// first-hand)` bullet names a task whose report.md the machine can open, so
// each backtick/double-quoted fragment of >= 6 words absent from that report
// (whitespace-normalized) gets a `quote-unverified: <fragment>` line under the
// bullet and the land line carries the count (quoteUnverified). It is
// visibility, never a gate: a paraphrase wearing quotes still lands, and a
// bullet with no openable source is not judged at all.
// The rewrite is EXACT over every frame this writer can itself emit: outside the
// consumed records and that pointer row it reproduces the ledger byte for byte -
// blank separators, and the surplus seam blanks an older ledger accreted,
// included - so the maintenance gate never sees an edit broader than the plan
// declared, in either direction. It is NOT a fixed point on a frame the writer
// cannot emit - surplus blanks between the title and `## Pending`, or an empty
// `## Pending` exactly two blank lines from `## Distilled` - because one blank
// per seam cannot round-trip them; such a ledger was hand-edited, and the
// transaction canonicalizes it. The `[evidence]` link is emitted only for a pointer
// whose records/learnings-archive/<name>.md already exists or is staged by this
// same transaction, so the index never links a file that does not exist.
// A pointer can never contradict the evidence it links either - but the
// invariant is the DELTA, not the total: on EVERY land, including a skill's
// first, the transaction refuses unless the `sources=` it is about to publish
// grows by exactly what it appends to that archive's `source-count:` lines. The
// TOTALS are allowed to differ, because they measure different things -
// `sources=` is a lifetime aggregate (ledgerSplit folds every pointer row
// sharing a name, legacy rows that predate the archive frame included) while the
// archive only holds what post-frame transactions appended, so total-equality is
// an invariant only for a skill born after the frame. That is what still closes
// `counts[name] += count`: a duplicated row inflates the ledger side of the
// delta and nothing else reconciles it. It is a code invariant, not a data
// repair - an archive that does not exist yet simply declares 0, and a pointer
// with no archive is still written without an `[evidence]` link.
// The transaction resets only the generation it captured. It then ticks Curate
// and runs automatic Curate when its own cadence is due.
//
// `note` is the ONE placing append onto the ledger, and the reason every
// instruction site names it instead of describing a hand-edit: it inserts its
// arguments verbatim at the end of the `## Pending` body, where the retro window
// and the transaction read them. An append at end-of-file lands after
// `## Distilled` - the pointer index - which ledgerSplit drops, so a
// landing lesson written by hand is deleted by the next transaction. It is pure
// insertion (every existing line is reproduced exactly once, so no pending
// source can be lost), carries no opinion about a lesson's own shape, mints the
// canonical frame when the ledger is absent, and refuses a line that is itself a
// section marker.
//
// The apply is RESUMABLE, not all-or-nothing: it mutates N independent files
// and no shell commits N renames atomically, so each action is idempotent by
// hash instead and a replay of the same plan finishes exactly what did not
// land. `maintenance` is the operator surface for that. An UNSETTLED
// transaction refuses every other Learning/Curate transaction, and neither
// `run` (fresh run_id) nor `land` (fresh txid) can ever finish the one holding
// the claim - so a crash between the claim and the final `complete`, or a plan
// whose second action failed, wedged the loop until someone read state/ by
// hand. `status` names every unsettled transaction (as does the session-start
// digest), `resume <txid>` replays its recorded plan through the same
// hash-bound apply, and `abandon <txid>` settles one that cannot be replayed -
// keeping the journal as the record, rolling nothing back, and saying what is
// still committed and where the pre-mutation backup is.
//
// `land` remains a compatibility interface for an already `approved:` candidate,
// but stages and commits through the same maintenance transaction; it is not the
// normal automatic authority. `promote` always refuses because learned skills
// are permanently fleet-owned.
//
// The one-time `migrate` subcommand (the sole legacy container reader) was
// RETIRED by audit-f7 after running on every fleet home: no learnings.md holds
// a live @container pointer anymore, and the legacy container store is never
// read. Its history (gated plan, verbatim archive, recoverable source moves)
// lives in git at the retirement commit.
//
// Candidate files keep the existing `kind`, `name`, `description`, `===sources===`,
// `===skill===`, and `===patch===` grammar. The scout proposes rule candidates
// for captain review but no automatic plan may mutate captain.md.
//
// `kind: crewmate` (learning-output-reroute) is the fourth candidate kind: an
// always-loaded METHOD lesson for the machine-owned $AC_HOME/CREWMATE-learned.md,
// which bin/ac-lib.sh ac_seed_crewmate_md merges into every crew worktree as its own layer
// (container -> learned -> fleet -> crewdomain: the captain's hand-written
// CREWMATE.md deliberately reads later and wins on conflict; captains never
// edit the learned file, transactions never touch CREWMATE.md). The routing
// rule lives in the scout brief: a lesson no task-matched invocation would ever
// reach is a crewmate lesson, and `kind: skill` is reserved for demonstrated
// procedures - each skill land also stages one discovery-pointer line into the
// layer's `## when to reach for a learned skill` section, so no learned skill
// exists without its always-loaded trigger again. That line is the candidate's
// own `trigger:` (at most 100 bytes, refused when missing, over, or starting
// with "when"), never its description, which stays in SKILL.md: a full
// description per pointer can spend a fleet's whole budget.
// Every rewrite of the file also shortens an existing pointer whose trigger is
// over the cap (shortTrigger: a leading "When " dropped, the first clause kept,
// then a cut at a space), so a fleet already at its budget unblocks at its next
// land. The transaction composes the
// `## <name>` heading and `(learned <date>)` provenance itself and REFUSES: a
// body over 12 lines, a body carrying a `## ` heading (entry spoofing), a
// duplicate name, a staged file over the 4096-byte always-loaded budget (the
// refusal names the retire remedy), and any rewrite dropping an existing entry
// without retired accounting (crewmateLearnedNoLoss, src/lib.ts - defense in depth for
// future curate rewrites). Evidence compaction is identical to a skill land -
// archive + `[distilled -> <name>]` pointer - with the pointer's first link
// `[lesson](../CREWMATE-learned.md)` since no skill store exists. The file
// rides recordsBackup's (src/lib.ts) reversibility floor and each planning run keeps a
// backup/CREWMATE-learned.md.prev copy.
//
//
// ROUTE-PROPOSE (the System One route proposer, config/jev). The landing
// split - a `## Lessons` line that VERIFIES something about the codebase goes
// to repo-knowledge, only its method half to the ledger - and the /debrief
// route table (.agents/skills/debrief/SKILL.md) are the same closed-set
// question, judged by the chief's eyes alone, and a repo fact that lands in
// the ledger by mistake is never recovered downstream. `route-propose` reads
// candidate lines on stdin and asks bin/ac-jev.sh two questions per line in
// ONE request: `owner` over the nine debrief destinations, and `dup` over
// new / unclear / every `## <slug>` entry of the always-loaded
// CREWMATE-learned.md - the transaction refuses only a duplicate NAME
// (cmdNote, the 4096-byte budget), this asks whether the LESSON is already
// there - and `worth`: durable (the next crewmate would get it wrong
// untold) / routine (a habit every crewmate is already told) / unclear,
// because every Pending line is first-hand evidence the next distill pays
// to read, and a routine one is a cost, not a gift. Under on it prints one
// TAB-separated line per input line,
// `<n>\towner=<o> p=<p>\tdup-of=<slug|none>[ p=<p>]\tworth=<w> p=<p>`, then
// `state_sha=<sha>` for `ac-jev.sh label --site learn-route`; off or absent
// prints nothing and makes no request; shadow logs only. It proposes and
// writes no ledger: the chief still runs ac-know.sh add and ac-learn.sh note
// with its own hands, and a repo fact is VERIFIED by a cited act, never by
// this answer. WHEN A CHIEF LETS THIS GATE THE PEN (a captain standing rule
// in records/captain.md, since AGENTS.md folds `## Lessons` VERBATIM), the
// fail direction is toward WRITING: only owner=none, dup-of=<entry>, or
// worth=routine drops a line, `unclear` on any question keeps it, and every
// dropped line is receipted to the room - a lost lesson is lost for good, a
// spare line costs one distill read.
//
// TICK. A keyed tick is idempotent per landing: a landing has two possible
// actors (the roomchief before its handback, the crewchief at close-out) and
// neither sees the other's tick, so the key - the family/task id both hold -
// is stamped in state/.learn-ticks under the cadence lock BEFORE the count,
// and a key stamped inside 24 h prints `tick skipped:` instead. The window
// errs long on purpose: counting a landing twice consumes a retro window
// nothing re-examines, missing one only delays the next distill. An unkeyed
// tick (/debrief) is unguarded. Every tick SAYS what it did (`tick:
// debriefs=<n>/<every>`), and the one that CROSSES config/learn-every
// publishes one fleet `learning-due` wake that names no command to run - the
// ACT is autoroom, which reads the level, so a lost wake costs latency only.
//
// AUTOROOM is level-triggered: DUE and no state/learning-chief.meta, two pure
// reads any drain can recompute. A scoped session never promotes. The
// predicate is re-read under state/.learn-autoroom.lock (timeout 0 - a loser
// returns silently), so an ordinary race posts ONE charter; the double
// promote itself is closed by ac-spawn.sh's atomic pre-meta claim, not by
// this lock. Under the lock: the LEDGER SHAPE GATE, then the FULL-SUITE GATE
// below, then the charter posted to room `learning`, then `ac-spawn.sh
// --roomchief learning --system-initiated <the captain.md rule>`; a promote
// that fails with no meta written WARNs and the next drain retries, a
// failure with the meta present is the idempotent loser and is silent. Every
// gate line and the outcome print after the lock is released.
//
// FULL-SUITE GATE (only in a fleet that pins config/learn-suite-gate=on).
// Its state is one verdict record, state/.learn-suite.meta (generation=,
// head=, status=green|red, exit= - run-suite's own status, 124 at the
// ceiling - and at=), and it releases the DISTILL only for a GREEN record of
// THIS cadence generation and THIS generation's PINNED tree. The pin
// (state/.learn-suite-pin.meta) is live HEAD recorded by the first caller of a
// generation and read back by every later one - the gate on each drain and the
// suite task itself - so commits landing mid-run never discard an earned
// verdict. GREEN is sticky for the generation; RED holds without a re-run
// while live HEAD still equals the pinned tree, and once HEAD has moved (or
// no verdict was recorded and no run is in flight) the gate re-pins to live
// HEAD and launches a fresh run - never while a run is in flight. A suite
// run in flight HOLDS; one whose pane the backend DEFINITELY reports gone is
// reclaimed (its snapshot, meta, status and handle removed), an unobservable
// one keeps holding. `suite` runs as its own paned task (kind=verify-suite,
// supervised, outside crew accounting) from an immutable detached worktree
// at the pinned sha under <root>/.crew/learn-suite-snapshots/<id>, removed on
// every exit; AC_LEARN_SUITE_BIN replaces the runner and
// AC_LEARN_SUITE_TIMEOUT the 10800 s ceiling, past which the runner's whole
// process tree is ended and the run records red exit 124.
//
// ROTATE-PENDING. `run` rotates before it snapshots sources/, so the scout's
// copy is a window a verbatim citation can reach. Past
// config/learn-pending-budget bytes (default 131072) of `## Pending` body,
// the oldest CONTIGUOUS prefix moves verbatim to
// records/learnings-archive/pending-<ts>[-<k>].md, cut only at a bullet, a
// heading or a blank, and a `[pending-overflow -> ...]` marker line is left
// at the top of the kept body. Earlier markers are never archived, and the
// ===sources=== bullets of the newest run that wrote report.md stay with
// their continuation lines and their `### <date>` heading (copied to the
// archive too) until a later run has examined them; when they alone outgrow
// the budget they are kept and the line WARNs OVER budget. The rewrite runs
// under .learn-note.lock; an under-budget ledger is left untouched.
//
// RETRO WINDOW. `run` snapshots sources/retro/window.md: the Done rows (the
// shared Done-line grammar) dated on or after the UTC date of .learn.meta's
// last_run - the whole Done section without one - each with its room
// (live, else archived) and the `## Lessons` section of every report.md up
// to three levels under its family dir (a backtick fence hides a quoted
// heading); undated rows are listed as skipped. The reset at the end of an
// examined run stamps last_run, so the anchor moves only with a run that
// produced its report.
//
// STALENESS. `stale` grades every CREWMATE-learned.md entry by the last date
// of its `(learned <d>[, reinforced <d>])` line against
// config/learn-stale-days (default 30) - STALE, FRESH or NO-CLOCK - and the
// scenes by their `updated=`, report-only; `run` snapshots that grading for
// the scout. `reinforce <slug> --evidence '<line>'` is the one in-place edit
// of the layer: it rewrites the date line to `(learned <orig>, reinforced
// <today>)` under <home>/CREWMATE-learned.md.lock, requires a single-line
// evidence it prints rather than stores, and refuses an entry with no clock.
//
// PREAMBLE AND EXIT. Before any verb the fleet backend is resolved as
// sourcing ac-backend.sh resolved it (backendName): an unsupported name in
// AC_BACKEND or config/backend refuses every verb, note and promote included.
// Refusals are `ERROR: <text>` on stderr, exit 1; warnings `WARN: <text>`.
// Exit 0 for every verb that reached its end (a withheld or unjudged run, a
// skipped tick, autoroom and route-propose always); 1 for every refusal, an
// unkeyed tick whose lock was busy and a keyed tick NOT counted; `suite` exits
// with its runner's status (124 at the ceiling); a command the bash ran under
// errexit ends the verb with that command's status. The lib's cadence and
// transaction twins (src/lib.ts `// --- learn twins ---` and `// --- curate
// twins ---`) are the bash ones' twins, held to them by tests/ts/learn.test.ts
// and tests/ts/curate.test.ts.
//
// SIGNALS, as the bash's traps stood at each point. `run` registers nothing
// until its pane ledger is armed, so TERM or HUP before then ends it at once
// and leaves the scout helper running with its meta, status and handle (W7);
// from then on TERM, HUP and INT run the ledger's reap and exit 128+n, a
// signal landing inside a child (a gate's capture, an apply, the Curate
// capture) taking effect once that child returns, as bash deferred it inside
// a capture. `suite` arms its snapshot removal the same way before the
// snapshot exists. No other verb registers a handler.
//
// ESCAPE HATCH. `note` and `tick` sit on every solo landing's own path (the
// solo landing check refuses a slice without its lesson, and teardown runs
// the tick), so a landed change that breaks this module is worked around with
// the frozen original from a scratch bin/ at a PHYSICAL path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-learn.sh "$o/bin/ac-learn.sh"
//   cat tests/fixtures/ac-maintenance-retired.sh >>"$o/bin/ac-maintenance-lib.sh"
// then AC_HOME=<home> "$o/bin/ac-learn.sh" note|tick|run|maintenance ...; a
// solo landing's tick through "$o/bin/ac-teardown.sh" <id> (its STARTED_BIN
// is $o/bin) or a by-hand "$o/bin/ac-learn.sh" tick <id> after the teardown's
// WARN; the drain's autoroom by hand from the copy. The copy bakes no bin path
// into anything it writes; its suite root is the copy dir, which has no git
// HEAD (the suite gate, off by default, would pin `no-head`). No knob
// overrides this entry's path. Each run's and each transaction's tarball (`tar -xzf
// <arc> -C <home>`) undoes a mutation; the captain's revert of the land is the
// last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W1: a note word holding LF passes the whole-word marker refusal, so a
//   `## Distilled` inside it lands as a line of its own and the next
//   transaction drops every Pending line below it unarchived.
// - W3: note and rotate take .learn-note.lock and reinforce its own lock,
//   never the transaction's .maintenance.lock, so a note landing between a
//   plan's staging and its apply HOLDS the transaction or costs the
//   candidate at the gate.
// - The preparer inside `run` keeps the bash's errexit-asleep context: a
//   failing step goes on and only a refusal rejects the candidate, while
//   `land`'s preparer ends at its first failing step.
// - W6: two rule candidates prepared in one second share `rule-<epoch>`, the
//   second overwriting the first's candidate copy, staged captain.md and plan.
// - W7: see SIGNALS; and no run-level lock - two runs in one second share
//   learning-<ts> and verify-learning-<ts>, the second taking the first's
//   pane.handle for its own scout.
// - W8: a malformed config/learn-stale-days grades every entry FRESH inside
//   `run` (its refusal ends only its own substitution there).
// - W9: the Curate capture, every gate capture and the scout wait are bounded
//   by nothing of this module's (the helper's own --timeout aside).
// - W14: a snapshot git could not make still names its path, so a missing
//   runner records red exit 127; `suite` exits with the runner's status and
//   its poll sleep is resolved from `getconf PATH`.
// - W15: `maintenance abandon` rewrites the journal without the maintenance
//   lock.
// - W18: ages spawn BSD `date -j -f` first (the time of day filled from now,
//   Feb 30 normalized to Mar 2), then GNU `date -d`.
// - The scout meta's backend= is the fleet's own (W2, fixed in the bash
//   before it froze).
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every verb needs bun (the shim's `ERROR: required tool not found:
//   bun`, exit 1), where note, tick, stale, maintenance status and
//   rotate-pending ran without it.
// - HOME RESOLUTION and W10: no home is one refusal at the first home read,
//   exit 1 (autoroom: exit 0), where tick printed three, autoroom two, land
//   went on through several, and run and suite reached the host root; an
//   AC_HOME cd cannot enter is `ERROR: AC_HOME is not a readable directory:
//   <h>`.
// - W5 BYTES: every awk is spawned with its program unchanged under LC_ALL=C
//   and every grep over a ledger, candidate or report is read as bytes, where
//   the bash's awk under a UTF-8 caller aborted at an invalid byte (towc) and
//   the errexit-asleep preparer staged the cut ledger as a continue.
// - W11: the bracket grammars - a tick key, a slug, a transaction id, a
//   subject, a retro member id, note's flag refusal - are read per their text
//   (C), where bash's brackets followed LC_COLLATE under a UTF-8 locale.
// - W12 EXCLUSIVE TEMPS: every `<f>.tmp.$$` write (the tick stamps, the scout
//   meta and handle, the reinforce and note rewrites, the ask receipt, the
//   suite pin and verdict) and the staged pointer rewrite's fixed
//   <run>/work/pointers.next.tsv.tmp (a name in the run dir the scout writes,
//   written before any gate judges the plan) go through a temp created
//   exclusively (<f>.tmp.<pid>, then .<n>), so a link planted there is never
//   written through; the written file keeps the umask's mode, as the bash's did.
// - W4 (fixed): reinforce refuses, nothing written, a refresh that would grow
//   CREWMATE-learned.md past its 4096-byte budget; the bash grew it unchecked.
// - THE POINTER TRIGGER: a skill candidate needs `trigger:` and its pointer
//   is composed from it, and every CREWMATE-learned.md rewrite shortens an
//   over-cap pointer already there; the bash composed the pointer from the
//   description and ignored a trigger header.
// - W13 ORDER: globs, the printed candidate list, the report walks, the
//   archived room pick, the pointer sort and the maintenance status rows are
//   in BYTE order, where the bash followed LC_COLLATE and `find` printed
//   directory order.
// - SHELL-OWN STDERR: bash's arithmetic, redirect, test and cd diagnostics and
//   its job notice for a suite runner ended at the ceiling (`Terminated: 15`)
//   are not reproduced, the status kept; a gate, Curate or spawn that cannot
//   start is named by /bin/sh, not bash.
// - BYTES: argv and the environment arrive decoded, so a byte that is no
//   UTF-8 in a note line, a key, an evidence line or a knob reaches the files
//   (and an awk -v value) as U+FFFD; a stale scene date is cut at 10 bytes,
//   where BSD cut counted characters under a UTF-8 locale.
// - A line a lib twin writes to stderr itself (crewmateLearnedNoLoss's grep
//   over an unreadable live layer) reaches the caller's stderr even inside a
//   run's preparer, where the bash's went to the subject's prepare.err.
// - SIGNALS: INT alone ends a run 130 where bash swallowed it while waiting on
//   the scout; a signal landing while a candidate is prepared takes effect
//   once the whole preparer has run, where bash acted after the current
//   command (the extra staged files stay under the run dir); suite's poll
//   sleep is an awaited child, so a TERM there takes effect at once where
//   bash waited out the current `sleep 1`.
// - SUITE LAUNCH: the runner starts in a process group of its own through a
//   `/bin/bash -c 'set -m; ...'` launcher - one process more in its tree than
//   the bash's background job, reaped with it at the ceiling.
//
// CALLERS: src/teardown.ts runs `tick <id>` for every solo slice (its failure
// already the soft `WARN: learning tick ... failed`), the solo session and
// every chief run `note` and keyed `tick` at landing, /debrief the unkeyed
// `tick`, src/wake-drain.ts runs `autoroom` on every unscoped drain (its
// status ignored), the learning roomchief `run` and `reinforce`, the suite
// pane `suite <id>`, and operators `maintenance`, `stale`, `rotate-pending`,
// `land`, `promote` and `route-propose`. What it WRITES is read by
// src/lib.ts soloLandingCheck (learnings.md's Pending), session start (the
// cadence metas, the incomplete transactions, CREWMATE-learned.md), the crew
// seed (CREWMATE-learned.md, skills/), the watcher (the verify-learning and
// verify-suite identities, the wake spool), src/curate.ts (the ledger's
// pointers, learnings-archive/, skills/, the journals), src/gate.ts (plans,
// manifests, receipts) and the dashboard (pointer rows).

import { accessSync, appendFileSync, closeSync, constants as fsConstants, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { acDoneline, records } from "./backlog.ts";
import { receiptValidate } from "./maintenance-receipt.ts";
import {
  NO_HOME,
  SKILLS_ARCHIVE,
  STARTED_BIN,
  arithValue,
  backendCall,
  backendKillWindow,
  backendName,
  backendWindowNew,
  commandV,
  configReadSoft,
  crewmateLearnedNoLoss,
  curateDue,
  curateTick,
  enterCaller,
  exclusiveTemp,
  learnDue,
  learnGeneration,
  learnMeta,
  learnReset,
  learnTick,
  learnTickKeyed,
  lockAcquire,
  lockRelease,
  maintenanceApply,
  maintenanceGateFailureReason,
  maintenanceIncomplete,
  metaGet,
  metaSet,
  nowRaw,
  physicalDir,
  recordsBackup,
  roomFile,
  sha256File,
  shellLength,
  shellQuote,
  shellStatus,
  spawnShell,
  spawnShellSync,
  stageDirForId,
  statusAppend,
  taskMeta,
  taskStatus,
  testInt,
  wakePublish,
  writeAll,
} from "./lib.ts";

// The lib's AC_MAINTENANCE_QUOTE_MIN (tests/ts/learn.test.ts holds the two
// together).
const QUOTE_MIN = 12;

// Byte strings (latin1) carry what the bash held as bytes; argv, the
// environment and the lib's paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const B = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");

// A status the run ends with: a die, or a command errexit would end the
// script on (the shell's own line about it not reproduced). Thrown, so a
// `$(...)` the bash ended only the substitution of catches it.
type Exit = { exit: number };
const fatal = (status: number): never => {
  throw { exit: status } as Exit;
};
const exitOf = (e: unknown): number => {
  if (typeof (e as Exit)?.exit !== "number") throw e;
  return (e as Exit).exit;
};

// The fd the bash's stderr pointed at: the preparer inside auto-apply ran
// with `2>"$prep_err"`, and every line it and its children wrote went there.
let ERR = 2;
function err(s: string): void {
  try {
    writeAll(ERR, B(s));
  } catch {}
}
function dieB(msg: string): never {
  err(`ERROR: ${msg}\n`);
  fatal(1);
}
const warnB = (msg: string): void => err(`WARN: ${msg}\n`);

let OUT = 1;
function out(s: string): void {
  try {
    writeAll(OUT, B(s));
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    fatal(1);
  }
}

// --- the home and its dirs ---------------------------------------------------

let LIVE = "";
function home(): string {
  if (LIVE === "") {
    const h = process.env.AC_HOME;
    if (!h) dieB(NO_HOME);
    LIVE = b8(physicalDir(h) ?? dieB(`AC_HOME is not a readable directory: ${b8(h)}`));
  }
  return LIVE;
}

// ac_*_dir as `$(...)` read them: the dir under the home, minted, a failing
// mkdir going on unseen.
function sub(name: string): string {
  const d = `${home()}/${name}`;
  try {
    mkdirSync(B(d), { recursive: true });
  } catch {}
  return d;
}
const stateD = (): string => sub("state");
const dataD = (): string => sub("data");
const recordsD = (): string => sub("records");
const skillsD = (): string => sub("skills");

const statOf = (p: string) => {
  try {
    return statSync(B(p));
  } catch {
    return null;
  }
};
const isFile = (p: string): boolean => statOf(p)?.isFile() ?? false;
const isDir = (p: string): boolean => statOf(p)?.isDirectory() ?? false;
// `[ -s ]`: exists (a link followed) with a size above zero.
const nonEmpty = (p: string): boolean => (statOf(p)?.size ?? 0) > 0;
const isLink = (p: string): boolean => {
  try {
    return lstatSync(B(p)).isSymbolicLink();
  } catch {
    return false;
  }
};
const exists = (p: string): boolean => existsSync(B(p));
// `[ -e ] || [ -L ]`: anything at the name, a dangling link included.
const present = (p: string): boolean => exists(p) || isLink(p);
const read = (p: string): string | null => {
  try {
    return readFileSync(B(p)).toString("latin1");
  } catch {
    return null;
  }
};
const basename = (p: string): string => {
  const t = p.replace(/\/+$/, "");
  return t === "" ? (p === "" ? "" : "/") : t.slice(t.lastIndexOf("/") + 1);
};
const dirname = (p: string): string => {
  const t = p.replace(/\/+$/, "");
  if (t === "") return p === "" ? "." : "/";
  const i = t.lastIndexOf("/");
  if (i < 0) return ".";
  const d = t.slice(0, i).replace(/\/+$/, "");
  return d === "" ? "/" : d;
};
const sha = (p: string): string | null => {
  try {
    return sha256File(u8(p));
  } catch {
    return null;
  }
};
const byteOrder = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

// The entries a bash glob `<dir>/<pre>*<suf>` names: no dotfile, BYTE order
// (W13: the bash's followed LC_COLLATE).
function glob(dir: string, pre = "", suf = ""): string[] {
  let names: Uint8Array[] = [];
  try {
    names = readdirSync(B(dir), { encoding: "buffer" });
  } catch {
    return [];
  }
  return names
    .map((n) => Buffer.from(n).toString("latin1"))
    .filter((n) => !n.startsWith(".") && n.startsWith(pre) && n.endsWith(suf) && n.length >= pre.length + suf.length)
    .sort(byteOrder)
    .map((n) => `${dir}/${n}`);
}

// --- spawned children, as the shell ran them ----------------------------------

type In = "inherit" | "ignore" | Buffer;
type Io = "inherit" | "ignore" | "pipe" | number;
// A child's status (127 when it cannot start, 128+n when signalled) and its
// stdout when piped; stderr goes where the bash's did (ERR unless a call site
// dropped it).
function run(cmd: string[], io: { stdin?: In; stdout?: Io; stderr?: Io } = {}): { status: number; out: string } {
  const stdout = io.stdout ?? "inherit";
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd.map(u8), {
      stdin: io.stdin ?? "inherit",
      stdout: stdout === "inherit" ? OUT : stdout,
      stderr: io.stderr === undefined || io.stderr === "inherit" ? ERR : io.stderr,
    });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout).toString("latin1") : "" };
}

// `<cmd> >file` (`>>file` with append): the file opened first, as the
// shell's redirection is; null when it cannot be.
function runTo(file: string, cmd: string[], append = false): number | null {
  let fd: number;
  try {
    fd = openSync(B(file), append ? "a" : "w");
  } catch {
    return null;
  }
  try {
    return run(cmd, { stdout: fd }).status;
  } finally {
    closeSync(fd);
  }
}

// Every awk the bash ran is spawned with its program text unchanged, under
// LC_ALL=C: the module reads records as bytes (W5) - the bash's awk under a
// UTF-8 caller aborted at an invalid byte (towc) and its errexit-asleep
// callers kept the cut output.
const awk = (vars: [string, string][], prog: string, files: string[], extra: string[] = []): string[] => [
  "/usr/bin/env",
  "LC_ALL=C",
  "awk",
  ...extra,
  ...vars.flatMap(([k, v]) => ["-v", `${k}=${v}`]),
  prog,
  ...files,
];

// `printf ... >file` / `>>file`; false when the redirection fails.
function put(file: string, bytes: string, append = false): boolean {
  try {
    if (append) appendFileSync(B(file), B(bytes));
    else {
      const fd = openSync(B(file), "w");
      try {
        writeAll(fd, B(bytes));
      } finally {
        closeSync(fd);
      }
    }
    return true;
  } catch {
    return false;
  }
}

// `mktemp [<template>]`, spawned so its name shape, failure line and status
// are mktemp's own; null when it fails.
function mktemp(template?: string): string | null {
  const r = run(template === undefined ? ["mktemp"] : ["mktemp", template], { stdout: "pipe" });
  return r.status === 0 ? subst(r.out) : null;
}

const rmF = (...files: string[]): void => {
  for (const f of files)
    try {
      rmSync(B(f), { force: true });
    } catch {}
};
const mkdirP = (...dirs: string[]): number => run(["mkdir", "-p", ...dirs]).status;

// `{ ... } >"$f.tmp.$$"; mv "$f.tmp.$$" "$f"`: the bytes land in a temp made
// exclusively (<f>.tmp.<pid>, then .<n>) where the bash's name was written
// through, then a spawned mv renames it; mv's status, 1 when no temp could be
// made.
function publish(target: string, bytes: string): number {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(u8(`${target}.tmp`));
  } catch {
    return 1;
  }
  try {
    writeAll(t.fd, B(bytes));
  } catch {
    closeSync(t.fd);
    rmF(b8(t.path));
    return 1;
  }
  closeSync(t.fd);
  return run(["mv", b8(t.path), target]).status;
}

const sleepFor = (secs: string): void => {
  run(["sleep", secs], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
};
const sleepOne = (): void => sleepFor("1");
// The claim is the bash's `mkdir "$lockdir" 2>/dev/null`, spawned, so a PATH
// mkdir sees the instant a lock is taken, as tests/sh/ac-learn.test.sh's note
// handshake and ac-learn-autoroom.test.sh's under-lock re-read do.
const lock = (dir: string, timeout: number): boolean =>
  lockAcquire(u8(dir), timeout, sleepOne, () => run(["mkdir", dir], { stderr: "ignore" }).status === 0);
const unlock = (dir: string): void => {
  try {
    lockRelease(u8(dir));
  } catch {}
};

// ac_iso / ac_now as `$(...)` read them, date(1) spawned so a PATH stub binds
// both sides.
const isoNow = (): string => subst(run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", stdout: "pipe" }).out);
const now = (): string => nowRaw();

// ac_meta_get read as `$(...)`: its warning on stderr and "" when the meta is
// unreadable; ac_meta_set's failure the ignored status every caller gave it.
function metaG(file: string, key: string): string {
  try {
    return metaGet(u8(file), key);
  } catch {
    return "";
  }
}
function metaS(file: string, key: string, value: string): void {
  try {
    metaSet(u8(file), key, value);
  } catch {}
}

// Every line of <text> as `while IFS= read -r` reads it: LF-split, an
// unterminated last line still read, NULs dropped.
function readLines(text: string): string[] {
  const lines = text.replace(/\0/g, "").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

// `IFS=$'\t' read -r a b c`: a leading and trailing run of TABs dropped,
// each run of TABs one separator, the last field keeping the rest (its
// trailing TABs gone too).
function tabRead(line: string, n: number): string[] {
  let rest = line.replace(/^\t+|\t+$/g, "");
  const f: string[] = [];
  for (let i = 0; i < n - 1; i++) {
    const m = /\t+/.exec(rest);
    if (m === null) {
      f.push(rest);
      rest = "";
      continue;
    }
    f.push(rest.slice(0, m.index));
    rest = rest.slice(m.index + m[0].length);
  }
  f.push(rest);
  return f;
}

// The distill contract `run` writes into every run dir's brief.md verbatim, and
// the kickoff naming it: the one source of truth for the scout's instructions.
const SCOUT_BRIEF = `# learning scout - distill contract

You are the independent \`learning\` scout for the agent-crew fleet: a fresh-eyes
pane agent, NOT the crewchief. You PROPOSE, you never land. Nothing you write
reaches a skill store or a ledger. After your turn, the caller validates the
complete run, stages immutable maintenance plans, and sends skill/patch plans
through an independent maintenance gate. Write ONLY inside this run directory.

## Execution constraint (read this first)

Do NOT launch any async/background sub-agents (the \`Agent\`/\`Explore\`/\`Task\`
tools). Read the room snapshots in \`./sources/retro/rooms/*.md\` INLINE
yourself, in ONE continuous flow. Write \`./retro.md\`, then \`./report.md\` and
each \`./candidate-*.md\`, BEFORE your turn ends.

Why: this run harvests you as done the moment your pane goes idle (turn-end).
An async sub-agent ends your turn while it keeps running in the background, so
the run will reap you before you synthesize anything.

If the window is too wide to hold every room snapshot in context at once, work
NEWEST-first and read/summarize snapshots in batches inline, noting in
\`retro.md\` any member you did not reach (see Pass 1 below).

This run has TWO passes, in order: Pass 1 - RETRO reconstructs what actually
happened in the families that landed since the last run; Pass 2 - DISTILL
proposes candidates from the ledgers AND the retro together. Do Pass 1 FIRST -
Pass 2 reads its output.

## Pass 1 - RETRO (do this FIRST)

- Read \`sources/retro/window.md\` - the manifest of every family landed in this
  distill window (or the full \`## Done\` history when this is the first run) -
  and, for each member it marks \`room\`, its \`sources/retro/rooms/<family>.md\`,
  plus \`sources/retro/lessons/<family>.md\` for each member marked \`lessons=<n>\`.
- For EVERY member family, reconstruct: what the family set out to do versus
  what actually landed; friction (gate loops, review rounds, re-routes,
  \`blocked:\`/\`needs-decision:\` items, failures); what worked and should become
  standard practice.
- Add a CROSS-FAMILY section: friction or a working practice that recurs in TWO
  OR MORE families is called out as a pattern - that is what earns a durable
  artifact later, in Pass 2.
- A member's Done line may carry an \`epic:<id>\` token (an epic and each of its
  stories land as separate Done lines that share the token) - GROUP those
  members under their shared epic instead of reconstructing each in isolation,
  so the epic's own friction/pattern is not lost as noise between its stories.
- Every observation cites the family and the room entry (or backlog line) it
  derives from. A family that yields nothing is listed as such - never invent
  material.
- \`window.md\` states the member count up front; a wide window is never
  truncated for you. If it is too wide to cover every member in full, work
  NEWEST-first and say in \`retro.md\` which member(s) you did not reach.
- Write this pass's output to \`./retro.md\` BEFORE you propose any candidate in
  Pass 2.

## Pass 2 - DISTILL

### Sources (read these, in ./sources/)

- \`sources/retro/lessons/<family>.md\` - the \`## Lessons\` sections lifted from
  that family's stage reports (spec/arch/plan/implement), where a crewmate
  wrote its FIRST-HAND method lessons. Present only for members that wrote any
  (window.md marks them \`lessons=<n>\`). Prefer these words over a chief's
  second-hand summary of the same run, exactly as you already prefer a
  \`(by: <task-id>, first-hand)\` ledger bullet.
- \`./retro.md\` - THIS run's Pass 1 output (write it first). A retro
  observation may support a candidate even when \`sources/learnings.md\` never
  captured it - that is the point of the pass.
- \`sources/learnings.md\` - the fleet's raw work-lessons (procedural material).
  This is the NEWEST window: older bullets were rotated verbatim into
  records/learnings-archive/pending-*.md before staging, so every line you
  read here is one your \`===sources===\` citation can actually reach.
  Cluster recurring lessons; a cluster general enough to guide future crews is a
  SKILL candidate. Name the EXACT source bullet line(s) each candidate distils;
  a successful transaction archives them verbatim before replacing them with
  one canonical skill pointer, so it must find them exactly.
- \`sources/captain.md\` - the captain's existing standing rules (semantic memory:
  who the captain is, what they want, how the crew must operate). Read it for
  de-dup / supersede awareness. A recurring captain CORRECTION that is not yet a
  standing rule is a RULE candidate. There is no source bullet to compact for a
  rule (the correction lived in chat), and captain.md wording is NEVER
  paraphrased - propose the rule in the captain's own words.
- \`sources/crewmate-learned.md\` + \`sources/always-loaded-staleness.md\` - the
  ALWAYS-LOADED lesson layer and its age grading. A STALE entry must re-prove
  itself: search THIS window (retro, lessons, rooms) for independent evidence
  that the lesson was exercised, confirmed, or re-derived - plausibility,
  importance, prior knowledge, and the entry's own text are NOT evidence.
  Propose per stale entry, in \`report.md\` under \`## Always-loaded staleness\`
  (report-only, the chief applies - exactly like scene proposals):
  \`reinforce <slug> - evidence: <the window pointer>\` when evidence exists,
  \`retire <slug> - <why>\` when none does (the retire itself rides the
  existing 4096-budget pairing rule at the next land, never a new path).
- \`sources/scenes.md\` - the fleet's L2 SCENE store index (one line per scene:
  slug, heat, updated, summary), plus its count against \`config/scene-max\`. A
  scene is a consolidated TOPIC file a reader opens on purpose - the layer
  between a repo-knowledge fact and the always-loaded crewmate layer. Read this
  before proposing one, both to match a cluster against a scene that already
  covers its territory and to see whether the store has room.

- \`sources/skills/*/SKILL.md\` - the fleet's EXISTING learned skill store (one dir
  per skill). BEFORE proposing a new skill for a lesson cluster, match the
  cluster against these by DESCRIPTION / TERRITORY, never by name: read each
  skill's frontmatter \`description:\` first, then its body, and decide whether the
  cluster's territory is ALREADY covered. This is patch-before-new: a name-only
  clobber-guard would let a same-topic lesson under a different name slip past.

### What to propose

Only candidates the sources genuinely support. Zero candidates is a valid
outcome - say so in the report rather than inventing one. Do NOT capture one-off
incidents or anything a standing rule or existing skill already covers - those
are noise, not durable lessons. A learned skill may never share a NAME with a
built-in crew skill (crew-ship, crew-qa, document). Bullets suffixed
\`(by: <task-id>, first-hand)\` are the crewmate's own words from inside the
work - prefer them as evidence over a chief's second-hand summary of the same
run.

For every lesson cluster, decide between three tiers BEFORE writing a candidate:

- Territory ALREADY covered by an existing skill (matched by description /
  territory above) -> propose a PATCH candidate (\`kind: patch\`) that names that
  existing skill; the body is ONLY the addition, written as a labeled
  \`## <subsection>\` that extends the skill. Do NOT spawn a second same-topic
  skill under a new name. A \`skill-defect: <name> - <what is wrong>\` line in a
  crewmate report is a ready-made patch candidate - prefer it as first-hand
  evidence.
- A METHOD, REASONING, or DISCIPLINE lesson -> propose a CREWMATE-LESSON
  candidate (\`kind: crewmate\`, form below). The routing test: would a crewmate
  matching its CURRENT TASK against this description ever invoke it? If not,
  it is \`kind: crewmate\`, not a skill - it belongs in the always-loaded layer,
  not behind an invocation that will never come.
- GENUINELY NEW procedural territory -> propose a NEW skill candidate
  (\`kind: skill\`), exactly as below. \`kind: skill\` is RESERVED for a
  repeatable multi-step procedure that DEMONSTRABLY WORKED in a real task - a
  recovered error, a corrected approach, or a non-obvious workflow - whose
  sources cite that task's lesson, and whose \`description:\` names the concrete
  trigger (project, operation, or failure mode) a crewmate would search for.
  The routing test above rejects; this names what passes.

ONE BULLET BACKS ONE CANDIDATE - by CONTENT, not just by citation. Decide
which candidate each source bullet BELONGS to BEFORE you write any body, and
let only that one use it. Citing a bullet twice is already impossible (the land
consumes each one once); USING ITS CONTENT in a second candidate's body without
citing it is not, and that is the shape that killed a whole pair on 2026-08-16.
One candidate cited the "a modelled non-zero status is already a refusal"
bullet and was refused as OVER-BROAD (it consumed a source its own lesson does
not need); a second restated that same bullet's content inside \`===patch===\`
without citing it and was refused as REDUNDANT with incomplete provenance. Both
revise, from opposite ends, over one bullet. NOTHING DOWNSTREAM CAN SEE THIS:
the maintenance gate judges ONE candidate at a time, and the land only ever
checks CITATIONS - you are the only reader holding every candidate at once, so
it is YOUR check and nobody else's. Run it explicitly before you write
\`report.md\`: re-read each candidate's body against the bullets the OTHER
candidates cite, and where it uses one, either drop that content or move the
whole lesson to the candidate that owns the bullet. Then report that you ran
the CONTENT check in those words - "no bullet is cited by two candidates" is a
true sentence about citations and says nothing about this.

A candidate supported ONLY by \`./retro.md\` (no \`sources/learnings.md\` bullet
backs it) still gets an EMPTY \`===sources===\` section - do not invent a
bullet - and you must flag it \`source: retro-only\` when you write it up in
\`report.md\` (below), so the captain knows the evidence is this run's retro.

SCENE PROPOSALS are a FIFTH output and they are NOT candidates - they go in
\`report.md\`, never in a \`candidate-*.md\`, because a candidate is by definition
something the maintenance transaction lands and a scene is not landed that way
(it takes the repo-knowledge trust tier: the chief runs \`bin/ac-scene.sh\`
itself, exactly as it runs \`ac-know.sh add\` on a proposed fact). Propose one
when a cluster is a TOPIC rather than a lesson - several facts and lessons that
only make sense together, the thing a reader would want restored in one read.
Write them under a \`## Scene proposals\` section, one block each:

    op: new|update|merge
    name: <slug of the scene to write>
    merge-from: <slug-a,slug-b>        (op=merge only)
    summary: <one line - what this scene restores context for>
    body: |
      <the consolidated topic text>

Match against \`sources/scenes.md\` FIRST: a cluster whose territory an existing
scene already covers is an \`update\` or a \`merge\`, never a second scene under a
new name - the same patch-before-new rule the skill tiers use. If the store is
at or near its cap, propose the \`merge\` that makes room as its own block; do
not propose a \`new\` the store cannot take.

Write each candidate to its own file \`candidate-<slug>.md\`. Do NOT write an
\`approved:\` line. Automatic authority comes only from the later hash-bound
maintenance-gate receipt; candidate headers never authorize mutation.

Skill candidate:

    kind: skill
    name: <slug, lowercase [a-z0-9-]>
    description: <one line - when a crew should reach for this skill>
    trigger: <a few words - the situation, read after "when">
    ===sources===
    <date><TAB><short hook><TAB><exact learnings.md bullet line, verbatim>
    ===skill===
    # <name>

    <the SKILL.md body: the distilled behaviour, in the fleet's own voice>

- \`trigger:\` becomes the always-loaded pointer line
  \`- when <trigger> -> use skill <name>\` every crewmate reads, so it is at most
  100 bytes and does not itself start with "when"; the land refuses one that is
  missing or over. The full \`description:\` stays in the SKILL.md.
- \`<date>\` is the source lesson's date (its \`## YYYY-MM-DD\` section header).
- \`<short hook>\` is a few words naming the lesson - it rides in the pointer that
  replaces the bullet, so keep it terse and specific.
- The third field is the source bullet copied VERBATIM (the whole \`- ...\` line).
- Separate the three fields with a literal TAB.
- A retro-only candidate leaves \`===sources===\` EMPTY (no lines at all).

Patch candidate (extend an EXISTING learned skill in place):

    kind: patch
    name: <slug of the EXISTING skill to patch>
    ===sources===
    <date><TAB><short hook><TAB><exact learnings.md bullet line, verbatim>
    ===patch===
    ## <labeled subsection heading>

    <the addition - the new behaviour that extends the existing skill>

- A patch has NO \`description:\` header - it never touches the existing
  frontmatter.
- \`===sources===\` works exactly as for a skill (the cited bullets are compacted
  on land); a retro-only patch leaves it EMPTY too.
- The \`===patch===\` body MUST lead with a \`## \` heading (the labeled subsection).

Crewmate-lesson candidate (always-loaded method lesson, CREWMATE-learned.md):

    kind: crewmate
    name: <slug, lowercase [a-z0-9-]>
    description: <one line - what behavior this lesson corrects>
    ===sources===
    <date><TAB><short hook><TAB><exact learnings.md bullet line, verbatim>
    ===crewmate===
    <1-3 terse imperative lines - the lesson itself, nothing else>

- The body is LESSON PROSE ONLY, in YOUR OWN distilled words: the transaction
  composes the \`## <name>\` heading and the provenance line itself, and the
  land REFUSES a body over 12 lines, a body carrying its own \`## \` heading,
  or a body that quotes task/repo content verbatim or reads as a directive
  addressed to future agents beyond the lesson's own scope (an always-loaded
  file is a persistence vector - untrusted words never ride into it
  unrewritten; first-hand \`## Lessons\` report lines are EVIDENCE you cite,
  never text you copy through).
- The file has a hard 4096-byte whole-file budget: when your entry would
  exceed it, pair the candidate with a retire proposal in your report.
- \`===sources===\` works exactly as for a skill; retro-only leaves it EMPTY.

Rule candidate:

    kind: rule
    ===rule===
    <the standing rule text, in the captain's own words, appended verbatim>

### Report

Write \`report.md\`: a \`## Retro\` section FIRST (the Pass 1 headline findings -
the cross-family patterns and anything else notable - plus a pointer to
\`./retro.md\`), then for each candidate the file name, what it distils, the
source lesson(s) (or \`source: retro-only\` when \`===sources===\` is empty), and
why it earns a permanent place; note anything you considered and rejected.
This report is what the gate judge and the captain read. Then print a
one-paragraph summary and STOP.
`;

const KICKOFF = `You are the independent \`learning\` scout for the agent-crew fleet - a fresh-eyes pane agent, not the chief. Your full contract is ./brief.md in THIS directory; read it and the raw material under ./sources/ and follow it EXACTLY. PROPOSE only: write your report to ./report.md and each candidate to a ./candidate-<slug>.md file HERE. Write NOTHING outside this directory - never to any skill store, never to records/. When done, print a one-paragraph summary and STOP.
`;

// --- candidate parsing --------------------------------------------------------

const MARKER = /^===[a-zA-Z]*===$/;

// candidate_header: the value of the first `<key>:` line before the first
// ===section=== marker, `<key>:` and the [:space:] after it cut, "" when
// absent. An unreadable file is sed's own line (spawned) and "".
function candidateHeader(file: string, key: string): string {
  const t = read(file);
  if (t === null) {
    run(["sed", "-n", "/^===[a-zA-Z]*===$/q;p", file], { stdout: "ignore" });
    return "";
  }
  for (const line of t.split("\n")) {
    if (MARKER.test(line)) break;
    if (line.startsWith(`${key}:`)) return subst(line.slice(key.length + 1).replace(/^[ \t\n\v\f\r]+/, ""));
  }
  return "";
}

const SECTION_AWK = String.raw`
    $0 == want { insec = 1; next }
    /^===[a-zA-Z]*===$/ { insec = 0 }
    insec { print }
  `;

// candidate_section: the body of the ===<name>=== block up to the next marker
// or EOF, as the spawned awk printed it (each line LF-terminated).
function candidateSection(file: string, name: string): string {
  return run(awk([["want", `===${name}===`]], SECTION_AWK, [file]), { stdout: "pipe" }).out;
}

// The `date hook bullet` rows of a candidate's ===sources=== block as
// `while IFS=$'\t' read -r date hook bullet` reads them.
const sourceRows = (file: string): string[][] => readLines(candidateSection(file, "sources")).map((l) => tabRead(l, 3));

// valid_slug, per the text (W11: the bash's bracket followed collation): one
// or more [a-z0-9-] bytes, no leading, trailing or doubled hyphen, <= 64.
const validSlug = (s: string): boolean => /^[a-z0-9-]+$/.test(s) && !s.startsWith("-") && !s.endsWith("-") && !s.includes("--") && s.length <= 64;

// valid_description: non-empty and at most 1024 characters as `${#d}` counts
// them under the caller's locale.
const validDescription = (d: string): boolean => d !== "" && shellLength(d) <= 1024;

// The pointer line is always loaded into every crew worktree and shares the
// file's 4096 bytes, so its trigger is capped in BYTES (these strings are
// latin1, one char per byte); a trigger reading "when ..." stutters after the
// pointer's own "- when ".
const TRIGGER_MAX = 100;
const validTrigger = (t: string): boolean => t !== "" && t.length <= TRIGGER_MAX && !/^when\b/i.test(t);

// A pointer landed before the trigger field carries the skill's whole
// description; cutting at a space keeps a UTF-8 sequence whole.
function shortTrigger(t: string): string {
  if (t.length <= TRIGGER_MAX) return t;
  let s = t.replace(/^when /i, "");
  const clause = s.search(/: | - |; /);
  if (clause > 0) s = s.slice(0, clause);
  if (s.length <= TRIGGER_MAX) return s;
  const cut = s.lastIndexOf(" ", TRIGGER_MAX);
  return s.slice(0, cut > 0 ? cut : TRIGGER_MAX);
}

const POINTER_SEC = "## when to reach for a learned skill";

function shortenPointers(staged: string): void {
  let inSec = false;
  const lines = (read(staged) ?? "").split("\n").map((l) => {
    if (l.startsWith("## ")) inSec = l === POINTER_SEC;
    const m = inSec ? /^- when (.*) -> use skill ([a-z0-9-]+)$/.exec(l) : null;
    return m ? `- when ${shortTrigger(m[1]!)} -> use skill ${m[2]}` : l;
  });
  step(put(staged, lines.join("\n")) ? 0 : 1);
}

// --- run: the DISTILL run (backup + spawn scout + collect) --------------------

// reap_scout_panes: `<helper> reap-pane --pane <p>` for every non-empty line of
// the run's pane ledger, its stdout captured and stderr dropped, and a WARN
// when the answer says the pane did not close. Never changes the run's status.
function reapScoutPanes(ledger: string): void {
  const t = isFile(ledger) ? read(ledger) : null;
  if (t === null) return;
  const helper = paneAgent();
  if (!executable(helper)) return;
  for (const pane of readLines(t)) {
    if (pane === "") continue;
    const said = run([helper, "reap-pane", "--pane", pane], { stdout: "pipe", stderr: "ignore" }).out;
    if (subst(said).includes('"closed":false')) warnB(`learning scout pane ${pane} did not close - it is orphaned in the pane-agent workspace; retire it by hand: ac-pane-agent.sh reap-pane --pane ${pane}`);
  }
}

const paneAgent = (): string => (process.env.AC_PANE_AGENT ? b8(process.env.AC_PANE_AGENT) : `${b8(STARTED_BIN)}/ac-pane-agent.sh`);

// `[ -x ]`: execute (or, for a directory, search) permission for this user.
function executable(p: string): boolean {
  try {
    accessSync(B(p), fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// learn_epoch_to_date: GNU `date -d @<e>` first, then BSD `date -r <e>`, as
// `$(...)` read them.
function epochToDate(epoch: string): string {
  const g = run(["date", "-u", "-d", `@${epoch}`, "+%Y-%m-%d"], { stdout: "pipe", stderr: "ignore" });
  if (g.status === 0) return subst(g.out);
  return subst(g.out + run(["date", "-u", "-r", epoch, "+%Y-%m-%d"], { stdout: "pipe" }).out);
}

const LIFT_AWK = `
    /^[[:space:]]*\`\`\`/ { fence = !fence; if (f) print; next }
    fence == 0 && /^## Lessons/ { f = 1; next }
    fence == 0 && f && /^## / { exit }
    f
  `;

// `find <base> -maxdepth 3 -name report.md -type f 2>/dev/null | sort`: no
// link followed, an unreadable dir skipped silently, BYTE order (W13).
function findReports(base: string): string[] {
  const found: string[] = [];
  const walk = (dir: string, depth: number): void => {
    let names: Uint8Array[] = [];
    try {
      names = readdirSync(B(dir), { encoding: "buffer" });
    } catch {
      return;
    }
    for (const raw of names) {
      const n = Buffer.from(raw).toString("latin1");
      const p = `${dir}/${n}`;
      let st;
      try {
        st = lstatSync(B(p));
      } catch {
        continue;
      }
      if (n === "report.md" && st.isFile()) found.push(p);
      if (st.isDirectory() && depth < 3) walk(p, depth + 1);
    }
  };
  walk(base, 1);
  return found.sort(byteOrder);
}

// learn_lessons_lift <family> <out>: the `## Lessons` section of every
// report.md under the family's live dir (else its first archived copy, byte
// order - W13), each headed by its path under data/, written to <out>;
// ` lessons=<n>` when any was lifted, else "" and no file.
function lessonsLift(fam: string, outFile: string): string {
  let base = `${dataD()}/${fam}`;
  if (!isDir(base)) base = glob(`${dataD()}/archive`).map((d) => `${d}/${fam}`).filter((p) => present(p))[0] ?? "";
  if (base === "" || !isDir(base)) return "";
  let body = "";
  let n = 0;
  const prefix = `${dataD()}/`;
  for (const rep of findReports(base)) {
    const lifted = run(awk([], LIFT_AWK, [rep]), { stdout: "pipe" }).out;
    if (!/[^ \t\n\v\f\r]/.test(lifted)) continue;
    body += `### ${rep.startsWith(prefix) ? rep.slice(prefix.length) : rep}\n\n${lifted}\n`;
    n++;
  }
  if (n === 0) return "";
  put(outFile, `# Stage-report lessons: ${fam}\n\n${body}`);
  return ` lessons=${n}`;
}

// learn_retro_snapshot <rundir>: the distill window's manifest
// sources/retro/window.md, each member's room and lifted lessons; the member
// count, or null where the bash returned 2 (a ledger it could not read).
// Membership is the Done-line parser in process (src/backlog.ts acDoneline
// over awk's records): a dated row whose date is not before the anchor - the
// UTC date of .learn.meta's last_run, or the whole Done section without one.
function retroSnapshot(rundir: string): string | null {
  const retrodir = `${rundir}/sources/retro`;
  mkdirP(`${retrodir}/rooms`, `${retrodir}/lessons`);
  let anchorEpoch = metaG(b8(learnMeta()), "last_run");
  if (!/^[0-9]+$/.test(anchorEpoch)) anchorEpoch = "";
  const anchorDate = anchorEpoch !== "" ? epochToDate(anchorEpoch) : "";
  const backlog = `${recordsD()}/backlog.md`;
  const members: string[] = [];
  const skipped: string[] = [];
  if (isFile(backlog)) {
    const text = read(backlog);
    if (text === null) return null;
    let sec = "";
    for (const line of records(text)) {
      if (line.startsWith("## Done")) {
        sec = "done";
        continue;
      }
      if (line.startsWith("## ")) {
        sec = "";
        continue;
      }
      if (sec !== "done" || !/^- \[[ x]\] /.test(line)) continue;
      const o = acDoneline(line);
      const marker = o.terminal === "failed" || o.terminal === "abandoned" ? o.terminal : o.verb;
      if (o.date === "") skipped.push(`${o.id}\t${line}`);
      else if (anchorDate === "" || o.date >= anchorDate) members.push(`${o.id}\t${o.date}\t${marker}\t${line}`);
    }
  }
  const count = String(members.length);
  let w = anchorDate !== "" ? `anchor: ${anchorEpoch} (${anchorDate})\n` : "anchor: none - full Done section\n";
  w += `resolved: ${isoNow()}\nmembers: ${count}\n\n`;
  if (members.length === 0) w += "no families landed in this window\n\n";
  else {
    w += "## Members\n\n";
    for (const m of members) {
      const [id = "", date = "", marker = "", doneline = ""] = tabRead(m, 4);
      if (id === "") continue;
      if (/[^a-zA-Z0-9_-]/.test(id)) w += `${id} ${date} ${marker} no-room\n`;
      else {
        const roomsrc = b8(roomFile(u8(id)));
        const lessons = lessonsLift(id, `${retrodir}/lessons/${id}.md`);
        if (isFile(roomsrc)) {
          run(["cp", roomsrc, `${retrodir}/rooms/${id}.md`]);
          w += `${id} ${date} ${marker} room${lessons}\n`;
        } else w += `${id} ${date} ${marker} no-room${lessons}\n`;
      }
      w += `  ${doneline}\n\n`;
    }
  }
  if (skipped.length > 0) {
    w += "## Skipped (no parsable date)\n\n";
    for (const s of skipped) {
      const [id = "", doneline = ""] = tabRead(s, 2);
      if (id === "") continue;
      w += `${id} skipped-no-date\n  ${doneline}\n\n`;
    }
  }
  put(`${retrodir}/window.md`, w);
  return count;
}

// A command errexit would end the run on: its status ends it.
const must = (status: number): void => {
  if (status !== 0) fatal(status);
};

// `$(<cmd> 2>&1)`: stdout and stderr in WRITE order through the one pipe a
// /bin/sh exec hands the child for both, the stdin the caller's.
function captureMerged(cmd: string[]): { status: number; out: string } {
  const r = run(["/bin/sh", "-c", 'exec "$0" "$@" 2>&1', ...cmd], { stdout: "pipe" });
  return { status: r.status, out: subst(r.out) };
}

// The EXIT trap the bash armed by then: run on every way out - the end, a
// die, errexit and TERM/HUP/INT (bash's termination runs it; a signal that
// lands inside a synchronous child waits for that child, as bash deferred it
// inside a capture).
let EXIT_TRAP: (() => void) | null = null;
function armTrap(fn: () => void): void {
  EXIT_TRAP = fn;
  for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const)
    process.on(sig, () => {
      runTrap();
      process.exit(128 + n);
    });
}
// A point where bash, past a command that held a signal back, acted on it:
// the pending handler runs here, never inside a synchronous child.
const checkpoint = (): Promise<void> => Bun.sleep(0);

function runTrap(): void {
  const t = EXIT_TRAP;
  EXIT_TRAP = null;
  if (t !== null)
    try {
      t();
    } catch {}
}

const dateS = (): string => subst(run(["date", "+%s"], { stdout: "pipe" }).out);

// `sleep <s>` as an awaited child, so the event loop - and the scout's exit -
// is observed while the bash's loop slept.
async function sleepAsync(secs: string): Promise<void> {
  try {
    await spawnShell(["sleep", secs], { stdin: "ignore", stdout: "ignore", stderr: "ignore" }).exited;
  } catch {}
}

// `$(( a + b ))` over two shell texts: bash arithmetic, an error ending the
// run with status 1 as the shell's expansion error did.
function arithSum(a: string, b: string): bigint {
  try {
    return BigInt.asIntN(64, arithValue(a) + arithValue(b));
  } catch {
    return fatal(1);
  }
}

// `read -r a rest <file>` under the default IFS: the first line, outer blanks
// cut, split at its first run of blanks.
function readPair(file: string): [string, string] {
  const first = (read(file) ?? "").replace(/\0/g, "").split("\n")[0]!.replace(/^[ \t]+|[ \t]+$/g, "");
  const m = /[ \t]+/.exec(first);
  return m === null ? [first, ""] : [first.slice(0, m.index), first.slice(m.index + m[0].length)];
}

// learn_cadence_call: the bash ran the cadence helper inside `$(...)`, so a
// failure that ended the shell there (an arithmetic error over a count or a
// generation of 08) ended only that capture, having spoken - the caller's 2,
// the shell's own line not reproduced and the cadence lock left held, as the
// ended capture left it.
function cadenceCall(call: () => number): number {
  try {
    return call();
  } catch (e) {
    if (SHELL_ENDS.has((e as { code?: string })?.code ?? "")) return 2;
    throw e;
  }
}

async function cmdRun(): Promise<void> {
  requireTool("jq");
  home();
  const learnGen = learnGeneration();
  const backup = recordsBackup("learn");
  if (backup === null) fatal(1);
  const ts = now();
  const rundir = `${dataD()}/learning-${ts}`;
  must(mkdirP(`${rundir}/sources`));

  rotatePending();

  const recs = recordsD();
  const captain = `${recs}/captain.md`;
  if (isFile(`${recs}/learnings.md`)) must(run(["cp", `${recs}/learnings.md`, `${rundir}/sources/learnings.md`]).status);
  if (isFile(captain)) must(run(["cp", captain, `${rundir}/sources/captain.md`]).status);

  const retroMembers = retroSnapshot(rundir) ?? dieB("cannot read the ledger for the retro window");

  for (const sksrc of glob(skillsD())) {
    if (!isFile(`${sksrc}/SKILL.md`)) continue;
    const skname = basename(sksrc);
    if (skname === SKILLS_ARCHIVE) continue;
    const skdst = `${rundir}/sources/skills/${skname}`;
    if (exists(skdst)) continue;
    must(mkdirP(skdst));
    must(run(["cp", `${sksrc}/SKILL.md`, `${skdst}/SKILL.md`]).status);
  }

  const scenes = `${rundir}/sources/scenes.md`;
  if (runToQuiet(scenes, [`${b8(STARTED_BIN)}/ac-scene.sh`, "list"]) !== 0) put(scenes, "");

  if (isFile(`${home()}/CREWMATE-learned.md`)) must(run(["cp", `${home()}/CREWMATE-learned.md`, `${rundir}/sources/crewmate-learned.md`]).status);
  const staleness = `${rundir}/sources/always-loaded-staleness.md`;
  {
    let text = "";
    let ok = true;
    const savedErr = ERR;
    ERR = openDevNull();
    try {
      cmdStale((s) => (text += s), true);
    } catch (e) {
      exitOf(e);
      ok = false;
    } finally {
      closeSync(ERR);
      ERR = savedErr;
    }
    put(staleness, ok ? text : "");
  }

  if (!put(`${rundir}/brief.md`, SCOUT_BRIEF)) fatal(1);

  const helper = paneAgent();
  if (!executable(helper)) dieB(`no pane-agent helper at ${helper} (set AC_PANE_AGENT)`);

  const kickoff = `${rundir}/kickoff.md`;
  if (!put(kickoff, KICKOFF)) fatal(1);

  const verifyId = `verify-learning-${ts}`;
  const verifyMeta = b8(taskMeta(u8(verifyId)));
  const verifyStatus = b8(taskStatus(u8(verifyId)));
  const verifyHandle = `${stateD()}/.pane-${verifyId}`;
  const paneEarly = `${rundir}/pane.handle`;
  const outTmp = `${rundir}/scout.ndjson`;

  // The background job: its redirections are the job's own, so one that
  // cannot be opened is a job that ended 1 at once, never the run's end. A
  // job without job control reads /dev/null.
  let job: ReturnType<typeof spawnShell> | null = null;
  let jobDone = false;
  {
    let o = -1;
    let e = -1;
    try {
      o = openSync(B(outTmp), "w");
      e = openSync(B(`${rundir}/scout.err`), "w");
      const saved = process.env.AC_WINDOW_FAMILY;
      process.env.AC_WINDOW_FAMILY = "learning";
      try {
        job = spawnShell(
          [helper, "run", "--cwd", rundir, "--prompt-file", kickoff, "--kind", "learning", "--label", verifyId, "--timeout", b8(process.env.AC_LEARN_TIMEOUT || "7200"), "--deliverable", `${rundir}/report.md`, "--pane-file", paneEarly].map(u8),
          { stdin: "ignore", stdout: o, stderr: e },
        );
      } catch {
        job = null;
      } finally {
        if (saved === undefined) delete process.env.AC_WINDOW_FAMILY;
        else process.env.AC_WINDOW_FAMILY = saved;
      }
    } catch {}
    for (const fd of [o, e]) if (fd >= 0) closeSync(fd);
    if (job === null) jobDone = true;
    else void job.exited.then(() => (jobDone = true));
  }

  const deadline = arithSum(dateS(), b8(process.env.AC_LEARN_START_TIMEOUT || "30"));
  while (!nonEmpty(paneEarly) && !jobDone) {
    const t = testInt(dateS());
    if (t === null || t >= deadline) break;
    await sleepAsync("0.05");
  }
  let pane = "";
  let rawTab = "";
  if (nonEmpty(paneEarly)) [pane, rawTab] = readPair(paneEarly);
  if (pane !== "") {
    const h = publishOrSkip(verifyHandle, `${pane} ${rawTab}\n`);
    if (h !== null) must(h);
    const metaTmp = tempFile(verifyMeta);
    if (metaTmp === null) fatal(1);
    if (!putFd(metaTmp.fd, `kind=verify-learning\nproject=${basename(home())}\nbackend=${backendName()}\nwindow=${pane}\ncwd=${rundir}\n`)) fatal(1);
    statusOrDie(verifyId, `started learning scout pane=${pane}`);
    must(run(["mv", b8(metaTmp.path), verifyMeta]).status);
  }

  if (job !== null) await job.exited;
  const cat = run(["cat", outTmp], { stdout: "pipe" });
  must(cat.status);
  const out_ = subst(cat.out);
  if (pane !== "") statusOrDie(verifyId, "learning scout pane returned");
  rmF(verifyHandle, verifyMeta, verifyStatus);
  if (!put(`${rundir}/scout.log`, `${out_}\n`)) fatal(1);

  const ledger = `${rundir}/scout.panes`;
  {
    const panes = run(["jq", "-r", "select(.pane != null) | .pane"], { stdin: B(`${out_}\n`), stdout: "pipe", stderr: "ignore" }).out;
    put(ledger, readLines(panes).filter((l) => l !== "").map((l) => `${l}\n`).join(""), true);
  }
  armTrap(() => reapScoutPanes(ledger));

  await checkpoint();
  const dones = run(["jq", "-c", 'select(.event == "done")'], { stdin: B(`${out_}\n`), stdout: "pipe", stderr: "ignore" });
  const doneLine = readLines(dones.out).pop() ?? "";
  if (dones.status !== 0) fatal(dones.status);
  if (doneLine === "") dieB(`learning scout emitted no done event (raw: ${rundir}/scout.log)`);
  const jqField = (prog: string): string => {
    const r = run(["jq", "-r", prog], { stdin: B(`${doneLine}\n`), stdout: "pipe" });
    must(r.status);
    return subst(r.out);
  };
  const status = jqField(".status");
  let scoutOk = false;
  if (status === "ok") scoutOk = true;
  else warnB(`learning scout ended '${status}' - preserving the run and due cadence; no candidate will be gated or applied`);
  const transcript = jqField('.transcript // ""');

  out(`learning run ${rundir}\n`);
  out(`  backup: ${backup}\n`);
  if (transcript !== "") out(`  transcript: ${transcript}\n`);
  let examined = false;
  if (nonEmpty(`${rundir}/report.md`)) out(`  report: ${rundir}/report.md\n`);
  else out("  report: (none written)\n");
  if (isFile(`${rundir}/retro.md`)) out(`  retro: ${rundir}/retro.md\n`);
  else {
    out("  retro: (none written)\n");
    const m = testInt(retroMembers === "" ? "0" : retroMembers);
    if (m !== null && m > 0n) warnB(`retro window had ${retroMembers} member(s) but no retro.md was written - inspect ${rundir}`);
  }
  const cands = listing(rundir, "candidate-", ".md");
  out(`  candidates: ${cands.length}\n`);
  for (const c of cands) out(`    ${c}\n`);
  let scoutComplete = false;
  if (scoutOk && nonEmpty(`${rundir}/report.md`) && nonEmpty(`${rundir}/retro.md`)) {
    scoutComplete = true;
    examined = true;
    if (!(await autoApplyCandidates(rundir))) {
      examined = false;
      warnB("one or more Learning subjects could not reach a settled receipt/apply state; cadence remains due");
    }
  } else out("AUTO-MAINTENANCE WITHHELD: a complete ok report + retro is required before gating or apply.\n");

  await checkpoint();
  curateTick();
  const [curateN, curateEvery] = curateDue();
  if (BigInt(curateN) >= BigInt(curateEvery)) {
    const curateCmd = process.env.AC_CURATE ? b8(process.env.AC_CURATE) : `${b8(STARTED_BIN)}/ac-curate.sh`;
    const c = captureMerged([curateCmd, "run"]);
    await checkpoint();
    if (c.status === 0) out(`  automatic Curate:\n${c.out}\n`);
    else warnB(`Curate is due (${curateN}/${curateEvery}) but its automatic run failed; Curate cadence remains due`);
  }

  if (examined) {
    const r = cadenceCall(() => learnReset(learnGen));
    if (r === 2) warnB("Learning completed, but its cadence lock was busy - the DISTILL cycle is NOT consumed and the retro window is NOT advanced");
    else if (r !== 0) warnB("Learning completed, but a newer cadence generation exists; late debriefs remain due instead of being erased");
  } else if (scoutComplete) warnB(`a maintenance gate could not judge one or more subjects - the DISTILL cycle is NOT consumed and the retro window is PRESERVED (still due; re-run after inspecting ${rundir})`);
  else warnB(`the scout did not produce a complete ok report + retro - the DISTILL cycle is NOT consumed and the retro window is PRESERVED (still due; re-run after inspecting ${rundir})`);
}

// `<cmd> >file 2>/dev/null`: the status, 1 when the file cannot be opened.
function runToQuiet(file: string, cmd: string[]): number {
  let fd: number;
  try {
    fd = openSync(B(file), "w");
  } catch {
    return 1;
  }
  try {
    return run(cmd, { stdout: fd, stderr: "ignore" }).status;
  } finally {
    closeSync(fd);
  }
}

function openDevNull(): number {
  return openSync("/dev/null", "w");
}

// An exclusive <f>.tmp.<pid> (then .<n>) for a `>"$f.tmp.$$"` write; null
// when it cannot be made, the redirect's failure.
function tempFile(f: string): { path: string; fd: number } | null {
  try {
    return exclusiveTemp(u8(`${f}.tmp`));
  } catch {
    return null;
  }
}
function putFd(fd: number, bytes: string): boolean {
  try {
    writeAll(fd, B(bytes));
    return true;
  } catch {
    return false;
  } finally {
    closeSync(fd);
  }
}

// `printf ... >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"`: null when the temp write
// failed (the list's first command - no errexit), else mv's status.
function publishOrSkip(f: string, bytes: string): number | null {
  const t = tempFile(f);
  if (t === null || !putFd(t.fd, bytes)) return null;
  return run(["mv", b8(t.path), f]).status;
}

// ac_status_append called bare under errexit: a date that cannot run, or a
// primary append that fails, ends the run with that status.
function statusOrDie(id: string, line: string): void {
  let ok: boolean;
  try {
    ok = statusAppend(u8(id), line, true);
  } catch (e) {
    return fatal((e as { status?: number }).status ?? 1);
  }
  if (!ok) fatal(1);
}

// `find <dir> -maxdepth 1 -name '<pre>*<suf>'`: every entry so named, of any
// type, in BYTE order (W13: find printed directory order).
function listing(dir: string, pre: string, suf: string): string[] {
  let names: Uint8Array[] = [];
  try {
    names = readdirSync(B(dir), { encoding: "buffer" });
  } catch {
    return [];
  }
  return names
    .map((n) => Buffer.from(n).toString("latin1"))
    .filter((n) => n.startsWith(pre) && n.endsWith(suf) && n.length >= pre.length + suf.length)
    .sort(byteOrder)
    .map((n) => `${dir}/${n}`);
}

// --- always-loaded staleness: the aging signal --------------------------------

// learn_stale_days: config/learn-stale-days (default 30), refused unless
// digits; an unreadable knob's head(1) line goes where this verb's stderr does.
function learnStaleDays(): string {
  const d = b8(configReadSoft("learn-stale-days", "30", ERR === 2 ? "inherit" : "ignore"));
  if (!/^[0-9]+$/.test(d)) dieB(`config/learn-stale-days must be a day count (got: '${d}')`);
  return d;
}

const ENTRY_DATE_AWK = String.raw`
    $0 == want { in_e = 1; next }
    in_e && /^## / { exit }
    in_e && /^\(learned / {
      line = $0
      if (match(line, /reinforced [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
        print substr(line, RSTART + 11, 10)
      else if (match(line, /learned [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
        print substr(line, RSTART + 8, 10)
      exit
    }
  `;

// learn_alw_entry_date <file> <slug>: the entry's last clock date (reinforced,
// else learned), "" when it carries none.
const entryDate = (file: string, slug: string): string => subst(run(awk([["want", `## ${slug}`]], ENTRY_DATE_AWK, [file]), { stdout: "pipe" }).out);

// learn_age_days: whole UTC days since a YYYY-MM-DD, "" for any other shape
// or a date neither BSD `date -j -f` nor GNU `date -d` reads (both spawned:
// BSD fills the time of day from now and normalizes Feb 30 - W18).
function ageDays(d: string): string {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(d)) return "";
  const a = run(["date", "-u", "-j", "-f", "%Y-%m-%d", d, "+%s"], { stdout: "pipe", stderr: "ignore" });
  let then = a.out;
  if (a.status !== 0) {
    const g = run(["date", "-u", "-d", d, "+%s"], { stdout: "pipe", stderr: "ignore" });
    if (g.status !== 0) return "";
    then += g.out;
  }
  then = subst(then);
  if (then === "") return "";
  try {
    const diff = BigInt.asIntN(64, arithValue(now()) - arithValue(then));
    return String(diff / 86400n);
  } catch {
    return "";
  }
}

// `printf '%-40s'` pads by bytes on bash 3.2.
const pad40 = (s: string): string => s.padEnd(40, " ");

// The `## ` heads of CREWMATE-learned.md as `grep '^## ' | grep -vxF '## when to
// reach for a learned skill' | sed 's/^## //'` printed them.
function learnedSlugs(live: string): string[] {
  const t = read(live) ?? "";
  return readLines(t)
    .filter((l) => l.startsWith("## ") && l !== "## when to reach for a learned skill")
    .map((l) => l.slice(3));
}

// cmd_stale, its output through <emit>. <lax> is the run's `cmd_stale >f
// 2>/dev/null || :` - errexit asleep, so a refused learn-stale-days ends only
// its own substitution and every entry is graded against an empty day count
// (W8: FRESH).
function cmdStale(emit: (s: string) => void, lax: boolean): void {
  let days: string;
  try {
    days = learnStaleDays();
  } catch (e) {
    if (!lax) throw e;
    exitOf(e);
    days = "";
  }
  const daysN = testInt(days);
  const stale_ = (age: string): boolean => {
    const a = testInt(age);
    return age !== "" && a !== null && daysN !== null && a >= daysN;
  };
  const live = `${home()}/CREWMATE-learned.md`;
  emit(`always-loaded (CREWMATE-learned.md), stale past ${days} days:\n`);
  if (!isFile(live)) emit("  (no file yet)\n");
  else {
    let n = 0;
    let stale = 0;
    for (const slug of learnedSlugs(live)) {
      if (slug === "") continue;
      n++;
      const d = entryDate(live, slug);
      if (d === "") {
        emit(`  ${pad40(slug)} NO-CLOCK\n`);
        continue;
      }
      const age = ageDays(d);
      let verdict = "FRESH";
      if (stale_(age)) {
        verdict = "STALE";
        stale++;
      }
      emit(`  ${pad40(slug)} ${d}  age=${age === "" ? "?" : age}d  ${verdict}\n`);
    }
    emit(`  -- ${n} entries, ${stale} stale --\n`);
    if (stale > 0) {
      emit("  a STALE entry must re-prove itself: reinforce it on INDEPENDENT current evidence\n");
      emit("    (ac-learn.sh reinforce <slug> --evidence '<what this window proved>') or retire it\n");
      emit("    at the next land (the 4096-budget pairing rule) - never keep it by inertia alone.\n");
    }
  }
  const sdir = `${recordsD()}/scenes`;
  const scenes = glob(sdir, "", ".md");
  if (isDir(sdir) && scenes.length > 0) {
    emit(`scenes (records/scenes/), stale past ${days} days:\n`);
    for (const sf of scenes) {
      if (!isFile(sf)) continue;
      const sslug = basename(sf).replace(/\.md$/, "");
      const line2 = (read(sf) ?? "").split("\n")[1] ?? "";
      const supd = subst(
        line2
          .split(" ")
          .filter((t) => t.startsWith("updated="))
          .map((t) => `${t.slice(8).slice(0, 10)}\n`)
          .join(""),
      );
      const sage = ageDays(supd);
      if (stale_(sage)) emit(`  ${pad40(sslug)} ${supd}  age=${sage}d  STALE (merge or update it - ac-scene.sh)\n`);
      else emit(`  ${pad40(sslug)} ${supd}  age=${sage === "" ? "?" : sage}d  FRESH\n`);
    }
  }
}

const REINFORCE_AWK = String.raw`
    $0 == want { in_e = 1; print; next }
    in_e && /^## / { in_e = 0 }
    in_e && /^\(learned / && !done {
      line = $0
      sub(/, reinforced [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/, "", line)
      sub(/\)$/, ", reinforced " today ")", line)
      print line; done = 1; next
    }
    { print }
  `;

// `grep -qxF <p> <file>`: a pattern holding LF is several patterns.
function grepWhole(file: string, pattern: string): boolean {
  const t = read(file);
  if (t === null) return false;
  const pats = pattern.split("\n");
  return t.split("\n").some((l, i, all) => (i < all.length - 1 || l !== "") && pats.includes(l));
}

function cmdReinforce(args: string[]): void {
  let slug = "";
  let evidence = "";
  for (let i = 0; i < args.length; ) {
    const a = b8(args[i]!);
    if (a === "--evidence") {
      evidence = args[i + 1] !== undefined ? b8(args[i + 1]!) : "";
      if (i + 2 > args.length) dieB(`${a} needs a value`);
      i += 2;
    } else if (a.startsWith("-")) dieB(`unknown flag: ${a}`);
    else {
      if (slug !== "") dieB(`reinforce takes ONE slug (got '${slug}' and '${a}')`);
      slug = a;
      i++;
    }
  }
  if (slug === "") dieB("usage: ac-learn.sh reinforce <slug> --evidence '<what this window proved>'");
  if (evidence === "") dieB("reinforce REQUIRES --evidence: plausibility, importance, prior knowledge, and the entry's own text are not evidence - name what THIS window actually exercised, confirmed, or re-derived. The evidence rides the receipt (and your room post), never the file: bytes there are always-loaded budget.");
  if (/[\n\r]/.test(evidence)) dieB("--evidence must be a single line");
  const live = `${home()}/CREWMATE-learned.md`;
  if (!isFile(live)) dieB("no CREWMATE-learned.md in this home - nothing to reinforce");
  if (!grepWhole(live, `## ${slug}`)) dieB(`no entry '## ${slug}' in CREWMATE-learned.md (ac-learn.sh stale lists them)`);
  const today = isoNow().slice(0, 10);
  const current = entryDate(live, slug);
  if (current === "") dieB(`entry '## ${slug}' carries no '(learned <date>)' line to refresh - nothing written`);
  if (current === today) {
    out(`already reinforced today (${today}) - clock unchanged; evidence noted on the receipt: ${evidence}\n`);
    return;
  }
  const lk = `${live}.lock`;
  if (!lock(lk, 30)) dieB(`CREWMATE-learned lock ${lk} could not be acquired within 30s - nothing written`);
  const t = tempFile(live) ?? fatal(1);
  const st = run(awk([["want", `## ${slug}`], ["today", today]], REINFORCE_AWK, [live]), { stdout: t.fd }).status;
  closeSync(t.fd);
  must(st);
  const tmp = b8(t.path);
  if (sameBytes(live, tmp)) {
    rmF(tmp);
    unlock(lk);
    dieB(`reinforce composed no change for '## ${slug}' despite a clock at ${current} - report this (nothing written)`);
  }
  const size = statOf(tmp)?.size ?? 0;
  if (size > 4096) {
    rmF(tmp);
    unlock(lk);
    dieB(`reinforce would grow CREWMATE-learned.md to ${size} bytes, past its 4096-byte always-loaded budget (nothing written)`);
  }
  must(run(["mv", tmp, live]).status);
  unlock(lk);
  out(`reinforced ${slug} (clock -> ${today}) on evidence: ${evidence}\n`);
  out("post the evidence to the owning room/report - the file deliberately does not store it\n");
}

const sameBytes = (a: string, b: string): boolean => {
  try {
    return readFileSync(B(a)).equals(readFileSync(B(b)));
  } catch {
    return false;
  }
};

// --- note: the one placing append onto the ledger ----------------------------

const NOTE_AWK = String.raw`
    function flush_new(  l) { while ((getline l < add) > 0) print l; close(add) }
    function flush_gap(  i) { for (i = 0; i < gap; i++) print ""; gap = 0 }
    $0 == "## Distilled" && !placed { flush_new(); placed = 1; flush_gap(); print; next }
    $0 == "" { gap++; next }
    { flush_gap(); print }
    END { if (!placed) flush_new(); flush_gap() }
  `;

function cmdNote(args: string[]): void {
  if (args.length === 0) dieB("usage: ac-learn.sh note <line>... (each argument is appended verbatim as one line under '## Pending')");
  const lines = args.map(b8);
  for (const line of lines) {
    if (line === "## Pending" || line === "## Distilled")
      dieB(`refusing to append the section marker '${line}': a second marker makes learn_ledger_split read everything after it as the pointer index and drop it (nothing written)`);
    if (line.startsWith("--") || /^-[A-Za-z]/.test(line))
      dieB(`note takes lesson lines only and defines no flags - refusing '${line}' (nothing written). A ledger line is '- <lesson>' and a heading is '### <date> (solo|family <id>)', each passed as its own argument.`);
  }
  const ledger = `${recordsD()}/learnings.md`;
  const lk = `${stateD()}/.learn-note.lock`;
  if (!lock(lk, 30)) dieB(`learnings ledger lock ${lk} could not be acquired within 30s - NOTHING was written. Re-run the note: a refused note you can see beats a lesson silently lost to a concurrent writer.`);
  if (!nonEmpty(ledger) && !put(ledger, "# Learning Ledger\n\n## Pending\n\n")) fatal(1);
  const add = mktemp() ?? fatal(1);
  if (!put(add, lines.map((l) => `${l}\n`).join(""))) fatal(1);
  const t = tempFile(ledger) ?? fatal(1);
  const st = run(awk([["add", add]], NOTE_AWK, [ledger]), { stdout: t.fd }).status;
  closeSync(t.fd);
  must(st);
  must(run(["mv", b8(t.path), ledger]).status);
  rmF(add);
  unlock(lk);
  out(`appended ${args.length} line(s) under ## Pending in ${ledger}\n`);
}

// --- rotate-pending: bound the Pending body so DISTILL stays citable ---------

const ROTATE_AWK = String.raw`
    BEGIN { while ((getline l < heldf) > 0) if (l != "") held[l] = 1 }
    { lines[NR] = $0
      if ($0 == "## Pending" && !pstart) pstart = NR
      else if ($0 == "## Distilled" && pstart && !pend) pend = NR }
    END {
      lo = pstart + 1; hi = (pend ? pend - 1 : NR)
      total = 0
      if (pstart) for (i = lo; i <= hi; i++) total += length(lines[i]) + 1
      if (!pstart || total <= budget) exit 0
      for (i = lo; i <= hi; i++) {
        if (lines[i] ~ /^### /) head = i
        if (lines[i] ~ /^\[pending-overflow -> /) keep[i] = 1
        else if (lines[i] in held) {
          keep[i] = 1
          if (head) keep[head] = 1
          for (j = i + 1; j <= hi && lines[j] != "" && lines[j] !~ /^(- |### |\[pending-overflow -> )/; j++) keep[j] = 1
        }
      }
      overhead = length(marker) + 1
      for (i = lo; i <= hi; i++)
        if (keep[i]) overhead += length(lines[i]) + 1
      run = 0
      for (i = hi; i >= lo; i--) {
        if (!keep[i]) run += length(lines[i]) + 1
        suffix[i] = run
      }
      cut = hi + 1
      for (i = lo; i <= hi; i++)
        if ((lines[i] ~ /^- / || lines[i] ~ /^### / || lines[i] == "") && suffix[i] + overhead <= budget) { cut = i; break }
      moved_any = 0
      for (i = lo; i < cut; i++)
        if (!keep[i]) { moved[i] = 1; moved_any = 1 }
      if (!moved_any) { print total > keptf; exit 0 }
      print overhead + (cut <= hi ? suffix[cut] : 0) > keptf
      for (i = lo; i < cut; i++) if (moved[i] || lines[i] ~ /^### /) print lines[i] > archf
      for (i = 1; i < lo; i++) print lines[i]
      for (i = lo; i < cut; i++) if (!moved[i]) print lines[i]
      print marker
      for (i = cut; i <= hi; i++) print lines[i]
      if (pend) for (i = pend; i <= NR; i++) print lines[i]
    }
  `;

// learn_rotate_pending (the header's ROTATE-PENDING): under the note lock, the
// oldest archivable prefix of the Pending body past config/learn-pending-budget
// moves verbatim to records/learnings-archive/pending-<ts>[-<k>].md, the
// spawned awk deciding the cut as the bash's did; an under-budget ledger is
// left untouched.
function rotatePending(): void {
  const ledger = `${recordsD()}/learnings.md`;
  if (!isFile(ledger)) return;
  const budget = b8(configReadSoft("learn-pending-budget", "131072"));
  if (!/^[0-9]+$/.test(budget)) dieB(`config/learn-pending-budget must be a byte count (got: '${budget}')`);
  const lk = `${stateD()}/.learn-note.lock`;
  if (!lock(lk, 30)) dieB(`learnings ledger lock ${lk} could not be acquired within 30s - rotation refused, nothing rewritten`);
  const archdir = `${recordsD()}/learnings-archive`;
  const ts = now();
  let arch = `${archdir}/pending-${ts}.md`;
  for (let k = 2; exists(arch); k++) arch = `${archdir}/pending-${ts}-${k}.md`;
  const marker = `[pending-overflow -> learnings-archive/${basename(arch)}]`;
  const tmp = mktemp() ?? fatal(1);
  const archtmp = mktemp() ?? fatal(1);
  const held = mktemp() ?? fatal(1);
  const keptf = mktemp() ?? fatal(1);
  if (!put(held, priorRunSources().map((l) => `${l}\n`).join(""))) fatal(1);
  const vars: [string, string][] = [["budget", budget], ["archf", archtmp], ["marker", marker], ["heldf", held], ["keptf", keptf]];
  if (runTo(tmp, awk(vars, ROTATE_AWK, [ledger])) !== 0) {
    rmF(tmp, archtmp, held, keptf);
    unlock(lk);
    dieB(`rotate-pending: the ledger rewrite failed mid-pass - nothing installed, ${ledger} untouched`);
  }
  if (nonEmpty(archtmp)) {
    must(mkdirP(archdir));
    const body = read(archtmp) ?? fatal(1);
    if (!put(arch, `# Pending overflow - rotated at ${ts} by ac-learn.sh rotate-pending\n# Bullets below are VERBATIM, oldest-first, moved out of ## Pending to keep\n# the staged DISTILL copy within config/learn-pending-budget.\n\n${body}`)) fatal(1);
    must(run(["mv", tmp, ledger]).status);
    const kept = subst(read(keptf) ?? fatal(1));
    const bullets = readLines(read(arch) ?? "").filter((l) => l.startsWith("- ")).length;
    const k = testInt(kept);
    if (k !== null && k <= BigInt(budget)) out(`rotated ${bullets} bullet(s) into ${arch} (Pending kept within ${budget} bytes)\n`);
    else warnB(`rotated ${bullets} bullet(s) into ${arch}, but Pending is OVER budget: ${kept} of ${budget} bytes kept - no safe cut fits it beside the retained markers and the last examined run's held sources`);
  } else {
    rmF(tmp);
    const kept = subst(read(keptf) ?? fatal(1));
    if (kept !== "") warnB(`nothing in Pending can rotate, and it is OVER budget: ${kept} of ${budget} bytes - markers and the last examined run's held sources fill it`);
  }
  rmF(archtmp, held, keptf);
  unlock(lk);
}

// learn_prior_run_sources: the ===sources=== bullets of every candidate of the
// newest learning-<digits> run that wrote report.md.
function priorRunSources(): string[] {
  let best = "";
  let bestn = -1n;
  for (const d of glob(dataD(), "learning-")) {
    const n = d.slice(d.lastIndexOf("/learning-") + "/learning-".length);
    if (!/^[0-9]/.test(n) || /[^0-9]/.test(n)) continue;
    const v = testInt(n);
    if (nonEmpty(`${d}/report.md`) && v !== null && v > bestn) {
      best = d;
      bestn = v;
    }
  }
  if (best === "") return [];
  const held: string[] = [];
  for (const cand of glob(best, "candidate-", ".md")) {
    if (!isFile(cand)) continue;
    for (const [, , bullet = ""] of sourceRows(cand)) if (bullet !== "") held.push(bullet);
  }
  return held;
}

// learn_validate_sources: every ===sources=== bullet is a whole line of the
// ledger, before any write.
function validateSources(cand: string, learnings: string): void {
  for (const [, , bullet = ""] of sourceRows(cand)) {
    if (bullet === "") continue;
    if (!isFile(learnings)) dieB(`cannot compact: no learnings.md at ${learnings}`);
    if (!grepWhole(learnings, bullet)) dieB(`source bullet not found verbatim in learnings.md (compaction is coupled to landing; nothing written): ${bullet}`);
  }
}

// --- candidate staging: archive + canonical pointer + closed transaction -------

// errexit at the preparer's call site: on for `land` (a `< <(...)` producer
// keeps it), asleep inside run's `$(...)` (W5's litter and W6's rule subject
// rely on it) - there a failing command goes on and only a die ends it.
let LAX = false;
const step = (status: number): void => {
  if (status !== 0 && !LAX) fatal(status);
};

// learn_file_sha_or_absent: a plain file's digest, `-` for nothing at the
// name, null (return 1) for anything else.
function shaOrAbsent(p: string): string | null {
  if (isFile(p) && !isLink(p)) return sha(p) ?? "";
  if (!exists(p) && !isLink(p)) return "-";
  return null;
}

const SPLIT_AWK = String.raw`
    function remember(name, count, date) {
      if (name == "") return
      if (count !~ /^[0-9]+$/) count = 1
      counts[name] += count
      if (date > updated[name]) updated[name] = date
    }
    function consume_pointer(line, name, rest, closing, token, bits, count, date) {
      if (line ~ /^- \[distilled -> /) {
        rest = substr(line, length("- [distilled -> ") + 1)
        closing = index(rest, "]")
        if (closing == 0) return 0
        name = substr(rest, 1, closing - 1)
        if (name !~ /^[a-z0-9][a-z0-9-]*$/) return 0
        if (substr(rest, closing) !~ /^\] sources=/) return 0
      } else if (line ~ /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \[distilled -> /) {
        rest = substr(line, index(line, "[distilled -> ") + length("[distilled -> "))
        closing = index(rest, "]")
        if (closing == 0) return 0
        token = substr(rest, 1, closing - 1)
        split(token, bits, /[[:space:]]+/)
        name = bits[1]
        if (name !~ /^[a-z0-9][a-z0-9-]*$/) return 0
        if (bits[2] != "@fleet" && bits[2] != "@container") return 0
      } else {
        return 0
      }
      count = 1
      if (line ~ /sources=[0-9]+/) {
        count = line
        sub(/^.*sources=/, "", count)
        sub(/[^0-9].*$/, "", count)
      }
      date = ""
      if (line ~ /updated=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        date = line
        sub(/^.*updated=/, "", date)
        date = substr(date, 1, 10)
      } else if (line ~ /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) {
        date = substr(line, 3, 10)
      }
      remember(name, count, date)
      return 1
    }
    function emit(n,   i) { for (i = 0; i < n; i++) print "" >> pending }
    $0 == "## Pending" { emit(gap); gap = 0; skip = 1; section = "pending"; canonical = 1; next }
    $0 == "## Distilled" { if (gap > 0) gap--; emit(gap); gap = 0; section = "distilled"; canonical = 1; next }
    consume_pointer($0) { next }
    section == "distilled" { next }
    $0 == "" { if (skip) { skip = 0; next } gap++; next }
    {
      line = $0
      if (!canonical && line ~ /^## /) sub(/^## /, "### ", line)
      if (line ~ /^# (Learning|Learnings)( Ledger)?[[:space:]]*$/) { skip = 1; next }
      skip = 0
      emit(gap); gap = 0
      print line >> pending
    }
    END {
      emit(gap)
      for (name in counts)
        printf "%s\t%d\t%s\n", name, counts[name], updated[name] >> pointers
    }
  `;

// learn_ledger_split <ledger> <pending-out> <pointer-tsv-out>, the spawned awk.
function ledgerSplit(ledger: string, pending: string, pointers: string): void {
  step(put(pending, "") ? 0 : 1);
  step(put(pointers, "") ? 0 : 1);
  if (!isFile(ledger)) return;
  step(run(awk([["pending", pending], ["pointers", pointers]], SPLIT_AWK, [ledger])).status);
}

const CONSUME_AWK = String.raw`NR == FNR { want[$0]++; next }
         want[$0] > 0 { want[$0]--; next }
         { print }`;
const REDATE_AWK = "$1 == name { $3 = updated } { print }";

// learn_ledger_stage <cand> <name> <ledger> <out> <work> [self-link]: the
// staged ledger - the frame, the Pending body less one line per declared
// source, then every pointer row in BYTE order of its name (W13: the bash's
// sort followed LC_COLLATE), each linked to where its body lives.
function ledgerStage(cand: string, name: string, ledger: string, outFile: string, work: string, selfLink: string): void {
  const archdir = `${dirname(ledger)}/learnings-archive`;
  const pending = `${work}/pending`;
  const pointers = `${work}/pointers.tsv`;
  const sources = `${work}/source-bullets`;
  const filtered = `${work}/pending.filtered`;
  const next = `${work}/pointers.next.tsv`;
  step(mkdirP(work));
  ledgerSplit(ledger, pending, pointers);
  step(put(sources, "") ? 0 : 1);
  let count = 0;
  let updated = "";
  for (const [date = "", , bullet = ""] of sourceRows(cand)) {
    if (bullet === "") continue;
    step(put(sources, `${bullet}\n`, true) ? 0 : 1);
    count++;
    if (date !== "" && (updated === "" || date > updated)) updated = date;
  }
  if (updated === "") {
    const d = run(["date", "-u", "+%Y-%m-%d"], { stdout: "pipe" });
    step(d.status);
    updated = subst(d.out);
  }
  if (nonEmpty(sources)) step(runTo(filtered, awk([], CONSUME_AWK, [sources, pending])) ?? 1);
  else step(run(["cp", pending, filtered]).status);
  step(put(next, "") ? 0 : 1);
  let found = false;
  for (const row of readLines(read(pointers) ?? "")) {
    let [pname = "", pcount = "", pdate = ""] = tabRead(row, 3);
    if (pname === "") continue;
    if (!/^[0-9]+$/.test(pcount)) pcount = "0";
    if (pname === name) {
      pcount = String(BigInt.asIntN(64, arithValue(pcount) + BigInt(count)));
      if (pdate !== "" && !(pdate < updated)) updated = pdate;
      found = true;
    }
    step(put(next, `${pname}\t${pcount}\t${pdate}\n`, true) ? 0 : 1);
  }
  if (!found) step(put(next, `${name}\t${count}\t${updated}\n`, true) ? 0 : 1);
  else {
    const t = tempFile(next);
    if (t === null) step(1);
    else {
      try {
        step(run(awk([["name", name], ["updated", updated]], REDATE_AWK, [next], ["-F\t", "-v", "OFS=\t"]), { stdout: t.fd }).status);
      } finally {
        closeSync(t.fd);
      }
      step(run(["mv", b8(t.path), next]).status);
    }
  }
  let body = "# Learning Ledger\n\n## Pending\n\n";
  body += read(filtered) ?? "";
  if (nonEmpty(filtered)) body += "\n";
  body += "## Distilled\n\n";
  const sort = run(["/usr/bin/env", "LC_ALL=C", "sort", "-t", "\t", "-k1,1", next], { stdout: "pipe" });
  const sorted = sort.out;
  const learned = `${dirname(ledger)}/../CREWMATE-learned.md`;
  for (const row of readLines(sorted)) {
    const [pname = "", pcount = "", pdate = ""] = tabRead(row, 3);
    let plink: string;
    if (pname === name && selfLink !== "") plink = selfLink;
    else if (!isFile(`${dirname(ledger)}/../skills/${pname}/SKILL.md`) && grepWhole(learned, `## ${pname}`)) plink = "[lesson](../CREWMATE-learned.md)";
    else plink = `[skill](../skills/${pname}/SKILL.md)`;
    if (pname === name || isFile(`${archdir}/${pname}.md`)) body += `- [distilled -> ${pname}] sources=${pcount} updated=${pdate} (${plink}; [evidence](learnings-archive/${pname}.md))\n`;
    else body += `- [distilled -> ${pname}] sources=${pcount} updated=${pdate} (${plink})\n`;
  }
  if (!put(outFile, body)) step(1);
  else step(sort.status);
}

const LEGACY_ROW = /^- [0-9]{4}-[0-9]{2}-[0-9]{2} \[distilled -> /;
const EVIDENCE_LINK = /^.*\[evidence\]\(learnings-archive\/([a-z0-9][a-z0-9-]*)\.md\).*$/;

// learn_ledger_shape_gate <n> <every>: the one HELD line and false when the
// ledger carries a legacy rung-qualified pointer row or a canonical row whose
// [evidence] archive does not exist; else "" and true.
function shapeGate(n: string, every: string): { ok: boolean; out: string } {
  const ledger = `${recordsD()}/learnings.md`;
  if (!isFile(ledger)) return { ok: true, out: "" };
  const lines = readLines(read(ledger) ?? "");
  const legacy = lines.filter((l) => LEGACY_ROW.test(l)).length;
  if (legacy > 0)
    return {
      ok: false,
      out: `learning DUE (${n}/${every}) HELD: records/learnings.md carries ${legacy} legacy rung-qualified pointer row(s) (e.g. "- <date> [distilled -> <name> @fleet|@container] ...") that predate the ## Pending/## Distilled frame - every per-candidate plan would bundle their canonicalization and the maintenance gate would refuse it as over-broad (2026-07-28, 7/7 revise); hand-canonicalize the ledger once before the next DISTILL\n`,
    };
  const archdir = `${dirname(ledger)}/learnings-archive`;
  for (const line of lines.filter((l) => l.startsWith("- [distilled -> "))) {
    const m = EVIDENCE_LINK.exec(line);
    if (m === null) continue;
    if (isFile(`${archdir}/${m[1]}.md`)) continue;
    return {
      ok: false,
      out: `learning DUE (${n}/${every}) HELD: records/learnings.md links [evidence](learnings-archive/${m[1]}.md) but that file does not exist - learn_ledger_stage emits the link only when its target exists, so every per-candidate plan would strip it and the maintenance gate would refuse it as over-broad (2026-08-03, 5/5 revise); hand-repair the dangling link before the next DISTILL\n`,
    };
  }
  return { ok: true, out: "" };
}

const CLAIMED_AWK = String.raw`
    function amount(line,   c) {
      c = 1
      if (line ~ /sources=[0-9]+/) {
        c = line; sub(/^.*sources=/, "", c); sub(/[^0-9].*$/, "", c)
      }
      return c
    }
    $0 ~ "^- \\[distilled -> " n "\\] sources=" {
      if (!canonical++) { total += amount($0); found = 1 }
      next
    }
    $0 ~ "^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \\[distilled -> " n " @(fleet|container)\\]" {
      total += amount($0); found = 1
    }
    END { if (found) print total + 0 }
  `;

// learn_pointer_claimed <ledger> <skill>: what the ledger claims for <skill>
// (the first canonical row plus every legacy row), "" for no row or no file.
const pointerClaimed = (ledger: string, name: string): string => (isFile(ledger) ? subst(run(awk([["n", name]], CLAIMED_AWK, [ledger]), { stdout: "pipe" }).out) : "");

// learn_archive_declared <archive>: the sum of its `source-count:` lines, 0
// when it does not exist.
const archiveDeclared = (archive: string): string => (isFile(archive) ? subst(run(awk([], "/^source-count: [0-9]+$/ { n += $2 } END { print n + 0 }", [archive]), { stdout: "pipe" }).out) : "0");

// learn_pointer_evidence_check: the staged pointer and archive must grow by
// the same number of sources, or the transaction refuses with nothing written.
function pointerEvidenceCheck(liveLedger: string, ledger: string, liveArchive: string, archive: string, name: string): void {
  const was = pointerClaimed(liveLedger, name);
  const claimed = pointerClaimed(ledger, name);
  if (claimed === "") dieB(`refusing the transaction: no canonical pointer for '${name}' in the staged ledger to reconcile against its archive (nothing written)`);
  const had = archiveDeclared(liveArchive);
  const declared = archiveDeclared(archive);
  let add: bigint;
  let gain: bigint;
  try {
    add = BigInt.asIntN(64, arithValue(claimed) - arithValue(was === "" ? "0" : was));
    gain = BigInt.asIntN(64, arithValue(declared) - arithValue(had));
  } catch {
    return fatal(1);
  }
  if (add === gain) return;
  dieB(`refusing to publish a pointer that contradicts its own evidence: this transaction would add ${add} source(s) to '[distilled -> ${name}]' (sources=${was === "" ? "0" : was} -> ${claimed}) while records/learnings-archive/${name}.md gains ${gain} (source-count sum ${had} -> ${declared}). Nothing written. The two totals may legitimately differ - the pointer aggregates rows that predate the archive - but each land must add the SAME number to both; a duplicated pointer row in records/learnings.md is what inflates the ledger side.`);
}

const BY_ID = /^.*\(by: ([a-z0-9][a-z0-9-]*), first-hand\).*$/;
const squeeze = (s: string): string => s.replace(/[ \t\n\v\f\r]+/g, " ");

// learn_quote_unverified <bullet>: each backtick/double-quoted fragment of >= 6
// words not in the whitespace-squeezed reports of the bullet's `(by: <id>,
// first-hand)` task (live, archived, then its stage dir; byte order - W13),
// one per entry; none when the bullet names no task or no report is found.
function quoteUnverified(bullet: string): string[] {
  const m = BY_ID.exec(bullet);
  if (m === null) return [];
  const id = m[1]!;
  const roots = [`${dataD()}/${id}`];
  const archived = glob(`${dataD()}/archive`)
    .map((d) => `${d}/${id}`)
    .filter((p) => present(p));
  roots.push(...(archived.length > 0 ? archived : [`${dataD()}/archive/*/${id}`]));
  const subdir = b8(stageDirForId(u8(id)));
  if (subdir !== "") roots.push(`${dataD()}/${subdir}`);
  let hay = "";
  for (const root of roots) {
    let st;
    try {
      st = lstatSync(B(root));
    } catch {
      continue;
    }
    const reps = st.isDirectory() ? findReports(root) : root.endsWith("/report.md") && st.isFile() ? [root] : [];
    for (const r of reps) hay += read(r) ?? "";
  }
  hay = squeeze(hay).replace(/\0/g, "");
  if (hay === "") return [];
  const flags: string[] = [];
  for (const q of bullet.match(/`[^`]+`|"[^"]+"/g) ?? []) {
    const frag = squeeze(q.slice(1, -1));
    if (frag.split(/[ \t\n\v\f\r]+/).filter((w) => w !== "").length < 6) continue;
    if (!hay.includes(frag)) flags.push(frag);
  }
  return flags;
}

// learn_quote_unverified_count <plan> <run>: the `quote-unverified:` lines the
// plan's append-archive action adds (staged minus live).
function quoteUnverifiedCount(plan: string, rundir: string): string {
  const field = (f: string): string => subst(run(["jq", "-r", `.actions[] | select(.op == "append-archive") | .${f}`, plan], { stdout: "pipe" }).out);
  const staged = field("staged");
  if (staged === "") return "0";
  const target = field("target");
  const countIn = (p: string): string => {
    const t = read(p);
    return t === null ? "" : String(t.split("\n").filter((l) => l.startsWith("quote-unverified: ")).length);
  };
  const live = isFile(`${home()}/${target}`) ? countIn(`${home()}/${target}`) : "0";
  try {
    return String(BigInt.asIntN(64, arithValue(countIn(`${rundir}/${staged}`)) - arithValue(live)));
  } catch {
    return "";
  }
}

const unverifiedNote = (n: string): string => {
  const v = testInt(n);
  return v !== null && v > 0n ? ` (quote-unverified: ${n})` : "";
};

// learn_archive_stage: the live archive (or its title) plus one evidence
// block for this transaction.
function archiveStage(cand: string, name: string, archive: string, outFile: string, txid: string, gateRel: string, candidateRel: string): void {
  if (isFile(archive)) step(run(["cp", archive, outFile]).status);
  if (!isFile(archive)) step(put(outFile, `# Learning Evidence: ${name}\n`) ? 0 : 1);
  const rows = sourceRows(cand).filter(([, , b = ""]) => b !== "");
  let block = `\n## ${isoNow()} - ${txid}\n\ngate: ${gateRel}\ncandidate: ${candidateRel}\nsource-count: ${rows.length}\n\n`;
  for (const [date = "", , bullet = ""] of rows) {
    block += `### ${date}\n\n${bullet}\n\n`;
    const flags = quoteUnverified(bullet);
    if (flags.length > 0) block += `${flags.map((f) => `quote-unverified: ${f}`).join("\n")}\n\n`;
  }
  step(put(outFile, block, true) ? 0 : 1);
}

// learn_crewmate_learned_base: the live CREWMATE-learned.md, or the ownership
// header when none exists yet.
function crewmateBase(): string {
  const live = `${home()}/CREWMATE-learned.md`;
  if (isFile(live)) return read(live) ?? "";
  return "# Fleet-learned crewmate lessons\n<!-- written only by ac-learn.sh transactions; captains edit CREWMATE.md instead -->\n";
}

// learn_crewmate_learned_guard <staged> <run>: the 4096-byte budget, the
// no-silent-loss check, and a .prev copy of the live file under the run.
function crewmateGuard(staged: string, rundir: string): void {
  const live = `${home()}/CREWMATE-learned.md`;
  if ((statOf(staged)?.size ?? 0) > 4096) {
    const entries = isFile(live) ? learnedSlugs(live).map((s) => `${s} `).join("") : "";
    dieB(`staged CREWMATE-learned.md exceeds its 4096-byte always-loaded budget - pair the new entry with a retire of one of: ${entries === "" ? "none " : entries}(nothing written)`);
  }
  if (!crewmateLearnedNoLoss(u8(live), u8(staged), "")) dieB("staged CREWMATE-learned.md drops an existing '## <slug>' entry with no retired accounting (nothing written)");
  if (isFile(live)) {
    step(mkdirP(`${rundir}/backup`));
    step(run(["cp", live, `${rundir}/backup/CREWMATE-learned.md.prev`]).status);
  }
}

// learn_plan_action: one `jq -nc` action row appended to <actions>; 1 where
// the bash returned 1 (a target that is neither a plain file nor absent, a
// staged file it cannot hash).
function planAction(actions: string, op: string, target: string, staged: string, rundir: string): number {
  const old = shaOrAbsent(`${home()}/${target}`);
  if (old === null) return 1;
  const nw = sha(`${rundir}/${staged}`);
  if (nw === null) return 1;
  return runTo(actions, ["jq", "-nc", "--arg", "op", op, "--arg", "target", target, "--arg", "old", old, "--arg", "new", nw, "--arg", "staged", staged, "{op:$op,target:$target,old_sha256:$old,new_sha256:$new,staged:$staged}"], true) ?? 1;
}

const PLAN_JQ = `{schema:"agentcrew.maintenance-plan/v1",mode:"learning",run_id:$run_id,
      subject:$subject,input_manifest_sha256:$manifest,actions:.}`;

// learn_prepare_candidate_plan <cand> <authority> [<owning-run>]: the staged
// files, plan and candidate copy of one subject; [run, plan, copy] on success.
// Every refusal is a die (thrown); LAX decides what any other failure does.
function prepareCandidatePlan(cand: string, authority: string, owning: string): [string, string, string] {
  if (!commandV("jq")) dieB("jq is required for maintenance plans");
  const kind = candidateHeader(cand, "kind");
  const name = candidateHeader(cand, "name");
  let desc = "";
  let trigger = "";
  let subject = "";
  const slugRule = "lowercase [a-z0-9-], <=64 chars, no leading/trailing/consecutive hyphen";
  switch (kind) {
    case "skill":
      desc = candidateHeader(cand, "description");
      trigger = candidateHeader(cand, "trigger");
      if (!validSlug(name)) dieB(`skill candidate 'name:' must be an agentskills slug: ${slugRule} (got: '${name}')`);
      if (!validDescription(desc)) dieB("skill candidate 'description:' must be non-empty and <=1024 chars (spec-required)");
      if (!validTrigger(trigger)) dieB(`skill candidate 'trigger:' must be non-empty, <=${TRIGGER_MAX} bytes and not start with 'when' - it is the always-loaded pointer line (got: '${trigger}', nothing written)`);
      if (exists(`${skillsD()}/${name}`)) dieB(`refusing to clobber an existing skill store at ${skillsD()}/${name}`);
      subject = name;
      break;
    case "patch": {
      if (!validSlug(name)) dieB(`patch candidate 'name:' must be an agentskills slug: ${slugRule} (got: '${name}')`);
      const target = `${skillsD()}/${name}/SKILL.md`;
      if (!isFile(target)) {
        if (isFile(`${dirname(home())}/.claude/skills/${name}/SKILL.md`))
          dieB(`learned skill '${name}' exists only in the legacy container store, which is retired and never read; learned skills are permanently fleet-local - copy it into the fleet store deliberately before patching (nothing written)`);
        dieB(`no fleet-local learned skill named '${name}' to patch (nothing written)`);
      }
      const front = (key: string): string => {
        const t = read(target) ?? "";
        for (const l of t.split("\n")) if (l.startsWith(`${key}:`)) return subst(l.slice(key.length + 1).replace(/^[ \t\n\v\f\r]+/, ""));
        return "";
      };
      const tname = front("name");
      const tdesc = front("description");
      if (!validSlug(tname)) dieB(`refusing to patch '${name}': target frontmatter 'name:' is not an agentskills slug (got: '${tname}')`);
      if (!validDescription(tdesc)) dieB(`refusing to patch '${name}': target frontmatter 'description:' is empty or >1024 chars`);
      if (!subst(candidateSection(cand, "patch")).startsWith("## ")) dieB("patch '===patch===' body must lead with a '## ' labeled subsection heading (nothing written)");
      subject = name;
      break;
    }
    case "crewmate":
      desc = candidateHeader(cand, "description");
      if (!validSlug(name)) dieB(`crewmate candidate 'name:' must be an agentskills slug: ${slugRule} (got: '${name}')`);
      if (!validDescription(desc)) dieB(`crewmate candidate 'description:' must be non-empty and <=1024 chars (got: '${desc}')`);
      if (isFile(`${home()}/CREWMATE-learned.md`) && grepWhole(`${home()}/CREWMATE-learned.md`, `## ${name}`))
        dieB(`CREWMATE-learned.md already carries '## ${name}' - curate the existing entry instead of re-landing it (nothing written)`);
      subject = name;
      break;
    case "rule":
      subject = `rule-${now()}`;
      break;
    default:
      dieB(`candidate 'kind:' must be skill|patch|crewmate|rule (got: '${kind}')`);
  }
  if (kind !== "rule") validateSources(cand, `${recordsD()}/learnings.md`);

  let rundir: string;
  let txid: string;
  let stagedPrefix: string;
  let actions: string;
  let planOut: string;
  let candidateCopy: string;
  let candidateRel: string;
  if (owning !== "") {
    const p = physicalDir(u8(owning));
    if (p === null) step(1);
    rundir = p === null ? "" : b8(p);
    if (!`${rundir}/`.startsWith(`${dataD()}/`)) dieB(`automatic Learning run must resolve under ${dataD()}`);
    txid = basename(rundir);
    stagedPrefix = `staged/${subject}`;
    actions = `${rundir}/plans/.${subject}.actions.${process.pid}`;
    planOut = `${rundir}/plans/${subject}.json`;
    candidateCopy = `${rundir}/candidates/${subject}.md`;
    candidateRel = `data/${txid}/candidates/${subject}.md`;
  } else {
    txid = `maintenance-learning-manual-${now()}-${process.pid}`;
    rundir = `${dataD()}/${txid}`;
    stagedPrefix = "staged";
    actions = `${rundir}/actions.ndjson`;
    planOut = `${rundir}/plan.json`;
    candidateCopy = `${rundir}/candidate.md`;
    candidateRel = `data/${txid}/candidate.md`;
  }
  const staged = `${rundir}/${stagedPrefix}`;
  step(mkdirP(`${staged}/records/learnings-archive`, `${staged}/skills/${name}`, `${rundir}/gates/${subject}`, dirname(actions), dirname(candidateCopy)));
  step(run(["cp", cand, candidateCopy]).status);
  const gateRel = `data/${txid}/gates/${subject}/decision.md`;
  if (owning === "")
    step(
      put(
        `${rundir}/gates/${subject}/decision.md`,
        `---\nschema: agentcrew.captain-decision/v1\nmode: learning\nsubject: ${subject}\ndecision: continue\nauthority: ${authority}\ncandidate_sha256: ${sha(candidateCopy) ?? ""}\nreviewed_at: ${isoNow()}\n---\n`,
      )
        ? 0
        : 1,
    );
  step(put(actions, "") ? 0 : 1);

  const skillMd = `${staged}/skills/${name}/SKILL.md`;
  const stagedCml = `${staged}/CREWMATE-learned.md`;
  switch (kind) {
    case "skill": {
      const sec = run(awk([["want", "===skill==="]], SECTION_AWK, [cand]), { stdout: "pipe" });
      if (!put(skillMd, `---\nname: ${name}\ndescription: ${desc}\nmetadata:\n  origin: learned\n  landed: "${now()}"\n---\n\n${sec.out}`)) step(1);
      else step(sec.status);
      break;
    }
    case "patch": {
      step(run(["cp", `${skillsD()}/${name}/SKILL.md`, skillMd]).status);
      const sec = run(awk([["want", "===patch==="]], SECTION_AWK, [cand]), { stdout: "pipe" });
      if (!put(skillMd, `\n${sec.out}`, true)) step(1);
      else step(sec.status);
      break;
    }
    case "crewmate": {
      const body = subst(candidateSection(cand, "crewmate"));
      if (body === "") dieB("crewmate candidate '===crewmate===' body is empty (nothing written)");
      if (body.split("\n").some((l) => l.startsWith("## "))) dieB(`crewmate '===crewmate===' body must be lesson prose only - the transaction composes the '## ${name}' heading itself (nothing written)`);
      if (body.split("\n").length > 12) dieB("crewmate '===crewmate===' body is over 12 lines - a lesson that long is a skill or a doc (nothing written)");
      step(put(stagedCml, `${crewmateBase()}\n## ${name}\n\n${body}\n\n(learned ${isoNow().slice(0, 10)})\n`) ? 0 : 1);
      shortenPointers(stagedCml);
      crewmateGuard(stagedCml, rundir);
      step(planAction(actions, "rewrite-crewmate-learned", "CREWMATE-learned.md", `${stagedPrefix}/CREWMATE-learned.md`, rundir));
      break;
    }
    case "rule": {
      const captain = `${recordsD()}/captain.md`;
      const stagedCaptain = `${staged}/records/captain.md`;
      if (isFile(captain)) step(run(["cp", captain, stagedCaptain]).status);
      if (!isFile(captain)) step(put(stagedCaptain, "") ? 0 : 1);
      if (nonEmpty(stagedCaptain)) step(put(stagedCaptain, "\n", true) ? 0 : 1);
      step(runTo(stagedCaptain, awk([["want", "===rule==="]], SECTION_AWK, [cand]), true) ?? 1);
      step(planAction(actions, "rewrite-registry", "records/captain.md", `${stagedPrefix}/records/captain.md`, rundir));
      break;
    }
  }

  if (kind === "skill") {
    const cmlPtr = `- when ${trigger} -> use skill ${name}`;
    const live = `${home()}/CREWMATE-learned.md`;
    if (!(isFile(live) && (read(live) ?? "").split("\n").some((l) => l.includes(`use skill ${name}`)))) {
      if (isFile(live) && grepWhole(live, POINTER_SEC)) step(runTo(stagedCml, awk([["sec", POINTER_SEC], ["ptr", cmlPtr]], "{ print } $0 == sec { print ptr }", [live])) ?? 1);
      else step(put(stagedCml, `${crewmateBase()}\n${POINTER_SEC}\n${cmlPtr}\n`) ? 0 : 1);
      shortenPointers(stagedCml);
      crewmateGuard(stagedCml, rundir);
      step(planAction(actions, "rewrite-crewmate-learned", "CREWMATE-learned.md", `${stagedPrefix}/CREWMATE-learned.md`, rundir));
    }
  }

  if (kind === "skill" || kind === "patch" || kind === "crewmate") {
    const learnings = `${recordsD()}/learnings.md`;
    const archive = `${recordsD()}/learnings-archive/${name}.md`;
    archiveStage(candidateCopy, name, archive, `${staged}/records/learnings-archive/${name}.md`, txid, gateRel, candidateRel);
    ledgerStage(candidateCopy, name, learnings, `${staged}/records/learnings.md`, `${rundir}/work`, kind === "crewmate" ? "[lesson](../CREWMATE-learned.md)" : "");
    pointerEvidenceCheck(learnings, `${staged}/records/learnings.md`, archive, `${staged}/records/learnings-archive/${name}.md`, name);
    step(planAction(actions, "append-archive", `records/learnings-archive/${name}.md`, `${stagedPrefix}/records/learnings-archive/${name}.md`, rundir));
    if (kind !== "crewmate") step(planAction(actions, kind === "skill" ? "write-skill" : "patch-skill", `skills/${name}/SKILL.md`, `${stagedPrefix}/skills/${name}/SKILL.md`, rundir));
    step(planAction(actions, "rewrite-ledger", "records/learnings.md", `${stagedPrefix}/records/learnings.md`, rundir));
  }

  step(runTo(planOut, ["jq", "-s", "--arg", "run_id", txid, "--arg", "subject", subject, "--arg", "manifest", sha(candidateCopy) ?? "", PLAN_JQ, actions]) ?? 1);
  rmF(actions);
  return [rundir, planOut, candidateCopy];
}

// learn_policy_ask_receipt: the repository-policy ask-captain receipt, through
// an exclusive temp and a spawned mv.
function policyAskReceipt(receipt: string, plan: string, manifest: string, subject: string, grounds: string): void {
  publish(
    receipt,
    `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "learning"\nsubject: "${subject}"\ndecision: "ask-captain"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${sha(manifest) ?? ""}"\naction_plan_sha256: "${sha(plan) ?? ""}"\nreviewed_at: "${isoNow()}"\n---\n# Maintenance Gate Decision\n## Decision\nask-captain\n## Grounds\n${grounds}\n## Proposed Process\nRecord one durable captain question and wait; do not mutate fleet state.\n`,
  );
}

// learn_captain_escalate: the ASK in the learning room, posted through this
// bin's ac-room.sh with its output dropped; a gate= link only for a receipt
// that exists.
function captainEscalate(rundir: string, subject: string, plan: string, manifest: string, reason: string): void {
  const txid = basename(rundir);
  const receiptRel = `data/${txid}/gates/${subject}/decision.md`;
  const candidateRel = manifest.startsWith(`${home()}/`) ? manifest.slice(home().length + 1) : manifest;
  const gateLinks = exists(`${home()}/${receiptRel}`) ? `; gate=${receiptRel}` : "";
  const message = `ASK: Learning maintenance cannot decide automatically.
why: ${reason}
subject: ${subject}; action-plan-sha256: ${sha(plan) ?? ""}
options: (1) approve this exact recoverable plan; (2) reject and preserve Pending; (3) request a revised candidate.
tradeoffs: approve compacts supported evidence now; reject preserves all active records; revise spends another learning/gate round.
recommendation: reject or revise unless the linked evidence clearly supports the exact action.
links: candidate=${candidateRel}${gateLinks}; evidence=${candidateRel}`;
  if (run([`${b8(STARTED_BIN)}/ac-room.sh`, "post", "learning", "roomchief", message], { stdout: "ignore", stderr: "ignore" }).status !== 0)
    warnB(`captain escalation for ${subject} could not be posted to the learning room`);
}

// learn_auto_apply_candidates <run>: every candidate gated on its own; true
// when every subject settled with a genuine judgment. Called inside the
// bash's `if !`, so errexit sleeps through all of it.
async function autoApplyCandidates(rundir: string): Promise<boolean> {
  let ok = true;
  let found = false;
  const gate = process.env.AC_GATE ? b8(process.env.AC_GATE) : `${b8(STARTED_BIN)}/ac-gate.sh`;
  for (const cand of glob(rundir, "candidate-", ".md")) {
    if (!isFile(cand)) continue;
    found = true;
    const kind = candidateHeader(cand, "kind");
    let subject = candidateHeader(cand, "name");
    if (kind === "rule") subject = `rule-${basename(cand).replace(/\.md$/, "").replace(/^candidate-/, "")}`;
    if (subject === "" || /[^A-Za-z0-9._-]/.test(subject)) subject = `invalid-${(sha(cand) ?? "").slice(0, 12)}`;
    mkdirP(`${rundir}/gates/${subject}`);
    const prepErr = `${rundir}/gates/${subject}/prepare.err`;
    let prepared: [string, string, string] | null = null;
    let fd = -1;
    try {
      fd = openSync(B(prepErr), "w");
    } catch {}
    if (fd >= 0) {
      const savedErr = ERR;
      ERR = fd;
      LAX = true;
      try {
        prepared = prepareCandidatePlan(cand, "maintenance-gate", rundir);
      } catch (e) {
        exitOf(e);
      } finally {
        LAX = false;
        ERR = savedErr;
        closeSync(fd);
      }
    }
    await checkpoint();
    if (prepared === null) {
      put(
        `${rundir}/gates/${subject}/rejected.md`,
        `schema: agentcrew.maintenance-rejection/v1\ndecision: revise\nsubject: ${subject}\nreviewed_at: ${isoNow()}\n\nCandidate or staged-plan validation failed. Sources remain Pending.\n\n${read(prepErr) ?? ""}`,
      );
      out(`  revise: ${subject} (candidate/plan validation failed; sources preserved)\n`);
      continue;
    }
    const [, plan, manifest] = prepared;
    const receipt = `${rundir}/gates/${subject}/decision.md`;
    if (kind === "rule") {
      const reason = "A new or changed standing captain rule is captain-owned and cannot auto-apply.";
      policyAskReceipt(receipt, plan, manifest, subject, reason);
      captainEscalate(rundir, subject, plan, manifest, reason);
      out(`  ask-captain: ${subject} (standing-rule authority; no mutation)\n`);
      continue;
    }
    const g = captureMerged([gate, "maintenance", "--mode", "learning", "--run", rundir, "--subject", subject, "--manifest", manifest, "--plan", plan]);
    await checkpoint();
    if (g.status === 0) {
      if (g.out !== "") out(`  ${g.out}\n`);
    } else {
      let reason = maintenanceGateFailureReason(g.status);
      if (g.out !== "") reason = `${reason}\n${g.out}`;
      captainEscalate(rundir, subject, plan, manifest, reason);
      out(`  ask-captain: ${subject} (gate unavailable; no mutation)\n`);
      ok = false;
      continue;
    }
    const decision = receiptValidate(receipt, plan, manifest, QUOTE_MIN);
    if (decision === null) {
      captainEscalate(rundir, subject, plan, manifest, "The gate receipt did not match the immutable manifest and action-plan hashes.");
      out(`  ask-captain: ${subject} (invalid gate receipt; no mutation)\n`);
      ok = false;
      continue;
    }
    if (decision === "continue") {
      const unverified = quoteUnverifiedCount(plan, rundir);
      const applied = maintenanceApply(u8(plan), u8(rundir));
      await checkpoint();
      if (!applied) {
        warnB(`continue receipt for ${subject} became stale or its transaction could not complete; obtain a fresh gate decision`);
        ok = false;
        continue;
      }
      out(`  auto-applied: ${subject}${unverifiedNote(unverified)}\n`);
    } else if (decision === "revise") out(`  revise: ${subject} (sources preserved; no captain question)\n`);
    else if (decision === "ask-captain") {
      captainEscalate(rundir, subject, plan, manifest, "The maintenance gate returned ask-captain for this exact subject.");
      out(`  ask-captain: ${subject} (gate could not decide; no mutation)\n`);
      ok = false;
    }
  }
  if (!found) out("  AUTO-MAINTENANCE: no candidates; the examined cycle is settled without mutation.\n");
  return ok;
}

// learn_charter <n> <every>: the self-contained charter posted to room
// `learning` before the promote - `--roomchief` takes no brief, so this is
// the only thing telling an auto-created chief to call `ac-learn.sh run`.
const charter = (n: string, every: string): string => `CHARTER: room \`learning\` was created automatically because the fleet reached its distill threshold (${n}/${every} debriefs). This executes the captain's standing policy.
AUTHORITY: records/captain.md delegates the end-to-end Learning loop and its cap-exempt system room to the crewchief. The captain retains post-hoc veto authority.
WHY A ROOM: the work must remain visible while the independent scout and the maintenance gate retain separate judgment.
ROOMCHIEF DUTIES:
(1) Run \`bin/ac-learn.sh run\`. It snapshots the fleet, launches the independent Learning scout, validates a complete run, and gates/applies eligible skill or patch plans automatically.
(2) Read retro.md, report.md, candidate files, gate receipts, and transaction journals in data/learning-<epoch>/. Do not author scout artifacts in this session.
(3) Do not add \`approved:\` or call compatibility \`land\`/\`promote\`. A matching hash-bound maintenance-gate \`continue\` is the only automatic authority. \`revise\` preserves Pending; only a real escalation asks the captain.
(4) When the cycle settles, run \`bin/ac-room.sh handback learning '<one-line result>'\` so the crewchief can demote and close the room.`;

// 12 criteria

// --- compatibility land: approved candidate through the shared transaction ---

function cmdLand(args: string[]): void {
  const cand = b8(args[0] ?? "");
  if (cand === "") dieB("usage: ac-learn.sh land <candidate-file>");
  if (!isFile(cand)) dieB(`no candidate file at ${cand}`);
  const kind = candidateHeader(cand, "kind");
  const approved = candidateHeader(cand, "approved");
  if (approved === "") dieB(`refusing to land an UNAPPROVED candidate (${cand}): no 'approved:' header - the captain gate (Q6) must approve first`);
  home();
  const captured = learnGeneration();
  // The bash read the preparer through `< <(...)`: whatever ended it, the
  // read found no line and errexit ended the land with 1.
  let prepared: [string, string, string];
  try {
    prepared = prepareCandidatePlan(cand, "legacy-captain", "");
  } catch (e) {
    exitOf(e);
    return fatal(1);
  }
  const [rundir, plan] = prepared;
  const unverified = quoteUnverifiedCount(plan, rundir);
  if (!maintenanceApply(u8(plan), u8(rundir))) dieB(`maintenance transaction refused candidate plan at ${plan}`);
  const r = cadenceCall(() => learnReset(captured));
  if (r === 2) warnB(`landed ${kind}, but its cadence lock was busy; its cadence was preserved instead of reset`);
  else if (r !== 0) warnB(`landed ${kind}, but a newer Learning generation exists; its cadence was preserved instead of reset`);
  out(`landed ${kind} through maintenance transaction ${rundir}${unverifiedNote(unverified)}\n`);
}

// --- promote: fleet-local ownership compatibility command ---------------------

function cmdPromote(args: string[]): never {
  const name = b8(args[0] ?? "");
  if (name === "") dieB("usage: ac-learn.sh promote <skill-name>");
  if (!validSlug(name)) dieB(`skill name must be a slug [a-z0-9-] (got: '${name}')`);
  dieB("learned skills are permanently fleet-local; promote is a fail-closed compatibility command (the legacy container store is retired and never read).");
}

// --- maintenance: the operator surface for the shared transaction -------------

// ac_meta_get / ac_meta_set called bare under errexit: an unreadable journal
// (the lib's warning) or a write that fails ends the verb 1.
function metaStrict(file: string, key: string): string {
  try {
    return metaGet(u8(file), key);
  } catch {
    return fatal(1);
  }
}
function metaSetStrict(file: string, key: string, value: string): void {
  try {
    metaSet(u8(file), key, value);
  } catch {
    fatal(1);
  }
}

function cmdMaintenance(args: string[]): void {
  const verb = b8(args[0] || "status");
  const txid = b8(args[1] ?? "");
  const root = `${stateD()}/.maintenance-transactions`;
  if (verb === "status") {
    const rows = maintenanceIncomplete(u8(root));
    if (rows.length === 0) {
      out("no incomplete maintenance transaction - the Learning/Curate loop is clear\n");
      return;
    }
    out("INCOMPLETE maintenance transaction(s) - every other Learning/Curate transaction refuses until settled:\n");
    for (const row of rows) {
      const [id = "", status = "", committed = "", plan = ""] = tabRead(row, 4);
      if (id === "") continue;
      out(`  ${id} status=${status} committed=${committed} plan=${plan}\n`);
      out(`    resume: bin/ac-learn.sh maintenance resume ${id}\n`);
      out(`    drop:   bin/ac-learn.sh maintenance abandon ${id}\n`);
    }
    return;
  }
  if (verb !== "resume" && verb !== "abandon") dieB("usage: ac-learn.sh maintenance status|resume <txid>|abandon <txid>");
  if (txid === "") dieB(`usage: ac-learn.sh maintenance ${verb} <transaction-id> (list them: ac-learn.sh maintenance status)`);
  if (/[^A-Za-z0-9._-]/.test(txid)) dieB(`transaction id must be [A-Za-z0-9._-] (got: '${txid}')`);
  const journal = `${root}/${txid}/journal`;
  if (!isFile(journal)) dieB(`no maintenance transaction '${txid}' on record at ${root}`);
  const status = metaStrict(journal, "status");
  if (status === "complete") {
    out(`${txid} already reached complete - nothing to settle\n`);
    return;
  }
  if (status === "abandoned") {
    out(`${txid} was already abandoned - it blocks nothing\n`);
    return;
  }
  const committed = metaStrict(journal, "held_committed");
  if (verb === "abandon") {
    const backup = metaStrict(journal, "backup");
    metaSetStrict(journal, "status", "abandoned");
    metaSetStrict(journal, "abandoned_at", now());
    out(`abandoned ${txid} - it no longer blocks the loop.\n`);
    out(`NOTHING was rolled back: ${committed === "" ? "an unrecorded number of" : committed} action(s) of this plan are still committed to disk.\n`);
    if (backup !== "") out(`The pre-mutation backup of records/ + skills/ is at ${backup}\n`);
    return;
  }
  const plan = metaStrict(journal, "plan");
  const rundir = metaStrict(journal, "run");
  if (plan === "" || rundir === "")
    dieB(`${txid} records no plan/run to replay (it predates the resume record) - re-run the owning Learning/Curate run, or settle it: bin/ac-learn.sh maintenance abandon ${txid}`);
  if (!isFile(plan) || !isDir(rundir))
    dieB(`${txid}'s plan or run directory is gone (plan=${plan} run=${rundir}) - it cannot be replayed; settle it: bin/ac-learn.sh maintenance abandon ${txid}`);
  if (!maintenanceApply(u8(plan), u8(rundir))) dieB(`${txid} could not be resumed - the cause above is still present; fix it and resume again, or abandon it`);
  out(`resumed ${txid} - transaction complete\n`);
}

// --- tick: the cadence counter ------------------------------------------------

function cmdTick(args: string[]): void {
  const key = b8(args[0] ?? "");
  if (args.length > 1) dieB(`tick takes at most one landing id (got: ${args.map(b8).join(" ")})`);
  home();
  const [before, every] = learnDue();
  if (key !== "") {
    if (/[^a-z0-9-]/.test(key)) dieB(`tick key must be a task/family id [a-z0-9-] (got: '${key}')`);
    const r = cadenceCall(() => learnTickKeyed(key));
    if (r === 2) {
      out(`tick NOT counted: landing ${key} could not be claimed (see the warning above) - re-run this tick\n`);
      fatal(1);
    }
    if (r !== 0) {
      out(`tick skipped: landing ${key} is already counted - one landing advances the counter once, whichever actor runs it\n`);
      return;
    }
  } else if (!learnTick()) fatal(1);
  const [after] = learnDue();
  out(`tick: debriefs=${after}/${every}\n`);
  if (BigInt(before) < BigInt(every) && BigInt(after) >= BigInt(every))
    if (!wakePublish(u8(stateD()), "", "learning-due", "learning", `${after}/${every} - the cap-exempt learning room opens itself at the next drain; do NOT run the distill in this session`))
      warnB(`learning DUE (${after}/${every}) but its wake could not be published`);
}

// --- route-propose: the System One route proposer (config/jev) ----------------

const LEARNED_ENTRIES_AWK = String.raw`
      /^## when to reach for a learned skill/ { if (slug != "") printf "%s\t%s\n", slug, body; slug = ""; next }
      /^## / { if (slug != "") printf "%s\t%s\n", slug, body; slug = substr($0, 4); body = ""; next }
      slug != "" && /^\(learned / { next }
      slug != "" && NF { body = (body == "" ? $0 : body " " $0) }
      END { if (slug != "") printf "%s\t%s\n", slug, body }
    `;

const ROUTE_JQ = `
        .[$o] as $ow | .[$d] as $du | .[$w] as $wo
        | $n + "\\towner=" + $ow.choice + " p=" + ($ow.p[$ow.choice] | tostring)
          + "\\tdup-of=" + (if $du.choice == "new" or $du.choice == "unclear" then "none"
                             else $du.choice + " p=" + ($du.p[$du.choice] | tostring) end)
          + "\\tworth=" + $wo.choice + " p=" + ($wo.p[$wo.choice] | tostring)`;

function cmdRoutePropose(): void {
  let raw = "";
  try {
    raw = readFileSync(0).toString("latin1");
  } catch {}
  const lines = subst(raw);
  if (!/[^ \t\n\v\f\r]/.test(lines)) return;
  const state = mktemp(`${b8(process.env.TMPDIR || "/tmp")}/ac-learn-route.XXXXXX`) ?? fatal(1);
  const cands = readLines(lines).filter((l) => l !== "");
  if (!put(state, `CANDIDATE LINES:\n${cands.map((l, i) => `[${i + 1}] ${l}\n`).join("")}`)) fatal(1);
  const dup = ["new=A lesson no existing entry already states.", "unclear=Not enough reliable evidence."];
  const learned = `${home()}/CREWMATE-learned.md`;
  if (isFile(learned))
    for (const row of readLines(run(awk([], LEARNED_ENTRIES_AWK, [learned]), { stdout: "pipe" }).out)) {
      const [slug = "", body = ""] = tabRead(row, 2);
      dup.push(`${slug}=${body}`);
    }
  const q: string[] = [];
  cands.forEach((_, n) => {
    const i = n + 1;
    q.push(
      "--choice", `owner_${i}`, "--instructions", `Which durable record owns candidate line [${i}]?`,
      "--criteria",
      "backlog=Task index, status, completion evidence, undone or newly discovered work (records/backlog.md).",
      "room=Family narrative, a decision, a gate, a handback, or an unresolved captain choice (data/<family>/room.md).",
      "learnings=A durable fleet-local gotcha or METHOD lesson about how to work (records/learnings.md).",
      "captain=A captain preference or standing decision (records/captain.md).",
      "projects=A project registration, +yolo posture, or retirement (records/projects.md).",
      "repo_knowledge=A VERIFIED fact about a project codebase - a call graph, a script behavior, a column, a flag (records/repo-knowledge).",
      "project_docs=Project-intrinsic build, test, architecture or convention knowledge that belongs in that project own AGENTS.md through a task.",
      "distro_task=A generalizable agent-crew behavior change that should become a tracked task.",
      "none=Nothing durable: status chatter, thanks, noise.",
      "--choice", `dup_${i}`, "--instructions", `Does candidate line [${i}] restate an existing always-loaded lesson? Pick the entry it repeats, or new.`,
      "--criteria", ...dup,
      "--choice", `worth_${i}`, "--instructions", `Is candidate line [${i}] worth a line in the fleet's learning ledger, which the next Learning distill reads as first-hand evidence?`,
      "--criteria",
      "durable=Durable: something the next crewmate would get wrong without being told, specific to a mechanism, a condition, or a tool.",
      "routine=Routine: a good habit every crewmate is already told or would do unprompted; true but not worth a ledger line.",
      "unclear=Not enough reliable evidence.",
    );
  });
  const jev = `${b8(STARTED_BIN)}/ac-jev.sh`;
  const ask = run([jev, "ask", "--site", "learn-route", "--state-file", state, ...q], { stdout: "pipe" });
  const answer = ask.status === 0 ? subst(ask.out) : "";
  if (answer !== "") {
    for (let n = 1; n <= cands.length; n++)
      must(run(["jq", "-r", "--arg", "o", `owner_${n}`, "--arg", "d", `dup_${n}`, "--arg", "w", `worth_${n}`, "--arg", "n", String(n), ROUTE_JQ], { stdin: B(`${answer}\n`) }).status);
    out(`state_sha=${subst(run([jev, "sha", "--state-file", state], { stdout: "pipe" }).out)}\n`);
  }
  rmF(state);
}

// --- the full-suite gate in front of the DISTILL ------------------------------

const suiteRecord = (): string => `${stateD()}/.learn-suite.meta`;
const suitePinRecord = (): string => `${stateD()}/.learn-suite-pin.meta`;

// learn_suite_root: the distro checkout this entry belongs to, physically.
const suiteRoot = (): string => b8(physicalDir(`${STARTED_BIN}/..`) ?? "");

// learn_suite_head: the root's HEAD, else `no-head`.
function suiteHead(): string {
  const g = run(["git", "-C", suiteRoot(), "rev-parse", "HEAD"], { stdout: "pipe", stderr: "ignore" });
  return subst(g.status === 0 ? g.out : `${g.out}no-head\n`);
}

// learn_suite_pin_write <gen> <head>: the pin record through an exclusive
// temp and a spawned mv; <head> back.
function suitePinWrite(gen: string, head: string): string {
  publish(suitePinRecord(), `generation=${gen}\nhead=${head}\n`);
  return head;
}

// learn_suite_pinned_head <gen>: the pinned head of this generation, else
// live HEAD pinned now.
function suitePinnedHead(gen: string): string {
  const pin = suitePinRecord();
  if (metaG(pin, "generation") === gen) return metaG(pin, "head");
  return suitePinWrite(gen, suiteHead());
}

const snapshotDir = (id: string): string => `${suiteRoot()}/.crew/learn-suite-snapshots/${id}`;

// learn_suite_snapshot_create <id> <head>: a detached worktree at <head>; its
// path printed whether or not git made it (W14).
function snapshotCreate(id: string, head: string): string {
  const dir = snapshotDir(id);
  run(["git", "-C", suiteRoot(), "worktree", "add", "--detach", "--quiet", dir, head], { stdout: "ignore" });
  return dir;
}

// learn_suite_snapshot_remove <id>: best-effort and idempotent.
function snapshotRemove(id: string): void {
  const root = suiteRoot();
  const dir = snapshotDir(id);
  if (exists(dir) && run(["git", "-C", root, "worktree", "remove", "--force", dir], { stderr: "ignore" }).status !== 0) run(["rm", "-rf", dir]);
  run(["git", "-C", root, "worktree", "prune"], { stdout: "ignore", stderr: "ignore" });
}

// `( AC_BACKEND="${b:-herdr}"; export AC_BACKEND; backend_window_alive <id> )
// 2>/dev/null`: the status under the meta's backend, restored after.
function windowAliveUnder(b: string, id: string): number {
  const saved = process.env.AC_BACKEND;
  process.env.AC_BACKEND = u8(b === "" ? "herdr" : b);
  try {
    return backendCall("window_alive", [u8(id)], { stdin: "inherit", stdout: "ignore", stderr: "ignore", subshell: true }).status;
  } finally {
    if (saved === undefined) delete process.env.AC_BACKEND;
    else process.env.AC_BACKEND = saved;
  }
}

// `ac_meta_get ... 2>/dev/null`: an unreadable meta reads as no value, quietly.
const readable = (p: string): boolean => {
  try {
    accessSync(B(p), fsConstants.R_OK);
    return true;
  } catch {
    return false;
  }
};

// learn_suite_inflight: the id of a suite task still in flight, else null -
// having reclaimed every one whose pane the backend DEFINITELY reports gone
// (unobservable keeps holding).
function suiteInflight(): string | null {
  for (const m of glob(stateD(), "verify-suite-", ".meta")) {
    if (!exists(m)) continue;
    const id = basename(m).replace(/\.meta$/, "");
    const b = readable(m) ? metaG(m, "backend") : "";
    if (windowAliveUnder(b, id) === 1) {
      warnB(`the full-suite run ${id} died before recording a verdict (the backend says its pane is gone) - reclaiming it, so the next checkpoint starts a fresh run`);
      snapshotRemove(id);
      rmF(m, b8(taskStatus(u8(id))), `${stateD()}/.pane-${id}`);
      continue;
    }
    return id;
  }
  return null;
}

// learn_suite_launch: the suite as its own paned task; its id, or null where
// the bash's substitution failed (a window the backend would not make, a
// line the pane would not take - its window killed, its identity removed).
function suiteLaunch(): string | null {
  const root = suiteRoot();
  const id = `verify-suite-${now()}`;
  const meta = b8(taskMeta(u8(id)));
  const made = backendWindowNew(u8(id), u8(root), false);
  if (made.exited) return null;
  const window = subst(backendCall("target", [u8(id)], { stdin: "inherit", stdout: "pipe", stderr: "inherit" }).out.toString("latin1"));
  const t = tempFile(meta);
  if (t !== null) putFd(t.fd, `kind=verify-suite\nproject=${basename(root)}\nbackend=${backendName()}\nwindow=${window}\ncwd=${root}\nspawned_at=${isoNow()}\nspawned_epoch=${now()}\n`);
  statusAppend(u8(id), "started the full-suite gate run");
  if (t !== null) run(["mv", b8(t.path), meta]);
  const saved = process.env.AC_SEND_UNPROVEN;
  process.env.AC_SEND_UNPROVEN = "1";
  let sent: number;
  try {
    sent = backendCall("send_line", [u8(id), u8(`AC_HOME=${shellQuote(home())} ${shellQuote(`${root}/bin/ac-learn.sh`)} suite ${id}`)], { stdin: "inherit", stdout: "inherit", stderr: "inherit" }).status;
  } finally {
    if (saved === undefined) delete process.env.AC_SEND_UNPROVEN;
    else process.env.AC_SEND_UNPROVEN = saved;
  }
  if (sent !== 0) {
    try {
      backendKillWindow(u8(id));
    } catch {}
    rmF(meta, b8(taskStatus(u8(id))));
    return null;
  }
  return id;
}

// learn_suite_gate <n> <every>: true when a GREEN verdict for this cycle and
// its pinned tree is on record (or the fleet does not pin the gate); else the
// one HELD line.
function suiteGate(n: string, every: string): { ok: boolean; out: string } {
  if (configReadSoft("learn-suite-gate", "off") !== "on") return { ok: true, out: "" };
  const rec = suiteRecord();
  const gen = learnGeneration();
  let head = suitePinnedHead(gen);
  if (metaG(rec, "generation") === gen && metaG(rec, "head") === head) {
    const st = metaG(rec, "status");
    if (st === "green") return { ok: true, out: "" };
    if (st === "red" && suiteHead() === head)
      return {
        ok: false,
        out: `learning DUE (${n}/${every}) HELD: the full suite is RED for this cycle (run-suite exit ${metaG(rec, "exit")}, ${rec}) - fix it first; Learning waits, and the fix landing starts a fresh run by itself\n`,
      };
  }
  const inflight = suiteInflight();
  if (inflight !== null) {
    const since = metaG(b8(taskMeta(u8(inflight))), "spawned_epoch");
    let elapsed = "an unknown time";
    if (/^[0-9]+$/.test(since)) elapsed = `${BigInt.asIntN(64, arithValue(now()) - arithValue(since))}s`;
    return {
      ok: false,
      out: `learning DUE (${n}/${every}) HELD: the full-suite run ${inflight} is still in flight (running ${elapsed} against ${head.slice(0, 7)}, the tree this cycle pinned - a concurrent commit cannot invalidate it)\n`,
    };
  }
  head = suitePinWrite(gen, suiteHead());
  const id = suiteLaunch();
  if (id === null) return { ok: false, out: `learning DUE (${n}/${every}) HELD: the full-suite run could not be started - the next checkpoint retries\n` };
  return {
    ok: false,
    out: `learning DUE (${n}/${every}) HELD: started the full-suite run ${id} against ${head.slice(0, 7)} - only a GREEN suite releases the DISTILL (config/learn-suite-gate=on - the fleet pinned this gate)\n`,
  };
}

const REAP_AWK = String.raw`
      index(set, " " $2 " ") && !index(set, " " $1 " ") { printf "%s ", $1 }`;

// learn_suite_reap_tree <pid> <sleep>: <pid> and every process below it (read
// by ppid, one ps per level, collected before any signal), TERM and CONT,
// <sleep> 2, then KILL.
function reapTree(pid: number, sleepBin: string): void {
  let all = ` ${pid} `;
  for (;;) {
    const ps = run(["ps", "-A", "-o", "pid=,ppid="], { stdout: "pipe", stderr: "ignore" }).out;
    const more = run(awk([["set", all]], REAP_AWK, []), { stdin: B(ps), stdout: "pipe" }).out;
    if (subst(more) === "") break;
    all += subst(more);
  }
  const pids = all.split(" ").filter((p) => /^[0-9]+$/.test(p)).map(Number);
  const signal = (sig: NodeJS.Signals): void => {
    for (const p of pids)
      try {
        process.kill(p, sig);
      } catch {}
  };
  signal("SIGTERM");
  signal("SIGCONT");
  run([sleepBin, "2"], { stdin: "ignore" });
  signal("SIGKILL");
}

// `$SECONDS`: whole seconds of wall clock.
const seconds = (): number => Math.floor(Date.now() / 1000);

async function cmdSuite(args: string[]): Promise<number> {
  const id = b8(args[0] ?? "");
  if (id !== "" && !id.startsWith("verify-suite-")) dieB(`suite takes its own task id (verify-suite-*), never another task's (got: '${id}')`);
  home();
  const rec = suiteRecord();
  const gen = learnGeneration();
  const head = suitePinnedHead(gen);
  const snapId = id === "" ? `adhoc-${process.pid}` : id;
  armTrap(() => snapshotRemove(snapId));
  const snapshot = snapshotCreate(snapId, head);
  const runner = process.env.AC_LEARN_SUITE_BIN ? b8(process.env.AC_LEARN_SUITE_BIN) : `${snapshot}/tests/run-suite.sh`;
  const limit = b8(process.env.AC_LEARN_SUITE_TIMEOUT || "10800");
  const limitN = testInt(limit);
  const getconf = run(["getconf", "PATH"], { stdout: "pipe", stderr: "ignore" });
  const sleepBin = Bun.which("sleep", { PATH: subst(getconf.out) }) ?? "sleep";
  let timedOut = false;
  const start = seconds();
  // `set -m; "$runner" </dev/null &`: the runner in a process group of its
  // own (run-suite.sh's signal probe needs SIGINT not ignored), through the
  // same bash job-control launch; the launcher's status is the runner's. Job
  // control is off again before the wait, as in the bash, or bash prints the
  // job's `[1]+ Done` line on stderr when it ends.
  let launcher: ReturnType<typeof spawnShell> | null = null;
  try {
    launcher = spawnShell(["/bin/bash", "-c", 'set -m; "$0" </dev/null & set +m; wait $!', u8(runner)], { stdin: "inherit", stdout: OUT, stderr: ERR });
  } catch {}
  let done = launcher === null;
  if (launcher !== null) void launcher.exited.then(() => (done = true));
  while (!done) {
    if (limitN !== null && BigInt(seconds() - start) >= limitN) {
      out(`suite run outlived its ceiling of ${limit}s - ending it and every process below it\n`);
      reapTree(launcher!.pid, sleepBin);
      timedOut = true;
      break;
    }
    try {
      await spawnShell([sleepBin, "1"], { stdin: "ignore", stdout: "ignore", stderr: "ignore" }).exited;
    } catch {}
  }
  let rc = 127;
  if (launcher !== null) {
    await launcher.exited;
    rc = shellStatus(launcher);
  }
  if (timedOut) rc = 124;
  const status = rc === 0 ? "green" : "red";
  const t = tempFile(rec) ?? fatal(1);
  if (!putFd(t.fd, `generation=${gen}\nhead=${head}\nstatus=${status}\nexit=${rc}\nat=${now()}\n`)) fatal(1);
  must(run(["mv", b8(t.path), rec]).status);
  if (id !== "") rmF(b8(taskMeta(u8(id))), b8(taskStatus(u8(id))), `${stateD()}/.pane-${id}`);
  out(`suite ${status} (run-suite exit ${rc}) recorded for generation ${gen} at ${head}\n`);
  return rc;
}

// --- autoroom: the level-triggered learning room ----------------------------

function cmdAutoroom(): void {
  if (process.env.AC_SCOPE) return;
  home();
  let [n, every] = learnDue();
  if (BigInt(n) < BigInt(every)) return;
  const lk = `${stateD()}/.learn-autoroom.lock`;
  if (!lock(lk, 0)) return;
  [n, every] = learnDue();
  const meta = `${stateD()}/learning-chief.meta`;
  const ref = 'records/captain.md "Learning room is chief-created and CAP-EXEMPT"';
  let outcome = "";
  if (BigInt(n) >= BigInt(every) && !exists(meta)) {
    // Each gate's line is captured, as the bash's `$(...)` did, so it prints
    // only after the lock is released - and a die inside the suite launch, or
    // an error that ended the shell (an in-flight epoch of 08), ends that
    // capture, never this verb with the lock held.
    const gate = (fn: () => { ok: boolean; out: string }): { ok: boolean; out: string } => {
      try {
        return fn();
      } catch (e) {
        if (!SHELL_ENDS.has((e as { code?: string })?.code ?? "")) exitOf(e);
        return { ok: false, out: "" };
      }
    };
    const shape = gate(() => shapeGate(n, every));
    const suite = shape.ok ? gate(() => suiteGate(n, every)) : shape;
    if (!shape.ok) outcome = subst(shape.out);
    else if (!suite.ok) outcome = subst(suite.out);
    else if (run([`${b8(STARTED_BIN)}/ac-room.sh`, "post", "learning", "crewchief", charter(n, every)], { stdout: "ignore" }).status !== 0)
      warnB(`learning DUE (${n}/${every}) but the charter could not be posted - the next checkpoint retries`);
    else {
      const sp = captureMerged([`${b8(STARTED_BIN)}/ac-spawn.sh`, "--roomchief", "learning", "--system-initiated", ref]);
      if (sp.status === 0) {
        if (sp.out !== "") out(`${sp.out}\n`);
        outcome = `learning DUE (${n}/${every}): auto-created room \`learning\` and promoted its roomchief (system-initiated, cap-exempt)`;
      } else if (!exists(meta)) {
        if (sp.out !== "") err(`${sp.out}\n`);
        warnB(`learning DUE (${n}/${every}) but the roomchief promote failed BEFORE its meta was written, so the next checkpoint retries (contract: ac-spawn.sh's post-meta tail warns, it never fails a promote - otherwise this line would be a lie)`);
      }
    }
  }
  unlock(lk);
  if (outcome !== "") out(`${outcome}\n`);
}

// --- dispatch ----------------------------------------------------------------

const USAGE = "usage: ac-learn.sh tick [<landing-id>]|autoroom|suite [<task-id>]|run|note <line>...|land <candidate>|promote <name>|rotate-pending|stale|reinforce <slug> --evidence <line>|maintenance status|resume <txid>|abandon <txid>";

const requireTool = (t: string): void => {
  if (!commandV(t)) dieB(`required tool not found: ${t}`);
};

async function main(args: string[]): Promise<number> {
  const [cmd = "", ...rest] = args;
  // Sourcing ac-backend.sh refused a bad backend name before any verb ran.
  backendName();
  switch (cmd) {
    case "autoroom":
      // Best-effort by contract - its host keeps going whatever happens here -
      // so even a refused home exits 0.
      try {
        cmdAutoroom();
      } catch (e) {
        exitOf(e);
      }
      return 0;
    case "tick":
      cmdTick(rest);
      return 0;
    case "suite":
      return await cmdSuite(rest);
    case "run":
      await cmdRun();
      return 0;
    case "note":
      cmdNote(rest);
      return 0;
    case "route-propose":
      cmdRoutePropose();
      return 0;
    case "land":
      cmdLand(rest);
      return 0;
    case "promote":
      cmdPromote(rest);
      break;
    case "maintenance":
      cmdMaintenance(rest);
      return 0;
    case "rotate-pending":
      rotatePending();
      return 0;
    case "stale":
      cmdStale(out, false);
      return 0;
    case "reinforce":
      cmdReinforce(rest);
      return 0;
  }
  dieB(USAGE);
}

// A lib twin that ended the way the shell itself would have (an arithmetic
// error, an unbound variable, a meta lock, a date that could not run) ends the
// run with that status, its own line already printed or the shell's not
// reproduced.
const SHELL_ENDS = new Set(["EARITH", "EUNBOUND", "ELOCK", "EDATE"]);

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  let rc: number;
  try {
    rc = await main(args);
  } catch (e) {
    const code = (e as { code?: string })?.code;
    if (code !== undefined && SHELL_ENDS.has(code)) rc = (e as { status?: number }).status ?? 1;
    else rc = exitOf(e);
  }
  runTrap();
  process.exit(rc);
}
