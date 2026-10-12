// feature.ts - the FEATURE integration-branch verbs (feature-branch-mech). The
// entry is bin/ac-feature.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-feature.sh as the oracle the
// differential leg of tests/sh/ac-feature.test.sh holds this module to.
//
// A feature accumulates SEVERAL crew tasks on one branch per repo that stays
// LOCAL until ship: create cuts it at the recorded target's freshest tip and
// never pushes; member rows bind with the `feature:<name>` ledger token
// (src/backlog.ts's feature field) and land onto the branch through the
// ordinary ac-merge-local path via the shared resolver (ac_epic_base_for);
// `ship` publishes the branch ONCE and opens one PR per repo to the recorded
// target. The design pins: a standalone mechanism reusable by
// epic-branch-mech; many tasks per feature; one review/QA gate at the tip
// before push; the target is captain-recorded.
//
// The RECORD is data/<feature>/branches - `<repo> <branch> [target=<branch>]
// push=deferred`, one line per repo - chief-written on the captain's word and
// receipted DECIDED: to the feature room. epicBranchesFile / epicBranchEntry
// (src/lib.ts, the twins of the bash pair orca's fence still reads) resolve it
// live-then-archived exactly as an epic record: the FILE shape is shared, and
// `push=deferred` on the entry is what marks it a FEATURE entry - the
// ac-tree.sh fence and this module both key on it, and an entry without it is
// an epic-shaped record these verbs refuse toward ac-epic-branch.sh. `target`
// defaults to the repo's default branch.
//
//   create <feature> <repo>          cut the recorded branch LOCALLY at the
//                                    freshest tip of its target; NEVER pushes
//                                    (deferred publication is the mode's
//                                    defining property). Idempotent, and it
//                                    never moves an existing branch.
//   verify <feature> <repo>          exit 0 iff the recorded, unretired branch
//                                    exists LOCALLY - a deferred-push branch
//                                    judged on origin would fail every
//                                    pre-ship verify. Quiet, built to be
//                                    gated on.
//   show   <feature>                 src/epic-branch.ts's show - the record
//                                    verbs are kind-agnostic.
//   retire <feature>                 src/epic-branch.ts's retire (its own
//                                    chief-only fence).
//   ship   <feature> <repo> [--dry-run]
//                                    the gated exit, SHIP below.
//
// ORDER: arity first, before the home or the fence - create|verify take
// exactly 3 arguments, show|retire exactly 2, ship 3, or 4 with the 4th
// exactly `--dry-run` (as the 3rd it is a repo name); else, on stderr, exit 1:
//   ERROR: usage: ac-feature.sh create <feature> <repo>          (verify alike)
//   ERROR: usage: ac-feature.sh <show|retire> <feature>
//   ERROR: usage: ac-feature.sh ship <feature> <repo> [--dry-run]
//   ERROR: usage: ac-feature.sh create|verify <feature> <repo> | show|retire <feature> | ship <feature> <repo> [--dry-run]
// the last for no verb, an empty or an unknown one. show|retire then run
// src/epic-branch.ts as a bun child (bunChild's command and cwd, started
// through `env -u <each BUN_*/JSC_* name>` so the child gets this process's
// environment BYTES less the names ac-bun.sh unsets) with the verb and the
// feature, stdio inherited, and exit with its status - that module's header
// is their spec, homeless included. Then CHIEF-ONLY on create and ship, before anything
// is read (a PreToolUse hook cannot see a bash verb, so the guard lives here) -
// AC_SCOPE non-empty:
//   ERROR: <verb> is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=<v>) - the feature branch is cut and shipped on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it
// ship then needs jq on PATH (`ERROR: required tool not found: jq`).
//
// THE ENTRY, each verb with its own name as <verb>:
//   ERROR: <verb>: the <feature> record is retired (<its first line>) - a retired feature has no integration branch; re-record on the captain's word if the feature truly reopens
//   ERROR: <verb>: no record entry for <repo> under feature <feature> - write data/<feature>/branches first (the captain's word, receipted DECIDED: to the room): '<repo> <branch> [target=<branch>] push=deferred'
//   ERROR: <verb>: the <feature> entry for <repo> carries no push=deferred key - that is an epic-shaped record, not a feature entry; a FEATURE branch stays local until ship (add push=deferred on the captain's word, or use ac-epic-branch.sh for an epic record)
// The entry is epicBranchEntry's `<branch> [key=value ...]`, fields rejoined by
// single spaces (a TAB-separated record reads fine; the repo's first line
// wins; a numeric repo matches numerically, `07` reading the `7` line).
// push=deferred is a whole token AFTER the branch - a branch named so is no
// key. Then the clone: <home>/projects/<repo> with `.git` a directory or a
// file (a linked worktree), else `ERROR: no project clone at projects/<repo>`.
// The target is the value of the FIRST ` target=` token up to the next space;
// an absent or EMPTY one (`target= `, W4, kept) is defaultBranch's answer.
//
// create, on stdout, exit 0 unless noted:
// - refs/heads/<branch> exists: `exists: <branch> in <repo> (left untouched)`.
// - an origin (`git remote get-url origin`) is fetched first, `git fetch
//   origin --quiet`; failing:
//   ERROR: create: fetch origin failed for <repo> - the branch must be cut at the target's real tip, not a stale mirror
// - the target is neither refs/heads/<t> nor refs/remotes/origin/<t>:
//   ERROR: create: target branch <t> resolves nowhere in <repo> - the record names a target that does not exist
// - `git branch <branch> <freshestRef(target)>`, whose failure ends the run
//   with git's status and lines; cut from origin/<t>, git's own `branch '<b>'
//   set up to track 'origin/<t>'.` comes first on stdout (W7, kept), then
//   `created: <branch> in <repo> at the tip of <target> (LOCAL - deferred push)`.
// verify prints nothing, exit 0, when refs/heads/<branch> exists; else
//   ERROR: verify: <branch> does not exist locally in <repo> - a feature branch lives LOCALLY until ship; create it (ac-feature.sh create <feature> <repo>) before any member spawns against it
//
// SHIP - the gated exit: ONE review/QA gate at the tip, before push. Every
// precondition fails closed, in this order - the verb REFUSES with the exact
// remedy instead of doing a lesser thing - each `ERROR:` exit 1 unless noted:
//   1. RECORD: the entry, the clone and the target as above, then verify's
//      check with its refusal verbatim.
//   2. MEMBERS: records/backlog.md as bytes, split into awk's records
//      (src/backlog.ts records(): on LF, an unterminated last line kept, a
//      NUL ending its record), every one starting `- [` in any section, in
//      ledger order, its fields acDoneline's. The container (id = the
//      feature) and rows whose `feature` is another (byte equality) are
//      skipped; a member carrying `epic:` refuses AT ONCE, ahead of any open
//      member:
//        ERROR: member <id> carries epic:<e> BESIDE feature:<feature> - two integration targets on one row is a ledger defect; fix the row before the exit
//      a member whose line does not start `- [x]` is open (`- [X]` too - W14:
//      the parser reads that row's id as `-`); a checked member whose
//      terminal is failed|abandoned is partial. Open members:
//        ERROR: feature <feature> has non-terminal members: <id> <id> - every member lands (or is failed/abandoned by the captain) before the feature ships
//      The partial ids are the words of the original's unquoted `for p in
//      $partials`: an id holding a glob character is expanded by bash itself
//      against the caller's cwd (W16, kept: `fa*` is the cwd's `fab fac`;
//      a cwd with no name expands nothing), and a bash that cannot do it
//      ends the run with its status. Each partial member needs a line in
//      roomFile(<feature>)'s room (the
//      live room, else the archived one) that a spawned `grep -q` finds for
//      the BRE `DECIDED: feature-ship partial - <id> ` - the trailing space is
//      grammar (W8: a receipt ending at the id is none) and the id a pattern
//      (W15: its `.` matches any byte), both kept:
//        ERROR: partial feature: [failed]/[abandoned] members need a captain revert-or-keep receipt in the room - <id> <id> - post the GATE:/ASK:, record the captain's answer as 'DECIDED: feature-ship partial - <id> revert|keep <words>', then re-run
//      A ledger that cannot be read (missing, unreadable) ends the run with
//      exit 2 and nothing printed (W1); one that is a directory holds no
//      record, as awk read it, and the ship goes on.
//   3. NO TARGET DRIFT: `git fetch origin --quiet`, its stderr and failure
//      dropped; tip = `rev-parse refs/heads/<branch>`, target tip =
//      `rev-parse <freshestRef(target)>`, either failing ending the run with
//      git's status and lines (a target that resolves nowhere is git's 128);
//      the target tip must be an ancestor of the tip:
//        ERROR: feature <branch> is behind its target <target> - rebase the branch onto <target> in a LEASED worktree on the captain's word (never the primary checkout, never automatic), re-run the review round at the new tip, then re-run the ship
//      base = `merge-base <target tip> <tip>`, its failure likewise.
//   4. REVIEW AT THE LOCAL TIP: data/<feature>/gate/review.json, an ac-verify
//      codereview output; <cmd> below is
//        bin/ac-verify.sh codereview --repo <clone> --ref <tip> --family <feature> --caller <your AC_CREW_ID> --base <base> --intent <data>/<feature>/room.md --output <data>/<feature>/gate/review.json
//      No regular file there:
//        ERROR: no feature review round on record - run ONE independent round over the whole integration diff first: <cmd>
//      `jq -r '.reviewed_ref // ""'` must print the tip, its stdout read as a
//      command substitution reads it and nothing more on failure (null, false,
//      unparseable and unreadable all read as none - W3; a number prints as
//      jq spells it; two JSON values print two lines):
//        ERROR: the recorded review round is for ref <ref, or <none>>, not the current tip <tip> - the tip moved, run a fresh round: <cmd>
//      `jq -r '[.findings[]? | select(.action == "fix")] | length'` must print
//      exactly `0` - its stdout with `ERR` appended when jq fails (W2: an
//      element jq cannot index is `ERR`, a clean value before a broken one
//      `0<LF>ERR`; findings that are no array count 0):
//        ERROR: the feature review round left <n> open fix finding(s) - fix on the feature branch (the ref change invalidates the round) and run a fresh round: <cmd>
//      A fix lands as its own member onto the branch, then ship re-runs at
//      the new tip.
//   5. QA WHEN PINNED: the ledger read again; the contract of the FIRST `- [`
//      row whose id equals the feature as `awk -v` reads it (string equality:
//      `07` is not `7`), holding `qa:yes` as a space- or TAB-joined token,
//      needs a crew-qa pass attestation: some name under
//      <clone>/.crew/qa/passed/ STARTING with the tip (W10, a prefix:
//      `<tip>junk` counts), every match handed to a spawned `ls` whose success
//      is the answer (an unreadable directory is none):
//        ERROR: the container row pins qa:yes and no crew-qa pass attestation exists for the tip <tip> - run one behavioral round against the BUILT feature branch (crew-qa skill / bin/ac-qa.sh agent --target <tip> ...)
// Then THE EXIT, in order:
// - no origin:
//     ERROR: feature-ship needs an origin remote on <repo> - a local-only repo has no PR to open (land it by captain merge instead)
// - `mkdir -p <data>/<feature>/gate`, spawned; its failure ends the run with
//   its status.
// - The url slot is PER REPO: ships.env keys pr_url_<repo> with every byte
//   outside [a-zA-Z0-9] folded to `_` (W5: per BYTE, `é` is `__`), because a
//   multi-repo feature ships one PR per repo. The fold is not one-to-one, so
//   a record holding two repos that fold to one key is refused, never
//   guessed - the record's lines through a spawned `grep -v '^#'`, each read
//   as `read -r other _` reads it (leading blanks dropped, the first
//   space/TAB-delimited field; grep terminates an unterminated last line):
//     ERROR: ship: repos <repo> and <other> of feature <feature> share the ships.env key <key> - one url slot cannot tell their PRs apart; re-record one of them under a distinct name (the captain's word) before shipping
// - ships.env as `ac_meta_get ... 2>/dev/null || printf ''` read it
//   (shipsUrl: the LAST `<key>=` line wins, an empty last value or a file
//   that cannot be read is none, a NUL ends awk's record - W17, `<key><NUL>x`
//   is the bare key): a recorded url prints `PR already recorded: <url>`,
//   exit 0 - re-runs are idempotent. A bare legacy `pr_url=` is ignored: it cannot be
//   attributed to a repo, and gh itself refuses a duplicate head PR loudly.
// - --dry-run prints, exit 0:
//     DRY-RUN: git -C <clone> push origin refs/heads/<branch>:refs/heads/<branch>
//     DRY-RUN: gh pr create --base <target> --head <branch> --title "feature(<feature>): <branch> -> <target>" (in <clone>)
// - else `git -C <clone> push origin refs/heads/<b>:refs/heads/<b>` WITH the
//   pre-push hook (the ONE deferred publication, an AGENTS.md section-1
//   sanctioned write - never pushControlPlane), its failure ending the run
//   with git's status and lines and none of ours; then, in the clone,
//     gh pr create --base <target> --head <branch> --title "feature(<feature>): <branch> -> <target>" --body "Feature branch `<branch>` of `<feature>` -> `<target>`. Opened by ac-feature.sh ship after the feature gate (members terminal, review round clean at <tip>). The captain merges."
//   its stderr passing through, its stdout the url (trailing newlines cut);
//   failing - the branch is already published by then:
//     ERROR: gh pr create failed for <branch> -> <target>
//   then `<key>=<url>` appended to ships.env (a failed append ends the run,
//   exit 1), `ac-room.sh post <feature> crewchief "SHIPS: pr <url> (<repo>,
//   feature-ship)"` from this module's own bin/ (io dropped, status ignored),
//   and `opened pr: <url>`. This verb NEVER merges - the captain does.
// KNOWN RESIDUAL on a multi-repo feature: gate/review.json is one slot for the
// whole feature, so each repo's ship needs the review round re-run at ITS tip
// before its exit - loud (the ref-mismatch refusal names it), never silent.
//
// EXIT: 0; 1 on every refusal; 2 for a ledger that cannot be read; git's own
// status where its failure ends the run - 128+signal for any child a signal
// ended, 127 for one that could not start (a gh that cannot start is the gh
// refusal). Every child is spawned with the original's argv and io and
// inherits the caller's stdin. The record, the ledger, the room, git's and
// gh's output and ships.env are bytes, and every line built from them is
// written as those bytes.
//
// DIVERGENCES from the original, named in the differential leg:
// - W6: homeless, create/verify/ship refuse ONCE with the AC_HOME refusal,
//   where the original printed it twice (a swallowed `$(ac_data_dir)` per
//   record rung) and then the no-entry remedy; an AC_HOME cd cannot enter is
//   `AC_HOME is not a readable directory: <h>` once, where the shell printed
//   cd's own lines and the remedy (exit 1 everywhere).
// - W1: the ledger awk's own `can't open file` lines are not reproduced, its
//   exit 2 is.
// - W12 (the HOME RESOLUTION ruling): the clone is joined onto the PHYSICAL
//   home, so under a symlinked AC_HOME the DRY-RUN lines and <cmd> name the
//   physical clone where the original named AC_HOME as spelled.
// - bash's own stderr is not reproduced: the job line of a child a signal
//   ended (`Terminated: 15`), `gh: command not found`, a failed append's
//   redirection line.
// - argv and env arrive decoded: a byte that is not UTF-8 in an argument
//   reaches this module as U+FFFD, and a branch, target or member id that is
//   not UTF-8 is spawned decoded; a url gh printed that is not UTF-8 is
//   recorded and printed as its bytes and reaches the room as its U+FFFD
//   spelling - the room entry decodes its argv the same way from either
//   side; a passed/ name that is not UTF-8 reaches ls decoded and fails.
//
// CALLERS: no bin/, src/, dashboard/ or hook runs this entry -
// bin/ac-tree.sh, bin/ac-merge-local.sh, bin/ac-backend-orca.sh and
// bin/ac-brief.sh name it in a remedy, the skills and docs in prose; chiefs run
// it by hand on the captain's word. A bun-less run answers `ERROR: required
// tool not found: bun`, exit 1, from the shim, to that hand - no `set -e`
// caller dies silently, so nothing fails soft.
import { appendFileSync, readdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { resolve } from "node:path";
import { acDoneline, records } from "./backlog.ts";
import {
  awkAssign,
  bunChild,
  dataDir,
  defaultBranch,
  die,
  enterCaller,
  envHome,
  epicBranchEntry,
  epicBranchesFile,
  freshestRef,
  recordsDir,
  require,
  roomFile,
  spawnShellSync,
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

// The shell's status for a child: its exit, 128+signal, 127 when it could not
// start. stdin is the caller's, as it was for every child of the bash.
function run(cmd: string[], stdout: Io, stderr: Io, opts: { cwd?: string } = {}): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync>;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout, stderr, cwd: opts.cwd });
  } catch {
    return { status: 127, out: Buffer.alloc(0) };
  }
  const sig = r.signalCode ? (osConstants.signals as Record<string, number>)[r.signalCode] ?? 0 : 0;
  return { status: r.exitCode ?? 128 + sig, out: stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

const git = (dir: string, args: string[], stdout: Io, stderr: Io): number => run(["git", "-C", dir, ...args], stdout, stderr).status;

// A bare `x="$(git ...)"` under errexit: git's lines pass, its failure ends the run.
function gitValue(dir: string, args: string[]): string {
  const r = run(["git", "-C", dir, ...args], "pipe", "inherit");
  if (r.status !== 0) process.exit(r.status);
  return subst(r.out);
}

export type Member = { id: string; feature: string; epic: string; terminal: string; line: string };

// The member awk: `index($0, "- [") == 1 { ac_doneline($0, f); print ... $0 }`.
export function memberRows(text: string): Member[] {
  const rows: Member[] = [];
  for (const line of records(text)) {
    if (!line.startsWith("- [")) continue;
    const f = acDoneline(line);
    rows.push({ id: f.id, feature: f.feature, epic: f.epic, terminal: f.terminal, line });
  }
  return rows;
}

// The container awk: `BEGIN { w[want] } /^- \[/ { ...; if (f["id"] in w) { print
// f["contract"]; exit } }` run with `-v want=<feature>` - `in`, never `==`,
// because awk compares numeric-looking ids as numbers (07 == 7).
export function containerContract(text: string, want: string): string {
  const w = awkAssign(want);
  for (const line of records(text)) {
    if (!line.startsWith("- [")) continue;
    const f = acDoneline(line);
    if (f.id === w) return f.contract;
  }
  return "";
}

// awk's reading: a directory operand is input with no record in it.
function readLedger(file: string): string {
  try {
    return readFileSync(file, "latin1");
  } catch (e) {
    if ((e as { code?: string }).code === "EISDIR") return "";
    process.exit(2);
  }
}

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

// `ac_meta_get <ships> <key> 2>/dev/null || printf ''`. The records are
// awk's, so a NUL ends one: `<key><NUL>junk` is the bare key, read as none,
// where metaGet would read on past the NUL.
function shipsUrl(file: string, key: string): string {
  let text = "";
  try {
    if (statSync(file).isFile()) text = readFileSync(file, "latin1");
  } catch {}
  let v = "";
  for (const r of records(text)) if (r.split("=")[0] === key) v = r.slice(key.length + 1);
  return v;
}

function chiefOnly(verb: string): void {
  const scope = process.env.AC_SCOPE;
  if (scope)
    die(
      `${verb} is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=${scope}) - the feature branch is cut and shipped on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it`,
    );
}

function repoDir(repo: string): string {
  const d = `${envHome()}/projects/${repo}`;
  try {
    const s = statSync(`${d}/.git`);
    if (s.isDirectory() || s.isFile()) return d;
  } catch {}
  die(`no project clone at projects/${repo}`);
}

const hasOrigin = (dir: string): boolean => git(dir, ["remote", "get-url", "origin"], "ignore", "ignore") === 0;

// `${entry#"${entry%% *}"}`: the entry past its branch, leading space kept.
const keys = (entry: string): string => (entry.includes(" ") ? entry.slice(entry.indexOf(" ")) : "");

function entryOrDie(verb: string, feature: string, repo: string): string {
  const r = epicBranchEntry(feature, repo);
  if (r.rc === 2) {
    const first = readFileSync(epicBranchesFile(feature)!, "latin1").split("\n")[0]!.replace(/\0/g, "");
    die(
      b(
        `${verb}: the ${bytes(feature)} record is retired (${first}) - a retired feature has no integration branch; re-record on the captain's word if the feature truly reopens`,
      ),
    );
  }
  if (r.rc === 1)
    die(
      `${verb}: no record entry for ${repo} under feature ${feature} - write data/${feature}/branches first (the captain's word, receipted DECIDED: to the room): '<repo> <branch> [target=<branch>] push=deferred'`,
    );
  if (!` ${keys(r.entry)} `.includes(" push=deferred "))
    die(
      `${verb}: the ${feature} entry for ${repo} carries no push=deferred key - that is an epic-shaped record, not a feature entry; a FEATURE branch stays local until ship (add push=deferred on the captain's word, or use ac-epic-branch.sh for an epic record)`,
    );
  return r.entry;
}

function entryTarget(entry: string, dir: string): string {
  const rest = ` ${keys(entry)} `;
  const i = rest.indexOf(" target=");
  const target = i < 0 ? "" : rest.slice(i + " target=".length).split(" ")[0]!;
  return target || bytes(defaultBranch(dir));
}

function cmdCreate(feature: string, repo: string): void {
  chiefOnly("create");
  const entry = entryOrDie("create", feature, repo);
  const branch = entry.split(" ")[0]!;
  const dir = repoDir(repo);
  const target = entryTarget(entry, dir);
  if (git(dir, ["show-ref", "--verify", "--quiet", `refs/heads/${native(branch)}`], "inherit", "inherit") === 0) {
    out(`exists: ${branch} in ${bytes(repo)} (left untouched)\n`);
    return;
  }
  if (hasOrigin(dir) && git(dir, ["fetch", "origin", "--quiet"], "inherit", "inherit") !== 0)
    die(`create: fetch origin failed for ${repo} - the branch must be cut at the target's real tip, not a stale mirror`);
  const t = native(target);
  if (
    git(dir, ["rev-parse", "--verify", "--quiet", `refs/heads/${t}`], "ignore", "ignore") !== 0 &&
    git(dir, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${t}`], "ignore", "ignore") !== 0
  )
    die(b(`create: target branch ${target} resolves nowhere in ${bytes(repo)} - the record names a target that does not exist`));
  const s = git(dir, ["branch", native(branch), freshestRef(dir, t)], "inherit", "inherit");
  if (s !== 0) process.exit(s);
  out(`created: ${branch} in ${bytes(repo)} at the tip of ${target} (LOCAL - deferred push)\n`);
}

function cmdVerify(feature: string, repo: string): void {
  const branch = entryOrDie("verify", feature, repo).split(" ")[0]!;
  const dir = repoDir(repo);
  if (git(dir, ["show-ref", "--verify", "--quiet", `refs/heads/${native(branch)}`], "inherit", "inherit") !== 0)
    die(
      b(
        `verify: ${branch} does not exist locally in ${bytes(repo)} - a feature branch lives LOCALLY until ship; create it (ac-feature.sh create ${bytes(feature)} ${bytes(repo)}) before any member spawns against it`,
      ),
    );
}

// `$(jq -r <filter> <file> 2>/dev/null || printf <fallback>)`.
function jq(filter: string, file: string, fallback: string): string {
  const r = run(["jq", "-r", filter, file], "pipe", "ignore");
  return subst(r.status === 0 ? r.out : Buffer.concat([r.out, b(fallback)]));
}

// `ls "<passed>/<tip>"* >/dev/null 2>&1`: the glob's matches handed to ls,
// whose status is the answer; no match left the pattern, which names nothing.
function attested(dir: string, tip: string): boolean {
  const passed = `${dir}/.crew/qa/passed`;
  let names: string[] = [];
  try {
    names = readdirSync(passed);
  } catch {}
  const hits = names.filter((n) => n.startsWith(tip)).map((n) => `${passed}/${n}`);
  return hits.length > 0 && run(["ls", ...hits], "ignore", "ignore").status === 0;
}

const fold = (s: string): string => s.replace(/[^a-zA-Z0-9]/g, "_");

// `for p in $partials`: no id holds a blank, so the words are the ids, and an
// id with no pattern character is itself. The pathname expansion of the rest
// is bash's own (glob syntax, locale and match order included), so bash
// performs it. `set -f` where enterCaller could not return to the caller's
// cwd: the bash globbed a directory with no name, which held nothing, where
// this process sits in the distro root. The expansion was the shell's own
// step, with no status to fail; a bash that cannot do it here ends the run.
function partialWords(list: string, atCaller: boolean): string[] {
  const script = `${atCaller ? "" : "set -f; "}for p in $1; do printf '%s\\0' "$p"; done`;
  return list
    .split(" ")
    .filter((w) => w !== "")
    .flatMap((w) => {
      if (!/[*?[\\]/.test(w)) return [w];
      const r = run(["bash", "-c", script, "ac-feature.sh", native(w)], "pipe", "inherit");
      if (r.status !== 0) process.exit(r.status);
      const words = r.out.toString("latin1").split("\0");
      words.pop();
      return words;
    });
}

function cmdShip(feature: string, repo: string, dry: boolean, atCaller: boolean): void {
  chiefOnly("ship");
  require("jq");
  const entry = entryOrDie("ship", feature, repo);
  const branch = entry.split(" ")[0]!;
  const dir = repoDir(repo);
  const target = entryTarget(entry, dir);
  cmdVerify(feature, repo);
  const fb = bytes(feature);
  const rb = bytes(repo);

  const ledger = `${recordsDir()}/backlog.md`;
  let open = "";
  const partials: string[] = [];
  for (const m of memberRows(readLedger(ledger))) {
    if (m.id === fb || m.feature !== fb) continue;
    if (m.epic !== "")
      die(b(`member ${m.id} carries epic:${m.epic} BESIDE feature:${fb} - two integration targets on one row is a ledger defect; fix the row before the exit`));
    if (!m.line.startsWith("- [x]")) {
      open += ` ${m.id}`;
      continue;
    }
    if (m.terminal === "failed" || m.terminal === "abandoned") partials.push(m.id);
  }
  if (open !== "")
    die(b(`feature ${fb} has non-terminal members:${open} - every member lands (or is failed/abandoned by the captain) before the feature ships`));
  if (partials.length > 0) {
    const room = roomFile(feature);
    let missing = "";
    for (const p of partialWords(partials.join(" "), atCaller)) if (run(["grep", "-q", native(`DECIDED: feature-ship partial - ${p} `), room], "ignore", "ignore").status !== 0) missing += ` ${p}`;
    if (missing !== "")
      die(
        b(
          `partial feature: [failed]/[abandoned] members need a captain revert-or-keep receipt in the room -${missing} - post the GATE:/ASK:, record the captain's answer as 'DECIDED: feature-ship partial - <id> revert|keep <words>', then re-run`,
        ),
      );
  }

  git(dir, ["fetch", "origin", "--quiet"], "inherit", "ignore");
  const tip = gitValue(dir, ["rev-parse", `refs/heads/${native(branch)}`]);
  const targetTip = gitValue(dir, ["rev-parse", freshestRef(dir, native(target))]);
  if (git(dir, ["merge-base", "--is-ancestor", targetTip, tip], "inherit", "inherit") !== 0)
    die(
      b(
        `feature ${branch} is behind its target ${target} - rebase the branch onto ${target} in a LEASED worktree on the captain's word (never the primary checkout, never automatic), re-run the review round at the new tip, then re-run the ship`,
      ),
    );
  const base = gitValue(dir, ["merge-base", targetTip, tip]);

  const gateDir = `${dataDir()}/${feature}/gate`;
  const review = `${gateDir}/review.json`;
  const reviewCmd = `bin/ac-verify.sh codereview --repo ${bytes(dir)} --ref ${tip} --family ${fb} --caller <your AC_CREW_ID> --base ${base} --intent ${bytes(dataDir())}/${fb}/room.md --output ${bytes(review)}`;
  if (!isFile(review)) die(b(`no feature review round on record - run ONE independent round over the whole integration diff first: ${reviewCmd}`));
  const rRef = jq('.reviewed_ref // ""', review, "");
  if (rRef !== tip) die(b(`the recorded review round is for ref ${rRef || "<none>"}, not the current tip ${tip} - the tip moved, run a fresh round: ${reviewCmd}`));
  const nFix = jq('[.findings[]? | select(.action == "fix")] | length', review, "ERR");
  if (nFix !== "0")
    die(b(`the feature review round left ${nFix} open fix finding(s) - fix on the feature branch (the ref change invalidates the round) and run a fresh round: ${reviewCmd}`));

  const contract = containerContract(readLedger(ledger), fb);
  if (` ${contract.replace(/\t/g, " ")} `.includes(" qa:yes ") && !attested(dir, tip))
    die(
      b(
        `the container row pins qa:yes and no crew-qa pass attestation exists for the tip ${tip} - run one behavioral round against the BUILT feature branch (crew-qa skill / bin/ac-qa.sh agent --target ${tip} ...)`,
      ),
    );

  if (!hasOrigin(dir)) die(b(`feature-ship needs an origin remote on ${rb} - a local-only repo has no PR to open (land it by captain merge instead)`));
  const made = run(["mkdir", "-p", gateDir], "inherit", "inherit").status;
  if (made !== 0) process.exit(made);
  const ships = `${gateDir}/ships.env`;
  const key = `pr_url_${fold(rb)}`;
  const scan = run(["grep", "-v", "^#", epicBranchesFile(feature) ?? ""], "pipe", "inherit");
  const lines = scan.out.toString("latin1").split("\n");
  lines.pop();
  for (const line of lines) {
    const other = line.replace(/^[ \t]+/, "").split(/[ \t]/)[0]!;
    if (other !== rb && `pr_url_${fold(other)}` === key)
      die(
        b(
          `ship: repos ${rb} and ${other} of feature ${fb} share the ships.env key ${key} - one url slot cannot tell their PRs apart; re-record one of them under a distinct name (the captain's word) before shipping`,
        ),
      );
  }
  const recorded = shipsUrl(ships, key);
  if (recorded !== "") {
    out(`PR already recorded: ${recorded}\n`);
    return;
  }
  if (dry) {
    out(`DRY-RUN: git -C ${bytes(dir)} push origin refs/heads/${branch}:refs/heads/${branch}\n`);
    out(`DRY-RUN: gh pr create --base ${target} --head ${branch} --title "feature(${fb}): ${branch} -> ${target}" (in ${bytes(dir)})\n`);
    return;
  }
  const ref = `refs/heads/${native(branch)}`;
  const pushed = git(dir, ["push", "origin", `${ref}:${ref}`], "inherit", "inherit");
  if (pushed !== 0) process.exit(pushed);
  const [nb, nt] = [native(branch), native(target)];
  const gh = run(
    [
      "gh", "pr", "create", "--base", nt, "--head", nb, "--title", `feature(${feature}): ${nb} -> ${nt}`,
      "--body", `Feature branch \`${nb}\` of \`${feature}\` -> \`${nt}\`. Opened by ac-feature.sh ship after the feature gate (members terminal, review round clean at ${tip}). The captain merges.`,
    ],
    "pipe",
    "inherit",
    { cwd: dir },
  );
  if (gh.status !== 0) die(b(`gh pr create failed for ${branch} -> ${target}`));
  const url = subst(gh.out);
  try {
    appendFileSync(ships, b(`${key}=${url}\n`));
  } catch {
    process.exit(1);
  }
  // The room entry decodes its argv, so a url that is not UTF-8 reaches the
  // room as its U+FFFD spelling from either side.
  run([resolve(import.meta.dir, "..", "bin", "ac-room.sh"), "post", feature, "crewchief", `SHIPS: pr ${native(url)} (${repo}, feature-ship)`], "ignore", "ignore");
  out(`opened pr: ${url}\n`);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  const n = args.length;
  const verb = args[0] ?? "";
  switch (verb) {
    case "create":
      if (n !== 3) die("usage: ac-feature.sh create <feature> <repo>");
      cmdCreate(args[1]!, args[2]!);
      break;
    case "verify":
      if (n !== 3) die("usage: ac-feature.sh verify <feature> <repo>");
      cmdVerify(args[1]!, args[2]!);
      break;
    case "show":
    case "retire": {
      if (n !== 2) die(`usage: ac-feature.sh ${verb} <feature>`);
      const child = bunChild("src/epic-branch.ts", [verb, args[1]!]);
      process.exit(run(child.cmd, "inherit", "inherit", { cwd: child.cwd }).status);
    }
    case "ship":
      if (n !== 3 && !(n === 4 && args[3] === "--dry-run")) die("usage: ac-feature.sh ship <feature> <repo> [--dry-run]");
      cmdShip(args[1]!, args[2]!, n === 4, atCaller);
      break;
    default:
      die("usage: ac-feature.sh create|verify <feature> <repo> | show|retire <feature> | ship <feature> <repo> [--dry-run]");
  }
}
