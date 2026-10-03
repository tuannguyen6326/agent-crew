// epic-branch.ts - the per-epic INTEGRATION-BRANCH verbs (epic-branch-mech).
// The entry is bin/ac-epic-branch.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-epic-branch.sh as the oracle
// the differential leg of tests/sh/ac-epic-branch.test.sh holds this module to.
//
// A branch-recorded epic integrates its stories on one branch per repo before
// the whole ships. The RECORD is data/<epic>/branches (`<repo> <branch>
// [key=value ...]`, e.g. `push=yes staging=<b>`), chief-written on the
// captain's word and receipted DECIDED: to the epic room; ac_epic_branches_file
// / ac_epic_branch_entry (bin/ac-lib.sh) and their twins epicBranchesFile /
// epicBranchEntry (src/lib.ts) own its archive-aware resolution and the
// `# retired <iso>` end-marker semantics - two readers of one grammar, pinned
// to each other by tests/ts/epic-branch.test.ts. This module owns the verbs:
//
//   create <epic> <repo>   cut the recorded branch at the repo's freshest
//                          default tip (freshestRef - THE shared resolver).
//                          Origin-backed repo: fetch, then push the branch ref;
//                          no-origin repo: a local branch. Idempotent, and it
//                          NEVER moves an existing branch - exists = untouched.
//                          Refuses without a record entry: the record is the
//                          captain's word, the branch merely follows it.
//   verify <epic> <repo>   exit 0 iff the recorded, unretired branch exists
//                          (live ls-remote on origin repos; local show-ref on
//                          no-origin repos). Quiet - built to be gated on.
//   show   <epic>          the resolved record, verbatim, with its path.
//   retire <epic>          prepend `# retired <iso>` - the deliberate end of
//                          the fence (run at epic close). Idempotent. Nothing
//                          ever deletes the file: it is provenance.
//
// CHIEF-ONLY on the mutating verbs (create/retire), the domain_chief_only
// pattern: a PreToolUse hook cannot see a bash verb, so the guard lives here.
// A scoped chief (roomchief/domainchief) reads via show/verify and never
// mutates. Known residual, accepted: the record FILE sits in the family dir a
// promoted roomchief can edit - this fences the honest path, and the spawn
// fence enforces whatever the record says regardless of who wrote it.
//
// ORDER: arity first - create|verify take exactly 3 arguments, show|retire
// exactly 2, anything else (no verb, an unknown verb, a wrong count) is
//   ERROR: usage: ac-epic-branch.sh create|verify <epic> <repo> | show|retire <epic>
// on stderr, exit 1, before the home is touched. Then the fence (create and
// retire, `AC_SCOPE` non-empty):
//   ERROR: <verb> is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=<v>) - the integration branch is cut and retired on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it
// Then the record, through dataDir (a missing AC_HOME refuses there).
//
// RECORD refusals (create and verify, with their own verb as the prefix):
//   ERROR: <verb>: the <epic> record is retired (<first line of the record>) - a retired epic has no integration branch; re-record on the captain's word if the epic truly reopens
//   ERROR: <verb>: no record entry for <repo> under epic <epic> - write data/<epic>/branches first (the captain's word, receipted DECIDED: to the room)
// then `ERROR: no project clone at projects/<repo>` unless $AC_HOME/projects/
// <repo>/.git is a directory or a file. The branch is the entry's text before
// its first space.
//
// create, origin-backed (`git remote get-url origin` succeeds): `git fetch
// origin --quiet` (failing: `ERROR: create: fetch origin failed for <repo> - the
// branch must be cut at origin's real tip, not a stale mirror`); the branch on
// origin already (`ls-remote --exit-code`) prints
//   exists: <branch> on origin of <repo> (left untouched)
// exit 0; else the tip is `git rev-parse <freshestRef>` and is pushed with the
// pre-push hook skipped (pushControlPlane, `--quiet origin <sha>:refs/heads/
// <branch>`; failing: `ERROR: create: pushing <branch> to origin of <repo>
// failed`), then
//   created: <branch> on origin of <repo> at <sha>
// create, no origin: an existing local branch prints `exists: <branch> in
// <repo> (left untouched)`; else `git branch <branch> <freshestRef>` and
//   created: <branch> in <repo> (local-only repo)
// verify prints NOTHING on success; the branch missing is
//   ERROR: verify: <branch> is not on origin of <repo> - create it (ac-epic-branch.sh create <epic> <repo>) before any story spawns against it
//   ERROR: verify: <branch> does not exist in <repo> - create it (ac-epic-branch.sh create <epic> <repo>) before any story spawns against it
// show prints `# <resolved path>` then the record's bytes verbatim; no record
// live or archived is `ERROR: show: no branches record for epic <epic> (live
// or archived) - this epic was never branch-recorded`. It works on a retired
// record and in a scoped session. retire: no record is `ERROR: retire: no
// branches record for epic <epic> - nothing to retire`; a first line already
// `# retired...` prints `already retired: <first line>` exit 0; else the file
// is rewritten in place (an archived record under data/archive/ too) as
// `# retired <date -u +%Y-%m-%dT%H:%M:%SZ>` + its old bytes and
//   retired: epic <epic> record at <path>
//
// EXIT: 0; 1 on every refusal above (`ERROR:` on stderr). git is spawned with
// the original's arguments: fetch, push and `git branch` keep their stdout and
// stderr (fetch and push `--quiet`), and a failing `git branch` or `git
// rev-parse` ends the run with git's own status and message, as errexit did.
// Record bytes are echoed as bytes (the branch in every line, show's cat).
//
// DIVERGENCES from the original, named in the differential leg: a missing
// AC_HOME is refused once and nothing more is said (the original printed the
// refusal twice and ran on to the verb's no-record line); an unreadable
// AC_HOME names the variable (the shell's own `cd:` line is not reproduced);
// retire keeps the record's mode (the original's mktemp+mv left it 0600 - the
// temp file's mode, not the record's); the tool-own lines of an unreadable
// record (head/awk/cat) are not reproduced, its exit status is; the archive
// years are read in byte order under any locale.
import { chmodSync, readFileSync, renameSync, statSync, writeFileSync, writeSync } from "node:fs";
import { dataDir, die, enterCaller, epicBranchEntry, epicBranchesFile, freshestRef, pushControlPlane } from "./lib.ts";

const b = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const native = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const out = (s: string): void => {
  writeSync(1, b(s));
};
function git(dir: string, args: string[], io: "inherit" | "ignore"): number {
  return Bun.spawnSync(["git", "-C", dir, ...args], { stdout: io, stderr: io }).exitCode ?? 1;
}

function chiefOnly(verb: string): void {
  const scope = process.env.AC_SCOPE;
  if (scope)
    die(
      `${verb} is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=${scope}) - the integration branch is cut and retired on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it`,
    );
}

function repoDir(repo: string): string {
  const d = `${process.env.AC_HOME}/projects/${repo}`;
  try {
    const s = statSync(`${d}/.git`);
    if (s.isDirectory() || s.isFile()) return d;
  } catch {}
  die(`no project clone at projects/${repo}`);
}

const hasOrigin = (dir: string): boolean => git(dir, ["remote", "get-url", "origin"], "ignore") === 0;

// `$(head -1 f)`: the first line, its newline dropped. Throws where head could
// not read the file.
const firstLine = (f: string): string => readFileSync(f, "latin1").split("\n")[0]!;

// The entry as bytes; dies with the verb's own remedy on a missing record or
// entry, naming the retirement on rc 2.
function entryOrDie(verb: string, epic: string, repo: string): string {
  const r = epicBranchEntry(epic, repo);
  if (r.rc === 0) return r.entry;
  if (r.rc === 2)
    die(
      b(
        `${verb}: the ${bytes(epic)} record is retired (${firstLine(epicBranchesFile(epic)!)}) - a retired epic has no integration branch; re-record on the captain's word if the epic truly reopens`,
      ),
    );
  die(`${verb}: no record entry for ${repo} under epic ${epic} - write data/${epic}/branches first (the captain's word, receipted DECIDED: to the room)`);
}

function cmdCreate(epic: string, repo: string): void {
  chiefOnly("create");
  const branch = entryOrDie("create", epic, repo).split(" ")[0]!;
  const dir = repoDir(repo);
  const ref = `refs/heads/${native(branch)}`;
  if (hasOrigin(dir)) {
    if (git(dir, ["fetch", "origin", "--quiet"], "inherit") !== 0)
      die(`create: fetch origin failed for ${repo} - the branch must be cut at origin's real tip, not a stale mirror`);
    if (git(dir, ["ls-remote", "--exit-code", "origin", ref], "ignore") === 0) {
      out(`exists: ${branch} on origin of ${bytes(repo)} (left untouched)\n`);
      return;
    }
    const r = Bun.spawnSync(["git", "-C", dir, "rev-parse", freshestRef(dir)], { stdout: "pipe", stderr: "inherit" });
    if (r.exitCode !== 0) process.exit(r.exitCode ?? 1);
    const sha = r.stdout.toString().replace(/\n+$/, "");
    if (pushControlPlane(dir, ["--quiet", "origin", `${sha}:${ref}`]) !== 0) die(b(`create: pushing ${branch} to origin of ${bytes(repo)} failed`));
    out(`created: ${branch} on origin of ${bytes(repo)} at ${sha}\n`);
  } else {
    if (git(dir, ["show-ref", "--verify", "--quiet", ref], "inherit") === 0) {
      out(`exists: ${branch} in ${bytes(repo)} (left untouched)\n`);
      return;
    }
    const rc = git(dir, ["branch", native(branch), freshestRef(dir)], "inherit");
    if (rc !== 0) process.exit(rc);
    out(`created: ${branch} in ${bytes(repo)} (local-only repo)\n`);
  }
}

function cmdVerify(epic: string, repo: string): void {
  const branch = entryOrDie("verify", epic, repo).split(" ")[0]!;
  const dir = repoDir(repo);
  const ref = `refs/heads/${native(branch)}`;
  if (hasOrigin(dir)) {
    if (git(dir, ["ls-remote", "--exit-code", "origin", ref], "ignore") !== 0)
      die(b(`verify: ${branch} is not on origin of ${bytes(repo)} - create it (ac-epic-branch.sh create ${bytes(epic)} ${bytes(repo)}) before any story spawns against it`));
  } else if (git(dir, ["show-ref", "--verify", "--quiet", ref], "inherit") !== 0) {
    die(b(`verify: ${branch} does not exist in ${bytes(repo)} - create it (ac-epic-branch.sh create ${bytes(epic)} ${bytes(repo)}) before any story spawns against it`));
  }
}

function cmdShow(epic: string): void {
  const f = epicBranchesFile(epic);
  if (f === null) die(`show: no branches record for epic ${epic} (live or archived) - this epic was never branch-recorded`);
  out(`# ${bytes(f)}\n`);
  let body: Buffer;
  try {
    body = readFileSync(f);
  } catch {
    process.exit(1);
  }
  writeSync(1, body);
}

function cmdRetire(epic: string): void {
  chiefOnly("retire");
  const f = epicBranchesFile(epic);
  if (f === null) die(`retire: no branches record for epic ${epic} - nothing to retire`);
  let old: Buffer;
  try {
    old = readFileSync(f);
  } catch {
    process.exit(1);
  }
  const head = old.toString("latin1").split("\n")[0]!;
  if (head.startsWith("# retired")) {
    out(`already retired: ${head}\n`);
    return;
  }
  const stamp = Bun.spawnSync(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdout: "pipe", stderr: "inherit" }).stdout.toString().replace(/\n+$/, "");
  // A sibling temp file renamed over the record, so a reader mid-write sees
  // the old record or the new one, never a torn one. Created exclusively, as
  // mktemp did: a path already at the name (a symlink back to the record,
  // say) is never written through - the next name is tried.
  const retired = Buffer.concat([Buffer.from(`# retired ${stamp}\n`), old]);
  let tmp = `${f}.retire`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, retired, { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      tmp = `${f}.retire.${i}`;
    }
  }
  chmodSync(tmp, statSync(f).mode & 0o7777);
  renameSync(tmp, f);
  out(`retired: epic ${bytes(epic)} record at ${bytes(f)}\n`);
}

const usage = (): never => die("usage: ac-epic-branch.sh create|verify <epic> <repo> | show|retire <epic>");

const { args } = enterCaller(process.argv.slice(2));
switch (args[0]) {
  case "create":
    if (args.length !== 3) usage();
    cmdCreate(args[1]!, args[2]!);
    break;
  case "verify":
    if (args.length !== 3) usage();
    cmdVerify(args[1]!, args[2]!);
    break;
  case "show":
    if (args.length !== 2) usage();
    cmdShow(args[1]!);
    break;
  case "retire":
    if (args.length !== 2) usage();
    cmdRetire(args[1]!);
    break;
  default:
    usage();
}
