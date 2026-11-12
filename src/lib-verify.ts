// lib-verify.ts - the verify twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { isoEpoch } from "./pane-agent.ts";
import { readFileSync, writeFileSync } from "node:fs";
import type { Ended, SpawnIo, Stdio } from "./lib.ts";
import {
  AGENT_STATUS_JQ,
  backendCall,
  backendRoute,
  capturedText,
  chiefBusyHeld,
  chiefBusyPath,
  herdrCli,
  herdrFocusPane,
  isDir,
  isFile,
  iso,
  jqOver,
  latBuf,
  lockAcquire,
  lockRelease,
  orcaAgentIdle,
  orcaJson,
  orcaSubmitVerified,
  orcaType,
  settle,
  sleepOne,
  spins,
  stage,
  submitVerifiedPane,
  testInt,
} from "./lib.ts";

// ac_verdict_json's string-aware awk, verbatim: the brace depth, the string
// and escape states and the NUL after every top-level object are awk's, in
// the caller's locale.
const VERDICT_AWK = String.raw`
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; instr = 0; esc = 0; start = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (instr) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0 }
          continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "{") { if (depth == 0) start = i; depth += 1 }
        else if (c == "}" && depth > 0) {
          depth -= 1
          if (depth == 0) { printf "%s%c", substr(buf, start, i - start + 1), 0; start = 0 }
        }
      }
    }
  `;

// ac_verdict_json's twin as its pipefail callers read it: <input> (what the
// bash read on stdin) through the spawned awk, then each NUL-terminated
// candidate - `read -r -d ''` leaves an unterminated tail unread - offered to a
// spawned `jq -e 'type == "object"'` as its bytes, the LAST one it accepts
// answered with a LF, nothing when none. The status is awk's when awk failed,
// else 0. Bytes in, bytes out.
export function verdictJson(input: Buffer): { status: number; out: Buffer } {
  const a = stage(["awk", VERDICT_AWK], input, "pipe", "inherit");
  const cands = a.out.toString("latin1").split("\0");
  cands.pop();
  let best = "";
  for (const c of cands) if (stage(["jq", "-e", 'type == "object"'], latBuf(c), "ignore", "ignore").status === 0) best = c;
  return { status: a.status, out: best === "" ? Buffer.alloc(0) : latBuf(`${best}\n`) };
}

const TRANSCRIPT_EPOCH_JQ = `[.[] | select(.type == "assistant")] | last | .timestamp // ""`;

// ac_transcript_final_epoch's twin: the last assistant message's own
// .timestamp through a spawned jq, read as `$(... || true)` read it, then the
// iso-epoch verb's isoEpoch in process: the epoch second and a LF (status 0),
// or nothing (status 1) for an empty stamp or one outside its calendar
// grammar. The bash starts that verb through bun with its stderr dropped, so
// its bun-less arm answered 1 silently; nothing here starts bun.
export function transcriptFinalEpoch(file: string): { status: number; out: string } {
  const ts = capturedText(stage(["jq", "-rs", TRANSCRIPT_EPOCH_JQ, file], "inherit", "pipe", "ignore").out);
  const epoch = ts === "" ? null : isoEpoch(Buffer.from(ts, "latin1").toString("utf8"));
  return epoch === null ? { status: 1, out: "" } : { status: 0, out: `${epoch}\n` };
}

// ac_chief_busy_hold's twin (bin/ac-wake-lib.sh owns the declaration's
// contract): this process's holder mark `pid=<pid>` first, then <until> over a
// declaration whose `$(cat)` text - anything but ASCII digits read as 0 - is
// below it, so a later bound is never shortened; a comparison `[` cannot make
// (a value past its range) writes, as its error status did. Every write best
// effort. The shell's own lines are not reproduced: `[`'s, and a failed
// write's, which its `2>/dev/null` - placed after the failing `>` - never
// silenced.
export function chiefBusyHold(sd: string, fam: string, until: string): void {
  const decl = chiefBusyPath(sd, fam);
  try {
    writeFileSync(`${sd}/.chief-busy-holder.${fam}.${process.pid}`, `pid=${process.pid}\n`);
  } catch {}
  let prev = "";
  try {
    prev = capturedText(readFileSync(decl));
  } catch {}
  if (prev === "" || /[^0-9]/.test(prev)) prev = "0";
  const p = testInt(prev);
  const u = testInt(until);
  if (p === null || u === null || p < u)
    try {
      writeFileSync(decl, `${until}\n`);
    } catch {}
}

// ac_chief_busy_leave's twin: this process's holder mark goes (a spawned
// `rm -f`), and the declaration with it unless chiefBusyHeld finds a live
// holder left - under <famData>/.gate-lock when <famData> is a directory and
// the lock is had within 10 PATH `sleep 1` waits, unlocked otherwise, as
// ac-gate.sh takes it at its exit. `quiet` is the caller's `2>/dev/null`.
export function chiefBusyLeave(sd: string, fam: string, famData: string, quiet = false): void {
  const err = quiet ? "ignore" : "inherit";
  stage(["rm", "-f", `${sd}/.chief-busy-holder.${fam}.${process.pid}`], "inherit", "inherit", err);
  const lock = `${famData}/.gate-lock`;
  const locked = isDir(famData) && lockAcquire(lock, 10, sleepOne);
  if (!chiefBusyHeld(sd, fam, famData, quiet)) stage(["rm", "-f", chiefBusyPath(sd, fam)], "inherit", "inherit", err);
  if (locked) lockRelease(lock);
}

// ac_room_review_rulings' awk, verbatim, run under LC_ALL=C as there.
const ROOM_RULINGS_AWK = String.raw`
    /^- \[[^]]*\] [^>]*> (GATE|ASK):/ { print; next }
    /^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { print; next }
    /^- \[[^]]*\] [^>]*> (TRIAGE|SELF-APPROVED):/ { print; next }
    /^- \[[^]]*\] [^>]*> GATE-PASSED \(auto\):/ { print; next }
    /^- \[[^]]*\] [^>]*> CORRECTION( \([^)]*\))?:/ { print; next }
  `;

// ac_room_review_rulings' twin: nothing (status 0) unless <file> is a regular
// file (`[ -f ]`), else the awk's stdout bytes and status.
export function roomReviewRulings(file: string): { status: number; out: Buffer } {
  if (!isFile(file)) return { status: 0, out: Buffer.alloc(0) };
  return stage(["/usr/bin/env", "LC_ALL=C", "awk", ROOM_RULINGS_AWK, file], "inherit", "pipe", "inherit");
}

// ac_harness_pane_arm's twin (bin/ac-harness.sh owns the arm map): null where
// the bash returned 1.
export function harnessPaneArm(h: string): "session" | "crewmate" | null {
  if (h === "claude") return "session";
  return ["codex", "opencode", "pi", "cursor"].includes(h) ? "crewmate" : null;
}

// backend_capture_pane's twin, the read addressed by RAW pane id - a pane with
// no state/.pane-<id> handle, a pane agent's or a verifier's: the route as
// backendCall reads it (a refused name exits, 1), an empty <pane> 1, then the
// driver's read - herdr `pane read <pane> --source recent --lines <n>` (n the
// lines when testInt reads them at least 200, else 200; stdin /dev/null and
// stderr dropped, as inside its `$( )`), failing 1, then `tail -n <lines>`
// over that text and a LF; orca `terminal read --terminal <pane> --limit
// <lines> --screen` through orcaJson, failing 1, then `jq -r
// '.result.terminal.tail[]?'` over it. The status is tail's or jq's. <lines>
// empty is 40.
export function backendCapturePane(pane: string, lines: string, io: { stdin?: "inherit" | "ignore"; stdout: Stdio; stderr: "inherit" | "ignore" }): { status: number; exited: boolean; out: Buffer } {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true, out: Buffer.alloc(0) };
  const none = { status: 1, exited: false, out: Buffer.alloc(0) };
  if (pane === "") return none;
  const n = lines || "40";
  if (b === "herdr") {
    const want = testInt(n);
    const read = herdrCli(["pane", "read", pane, "--source", "recent", "--lines", want !== null && want >= 200n ? n : "200"], "ignore", "pipe");
    if (read.status !== 0) return none;
    const t = stage(["tail", "-n", n], latBuf(`${capturedText(read.out)}\n`), io.stdout, io.stderr);
    return { status: t.status, exited: false, out: t.out };
  }
  const out = orcaJson(["terminal", "read", "--terminal", pane, "--limit", n, "--screen"], io.stdin ?? "inherit");
  if (out === null) return none;
  const t = jqOver(["-r", ".result.terminal.tail[]?"], out, io.stdout, io.stderr);
  return { status: t.status, exited: false, out: t.out };
}

// backend_send_line_pane's twin, routed per call over a raw pane id, silent:
// no pane 1; herdr types <text>, settles and verifies one Enter, then focuses
// and verifies one more, that retry's verdict the answer (0 accepted, 1
// stranded, 2 unreadable); orca types it in chunks, settles and verifies the
// Enter with <text> - a dialog-owned pane (3) answers 1 with no retry, any
// other failure gets a terminal switch and one more verify whose verdict,
// 3 included, is the answer.
export function backendSendLinePane(pane: string, text: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  if (pane === "") return { status: 1, exited: false };
  const top = io.stdin ?? "inherit";
  if (b === "herdr") {
    herdrCli(["pane", "send-text", pane, text], top, "ignore");
    settle(io.stderr);
    if (submitVerifiedPane(pane, top, io.stderr) === 0) return { status: 0, exited: false };
    herdrFocusPane(pane, top);
    return { status: submitVerifiedPane(pane, top, io.stderr), exited: false };
  }
  orcaType(pane, text, top, io.stderr);
  settle(io.stderr);
  const rc = orcaSubmitVerified(pane, text, top, io.stderr);
  if (rc === 0) return { status: 0, exited: false };
  if (rc === 3) return { status: 1, exited: false };
  orcaJson(["terminal", "switch", "--terminal", pane], top);
  return { status: orcaSubmitVerified(pane, text, top, io.stderr), exited: false };
}

// backend_agent_status_pane's twin, routed per call over a raw pane id: the
// word and a LF, status 0. herdr: `pane get`'s agent_status (jq's stderr
// dropped), `unknown` for no pane, a failed read or no status; orca: blocked
// for a pending wait, unknown for no pane, an unreadable or disconnected
// terminal, idle when the TUI reads idle (orcaAgentIdle), working for a
// spinner title, else unknown.
export function backendAgentStatusPane(pane: string, io: SpawnIo): { status: number; exited: boolean; out: Buffer } {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true, out: Buffer.alloc(0) };
  const say = (w: string): { status: number; exited: boolean; out: Buffer } => ({ status: 0, exited: false, out: latBuf(`${w}\n`) });
  if (pane === "") return say("unknown");
  if (b === "herdr") {
    const get = herdrCli(["pane", "get", pane], "ignore", "pipe");
    if (get.status !== 0) return say("unknown");
    return say(capturedText(jqOver(["-r", AGENT_STATUS_JQ], capturedText(get.out), "pipe", "ignore").out) || "unknown");
  }
  const top = io.stdin ?? "inherit";
  const show = orcaJson(["terminal", "show", "--terminal", pane], top);
  if (show === null) return say("unknown");
  if (jqOver(["-e", ".result.terminal.agentWait != null"], show, "ignore", "ignore").status === 0) return say("blocked");
  if (jqOver(["-e", ".result.terminal.connected == true"], show, "ignore", "ignore").status !== 0) return say("unknown");
  if (orcaAgentIdle(pane, top, io.stderr)) return say("idle");
  return say(spins(capturedText(jqOver(["-r", ".result.terminal.title // empty"], show, "pipe", io.stderr).out)) ? "working" : "unknown");
}
