// guard.ts - the warn-only situational advisory that rides along at the start
// of fleet commands. The entry is bin/ac-guard.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, and the
// bash original it replaced stays frozen at tests/fixtures/ac-guard.sh as the
// oracle the differential leg of tests/sh/ac-guard.test.sh holds this module
// to.
//
// Usage: ac-guard.sh
//   Arguments are never read (`-h` and `bogus x` behave as none); stdin is
//   never read by the guard, and stdout is never written. The warnings go to
//   stderr as ONE write, so the host command's stdout stays clean for
//   pipelines and its own lines never interleave inside the block.
//
// Every warning is scoped to the session it rides in: the guard runs inside
// roomchief sessions too, so it nudges each one about the wakes and the
// watcher that are ITS OWN. <scope> is AC_SCOPE ("" when unset or empty); a
// LEGAL scope is one [A-Za-z0-9_-] path segment (wakeScopeOk, read per the
// text - bash 3.2's range let `é` through under a UTF-8 locale).
//
// IN ORDER, each step only reading (the stamp is the one write):
// 0. The backend name, as sourcing ac-backend.sh checked it (backendName's
//    soft rung, src/lib.ts): AC_BACKEND, config/backend, the first word of
//    <AC_FLEET_STATE less one trailing slash>/../config/backend, herdr; an
//    unreadable rung reads as none. Any name but herdr or orca exits 1 with
//    NOTHING printed and nothing minted (W1, a wart of the original kept: its
//    header promised 0).
// 1. The home: AC_HOME through physicalDir (`cd && pwd -P`, a relative one
//    from the caller's cwd). Unset, empty or not enterable: exit 0 silently.
//    <state> is <home>/state, minted (mkdir -p; a failure is silent and the
//    run goes on with that path).
// 2. WATCHER-DOWN when watcherDown(<state>, <scope>) (src/lib.ts, the twin of
//    ac_watcher_down): crew in flight -
//    crewMetas(<state>, "verify", "self"), so a roomchief, a crewdeputy, a
//    kind-less meta and `kind=self\r` count (W8), a dangling FIRST *.meta
//    hides every meta (W7) and a directory named *.meta ends the list there
//    with awk's own two lines on stderr (W6) - and the scope's beacon
//    (.last-watcher-beat.<scope> for a legal scope, else the fleet's; absent,
//    0, zero-padded or not digits all read 0) older than the grace:
//    `$(( <clock> - <beat> ))` `[ -gt ]` AC_GUARD_GRACE (unset or empty:
//    300). <clock> is ac_now's text (nowRaw, src/lib.ts): an exported
//    non-empty EPOCHSECONDS less trailing LFs (bash 3.2 has no such builtin,
//    so the variable was the clock - W11, kept), else `date +%s`. Line: `WATCHER-DOWN: crew in flight with no live watcher - arm
//    bin/ac-watch.sh`; token ` watcher-down`.
// 3. QUEUED WAKES when a store this session drains holds a record (a non-dot
//    entry `[ -e ]` finds - a subdirectory counts; a dotfile, a dangling link
//    or a spool that is a plain file do not): a non-empty <scope> asks only
//    its own spool (wakePending), so a MALFORMED scope asks the fleet's and
//    never the orphans (W5); the fleet asks state/.wake-spool, then every
//    ORPHAN family spool (wakeOrphanPending): each state/.wake-spool.<legal>
//    directory (a symlinked one counts) in byte order, whose roomchief is
//    probed first (roomchiefLive - below) and whose records are looked at only
//    when it is not live; the first orphan holding one answers. Line:
//    `QUEUED WAKES: run bin/ac-wake-drain.sh`; token ` wake-queue`.
// 4. <anchor> is AC_GUARD_ROOT (unset or empty: the root this module was
//    STARTED in - process.cwd() before enterCaller, the physical parent of
//    the bin/ the shim ran from; a lab copy's bin/ names its own root, never
//    import.meta.dir's distro checkout). <root> is <anchor>, replaced when
//    `git -C <anchor> rev-parse --git-dir` succeeds by repoRoot(<anchor>) -
//    the main worktree's root as git spells it (physical: /tmp/x answers
//    /private/tmp/x), "" when that git fails.
// 5. TANGLE when <root> is non-empty and a repo: <cur> is `git -C <root>
//    symbolic-ref --quiet --short HEAD`'s output, `detached HEAD` appended
//    when it fails; <def> defaultBranch(<root>) - origin/HEAD's target even
//    with no local ref, else main, else master, else the checked-out branch
//    (a repo with neither main nor master never TANGLEs). <cur> != <def>:
//    `TANGLE: distro checkout on '<cur>', not '<def>' - fleet tooling may be
//    mid-edit`; token ` tangle`.
// 6. WIP-TOOLING when <anchor> and <root> are non-empty and differ as STRINGS
//    (any other spelling of the primary - a trailing slash, a symlink, a
//    /tmp path, a subdirectory - fires it: W10): `WIP-TOOLING: running bin/
//    from '<anchor>', not the primary '<root>' - this may be a crewmate's
//    leased worktree copy`; token ` wip-tooling`.
// 7. DISTRO-LAG when <anchor> is a repo: <n> is `git -C <anchor> rev-list
//    --count HEAD..refs/heads/<defaultBranch(anchor)>` ("" when git fails - a
//    missing local ref); silent for "", 0 or anything not all digits, else
//    `DISTRO-LAG: running tree is <n> behind <def>`; token ` distro-lag`.
// 8. THE STAMP: state/.guard-stamp.<scope> for a legal scope, else
//    state/.guard-stamp. No warning: `rm -f <stamp>` (spawned - a directory
//    there is rm's own `is a directory` line, W9), exit 0. Else <sig> is the
//    tokens in the order above, each with its LEADING space (` watcher-down
//    wake-queue tangle wip-tooling distro-lag`); the stamp's last `sig=` and
//    `at=` are read as ac_meta_get's awk read them (last key wins, cut at a
//    NUL; an unreadable stamp reads as none, silently), an `at=` that is
//    empty or not all digits reads 0, and <now> is the clock's text. The SAME
//    <sig> with `$(( <now> - <at> ))` `[ -lt ]` AC_GUARD_QUIET (unset or
//    empty: 60) exits 0 printing nothing and leaving the stamp alone - the
//    window runs from the FIRST print. Else the warnings, LF-terminated in
//    the order 2, 3, 5, 6, 7, go to stderr in one write, then the stamp gets
//    `sig=<sig>` and `at=<now>` through metaSet (each failure silent):
//    `sig= watcher-down\nat=<epoch>\n`. A reader that has closed stderr ends
//    the run at the write, 141, no stamp - SIGPIPE ended the shell there.
// EXIT: 0, but 1 at step 0 and 141 at a closed reader.
//
// THE NUMBERS are read as bash 3.2 read them (src/lib.ts): the grace and the
// quiet window by testInt - `[ -gt ]`'s strtoimax grammar: C isspace before,
// one sign, decimal digits, blanks after, int64 (` 600 `, `+600`, `010` is
// ten; `0x10`, `600abc`, `1e3`, 2^63 are no number: the test is false - no
// WATCHER-DOWN, no suppression; W2, W3); the clock's text and the stamp's
// digits by arithValue - `$(( ))` over one operand: a leading 0 is OCTAL
// (`at=0012` is ten, `0099` and a clock reading `12abc` are an evaluation
// error), 0x
// hex, base#digits, the 64-bit wrap (`at=99999999999999999999` suppresses),
// empty is 0 (W4). An evaluation error discards the command it stood in, as
// the shell did: no WATCHER-DOWN, or no suppression. An identifier (a clock
// reading `garbage`) is set -u's abort: exit 0, nothing printed, no stamp
// written (W12).
//
// SPAWNED, with the original's argv: git per call (`-C <d> rev-parse
// --git-dir`, `rev-parse --path-format=absolute --git-common-dir`,
// `symbolic-ref --quiet --short HEAD`, defaultBranch's `symbolic-ref --quiet
// refs/remotes/origin/HEAD` / `show-ref --verify --quiet refs/heads/<b>` /
// `symbolic-ref --short HEAD`, `rev-list --count HEAD..refs/heads/<def>`;
// stdin the caller's, stderr dropped); awk once (crewMetas' program, stderr
// passed through); `date +%s`, unless EPOCHSECONDS is the clock, in step 2
// when crew is in flight and again in step 8 when a print may follow (stdin
// and stderr the caller's); `rm -f`;
// metaSet's `mv`. Per orphan candidate WITH a chief meta, roomchiefLive
// probes backend_window_alive <fam>-chief through backendCall (src/lib.ts,
// the twin of bin/ac-backend.sh's drivers) with AC_BACKEND set to the meta's
// backend= (herdr when none) for that call alone, stdin, stdout and stderr
// dropped; only status 0 is live (1 gone, 2 unreadable, a refused name such
// as `backend=tmux` - every other answer is an orphan). It spawns awk for the
// pane handle, then `herdr pane get|pane list|status server --json` (with
// `--session <s>` and HERDR_SESSION=<s> for a configured session, each under
// the per-RPC ceiling that kills its process group: a hung herdr costs up to
// three AC_HERDR_RPC_TIMEOUTs) or `orca terminal show --terminal <h> --json`
// / `orca status --json`, with jq.
//
// DIVERGENCES from the original, named in the differential leg:
// - ORDER: the metas and the family spools are walked in byte order; bash
//   3.2's glob followed libc collation under a UTF-8 locale (the leg runs
//   the oracle under LC_ALL=C).
// - THE ORPHAN SCAN RACE: the original probed liveness in a process
//   substitution that ran AHEAD of the reader and outlived the run - past
//   the answering orphan it went on probing (until its next orphan line hit
//   the closed pipe), after the guard had exited. The port stops at the
//   answer.
// - THE PROBE'S STDIN: the original's probe ran in a subshell whose stdin
//   was the family-list pipe. The herdr CLI, backgrounded there, got
//   /dev/null on both sides; the orca CLI, in a command substitution, got
//   the pipe - an orca that reads stdin swallowed the families after it, and
//   they went unheard. The port's driver children read /dev/null.
// - W13: an unreadable stamp - the original printed and rewrote it as a
//   fresh 0644 file; the port prints and leaves it (metaSet refuses to
//   rewrite what it cannot read), so it prints on every run.
// - Shell-own stderr is not reproduced: `[: integer expression expected`,
//   the arithmetic error and `unbound variable` lines (W2-W4, W12), a
//   missing tool's `command not found`, and mv's own line in the one case
//   metaSet's mv fails (a directory planted at the temp's name inside a
//   stamp directory) - the original's `2>/dev/null` dropped it.
// - A clock text that is an EXPRESSION (`1+1`, `12 abc`) reads as the
//   evaluation error where bash evaluated it (arithValue's model is one
//   operand).
// - Bytes: AC_GUARD_ROOT, AC_GUARD_GRACE/QUIET and paths arrive decoded, so a
//   byte that is not UTF-8 (a lone 0xA0, isspace under a UTF-8 locale) is
//   U+FFFD here; a default branch name that is not UTF-8 prints as U+FFFD.
// - A relative AC_HOME or AC_GUARD_ROOT from a caller cwd bun cannot name is
//   homeless / no repo, never resolved inside the distro root bun started
//   in: a deleted cwd failed the original's cd too, a cwd whose name ends in
//   a backslash it entered. The backend rung (backendName) still reads a
//   relative AC_HOME from that root.
//
// CALLERS, all fail-soft: five bash entries run `[ ! -x
// "$(dirname "$0")/ac-guard.sh" ] || "$(dirname "$0")/ac-guard.sh" || true` -
// bin/ac-send.sh's shim (src/send.ts spawns this shim), bin/ac-peek.sh's
// shim (src/peek.ts spawns this shim),
// bin/ac-spawn.sh, bin/ac-review-diff.sh's shim (src/review-diff.ts spawns
// this shim unless --no-guard) and
// bin/ac-merge-local.sh - so a failure here (exit 1 at step 0, or the shim's
// `ERROR: required tool not found: bun` on a bun-less PATH) is only stderr
// noise on the host command, never its exit. Transitively the Stop hook
// bin/ac-compact-advise.sh (its --send runs ac-send.sh) and src/promote.ts
// (it spawns ac-send.sh) reach it the same way, behind src/send.ts's ignored
// status - ac-send.sh is itself a bun shim, so that hook's --send depends on
// bun through it anyway (src/send.ts's header). A
// crewmate running ac-merge-local.sh from its own pane needs bun on that
// PATH for the advisory to print. The stamp is shared with any bash guard
// (an older bin/, a deputy home) on the same state/, so its bytes are frozen.
import { accessSync, constants, mkdirSync, writeSync } from "node:fs";
import { isAbsolute } from "node:path";
import {
  arithValue,
  backendName,
  defaultBranch,
  enterCaller,
  metaGet,
  metaSet,
  nowRaw,
  physicalDir,
  repoRoot,
  shellStatus,
  spawnShellSync,
  testInt,
  wakeOrphanPending,
  wakePending,
  wakeScopeOk,
  watcherDown,
} from "./lib.ts";

const started = process.cwd();
const { atCaller } = enterCaller(process.argv.slice(2));
backendName(true);

// Lines are bytes: git's output is read as latin1, a decoded name joins it as
// its UTF-8 bytes.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const subst = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");
// A caller cwd bun could not enter left this process in the distro root,
// where a relative path would name the checkout itself.
const reachable = (p: string): boolean => atCaller || isAbsolute(p);

// set -u's abort ended the original where it struck, with the status of the
// last command run - 0 at both places it can strike.
function aborted(e: unknown): never {
  if ((e as { code?: string }).code === "EUNBOUND") process.exit(0);
  throw e;
}

const h = process.env.AC_HOME ?? "";
const home = h !== "" && reachable(h) ? physicalDir(h) : null;
if (home === null) process.exit(0);
const sd = `${home}/state`;
try {
  mkdirSync(sd, { recursive: true });
} catch {}
const quiet = process.env.AC_GUARD_QUIET || "60";
const scope = process.env.AC_SCOPE || "";

let warnings = "";
let sig = "";

try {
  if (await watcherDown(sd, scope)) {
    warnings += "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh\n";
    sig += " watcher-down";
  }
} catch (e) {
  aborted(e);
}

if (scope !== "" ? wakePending(sd, scope) : wakePending(sd, "") || wakeOrphanPending(sd)) {
  warnings += "QUEUED WAKES: run bin/ac-wake-drain.sh\n";
  sig += " wake-queue";
}

function git(args: string[], stdout: "pipe" | "ignore" = "pipe"): { status: number; out: string } {
  try {
    const r = spawnShellSync(["git", ...args], { stdin: "inherit", stdout, stderr: "ignore" });
    return { status: shellStatus(r), out: stdout === "pipe" ? r.stdout.toString("latin1") : "" };
  } catch {
    return { status: 127, out: "" };
  }
}
const isRepo = (d: string): boolean => reachable(d) && git(["-C", d, "rev-parse", "--git-dir"], "ignore").status === 0;

const anchor = process.env.AC_GUARD_ROOT || started;
let root = anchor;
if (root !== "" && isRepo(root)) root = repoRoot(root) ?? "";
if (root !== "" && isRepo(root)) {
  const r = git(["-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"]);
  const cur = subst(r.out + (r.status !== 0 ? "detached HEAD" : ""));
  const def = b8(defaultBranch(root));
  if (def !== "" && cur !== def) {
    warnings += `TANGLE: distro checkout on '${cur}', not '${def}' - fleet tooling may be mid-edit\n`;
    sig += " tangle";
  }
}

if (anchor !== "" && root !== "" && anchor !== root) {
  warnings += `WIP-TOOLING: running bin/ from '${b8(anchor)}', not the primary '${b8(root)}' - this may be a crewmate's leased worktree copy\n`;
  sig += " wip-tooling";
}

if (anchor !== "" && isRepo(anchor)) {
  const lagDef = defaultBranch(anchor);
  if (lagDef !== "") {
    const r = git(["-C", anchor, "rev-list", "--count", `HEAD..refs/heads/${lagDef}`]);
    const behind = r.status === 0 ? subst(r.out) : "";
    if (behind !== "" && behind !== "0" && !/[^0-9]/.test(behind)) {
      warnings += `DISTRO-LAG: running tree is ${behind} behind ${b8(lagDef)}\n`;
      sig += " distro-lag";
    }
  }
}

const stamp = wakeScopeOk(scope) ? `${sd}/.guard-stamp.${scope}` : `${sd}/.guard-stamp`;
if (warnings === "") {
  try {
    spawnShellSync(["rm", "-f", stamp], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  } catch {}
  process.exit(0);
}

// ac_meta_get under `2>/dev/null || true`: its WARN about an unreadable stamp
// was never seen, so readability is checked before metaGet can print it.
function stampGet(key: string): string {
  try {
    accessSync(stamp, constants.R_OK);
    return metaGet(stamp, key).replace(/\0[\s\S]*$/, "");
  } catch {
    return "";
  }
}
const lastSig = stampGet("sig");
let lastAt = stampGet("at");
if (lastAt === "" || /[^0-9]/.test(lastAt)) lastAt = "0";
const now = nowRaw();
if (sig === lastSig) {
  let elapsed: bigint | null = null;
  try {
    elapsed = BigInt.asIntN(64, arithValue(now) - arithValue(lastAt));
  } catch (e) {
    if ((e as { code?: string }).code !== "EARITH") aborted(e);
  }
  const q = testInt(quiet);
  if (elapsed !== null && q !== null && elapsed < q) process.exit(0);
}

const block = Buffer.from(warnings, "latin1");
try {
  for (let off = 0; off < block.length; ) off += writeSync(2, block, off, block.length - off);
} catch (e) {
  if ((e as { code?: string }).code === "EPIPE") process.exit(141);
}
try {
  metaSet(stamp, "sig", sig);
} catch {}
try {
  metaSet(stamp, "at", now);
} catch {}
process.exit(0);
