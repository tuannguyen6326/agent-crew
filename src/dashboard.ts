// dashboard.ts - launch the agent-crew local web dashboard.
//
// The entry is bin/ac-dashboard.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec of the entry, and the
// bash original it replaced stays frozen at tests/fixtures/ac-dashboard.sh as
// the oracle the differential leg of tests/sh/ac-dashboard-daemon.test.sh holds
// this module to. The server itself is dashboard/app.ts, whose header owns the
// routes, the API and the write surfaces.
//
// Usage: ac-dashboard.sh [--port <N>]     (default port 8787; FOREGROUND)
//        ac-dashboard.sh start|stop|restart|status [--port <N>]
//        ac-dashboard.sh -h | --help
//
// ARGS: a verb is only the first word. Then, in order: `--port` takes the
// next word (the last one wins; none is `ac-dashboard.sh: --port needs a
// value`, exit 2), `-h`/`--help` prints this header on stdout, exit 0, and
// any other word is `ac-dashboard.sh: unknown arg: <word>`, exit 2. A port
// that is empty or holds anything but ASCII digits is `ac-dashboard.sh: --port
// must be a number`, exit 2. Each refusal is one line on stderr.
//
// FOREGROUND (no verb): one cheap check that the port is free, so a second
// launch on a busy port fails with a clear message instead of a stack trace -
// `ac-dashboard.sh: 127.0.0.1:<port> is already in use - a dashboard may
// already be running.` and `  stop it (Ctrl-C in its window, or
// ac-dashboard.sh stop) or pick another port: ac-dashboard.sh --port <N>` on
// stderr, exit 3. Otherwise `http://127.0.0.1:<port>` on stdout, and this
// process serves dashboard/app.ts (its dashboardMain, handed `--port <port>`)
// until interrupted: on-demand, Ctrl-C to stop. A relative AC_HOME from a
// caller cwd that has no name is `ERROR: the current directory cannot be
// resolved, so a relative AC_HOME cannot be either`, exit 1, after the URL.
// The foreground needs no AC_HOME.
//
// DAEMON verbs (captain-facing lifecycle; the dashboard is a standing service
// of a home, so the ceremony of keeping a terminal window open for it is
// gone - launchd stays out, this is one detached process + one pidfile). They
// need AC_HOME, the pidfile's home: unset or empty is `ac-dashboard.sh <verb>:
// AC_HOME must be set (the pidfile lives in its state/)`, exit 2. Every path
// is AC_HOME as given: <AC_HOME>/state (a spawned `mkdir -p`, whose failure
// ends the run with its status) holds dashboard.pid, dashboard.port and
// dashboard.log. The recorded pid is the pidfile's text (NULs dropped,
// trailing LFs cut; none when it is no regular file or cannot be read), and a
// verb with no --port acts on the port dashboard.port records, its text taken
// as the port unchecked.
//   start    when the recorded pid is RUNNING (below) and the port answers:
//            `already running (pid <pid>) - http://127.0.0.1:<port>`, exit 0.
//            Running on another recorded port: `already running (pid <pid>) -
//            http://127.0.0.1:<recorded> (restart --port <port> moves it)`, exit
//            0 - the pidfile holds one pid, so a second daemon would be
//            orphaned where no verb could stop it. Otherwise the pidfile goes,
//            a port that answers is `ac-dashboard.sh start: 127.0.0.1:<port> is
//            held by a FOREIGN process - pick another port` on stderr, exit 3,
//            and the daemon starts detached: `bun --no-env-file
//            <root>/dashboard/app.ts <caller cwd> --port <port>` from PATH in
//            the distro root, stdin /dev/null, stdout and stderr the log
//            (truncated), INT and QUIT ignored as a non-interactive shell's
//            background job had them; its pid goes to dashboard.pid and the
//            port to dashboard.port. Up to 20 waits of a spawned `sleep 0.25`
//            (its failure ends the run with its status) end once the port
//            answers or the daemon is gone. Still no answer: `ac-dashboard.sh
//            start: the daemon never answered on <port> - log tail:` and the
//            log's `tail -5` on stderr, the daemon TERMed, both files removed,
//            exit 1. Else `started (pid <pid>) - http://127.0.0.1:<port> (log:
//            <AC_HOME>/state/dashboard.log)`.
//   stop     a RUNNING pid is TERMed, then up to 20 waits of `sleep 0.25` while
//            `kill -0` still reaches it, then `kill -9` - whose failure ends the
//            run 1 with the files kept - then both files removed and `stopped
//            (pid <pid>)`. Not running (a stale pidfile included): both files
//            removed and `not running`. Exit 0 either way.
//   restart  stop, then start with no recorded pid or port - the reload after
//            a dashboard/ edit.
//   status   RUNNING and the port answers: `running (pid <pid>) -
//            http://127.0.0.1:<port>`, exit 0; else `not running`, exit 1. Never
//            repairs the files.
// RUNNING: the pid word is one `kill -0` reaches (bash's reading of a pid: C
// space before, a sign, decimal digits, space or TAB after; a process this
// user may not signal reads as gone) AND a spawned `ps -o command= -p <pid>`
// names <root>/dashboard/app.ts or <root>/bin/dashboard.ts - a recycled pid
// is never shot, and a daemon started before the dashboard entry left bin/
// still runs bin/dashboard.ts, which an upgrade must stop rather than orphan
// on its port. <root> is this checkout, physical. The port ANSWERS when
// `exec 3<>/dev/tcp/127.0.0.1/<port>` succeeds in a spawned `/bin/bash -p`
// (no BASH_ENV, no SHELLOPTS) - getaddrinfo reads the word, so `0800` is 800
// and a port past 65535 never answers.
// A relative AC_HOME from a caller cwd that has no name is `ERROR: the
// current directory cannot be resolved, so a relative AC_HOME cannot be
// either`, exit 1. Every line is written as bytes: a pid, a port or a path is
// printed as read.
//
// The server is stateless and read-only over fleet task/session state - it
// never locks or drives a backend - but has FOUR write surfaces:
// POST /api/config writes ONE
// allowlisted flat value-file under <home>/config/; POST /api/dispatch
// atomic-writes config/crew-dispatch.json, the table deciding which
// harness/model every crewmate spawns on; and POST /api/whiteboard
// normalize+atomic-writes (or RENAMEs - never onto an existing name - or
// DELETEs, two-step-confirmed in the UI) ONE
// Excalidraw scene under <home>/whiteboards/
// (the /whiteboard editor page's save - dashboard/app.ts's whiteboard block owns
// the contract, incl. its pinned-CDN editor runtime); and the review routes
// publish ONE fleet wake (kind=review, via ac_wake_publish - never a
// re-implemented grammar) when captain feedback lands on a session nobody is
// polling, or when the captain reopens an ended one - deduped until a poller
// returns, so a message can never fall silent yet never floods the spool. Otherwise it only shells out to
// ac-fleets.sh --json / ac-room.sh and reads flat config/state/records/slots
// files and discovered artifacts. Bun runs the TypeScript with no build step
// (zero-install; the host already has Bun).
//
// Exit: 0 on clean shutdown or a verb done; 1 a refusal above; 2 bad args; 3
// port busy. bun missing is the shim's own `ERROR: required tool not found:
// bun`, exit 1.
//
// ESCAPE HATCH. No script starts this entry. If a landed change breaks it, run
// the frozen original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-dashboard.sh "$o/bin/ac-dashboard.sh"
// then AC_HOME=<home> "$o/bin/ac-dashboard.sh" <verb> by hand. Each side
// recognises only a daemon whose cmdline names its OWN root, so a daemon one
// started is `not running` to the other: stop it with the one that started it,
// or kill the pid in <home>/state/dashboard.pid.
//
// AT PARITY (each pinned in the leg where a row can reach it):
// - A verb with no --port takes dashboard.port's text as the port unchecked.
// - start against a FOREIGN port removes the pidfile but leaves dashboard.port.
// - status never repairs a stale pidfile; stop does.
// - A port that is digits but no TCP port (`0`, `99999`) passes the check: the
//   probe never answers, and app.ts serves its default 8787 (no row: it would
//   bind 8787).
// - A pidfile whose pid this user may not signal reads not running, and stop
//   removes its files without a kill.
// - A `kill -9` that fails after a live `kill -0` ends stop or restart 1, both
//   files kept (no row: the window is a race).
//
// DIVERGENCES from the frozen original (the leg names each one a row can show):
// - USAGE HEADER: -h/--help prints this header, where the original printed
//   its own.
// - BUN: the shim's refusal comes before any argument is read, where the
//   original refused bad arguments first (exit 2) and then printed
//   `ac-dashboard.sh: bun not found (needed to run dashboard/app.ts)`, exit 4.
// - ONE PROCESS: the foreground serves inside this process, so its cmdline
//   names src/dashboard.ts where the original exec'd bun on dashboard/app.ts;
//   the DAEMON's cmdline is the original's, which RUNNING matches.
// - The port probe and the daemon's signal wrapper are spawned shells
//   (`/bin/bash -p`, and `/bin/sh -c 'trap "" INT QUIT; exec "$0" "$@"'`),
//   where the original probed in a subshell and set the ignore in its fork:
//   a /bin/bash that cannot start reads as no answer, and the daemon's SHLVL
//   reads one higher.
// - SHELL-OWN STDERR is not reproduced, the status kept: a log the daemon
//   cannot open starts nothing (the original's fork printed the shell's
//   redirection line and died), so the never-answered path follows with no pid
//   recorded; a pidfile or port file that cannot be written ends the run 1
//   silently; from a cwd that has no name the shell's own getcwd lines
//   (`shell-init:`, `chdir:`) are the shim's, fewer than the original's cds
//   printed.
// - HOME RESOLUTION: a relative AC_HOME from a caller cwd that has no name is
//   refused with the line above, where the verbs' `mkdir -p` failed in the
//   deleted directory (exit 1 both).
// - BYTES: argv and the environment arrive decoded, so a port, an argument or
//   an AC_HOME that is no UTF-8 is U+FFFD.
//
// CALLERS: operators by hand (README, docs/getting-started.md, the `ac
// dashboard` zsh example); src/review.ts and the rich-review skill name it as
// the precondition; tests/sh/ac-dashboard-daemon.test.sh, ac-review.test.sh and
// ac-review-reply.test.sh start and stop real daemons. No script runs it, and
// nothing parses what it prints but those tests.
import { closeSync, openSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { die, enterCaller, shellStatus, spawnShell, spawnShellSync, testInt } from "./lib.ts";

const ROOT = resolve(import.meta.dir, "..");
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const say = (s: string): void => {
  writeSync(1, Buffer.from(s, "latin1"));
};
const err = (s: string): void => {
  writeSync(2, Buffer.from(s, "latin1"));
};

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(0);
}

function refuse(msg: string): never {
  writeSync(2, `${msg}\n`);
  process.exit(2);
}

function run(argv: string[], stdout: "ignore" | "pipe" | number = "ignore", stderr: "ignore" | "inherit" = "inherit"): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(argv, { stdin: "inherit", stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: r && stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// A step the original ran under errexit: its failure ends the run with its status.
function must(argv: string[]): void {
  const st = run(argv).status;
  if (st !== 0) process.exit(st);
}

// `$(cat <file> 2>/dev/null || printf '')`.
function captured(file: string): string {
  try {
    return readFileSync(file, "latin1").replace(/\0/g, "").replace(/\n+$/, "");
  } catch {
    return "";
  }
}

// `kill -<sig> <word>`: the word read as bash's kill builtin reads a pid.
function kill(word: string, sig: string | number): boolean {
  const v = testInt(word);
  if (v === null) return false;
  try {
    process.kill(Number(v), sig);
    return true;
  } catch {
    return false;
  }
}

function running(pid: string): boolean {
  if (pid === "" || !kill(pid, 0)) return false;
  const cmd = run(["ps", "-o", "command=", "-p", u8(pid)], "pipe", "ignore").out.toString("latin1");
  return cmd.includes(b8(`${ROOT}/dashboard/app.ts`)) || cmd.includes(b8(`${ROOT}/bin/dashboard.ts`));
}

// A spawned bash, not a JS socket: getaddrinfo reads the word, and a port
// taken from dashboard.port is not checked for digits.
const answers = (port: string): boolean => run(["/bin/bash", "-p", "-c", 'exec 3<>"/dev/tcp/127.0.0.1/$0"', u8(port)], "ignore", "ignore").status === 0;

const sleepQuarter = (): void => must(["sleep", "0.25"]);

const { args, atCaller } = enterCaller(process.argv.slice(2));
let verb = "";
let i = 0;
if (["start", "stop", "restart", "status"].includes(args[0] ?? "")) verb = args[i++]!;
let port = "8787";
let portGiven = false;
while (i < args.length) {
  const a = args[i]!;
  if (a === "--port") {
    if (i + 1 >= args.length) refuse("ac-dashboard.sh: --port needs a value");
    port = b8(args[i + 1]!);
    portGiven = true;
    i += 2;
  } else if (a === "-h" || a === "--help") usage();
  else refuse(`ac-dashboard.sh: unknown arg: ${a}`);
}
if (!/^[0-9]+$/.test(port)) refuse("ac-dashboard.sh: --port must be a number");

const home = process.env.AC_HOME ?? "";
const relativeHomeless = (): boolean => !atCaller && home !== "" && !isAbsolute(home);
const NAMELESS = "the current directory cannot be resolved, so a relative AC_HOME cannot be either";

if (verb === "") {
  if (answers(port)) {
    err(`ac-dashboard.sh: 127.0.0.1:${port} is already in use - a dashboard may already be running.\n`);
    err("  stop it (Ctrl-C in its window, or ac-dashboard.sh stop) or pick another port: ac-dashboard.sh --port <N>\n");
    process.exit(3);
  }
  say(`http://127.0.0.1:${port}\n`);
  if (relativeHomeless()) die(NAMELESS);
  const { dashboardMain } = await import("../dashboard/app.ts");
  dashboardMain(["--port", u8(port)]);
} else {
  if (home === "") {
    writeSync(2, `ac-dashboard.sh ${verb}: AC_HOME must be set (the pidfile lives in its state/)\n`);
    process.exit(2);
  }
  if (relativeHomeless()) die(NAMELESS);
  const stateDir = `${home}/state`;
  const pidfile = `${stateDir}/dashboard.pid`;
  const portfile = `${stateDir}/dashboard.port`;
  const logfile = `${stateDir}/dashboard.log`;
  must(["mkdir", "-p", stateDir]);
  let isFile = false;
  try {
    isFile = statSync(pidfile).isFile();
  } catch {}
  let pid = isFile ? captured(pidfile) : "";
  let served = captured(portfile);
  if (!portGiven && served !== "") port = served;

  const doStop = (): void => {
    if (running(pid)) {
      kill(pid, "SIGTERM");
      for (let n = 0; n < 20 && kill(pid, 0); n++) sleepQuarter();
      if (kill(pid, 0) && !kill(pid, "SIGKILL")) process.exit(1);
      must(["rm", "-f", pidfile, portfile]);
      say(`stopped (pid ${pid})\n`);
    } else {
      must(["rm", "-f", pidfile, portfile]);
      say("not running\n");
    }
  };

  // The daemon's pid, "" when its log cannot be opened (nothing started).
  const launch = (): string => {
    let fd: number;
    try {
      fd = openSync(logfile, "w");
    } catch {
      return "";
    }
    try {
      const p = spawnShell(
        ["/bin/sh", "-c", 'trap "" INT QUIT; exec "$0" "$@"', "bun", "--no-env-file", `${ROOT}/dashboard/app.ts`, atCaller ? process.cwd() : "", "--port", u8(port)],
        { cwd: ROOT, stdin: "ignore", stdout: fd, stderr: fd },
      );
      p.unref();
      return String(p.pid);
    } catch {
      return "";
    } finally {
      closeSync(fd);
    }
  };

  const doStart = (): void => {
    if (running(pid) && answers(port)) {
      say(`already running (pid ${pid}) - http://127.0.0.1:${port}\n`);
      return;
    }
    if (running(pid) && served !== "" && served !== port) {
      say(`already running (pid ${pid}) - http://127.0.0.1:${served} (restart --port ${port} moves it)\n`);
      return;
    }
    must(["rm", "-f", pidfile]);
    if (answers(port)) {
      err(`ac-dashboard.sh start: 127.0.0.1:${port} is held by a FOREIGN process - pick another port\n`);
      process.exit(3);
    }
    pid = launch();
    try {
      writeFileSync(pidfile, `${pid}\n`, "latin1");
      writeFileSync(portfile, `${port}\n`, "latin1");
    } catch {
      process.exit(1);
    }
    for (let n = 0; n < 20; n++) {
      if (answers(port) || !kill(pid, 0)) break;
      sleepQuarter();
    }
    if (!answers(port)) {
      err(`ac-dashboard.sh start: the daemon never answered on ${port} - log tail:\n`);
      run(["tail", "-5", logfile], 2);
      kill(pid, "SIGTERM");
      must(["rm", "-f", pidfile, portfile]);
      process.exit(1);
    }
    say(`started (pid ${pid}) - http://127.0.0.1:${port} (log: ${b8(logfile)})\n`);
  };

  if (verb === "status") {
    if (running(pid) && answers(port)) {
      say(`running (pid ${pid}) - http://127.0.0.1:${port}\n`);
      process.exit(0);
    }
    say("not running\n");
    process.exit(1);
  }
  if (verb === "stop") doStop();
  else if (verb === "start") doStart();
  else {
    doStop();
    pid = "";
    served = "";
    doStart();
  }
  process.exit(0);
}
