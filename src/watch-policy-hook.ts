// watch-policy-hook.ts - PreToolUse hook (Bash tool): deny broad watcher
// kills before they run.
// The entry is bin/ac-watch-policy-hook.sh, the fail-open hook shim that
// starts this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is
// the authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-watch-policy-hook.sh as the oracle the differential leg of
// tests/sh/ac-guard.test.sh holds this module to.
//
// Wired in .claude/settings.json under hooks.PreToolUse (matcher "Bash");
// reads the hook payload JSON on stdin and inspects .tool_input.command.
//
// DENIES (exit 2, reason on stderr) commands that kill watchers by PATTERN
// instead of by pid - the incident this prevents: an over-broad pkill took
// down ANOTHER session's scoped watcher along with the caller's own:
// - pkill/killall whose argument (same pipeline segment) mentions watch
//   (ac-watch, ac-watch.sh, ...);
// - kill fed by pgrep in a command that mentions watch
//   (kill $(pgrep -f ac-watch); p=$(pgrep -f watch); kill $p);
// - kill of a shell variable whose name mentions watch (kill "$WATCH_PID").
// Everything else is ALLOWED (exit 0): plain `kill <pid>` of a single known
// pid is the sanctioned way to stop a watcher you own.
//
// THE TESTS, the original's, in its order - the first that matches denies
// with its reason. Each greps the command LOWERCASED by `tr '[:upper:]'
// '[:lower:]'` over the bytes jq printed, and each grep reads that text plus
// one LF, as the original's here-strings fed it; tr and every grep are
// spawned under the caller's locale with their stderr the hook's, so what
// `[:alnum:]` or a case fold means is theirs:
// 1. `grep -qE '(^|[^[:alnum:]_-])(pkill|killall)[^|;&]*watch'` - "denied:
//    pkill/killall pattern targets a watcher";
// 2. `grep -q kill`, `grep -q pgrep` and `grep -q watch` all match, each
//    over the whole text - "denied: kill of pgrep-derived pids mentioning
//    watch";
// 3. `grep -qE '(^|[^[:alnum:]_-])kill[^|;&]*[$][{"]*[a-z_]*watch'` -
//    "denied: kill of a watch-named variable".
// A grep that cannot start or errs is no match.
//
// Fails open: missing jq, an empty or unparseable payload, a payload naming a
// tool other than Bash, or no command all exit 0 (no bun, and a module that
// cannot load, are the shim's) - a broken hook must never wedge the harness.
// A payload with no tool name at all is judged. Exit codes: 0 allow, 2 deny;
// nothing on stdout, the refusal one line on stderr. Files: none.
//
// THE READS, the original's: jq is looked for before stdin is read; the
// payload is stdin to its end with NULs dropped and trailing LFs stripped;
// the name is jq's `-r '.tool_name // empty'` and the command jq's `-r
// '.tool_input.command // empty'`, each over the payload plus one LF,
// spawned, its stdout taken whatever jq's status, NULs dropped and trailing
// LFs stripped; tr's output is read the same way.
//
// A BROKEN PORT. The frozen original needs only bash, jq, tr and grep:
// copying tests/fixtures/ac-watch-policy-hook.sh over
// bin/ac-watch-policy-hook.sh in the checkout the fleets run (the wiring
// names that path) restores it whole until the fix lands; the captain's
// revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - the command is jq's text: a command that is no string is judged by its
//   JSON text, and a payload holding a second value prints a name joined by
//   LF (`Bash<LF>Bash` is no Bash, so it is allowed);
// - grep reads lines: tests 1 and 3 match within one line of the command,
//   so a pkill whose watch-naming argument sits past an LF is allowed.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: with no bun on PATH the shim allows at once, saying nothing, where
//   the original judged; a module that cannot load or crashes allows too.
// - SHELL-OWN STDERR: tr or a grep that cannot start reads as no text or no
//   match on both sides, and the original's `<name>: command not found` line
//   is not reproduced.
// - TEMP: the original fed jq and every grep a here-string, a temp file under
//   $TMPDIR, else /tmp; with neither writable it allowed with bash's own
//   line, where the port pipes each child's stdin and judges.
//
// CALLERS: the PreToolUse wiring of .claude/settings.json and
// .codex/hooks.json, each behind its own [ -x ] gate; by path, with a payload
// each synthesizes: bin/ac-watch-policy-cursor.sh,
// .opencode/plugins/ac-primary-guards.js and
// .pi/extensions/ac-primary-turnend-guard.ts.

import { writeSync } from "node:fs";
import { commandV, enterCaller, hookJq, hookPayload, spawnShellSync } from "./lib.ts";

enterCaller(process.argv.slice(2));
if (!commandV("jq")) process.exit(0);
const payload = hookPayload();
if (payload === "") process.exit(0);

const tool = hookJq(".tool_name // empty", payload);
if (tool !== "" && tool !== "Bash") process.exit(0);
const cmd = hookJq(".tool_input.command // empty", payload);
if (cmd === "") process.exit(0);

let folded = Buffer.alloc(0);
try {
  folded = Buffer.from(spawnShellSync(["tr", "[:upper:]", "[:lower:]"], { stdin: Buffer.from(cmd, "latin1"), stdout: "pipe", stderr: "inherit" }).stdout);
} catch {}
const lc = Buffer.from(`${folded.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "")}\n`, "latin1");

const grep = (...argv: string[]): boolean => {
  try {
    return spawnShellSync(["grep", ...argv], { stdin: lc, stdout: "ignore", stderr: "inherit" }).exitCode === 0;
  } catch {
    return false;
  }
};

const deny = (why: string): never => {
  writeSync(2, `ac-watch-policy: ${why}. Kill a watcher by its OWN pid (kill <pid>), never by pattern - a broad match can take down another session's watcher.\n`);
  process.exit(2);
};

if (grep("-qE", "(^|[^[:alnum:]_-])(pkill|killall)[^|;&]*watch")) deny("denied: pkill/killall pattern targets a watcher");
if (grep("-q", "kill") && grep("-q", "pgrep") && grep("-q", "watch")) deny("denied: kill of pgrep-derived pids mentioning watch");
if (grep("-qE", '(^|[^[:alnum:]_-])kill[^|;&]*[$][{"]*[a-z_]*watch')) deny("denied: kill of a watch-named variable");
process.exit(0);
