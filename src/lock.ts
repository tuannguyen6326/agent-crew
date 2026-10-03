// lock.ts - per-home chief session lock: one fleet-driving session at a time.
// The entry is bin/ac-lock.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-lock.sh as the oracle the
// differential leg of tests/sh/ac-lock.test.sh holds this module to.
//
// Usage: ac-lock.sh acquire | status | release
//
// The lock file state/.session-lock records which HARNESS process owns this
// home, one key=value per line: `pid=<n>`, `since=<ISO timestamp>`, and
// `cmd=<the pid's command at acquire time>` (absent when unreadable) - the
// IDENTITY fingerprint that lets a later check tell a still-live holder apart
// from an unrelated process pid reuse handed the same number (holderAlive owns
// the contract: PID REUSE below). The format is byte-frozen: bin/ac-watch.sh,
// bin/ac-watch-autoarm.sh, bin/ac-turnend-guard.sh, src/fleets.ts and
// dashboard/app.ts read the file directly, and any bash ac-lock.sh still
// running against the same home (an older bin/) shares the whole protocol -
// the file, the temp name `<lock>.tmp.<pid>`, the reap dir.
//
// BEFORE THE VERB: the state dir is resolved (`state/` minted under the
// physical AC_HOME) - a homeless run prints `ERROR: AC_HOME is not set ...`
// exit 1 for EVERY argv, usage and AC_SCOPE included; the harness regex is
// AC_LOCK_HARNESS_RE when non-empty, else HARNESS_RE (src/lib.ts, the copy of
// bin/ac-harness.sh's AC_HARNESS_RE: `claude|codex|opencode|pi|cursor-agent`).
// No verb, `-h`, anything unknown: `ERROR: usage: ac-lock.sh acquire | status |
// release` exit 1. Extra arguments are ignored. stdin is never read.
//
// THE ANCESTRY WALK (selfPid) - the harness pid is found by walking this
// process's ancestry for the long-lived harness process, never the transient
// tool-call subshell that ran this entry, and never a rotating daemon worker.
// AC_LOCK_PID, when non-empty, is the answer as given, UNVALIDATED (`abc` is
// recorded as `pid=abc` and reads stale). Otherwise, from this process's own
// pid, while the pid is a run of digits greater than 1 (anything else ends the
// walk silently - a `ps` that failed, ` 0` for pid 1's parent, a stub's junk):
//   - `ps -o command= -p <pid>` is spawned from PATH with exactly that argv
//     (stderr dropped, stdout the bash `$(...)` kept: NULs dropped, trailing
//     LFs stripped); an empty answer classifies nothing;
//   - `(^|[ /])(<re>) bg-[a-z0-9-]+( |$)` - a daemon WORKER (`claude bg-spare
//     ...`, `claude bg-pty-host ...`): skipped, neither a match nor a stable
//     candidate, so a later tool call under a DIFFERENT worker resolves the
//     same identity. ANCHORED to the worker token directly after the harness
//     token - a real harness whose argv merely CONTAINS `bg-spare` elsewhere
//     (a path segment) is still matched;
//   - `(^|[ /])(<re>)( |$)` - a HARNESS: remembered and the walk goes on; the
//     LAST match wins = the OUTERMOST harness ancestor, because a Claude Stop
//     hook fires levels below the lock-owning process with same-session
//     workers in between, and first-match handed ownership checks the wrong
//     pid (a single-match chain is unchanged);
//   - else the first word's basename (`${cmd%% *}`, `${base##*/}` - parameter
//     expansion, so a login shell's `-zsh` is read as spelled, where
//     basename(1) would have parsed it as flags): bash sh zsh dash fish -bash
//     -sh -zsh login script are skipped; the first other pid that is not this
//     process is the STABLE fallback;
//   - `ps -o ppid= -p <pid>` (same argv discipline, spaces removed) names the
//     next pid.
// The regex is applied as `grep -E` applied it: a pattern of plain
// alternatives (`[A-Za-z0-9_-]` words joined by `|`) is a JS RegExp, anything
// else - an AC_LOCK_HARNESS_RE carrying a POSIX class (`[[:alpha:]]+`) or
// other ERE-only syntax - is handed to a spawned `grep -qE` with the command
// line on stdin, so the classification stays grep's (its stderr for an invalid
// pattern passes through, as it did).
// THE OWN-PID SKIP (a named divergence that preserves the bash RESULT): the
// walk starts at this process, whose own command line the bash classified too
// - `bash <path>/ac-lock.sh <verb>`, a shell, never a match. The port's own
// line is `bun --no-env-file <root>/src/lock.ts <caller cwd> <verb>`, which
// DOES match `(^|[ /])(pi)( |$)` for a caller cwd ending in `/pi`, so the
// match/worker arms never see this process's own command; it was already no
// stable candidate (`[ "$pid" != "$$" ]`). Only a PATH `ps` stub answering
// this process's own pid with a harness line could tell the two apart.
// No match: `WARN: no harness ancestor matched (<re>) - locking with nearest
// stable ancestor pid <stable|PPID>` on stderr and the stable pid, else this
// process's parent pid.
//
// RE-ENTRANCY (selfOwns): the recorded holder IS this session when it equals
// the detected pid (string compare: `07` is not `7`) or - only when
// AC_LOCK_PID is unset - appears anywhere in this process's own ancestor chain
// (`ps -o ppid=` walked from this pid, itself included). A tool-call subshell
// whose argv carries a harness token (`ac-spawn.sh ... --harness claude`)
// matches the regex itself, so the walk answers with that transient shell and
// the session's OWN lock would otherwise read as foreign.
//
// PID REUSE (holderAlive): a holder is alive when pidAlive says so (a canonical
// positive pid that exists; EPERM is alive) AND, when the file carries `cmd=`,
// `ps -o command= -p <pid>` now equals it byte for byte. A missing fingerprint
// or an unreadable current command reads ALIVE - the safe direction: a false
// "still held" only wedges acquire, a false "stale" risks two chiefs on one
// home.
//
// acquire:
//   - AC_SCOPE non-empty (scoped roomchief session): stdout `lock: skipped -
//     scoped session (AC_SCOPE=<v>) never owns the home`, exit 0, nothing
//     touched, the walk never runs.
//   - me = selfPid; mycmd = `ps -o command= -p <me>` ("" when unreadable).
//     The temp `<lock>.tmp.<pid>` is written whole - `pid=<me>\nsince=<iso>\n`
//     plus `cmd=<mycmd>\n` when non-empty, <iso> from date(1) through iso() -
//     so the lock is never observed pid-less; it is removed on every return.
//     EXCLUSIVE (a named divergence): the temp is created `wx`, the next name
//     (`<lock>.tmp.<pid>.<n>`) on EEXIST - the bash wrote THROUGH a path
//     already at that name, a planted symlink's target included.
//   - THE ATOMIC CLAIM: link(2) of the temp onto the lock path; it fails with
//     EEXIST when the target exists, so exactly one racer wins and the winner
//     is never overwritten. While it fails (ANY failure):
//       holder/since read (LAST `pid=`/`since=` wins; an unreadable lock is
//       `WARN: cannot read meta file <f>` and exit 1 right there, the temp left
//       behind - the bash's bare assignment under errexit, its RETURN trap
//       never fired);
//       selfOwns(holder, me) -> stdout `lock: already held by this session
//       (pid <holder> since <since>)` RAW (`since )` when the file has no
//       since=), exit 0;
//       holder non-empty and holderAlive -> stderr `ERROR: another chief
//       session owns this home (pid <holder> since <since|?>)` exit 2;
//       else attempt n+1; past 1000 -> stderr `ERROR: session lock did not
//       settle after 1000 attempts (last holder pid <holder|?>) - leaked reap
//       dir? remove <lock>.reap` exit 2 - a pid-less lock (no `pid=` line, an
//       empty file, a DIRECTORY at the path) spins all 1000 attempts to that
//       line, as a count, never a wait;
//       the reap gate: `mkdir <lock>.reap` succeeding makes this process the
//       sole reaper - it re-reads pid/since (the same unreadable exit, the
//       reap dir then leaked too), and when the holder is non-empty and not
//       holderAlive prints `lock: recovering stale lock (pid <h> alive but a
//       DIFFERENT process now - pid reuse, held since <s|?>)` or `lock:
//       recovering stale lock (pid <h> dead, held since <s|?>)` and removes
//       the lock; then `rmdir <lock>.reap`. A pre-existing reap dir (a reaper
//       SIGKILLed between its mkdir and rmdir) makes every attempt skip the
//       reap: stale recovery REFUSES with the 1000-attempt line until the dir
//       is removed by hand - fail-CLOSED, never two holders.
//   - read-back: the on-disk pid must equal me, else stderr `ERROR: lost the
//     session-lock race after claim (on disk pid <h|?>, this session pid <me>)`
//     exit 2; else stdout `lock: acquired (pid <me>)` exit 0.
// status (always exit 0 by contract, but see the unreadable case):
//   no regular file at the path (a directory reads so too) -> `unlocked`;
//   holder non-empty and holderAlive -> `held pid=<h> since=<since|?>`; else
//   `stale pid=<h|?> since=<since|?>`. An unreadable lock: the WARN and exit 1.
// release:
//   no regular file -> `lock: not held` exit 0; holder non-empty and
//   holderAlive: me = selfPid (may WARN), not selfOwns -> stderr `ERROR: only
//   the holder releases - held by live pid <h>, this session is pid <me>` exit
//   2; else (dead OR reused) stdout `lock: clearing stale lock (pid <h|?>
//   dead)` - `dead` for a reused pid too; then the lock is removed and `lock:
//   released` exit 0. An unreadable lock: the WARN and exit 1.
//
// Exit codes: 0 ok/skipped, 1 usage (and the homeless and unreadable-lock
// refusals), 2 refused. Every pid, since and cmd value is bytes in, bytes out.
//
// CALLERS, audited with the port (the entry now needs bun on PATH; without it
// the shim prints `ERROR: required tool not found: bun` and exits 1):
//   - bin/ac-session-start.sh (its lock step) - rc 2 is the READ-ONLY banner, any other
//     non-zero `WARN: session lock acquire failed (rc=N) - continuing unlocked`:
//     a bun-less session start runs UNLOCKED with one WARN, already fail-soft.
//   - bin/ac-watch.sh (the fleet watcher's owner gate) - rc 2 refuses the arm
//     with `refused: fleet watcher not armed - another session owns this
//     home`; any OTHER rc used to print that same refusal, so a bun-less run
//     read as a foreign owner - dishonest. It now arms WITHOUT the owner gate
//     after `WARN: session lock acquire failed (rc=N, ac-lock.sh) - arming
//     without the owner gate`, the owner beacon emptied (no remote poller
//     without a known owner), and a `status` read that fails after a good
//     acquire is treated the same way (`session lock status failed ...`);
//     pinned by tests/sh/ac-watch.test.sh with PATH bun stubs.
//   - bin/ac-sessionstart-nudge.sh (a wired SessionStart hook) runs
//     `status 2>/dev/null` and stays silent only on `held*`: a bun-less status
//     answers nothing, so the nudge prints - fail-open, unchanged, but the
//     hook is now transitively bun-dependent (the jev/compact-advise class).
//
// NAMED DIVERGENCES from the frozen original, pinned in the differential leg:
// the own-pid skip and the exclusive temp (above); an AC_HOME that cannot be
// entered is `ERROR: AC_HOME is not a readable directory: <h>` where the bash
// printed its own `cd:` line (the HOME RESOLUTION ruling), same exit 1.
import { linkSync, mkdirSync, rmdirSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
import { die, enterCaller, HARNESS_RE, iso, metaGet, pidAlive, stateDir, warn } from "./lib.ts";

const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const native = (b: string): string => Buffer.from(b, "latin1").toString("utf8");
const out = (s: string): void => {
  writeSync(1, Buffer.from(`${s}\n`, "latin1"));
};
const err = (s: string): void => {
  writeSync(2, Buffer.from(`${s}\n`, "latin1"));
};

const { args } = enterCaller(process.argv.slice(2));
const verb = args[0] ?? "";
const lockFile = `${stateDir()}/.session-lock`;
const harnessRe = process.env.AC_LOCK_HARNESS_RE || HARNESS_RE;
const self = String(process.pid);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "fish", "-bash", "-sh", "-zsh", "login", "script"]);

// `$(ps ... 2>/dev/null || true)`: whatever ps printed, failed or not.
function ps(...a: string[]): string {
  try {
    const r = Bun.spawnSync(["ps", ...a], { stdin: "inherit", stdout: "pipe", stderr: "ignore", env: process.env });
    return r.stdout.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
  } catch {
    return "";
  }
}

const ppidOf = (pid: string): string => ps("-o", "ppid=", "-p", native(pid)).replace(/ /g, "");

// `[ "$pid" -gt 1 ] 2>/dev/null`: test's integer grammar (blanks, a sign,
// digits, in range), false for anything else.
function gt1(s: string): boolean {
  const m = /^[ \t\n]*([+-]?[0-9]+)[ \t\n]*$/.exec(s);
  if (!m) return false;
  const v = BigInt(m[1]!);
  return v > 1n && v <= 9223372036854775807n;
}

// Plain alternatives are the same language in ERE and JS; anything else is
// grep's to read.
const PLAIN_RE = /^[A-Za-z0-9_-]+(\|[A-Za-z0-9_-]+)*$/;
function harnessLine(cmd: string, worker: boolean): boolean {
  const pat = `(^|[ /])(${harnessRe})${worker ? " bg-[a-z0-9-]+" : ""}( |$)`;
  if (PLAIN_RE.test(harnessRe)) return new RegExp(pat, "m").test(native(cmd));
  try {
    const r = Bun.spawnSync(["grep", "-qE", pat], { stdin: Buffer.from(`${cmd}\n`, "latin1"), stdout: "ignore", stderr: "inherit", env: process.env });
    return r.exitCode === 0;
  } catch {
    return false;
  }
}

function selfPid(): string {
  const pinned = process.env.AC_LOCK_PID;
  if (pinned) return bytes(pinned).replace(/\0/g, "").replace(/\n+$/, "");
  let pid = self;
  let stable = "";
  let match = "";
  while (pid !== "" && gt1(pid)) {
    // The own-pid skip (header): the bash read `bash <path> <verb>` here, a shell.
    if (pid !== self) {
      const cmd = ps("-o", "command=", "-p", native(pid));
      if (cmd !== "") {
        if (harnessLine(cmd, true)) {
          // A rotating worker: neither the harness nor a stable candidate.
        } else if (harnessLine(cmd, false)) {
          match = pid;
        } else {
          const base = cmd.split(" ")[0]!.replace(/^.*\//, "");
          if (!SHELLS.has(base) && stable === "") stable = pid;
        }
      }
    }
    pid = ppidOf(pid);
  }
  if (match !== "") return match;
  const fallback = stable || String(process.ppid);
  warn(Buffer.from(`no harness ancestor matched (${bytes(harnessRe)}) - locking with nearest stable ancestor pid ${fallback}`, "latin1"));
  return fallback;
}

// A read the bash made in a bare assignment under errexit: metaGet has warned,
// the run ends with status 1 - no finally runs, so an acquire's temp stays, as
// the original's RETURN trap never fired there.
function meta(key: string): string {
  try {
    return metaGet(lockFile, key);
  } catch {
    process.exit(1);
  }
}

function holderAlive(pid: string): boolean {
  if (!pidAlive(pid)) return false;
  let recorded = "";
  // Inside a condition the bash's assignment slept through the status; the
  // WARN is printed and the holder reads alive.
  try {
    recorded = metaGet(lockFile, "cmd");
  } catch {}
  if (recorded === "") return true;
  const current = ps("-o", "command=", "-p", native(pid));
  if (current === "") return true;
  return current === recorded;
}

function selfOwns(holder: string, me: string): boolean {
  if (holder === "") return false;
  if (holder === me) return true;
  if (process.env.AC_LOCK_PID) return false;
  let pid = self;
  while (pid !== "" && gt1(pid)) {
    if (pid === holder) return true;
    pid = ppidOf(pid);
  }
  return false;
}

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function doAcquire(): number {
  const scope = process.env.AC_SCOPE;
  if (scope) {
    out(`lock: skipped - scoped session (AC_SCOPE=${bytes(scope)}) never owns the home`);
    return 0;
  }
  const me = selfPid();
  const mycmd = ps("-o", "command=", "-p", native(me));
  const reapDir = `${lockFile}.reap`;
  const body = Buffer.from(`pid=${me}\nsince=${iso()}\n${mycmd === "" ? "" : `cmd=${mycmd}\n`}`, "latin1");
  let tmp = `${lockFile}.tmp.${process.pid}`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, body, { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      tmp = `${lockFile}.tmp.${process.pid}.${i}`;
    }
  }
  try {
    let attempts = 0;
    for (;;) {
      try {
        linkSync(tmp, lockFile);
        break;
      } catch {}
      const holder = meta("pid");
      const since = meta("since");
      if (selfOwns(holder, me)) {
        out(`lock: already held by this session (pid ${holder} since ${since})`);
        return 0;
      }
      if (holder !== "" && holderAlive(holder)) {
        err(`ERROR: another chief session owns this home (pid ${holder} since ${since || "?"})`);
        return 2;
      }
      attempts++;
      if (attempts > 1000) {
        err(`ERROR: session lock did not settle after 1000 attempts (last holder pid ${holder || "?"}) - leaked reap dir? remove ${bytes(reapDir)}`);
        return 2;
      }
      let reaper = false;
      try {
        mkdirSync(reapDir);
        reaper = true;
      } catch {}
      if (!reaper) continue;
      const h2 = meta("pid");
      const s2 = meta("since");
      if (h2 !== "" && !holderAlive(h2)) {
        if (pidAlive(h2)) out(`lock: recovering stale lock (pid ${h2} alive but a DIFFERENT process now - pid reuse, held since ${s2 || "?"})`);
        else out(`lock: recovering stale lock (pid ${h2} dead, held since ${s2 || "?"})`);
        rmSync(lockFile, { force: true });
      }
      try {
        rmdirSync(reapDir);
      } catch {}
    }
    const holder = meta("pid");
    if (holder !== me) {
      err(`ERROR: lost the session-lock race after claim (on disk pid ${holder || "?"}, this session pid ${me})`);
      return 2;
    }
    out(`lock: acquired (pid ${me})`);
    return 0;
  } finally {
    rmSync(tmp, { force: true });
  }
}

function doStatus(): number {
  if (!isFile(lockFile)) {
    out("unlocked");
    return 0;
  }
  const holder = meta("pid");
  const since = meta("since");
  if (holder !== "" && holderAlive(holder)) out(`held pid=${holder} since=${since || "?"}`);
  else out(`stale pid=${holder || "?"} since=${since || "?"}`);
  return 0;
}

function doRelease(): number {
  if (!isFile(lockFile)) {
    out("lock: not held");
    return 0;
  }
  const holder = meta("pid");
  if (holder !== "" && holderAlive(holder)) {
    const me = selfPid();
    if (!selfOwns(holder, me)) {
      err(`ERROR: only the holder releases - held by live pid ${holder}, this session is pid ${me}`);
      return 2;
    }
  } else out(`lock: clearing stale lock (pid ${holder || "?"} dead)`);
  rmSync(lockFile, { force: true });
  out("lock: released");
  return 0;
}

switch (verb) {
  case "acquire":
    process.exit(doAcquire());
  case "status":
    process.exit(doStatus());
  case "release":
    process.exit(doRelease());
  default:
    die("usage: ac-lock.sh acquire | status | release");
}
