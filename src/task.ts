// task.ts <verb> - every ROUTINE mutation of records/backlog.md as a verb
// instead of a model rewriting markdown. The entry is bin/ac-task.sh (a shim
// that execs this file through bin/ac-bun.sh); THIS header is the
// authoritative spec for the verbs, the lock, the body block and the archives.
// The LINE grammar itself stays owned by docs/backlog.md + src/backlog.ts, and
// the contract vocabulary by contractLint (src/lib.ts). This module EMITS what
// they parse and never invents a second dialect.
//
//   ac-task.sh add <id> <one-line> [--contract '<tokens>'] [--repo <name>]
//   ac-task.sh start <id>                 # Queued -> In flight, stamps `since`;
//                                         # refuses while a blocker is not clean Done
//   ac-task.sh done <id> <outcome> [--verb merged|reported|...]
//   ac-task.sh hold <id> [--until <YYYY-MM-DD>] [--why <text>]
//   ac-task.sh unhold <id>
//   ac-task.sh update-note <id> <text>    # the row's BODY, off the line
//   ac-task.sh prune [--keep <n>]         # Done tail -> dated archive
//
// Exit status: 0 on an ok: or already: receipt, 1 on a refusal (ERROR: on
// stderr, nothing written), 2 on a missing or unknown verb (this text). A
// verb signalled while it holds the lock finishes its write, releases the
// lock and exits 128 + the signal number.
//
// Arguments must be UTF-8 text: Bun decodes argv with replacement, so bytes
// that are not UTF-8 arrive as U+FFFD, and an argument carrying one is refused
// rather than written as text no caller typed.
//
// THREE PROPERTIES ARE THE POINT:
//
// 1. LOCKED ATOMIC WRITES. Every verb takes the advisory lock
//    `records/.backlog.md.lock` (the lock dir ac_lock_acquire takes, through
//    its twin lockAcquire; AC_TASK_LOCK_TIMEOUT secs, default 10), RE-READS
//    the file inside it, and publishes by tmp+rename, the tmp a `cp -p` of
//    the ledger so its mode, group, ACL and xattrs survive. Several live
//    sessions measurably write one ledger in a day and the
//    harness Edit path has no guard; a refused write changes nothing.
//
// 2. BODY OFF THE LINE. A row's narrative rides as INDENTED lines (two spaces)
//    directly under its bullet - the LINE stays the index, so AC_DONELINE_AWK
//    and every scheduler reading it are untouched, and a body is opaque to all
//    of them. The body moves with its row through start/done/prune, and a
//    replaced body is appended to `records/backlog-body-archive.md` rather
//    than dropped.
//
// 3. HOLD-UNTIL. `[@held until <YYYY-MM-DD>]` is the dated arm of the captain
//    hold: HELD before the date, READY on and after it, with no hand-edit to
//    release. The bare `[@held]` is unchanged and still needs a captain act.
//    A malformed date fails CLOSED (HELD) exactly like every other hold slip.
//
// RESIDUAL: `hold --why <text>` appends the reason as ordinary prose at the end
// of the line, where docs/backlog.md puts it, and `unhold` removes the
// TOKEN only - the prose stays, because nothing on disk records which trailing
// words were the hold's. A chief that wants the stale reason gone edits it.
//
// HAND-EDITING STAYS LEGAL. This module owns no state of its own: it re-reads
// the file on every verb and tolerates rows nobody here wrote - a row is found
// by the id src/backlog.ts reads off it, and an unterminated last line is a
// line like any other. Every verb is IDEMPOTENT - a re-run prints `already:`
// and writes nothing - and prints one receipt line per call.
//
// The chief-only fence is unchanged: a scoped session is refused by
// bin/ac-ledger-guard.sh whichever path it writes through.

import { appendFileSync, existsSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { acDoneline, records } from "./backlog.ts";
import { contractLint, enterCaller, lockAcquire, lockRelease, recordsDir } from "./lib.ts";

// The ledger is bytes (latin1, one character per byte), and so is every
// argument written into it or echoed back from it.
const bytes = (s: string) => Buffer.from(s, "latin1");
const say = (s: string) => writeSync(1, bytes(`${s}\n`));
// A path is a UTF-8 string, so it is shown as its UTF-8 bytes.
const shown = (p: string) => Buffer.from(p, "utf8").toString("latin1");

function fail(msg: string): never {
  writeSync(2, bytes(`ERROR: ${msg}\n`));
  process.exit(1);
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(2);
}

const { args } = enterCaller(process.argv.slice(2));
const recs = recordsDir();
const ledger = join(recs, "backlog.md");
const lockdir = join(recs, ".backlog.md.lock");
// date(1), not Date: ICU misreads POSIX TZ strings, and src/ready.ts decides a
// dated hold is spent by date(1) too.
const today = Bun.spawnSync(["date", "+%Y-%m-%d"]).stdout.toString().trim();

// --- ledger buffer ------------------------------------------------------------

let L: string[] = [];

function load(): void {
  let isFile = false;
  try {
    isFile = statSync(ledger).isFile();
  } catch {}
  if (!isFile) fail(`no ledger at ${shown(ledger)}`);
  let text: string;
  try {
    text = readFileSync(ledger).toString("latin1");
  } catch {
    fail(`cannot read ${shown(ledger)}`);
  }
  // The parser's own line split: every reader already stopped a line at its
  // first NUL, so a write keeps exactly the text they all saw.
  L = records(text);
}

// A failed write names its file and leaves no temp copy behind.
function writing(path: string, act: () => void): void {
  try {
    act();
  } catch (e) {
    fail(`cannot write ${shown(path)}: ${(e as { code?: string }).code ?? e}`);
  }
}

// `cp -p` first, then the content into that copy: the published ledger keeps
// its mode, group, ACL and xattrs, the copy is never readable wider than the
// ledger, and a read-only ledger refuses the write.
function save(): void {
  const tmp = `${ledger}.${process.pid}`;
  writing(ledger, () => {
    try {
      const cp = Bun.spawnSync(["cp", "-p", ledger, tmp]);
      if (cp.exitCode !== 0) throw new Error(cp.stderr.toString().trim());
      writeFileSync(tmp, bytes(L.length ? L.map((l) => `${l}\n`).join("") : "\n"));
      renameSync(tmp, ledger);
    } catch (e) {
      rmSync(tmp, { force: true });
      throw e;
    }
  });
}

let rowI = -1;
let rowEnd = -1;
let rowSec = "";

// A row is its bullet plus the indented body lines under it.
function findRow(want: string): boolean {
  let sec = "";
  rowI = -1;
  rowEnd = -1;
  rowSec = "";
  for (let i = 0; i < L.length; i++) {
    const l = L[i];
    if (l.startsWith("## In flight")) sec = "inflight";
    else if (l.startsWith("## Queued")) sec = "queued";
    else if (l.startsWith("## Done")) sec = "done";
    else if (l.startsWith("## ")) sec = "";
    else if ((l.startsWith("- [ ] ") || l.startsWith("- [x] ")) && acDoneline(l).id === want) {
      rowI = i;
      rowSec = sec;
      break;
    }
  }
  if (rowI < 0) return false;
  rowEnd = rowI;
  while (rowEnd + 1 < L.length && L[rowEnd + 1].startsWith("  ")) rowEnd++;
  return true;
}

function sectionHead(want: "inflight" | "queued" | "done"): number {
  const title = { inflight: "## In flight", queued: "## Queued", done: "## Done" }[want];
  const i = L.findIndex((l) => l.startsWith(title));
  if (i < 0) fail(`ledger has no '${want}' section`);
  return i;
}

// The index to insert a row AT so it lands LAST in the section: past its final
// row's body, before the blank line that separates it.
function sectionTail(want: "inflight" | "queued" | "done"): number {
  const head = sectionHead(want);
  let last = head + 1;
  for (let i = head + 1; i < L.length; i++) {
    if (L[i].startsWith("## ")) break;
    if (L[i] !== "") last = i + 1;
  }
  return last;
}

// The surgery half of what the parser judges: the AUTHORITATIVE hold token is
// found by walking the leading run of [...] groups after the id with the
// parser's own position rule (src/backlog.ts), so a quoted or out-of-run shape
// is never found here.
function splitHold(l: string): { pre: string; grp: string; post: string } | null {
  const head = /^- \[[ x]\] [^ \t]+/.exec(l);
  if (!head) return null;
  let at = head[0].length;
  for (;;) {
    const ws = /^[ \t]*/.exec(l.slice(at))![0];
    const grp = /^\[[^\][]*\]/.exec(l.slice(at + ws.length))?.[0];
    if (grp === undefined) return null;
    if (/^\[@held( until [0-9]{4}-[0-9]{2}-[0-9]{2})?\]$/.test(grp)) {
      return { pre: l.slice(0, at + ws.length - (ws === "" ? 0 : 1)), grp, post: l.slice(at + ws.length + grp.length) };
    }
    at += ws.length + grp.length;
  }
}

function holdOf(id: string, line: string, fix: string) {
  const f = acDoneline(line);
  if (f.hold_malformed !== "") fail(`${id} carries a malformed hold-shaped group - fix the line by hand${fix} (docs/backlog.md)`);
  return f;
}

// The first of the row's blockers that is not a clean Done row, as `<blocker>
// (<why>)`, or `blocked-by malformed`; empty when the row may start. The same
// rule src/ready.ts schedules by (docs/backlog.md), enforced here because the
// scheduler only advises. It reads the buffer the verb may already have edited.
function unresolvedBlocker(want: string): string {
  const state = new Map<string, string>();
  const mark = new Map<string, string>();
  let blockers = "";
  let malformed = "";
  let sec = "";
  for (const l of L) {
    if (l.startsWith("## In flight")) sec = "in flight";
    else if (l.startsWith("## Queued")) sec = "queued";
    else if (l.startsWith("## Done")) sec = "done";
    else if (l.startsWith("## ")) sec = "";
    else if (/^- \[[ x]\] /.test(l)) {
      const f = acDoneline(l);
      state.set(f.id, sec);
      mark.set(f.id, f.terminal);
      if (f.id === want) {
        blockers = f.blockers;
        malformed = f.blockers_malformed;
      }
    }
  }
  if (malformed !== "") return "blocked-by malformed";
  for (const b of blockers === "" ? [] : blockers.split(",")) {
    if (!state.has(b)) return `${b} (missing)`;
    const m = mark.get(b)!;
    if (m === "failed" || m === "abandoned") return `${b} (${m})`;
    if (state.get(b) !== "done") return `${b} (${state.get(b) || "no section"})`;
  }
  return "";
}

function stampSince(l: string): string {
  if (l.includes(", since ")) return l;
  const k = l.indexOf("(repo: ");
  if (k < 0) return `${l} (since ${today})`;
  const tail = l.slice(k + "(repo: ".length);
  const c = tail.indexOf(")");
  const [grp, after] = c < 0 ? [tail, tail] : [tail.slice(0, c), tail.slice(c + 1)];
  return `${l.slice(0, k)}(repo: ${grp}, since ${today})${after}`;
}

function flags(words: string[], known: string[]): Map<string, string> {
  const got = new Map<string, string>();
  for (let i = 0; i < words.length; i += 2) {
    if (!known.includes(words[i])) fail(`unknown flag: ${words[i]}`);
    if (i + 1 >= words.length) fail(`${words[i]} needs a value`);
    got.set(words[i], words[i + 1]);
  }
  return got;
}

// --- verbs --------------------------------------------------------------------

function add(id = "", text = "", ...rest: string[]): void {
  if (id === "" || text === "") fail("usage: ac-task.sh add <id> <one-line> [--contract <tokens>] [--repo <name>]");
  const f = flags(rest, ["--contract", "--repo"]);
  const contract = f.get("--contract") ?? "";
  const repo = f.get("--repo") ?? "";
  if (!/^[a-z0-9-]+$/.test(id)) fail(`invalid id '${id}' - want [a-z0-9-]`);
  const violations = contractLint(contract);
  if (violations.length) fail(`invalid contract: ${violations.join("\n")}`);
  load();
  if (findRow(id)) return void say(`already: ${id} exists in ${rowSec || "no section"}`);
  let line = `- [ ] ${id}`;
  if (contract !== "") line += ` [${contract}]`;
  line += ` - ${text}`;
  if (repo !== "") line += ` (repo: ${repo})`;
  L.splice(sectionTail("queued"), 0, line);
  save();
  say(`ok: added ${id} to Queued`);
}

function start(id = ""): void {
  if (id === "") fail("usage: ac-task.sh start <id>");
  load();
  if (!findRow(id)) fail(`no row for '${id}'`);
  if (rowSec !== "queued") return void say(`already: ${id} is in ${rowSec || "no section"}`);
  const f = holdOf(id, L[rowI], "");
  let spent = "";
  if (f.hold !== "") {
    // An EXPIRED dated hold is exactly what ac-ready offers as READY, so start
    // must take it; the spent token is stripped - the date WAS the release,
    // and a leftover [@held...] on an In-flight line would still read as
    // waiting-on-captain in every display.
    if (f.hold_until === "" || f.hold_until > today) fail(`${id} is held - release it before starting (docs/backlog.md)`);
    const h = splitHold(L[rowI]);
    if (!h) fail(`internal: parser saw a hold that the leading-run walk cannot find on: ${L[rowI]}`);
    L[rowI] = h.pre + h.post;
    spent = ` (hold until ${f.hold_until} expired - token stripped)`;
  }
  const blocker = unresolvedBlocker(id);
  if (blocker !== "") fail(`${id} is blocked: ${blocker} - it starts only once every blocker is a clean Done row (docs/backlog.md)`);
  const block = L.splice(rowI, rowEnd - rowI + 1);
  block[0] = stampSince(block[0]);
  L.splice(sectionTail("inflight"), 0, ...block);
  save();
  say(`ok: started ${id} (since ${today})${spent}`);
}

function done(id = "", outcome = "", ...rest: string[]): void {
  if (id === "" || outcome === "") fail("usage: ac-task.sh done <id> <outcome> [--verb <verb>]");
  const verb = flags(rest, ["--verb"]).get("--verb") ?? "merged";
  if (!/^[a-z]+$/.test(verb)) fail(`invalid --verb '${verb}' - want a word like merged|reported`);
  load();
  if (!findRow(id)) fail(`no row for '${id}'`);
  if (rowSec === "done") return void say(`already: ${id} is Done`);
  const block = L.splice(rowI, rowEnd - rowI + 1);
  const bare = block[0].startsWith("- [ ] ") ? block[0].slice("- [ ] ".length) : block[0];
  block[0] = `- [x] ${bare} - ${outcome} (${verb} ${today})`;
  L.splice(sectionHead("done") + 1, 0, ...block);
  save();
  say(`ok: ${verb} ${id} (${verb} ${today})`);
}

function hold(id = "", ...rest: string[]): void {
  if (id === "") fail("usage: ac-task.sh hold <id> [--until <YYYY-MM-DD>] [--why <text>]");
  const f = flags(rest, ["--until", "--why"]);
  const until = f.get("--until") ?? "";
  const why = f.get("--why") ?? "";
  if (until !== "" && !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(until)) fail(`invalid --until date '${until}' - want YYYY-MM-DD`);
  const token = until !== "" ? `[@held until ${until}]` : "[@held]";
  load();
  if (!findRow(id)) fail(`no row for '${id}'`);
  if (rowSec === "done") fail(`${id} is Done - a hold schedules nothing`);
  holdOf(id, L[rowI], " before re-holding");
  const h = splitHold(L[rowI]);
  let line = h ? h.pre + h.post : L[rowI];
  // The id goes right after the checkbox, where the parser places a hold.
  const idEnd = /^- \[[ x]\] [ \t]*[^ \t]+/.exec(line)![0].length;
  line = `${line.slice(0, 5)} ${id} ${token}${line.slice(idEnd)}`;
  if (why !== "" && !line.includes(` - ${why}`)) line += ` - ${why}`;
  if (line === L[rowI]) return void say(`already: ${id} holds ${token}`);
  L[rowI] = line;
  save();
  say(`ok: held ${id} ${token}`);
}

function unhold(id = ""): void {
  if (id === "") fail("usage: ac-task.sh unhold <id>");
  load();
  if (!findRow(id)) fail(`no row for '${id}'`);
  if (holdOf(id, L[rowI], "").hold === "") return void say(`already: ${id} carries no hold`);
  const h = splitHold(L[rowI]);
  if (!h) fail(`internal: parser saw a hold that the leading-run walk cannot find on: ${L[rowI]}`);
  L[rowI] = h.pre + h.post;
  save();
  say(`ok: released ${id} from ${h.grp}`);
}

function updateNote(id = "", text = ""): void {
  if (id === "" || text === "") fail("usage: ac-task.sh update-note <id> <text>");
  load();
  if (!findRow(id)) fail(`no row for '${id}'`);
  const old = L.slice(rowI + 1, rowEnd + 1);
  const body = text.split("\n").map((l) => `  ${l}`);
  if (old.length === body.length && old.every((l, i) => l === body[i])) return void say(`already: ${id} carries this body`);
  const arc = join(recs, "backlog-body-archive.md");
  if (old.length) writing(arc, () => appendFileSync(arc, bytes(`\n## ${id} body replaced ${today}\n${old.map((l) => `${l}\n`).join("")}`)));
  L.splice(rowI + 1, old.length, ...body);
  save();
  say(`ok: body updated on ${id} (${body.length} line(s), ${old.length} archived)`);
}

function prune(...rest: string[]): void {
  const keep = flags(rest, ["--keep"]).get("--keep") ?? "20";
  if (!/^[0-9]+$/.test(keep)) fail(`invalid --keep '${keep}' - want a count`);
  load();
  const head = sectionHead("done");
  // end = one past the Done section: the grammar puts Done last, but
  // hand-editing stays legal, so a section someone added after it must
  // survive a prune untouched rather than being swept into the archive.
  let end = L.findIndex((l, i) => i > head && l.startsWith("## "));
  if (end < 0) end = L.length;
  let seen = 0;
  let cut = -1;
  for (let i = head + 1; i < end && cut < 0; i++) {
    if (L[i].startsWith("- [") && ++seen > Number(keep)) cut = i;
  }
  if (cut < 0) return void say(`already: Done holds ${seen} row(s), keep is ${keep}`);
  const arc = join(recs, `backlog-archive-${today}.md`);
  const moved = L.splice(cut, end - cut);
  writing(arc, () => {
    if (!existsSync(arc)) writeFileSync(arc, `# backlog Done rows pruned ${today}\n`);
    appendFileSync(arc, bytes(moved.map((l) => `${l}\n`).join("")));
  });
  save();
  say(`ok: pruned ${moved.filter((l) => l.startsWith("- [")).length} Done row(s) into ${shown(arc)}`);
}

// --- dispatch -----------------------------------------------------------------

const verbs: Record<string, (...a: string[]) => void> = { add, start, done, hold, unhold, "update-note": updateNote, prune };
const [verb = "", ...rest] = args.map((a) => Buffer.from(a, "utf8").toString("latin1"));
if (!Object.hasOwn(verbs, verb)) usage();
if (args.some((a) => a.includes("\ufffd"))) fail("an argument is not valid UTF-8 text - nothing written");
if (!lockAcquire(lockdir, Number(process.env.AC_TASK_LOCK_TIMEOUT || "10"))) fail("records/backlog.md is locked by another writer - nothing written");
process.on("exit", () => lockRelease(lockdir));
// A signal's default action ends the process before any exit handler runs and
// leaves the lock behind; handled, it waits for the synchronous verb to finish.
for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) process.on(sig, () => process.exit(128 + n));
verbs[verb](...rest);
