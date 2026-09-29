// ready.ts - the ledger half of bin/ac-ready.sh: its default report and the
// queued, watch-set and validate verbs. That script's header is the spec: it
// doubles as the usage text, and `overlap`, glue around git and ac-jev, stays
// bash there. The ledger is read as bytes (latin1, one character per byte), so
// a byte that is not UTF-8 is prose like any other and no locale can abort the
// walk; every field comes from acDoneline, the one row parser.

import { readFileSync, statSync, writeSync } from "node:fs";
import { join } from "node:path";
import { acDoneline, records } from "./backlog.ts";
import { configRead, contractLint, die, enterCaller, recordsDir } from "./lib.ts";

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

const { args } = enterCaller(process.argv.slice(2));
const backlog = join(recordsDir(), "backlog.md");
let isFile = false;
try {
  isFile = statSync(backlog).isFile();
} catch {}
if (!isFile) process.exit(0);
const capText = configRead("epic-parallel", "2");
const cap = /^[0-9]+$/.test(capText) ? Number(capText) : 2;
const [verb = "", arg = ""] = args;
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
const now = new Date();
const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
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
