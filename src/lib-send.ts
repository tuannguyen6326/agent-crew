// lib-send.ts - the send twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does - except
// arrivalWait's mid-turn queue-operation carve-out (its own header), which has
// no bash twin to keep contract with: ac_arrival_wait/ac_claude_last_typed_turn
// in bin/ac-lib.sh have no live caller left.

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
// lifts it out of bin/ac-lib.sh; that bash function and ac_arrival_wait have
// no live caller any more - every live caller runs this TS twin instead).
const LAST_TYPED_TURN = `
    [.[] | select(.type == "user" and .promptSource == "typed"
                  and .origin.kind == "human"
                  and (.message.content | type) == "string")]
    | last | .message.content // empty
  `;

// A message typed while claude is mid-turn is never a typed turn at all: a
// live transcript shows it ONLY as a queue-operation pair
// (enqueue, then remove reason="absorbed_mid_turn") - claude folds it into the
// turn already running instead of starting a new one. ORDER matters, not just
// presence: the content of the chronologically LAST entry that is either a
// typed turn or a queue-operation, kept ONLY when that last entry is the
// queue-operation. A typed turn landing AFTER an absorbed queue entry for
// some earlier, unrelated send with the same text is a genuine new (and
// possibly wrong) arrival, and must still be judged on its own - a queue
// entry anywhere in the window, regardless of order, would wrongly mask that.
const LAST_QUEUED_IF_NEWEST = `
    [.[] | select((.type == "user" and .promptSource == "typed"
                   and .origin.kind == "human"
                   and (.message.content | type) == "string")
               or (.type == "queue-operation" and (.content | type) == "string"))]
    | last | select(.type == "queue-operation") | .content // empty
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

// Same tail, LAST_QUEUED_IF_NEWEST's jq program: null on any failure or an
// empty answer (no queue-operation, or a typed turn supersedes it).
function claudeLastQueuedIfNewest(path: string): string | null {
  const tail = stage(["tail", "-n", "200", argvOf(path)], "ignore", "pipe", "ignore");
  const queued = stage(["jq", "-rs", LAST_QUEUED_IF_NEWEST], tail.out, "pipe", "ignore");
  if (tail.status !== 0 || queued.status !== 0) return null;
  const out = capturedText(queued.out);
  return out === "" ? null : out;
}

// A mismatched last typed turn and a not-yet-replied-to one read identically
// from content alone (both static for arrivalWait's whole budget) - only the
// turn's OWN transcript timestamp can tell "this predates the send, nothing
// has happened in reply yet" from "this is a finished, genuine reply that
// just isn't ours". Null (missing or unparseable, as every fixture with no
// timestamp field keeps) on any failure - that turn cannot be proven stale,
// so it refutes as it always did.
const LAST_TYPED_TURN_TIMESTAMP = `
    [.[] | select(.type == "user" and .promptSource == "typed"
                  and .origin.kind == "human"
                  and (.message.content | type) == "string")]
    | last | .timestamp // empty
  `;

function claudeLastTypedTurnTimestamp(path: string): string | null {
  const tail = stage(["tail", "-n", "200", argvOf(path)], "ignore", "pipe", "ignore");
  const ts = stage(["jq", "-rs", LAST_TYPED_TURN_TIMESTAMP], tail.out, "pipe", "ignore");
  if (tail.status !== 0 || ts.status !== 0) return null;
  const out = capturedText(ts.out);
  return out === "" ? null : out;
}

// claude bracket-pastes a long, multi-paragraph steer instead of typing it
// character by character, and the transcript shows its content - whether it
// landed as a typed turn or was absorbed into a queue-operation pair, the
// SAME capture-time wrapping either way - inside `<pasted_content id="...">`
// tags, each on its OWN line, with a blank line outside both (verified
// against a real captured incident): the closing tag's own leading LF is
// wrapper formatting, never part of the sent text, so it is consumed
// separately and not left in the captured group. The TRAILING blank line
// is already gone by the time either caller reads this far (capturedText
// strips trailing LFs, same as `$(...)`), so only the leading one still
// needs matching. Only that exact shape, around the WHOLE field and
// nothing else (both tags carrying the SAME id), is stripped before
// comparison; anything looser would let a genuinely different pasted text
// stand down a real refutation.
const PASTE_WRAP_RE = /^\n+<pasted_content id="([^"]*)">\n([\s\S]*)\n<\/pasted_content id="\1">\n*$/;

function stripPasteWrap(s: string): string {
  const m = PASTE_WRAP_RE.exec(s);
  return m === null ? s : m[2];
}

// ac_arrival_wait's twin (ac-lib.sh's claude transcript arrival check): did
// <text>, its trailing LFs cut as the transcript reader cuts the arrived
// turn's, ARRIVE as the session's last typed human turn - byte-exact, or
// wrapped verbatim in claude's own bracket-paste tags (stripPasteWrap)? Up
// to seven reads a settle apart (PATH's sleep, as the bash ran it), returning
// at the first
// match: 0 CONFIRMED; 1 REFUTED - some turn was read and none matched, `last`
// the last one read (the bash's AC_ARRIVAL_LAST), UNLESS <text> is (again,
// byte-exact or wrapped) the newest queue-operation entry's content as of
// the LATEST read, with no typed turn superseding it since
// (LAST_QUEUED_IF_NEWEST's header: a mid-turn queued steer, never a typed
// turn - that reads 2 UNOBSERVABLE, not a refutation), OR the mismatched
// `last` turn's OWN transcript timestamp predates <started> (the caller's
// wall-clock moment, taken BEFORE the submit it is verifying the arrival
// of - never inside this function: claude can write a WRONG turn in the
// instant right after the submit's Enter, before this call even begins, and
// a started taken in here would already be past that write, misreading a
// genuine wrong arrival as merely pre-existing). A turn timestamped before
// <started> provably predates this send's submit - the budget closed before
// claude wrote anything AT ALL in reply (measured on a live incident: 36s
// between the pre-send turn and the real one, against a 2.4s default
// budget) - what we read is provably the turn that was already there, not a
// verdict on this send; a turn with no parseable timestamp, as every
// fixture lacking that field keeps, cannot be proven stale this way and
// still refutes; 2 UNOBSERVABLE - no <sid> (bytes, latin1), no single
// transcript, or no turn read at all. Neither carve-out has a bash twin:
// ac_arrival_wait/ac_claude_last_typed_turn in bin/ac-lib.sh have no live
// caller any more (only their own and the differential tests) - every live
// caller, ac-send.sh's steer AND ac-spawn.sh's kickoff alike, already runs
// this one function.
export function arrivalWait(sid: string, text: string, started: number = Date.now()): { status: number; last: string } {
  const expected = lat(text).replace(/\n+$/, "");
  if (sid === "") return { status: 2, last: "" };
  let last = "";
  let lastPath: string | null = null;
  let queued = false;
  for (let reads = 1; ; reads++) {
    // claude creates the transcript file at the session's first submitted
    // turn, which can land after the send that this wait follows returned.
    const path = claudeTranscriptPath(sid);
    if (path !== null) {
      const cur = claudeLastTypedTurn(path);
      if (cur !== null) {
        last = cur;
        lastPath = path;
        if (last === expected || stripPasteWrap(last) === expected) return { status: 0, last: "" };
      }
      const q = claudeLastQueuedIfNewest(path);
      queued = q !== null && (q === expected || stripPasteWrap(q) === expected);
    }
    if (reads >= 7) break;
    settle("inherit");
  }
  if (last === "") return { status: 2, last: "" };
  if (queued) return { status: 2, last: "" };
  if (lastPath !== null) {
    const ts = claudeLastTypedTurnTimestamp(lastPath);
    const at = ts === null ? NaN : Date.parse(ts);
    if (!Number.isNaN(at) && at < started) return { status: 2, last: "" };
  }
  return { status: 1, last };
}
