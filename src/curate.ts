// curate.ts - fleet-local Curate maintenance. The entry is bin/ac-curate.sh
// (a shim that starts this file through bin/ac-bun.sh); THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-curate.sh as the oracle the differential leg of
// tests/sh/ac-curate.test.sh holds this module to.
//
// Usage:
//   ac-curate.sh learnings              # pointer-integrity check (PROPOSE ONLY)
//   ac-curate.sh captain [--apply]      # compatibility targeted mutation
//   ac-curate.sh backlog [--apply]      # compatibility targeted mutation
//   ac-curate.sh projects               # correctness-audit (PROPOSE ONLY)
//   ac-curate.sh skills-audit           # skill overlap + stale (PROPOSE ONLY)
//   ac-curate.sh skills-consolidate [--apply]  # diagnostic; --apply refuses
//   ac-curate.sh run [--dry-run]        # automatic policy + gated maintenance
// Every word after the verb must be --apply or --dry-run (repeats and both
// together pass), checked before the verb is read: anything else is `ERROR:
// unknown flag: <w>`. No verb, or an unknown one, is the one-line usage
// error. --apply is read only by captain, backlog and skills-consolidate,
// --dry-run only by run; elsewhere each is ignored (`run --apply` is the full
// automatic pass).
//
// Learning runs advance Curate's lock-protected generation/cadence. When
// `runs_since >= config/curate-every` (default 5), `ac-learn.sh run` calls this
// automatic `run`. There is no cron or daemon.
//
// Automatic `run` separates deterministic maintenance from semantic judgment:
//
// - captain.md: move only fully `SUPERSEDED` or non-standing
//   `COMPLETED`/`EXPIRED` blocks verbatim to captain-archive.md. Preserve one
//   stable archive link in captain.md. Live, standing, and partial rules remain.
// - backlog.md: retain the configured recent Done window and move older lines
//   verbatim to backlog-archive.md, while preserving live blocked-by and epic
//   dependencies.
// - a live `SUPERSEDES` ruling with one safely identifiable complete target,
//   an absent project registry entry, and a traceable umbrella-skill
//   consolidation become independent semantic subjects. A hash-bound
//   maintenance-gate `continue` applies each recoverable plan; `revise`
//   preserves it; ambiguity asks the captain.
// - a semantic subject with NO safe plan asks the captain and keeps cadence due
//   for ever, UNLESS `records/curate-acknowledged.md` records that the captain
//   already ruled on that exact material:
//   `- <subject> material=<sha256> ruling: <citation>`. Field 3 is the KEY and
//   the leading subject id is documentation only. The key is a sha256 over the
//   subject's OWN material - a captain subject's live and target rule BLOCKS in
//   full, a project subject's registry line, a skill subject's umbrella plus
//   body - never the index-derived subject id, which shifts whenever an earlier
//   captain.md block is added or removed, and never the containing file, whose
//   unrelated edits would otherwise wipe every acknowledgement. An acknowledged
//   subject prints `settled:` with its ruling, mutates nothing, and lets the run
//   reset cadence; edit that material and the same subject asks again. The ask
//   prints the paste-ready line, fingerprint included; deleting the line undoes
//   the acknowledgement. It can never hide a subject that became ACTIONABLE:
//   one with a safe plan goes to the maintenance gate and never reaches here.
//   Material this run cannot identify has no key at all: hashing nothing would
//   give every such subject the one empty-string digest.
// - learning-pointer defects and stale/overlap signals remain non-mutating
//   findings until a safe semantic plan exists.
//
// Automatic changes are first produced in a shadow home, converted into one
// closed action plan, bound to a deterministic policy receipt, and applied by
// the shared fleet maintenance transaction (maintenanceApply, src/lib.ts - the
// one Learning calls too, the twin of the bash ac_maintenance_apply frozen at
// tests/fixtures/ac-maintenance-retired.sh, the two pinned together by
// tests/ts/curate.test.ts). That boundary owns the fleet-wide
// lock, pre-write backup, staged hashes (pre-state hashes bound to the
// pre-pass snapshot, so a write landing mid-run is refused rather than
// reverted), atomic replacement, crash journal, and idempotent replay.
// `move-skill` copies and verifies every staged file before removing its live
// source, while the active/archive pointer ledgers participate in the same
// plan. The captured Curate generation resets only after every subject
// settles; an unresolved `ask-captain` keeps the run open and cadence due.
// `run --dry-run` creates no backup, receipt, mutation, or cadence reset.
//
// RUN, in order: the generation is read; the run dir data/curate-<epoch>-<pid>
// is minted with shadow/{records,state,skills}, staged/records, pristine,
// plans and gates/deterministic-records; input-manifest.json binds the live
// hashes of captain.md, captain-archive.md, backlog.md and backlog-archive.md
// (`-` for an absent one; a symlink or non-file refuses `ERROR: Curate input
// manifest refused a non-file or symlink`); each is copied to the shadow and
// its hash written to pristine/<f>. The TEST SEAM runs next: with
// AC_TEST_HOOKS=1 AND an executable AC_CURATE_SNAPSHOT_HOOK, the hook gets
// the records dir (its status ignored) - double-keyed, so one inherited
// variable cannot make a production run exec a file. Then the learnings,
// projects and skills-audit passes on the live home, and the captain and
// backlog passes (apply, no backup line) on the shadow into report.md, whose
// shadow paths are rewritten to the live records (NULs dropped, one trailing
// LF) and printed. Each shadow file that differs from its live record is
// staged and planned (append-archive for an archive, else rewrite-registry,
// old_sha256 the PRISTINE hash) into plans/deterministic-records.json, bound
// by a `repository-policy` continue receipt the run then validates like any
// other and applies - a zero-action plan included. Then the semantic subjects
// (captain, projects, skills), each a hash-bound plan for the maintenance gate
// `${AC_GATE:-<this bin>/ac-gate.sh} maintenance --mode curate --run <run>
// --subject <s> --manifest <m> --plan <p>`, its merged output printed
// indented, a non-zero status folded by maintenanceGateFailureReason
// (src/lib.ts), its receipt validated by this module, every ask posted to the curate
// room through <this bin>/ac-room.sh. Unresolved, the run ends `== curate pass
// open ... ==`; else the cadence resets (a newer generation or a busy lock is
// the run's WARN) and it ends `== curate pass complete ... ==`.
//
// `learnings` validates each canonical `- [distilled -> <name>]` row against the
// body its OWN first link names, resolved relative to the ledger's directory -
// `[skill](../skills/<name>/SKILL.md)` for a skill, `[lesson](../CREWMATE-learned.md)`
// for a crewmate-landed lesson - mirroring the writer at ledgerStage
// (src/learn.ts). It does NOT derive the target from the slug: that made a
// correctly-retired skill package read BROKEN and so required the lesson to stay
// live in both seeded layers. A row with no link is BROKEN (fail-closed).
// Any remaining @fleet/@container pointer is a compatibility defect the chief
// resolves by hand (the one-time `ac-learn.sh migrate` ran on every home and is
// retired); Curate never reads the legacy container skill store.
//
// Individual `captain --apply` and `backlog --apply` remain compatibility
// surfaces and take their own backup. `skills-consolidate --apply` is
// deliberately refused (exit 2) because it cannot bypass semantic review or
// pointer integrity. Individual verbs do not reset cadence.
//
// EXIT: 0 for every report, an open or complete run and a lost reset; 1 for
// usage, an unknown flag, no home, the five run refusals and a failing write;
// 2 for skills-consolidate --apply with movers and a record the passes cannot
// read; a signal ends the run at once, 128+n, with no handler (a run dir, a
// dead-pid lock and, mid-apply, an `applying` journal are what it leaves).
//
// ESCAPE HATCH. A broken Curate leaves the Learning DISTILL's caller soft
// (`WARN: Curate is due ... failed`, cadence stays due) but a WRONG write
// rewrites the fleet's ledgers. If a landed change breaks this module, run
// the frozen original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-curate.sh "$o/bin/ac-curate.sh"
//   cat tests/fixtures/ac-maintenance-retired.sh >>"$o/bin/ac-maintenance-lib.sh"
// then AC_CURATE="$o/bin/ac-curate.sh" bin/ac-learn.sh run (the override
// Learning reads, src/learn.ts cmdRun), or "$o/bin/ac-curate.sh" <verb>
// by hand. The copy reaches its own ac-gate.sh and ac-room.sh siblings (shims
// into "$o/src") and bakes no bin root into anything it writes, so nothing
// needs rewriting. Each transaction's tarball (`tar -xzf <arc> -C <home>`)
// undoes a run; the captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W2: no run-level lock - a run started inside another's window binds its
//   deterministic plan to its own snapshot and ends HELD, refusing every
//   later Learning/Curate transaction until `maintenance resume|abandon`.
// - W3: a zero-action deterministic plan is still claimed and backed up, so a
//   file under records/ or skills/ the tar cannot read HOLDS the claim.
// - W4: a compatibility apply whose backup fails prints an empty
//   `pre-run backup:` and moves anyway.
// - W5: neither path takes the ledger lock records/.backlog.md.lock.
// - W6: survivors are rewritten line by line cut at their first NUL (awk's
//   reading) while moved lines keep every byte (sed's).
// - W7: a moved line that was the ledger's unterminated last line is appended
//   without its LF, and the next move glues onto it.
// - W9: a SUPERSEDES ruling whose text holds `above`/`below` anywhere targets
//   the adjacent block, before any date it names.
// - W10: a skill preparer ignores every failure but its explicit refusals -
//   an LF-named file's two halves fail to copy and the move goes on without it.
// - W11: a registry line read as `IFS=$'\t' read` loses its trailing TABs, so
//   its exact-line lookup finds nothing and it asks the captain every run.
// - W12: AC_CURATE_KEEP is compared as awk compares a -v value (a number when
//   strtod reads all of it - `1e1`, `0x3`, ` 3`, `-1`, and `nan`, which
//   equals every count - else as a string, so `abc` keeps every row) and
//   printed and recorded raw.
// - The epic pass walks the tentative rows in onetrue awk's hash order,
//   dropping as it goes, so a story whose epic row is itself dropped stays
//   when awk reached the epic first and goes when it reached the story first.
// - W13: AC_CURATE_STALE_DAYS (and every stale input) is read by bash
//   arithmetic - `010` is 8 days, `08` ends the run 1, 15 digits wrap.
// - W16: the projects audit reads a plain dir inside any git work tree as a
//   repo, a link to a file as an unresolved link, and `..` as the home's
//   parent.
// - grep's reading of a record holding a NUL in its first 32 KB: a printing
//   grep answers one `Binary file <path> matches` line for the matches.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every verb needs bun now (the shim's `ERROR: required tool not
//   found: bun`, exit 1, before usage), where learnings, captain, projects
//   and the skills verbs ran without it and backlog exited 2 at its parser.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is `ERROR: AC_HOME is not a
//   readable directory: <h>`, and a relative one is resolved without CDPATH,
//   where the shell printed cd's own lines (and took cd's echo into the path).
// - W14: no home is the refusal at the first home read, exit 1 - where
//   skills-audit globbed the host's `/*` and exited 0, and run printed the
//   refusal twice and minted `/curate-<epoch>-<pid>`.
// - W8 FAIL-PATH and Q4's C reading: records, frontmatter, overlap tokens,
//   candidate names and the captain greps are read as bytes under any locale,
//   where a UTF-8 caller's awk aborted at an invalid byte (towc, exit 2), its
//   tolower/[a-z] reached non-ASCII letters and bash's brackets collated.
// - W15 EXCLUSIVE TEMPS: captain.md's and backlog.md's rewrite and every
//   receipt land through temps created exclusively (<name>.tmp.<pid>, then
//   .<n>), so a link planted there is never written through; a rewritten
//   record keeps its mode where the original's temp left it at the umask's
//   (a 0600 captain.md stays 0600, through `run`'s deterministic moves too;
//   a semantic subject's rewrite lands with its staged file's mode, as the
//   original's did).
// - W18 ORDER: globs, sorts and the moved file list are in byte order, where
//   the original's followed LC_COLLATE.
// - SHELL-OWN STDERR is not reproduced, the status kept: bash's arithmetic
//   (`08: value too great for base`), redirect and test lines, and awk's own
//   diagnostics; a gate that cannot start is named by /bin/sh, not bash.
// - BYTES: argv and environment arrive decoded, so a byte that is no UTF-8 in
//   a flag, AC_CURATE_KEEP or a path reaches the output, jq and the room as
//   U+FFFD; an arithmetic input naming a variable ends the run 1.
//
// CALLERS: src/learn.ts cmdRun (`${AC_CURATE:-<its bin>/ac-curate.sh}
// run` at the cadence threshold, its failure already the soft `WARN: Curate
// is due ... failed`), and chiefs by hand (session start's `to curate now:
// bin/ac-curate.sh run`). What it WRITES is read by bin/ac-ready.sh and every
// AC_DONELINE_AWK site (backlog.md), the dashboard (the two archives), the
// crew-skill seed and the brain (which skip skills-archive), src/fleets.ts
// and session start (state/.curate.meta), `ac-learn.sh maintenance` (the
// journals) and src/room.ts (data/curate/room.md).

import { accessSync, appendFileSync, chmodSync, closeSync, constants as fsConstants, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readlinkSync, statSync } from "node:fs";
import { acDoneline, records } from "./backlog.ts";
import { receiptValidate } from "./maintenance-receipt.ts";
import {
  NO_HOME,
  SKILLS_ARCHIVE,
  STARTED_BIN,
  arithValue,
  awkAssign,
  awkNumber,
  curateDue,
  curateGeneration,
  curateReset,
  die,
  enterCaller,
  exclusiveTemp,
  fileMtime,
  iso,
  maintenanceApply,
  maintenanceGateFailureReason,
  metaGet,
  nowRaw,
  physicalDir,
  recordsBackup,
  sha256File,
  shellStatus,
  spawnShellSync,
  tabFields,
  testInt,
  warn,
  writeAll,
} from "./lib.ts";

// The lib's AC_MAINTENANCE_QUOTE_MIN (tests/ts/curate.test.ts holds the two
// together).
const QUOTE_MIN = 12;

// Byte strings (latin1) carry what the bash held as bytes; argv, the
// environment and the lib's paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const B = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");

type Exit = { exit: number };
// A command errexit would end the script on: the status leaves through
// main's catch, the shell's own line about it not reproduced.
const fatal = (status: number): never => {
  throw { exit: status } as Exit;
};

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
function liveHome(): string {
  if (LIVE === "") {
    const h = process.env.AC_HOME;
    if (!h) die(NO_HOME);
    LIVE = b8(physicalDir(h) ?? die(`AC_HOME is not a readable directory: ${h}`));
  }
  return LIVE;
}

// ac_*_dir as `$(...)` read them: the dir under <h>, minted, a failing mkdir
// going on unseen.
function sub(h: string, name: string): string {
  const d = `${h}/${name}`;
  try {
    mkdirSync(B(d), { recursive: true });
  } catch {}
  return d;
}

const isFile = (p: string): boolean => {
  try {
    return statSync(B(p)).isFile();
  } catch {
    return false;
  }
};
const isDir = (p: string): boolean => {
  try {
    return statSync(B(p)).isDirectory();
  } catch {
    return false;
  }
};
const isLink = (p: string): boolean => {
  try {
    return lstatSync(B(p)).isSymbolicLink();
  } catch {
    return false;
  }
};
const exists = (p: string): boolean => existsSync(B(p));
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

// The entries a bash glob `<dir>/<pre>*<suf>` names: no dotfile, byte order.
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
    .sort()
    .map((n) => `${dir}/${n}`);
}

// --- the shell's tools over bytes ---------------------------------------------

// A record's lines as sed reads them: every LF-terminated line, then an
// unterminated last one, which sed prints back without its LF.
function rawLines(text: string): { lines: string[]; tail: boolean } {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") {
    lines.pop();
    return { lines, tail: true };
  }
  return { lines, tail: false };
}

// `sed -n '<a>,<b>p'` (only line <a> when <b> is below it), each line with
// <prefix>: NULs kept, an unterminated last line printed without its LF.
function sedRange(text: string, a: number, b: number, prefix = ""): string {
  const { lines, tail } = rawLines(text);
  let o = "";
  for (let n = a; n <= Math.max(a, b) && n <= lines.length; n++) o += prefix + lines[n - 1] + (n < lines.length || tail ? "\n" : "");
  return o;
}

// One `sed -n '<n>p...'` script: the picked lines in file order.
function sedPick(text: string, picks: Set<number>, prefix = ""): string {
  const { lines, tail } = rawLines(text);
  let o = "";
  lines.forEach((l, i) => {
    if (picks.has(i + 1)) o += prefix + l + (i + 1 < lines.length || tail ? "\n" : "");
  });
  return o;
}

// awk's `!(FNR in drop) { print }` and `{ print }` walks: each kept record cut
// at its first NUL and LF-terminated.
const awkKeep = (text: string, keep: (nr: number) => boolean): string =>
  records(text)
    .map((l, i) => (keep(i + 1) ? `${l}\n` : ""))
    .join("");

const lower = (s: string): string => s.replace(/[A-Z]/g, (c) => c.toLowerCase());

// BSD grep over a file read as bytes: the lines (an unterminated last one
// too), and whether a NUL in its first 32 KB makes it binary - a printing
// grep then answers `Binary file <path> matches` for any match, -c and -q do
// not change. A pattern holding LF is several patterns. Null when unreadable.
type Grep = { lines: string[]; binary: boolean } | null;
function grepFile(file: string): Grep {
  const t = read(file);
  if (t === null) return null;
  const lines = t.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return { lines, binary: t.slice(0, 32768).includes("\0") };
}
const fixedHit = (pattern: string, whole: boolean) => {
  const ps = pattern.split("\n");
  return (l: string): boolean => ps.some((p) => (whole ? l === p : l.includes(p)));
};
// -c: the count, "" when grep could not read the file.
function grepCount(file: string, pattern: string, whole: boolean): string {
  const g = grepFile(file);
  return g === null ? "" : String(g.lines.filter(fixedHit(pattern, whole)).length);
}
function grepQuiet(file: string, pattern: string): boolean {
  const g = grepFile(file);
  return g !== null && g.lines.some(fixedHit(pattern, true));
}
// The matching lines a printing grep writes (with -n, `<n>:` first).
function grepPrint(file: string, hit: (l: string) => boolean, numbered = false): string[] {
  const g = grepFile(file);
  if (g === null) return [];
  const o: string[] = [];
  g.lines.forEach((l, i) => {
    if (hit(l)) o.push(numbered ? `${i + 1}:${l}` : l);
  });
  return g.binary && o.length > 0 ? [`Binary file ${file} matches`] : o;
}

// A child spawned as the shell ran it: its status (127 when it cannot start,
// 128+n when signalled), its stdout when piped or written to <fd>.
function spawn(cmd: string[], stdout: "inherit" | "ignore" | "pipe" | number = "inherit", stderr: "inherit" | "ignore" = "inherit"): { status: number; out: string } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd.map(u8), { stdin: "inherit", stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout).toString("latin1") : "" };
}

// `<cmd> >file` (`>>file` with append): the file opened first, as the shell's
// redirection is; null when it cannot be.
function spawnTo(file: string, cmd: string[], append = false): number | null {
  let fd: number;
  try {
    fd = openSync(B(file), append ? "a" : "w");
  } catch {
    return null;
  }
  try {
    return spawn(cmd, fd).status;
  } finally {
    closeSync(fd);
  }
}

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

// `mktemp "${TMPDIR:-/tmp}/<name>.XXXXXX"`, spawned so its failure line and
// status are mktemp's own; null when it fails.
function mktemp(name: string): string | null {
  const r = spawn(["mktemp", `${b8(process.env.TMPDIR || "/tmp")}/${name}.XXXXXX`], "pipe");
  return r.status === 0 ? subst(r.out) : null;
}

const rmF = (...files: string[]): void => {
  spawn(["rm", "-f", ...files]);
};

// <bytes> published over <target> through an exclusive <target>.tmp.<pid>
// given the record's mode, renamed by a spawned mv; the status of the step
// that failed, 0 when it landed.
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
    return 1;
  } finally {
    closeSync(t.fd);
  }
  try {
    chmodSync(t.path, statSync(B(target)).mode & 0o7777);
  } catch {}
  return spawn(["mv", b8(t.path), target]).status;
}

// --- learnings: pointer-integrity check (PROPOSE ONLY) -------------------------

function curateLearnings(): void {
  const ledger = `${sub(liveHome(), "records")}/learnings.md`;
  out("== learnings: pointer-integrity check (propose-only; CURATE never compacts) ==\n");
  if (!isFile(ledger)) {
    out("  (no learnings.md - nothing to check)\n");
    return;
  }
  let broken = 0;
  let compatibility = 0;
  // A pointer's FIRST link names where its distilled body lives, relative to
  // the ledger's own directory, as src/learn.ts ledgerStage writes it - never the
  // slug, which read every correctly-retired skill package as BROKEN.
  for (const raw of grepPrint(ledger, (l) => /^- \[distilled -> [a-z0-9-]+\]/.test(l))) {
    // bash 3.2's read ends a line at its first NUL.
    const row = raw.split("\0", 1)[0]!;
    if (row === "") continue;
    const at = row.indexOf("[distilled -> ");
    let name = at < 0 ? row : row.slice(at + 14);
    if (name.includes("]")) name = name.slice(0, name.indexOf("]"));
    const cut = row.indexOf("](");
    if (cut < 0) {
      out(`  BROKEN: [distilled -> ${name}] - pointer carries no link to its distilled body\n`);
      broken++;
      continue;
    }
    let link = row.slice(cut + 2);
    if (link.includes(")")) link = link.slice(0, link.indexOf(")"));
    const target = `${dirname(ledger)}/${link}`;
    if (!isFile(target)) {
      out(`  BROKEN: [distilled -> ${name}] - distilled body vanished (link ${link}, missing ${target})\n`);
      broken++;
    }
  }
  const rung = /\[distilled -> [a-z0-9-]+ @(fleet|container)\]/g;
  const matches: string[] = [];
  const g = grepFile(ledger);
  for (const l of g?.lines ?? []) for (const m of l.matchAll(rung)) matches.push(m[0]);
  for (const name of g?.binary && matches.length > 0 ? [`Binary file ${ledger} matches`] : matches) {
    out(`  COMPATIBILITY DEFECT: ${name} - rung-qualified pointer remains; the migrate command is retired, so rewrite the pointer to the canonical fleet-local form by hand\n`);
    compatibility++;
  }
  if (broken === 0 && compatibility === 0) out("  ok: all distilled pointers resolve\n");
  else out(`  ${broken} broken canonical pointer(s), ${compatibility} migration compatibility defect(s); propose-only\n`);
}

// --- captain: consolidate-supersede + expire (AUTO-tier, move-only) -------------

type CapRow = { start: number; end: number; cls: string; reason: string };

// Each rule BLOCK (a `- ` line plus its indented continuations) that is a move
// candidate or an informational note; UPPERCASE markers only, conservative -
// a `SUPERSEDES` ruling and any partial/standing marker are KEPT.
function captainPlan(text: string): CapRow[] {
  const rows: CapRow[] = [];
  let bstart = 0;
  let bend = 0;
  let block = "";
  const flush = (): void => {
    if (bstart === 0) return;
    let cls = "";
    let reason = "";
    if (block.includes("SUPERSEDES")) {
      cls = "note";
      reason = "declares SUPERSEDES a named earlier rule - live ruling KEPT (retire its dead target manually if fully superseded)";
    } else if (block.includes("SUPERSEDED")) {
      if (lower(block).includes("holds")) {
        cls = "note";
        reason = "partial supersession (self-marked SUPERSEDED, the rest holds) - NOT auto-moved";
      } else {
        cls = "move-superseded";
        reason = "fully-superseded rule (self-marked SUPERSEDED, no partial qualifier)";
      }
    } else if (block.includes("COMPLETED") || block.includes("EXPIRED")) {
      if (block.includes("STANDING")) {
        cls = "note";
        reason = "STANDING rule marked COMPLETED/EXPIRED - NOT auto-moved (a standing rule never expires)";
      } else {
        cls = "move-expired";
        reason = "completed one-time order (marked COMPLETED/EXPIRED)";
      }
    }
    if (cls !== "") rows.push({ start: bstart, end: bend, cls, reason });
    bstart = 0;
    block = "";
  };
  records(text).forEach((l, i) => {
    if (l.startsWith("- ")) {
      flush();
      bstart = bend = i + 1;
      block = l;
    } else if (bstart > 0 && /^[ \t]/.test(l)) {
      bend = i + 1;
      block += `\n${l}`;
    } else flush();
  });
  flush();
  return rows;
}

const ARCHIVE_LINK = "Archived rulings: [captain-archive.md](captain-archive.md)";
const CAPTAIN_ARCHIVE_HEAD = "# captain-archive - retired captain.md rules (moved by ac-curate.sh, never deleted)\n";

// <survivors> with the one archive link ensured, as `grep -qFx || { [ ! -s ]
// || printf '\n'; printf link }` leaves it.
const withArchiveLink = (s: string): string => (s.split("\n").includes(ARCHIVE_LINK) ? s : `${s}${s === "" ? "" : "\n"}${ARCHIVE_LINK}\n`);

function curateCaptain(h: string, apply: boolean, preBacked: boolean): void {
  const rec = sub(h, "records");
  const captain = `${rec}/captain.md`;
  const archive = `${rec}/captain-archive.md`;
  out("== captain: consolidate-supersede + expire (AUTO-tier, verbatim move-only) ==\n");
  if (!isFile(captain)) {
    out("  (no captain.md - nothing to curate)\n");
    return;
  }
  const text = read(captain) ?? fatal(2);
  const plan = captainPlan(text);
  if (plan.length === 0) {
    out("  ok: no retirement markers found - nothing to consolidate or expire\n");
    return;
  }
  const movers = plan.filter((r) => r.cls.startsWith("move-"));
  for (const r of plan) {
    out(`  --- [${r.cls}] captain.md lines ${r.start}-${r.end}: ${r.reason}\n`);
    out(sedRange(text, r.start, r.end, "    | "));
  }
  if (!apply) {
    out(`  PROPOSE-ONLY: ${movers.length} block(s) would move to ${archive} on --apply (notes are informational, never moved)\n`);
    return;
  }
  if (movers.length === 0) {
    out("  --apply: nothing to move (only informational supersede-chain notes)\n");
    return;
  }
  if (!preBacked) out(`  pre-run backup: ${recordsBackup("curate") ?? ""}\n`);
  const datestr = iso();
  if (!isFile(archive) && !put(archive, CAPTAIN_ARCHIVE_HEAD)) fatal(1);
  // Each moved block goes VERBATIM under a dated note, read from the still-
  // intact captain.md; then those lines drop and the survivors stay as they were.
  // Both read the record as it stands at the write, as the shell's sed and awk
  // did, so a rule added inside the backup's window is kept.
  const movetmp = mktemp("ac-curate-cap") ?? fatal(1);
  if (!put(movetmp, movers.map((r) => `${r.start}\t${r.end}\t${r.cls}\t${r.reason}\n`).join(""))) fatal(1);
  for (const r of movers) {
    const [label, note] = r.cls === "move-superseded" ? ["superseded", "superseded-by: self-marked in the retired rule"] : ["expired", "completed: retired one-time order"];
    if (!put(archive, `\n## curated ${datestr} - ${label}\n${note}\n${sedRange(read(captain) ?? fatal(1), r.start, r.end)}`, true)) fatal(1);
  }
  const drop = new Set<number>();
  for (const r of movers) for (let n = r.start; n <= r.end; n++) drop.add(n);
  const droptmp = mktemp("ac-curate-drop") ?? fatal(1);
  if (!put(droptmp, [...drop].sort((a, b) => a - b).map((n) => `${n}\n`).join(""))) fatal(1);
  const st = publish(captain, withArchiveLink(awkKeep(read(captain) ?? fatal(2), (nr) => !drop.has(nr))));
  if (st !== 0) fatal(st);
  rmF(movetmp, droptmp);
  out(`  CURATED: moved ${movers.length} block(s) to ${archive} (verbatim); survivors byte-identical (receipt + captain veto is the roomchief process)\n`);
}

// --- backlog: archive move-only (keep-N recent Done) ---------------------------

// onetrue awk's array: 50 buckets grown x4 past twice as many keys, a key
// hashed `c + 31 * h` over its bytes and pushed at its bucket's head - the
// order a `for (k in a)` walks, which the epic pass's deletions depend on.
function awkOrder(keys: string[]): string[] {
  let size = 50;
  let tab: string[][] = Array.from({ length: size }, () => []);
  const hash = (s: string, n: number): number => {
    let v = 0;
    for (let i = 0; i < s.length; i++) v = (s.charCodeAt(i) + 31 * v) >>> 0;
    return v % n;
  };
  let nelem = 0;
  for (const k of keys) {
    nelem++;
    if (nelem > 2 * size) {
      const nsz = 4 * size;
      const np: string[][] = Array.from({ length: nsz }, () => []);
      for (const chain of tab) for (const c of chain) np[hash(c, nsz)]!.unshift(c);
      tab = np;
      size = nsz;
    }
    tab[hash(k, size)]!.unshift(k);
  }
  return tab.flat();
}

// _backlog_plan's walk, in process over src/backlog.ts's parser: the Done rows
// past the first <keep> (awk's comparison of a -v value, W12), minus a Done id
// a Queued row's blocked-by names, minus a story whose epic row is absent or
// not itself archived; line numbers ascending.
function backlogPlan(text: string, keep: string): number[] {
  let sec = "";
  const lineid = new Map<number, string>();
  const idline = new Map<string, number>();
  const lineepic = new Map<number, string>();
  const blockerref = new Set<string>();
  const doneorder: number[] = [];
  records(text).forEach((l, i) => {
    const nr = i + 1;
    if (l.startsWith("## ")) sec = "";
    if (l.startsWith("## In flight")) sec = "inflight";
    if (l.startsWith("## Queued")) sec = "queued";
    if (l.startsWith("## Done")) sec = "done";
    if (!/^- \[[ x]\] /.test(l)) return;
    const o = acDoneline(l);
    lineid.set(nr, o.id);
    idline.set(o.id, nr);
    lineepic.set(nr, o.epic);
    if (sec === "queued" && o.blockers !== "") for (const b of o.blockers.split(",")) blockerref.add(b);
    if (sec === "done") doneorder.push(nr);
  });
  const kv = awkAssign(keep);
  const kn = awkNumber(kv);
  // awk compares two numbers by the sign of their difference, so a nan keep
  // equals every k.
  const kept = (k: number): boolean => (kn === null ? String(k) <= kv : !(k - kn > 0));
  const tent = new Set<string>();
  doneorder.forEach((nr, i) => {
    if (kept(i + 1) || blockerref.has(lineid.get(nr)!)) return;
    tent.add(String(nr));
  });
  for (const nr of awkOrder([...tent])) {
    const ep = lineepic.get(Number(nr))!;
    if (ep === "") continue;
    const epicnr = idline.get(ep);
    if (epicnr === undefined || !tent.has(String(epicnr))) tent.delete(nr);
  }
  return [...tent].map(Number).sort((a, b) => a - b);
}

const BACKLOG_ARCHIVE_HEAD = "# Backlog archive - moved Done receipts (byte-identical; ac-ready.sh never reads this)\n\n## Done\n";

function curateBacklog(h: string, apply: boolean, preBacked: boolean): void {
  const keep = b8(process.env.AC_CURATE_KEEP || "20");
  const rec = sub(h, "records");
  const backlog = `${rec}/backlog.md`;
  const archive = `${rec}/backlog-archive.md`;
  out(`== backlog: archive move-only (keep ${keep} recent Done, blocked-by-safe + epic-safe) ==\n`);
  if (!isFile(backlog)) {
    out("  (no backlog.md - nothing to archive)\n");
    return;
  }
  const text = read(backlog) ?? fatal(2);
  const plan = backlogPlan(text, keep);
  if (plan.length === 0) {
    out(`  ok: nothing to archive (<= ${keep} Done, or all older ones are blocker/epic-protected)\n`);
    return;
  }
  out(`  candidates to archive: ${plan.length} Done line(s) older than the ${keep} most-recent\n`);
  // sed, not awk, picks the moved lines: awk cuts a line at a NUL and
  // terminates an unterminated last line, so they would stop being the ledger's.
  const picks = new Set(plan);
  out(sedPick(text, picks, "    move | "));
  if (!apply) {
    out(`  PROPOSE-ONLY: ${plan.length} line(s) would move to ${archive} on --apply\n`);
    return;
  }
  if (!preBacked) out(`  pre-run backup: ${recordsBackup("curate") ?? ""}\n`);
  if (!isFile(archive) && !put(archive, BACKLOG_ARCHIVE_HEAD)) fatal(1);
  // Read at the write, as the shell's sed and awk read it: a row landed in
  // the backup's window stays.
  if (!put(archive, sedPick(read(backlog) ?? fatal(1), picks), true)) fatal(1);
  const droptmp = mktemp("ac-curate-bl") ?? fatal(1);
  if (!put(droptmp, plan.map((n) => `${n}\n`).join(""))) fatal(1);
  const st = publish(backlog, awkKeep(read(backlog) ?? fatal(2), (nr) => !picks.has(nr)));
  if (st !== 0) fatal(st);
  rmF(droptmp);
  out(`  CURATED: moved ${plan.length} Done line(s) to ${archive} (byte-identical); backlog survivors untouched\n`);
}

// --- projects: correctness-audit (PROPOSE ONLY) --------------------------------

// The registry lines in the grammar `- <name> [+yolo] - <desc> (added
// <date>)` (bin/ac-project-mode.sh header), recognised by the grammar position
// after the name (` [` or ` - `), never the bracket alone; read as bytes, as
// the line-number<TAB>name<TAB>line wire `IFS=$'\t' read` takes apart.
function registryLines(h: string): string[] {
  const registry = `${sub(h, "records")}/projects.md`;
  if (!isFile(registry)) return [];
  const o: string[] = [];
  records(read(registry) ?? "").forEach((l, i) => {
    if (/^- [^ ]+ (\[|- )/.test(l)) o.push(`${i + 1}\t${l.slice(2).replace(/ [\s\S]*$/, "")}\t${l}`);
  });
  return o;
}

function curateProjects(): void {
  const h = liveHome();
  const projects = `${sub(h, "records")}/projects.md`;
  out("== projects: correctness-audit (propose-only; deletion stays a captain call) ==\n");
  if (!isFile(projects)) {
    out("  (no projects.md - nothing to audit)\n");
    return;
  }
  const projDir = sub(h, "projects");
  let flags = 0;
  for (const wire of registryLines(h)) {
    const name = tabFields(wire, 3)[1]!;
    const pd = `${projDir}/${name}`;
    if (!exists(pd)) {
      out(`  FLAG ${name}: registered but projects/${name} is absent - dead project? (propose drop; deletion is a captain call)\n`);
      flags++;
      continue;
    }
    if (isLink(pd) && !isDir(pd)) {
      let to = "";
      try {
        to = readlinkSync(B(pd), { encoding: "buffer" }).toString("latin1");
      } catch {}
      out(`  FLAG ${name}: symlink projects/${name} -> ${to} does not resolve\n`);
      flags++;
    }
    if (spawn(["git", "-C", pd, "rev-parse", "--git-dir"], "ignore", "ignore").status !== 0) {
      out(`  FLAG ${name}: projects/${name} is not a git repo\n`);
      flags++;
    }
  }
  if (flags === 0) out("  ok: every registered project line verified against reality (no mismatches)\n");
  else out(`  ${flags} mismatch(es) proposed with evidence - NO mutation (projects.md audit is propose-only)\n`);
}

// --- skills: the learned store, its frontmatter, staleness ---------------------

// `<skill-dir><TAB>fleet` per active learned skill, as one text.
function learnedSkillDirs(h: string): string {
  return glob(sub(h, "skills"))
    .filter((d) => isDir(d) && basename(d) !== SKILLS_ARCHIVE && isFile(`${d}/SKILL.md`))
    .map((d) => `${d}\tfleet\n`)
    .join("");
}

// The value of `<key>:` at any indent inside the frontmatter (between the
// first two `---` fences, line 1 being the first), one pair of wrapping quotes
// stripped; "" when absent or unreadable. Restricted to the frontmatter so a
// body word never leaks.
function skillField(file: string, key: string): string {
  const recs = records(read(file) ?? "");
  if (recs[0] !== "---") return "";
  for (const l of recs.slice(1)) {
    if (l === "---") return "";
    let line = l.replace(/^[ \t]+/, "");
    if (!line.startsWith(`${key}:`)) continue;
    line = line.slice(key.length + 1).replace(/^[ \t]+/, "");
    if (/^"[\s\S]*"$/.test(line) || /^'[\s\S]*'$/.test(line)) line = line.slice(1, -1);
    return subst(line);
  }
  return "";
}

// ac_meta_get with its stderr dropped: "" for a meta that is not there or
// cannot be read.
function metaQuiet(file: string, key: string): string {
  if (!isFile(file)) return "";
  const t = read(file);
  if (t === null) return "";
  let v = "";
  for (const line of t.split("\n")) if (line === key || line.startsWith(`${key}=`)) v = line.slice(key.length + 1);
  return v;
}

const metaLoud = (file: string, key: string): string => {
  try {
    return b8(metaGet(u8(file), key));
  } catch {
    return "";
  }
};

// The fleet skill names an unsettled Learning candidate still names: a
// validated/applied transaction removes its subject through the completed
// journal; historical candidate artifacts alone are not live.
function pendingCandidateTargets(h: string): Set<string> {
  const data = sub(h, "data");
  const cands: string[] = [];
  const top = glob(data).filter(isDir);
  for (const d of top) cands.push(...glob(d, "candidate-", ".md"));
  const first = cands.sort();
  const nested: string[] = [];
  for (const d of top) if (isDir(`${d}/candidates`)) nested.push(...glob(`${d}/candidates`, "", ".md"));
  const names = new Set<string>();
  for (const cand of [...first, ...nested.sort()]) {
    if (!isFile(cand)) continue;
    let name = "";
    for (const l of (read(cand) ?? "").split("\n")) {
      if (!l.startsWith("name:")) continue;
      name = subst(l.slice(5).replace(/^[ \t\n\v\f\r]+/, ""));
      break;
    }
    if (!/^[a-z0-9-]+$/.test(name)) continue;
    const run = cand.includes("/candidates/") ? dirname(dirname(cand)) : dirname(cand);
    const journal = `${sub(h, "state")}/.maintenance-transactions/${basename(run)}-${name}/journal`;
    if (isFile(journal) && metaLoud(journal, "status") === "complete") continue;
    names.add(name);
  }
  return names;
}

// The first active task whose seeded skill link resolves to the fleet's only
// live copy of <name>, "" for none.
function activeDependency(h: string, name: string): string {
  const source = physicalDir(u8(`${sub(h, "skills")}/${name}`));
  if (source === null) return "";
  for (const meta of glob(sub(h, "state"), "", ".meta")) {
    if (!isFile(meta)) continue;
    const wt = metaQuiet(meta, "worktree");
    if (wt === "" || !isLink(`${wt}/.claude/skills/${name}`)) continue;
    if (physicalDir(u8(`${wt}/.claude/skills/${name}`)) !== source) continue;
    return basename(meta).replace(/\.meta$/, "");
  }
  return "";
}

// Bash arithmetic over a text value (`$((a - b))`, `$((d * 86400))`):
// leading 0 octal, 64-bit wrap; a digit too great for its base or a name ends
// the run 1, as the shell's arithmetic error did.
function arith(text: string): bigint {
  try {
    return arithValue(text);
  } catch {
    return fatal(1);
  }
}
// `[ <a> -gt <b> ]`, false when either is no integer to test(1).
const testGt = (a: bigint, b: string): boolean => {
  const y = testInt(b);
  return y !== null && a > y;
};

// The canonical pointer is intentionally not a usefulness signal: freshness
// comes from the newest landing/patch bytes, seeding telemetry, evidence
// append, unsettled Learning candidates and active worktree use.
function skillIsStale(h: string, d: string, now: string, window: string): boolean {
  const name = basename(d);
  const landed = skillField(`${d}/SKILL.md`, "landed");
  if (!/^[0-9]+$/.test(landed)) return false;
  let mtime = fileMtime(B(`${d}/SKILL.md`)) ?? "";
  if (!/^[0-9]+$/.test(mtime)) mtime = "0";
  const a = testInt(mtime);
  const b = testInt(landed);
  const latest = a !== null && b !== null && a <= b ? landed : mtime;
  if (!testGt(BigInt.asIntN(64, arith(now) - arith(latest)), window)) return false;
  const seeded = metaQuiet(`${d}/.usage.meta`, "last_seeded");
  if (/^[0-9]+$/.test(seeded) && !testGt(BigInt.asIntN(64, arith(now) - arith(seeded)), window)) return false;
  const archive = `${sub(h, "records")}/learnings-archive/${name}.md`;
  if (isFile(archive)) {
    const am = fileMtime(B(archive)) ?? "";
    if (!/^[0-9]+$/.test(am)) return false;
    if (!testGt(BigInt.asIntN(64, arith(now) - arith(am)), window)) return false;
  }
  const pending = pendingCandidateTargets(h);
  if (name.split("\n").some((n) => pending.has(n))) return false;
  return activeDependency(h, name) === "";
}

// --- skills-audit: territory overlap + stale candidates (PROPOSE ONLY) ----------

const STOP = new Set("before after should would could cannot without between against through another because itself always actually".split(" "));

// Descriptions-first territory overlap: a significant word is a >= 6-char
// [a-z0-9] token of the lowercased description, minus a few generic long
// fillers; two skills sharing >= 2 are flagged (pairs in input order, words
// in the first one's order). PROPOSE ONLY - a human adjudicates.
function overlapFlags(tsv: string): string {
  const names: string[] = [];
  const words: string[][] = [];
  for (const l of records(tsv)) {
    const f = l.split("\t");
    names.push(f[0]!);
    const seen = new Set<string>();
    const w: string[] = [];
    for (const t of lower(f[1] ?? "").replace(/[^a-z0-9]+/g, " ").split(" ")) {
      if (t.length < 6 || STOP.has(t) || seen.has(t)) continue;
      seen.add(t);
      w.push(t);
    }
    words.push(w);
  }
  let o = "";
  for (let a = 0; a < names.length; a++)
    for (let b = a + 1; b < names.length; b++) {
      const shared = words[a]!.filter((t) => words[b]!.includes(t));
      if (shared.length >= 2) o += `  OVERLAP: ${names[a]} ~ ${names[b]} - share ${shared.length} territory word(s): ${shared.join(", ")} (review for possible consolidation)\n`;
    }
  return o;
}

function curateSkillsAudit(): void {
  const now = b8(nowRaw());
  let staleDays = b8(process.env.AC_CURATE_STALE_DAYS || "90");
  if (!/^[0-9]+$/.test(staleDays)) staleDays = "90";
  const window = String(BigInt.asIntN(64, arith(staleDays) * 86400n));
  out("== skills-audit: territory overlap + stale candidates (propose-only, never mutates) ==\n");
  const h = liveHome();
  const dirs = subst(learnedSkillDirs(h));
  if (dirs === "") {
    out("  (no learned skills - nothing to audit)\n");
    return;
  }
  const rows = `${dirs}\n`.split("\n").slice(0, -1);
  const total = rows.filter((r) => r !== "").length;
  const ndtsv = mktemp("ac-curate-skov") ?? fatal(1);
  let tsv = "";
  for (const r of rows) {
    const d = tabFields(r, 2)[0]!;
    if (d === "") continue;
    tsv += `${subst(basename(d))}\t${skillField(`${d}/SKILL.md`, "description")}\n`;
  }
  if (!put(ndtsv, tsv)) fatal(1);
  const ov = subst(overlapFlags(tsv));
  rmF(ndtsv);
  let flagOv = 0;
  if (ov !== "") {
    out(`${ov}\n`);
    flagOv = ov.split("\n").filter((l) => l.includes("OVERLAP:")).length;
  } else out("  ok: no overlapping description territory among learned skills\n");
  let flagSt = 0;
  for (const r of rows) {
    const [d, store] = tabFields(r, 2) as [string, string];
    if (d === "") continue;
    if (!skillIsStale(h, d, now, window)) continue;
    out(`  STALE: ${subst(basename(d))} [${store}] - last landing/patch, seed, and evidence activity exceed ${staleDays}d; no pending candidate or active worktree dependency\n`);
    flagSt++;
  }
  if (flagSt === 0) out("  ok: no stale candidates under the activity, evidence, pending-candidate, and active-worktree predicates\n");
  out(`  audited ${total} learned skill(s): ${flagOv} overlap pair(s), ${flagSt} stale candidate(s) - propose-only, no mutation (even with --apply)\n`);
}

// --- skills-consolidate: prefix-cluster umbrella merge, MOVE-to-archive ---------

// First-segment prefix clusters of the fleet store (prefix = the text before
// the first `-`): `move<TAB><prefix><TAB><sibling>` for a sibling whose
// umbrella is a skill named EXACTLY the prefix, `noumbrella<TAB><prefix><TAB>
// <count>` for a >= 2-sibling group with none; byte order.
function clusterPlan(store: string): string[] {
  const listed = glob(store)
    .filter((d) => isDir(d) && basename(d) !== SKILLS_ARCHIVE && isFile(`${d}/SKILL.md`))
    .map((d) => `${basename(d)}\n`)
    .join("");
  const names = new Set<string>();
  for (const l of records(listed)) names.add(l.replace(/^[ \t]+/, "").split(/[ \t]+/)[0]!);
  const sib = new Map<string, string[]>();
  for (const n of names) {
    const p = n.includes("-") ? n.slice(0, n.indexOf("-")) : n;
    if (n !== p) sib.set(p, [...(sib.get(p) ?? []), n]);
  }
  const lines: string[] = [];
  for (const [p, s] of sib) {
    if (names.has(p)) for (const n of s) lines.push(`move\t${p}\t${n}`);
    else if (s.length >= 2) lines.push(`noumbrella\t${p}\t${s.length}`);
  }
  return lines.sort();
}

function curateSkillsConsolidate(apply: boolean): number {
  const store = sub(liveHome(), "skills");
  out("== skills-consolidate: prefix-cluster umbrella merge, MOVE-to-archive (move-only, never delete) ==\n");
  const plan = clusterPlan(store);
  if (plan.length === 0) {
    out("  ok: no prefix cluster with an umbrella - nothing to consolidate\n");
    return 0;
  }
  let movers = 0;
  let proposed = 0;
  for (const l of plan) {
    const [kind, p, arg] = tabFields(l, 3) as [string, string, string];
    if (kind === "move") {
      out(`  CLUSTER ${p}: sibling ${arg} -> archive (umbrella ${p} stays)\n`);
      movers++;
    } else if (kind === "noumbrella") {
      out(`  cluster ${p}-*: ${arg} sibling(s) but NO umbrella skill named "${p}" - propose-only, not moved (create the umbrella first)\n`);
      proposed++;
    }
  }
  if (movers === 0) {
    out(`  PROPOSE-ONLY: ${proposed} umbrella-less cluster(s) flagged; 0 movable (an exact-prefix umbrella is required to move a sibling)\n`);
    return 0;
  }
  if (apply) {
    out("  REFUSED: direct --apply cannot prove behavior preservation or update the canonical pointer atomically.\n");
    out("  Run ac-curate.sh run; each movable sibling becomes a hash-bound semantic maintenance-gate subject.\n");
    return 2;
  }
  out(`  PROPOSE-ONLY: ${movers} sibling(s) require automatic Curate maintenance-gate review before a recoverable move to ${store}/${SKILLS_ARCHIVE}; ${proposed} umbrella-less cluster(s) never move\n`);
  return 0;
}

// --- run: plans, receipts, the gate ---------------------------------------------

// A plain non-link file's hash, `-` for nothing there, null for anything else.
function shaOrAbsent(f: string): string | null {
  if (isFile(f) && !isLink(f)) return sha(f);
  if (!exists(f) && !isLink(f)) return "-";
  return null;
}

// One action line onto <actions>. With no <old>, old_sha256 is the LIVE
// file's at call time - right only when the staged bytes were derived from
// that same read; a caller staging from an earlier snapshot (the shadow
// passes) passes that snapshot's hash, or a write landing in between would be
// taken as the plan's pre-state and reverted by the transaction.
function planAction(actions: string, op: string, target: string, staged: string, run: string, old = ""): boolean {
  if (old === "") {
    const s = shaOrAbsent(`${liveHome()}/${target}`);
    if (s === null) return false;
    old = s;
  }
  const nw = sha(`${run}/${staged}`);
  if (nw === null) return false;
  return (
    spawnTo(actions, ["jq", "-nc", "--arg", "op", op, "--arg", "target", target, "--arg", "old", old, "--arg", "new", nw, "--arg", "staged", staged, "{op:$op,target:$target,old_sha256:$old,new_sha256:$new,staged:$staged}"], true) === 0
  );
}

const shaText = (f: string): string => sha(f) ?? "";

// A receipt through its exclusive <receipt>.tmp.<pid>, renamed by a spawned
// mv; false when the temp cannot be written or the mv fails.
function writeReceipt(receipt: string, body: string): boolean {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(u8(`${receipt}.tmp`));
  } catch {
    return false;
  }
  try {
    writeAll(t.fd, B(body));
  } catch {
    return false;
  } finally {
    closeSync(t.fd);
  }
  return spawn(["mv", b8(t.path), receipt]).status === 0;
}

function policyReceipt(receipt: string, plan: string, manifest: string): boolean {
  const m = shaText(manifest);
  const p = shaText(plan);
  return writeReceipt(
    receipt,
    `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "continue"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${p}"\nreviewed_at: "${b8(iso())}"\n---\n# Maintenance Gate Decision\n## Decision\ncontinue\n## Grounds\nCaptain terminal markers and backlog retention are deterministic, reversible repository policies.\n## Proposed Process\nApply the exact staged files through the shared maintenance transaction.\n`,
  );
}

// `{path,sha256}` entries through a TMPDIR temp into one jq-slurped
// document; false at the first entry <hash> refuses (null). A TMPDIR that
// cannot take the entries leaves the document empty and goes on, as the
// original's unchecked steps did.
function manifestOf(out_: string, tmpName: string, entries: [string, () => string | null][], doc: string[]): boolean {
  const tmp = mktemp(tmpName);
  for (const [path, hash] of entries) {
    const s = hash();
    if (s === null) {
      if (tmp !== null) rmF(tmp);
      return false;
    }
    if (tmp !== null) spawnTo(tmp, ["jq", "-nc", "--arg", "path", path, "--arg", "sha", s, "{path:$path,sha256:$sha}"], true);
  }
  if (tmp === null) put(out_, "");
  else spawnTo(out_, ["jq", "-s", ...doc, tmp]);
  if (tmp !== null) rmF(tmp);
  return true;
}

// The exact live hashes the deterministic plan reads; false for a symlink or
// a non-file.
function inputManifest(out_: string): boolean {
  const rec = sub(liveHome(), "records");
  const files = ["captain.md", "captain-archive.md", "backlog.md", "backlog-archive.md"];
  return manifestOf(
    out_,
    "ac-curate-manifest",
    files.map((f) => [`records/${f}`, () => shaOrAbsent(`${rec}/${f}`)]),
    ["--arg", "keep", b8(process.env.AC_CURATE_KEEP || "20"), '{schema:"agentcrew.curate-input/v1",keep_done:$keep,files:.}'],
  );
}

const relBad = (rel: string): boolean =>
  rel === "" || rel.startsWith("/") || rel === "." || rel === ".." || rel.startsWith("./") || rel.startsWith("../") || rel.includes("/./") || rel.includes("/../") || rel.endsWith("/.") || rel.endsWith("/..") || /[^A-Za-z0-9._/-]/.test(rel);

function subjectManifest(out_: string, subject: string, rels: string[]): boolean {
  return manifestOf(
    out_,
    "ac-curate-subject",
    rels.map((rel) => [rel, () => (relBad(rel) ? null : shaOrAbsent(`${liveHome()}/${rel}`))]),
    ["--arg", "subject", subject, '{schema:"agentcrew.curate-subject-input/v1",subject:$subject,files:(unique_by(.path))}'],
  );
}

const SUBJECT_MANIFEST_JQ = `
    type == "object"
    and .schema == "agentcrew.curate-subject-input/v1"
    and (.subject | type == "string")
    and (.files | type == "array")
    and all(.files[];
      type == "object"
      and keys == ["path","sha256"]
      and (.path | type == "string"
        and test("^[A-Za-z0-9._/-]+$")
        and (test("(^|/)\\\\.\\\\.?(/|$)") | not))
      and (.sha256 | type == "string"
        and (. == "-" or test("^[0-9a-f]{64}$"))))
  `;

// The non-action judgment inputs rechecked after the gate returns: action
// targets carry their old hashes in the closed plan, and this closes the same
// gap for the umbrella, evidence and absence inputs that informed the decision.
function subjectManifestValidate(manifest: string): boolean {
  if (spawn(["jq", "-e", SUBJECT_MANIFEST_JQ, manifest], "ignore", "ignore").status !== 0) return false;
  for (const row of spawn(["jq", "-r", ".files[] | [.path,.sha256] | @tsv", manifest], "pipe").out.split("\n").slice(0, -1)) {
    const [rel, expected] = tabFields(row.split("\0", 1)[0]!, 2) as [string, string];
    const actual = shaOrAbsent(`${liveHome()}/${rel}`);
    if (actual === null || actual !== expected) return false;
  }
  return true;
}

function subjectPlan(out_: string, run: string, subject: string, manifest: string, actions: string): void {
  spawnTo(out_, [
    "jq",
    "-s",
    "--arg",
    "run_id",
    basename(run),
    "--arg",
    "subject",
    subject,
    "--arg",
    "manifest",
    shaText(manifest),
    "{schema:\"agentcrew.maintenance-plan/v1\",mode:\"curate\",run_id:$run_id,\n      subject:$subject,input_manifest_sha256:$manifest,actions:.}",
    actions,
  ]);
}

// A hash-bound non-authorizing receipt for a subject policy or the runtime
// could not decide, so every captain escalation link resolves.
function askReceipt(receipt: string, plan: string, manifest: string, subject: string, grounds: string): void {
  spawn(["mkdir", "-p", dirname(receipt)]);
  const m = shaText(manifest);
  const p = shaText(plan);
  writeReceipt(
    receipt,
    `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "${subject}"\ndecision: "ask-captain"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${p}"\nreviewed_at: "${b8(iso())}"\n---\n# Maintenance Gate Decision\n## Decision\nask-captain\n## Grounds\n${grounds}\n## Proposed Process\nPreserve the live records and ask the captain about this exact hash-bound subject.\n`,
  );
}

// The captain's ask in the curate room, posted through this bin's ac-room.sh,
// its output dropped; <ack> is the paste-ready acknowledgement of a subject
// with no safe plan, since the captain reads the ask here.
function escalate(run: string, subject: string, plan: string, manifest: string, reason: string, ack = ""): void {
  const txid = basename(run);
  const home = liveHome();
  let message = `ASK: Curate maintenance cannot decide automatically.
why: ${reason}
subject: ${subject}; action-plan-sha256: ${shaText(plan)}
options: (1) approve this exact recoverable plan; (2) reject and preserve the live records; (3) request a revised plan.
tradeoffs: approve performs the reversible archival now; reject preserves active state and keeps Curate due; revise spends another maintenance-gate round.
recommendation: reject or revise unless the linked evidence proves the complete subject is retired.
links: candidate=data/${txid}/subjects/${subject}.md; gate=data/${txid}/gates/${subject}/decision.md; evidence=${manifest.startsWith(`${home}/`) ? manifest.slice(home.length + 1) : manifest}`;
  if (ack !== "")
    message += `
already-ruled: if a standing ruling already answers this subject, record it in records/curate-acknowledged.md and Curate settles it without moving a line - replace the placeholder with that ruling:
${ack}`;
  if (spawn([`${b8(STARTED_BIN)}/ac-room.sh`, "post", "curate", "curator", message], "ignore", "ignore").status !== 0) warn(B(`captain escalation for Curate subject ${subject} could not be posted`));
}

// 0 when applied or preserved under a settled receipt, 2 when captain input
// is unresolved, 1 for an apply failure that must keep cadence due.
function gateSubject(run: string, subject: string, manifest: string, plan: string): number {
  const receipt = `${run}/gates/${subject}/decision.md`;
  const gate = process.env.AC_GATE ? b8(process.env.AC_GATE) : `${b8(STARTED_BIN)}/ac-gate.sh`;
  spawn(["mkdir", "-p", dirname(receipt)]);
  const g = spawn(["/bin/sh", "-c", 'exec "$0" "$@" 2>&1', gate, "maintenance", "--mode", "curate", "--run", run, "--subject", subject, "--manifest", manifest, "--plan", plan], "pipe");
  const said = subst(g.out);
  if (g.status !== 0) {
    let reason = b8(maintenanceGateFailureReason(g.status));
    if (said !== "") reason += `\n${said}`;
    if (!exists(receipt)) askReceipt(receipt, plan, manifest, subject, reason);
    escalate(run, subject, plan, manifest, reason);
    out(`  ask-captain: ${subject} (gate unavailable; no mutation)\n`);
    return 2;
  }
  if (said !== "") out(`  ${said}\n`);
  const decision = receiptValidate(receipt, plan, manifest, QUOTE_MIN);
  if (decision === null) {
    escalate(run, subject, plan, manifest, "The gate receipt did not match the immutable manifest and action-plan hashes.");
    out(`  ask-captain: ${subject} (invalid gate receipt; no mutation)\n`);
    return 2;
  }
  if (decision === "continue") {
    if (!subjectManifestValidate(manifest)) {
      escalate(run, subject, plan, manifest, "A live semantic input changed after the gate reviewed its immutable manifest.");
      out(`  ask-captain: ${subject} (post-gate input drift; no mutation)\n`);
      return 2;
    }
    if (!maintenanceApply(u8(plan), u8(run))) {
      warn(B(`continue receipt for Curate subject ${subject} became stale or could not resume`));
      return 1;
    }
    out(`  auto-applied semantic subject: ${subject}\n`);
    return 0;
  }
  if (decision === "revise") {
    out(`  revise: ${subject} (live records preserved; subject settled)\n`);
    return 0;
  }
  escalate(run, subject, plan, manifest, "The maintenance gate returned ask-captain for this exact subject.");
  out(`  ask-captain: ${subject} (gate could not prove the move; no mutation)\n`);
  return 2;
}

// The ruling recorded for this exact material: the first `- ` line whose
// FIELD 3 is `material=<fingerprint>` and that cites a non-empty ruling - an
// acknowledgement without its pointer is a mute button, and acknowledges
// nothing.
function acknowledged(fingerprint: string): string | null {
  const ledger = `${sub(liveHome(), "records")}/curate-acknowledged.md`;
  if (!isFile(ledger)) return null;
  for (const l of records(read(ledger) ?? "")) {
    const f = l.replace(/^[ \t\n]+/, "").split(/[ \t\n]+/);
    if (f[0] !== "-" || f[2] !== `material=${fingerprint}`) continue;
    const i = l.indexOf("ruling:");
    if (i < 0) continue;
    const r = l.slice(i + 7).replace(/^[ \t]+|[ \t]+$/g, "");
    if (r !== "") return r;
  }
  return null;
}

// An immutable empty plan and a non-authorizing ask receipt for a subject
// with no safe mutation plan: 0 when its material carries a recorded captain
// ruling (settled, nothing written), else 2 - a real unresolved subject the
// run must not reset cadence over.
function blockedSubject(run: string, subject: string, reason: string, material: string): number {
  let ack = "";
  if (material !== "") {
    const fingerprint = sha256Of(material);
    const ruling = acknowledged(fingerprint);
    if (ruling !== null) {
      out(`  settled: ${subject} (acknowledged - ruling: ${ruling})\n`);
      return 0;
    }
    ack = `- ${subject} material=${fingerprint} ruling: <the records/ line that already decided this>`;
  }
  const manifest = `${run}/manifests/${subject}.json`;
  const plan = `${run}/plans/${subject}.json`;
  const actions = `${run}/plans/.${subject}.actions`;
  const receipt = `${run}/gates/${subject}/decision.md`;
  spawn(["mkdir", "-p", dirname(manifest), dirname(receipt), `${run}/subjects`]);
  put(`${run}/subjects/${subject}.md`, `# Curate Blocked Subject: ${subject}\n\n${reason}\n${ack === "" ? "" : `\nAlready ruled on? Append this line to records/curate-acknowledged.md,\nreplacing the placeholder with the ruling that decided it:\n\n${ack}\n`}`);
  put(actions, "");
  subjectManifest(manifest, subject, [`data/${basename(run)}/subjects/${subject}.md`]);
  subjectPlan(plan, run, subject, manifest, actions);
  rmF(actions);
  askReceipt(receipt, plan, manifest, subject, reason);
  escalate(run, subject, plan, manifest, reason, ack);
  out(`  ask-captain: ${subject} (no unique safe plan; no mutation)\n`);
  if (ack !== "") out(`    already ruled? record it in records/curate-acknowledged.md:\n      ${ack}\n`);
  return 2;
}

const sha256Of = (s: string): string => new Bun.CryptoHasher("sha256").update(B(s)).digest("hex");

// --- run: the semantic subjects ---------------------------------------------------

// Registry lines whose fleet-local project path is absent; audit-only
// mismatches are not candidates.
function projectCandidates(): string[] {
  const h = liveHome();
  const o: string[] = [];
  for (const wire of registryLines(h)) {
    const [nr, name, line] = tabFields(wire, 3) as [string, string, string];
    if (!/^[A-Za-z0-9._-]+$/.test(name)) continue;
    if (!exists(`${sub(h, "projects")}/${name}`)) o.push(`${nr}\t${name}\t${line}`);
  }
  return o;
}

// The project subject's manifest<TAB>plan, null when its registry line is not
// one exact line (both read as bytes, so a line holding an invalid byte still
// is). Every other step's failure goes on unseen, as inside the original's
// `$(...)`.
function prepareProject(run: string, name: string, line: string): string | null {
  const subject = `project-${name}`;
  const staged = `${run}/staged/${subject}/records`;
  const actions = `${run}/plans/.${subject}.actions`;
  const manifest = `${run}/manifests/${subject}.json`;
  const plan = `${run}/plans/${subject}.json`;
  const rec = sub(liveHome(), "records");
  const registry = `${rec}/projects.md`;
  const archive = `${rec}/projects-archive.md`;
  if (grepCount(registry, line, true) !== "1") return null;
  const nr = (grepPrint(registry, fixedHit(line, true), true)[0] ?? "").split(":")[0]!;
  spawn(["mkdir", "-p", staged, dirname(manifest), `${run}/subjects`]);
  const drop = /^[0-9]+$/.test(nr) ? Number(nr) : -1;
  put(`${staged}/projects.md`, awkKeep(read(registry) ?? "", (n) => n !== drop));
  if (isFile(archive)) spawn(["cp", archive, `${staged}/projects-archive.md`]);
  if (!isFile(archive)) put(`${staged}/projects-archive.md`, "# Projects Archive\n\n");
  put(`${staged}/projects-archive.md`, `${line}\n`, true);
  put(`${run}/subjects/${subject}.md`, `# Curate Semantic Subject: ${subject}\n\nThe registered project path is absent. The proposed action moves the original registry line verbatim into the fleet archive. It never deletes a clone or remote.\n`);
  put(actions, "");
  planAction(actions, "rewrite-registry", "records/projects.md", `staged/${subject}/records/projects.md`, run);
  planAction(actions, "append-archive", "records/projects-archive.md", `staged/${subject}/records/projects-archive.md`, run);
  subjectManifest(manifest, subject, ["records/projects.md", "records/projects-archive.md", `projects/${name}`]);
  subjectPlan(plan, run, subject, manifest, actions);
  rmF(actions);
  return `${manifest}\t${plan}`;
}

// A prepared subject through the gate: the unresolved flag it leaves.
function gatePrepared(run: string, subject: string, prepared: string, what: string): boolean {
  const [manifest, plan] = tabFields(prepared.split("\n")[0]!, 2) as [string, string];
  const rc = gateSubject(run, subject, manifest, plan);
  if (rc === 0) return false;
  if (rc !== 2) warn(B(`${what} could not apply safely`));
  return true;
}

function semanticProjects(run: string): boolean {
  let unresolved = false;
  for (const wire of projectCandidates()) {
    const [nr, name, line] = tabFields(wire, 3) as [string, string, string];
    if (nr === "") continue;
    const prepared = prepareProject(run, name, line);
    if (prepared === null) {
      if (blockedSubject(run, `project-${name}`, "The project registry entry could not be staged as a unique verbatim archive move.", line) !== 0) unresolved = true;
      continue;
    }
    if (gatePrepared(run, `project-${name}`, prepared, `project subject ${name}`)) unresolved = true;
  }
  return !unresolved;
}

// `subject<TAB>live-first-line<TAB>target-first-line<TAB>class` per live
// SUPERSEDES ruling: directional "above/below" and an explicit date after the
// LAST SUPERSEDES (a date naming exactly one other block's first line) are
// the closed target grammar; anything else is an ambiguous captain subject.
function namedCaptainCandidates(): string[] {
  const captain = `${sub(liveHome(), "records")}/captain.md`;
  if (!isFile(captain)) return [];
  const first: string[] = [""];
  const text: string[] = [""];
  let start = 0;
  let firstline = "";
  let block = "";
  const flush = (): void => {
    if (!start) return;
    first.push(firstline);
    text.push(block);
    start = 0;
    block = "";
  };
  records(read(captain) ?? "").forEach((l, i) => {
    if (l.startsWith("- ")) {
      flush();
      start = i + 1;
      firstline = block = l;
    } else if (start && /^[ \t]/.test(l)) block += `\n${l}`;
    else flush();
  });
  flush();
  const n = first.length - 1;
  const o: string[] = [];
  for (let i = 1; i <= n; i++) {
    if (!text[i]!.includes("SUPERSEDES")) continue;
    let target = 0;
    if (lower(text[i]!).includes("below")) target = i + 1;
    else if (lower(text[i]!).includes("above")) target = i - 1;
    else {
      const rest = text[i]!.slice(text[i]!.lastIndexOf("SUPERSEDES") + 10);
      const m = /[0-9]{4}-[0-9]{2}-[0-9]{2}/.exec(rest);
      if (m) {
        let hits = 0;
        for (let j = 1; j <= n; j++)
          if (j !== i && first[j]!.includes(m[0])) {
            target = j;
            hits++;
          }
        if (hits !== 1) target = 0;
      }
    }
    let cls = "movable";
    if (!target || target < 1 || target > n) cls = "ambiguous";
    else if (lower(text[target]!).includes("holds")) cls = "partial";
    o.push(`captain-supersedes-${i}\t${first[i]}\t${target ? (first[target] ?? "") : ""}\t${cls}`);
  }
  return o;
}

// The rule BLOCK a unique first line identifies, as `<start> <end>`: from
// that line to the one before the next `- ` line, else to the end of the
// file; null for a first line that is not exactly one line.
function captainBlockRange(captain: string, firstLine: string): [number, number] | null {
  if (grepCount(captain, firstLine, true) !== "1") return null;
  const startText = (grepPrint(captain, fixedHit(firstLine, true), true)[0] ?? "").split(":")[0]!;
  if (!/^[0-9]+$/.test(startText)) return null;
  const start = Number(startText);
  const recs = records(read(captain) ?? "");
  for (let nr = start + 1; nr <= recs.length; nr++) if (recs[nr - 1]!.startsWith("- ")) return [start, nr - 1];
  return recs.length >= start ? [start, recs.length] : null;
}

// Both rule BLOCKS in full, so an edit anywhere inside either one retires the
// acknowledgement while an edit elsewhere in captain.md leaves it standing.
function captainMaterial(live: string, target: string): string {
  const captain = `${sub(liveHome(), "records")}/captain.md`;
  const text = read(captain) ?? "";
  let o = "";
  for (const f of [live, target]) {
    if (f === "") continue;
    const r = captainBlockRange(captain, f);
    if (r !== null) o += sedRange(text, r[0], r[1]);
  }
  return subst(o);
}

function prepareCaptain(run: string, subject: string, live: string, target: string): string | null {
  const rec = sub(liveHome(), "records");
  const captain = `${rec}/captain.md`;
  const archive = `${rec}/captain-archive.md`;
  if (grepCount(captain, live, true) !== "1") return null;
  const range = captainBlockRange(captain, target);
  if (range === null) return null;
  const [start, end] = range;
  const text = read(captain) ?? "";
  if (lower(sedRange(text, start, end)).includes("holds")) return null;
  const staged = `${run}/staged/${subject}/records`;
  const actions = `${run}/plans/.${subject}.actions`;
  const manifest = `${run}/manifests/${subject}.json`;
  const plan = `${run}/plans/${subject}.json`;
  spawn(["mkdir", "-p", staged, dirname(manifest), `${run}/subjects`]);
  put(`${staged}/captain.md`, withArchiveLink(awkKeep(text, (nr) => nr < start || nr > end)));
  if (isFile(archive)) spawn(["cp", archive, `${staged}/captain-archive.md`]);
  if (!isFile(archive)) put(`${staged}/captain-archive.md`, CAPTAIN_ARCHIVE_HEAD);
  put(`${staged}/captain-archive.md`, `\n## curated ${b8(iso())} - named supersession\nsuperseded-by: ${live}\n${sedRange(text, start, end)}`, true);
  put(`${run}/subjects/${subject}.md`, `# Curate Semantic Subject: ${subject}\n\n## Live ruling (must remain)\n\n${live}\n\n## Named target (proposed verbatim archive)\n\n${sedRange(text, start, end)}`);
  put(actions, "");
  planAction(actions, "append-archive", "records/captain-archive.md", `staged/${subject}/records/captain-archive.md`, run);
  planAction(actions, "rewrite-registry", "records/captain.md", `staged/${subject}/records/captain.md`, run);
  subjectManifest(manifest, subject, ["records/captain.md", "records/captain-archive.md"]);
  subjectPlan(plan, run, subject, manifest, actions);
  rmF(actions);
  return `${manifest}\t${plan}`;
}

function semanticCaptain(run: string): boolean {
  const archive = `${sub(liveHome(), "records")}/captain-archive.md`;
  let unresolved = false;
  for (const wire of namedCaptainCandidates()) {
    const [subject, live, target, cls] = tabFields(wire, 4) as [string, string, string, string];
    if (subject === "") continue;
    if (isFile(archive) && grepQuiet(archive, `superseded-by: ${live}`)) {
      out(`  settled: ${subject} (named target already archived under this live ruling)\n`);
      continue;
    }
    const prepared = cls === "movable" ? prepareCaptain(run, subject, live, target) : null;
    if (prepared === null) {
      if (blockedSubject(run, subject, "A live SUPERSEDES ruling does not identify one wholly retired target, or the named target retains a partial 'holds' qualifier.", captainMaterial(live, target)) !== 0) unresolved = true;
      continue;
    }
    if (gatePrepared(run, subject, prepared, `captain supersession subject ${subject}`)) unresolved = true;
  }
  return !unresolved;
}

// The single canonical active pointer of <name>; null for none or several.
function skillPointerLine(name: string): string | null {
  const ledger = `${sub(liveHome(), "records")}/learnings.md`;
  if (!isFile(ledger)) return null;
  const marker = `[distilled -> ${name}]`;
  if (grepCount(ledger, marker, false) !== "1") return null;
  return subst(grepPrint(ledger, fixedHit(marker, false)).map((l) => `${l}\n`).join(""));
}

// The umbrella it would fold into plus the live skill body, so a rewritten
// skill retires its acknowledgement.
function skillMaterial(umbrella: string, name: string): string {
  const skill = `${sub(liveHome(), "skills")}/${name}/SKILL.md`;
  return subst(`umbrella=${umbrella}\n${isFile(skill) ? (read(skill) ?? "") : ""}`);
}

// A tree walked as `find <dir> <test>`: the first entry a test admits, for
// `-print -quit`; unreadable subtrees are skipped as find's own complaint was.
function findFirst(dir: string, test: (p: string) => boolean): boolean {
  if (test(dir)) return true;
  let names: Uint8Array[] = [];
  try {
    if (!lstatSync(B(dir)).isDirectory()) return false;
    names = readdirSync(B(dir), { encoding: "buffer" });
  } catch {
    return false;
  }
  return names.some((n) => findFirst(`${dir}/${Buffer.from(n).toString("latin1")}`, test));
}

// `find <dir> -type f`, every regular file below <dir> (links never followed).
function findFiles(dir: string): string[] {
  const o: string[] = [];
  const walk = (d: string): void => {
    let st;
    try {
      st = lstatSync(B(d));
    } catch {
      return;
    }
    if (st.isFile()) {
      o.push(d);
      return;
    }
    if (!st.isDirectory()) return;
    let names: Uint8Array[] = [];
    try {
      names = readdirSync(B(d), { encoding: "buffer" });
    } catch {
      return;
    }
    for (const n of names) walk(`${d}/${Buffer.from(n).toString("latin1")}`);
  };
  walk(dir);
  return o;
}

// Every file of the live package moves under the reserved archive while the
// canonical pointer changes rung in the same transaction. Only the explicit
// refusals refuse; every other step's failure goes on (W10).
function prepareSkill(run: string, umbrella: string, name: string): string | null {
  const h = liveHome();
  const skills = sub(h, "skills");
  const rec = sub(h, "records");
  const subject = `skill-${name}`;
  const source = `${skills}/${name}`;
  const archiveDir = `${skills}/${SKILLS_ARCHIVE}/${name}`;
  const evidence = `${rec}/learnings-archive/${name}.md`;
  const ledger = `${rec}/learnings.md`;
  const index = `${rec}/learnings-archive/index.md`;
  const staged = `${run}/staged/${subject}`;
  const actions = `${run}/plans/.${subject}.actions`;
  const manifest = `${run}/manifests/${subject}.json`;
  const plan = `${run}/plans/${subject}.json`;
  if (!isFile(`${skills}/${umbrella}/SKILL.md`)) return null;
  if (!isDir(source) || isLink(source) || exists(archiveDir)) return null;
  if (!isFile(evidence) || isLink(evidence)) return null;
  const pointer = skillPointerLine(name);
  if (pointer === null) return null;
  if (activeDependency(h, name) !== "") return null;
  const kind = (p: string): string => {
    try {
      const st = lstatSync(B(p));
      return st.isSymbolicLink() ? "l" : st.isDirectory() ? "d" : st.isFile() ? "f" : "o";
    } catch {
      return "";
    }
  };
  if (findFirst(source, (p) => kind(p) === "l")) return null;
  if (findFirst(source, (p) => kind(p) === "l" || kind(p) === "o")) return null;
  const archiveRel = `skills/${SKILLS_ARCHIVE}/${name}`;
  spawn(["mkdir", "-p", `${staged}/${archiveRel}`, `${staged}/records/learnings-archive`, dirname(manifest), `${run}/subjects`]);
  put(actions, "");
  // find's paths as `| sort` reads them: LF-separated lines, sorted.
  for (const file of findFiles(source).join("\n").split("\n").sort()) {
    if (file === "") continue;
    const rel = file.startsWith(`${source}/`) ? file.slice(source.length + 1) : file;
    spawn(["mkdir", "-p", `${staged}/${archiveRel}/${dirname(rel)}`]);
    spawn(["cp", file, `${staged}/${archiveRel}/${rel}`]);
    planAction(actions, "move-skill", `${archiveRel}/${rel}`, `staged/${subject}/${archiveRel}/${rel}`, run);
  }
  const marker = awkAssign(`[distilled -> ${name}]`);
  put(`${staged}/records/learnings.md`, records(read(ledger) ?? "").map((l) => (l.includes(marker) ? "" : `${l}\n`)).join(""));
  if (isFile(index)) spawn(["cp", index, `${staged}/records/learnings-archive/index.md`]);
  if (!isFile(index)) put(`${staged}/records/learnings-archive/index.md`, "# Archived Learning Pointers\n\n");
  const field = (re: RegExp): string => subst(pointer.split("\n").map((l) => { const m = re.exec(l); return m ? `${m[1]}\n` : ""; }).join(""));
  const sources = field(/^.*sources=([0-9][0-9]*).*$/s);
  const updated = field(/^.*updated=([0-9][0-9-]*).*$/s);
  if (!/^[0-9]+$/.test(sources)) return null;
  if (updated.length !== 10 || !/^.{4}-.{2}-.{2}$/s.test(updated)) return null;
  put(`${staged}/records/learnings-archive/index.md`, `- [distilled -> ${name}] sources=${sources} updated=${updated} ([skill](../../skills/${SKILLS_ARCHIVE}/${name}/SKILL.md); [evidence](${name}.md))\n`, true);
  planAction(actions, "rewrite-ledger", "records/learnings.md", `staged/${subject}/records/learnings.md`, run);
  planAction(actions, "rewrite-index", "records/learnings-archive/index.md", `staged/${subject}/records/learnings-archive/index.md`, run);
  put(`${run}/subjects/${subject}.md`, `# Curate Semantic Subject: ${subject}\n\nUmbrella skill \`${umbrella}\` remains live. The gate must confirm it preserves the behavior of \`${name}\` before authorizing the recoverable move and canonical pointer update.\n`);
  subjectManifest(manifest, subject, [`skills/${umbrella}/SKILL.md`, `skills/${name}/SKILL.md`, `${archiveRel}/SKILL.md`, "records/learnings.md", "records/learnings-archive/index.md", `records/learnings-archive/${name}.md`]);
  subjectPlan(plan, run, subject, manifest, actions);
  rmF(actions);
  return `${manifest}\t${plan}`;
}

function semanticSkills(run: string): boolean {
  let unresolved = false;
  for (const l of clusterPlan(sub(liveHome(), "skills"))) {
    const [kind, umbrella, name] = tabFields(l, 3) as [string, string, string];
    if (kind !== "move") continue;
    const prepared = prepareSkill(run, umbrella, name);
    if (prepared === null) {
      if (blockedSubject(run, `skill-${name}`, "The skill lacks a unique safe consolidation plan: its canonical pointer, evidence archive, archive destination, or active-worktree dependency is unresolved.", skillMaterial(umbrella, name)) !== 0) unresolved = true;
      continue;
    }
    if (gatePrepared(run, `skill-${name}`, prepared, `skill subject ${name}`)) unresolved = true;
  }
  return !unresolved;
}

// --- run ---------------------------------------------------------------------------

const DETERMINISTIC = ["captain.md", "captain-archive.md", "backlog.md", "backlog-archive.md"];

function cmdRun(dryRun: boolean): void {
  if (dryRun) {
    out("== records-wide CURATE pass (--dry-run; read-only) ==\n");
    curateLearnings();
    curateCaptain(liveHome(), false, true);
    curateBacklog(liveHome(), false, true);
    curateProjects();
    curateSkillsAudit();
    out("== curate dry-run complete; no backup, mutation, receipt, or cadence reset ==\n");
    return;
  }
  const home = liveHome();
  const generation = curateGeneration();
  const run = `${sub(home, "data")}/curate-${b8(nowRaw())}-${process.pid}`;
  const shadow = `${run}/shadow`;
  const report = `${run}/report.md`;
  const actions = `${run}/actions.ndjson`;
  const manifest = `${run}/input-manifest.json`;
  const plan = `${run}/plans/deterministic-records.json`;
  const receipt = `${run}/gates/deterministic-records/decision.md`;
  const pristine = `${run}/pristine`;
  const mk = spawn(["mkdir", "-p", `${shadow}/records`, `${shadow}/state`, `${shadow}/skills`, `${run}/staged/records`, pristine, dirname(plan), dirname(receipt)]).status;
  if (mk !== 0) fatal(mk);

  if (!inputManifest(manifest)) die("Curate input manifest refused a non-file or symlink");
  const records_ = sub(home, "records");
  for (const base of DETERMINISTIC) {
    if (isFile(`${records_}/${base}`)) {
      const st = spawn(["cp", `${records_}/${base}`, `${shadow}/records/${base}`]).status;
      if (st !== 0) fatal(st);
    }
    // The bytes the passes below are about to read, captured NOW - not a live
    // re-read once they (and a concurrent captain write) may have moved on.
    const s = shaOrAbsent(`${shadow}/records/${base}`);
    if (!put(`${pristine}/${base}`, s === null ? "" : `${s}\n`) || s === null) die(`Curate could not hash the pristine ${u8(base)} snapshot`);
  }

  // The deterministic stand-in for a captain write landing inside the passes'
  // real multi-second window. Double-keyed: the hook execs whatever the env
  // names, so AC_TEST_HOOKS=1 (exported by tests/sh/helpers.sh and nothing
  // else) must be set too.
  const hook = process.env.AC_CURATE_SNAPSHOT_HOOK ?? "";
  if (process.env.AC_TEST_HOOKS === "1" && hook !== "" && executable(hook))
    spawn([b8(hook), records_]);

  out("== records-wide CURATE pass (automatic deterministic apply) ==\n");
  curateLearnings();
  curateProjects();
  curateSkillsAudit();
  let fd: number;
  try {
    fd = openSync(B(report), "w");
  } catch {
    return fatal(1);
  }
  OUT = fd;
  try {
    curateCaptain(shadow, true, true);
    curateBacklog(shadow, true, true);
  } finally {
    OUT = 1;
    closeSync(fd);
  }
  // Those passes name the shadow copy; the transaction below writes the live
  // records, and that is the path a reader of the report acts on. Byte for
  // byte as the original's `tr -d '\000' | awk` capture: NULs dropped, each
  // line's shadow prefix replaced left to right, every trailing LF cut and one
  // printed back.
  const pat = `${shadow}/`;
  const body = records((read(report) ?? "").replace(/\0/g, ""))
    .map((l) => l.split(pat).join(`${home}/`))
    .join("\n")
    .replace(/\n+$/, "");
  if (!put(report, `${body}\n`)) fatal(1);
  out(`${body}\n`);

  if (!put(actions, "")) fatal(1);
  let changed = 0;
  for (const base of ["captain-archive.md", "captain.md", "backlog-archive.md", "backlog.md"]) {
    if (!isFile(`${shadow}/records/${base}`)) continue;
    if (isFile(`${records_}/${base}`) && sameBytes(`${records_}/${base}`, `${shadow}/records/${base}`)) continue;
    const st = spawn(["cp", `${shadow}/records/${base}`, `${run}/staged/records/${base}`]).status;
    if (st !== 0) fatal(st);
    const op = base.endsWith("-archive.md") ? "append-archive" : "rewrite-registry";
    if (!planAction(actions, op, `records/${base}`, `staged/records/${base}`, run, subst(read(`${pristine}/${base}`) ?? ""))) fatal(1);
    changed++;
  }
  const pst = spawnTo(plan, [
    "jq",
    "-s",
    "--arg",
    "run_id",
    basename(run),
    "--arg",
    "manifest",
    shaText(manifest),
    "{schema:\"agentcrew.maintenance-plan/v1\",mode:\"curate\",run_id:$run_id,\n      subject:\"deterministic-records\",input_manifest_sha256:$manifest,actions:.}",
    actions,
  ]);
  if (pst !== 0) fatal(pst ?? 1);
  rmF(actions);
  if (!policyReceipt(receipt, plan, manifest)) fatal(1);
  const decision = receiptValidate(receipt, plan, manifest, QUOTE_MIN);
  if (decision === null) die("Curate policy receipt failed its own hash/schema validation");
  if (decision !== "continue") die("Curate deterministic policy did not authorize its plan");
  if (!maintenanceApply(u8(plan), u8(run))) die("Curate maintenance transaction could not apply or resume safely");

  out("== semantic Curate subjects (maintenance gate) ==\n");
  let unresolved = !semanticCaptain(run);
  if (!semanticProjects(run)) unresolved = true;
  if (!semanticSkills(run)) unresolved = true;
  if (unresolved) {
    const [rn, rx] = curateDue();
    out(`== curate pass open: deterministic subjects committed; unresolved semantic/captain subject(s) preserve cadence=${b8(rn)}/${b8(rx)} ==\n`);
    return;
  }
  let reset: boolean;
  try {
    reset = curateReset(generation);
  } catch {
    return fatal(1);
  }
  if (!reset)
    warn("Curate committed, but did not reset its cadence: either a newer cadence generation exists and its late Learning ticks were preserved, or the cadence lock was not acquired (warned just above)");
  const [rn, rx] = curateDue();
  out(`== curate pass complete: ${changed} changed record file(s); transaction + policy receipt committed; interval=${b8(rn)}/${b8(rx)} ==\n`);
}

const sameBytes = (a: string, b: string): boolean => {
  try {
    return readFileSync(B(a)).equals(readFileSync(B(b)));
  } catch {
    return false;
  }
};

// `[ -x ]`: execute (or, for a directory, search) permission for this user.
function executable(p: string): boolean {
  try {
    accessSync(p, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// --- dispatch ----------------------------------------------------------------------

const USAGE = "usage: ac-curate.sh learnings|captain [--apply]|backlog [--apply]|projects|skills-audit|skills-consolidate [--apply]|run [--dry-run]";

function main(args: string[]): number {
  const [cmd = "", ...flags] = args;
  let apply = false;
  let dryRun = false;
  for (const a of flags) {
    if (a === "--apply") apply = true;
    else if (a === "--dry-run") dryRun = true;
    else die(`unknown flag: ${a}`);
  }
  switch (cmd) {
    case "learnings":
      curateLearnings();
      return 0;
    case "captain":
      curateCaptain(liveHome(), apply, false);
      return 0;
    case "backlog":
      curateBacklog(liveHome(), apply, false);
      return 0;
    case "projects":
      curateProjects();
      return 0;
    case "skills-audit":
      curateSkillsAudit();
      return 0;
    case "skills-consolidate":
      return curateSkillsConsolidate(apply);
    case "run":
      cmdRun(dryRun);
      return 0;
  }
  die(USAGE);
}

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  let rc: number;
  try {
    rc = main(args);
  } catch (e) {
    if (typeof (e as Exit).exit !== "number") throw e;
    rc = (e as Exit).exit;
  }
  process.exit(rc);
}
