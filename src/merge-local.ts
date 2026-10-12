// merge-local.ts - land a local-only crewmate task from crew/<family> into the
// project's local default branch, or into the integration branch its epic or
// feature records. Writes into a project clone - one of the few sanctioned
// writes. The entry is bin/ac-merge-local.sh (a shim that starts this file
// through bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-merge-local.sh as the
// oracle the differential leg of tests/sh/ac-merge-local.test.sh holds this
// module to.
//
//   ac-merge-local.sh <id> [--no-ff]
//
// Default path (no flag): FAST-FORWARD ONLY. It requires the primary checkout
// to be on the default branch, clean, and the default to be an ancestor of
// crew/<family> (a pure fast-forward); on success it prints `fast-forwarded
// <default> to <branch>`, which asserts the default's tree now IS the
// branch's tree - or, when the default already contains the branch (a no-op
// re-land), `<default> already contains <branch>; nothing to move`, which
// asserts nothing about the trees. When neither is an ancestor of the other
// the merge is never attempted (git's bare --ff-only error would say nothing
// useful) - the refusal is in this entry's voice and ACTOR-AWARE: an unscoped
// actor (crewchief/captain) is named `--no-ff` as the conflict-free escape
// hatch; a scoped actor (AC_CREW_ID or AC_SCOPE non-empty - a
// crewmate/roomchief) is never offered it, because the primary-checkout
// commit guard (src/tree.ts's pre-commit body, D2) refuses that actor's merge commit - it is
// told to rebase and re-run the plain land, or hand the landing back to the
// crewchief. This path never falls back to `--no-ff` on its own; that would
// change the default and is a captain decision (a conflict-free branch is
// never rebased; family merge-local-cannot-honor-the-captain-no-rebase-rule).
//
// --no-ff path (opt-in): lands a non-fast-forwardable-but-CONFLICT-FREE branch
// as an ordinary merge commit. It is tried with `git merge --no-ff
// --no-commit` first; on a conflict `git merge --abort` restores the checkout
// to clean / on the default / not MERGING before refusing with the conflicting
// paths - this is the captain's live clone, never left mid-merge. On success
// it prints `merged <branch> into <default> (--no-ff)`, which asserts the
// default now CONTAINS the branch's history, NOT that its tree IS the
// branch's - that distinction is the point of the flag. When the branch is
// already an ancestor of the default, git makes no MERGE_HEAD and there is
// nothing to commit: that is said plainly, never claimed as a merge commit.
//
// Either way the checkout must be on the default branch and clean of TRACKED
// dirt on entry. An untracked file is not refused on its own: it matters only
// when the incoming commits add the same path, and git refuses that collision
// itself (on both paths), wrapped in this entry's voice. There is no
// .gitignore special case: src/tree.ts ignores the pool (`/.crew/`)
// per-clone via `.git/info/exclude`, so a land never self-inflicts that dirt.
//
// ORDER, every refusal on stderr as `ERROR: <text>`, exit 1 unless named:
// 1. <STARTED_BIN>/ac-guard.sh is spawned when executable (stdio inherited,
//    status ignored) - its WATCHER-DOWN and peers precede every line here and
//    it may stamp state/.guard-stamp. STARTED_BIN is the bin/ of the root bun
//    was started in (src/lib.ts), so a lab bin/ runs its own guard.
// 2. `required tool not found: git` (Bun.which over the live PATH).
// 3. `usage: ac-merge-local.sh <id> [--no-ff]` when <id> is empty or a second
//    argument is not exactly `--no-ff`; a third is ignored (W9).
// 4. The meta, state/<id>.meta: homeless prints the AC_HOME refusal and then
//    `no crewmate meta for <id>` (the bash's `$(ac_task_meta)` swallow, kept);
//    no regular file there is that line alone; a meta that is there and
//    unreadable is metaGet's `WARN: cannot read meta file <meta>` alone, exit
//    1 (W2, the bash's bare assignment). Its LAST project_dir= and worktree=
//    values are read as bytes, cut at a NUL as awk handed them over.
// 5. branch = crew/<familyOfId(id)> (crewBranch), default = defaultBranch of
//    project_dir. An EMPTY project_dir is passed to every git as `-C ""`,
//    which git reads as no -C at all: the land is judged against, and lands
//    into, the repo of the CALLER's cwd (W1, reproduced - a defect of the
//    original, routed).
// 6. The epic fence: epicBaseFor(id, basename of project_dir): rc 2 is
//    `cannot read the ledger to resolve the epic-branch fence for <id>`; rc 0
//    makes the entry's first token the TARGET (epic mode), ` push=yes ` among
//    the rest the push flag and ` push=deferred ` a FEATURE entry. A target
//    missing locally: a feature's is `feature target <t> does not exist
//    locally - cut it first: ac-feature.sh create <feature> <repo>`; an
//    epic's is `epic target <t> exists neither locally nor on origin - cut it
//    first: ac-epic-branch.sh create <epic> <repo>` unless
//    refs/remotes/origin/<t> resolves, when `git branch <t>
//    refs/remotes/origin/<t>` cuts it with stdio inherited - git's own
//    `branch '<t>' set up to track 'origin/<t>'.` lands on STDOUT (W4) - and
//    its failure ends the run with git's status.
// 7. current = `git symbolic-ref --short HEAD` (stderr dropped), `DETACHED`
//    when it fails: epic mode needs the default or the target - `primary
//    checkout is on '<cur>' - an epic landing needs it on '<default>' or on
//    the target '<t>'`; otherwise the default - `primary checkout is on
//    '<cur>', not '<default>'`.
// 8. `git status --porcelain -uno` (its failure ends the run with git's
//    status): non-empty is `primary checkout is dirty: <paths> (commit, stash,
//    or discard, then retry)`, <paths> each line less its first 3 bytes,
//    joined by single spaces - git's quoting kept (`"a b.txt"`, `c.txt ->
//    d.txt` for a rename).
// 9. `branch <branch> not found in <project_dir> (did the crewmate commit?
//    worktree: <worktree>)` unless refs/heads/<branch> resolves.
//
// THE QA GATE. Epic mode prints on STDOUT `qa.require_for_ship: deferred to
// the feature ship gate (feature-branch landing)` for a feature entry, else
// `qa.require_for_ship: deferred to the epic gate (epic-branch landing)`.
// Otherwise land_sha = `git rev-parse refs/heads/<branch>` (its failure ends
// the run with git's status) and qaGateOk <project_dir> <land_sha> <id> runs
// in process - src/lib.ts's twin of ac_qa_gate_ok, held to the bash function
// by tests/ts/qa-gate.test.ts, its named divergences at that block: its
// `qa: ...` lines on stdout, its WARNs on stderr. The ERROR it throws for a
// policy it cannot read (the RETIRED legacy config, a yaml it cannot read,
// a git that cannot run; a .git git refuses fails an earlier step first -
// step 7 reads it DETACHED) is the run's exit 1 (no further line); a refusal is
// `local merge blocked by qa.require_for_ship (see message above)`. A lab
// bin/ (the ROOT seam) supplies its guard and the remedy's ac-know.sh, never
// the gate.
// The merge below takes land_sha, never the branch name: a commit landing on
// the branch between the gate and the merge must not ride an attestation it
// never earned.
//
// THE INTERLOCK (contract: ac-lib.sh's landing-ledger block). The landed set
// is the lines of `git diff --name-only <target>...refs/heads/<branch>` -
// three-dot, the branch's OWN commits since it diverged, so a sibling family's
// files on an advanced default are never stamped under this family; git's
// stderr passes, its failure yields an empty set silently (W5); an
// unterminated last line is dropped as `read` dropped it. A non-empty set
// gets landingWarn (src/lib.ts: one LANDING-OVERLAP WARN per <24h foreign
// record; an unreadable ledger ends the run with awk's 2, an empty-family
// record whose path the shell's arithmetic refuses with 1 (W10) - both
// before any merge). knowledgeWarn (the KNOWLEDGE-GAP flag) runs on EVERY landing that
// gets here, whatever the set.
//
// THE LAND, every git with stdout to /dev/null and stderr captured as `$(...
// 2>&1 >/dev/null)` captured it (trailing newlines cut, NULs dropped), every
// probe's stderr inherited:
// - --no-ff in epic mode: `--no-ff is not available for an epic-branch
//   landing: a merge commit onto <t> belongs in a leased worktree, never the
//   primary checkout - rebase <branch> onto <t> and land ff, or route the
//   merge through the epic gate`.
// - --no-ff: `git merge --no-ff --no-commit -m "Merge branch '<branch>'"
//   <land_sha>`. Failing with MERGE_HEAD: the unmerged paths (`git diff
//   --name-only --diff-filter=U`, joined by spaces; its failure ends the run
//   with git's status), `git merge --abort` (stdio inherited, its failure
//   ends the run), then `--no-ff merge of <branch> conflicts on: <paths>
//   (checkout left clean on <default>)`. Failing without: `--no-ff merge of
//   <branch> never started: <git's stderr> (checkout untouched, still clean
//   on <default>)`. With MERGE_HEAD: `git commit -q --no-edit`; refused, the
//   abort, then `--no-ff commit of <branch> was refused: <its stderr>
//   (checkout restored, clean on <default>)`; else the record, the status
//   `merged: local <default> (--no-ff)` and `merged <branch> into <default>
//   (--no-ff)`. Without MERGE_HEAD (contained): the record, `merged: local
//   <default>` and `<default> already contains <branch>; no merge commit
//   created (--no-ff)`.
// - Otherwise, when neither `merge-base --is-ancestor refs/heads/<target>
//   refs/heads/<branch>` nor the reverse holds (the second probe runs only
//   when the first failed): epic mode `<branch> is not fast-forwardable: <t>
//   has diverged from it (a sibling story landed first). Rebase <branch> onto
//   <t> and re-run the plain land`; scoped `<branch> is not
//   fast-forwardable: <default> has diverged from it. --no-ff is not
//   available here (the primary-checkout commit guard refuses it for a
//   crewmate/roomchief) - rebase <branch> onto <default> and re-run the plain
//   land, or hand the landing back to the crewchief`; else `<branch> is not
//   fast-forwardable: <default> has diverged from it. Land a conflict-free
//   branch with 'ac-merge-local.sh <id> --no-ff', or rebase <branch> onto
//   <default> first`.
// - Epic mode: the branch already an ancestor of the target prints `<t>
//   already contains <branch>; nothing to move`; the target checked out is an
//   in-place `git merge --ff-only <branch>` (`ff of <t> (checked out) from
//   <branch> failed: <err> (<t> untouched)`, else `fast-forwarded <t> to
//   <branch> (in place)`); otherwise the REF-ONLY `git fetch --quiet .
//   refs/heads/<branch>:refs/heads/<t>` (`ff update of <t> from <branch>
//   failed: <err> (<t> untouched)`, else `fast-forwarded <t> to <branch>
//   (ref-only)`) - no checkout flip, the commit guard has nothing to see.
//   Then, with push=yes and `git remote get-url origin` answering,
//   pushControlPlane `--quiet origin refs/heads/<t>:refs/heads/<t>` with its
//   stderr dropped: `pushed <t> to origin (record push=yes)` or `WARN: push of
//   <t> to origin FAILED - the landing stands; retry: git -C <project_dir>
//   push --no-verify origin <t>`. Then the record and `merged: local <t>
//   (epic)`.
// - Plain: noop when `merge-base --is-ancestor <land_sha>
//   refs/heads/<default>`; `git merge --ff-only <land_sha>` (`fast-forward
//   of <branch> failed: <err> (<default> untouched)` - the untracked
//   collision's shape); the record; `merged: local <default>`; the noop or
//   the fast-forwarded line.
// The record is landingRecord over the landed set (src/lib.ts: the 7-day
// prune and the append under state/.landings.lock, the UNSERIALIZED WARN past
// 10 spawned `sleep 1`s; a failed mv exits 1 after the land). The status line
// is statusAppend's UNGUARDED arm (the bash ran ac_status_append bare): a
// date that fails ends the run with its status, an append that fails with 1 -
// both after the land.
//
// EXIT: 0; 1 for every ERROR and the cases above; git's own status where a
// bare git failed (`git branch`, `status`, `rev-parse`, `merge --abort`, the
// conflict list); 128+signal for a child a signal ended, 127 for one that
// could not start.
//
// DIVERGENCES from the original, named in the differential leg:
// - SHELL-OWN STDERR is not reproduced: the arithmetic error of an
//   empty-family ledger record (`g: unbound variable`, W10), a failed
//   append's redirection line, awk's `can't open file` lines (an unreadable
//   landing ledger, an unreadable backlog - epicBaseFor's), the line of a
//   guard that is a directory.
// - defaultBranch (src/lib.ts) drops the stderr of its show-ref probes, so a
//   project_dir that is no repo misses git's two `fatal: cannot change to`
//   lines the original printed before its DETACHED refusal (exit and refusal
//   kept).
// - landingWarn ends the run with 1 on any age but a plain decimal, where the
//   shell evaluated the shifted path as an arithmetic expression (`p`, `UID`,
//   `0x10` read as numbers there).
// - W3: the dirty and conflict path lists keep their bytes where `tr` under a
//   UTF-8 locale cut them at an invalid byte (the oracle runs under C).
// - The ledger temp is created EXCLUSIVELY (landingRecord - the bash wrote
//   through a planted `.landings.tmp.<pid>`; tests/ts/merge-local.test.ts).
// - require reads PATH through Bun.which, which refuses a non-executable PATH
//   file `command -v` accepted (every port shares it).
// - argv and the meta's bytes: an argument arrives decoded, and a project_dir,
//   branch or target that is not UTF-8 is spawned decoded (as U+FFFD).
//
// CALLERS: no bin/, src/, dashboard/ or hook runs this entry. Chiefs run it by
// hand (.agents/skills/task-lifecycle, solo-session; src/self-task.ts's
// header), and a crewmate or roomchief runs it from its own pane on its
// brief's word (bin/ac-spawn.sh's roomchief LANDING line, the scoped-actor
// path above) - THAT pane's PATH must now carry bun: a bun-less pane answers
// `ERROR: required tool not found: bun`, exit 1, from the shim, where the bash
// landed. No `set -e` caller dies silently on it, so nothing fails soft;
// tests/sh/ac-guard.test.sh greps the literal `ac-guard.sh` in the shim.
import { accessSync, constants, statSync, writeSync } from "node:fs";
import {
  crewBranch,
  defaultBranch,
  die,
  enterCaller,
  epicBaseFor,
  familyOfId,
  knowledgeWarn,
  landingRecord,
  landingWarn,
  metaGet,
  pushControlPlane,
  qaGateOk,
  require,
  shellStatus,
  spawnShellSync,
  STARTED_BIN,
  statusAppend,
  taskMeta,
  warn,
} from "./lib.ts";

const b = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const native = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const out = (s: string): void => {
  writeSync(1, b(s));
};
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (buf: Buffer): string => buf.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

type Io = "inherit" | "ignore" | "pipe";

// Every child inherits the caller's stdin, as every child of the bash did.
function run(cmd: string[], stdout: Io, stderr: Io): { status: number; out: Buffer; err: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout, stderr });
  } catch {}
  return {
    status: shellStatus(r),
    out: r && stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0),
    err: r && stderr === "pipe" ? Buffer.from(r.stderr) : Buffer.alloc(0),
  };
}

// A lib twin throws the status where the bash's errexit ended the run.
function exitWith(e: unknown): never {
  const s = (e as { status?: number }).status;
  if (s === undefined) throw e;
  process.exit(s);
}

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

// basename(1): trailing slashes dropped, `/` for a name of slashes only.
function basename(p: string): string {
  const t = p.replace(/\/+$/, "");
  if (t === "") return p === "" ? "" : "/";
  return t.slice(t.lastIndexOf("/") + 1);
}

const { args } = enterCaller(process.argv.slice(2));

const guard = `${STARTED_BIN}/ac-guard.sh`;
let guardRuns = false;
try {
  accessSync(guard, constants.X_OK);
  guardRuns = true;
} catch {}
if (guardRuns) run([guard], "inherit", "inherit");
require("git");

const id = args[0] ?? "";
const noff = args[1] ?? "";
if (!id || (noff !== "" && noff !== "--no-ff")) die("usage: ac-merge-local.sh <id> [--no-ff]");
const idB = bytes(id);
const meta = taskMeta(id);
if (!isFile(meta)) die(`no crewmate meta for ${id}`);
const metaValue = (key: string): string => {
  try {
    return metaGet(meta, key).replace(/\0[\s\S]*$/, "");
  } catch {
    process.exit(1);
  }
};
const projectDir = metaValue("project_dir");
const worktree = metaValue("worktree");
const dir = native(projectDir);
const branchB = bytes(crewBranch(id));
const branchN = native(branchB);
const defB = bytes(defaultBranch(dir));
const defN = native(defB);

const git = (gargs: string[], stdout: Io, stderr: Io) => run(["git", "-C", dir, ...gargs], stdout, stderr);
const resolves = (ref: string): boolean => git(["rev-parse", "--verify", "--quiet", ref], "ignore", "inherit").status === 0;
// `x="$(git ...)"` bare under errexit: git's failure ends the run.
const gitValue = (gargs: string[]): string => {
  const r = git(gargs, "pipe", "inherit");
  if (r.status !== 0) process.exit(r.status);
  return subst(r.out);
};
const bare = (gargs: string[]): void => {
  const s = git(gargs, "inherit", "inherit").status;
  if (s !== 0) process.exit(s);
};

let targetB = defB;
let epic = false;
let epicPush = false;
let deferred = false;
const repoName = basename(projectDir);
const eb = epicBaseFor(id, native(repoName));
if (eb.rc === 2) die(`cannot read the ledger to resolve the epic-branch fence for ${id}`);
if (eb.rc === 0) {
  targetB = eb.entry.split(" ")[0]!;
  epic = true;
  const keys = ` ${eb.entry.slice(targetB.length)} `;
  epicPush = keys.includes(" push=yes ");
  deferred = keys.includes(" push=deferred ");
  if (!resolves(`refs/heads/${native(targetB)}`)) {
    if (deferred) die(b(`feature target ${targetB} does not exist locally - cut it first: ac-feature.sh create <feature> ${repoName}`));
    if (!resolves(`refs/remotes/origin/${native(targetB)}`))
      die(b(`epic target ${targetB} exists neither locally nor on origin - cut it first: ac-epic-branch.sh create <epic> ${repoName}`));
    bare(["branch", native(targetB), `refs/remotes/origin/${native(targetB)}`]);
  }
}
const targetN = native(targetB);

const head = git(["symbolic-ref", "--short", "HEAD"], "pipe", "ignore");
const currentB = subst(head.status === 0 ? head.out : Buffer.concat([head.out, Buffer.from("DETACHED")]));
if (epic) {
  if (currentB !== defB && currentB !== targetB)
    die(b(`primary checkout is on '${currentB}' - an epic landing needs it on '${defB}' or on the target '${targetB}'`));
} else if (currentB !== defB) die(b(`primary checkout is on '${currentB}', not '${defB}'`));

const status = gitValue(["status", "--porcelain", "-uno"]);
if (status !== "") {
  const paths = status
    .split("\n")
    .map((l) => (l.length >= 3 ? l.slice(3) : l))
    .join(" ");
  die(b(`primary checkout is dirty: ${paths} (commit, stash, or discard, then retry)`));
}

if (!resolves(`refs/heads/${branchN}`)) die(b(`branch ${branchB} not found in ${projectDir} (did the crewmate commit? worktree: ${worktree})`));

let landSha = "";
if (epic) {
  out(
    deferred
      ? "qa.require_for_ship: deferred to the feature ship gate (feature-branch landing)\n"
      : "qa.require_for_ship: deferred to the epic gate (epic-branch landing)\n",
  );
} else {
  landSha = gitValue(["rev-parse", `refs/heads/${branchN}`]);
  let open = false;
  try {
    open = qaGateOk(dir, landSha, id);
  } catch (e) {
    exitWith(e);
  }
  if (!open) die("local merge blocked by qa.require_for_ship (see message above)");
}

const family = familyOfId(id);
const diff = git(["diff", "--name-only", `${targetN}...refs/heads/${branchN}`], "pipe", "inherit").out.toString("latin1").split("\n");
diff.pop();
const landed = diff.map((p) => native(p.replace(/\0/g, "")));
try {
  if (landed.length > 0) landingWarn(family, landed);
} catch (e) {
  exitWith(e);
}
knowledgeWarn(family, dir);

const record = (): void => {
  let ok = true;
  try {
    if (landed.length > 0) ok = landingRecord(family, landed);
  } catch (e) {
    exitWith(e);
  }
  if (!ok) process.exit(1);
};
const appendStatus = (line: string): void => {
  let ok: boolean;
  try {
    ok = statusAppend(id, line, true);
  } catch (e) {
    exitWith(e);
  }
  if (!ok) process.exit(1);
};
const mergeHead = (): boolean => git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], "ignore", "inherit").status === 0;
const ancestor = (a: string, c: string): boolean => git(["merge-base", "--is-ancestor", a, c], "inherit", "inherit").status === 0;

if (noff === "--no-ff") {
  if (epic)
    die(
      b(
        `--no-ff is not available for an epic-branch landing: a merge commit onto ${targetB} belongs in a leased worktree, never the primary checkout - rebase ${branchB} onto ${targetB} and land ff, or route the merge through the epic gate`,
      ),
    );
  const m = git(["merge", "--no-ff", "--no-commit", "-m", `Merge branch '${branchN}'`, native(landSha)], "ignore", "pipe");
  if (m.status !== 0) {
    if (mergeHead()) {
      const u = git(["diff", "--name-only", "--diff-filter=U"], "pipe", "inherit");
      if (u.status !== 0) process.exit(u.status);
      const conflicts = subst(u.out).replace(/\n/g, " ").replace(/ $/, "");
      bare(["merge", "--abort"]);
      die(b(`--no-ff merge of ${branchB} conflicts on: ${conflicts} (checkout left clean on ${defB})`));
    }
    die(b(`--no-ff merge of ${branchB} never started: ${subst(m.err)} (checkout untouched, still clean on ${defB})`));
  }
  if (mergeHead()) {
    const c = git(["commit", "-q", "--no-edit"], "ignore", "pipe");
    if (c.status !== 0) {
      bare(["merge", "--abort"]);
      die(b(`--no-ff commit of ${branchB} was refused: ${subst(c.err)} (checkout restored, clean on ${defB})`));
    }
    record();
    appendStatus(`merged: local ${defB} (--no-ff)`);
    out(`merged ${branchB} into ${defB} (--no-ff)\n`);
  } else {
    record();
    appendStatus(`merged: local ${defB}`);
    out(`${defB} already contains ${branchB}; no merge commit created (--no-ff)\n`);
  }
} else {
  if (!ancestor(`refs/heads/${targetN}`, `refs/heads/${branchN}`) && !ancestor(`refs/heads/${branchN}`, `refs/heads/${targetN}`)) {
    if (epic)
      die(b(`${branchB} is not fast-forwardable: ${targetB} has diverged from it (a sibling story landed first). Rebase ${branchB} onto ${targetB} and re-run the plain land`));
    if (process.env.AC_CREW_ID || process.env.AC_SCOPE)
      die(
        b(
          `${branchB} is not fast-forwardable: ${defB} has diverged from it. --no-ff is not available here (the primary-checkout commit guard refuses it for a crewmate/roomchief) - rebase ${branchB} onto ${defB} and re-run the plain land, or hand the landing back to the crewchief`,
        ),
      );
    die(b(`${branchB} is not fast-forwardable: ${defB} has diverged from it. Land a conflict-free branch with 'ac-merge-local.sh ${idB} --no-ff', or rebase ${branchB} onto ${defB} first`));
  }
  if (epic) {
    if (ancestor(`refs/heads/${branchN}`, `refs/heads/${targetN}`)) out(`${targetB} already contains ${branchB}; nothing to move\n`);
    else if (currentB === targetB) {
      const m = git(["merge", "--ff-only", branchN], "ignore", "pipe");
      if (m.status !== 0) die(b(`ff of ${targetB} (checked out) from ${branchB} failed: ${subst(m.err)} (${targetB} untouched)`));
      out(`fast-forwarded ${targetB} to ${branchB} (in place)\n`);
    } else {
      const f = git(["fetch", "--quiet", ".", `refs/heads/${branchN}:refs/heads/${targetN}`], "ignore", "pipe");
      if (f.status !== 0) die(b(`ff update of ${targetB} from ${branchB} failed: ${subst(f.err)} (${targetB} untouched)`));
      out(`fast-forwarded ${targetB} to ${branchB} (ref-only)\n`);
    }
    if (epicPush && git(["remote", "get-url", "origin"], "ignore", "ignore").status === 0) {
      if (pushControlPlane(dir, ["--quiet", "origin", `refs/heads/${targetN}:refs/heads/${targetN}`], "ignore") === 0) out(`pushed ${targetB} to origin (record push=yes)\n`);
      else warn(b(`push of ${targetB} to origin FAILED - the landing stands; retry: git -C ${projectDir} push --no-verify origin ${targetB}`));
    }
    record();
    appendStatus(`merged: local ${targetB} (epic)`);
  } else {
    const noop = ancestor(native(landSha), `refs/heads/${defN}`);
    const m = git(["merge", "--ff-only", native(landSha)], "ignore", "pipe");
    if (m.status !== 0) die(b(`fast-forward of ${branchB} failed: ${subst(m.err)} (${defB} untouched)`));
    record();
    appendStatus(`merged: local ${defB}`);
    out(noop ? `${defB} already contains ${branchB}; nothing to move\n` : `fast-forwarded ${defB} to ${branchB}\n`);
  }
}
