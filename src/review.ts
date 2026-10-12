// review.ts - the crewmate CLI for the dashboard's native annotate loop: the
// open/poll/reply/end/url verb set the rich-review skill teaches, a thin
// client of the dashboard review API - the DASHBOARD owns sessions, anchors
// and the viewer (dashboard/app.ts's review block is that contract). The
// entry is bin/ac-review.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-review.sh as the oracle the
// differential leg of tests/sh/ac-review.test.sh holds this module to.
//
// Usage (the artifact is an .html OR .md file under the home's artifact roots;
// an md file reviews as-is - the dashboard renders it and pins carry the
// source line):
//   ac-review.sh open <file> [--reopen] [--auto-open]
//   ac-review.sh poll <file> [--after N] [--agent-reply <reply>]
//   ac-review.sh reply <file> <reply>
//   ac-review.sh end <file>
//   ac-review.sh url <file>                    print the captain's viewer URL
//
// The dashboard must be RUNNING (bin/ac-dashboard.sh); a down dashboard is a
// loud refusal naming the fix, never a hang. Every refusal below is `ERROR:
// <msg>` on stderr, exit 1, unless it says otherwise.
//
// PRELUDE, in order:
//   1. curl, then jq, not on PATH: `required tool not found: <tool>`, before
//      any argument is read.
//   2. a first word other than the five verbs (none, `-h`, anything):
//      `usage: ac-review.sh open|poll|reply|end|url <file>.html [options]`.
//   3. no <file>: `usage: ac-review.sh <verb> <file>.html [options]`.
//   4. <file> no regular file (missing, a directory, a FIFO - never opened):
//      `no such artifact: <file as given>`.
//   5. <file> made canonical: `dirname <file>` and `basename <file>` are
//      spawned (stderr passing through), the directory entered physically
//      (physicalDir), `<dir>/<base>` - a symlinked directory resolves, a
//      symlinked file keeps its link name, a relative path is the caller's. A
//      <file> they take for an option (`-x/a.html`, `--`) is their usage text
//      and basename's status, 1; a file named `-` is an operand.
//   6. the home, AC_HOME through physicalDir: unset is `ERROR: <ac_home's
//      refusal>` and then `AC_HOME required: the review session belongs to a
//      fleet home` - TWO lines, kept; one that cannot be entered, the second
//      line alone.
//   7. <port>: AC_DASH_PORT when non-empty, else config/dash-port's first line
//      [:space:]-trimmed (configReadDir; one this user cannot read is ""),
//      else 8787 - never validated. <base> is `http://127.0.0.1:<port>`.
//   8. <q> is `path=<home>&file=<file>`, each value through `jq -rn --arg v
//      <value> '$v|@uri'` spawned (stdin inherited; jq keeps only
//      A-Za-z0-9-_.~) - for every verb, url included; the second jq failing
//      ends the run with its status, as the assignment's last substitution.
//
// VERBS, the words after <file> (ignored unless a verb reads them):
//   url: stdout `<base>/review?<q>`, exit 0, no request.
//   open [--reopen] [--auto-open], each repeatable; any other word is
//     `unknown open option: <w>` before any request. Without --reopen, REQ
//     POST `/api/review/end?<q>&reopen=1` (a failed request ends the run
//     after its line); `jq -e .ok` false is `open refused: <jq -r '.error //
//     .'> ` with a TRAILING SPACE (W2) - the whole body pretty-printed when it
//     has no .error, jq's parse error once per read on a body that is no
//     JSON. With --reopen, REQ POST `...&reopen=1&force=1` piped into `jq -e
//     .ok`: a failed request is its line AND `reopen failed` (W3: jq read an
//     empty pipe), a refusal `reopen failed` alone. Then stdout `review open -
//     captain viewer: <base>/review?<q>` and, with --auto-open, THE OPENER;
//     exit 0. A captain-ended session is refused by the server (409) and
//     --reopen is the deliberate override.
//   reply <reply>: REPLY, then stdout `replied`.
//   end: REQ POST `/api/review/end?<q>&by=agent` piped into `jq -e .ok` (W3
//     as --reopen): `end failed`; stdout `session ended`.
//   poll [--after <n>] [--agent-reply <reply>], in argv order: --after's
//     value (the last wins) is neither validated nor encoded - it rides the
//     query raw (W7: `1&x=2` adds a parameter); --agent-reply is a REPLY made
//     when the flag is read (W6: before a later word is refused; once per
//     flag); a flag with no value or an empty one is `<flag> needs a value`
//     (W5); any other word `unknown poll option: <w>`. Then THE POLL LOOP.
//
// THE POLL LOOP has no pause of its own - the server's long-poll hold (25 s a
// round) paces it. Each round: REQ GET `/api/review/poll?<q>&after=<n>` (a
// failed request ends the run after its line), then jq spawned over the body
// in this order:
//   - `jq -e 'has("items")'` false: `poll failed: <jq -r '.error // .'>`;
//   - `jq -r .state`, then `jq '.items | length'` - either failing ends the
//     run with jq's status (`"items": true` is 5) before a byte is printed;
//   - state `ended`, or a length that is an integer > 0: stdout the body,
//     exit 0;
//   - `jq -r '.pending // 0'` an integer > 0: stderr `pending: <n> item(s)
//     awaiting captain approval - stop and ask your chief; resume with:
//     bin/ac-review.sh poll <canonical file> --after <n as given>`, then stdout
//     the body, exit 0 - only the COUNT rides this line, never content;
//   - else the next round.
//   "An integer" is bash's `[ x -gt 0 ]` grammar (W8, reproduced): leading
//   white space, a sign, ASCII digits, trailing blanks, within int64 -
//   `2.5`, `1.5`, `true`, past 2^63 and a multi-value stream's `1\n0` are no
//   integer, so the loop goes on (forever while the server keeps answering
//   so) exactly where the original's did.
//
// REQ <method> <route> [<body>]: curl from PATH,
//   curl -sS --connect-timeout 2 --max-time 40 -X <method> [--data-binary <body>] <base><route>
// stdin inherited, stdout and stderr MERGED into one capture in curl's write
// order (spawned as `sh -c 'exec "$0" "$@" 2>&1' curl <argv>` with stdout
// piped: one pipe behind both fds, as the original's `$(... 2>&1)` had; W4:
// a curl warning rides inside the answer), NULs and trailing LFs dropped. There is no -f: an HTTP error status is an
// answer. curl's status: 0, the capture is the answer; 7 `dashboard
// unreachable on port <port> - start it: bin/ac-dashboard.sh`; 28 `dashboard
// on port <port> timed out - it may be overloaded, retry`; 52 or 56
// `dashboard on port <port> dropped the connection (a transport hiccup, not a
// dead process) - retry`; else `dashboard request on port <port> failed
// (curl exit <rc>): <capture>` - <rc> the shell's reading (128+signal), a
// trailing space when nothing was captured.
//
// REPLY <reply>: "" is `reply text required`; any text but `-` or one
// starting with `@` is the body itself, sent as argv, uncapped. `@<path>` and
// `-` (stdin) are SPOOLED: `mktemp ${TMPDIR:-/tmp}/ac-review-reply.XXXXXX`
// spawned (its own line and status when it fails); `@<path>` that is no
// regular file removes the spool, `no such reply file: <path>` (`@` alone
// names ""); then `cat <path>`, or `cat` of stdin for `-`, spawned into the
// spool - a cat that fails ends the run with its own line and status, the
// spool LEFT in TMPDIR (W9); past 1048576 bytes (dashboard/app.ts
// REVIEW_REPLY_MAX_BYTES, the number the reply route answers 413 past) the
// spool is removed, `reply is <n> bytes, over the dashboard's 1048576-byte
// cap (dashboard/app.ts REVIEW_REPLY_MAX_BYTES) - shorten it`; empty, removed,
// `reply text required`. The body is then `@<spool>` (curl reads the file).
// REQ POST `/api/review/reply?<q>` <body>; the spool removed; a failed request
// exits 1 after its line; `jq -e .ok` false is `reply refused: <jq -r
// '.error // .'>`.
//
// THE OPENER (--auto-open), after the viewer line: $BROWSER when non-empty
// and `command -v` resolves it, else `open`, else `xdg-open`, else nothing -
// a headless box is silent success. Resolution is bash's: a shell builtin or
// reserved word resolves; a word holding `/` resolves as an executable
// non-directory; a bare word as the first executable non-directory on PATH,
// else the first non-directory file there that is not executable (bash's last
// resort - spawning it fails, nothing launches). A BROWSER with arguments
// resolves nothing and falls through (W11). The opener is spawned `<opener>
// <url>` with the caller's stdin, its output and status discarded, and waited
// for. A builtin or reserved word launches nothing (W12: `BROWSER=:` or
// `true` never reaches `open`); `exit` and `return` end the run 255, and `.`,
// `source`, `exec`, `history`, `let` and `shift` 1 - the status running them
// gave the original (measured, bash 3.2).
//
// EXIT: 0 per verb above; 1 on a refusal; a spawned tool's status where one
// is named; 141, silently, when stdout's reader is gone.
//
// DIVERGENCES from the original, named in the differential leg:
//   W1 an AC_HOME cd cannot enter: the entry's line alone, where the shell
//      printed cd's own line first (the HOME RESOLUTION ruling).
//   W10 an exported CDPATH: never consulted - the original's `cd` of a
//      relative directory entered the CDPATH match and captured its echo into
//      the path (of the artifact, or of a relative AC_HOME).
//   A path component ending in LF is kept; the original's `$(...)` dropped it
//      and named a sibling (the HOME RESOLUTION class).
//   W5 bash's own `<script>: line <n>: 2: parameter null or not set` is now
//      `<flag> needs a value`, exit 1 alike.
//   Shell-own and tool-own stderr not reproduced: the test builtin's `[:
//      <x>: integer expression expected` (W8), head's line for an unreadable
//      config/dash-port, a failed redirection into the spool.
//   A BROWSER naming a function of the original's (ac-lib.sh's helpers, req,
//      post_reply, ac_try_open) RAN it there - ac_die ended the run 1,
//      nothing launched; the port has no such functions and resolves the
//      name like any other.
//   A curl or jq on PATH that is not executable is `not found` here; the
//      original's `command -v` took it and failed running it.
//   An executable the kernel refuses (no shebang) runs under /bin/bash as
//      the shell ran it with itself - the same file, $0 its resolved path;
//      curl's capture shell is /bin/sh by its absolute path: PATH owes
//      neither a bash nor an sh.
//   argv bytes: a byte that is not UTF-8 reaches Bun's argv as U+FFFD (a
//      <file> or reply path holding one names nothing; a reply text sends
//      U+FFFD), and config/dash-port is read as UTF-8 the same way.
//   A caller cwd with no name: a relative <file>, reply path or AC_HOME names
//      nothing, as the deleted directory the original looked in held nothing.
//
// CALLERS: no script runs this entry. Agents run it from crewmate and
// roomchief panes on the rich-review skill's word (open, poll, reply, end)
// and gate-review's (`open <file>.html --auto-open`); dashboard/app.ts's
// review wake names `bin/ac-review.sh poll <file>` as the legal channel
// (pinned by dashboard/app.test.ts). Those panes' PATH needs bun now: without
// it the shim prints `ERROR: required tool not found: bun`, exit 1, where the
// review loop used to answer - a loud refusal to an agent's hand, never a
// silent exit, so nothing fails soft.
import { accessSync, closeSync, constants, openSync, statSync, unlinkSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { configReadDir, die, enterCaller, NO_HOME, physicalDir, require, spawnShellSync } from "./lib.ts";

type Spawned = ReturnType<typeof Bun.spawnSync> | null;
type Io = "pipe" | "ignore" | "inherit" | number;

// Lines are bytes: what a child printed is held as latin1 and written back as
// the same bytes; an argv string joins it as its UTF-8 bytes.
const b = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const text = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
// `$(...)`: NULs dropped, trailing newlines stripped.
const captured = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");
const fail = (msg: string): never => die(b(msg));
const refuse = (msg: string): void => {
  writeSync(2, b(`ERROR: ${msg}\n`));
};

function say(line: string): void {
  const buf = b(`${line}\n`);
  try {
    for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off, buf.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

function status(r: Spawned): number {
  if (!r) return 127;
  if (r.signalCode) return 128 + ((osConstants.signals as Record<string, number>)[r.signalCode] ?? 0);
  return r.exitCode ?? 1;
}

function run(argv: string[], stdin: "inherit" | Buffer, stdout: Io, stderr: Io = "inherit"): { rc: number; out: string } {
  let r: Spawned = null;
  try {
    r = spawnShellSync(argv, { stdin, stdout, stderr });
  } catch {}
  return { rc: status(r), out: stdout === "pipe" && r?.stdout ? Buffer.from(r.stdout).toString("latin1") : "" };
}

// `jq <args> <<<"$out"`: the here-string adds one LF; jq's stderr is the reader's.
const jq = (args: string[], body: string, keep = true) => run(["jq", ...args], b(`${body}\n`), keep ? "pipe" : "ignore");
const jqOk = (body: string): boolean => jq(["-e", ".ok"], body, false).rc === 0;
const jqError = (body: string): string => captured(jq(["-r", ".error // ."], body).out);
// A bare `x="$(jq ...)"` under errexit: jq's failure is the run's status.
const must = (r: { rc: number; out: string }): string => (r.rc === 0 ? captured(r.out) : process.exit(r.rc));
// `req ... | jq -e '.ok' >/dev/null` under pipefail: jq reads what req printed
// (nothing once req refused), and both must succeed.
const piped = (out: string | null): boolean => run(["jq", "-e", ".ok"], b(out === null ? "" : `${out}\n`), "ignore").rc === 0 && out !== null;

// `[ "$x" -gt 0 ]` under bash 3.2: strtoimax's leading white space and sign,
// decimal digits, trailing blanks only, within int64; anything else is no
// integer and the test is false.
function gt0(x: string): boolean {
  const m = /^[\t\n\v\f\r ]*([+-]?)([0-9]+)[\t ]*$/.exec(x);
  if (!m) return false;
  const v = BigInt(m[2]!) * (m[1] === "-" ? -1n : 1n);
  return v > 0n && v <= 9223372036854775807n;
}

const callerCwd = process.argv[2] ?? "";
const { args, atCaller } = enterCaller(process.argv.slice(2));
// A caller cwd bun could not enter leaves this process in the distro root; a
// relative path is still the caller's, and a cwd with no name holds nothing.
const at = (p: string): string | null => (atCaller || p.startsWith("/") ? p : callerCwd === "" ? null : `${callerCwd}/${p}`);

function isFile(p: string | null): boolean {
  if (p === null) return false;
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

const rm = (p: string): void => {
  try {
    unlinkSync(p);
  } catch {}
};

// `$(cd "$(dirname f)" && pwd -P)/$(basename f)`. Each tool's answer loses only
// the LF it ended it with: an LF that ends a name is the name's.
function canonical(f: string): string {
  const oneLine = (s: string): string => text(s.endsWith("\n") ? s.slice(0, -1) : s);
  const dir = physicalDir(oneLine(run(["dirname", f], "inherit", "pipe").out)) ?? "";
  const base = run(["basename", f], "inherit", "pipe");
  if (base.rc !== 0) process.exit(base.rc);
  return `${dir}/${oneLine(base.out)}`;
}

require("curl", "jq");
const [cmd = "", fileArg = ""] = args;
if (!["open", "poll", "reply", "end", "url"].includes(cmd)) fail("usage: ac-review.sh open|poll|reply|end|url <file>.html [options]");
if (fileArg === "") fail(`usage: ac-review.sh ${cmd} <file>.html [options]`);
const fileAt = at(fileArg);
if (!isFile(fileAt)) fail(`no such artifact: ${bytes(fileArg)}`);
const file = canonical(fileAt!);

const HOME_REQUIRED = "AC_HOME required: the review session belongs to a fleet home";
const h = process.env.AC_HOME ?? "";
if (h === "") {
  refuse(NO_HOME);
  fail(HOME_REQUIRED);
}
const hAt = at(h);
const home = (hAt === null ? null : physicalDir(hAt)) ?? fail(HOME_REQUIRED);

let port = process.env.AC_DASH_PORT ?? "";
if (port === "") {
  // Inside the original's `$(...)` a knob this user cannot read was head's
  // own line and an empty port, and the run went on.
  try {
    port = text(configReadDir(`${home}/config`, "dash-port", "8787"));
  } catch {}
}
const base = `http://127.0.0.1:${port}`;
const uri = (v: string) => run(["jq", "-rn", "--arg", "v", v, "$v|@uri"], "inherit", "pipe");
const homeQ = uri(home);
const fileQ = uri(file);
// The assignment's status was its LAST substitution's.
if (fileQ.rc !== 0) process.exit(fileQ.rc);
const q = `path=${captured(homeQ.out)}&file=${captured(fileQ.out)}`;
const viewer = `${base}/review?${q}`;

// `$(curl ... 2>&1)`: one pipe behind both of curl's outputs keeps the order
// the bytes were written in, which two pipes would lose; `exec` leaves the
// status, a signal's included, curl's own.
function curl(argv: string[]): { rc: number; out: string } {
  const { rc, out } = run(["/bin/sh", "-c", 'exec "$0" "$@" 2>&1', "curl", ...argv], "inherit", "pipe");
  return { rc, out: captured(out) };
}

// The answer, or null once the failure's line is printed - what the caller
// does next is the caller's, as each of the original's call sites differed.
function req(method: string, route: string, body = ""): string | null {
  const { rc, out } = curl(["-sS", "--connect-timeout", "2", "--max-time", "40", "-X", method, ...(body ? ["--data-binary", body] : []), `${base}${route}`]);
  if (rc === 0) return out;
  const p = bytes(port);
  if (rc === 7) refuse(`dashboard unreachable on port ${p} - start it: bin/ac-dashboard.sh`);
  else if (rc === 28) refuse(`dashboard on port ${p} timed out - it may be overloaded, retry`);
  else if (rc === 52 || rc === 56) refuse(`dashboard on port ${p} dropped the connection (a transport hiccup, not a dead process) - retry`);
  else refuse(`dashboard request on port ${p} failed (curl exit ${rc}): ${out}`);
  return null;
}

// Mirrors dashboard/app.ts REVIEW_REPLY_MAX_BYTES - the one number both ends
// refuse at, so the agent reads the cap here instead of a bare 413.
const REPLY_MAX = 1024 * 1024;

function postReply(src: string): void {
  let body = src;
  let spool = "";
  if (src.startsWith("@") || src === "-") {
    const made = run(["mktemp", `${process.env.TMPDIR || "/tmp"}/ac-review-reply.XXXXXX`], "inherit", "pipe");
    if (made.rc !== 0) process.exit(made.rc);
    spool = text(captured(made.out));
    const path = src === "-" ? null : src.slice(1);
    if (path !== null && !isFile(at(path))) {
      rm(spool);
      fail(`no such reply file: ${bytes(path)}`);
    }
    // `cat ... >"$spool"`: a redirection that fails ended the original 1.
    let fd: number;
    try {
      fd = openSync(spool, "w");
    } catch {
      process.exit(1);
    }
    const copied = run(path === null ? ["cat"] : ["cat", at(path)!], "inherit", fd);
    closeSync(fd);
    if (copied.rc !== 0) process.exit(copied.rc);
    const size = statSync(spool).size;
    if (size > REPLY_MAX) {
      rm(spool);
      fail(`reply is ${size} bytes, over the dashboard's ${REPLY_MAX}-byte cap (dashboard/app.ts REVIEW_REPLY_MAX_BYTES) - shorten it`);
    }
    if (size === 0) {
      rm(spool);
      fail("reply text required");
    }
    body = `@${spool}`;
  } else if (src === "") fail("reply text required");
  const out = req("POST", `/api/review/reply?${q}`, body);
  if (spool) rm(spool);
  if (out === null) process.exit(1);
  if (!jqOk(out)) fail(`reply refused: ${jqError(out)}`);
}

// bash 3.2's builtins (`enable -a`) and reserved words (`compgen -k`):
// `command -v` resolves each, and running one as "$opener" launched nothing.
const SHELL_WORDS = new Set(
  (
    ". : [ alias bg bind break builtin caller cd command compgen complete continue declare dirs disown echo enable eval " +
    "exec exit export false fc fg getopts hash help history jobs kill let local logout popd printf pushd pwd read readonly " +
    "return set shift shopt source suspend test times trap true type typeset ulimit umask unalias unset wait " +
    "if then else elif fi case esac for select while until do done in function time { } ! [[ ]]"
  ).split(" "),
);
// The ones whose run ended the original, with its status (measured).
const SHELL_ENDS: Record<string, number> = { exit: 255, return: 255, ".": 1, source: 1, exec: 1, history: 1, let: 1, shift: 1 };

function fileKind(p: string): "exec" | "file" | null {
  try {
    if (statSync(p).isDirectory()) return null;
  } catch {
    return null;
  }
  try {
    accessSync(p, constants.X_OK);
    return "exec";
  } catch {
    return "file";
  }
}

function resolves(word: string): boolean {
  if (SHELL_WORDS.has(word)) return true;
  if (word.includes("/")) return fileKind(word) === "exec";
  let lastResort = false;
  for (const dir of (process.env.PATH ?? "").split(":")) {
    const kind = fileKind(`${dir || "."}/${word}`);
    if (kind === "exec") return true;
    if (kind === "file") lastResort = true;
  }
  return lastResort;
}

// Headless/cron/no-GUI hosts are the common case here, not the exception, so
// a missing opener is silent success, never a failure this entry surfaces.
function tryOpen(url: string): void {
  const browser = process.env.BROWSER ?? "";
  const opener = browser !== "" && resolves(browser) ? browser : ["open", "xdg-open"].find(resolves);
  if (opener === undefined) return;
  if (!SHELL_WORDS.has(opener)) {
    run([opener, url], "inherit", "ignore", "ignore");
    return;
  }
  const end = SHELL_ENDS[opener];
  if (end !== undefined) process.exit(end);
}

const rest = args.slice(2);
if (cmd === "url") {
  say(bytes(viewer));
} else if (cmd === "open") {
  let reopen = false;
  let autoOpen = false;
  for (const a of rest) {
    if (a === "--reopen") reopen = true;
    else if (a === "--auto-open") autoOpen = true;
    else fail(`unknown open option: ${bytes(a)}`);
  }
  if (reopen) {
    if (!piped(req("POST", `/api/review/end?${q}&reopen=1&force=1`))) fail("reopen failed");
  } else {
    const out = req("POST", `/api/review/end?${q}&reopen=1`) ?? process.exit(1);
    if (!jqOk(out)) fail(`open refused: ${jqError(out)} `);
  }
  say(`review open - captain viewer: ${bytes(viewer)}`);
  // --auto-open is gate-review's own opt-in (a captain-required gate is
  // already blocking on this URL); rich-review omits the flag so an ordinary
  // artifact publish never pops a window uninvited.
  if (autoOpen) tryOpen(viewer);
} else if (cmd === "reply") {
  postReply(rest[0] ?? "");
  say("replied");
} else if (cmd === "end") {
  if (!piped(req("POST", `/api/review/end?${q}&by=agent`))) fail("end failed");
  say("session ended");
} else {
  let after = "0";
  for (let i = 0; i < rest.length; i += 2) {
    const flag = rest[i]!;
    if (flag !== "--after" && flag !== "--agent-reply") fail(`unknown poll option: ${bytes(flag)}`);
    const v = rest[i + 1] ?? "";
    if (v === "") fail(`${flag} needs a value`);
    if (flag === "--after") after = v;
    else postReply(v);
  }
  for (;;) {
    const out = req("GET", `/api/review/poll?${q}&after=${after}`) ?? process.exit(1);
    if (jq(["-e", 'has("items")'], out, false).rc !== 0) fail(`poll failed: ${jqError(out)}`);
    const state = must(jq(["-r", ".state"], out));
    const items = must(jq([".items | length"], out));
    if (state === "ended" || gt0(items)) {
      say(out);
      process.exit(0);
    }
    // A non-zero `pending` (guest feedback withheld at the moderation wall)
    // with empty `items` must reach the caller, not loop in silence: the
    // rich-review skill promises "a non-zero pending with empty items means
    // WAIT". The hint names the ONE correct move - stop and ask, never
    // re-poll in a loop for the same non-answer - so the entry teaches it even
    // to a caller that has not loaded the skill.
    const pending = must(jq(["-r", ".pending // 0"], out));
    if (gt0(pending)) {
      writeSync(2, b(`pending: ${pending} item(s) awaiting captain approval - stop and ask your chief; resume with: bin/ac-review.sh poll ${bytes(file)} --after ${bytes(after)}\n`));
      say(out);
      process.exit(0);
    }
  }
}
