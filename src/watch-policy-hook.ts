// watch-policy-hook.ts - PreToolUse hook (Bash tool): deny broad watcher
// kills before they run.
// The entry is bin/ac-watch-policy-hook.sh, the hook shim that starts this
// file through bin/ac-bun.sh's ac_bun_exec_guard; THIS header is
// the authoritative spec, and tests/sh/ac-guard.test.sh is its contract
// test.
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
// tool other than Bash, or no command all exit 0 (a module that cannot load
// is the shim's, and no bun the shim's denial) - a broken hook must never
// wedge the harness.
// A payload with no tool name at all is judged. Exit codes: 0 allow, 2 deny;
// nothing on stdout, the refusal one line on stderr. Files: none.
//
// THE READS, the original's: jq is looked for before stdin is read; the
// payload is stdin to its end with NULs dropped and trailing LFs stripped;
// the name is jq's `-r '.tool_name // empty'`. The command is jq's `-r 'if
// .tool_input.command == null then empty elif (.tool_input.command|type) ==
// "string" then .tool_input.command else "\u0001" end'` - a present non-string
// command denies on the sentinel rather than being judged by its JSON text.
// Each runs over the payload plus one LF, spawned, its stdout taken whatever
// jq's status, NULs dropped and trailing LFs stripped; tr's output is read
// the same way.
//
// A name holding an embedded LF (a second top-level JSON value in the payload
// joined its own line to the first) denies outright, before the shape test:
// `Bash<LF>Bash` is two documents, never a wider tool name. A present command
// that is no JSON string denies when the `\u0001` sentinel appears anywhere in
// what jq printed, rather than being judged by its JSON text. A shell
// line-continuation (backslash+LF) the command carries is folded to a space
// before the line-sensitive tests run - it is the SAME logical line, and grep
// reads lines, so a pkill whose watch-naming argument sits past one would
// otherwise be judged a line at a time; a BARE LF stays a line of its own, a
// statement separator exactly like `;`, so an unrelated later command sharing
// a word with an earlier pkill/kill is never judged together with it.
//
// ALSO:
// - BUN: with no bun on PATH, or no module file, the shim denies at once with
//   one stderr line naming it; a module that cannot load or crashes allows,
//   with one stderr line.
// - tr or a grep that cannot start reads as no text or no match, with no
//   line of this module's own.
// - Each child's stdin is piped: no temp file is written under $TMPDIR.
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

const deny = (why: string): never => {
  writeSync(2, `ac-watch-policy: ${why}. Kill a watcher by its OWN pid (kill <pid>), never by pattern - a broad match can take down another session's watcher.\n`);
  process.exit(2);
};

const tool = hookJq(".tool_name // empty", payload);
if (tool.includes("\n")) deny("denied: the payload holds more than one JSON value");
if (tool !== "" && tool !== "Bash") process.exit(0);
const cmdFilter = 'if .tool_input.command == null then empty elif (.tool_input.command|type) == "string" then .tool_input.command else "\\u0001" end';
const cmd = hookJq(cmdFilter, payload);
if (cmd.includes("\u0001")) deny("denied: command is not a JSON string");
if (cmd === "") process.exit(0);

// A shell line-continuation (backslash+LF) is the SAME logical line and is
// folded to a space before tr/grep ever see it; a bare LF is a statement
// separator (same as `;`) and must stay a line of its own, or an unrelated
// later command sharing a word with an earlier pkill/kill would deny it.
const continued = cmd.replace(/\\\n/g, " ");
let folded = Buffer.alloc(0);
try {
  folded = Buffer.from(spawnShellSync(["tr", "[:upper:]", "[:lower:]"], { stdin: Buffer.from(continued, "latin1"), stdout: "pipe", stderr: "inherit" }).stdout);
} catch {}
const lc = Buffer.from(`${folded.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "")}\n`, "latin1");

const grep = (...argv: string[]): boolean => {
  try {
    return spawnShellSync(["grep", ...argv], { stdin: lc, stdout: "ignore", stderr: "inherit" }).exitCode === 0;
  } catch {
    return false;
  }
};

if (grep("-qE", "(^|[^[:alnum:]_-])(pkill|killall)[^|;&]*watch")) deny("denied: pkill/killall pattern targets a watcher");
if (grep("-q", "kill") && grep("-q", "pgrep") && grep("-q", "watch")) deny("denied: kill of pgrep-derived pids mentioning watch");
if (grep("-qE", '(^|[^[:alnum:]_-])kill[^|;&]*[$][{"]*[a-z_]*watch')) deny("denied: kill of a watch-named variable");
process.exit(0);
