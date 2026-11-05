// lib-domain.ts - the domain twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { acDoneline, records } from "./backlog.ts";
import { existsSync, lstatSync, readFileSync, readlinkSync, writeSync } from "node:fs";
import { basename, dirname } from "node:path";
import {
  capturedText,
  die,
  isFile,
  isLink,
  lat,
  namedCwd,
  physicalDir,
  projectDir,
  softHome,
  softSubdir,
  spawnShellSync,
} from "./lib.ts";

// ac_domain_registry's twin: `<records>/crewdomains.md`, records/ minted;
// homeless, the refusal printed and `/crewdomains.md`.
export function domainRegistry(): string {
  return `${softSubdir("records", true)}/crewdomains.md`;
}

// ac_domain_parse's program, byte for byte: tests/ts/domain.test.ts lifts it
// out of bin/ac-lib.sh, whose function stays live for ac-spawn and the
// dashboard's pin. Its comments quote words in backticks, which a template
// literal cannot hold raw.
const BT = "`";

const DOMAIN_PARSE_AWK = String.raw`
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function bad(reason) { printf "INVALID\t%s\t\t\t%s\n", $0, reason }
    {
      if (substr($0, 1, 2) != "- ") next
      rest = substr($0, 3)
      if (rest !~ / \(added [^)]*\)$/) { bad("missing \"(added ...)\""); next }
      sub(/ \(added [^)]*\)$/, "", rest)

      # Drop the ONE legitimate keyed field, then any keyed token left over is a
      # field this grammar does not have. Checked BEFORE the scope split so a
      # ${BT}home:${BT} line is refused by name rather than by a downstream symptom.
      probe = rest
      sub(/ - scope:/, "", probe)
      if (match(probe, / - [a-zA-Z][a-zA-Z0-9_-]*:/)) {
        bad("unknown field \"" substr(probe, RSTART + 3, RLENGTH - 3) "\""); next
      }

      p = index(rest, " - scope:")           # 9 chars
      if (p == 0) { bad("missing \"scope:\" field"); next }
      head = substr(rest, 1, p - 1)
      scope = trim(substr(rest, p + 9))

      q = index(head, " - ")                 # id, then the free-text charter
      if (q > 0) { id = trim(substr(head, 1, q - 1)); charter = trim(substr(head, q + 3)) }
      else { id = trim(head); charter = "" }
      if (charter == "") { bad("missing charter field"); next }

      # [a-z0-9-], TIGHTER than the loose read-path charset the deputy parser
      # uses, and equal to what ${BT}new${BT} mints - because a crewdomain id is
      # CONCATENATED into a package path. A parser calling ${BT}Payments${BT} VALID
      # would hand an id to a path verb that refuses it, and ${BT}list${BT} (which may
      # never exit non-zero) would then die on the digest. One charset, both
      # ends. NOTE: no apostrophes in this block - the awk program is inside a
      # shell single-quoted string, and one would close it.
      if (id !~ /^[a-z0-9-]+$/) { bad("bad id charset"); next }
      if (id in seen) { bad("duplicate id"); next }
      seen[id] = 1
      printf "VALID\t%s\t%s\t%s\t\n", id, charter, scope
    }
  `;

// ac_domain_parse's twin as the argv it ran - `awk <program> <file>` under
// the caller's locale, so a byte that is not UTF-8 aborts it under a UTF-8
// one (towc, exit 2) as it did the bash - for a caller to run and read.
// <file> defaults to domainRegistry(); null when it is no regular file, where
// the bash returned 0 with no record.
export function domainParse(file = ""): string[] | null {
  if (file === "") file = domainRegistry();
  return isFile(file) ? ["awk", DOMAIN_PARSE_AWK, file] : null;
}

// ac_domain_name_ok's twin: `''`, `/`, `.` and `..` refused, then the C
// locale's [a-z0-9-] - so the charset is the text's under any locale.
export function domainNameOk(name: string): boolean {
  return /^[a-z0-9-]+$/.test(name);
}

// ac_backlog_id_ok's twin, the same rule for a backlog row id.
export function backlogIdOk(id: string): boolean {
  return /^[a-z0-9-]+$/.test(id);
}

// `cd -P <p> && pwd -P`: entered as the kernel resolves it, links and `..`
// physically, never the lexical spelling physicalDir tries first.
function cdPhysical(p: string): string | null {
  const here = process.cwd();
  try {
    process.chdir(p);
    return namedCwd();
  } catch {
    return null;
  } finally {
    process.chdir(here);
  }
}

// `$(dirname ...)`, `$(basename ...)` and `$(readlink ...)` lost a trailing LF.
const noLF = (s: string): string => s.replace(/\n+$/, "");

// ac_domain_view_entry's twin: one projects/ view entry of <dom> classified as
// the capture read it - `ok`, `not-symlink`, `dangling`, `outside <target>`
// or `mismatch <target>`. The link chain is followed one hop at a time (its
// target resolved against the link's own physical dir) and stops the moment a
// hop lands in the physical <home>/projects - a fleet clone that is itself a
// symlink is trusted there - or after 16 hops (dangling); the landing point
// must sit under that dir and equal <clones>/<entry> as a literal string.
// Homeless, the refusal printed and the entry read under `/crewdomains`.
export function domainViewEntry(dom: string, entry: string): string {
  const home = softHome(true);
  const link = `${home}/crewdomains/${dom}/projects/${entry}`;
  const isLink = (p: string): boolean => {
    try {
      return lstatSync(p).isSymbolicLink();
    } catch {
      return false;
    }
  };
  if (!isLink(link)) return "not-symlink";
  if (!existsSync(link)) return "dangling";
  const clones = cdPhysical(`${home}/projects`) ?? `${home}/projects`;
  let t = link;
  let hops = 0;
  let landed = false;
  while (isLink(t) && hops < 16) {
    let d = cdPhysical(noLF(dirname(t)));
    if (d === null) return "dangling";
    let rl: string;
    try {
      rl = noLF(readlinkSync(t));
    } catch {
      return "dangling";
    }
    t = rl.startsWith("/") ? rl : `${d}/${rl}`;
    hops++;
    d = cdPhysical(noLF(dirname(t)));
    if (d === null) return "dangling";
    if (d === clones) {
      t = `${d}/${noLF(basename(t))}`;
      landed = true;
      break;
    }
  }
  if (!landed) {
    if (hops >= 16) return "dangling";
    const d = cdPhysical(noLF(dirname(t)));
    if (d === null) return "dangling";
    t = `${d}/${noLF(basename(t))}`;
  }
  if (!`${t}/`.startsWith(`${clones}/`)) return noLF(`outside ${t}`);
  if (t !== `${clones}/${entry}`) return noLF(`mismatch ${t}`);
  return "ok";
}

// ac_domain_qa_repo's twin: the main repo root of the project <dom>'s
// package member `qa-repo` names, null for none. The name is the member's
// first line with every [:space:] deleted by a spawned `tr` - the caller's
// locale decides what a space is, and under UTF-8 tr cuts at a byte that is
// not UTF-8 with its own line - then `[ -e <pkg>/projects/<name> ]` and
// projectDir (the physical path). Homeless, the refusal (stderr allowing) and
// null. <stderr> "ignore" is the caller that ran it under 2>/dev/null.
export function domainQaRepo(dom: string, stderr: "inherit" | "ignore" = "inherit"): string | null {
  if (!domainNameOk(dom)) return null;
  const home = softHome(stderr === "inherit");
  if (home === "") return null;
  const pkg = `${home}/crewdomains/${dom}`;
  let head = Buffer.alloc(0);
  try {
    const b = readFileSync(`${pkg}/qa-repo`);
    const lf = b.indexOf(10);
    head = lf < 0 ? b : b.subarray(0, lf + 1);
  } catch {}
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["tr", "-d", "[:space:]"], { stdin: head, stdout: "pipe", stderr });
  } catch {}
  const name = r === null ? "" : capturedText(Buffer.from(r.stdout));
  if (name === "") return null;
  const path = `${pkg}/projects/${Buffer.from(name, "latin1").toString("utf8")}`;
  if (!existsSync(path)) return null;
  return projectDir(path);
}

// ac_domain_tally's twin over the ledger's grammar in-process (records() +
// acDoneline(), the AC_DONELINE_AWK reading under LC_ALL=C):
// `<queued> <in flight> <done>` for the rows whose domain - their own token,
// else their epic row's - is <name> (every domain for ""), the section read
// from the last `## In flight` / `## Queued` / `## Done` PREFIX (any other
// `## ` line ends it), a [failed]/[abandoned] Done row not counted; `0 0 0`
// with no ledger. A ledger it cannot read is null, with the parser's own
// refusal where the original printed awk's `can't open file`.
export function domainTally(name: string): string | null {
  const f = `${softSubdir("records", true)}/backlog.md`;
  if (!isFile(f)) return "0 0 0";
  let text: string;
  try {
    text = readFileSync(f, "latin1");
  } catch {
    writeSync(2, Buffer.from(`ERROR: cannot read ${lat(f)}\n`, "latin1"));
    return null;
  }
  const recs = records(text);
  const dom = new Map<string, string>();
  for (const r of recs) {
    if (!r.startsWith("- [")) continue;
    const o = acDoneline(r);
    if (o.domain !== "") dom.set(o.id, o.domain);
  }
  const n: Record<string, number> = { q: 0, i: 0, d: 0 };
  let sec = "";
  for (const r of recs) {
    if (r.startsWith("## ")) sec = "";
    if (r.startsWith("## In flight")) sec = "i";
    else if (r.startsWith("## Queued")) sec = "q";
    else if (r.startsWith("## Done")) sec = "d";
    else if (r.startsWith("- [") && sec !== "") {
      const o = acDoneline(r);
      const d = o.domain === "" && o.epic !== "" ? dom.get(o.epic) ?? "" : o.domain;
      if (d === "" || (name !== "" && d !== name)) continue;
      if (sec === "d" && (o.terminal === "failed" || o.terminal === "abandoned")) continue;
      n[sec]!++;
    }
  }
  return `${n.q} ${n.i} ${n.d}`;
}
