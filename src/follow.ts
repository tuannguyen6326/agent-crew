// follow.ts - realtime, full-fidelity stream of a crewmate's claude session
// (the captain's x-ray: full tool inputs and results, not the 40-line pane
// tail ac-peek gives). The entry is bin/ac-follow.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, and the
// bash original it replaced stays frozen at tests/fixtures/ac-follow.sh as the
// oracle the differential leg of tests/sh/ac-follow.test.sh holds this module
// to (beside tests/fixtures/follow.ts, the renderer that original started).
//
// Usage:
//   ac-follow.sh <id>              follow the crewmate's transcript live
//   ac-follow.sh --render <jsonl>  one-shot render of a transcript (tests)
//
// --render <jsonl>: an empty or missing <jsonl> is `ERROR: usage: ac-follow.sh
// --render <jsonl>`, exit 1; one that is no regular file (a link to one
// counts) is `ERROR: no such transcript: <jsonl>`, exit 1. Otherwise every
// record is rendered, then one empty line; exit 0. Words after <jsonl> are
// ignored.
//
// <id>: an empty <id> is `ERROR: usage: ac-follow.sh <id> | --render <jsonl>`,
// exit 1. The task meta is <state>/<id>.meta (ac_task_meta: state/ minted, the
// id a path component as given), else <state>/archive/<id>/meta; homeless,
// each of the two reads prints the refusal and the second ends the run, exit
// 1; neither a regular file is `ERROR: no crewmate meta for <id>`, exit 1. A
// meta that cannot be read is metaGet's `WARN: cannot read meta file <meta>`,
// exit 1. Its `worktree=` empty is `ERROR: meta for <id> has no worktree`, a
// `harness=` other than `claude` (absent included) `ERROR: <id> is not a claude
// crewmate; use ac-peek.sh instead`, both exit 1; each value is read as awk
// handed it over, cut at its first NUL. claude keys transcripts by cwd: the
// slug is the worktree with every `/` and `.` made `-` (bytes), and the
// followed DIRECTORY is <root>/<slug>, <root> AC_CLAUDE_TRANSCRIPT_ROOT, else
// <CLAUDE_CONFIG_DIR, else HOME/.claude>/projects (each rung when the one
// above is unset or empty; HOME unset there is `ERROR: HOME is not set, so the
// claude transcript root cannot be named`, exit 1). No directory there yet is
// `WARN: no transcripts yet at <dir> (crewmate still booting?)`; then `following
// <id> (<dir>) - ctrl-c to stop` on stderr, and follow mode below until killed.
// The crewmate is never touched (read-only).
//
// What is printed: a record is one line of JSON; a line that does not parse
// prints nothing. A user record whose message content is a string prints
// "\nuser: <content>",
// clipped at 2000 characters; other string content prints nothing. Of the
// content blocks, `text` prints its text with no newline, `tool_use` prints
// "\ntool <name> <input as JSON>", and `tool_result` prints "-> <body>", or
// "ERR <body>" when is_error, a list body joined from its text parts; both
// clipped at 1500 characters ("...[+<n> chars]" counts the rest). Colors only
// on a tty. A record of the wrong shape - not an object, a message or block
// that is not an object, content that is neither a string nor a list, a text
// part that is not a string - ends the run with ERROR on stderr and exit 1,
// after what was already printed; so does text that is not UTF-8.
//
// Follow mode polls once a second, names each transcript it switches to
// ("-- session: <file> --"), shows only the last 15 records of one first seen
// past 200000 bytes, then prints records as they are appended, and reads a
// truncated transcript again from the start. Before the first transcript it
// says `waiting for the first transcript in <dir> ...` once. A relative <dir>
// from a caller cwd that has no name is `ERROR: the current directory cannot
// be resolved, so a relative transcript path cannot be either`, exit 1, after
// the two stderr lines above.
//
// PYTHON SEMANTICS. The renderer replaced a python one, and the output kept
// python's meaning where it differs from plain JS: truthiness ([] and {} are
// false), str() of a non-string (None, True), json.dumps's ", " and ": "
// separators with non-ASCII left raw, lengths in code points, a BOM that
// leaves its line unparsable, lines ending at CR as well as LF. Deliberately
// NOT kept: numbers are JS doubles (1.0 prints 1, an integer past 2^53 rounds,
// NaN leaves its line unparsable) and an object's integer-like keys print
// first; a list or object where text belongs prints as JSON, not python's
// repr; a lone surrogate prints as U+FFFD in text where python crashed, and
// as its \uXXXX escape where a value prints as JSON (tool input); text that is
// not UTF-8 fails before any output, not after the chunks ahead of it. Follow
// offsets count the bytes actually read: python counted characters after the
// tail and printed records again on non-ASCII text. Records split on LF and
// CR only, where python's str.splitlines also split on VT, FF, the separators
// U+001C-U+001E, U+0085, U+2028 and U+2029 - so it dropped a record holding
// one. <dir> is a literal path, never a glob pattern.
//
// ESCAPE HATCH. No script runs this entry, so a broken one costs only the
// x-ray. The frozen original started the renderer as `follow.ts file|dir
// <path>`, so it runs beside that renderer, frozen too, from a scratch copy:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin" "$o/src"; cp bin/*.sh "$o/bin/"
//   cp src/*.ts "$o/src/"
//   cp tests/fixtures/follow.ts "$o/src/follow.ts"
//   cp tests/fixtures/ac-follow.sh "$o/bin/ac-follow.sh"
// then "$o/bin/ac-follow.sh" <id> by hand.
//
// AT PARITY (each pinned in the leg):
// - Homeless, the refusal is printed twice (the meta read, then the archive
//   read that ends the run).
// - The id is a path component as given: `../x` reads <home>/x.meta.
// - The transcript root loses its trailing LFs, as the original's `$(...)`
//   cut them: AC_CLAUDE_TRANSCRIPT_ROOT=/tmp/tr<LF> follows /tmp/tr/<slug>.
// - The followed directory is handed on as bun decoded the original's argv:
//   a worktree byte that is no UTF-8 is U+FFFD there (in `waiting for` and in
//   every read), where the two stderr lines carry the byte - a directory no
//   claude session can have, since APFS refuses a name that is no UTF-8.
//
// DIVERGENCES from the frozen original (the leg names each one a row can show):
// - FAIL-PATH: under a UTF-8 locale the original's `sed` aborted the slug on a
//   worktree byte that is no UTF-8 (`sed: RE error: illegal byte sequence`,
//   exit 1); here the slug is made from bytes and the stream follows.
// - SHELL-OWN STDERR is not reproduced, the status kept: `${2:?}`'s line for a
//   missing --render path is the usage line above, and `HOME: unbound
//   variable` the HOME line (exit 1 both); a state/ that mkdir cannot make is
//   silent here (the run goes on alike); from a cwd that has no name the
//   shell's own getcwd lines (`shell-init:`, `chdir:`) are the shim's, fewer
//   than the original's cds printed.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is `ERROR: AC_HOME is not a
//   readable directory: <AC_HOME>`, twice, where the shell printed its own
//   `cd:` line twice (exit 1 both); a relative AC_HOME from a caller cwd that
//   has no name is `ERROR: the current directory cannot be resolved, so a
//   relative AC_HOME cannot be either`, once, never resolved in the distro
//   root (the original's cd failed twice in the deleted directory).
// - BUN: without bun the shim's `ERROR: required tool not found: bun`, exit 1,
//   comes before any argument is read, where the original refused a bad
//   argument, a meta and a non-claude crewmate first.
// - BYTES: argv and the environment arrive decoded, so an <id>, a <jsonl> or a
//   transcript root that is no UTF-8 is U+FFFD.
//
// CALLERS: operators and chiefs by hand (the task-lifecycle,
// stuck-crewmate-recovery and harness-operations skills; src/session.ts's
// mid-turn refusal names it); tests/sh/ac-follow.test.sh. No script runs it
// and nothing parses what it prints.

import { closeSync, openSync, readdirSync, readFileSync, readSync, statSync, writeSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { isatty } from "node:tty";
import { NO_HOME, claudeTranscriptRoot, die, enterCaller, metaGet, physicalDir, taskMeta, warn } from "./lib.ts";

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
type Obj = { [k: string]: Json };

export class Malformed extends Error {}

export type Colors = { DIM: string; RST: string; CYA: string; RED: string; B: string };
export const PLAIN: Colors = { DIM: "", RST: "", CYA: "", RED: "", B: "" };
export const ANSI: Colors = { DIM: "\x1b[2m", RST: "\x1b[0m", CYA: "\x1b[36m", RED: "\x1b[31m", B: "\x1b[1m" };

const isObj = (v: Json | undefined): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);
const has = (o: Obj, k: string) => Object.hasOwn(o, k);

export function truthy(v: Json | undefined): boolean {
  if (Array.isArray(v)) return v.length > 0;
  if (isObj(v)) return Object.keys(v).length > 0;
  return Boolean(v);
}

export function dumps(v: Json): string {
  if (Array.isArray(v)) return `[${v.map(dumps).join(", ")}]`;
  if (isObj(v)) return `{${Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}: ${dumps(x)}`).join(", ")}}`;
  return typeof v === "number" ? String(v) : JSON.stringify(v);
}

export function pyStr(v: Json | undefined): string {
  if (typeof v === "string") return v;
  if (v === null || v === undefined) return "None";
  if (typeof v === "boolean") return v ? "True" : "False";
  return dumps(v);
}

export function clip(s: string, c: Colors, n = 1500): string {
  const cps = Array.from(s);
  return cps.length <= n ? s : `${cps.slice(0, n).join("")}...${c.DIM}[+${cps.length - n} chars]${c.RST}`;
}

export function lines(text: string): string[] {
  const ls = text.split(/\r\n|\r|\n/);
  if (ls[ls.length - 1] === "") ls.pop();
  return ls;
}

export function render(line: string, c: Colors, out: (s: string) => void): void {
  let d: Json;
  try {
    d = JSON.parse(line);
  } catch {
    return;
  }
  if (!isObj(d)) throw new Malformed("a record that is not an object");
  const msg = truthy(d.message) ? d.message : {};
  if (!isObj(msg)) throw new Malformed("a message that is not an object");
  const content = msg.content;
  if (typeof content === "string") {
    if (d.type === "user") out(`\n${c.B}user:${c.RST} ${clip(content, c, 2000)}\n`);
    return;
  }
  if (!truthy(content)) return;
  if (!Array.isArray(content)) throw new Malformed("content that is neither a string nor a list");
  for (const b of content) {
    if (!isObj(b)) throw new Malformed("a content block that is not an object");
    if (b.type === "text" && truthy(b.text)) {
      out(pyStr(b.text));
    } else if (b.type === "tool_use") {
      const name = has(b, "name") ? pyStr(b.name) : "?";
      out(`\n${c.CYA}tool ${name}${c.RST} ${clip(dumps(has(b, "input") ? b.input : {}), c)}\n`);
    } else if (b.type === "tool_result") {
      let body = b.content;
      if (Array.isArray(body))
        body = body.filter(isObj).map((x) => {
          const t = has(x, "text") ? x.text : "";
          if (typeof t !== "string") throw new Malformed("a text part that is not a string");
          return t;
        }).join("");
      const mark = truthy(b.is_error) ? `${c.RED}ERR` : `${c.DIM}->`;
      out(`${mark} ${clip(pyStr(body), c)}${c.RST}\n`);
    }
  }
}

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const out = (s: string) => writeSync(1, s);

function renderBytes(bytes: Uint8Array, c: Colors, tail = Infinity): void {
  let text: string;
  try {
    text = UTF8.decode(bytes);
  } catch {
    die("the transcript is not UTF-8 text");
  }
  const ls = lines(text);
  for (const line of ls.slice(Math.max(0, ls.length - tail))) render(line, c, out);
}

function newest(dir: string): string | null {
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return null;
  }
  let best: string | null = null;
  let bestMtime = -Infinity;
  for (const name of names) {
    if (name.startsWith(".") || !name.endsWith(".jsonl")) continue;
    const p = join(dir, name);
    const m = statSync(p).mtimeMs;
    if (m > bestMtime) [best, bestMtime] = [p, m];
  }
  return best;
}

function readFrom(path: string, off: number): Buffer {
  const fd = openSync(path, "r");
  try {
    const parts: Buffer[] = [];
    for (;;) {
      const buf = Buffer.alloc(1 << 16);
      const n = readSync(fd, buf, 0, buf.length, off);
      if (n === 0) return Buffer.concat(parts);
      parts.push(buf.subarray(0, n));
      off += n;
    }
  } finally {
    closeSync(fd);
  }
}

function sizeOf(path: string): number | null {
  try {
    return statSync(path).size;
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") return null;
    throw e;
  }
}

function follow(dir: string, c: Colors): never {
  let cur: string | null = null;
  let off = 0;
  let waiting = false;
  for (;;) {
    const path = newest(dir);
    if (path === null) {
      if (!waiting) out(`${c.DIM}waiting for the first transcript in ${dir} ...${c.RST}\n`);
      waiting = true;
      Bun.sleepSync(1000);
      continue;
    }
    if (path !== cur) {
      cur = path;
      off = 0;
      out(`\n${c.B}-- session: ${basename(path)} --${c.RST}\n`);
      if (statSync(path).size > 200_000) {
        const bytes = readFileSync(path);
        renderBytes(bytes, c, 15);
        off = bytes.length;
      }
    }
    const size = sizeOf(path);
    if (size === null) {
      cur = null;
      continue;
    }
    if (size < off) off = 0;
    if (size > off) {
      const bytes = readFrom(path, off);
      off += bytes.length;
      renderBytes(bytes, c);
    }
    Bun.sleepSync(1000);
  }
}

const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");

function statOf(p: string | Buffer): ReturnType<typeof statSync> | null {
  try {
    return statSync(p);
  } catch {
    return null;
  }
}

// The value as awk handed it to the shell: a C string, cut at its first NUL.
const metaValue = (meta: string, key: string): string => metaGet(meta, key).replace(/\0[\s\S]*$/, "");

// The original tested <jsonl> in the caller's cwd, and one that has no name
// holds no relative path.
function renderEntry(f: string, atCaller: boolean, c: Colors): void {
  if (f === "") die("usage: ac-follow.sh --render <jsonl>");
  if (!(atCaller || isAbsolute(f)) || !statOf(f)?.isFile()) die(`no such transcript: ${f}`);
  renderBytes(readFileSync(f), c);
  out("\n");
}

function followEntry(id: string, atCaller: boolean, c: Colors): never {
  if (id === "") die("usage: ac-follow.sh <id> | --render <jsonl>");
  const h = process.env.AC_HOME;
  if (h && !atCaller && !isAbsolute(h)) die("the current directory cannot be resolved, so a relative AC_HOME cannot be either");
  let meta = taskMeta(id);
  if (!statOf(meta)?.isFile()) {
    // The archive path is a second `$(ac_state_dir)`, and homeless its
    // refusal ends the run.
    const home = h ? physicalDir(h) : null;
    if (home === null) die(h ? `AC_HOME is not a readable directory: ${h}` : NO_HOME);
    meta = `${home}/state/archive/${id}/meta`;
  }
  if (!statOf(meta)?.isFile()) die(`no crewmate meta for ${id}`);
  let worktree = "";
  try {
    worktree = metaValue(meta, "worktree");
  } catch {
    process.exit(1);
  }
  if (worktree === "") die(`meta for ${id} has no worktree`);
  let harness = "";
  try {
    harness = metaValue(meta, "harness");
  } catch {}
  if (harness !== "claude") die(`${id} is not a claude crewmate; use ac-peek.sh instead`);
  const root = claudeTranscriptRoot();
  if (root === null) die("HOME is not set, so the claude transcript root cannot be named");
  const dir = `${b8(root.replace(/\n+$/, ""))}/${worktree.replace(/[/.]/g, "-")}`;
  const named = atCaller || dir.startsWith("/");
  if (!(named && statOf(Buffer.from(dir, "latin1"))?.isDirectory())) warn(Buffer.from(`no transcripts yet at ${dir} (crewmate still booting?)`, "latin1"));
  writeSync(2, Buffer.from(`following ${b8(id)} (${dir}) - ctrl-c to stop\n`, "latin1"));
  if (!named) die("the current directory cannot be resolved, so a relative transcript path cannot be either");
  // The original handed the directory on as an argument, which bun decoded.
  follow(u8(dir), c);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  const c = isatty(1) ? ANSI : PLAIN;
  try {
    if (args[0] === "--render") renderEntry(args[1] ?? "", atCaller, c);
    else followEntry(args[0] ?? "", atCaller, c);
  } catch (e) {
    // A reader that closed the pipe early (`| head`) ends the run the way the
    // shell's SIGPIPE did: silently, 128+13.
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    die(e instanceof Malformed ? `unrenderable transcript record: ${e.message}` : e instanceof Error ? e.message : String(e));
  }
}
