// notify.ts - best-effort captain notification (the wedge-alarm surface). The
// entry is bin/ac-notify.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-notify.sh as the oracle the
// differential leg of tests/sh/ac-notify.test.sh holds this module to. Its one
// caller is src/room.ts's post, which calls notify() in-process on the
// blocked-by-captain edge (tests/sh/ac-notify-surface.test.sh pins that
// single call site).
//
// Usage: ac-notify.sh <title> <message...>
//
// <title> is the first argument, `agent-crew` when it is absent or empty; the
// message is every later argument joined by ONE space, empty ones kept. stdin
// is never read, stdout never written, and the exit is ALWAYS 0: a refusal of
// any channel is caught.
//
// The channel is config/wedge-alarm's first line, [:space:]-trimmed
// (configReadSoft: `auto` with no home, no file or a home cd cannot enter; a
// file that cannot be read is head(1)'s own line and the empty channel):
//   off            nothing
//   herdr          herdr notification show <title> --body <message> --sound none --position top-right
//   osascript      osascript -e 'display notification "<message>" with title "<title>"'
//                  (only `"` escaped, as `\"`; backslashes and newlines pass)
//   bell           stderr: BEL, then `<title>: <message>` and a newline
//   command:<cmd>  sh -c <cmd> (`sh` from PATH, as the bash ran it), with
//                  AC_NOTIFY_TITLE / AC_NOTIFY_MESSAGE added to its environment
//   anything else  auto: herdr when config/backend reads `herdr` (the default -
//                  AC_BACKEND is not consulted) and herdr is on PATH; else
//                  osascript when it is on PATH; else the bell
// Every spawned channel inherits stdin, has its stdout and stderr dropped, and
// a status other than 0 - or a binary that cannot start - rings the bell.
//
// DIVERGENCES from the original, named in the differential leg: argv and the
// environment arrive decoded, so a title or message byte that is not UTF-8
// reaches the bell, herdr, osascript and the hook as U+FFFD; the shell's own
// `cd:` lines for an AC_HOME it cannot enter are not reproduced; `herdr` and
// `osascript` are found by Bun.which, which skips a PATH file that is not
// executable where `command -v` took it. A PATH without bun is the shim's
// `ERROR: required tool not found: bun`, exit 1 - the one exit not 0, which no
// caller meets: the room calls notify() in-process.
import { writeSync } from "node:fs";
import { configReadSoft, enterCaller, spawnShellSync } from "./lib.ts";

const DROP = { stdin: "inherit", stdout: "ignore", stderr: "ignore" } as const;

function delivered(argv: string[]): boolean {
  try {
    return spawnShellSync(argv, DROP).exitCode === 0;
  } catch {
    return false;
  }
}

// stderr is where the bell line and a config file's head(1) line go: src/room.ts
// passes "ignore", because the bash room ran this entry with `2>/dev/null`.
export function notify(title: string, message: string, stderr: "inherit" | "ignore"): void {
  const ring = (): void => {
    if (stderr === "inherit") writeSync(2, Buffer.from(`\x07${title}: ${message}\n`, "utf8"));
  };
  const herdr = (): boolean => delivered(["herdr", "notification", "show", title, "--body", message, "--sound", "none", "--position", "top-right"]);
  const esc = (s: string): string => s.replace(/"/g, '\\"');
  const osascript = (): boolean => delivered(["osascript", "-e", `display notification "${esc(message)}" with title "${esc(title)}"`]);
  const channel = configReadSoft("wedge-alarm", "auto", stderr);
  if (channel === "off") return;
  if (channel === "herdr") {
    if (!herdr()) ring();
  } else if (channel === "osascript") {
    if (!osascript()) ring();
  } else if (channel === "bell") ring();
  else if (channel.startsWith("command:")) {
    const saved = [process.env.AC_NOTIFY_TITLE, process.env.AC_NOTIFY_MESSAGE];
    process.env.AC_NOTIFY_TITLE = title;
    process.env.AC_NOTIFY_MESSAGE = message;
    const ok = delivered(["sh", "-c", channel.slice("command:".length)]);
    for (const [k, v] of [["AC_NOTIFY_TITLE", saved[0]], ["AC_NOTIFY_MESSAGE", saved[1]]] as const) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    if (!ok) ring();
  } else if (configReadSoft("backend", "herdr", stderr) === "herdr" && Bun.which("herdr")) {
    if (!herdr()) ring();
  } else if (Bun.which("osascript")) {
    if (!osascript()) ring();
  } else ring();
}

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  notify(args[0] || "agent-crew", args.slice(1).join(" "), "inherit");
  process.exit(0);
}
