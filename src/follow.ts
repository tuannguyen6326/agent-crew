// follow.ts - the transcript renderer behind bin/ac-follow.sh, which resolves
// the crewmate's transcript directory and starts this file through
// bin/ac-bun.sh (the caller's cwd arrives as the first argument, src/lib.ts's
// enterCaller returns there; a relative path is refused when that cwd has no
// name). THIS header is the spec for what is printed.
//
// Usage:
//   follow.ts file <jsonl>   render every record, then one empty line; exit 0
//   follow.ts dir <dir>      follow the newest <dir>/*.jsonl until killed
//
// A record is one line of JSON; a line that does not parse prints nothing. A
// user record whose message content is a string prints "\nuser: <content>",
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
// truncated transcript again from the start.
//
// PYTHON SEMANTICS. This file replaced a python renderer, and the output kept
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

import { closeSync, openSync, readdirSync, readFileSync, readSync, statSync, writeSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { isatty } from "node:tty";
import { die, enterCaller } from "./lib.ts";

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

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  const [mode = "", target = ""] = args;
  if (!atCaller && !isAbsolute(target))
    die("the current directory cannot be resolved, so a relative transcript path cannot be either");
  const c = isatty(1) ? ANSI : PLAIN;
  try {
    if (mode === "file") {
      renderBytes(readFileSync(target), c);
      out("\n");
    } else {
      follow(target, c);
    }
  } catch (e) {
    // A reader that closed the pipe early (`| head`) ends the run the way the
    // shell's SIGPIPE did: silently, 128+13.
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    die(e instanceof Malformed ? `unrenderable transcript record: ${e.message}` : e instanceof Error ? e.message : String(e));
  }
}
