// room.ts - per-task-family rooms, the captain-facing thread of one task. The
// entry is bin/ac-room.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-room.sh as the oracle the
// differential leg of tests/sh/ac-room.test.sh holds this module to.
//
// A room is data/<family>/room.md - an append-only, timestamped ledger of
// everything the captain cares about for that family: stage transitions,
// gates, escalations, decisions. One file tells one task's whole story, and
// `list` is the captain's inbox of the rooms still waiting on them.
//
// Usage:
//   ac-room.sh post <family> <actor> <text...>   append one entry
//   ac-room.sh show <family> [<n>]               the room; with n > 0 its two
//                                                head lines and last n entries
//   ac-room.sh list                              the inbox: one line per room
//   ac-room.sh close <family> <outcome...>       verify closable, post CLOSED:,
//                                                remove the family's empty spool
//   ac-room.sh open <family>                     focus the promoted room's chief
//                                                window - the CONSENTED redirect:
//                                                only after the captain says yes
//   ac-room.sh pending <family>                  the pending count (0, no room)
//   ac-room.sh handback <family> <text...>       the roomchief reports back:
//                                                HANDBACK: posted, a durable wake
//                                                queued, the fleet watcher nudged
//   ac-room.sh gate-route|route-gate <family> <stage> --report <file>
//       --uncertainty <yes|no> --consequence <low|high> --authority <chief|captain>
//       --grounds <text...>
//   ac-room.sh gate-verify|verify-gate <family> <stage> --round <1|2>
//       --report <file> --grounds <text...>
//   ac-room.sh disposition <family> <stage> --r1 <file> --accepted <ids|none>
//       --disputed <ids|none> --authority <chief-owned|captain-owned|mixed|none>
//       --grounds <text...>
//   room.ts rows <room-file>...                  the inbox projection (ROWS)
// No verb, or any other: this header on stdout, exit 2.
//
// THE GRAMMAR. An entry is `- [<utc>] <actor>> <text>`, written here and read
// by every room reader by its LINE shape - the stamp `[^]]*`, the actor `[^>]*`,
// both POSITION-pinned, so a marker quoted inside a message is never one. A
// `GATE:` or `ASK:` entry waits on the captain; each `DECIDED:` settles one,
// oldest first, never below zero. The verb may carry one [A-Za-z0-9_-] word
// and one (parenthetical) before its colon (`ASK (1 of 2):`, `DECIDED
// <family>:`, `DECIDED (captain):`); a verb continued by `-` (GATE-LOOPED:,
// GATE-PASSED (auto):, GATE-ROUTING:, GATE-VERIFY:) is no counted item. The
// MATCHER is ac_room_pending in bin/ac-wake-lib.sh, shared with the turn-end
// guard; this module's OPEN/DECIDED patterns are its copy
// (roomPending, exported), held to it by tests/sh/ac-room.test.sh. A room is in HANDBACK while its last `HANDBACK:`
// is not followed by `HANDBACK-REFUSED:`, `DEMOTED:` or `CLOSED:`
// (ac_room_handback_families). TRIAGE:, SELF-APPROVED:, GATE-PASSED (auto):,
// GATE-LOOPED:, GATE-ROUTING:, GATE-VERIFY:, R1-DISPOSITION: and
// STAGE-ADMISSION: are receipts: no pending effect, the captain vetoes by
// replying. GATE-ROUTING binds one exact report's SHA-256 and DERIVES the
// route: authority=captain -> captain, else uncertainty=yes or
// consequence=high -> second-chief, else chief. GATE-VERIFY is the roomchief's
// pass before a staged second-chief pane opens. R1-DISPOSITION records which
// R1 Required Changes the roomchief accepted or disputed, bound to the R1's
// and the current report's SHA-256; src/gate.ts reads the latest valid one
// before R2 (its readers and these writers are held together by the
// WRITER/READER PARITY matrix of tests/sh/ac-gate.test.sh). STAGE-ADMISSION's
// grammar is docs/staged-design-flow-spec.md's.
//
// BEFORE ANY VERB but rows, the fleet backend is resolved (backendName,
// src/lib.ts): AC_BACKEND, config/backend, <AC_FLEET_STATE>/../config/backend,
// herdr - any other name, usage included, is
//   ERROR: unsupported backend '<b>' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)
// exit 1. Every ERROR below is on stderr, exit 1 unless noted.
//
// post <family> <actor> <text...>, in this order:
//  1. fewer than two arguments, or an empty family, actor or text (the words
//     after the actor joined by one space, empty ones kept - `post f a "" ""`
//     posts ` `):  ERROR: usage: ac-room.sh post <family> <actor> <text...>
//  2. a family outside [a-zA-Z0-9_-]:  ERROR: family must be [a-zA-Z0-9_-]: <family>
//  3. actor `crewchief` in a home holding .ac-crewdeputy-home (`[ -e ]`)
//     records as `crewdeputy`: a deputy's chief self-labels crewchief beside
//     migrated parent-fleet entries whose crewchief was another session.
//  4. the text's first line opening GATE/ASK/DECIDED then [:space:], `:` or
//     its end, without the `verb[ word][ (paren)]:` shape (grep -E judges both,
//     under the caller's locale - a TAB or, under UTF-8, a NBSP is
//     [:space:]):  ERROR: post: '<text>' opens with a GATE/ASK/DECIDED verb but is not well-formed (needs a colon, after an optional word and/or (parenthetical)) - fix the message; a malformed marker settles/opens nothing and can hang this room PENDING forever
//  5. a later line of the text matching `^- \[[^]]*\] [^>]*> ` (grep -E):
//     ERROR: post: a continuation line of the message has the shape of a room entry ('- [stamp] actor> ...') and every room reader would count it as its own entry - quote it indented or without the leading '- '
//  6. THE GUARD: a text opening GATE, ASK, TRIAGE, SELF-APPROVED, LANDED,
//     `HANDBACK:`, R1-DISPOSITION, DECIDED or `STAGE-ADMISSION:`, posted with
//     AC_SCOPE other than <family> and AC_ROOM_PROMOTE_RECEIPT other than 1,
//     into a family whose roomchief is LIVE - state/<family>-chief.meta there
//     (`[ -e ]`) and backend_window_alive answering 0 (backendCall, as its
//     `( )` ran) under the meta's backend= (herdr when absent; an unreadable
//     meta reads as none, silently), stderr dropped:  ERROR: post: <family> has a LIVE roomchief - its own TRIAGE/GATE/ASK/SELF-APPROVED/LANDED/HANDBACK/GATE-ROUTING/R1-DISPOSITION/DECIDED/STAGE-ADMISSION receipts belong to it, never to an unscoped caller (rooms-threads skill: 'Two chiefs on one family is a role violation, not extra help')
//     Every other answer - 1, 2, a refused backend name - is NOT live: the
//     guard fails OPEN, refusing a real write being worse than a
//     rare duplicate. Two chiefs writing one family's receipts is a role
//     violation (AGENTS.md section 8); AC_SCOPE, never the actor string, is
//     the discriminator, since a live roomchief posts under several actors.
//     PROMOTED/DEMOTED/CLOSED (the crewchief's own lifecycle bookkeeping),
//     CORRECTION and HANDBACK-REFUSED: (the crewchief refusing its live
//     roomchief's hand-back - the turn-end guard's one way to clear an owed
//     hand-back without demoting) stay unguarded; AC_ROOM_PROMOTE_RECEIPT=1 is
//     bin/ac-spawn.sh's ONE declared exception, its cap-gate DECIDED: receipt
//     posted the instant a roomchief is promoted - an accident guard, not a
//     security boundary.
//  7. the LIVE room <home>/data/<family>/room.md (never an archived one): its
//     directory made by a spawned `mkdir -p` when absent (its line and status
//     end the run), `# Room: <family>` and a blank line written when no
//     regular file is there.
//  8. the pending count read (an unreadable room reads 0), the date taken
//     with date(1) -u +%Y-%m-%dT%H:%M:%SZ - one that fails ends the run with
//     its status, the room left as it was - and `- [<date>] <actor>> <text>`
//     plus a newline appended: the text's own newlines become continuation
//     lines, a trailing one a blank line.
//  9. the count re-read: 0 before and above 0 now - the blocked-by-captain
//     EDGE, strict, so a second GATE/ASK on an already-pending room is silent
//     - notifies in-process: notify("crew blocked", "<family>: <text>") of
//     src/notify.ts, its stderr - the bell line, a config file's head(1)
//     line - sunk (the bash dropped notify's stderr and status). That is the
//     repo's ONE captain notification
//     (tests/sh/ac-notify-surface.test.sh).
// 10. actor <family>-chief at 0 pending with a text opening none of GATE ASK
//     DECIDED TRIAGE SELF-APPROVED LANDED HANDBACK PROMOTED DEMOTED CLOSED
//     CORRECTION R1-DISPOSITION STAGE-ADMISSION - the shape of a silent
//     escalation:  WARN: post: <family>-chief posted with no marker while <family> has 0 pending - if you are actually waiting on the captain, post an ASK:/GATE: instead
// 11. THE MIRROR, only when config/remote-mirror reads `on`: verb = the text
//     before its first `:`, body = the text after its first `: ` (else all);
//     a text opening [A-Z] with a `:` after it heads
//     `<verbEmoji(verb)> *[<vn>] [<verb>] [<family>]* <actor>`, any other
//     `📝 *[<vn>] [<family>]* <actor>` with the whole text as body; <vn> is
//     ac_vn_ts's (TZ=Asia/Ho_Chi_Minh date '+%Y-%m-%d %H:%M'), whose failure
//     ends the run with its status. The body goes through a spawned
//     `sed -E 's/ ([A-Z][A-Z_-]{2,}: )/\<LF>• \1/g; s/ (\([0-9]+\) )/\<LF>• \1/g'`
//     (its failure ends the run with its status) and is prefixed `• `; head
//     and body, a newline after each, are the stdin of
//     <started bin>/ac-remote.sh thread-post <family> [--mention-captain
//     on GATE:/ASK:], its output dropped; its failure:
//       WARN: room mirror to remote thread failed for <family> (room entry saved)
// 12. THE CAPTAIN-WAIT STAMP, when state/<family>-chief.meta is a regular file:
//     pending > 0 -> backend_mark_wait <family>-chief "ĐANG CHỜ captain - <n>
//     mục trong room <family>", else backend_clear_wait <family>-chief -
//     backendCall under the FLEET backend (never the chief meta's), stderr
//     dropped, failures ignored; a refused backend name ends the run with
//     its status.
// 13. stdout `posted to <room path>`, exit 0.
//
// handback <family> <text...>: no family -> `ERROR: usage: ac-room.sh handback
// <family> <text...>` (and an empty family or text). Then post <family>
// <family>-chief "HANDBACK: <text>" with every refusal and warning of post, its
// stdout dropped (the stamp's included); then the wake record published to
// the FLEET spool whatever AC_SCOPE says - a hand-back wakes the crewchief, and
// a family spool would hand the demotion notice to the roomchief demoting
// itself: wakePublish(<state>, "", handback, <family>-chief, <text>) called
// bare, so a failing date ends the run with its status and a clock printing
// no ten digits exits 1 SILENTLY, the HANDBACK already in the room (W17). Then
// the nudge (watcherNudge, src/lib.ts) and on stdout
//   handback posted and queued for <family> - <the nudge's outcome line>
// A hand-back never notifies (it is chief-owned, not blocked-by-captain).
//
// pending <family>: no family -> `ERROR: usage: ac-room.sh pending <family>`.
// The room roomFile (src/lib.ts) resolves - live, archived, a fan-out
// sub-task's family - not a regular file: `0`; else its count, or, unreadable,
// grep's own line (`grep: <path>: Permission denied`) and exit 2. Homeless,
// roomFile's refusal per data-dir read, then `0`, exit 0 (W16).
//
// show <family> [<n>]: no family -> `ERROR: usage: ac-room.sh show <family>
// [<n>]`; no regular file at roomFile's path -> `ERROR: no room for <family>`.
// <n> (empty -> 0) read as bash's `[ "$n" -gt 0 ]` reads it - leading
// isspace, a sign, decimal digits, trailing blanks, 64 bits - and above zero:
// spawned `head -n 2 <room>` (its failure ends the run with its status), then
// `grep '^- \[' <room> | tail -n <n as given>`, statuses ignored - so `+1` is
// every entry, ` 2 ` is tail's own offset error, `007` is 7 (W28), and a room
// holding a NUL is grep's `Binary file ... matches`. Else spawned `cat <room>`,
// its status the exit.
//
// list: the home is required (no AC_HOME is its refusal, a home cd cannot
// enter is `AC_HOME is not a readable directory: <h>`, exit 1); nothing is
// minted. The rooms are <home>/data/<name>/room.md for every <name> not
// opening with a dot whose room.md exists as a directory entry (a dangling
// link included), in BYTE order. Only the FIRST is judged a regular file - a
// directory or a dangling link there reads as no rooms at all (W10); a later
// one fails the read (W11). The rows (ROWS, in-process) failing:
//   ERROR: cannot read <path>
//   ERROR: list: the room set could not be read - the inbox has no answer, not zero rooms
// exit 1 - never an empty inbox. Each row is read as `IFS=$'\x1f' read -r
// pending hb family last` read it (a last field ending in its only 0x1f loses
// it - W13), <last> cut to 120 CHARACTERS under a UTF-8 locale (a strictly
// valid UTF-8 sequence one, every other byte one) and 120 bytes under any
// other (shellPrefix, src/lib.ts - W12); BLOCKED when the room's count is 0
// and state/.ask-<family>-chief exists (`[ -e ]`) - the watcher's live stamp
// of a chief pane parked on a select, a silent escalation that posts nothing
// - shown as 1. One line each, the 20-column status field and the TAB frozen
// (dashboard/lib.ts parseRoomList, src/fleets.ts, src/dash.ts and
// bin/ac-session-start.sh read them):
//   PENDING-CAPTAIN(<n>)+HANDBACK  <family>\t<last>
//   PENDING-CAPTAIN(<n>)+BLOCKED  <family>\t<last>
//   PENDING-CAPTAIN(<n>)  <family>\t<last>
//   HANDBACK            <family>\t<last>
//   ok                  <family>\t<last>
// none: `(no rooms yet)`. Exit 0.
//
// close <family> <outcome...>: no family -> `ERROR: usage: ac-room.sh close
// <family> <outcome...>`. <outcome> is the later words joined, `landed` only
// when there are none (one empty word is an empty outcome - W8). The LIVE room
// must be a regular file (homeless, the refusal once and the dir-less path):
//   ERROR: no room for <family>
// then, over state/*.meta in byte order (a dot name skipped, `[ -e ]`, a
// verify-* meta skipped - a verifier holds no backlog row and nobody demotes
// it), the first that is <family>-chief, or whose id familyOfId reads as
// <family>, or whose fleet_scope= is <family> (an unreadable meta warns
// `WARN: cannot read meta file <m>` there and is no member) - membership,
// never an id prefix, as bin/ac-teardown.sh's demote reads it:
//   ERROR: close: <id> is still in flight
// then the count (unreadable: grep's line, then the refusal - W15):
//   ERROR: close: room <family> still has pending gates/asks (answer them first)
// then `- [<date>] crewchief> CLOSED: <outcome>` appended (a failing date
// writes `- []` and goes on - W9). The family's own spool
// (wakeSpoolPath(<state>, <family>): a family that is no scope name names the
// FLEET spool), when a directory: holding a non-dot entry `[ -e ]` finds (a
// subdirectory counts, a dangling link does not) ->
//   WARN: close: <family>'s wake spool (<spool>) still holds undrained records - not removing it
// else rmdir, failing (a dot entry left) ->
//   WARN: close: <family>'s wake spool (<spool>) could not be removed
// - a family outlives its tasks, so nothing else ever removes it, and an
// undrained record is never deleted to tidy up. stdout
// `room <family> closed: <outcome>`.
//
// open <family>: no family -> `ERROR: usage: ac-room.sh open <family>`; no
// regular file at taskMeta(<family>-chief):
//   ERROR: room <family> is not promoted (no <family>-chief in flight); promote with ac-spawn.sh --roomchief <family>, or keep talking here
// AC_BACKEND becomes the meta's backend (taskBackend: herdr when absent, an
// unreadable meta warned and herdr), then backend_window_alive (backendCall),
// stdio passed: a refused backend name (a bogus meta backend's
// unsupported-backend line) ends the run with its status; 1 ->
//   ERROR: roomchief window is gone; respawn (--roomchief <family>) or teardown <family>-chief
// any other but 0 (2 unreadable, a timed-out herdr included) - never
// "gone", a roomchief that may be alive is never torn down on an
// unobservable read:
//   ERROR: the BACKEND could not be READ for <family>-chief - whether <backend_target> still exists is UNKNOWN, so this is NOT treated as gone; check the backend itself (herdr status server), then try again
// (herdr named for orca too - W18). 0 -> backend_focus (`ERROR: could not
// focus <family>-chief` on failure), then `focused <family>-chief
// (<backend_target>)` - `herdr:pane-<p>` or `orca:<h>`.
//
// gate-route / gate-verify / disposition: fewer than two words, a value flag
// as the last word, an unknown word, or an empty value - every value flag
// takes the next word, --grounds takes EVERY later word joined by one space
// and ends the parse, the last of a repeated flag wins - and grounds of
// [:space:] only (the class under the caller's locale: a NBSP is space under
// UTF-8 alone - W22) -> the verb's usage line:
//   ERROR: usage: ac-room.sh gate-verify <family> <stage> --round <1|2> --report <file> --grounds <text...>
//   ERROR: usage: ac-room.sh gate-route <family> <stage> --report <file> --uncertainty <yes|no> --consequence <low|high> --authority <chief|captain> --grounds <text...>
//   ERROR: usage: ac-room.sh disposition <family> <stage> --r1 <file> --accepted <ids|none> --disputed <ids|none> --authority <chief-owned|captain-owned|mixed|none> --grounds <text...>
// then, in order: `<verb> grounds must be one physical line` (a LF or CR);
// the family charset line; gate-route `--uncertainty must be yes|no`,
// `--consequence must be low|high`, `--authority must be chief|captain`;
// gate-verify `--round must be 1 or 2`; `<verb> stage must be
// spec|architecture|plan|design` (spec, arch, plan, design dirs);
// disposition `authority must be chief-owned|captain-owned|mixed|none`. The
// file (relative to the CALLER's cwd) must be non-empty and no symlink
// (`[ -s ] && [ ! -L ]`) - `<verb> --report must name a non-empty plain file`,
// `disposition --r1 must name a non-empty plain file` - and, as its physical
// directory plus its name (a directory cd cannot enter makes it `/<name>` -
// W23), exactly <home>/data/<family>/<dir>/report.md
// (second-chief-r1.md for --r1): `<verb> --report must be <expected>`,
// `disposition --r1 must be <expected>` (homeless: the refusal, exit 1).
// disposition then needs that stage's report.md non-empty and no symlink
// (`disposition requires a non-empty current report at <path>`) and the R1's
// ids - its body after the second `---` line, the numbered lines of its
// `## Required Changes` section, through spawned awk | awk | `paste -sd, -`
// (any stage failing ends the run with the rightmost failing status: an
// unreadable R1 is awk's 2) - non-empty (`disposition R1 has no numbered
// Required Changes to adjudicate`); --accepted and --disputed each normalized
// by a spawned `awk -v raw=` - `none`, or distinct ids sorted ascending
// (`disposition --accepted must be comma-separated numeric ids or none`, the
// same for --disputed; awk reads escapes in the value: `1\0542` is `1,2` -
// W20, and a huge id walks up to it - W21); then a spawned awk judging the
// partition (`disposition accepted/disputed ids must exactly partition R1
// Required Changes, with valid authority`). The SHA-256 of each file (one
// that cannot be read exits 1) and the receipt posted by post as actor
// <family>-chief, the guard and the stamp included, `posted to` on stdout:
//   GATE-ROUTING: stage=<stage> report_sha256=<hex> uncertainty=<u> consequence=<c> authority=<a> route=<captain|second-chief|chief> grounds=<g>
//   GATE-VERIFY: stage=<stage> round=<r> report_sha256=<hex> verdict=pass grounds=<g>
//   R1-DISPOSITION: stage=<stage> r1_sha256=<hex> report_sha256=<hex> accepted=<ids> disputed=<ids> authority=<a> grounds=<g>
// <stage> as typed (`architecture`, never `arch`). The three awk programs are
// the original's verbatim, and src/gate.ts's readers spawn these same
// constants, so a writer and its reader cannot drift apart.
//
// ROWS - `room.ts rows <room-file>...`, started by ac_room_list_rows in
// bin/ac-wake-lib.sh (that function stays, with no caller of its own once list
// reads the rows in-process): one line "<pending>\x1f<hb>\x1f<family>\x1f
// <last>" per argument, in argument order, an empty room included (0, 0, its
// family, ""). Exit 0; 2 with no rows printed on a usage error (`ERROR:
// usage: room.ts rows <room-file>...`) or when any room cannot be read
// (`ERROR: cannot read <path>`). A room is bytes: read latin1, a line ending
// at its first NUL - the C-locale awk reading. <pending> and <hb> are THE
// GRAMMAR's; <family> is the room file's parent directory name, printed as
// latin1 of its decoded name (`café` prints `caf\351` - W14); <last> the whole
// last line opening "- [", untruncated. State is keyed by the path as given,
// so a room named twice counts twice. The separator is 0x1f, never a TAB, which
// `read` would trim off the last field.
//
// THE BACKEND VERBS go through backendCall (src/lib.ts), the twin of
// bin/ac-backend.sh's herdr and orca drivers: backend_window_alive
// <fam>-chief (the guard, AC_BACKEND the meta's for that call only, as the
// original's `( )`; open), backend_mark_wait / backend_clear_wait (the
// stamp), backend_focus and backend_target (open). stdin passes to every one,
// as to every child here, except where the original's subshell handed herdr
// /dev/null (the guard).
//
// EXIT: 0; 1 on every refusal; 2 for usage and an unreadable room's pending;
// a child's status where its failure ends the run (128+signal for a signal,
// 127 for one that could not start).
//
// DIVERGENCES from the original, named in the differential leg:
// - W26: the usage text is this header (the shim's is a pointer), and `rows`
//   answers the projection where the original printed its header.
// - W1, W6: `[a-zA-Z0-9_-]` and `[A-Z]` are read per the text; bash 3.2's
//   ranges under a UTF-8 locale let `café` and `lower:` through.
// - W3, W4 (the HOME RESOLUTION ruling): homeless, post refuses ONCE where the
//   original printed the refusal per swallowed `$(ac_home)` and went on to
//   `mkdir -p /<family>`; an AC_HOME cd cannot enter is `AC_HOME is not a
//   readable directory: <h>` where the shell printed cd's own lines.
// - W7 and every other argv byte: argv arrives decoded, so a text byte that
//   is not UTF-8 is posted as U+FFFD - the mirror's sed then never aborts on
//   it the way BSD sed aborted the original under UTF-8, after the append.
//   So is such a byte of the chief meta's backend= in AC_BACKEND, and so in
//   open's unsupported-backend refusal.
// - W24 and bash's own stderr are not reproduced: the redirection line of an
//   unreadable report, `command not found`, a failed append's line.
// - W27 ORDER: the rooms, the metas and the archive years are walked in byte
//   order (the oracle runs under LC_ALL=C); bash 3.2's glob followed the UTF-8
//   collation.
// - A DRIVER THAT FAILED TO LOAD: bash's 127 (open's BACKEND refusal, a guard
//   reading not live) has no counterpart - the backend verbs are native.
//
// CALLERS, every one fail-soft already (a bun-less PATH degrades each to its
// own WARN or UNKNOWN): bin/ac-session-start.sh (list, `|| printf 'WARN
// rooms: ...'`), bin/ac-spawn.sh (the PROMOTED post and the declared
// DECIDED: receipt, `|| ac_warn`), bin/ac-teardown.sh (the DEMOTED post, its
// stderr in the WARN), bin/ac-learn.sh (two posts, `|| ac_warn`),
// src/curate.ts (status checked, its WARN), bin/ac-epic-ship.sh (`|| true`),
// src/feature.ts (status ignored), src/fleets.ts (list: inbox.unreadable),
// src/dash.ts (list: the rooms-unreadable WARN), dashboard/app.ts (list: null;
// show: no entries). No hook runs this entry.
import { accessSync, appendFileSync, constants, existsSync, lstatSync, readdirSync, readFileSync, rmdirSync, statSync, writeFileSync, writeSync } from "node:fs";
import { basename, dirname, isAbsolute } from "node:path";
import { records } from "./backlog.ts";
import {
  backendCall,
  backendName,
  configReadSoft,
  dataDir,
  die,
  enterCaller,
  envHome,
  familyOfId,
  metaGet,
  metaIsVerify,
  NO_HOME,
  physicalDir,
  roomchiefLive,
  roomFile,
  sha256File,
  shellPrefix,
  shellSpaceClass,
  shellStatus,
  softSubdir,
  spawnShellSync,
  spoolHasRecord,
  STARTED_BIN,
  stateDir,
  taskBackend,
  taskMeta,
  verbEmoji,
  vnTs,
  wakePublish,
  wakeSpoolPath,
  warn,
  watcherNudge,
} from "./lib.ts";
import { notify } from "./notify.ts";

const OPEN = /^- \[[^\]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/;
const DECIDED = /^- \[[^\]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/;
const HANDBACK = /^- \[[^\]]*\] [^>]*> HANDBACK:/;
const REFUSED = /^- \[[^\]]*\] [^>]*> HANDBACK-REFUSED:/;
const RETIRED = /^- \[[^\]]*\] [^>]*> (DEMOTED|CLOSED):/;

type Io = "inherit" | "ignore" | "pipe";
type Out = "inherit" | "ignore";

const utf8 = (s: string): Buffer => Buffer.from(s, "utf8");
const latin1 = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const out = (s: string | Buffer): void => {
  const buf = typeof s === "string" ? utf8(s) : s;
  for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
};
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (buf: Uint8Array): string => Buffer.from(buf).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// The shell's status for a child, its stdout when piped. stdin is the
// caller's, as it was for every child of the bash.
function run(cmd: string[], stdout: Io, stderr: Io, stdin: "inherit" | Buffer = "inherit"): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// ac_home inside a bare statement: no AC_HOME is its refusal, a home cd cannot
// enter is named (the HOME RESOLUTION ruling), both exit 1.
function home(): string {
  if (!process.env.AC_HOME) die(NO_HOME);
  return envHome();
}

// --- the room grammar -------------------------------------------------------

type Room = { open: number; hb: number; last: string };

function scan(text: string, s: Room): void {
  for (const l of records(text)) {
    if (OPEN.test(l)) s.open++;
    if (DECIDED.test(l) && s.open > 0) s.open--;
    if (HANDBACK.test(l)) s.hb = 1;
    if (REFUSED.test(l) || RETIRED.test(l)) s.hb = 0;
    if (l.startsWith("- [")) s.last = l;
  }
}

// ac_room_pending's count for one room (the bash function stays for its own
// callers); a room that cannot be read throws.
export function roomPending(file: string): number {
  const s: Room = { open: 0, hb: 0, last: "" };
  scan(readFileSync(file).toString("latin1"), s);
  return s.open;
}

// What ac_room_scan's grep printed for a room it could not open: grep's own
// line, from grep.
function grepRefusal(file: string): void {
  const saved = process.env.LC_ALL;
  process.env.LC_ALL = "C";
  run(["grep", "-a", "-q", "-E", "--", "^", file], "ignore", "inherit");
  if (saved === undefined) delete process.env.LC_ALL;
  else process.env.LC_ALL = saved;
}

// `$(ac_room_pending "$f" 2>/dev/null || printf 0)`, a non-count read as 0.
function pendingSoft(file: string): number {
  try {
    return roomPending(file);
  } catch {
    return 0;
  }
}

// Exported so src/turnend-guard.ts judges pending and HANDBACK by this one
// copy of the room grammar.
export function rowsOf(files: string[], atCaller: boolean): { text: string } | { error: string } {
  const state = new Map<string, Room>();
  for (const f of files) {
    if (!isAbsolute(f) && !atCaller) return { error: `cannot read ${f}: the current directory has no name` };
    let text: string;
    try {
      text = readFileSync(f).toString("latin1");
    } catch {
      return { error: `cannot read ${f}` };
    }
    let s = state.get(f);
    if (!s) state.set(f, (s = { open: 0, hb: 0, last: "" }));
    scan(text, s);
  }
  const family = (path: string): string => {
    const a = path.split("/");
    return a.length >= 2 ? a[a.length - 2]! : path;
  };
  return {
    text: files
      .map((f) => {
        const s = state.get(f)!;
        return `${s.open}\x1f${s.hb}\x1f${family(f)}\x1f${s.last}\n`;
      })
      .join(""),
  };
}

function cmdRows(args: string[], atCaller: boolean): void {
  const fail = (msg: string): never => {
    writeSync(2, `ERROR: ${msg}\n`);
    process.exit(2);
  };
  if (args.length < 2) fail("usage: room.ts rows <room-file>...");
  const r = rowsOf(args.slice(1), atCaller);
  if ("error" in r) fail(r.error);
  try {
    out(latin1(r.text));
  } catch (e) {
    if ((e as { code?: string }).code !== "EPIPE") throw e;
  }
}

// --- post -------------------------------------------------------------------

const GUARDED = ["GATE", "ASK", "TRIAGE", "SELF-APPROVED", "LANDED", "HANDBACK:", "R1-DISPOSITION", "DECIDED", "STAGE-ADMISSION:"];
const MARKERS = ["GATE", "ASK", "DECIDED", "TRIAGE", "SELF-APPROVED", "LANDED", "HANDBACK", "PROMOTED", "DEMOTED", "CLOSED", "CORRECTION", "R1-DISPOSITION", "STAGE-ADMISSION"];
const MIRROR_SED = "s/ ([A-Z][A-Z_-]{2,}: )/\\\n• \\1/g; s/ (\\([0-9]+\\) )/\\\n• \\1/g";

// `grep -qE <ere> <<<"$s"` under the caller's locale.
const grepQ = (ere: string, input: string): boolean => run(["grep", "-qE", ere], "ignore", "inherit", utf8(input)).status === 0;

// ac_room_marker_malformed: grep judges the first line only when it opens with
// a counting verb - the one shape either ERE can match.
function markerMalformed(text: string): boolean {
  const first = text.split("\n")[0]!;
  if (!/^(GATE|ASK|DECIDED)/.test(first)) return false;
  if (!grepQ("^(GATE|ASK|DECIDED)([[:space:]]|:|$)", `${first}\n`)) return false;
  return !grepQ("^(GATE|ASK|DECIDED)( [A-Za-z0-9_-]+)?( \\([^)]*\\))?:", `${first}\n`);
}

// `tail -n +2 <<<"$text"` searched for a room entry's line shape.
function continuationShaped(text: string): boolean {
  const nl = text.indexOf("\n");
  if (nl < 0) return false;
  const rest = `${text.slice(nl + 1)}\n`;
  if (!rest.split("\n").some((l) => l.startsWith("- ["))) return false;
  return grepQ("^- \\[[^]]*\\] [^>]*> ", rest);
}

// date(1) as `$(...)` reads it, with the shell's status for it.
function dateStamp(argv: string[]): { status: number; stamp: string } {
  const r = run(argv, "pipe", "inherit");
  return { status: r.status, stamp: subst(r.out) };
}

function post(args: string[], stdout: Out): void {
  const usage = "usage: ac-room.sh post <family> <actor> <text...>";
  if (args.length < 2) die(usage);
  const family = args[0]!;
  let actor = args[1]!;
  const text = args.slice(2).join(" ");
  if (!family || !actor || !text) die(usage);
  if (/[^a-zA-Z0-9_-]/.test(family)) die(`family must be [a-zA-Z0-9_-]: ${family}`);
  if (actor === "crewchief" && existsSync(`${home()}/.ac-crewdeputy-home`)) actor = "crewdeputy";
  if (markerMalformed(text))
    die(
      `post: '${text}' opens with a GATE/ASK/DECIDED verb but is not well-formed (needs a colon, after an optional word and/or (parenthetical)) - fix the message; a malformed marker settles/opens nothing and can hang this room PENDING forever`,
    );
  if (continuationShaped(text))
    die(
      "post: a continuation line of the message has the shape of a room entry ('- [stamp] actor> ...') and every room reader would count it as its own entry - quote it indented or without the leading '- '",
    );
  if (
    GUARDED.some((v) => text.startsWith(v)) &&
    (process.env.AC_SCOPE ?? "") !== family &&
    process.env.AC_ROOM_PROMOTE_RECEIPT !== "1" &&
    // The bash subshell dropped only the probe's stderr; stdin and stdout
    // stayed post's.
    roomchiefLive(stateDir(), family, { stdin: "inherit", stdout })
  )
    die(
      `post: ${family} has a LIVE roomchief - its own TRIAGE/GATE/ASK/SELF-APPROVED/LANDED/HANDBACK/GATE-ROUTING/R1-DISPOSITION/DECIDED/STAGE-ADMISSION receipts belong to it, never to an unscoped caller (rooms-threads skill: 'Two chiefs on one family is a role violation, not extra help')`,
    );
  const f = `${dataDir()}/${family}/room.md`;
  if (!isDir(dirname(f))) {
    const s = run(["mkdir", "-p", dirname(f)], stdout, "inherit").status;
    if (s !== 0) process.exit(s);
  }
  try {
    if (!isFile(f)) writeFileSync(f, utf8(`# Room: ${family}\n\n`));
  } catch {
    process.exit(1);
  }
  const before = pendingSoft(f);
  const now = dateStamp(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]);
  if (now.status !== 0) process.exit(now.status);
  try {
    appendFileSync(f, Buffer.concat([utf8("- ["), latin1(now.stamp), utf8(`] ${actor}> ${text}\n`)]));
  } catch {
    process.exit(1);
  }
  const pending = pendingSoft(f);
  if (before === 0 && pending > 0) notify("crew blocked", `${family}: ${text}`, "ignore");
  const chief = `${family}-chief`;
  if (actor === chief && pending === 0 && !MARKERS.some((v) => text.startsWith(v)))
    warn(`post: ${chief} posted with no marker while ${family} has 0 pending - if you are actually waiting on the captain, post an ASK:/GATE: instead`);
  if (configReadSoft("remote-mirror", "off") === "on") {
    const verb = text.includes(":") ? text.slice(0, text.indexOf(":")) : text;
    let body = text.includes(": ") ? text.slice(text.indexOf(": ") + 2) : text;
    let head: string;
    // `[A-Z]*:*` read per the text: bash 3.2's range under a UTF-8 locale let
    // lowercase and accented letters through.
    if (/^[A-Z]/.test(text) && text.indexOf(":", 1) > 0) {
      const ts = vnTs();
      if (ts.status !== 0) process.exit(ts.status);
      head = `${verbEmoji(verb)} *[${ts.stamp}] [${verb}] [${family}]* ${actor}`;
    } else {
      const ts = vnTs();
      if (ts.status !== 0) process.exit(ts.status);
      head = `\u{1f4dd} *[${ts.stamp}] [${family}]* ${actor}`;
      body = text;
    }
    const sed = run(["sed", "-E", MIRROR_SED], "pipe", "inherit", utf8(`${body}\n`));
    if (sed.status !== 0) process.exit(sed.status);
    const lines = Buffer.concat([utf8(`${head}\n• `), latin1(subst(sed.out)), utf8("\n")]);
    const mention = text.startsWith("GATE:") || text.startsWith("ASK:") ? ["--mention-captain"] : [];
    if (run([`${STARTED_BIN}/ac-remote.sh`, "thread-post", family, ...mention], "ignore", "ignore", lines).status !== 0)
      warn(`room mirror to remote thread failed for ${family} (room entry saved)`);
  }
  if (isFile(taskMeta(chief))) {
    const r =
      pending > 0
        ? backendCall("mark_wait", [chief, `ĐANG CHỜ captain - ${pending} mục trong room ${family}`], { stdout, stderr: "ignore" })
        : backendCall("clear_wait", [chief], { stdout, stderr: "ignore" });
    if (r.exited) process.exit(r.status);
  }
  if (stdout === "inherit") out(`posted to ${f}\n`);
}

// --- the other verbs --------------------------------------------------------

function cmdHandback(args: string[]): void {
  const usage = "usage: ac-room.sh handback <family> <text...>";
  if (args.length < 1) die(usage);
  const family = args[0]!;
  const text = args.slice(1).join(" ");
  if (!family || !text) die(usage);
  const chief = `${family}-chief`;
  post([family, chief, `HANDBACK: ${text}`], "ignore");
  const sd = stateDir();
  let published = false;
  try {
    published = wakePublish(sd, "", "handback", bytes(chief), bytes(text), true);
  } catch (e) {
    process.exit((e as { status?: number }).status ?? 1);
  }
  if (!published) process.exit(1);
  out(`handback posted and queued for ${family} - ${watcherNudge(sd, "")}\n`);
}

function cmdPending(args: string[]): number {
  const family = args[0] ?? "";
  if (!family) die("usage: ac-room.sh pending <family>");
  const f = roomFile(family);
  if (!isFile(f)) {
    out("0\n");
    return 0;
  }
  try {
    out(`${roomPending(f)}\n`);
    return 0;
  } catch {
    grepRefusal(f);
    return 2;
  }
}

// `[ "$n" -gt 0 ]`: bash's integer - leading isspace, a sign, decimal digits,
// trailing blanks, inside 64 bits - above zero.
function positive(n: string): boolean {
  const m = /^[ \t\n\v\f\r]*([+-]?)([0-9]+)[ \t]*$/.exec(n);
  if (!m) return false;
  const v = BigInt(`${m[1]}${m[2]}`);
  return v > 0n && v <= 9223372036854775807n;
}

function cmdShow(args: string[]): number {
  const family = args[0] ?? "";
  const n = args[1] || "0";
  if (!family) die("usage: ac-room.sh show <family> [<n>]");
  const f = roomFile(family);
  if (!isFile(f)) die(`no room for ${family}`);
  if (positive(n)) {
    const h = run(["head", "-n", "2", f], "inherit", "inherit").status;
    if (h !== 0) return h;
    const g = run(["grep", "^- \\[", f], "pipe", "inherit");
    run(["tail", "-n", n], "inherit", "inherit", g.out);
    return 0;
  }
  return run(["cat", f], "inherit", "inherit").status;
}

// `IFS=$'\x1f' read -r pending hb family last`: a field per 0x1f; the last
// name keeps the rest of the line, less ONE trailing 0x1f when that is the
// only 0x1f left in it.
function readRow(line: string): [string, string, string, string] {
  const f: string[] = [];
  let rest = line;
  for (let i = 0; i < 3; i++) {
    const j = rest.indexOf("\x1f");
    if (j < 0) {
      f.push(rest);
      rest = "";
    } else {
      f.push(rest.slice(0, j));
      rest = rest.slice(j + 1);
    }
  }
  const j = rest.indexOf("\x1f");
  f.push(j === rest.length - 1 ? rest.slice(0, -1) : rest);
  return f as [string, string, string, string];
}

function cmdList(): void {
  const h = home();
  const data = `${h}/data`;
  let names: string[] = [];
  try {
    names = readdirSync(data);
  } catch {}
  const rooms = names
    .filter((n) => !n.startsWith("."))
    .sort((a, b) => Buffer.compare(utf8(a), utf8(b)))
    .map((n) => `${data}/${n}/room.md`)
    .filter((p) => {
      try {
        lstatSync(p);
        return true;
      } catch {
        return false;
      }
    });
  let found = false;
  if (rooms.length > 0 && isFile(rooms[0]!)) {
    const r = rowsOf(rooms, true);
    if ("error" in r) {
      writeSync(2, `ERROR: ${r.error}\n`);
      die("list: the room set could not be read - the inbox has no answer, not zero rooms");
    }
    const sd = utf8(`${h}/state/.ask-`);
    for (const line of r.text.replace(/\0/g, "").replace(/\n+$/, "").split("\n")) {
      const [pending, hb, family, whole] = readRow(line);
      if (!family) continue;
      found = true;
      const last = shellPrefix(whole, 120);
      const blocked = pending === "0" && existsSync(Buffer.concat([sd, latin1(family), utf8("-chief")]));
      const disp = blocked ? "1" : pending;
      const fam = `${family}\t${last}\n`;
      if (Number(disp) > 0 && hb === "1") out(latin1(`PENDING-CAPTAIN(${disp})+HANDBACK  ${fam}`));
      else if (blocked) out(latin1(`PENDING-CAPTAIN(${disp})+BLOCKED  ${fam}`));
      else if (Number(disp) > 0) out(latin1(`PENDING-CAPTAIN(${disp})  ${fam}`));
      else if (hb === "1") out(latin1(`HANDBACK            ${fam}`));
      else out(latin1(`ok                  ${fam}`));
    }
  }
  if (!found) out("(no rooms yet)\n");
}

function cmdClose(args: string[]): void {
  const family = args[0] ?? "";
  const outcome = args.length > 1 ? args.slice(1).join(" ") : "landed";
  if (!family) die("usage: ac-room.sh close <family> <outcome...>");
  const f = `${softSubdir("data", true)}/${family}/room.md`;
  if (!isFile(f)) die(`no room for ${family}`);
  const sd = stateDir();
  let metas: string[] = [];
  try {
    metas = readdirSync(sd);
  } catch {}
  metas = metas.filter((n) => !n.startsWith(".") && n.endsWith(".meta")).sort((a, b) => Buffer.compare(utf8(a), utf8(b)));
  for (const n of metas) {
    const m = `${sd}/${n}`;
    if (!existsSync(m) || metaIsVerify(m)) continue;
    const other = n.slice(0, -".meta".length);
    const scoped = (): boolean => {
      try {
        return metaGet(m, "fleet_scope") === bytes(family);
      } catch {
        return false;
      }
    };
    if (other === `${family}-chief` || familyOfId(other) === family || scoped()) die(`close: ${other} is still in flight`);
  }
  let pending = -1;
  try {
    pending = roomPending(f);
  } catch {
    grepRefusal(f);
  }
  if (pending !== 0) die(`close: room ${family} still has pending gates/asks (answer them first)`);
  const now = dateStamp(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]);
  try {
    appendFileSync(f, Buffer.concat([utf8("- ["), latin1(now.stamp), utf8(`] crewchief> CLOSED: ${outcome}\n`)]));
  } catch {
    process.exit(1);
  }
  const spool = wakeSpoolPath(stateDir(), family);
  if (isDir(spool)) {
    if (spoolHasRecord(spool)) warn(`close: ${family}'s wake spool (${spool}) still holds undrained records - not removing it`);
    else
      try {
        rmdirSync(spool);
      } catch {
        warn(`close: ${family}'s wake spool (${spool}) could not be removed`);
      }
  }
  out(`room ${family} closed: ${outcome}\n`);
}

function cmdOpen(args: string[]): void {
  const family = args[0] ?? "";
  if (!family) die("usage: ac-room.sh open <family>");
  const chief = `${family}-chief`;
  if (!isFile(taskMeta(chief)))
    die(`room ${family} is not promoted (no ${chief} in flight); promote with ac-spawn.sh --roomchief ${family}, or keep talking here`);
  // taskBackend answers bytes; AC_BACKEND carries the text they spell, as the
  // shell's export did.
  process.env.AC_BACKEND = latin1(taskBackend(chief)).toString("utf8");
  const io = { stdout: "inherit", stderr: "inherit" } as const;
  const target = (): string => subst(backendCall("target", [chief], { stdout: "pipe", stderr: "inherit" }).out);
  const alive = backendCall("window_alive", [chief], io);
  if (alive.exited) process.exit(alive.status);
  if (alive.status === 1) die(`roomchief window is gone; respawn (--roomchief ${family}) or teardown ${chief}`);
  if (alive.status !== 0)
    die(
      latin1(
        `${bytes(`the BACKEND could not be READ for ${chief} - whether `)}${target()}${bytes(" still exists is UNKNOWN, so this is NOT treated as gone; check the backend itself (herdr status server), then try again")}`,
      ),
    );
  const focus = backendCall("focus", [chief], io);
  if (focus.exited) process.exit(focus.status);
  if (focus.status !== 0) die(`could not focus ${chief}`);
  out(latin1(`focused ${bytes(chief)} (${target()})\n`));
}

// --- the receipt verbs: the WRITER-side twins of src/gate.ts's readers
// (tests/sh/ac-gate.test.sh's WRITER/READER PARITY matrix) ------------------

// A Map, never an object literal: a stage named `__proto__` must find nothing.
const STAGES = new Map([["spec", "spec"], ["architecture", "arch"], ["plan", "plan"], ["design", "design"]]);

export const REVIEW_BODY = "BEGIN{fm=0} /^---[[:space:]]*$/{fm++; next} fm>=2{print}";
export const R1_IDS = `
    /^## Required Changes[[:space:]]*$/ { insec=1; next }
    insec && /^## / { exit }
    insec && /^[[:space:]]*[0-9]+\\./ {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      sub(/\\..*/, "", line)
      print line
    }`;
export const NORMALIZE_IDS = `
    BEGIN {
      if (raw == "none") { print "none"; exit 0 }
      n = split(raw, a, ",")
      if (n < 1) exit 1
      for (i = 1; i <= n; i++) {
        if (a[i] !~ /^[0-9]+$/) exit 1
        id = a[i] + 0
        if (seen[id]) exit 1
        seen[id] = 1
        if (id > max) max = id
      }
      out = ""
      for (i = 1; i <= max; i++) {
        if (!seen[i]) continue
        out = out (out ? "," : "") i
      }
      if (out == "") exit 1
      print out
    }`;
export const PARTITION = `
    function load(list, arr, label,    n, a, i) {
      if (list == "none") return 0
      n = split(list, a, ",")
      for (i = 1; i <= n; i++) {
        if (arr[a[i]]) exit 1
        arr[a[i]] = 1
      }
      return n
    }
    BEGIN {
      if (expected == "") exit 1
      load(expected, expected_map, "expected")
      ac = load(accepted, acc, "accepted")
      dc = load(disputed, dis, "disputed")
      for (id in acc) {
        if (!(id in expected_map)) exit 1
        if (id in dis) exit 1
      }
      for (id in dis) if (!(id in expected_map)) exit 1
      for (id in expected_map) if (!(id in acc) && !(id in dis)) exit 1
      if (dc == 0 && authority == "none") exit 0
      if (dc == 0 && authority != "none") exit 1
      if (dc > 0 && authority == "none") exit 1
      if (authority == "chief-owned" || authority == "captain-owned" || authority == "mixed") exit 0
      exit 1
    }`;

// The flag loop: a value flag takes the next word (absent: usage), --grounds
// takes every word after it, joined, and ends the loop; the last of a
// repeated flag wins.
function receiptArgs(args: string[], usage: string, flags: string[]): { family: string; stage: string; v: Map<string, string>; grounds: string } {
  if (args.length < 2) die(usage);
  const v = new Map(flags.map((k) => [k, ""]));
  let grounds = "";
  for (let i = 2; i < args.length; ) {
    const a = args[i]!;
    if (a === "--grounds") {
      grounds = args.slice(i + 1).join(" ");
      break;
    }
    if (!flags.includes(a) || i + 2 > args.length) die(usage);
    v.set(a, args[i + 1]!);
    i += 2;
  }
  return { family: args[0]!, stage: args[1]!, v, grounds };
}

const blank = (g: string): boolean => g.replace(shellSpaceClass(), "") === "";

// `[ -s "$f" ] && [ ! -L "$f" ]`
function plainNonEmpty(f: string): boolean {
  try {
    return statSync(f).size > 0 && !lstatSync(f).isSymbolicLink();
  } catch {
    return false;
  }
}

// `"$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"`
const physical = (f: string): string => `${physicalDir(dirname(f)) ?? ""}/${basename(f)}`;

function sha(f: string): string {
  try {
    return sha256File(f);
  } catch {
    process.exit(1);
  }
}

function receiptChecks(verb: string, family: string, stage: string, grounds: string): string {
  if (/[\n\r]/.test(grounds)) die(`${verb} grounds must be one physical line`);
  if (/[^a-zA-Z0-9_-]/.test(family)) die(`family must be [a-zA-Z0-9_-]: ${family}`);
  return STAGES.get(stage) ?? "";
}

function cmdGateVerify(args: string[]): void {
  const usage = "usage: ac-room.sh gate-verify <family> <stage> --round <1|2> --report <file> --grounds <text...>";
  const { family, stage, v, grounds } = receiptArgs(args, usage, ["--round", "--report"]);
  const [round, report] = [v.get("--round")!, v.get("--report")!];
  if (!family || !stage || !round || !report || blank(grounds)) die(usage);
  const short = receiptChecks("gate-verify", family, stage, grounds);
  if (round !== "1" && round !== "2") die("gate-verify --round must be 1 or 2");
  if (!short) die("gate-verify stage must be spec|architecture|plan|design");
  if (!plainNonEmpty(report)) die("gate-verify --report must name a non-empty plain file");
  const phys = physical(report);
  const expected = `${dataDir()}/${family}/${short}/report.md`;
  if (phys !== expected) die(`gate-verify --report must be ${expected}`);
  post([family, `${family}-chief`, `GATE-VERIFY: stage=${stage} round=${round} report_sha256=${sha(phys)} verdict=pass grounds=${grounds}`], "inherit");
}

function cmdGateRoute(args: string[]): void {
  const usage =
    "usage: ac-room.sh gate-route <family> <stage> --report <file> --uncertainty <yes|no> --consequence <low|high> --authority <chief|captain> --grounds <text...>";
  const { family, stage, v, grounds } = receiptArgs(args, usage, ["--report", "--uncertainty", "--consequence", "--authority"]);
  const [report, uncertainty, consequence, authority] = [v.get("--report")!, v.get("--uncertainty")!, v.get("--consequence")!, v.get("--authority")!];
  if (!family || !stage || !report || !uncertainty || !consequence || !authority || blank(grounds)) die(usage);
  const short = receiptChecks("gate-route", family, stage, grounds);
  if (uncertainty !== "yes" && uncertainty !== "no") die("gate-route --uncertainty must be yes|no");
  if (consequence !== "low" && consequence !== "high") die("gate-route --consequence must be low|high");
  if (authority !== "chief" && authority !== "captain") die("gate-route --authority must be chief|captain");
  if (!short) die("gate-route stage must be spec|architecture|plan|design");
  if (!plainNonEmpty(report)) die("gate-route --report must name a non-empty plain file");
  const phys = physical(report);
  const expected = `${dataDir()}/${family}/${short}/report.md`;
  if (phys !== expected) die(`gate-route --report must be ${expected}`);
  const route = authority === "captain" ? "captain" : uncertainty === "yes" || consequence === "high" ? "second-chief" : "chief";
  post(
    [
      family,
      `${family}-chief`,
      `GATE-ROUTING: stage=${stage} report_sha256=${sha(phys)} uncertainty=${uncertainty} consequence=${consequence} authority=${authority} route=${route} grounds=${grounds}`,
    ],
    "inherit",
  );
}

// A bare `x="$(a | b | c)"` under pipefail: each stage's stderr passes, the
// rightmost failure ends the run with its status.
function pipeline(stages: string[][], file: string): string {
  let data: Buffer | null = null;
  let status = 0;
  for (const argv of stages) {
    const r = data === null ? run([...argv, file], "pipe", "inherit") : run(argv, "pipe", "inherit", data);
    if (r.status !== 0) status = r.status;
    data = r.out;
  }
  if (status !== 0) process.exit(status);
  return subst(data!);
}

function cmdDisposition(args: string[]): void {
  const usage =
    "usage: ac-room.sh disposition <family> <stage> --r1 <file> --accepted <ids|none> --disputed <ids|none> --authority <chief-owned|captain-owned|mixed|none> --grounds <text...>";
  const { family, stage, v, grounds } = receiptArgs(args, usage, ["--r1", "--accepted", "--disputed", "--authority"]);
  const [r1, accepted, disputed, authority] = [v.get("--r1")!, v.get("--accepted")!, v.get("--disputed")!, v.get("--authority")!];
  if (!family || !stage || !r1 || !accepted || !disputed || !authority || blank(grounds)) die(usage);
  const short = receiptChecks("disposition", family, stage, grounds);
  if (!short) die("disposition stage must be spec|architecture|plan|design");
  if (!["chief-owned", "captain-owned", "mixed", "none"].includes(authority)) die("disposition authority must be chief-owned|captain-owned|mixed|none");
  if (!plainNonEmpty(r1)) die("disposition --r1 must name a non-empty plain file");
  const r1phys = physical(r1);
  const expectedR1 = `${dataDir()}/${family}/${short}/second-chief-r1.md`;
  if (r1phys !== expectedR1) die(`disposition --r1 must be ${expectedR1}`);
  const expectedReport = `${dataDir()}/${family}/${short}/report.md`;
  if (!plainNonEmpty(expectedReport)) die(`disposition requires a non-empty current report at ${expectedReport}`);
  const report = physical(expectedReport);
  const expected = pipeline([["awk", REVIEW_BODY], ["awk", R1_IDS], ["paste", "-sd,", "-"]], r1phys);
  if (!expected) die("disposition R1 has no numbered Required Changes to adjudicate");
  const normalize = (raw: string, flag: string): string => {
    const r = run(["awk", "-v", `raw=${raw}`, NORMALIZE_IDS], "pipe", "inherit");
    if (r.status !== 0) die(`disposition --${flag} must be comma-separated numeric ids or none`);
    return subst(r.out);
  };
  const acc = normalize(accepted, "accepted");
  const dis = normalize(disputed, "disputed");
  const vars = [`expected=${expected}`, `accepted=${acc}`, `disputed=${dis}`, `authority=${authority}`].flatMap((a) => ["-v", a]);
  if (run(["awk", ...vars, PARTITION], "ignore", "inherit").status !== 0)
    die("disposition accepted/disputed ids must exactly partition R1 Required Changes, with valid authority");
  post(
    [
      family,
      `${family}-chief`,
      `R1-DISPOSITION: stage=${stage} r1_sha256=${sha(r1phys)} report_sha256=${sha(report)} accepted=${acc} disputed=${dis} authority=${authority} grounds=${grounds}`,
    ],
    "inherit",
  );
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  out(`${head.join("\n")}\n`);
  process.exit(2);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  const [verb = "", ...rest] = args;
  if (verb === "rows") cmdRows(args, atCaller);
  else {
    backendName();
    switch (verb) {
      case "post":
        post(rest, "inherit");
        break;
      case "show":
        process.exit(cmdShow(rest));
      case "list":
        cmdList();
        break;
      case "close":
        cmdClose(rest);
        break;
      case "open":
        cmdOpen(rest);
        break;
      case "pending":
        process.exit(cmdPending(rest));
      case "handback":
        cmdHandback(rest);
        break;
      case "gate-route":
      case "route-gate":
        cmdGateRoute(rest);
        break;
      case "gate-verify":
      case "verify-gate":
        cmdGateVerify(rest);
        break;
      case "disposition":
        cmdDisposition(rest);
        break;
      default:
        usage();
    }
  }
}
