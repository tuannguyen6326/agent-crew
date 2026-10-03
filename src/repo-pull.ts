// repo-pull.ts - fetch + FAST-FORWARD-ONLY sync of one project clone's
// checked-out branch: the dashboard Pull button's whole authority, and exactly
// the sanctioned chief write (fetch, ff-sync - AGENTS.md section 1). The entry
// is bin/ac-repo-pull.sh (a shim that starts this file through bin/ac-bun.sh);
// THIS header is the authoritative spec, and the bash original it replaced
// stays frozen at tests/fixtures/ac-repo-pull.sh as the oracle the
// differential leg of tests/sh/ac-repo-pull.test.sh holds this module to.
//
//   ac-repo-pull.sh <repo-root>
//
// <repo-root> is any path git's -C accepts, exactly as given: absolute,
// relative to the caller's cwd (enterCaller), a subdirectory of a work tree, a
// trailing slash. Extra arguments are ignored; no -h; stdin is never read;
// AC_HOME is never consulted (a homeless run is legal and identical). Every
// result is git's: seven `git -C <root>` spawns at most, with the original's
// arguments and the original's handling of each one's output.
//
// ONE line on stdout, exit 0, unless marked; the probes run IN THIS ORDER:
//   1. no or empty root     ERROR: usage: ac-repo-pull.sh <repo-root>   (stderr, exit 1)
//   2. rev-parse --git-dir fails (quiet)
//                           ERROR: not a git repo: <root as given>     (stderr, exit 1)
//   3. fetch --prune origin fails (quiet) - no remote `origin`, its URL gone, network
//                           ERROR: fetch failed (no origin, or network down)  (stderr, exit 1)
//      The fetch ALWAYS runs and ALWAYS mutates refs/remotes/origin/* (it
//      prunes), on every "fetched only" path too.
//   4. symbolic-ref --short HEAD prints nothing (detached HEAD)
//                           fetched only (detached HEAD)
//   5. refs/remotes/origin/<branch> missing (show-ref --verify --quiet) - also
//      what a `clone --bare` answers, having no fetch refspec
//                           fetched only (origin has no <branch>)
//   6. <branch> is not an ancestor of origin/<branch> (merge-base --is-ancestor):
//      origin/<branch> an ancestor of <branch> -> fetched only (local <branch> ahead of origin - nothing to pull)
//      otherwise                               -> fetched only (<branch> diverged from origin)
//      An UNBORN local branch (fresh init + remote) lands here as `diverged`:
//      both probes fail on the missing ref (kept - WIRE QUIRK).
//   7. `status --porcelain` prints anything (untracked, modified, staged alike)
//                           fetched only (working tree dirty)
//      Probed AFTER 6, so an ahead or diverged dirty clone says ahead/diverged,
//      never dirty (kept). Only stdout decides: a status that itself fails
//      reads as clean, its stderr passing through.
//   8. merge --ff-only origin/<branch> fails (quiet; a planted .git/index.lock,
//      a concurrent pull)   fetched only (fast-forward refused)
//      succeeds             synced <branch> -> <rev-parse --short HEAD>
//      ALSO when nothing moved (the no-op ff exits 0; kept - the operator
//      cannot tell "already current" from "moved"). The short sha is git's own
//      adaptive abbreviation; a failing rev-parse prints `synced <branch> -> `
//      with its stderr passed through, exit 0, as the original did.
// The branch name is the checked-out branch (symbolic-ref), never origin/HEAD:
// on `other` it syncs other while origin/main moves. It passes through as the
// bytes git printed (`synced feat/x -> 87397f7`, `origin has no feat/x`).
//
// CONSUMER: dashboard/app.ts (POST /api/repo/pull) is the only caller - an
// async spawn that captures stdout only and gates on the exit code, so every
// ERROR: line above reaches the UI as `pull failed` (a dashboard trait this
// port leaves as it was). No bash or `set -e` caller, no hook.
//
// DIVERGENCE from the original, named in the differential leg: a root whose
// name holds a byte that is not UTF-8 arrives in Bun's argv as U+FFFD, so
// `not a git repo: <root>` echoes that character where the original echoed
// the byte (exit status and stdout agree).
import { writeSync } from "node:fs";
import { die, enterCaller } from "./lib.ts";

const { args } = enterCaller(process.argv.slice(2));
const root = args[0] ?? "";
if (root === "") die("usage: ac-repo-pull.sh <repo-root>");

const quiet = (...a: string[]): number => Bun.spawnSync(["git", "-C", root, ...a], { stdout: "ignore", stderr: "ignore" }).exitCode ?? 1;
// `$(git ...)`: the stdout bytes, trailing newlines dropped, the exit ignored.
function captured(stderr: "ignore" | "inherit", ...a: string[]): Buffer {
  const r = Bun.spawnSync(["git", "-C", root, ...a], { stdout: "pipe", stderr });
  let out = Buffer.from(r.stdout);
  let end = out.length;
  while (end > 0 && out[end - 1] === 0x0a) end--;
  return out.subarray(0, end);
}
const say = (...parts: (string | Buffer)[]): void => {
  writeSync(1, Buffer.concat([...parts.map((p) => (typeof p === "string" ? Buffer.from(p) : p)), Buffer.from("\n")]));
};

if (quiet("rev-parse", "--git-dir") !== 0) die(`not a git repo: ${root}`);
if (quiet("fetch", "--prune", "origin") !== 0) die("fetch failed (no origin, or network down)");

const def = captured("ignore", "symbolic-ref", "--short", "HEAD");
if (def.length === 0) {
  say("fetched only (detached HEAD)");
  process.exit(0);
}
const branch = def.toString();
if (quiet("show-ref", "--verify", "--quiet", `refs/remotes/origin/${branch}`) !== 0) {
  say("fetched only (origin has no ", def, ")");
  process.exit(0);
}
if (quiet("merge-base", "--is-ancestor", branch, `origin/${branch}`) !== 0) {
  // Ahead and diverged both refuse the sync, but the operator's next move
  // differs - say which one it is.
  if (quiet("merge-base", "--is-ancestor", `origin/${branch}`, branch) === 0) say("fetched only (local ", def, " ahead of origin - nothing to pull)");
  else say("fetched only (", def, " diverged from origin)");
  process.exit(0);
}
if (captured("inherit", "status", "--porcelain").length > 0) {
  say("fetched only (working tree dirty)");
  process.exit(0);
}
if (quiet("merge", "--ff-only", `origin/${branch}`) !== 0) {
  say("fetched only (fast-forward refused)");
  process.exit(0);
}
say("synced ", def, " -> ", captured("inherit", "rev-parse", "--short", "HEAD"));
