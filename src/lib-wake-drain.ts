// lib-wake-drain.ts - the wake-drain twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { records } from "./backlog.ts";
import { existsSync, readdirSync } from "node:fs";
import type { ProbeIo } from "./lib.ts";
import {
  capturedText,
  cutNul,
  familyOfId,
  metaGet,
  metaIsVerify,
  pidAlive,
  roomPendingLines,
  shellStatus,
  softSubdir,
  spawnShellSync,
  windowAliveAs,
} from "./lib.ts";

// `"$sd"/*.meta` as a bash loop walked it: every non-dot name ending .meta, in
// byte order (the glob followed the locale's collation); the caller tests
// `[ -e ]`.
export function metaPaths(sd: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(sd);
  } catch {}
  return names
    .filter((n) => !n.startsWith(".") && n.endsWith(".meta"))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((n) => `${sd}/${n}`);
}

// ac_chief_child_live's twin: <id> is a <fam>-chief with a LIVE member - over
// metaPaths, a verifier skipped and the chief's own pane skipped first, an id
// familyOfId reads as <fam>, else a fleet_scope= of <fam> read LOUD (an
// unreadable member warns `cannot read meta file` and is no member) - each
// probed by windowAliveAs with the caller's stdin and stdout; the first live
// member answers.
export function chiefChildLive(sd: string, id: string, io: ProbeIo): boolean {
  if (!id.endsWith("-chief")) return false;
  const fam = id.slice(0, -"-chief".length);
  for (const m of metaPaths(sd)) {
    if (!existsSync(m) || metaIsVerify(m)) continue;
    const cid = m.slice(sd.length + 1, -".meta".length).replace(/\n+$/, "");
    if (cid === `${fam}-chief`) continue;
    if (familyOfId(cid) !== fam) {
      let scope = "";
      try {
        scope = cutNul(metaGet(m, "fleet_scope"));
      } catch {}
      if (scope !== fam) continue;
    }
    if (windowAliveAs(m, cid, io)) return true;
  }
  return false;
}

// ac_chief_gate_parked's twin: <id> is a <fam>-chief whose LIVE room
// (<data>/<fam>/room.md, data/ minted as `$(ac_data_dir)` minted it) still
// holds an unanswered GATE/ASK (roomPendingLines' count). A room it cannot read
// is not parked, after ac_room_scan's grep printed its own refusal - spawned
// again for that line, under C; the `[` line bash added there is the shell's.
export function chiefGateParked(id: string): boolean {
  if (!id.endsWith("-chief")) return false;
  const f = `${softSubdir("data", true)}/${id.slice(0, -"-chief".length)}/room.md`;
  const open = roomPendingLines(f);
  if (open !== null) return open !== "";
  try {
    spawnShellSync(["/usr/bin/env", "LC_ALL=C", "grep", "-a", "-H", "-E", "--", "^- \\[[^]]*\\] [^>]*> (GATE|ASK|DECIDED)", f], {
      stdin: "inherit",
      stdout: "ignore",
      stderr: "inherit",
    });
  } catch {}
  return false;
}

// The dead-claim sweep's verdict on a claim dir's pid (src/wake-drain.ts):
// KEPT while it is not this process, is alive (pidAlive) and its `ps -o
// command= -p <pid>` either cannot be read - failing toward live - or names a
// drainer: the bash entry by its name, or this module, which a drainer the
// shim started runs as `bun --no-env-file <root>/src/wake-drain.ts <cwd>`.
// Matching the entry name alone would read a live TS drainer as a reused pid
// and hand its claimed records to a second drain, which emits them again.
export function claimLive(pid: string): boolean {
  if (pid === String(process.pid) || !pidAlive(pid)) return false;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["ps", "-o", "command=", "-p", pid], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  } catch {}
  if (r === null || shellStatus(r) !== 0) return true;
  const cmd = capturedText(Buffer.from(r.stdout));
  return cmd.includes("ac-wake-drain") || cmd.includes("/src/wake-drain.ts");
}
