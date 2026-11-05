// lib-learn.ts - the learn twins: the TypeScript twins of the ac-learn.sh and
// ac-maintenance-lib.sh helpers that src/learn.ts alone calls, kept beside
// their port by src/lib.ts's fanout rule (its header) so a change here
// selects learn's tests, not every module's. Each keeps its bash original's
// observable contract, as every twin in src/lib.ts does.

import { closeSync, readdirSync, readFileSync } from "node:fs";
import {
  arithValue,
  capturedText,
  configReadSoft,
  exclusiveTemp,
  homeSubdir,
  isDir,
  isFile,
  lat,
  lockAcquire,
  lockRelease,
  nowRaw,
  shellStatus,
  sleepOne,
  softSubdir,
  spawnShellSync,
  stage,
  warn,
  writeAll,
} from "./lib.ts";
import { curateMeta, metaGetSoft, metaSetSoft } from "./lib-curate.ts";

// ac_learn_meta / ac_learn_ticks twins: the dot-files under state/ (minted),
// outside the state/*.meta crewmate namespace.
export const learnMeta = (): string => `${softSubdir("state", true)}/.learn.meta`;
export const learnTicks = (): string => `${softSubdir("state", true)}/.learn-ticks`;
const learnCadenceLock = (): string => `${softSubdir("state", true)}/.learn-cadence.lock`;

// `{ ... } >"$f.tmp.$$"; mv "$f.tmp.$$" "$f"`: <fill> writes the temp, made
// exclusively (<f>.tmp.<pid>, then .<n>) where the bash's name was written
// through, and a spawned mv renames it; mv's status, 1 when no temp could be
// made (the bash's redirect failed and its mv found nothing to move).
function viaTemp(f: string, fill: (fd: number) => void): number {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(`${f}.tmp`);
  } catch {
    return 1;
  }
  try {
    fill(t.fd);
  } finally {
    closeSync(t.fd);
  }
  return stage(["mv", t.path, f], "inherit", "inherit", "inherit").status;
}

// One spawned child writing to <fd>, its stdin the caller's; its status.
function stageTo(cmd: string[], fd: number): number {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout: fd, stderr: "inherit" });
  } catch {}
  return shellStatus(r);
}

// ac_learn_migrate's twin: a meta holding the legacy `stows` key carries its
// count to `debriefs` (unless debriefs is already set - never clobbered) and
// loses every `stows=` line through a spawned `grep -v`, whose own failure is
// ignored as `|| true` ignored it.
export function learnMigrate(f: string): void {
  if (!isFile(f)) return;
  const old = metaGetSoft(f, "stows");
  if (old === "") return;
  if (metaGetSoft(f, "debriefs") === "") metaSetSoft(f, "debriefs", old);
  viaTemp(f, (fd) => {
    stageTo(["grep", "-v", "^stows=", f], fd);
  });
}

// `$((n + 1))` over a digits-only count: a leading 0 reads octal, and an 8 or
// 9 behind it throws EARITH where the shell's arithmetic error ended it.
const plusOne = (n: string): string => String(BigInt.asIntN(64, arithValue(n) + 1n));
const digitsOr = (v: string, d: string): string => (/^[0-9]+$/.test(v) ? v : d);

// ac_learn_count_one's twin, for a caller already holding the cadence lock:
// migrate, then generation (rewritten as read) and debriefs+1.
export function learnCountOne(): void {
  const f = learnMeta();
  learnMigrate(f);
  const cur = digitsOr(metaGetSoft(f, "debriefs"), "0");
  const gen = digitsOr(metaGetSoft(f, "generation"), "0");
  metaSetSoft(f, "generation", gen);
  metaSetSoft(f, "debriefs", plusOne(cur));
}

// ac_learn_tick's twin under state/.learn-cadence.lock (10 PATH `sleep 1`
// waits): false, warned, when the lock is not taken; else counted.
export function learnTick(): boolean {
  const lock = learnCadenceLock();
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`learning tick: cadence lock ${lock} could not be acquired within 10s - the debrief counter was NOT advanced. Missing a tick only delays the next distill (the LEVEL trigger still fires); it never loses a landing outright, but a caller that assumes success will believe the counter moved when it did not.`);
    return false;
  }
  learnCountOne();
  lockRelease(lock);
  return true;
}

// ac_learn_generation's twin: the meta's generation, "0" unless digits.
export function learnGeneration(): string {
  return digitsOr(metaGetSoft(learnMeta(), "generation"), "0");
}

const TICK_HIT_AWK = "BEGIN { w[k] } ($2 in w) && now - $1 < win { hit = 1 } END { if (!hit) exit 1 }";

// ac_learn_tick_keyed's twin, its status as learn_cadence_call reads it: 0
// when <key>'s claim was fresh and the counter advanced, 1 when <key> is
// stamped inside 24 h (silent), 2 where the bash returned 1 having spoken - a
// busy cadence lock (warned) or a stamp whose mv failed (mv's own line). Both
// awks are spawned as the bash ran them (`in`, never ==, so `07` is not `7`),
// under LC_ALL=C: the stamp file is read as bytes. The stamp (the file's live
// rows plus `<now>\t<key>`) lands through an exclusive temp and a spawned mv
// BEFORE the count.
export function learnTickKeyed(key: string): number {
  const f = learnTicks();
  const lock = learnCadenceLock();
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`learning tick: cadence lock ${lock} could not be acquired within 10s - landing '${key}' was NOT claimed. Missing a tick only delays the next distill (the LEVEL trigger still fires); counting one twice consumes a retro window and cannot be undone.`);
    return 2;
  }
  const now = nowRaw();
  const awk = ["/usr/bin/env", "LC_ALL=C", "awk", "-F\t", "-v", `now=${now}`];
  if (isFile(f) && stage([...awk, "-v", `k=${key}`, "-v", "win=86400", TICK_HIT_AWK, f], "inherit", "inherit", "inherit").status === 0) {
    lockRelease(lock);
    return 1;
  }
  const mv = viaTemp(f, (fd) => {
    if (isFile(f)) stageTo([...awk, "-v", "win=86400", "now - $1 < win", f], fd);
    writeAll(fd, Buffer.from(`${now}\t${key}\n`, "latin1"));
  });
  if (mv === 0) learnCountOne();
  lockRelease(lock);
  return mv === 0 ? 0 : 2;
}

// ac_learn_due's twin: [debriefs (the legacy stows when unset), learn-every],
// "0" and "8" unless digits. Reads only.
export function learnDue(): [string, string] {
  const m = learnMeta();
  let cur = metaGetSoft(m, "debriefs");
  if (cur === "") cur = metaGetSoft(m, "stows");
  return [digitsOr(cur, "0"), digitsOr(configReadSoft("learn-every", "8"), "8")];
}

// ac_learn_reset's twin under the cadence lock, its status as
// learn_cadence_call reads it: 2 for a lock not taken (warned), 1 when
// <expected> names an older generation (silent), else 0 - the migrate, then
// generation+1 (bash arithmetic, as curateReset), debriefs 0 and last_run
// stamped. The landing stamps are deliberately left alone.
export function learnReset(expected = ""): number {
  const f = learnMeta();
  const lock = learnCadenceLock();
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`learning reset: cadence lock ${lock} could not be acquired within 10s - the debrief counter was NOT reset and its generation did NOT advance, so a due DISTILL cycle stays due. This is a lock failure, not a newer cadence generation.`);
    return 2;
  }
  learnMigrate(f);
  const current = learnGeneration();
  if (expected !== "" && expected !== current) {
    lockRelease(lock);
    return 1;
  }
  metaSetSoft(f, "generation", plusOne(current));
  metaSetSoft(f, "debriefs", "0");
  metaSetSoft(f, "last_run", nowRaw());
  lockRelease(lock);
  return 0;
}

// ac_curate_tick's twin, under state/.curate-cadence.lock: false, warned,
// when the lock is not taken; else generation (as read) and runs_since+1.
export function curateTick(): boolean {
  const f = curateMeta();
  const lock = `${softSubdir("state", true)}/.curate-cadence.lock`;
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`curate tick: cadence lock ${lock} could not be acquired within 10s - the learning-run counter was NOT advanced. Missing a tick only delays the next Curate pass, but a caller that assumes success will believe the counter moved when it did not.`);
    return false;
  }
  const cur = digitsOr(metaGetSoft(f, "runs_since"), "0");
  const gen = digitsOr(metaGetSoft(f, "generation"), "0");
  metaSetSoft(f, "generation", gen);
  metaSetSoft(f, "runs_since", plusOne(cur));
  lockRelease(lock);
  return true;
}

// ac_skills_dir's twin: <home>/skills, minted.
export function skillsDir(): string {
  return homeSubdir("skills");
}

// ac_maintenance_incomplete's twin: one `<txid>\t<status>\t<committed>\t<plan>`
// row per transaction dir under <root> whose journal is neither complete nor
// abandoned - status `unknown` when unset, committed the run of leading
// `action_<i>=complete` keys, plan `-` when unset - the dirs in byte order
// (W13: the bash's glob followed LC_COLLATE). Bytes (latin1) out.
export function maintenanceIncomplete(root: string): string[] {
  if (!isDir(root)) return [];
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {}
  const rows: string[] = [];
  for (const n of names.filter((x) => !x.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    const dir = `${root}/${n}`;
    const journal = `${dir}/journal`;
    if (!isDir(dir) || !isFile(journal)) continue;
    const status = metaGetSoft(journal, "status");
    if (status === "complete" || status === "abandoned") continue;
    let done = 0;
    while (metaGetSoft(journal, `action_${done}`) === "complete") done++;
    const plan = metaGetSoft(journal, "plan");
    rows.push(`${lat(n)}\t${status || "unknown"}\t${done}\t${plan || "-"}`);
  }
  return rows;
}

// ac_crewmate_learned_no_loss's twin: true when every `## ` line of <live>
// (as grep prints them - a NUL in its head makes that one `Binary file`
// line) is a whole line of <staged>, or its slug occurs in <retired>; a
// missing <live> passes, a missing <staged> fails.
export function crewmateLearnedNoLoss(live: string, staged: string, retired: string): boolean {
  if (!isFile(live)) return true;
  if (!isFile(staged)) return false;
  const heads = capturedText(stage(["grep", "^## ", live], "inherit", "pipe", "inherit").out);
  if (heads === "") return true;
  const lines = (p: string): string[] => {
    try {
      return readFileSync(p).toString("latin1").split("\n");
    } catch {
      return [];
    }
  };
  const have = new Set(lines(staged));
  for (const head of heads.split("\n")) {
    if (have.has(head)) continue;
    if (retired !== "" && isFile(retired) && lines(retired).some((l) => l.includes(head.replace(/^## /, "")))) continue;
    return false;
  }
  return true;
}
