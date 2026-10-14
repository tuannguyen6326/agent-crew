// self-task.ts - make a SMALL chief-side edit VISIBLE. The authoritative spec
// for the chief-self-but-visible mechanism. A SOLO session (AC_SOLO=1) uses
// the SAME verb per slice with no size cap - the cap below binds the CHIEF's
// self-exception; the solo contract is the solo-session skill. A SOLO CHIEF (a
// roomchief promoted --solo, AC_SCOPE set) uses it the same way for its
// family's slices: the meta then carries fleet_scope=<family>, and at landing
// the teardown gate reads the family room's `LANDED: <id>` receipt where a
// Done row would be (soloLandingCheck, src/lib.ts), since the ledger guard
// fences the backlog from it.
// The entry is bin/ac-self-task.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-self-task.sh as the oracle the
// differential leg of tests/sh/ac-self-task.test.sh holds this module to.
//
// Usage: ac-self-task.sh start <id> <project-name-or-dir> [--mode <m>] [--harness <h>] [--base-branch <b>]
//        ac-self-task.sh log <id> '<progress line>'
//
// THE RULE IT SERVES (no invisible tasks; small tasks chief-self but
// herdr-visible): no task may be done invisibly, and a task the CREWCHIEF does
// itself is still a task. A chief editing a one-line doc or config used to
// leave no trace on herdr at all - `start` is the one command that fixes
// exactly that, and nothing else.
//
// WHAT IT IS NOT. This is VISIBILITY, not an execution engine. It launches no
// harness, reads no brief, opens no room, runs no gate, no review and no
// stage. There is no promote tier below room and no config knob here. The
// CHIEF does the work in the leased worktree with its own hands, and the whole
// mechanism is: a lease, a pane, a meta, a progress log. It is NOT a way
// around the prime directive either - real project work still goes to a
// crewmate in its own worktree. `start` cannot enforce "small"; the chief's
// charter does.
//
// BEFORE EITHER VERB, in this order: the backend name (AC_BACKEND >
// config/backend > <AC_FLEET_STATE>/../config/backend > herdr) - any other
// name is `ERROR: unsupported backend '<b>' ...`, exit 1, whatever the argv,
// usage included (W14); git on PATH (`ERROR: required tool not found: git`,
// `log` included - W3); the verb; a non-empty id inside [a-z0-9-] read by its
// text, so an uppercase or accented letter is refused under any locale while
// a dash-only id passes (W4); then the state dir, so a homeless call is the
// one `AC_HOME is not set` ERROR on both verbs.
//
// start <id> <project>  - the flags in any order, the later one winning:
// --mode crew-ship|direct-pr|local-only|feature-pr, --harness and
// --base-branch each refused without a value (the --harness VALUE is not
// checked here - W1), anything else `unknown argument`. A meta that EXISTS
// refuses the id (a dangling link does not exist - W9). The project is a
// directory relative to the caller's cwd first - a non-repo one there
// shadows projects/<name> (W7) - else projects/<name>, read to its MAIN repo
// root physically. Then, in this order, all of it BEFORE the first edit:
//   0. THE BRANCH COLLISION REFUSAL (contract: the spawn entry's spec header,
//      the block of that name): a self task also commits on crew/<id> and
//      lands via ac-merge-local.sh, so it carries the identical hazard a dead
//      or --force'd task leaving crew/<family> behind creates for a crewmate
//      spawn. Refuses when crew/<family> resolves in the project repo and no
//      in-flight family task owns it (familyOwned, src/lib.ts - the twin of
//      the predicate the spawn entry's own refusal calls). Fires before the
//      status seed, the lease and the pane, so a refusal leaves nothing
//      half-open, and never touches the ref. Then AC_BACKEND is SET to
//      config/backend (default herdr) for this run and its children - an
//      environment pin validated above is overwritten here (W2) - and
//      --base-branch on a fleet that is not orca is refused.
//   1. seed state/<id>.status, the progress log (the pane needs a file to tail),
//   2. lease a worktree per the fleet backend - a herdr fleet from the in-repo
//      pool (<bin>/ac-tree.sh get, holder self:<id>, the same pool a crewmate
//      leases from - its status is the start's), an orca fleet an
//      Orca-managed worktree on crew/<id> (orcaWorktreeLease; the meta
//      records worktree_backend=orca so teardown routes to the release arm) -
//      then run the project's commands.install in it (the spawn entry's THE
//      LEASE INSTALL: deps=ok|failed on the meta, a failure only WARNed - with
//      no kickoff here, that WARN is the slice's whole notice), and seed the
//      crewmate layer (instructions, settings, skills, the port
//      slot) into it: work on a worktree follows the crewmate rules, whoever
//      holds the hands. `--harness <h>` routes the instruction/skills seed to
//      the file that harness loads (default claude -> .claude/CLAUDE.md;
//      codex/opencode/pi/cursor -> AGENTS.md) - a solo session is not only
//      claude. The fleet-memory read follows (the prompt-time recall hook,
//      below),
//   3. open the labelled tab in the fleet ROOT workspace and run `tail -f` on
//      the progress log in it - the pane's ONLY job is to show the chief's own
//      progress. A pane that cannot be opened FAILS the start saying so, and
//      names the backend's own reason where the backend has one it can state
//      (a stopped herdr server, plus the call that fixes it),
//   4. write the COMPLETE state/<id>.meta with kind=self.
//   THE ROLLBACK: from step 1 until step 4 is done, every exit gives the lease
//   back, removes BOTH the partial meta and the status file step 1 seeded,
//   and reaps the tab once its target has been read - a left-behind status
//   file reads as a task in flight in every fleet view, and a retry of the
//   same id would then append to a dead slice's log. The window is a few
//   syscalls wide - there is no harness to boot here, so the spawn entry's
//   pre-meta claim (which exists for its AC_SPAWN_SETTLE-wide gap) would be
//   machinery with no gap to protect.
//
// log <id> '<line>'     - append one timestamped line to the progress log (and
//   the task's durable timeline). The pane is tailing it, and ac-crew-state
//   reports the LAST line (prefixed `status| `, F13: a bare captain marker in
//   that line must not read as a fresh one from whichever pane is running the
//   fleet view), so every fleet view shows what the chief is doing right now.
//   Refuses on any kind but self: the crew status log is the fleet's own
//   record and this verb is not a way to write into it by hand. Arguments past
//   the line are ignored.
//
// LANDING is the EXISTING path, unchanged: the chief creates/continues
// crew/<id> in the leased worktree, commits there, then
//   bin/ac-merge-local.sh <id>   (needs no kind - it reads project_dir/worktree)
//   bin/ac-teardown.sh <id>      (kind=self takes the ordinary committing-task
//                                 landed proof, then REFUSES until the slice's
//                                 knowledge loop is written - lesson, repo
//                                 fact, Done row, or --no-lesson/--no-fact
//                                 '<why>' - ticks the Learning cadence, and
//                                 returns the lease; src/teardown.ts's header
//                                 owns the gate)
// `--mode <m>` (default local-only, the chief self path above) records the
// slice's real delivery mode on the meta - a SOLO slice landing a PR is
// mode=direct-pr, and the landed proof already accepts a merged PR the same as
// a local merge. The meta's mode is what fleet views display; nothing
// schedules off it.
//
// SUPERVISION. The meta is EXCLUDED FROM SUPERVISION, NEVER FROM ACCOUNTING -
// the authoritative contract is the SELF-TASK class block in bin/ac-lib.sh
// (ac_meta_is_self). Short version: no agent lives in this pane, so the fleet
// must not demand a watcher for it and the watcher must not wake the chief
// about the chief's own typing; every dashboard still lists it, which is the
// point.
//
// On success `start` prints:
//   self-task <id> kind=self project=<name> backend=<b> window=<target> worktree=<path>
//
// EXIT: 0 started (a fallback notice, the recall block, a tail that may be
// stranded and an unknown --harness included) or logged; 1 every ERROR above,
// a status append that failed or a meta write that failed before its mv, a
// closed stdout, a seed the shell's arithmetic refused; the herdr lease's own
// status (bin/ac-tree.sh get), mv's under a meta write, date's under an
// unguarded append, sed's in the recall block and the skills seed's failed
// mkdir, ln or rm; 143, 129 and 130 when TERM, HUP or INT ends the run.
// SIGNALS: TERM, HUP and INT are handled alike - each runs THE ROLLBACK for
// the step reached and exits 128+n. A signal held through a synchronous child
// acts at the next turn of the event loop, which the start takes after each
// step that runs children from the status seed on, the final meta write
// included, and `log` takes after its append. The worktree and the tab are
// known to the rollback only once their step has returned, as the original
// assigned them from `$(...)`.
//
// ESCAPE HATCH. This entry is the solo session's own write path - every slice,
// the one that would fix a broken port included, opens through it. If a
// landed change breaks this module, run the frozen original from a scratch
// root at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   ln -s "$PWD/.agents" "$o/.agents"; cp tests/fixtures/ac-self-task.sh "$o/bin/ac-self-task.sh"
// then AC_HOME=<home> "$o/bin/ac-self-task.sh" start|log ... from the
// session's own cwd (the recall reads it). Without the .agents link the seed
// links none of the built-in skills the container's .claude/skills lacks; with
// it the worktree's skill links point through the copy, so keep the copy until
// those slices are torn down. The hatch covers a broken module, not a missing
// bun: the copy's siblings are the live shims over src/, its ac-tree.sh lease
// among them. It writes the same meta, status and handle formats, so a slice
// opened by either side is logged, landed and torn down by the other. The
// captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W1: an unknown --harness prints harnessInstructionFile's ERROR and the
//   start still exits 0; where any layer source exists the layer lands at the
//   FALLBACK path with the "repo ships its own instruction file" notice
//   although the repo ships none.
// - W2: an AC_BACKEND in the environment is validated, then overwritten by
//   config/backend or herdr - an orca pin with no config leases from the
//   herdr pool.
// - W3: `log` requires git.
// - W4: a dash-only id (`-`, `--`) starts a task.
// - W5: log's refusal reads kind= a second time, unsilenced: an unreadable
//   meta is WARNed and named `kind=,`, and `kind=self<CR>` is refused with
//   its CR raw.
// - W6: the rollback never releases the worktree's port-slot registry row.
// - W7: a directory in the caller's cwd named like the project shadows
//   projects/<name> - a non-repo one is `project not found`.
// - W8: the recall query is not JSON-escaped: a `"` in the project name breaks
//   the hook's parse and the read vanishes silently.
// - W9: a dangling symlink at the meta path passes the duplicate refusal and
//   the meta replaces it as a regular file.
// - W10: a log line holding LF writes an unstamped second record line.
// - W14: an unsupported backend name refuses every argv, usage included.
// - W15: a signal held through the lease acts before the rollback knows the
//   worktree: the slot or Orca worktree stays leased, the status removed.
// - W16: a signal from the pane's opening until its target is read (the open,
//   the herdr tail send) leaves the tab and its handle: the rollback reaps
//   only a window whose target it read.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every path needs bun now (the shim's `ERROR: required tool not
//   found: bun`, exit 1, before anything), where the original's `log` ran
//   without it and its herdr `start` reached the lease before a shim refused.
// - SIGNALS: the original acted on a signal held by a `$(...)` child as that
//   child returned - the leg holds its signal rows there - but at once during
//   a plain child (a seed's cp, mkdir or ln, a herdr RPC, the pane's
//   subshell, the send and its settle, a meta rewrite), leaving the child
//   running, and it swallowed an INT there and went on. Here the signal acts
//   at the turn after the step, which completes first, and INT ends the run
//   130 like the others. A signal held through `log`'s date ended the
//   original with nothing appended; here the line lands, then the run ends.
//   The original re-raised the signal after its trap; this exits 128+n, the
//   status a shell parent reads either way.
// - SHELL-OWN STDERR is not reproduced, the status kept: a status file that
//   is a directory (`<lib>: line N: <path>: Is a directory`, exit 1 - W11),
//   a closed stdout (`printf: write error`, exit 1) and a meta write's mv a
//   signal ended (`<lib>: line N: <pid> Terminated: 15 ...` for TERM, exit
//   128+n).
// - HOME RESOLUTION: an AC_HOME cd cannot enter is `ERROR: AC_HOME is not a
//   readable directory: <h>`, where the original printed cd's own line.
// - BYTES: argv and the environment arrive decoded - a byte that is no UTF-8
//   in the id (refused either way), a project path, --mode, --harness or
//   AC_SCOPE reaches the messages, the metas and the children as U+FFFD, and
//   `%q` spells the decoded text's bytes.
// - require reads PATH through Bun.which, which refuses a non-executable git
//   `command -v` accepted (every port shares it).
// - A caller whose cwd has no name: a relative project resolves against the
//   distro root (enterCaller), where the original's `[ -d ]` failed and read
//   projects/<name>.
// - EXCLUSIVE TEMP: the meta's and the port registry's temps are created
//   exclusively (metaSet, seedPortsEnv), where the original wrote through a
//   planted `.tmp.$$`.
// - LEASE INSTALL: a declared commands.install runs in the lease (step 2),
//   where the original installed nothing; with none declared the start is the
//   original's.
//
// CALLERS: no bin/, src/, dashboard/ or hook runs this entry - it is run by
// hand: by the chief for a small self-edit, a SOLO session per slice and a
// solo chief per family slice (AGENTS.md section 5; the solo-session,
// rooms-threads and task-lifecycle skills; bin/ac-session-start.sh's banner,
// bin/ac-sessionstart-nudge.sh's orientation and the spawn entry's --solo
// kickoff name it), reading its `self-task` line, the fallback notice and the
// recall block. No caller runs it under errexit, so nothing fails soft. What
// it writes is read by src/teardown.ts (leases=, lease_ids=,
// worktree_backend=, project_dir=, fleet_scope=, kind= - the knowledge-loop
// gate), src/merge-local.ts (project_dir=, worktree=), the fleet views and
// ac-crew-state (kind=self, project, mode, window, the status's last line),
// the supervision skips (the watcher, the turn-end guard, the guard),
// ac_self_tasks_in_flight (bin/ac-lib.sh) and every driver reading
// state/.pane-<id>.

import { existsSync, statSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import {
  STARTED_BIN,
  backendCall,
  backendKillWindow,
  backendName,
  backendWindowNew,
  configReadSoft,
  crewBranch,
  die,
  enterCaller,
  familyOwned,
  herdrCli,
  iso,
  leaseInstall,
  metaGet,
  metaIsSelf,
  metaSet,
  orcaPlacePane,
  orcaWorktreeLease,
  orcaWorktreeRelease,
  projectDir,
  require,
  seedCrewSettings,
  seedCrewSkills,
  seedCrewmateMd,
  seedPortsEnv,
  shellQuote,
  shellStatus,
  spawnShellSync,
  stateDir,
  statusAppend,
  taskStatus,
  warn,
  writeAll,
} from "./lib.ts";

// Decoded strings throughout; the lib's byte (latin1) answers cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
// `$(...)`: NULs dropped, trailing newlines cut.
const cap = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");
// `printf %q`, spelled in the caller's locale as bash 3.2 spelled it.
const q = (s: string): string => u8(shellQuote(b8(s)));
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};

type Exit = { exit: number };
const fatal = (status: number): never => {
  throw { exit: status } as Exit;
};
// errexit: a failed command ends the run with its status.
const ee = (status: number): void => {
  if (status !== 0) fatal(status);
};

type Io = "inherit" | "ignore" | "pipe";
type Ran = { status: number; out: string; raw: Buffer };
function run(argv: string[], o: { stdin?: "inherit" | "ignore" | Buffer; stdout?: Io; stderr?: "inherit" | "ignore" } = {}): Ran {
  const stdout = o.stdout ?? "pipe";
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(argv, { stdin: o.stdin ?? "inherit", stdout, stderr: o.stderr ?? "inherit" });
  } catch {}
  const raw = r && stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0);
  return { status: shellStatus(r), out: raw.toString("utf8"), raw };
}
// A bare `printf` under errexit: a stdout that cannot take it ends the run 1.
const say = (b: Buffer): void => {
  try {
    writeAll(1, b);
  } catch {
    fatal(1);
  }
};
// The original acted on a TERM, HUP or INT held through a child once that
// child returned; a synchronous spawn here holds it until the loop turns.
const turn = (): Promise<void> => new Promise((r) => setTimeout(r, 0));

// `NAME=<value> <call>`: the name set for the one call and its children.
function withEnv<T>(name: string, value: string, call: () => T): T {
  const saved = process.env[name];
  process.env[name] = value;
  try {
    return call();
  } finally {
    if (saved === undefined) delete process.env[name];
    else process.env[name] = saved;
  }
}

// What THE ROLLBACK reads at exit.
const S = { armed: false, id: "", meta: "", status: "", backend: "", worktree: "", window: "" };
let binDir = "";

// The lease back, the partial meta and the status removed, the tab reaped once
// its target is known. The original's rm ran under errexit inside its trap, so
// an rm that failed ended the rollback there.
function rollback(): void {
  if (S.worktree !== "") {
    if (S.backend === "orca") orcaWorktreeRelease(S.worktree);
    else run([`${binDir}/ac-tree.sh`, "return", S.worktree, "--force"], { stdout: "ignore", stderr: "ignore" });
  }
  if (run(["rm", "-f", S.meta, S.status], { stdout: "inherit" }).status !== 0) return;
  if (S.window !== "") backendKillWindow(S.id);
}

// ac_status_append bare under errexit: a date that failed or a primary
// append that did not land ends the run there. <line> is bytes (latin1).
function statusHard(id: string, line: string): void {
  let ok = false;
  try {
    ok = statusAppend(id, line, true);
  } catch (e) {
    fatal((e as { status?: number }).status ?? 1);
  }
  if (!ok) fatal(1);
}

// ac_meta_set bare under errexit: a refused write ends the run with its
// status. <value> is bytes (latin1).
function metaSetHard(key: string, value: string): void {
  try {
    metaSet(S.meta, key, value);
  } catch (e) {
    fatal((e as { status?: number }).status ?? 1);
  }
}

const IO = { stdin: "inherit", stdout: "inherit", stderr: "inherit" } as const;
function bc(fn: Parameters<typeof backendCall>[0], args: string[], io: Parameters<typeof backendCall>[2] = IO): ReturnType<typeof backendCall> {
  const r = backendCall(fn, args, io);
  if (r.exited) fatal(r.status);
  return r;
}
const target = (id: string): string => cap(bc("target", [id], { ...IO, stdout: "pipe" }).out.toString("utf8"));

// The ONE backend fault that names itself: herdr answers `status server` from
// the CLIENT when the socket has no server behind it (the reading window
// liveness takes as positive absence), and a stopped server is what a chief
// can act on. The fix is attaching the session - `herdr --help` lists no
// `server start`, only `server stop`, and a bare `herdr` launches or attaches
// the persistent session - so it is the CAPTAIN's call, never one this module
// makes for them.
function backendWhy(backend: string): string {
  if (backend !== "herdr") return "";
  const st = herdrCli(["status", "server", "--json"], "ignore", "pipe");
  const running = run(["jq", "-r", ".running"], { stdin: st.out, stderr: "ignore" });
  return cap(running.out) === "false" ? ": the herdr server is not running - attach the session (run `herdr`) and try again" : "";
}

const MODES = ["crew-ship", "direct-pr", "local-only", "feature-pr"];

async function main(argv: string[]): Promise<void> {
  backendName();
  require("git");
  binDir = STARTED_BIN;
  const verb = argv[0] ?? "";
  if (!["start", "log"].includes(verb)) die("usage: ac-self-task.sh start <id> <project> | ac-self-task.sh log <id> '<line>'");
  const id = argv[1] ?? "";
  if (id === "") die(`usage: ac-self-task.sh ${verb} <id> ...`);
  // By its text: a collating locale's a-z range admitted most uppercase
  // letters, which is why the original forced C collation for this one test.
  if (/[^a-z0-9-]/.test(id)) die(`id must be [a-z0-9-]: ${id}`);
  const sd = stateDir();
  const meta = `${sd}/${id}.meta`;
  const status = taskStatus(id);
  if (verb === "log") {
    logLine(id, meta, argv[2] ?? "");
    await turn();
  } else await start(id, sd, meta, status, argv.slice(2));
}

function logLine(id: string, meta: string, line: string): void {
  if (line === "") die("usage: ac-self-task.sh log <id> '<line>'");
  if (!isFile(meta)) die(`no self task for ${id} (start it first)`);
  if (!metaIsSelf(meta)) {
    let kind = "";
    try {
      kind = metaGet(meta, "kind").replace(/\0[\s\S]*$/, "");
    } catch {}
    die(Buffer.concat([Buffer.from(`${id} is kind=`), Buffer.from(kind, "latin1"), Buffer.from(", not self - only a self task's own progress log is written by hand")]));
  }
  statusHard(id, b8(line));
}

async function start(id: string, sd: string, meta: string, status: string, rest: string[]): Promise<void> {
  const project = rest[0] ?? "";
  if (project === "") die("usage: ac-self-task.sh start <id> <project-name-or-dir> [--mode <m>] [--harness <h>] [--base-branch <b>]");
  // local-only is the DEFAULT (a chief self task lands with ac-merge-local.sh),
  // never a hardcode: a SOLO session's slice lands per the repo's mode, PR
  // included, and the fleet views display what the meta records.
  let mode = "local-only";
  let harness = "";
  let baseBranch = "";
  for (let i = 1; i < rest.length; i += 2) {
    const flag = rest[i]!;
    const value = rest[i + 1] ?? "";
    if (flag === "--mode") {
      mode = value;
      if (!MODES.includes(mode)) die(`invalid --mode: ${mode || "empty"} (want crew-ship|direct-pr|local-only|feature-pr)`);
    } else if (flag === "--harness") {
      harness = value;
      if (harness === "") die("--harness names the harness working this slice (claude|codex|opencode|pi|cursor|...)");
    } else if (flag === "--base-branch") {
      baseBranch = value;
      if (baseBranch === "") die("--base-branch names the branch the orca lease is cut from (wins over the live checkout; orca backend only)");
    } else die(`unknown argument: ${flag}`);
  }
  if (existsSync(meta)) die(`task ${id} already exists (see ${meta}); tear it down first`);
  const projectDirC = projectDir(project) ?? die(`project not found: ${project} (clone it into projects/ first)`);
  const projectName = basename(projectDirC);

  // THE BRANCH COLLISION REFUSAL (above). Teardown deletes a crew branch only
  // when it is MERGED, so a dead or --force'd task can leave crew/<family>
  // behind for a later start to land onto by mistake; read here, right after
  // the project resolves and before anything is created.
  const branch = crewBranch(id);
  const sha = cap(run(["git", "-C", projectDirC, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`]).out);
  if (sha !== "" && !(await familyOwned(id, sd)))
    die(`${branch} already exists in ${projectDirC} (${sha.slice(0, 12)}) and NO task is in flight to own it - it outlived a dead or torn-down task (teardown deletes a crew branch only when it is MERGED), so starting ${id} would commit onto that foreign history and make its landing diff nonsense. Rename it or delete it - that is YOUR call, this start touches no ref:
  keep it:   git -C ${projectDirC} branch -m ${branch} ${branch}-old
  drop it:   git -C ${projectDirC} branch -D ${branch}
then start again`);

  process.env.AC_BACKEND = configReadSoft("backend", "herdr");
  const backend = backendName();
  // --base-branch only ever reaches the orca lease below; on a herdr fleet it
  // would otherwise silently no-op (the pool lease has no base-branch
  // concept), the exact silent-outcome defect this fleet's own conventions
  // refuse.
  if (baseBranch !== "" && backend !== "orca") die(`--base-branch requires an orca-backend fleet (config/backend=${backend} here) - a herdr fleet leases from its own worktree pool, which has no base-branch concept`);

  Object.assign(S, { armed: true, id, meta, status, backend });

  // 1. The progress log, before the pane that tails it exists.
  statusHard(id, "working: self task started by the chief");
  await turn();

  // 2. The lease - per the fleet backend, like every other isolated checkout
  // (crew, verifier): an orca fleet leases through the Orca CLI, on crew/<id>.
  if (backend === "orca") {
    const lease = orcaWorktreeLease(id, projectDirC, baseBranch);
    await turn();
    S.worktree = lease.out;
    if (lease.status !== 0) die(`could not lease an Orca worktree for ${id}`);
  } else {
    const get = run([`${binDir}/ac-tree.sh`, "get", "--repo", projectDirC, "--id", id, "--holder", `self:${id}`]);
    await turn();
    S.worktree = cap(get.out);
    ee(get.status);
  }
  const wt = S.worktree;
  const deps = leaseInstall(id, projectDirC, wt);
  await turn();

  // Work on a worktree follows the crewmate layer, whoever holds the hands -
  // the chief, a solo session, or a session the captain opens INSIDE the tree
  // - so the lease seeds exactly what a crew spawn seeds: instructions,
  // settings, skills. A repo shipping its OWN instruction file forces the seed
  // to a FALLBACK path no harness auto-loads - a crew spawn rides that print
  // into its kickoff prompt; here there is no kickoff, so the status record is
  // the durable channel: swallowing it points the session at the shipped law
  // while the real crewmate layer sits unannounced.
  const fallback = seedCrewmateMd(wt, harness);
  if (fallback !== "") {
    statusHard(id, b8(`layer: crewmate layer at FALLBACK path ${fallback} (the repo ships its own instruction file) - read THAT file, not only the shipped law`));
    say(Buffer.from(`crewmate layer at FALLBACK path: ${fallback} (the repo ships its own instruction file - read it)\n`));
  }
  seedCrewSettings(wt);
  ee(seedCrewSkills(wt, harness));
  let ports: string | null = null;
  try {
    ports = seedPortsEnv(wt, projectName);
  } catch {
    fatal(1);
  }
  if (ports === null) warn(`could not seed a port slot for ${wt} - listeners in this worktree may collide with a sibling's`);
  await turn();

  // Fleet-memory read at slice open: the knowledge law names `ac-brain.sh
  // recall` at intake, and the start makes it machine-made through the same
  // prompt-time hook every harness runs (its shape gate - a chief at the
  // fleet home, from the caller's cwd, or a solo session - and its noise
  // gates apply). The slice id and project are the query. The hits print to
  // the session AND land on the status record - the durable channel the pane
  // tails - so the read survives the start's stdout scrolling away. The
  // record's LAST line is what every fleet view shows as the slice's state,
  // so a state line closes the block. The hook's `agent-crew:` pending-wake
  // line is not a recall hit, so it is dropped here or a queued wake alone
  // would read as a memory read.
  const query = `{"prompt":"${id.replaceAll("-", " ")} ${projectName}"}`;
  const hook = run([`${binDir}/ac-prompt-recall.sh`], { stdin: Buffer.from(query), stderr: "ignore" });
  const recall = cap(run(["grep", "-v", "^agent-crew: "], { stdin: hook.raw }).raw.toString("latin1"));
  if (recall !== "") {
    say(Buffer.from(`${recall}\n`, "latin1"));
    const brain = run(["sed", "-n", "s/^- /brain: /p"], { stdin: Buffer.from(`${recall}\n`, "latin1") });
    // `while IFS= read -r line`: whole lines only.
    for (const line of brain.raw.toString("latin1").split("\n").slice(0, -1)) {
      try {
        statusAppend(id, line);
      } catch {}
    }
    ee(brain.status);
    statusHard(id, "working: fleet memory read, opening the pane");
  }
  await turn();

  // 3. The pane. Refused rather than doubled when the backend cannot answer
  // for an existing one - the three states are WINDOW LIVENESS's
  // (bin/ac-backend.sh). A self task is the chief's own fleet-level work: its
  // tail tab lives in the fleet ROOT workspace (AC_WINDOW_FAMILY set EMPTY),
  // never in a family's space.
  const alive = bc("window_alive", [id]).status;
  await turn();
  if (alive === 0) die(`window ${target(id)} already exists`);
  if (alive !== 1) die(`the BACKEND could not be READ for ${id} - whether ${target(id)} still exists is UNKNOWN, so this is REFUSED rather than open a second window beside a possibly LIVE one; check the backend itself (herdr status server), then try again`);
  if (backend === "orca") {
    // The tail is the PANE'S OWN command - nothing is ever typed into a
    // booting shell (a typed tail measurably raced the shell's cd+exec and
    // landed as interleaved fragments, killing the first start).
    const placed = withEnv("AC_WINDOW_FAMILY", "", () => orcaPlacePane(wt, `cd ${q(wt)} && exec tail -f ${q(status)}`, id));
    await turn();
    if (placed === null) die(`orca pane placement failed for ${id} at ${wt}`);
    try {
      writeFileSync(`${sd}/.pane-${id}`, Buffer.from(`${placed}\n`, "latin1"));
    } catch {
      fatal(1);
    }
  } else {
    // The original's SUBSHELL kept the driver's own die from ending the start
    // wherever it happened (a bare rc=1 under the pool's WARN): the driver's
    // reason still prints, then what the start was doing. Its errexit slept
    // inside it.
    const opened = withEnv("AC_WINDOW_FAMILY", "", () => backendWindowNew(id, wt, false));
    await turn();
    if (opened.status !== 0) die(`could not open the pane for ${id} on the ${backend} backend${backendWhy(backend)}`);
    const sent = withEnv("AC_SEND_UNPROVEN", "1", () => bc("send_line", [id, `tail -f ${q(status)}`]).status);
    await turn();
    if (sent !== 0) warn(`the pane may not have started tailing ${status} - peek it (bin/ac-peek.sh ${id})`);
  }
  const window = target(id);
  await turn();
  S.window = window;

  // 4. The complete meta.
  metaSetHard("backend", b8(backend));
  metaSetHard("window", b8(window));
  metaSetHard("worktree", b8(wt));
  metaSetHard("leases", b8(wt));
  if (backend === "orca") metaSetHard("worktree_backend", "orca");
  else {
    // lease_ids is a POOL concept (the slot meta's reclaim token); an orca
    // lease has no slot to read it from, and teardown's orca arm never pops it.
    let leaseId = "";
    try {
      leaseId = metaGet(`${projectDirC}/.crew/slots/${basename(wt)}.meta`, "lease_id").replace(/\0[\s\S]*$/, "");
    } catch {}
    metaSetHard("lease_ids", leaseId);
  }
  metaSetHard("project", b8(projectName));
  metaSetHard("project_dir", b8(projectDirC));
  metaSetHard("kind", "self");
  metaSetHard("mode", b8(mode));
  if (deps !== "") metaSetHard("deps", deps);
  // A SOLO CHIEF's slice (a scoped session, AC_SCOPE set) belongs to its
  // family: the scope rides the meta the way a crewmate spawn records it, so
  // fleet views group the slice under the family and the teardown gate knows
  // to read the family room's LANDED: receipt where a Done row would be.
  const scope = process.env.AC_SCOPE ?? "";
  if (scope !== "") metaSetHard("fleet_scope", b8(scope));
  let at = "";
  try {
    at = iso();
  } catch {}
  await turn();
  metaSetHard("spawned_at", at);
  await turn();
  S.armed = false;

  say(Buffer.from(`self-task ${id} kind=self project=${projectName} backend=${backend} window=${window} worktree=${wt}\n`));
}

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  process.on("exit", () => {
    if (!S.armed) return;
    S.armed = false;
    rollback();
  });
  for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) process.on(sig, () => process.exit(128 + n));
  let rc = 0;
  try {
    await main(args);
  } catch (e) {
    if (typeof (e as Exit).exit !== "number") throw e;
    rc = (e as Exit).exit;
  }
  process.exit(rc);
}
