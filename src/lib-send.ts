// lib-send.ts - the send twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { existsSync, readdirSync } from "node:fs";
import {
  argvOf,
  CAPTAIN_RE,
  capturedText,
  lat,
  settle,
  stage,
} from "./lib.ts";

// ac_bare_marker_verbs' twin (bin/ac-lib.sh keeps the bash one and its
// contract): the bare marker verbs <text> carries, one per line, deduped by
// awk's $1 in first-seen order, null for none. The verb list is the `(...)`
// group of CAPTAIN_RE by the bash's own sed; one that is empty or holds any
// byte but a-z, `|` and `-` is unparseable - none - read by that text under
// every locale (bash 3.2's case range collated under UTF-8 and let an
// uppercase verb pass: named). grep and awk are spawned under the caller's
// locale, so [[:space:]] is the class they read (NBSP under UTF-8 only).
export function bareMarkerVerbs(text: string): string | null {
  const verbs = capturedText(stage(["sed", "-n", "s/.*(\\([^)]*\\)):.*/\\1/p"], Buffer.from(`${CAPTAIN_RE}\n`), "pipe", "inherit").out);
  if (verbs === "" || /[^a-z|-]/.test(verbs)) return null;
  const hits = stage(["grep", "-oE", `(${verbs}):([[:space:]]|$)`], Buffer.from(`${text}\n`), "pipe", "inherit");
  const tokens = capturedText(stage(["awk", "!seen[$1]++ { print $1 }"], hits.out, "pipe", "inherit").out);
  return tokens === "" ? null : tokens;
}

// ac_claude_last_typed_turn's jq program, byte for byte (tests/ts/send.test.ts
// lifts it out of bin/ac-lib.sh, whose function stays live for ac-spawn).
const LAST_TYPED_TURN = `
    [.[] | select(.type == "user" and .promptSource == "typed"
                  and .origin.kind == "human"
                  and (.message.content | type) == "string")]
    | last | .message.content // empty
  `;

// ac_claude_transcript_path's twin: the one `<root>/*/<sid>.jsonl` that
// exists, <root> AC_CLAUDE_TRANSCRIPT_ROOT, else <CLAUDE_CONFIG_DIR, else
// HOME/.claude>/projects, its trailing LFs cut as the bash's `$(...)` cut
// them; null for none, two or more, or HOME unset where it was needed (the
// bash's `set -u` ended the reading there). <sid> is bytes (latin1), and so
// is the answer.
export function claudeTranscriptPath(sid: string): string | null {
  const home = process.env.HOME;
  const cfg = process.env.CLAUDE_CONFIG_DIR || (home === undefined ? null : `${home}/.claude`);
  const root = process.env.AC_CLAUDE_TRANSCRIPT_ROOT || (cfg === null ? null : `${cfg}/projects`);
  if (root === null) return null;
  const r = lat(root).replace(/\n+$/, "");
  let names: Uint8Array[] = [];
  try {
    names = readdirSync(Buffer.from(r, "latin1"), { encoding: "buffer" });
  } catch {}
  const hits = names
    .map((n) => Buffer.from(n).toString("latin1"))
    .filter((n) => !n.startsWith(".") && existsSync(Buffer.from(`${r}/${n}/${sid}.jsonl`, "latin1")));
  return hits.length === 1 ? `${r}/${hits[0]}/${sid}.jsonl` : null;
}

// ac_claude_last_typed_turn's twin: `tail -n 200 <file> | jq -rs <program>`,
// both spawned, their stderr dropped; null when either fails (pipefail) or
// the answer reads empty, else the turn as `$(...)` read it (latin1).
function claudeLastTypedTurn(path: string): string | null {
  const tail = stage(["tail", "-n", "200", argvOf(path)], "ignore", "pipe", "ignore");
  const turn = stage(["jq", "-rs", LAST_TYPED_TURN], tail.out, "pipe", "ignore");
  if (tail.status !== 0 || turn.status !== 0) return null;
  const out = capturedText(turn.out);
  return out === "" ? null : out;
}

// ac_arrival_wait's twin (ac-lib.sh's claude transcript arrival check; the
// bash stays live for ac-spawn): did <text>, its trailing LFs cut as the
// transcript reader cuts the arrived turn's, ARRIVE as the session's last
// typed human turn? Up to seven reads a settle apart (PATH's sleep, as the
// bash ran it), returning at the first match: 0 CONFIRMED; 1 REFUTED - some
// turn was read and none matched, `last` the last one read (the bash's
// AC_ARRIVAL_LAST); 2 UNOBSERVABLE - no <sid> (bytes, latin1), no single
// transcript, or no turn read at all.
export function arrivalWait(sid: string, text: string): { status: number; last: string } {
  const expected = lat(text).replace(/\n+$/, "");
  if (sid === "") return { status: 2, last: "" };
  const path = claudeTranscriptPath(sid);
  if (path === null) return { status: 2, last: "" };
  let last = "";
  for (let reads = 1; ; reads++) {
    const cur = claudeLastTypedTurn(path);
    if (cur !== null) {
      last = cur;
      if (last === expected) return { status: 0, last: "" };
    }
    if (reads >= 7) break;
    settle("inherit");
  }
  return { status: last === "" ? 2 : 1, last };
}
