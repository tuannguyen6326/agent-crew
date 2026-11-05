// lib-merge-local.ts - the merge-local twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { records } from "./backlog.ts";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  awkAssign,
  awkNumber,
  isDir,
  isFile,
  lat,
  lockAcquire,
  lockRelease,
  now,
  nowRaw,
  projectConfigName,
  roomFile,
  shellStatus,
  sleepOne,
  softHome,
  softSubdir,
  spawnShellSync,
  STARTED_BIN,
  tabFields,
  warn,
} from "./lib.ts";

// A string in awk arithmetic (onetrue awk's getfval is atof): strtod's longest
// numeric PREFIX - `17x` is 17, a hex or inf/nan spelling counts - and 0 when
// there is none, so a header line's epoch reads 0.
function awkAtof(s: string): number {
  const m = /^[ \t\n\v\f\r]*([+-]?)(?:0[xX]([0-9a-fA-F]+)|((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|([iI][nN][fF])|[nN][aA][nN])/.exec(s);
  if (!m) return 0;
  const sign = m[1] === "-" ? -1 : 1;
  if (m[2] !== undefined) return sign * parseInt(m[2], 16);
  if (m[3] !== undefined) return sign * Number(m[3]);
  return m[4] !== undefined ? sign * Infinity : NaN;
}

// awk's %d: the number cast to a 64-bit integer.
function awkInt(x: number): bigint {
  if (x >= 2 ** 63) return 2n ** 63n - 1n;
  if (x < -(2 ** 63)) return -(2n ** 63n);
  return Number.isNaN(x) ? 0n : BigInt(Math.trunc(x));
}

const landingsPath = (): string => `${softSubdir("state", true)}/.landings`;

// ac_landing_overlaps' awk over state/.landings, `<family>\t<age>\t<path>` per
// record: the epoch read as awk reads it, the family compared numerically when
// both sides look numeric (`07` is the family `7`), the path matched as a
// whole third field. An unreadable ledger throws awk's status 2 (its own
// `can't open file` line is not reproduced).
export function landingOverlaps(max: number, excl: string, paths: string[]): string[] {
  const f = landingsPath();
  if (!isFile(f) || paths.length === 0) return [];
  const now = awkAtof(awkAssign(nowRaw()));
  let text: string;
  try {
    text = readFileSync(f, "latin1");
  } catch {
    throw Object.assign(new Error(`cannot read ${f}`), { code: "EAWK", status: 2 });
  }
  const plist = lat(paths.join("\n")).replace(/\n+$/, "");
  const want = new Set(plist === "" ? [] : plist.split("\n"));
  const ex = awkAssign(lat(excl));
  const exN = awkNumber(ex);
  const hits: string[] = [];
  for (const r of records(text)) {
    const [f1 = "", f2 = "", f3 = ""] = r.split("\t");
    const age = now - awkAtof(f1);
    if (!(age < max) || !want.has(f3)) continue;
    const n2 = exN === null ? null : awkNumber(f2);
    if (n2 !== null && exN !== null ? !(n2 - exN < 0 || n2 - exN > 0) : f2 === ex) continue;
    hits.push(`${f2}\t${awkInt(age)}\t${f3}`);
  }
  return hits;
}

// ac_landing_warn's twin (no entry calls the bash copy, nor the
// ac_landing_overlaps under it, now): one
// `LANDING-OVERLAP: <path> landed <h>h ago by family <f> - required reading:
// <room>` WARN per record younger than a day from another family touching one
// of <paths>, read back as `IFS=$'\t' read -r` reads it - so a record with an
// EMPTY family shifts its age into the family and its path into the age.
// Where the bash's errexit ended the run it throws with the status: 2 for an
// unreadable ledger, 1 for an age the shell's arithmetic refused under
// nounset - here any but a plain decimal (the shell evaluated the shifted path
// as an expression, so `p` or `UID` read as numbers there; not reproduced).
export function landingWarn(fam: string, paths: string[]): void {
  for (const hit of landingOverlaps(86400, fam, paths)) {
    const [pf, age, p] = tabFields(hit, 3) as [string, string, string];
    if (age !== "" && !/^-?(0|[1-9][0-9]*)$/.test(age)) throw Object.assign(new Error(`arithmetic on ${age}`), { code: "EARITH", status: 1 });
    const hours = age === "" ? 0n : BigInt(age) / 3600n;
    const room = lat(roomFile(Buffer.from(pf, "latin1").toString("utf8")));
    warn(Buffer.from(`LANDING-OVERLAP: ${p} landed ${hours}h ago by family ${pf} - required reading: ${room}`, "latin1"));
  }
}

// ac_landing_record's twin (no entry calls the bash copy now): under
// state/.landings.lock (10 s through a spawned `sleep`, then the UNSERIALIZED
// WARN and the write anyway) the ledger is rewritten with its records older
// than 7 days pruned by awk's reading and `<now>\t<fam>\t<path>` appended per
// path, <now> as ac_now spelled it. The temp is created EXCLUSIVELY
// (`<ledger>.tmp.<pid>`, the next name on EEXIST - the bash wrote through a
// planted sibling) and a spawned `mv` renames it over the ledger: false when
// the mv failed, the bash's return 1. Where the bash's errexit ended the run
// it throws with the status, the lock left held as it was there: 2 for an
// unreadable ledger, 1 for a temp that cannot be created.
export function landingRecord(fam: string, paths: string[]): boolean {
  if (paths.length === 0) return true;
  const f = landingsPath();
  const lock = `${f}.lock`;
  const locked = lockAcquire(lock, 10, sleepOne);
  if (!locked)
    warn(`landing ledger: ${lock} could not be acquired within 10s - recording UNSERIALIZED, so a concurrent landing's records may be lost and its <24h LANDING-OVERLAP warn may not fire for them`);
  const now = nowRaw();
  const nowN = awkAtof(awkAssign(now));
  let body = "";
  if (isFile(f)) {
    let text: string;
    try {
      text = readFileSync(f, "latin1");
    } catch {
      throw Object.assign(new Error(`cannot read ${f}`), { code: "EAWK", status: 2 });
    }
    for (const r of records(text)) if (nowN - awkAtof(r.split("\t")[0]!) <= 604800) body += `${r}\n`;
  }
  for (const p of paths) body += `${now}\t${lat(fam)}\t${lat(p)}\n`;
  let tmp = `${f}.tmp.${process.pid}`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, Buffer.from(body, "latin1"), { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw Object.assign(e as object, { status: 1 });
      tmp = `${f}.tmp.${process.pid}.${i}`;
    }
  }
  let status = 127;
  try {
    status = shellStatus(spawnShellSync(["mv", tmp, f], { stdin: "ignore", stdout: "inherit", stderr: "inherit" }));
  } catch {}
  if (locked) lockRelease(lock);
  return status === 0;
}

// ac_knowledge_warn's twin (no entry calls the bash copy now): the KNOWLEDGE-GAP
// WARN when <fam> left no live `- ... | by: <fam>` entry in the project's
// repo-knowledge record - the suffix compared as a string (awk -v read its
// escapes), the scan stopped at `## Superseded`. Silent for an empty family,
// a <repo> that is no directory or no repo. The remedy names
// <STARTED_BIN>/ac-know.sh, the bin/ of ac_root, and the physical home. An
// unreadable record is no entry (awk's own line is not reproduced).
export function knowledgeWarn(fam: string, repo: string): void {
  if (fam === "" || repo === "" || !isDir(repo)) return;
  let repoOk = false;
  try {
    repoOk = spawnShellSync(["git", "-C", repo, "rev-parse", "--git-dir"], { stdin: "inherit", stdout: "ignore", stderr: "ignore" }).exitCode === 0;
  } catch {}
  if (!repoOk) return;
  const name = projectConfigName(repo);
  if (name === null) return;
  const rec = `${softSubdir("records", false)}/repo-knowledge/${name}.md`;
  let text = "";
  try {
    if (isFile(rec)) text = readFileSync(rec, "latin1");
  } catch {}
  const suffix = awkAssign(lat(`| by: ${fam}`));
  for (const r of records(text)) {
    if (r.startsWith("## Superseded")) break;
    if (r.startsWith("- ") && r.endsWith(suffix)) return;
  }
  const home = softHome(true);
  warn(
    `KNOWLEDGE-GAP: family ${fam} is landing on ${name} with no repo-knowledge entry -\nrecord what it learned (${STARTED_BIN}/ac-know.sh add --home ${home} --repo ${repo} --family ${fam} --src-file <path>:<line> --fact '<what you learned>')\nor dismiss if it learned nothing about the codebase. Record: ${rec}`,
  );
}
