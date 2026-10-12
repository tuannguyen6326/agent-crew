// prompt-recall.ts - prompt-time fleet-memory recall for a HUMAN-DRIVEN
// session. Runs between the captain's prompt and the model's first read (the
// claude/codex UserPromptSubmit hook; cursor's beforeSubmitPrompt through
// bin/ac-prompt-recall-cursor.sh; pi before_agent_start and opencode
// chat.message through their extension/plugin), so a chief or solo session
// meets the home's history before it acts instead of remembering to ask -
// the knowledge law names `ac-brain.sh recall` at intake, and a law with no
// machine behind it measurably went unused for whole sessions.
// The entry is bin/ac-prompt-recall.sh, the fail-open hook shim that starts
// this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-prompt-recall.sh as the oracle the differential leg of
// tests/sh/ac-prompt-recall.test.sh holds this module to.
//
// Stdin: the harness payload; the prompt is jq's `(.prompt // .user_message
// // .text // empty) | tostring`. Stdout: at most ONE short block - the top
// hits with path, trust label and snippet, plus a freshness line (after the
// pending-wake line below, when there is one) - which the harness hands the
// model as context, so every byte of it is the original's. Empty stdout is
// the common case and means "nothing to add".
//
// SCOPE is the session's SHAPE, never the registration: the fleet settings
// file is copied into every crewmate worktree (seedCrewSettings), so this hook
// runs there too and must self-scope. It fires for the two shapes a human
// types into - a solo session (AC_SOLO=1, any cwd) and a chief whose cwd is
// the fleet home (crewchief or a scoped roomchief) - and is silent for
// everything else: a crewmate's prompts are briefs the chief already grounded
// and cited, and recalling again there is noise on top of cost.
//
// PENDING WAKES ride the same hook for a chief-shaped session only: one line
// counting the regular files in its own spool (the family spool under
// AC_SCOPE), printed ahead of every recall gate below. A solo session owns no
// wakes. The count only peeks - the drain consumes records.
//
// NOISE GATES, because a per-prompt reader pays context on every turn: no
// brain (state/brain.sqlite's existence is the opt-in),
// config/brain-prompt-recall=off (the valve), slash and bang prompts, prompts
// under 12 characters (counted as bash counts under the caller's locale) or
// with fewer than two content words (runs of [:alnum:] of length 3 or more,
// spawned tr and awk), and zero hits all print nothing. The prompt has its
// LF/CR/TAB turned to spaces and its [:space:] trimmed (spawned tr and sed).
// AC_PROMPT_RECALL_LIMIT caps the hits (default 3; anything but digits reads
// 3); snippets are cut at 140 characters.
//
// FRESHNESS: the block names the marker's age (state/.brain-last-sync), calls
// it STALE past AC_BRAIN_SYNC_IV (1800), and fires the shared catch-up sync
// (brainFreshen, one throttle with the watcher) so a stale brain is at most
// one turn old by the next prompt. Solo sessions never sync otherwise - a
// solo home with no chief measurably sat 11 days stale.
//
// Attribution: the recall's --by says who asked - solo, <fam>-chief under
// AC_SCOPE, else crewchief. Fails OPEN on every missing dependency and never
// blocks a prompt: exit 0 always.
//
// A BROKEN PORT. The frozen original needs bash, jq and its bin/ siblings
// (ac-lib.sh, ac-wake-lib.sh, ac-brain.sh): copying
// tests/fixtures/ac-prompt-recall.sh over bin/ac-prompt-recall.sh in the
// checkout the fleets run restores it whole until the fix lands; the
// captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - an AC_BRAIN_SYNC_IV that is no integer reads every age as fresh (`synced
//   <n>m ago`) and never fires a sync;
// - a recall that fails, or prints no `path`, is silence.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: with no bun on PATH the shim exits 0 at once and says nothing, where
//   the original recalled; a module that cannot load is the same silence.
// - FRESHEN: a catch-up whose attempt stamp cannot be written fires nothing,
//   where the original's failed redirection (no errexit here) still fired the
//   sync and said `catch-up sync fired`.
// - SHELL-OWN STDERR: `[`'s `integer expression expected` for an
//   AC_BRAIN_SYNC_IV that is no integer is not reproduced.
// - HOME RESOLUTION: an AC_HOME whose name ends in LF is the directory it
//   names, and a relative one is entered without CDPATH; a caller whose cwd
//   Bun cannot enter resolves no relative AC_HOME (silent).
// - BYTES: argv and the environment arrive decoded, so a prompt byte that is
//   not UTF-8 reaches the brain's argv as U+FFFD.
//
// CALLERS: the UserPromptSubmit wiring of .claude/settings.json and
// .codex/hooks.json; bin/ac-prompt-recall-cursor.sh (AC_PROMPT_RECALL_BIN for
// its tests), which wraps a non-empty block in cursor's continue envelope;
// .opencode/plugins/ac-primary-guards.js and .pi/extensions, which run the
// entry and read its stdout.

import { readdirSync, statSync, writeSync } from "node:fs";
import { brainFreshen, brainMarkerAge, commandV, configReadSoft, enterCaller, hookPayload, physicalDir, shellLength, softSubdir, spawnShellSync, STARTED_BIN, testInt, wakeSpoolPath } from "./lib.ts";

const { atCaller } = enterCaller(process.argv.slice(2));
const caller = process.argv[2] ?? "";
const HITS_JQ = "\n  (.results // [])[] | select(.path != null)\n  | \"- \" + .path + \" [\" + (.trust // \"?\") + \"; \" + (.evidence // \"?\") + \"] \"\n    + ((.snippet // \"\") | gsub(\"\\n\"; \" \") | .[0:140])";

const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const nat = (b: string): string => Buffer.from(b, "latin1").toString("utf8");
const say = (b: string): void => {
  const buf = Buffer.from(b, "latin1");
  for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
};
const cap = (b: string): string => b.replace(/\0/g, "").replace(/\n+$/, "");
// A child's stdout and status, "" when it cannot start.
function run(argv: string[], stdin: "inherit" | Buffer = "inherit", stderr: "inherit" | "ignore" = "ignore"): { status: number; out: string } {
  try {
    const r = spawnShellSync(argv, { stdin, stdout: "pipe", stderr });
    return { status: r.exitCode ?? 1, out: r.stdout.toString("latin1") };
  } catch {
    return { status: 127, out: "" };
  }
}

const payload = hookPayload();
if (!commandV("jq")) process.exit(0);
const h = process.env.AC_HOME ?? "";
const home = h !== "" && (atCaller || h.startsWith("/")) ? physicalDir(h) : null;
if (home === null) process.exit(0);

let by: string;
if (process.env.AC_SOLO === "1") by = "solo";
else {
  if (caller === "" || caller !== home) process.exit(0);
  by = process.env.AC_SCOPE ? `${lat(process.env.AC_SCOPE)}-chief` : "crewchief";
}

if (by !== "solo") {
  const spool = wakeSpoolPath(softSubdir("state", false), process.env.AC_SCOPE ?? "");
  let names: string[] = [];
  try {
    names = readdirSync(spool);
  } catch {}
  let n = 0;
  for (const r of names) {
    try {
      if (!r.startsWith(".") && statSync(`${spool}/${r}`).isFile()) n++;
    } catch {}
  }
  if (n !== 0) say(`agent-crew: ${n} queued wake(s) wait in this session's spool - run bin/ac-wake-drain.sh and handle them before acting on this prompt.\n`);
}

try {
  if (!statSync(`${home}/state/brain.sqlite`).isFile()) process.exit(0);
} catch {
  process.exit(0);
}
if (configReadSoft("brain-prompt-recall", "on") !== "on") process.exit(0);

const asked = cap(run(["jq", "-r", "(.prompt // .user_message // .text // empty) | tostring"], Buffer.from(`${payload}\n`, "latin1")).out);
const flat = run(["tr", "\n\r\t", "   "], Buffer.from(asked, "latin1"), "inherit").out;
const prompt = cap(run(["sed", "s/^[[:space:]]*//; s/[[:space:]]*$//"], Buffer.from(flat, "latin1"), "inherit").out);
if (prompt === "" || prompt.startsWith("/") || prompt.startsWith("!")) process.exit(0);
if (shellLength(prompt) < 12) process.exit(0);
const pieces = run(["tr", "-c", "[:alnum:]", "\n"], Buffer.from(prompt, "latin1"), "inherit").out;
const long = run(["awk", "length($0) >= 3"], Buffer.from(pieces, "latin1"), "inherit").out;
if (long.split("\n").length - 1 < 2) process.exit(0);

const iv = testInt(process.env.AC_BRAIN_SYNC_IV || "1800");
const age = brainMarkerAge() ?? 0n;
const fired = brainFreshen();

let limit = process.env.AC_PROMPT_RECALL_LIMIT ? lat(process.env.AC_PROMPT_RECALL_LIMIT) : "3";
if (limit === "" || /[^0-9]/.test(limit)) limit = "3";
const res = run([`${STARTED_BIN}/ac-brain.sh`, "recall", "--home", home, "--query", nat(prompt), "--limit", limit, "--by", nat(by), "--compact"]);
if (res.status !== 0) process.exit(0);
const hits = cap(run(["jq", "-r", HITS_JQ], Buffer.from(`${cap(res.out)}\n`, "latin1")).out);
if (hits === "") process.exit(0);

let fresh: string;
if (age < 0n) fresh = "never synced";
else if (iv !== null && age >= iv) {
  fresh = age >= 86400n ? `STALE - last sync ${age / 86400n}d ago` : `STALE - last sync ${age / 3600n}h ago`;
  if (fired) fresh += ", catch-up sync fired";
} else fresh = `synced ${age / 60n}m ago`;

say(`ac-brain recall for this prompt (fleet memory, by ${by}; ${fresh}):\n${hits}\nUse a hit only after reading its path; cite path + quote when it shapes the answer. A STALE brain is missing history after its last sync.\n`);
process.exit(0);
