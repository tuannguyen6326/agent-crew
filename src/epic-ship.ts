// epic-ship.ts - the EPIC GATE + 2-PR exit of a branch-recorded epic
// (epic-branch-mech proposal v2 sections 3.5/3.6):
// review/QA run per EPIC, and the ask-captain rules are unchanged inside one.
// The entry is bin/ac-epic-ship.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-epic-ship.sh as the oracle the
// differential leg of tests/sh/ac-epic-ship.test.sh holds this module to.
//
// Usage: ac-epic-ship.sh <epic> <repo> [--dry-run]
//
// The verb REFUSES with the exact remedy instead of doing a lesser thing, and
// NEVER merges - the captain / merge authority does. Every refusal below is
// `ERROR: <text>` on stderr, exit 1 unless noted, checked in this order:
//
// 0. git and jq on PATH, before a single argument is read (W17: a missing jq
//    answers every argv, usage included): `required tool not found: <tool>`.
//    gh is never required. Then <epic> = $1, <repo> = $2, either empty:
//      usage: ac-epic-ship.sh <epic> <repo> [--dry-run]
//    --dry-run counts only as the THIRD argument and further arguments are
//    ignored (W18: `<epic> <repo> x --dry-run` runs the REAL exit; as the
//    second it is a repo name). Then CHIEF-ONLY, before the home is read (a
//    PreToolUse hook cannot see a bash verb, so the guard lives here) -
//    AC_SCOPE non-empty:
//      epic-ship is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=<v>) - the exit of an epic is the fleet chief's act on the captain's word
// 1. RECORD: epicBranchEntry (src/lib.ts) over data/<epic>/branches, live
//    then archived:
//      the <epic> record is retired - a retired epic has no exit to run
//      no branches record entry for <repo> under epic <epic> - this epic is not branch-recorded
//    The entry is `<branch> [key=value ...]` rejoined by single spaces (a
//    TAB-separated record reads fine; a numeric repo matches numerically,
//    `07` reading the `7` line). <branch> is its text before the first space;
//    of the rest, staging is the text after the FIRST ` staging=` up to the
//    next space (`staging=a=b` is `a=b`; W5: an EMPTY `staging=` is no
//    staging - one PR straight to the default branch), and push is the whole
//    token ` push=yes ` (`push=YES`, `push=yesno` are none). Then
//    src/epic-branch.ts's verify as a bun child (bunChild's command and cwd,
//    started through `env -u <each BUN_*/JSC_* name>` so the child gets this
//    process's environment BYTES less the names ac-bun.sh unsets), stdio
//    inherited: its refusal and status end the run - that module's header is
//    its spec. The clone is <home>/projects/<repo>, which must be a directory
//    (`no project clone at projects/<repo>` - unreachable once verify passed).
// 2. STORIES TERMINAL: records/backlog.md as bytes, split into awk's records
//    (src/backlog.ts records(): on LF, an unterminated last line kept, a NUL
//    ending its record), every one starting `- [` in any section, in ledger
//    order, its fields acDoneline's. The epic's OWN row (id = <epic>) closes
//    after the ship and is skipped, as is every row whose `epic` field is not
//    <epic> (byte equality). A story whose line does not start `- [x]` is
//    open (W1: `- [X]`, `- [~]`, `- [ ]id` parse with the id `-`); a checked
//    story whose terminal is failed|abandoned is partial:
//      epic <epic> has non-terminal stories: <id> <id> - every story lands (or is failed/abandoned by the captain) before the epic exits
//    A ledger that cannot be read (missing, unreadable) ends the run with
//    exit 2 and nothing printed; one that is a directory holds no record, as
//    awk read it, so no story and no epic row (W10: every gate below passes
//    on it).
// 3. PARTIAL EPIC IS A CAPTAIN CALL (red-team M8): an abandoned story that
//    LANDED before dying leaves its commits on the branch, and nothing else
//    decides revert-vs-keep. The partial ids, joined by spaces, are expanded
//    as bash expands an unquoted `for p in $partials` - word-split, then each
//    word a pathname pattern against the caller's cwd (W2: `e1-*` becomes the
//    cwd's `e1-alpha e1-beta`; no match keeps the word as written) - a word
//    holding any of `*?[\` by the PATH's bash itself, the shell this entry's
//    shebang names; a caller cwd with no name globs nothing. Each word needs
//    a line in roomFile(<epic>)'s room (live, else archived) that a spawned
//    `grep -q` finds for the BRE `DECIDED: epic-ship partial - <word> ` (W3:
//    the trailing space is grammar - a receipt ending at the id is none; the
//    id is a pattern, its `.` any byte, a lone `*` any receipt at all):
//      partial epic: [failed]/[abandoned] stories need a captain revert-or-keep receipt in the room - <word> <word> - post the GATE:, record the captain's answer as 'DECIDED: epic-ship partial - <story> revert|keep <words>', then re-run
// 4. REVIEW ROUND AT THE TIP (captain ruling R1), judged on ORIGIN's tip:
//    `git fetch origin --quiet`, its stderr and failure dropped (a push does
//    not necessarily refresh the remote-tracking ref); tip =
//    `rev-parse refs/remotes/origin/<branch>` when that verifies, else
//    `rev-parse refs/heads/<branch>`, else
//      branch <branch> resolves nowhere in the clone - fetch origin, or create it first
//    base = `merge-base <defaultBranch> <tip>`, whose failure ends the run
//    with git's status and lines (W8: no local default branch is git's own
//    128; unrelated histories are a SILENT exit 1). <cmd> below is
//      bin/ac-verify.sh codereview --repo <clone> --ref <tip> --family <epic> --caller <your AC_CREW_ID> --base <base> --intent <data>/<epic>/room.md --output <data>/<epic>/gate/review.json
//    No regular file at data/<epic>/gate/review.json:
//      no epic review round on record - run ONE independent round over the whole integration diff first: <cmd>
//    `jq -r '.reviewed_ref // ""'` must print the tip, read as its command
//    substitution read it (W6: null, false, an array, unparseable and
//    unreadable all read as none; a number prints as jq spells it; two JSON
//    values print two lines):
//      the recorded review round is for ref <ref, or <none>>, not the current tip <tip> - the tip moved, run a fresh round: <cmd>
//    `jq -r '[.findings[]? | select(.action == "fix")] | length'` must print
//    exactly `0` - its stdout with `ERR` appended when jq fails (W7: an
//    element jq cannot index is `ERR`, a clean value before a broken one
//    `0<LF>ERR`; findings absent or no array count 0 and pass; an object of
//    findings counts its values):
//      the epic review round left <n> open fix finding(s) - fix on the epic branch (the ref change invalidates the round) and run a fresh round: <cmd>
// 5. QA WHEN PINNED: the ledger read again; the contract of the FIRST `- [`
//    row whose id equals <epic> as `awk -v` reads it (string equality: `07`
//    is not `7`), holding `qa:yes` as a space- or TAB-joined token, needs a
//    crew-qa pass attestation: some name under <clone>/.crew/qa/passed/
//    STARTING with the tip (W9, a prefix: `<tip>junk` counts, the in-flight
//    dot-prefixed temp never does), every match handed to a spawned `ls`
//    whose success is the answer (an unreadable directory is none):
//      the epic row pins qa:yes and no crew-qa pass attestation exists for the tip <tip> - run one behavioral round against the BUILT epic branch (crew-qa skill / bin/ac-qa.sh agent --target <tip> ...). Note: a ut coverage row qualifies only against a ship TEST RECEIPT minted at this tip - no story run's SHA can stand in (epic-branch-mech M7)
//
// THE 2-PR EXIT (merged-proof corrected per red-team B1: this fleet's own
// default merge is SQUASH, under which no epic commit is ever an ancestor of
// staging - so "PR-1 merged" is proven by ancestry OR by the forge reporting
// the RECORDED PR-1 url as MERGED, never by ancestry alone), in order:
// - `mkdir -p <data>/<epic>/gate`, spawned; its failure ends the run with its
//   status.
// - no origin (`git remote get-url origin` failing):
//     epic-ship needs an origin remote on <repo> - a local-only repo has no PR to open (land it by captain merge instead)
// - push=yes: `git -C <clone> push origin refs/heads/<b>:refs/heads/<b>` WITH
//   the project's pre-push hook (a delivery push), its failure ending the run
//   with git's status and lines; --dry-run prints instead
//     DRY-RUN: git -C <clone> push origin refs/heads/<b>:refs/heads/<b>
//   It pushes the LOCAL branch while every gate judged origin's tip (W11: a
//   local commit no review saw is published under a PR body naming the
//   reviewed tip clean), and it runs on every invocation, a recorded PR's
//   included.
// - data/<epic>/gate/ships.env as `ac_meta_get ... 2>/dev/null || printf ''`
//   read pr1_url and pr2_url (shipsUrl: the LAST `<key>=` line wins, an empty
//   last value or a file that cannot be read is none - W13, the PR is opened
//   again - and a NUL ends awk's record).
// - OPEN <base> <slot>, --dry-run, prints
//     DRY-RUN: gh pr create --base <base> --head <b> --title "epic(<epic>): integration -> <base>" (in <clone>)
//   else, in the clone, its stderr passing through, its stdout the url
//   (trailing newlines cut, NULs dropped):
//     gh pr create --base <base> --head <b> --title "epic(<epic>): integration -> <base>" --body "Integration branch `<b>` of epic `<epic>` -> `<base>`. Opened by ac-epic-ship.sh after the epic gate (stories terminal, review round clean at <tip>). The captain merges."
//   failing: `gh pr create failed for <b> -> <base>`; then `<slot>_url=<url>`
//   appended to ships.env (a failed append ends the run, exit 1, the PR
//   already open - W13), `ac-room.sh post <epic> crewchief "SHIPS: <slot>
//   <url> (epic-ship)"` from this module's own bin/ (io dropped, status
//   ignored), and `opened <slot>: <url>` (W12: an EMPTY url is recorded as
//   `<slot>_url=`, so the next run opens the PR again; a multi-line url is
//   written raw into ships.env and the room).
// - staging recorded: PR-1 is proven merged when the tip is an ancestor of
//   refs/remotes/origin/<s> or of refs/heads/<s> (`merge-base --is-ancestor`,
//   stderr dropped), else - pr1_url recorded and gh on PATH, --dry-run too
//   (W15, a forge read) - when `gh pr view <pr1_url> --json state --jq .state`
//   run in the clone prints MERGED. Then, on stdout, exit 0:
//     merged, pr2_url recorded: PR-1 (<b> -> <s>) proven merged; production PR already recorded: <pr2_url>
//     merged:                   PR-1 (<b> -> <s>) proven merged; opening PR-2   then OPEN <default> pr2
//     pr1_url recorded:         PR-1 already open, not merged yet: <pr1_url> - PR-2 held until it merges
//                               (W14: also for a CLOSED PR, an empty answer, no gh)
//     else:                     OPEN <s> pr1, then PR-2 (-> <default>) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)
// - no staging: pr2_url recorded prints `production PR already recorded:
//   <pr2_url>`; else OPEN <default> pr2.
//
// EXIT: 0; 1 on every refusal; 2 for a ledger that cannot be read; git's own
// status where its failure ends the run (128 for `fatal:`) - 128+signal for
// any child a signal ended, 127 for one that could not start (a gh that
// cannot start is the gh refusal). Every child is spawned with the
// original's argv and io and inherits the caller's stdin; an executable the
// kernel refuses (no shebang) runs under /bin/bash as the shell ran it. The
// record, the ledger, the room, git's, jq's and gh's output and ships.env
// are bytes, and every line built from them is written as those bytes.
//
// DIVERGENCES from the original, named in the differential leg:
// - W4: homeless, the run refuses ONCE with the AC_HOME refusal, where the
//   original printed it twice (a swallowed `$(ac_data_dir)` per record rung;
//   once for an epic outside [a-zA-Z0-9_-], which skips the archive rung) and
//   then the no-entry remedy; an AC_HOME cd cannot enter is `AC_HOME is not a
//   readable directory: <h>` once, where the shell printed cd's own lines and
//   the remedy (exit 1 everywhere).
// - The ledger awk's own `can't open file` lines are not reproduced, its exit
//   2 is; the parser runs in this process, so the binding's `backlog parser
//   failed` refusal has no counterpart.
// - W16 (the HOME RESOLUTION ruling): the clone is joined onto the PHYSICAL
//   home, so under a symlinked AC_HOME the DRY-RUN lines and <cmd>'s --repo
//   name the physical clone where the original named AC_HOME as spelled.
// - bash's own stderr is not reproduced: the job line of a child a signal
//   ended (`Terminated: 15`), `gh: command not found`, a failed append's
//   redirection line, the `shell-init:`/`chdir:` lines a caller cwd with no
//   name drew from every bash the original started.
// - A git or jq on PATH that is not executable is `required tool not found`
//   here; the original's `command -v` took it and failed running it.
// - argv and env arrive decoded: a byte that is not UTF-8 in an argument or
//   in AC_SCOPE reaches this module as U+FFFD, and a branch, staging branch,
//   story id or url that is not UTF-8 is spawned decoded (a story id that also
//   holds a pattern character comes back from bash so); a url gh printed
//   that is not UTF-8 is recorded and printed as its bytes and reaches the
//   room as its U+FFFD spelling - the room entry decodes its argv the same
//   way from either side.
// W2 is no divergence: the glob is reproduced (the WIRE QUIRKS rule), where
// src/feature.ts's W16 names the same glob in its member gate a divergence -
// the sibling, not this module, is out of step.
//
// CALLERS: no bin/, src/, dashboard/ or hook runs this entry - the
// intake-triage skill, docs/scripts.md and docs/architecture.md name it in
// prose; the chief runs it by hand on the captain's word. A bun-less run
// answers `ERROR: required tool not found: bun`, exit 1, from the shim, to
// that hand - no `set -e` caller dies silently, so nothing fails soft.
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
function run(cmd: string[], stdout: Io, stderr: Io, cwd?: string): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync>;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout, stderr, cwd });
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

export type Story = { id: string; epic: string; terminal: string; line: string };

// The story awk: `index($0, "- [") == 1 { ac_doneline($0, f); print f["id"]
// "\t" f["epic"] "\t" f["terminal"] "\t" $0 }`, its rows split back on the
// first three TABs - neither field before the line can hold one.
export function storyRows(text: string): Story[] {
  const rows: Story[] = [];
  for (const line of records(text)) {
    if (!line.startsWith("- [")) continue;
    const f = acDoneline(line);
    rows.push({ id: f.id, epic: f.epic, terminal: f.terminal, line });
  }
  return rows;
}

// The epic-row awk: `BEGIN { w[want] } /^- \[/ { ...; if (f["id"] in w) {
// print f["contract"]; exit } }` run with `-v want=<epic>` - `in`, never `==`,
// because awk compares numeric-looking ids as numbers (07 == 7).
export function epicContract(text: string, want: string): string {
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

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
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

// `for p in $partials`: no id holds a blank, so the words are the ids, and an
// id with no pattern character is itself. The pathname expansion of the rest
// is bash's own (glob syntax, locale and match order included), so bash
// performs it. `set -f` where enterCaller could not return to the caller's
// cwd: the bash globbed a directory with no name, which held nothing, where
// this process sits in the distro root.
function partialWords(list: string, atCaller: boolean): string[] {
  const script = `${atCaller ? "" : "set -f; "}for p in $1; do printf '%s\\0' "$p"; done`;
  return list
    .split(" ")
    .filter((w) => w !== "")
    .flatMap((w) => {
      if (!/[*?[\\]/.test(w)) return [w];
      // The expansion was the shell's own step, with no status to fail; a bash
      // that cannot do it here must end the run, never read as "no words".
      const r = run(["bash", "-c", script, "ac-epic-ship.sh", native(w)], "pipe", "inherit");
      if (r.status !== 0) process.exit(r.status);
      const words = r.out.toString("latin1").split("\0");
      words.pop();
      return words;
    });
}

function ship(epic: string, repo: string, dry: boolean, atCaller: boolean): void {
  const eb = bytes(epic);
  const r = epicBranchEntry(epic, repo);
  if (r.rc === 2) die(`the ${epic} record is retired - a retired epic has no exit to run`);
  if (r.rc === 1) die(`no branches record entry for ${repo} under epic ${epic} - this epic is not branch-recorded`);
  const branch = r.entry.split(" ")[0]!;
  const rest = ` ${r.entry.slice(branch.length)} `;
  const at = rest.indexOf(" staging=");
  const staging = at < 0 ? "" : rest.slice(at + " staging=".length).split(" ")[0]!;
  const push = rest.includes(" push=yes ");
  const child = bunChild("src/epic-branch.ts", ["verify", epic, repo]);
  const verified = run(child.cmd, "inherit", "inherit", child.cwd).status;
  if (verified !== 0) process.exit(verified);
  const dir = `${envHome()}/projects/${repo}`;
  if (!isDir(dir)) die(`no project clone at projects/${repo}`);

  const ledger = `${recordsDir()}/backlog.md`;
  let open = "";
  let partials = "";
  for (const s of storyRows(readLedger(ledger))) {
    if (s.id === eb || s.epic !== eb) continue;
    if (!s.line.startsWith("- [x]")) {
      open += ` ${s.id}`;
      continue;
    }
    if (s.terminal === "failed" || s.terminal === "abandoned") partials += ` ${s.id}`;
  }
  if (open !== "") die(b(`epic ${eb} has non-terminal stories:${open} - every story lands (or is failed/abandoned by the captain) before the epic exits`));
  if (partials !== "") {
    const room = roomFile(epic);
    let missing = "";
    for (const p of partialWords(partials, atCaller))
      if (run(["grep", "-q", native(`DECIDED: epic-ship partial - ${p} `), room], "ignore", "ignore").status !== 0) missing += ` ${p}`;
    if (missing !== "")
      die(
        b(
          `partial epic: [failed]/[abandoned] stories need a captain revert-or-keep receipt in the room -${missing} - post the GATE:, record the captain's answer as 'DECIDED: epic-ship partial - <story> revert|keep <words>', then re-run`,
        ),
      );
  }

  git(dir, ["fetch", "origin", "--quiet"], "inherit", "ignore");
  const nb = native(branch);
  let tip: string;
  if (git(dir, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${nb}`], "ignore", "inherit") === 0) tip = gitValue(dir, ["rev-parse", `refs/remotes/origin/${nb}`]);
  else if (git(dir, ["rev-parse", "--verify", "--quiet", `refs/heads/${nb}`], "ignore", "inherit") === 0) tip = gitValue(dir, ["rev-parse", `refs/heads/${nb}`]);
  else die(b(`branch ${branch} resolves nowhere in the clone - fetch origin, or create it first`));
  const dflt = defaultBranch(dir);
  const base = gitValue(dir, ["merge-base", dflt, tip]);
  const gateDir = `${dataDir()}/${epic}/gate`;
  const review = `${gateDir}/review.json`;
  const reviewCmd = `bin/ac-verify.sh codereview --repo ${bytes(dir)} --ref ${tip} --family ${eb} --caller <your AC_CREW_ID> --base ${base} --intent ${bytes(dataDir())}/${eb}/room.md --output ${bytes(review)}`;
  if (!isFile(review)) die(b(`no epic review round on record - run ONE independent round over the whole integration diff first: ${reviewCmd}`));
  const rRef = jq('.reviewed_ref // ""', review, "");
  if (rRef !== tip) die(b(`the recorded review round is for ref ${rRef || "<none>"}, not the current tip ${tip} - the tip moved, run a fresh round: ${reviewCmd}`));
  const nFix = jq('[.findings[]? | select(.action == "fix")] | length', review, "ERR");
  if (nFix !== "0")
    die(b(`the epic review round left ${nFix} open fix finding(s) - fix on the epic branch (the ref change invalidates the round) and run a fresh round: ${reviewCmd}`));

  const contract = epicContract(readLedger(ledger), eb);
  if (` ${contract.replace(/\t/g, " ")} `.includes(" qa:yes ") && !attested(dir, tip))
    die(
      b(
        `the epic row pins qa:yes and no crew-qa pass attestation exists for the tip ${tip} - run one behavioral round against the BUILT epic branch (crew-qa skill / bin/ac-qa.sh agent --target ${tip} ...). Note: a ut coverage row qualifies only against a ship TEST RECEIPT minted at this tip - no story run's SHA can stand in (epic-branch-mech M7)`,
      ),
    );

  const made = run(["mkdir", "-p", gateDir], "inherit", "inherit").status;
  if (made !== 0) process.exit(made);
  const ships = `${gateDir}/ships.env`;
  if (git(dir, ["remote", "get-url", "origin"], "ignore", "ignore") !== 0)
    die(b(`epic-ship needs an origin remote on ${bytes(repo)} - a local-only repo has no PR to open (land it by captain merge instead)`));
  if (push) {
    const ref = `refs/heads/${nb}`;
    if (dry) out(`DRY-RUN: git -C ${bytes(dir)} push origin refs/heads/${branch}:refs/heads/${branch}\n`);
    else {
      const pushed = git(dir, ["push", "origin", `${ref}:${ref}`], "inherit", "inherit");
      if (pushed !== 0) process.exit(pushed);
    }
  }
  const pr1 = shipsUrl(ships, "pr1_url");
  const pr2 = shipsUrl(ships, "pr2_url");
  const def = bytes(dflt);

  const openPr = (prbase: string, slot: string): void => {
    if (dry) {
      out(`DRY-RUN: gh pr create --base ${prbase} --head ${branch} --title "epic(${eb}): integration -> ${prbase}" (in ${bytes(dir)})\n`);
      return;
    }
    const nbase = native(prbase);
    const gh = run(
      [
        "gh", "pr", "create", "--base", nbase, "--head", nb, "--title", `epic(${epic}): integration -> ${nbase}`,
        "--body", `Integration branch \`${nb}\` of epic \`${epic}\` -> \`${nbase}\`. Opened by ac-epic-ship.sh after the epic gate (stories terminal, review round clean at ${tip}). The captain merges.`,
      ],
      "pipe",
      "inherit",
      dir,
    );
    if (gh.status !== 0) die(b(`gh pr create failed for ${branch} -> ${prbase}`));
    const url = subst(gh.out);
    try {
      appendFileSync(ships, b(`${slot}_url=${url}\n`));
    } catch {
      process.exit(1);
    }
    // The room entry decodes its argv, so a url that is not UTF-8 reaches the
    // room as its U+FFFD spelling from either side.
    run([resolve(import.meta.dir, "..", "bin", "ac-room.sh"), "post", epic, "crewchief", `SHIPS: ${slot} ${native(url)} (epic-ship)`], "ignore", "ignore");
    out(`opened ${slot}: ${url}\n`);
  };

  if (staging === "") {
    if (pr2 !== "") out(`production PR already recorded: ${pr2}\n`);
    else openPr(def, "pr2");
    return;
  }
  const ns = native(staging);
  let merged =
    git(dir, ["merge-base", "--is-ancestor", tip, `refs/remotes/origin/${ns}`], "inherit", "ignore") === 0 ||
    git(dir, ["merge-base", "--is-ancestor", tip, `refs/heads/${ns}`], "inherit", "ignore") === 0;
  if (!merged && pr1 !== "" && Bun.which("gh"))
    merged = subst(run(["gh", "pr", "view", native(pr1), "--json", "state", "--jq", ".state"], "pipe", "ignore", dir).out) === "MERGED";
  if (merged && pr2 !== "") out(`PR-1 (${branch} -> ${staging}) proven merged; production PR already recorded: ${pr2}\n`);
  else if (merged) {
    out(`PR-1 (${branch} -> ${staging}) proven merged; opening PR-2\n`);
    openPr(def, "pr2");
  } else if (pr1 !== "") out(`PR-1 already open, not merged yet: ${pr1} - PR-2 held until it merges\n`);
  else {
    openPr(staging, "pr1");
    out(`PR-2 (-> ${def}) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)\n`);
  }
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  require("git", "jq");
  const [epic = "", repo = ""] = args;
  if (epic === "" || repo === "") die("usage: ac-epic-ship.sh <epic> <repo> [--dry-run]");
  const scope = process.env.AC_SCOPE;
  if (scope)
    die(
      `epic-ship is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=${scope}) - the exit of an epic is the fleet chief's act on the captain's word`,
    );
  ship(epic, repo, args[2] === "--dry-run", atCaller);
}
