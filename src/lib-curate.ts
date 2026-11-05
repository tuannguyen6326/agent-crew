// lib-curate.ts - the curate twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { records } from "./backlog.ts";
import { existsSync, readdirSync } from "node:fs";
import { basename, dirname } from "node:path";
import {
  arithValue,
  capturedText,
  configReadSoft,
  isDir,
  isFile,
  isLink,
  lat,
  lockAcquire,
  lockRelease,
  maintenancePathPlain,
  maintenancePlanValidate,
  metaGet,
  metaSet,
  mkdirP,
  nowRaw,
  physicalDir,
  recordsBackup,
  settle,
  sha256File,
  SKILLS_ARCHIVE,
  sleepOne,
  softHome,
  softSubdir,
  stage,
  tabFields,
  warn,
} from "./lib.ts";

export const curateMeta = (): string => `${softSubdir("state", true)}/.curate.meta`;

export function metaGetSoft(file: string, key: string): string {
  try {
    return metaGet(file, key);
  } catch {
    return "";
  }
}

// ac_meta_set's failure is the bash caller's ignored status: its warning or
// mv's own line is already on stderr, and the sequence goes on.
export function metaSetSoft(file: string, key: string, value: string): void {
  try {
    metaSet(file, key, value);
  } catch {}
}

// ac_curate_generation's twin: the meta's generation, "0" unless digits.
export function curateGeneration(): string {
  const g = metaGetSoft(curateMeta(), "generation");
  return /^[0-9]+$/.test(g) ? g : "0";
}

// ac_curate_due's twin: [runs_since, curate-every], "0" and "5" unless digits.
export function curateDue(): [string, string] {
  const cur = metaGetSoft(curateMeta(), "runs_since");
  const every = configReadSoft("curate-every", "5");
  return [/^[0-9]+$/.test(cur) ? cur : "0", /^[0-9]+$/.test(every) ? every : "5"];
}

// ac_curate_reset's twin, under state/.curate-cadence.lock (10 PATH `sleep 1`
// waits): false, warned, when the lock is not taken; false when <expected>
// names an older generation; else generation+1 (`$((current + 1))`, so a
// leading 0 reads octal and an 8 or 9 behind it THROWS EARITH with the lock
// still held, where the shell's arithmetic error ended the script), runs_since
// 0 and last_run stamped, each write's own failure ignored as the bash's was.
export function curateReset(expected = ""): boolean {
  const f = curateMeta();
  const lock = `${softSubdir("state", true)}/.curate-cadence.lock`;
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`curate reset: cadence lock ${lock} could not be acquired within 10s - the learning-run counter was NOT reset and its generation did NOT advance, so a due Curate pass stays due. This is a lock failure, not a newer cadence generation.`);
    return false;
  }
  const current = curateGeneration();
  if (expected !== "" && expected !== current) {
    lockRelease(lock);
    return false;
  }
  metaSetSoft(f, "generation", String(BigInt.asIntN(64, arithValue(current) + 1n)));
  metaSetSoft(f, "runs_since", "0");
  metaSetSoft(f, "last_run", nowRaw());
  lockRelease(lock);
  return true;
}

// ac_maintenance_gate_failure_reason's twin, keyed on the gate's exit only.
export function maintenanceGateFailureReason(rc: number | string): string {
  switch (String(rc)) {
    case "4":
      return "The maintenance gate is disabled (config/gate-agent=off).";
    case "3":
      return "The maintenance gate ran but produced no usable decision (an engine failure, an invalid response, a timeout, or a declared environment-error).";
    default:
      return `The maintenance gate rejected its own invocation before it could run (usage or input error, exit ${rc}).`;
  }
}

// ac_maintenance_incomplete_other's twin: some OTHER transaction dir under
// <root> (byte order) holds a journal that is neither complete nor abandoned;
// an unreadable journal is ac_meta_get's warning and reads unsettled.
function maintenanceIncompleteOther(root: string, current: string): boolean {
  if (!isDir(root)) return false;
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {}
  for (const n of names.filter((x) => !x.startsWith(".")).sort()) {
    const dir = `${root}/${n}`;
    if (!isDir(dir) || dir === current) continue;
    if (!isFile(`${dir}/journal`)) continue;
    const s = metaGetSoft(`${dir}/journal`, "status");
    if (s !== "complete" && s !== "abandoned") return true;
  }
  return false;
}

// _ac_maintenance_hold's twin: the journal keeps the claim and says how much
// landed, then the one warning naming the verbs that settle it.
function maintenanceHold(journal: string, txn: string, committed: number, total: string, why: string): void {
  const txid = basename(txn);
  metaSetSoft(journal, "held_committed", String(committed));
  metaSetSoft(journal, "held_reason", Buffer.from(why, "utf8").toString("latin1"));
  warn(`maintenance transaction ${txid} is HELD (${why}): ${committed} of its ${total} action(s) are already committed to disk and are NOT rolled back. It stays claimed, so every other Learning/Curate transaction refuses until it is settled. Fix the cause and replay it (already-applied actions are skipped by hash), or drop it and keep the record: bin/ac-learn.sh maintenance resume ${txid} | bin/ac-learn.sh maintenance abandon ${txid}`);
}

export const shaSoft = (f: string): string => {
  try {
    return sha256File(f);
  } catch {
    return "";
  }
};

// ac_maintenance_apply's twin - the fleet-wide writer Learning and Curate
// call, beside the bash one the frozen oracles keep, so the two must leave
// the same claim, journal (key order included), backup and file bytes: a
// journal either side writes, the other resumes. The plan is validated (maintenancePlanValidate), the claim taken
// under state/.maintenance.lock (30 PATH `sleep 1` waits) and refused for a
// different recorded plan or another unsettled transaction; the journal
// records plan_sha256, plan, run, actions_total and status=applying before the
// first write, then the backup (recordsBackup <mode>, once per transaction).
// Each action is skipped when its target already holds new_sha256, applied
// when it holds old_sha256 (cp to <target>.maintenance.<pid>.<idx>, rehashed,
// mv over it - all spawned, so a link planted at the temp is written through
// as the bash's was), and a move-skill then removes its live source and every
// directory it empties below skills/. Every failure past the claim HOLDS the
// transaction with the bash's reason text. False wherever the bash returned 1.
export function maintenanceApply(plan: string, run: string): boolean {
  if (!maintenancePlanValidate(plan, run)) return false;
  const home = softHome(true);
  const root = `${softSubdir("state", true)}/.maintenance-transactions`;
  mkdirP(root);
  const jqr = (prog: string): string => capturedText(stage(["jq", "-r", prog, plan], "inherit", "pipe", "inherit").out);
  const runId = jqr(".run_id");
  const subject = jqr(".subject");
  const mode = jqr(".mode");
  const txn = `${root}/${runId}-${subject}`;
  const journal = `${txn}/journal`;
  const lock = `${softSubdir("state", true)}/.maintenance.lock`;
  const planSha = shaSoft(plan);
  if (planSha === "") return false;

  if (isFile(journal) && metaGetSoft(journal, "status") === "complete") {
    const recorded = metaGetSoft(journal, "plan_sha256");
    if (recorded === planSha) return true;
    warn(`maintenance apply: transaction ${runId}-${subject} already completed a different plan (plan_sha256 ${recorded}, this one ${planSha}), so this plan was not applied. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt.`);
    return false;
  }
  if (!lockAcquire(lock, 30, sleepOne)) {
    warn(`maintenance apply: writer lock ${lock} could not be acquired within 30s - another Learning/Curate transaction holds it, so ${runId}-${subject} was neither claimed nor written. This is a busy lock, not a stale receipt or a refused plan.`);
    return false;
  }
  if (!maintenancePlanValidate(plan, run)) {
    lockRelease(lock);
    return false;
  }
  mkdirP(txn);
  const recorded = metaGetSoft(journal, "plan_sha256");
  if (recorded !== "" && recorded !== planSha) {
    warn(`maintenance apply: transaction ${runId}-${subject} already recorded a different plan (plan_sha256 ${recorded}, this one ${planSha}), so this plan was neither claimed nor written. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt.`);
    lockRelease(lock);
    return false;
  }
  if (maintenanceIncompleteOther(root, txn)) {
    warn(`maintenance apply: another Learning/Curate transaction is still unsettled, so ${runId}-${subject} was neither claimed nor written. This is another transaction's claim, not a stale receipt or a refused plan - bin/ac-learn.sh maintenance status names it, and resume or abandon settles it.`);
    lockRelease(lock);
    return false;
  }

  const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
  const planAbs = `${physicalDir(dirname(plan)) ?? ""}/${basename(plan)}`;
  const runAbs = physicalDir(run) ?? "";
  const total = jqr(".actions | length");
  metaSetSoft(journal, "plan_sha256", planSha);
  metaSetSoft(journal, "plan", lat(planAbs));
  metaSetSoft(journal, "run", lat(runAbs));
  metaSetSoft(journal, "actions_total", total);
  metaSetSoft(journal, "status", "applying");
  const held = (idx: number, why: string): false => {
    maintenanceHold(journal, txn, idx, total, why);
    lockRelease(lock);
    return false;
  };
  let backup = metaGetSoft(journal, "backup");
  if (backup === "") {
    const b = recordsBackup(mode);
    if (b === null) return held(0, "the pre-mutation backup could not be taken");
    backup = b;
    metaSetSoft(journal, "backup", backup);
  } else if (!isFile(Buffer.from(backup, "latin1"))) {
    return held(0, "the recorded pre-mutation backup is missing");
  }

  const run1 = (cmd: string[], stderr: "inherit" | "ignore" = "inherit"): number => stage(cmd, "inherit", "inherit", stderr).status;
  const rows = stage(["jq", "-r", ".actions[] | [.op,.target,.old_sha256,.new_sha256,.staged] | @tsv", plan], "inherit", "pipe", "inherit").out.toString("latin1").split("\n").slice(0, -1);
  let idx = 0;
  for (const row of rows) {
    const [op, target, oldSha, newSha, staged] = tabFields(row.split("\0", 1)[0]!, 5) as [string, string, string, string, string];
    const targetAbs = `${home}/${target}`;
    const stagedAbs = `${run}/${staged}`;
    let actual: string;
    if (isFile(targetAbs) && !isLink(targetAbs)) {
      actual = shaSoft(targetAbs);
      if (actual === "") return held(idx, `target ${target} could not be hashed`);
    } else if (!existsSync(targetAbs)) {
      actual = "-";
    } else {
      return held(idx, `target ${target} is not a plain file`);
    }
    if (actual !== newSha) {
      if (actual !== oldSha) return held(idx, `target ${target} no longer matches the state the plan was staged against`);
      if (run1(["mkdir", "-p", dirname(targetAbs)]) !== 0) return held(idx, `the directory for ${target} could not be created`);
      if (!maintenancePathPlain(home, target)) return held(idx, `a path component of ${target} is a symlink`);
      const tmp = `${targetAbs}.maintenance.${process.pid}.${idx}`;
      if (run1(["cp", stagedAbs, tmp]) !== 0) return held(idx, `the staged bytes for ${target} could not be copied`);
      if (shaSoft(tmp) !== newSha) {
        run1(["rm", "-f", tmp]);
        return held(idx, `the copied bytes for ${target} do not match the planned hash`);
      }
      if (run1(["mv", tmp, targetAbs]) !== 0) {
        run1(["rm", "-f", tmp]);
        return held(idx, `${target} could not be replaced atomically`);
      }
    }
    if (op === "move-skill") {
      const prefix = `skills/${SKILLS_ARCHIVE}/`;
      if (!target.startsWith(prefix) || !target.slice(prefix.length).includes("/")) return held(idx, `the live source for ${target} could not be inferred`);
      const source = `skills/${target.slice(prefix.length)}`;
      const sourceAbs = `${home}/${source}`;
      if (isFile(sourceAbs) && !isLink(sourceAbs)) {
        if (shaSoft(sourceAbs) !== newSha) return held(idx, `live source ${source} does not match the archived bytes`);
        if (run1(["rm", sourceAbs]) !== 0) return held(idx, `live source ${source} could not be removed`);
      } else if (existsSync(sourceAbs) || isLink(sourceAbs)) {
        return held(idx, `live source ${source} is not a plain file`);
      }
      // Only directories the move emptied go; a failed rmdir means another
      // file remains there and is kept.
      for (let dir = dirname(sourceAbs); dir !== `${home}/skills`; dir = dirname(dir)) {
        if (run1(["rmdir", dir], "ignore") !== 0) break;
      }
    }
    metaSetSoft(journal, `action_${idx}`, "complete");
    idx++;
  }
  metaSetSoft(journal, "status", "complete");
  lockRelease(lock);
  return true;
}
