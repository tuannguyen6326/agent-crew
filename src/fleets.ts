// fleets.ts - READ-ONLY cross-fleet overview: for every fleet home under the
// homes container, one compact status block (text), the same survey as one
// JSON document (--json), or the home paths alone (--paths), so the captain
// surveys every fleet without visiting each one. The entry is bin/ac-fleets.sh
// (a shim that starts this file through bin/ac-bun.sh); THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-fleets.sh as the oracle the differential leg of
// tests/sh/ac-fleets.test.sh holds this module to.
//
//   ac-fleets.sh [--json | --paths] [<container>]
//   ac-fleets.sh -h | --help
//
// ARGS are scanned in order: `--json` / `--paths` set the mode (the last one
// wins, anywhere); `-h`/`--help` prints this header to stdout and exits 0 the
// moment it is seen; any other word - an unknown `--flag` included - is the
// container when none was taken yet, later words are ignored. stdin is never
// read. EXIT 0 on every surveyed path: a missing container, a regular file as
// container and an unreadable room set all exit 0 with their text. Nothing of
// its own goes to stderr (`ac-room.sh list`'s stderr is discarded; an
// unreadable meta carries ac_meta_get's WARN). In TEXT mode a per-home read
// that fails - a meta, a status or the watcher owner this user cannot read
// (config/captain was the one read the original guarded: "" in every mode) -
// ends the run with exit 1 after what was printed so far
// (the header, every earlier home, and the blank line or the parent's block
// before the dying home), as `set -e` ended the original on that assignment;
// in --json the same reads sit inside the original's command substitutions,
// where errexit sleeps, so the value reads "" and the survey goes on.
//
// CONTAINER (first hit wins): the <container> argument > $AC_HOMES_CONTAINER >
// `cd "$AC_HOME/.." && pwd -P` when AC_HOME is set (a symlinked AC_HOME gives
// the LINK's parent, as cd's logical walk does) > $HOME/Work/ac-homes. The hit
// is resolved `cd && pwd -P` (physicalDir); one that cannot be entered -
// missing, a regular file - is "not found".
//
// HOMES: the container's non-dot child directories (a symlink to one counts)
// holding data/, state/ or config/, in BYTE order of their names; a non-home
// child is skipped silently. Crewdeputy homes at <home>/crewdeputies/<name>
// are surveyed the same way, recursively, one indent deeper, down to depth 6
// (a depth-7 home prints nothing in text mode and poisons --json, below).
//
// Per home (text; --json carries the same readings as fields):
//   crew    - every state/<id>.meta (non-dot, byte order; a dangling symlink
//             skipped), id = the name less `.meta`, kind/project/mode by
//             ac_meta_get (metaGet: last key wins), status = the last line of
//             state/<id>.status after its first space (`tail -n1 | cut -d' '
//             -f2-`: a line with no space passes whole, an empty last line
//             reads ""), `-` when the file is absent or empty; a status over
//             100 CHARACTERS becomes its first 97 + `...` - characters as bash
//             counts them under the caller's locale (LC_ALL, else LC_CTYPE,
//             else LANG): UTF-8 sequences, an invalid byte one character, under
//             a UTF-8 name; plain BYTES under C. A meta value is read as awk
//             handed it to the shell: cut at its first NUL. A meta whose kind is
//             `verify-*` (metaIsVerify) is a VERIFICATION agent, listed apart
//             and never in the crew tally; `kind=self` is listed but not
//             supervised.
//   inbox   - `AC_HOME=<home> <bin>/ac-room.sh list` (stderr dropped), only
//             when data/ exists: each `PENDING-CAPTAIN(n)...` line adds n to
//             pending (a non-numeric n adds 0) and, when its status TOKEN ends
//             in `+HANDBACK`, 1 to handback; each `HANDBACK...` line adds 1 to
//             handback; both are echoed verbatim. A list that exits non-zero
//             is UNREADABLE (its partial stdout is still tallied, as the
//             original's `rows="$(...)" || flag` kept it).
//   watcher - state/.last-watcher-beat through ac_watcher_beat_read
//             (watcherBeatRead): absent -> `down (no beacon)`; a 0 beat (stood
//             down, empty, zero-padded, non-numeric) -> `down (no beat on
//             record)`; else age = now - beat, `armed (beat <age>s ago)` when
//             age <= grace, `down (beat <age>s > grace <grace>s)` past it (a
//             grace that is not an integer compares false, as `[ -le ]` did;
//             AC_GUARD_GRACE, default 300). `, owner pid <pid>` rides inside
//             the parentheses when state/.watcher-owner holds one (every
//             [:space:] deleted - the locale's class, ASCII under C). A down
//             line gains ` - no crew in flight` (no
//             crew) or ` - no supervised crew in flight (<n> self task(s) owe
//             none)` (self tasks only).
//   wakes   - the non-dot entries of state/.wake-spool/ plus those of every
//             family spool ac_wake_family_spools names (wakeFamilySpools),
//             counted by name, never read; a dangling symlink is not counted.
//   lock    - state/.session-lock: `free` when absent; pid= and since= by
//             ac_meta_get; `held pid=<p> since=<s|?>` when `ps -p <pid>`
//             succeeds (spawned, so `+42` is alive and `abc` is not),
//             `stale pid=<p|?> since=<s|?>` otherwise.
//   config, cadence - --json only: config/flow|promote|remote-mirror (first
//             line, [:space:]-trimmed under the locale's class - configReadDir;
//             defaults auto / always / off); learn count = state/.learn.meta
//             debriefs, else stows, non-digits -> 0; last_run digits or null;
//             learn-every (default 8) and curate-every (default 5), non-digits
//             -> the default; curate count = state/.curate.meta runs_since;
//             due = count >= every, compared as the integers they are (bash's
//             64-bit `-ge`), never as doubles.
//
// TEXT (default), bytes exact; <pad> is 3*depth spaces:
//   == fleet homes: <resolved container> ==
//   <one blank line, then per top-level home>
//   <pad>⚓ <name>[   captain: <config/captain first line, trimmed>]
//   <pad>   crew    : <n> in flight            | <pad>   crew    : none in flight
//   <pad>     <id %-16s> <kind|- %-6s> <project|- %-14s> <status>     (per crew meta)
//   <pad>   verify  : <n> in flight (verification agents, not crew)      (only when n > 0)
//   <pad>     <the same row> caller=<c|-> family=<f|-> ref=<ref's first 12 CHARACTERS>
//   <pad>   inbox   : UNKNOWN - the room set could not be read (bin/ac-room.sh list)
//     | <pad>   inbox   : <p> pending, <h> handback   then  <pad>     <ac-room.sh line>  per tallied line
//     | <pad>   inbox   : clear
//   <pad>   watcher : <watcher line>
//   <pad>   wakes   : <n> queued
//   <pad>   lock    : <lock line>
//   <pad>   crewdeputies:                 (once, before the first nested home)
//   The `%-Ns` columns pad by BYTES (bash's printf); the two truncations count
//   CHARACTERS. No homes: a blank line, then `(no fleet homes under <container>)`.
//   Not found: `(fleet homes container not found: <container as given>)`.
//
// --json: ONE document, pretty-printed by ONE spawned `jq .` fed the raw bytes
// of the document this module assembles (strings escaped only for `"`, `\` and
// control bytes), so jq's own printer and escaping decide the bytes exactly as
// they did for the original's `--arg` values: 2-space indent, control chars
// and DEL as \u00XX, invalid UTF-8 replaced by U+FFFD (jq 1.8.2's reading: the
// byte after an invalid lead goes into that one U+FFFD). Key order as listed:
//   {container, generated_at (ac_iso, taken after the walk), grace,
//    totals:{homes,crew,pending,handback,inbox_unreadable,watchers_down,learning_due,curate_due},
//    homes:[home...]}
//   home = {name, path (<container>/<name>; a symlinked child keeps its link name),
//           captain|null, config:{flow,promote,mirror},
//           crew:{count,supervised,tasks:[{id,kind|null,project|null,mode|null,status}]},
//           verify:[{id,kind|null,project|null,status,caller|null,family|null,ref|null,worktree|null}],
//           inbox:{pending,handback,unreadable,entries:[{status,family,last}]},
//           watcher:{state:"armed"|"down",age|null,beat|null,owner|null,detail},
//           wakes, lock:{state:"free"|"held"|"stale",pid|null,since|null,detail},
//           cadence:{learn:{count,every,due,last_run|null},curate:{count,every,due}},
//           crewdeputies:[home...]}
//   mode is null for "" or "-"; an inbox entry's status is the line's first
//   [:space:]-delimited token, family the text after the last space before the
//   first TAB, last the text after that TAB ("" without one). totals are
//   arithmetic over every emitted home, nested ones included; watchers_down
//   counts homes with supervised > 0 and a down watcher. Not found:
//   {container, generated_at, grace, note:"container not found", totals (all
//   0), homes:[]}. grace is ONE standalone JSON value as `--argjson` took it:
//   a canonical integer is placed as is; anything else is handed to a spawned
//   `jq -cn --argjson` first, whose refusal (exit 2, its own stderr) ends the
//   run as the original's did and whose answer is the token placed - so
//   `300,"x":1` is refused, not spliced into the document.
//   DEPTH POISON (reproduced; a defect of the original, whose command
//   substitutions ran without errexit, so a depth-7 home's empty object failed
//   every enclosing `--argjson` and the whole TOP-LEVEL home vanished from
//   homes[] and totals, exit 0): a top-level home with a crewdeputy chain 7
//   deep is omitted here too; jq's error lines on stderr are not reproduced.
//
// --paths: {container, homes:[{path, crewdeputies:[{path,crewdeputies:[...]}]}]}
//   through the same single `jq .`; home discovery only - no state read, no
//   ac-room.sh, no depth cap. Not found: {container, homes:[]}.
//
// WHO READS IT: dashboard/app.ts runs `--paths` (homePathsIn) and `--json`
// (/api/snapshot.json, passed through raw); both map a non-zero exit to an
// empty set / a 502, so no set -e caller depends on this entry; the
// cross-fleet-monitor standing job reads the text by eye.
//
// BINARIES: `<bin>/ac-room.sh list` per home with data/, `ps -p <pid>` per
// lock file, `date` through now()/iso() (a PATH stub freezes both sides), and
// one `jq .` per --json/--paths run (the jq-fork leg of the contract test
// counts it). <bin> is the bin/ this module was STARTED from: bin/ac-bun.sh
// runs bun in <bin>/.., so process.cwd() captured before enterCaller leaves it
// names that root - import.meta.dir would resolve through a copied bin's src/
// link to the distro checkout and call the wrong ac-room.sh.
//
// NAMED DIVERGENCES from the frozen original: `-h` prints THIS header; dirs
// and metas are listed in byte order (bash's glob followed libc collation
// under a UTF-8 locale); jq's stderr on the depth poison is not reproduced;
// on a text-mode read that fails, the tool's own stderr (`tail: ...:
// Permission denied`, `head: ...`) is not reproduced - exit and stdout are;
// the home is bound through physicalDir. A zero-padded cadence counter reads
// as its decimal value on both sides (jq takes `--argjson 007` as 7). Reads
// only - no lock, no mkdir, no temp file, nothing written under any home.
import { existsSync, readdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { configReadDir, die, enterCaller, iso, metaGet, metaIsVerify, now, physicalDir, wakeFamilySpools, watcherBeatRead } from "./lib.ts";

const bin = `${process.cwd()}/bin`;
// `now="$(ac_now)"` survived a date(1) that could not run: `${EPOCHSECONDS:-$(date
// +%s)}` left now empty, and bash's arithmetic read the empty string as 0, so
// every beat compared as `0 - beat` - armed. A NaN here would read as down.
const nowSecs = ((n: number): number => (Number.isNaN(n) ? 0 : n))(now());
const { args } = enterCaller(process.argv.slice(2));

const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const native = (b: string): string => Buffer.from(b, "latin1").toString("utf8");
const ANCHOR = bytes("⚓");
const NUL = /\u0000/g;

function write(fd: number, b: Buffer): void {
  for (let off = 0; off < b.length; ) off += writeSync(fd, b, off, b.length - off);
}

let mode: "text" | "json" | "paths" = "text";
let argContainer = "";
for (const a of args) {
  if (a === "--json") mode = "json";
  else if (a === "--paths") mode = "paths";
  else if (a === "-h" || a === "--help") {
    let out = "";
    for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
      if (!l.startsWith("//")) break;
      out += `${l.replace(/^\/\/ ?/, "")}\n`;
    }
    write(1, Buffer.from(out, "utf8"));
    process.exit(0);
  } else if (!argContainer) argContainer = a;
}

const grace = process.env.AC_GUARD_GRACE || "300";
const graceInt = /^[+-]?[0-9]+$/.test(grace) ? Number(grace) : null;
// bash's character and [:space:] readings follow the locale it was given.
const utf8Locale = /utf-?8/i.test(process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "");

// In text mode a failing per-home read ended the original on its assignment
// (`set -e`); the lines before it were already on stdout. In --json the same
// read sat inside a command substitution and the value is "".
class Fatal extends Error {}
const fatalOr = <T,>(v: T): T => {
  if (mode === "text") throw new Fatal();
  return v;
};

const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const listDir = (d: string): string[] => {
  try {
    return readdirSync(d)
      .filter((n) => !n.startsWith("."))
      .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  } catch {
    return [];
  }
};
const readBytes = (p: string): string => readFileSync(p, "latin1").replace(NUL, "");
// The value as awk handed it to the shell: a C string, cut at its first NUL.
const meta = (file: string, key: string): string => {
  try {
    return metaGet(file, key).replace(/\0[\s\S]*$/, "");
  } catch {
    return fatalOr("");
  }
};
const isHome = (h: string): boolean => isDir(`${h}/data`) || isDir(`${h}/state`) || isDir(`${h}/config`);
const homeChildren = (dir: string): string[] => listDir(dir).map((n) => `${dir}/${n}`).filter((p) => isDir(p) && isHome(p));

// bash's characters over a bytes string: under a UTF-8 locale one valid UTF-8
// sequence or one invalid byte each (so a slice keeps the raw bytes); under C
// every byte is one.
function chars(b: string): string[] {
  const out: string[] = [];
  if (!utf8Locale) return b.split("");
  for (let i = 0; i < b.length; ) {
    const c = b.charCodeAt(i);
    let n = c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 1;
    if (n > 1) {
      const t1 = b.charCodeAt(i + 1);
      let ok = t1 >= (c === 0xe0 ? 0xa0 : c === 0xf0 ? 0x90 : 0x80) && t1 <= (c === 0xed ? 0x9f : c === 0xf4 ? 0x8f : 0xbf);
      for (let k = 2; ok && k < n; k++) ok = b.charCodeAt(i + k) >= 0x80 && b.charCodeAt(i + k) <= 0xbf;
      if (!ok) n = 1;
    }
    out.push(b.slice(i, i + n));
    i += n;
  }
  return out;
}
const padBytes = (b: string, w: number): string => b + " ".repeat(Math.max(0, w - b.length));

// The shell's [:space:] over a bytes string: White_Space minus U+0085 (lib.ts
// SHELL_TRIM's class) when the locale is UTF-8 and the bytes are valid UTF-8,
// ASCII whitespace otherwise.
function onShellSpace(b: string, f: (s: string, ws: string) => string): string {
  const u = Buffer.from(b, "latin1").toString("utf8");
  const valid = utf8Locale && Buffer.from(u, "utf8").toString("latin1") === b;
  const out = f(valid ? u : b, valid ? "(?!\\x85)\\p{White_Space}" : "[\\t\\n\\v\\f\\r ]");
  return valid ? Buffer.from(out, "utf8").toString("latin1") : out;
}
const delSpace = (b: string): string => onShellSpace(b, (s, ws) => s.replace(new RegExp(ws, "gu"), ""));
const beforeSpace = (b: string): string => onShellSpace(b, (s, ws) => s.replace(new RegExp(`${ws}[\\s\\S]*$`, "u"), ""));

// `tail -n1 <f> | cut -d' ' -f2-`, `-` when the file is absent or empty.
function lastStatus(stf: string): string {
  let text: string;
  try {
    if (statSync(stf).size === 0) return "-";
    text = readFileSync(stf, "latin1");
  } catch {
    return existsSync(stf) ? fatalOr("") : "-";
  }
  if (text.endsWith("\n")) text = text.slice(0, -1);
  const line = text.slice(text.lastIndexOf("\n") + 1);
  const sp = line.indexOf(" ");
  return (sp < 0 ? line : line.slice(sp + 1)).replace(NUL, "");
}

const psAlive = (pid: string): boolean => {
  try {
    return Bun.spawnSync(["ps", "-p", native(pid)], { stdout: "ignore", stderr: "ignore" }).exitCode === 0;
  } catch {
    return false;
  }
};

type Row = { id: string; kind: string; project: string; status: string; text: string };
type Entry = { status: string; family: string; last: string };
type Home = {
  home: string;
  name: string;
  path: string;
  captain: string;
  crew: (Row & { dmode: string })[];
  verify: (Row & { caller: string; family: string; ref: string; worktree: string })[];
  supervised: number;
  inbox: { pending: number; handback: number; unreadable: boolean; lines: string[]; entries: Entry[] };
  watcher: { detail: string; state: "armed" | "down"; age: number | null; beat: string | null; owner: string };
  wakes: number;
  lock: { detail: string; state: "free" | "held" | "stale"; pid: string; since: string };
  config: { flow: string; promote: string; mirror: string };
  cadence: { lcur: string; lev: string; ldue: boolean; lrun: string | null; ccur: string; cev: string; cdue: boolean };
  deputies: Home[];
  capped: boolean;
};

function survey(home: string, depth: number, recurse = true): Home {
  const pad = " ".repeat(depth * 3);
  const sd = `${home}/state`;
  const cfgd = `${home}/config`;
  const cfg = (n: string, d: string): string => {
    try {
      return configReadDir(cfgd, n, d);
    } catch {
      return fatalOr("");
    }
  };
  const h: Home = {
    home,
    name: bytes(home.slice(home.lastIndexOf("/") + 1)).replace(/\n+$/, ""),
    path: bytes(home),
    // `head -n1 ... 2>/dev/null || true`: the one per-home read the original
    // guarded itself, so an unreadable captain is "" in every mode.
    captain: ((): string => {
      try {
        return configReadDir(cfgd, "captain", "");
      } catch {
        return "";
      }
    })(),
    crew: [],
    verify: [],
    supervised: 0,
    inbox: { pending: 0, handback: 0, unreadable: false, lines: [], entries: [] },
    watcher: { detail: "", state: "down", age: null, beat: null, owner: "" },
    wakes: 0,
    lock: { detail: "free", state: "free", pid: "", since: "" },
    config: { flow: "", promote: "", mirror: "" },
    cadence: { lcur: "0", lev: "8", ldue: false, lrun: null, ccur: "0", cev: "5", cdue: false },
    deputies: [],
    capped: false,
  };

  if (isDir(sd)) {
    for (const n of listDir(sd)) {
      const m = `${sd}/${n}`;
      if (!n.endsWith(".meta") || !existsSync(m)) continue;
      const id = n.slice(0, -".meta".length);
      const kind = meta(m, "kind");
      const project = meta(m, "project");
      let status = lastStatus(`${sd}/${id}.status`);
      if (chars(status).length > 100) status = `${chars(status).slice(0, 97).join("")}...`;
      const row = { id: bytes(id), kind, project, status, text: `${pad}     ${padBytes(bytes(id), 16)} ${padBytes(kind || "-", 6)} ${padBytes(project || "-", 14)} ${status}` };
      if (metaIsVerify(m)) {
        const caller = meta(m, "caller"), family = meta(m, "family"), ref = meta(m, "ref");
        h.verify.push({ ...row, caller, family, ref, worktree: meta(m, "worktree"), text: `${row.text} caller=${caller || "-"} family=${family || "-"} ref=${chars(ref).slice(0, 12).join("")}` });
      } else {
        h.crew.push({ ...row, dmode: meta(m, "mode") });
        if (kind !== "self") h.supervised++;
      }
    }
  }

  if (isDir(`${home}/data`)) {
    let rows = "";
    try {
      const r = Bun.spawnSync([`${bin}/ac-room.sh`, "list"], { stdout: "pipe", stderr: "ignore", env: { ...process.env, AC_HOME: home } });
      rows = r.stdout.toString("latin1");
      if (r.exitCode !== 0) h.inbox.unreadable = true;
    } catch {
      h.inbox.unreadable = true;
    }
    for (const line of rows.replace(NUL, "").replace(/\n+$/, "").split("\n")) {
      const tok = beforeSpace(line);
      if (line.startsWith("PENDING-CAPTAIN")) {
        let n = line.startsWith("PENDING-CAPTAIN(") ? line.slice("PENDING-CAPTAIN(".length) : line;
        if (n.includes(")")) n = n.slice(0, n.indexOf(")"));
        h.inbox.pending += /^[0-9]+$/.test(n) ? parseInt(n, 10) : 0;
        if (tok.endsWith("+HANDBACK")) h.inbox.handback++;
      } else if (line.startsWith("HANDBACK")) h.inbox.handback++;
      else continue;
      h.inbox.lines.push(line);
      const tab = line.indexOf("\t");
      const left = tab < 0 ? line : line.slice(0, tab);
      h.inbox.entries.push({ status: tok, family: left.slice(left.lastIndexOf(" ") + 1), last: tab < 0 ? "" : line.slice(tab + 1) });
    }
  }

  if (isFile(`${sd}/.watcher-owner`)) {
    try {
      h.watcher.owner = delSpace(readBytes(`${sd}/.watcher-owner`));
    } catch {
      fatalOr(undefined);
    }
  }
  const ownerSfx = h.watcher.owner ? `, owner pid ${h.watcher.owner}` : "";
  if (isFile(`${sd}/.last-watcher-beat`)) {
    const beat = watcherBeatRead(sd).split(" ")[0]!;
    h.watcher.beat = beat;
    if (beat === "0") h.watcher.detail = `down (no beat on record${ownerSfx})`;
    else {
      h.watcher.age = nowSecs - Number(beat);
      h.watcher.detail = graceInt !== null && h.watcher.age <= graceInt ? `armed (beat ${h.watcher.age}s ago${ownerSfx})` : `down (beat ${h.watcher.age}s > grace ${grace}s${ownerSfx})`;
    }
  } else h.watcher.detail = "down (no beacon)";
  if (h.supervised === 0 && h.watcher.detail.startsWith("down")) {
    h.watcher.detail += h.crew.length === 0 ? " - no crew in flight" : ` - no supervised crew in flight (${h.crew.length} self task(s) owe none)`;
  }
  if (h.watcher.detail.startsWith("armed")) h.watcher.state = "armed";

  for (const n of listDir(`${sd}/.wake-spool`)) if (existsSync(`${sd}/.wake-spool/${n}`)) h.wakes++;
  for (const q of wakeFamilySpools(sd)) for (const n of listDir(q)) if (existsSync(`${q}/${n}`)) h.wakes++;

  if (isFile(`${sd}/.session-lock`)) {
    const pid = meta(`${sd}/.session-lock`, "pid");
    const since = meta(`${sd}/.session-lock`, "since");
    const held = pid !== "" && psAlive(pid);
    h.lock = { detail: held ? `held pid=${pid} since=${since || "?"}` : `stale pid=${pid || "?"} since=${since || "?"}`, state: held ? "held" : "stale", pid, since };
  }

  if (mode === "json") {
    h.config = { flow: cfg("flow", "auto"), promote: cfg("promote", "always"), mirror: cfg("remote-mirror", "off") };
    const digits = (v: string, dflt: string): string => (/^[0-9]+$/.test(v) ? v : dflt);
    const lcur = digits(meta(`${sd}/.learn.meta`, "debriefs") || meta(`${sd}/.learn.meta`, "stows"), "0");
    const lrun = meta(`${sd}/.learn.meta`, "last_run");
    const lev = digits(cfg("learn-every", "8"), "8");
    const ccur = digits(meta(`${sd}/.curate.meta`, "runs_since"), "0");
    const cev = digits(cfg("curate-every", "5"), "5");
    h.cadence = { lcur, lev, ldue: BigInt(lcur) >= BigInt(lev), lrun: /^[0-9]+$/.test(lrun) ? lrun : null, ccur, cev, cdue: BigInt(ccur) >= BigInt(cev) };
  }

  if (recurse) {
    for (const cd of homeChildren(`${home}/crewdeputies`)) {
      if (depth >= 6) h.capped = true;
      else h.deputies.push(survey(cd, depth + 1));
    }
  }
  return h;
}

// Each block reaches stdout before the next home is read, so a read that
// fails leaves exactly what the original had printed by then.
function renderText(h: Home, depth: number): void {
  const pad = " ".repeat(depth * 3);
  let o = `${pad}${ANCHOR} ${h.name}${h.captain ? `   captain: ${h.captain}` : ""}\n`;
  if (h.crew.length > 0) {
    o += `${pad}   crew    : ${h.crew.length} in flight\n`;
    for (const r of h.crew) o += `${r.text}\n`;
  } else o += `${pad}   crew    : none in flight\n`;
  if (h.verify.length > 0) {
    o += `${pad}   verify  : ${h.verify.length} in flight (verification agents, not crew)\n`;
    for (const r of h.verify) o += `${r.text}\n`;
  }
  if (h.inbox.unreadable) o += `${pad}   inbox   : UNKNOWN - the room set could not be read (bin/ac-room.sh list)\n`;
  else if (h.inbox.pending > 0 || h.inbox.handback > 0) {
    o += `${pad}   inbox   : ${h.inbox.pending} pending, ${h.inbox.handback} handback\n`;
    for (const l of h.inbox.lines) o += `${pad}     ${l}\n`;
  } else o += `${pad}   inbox   : clear\n`;
  o += `${pad}   watcher : ${h.watcher.detail}\n${pad}   wakes   : ${h.wakes} queued\n${pad}   lock    : ${h.lock.detail}\n`;
  const kids = homeChildren(`${h.home}/crewdeputies`);
  if (kids.length > 0) o += `${pad}   crewdeputies:\n`;
  write(1, Buffer.from(o, "latin1"));
  if (depth >= 6) return;
  for (const cd of kids) renderText(textSurvey(cd, depth + 1), depth + 1);
}

function textSurvey(home: string, depth: number): Home {
  try {
    return survey(home, depth, false);
  } catch (e) {
    if (e instanceof Fatal) process.exit(1);
    throw e;
  }
}

// The document jq pretty-prints: strings are latin1 bytes escaped only where
// JSON's grammar demands it; a Raw is a number spelled as its source spelled it.
class Raw {
  constructor(public text: string) {}
}
type J = null | boolean | number | string | Raw | J[] | { [k: string]: J };
const raw = (digits: string): Raw => new Raw(digits.replace(/^0+(?=.)/, ""));
function ser(v: J): string {
  if (v === null) return "null";
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (typeof v === "string") return `"${v.replace(/["\\]/g, "\\$&").replace(/[\x00-\x1f]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`)}"`;
  if (v instanceof Raw) return v.text;
  if (Array.isArray(v)) return `[${v.map(ser).join(",")}]`;
  return `{${Object.entries(v)
    .map(([k, x]) => `${ser(k)}:${ser(x)}`)
    .join(",")}}`;
}
const orNull = (s: string): string | null => (s === "" ? null : s);

function homeJson(h: Home): J {
  const c = h.cadence;
  return {
    name: h.name,
    path: h.path,
    captain: orNull(h.captain),
    config: h.config,
    crew: {
      count: h.crew.length,
      supervised: h.supervised,
      tasks: h.crew.map((t) => ({ id: t.id, kind: orNull(t.kind), project: orNull(t.project), mode: t.dmode === "" || t.dmode === "-" ? null : t.dmode, status: t.status })),
    },
    verify: h.verify.map((v) => ({ id: v.id, kind: orNull(v.kind), project: orNull(v.project), status: v.status, caller: orNull(v.caller), family: orNull(v.family), ref: orNull(v.ref), worktree: orNull(v.worktree) })),
    inbox: { pending: h.inbox.pending, handback: h.inbox.handback, unreadable: h.inbox.unreadable, entries: h.inbox.entries },
    watcher: { state: h.watcher.state, age: h.watcher.age, beat: h.watcher.beat === null ? null : new Raw(h.watcher.beat), owner: orNull(h.watcher.owner), detail: h.watcher.detail },
    wakes: h.wakes,
    lock: { state: h.lock.state, pid: orNull(h.lock.pid), since: orNull(h.lock.since), detail: h.lock.detail },
    cadence: { learn: { count: raw(c.lcur), every: raw(c.lev), due: c.ldue, last_run: c.lrun === null ? null : raw(c.lrun) }, curate: { count: raw(c.ccur), every: raw(c.cev), due: c.cdue } },
    crewdeputies: h.deputies.map(homeJson),
  };
}
const poisoned = (h: Home): boolean => h.capped || h.deputies.some(poisoned);
const flat = (h: Home): Home[] => [h, ...h.deputies.flatMap(flat)];
const pathsJson = (home: string): J => ({ path: bytes(home), crewdeputies: homeChildren(`${home}/crewdeputies`).map(pathsJson) });

// `--argjson grace "$grace"`: one standalone value. A canonical integer needs
// no jq; anything else is handed to jq alone first, so its refusal (and its
// stderr) ends the run as the original's did, and its answer is the token.
function graceToken(): Raw {
  if (/^(0|-?[1-9][0-9]*)$/.test(grace)) return new Raw(grace);
  let r: ReturnType<typeof Bun.spawnSync>;
  try {
    r = Bun.spawnSync(["jq", "-cn", "--argjson", "g", grace, "$g"], { stdout: "pipe", stderr: "inherit", env: process.env });
  } catch {
    die("required tool not found: jq");
  }
  if (r.exitCode !== 0) process.exit(r.exitCode ?? 2);
  return new Raw(r.stdout.toString("latin1").replace(/\n+$/, ""));
}

function emitJson(doc: J): never {
  let r: ReturnType<typeof Bun.spawnSync>;
  try {
    r = Bun.spawnSync(["jq", "."], { stdin: Buffer.from(ser(doc), "latin1"), stdout: "inherit", stderr: "inherit", env: process.env });
  } catch {
    die("required tool not found: jq");
  }
  process.exit(r.exitCode ?? 1);
}

let container = argContainer || process.env.AC_HOMES_CONTAINER || "";
if (!container && process.env.AC_HOME) container = physicalDir(`${process.env.AC_HOME}/..`) ?? "";
if (!container) container = `${process.env.HOME ?? ""}/Work/ac-homes`;
const resolved = physicalDir(container);
if (resolved === null) {
  if (mode === "json") {
    emitJson({ container: bytes(container), generated_at: iso(), grace: graceToken(), note: "container not found", totals: { homes: 0, crew: 0, pending: 0, handback: 0, inbox_unreadable: 0, watchers_down: 0, learning_due: 0, curate_due: 0 }, homes: [] });
  }
  if (mode === "paths") emitJson({ container: bytes(container), homes: [] });
  write(1, Buffer.from(`(fleet homes container not found: ${bytes(container)})\n`, "latin1"));
  process.exit(0);
}
const topHomes = homeChildren(resolved);

if (mode === "paths") emitJson({ container: bytes(resolved), homes: topHomes.map(pathsJson) });

if (mode === "json") {
  const kept = topHomes.map((p) => survey(p, 0)).filter((h) => !poisoned(h));
  const all = kept.flatMap(flat);
  const count = (f: (h: Home) => boolean): number => all.filter(f).length;
  const sum = (f: (h: Home) => number): number => all.reduce((n, h) => n + f(h), 0);
  emitJson({
    container: bytes(resolved),
    generated_at: iso(),
    grace: graceToken(),
    totals: {
      homes: all.length,
      crew: sum((h) => h.crew.length),
      pending: sum((h) => h.inbox.pending),
      handback: sum((h) => h.inbox.handback),
      inbox_unreadable: count((h) => h.inbox.unreadable),
      watchers_down: count((h) => h.supervised > 0 && h.watcher.state === "down"),
      learning_due: count((h) => h.cadence.ldue),
      curate_due: count((h) => h.cadence.cdue),
    },
    homes: kept.map(homeJson),
  });
}

write(1, Buffer.from(`== fleet homes: ${bytes(resolved)} ==\n`, "latin1"));
for (const p of topHomes) {
  write(1, Buffer.from("\n"));
  renderText(textSurvey(p, 0), 0);
}
if (topHomes.length === 0) write(1, Buffer.from(`\n(no fleet homes under ${bytes(resolved)})\n`, "latin1"));
