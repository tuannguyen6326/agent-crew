// lib-teardown.ts - the teardown twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { records } from "./backlog.ts";
import { chmodSync, closeSync, statSync, writeSync } from "node:fs";
import {
  capturedText,
  exclusiveTemp,
  isDir,
  isFile,
  lat,
  lockAcquire,
  lockRelease,
  projectConfigName,
  roomFile,
  sleepOne,
  softHome,
  softSubdir,
  stage,
  STARTED_BIN,
  statusAppend,
  writeAll,
} from "./lib.ts";

// ac_task_stamps' twin: every per-id watcher stamp in <sd>, the one reap list
// (ac-watch and ac-done write them).
const TASK_STAMPS = [
  "hash", "change", "seen", "seen-hash", "stale", "gone", "ask", "unobservable", "report-hash", "superseded", "busy", "busy-stalled", "ended", "rewake",
  "stale-count", "stale-capped", "deferred-since",
];

export function taskStamps(sd: string, id: string): string[] {
  return TASK_STAMPS.map((b) => `${sd}/.${b}-${id}`);
}

// ac_port_slot_release's twin: <wt>'s row dropped from state/port-slots.tsv
// under the registry's lock (10 PATH `sleep 1` waits), never a failure - no
// home, no registry or a lock not taken (W20) leave it, silently. The rows are
// awk's `$2 != w` (-v escapes and all), spawned; its output goes to an
// exclusive <reg>.tmp.<pid> given the registry's mode (the bash's temp left
// it umask's) and is renamed over it by a spawned mv. An awk that fails, or a
// temp that cannot take all its bytes, leaves that temp and the registry as
// they were, as the bash's `awk >tmp && mv` did; so does a lock whose pid
// cannot be written (the bash's ac_lock_acquire answered 1 there).
export function portSlotRelease(wt: string): void {
  const sd = softSubdir("state", false);
  if (sd === "") return;
  const reg = `${sd}/port-slots.tsv`;
  if (!isFile(reg)) return;
  const lock = `${reg}.lock`;
  let held = false;
  try {
    held = lockAcquire(lock, 10, sleepOne);
  } catch {}
  if (!held) return;
  try {
    let t: { path: string; fd: number };
    try {
      t = exclusiveTemp(`${reg}.tmp`);
    } catch {
      return;
    }
    const r = stage(["awk", "-F\\t", "-v", `w=${wt}`, "$2 != w", reg], "inherit", "pipe", "inherit");
    let whole = true;
    try {
      writeAll(t.fd, r.out);
    } catch {
      whole = false;
    } finally {
      closeSync(t.fd);
    }
    if (r.status !== 0 || !whole) return;
    try {
      chmodSync(t.path, statSync(reg).mode & 0o7777);
    } catch {}
    stage(["mv", t.path, reg], "inherit", "inherit", "inherit");
  } finally {
    lockRelease(lock);
  }
}

// `awk <prog> <file>` as the gate's tests ran it - under the caller's locale,
// or LC_ALL=C for `c` - its own stderr the caller's: true on exit 0.
function awkFinds(prog: string, vars: [string, string][], file: string, c = false): boolean {
  const awk = ["awk", ...vars.flatMap(([k, v]) => ["-v", `${k}=${v}`]), prog, file];
  return stage(c ? ["/usr/bin/env", "LC_ALL=C", ...awk] : awk, "inherit", "ignore", "inherit").status === 0;
}

// ac_solo_landing_check's twin, the kind=self knowledge-loop gate: the one
// line `knowledge loop: lessons=<l> repo-knowledge=<f> done-row=<d>` (or
// `landed-receipt=<d>` for a <scope>) appended to <id>'s status record, its
// failure ignored, and printed on stdout, then `missing - the solo contract
// owes these at landing:` and the command for each missing write; true when
// none is missing, and for an empty <id> with nothing done. lessons: waived,
// or yes when records/learnings.md before `## Distilled` holds a `### `
// heading containing `(solo <id>)` or any line containing `(by: <id>,`;
// repo-knowledge: waived, or yes when <repo> is a directory git names a config
// name for and its records/repo-knowledge/<name>.md before `## Superseded`
// holds a `- ` line ending `| by: <id>`; the third: a scoped slice's room
// entry `- [` holding `> LANDED: <id> ` or `> UNLANDABLE: <id> `, else a line
// under `## Done` starting `- [x] <id> `. Each test is the original's awk,
// spawned (the last two under LC_ALL=C, as there), so an unreadable record
// prints awk's own line and reads as missing. The hints name the bin/ of
// STARTED_BIN, `date -u +%Y-%m-%d` (spawned) and the physical home. Every
// argument is text (UTF-8). <before>, given, runs just ahead of the record
// with the verdict, so a caller's own lines land before it - and only when
// they should.
export function soloLandingCheck(id: string, repo: string, noLesson: string, noFact: string, scope: string, before?: (pass: boolean) => void): boolean {
  if (id === "") return true;
  const recs = softSubdir("records", false);
  const led = `${recs}/learnings.md`;
  let lessons = "none";
  if (noLesson !== "") lessons = "waived";
  else if (
    isFile(led) &&
    awkFinds(
      "\n      /^## Distilled/ { exit }\n      /^### / && index($0, tag) { found = 1; exit }\n      index($0, by) { found = 1; exit }\n      END { exit(found ? 0 : 1) }",
      [["tag", `(solo ${id})`], ["by", `(by: ${id},`]],
      led,
    )
  )
    lessons = "yes";
  let facts = "none";
  if (noFact !== "") facts = "waived";
  else if (repo !== "" && isDir(repo)) {
    const name = projectConfigName(repo);
    const rec = name === null ? "" : `${softSubdir("records", false)}/repo-knowledge/${name}.md`;
    if (
      rec !== "" &&
      isFile(rec) &&
      awkFinds(
        "\n      /^## Superseded/ { exit }\n      /^- / && substr($0, length($0) - length(suffix) + 1) == suffix { found = 1; exit }\n      END { exit(found ? 0 : 1) }",
        [["suffix", `| by: ${id}`]],
        rec,
      )
    )
      facts = "yes";
  }
  let done = "none";
  let line: string;
  let bl = "";
  if (scope !== "") {
    const room = roomFile(scope);
    if (
      room !== "" &&
      isFile(room) &&
      awkFinds(
        "\n        /^- \\[/ && (index($0, landed) || index($0, unland)) { found = 1; exit }\n        END { exit(found ? 0 : 1) }",
        [["landed", `> LANDED: ${id} `], ["unland", `> UNLANDABLE: ${id} `]],
        room,
        true,
      )
    )
      done = "yes";
    line = `knowledge loop: lessons=${lessons} repo-knowledge=${facts} landed-receipt=${done}`;
  } else {
    bl = `${softSubdir("records", false)}/backlog.md`;
    if (
      isFile(bl) &&
      awkFinds(
        "\n        /^## Done/ { in_done = 1; next }\n        /^## / { in_done = 0 }\n        in_done && index($0, row) == 1 { found = 1; exit }\n        END { exit(found ? 0 : 1) }",
        [["row", `- [x] ${id} `]],
        bl,
        true,
      )
    )
      done = "yes";
    line = `knowledge loop: lessons=${lessons} repo-knowledge=${facts} done-row=${done}`;
  }
  const root = STARTED_BIN.slice(0, -"/bin".length);
  let hint = "";
  if (lessons === "none") {
    const day = capturedText(stage(["date", "-u", "+%Y-%m-%d"], "inherit", "pipe", "inherit").out);
    hint += `\n  lesson: ${root}/bin/ac-learn.sh note '### ${day} (solo ${id})' '- <one method lesson>'   (or --no-lesson '<why nothing new>')`;
  }
  if (facts === "none") hint += `\n  repo fact: ${root}/bin/ac-know.sh add --home ${softHome(true)} --repo ${repo || "<repo>"} --family ${id} --src-file <path>:<line> --fact '<verified fact>'   (or --no-fact '<why none verified>')`;
  if (done !== "yes") {
    if (scope !== "")
      hint += `\n  landed receipt: ${root}/bin/ac-room.sh post ${scope} ${scope}-chief 'LANDED: ${id} - <outcome>'   (the crewchief moves the backlog row at your hand-back)\n  ...or, when the slice CANNOT land: ${root}/bin/ac-room.sh post ${scope} ${scope}-chief 'UNLANDABLE: ${id} - <why>; crewchief to land'   (NEVER rebase to force it: a scoped actor is withheld --no-ff on purpose, and a rebase changes the sha a review receipt binds by. The slice STAYS IN FLIGHT until the crewchief lands crew/${id} --no-ff; this teardown keeps refusing 'unlanded work' until then, and passes on this receipt afterwards)`;
    else hint += `\n  done row: append '- [x] ${id} - <outcome>' under ## Done in ${bl}`;
  }
  before?.(hint === "");
  statusAppend(id, lat(line));
  writeSync(1, `${line}\n`);
  if (hint !== "") writeSync(1, `missing - the solo contract owes these at landing:${hint}\n`);
  return hint === "";
}
