// scene.ts - the L2 SCENE store: one consolidated, heat-tracked topic file
// between L1 (repo-knowledge facts, learnings bullets) and L3 (the always-loaded
// CREWMATE-learned layer). The entry is bin/ac-scene.sh (a shim that starts
// this file through bin/ac-bun.sh); THIS header is the authoritative spec, and
// the bash original it replaced stays frozen at tests/fixtures/ac-scene.sh as
// the oracle the differential leg of tests/sh/ac-scene.test.sh holds this
// module to.
//
// Usage:
//   ac-scene.sh new    <slug> --summary <line> [--file <path>]   (body on stdin)
//   ac-scene.sh update <slug> [--summary <line>] [--file <path>] (body on stdin)
//   ac-scene.sh merge  <src>... --into <slug> --summary <line> [--file <path>]
//   ac-scene.sh show   <slug> [--cite]
//   ac-scene.sh list
//   ac-scene.sh -h | --help
//
// WHY IT EXISTS: the fleet had L0 (data/<family>/room.md), L1 (repo-knowledge +
// the learnings ledger) and L3 (CREWMATE-learned.md), and NOTHING between L1 and
// L3. Knowledge too cross-cutting for one repo-knowledge line and too big for
// the always-loaded budget had nowhere to consolidate, so it stayed flat, and
// re-entering a topic meant re-deriving it from dozens of L1 lines every time.
// A scene is that missing read: ONE file that restores a topic's working context.
//
// PULL, NEVER PUSH - the load-bearing difference from CREWMATE-learned: a scene
// is read on purpose (intake, recall, a chief orienting), never seeded into a
// crew worktree and never auto-loaded into any prompt. That is why a scene takes
// the repo-knowledge TRUST TIER (a chief may write one by hand, like
// `ac-know.sh add`) instead of the always-loaded layer's gate tier: nothing it
// says enters a context that did not ask for it. A consumer treats scene content
// as EVIDENCE to cite, never as instructions to obey.
//
// THE STORE: $AC_HOME/records/scenes/<slug>.md, slug [a-z0-9][a-z0-9-]* (ASCII
// under any locale). Four fixed head lines, then free markdown:
//
//   # Scene: <slug>
//   META: created=<iso> updated=<iso> heat=<n>
//   summary: <one line - what this scene restores context for>
//   <blank>
//   <body>
//
// <iso> is date(1)'s `-u +%Y-%m-%dT%H:%M:%SZ`. The head is READ BY NAME and
// POSITION the way the original's sed/tr read it: a META field is the first
// space-separated token of line 2 starting `<key>=`, whatever line 2 starts
// with, "" when absent (heat then counts as 0, created as now, updated as
// ""); the summary is line 3 past `summary: `, "" when line 3 is not one; a
// head value drops its NUL bytes as `$(...)` dropped them; the body is
// everything after the fourth LF. Readers of this shape outside this
// module: bin/ac-session-start.sh (count, hottest), bin/ac-know.sh (recall,
// cite's open command), bin/ac-learn.sh (`list` is a DISTILL source verbatim;
// stale by `updated=`), src/brain.ts (kind scene, scenes-archive excluded).
// A heat is read as bash arithmetic read it: a leading zero makes it octal
// (010 is 8), it sits in 64 bits, and one that is not a run of digits, or
// that arithmetic refuses (08), is refused by every verb that would add to
// it (`scene '<slug>' carries a META heat that is not a count (heat=<v>) -
// fix line 2 by hand, nothing written`).
//
// `summary:` is the cheap index `list` and any recall verb rank against without
// opening bodies, so it is single-line and refuses newline/CR/`|` exactly as
// ac-know.sh's fields do (the same record-injection posture). The body is
// `--file <path>` (a regular file) or else ALL of stdin, read as the original's
// `$(cat)` read it: every NUL byte dropped, every trailing LF stripped, bytes
// otherwise untouched, then written back with exactly ONE trailing LF. Empty
// after stripping is refused (`the scene body is empty ...`); over 16384 bytes
// is refused (`the scene body exceeds its 16384-byte cap ...`). `--file ''`
// reads stdin. Bodies, summaries and files are bytes in, bytes out.
//
// HEAT is TOUCHES, not edits: `show --cite` (+1), `update` (+1), and `merge`
// (sum of every merged scene, +1). It answers ONE question - which scene to
// merge away first - and a read-count answers it better than an edit-count.
// A never-touched scene is the coldest by construction.
//
// THE TIERED CAP is the whole reason this store cannot rot into a second flat
// pile. `config/scene-max` (default 30; not a run of digits, or one that
// arithmetic refuses -> `config/scene-max must be a count (got: '<v>')`) caps
// the FILE COUNT - the lines of `ls records/scenes/*.md`, ls itself spawned, so
// a directory named like a scene adds its heading and entries as it did - and
// the tier changes which verbs are legal:
//
//   count <  max-1   GREEN   every verb
//   count == max-1   AMBER   `new` refuses - one slot left is not a slot
//                            (max-1 as `$(( ))` read it: 010 is 8)
//   count >= max     RED     `new` refuses AND names the 3 coldest scenes
//                            (max as `-ge` read it: decimal, 010 is 10)
//                            (lowest heat, then oldest updated) plus the exact
//                            merge command shape
//
// The coldest three are `<heat|0> TAB <updated|''> TAB <slug>` rows through
// `sort -t TAB -k1,1n -k2,2 | head -3` under LC_ALL=C (the binary is spawned,
// so its numeric reading of an odd heat is the original's), printed as
// `  <slug> (heat <h>, updated <u>)` the way `IFS=TAB read -r` split them: an
// empty updated collapses, so the slug lands in the updated column and the
// slug column is empty - a wire quirk that changes the result, kept.
//
// `update` and `merge` are legal at EVERY tier - the pressure must always have
// an exit. Nothing auto-merges and nothing is ever deleted: `merge` moves each
// source scene VERBATIM (mv) to records/scenes/scenes-archive/<slug>.md,
// overwriting an older archive of the same slug, so consolidation is
// recoverable and the machine never destroys a judgment it did not make.
//
// VERBS, each in its check order (the first failing check is the refusal):
//   new    flags (`--summary <v>`, `--file <v>`; a flag as the last word ->
//          `<flag> needs a value`; anything else -> `unknown flag: <x>`; the
//          first word after the verb is the slug, flag-looking or not) -> slug
//          (`no slug given` | `slug must match [a-z0-9][a-z0-9-]* (got: '<s>')`
//          | `slug must start with [a-z0-9] (got: '<s>')`) -> summary
//          (`--summary is required and must be non-empty` | `--summary must be
//          a single line (no newline or carriage return)` | `'|' cannot appear
//          in --summary (it is the field separator of the records it sits
//          beside)`) -> body -> lock -> exists (`scene '<slug>' already exists -
//          use \`update\` (a new scene never silently replaces one)`) -> tier,
//          read INSIDE the lock so two writers never see the same free slot ->
//          write heat=1, created=updated=now. Prints `created <path> (heat 1)`.
//   update flags -> slug -> summary (only when given) -> body -> lock -> exists
//          (`no scene '<slug>' to update - \`new\` creates one`) -> write with
//          created kept (now when the head lacks it), heat+1, the given summary
//          or line 3's. Prints `updated <path> (heat <n>)`.
//   merge  flags (`--into <v>` too; a bare word is a source, in order,
//          duplicates kept; `-x` -> unknown flag) -> into slug -> summary ->
//          `merge needs at least one source scene (merge <src>... --into
//          <slug>)` -> each source slug -> body -> lock -> every source exists,
//          in order (`merge source '<s>' does not exist - nothing moved`) ->
//          `--into '<x>' exists and was not among the merged sources - name it
//          as a source, or pick a fresh slug - nothing moved` -> heat = sum + 1,
//          created = byte-minimum of the non-empty source created= (now when
//          none) -> archive each source -> write into. Prints `merged <s>...
//          into <path> (heat <n>); sources archived verbatim in <archive dir>`.
//   show   flags (`--cite`) -> slug -> `no scene '<slug>' (ac-scene.sh list
//          shows the store)` -> with --cite: lock, rewrite with heat+1,
//          updated=now, the body after the fourth LF (a hand-written scene
//          gains the head) -> print the file bytes.
//   list   `scenes: <n>/<max> in <dir>` then one row per scene in byte order,
//          `  <slug>  heat=<h|0>  updated=<u|''>  <summary>`; <max> is the raw
//          config value; no body reaches the output. No scenes (dir
//          absent or empty): exit 1 printing NOTHING - the original's errexit
//          fired on the empty `ls` of its count before the `no scenes yet in
//          <dir> (0/<max>)` line it meant to print; kept as the wire reads
//          (bin/ac-learn.sh's DISTILL prep already takes the failure as an
//          empty source) until the defect slice that restores that line. That
//          line IS reached when ls succeeds with no lines (a lone directory
//          named like a scene), exit 0.
// Scene refusals are prefixed `scene rejected: `. Every verb mints records/;
// the lock mints records/scenes/.
//
// WRITER SYMMETRY: the DISTILL transaction (bin/ac-learn.sh) lands `kind:
// scene` candidates by CALLING THESE VERBS, never by writing the files itself,
// so the tier and the lock bind the machine writer exactly as they bind a hand.
//
// THE LOCK: records/scenes/.lock (mkdir + pid file, the ac_lock_acquire
// grammar through its twin, so a bash and a TypeScript writer exclude each
// other) for new/update/merge/show --cite; 30 tries one `sleep 1` apart (the
// PATH's sleep, so a stub fast-forwards it); `scene store lock <dir> could not
// be acquired within 30s - nothing written`. Every write is atomic (tmp+mv)
// under the lock; a refused lock writes nothing, and every refusal inside the
// lock releases it.
//
// Exit: 0 ok; 1 on every refusal (`ERROR: <msg>` on stderr) and on usage
// (-h | --help | no verb: this header on stdout); `unknown verb: <x>` exit 1.
//
// NAMED DIVERGENCES from the frozen original (tests/sh/ac-scene.test.sh): the
// usage text is this header, not its Usage block alone; a tier refusal, a
// scene-max that is not a count and a heat that is not a count release the
// lock (the original left its lock dir and a mktemp body file behind, and
// died in bash's own arithmetic noise on the heat); a homeless `show` refuses
// once (the original printed `no scene` after the home refusal); scenes list
// in byte order under every locale (the original's glob followed libc
// collation, the same order for [a-z0-9-] names on this host).

import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { configRead, die, enterCaller, iso, lockAcquire, lockRelease, recordsDir } from "./lib.ts";

const BODY_MAX = 16384;
const LF = Buffer.from("\n");
const b = (s: string): Buffer => Buffer.from(s, "latin1");
// A path or an argument is UTF-8 text, shown as its bytes beside file bytes.
const shown = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const say = (s: string): void => {
  writeSync(1, b(`${s}\n`));
};
const reject = (msg: string): never => die(`scene rejected: ${msg}`);
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const byBytes = (x: string, y: string): number => Buffer.compare(Buffer.from(x), Buffer.from(y));

let held = "";
// A refusal inside the lock releases it first: the original died with the
// dir in place, which only its dead pid let the next writer reclaim.
function refuse(msg: string | Uint8Array): never {
  if (held !== "") lockRelease(held);
  held = "";
  die(msg);
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(1);
}

// --- the store ----------------------------------------------------------------

const scenesDir = (): string => join(recordsDir(), "scenes");
const sceneFile = (slug: string): string => join(scenesDir(), `${slug}.md`);
const archiveDir = (): string => join(scenesDir(), "scenes-archive");

// The `*.md` glob in byte order: no dot entries, any type.
function sceneNames(): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(scenesDir());
  } catch {}
  return names.filter((n) => !n.startsWith(".") && n.endsWith(".md")).sort(byBytes);
}

// Lines as the original's sed numbered them: latin1, split on LF, the empty
// tail after a final LF being no line.
function headLines(f: string): string[] {
  if (!isFile(f)) return [];
  const lines = readFileSync(f, "latin1").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

// A head value as `$(...)` returned it: NUL bytes gone.
const subst = (s: string): string => s.replace(/\0/g, "");

function sceneMeta(f: string, key: string): string {
  const l2 = headLines(f)[1];
  if (l2 === undefined) return "";
  for (const tok of l2.split(" ")) if (tok.startsWith(`${key}=`)) return subst(tok.slice(key.length + 1));
  return "";
}

function sceneSummary(f: string): Buffer {
  const l3 = headLines(f)[2];
  return b(l3 !== undefined && l3.startsWith("summary: ") ? subst(l3.slice("summary: ".length)) : "");
}

// A run of digits as `$(( ))` read it: octal behind a leading zero (so 08 is
// no number), 64 bits wrapping; null where bash's arithmetic refused.
function shellInt(digits: string): bigint | null {
  if (/^0[0-9]*[89]/.test(digits)) return null;
  return BigInt.asIntN(64, digits.length > 1 && digits.startsWith("0") ? BigInt(`0o${digits}`) : BigInt(digits));
}

function sceneHeat(f: string, slug: string): bigint {
  const h = sceneMeta(f, "heat");
  if (h === "") return 0n;
  const v = /^[0-9]+$/.test(h) ? shellInt(h) : null;
  if (v === null) refuse(b(`scene '${shown(slug)}' carries a META heat that is not a count (heat=${h}) - fix line 2 by hand, nothing written`));
  return v;
}

// `ls *.md | wc -l`: ls itself, so a directory named like a scene counts its
// heading, its separator and its entries exactly as it did there.
function sceneCount(): bigint {
  const names = sceneNames();
  if (names.length === 0) return 0n;
  const r = Bun.spawnSync(["ls", ...names], { cwd: scenesDir(), stdin: "ignore", stdout: "pipe", stderr: "ignore" });
  return BigInt((r.stdout.toString("latin1").match(/\n/g) ?? []).length);
}

// `tail -n +5`: the bytes after the fourth LF, none when there are fewer.
function sceneBody(f: string): Buffer {
  const all = readFileSync(f);
  let at = 0;
  for (let n = 0; n < 4; n++) {
    at = all.indexOf(10, at);
    if (at < 0) return Buffer.alloc(0);
    at++;
  }
  return all.subarray(at);
}

function assertSlug(s: string): void {
  if (s === "") reject("no slug given");
  if (/[^a-z0-9-]/.test(s)) reject(`slug must match [a-z0-9][a-z0-9-]* (got: '${s}')`);
  if (/^[^a-z0-9]/.test(s)) reject(`slug must start with [a-z0-9] (got: '${s}')`);
}

function assertSummary(v: string): void {
  if (v === "") reject("--summary is required and must be non-empty");
  if (/[\n\r]/.test(v)) reject("--summary must be a single line (no newline or carriage return)");
  if (v.includes("|")) reject("'|' cannot appear in --summary (it is the field separator of the records it sits beside)");
}

function readBody(ff: string): Buffer {
  let raw: Buffer;
  if (ff !== "") {
    if (!isFile(ff)) die(`--file does not exist: ${ff}`);
    raw = readFileSync(ff);
  } else {
    raw = readFileSync(0);
  }
  const kept = Buffer.from(raw.filter((x) => x !== 0));
  let end = kept.length;
  while (end > 0 && kept[end - 1] === 10) end--;
  if (end === 0) reject("the scene body is empty (a scene with no body is a summary, not a scene)");
  if (end > BODY_MAX) reject(`the scene body exceeds its ${BODY_MAX}-byte cap - split it into two scenes, or consolidate harder (a cap keeps a recall budget meaningful)`);
  return Buffer.concat([kept.subarray(0, end), LF]);
}

function sceneWrite(slug: string, created: string, heat: bigint, summary: Buffer, body: Buffer): void {
  const f = sceneFile(slug);
  mkdirSync(dirname(f), { recursive: true });
  const composed = Buffer.concat([b(`# Scene: ${slug}\nMETA: created=${created} updated=${iso()} heat=${heat}\nsummary: `), summary, b("\n\n"), body]);
  // Exclusive, unlike the original's `$f.tmp.$$`: a path already at the name
  // (a symlink back to the scene, say) is never written through - the next
  // name is tried, and the rename stays a sibling's.
  let tmp = `${f}.tmp`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, composed, { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      tmp = `${f}.tmp.${i}`;
    }
  }
  renameSync(tmp, f);
}

const sleepOne = (): void => {
  Bun.spawnSync(["sleep", "1"], { stdin: "ignore", stdout: "ignore", stderr: "ignore", env: process.env });
};

function lock(): void {
  const d = scenesDir();
  mkdirSync(d, { recursive: true });
  const l = join(d, ".lock");
  if (!lockAcquire(l, 30, sleepOne)) die(`scene store lock ${l} could not be acquired within 30s - nothing written`);
  held = l;
}

function unlock(): void {
  lockRelease(held);
  held = "";
}

function coldest(n: number): string[] {
  const dir = scenesDir();
  const rows: string[] = [];
  for (const name of sceneNames()) {
    const f = join(dir, name);
    if (!isFile(f)) continue;
    rows.push(`${sceneMeta(f, "heat") || "0"}\t${sceneMeta(f, "updated")}\t${shown(name.slice(0, -3))}\n`);
  }
  const r = Bun.spawnSync(["sort", "-t", "\t", "-k1,1n", "-k2,2"], { stdin: b(rows.join("")), stdout: "pipe", stderr: "inherit", env: { ...process.env, LC_ALL: "C" } });
  const sorted = r.stdout.toString("latin1").split("\n");
  if (sorted[sorted.length - 1] === "") sorted.pop();
  return sorted.slice(0, n).map((l) => {
    const m = /^\t*([^\t]*)\t*([^\t]*)\t*(.*?)\t*$/.exec(l)!;
    return `  ${m[3]} (heat ${m[1]}, updated ${m[2]})`;
  });
}

// The tier gate guards `new` ONLY: the refusal text, "" when a slot is free.
function tierRefusal(): string {
  const max = configRead("scene-max", "30");
  if (!/^[0-9]+$/.test(max)) return `config/scene-max must be a count (got: '${shown(max)}')`;
  const n = sceneCount();
  // `-ge` read the cap in decimal; `$(( max - 1 ))` read it as arithmetic.
  if (n >= BigInt(max))
    return `scene store is FULL at the cap (${n}/${max}, config/scene-max) - merge before adding. Coldest first:\n${coldest(3).join("\n")}\n  ac-scene.sh merge <slug-a> <slug-b> --into <slug-a> --summary '<line>' --file <body>`;
  const m = shellInt(max);
  if (m === null) return `config/scene-max must be a count (got: '${shown(max)}')`;
  if (n === m - 1n)
    return `scene store is one slot from the cap (${n}/${max}, config/scene-max) - update an existing scene or merge two, rather than spending the last slot. Coldest first:\n${coldest(3).join("\n")}`;
  return "";
}

function flags(words: string[], known: string[], bare?: (w: string) => void): Map<string, string> {
  const got = new Map<string, string>();
  for (let i = 0; i < words.length; ) {
    const w = words[i];
    if (known.includes(w)) {
      if (i + 1 >= words.length) die(`${w} needs a value`);
      got.set(w, words[i + 1]);
      i += 2;
    } else if (bare && !w.startsWith("-")) {
      bare(w);
      i++;
    } else die(`unknown flag: ${w}`);
  }
  return got;
}

// --- verbs --------------------------------------------------------------------

function cmdNew(slug: string, rest: string[]): void {
  const f = flags(rest, ["--summary", "--file"]);
  const summary = f.get("--summary") ?? "";
  assertSlug(slug);
  assertSummary(summary);
  const body = readBody(f.get("--file") ?? "");
  lock();
  if (existsSync(sceneFile(slug))) refuse(`scene '${slug}' already exists - use \`update\` (a new scene never silently replaces one)`);
  const tier = tierRefusal();
  if (tier !== "") refuse(b(tier));
  sceneWrite(slug, iso(), 1n, Buffer.from(summary, "utf8"), body);
  unlock();
  say(`created ${shown(sceneFile(slug))} (heat 1)`);
}

function cmdUpdate(slug: string, rest: string[]): void {
  const f = flags(rest, ["--summary", "--file"]);
  assertSlug(slug);
  if (f.has("--summary")) assertSummary(f.get("--summary")!);
  const body = readBody(f.get("--file") ?? "");
  lock();
  const file = sceneFile(slug);
  if (!isFile(file)) refuse(`no scene '${slug}' to update - \`new\` creates one`);
  const heat = sceneHeat(file, slug) + 1n;
  const summary = f.has("--summary") ? Buffer.from(f.get("--summary")!, "utf8") : sceneSummary(file);
  sceneWrite(slug, sceneMeta(file, "created") || iso(), heat, summary, body);
  unlock();
  say(`updated ${shown(file)} (heat ${heat})`);
}

function cmdMerge(rest: string[]): void {
  const srcs: string[] = [];
  const f = flags(rest, ["--into", "--summary", "--file"], (w) => srcs.push(w));
  const into = f.get("--into") ?? "";
  const summary = f.get("--summary") ?? "";
  assertSlug(into);
  assertSummary(summary);
  if (srcs.length === 0) reject("merge needs at least one source scene (merge <src>... --into <slug>)");
  for (const s of srcs) assertSlug(s);
  const body = readBody(f.get("--file") ?? "");
  lock();
  // Every source is validated before any moves: a half-done merge would leave
  // the store claiming a consolidation that never happened.
  for (const s of srcs) if (!isFile(sceneFile(s))) refuse(`merge source '${s}' does not exist - nothing moved`);
  if (!srcs.includes(into) && existsSync(sceneFile(into)))
    refuse(`--into '${into}' exists and was not among the merged sources - name it as a source, or pick a fresh slug - nothing moved`);
  let heat = 0n;
  let created = "";
  for (const s of srcs) {
    heat = BigInt.asIntN(64, heat + sceneHeat(sceneFile(s), s));
    // The merged scene inherits the OLDEST creation date it absorbs: the topic
    // is as old as the earliest thing that knew about it.
    const c = sceneMeta(sceneFile(s), "created");
    if (created === "" || (c !== "" && c < created)) created = c;
  }
  mkdirSync(archiveDir(), { recursive: true });
  for (const s of srcs) {
    // mv itself: an archive copy of the same slug is overwritten as mv
    // overwrites it, and a failure ends the run with mv's own status and line.
    const r = Bun.spawnSync(["mv", sceneFile(s), join(archiveDir(), `${s}.md`)], { stdout: "ignore", stderr: "inherit" });
    if (r.exitCode !== 0) {
      unlock();
      process.exit(r.exitCode ?? 1);
    }
  }
  heat = BigInt.asIntN(64, heat + 1n);
  sceneWrite(into, created || iso(), heat, Buffer.from(summary, "utf8"), body);
  unlock();
  say(`merged${srcs.map((s) => ` ${s}`).join("")} into ${shown(sceneFile(into))} (heat ${heat}); sources archived verbatim in ${shown(archiveDir())}`);
}

function cmdShow(slug: string, rest: string[]): void {
  let cite = false;
  for (const w of rest) {
    if (w === "--cite") cite = true;
    else die(`unknown flag: ${w}`);
  }
  assertSlug(slug);
  const file = sceneFile(slug);
  if (!isFile(file)) die(`no scene '${slug}' (ac-scene.sh list shows the store)`);
  if (cite) {
    // The bump rides the READ, exactly as ac-know.sh cite does: a counter left
    // to a second deliberate act is a counter nobody keeps.
    lock();
    const heat = BigInt.asIntN(64, sceneHeat(file, slug) + 1n);
    sceneWrite(slug, sceneMeta(file, "created") || iso(), heat, sceneSummary(file), sceneBody(file));
    unlock();
  }
  writeSync(1, readFileSync(file));
}

function cmdList(): void {
  const dir = scenesDir();
  const max = configRead("scene-max", "30");
  const names = sceneNames();
  // The original's `n="$(ls ... | wc -l)"` failed under pipefail+errexit on an
  // empty store, before its `no scenes yet` line: silent exit 1, kept.
  if (names.length === 0) process.exit(1);
  const n = sceneCount();
  // Reached only when ls listed something that holds no lines: a lone
  // directory named like a scene.
  if (n === 0n) {
    say(`no scenes yet in ${shown(dir)} (0/${shown(max)})`);
    return;
  }
  say(`scenes: ${n}/${shown(max)} in ${shown(dir)}`);
  for (const name of names) {
    const f = join(dir, name);
    if (!isFile(f)) continue;
    say(`  ${shown(name.slice(0, -3))}  heat=${sceneMeta(f, "heat") || "0"}  updated=${sceneMeta(f, "updated")}  ${sceneSummary(f).toString("latin1")}`);
  }
}

// --- dispatch -----------------------------------------------------------------

const { args } = enterCaller(process.argv.slice(2));
const [verb = "", ...rest] = args;
switch (verb) {
  case "new":
    cmdNew(rest[0] ?? "", rest.slice(1));
    break;
  case "update":
    cmdUpdate(rest[0] ?? "", rest.slice(1));
    break;
  case "merge":
    cmdMerge(rest);
    break;
  case "show":
    cmdShow(rest[0] ?? "", rest.slice(1));
    break;
  case "list":
    cmdList();
    break;
  case "-h":
  case "--help":
  case "":
    usage();
  default:
    die(`unknown verb: ${verb}`);
}
