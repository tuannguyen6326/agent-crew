// ready.ts - the queued-work scheduler primitive and DAG validator.
// The entry is bin/ac-ready.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec and the entry's usage
// text, and the bash original it replaced stays frozen at
// tests/fixtures/ac-ready.sh as the oracle the differential leg of
// tests/sh/ac-ready.test.sh holds this module to.
// Idempotent and read-only over records/backlog.md: run it at every landing
// checkpoint, wake drain, session start, and /debrief - an interrupted
// checkpoint heals at the next run.
//
//   ac-ready.sh                 # default report: READY / STUCK / HELD lines.
//                               #   EVERY startable OR held Queued item, plain
//                               #   and epic alike, in backlog order (=
//                               #   priority order), uncapped and untruncated -
//                               #   the captain auto-fly rule (records/captain.md)
//                               #   is defined over this report,
//                               #   so an item it never names can never be
//                               #   started. Prints NOTHING when there is
//                               #   nothing - safe to wire into digests.
//   ac-ready.sh queued          # the SAME startable set as bare ids: no STUCK
//                               #   lines, no HELD lines, no `(epic:<e>)`
//                               #   decoration. That is what makes it pipeable -
//                               #   ac-teardown.sh takes `head -n1` of it, where
//                               #   a STUCK or HELD line would name a
//                               #   never-startable family as the next promote
//                               #   candidate. A selector for advisories, never
//                               #   the scheduler's word.
//   ac-ready.sh watch-set <fam> # the roomchief's read-only AC_WATCH_ONLY set:
//                               #   <fam> plus its IN-FLIGHT story family ids
//                               #   (an epic), comma-joined, family first and
//                               #   stories in backlog order. A non-epic family
//                               #   has no stories, so the set is EXACTLY <fam>
//                               #   - byte-identical to the pre-epic
//                               #   single-family arming. Recomputed at each
//                               #   re-arm so a scoped watcher tracks its
//                               #   stories as they start and land; a story's
//                               #   pane then routes to the epic roomchief's
//                               #   spool, not the fleet's.
//   ac-ready.sh validate <epic> # mechanical story-map checks: every listed
//                               #   story has a backlog line, ids are valid
//                               #   single tokens (no reserved -spec/-arch/
//                               #   -plan/-review/-ship/-design/-chief/-rN
//                               #   suffixes), and the blocked-by graph among
//                               #   the epic's stories is ACYCLIC
//   ac-ready.sh overlap --semantic '<order text>'  # the System One fold-or-mint proposer
//   ac-ready.sh overlap <path>... # the intake file-interlock check (read-
//                               #   only, prints NOTHING when clean). Per
//                               #   path, one line per hit:
//                               #   LANDED - a state/.landings record <7d old
//                               #     touching the path: family, age, and its
//                               #     data/<family>/room.md as required
//                               #     reading (ledger contract: ac-lib.sh's
//                               #     landing-ledger block)
//                               #   INFLIGHT - a crew/* branch in a projects/
//                               #     repo whose diff vs the default branch
//                               #     touches the path
//                               #   BRIEF - an in-flight brief (data/<id>/
//                               #     brief.md with a live state/<id>.meta)
//                               #     that names the path
//
// READY  <id> (epic:<e>)  - a Queued item that can START NOW: blockers ALL
//                           Done clean, and - for a story - its epic under
//                           config/epic-parallel (default 2) in-flight
//                           stories. A plain item satisfies both trivially,
//                           so it is READY on the same terms.
// STUCK  <id> blocker <b> <missing|failed|abandoned> - a dependent that can
//                           never start; raise ONE ASK in the epic room
// STUCK  <id> blocked-by malformed - ... - the row carries a `blocked-by`
//                           token the pinned grammar did not read, so a
//                           dependency is unreadable; fix the LINE. Never
//                           READY and never offered by `queued`: an unreadable
//                           dependency read as "none" is how a one-character
//                           slip authorized starting a story whose blocker was
//                           still flying (the parser fills blockers_malformed;
//                           src/backlog.ts owns that detection).
// HELD   <id> - captain hold - ... - the row carries the `[@held]` token
//                           (docs/backlog.md) as one of its `[...]`
//                           groups, OR a mis-typed attempt at it - sentinel
//                           present but wrong ("@hold" as well as "@held"),
//                           OR the sentinel forgotten outright (a ONE-WORD
//                           group, no space or TAB, spelling "held"/"hold" -
//                           `[held]`, `[hold]`, `[on-hold]`). NEVER READY and
//                           never offered by `queued`, same fail-closed
//                           direction as a malformed `blocked-by` - a hold is
//                           heavier than a dependency, so a slip may not read
//                           as "no hold" either. NOT pinned to rp[2] the way
//                           `[EPIC]`/`[failed]`/`[abandoned]` are: on a live
//                           ledger rp[2] is usually ALREADY another bracket
//                           tag (`[CAPTAIN-ORDERED ...]`, `[MONITOR ...]`),
//                           so `[@held]` has to be found wherever it actually
//                           sits, but AUTHORITY still needs POSITION: only a
//                           group in the leading run of `[...]` groups right
//                           after the id counts as the real token, so a row,
//                           receipt, or doc line that quotes `[@held]` (wrapped
//                           in backticks) or writes it in the wrong place never
//                           silently holds itself (full rule: the header of
//                           src/backlog.ts, the one owner).
//                           THE `@` SENTINEL is what the WELL-FORMED token and
//                           one malformed rule match on, not the bare word: a
//                           live ledger row was measured to false-positive on
//                           a bracket-syntax-only design, because this
//                           grammar's OTHER bracket tags (`[SLICE ...]`,
//                           `[CAPTAIN ORDER LANDED ...]`) carry free-text
//                           prose that uses "held"/"hold" as an ordinary
//                           English verb ("the guardrail held"). `@`
//                           immediately before the word is the part that
//                           prose never writes, so matching on it keeps the
//                           hold token distinguishable from a sentence inside
//                           a free-text tag. The SECOND malformed rule needs
//                           no sentinel: a group whose entire content is ONE
//                           WORD can never be a free-text tag's prose (a
//                           sentence is always multi-word), so "held"/"hold"
//                           alone in a one-word group is still a hold
//                           attempt, measured zero false positives against
//                           the live ledger's actual one-word bracket groups
//                           (`[x]`, `[abandoned]`, `[failed]`, `[project]`,
//                           `[needs-decision]`, `[0]`). Neither rule is a
//                           whole-line substring scan like `blocked-by`'s
//                           malformed check - every match stays scoped to one
//                           `[...]` group. Release is a CAPTAIN act: no
//                           script here or elsewhere clears `[@held]`; a
//                           chief removes it from the line by hand on the
//                           captain's word - EXCEPT the dated arm
//                           `[@held until <YYYY-MM-DD>]`, which releases
//                           ITSELF: HELD before that date, READY on and after
//                           it, so a time-bound hold needs no hand-edit. The
//                           parser extracts the date (src/backlog.ts's
//                           hold_until), this scheduler is the one that
//                           compares it to today. A hold whose date shape is
//                           anything else is not a dated hold: it reads
//                           `hold malformed`, the same fail-closed direction
//                           as every other slip, never an accidental release.
// Backlog grammar (docs/backlog.md): story lines carry `epic:<id>`;
// `blocked-by: id1,id2 - reason` (comma-joined, no spaces, one space after the
// colon, lowercase). Done lines marked `[failed]`/`[abandoned]` are terminal
// but never satisfy a blocker. `[@held]` anywhere among a row's `[...]` groups
// is a captain hold - visible, never scheduled, cleared only by the captain.
//
// OVERLAP --semantic (the System One fold-or-mint proposer, config/jev). The
// path interlock above answers "same FILE surface"; docs/backlog.md's rule is wider
// - "the same file surface, the same mechanism, or the same defect class, not
// the same wording" - and reading every open row for it was the chief's eyes
// alone. `overlap --semantic '<order text>'` asks bin/ac-jev.sh one choice
// question per OPEN row (In flight + Queued, never Done), all in ONE request
// over one state (the order, then every open row's line and body), and under
// `on` prints the rows the model calls related - `overlap-flying  <id>  p=<p>`
// for In flight (never folded into: its brief is fixed), `fold-candidate  <id>
// p=<p>` for Queued - in ledger order, closed by `state_sha=<sha>`, the key
// `ac-jev.sh label --site overlap` takes for the fold/mint the chief really
// made. Off or absent prints nothing and makes no request; shadow logs only.
// It proposes: folding stays the chief's read of the row, and an In flight
// row stays off limits whatever the model says. A ledger whose open rows
// exceed the adapter's request cap is one reason line and no proposal, the
// adapter's own fail direction; chunking is not built until a fleet's ledger
// needs it.
//
// THE LEDGER is read as bytes (latin1, one character per byte), so a byte
// that is not UTF-8 is prose like any other and no locale can abort the walk;
// every field comes from acDoneline (src/backlog.ts), the one row parser.
//
// HOME. The report, queued, watch-set and validate need records/ (homeless:
// the refusal, exit 1), and a ledger that is no regular file prints nothing.
// Any other first word needs the home before anything: unset or empty is
// `ERROR: AC_HOME is not set ...`, one cd cannot enter `ERROR: AC_HOME is not
// a readable directory: <AC_HOME>`, exit 1; then a word other than `overlap`
// prints this header on stdout, exit 2.
//
// OVERLAP <path>... in detail (no path: `ERROR: usage: ac-ready.sh overlap
// <path>...`, exit 1). Each line is written as it is found, as bytes:
// - LANDED: state/.landings (state/ minted) as ac_landing_overlaps' awk reads
//   it - a record younger than 604800 s by the clock ac_now spells
//   (EPOCHSECONDS, else date(1)), its third field one of the paths, its family
//   not empty - is `LANDED  <path> by <family> <age/3600>h ago - read <room>`,
//   <room> ac_room_file's (the live room, else an archived one, else the room
//   of the family a fan-out id belongs to). A ledger that cannot be read ends
//   the run 2 (awk's status) before any line.
// - INFLIGHT: each non-dot entry of projects/ (minted), in byte order, that is
//   a directory where `git -C <repo> rev-parse --git-dir` (its output dropped)
//   succeeds: against its default branch (ac_default_branch: origin/HEAD,
//   main, master, HEAD), each line `git for-each-ref
//   --format=%(refname:short) 'refs/heads/crew/*'` prints whose `git diff
//   --name-only <default>...<branch>` (stderr dropped, its output as `$(...)`
//   kept it, failed or not) is not empty is `INFLIGHT  <path> on <branch>
//   (repo: <name>)` per path a spawned `grep -qxF -- <path>` finds as a whole
//   line of that output.
// - BRIEF: each data/<name>/brief.md (data/ minted) that is a regular file,
//   ordered by the bytes of that path, whose <name> (trailing LFs cut) has a
//   regular state/<name>.meta, is `BRIEF  <path> named in in-flight
//   data/<name>/brief.md` per path a spawned `grep -qF -- <path> <brief>`
//   finds in it.
// grep's reading is the answer: a path holding a LF is several patterns, an
// empty one matches every line, git's quoted non-ASCII names never match a
// path given unquoted, and the locale's rules apply.
//
// OVERLAP --semantic '<order text>' in detail (an empty text: `ERROR: usage:
// ac-ready.sh overlap --semantic '<order text>'`, exit 1; words after it are
// ignored). A records/backlog.md (records/ minted) that is no regular file
// prints nothing; one that cannot be read ends the run 2. Its open rows are
// read as the original's awk read them: `## In flight` and `## Queued` open a
// section (`in flight`, `queued`), any other `## ` heading closes it; inside
// one, a `- [` line is a row (acDoneline's id; none skips it), and an indented
// non-blank line is a body line of the LAST row read, whatever section that
// row was in, its leading blanks dropped. No row prints nothing. Else a
// spawned `mktemp ${TMPDIR:-/tmp}/ac-ready-semantic.XXXXXX` (its failure ends
// the run with its status) holds the state: `ORDER:`, the order, a blank
// line, `OPEN ROWS:`, then `[<id>] (<section>) <line>` per row and `  <text>`
// per body line, each as `IFS=$'\t' read` read it back (trailing TABs
// dropped). `<bin>/ac-jev.sh ask --site overlap --state-file <state>` follows,
// with per row `--choice <id> --instructions 'Is the backlog row [<id>]
// related to the ORDER? Related means the same file surface, the same
// mechanism, or the same defect class, not the same wording.' --criteria
// related=... unrelated=... unclear=...`; a failure or an empty answer prints
// nothing more. Otherwise per row a spawned `jq -r` over the answer prints
// `<tag>  <id>  p=<p>` when the model chose related (<tag> `fold-candidate`
// for a Queued row, else `overlap-flying`; <p> as jq spells the number), a jq
// that fails ending the run with its status; then `state_sha=<the output of
// <bin>/ac-jev.sh sha --state-file <state>>`. A spawned `rm -f` removes the
// state (its failure ends the run). <bin> is the distro's own bin/
// (STARTED_BIN). Every child runs with the caller's stdin, and with its
// stderr wherever the original did not drop it (rev-parse's, diff's).
//
// ESCAPE HATCH. ac-ready rides session start, the wake drain, the turn-end
// guard and teardown (each fail-soft) and every intake's overlap check. If a
// landed change breaks this module, run the frozen original from a scratch
// bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-ready.sh "$o/bin/ac-ready.sh"
// then "$o/bin/ac-ready.sh" overlap ... by hand. Its report, queued,
// watch-set and validate start this module through "$o/src" all the same, so
// the hatch covers overlap and the usage only; the captain's revert of the
// land is the last resort.
//
// AT PARITY (each pinned in the leg):
// - A landing record with an EMPTY family never reports: the family '' that
//   excludes nothing excludes it.
// - grep's reading above: a path holding a LF is reported when any one of its
//   lines matches (printed whole), an empty path is BRIEF on every brief with
//   a line, a quoted non-ASCII name never matches, and under a UTF-8 locale no
//   path matches a brief line holding a byte that is no UTF-8.
// - A body line after a section change belongs to the last row read.
// - A repeated id is asked twice and printed twice.
//
// DIVERGENCES from the frozen original (the leg names each one a row can show):
// - USAGE HEADER: the usage is this header, where the original printed its
//   own.
// - ORDER: projects/ entries and briefs in byte order under every locale,
//   where bash 3.2's glob followed the locale's collation under UTF-8 (the leg
//   runs the oracle under C).
// - SHELL-OWN STDERR is not reproduced, the status kept: an unreadable
//   state/.landings or records/backlog.md ends the run 2 without awk's `can't
//   open file` lines; a state/, data/, projects/ or records/ that mkdir cannot
//   make is silent; a jq that cannot start ends the run 127 and a state file
//   that cannot be written 1, without the shell's line; from a cwd that has
//   no name the shell's own getcwd lines (`shell-init:`, `chdir:`) are the
//   shim's, fewer than the original's cds printed.
// - NO PARSER CHILD: --semantic parses its rows in this process, where the
//   original's awk started `ac-backlog.sh fields` and ended 2 (`ERROR: the
//   backlog parser failed on <file>`) when that failed - bun missing, or the
//   ledger rewritten mid-read.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is the ERROR line above, where
//   the shell printed its own `cd:` line (exit 1 both); a relative AC_HOME from
//   a caller cwd that has no name is `ERROR: the current directory cannot be
//   resolved, so a relative AC_HOME cannot be either`, exit 1, where cd failed
//   in the deleted directory. From such a cwd every child runs in the distro
//   root, so a relative TMPDIR names a directory there.
// - BUN: overlap needs bun now (the shim's `ERROR: required tool not found:
//   bun`, exit 1, before any argument is read), where the original's path
//   overlap needed none.
// - <bin>: ac-jev.sh is the distro's own bin/, where the original ran the one
//   beside the path it was started by - the same file unless that path was a
//   copy of bin/.
// - BYTES: argv and the environment arrive decoded, so a path, an order text
//   or a TMPDIR that is no UTF-8 is U+FFFD, and a branch name that is no UTF-8
//   reaches `git diff` decoded.
//
// CALLERS: chiefs and roomchiefs at intake (the intake-triage, epic-intake and
// brainstorm skills; bin/ac-spawn.sh's roomchief kickoff names overlap);
// report, queued, watch-set and validate: bin/ac-session-start.sh (a WARN when
// it fails), src/wake-drain.ts (a WARN), bin/ac-turnend-guard.sh (`|| return
// 0`), src/teardown.ts (`queued | head -n1`, stderr dropped),
// bin/ac-watch-autoarm.sh (watch-set, falling back to the scope);
// tests/sh/ac-ready.test.sh and the suites that execute it. No `set -e` script
// runs overlap.

import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { acDoneline, records } from "./backlog.ts";
import {
  NO_HOME,
  STARTED_BIN,
  configRead,
  contractLint,
  defaultBranch,
  die,
  enterCaller,
  landingOverlaps,
  physicalDir,
  recordsDir,
  roomFile,
  shellStatus,
  spawnShellSync,
  tabFields,
  taskMeta,
} from "./lib.ts";

type Row = {
  sec: string;
  id: string;
  marker: string;
  epic: string;
  blockers: string;
  malformed: string;
  hold: string;
  holdMalformed: string;
  until: string;
  contract: string;
  domain: string;
};

// A row's domain is its own token, else its epic row's - the inheritance
// ac_domain_tally and the promote derivation apply too, so every consumer
// fences domain rows off one derivation.
function snapshot(recs: string[]): Row[] {
  const parsed = recs.map((l) => (l.startsWith("- [") ? acDoneline(l) : null));
  const domainOf = new Map<string, string>();
  for (const f of parsed) if (f && f.domain !== "") domainOf.set(f.id, f.domain);
  const rows: Row[] = [];
  let sec = "";
  recs.forEach((l, i) => {
    if (l.startsWith("## In flight")) sec = "inflight";
    else if (l.startsWith("## Queued")) sec = "queued";
    else if (l.startsWith("## Done")) sec = "done";
    else if (l.startsWith("## ")) sec = "";
    else if (/^- \[[ x]\] /.test(l)) {
      const f = parsed[i]!;
      rows.push({
        sec,
        id: f.id,
        marker: f.terminal,
        epic: f.epic,
        blockers: f.blockers,
        malformed: f.blockers_malformed,
        hold: f.hold,
        holdMalformed: f.hold_malformed,
        until: f.hold_until,
        contract: f.contract.replace(/\t/g, " "),
        domain: f.domain !== "" || f.epic === "" ? f.domain : (domainOf.get(f.epic) ?? ""),
      });
    }
  });
  return rows;
}

// Keyed by id: a repeated id's last row decides its section, marker and
// Queued fields, while each Queued occurrence still takes its own turn.
function walk(rows: Row[], today: string) {
  const state = new Map<string, string>();
  const mark = new Map<string, string>();
  const flying = new Map<string, number>();
  const turns: string[] = [];
  const queued = new Map<string, Row>();
  for (const r of rows) {
    state.set(r.id, r.sec);
    mark.set(r.id, r.marker);
    if (r.sec === "inflight" && r.epic !== "" && r.marker !== "epic") flying.set(r.epic, (flying.get(r.epic) ?? 0) + 1);
    if (r.sec !== "queued") continue;
    turns.push(r.id);
    // A DATED hold releases itself: HELD before its date, READY on and after
    // it. ISO dates compare correctly as strings.
    queued.set(r.id, r.hold !== "" && r.until !== "" && r.until <= today ? { ...r, hold: "" } : r);
  }
  const started = new Map<string, number>();
  const underCap = (epic: string, cap: number) => epic === "" || (flying.get(epic) ?? 0) + (started.get(epic) ?? 0) < cap;
  const start = (epic: string) => started.set(epic, (started.get(epic) ?? 0) + 1);
  return { state, mark, turns, queued, underCap, start };
}

function report(rows: Row[], cap: number, today: string): string {
  let s = "";
  // A judge, never a gate: an invalid token must be VISIBLE at the scheduler
  // while the row stays schedulable - ac-brief.sh's escalation gate enforces.
  for (const r of rows) if (r.sec === "queued") for (const v of contractLint(r.contract)) s += `WARN   ${r.id} contract: ${v}\n`;
  const { state, mark, turns, queued, underCap, start } = walk(rows, today);
  for (const id of turns) {
    const r = queued.get(id)!;
    // An unreadable dependency may never read as none: the blockers below
    // would let the row READY, which is how a one-character slip authorized
    // starting a story whose blocker still flew.
    if (r.malformed !== "") {
      s += `STUCK  ${id} blocked-by malformed - fix the line (docs/backlog.md: \`blocked-by: id1,id2 - reason\`)\n`;
      continue;
    }
    if (r.holdMalformed !== "") {
      s += `HELD   ${id} hold malformed - fix the line: needs \`[@held]\` exactly, positioned in the leading run of \`[...]\` groups right after the id, or wrapped in backticks if it is only a mention (docs/backlog.md)\n`;
      continue;
    }
    if (r.hold !== "") {
      s += r.until !== ""
        ? `HELD   ${id} - captain hold until ${r.until}; it releases itself on that date (docs/backlog.md)\n`
        : `HELD   ${id} - captain hold; release is a captain act (docs/backlog.md)\n`;
      continue;
    }
    let stuck = "";
    let waiting = false;
    for (const b of r.blockers === "" ? [] : r.blockers.split(",")) {
      const m = mark.get(b);
      if (!state.has(b)) stuck += `STUCK  ${id} blocker ${b} missing\n`;
      else if (m === "failed" || m === "abandoned") stuck += `STUCK  ${id} blocker ${b} ${m}\n`;
      else if (state.get(b) !== "done") waiting = true;
    }
    if (stuck !== "") {
      s += stuck;
      continue;
    }
    if (waiting || !underCap(r.epic, cap)) continue;
    start(r.epic);
    // The contract rides the line as information, never a condition. A DOMAIN
    // row starts only by promoting its domainchief, and the auto-fly rule is
    // defined over this report, so the line must name that start action.
    const epic = r.epic !== "" ? ` (epic:${r.epic})` : "";
    const contract = r.contract !== "" ? ` [${r.contract}]` : "";
    const domain = r.domain !== "" ? ` {domain:${r.domain} - start = promote its domainchief}` : "";
    s += `READY  ${id}${epic}${contract}${domain}\n`;
  }
  return s;
}

// Bare ids a consumer can pipe - ac-teardown.sh takes `head -n1` - so a row
// that is not startable is simply never offered. A DOMAIN row is not offered
// either: this list feeds auto-fly and the next promote, and offering it would
// schedule the family past its domainchief.
function queuedIds(rows: Row[], cap: number, today: string): string {
  const { state, mark, turns, queued, underCap, start } = walk(rows, today);
  let s = "";
  for (const id of turns) {
    const r = queued.get(id)!;
    if (r.malformed !== "" || r.holdMalformed !== "" || r.hold !== "" || r.domain !== "") continue;
    const blocked = r.blockers !== "" && r.blockers.split(",").some((b) => {
      const m = mark.get(b);
      return state.get(b) !== "done" || m === "failed" || m === "abandoned";
    });
    if (blocked || !underCap(r.epic, cap)) continue;
    start(r.epic);
    s += `${id}\n`;
  }
  return s;
}

function watchSet(rows: Row[], fam: string): string {
  const stories = rows.filter((r) => r.sec === "inflight" && r.epic === fam).map((r) => `,${r.id}`);
  return `${fam}${stories.join("")}\n`;
}

function validate(recs: string[], rows: Row[], epic: string, shown: string): [string, number] {
  const heads = [`- [ ] ${epic} [EPIC]`, `- [x] ${epic} [EPIC]`];
  let list = "";
  for (const l of recs) {
    const m = heads.some((h) => l.startsWith(h)) ? /stories: [a-zA-Z0-9_,-]+/.exec(l) : null;
    if (m) {
      list = m[0].slice("stories: ".length);
      break;
    }
  }
  if (list === "") die(`no [EPIC] line with a stories: list for '${shown}'`);
  const stories = list.split(",").filter((s) => s !== "");
  const ids = new Set(rows.map((r) => r.id));
  let s = "";
  for (const id of stories) {
    if (/-(spec|arch|plan|review|ship|design|chief|r[0-9]{1,2})$/.test(id)) s += `INVALID id ${id}: collides with a reserved stage suffix\n`;
    else if (/[^a-zA-Z0-9_-]/.test(id)) s += `INVALID id ${id}: bad characters\n`;
    if (!ids.has(id)) s += `MISSING story line for ${id}\n`;
  }
  // Kahn over the blocked-by edges among this epic's stories. An edge is a
  // pair, so a blocker named twice still adds one to the in-degree.
  const member = new Set(stories);
  const edges = new Set<string>();
  const indeg = new Map<string, number>();
  const next = new Map<string, string[]>();
  for (const r of rows) {
    if (!member.has(r.id) || r.blockers === "") continue;
    for (const b of r.blockers.split(",")) {
      if (!member.has(b) || edges.has(`${b} ${r.id}`)) continue;
      edges.add(`${b} ${r.id}`);
      indeg.set(r.id, (indeg.get(r.id) ?? 0) + 1);
      next.set(b, [...(next.get(b) ?? []), r.id]);
    }
  }
  const free = [...member].filter((m) => !indeg.get(m));
  for (let n = free.pop(); n !== undefined; n = free.pop()) {
    for (const t of next.get(n) ?? []) {
      indeg.set(t, indeg.get(t)! - 1);
      if (indeg.get(t) === 0) free.push(t);
    }
  }
  for (const m of member) if (indeg.get(m)) s += `CYCLE involving ${m}\n`;
  if (s !== "") return [s, 1];
  return [`map OK: ${list.split(",").length} stories, DAG acyclic\n`, 0];
}

function write(s: string): void {
  const buf = Buffer.from(s, "latin1");
  try {
    for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");

function statOf(p: string): ReturnType<typeof statSync> | null {
  try {
    return statSync(p);
  } catch {
    return null;
  }
}

// `$(...)`'s reading of a child's stdout.
const captured = (b: Buffer): string => b.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

type Io = { stdin?: "inherit" | Buffer; stdout?: "inherit" | "ignore" | "pipe"; stderr?: "inherit" | "ignore" };

function run(argv: string[], { stdin = "inherit", stdout = "inherit", stderr = "inherit" }: Io = {}): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(argv, { stdin, stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: r && stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// A step the original ran under errexit: its failure ends the run with its status.
function must(st: number): void {
  if (st !== 0) process.exit(st);
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "latin1").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  write(`${head.join("\n")}\n`);
  process.exit(2);
}

// `"$(ac_<name>_dir)"`: the path, as bytes, even where mkdir -p failed.
function homeDir(home: string, name: string): string {
  try {
    mkdirSync(`${home}/${name}`, { recursive: true });
  } catch {}
  return b8(`${home}/${name}`);
}

// A glob's matches in the order bash 3.2 sorts them under C: by the bytes of
// each whole match.
function globNames(dir: string, suffix: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(u8(dir), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  return names
    .filter((n) => !n.startsWith("."))
    .sort((a, b) => Buffer.compare(Buffer.from(a + suffix, "latin1"), Buffer.from(b + suffix, "latin1")));
}

function overlapPaths(home: string, paths: string[]): void {
  if (paths.length === 0) die("usage: ac-ready.sh overlap <path>...");
  let hits: string[] = [];
  try {
    hits = landingOverlaps(604800, "", paths);
  } catch (e) {
    const st = (e as { status?: number }).status;
    if (st === undefined) throw e;
    process.exit(st);
  }
  for (const hit of hits) {
    const [fam = "", age = "", p = ""] = tabFields(hit, 3);
    write(`LANDED  ${p} by ${fam} ${BigInt(age) / 3600n}h ago - read ${b8(roomFile(u8(fam)))}\n`);
  }
  const projects = homeDir(home, "projects");
  for (const name of globNames(projects, "")) {
    const repo = u8(`${projects}/${name}`);
    if (!statOf(repo)?.isDirectory()) continue;
    if (run(["git", "-C", repo, "rev-parse", "--git-dir"], { stdout: "ignore", stderr: "ignore" }).status !== 0) continue;
    const def = defaultBranch(repo, true);
    // `while IFS= read -r` never reads an unterminated last line.
    const branches = run(["git", "-C", repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/crew/*"], { stdout: "pipe" }).out.toString("latin1").split("\n").slice(0, -1);
    for (const b of branches) {
      if (b === "") continue;
      const changed = captured(run(["git", "-C", repo, "diff", "--name-only", `${def}...${u8(b)}`], { stdout: "pipe", stderr: "ignore" }).out);
      if (changed === "") continue;
      for (const p of paths)
        if (run(["grep", "-qxF", "--", p], { stdin: Buffer.from(`${changed}\n`, "latin1") }).status === 0)
          write(`INFLIGHT  ${b8(p)} on ${b} (repo: ${name.replace(/\n+$/, "")})\n`);
    }
  }
  const data = homeDir(home, "data");
  for (const name of globNames(data, "/brief.md")) {
    const bf = u8(`${data}/${name}/brief.md`);
    if (!statOf(bf)?.isFile()) continue;
    const id = name.replace(/\n+$/, "");
    if (!statOf(taskMeta(u8(id)))?.isFile()) continue;
    for (const p of paths)
      if (run(["grep", "-qF", "--", p, bf]).status === 0) write(`BRIEF  ${b8(p)} named in in-flight data/${id}/brief.md\n`);
  }
}

const JEV_INSTRUCTIONS = "related to the ORDER? Related means the same file surface, the same mechanism, or the same defect class, not the same wording.";
const JEV_CRITERIA = [
  "related=Related: the same file surface, the same mechanism, or the same defect class, not the same wording.",
  "unrelated=Unrelated: a different surface, mechanism and defect class.",
  "unclear=Not enough reliable evidence.",
];

function overlapSemantic(home: string, order: string): void {
  if (order === "") die("usage: ac-ready.sh overlap --semantic '<order text>'");
  const f = u8(`${homeDir(home, "records")}/backlog.md`);
  if (!statOf(f)?.isFile()) return;
  let text: string;
  try {
    text = readFileSync(f, "latin1");
  } catch {
    process.exit(2);
  }
  // The awk's rows: `<id>\t<section>\t<line>` per row and
  // `<id>\t<section>\tbody\t<text>` per body line, read back as the loops read them.
  const lines: string[] = [];
  let sec = "";
  let id = "";
  for (const l of records(text)) {
    if (l.startsWith("## In flight")) sec = "in flight";
    else if (l.startsWith("## Queued")) sec = "queued";
    else if (l.startsWith("## ")) sec = "";
    else if (sec === "") continue;
    else if (l.startsWith("- [")) {
      id = acDoneline(l).id;
      if (id !== "") lines.push(`${id}\t${sec}\t${l}`);
    } else if (/^[ \t]+[^ \t]/.test(l) && id !== "") lines.push(`${id}\t${sec}\tbody\t${l.replace(/^[ \t]+/, "")}`);
  }
  if (lines.length === 0) return;
  const rows = lines.map((l) => tabFields(l, 3) as [string, string, string]);
  const tmp = run(["mktemp", `${process.env.TMPDIR || "/tmp"}/ac-ready-semantic.XXXXXX`], { stdout: "pipe" });
  must(tmp.status);
  const state = u8(captured(tmp.out));
  let st = `ORDER:\n${b8(order)}\n\nOPEN ROWS:\n`;
  for (const [rid, rsec, rest] of rows)
    st += rest.startsWith("body") ? `  ${rest.startsWith("body\t") ? rest.slice(5) : rest}\n` : `[${rid}] (${rsec}) ${rest}\n`;
  try {
    writeFileSync(state, Buffer.from(st, "latin1"));
  } catch {
    process.exit(1);
  }
  const asked = rows.filter(([, , rest]) => !rest.startsWith("body"));
  const q = asked.flatMap(([rid]) => ["--choice", u8(rid), "--instructions", u8(`Is the backlog row [${rid}] ${JEV_INSTRUCTIONS}`), "--criteria", ...JEV_CRITERIA]);
  const ask = run([`${STARTED_BIN}/ac-jev.sh`, "ask", "--site", "overlap", "--state-file", state, ...q], { stdout: "pipe" });
  const out = ask.status === 0 ? captured(ask.out) : "";
  if (out !== "") {
    for (const [rid, rsec] of asked) {
      const tag = rsec === "queued" ? "fold-candidate" : "overlap-flying";
      must(run(["jq", "-r", "--arg", "id", u8(rid), "--arg", "tag", tag, '.[$id] | select(.choice == "related") | "\\($tag)  \\($id)  p=\\(.p.related)"'], { stdin: Buffer.from(`${out}\n`, "latin1") }).status);
    }
    write(`state_sha=${captured(run([`${STARTED_BIN}/ac-jev.sh`, "sha", "--state-file", state], { stdout: "pipe" }).out)}\n`);
  }
  must(run(["rm", "-f", state]).status);
}

// Every first word but the four ledger verbs: the original bound the home
// before any of them, and overlap prints nothing when clean, so a homeless
// check must refuse rather than read as clean.
function others(verb: string, rest: string[], atCaller: boolean): never {
  const h = process.env.AC_HOME;
  if (!h) die(NO_HOME);
  if (!atCaller && !isAbsolute(h)) die("the current directory cannot be resolved, so a relative AC_HOME cannot be either");
  const home = physicalDir(h) ?? die(`AC_HOME is not a readable directory: ${h}`);
  if (verb === "overlap") {
    if (rest[0] === "--semantic") overlapSemantic(home, rest[1] ?? "");
    else overlapPaths(home, rest);
    process.exit(0);
  }
  usage();
}

const { args, atCaller } = enterCaller(process.argv.slice(2));
const [verb = "", arg = ""] = args;
if (!["", "queued", "watch-set", "validate"].includes(verb)) others(verb, args.slice(1), atCaller);
const backlog = join(recordsDir(), "backlog.md");
let isFile = false;
try {
  isFile = statSync(backlog).isFile();
} catch {}
if (!isFile) process.exit(0);
const capText = configRead("epic-parallel", "2");
const cap = /^[0-9]+$/.test(capText) ? Number(capText) : 2;
if (verb === "watch-set" && arg === "") die("usage: ac-ready.sh watch-set <family>");
if (verb === "validate" && arg === "") die("usage: ac-ready.sh validate <epic-id>");
let text: string;
try {
  text = readFileSync(backlog).toString("latin1");
} catch {
  die(`cannot read ${backlog}`);
}
const recs = records(text);
const rows = snapshot(recs);
// date(1), not Date: ICU misreads POSIX TZ strings the libc honours, and
// ac-task.sh start decides a dated hold is spent by date(1).
const today = spawnShellSync(["date", "+%Y-%m-%d"]).stdout.toString().trim();
// The ledger is compared as bytes, so an argument is too.
const bytes = Buffer.from(arg, "utf8").toString("latin1");
if (verb === "") write(report(rows, cap, today));
else if (verb === "queued") write(queuedIds(rows, cap, today));
else if (verb === "watch-set") write(watchSet(rows, bytes));
else if (verb === "validate") {
  const [out, rc] = validate(recs, rows, bytes, arg);
  write(out);
  process.exitCode = rc;
}
