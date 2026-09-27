// pane-agent.ts - the JSON readers and writers of bin/ac-pane-agent.sh, and
// the timestamp reader of bin/ac-lib.sh's ac_transcript_final_epoch. THIS
// header is the authoritative spec. Both callers start it through
// bin/ac-bun.sh inside a subshell (ac_bun_exec execs); the caller's cwd
// arrives as the first argument and enterCaller (src/lib.ts) returns there, so
// a relative path is the caller's - and when that cwd has no name, a relative
// path can be neither read nor written.
//
//   seed-trust <cwd>
//     Marks <cwd> (the raw string, never normalized) trusted in ~/.claude.json
//     ($HOME with trailing slashes dropped, the passwd home when HOME is
//     unset). A file that cannot be read or parsed is left alone and never
//     created, and an entry whose hasTrustDialogAccepted and
//     hasCompletedProjectOnboarding are both truthy is left alone: exit 0.
//     Otherwise both become true - an existing key keeps its place, a new one
//     is appended - and the document is rewritten with a 2-space indent.
//     A document, `projects` or entry that is not an object: exit 1, nothing
//     written.
//   stop-hook <settings> <marker>
//     Merges {"hooks":[{"type":"command","command":"touch '<marker>'"}]} onto
//     the end of hooks.Stop in <settings> and rewrites it on one line. A file
//     that cannot be read, parsed, or is not an object starts from {}; a
//     `hooks` that is not an object is replaced in its place, a hooks.Stop
//     that is not an array starts empty. Of the existing groups, only OUR OWN
//     dead ones go: exactly one hook whose command is
//     touch '[<dir>/]ac-pane-turnend.<name>.<pid>', and whose pid answers
//     kill(pid, 0) with ESRCH (EPERM, and a pid past the C int range, keep it).
//     A write that fails: exit 1.
//   wrap-transcript
//     Prints stdin as the one-message transcript line
//     {"type": "assistant", "message": {"role": "assistant", "content":
//     [{"type": "text", "text": <stdin>}]}} and a newline. Stdin that is not
//     UTF-8 (a BOM is text): exit 1, nothing printed.
//   has-final-text <transcript>
//     Exit 0 when some line - split at \n, \r\n or \r, whitespace-stripped,
//     parsed - is an object of type "assistant" whose message.content text
//     parts join to non-blank text; exit 1 otherwise, and also whenever the
//     python reader this replaced raised: the file cannot be read or is not
//     UTF-8, a line parses to a non-object, a message is truthy but not an
//     object, content is truthy but not iterable, or a text part is not a
//     string.
//   iso-epoch <timestamp>
//     Prints the stamp's epoch second, truncated toward zero, and a newline.
//     Accepted: YYYY-MM-DD[(T| )HH:MM[:SS[(.|,)digits]][Z|(+|-)HH:MM]] naming
//     a real date and time, every Z read as +00:00; no offset is local time.
//     Anything else: exit 1, nothing printed.
//
// Each subcommand replaced a python3 snippet, and two of them rewrite the
// USER's files, so python's json module is the contract byte for byte, on
// both sides. Reading: strict UTF-8 (a BOM is not JSON), python's scanner
// grammar including NaN, Infinity and -Infinity, integers of any length, an
// object keeping a repeated key's first place and last value. Writing:
// json.dumps defaults - ", " and ": ", or "," and a newline under an indent;
// every character outside printable ASCII as \uXXXX (lowercase, an astral one
// as its surrogate pair); integers as read, floats as python's repr (1.0,
// 5e-05, 1e+16); key order kept; no trailing newline. A rewrite goes to
// <file>.ac-pane-agent (created 0666 less the umask; a stale one keeps its
// mode), which is then renamed over <file>, replacing a symlink rather than
// following it.
//
// Deliberate divergences from the python:
//   - iso-epoch takes only the calendar form above, because every producer
//     (Claude Code's toISOString, date -u) writes it. python accepted a wider,
//     partly version-dependent set: every version also read an hour-only
//     time, any single character between date and time and an offset with
//     seconds; 3.11+ added basic, week-date, 24:00 and short offsets; 3.9
//     refused a comma and any fraction but 3 or 6 digits. A stamp with no
//     offset is local time as Bun resolves TZ: a POSIX rule string such as
//     UTC-7, which libc applied, reads as UTC.
//   - Input (stdin, ~/.claude.json, settings, a transcript) is decoded as
//     strict UTF-8 under every locale. python used the locale's encoding:
//     under ISO8859-1 it mojibaked non-ASCII text and rewrote the user's file
//     that way, and under C, POSIX or unset it let invalid stdin through with
//     surrogate escapes.
//   - An integer past 4300 digits is read here where python refused it.
//   - Nesting: python's writers failed past about 993 levels (its reads went
//     to about 116k on 3.14, 993 on 3.9); here a rewrite fails past about
//     10000 and a read past about 40000, so between those limits trust is
//     seeded and the hook installed where python failed. A read too deep to
//     parse fails the run and leaves the file as it was - never the {} an
//     unreadable file starts from, which would drop its content.

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { userInfo } from "node:os";
import { isAbsolute } from "node:path";
import { die, enterCaller } from "./lib.ts";

export type Py = null | boolean | bigint | number | string | Py[] | Map<string, Py>;

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

export function decodeStrict(bytes: Uint8Array): string {
  return UTF8.decode(bytes);
}

const NUMBER = /-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/y;
const ESCAPE: Record<string, string> = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
const LITERALS: [string, Py][] = [["null", null], ["true", true], ["false", false], ["NaN", NaN], ["Infinity", Infinity], ["-Infinity", -Infinity]];

export function loads(s: string): Py {
  let i = 0;
  const bad = (): never => {
    throw new SyntaxError(`not JSON at offset ${i}`);
  };
  const ws = () => {
    while (i < s.length && " \t\n\r".includes(s[i])) i++;
  };
  const string = (): string => {
    let out = "";
    let run = ++i;
    for (;;) {
      if (i >= s.length) bad();
      const c = s.charCodeAt(i);
      if (c === 0x22) {
        out += s.slice(run, i++);
        return out;
      }
      if (c === 0x5c) {
        out += s.slice(run, i);
        const e = s[i + 1];
        if (e === "u") {
          const hex = s.slice(i + 2, i + 6);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) bad();
          out += String.fromCharCode(parseInt(hex, 16));
          i += 6;
        } else if (e !== undefined && Object.hasOwn(ESCAPE, e)) {
          out += ESCAPE[e];
          i += 2;
        } else bad();
        run = i;
        continue;
      }
      if (c < 0x20) bad();
      i++;
    }
  };
  const value = (): Py => {
    if (s[i] === '"') return string();
    if (s[i] === "{") {
      const obj = new Map<string, Py>();
      i++;
      ws();
      if (s[i] === "}") {
        i++;
        return obj;
      }
      for (;;) {
        if (s[i] !== '"') bad();
        const key = string();
        ws();
        if (s[i] !== ":") bad();
        i++;
        ws();
        obj.set(key, value());
        ws();
        if (s[i] === "}") {
          i++;
          return obj;
        }
        if (s[i] !== ",") bad();
        i++;
        ws();
      }
    }
    if (s[i] === "[") {
      const arr: Py[] = [];
      i++;
      ws();
      if (s[i] === "]") {
        i++;
        return arr;
      }
      for (;;) {
        arr.push(value());
        ws();
        if (s[i] === "]") {
          i++;
          return arr;
        }
        if (s[i] !== ",") bad();
        i++;
        ws();
      }
    }
    for (const [literal, v] of LITERALS)
      if (s.startsWith(literal, i)) {
        i += literal.length;
        return v;
      }
    NUMBER.lastIndex = i;
    const m = NUMBER.exec(s) ?? bad();
    i = NUMBER.lastIndex;
    return m[1] === undefined && m[2] === undefined ? BigInt(m[0]) : Number(m[0]);
  };
  ws();
  const v = value();
  ws();
  if (i !== s.length) bad();
  return v;
}

function floatRepr(x: number): string {
  if (Number.isNaN(x)) return "NaN";
  if (x === Infinity) return "Infinity";
  if (x === -Infinity) return "-Infinity";
  if (x === 0) return Object.is(x, -0) ? "-0.0" : "0.0";
  const sign = x < 0 ? "-" : "";
  // toExponential() with no argument gives the shortest round-trip digits,
  // the same digits python's repr chooses; only the layout differs.
  const [mantissa, e] = Math.abs(x).toExponential().split("e");
  const digits = mantissa.replace(".", "");
  const exp = Number(e);
  const point = exp + 1;
  if (point <= -4 || point > 16)
    return `${sign}${digits[0]}${digits.length > 1 ? `.${digits.slice(1)}` : ""}e${exp < 0 ? "-" : "+"}${String(Math.abs(exp)).padStart(2, "0")}`;
  if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`;
  if (point >= digits.length) return `${sign}${digits}${"0".repeat(point - digits.length)}.0`;
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
}

const SHORT: Record<number, string> = { 0x08: "\\b", 0x09: "\\t", 0x0a: "\\n", 0x0c: "\\f", 0x0d: "\\r" };

function jsonString(s: string): string {
  let out = '"';
  for (let k = 0; k < s.length; k++) {
    const c = s.charCodeAt(k);
    if (c === 0x22) out += '\\"';
    else if (c === 0x5c) out += "\\\\";
    else if (c >= 0x20 && c <= 0x7e) out += s[k];
    else out += SHORT[c] ?? `\\u${c.toString(16).padStart(4, "0")}`;
  }
  return `${out}"`;
}

export function dumps(v: Py, indent?: number, level = 1): string {
  if (v === null) return "null";
  if (v === true) return "true";
  if (v === false) return "false";
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "number") return floatRepr(v);
  if (typeof v === "string") return jsonString(v);
  const open = indent === undefined ? "" : `\n${" ".repeat(indent * level)}`;
  const close = indent === undefined ? "" : `\n${" ".repeat(indent * (level - 1))}`;
  const sep = indent === undefined ? ", " : `,${open}`;
  if (Array.isArray(v)) return v.length ? `[${open}${v.map((x) => dumps(x, indent, level + 1)).join(sep)}${close}]` : "[]";
  return v.size ? `{${open}${[...v].map(([k, x]) => `${jsonString(k)}: ${dumps(x, indent, level + 1)}`).join(sep)}${close}}` : "{}";
}

export function truthy(v: Py | undefined): boolean {
  if (v === undefined || v === null || v === false) return false;
  if (v === true) return true;
  if (typeof v === "bigint") return v !== 0n;
  if (typeof v === "number") return Number.isNaN(v) || v !== 0;
  if (typeof v === "string" || Array.isArray(v)) return v.length > 0;
  return v.size > 0;
}

// python's str.isspace(), which is neither JS \s (that takes U+FEFF and leaves
// U+001C-U+001F and U+0085) nor the shell's [:space:].
const PY_SPACE = "[\\t\\n\\v\\f\\r\\x1c-\\x20\\x85\\xa0\\u{1680}\\u{2000}-\\u{200a}\\u{2028}\\u{2029}\\u{202f}\\u{205f}\\u{3000}]";
const PY_STRIP = new RegExp(`^${PY_SPACE}+|${PY_SPACE}+$`, "gu");

export function strip(s: string): string {
  return s.replace(PY_STRIP, "");
}

function child(d: Py, key: string): Map<string, Py> {
  if (!(d instanceof Map)) throw new TypeError(`not an object where ${JSON.stringify(key)} belongs`);
  if (!d.has(key)) d.set(key, new Map());
  const v = d.get(key);
  if (!(v instanceof Map)) throw new TypeError(`${JSON.stringify(key)} is not an object`);
  return v;
}

export function seedTrust(doc: Py, cwd: string): boolean {
  const entry = child(child(doc, "projects"), cwd);
  if (truthy(entry.get("hasTrustDialogAccepted")) && truthy(entry.get("hasCompletedProjectOnboarding"))) return false;
  entry.set("hasTrustDialogAccepted", true);
  entry.set("hasCompletedProjectOnboarding", true);
  return true;
}

const OUR_HOOK = /^touch '(?:[^\n]*\/)?ac-pane-turnend\.[^/']*\.([0-9]+)'\n?$/;

export function pidGone(pid: bigint): boolean {
  if (pid > 2147483647n) return false;
  try {
    process.kill(Number(pid), 0);
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "ESRCH";
  }
  return false;
}

export function mergeStopHook(doc: Py | undefined, marker: string, gone: (pid: bigint) => boolean): Map<string, Py> {
  const d = doc instanceof Map ? doc : new Map<string, Py>();
  const h = d.get("hooks");
  const hooks = h instanceof Map ? h : new Map<string, Py>();
  const s = hooks.get("Stop");
  const stop = (Array.isArray(s) ? s : []).filter((group) => {
    if (!(group instanceof Map)) return true;
    const inner = group.get("hooks");
    if (!Array.isArray(inner) || inner.length !== 1 || !(inner[0] instanceof Map)) return true;
    const command = inner[0].get("command");
    const m = typeof command === "string" ? OUR_HOOK.exec(command) : null;
    return m === null || !gone(BigInt(m[1]));
  });
  stop.push(new Map([["hooks", [new Map<string, Py>([["type", "command"], ["command", `touch '${marker}'`]])]]]));
  hooks.set("Stop", stop);
  d.set("hooks", hooks);
  return d;
}

export function wrapTranscript(text: string): string {
  const part = new Map<string, Py>([["type", "text"], ["text", text]]);
  const message = new Map<string, Py>([["role", "assistant"], ["content", [part]]]);
  return `${dumps(new Map<string, Py>([["type", "assistant"], ["message", message]]))}\n`;
}

export function hasFinalText(text: string): boolean {
  let found = false;
  for (const raw of text.split(/\r\n|\r|\n/)) {
    const line = strip(raw);
    if (!line) continue;
    let d: Py;
    try {
      d = loads(line);
    } catch {
      continue;
    }
    if (!(d instanceof Map)) return false;
    if (d.get("type") !== "assistant") continue;
    const m = d.get("message");
    const message = truthy(m) ? m! : new Map<string, Py>();
    if (!(message instanceof Map)) return false;
    const c = message.get("content");
    const content = truthy(c) ? c! : [];
    const parts = Array.isArray(content) ? content : content instanceof Map ? [...content.keys()] : typeof content === "string" ? [...content] : null;
    if (parts === null) return false;
    let joined = "";
    for (const part of parts) {
      if (!(part instanceof Map) || part.get("type") !== "text") continue;
      const t = part.has("text") ? part.get("text") : "";
      if (typeof t !== "string") return false;
      joined += t;
    }
    if (strip(joined)) found = true;
  }
  return found;
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(?:([+-])(\d{2}):(\d{2}))?)?$/;

export function isoEpoch(stamp: string): number | null {
  const m = ISO.exec(stamp.replaceAll("Z", "+00:00"));
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1, 7).map((x) => Number(x ?? 0));
  const micros = Number(`${m[7] ?? ""}000000`.slice(0, 6));
  const utc = new Date(0);
  utc.setUTCFullYear(y, mo - 1, d);
  // A day or month out of range rolls the date into another month.
  if (y < 1 || utc.getUTCMonth() !== mo - 1 || h > 23 || mi > 59 || s > 59) return null;
  let seconds: number;
  if (m[8] !== undefined) {
    const offset = (m[8] === "-" ? -1 : 1) * (Number(m[9]) * 3600 + Number(m[10]) * 60);
    if (Math.abs(offset) >= 86400) return null;
    utc.setUTCHours(h, mi, s, 0);
    seconds = utc.getTime() / 1000 - offset;
  } else {
    const local = new Date(0);
    local.setFullYear(y, mo - 1, d);
    local.setHours(h, mi, s, 0);
    seconds = local.getTime() / 1000;
  }
  const epoch = Math.trunc(seconds + micros / 1e6);
  return epoch === 0 ? 0 : epoch;
}

function claudeJson(): string {
  return `${(process.env.HOME ?? userInfo().homedir).replace(/\/+$/, "")}/.claude.json`;
}

function main(args: string[], atCaller: boolean): void | Promise<void> {
  const reachable = (path: string): string => {
    if (!atCaller && !isAbsolute(path)) throw new Error(`the caller's directory has no name, so ${path} cannot be resolved`);
    return path;
  };
  const readJson = (path: string): Py => loads(decodeStrict(readFileSync(reachable(path))));
  const publish = (path: string, text: string): void => {
    const tmp = `${reachable(path)}.ac-pane-agent`;
    writeFileSync(tmp, text);
    renameSync(tmp, path);
  };
  const [sub, ...rest] = args;
  const arity: Record<string, number> = { "seed-trust": 1, "stop-hook": 2, "wrap-transcript": 0, "has-final-text": 1, "iso-epoch": 1 };
  if (sub === undefined || arity[sub] !== rest.length)
    die("usage: pane-agent.ts seed-trust <cwd> | stop-hook <settings> <marker> | wrap-transcript | has-final-text <transcript> | iso-epoch <timestamp>");
  switch (sub) {
    case "seed-trust": {
      const file = claudeJson();
      let doc: Py;
      try {
        doc = readJson(file);
      } catch {
        return;
      }
      if (seedTrust(doc, rest[0])) publish(file, dumps(doc, 2));
      return;
    }
    case "stop-hook": {
      let doc: Py | undefined;
      try {
        doc = readJson(rest[0]);
      } catch (e) {
        // Too deep for the stack is not unreadable: starting from {} would
        // rewrite the file without its content.
        if (e instanceof RangeError) throw e;
      }
      publish(rest[0], dumps(mergeStopHook(doc, rest[1], pidGone)));
      return;
    }
    case "wrap-transcript":
      return Bun.stdin.arrayBuffer().then(async (b) => {
        await Bun.write(Bun.stdout, wrapTranscript(decodeStrict(new Uint8Array(b))));
      });
    case "has-final-text": {
      let text: string | null = null;
      try {
        text = decodeStrict(readFileSync(reachable(rest[0])));
      } catch {}
      process.exitCode = text !== null && hasFinalText(text) ? 0 : 1;
      return;
    }
    case "iso-epoch": {
      const epoch = isoEpoch(rest[0]);
      if (epoch === null) {
        process.exitCode = 1;
        return;
      }
      return Bun.write(Bun.stdout, `${epoch}\n`).then(() => {});
    }
  }
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  try {
    await main(args, atCaller);
  } catch (e) {
    die(e instanceof Error ? e.message : String(e));
  }
}
