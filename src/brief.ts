// brief.ts - scaffold one crewmate brief. The entry is bin/ac-brief.sh (a
// shim that starts this file through bin/ac-bun.sh); THIS header is the
// authoritative spec, the task-data layout included, and the bash original
// it replaced stays frozen at tests/fixtures/ac-brief.sh as the oracle the
// differential leg of tests/sh/ac-brief.test.sh holds this module to.
//
// Usage: ac-brief.sh <id> <project-name> [--scout | --stage <spec|architecture|plan|implement|design|qa>]
//                    [--mode <crew-ship|direct-pr|local-only|feature-pr>] [--review <yes|no>]
//                    [--captain-requested <ref>] [--reason <one line>]
//                    [--qa-required-profile <project/scope/app>]...
//
// --captain-requested <ref> DECLARES the captain's word for this call's
// time-expensive choices: staged flow, crew-ship, qa, and a review that is
// optional - an unstaged task that is no crew-ship (AGENTS.md's
// review-obligation block allows review=yes there only "when the captain
// requests independent review"), or a staged story of a branch-recorded
// epic. On the optional raise of an unstaged task the ref must be non-empty
// and rides the Review line; wherever the call spends, the ref - empty or
// multi-line too (W9, at parity) - rides the Escalation: line. A declaration
// that authorizes nothing is refused (the escalation gate below). Same shape
// and same reason as ac-spawn.sh's --captain-initiated: an explicit caller
// declaration, not text-shape matching. Staged and crew-ship derive
// review=yes on their own.
// --reason <one line> is REQUIRED whenever --captain-requested authorizes a
// time-expensive mode: the chief's justification as given to the captain in
// the ask, recorded on the Escalation: line of a spec, architecture, plan,
// design or implement brief - the scout and qa templates carry no such line,
// so a declared qa charter keeps its reason nowhere (W10, at parity). A row
// pin needs none - the pin is the captain's own act.
//
// --qa-required-profile (repeatable) records the task's explicit required
// profile set into a FAMILY-level manifest (data/<family>/qa/manifest.json),
// written by every stage that names one - a --scout's too, past no qa:yes
// gate (W11, at parity).
// Each key is refused unless it is non-empty and of the chars
// [A-Za-z0-9/_-] under any locale; its <project>/<scope>/<app> shape is not
// checked here - the merge gate refuses a key that does not parse. The gate
// then requires a passing attestation for EVERY listed profile at the exact
// merge head. Omit it for a flat/single-profile task (no manifest, no matrix
// - the simple one-profile gate stays). Doc: Required Profile Matrix.
//
// Brief location - the one authoritative statement of the task-data layout:
// - direct tasks and plain scouts (no --stage): data/<id>/brief.md (flat).
//   EXCEPT a SCOPED chief's free-slug fan-out sub-task (AC_SCOPE=<family>,
//   id=<family>-<slug>, no stage/-rN suffix): data/<family>/tasks/<slug>/brief.md,
//   nested so a family's fan-outs, QA rounds and revisions live inside the
//   family dir the way its stages already do (and ride src/archive.ts's
//   whole-family move for free). The scope is the family signal ON PURPOSE -
//   a prefix guess would nest an unrelated top-level id that merely extends
//   another row's name; unscoped scaffolds stay flat, and pre-existing flat
//   fan-out dirs stay readable forever (taskDir's tasks/ probe, src/lib.ts).
// - staged-flow tasks (--stage <s>): data/<family>/<stage>[-rN]/brief.md,
//   nested under the family dir with the SHORT stage names
//   (spec, arch, plan, implement, design, qa). Historical review/ship dirs remain
//   readable, but this scaffold never creates them. The family comes from the
//   id's canonical suffix (<task>-spec, <task>-arch, <task>-plan,
//   <task>-review, <task>-ship, <task>-design, <task>-qa; revisions keep theirs: <task>-spec-r2 ->
//   data/<task>/spec-r2, and a bare <task>-rN is an implement revision ->
//   data/<task>/implement-rN). The unsuffixed implement id nests at
//   data/<id>/implement; every OTHER stage requires its canonical suffix
//   (an unsuffixed id dies - the resolver could never find that brief).
//   A suffix contradicting --stage dies. A second brief for one id in the
//   other layout dies - a staged brief beside the flat data/<id>/brief.md, a
//   flat one beside the nested brief its suffix names, data/<id>/implement/,
//   or a tasks/ twin (longest prefix first) - with two holes kept at parity
//   (W14): an unstaged <family>-chief id scaffolds flat, which the resolver
//   calls ambiguous once data/<family>/ exists (a chief's nested dir needs no
//   brief), and a staged unsuffixed implement brief is never checked against
//   a tasks/ twin.
//   Family-level files (room.md, gate artifacts) stay at data/<family>/.
//   <task>-chief maps the same way, to data/<family>/chief, but a roomchief
//   never has a brief there (the room IS its brief) and the stage whitelist
//   below refuses --stage chief - it never becomes a briefable stage.
// Reports land next to their brief: <dir>/report.md.
// Every brief is CREATED at one of those live paths, always - archiving changes
// nothing here. A family that is already CLOSED may since have been relocated
// whole to data/archive/<year>/<family>/ by src/archive.ts, whose header owns
// that layout; reads resolve across it through ac_room_file (bin/ac-lib.sh).
//
// Execution briefs (default, = --stage implement) tell one crewmate to own
// IMPLEMENT plus DELIVERY on a `crew/<family>` branch, plus a `report.md`
// handback note (Lessons only) next to the brief. Scout briefs (--scout) tell
// the crewmate to investigate and deliver ONLY a report. Normal production
// topology is direct execution, or staged design -> execution; the design
// crewmate may produce spec, architecture, and plan reports in one gated
// session. Separate code-review and ship production stages are retired. The
// orchestrator edits the scaffold to fill in the actual task (and stage
// inputs) before spawning.
//
// ESCAPE HATCH. Every chief-side task on both fleets
// starts here, and a WRONG brief is worse than a refusal - spawn trusts its
// Mode:/Review: lines and the crewmate runs its baked lines. If a landed
// change breaks this module, run the frozen original from a scratch bin/
// whose path is physical (mktemp's /var is /private/var to the copy's root):
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-brief.sh "$o/bin/ac-brief.sh"
//   cp tests/fixtures/ac-qa-lib.sh tests/fixtures/ac-pipeline-lib.sh "$o/bin/"
// then "$o/bin/ac-brief.sh" <id> <project> [flags], and since the copy bakes
// ITS OWN root into the crewmate's runnable lines (ac-done.sh, ac-know.sh,
// ac-qa.sh, ac-verify.sh, docs/staged-design-flow-spec.md), end with
//   sed -i '' "s#$o#$(pwd -P)#g" <brief>
// Spawn reads only the Mode:/Review: lines, so a hand-written brief is the
// last resort before the captain's revert of the land.
//
// --- the run, in order (AUTHORITATIVE) ---
// Every ERROR is one line on stderr, exit 1; stdin is never read and every
// child inherits it.
// ARGUMENTS, every refusal before any home read. Fewer than two words is
// `ERROR: usage: ac-brief.sh <id> <project-name> [--scout | --stage <s>]` (one
// line, `-h` included). The rest, last wins: --scout (stage scout, unstaged),
// --stage <s> (staged), --mode, --review, --captain-requested (declared even
// with ''), --reason, --qa-required-profile (repeatable, appended). A value
// flag takes the next word whatever it is; as the last word it is `ERROR:
// <flag> needs a value`; any other word is `ERROR: unknown flag: <a>`. Then an
// empty id or project is the usage line; `ERROR: id must be [a-z0-9-]: <id>`
// under any locale (a dash-led id passes - W13, at parity: `--scout myid`
// scaffolds id --scout on project myid); `ERROR: unknown stage: <s> (want
// spec|architecture|plan|implement|design|qa)` - `--stage scout` passes it;
// `ERROR: invalid --review: <v> (want yes|no)` ('' is absent); each profile in
// order, `ERROR: invalid --qa-required-profile '<k>' (want
// <project>/<scope>/<app>, chars [A-Za-z0-9/_-]) (nothing scaffolded)`.
// HOME: no AC_HOME is `ERROR: AC_HOME is not set - set AC_HOME=<fleet home>
// (the directory holding state/ data/ records/ config/ projects/); the distro
// checkout is not one`; one cd cannot enter (or a relative one from a caller
// cwd with no name) is `ERROR: AC_HOME is not a readable directory: <h>`. The
// home is physical, a relative one resolved against the caller's cwd; data/
// is minted here, records/ at the first ledger read, projects/ at the first
// project lookup that is no directory in the cwd; state/ and config/ never.
// LAYOUT (above): staged, `--stage scout` - which the stage check passes -
// ends the run here, exit 1, as the original's unset $short did;
// `ERROR: id suffix of '<id>' maps to stage dir '<stage>' but --stage <s>
// wants '<short>'`; `ERROR: --stage <s> needs the canonical id form
// <task>-<short>[-rN] (got '<id>')`. Then `ERROR: brief already exists:
// <brief>` (anything stat finds there, a directory included); `ERROR: a brief
// for '<id>' already exists in the other layout: <other>`.
// THE LEDGER is records/backlog.md, read ONCE (src/lib.ts ledgerRead) at the
// first question asked of it; its rows are src/backlog.ts's. A directory or
// no file is no ledger; one that cannot be read is `ERROR: cannot read the
// ledger <ledger> for the delivery contract of <id>` here, or at the fence
// for a --scout, which asks nothing earlier.
// MODE, for every stage but --scout - spec, architecture, plan and qa too,
// though their briefs never print it. The pin is every `mode:` token of the
// row's contract (rowContractForId: the exact row's, else the family row's
// for a stage-suffixed id), joined by LF and never validated (W7, at parity:
// `Mode: bogus` and an empty Delivery block, or two lines for a doubled
// token). --mode given: `ERROR: invalid --mode: <m> (want
// crew-ship|direct-pr|local-only|feature-pr)`; a pin that differs is `ERROR:
// --mode <m> contradicts the row's pinned mode:<pin> - the pin is the
// captain's recorded word; change the row (a captain act) or drop the flag
// (nothing scaffolded)`. Else the pin; else `ERROR: mode unspecified for
// '<id>': pass --mode <crew-ship|direct-pr|local-only|feature-pr> (your triage
// - the time-expensive crew-ship will still ask the captain), or pin it on the
// backlog row's contract group. There is no registry default any more (captain
// order: mode is per-task)`. --mode '' is no flag; --scout ignores --mode.
// FENCE, every stage: epicBaseFor(<id>, <project as given>) over the ledger -
// a project given as a path misses the record keyed by name (W2, at parity).
// An unreadable ledger is `ERROR: cannot read the ledger to resolve the
// epic-branch fence for <id>`. A found entry's first word is the branch, and
// the PR base reads ``the epic integration branch `<b>` `` (a feature record
// too), else `the target branch`. mode feature-pr with no branch is `ERROR:
// mode:feature-pr for '<id>' resolves no integration-branch record - token the
// row 'feature:<name>', write data/<name>/branches ('<project> <branch>
// [target=<t>] push=deferred', the captain's word receipted DECIDED: to the
// room), and cut it with ac-feature.sh create <name> <project>`.
// REVIEW (review and QA run per EPIC, not per
// story): staged with a fence - --review or no, the line `yes (the captain's
// word: a rev:yes pin or --captain-requested, checked by the escalation
// gate)` or `no (epic gate owns the review round - captain ruling
// 2026-08-19)`; staged - `ERROR: staged flow requires review=yes; --review no
// is not allowed`, else yes; crew-ship - `ERROR: crew-ship requires
// review=yes; --review no is not allowed`, else yes; every other mode and
// every scout - --review yes needs the EXACT row's `rev:` tokens to read
// `yes` (no family fallback - W8, at parity) for `yes (pinned on the backlog
// row)`, else a declaration: none is `ERROR: review=yes on direct + <mode> is
// the CAPTAIN's call, not a chief's (delivery-review skill: 'no by default,
// optional yes when the captain requests independent review'); if they asked
// for it, PIN rev:yes on the backlog row's contract group or re-run with
// --captain-requested '<their words, or the order ref>' - if they did not,
// drop --review yes` (a scout's mode is "", two spaces), an empty ref
// `ERROR: --captain-requested needs a non-empty ref: name the captain words or
// order this review carries out`, else `yes (captain-requested: <ref>)`. The
// review is the flag or no, the line the review unless set above.
// ESCALATION GATE (a mode that takes time - staged, crew-ship, qa,
// code-reviewer - is confirmed with the captain, and the ask gives the reason;
// either authority satisfies it: the row PINS the
// token, or --captain-requested declares it for this call - an accident
// guard, not a security boundary). The row's contract tokens, split on
// blanks, last `flow:`/`mode:`/`rev:`/`qa:` winning; --scout spends nothing.
// Unauthorized, in order: staged ` flow:staged`, crew-ship ` mode:crew-ship`,
// a profile ` qa:yes`, a staged epic story's review ` rev:yes` - `ERROR:
// time-expensive mode(s) not confirmed:<list> - the captain's rule: confirm
// BEFORE using staged/crew-ship/qa/independent review. Put ONE ask to the
// captain carrying (1) the REASON each is warranted for THIS task (the signal:
// financial surface, behavioral surface, multi-file risk, ...), (2) the
// options, (3) your lean - then either PIN the answer on the backlog row's
// contract group (e.g. [src:cap flow:staged mode:crew-ship rev:yes qa:no]) so
// it is never re-asked, or re-run with --captain-requested '<the captain's
// words, or the order ref>' (nothing scaffolded)`. A declaration with nothing
// spent (an optional review counts) and no --review yes is `ERROR:
// --captain-requested with nothing to authorize: this call uses no
// time-expensive mode (staged/crew-ship/qa/review) - drop the flag`. Declared
// and spending: no --reason is `ERROR: --captain-requested authorizes
// time-expensive mode(s) but carries no --reason '<the justification you gave
// the captain>': the reason must ride the record, not just the ask (nothing
// scaffolded)`, a CR or LF in it `ERROR: --reason must be a single line`. A
// --reason with no declaration is `ERROR: --reason without
// --captain-requested documents an ask that never happened: a pinned row needs
// no reason (the pin is the captain's own act) and the cheap path spends
// nothing - drop the flag`. Declared and spending, the Escalation: line is
// `Escalation:<spent> - captain-requested: <ref> - reason: <why>`, spent `
// flow:staged`, ` mode:crew-ship`, ` qa:yes`, ` rev:yes` (any review yes).
// WRITE: the task dir by a spawned `mkdir -p` (its own line and status on a
// failure); then the crew branch (crewBranch - after the mkdir, since a plain
// stage suffix counts only once data/<family>/<stage> exists) and the captain
// (captainRead: an unreadable config/captain is head's own line and no name -
// W16, at parity). The qa stage first asks `<bin>/ac-qa.sh store-dir` in the
// project's clone (projectDir, src/lib.ts - a directory of that name in the
// caller's cwd shadows projects/<name>, W3, at parity) for the knowledge
// store, its stderr dropped. The brief is then CREATED exclusively - a path
// taken by the time it is opened (a dangling symlink) is the brief-exists
// refusal - and the template rendered and written.
// THE TEMPLATES join their blocks as `$(...)` joined them: each block loses
// its trailing LFs, an empty one leaves a blank line. Head: `# <Scout|Spec|
// Architecture|Plan|Design|Crew|QA> brief: <id>`, blank, `Project: <project as
// given>`, `Kind: ...`, design and implement add `Mode:` and `Review:`, then
// the Escalation: line where one is due (not scout, not qa), then `Captain:`.
// The blocks: signals (the done/blocked/needs-decision/paused lines and the
// push `<root>/bin/ac-done.sh <id> '<the exact line you printed>'`, a crew-ship
// or direct-pr execution brief's done line asking for the PR URL); the
// primary-checkout accident; the pool rule (scratch under <task dir>/); the
// repo knowledge, only when the project resolves to a repo - its ask, cite,
// full, re-check and record lines, baking <root>/bin/ac-know.sh, --home <home>
// and --family <family> unquoted, and the record (knowledgeFile, src/lib.ts);
// the design report contract (<root>/docs/staged-design-flow-spec.md - spec,
// architecture, plan and design only); the FLEET STANDING RULES - every block
// of records/captain.md (a `- ` line and the lines after it that start with
// space or TAB) holding the token STANDING between non-[A-Za-z-] bytes and no
// `STANDING (domain:` (that block reaches its domainchief at intake, ac-spawn's
// DOMAINCHIEF SECTION), the blocks joined by blank lines, else `(no
// STANDING-marked entries found in <src>)`, then `UNPARSED - mentions STANDING
// but is not a `- ` bulleted block, so it is NOT selected above (this channel
// invents no grammar for it; fix the source line, not this channel) - <src>:`
// and `<line number>: <line>` per token outside a block; a captain.md that
// cannot be read is `(no standing preferences file on record)`, a directory
// reads as empty. The execution brief bakes the delivery block
// (deliveryModeBlock, src/lib.ts, with an EPIC TARGET line for a fenced
// crew-ship story), its review step (crew-ship's own round, the verifier line
// `<root>/bin/ac-verify.sh codereview ... --intent <brief> --output <task
// dir>/verification/review.json`, or none) and `<root>/bin/ac-qa.sh agent
// --home <home> ... --task <family>-qa ...`. The qa charter bakes the store
// (`Knowledge store (pass this VERBATIM as `--store <path>` on step 1's
// `start` line - your pane has no AC_HOME to resolve it):` and the path, else
// the store-less directive) and `Fleet home (...)` with <home>.
// MANIFEST, with profiles, after the brief: data/<family>/qa/ by a spawned
// `mkdir -p`; the source ref is `git rev-parse <default branch>` in the clone
// (defaultBranch), its stdout kept whatever the status (a name git could not
// resolve is that name), "" with no clone; jq renders `{task, source_ref,
// required_profiles: [{profile_key}]}` into an exclusive temp beside the
// manifest (an existing manifest's mode kept), renamed over it - the last
// brief of a family wins. A temp that cannot be created ends the run 1, jq's
// failure with jq's status (127 when it cannot start), the old manifest
// whole and the brief already written. stdout `required-profile manifest:
// <path> (<n> profile(s))`.
// Last, stdout `brief scaffolded: <brief> (stage: <stage as given>)`, exit 0.
//
// AT PARITY (each pinned in the leg): W2, W7,
// W8, W9, W10, W11, W13 and W14 above. Reproduced too: W3 (the cwd shadows
// a project name), W16 (config/captain's bytes, an unreadable one naming no
// one), and `--stage scout` ending the run past the stage check.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - W1: ac-qa.sh is resolved from this module's bin/,
//   where the original's `$(dirname "$0")` ran after its cd into the clone,
//   so a relative invocation (bin/ac-brief.sh from the home) lost the store.
// - IN-PROCESS LEDGER: the ledger is read once, as a file - awk's `can't
//   open file` pair and the parser's own lines are not printed (the ERROR
//   line and exit are), the bun-missing parse failure has no equivalent, and
//   no later read can fail after an earlier one passed, where the original
//   parsed it 2-5 times through a bun child (W17).
// - BUN: without bun the shim refuses `ERROR: required tool not found: bun`,
//   where the original scaffolded a home with no ledger.
// - EXCLUSIVE WRITES: a dangling symlink at the brief is
//   refused, never written through (W15); the manifest goes through an
//   exclusive temp, so jq that cannot run or a full disk leaves the old one
//   whole where the original emptied it (W6), exit statuses kept.
// - W4/W5 (FAIL-PATH): captain.md is read as bytes, so a byte that is not
//   UTF-8 under a UTF-8 locale drops no rule, where the original's awk
//   aborted past it; no temp is made, so an unusable TMPDIR loses nothing.
// - W12: a profile key outside [A-Za-z0-9/_-] is refused under any locale,
//   where bash's bracket under a UTF-8 locale also took `Ä/x/y`.
// - SHELL-OWN STDERR is not reproduced: `line N: <brief>: Permission denied`
//   (a brief or a manifest temp that cannot be created), `jq: command not
//   found`, `short: unbound variable` (--stage scout), `cd:`'s own line (the HOME
//   RESOLUTION ruling names the variable instead); exit statuses are kept.
// - MINTING: data/, records/ and projects/ are minted silently, where the
//   original printed mkdir's line at each mint it could not make and went on
//   - the task dir's spawned mkdir -p prints its own and ends the run.
// - A caller whose cwd has no name resolves no relative path: a relative
//   AC_HOME is refused and a project name is looked up only under projects/.
// - Bytes: argv arrives decoded (U+FFFD for a byte that is not UTF-8).
//
// CALLERS: none executes it from code - the crewchief, roomchiefs and solo
// chiefs before every spawn (the task-lifecycle and intake-triage skills),
// crewdeputies in their own homes, and 14 tests/sh suites; bin/ac-spawn.sh
// refuses a missing brief naming it. Its stdout is read by people and
// agents; brief.md by ac-spawn (the first `Review: ` and `Mode: ` lines),
// ac-verify (evidence, the --intent), ac-gate (a stage report's brief and its
// `Project:` line), ac-ready overlap, the dashboard and the crewmate, who runs
// its baked lines; the manifest by the merge gate's matrix arm (qaGateOk,
// src/lib.ts). The layout is what taskDir (src/lib.ts) and ac_task_dir
// (bin/ac-lib.sh) resolve for every task-dir reader.

import { accessSync, closeSync, constants, fchmodSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync } from "node:fs";
import { isAbsolute } from "node:path";
import { acDoneline, records } from "./backlog.ts";
import {
  NO_HOME,
  STARTED_BIN,
  captainRead,
  crewBranch,
  defaultBranch,
  deliveryModeBlock,
  die,
  enterCaller,
  epicBaseFor,
  exclusiveTemp,
  familyOfId,
  knowledgeFile,
  type Ledger,
  ledgerRead,
  physicalDir,
  projectDir,
  rowContractForId,
  shellStatus,
  spawnShellSync,
  stageDirForId,
  writeAll,
} from "./lib.ts";

// Byte strings (latin1) carry what the bash held as bytes; argv and the lib's
// paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const noLF = (s: string): string => s.replace(/\n+$/, "");

function out(s: string): void {
  const b = fsPath(s);
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

function fail(msg: string): never {
  die(fsPath(msg));
}

type Io = { out?: "inherit" | "pipe" | "ignore"; err?: "inherit" | "pipe" | "ignore"; cwd?: string };

function run(cmd: string[], io: Io = {}): { status: number; out: Buffer } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd.map(u8), { stdin: "inherit", stdout: io.out ?? "inherit", stderr: io.err ?? "inherit", cwd: io.cwd === undefined ? undefined : u8(io.cwd) });
  } catch {}
  return { status: shellStatus(r), out: r && io.out === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// `mkdir -p` where errexit was awake: mkdir's own line, and its status ends
// the run.
function mkdirP(dir: string): void {
  const r = run(["mkdir", "-p", dir]);
  if (r.status !== 0) process.exit(r.status);
}

const isDir = (p: string): boolean => {
  try {
    return statSync(fsPath(p)).isDirectory();
  } catch {
    return false;
  }
};
const isFile = (p: string): boolean => {
  try {
    return statSync(fsPath(p)).isFile();
  } catch {
    return false;
  }
};
const exists = (p: string): boolean => {
  try {
    statSync(fsPath(p));
    return true;
  } catch {
    return false;
  }
};
const mint = (dir: string): string => {
  try {
    mkdirSync(fsPath(dir), { recursive: true });
  } catch {}
  return dir;
};

// `tr " \t" "\n\n" | sed -n "s/^<key>://p"` over a contract, as `$(...)` kept it.
const pinOf = (contract: string, key: string): string =>
  noLF(
    contract
      .split(/[ \t]/)
      .filter((t) => t.startsWith(`${key}:`))
      .map((t) => t.slice(key.length + 1))
      .join("\n"),
  );

const STAGES = ["scout", "spec", "architecture", "plan", "implement", "design", "qa"];
const SHORT: Record<string, string> = { spec: "spec", architecture: "arch", plan: "plan", implement: "implement", design: "design", qa: "qa" };
const USAGE = "usage: ac-brief.sh <id> <project-name> [--scout | --stage <s>]";
const STANDING = /(^|[^A-Za-z-])STANDING([^A-Za-z-]|$)/;

function main(): void {
  const entered = enterCaller(process.argv.slice(2));
  const atCaller = entered.atCaller;
  const argv = entered.args.map(b8);
  if (argv.length < 2) fail(USAGE);
  const id = argv[0]!;
  const project = argv[1]!;
  let stage = "implement";
  let staged = false;
  let modeFlag = "";
  let reviewFlag = "";
  const profiles: string[] = [];
  let ref = "";
  let declared = false;
  let reason = "";
  for (let i = 2; i < argv.length; ) {
    const a = argv[i]!;
    const value = (): string => {
      if (i + 1 >= argv.length) fail(`${a} needs a value`);
      i += 2;
      return argv[i - 1]!;
    };
    if (a === "--scout") {
      stage = "scout";
      staged = false;
      i++;
    } else if (a === "--stage") {
      stage = value();
      staged = true;
    } else if (a === "--mode") modeFlag = value();
    else if (a === "--review") reviewFlag = value();
    else if (a === "--captain-requested") {
      ref = value();
      declared = true;
    } else if (a === "--reason") reason = value();
    else if (a === "--qa-required-profile") profiles.push(value());
    else fail(`unknown flag: ${a}`);
  }
  if (id === "" || project === "") fail(USAGE);
  if (/[^a-z0-9-]/.test(id)) fail(`id must be [a-z0-9-]: ${id}`);
  if (!STAGES.includes(stage)) fail(`unknown stage: ${stage} (want spec|architecture|plan|implement|design|qa)`);
  if (!["", "yes", "no"].includes(reviewFlag)) fail(`invalid --review: ${reviewFlag} (want yes|no)`);
  for (const k of profiles) if (k === "" || /[^A-Za-z0-9/_-]/.test(k)) fail(`invalid --qa-required-profile '${k}' (want <project>/<scope>/<app>, chars [A-Za-z0-9/_-]) (nothing scaffolded)`);

  const h = process.env.AC_HOME;
  if (!h) die(NO_HOME);
  const homeU = (atCaller || isAbsolute(h) ? physicalDir(h) : null) ?? die(`AC_HOME is not a readable directory: ${h}`);
  const home = b8(homeU);
  const dataDir = mint(`${home}/data`);
  const recordsDir = (): string => mint(`${home}/records`);
  const root = b8(STARTED_BIN.slice(0, -"/bin".length));

  let taskDir: string;
  let sub = "";
  if (staged) {
    sub = stageDirForId(id);
    // `$short` had no arm for scout, and set -u ended the run on it.
    if (stage === "scout") process.exit(1);
    const short = SHORT[stage]!;
    if (sub !== "") {
      const part = sub.slice(sub.indexOf("/") + 1);
      if (part !== short && !new RegExp(`^${short}-r[0-9]`).test(part)) fail(`id suffix of '${id}' maps to stage dir '${part}' but --stage ${stage} wants '${short}'`);
      taskDir = `${dataDir}/${sub}`;
    } else if (short === "implement") taskDir = `${dataDir}/${id}/implement`;
    else fail(`--stage ${stage} needs the canonical id form <task>-${short}[-rN] (got '${id}')`);
  } else {
    taskDir = `${dataDir}/${id}`;
    const scope = b8(process.env.AC_SCOPE ?? "");
    if (scope !== "" && stageDirForId(id) === "" && id.startsWith(`${scope}-`) && id.length > scope.length + 1) taskDir = `${dataDir}/${scope}/tasks/${id.slice(scope.length + 1)}`;
  }
  const brief = `${taskDir}/brief.md`;
  if (exists(brief)) fail(`brief already exists: ${brief}`);

  let other = "";
  if (staged) other = `${dataDir}/${id}/brief.md`;
  else {
    const osub = stageDirForId(id);
    if (osub !== "") other = `${dataDir}/${osub}/brief.md`;
    else if (isFile(`${dataDir}/${id}/implement/brief.md`)) other = `${dataDir}/${id}/implement/brief.md`;
    if (other === "") {
      if (taskDir !== `${dataDir}/${id}`) other = `${dataDir}/${id}/brief.md`;
      else {
        for (let base = id; base.lastIndexOf("-") !== -1; ) {
          base = base.slice(0, base.lastIndexOf("-"));
          const twin = `${dataDir}/${base}/tasks/${id.slice(base.length + 1)}/brief.md`;
          if (isFile(twin)) {
            other = twin;
            break;
          }
        }
      }
    }
  }
  if (other !== "" && isFile(other)) fail(`a brief for '${id}' already exists in the other layout: ${other}`);

  let ledgerFile = "";
  let ledger: Ledger | undefined;
  const readLedger = (): Ledger => {
    if (ledger === undefined) {
      ledgerFile = `${recordsDir()}/backlog.md`;
      ledger = ledgerRead(u8(ledgerFile));
    }
    return ledger;
  };
  const contractUnread = (): never => fail(`cannot read the ledger ${ledgerFile} for the delivery contract of ${id}`);

  let mode = "";
  if (stage !== "scout") {
    const contract = rowContractForId(u8(id), readLedger()) ?? contractUnread();
    const pin = pinOf(contract, "mode");
    if (modeFlag !== "") {
      if (!["crew-ship", "direct-pr", "local-only", "feature-pr"].includes(modeFlag)) fail(`invalid --mode: ${modeFlag} (want crew-ship|direct-pr|local-only|feature-pr)`);
      if (pin !== "" && pin !== modeFlag)
        fail(`--mode ${modeFlag} contradicts the row's pinned mode:${pin} - the pin is the captain's recorded word; change the row (a captain act) or drop the flag (nothing scaffolded)`);
      mode = modeFlag;
    } else if (pin !== "") mode = pin;
    else
      fail(
        `mode unspecified for '${id}': pass --mode <crew-ship|direct-pr|local-only|feature-pr> (your triage - the time-expensive crew-ship will still ask the captain), or pin it on the backlog row's contract group. There is no registry default any more (captain order: mode is per-task)`,
      );
  }

  const fence = epicBaseFor(u8(id), u8(project), readLedger());
  if (fence.rc === 2) fail(`cannot read the ledger to resolve the epic-branch fence for ${id}`);
  const epicBranch = fence.rc === 0 ? fence.entry.split(" ")[0]! : "";
  const prBase = epicBranch === "" ? "the target branch" : `the epic integration branch \`${epicBranch}\``;
  if (mode === "feature-pr" && epicBranch === "")
    fail(
      `mode:feature-pr for '${id}' resolves no integration-branch record - token the row 'feature:<name>', write data/<name>/branches ('${project} <branch> [target=<t>] push=deferred', the captain's word receipted DECIDED: to the room), and cut it with ac-feature.sh create <name> ${project}`,
    );

  let review: string;
  let reviewLine = "";
  if (staged && epicBranch !== "") {
    review = reviewFlag || "no";
    reviewLine = review === "yes" ? "yes (the captain's word: a rev:yes pin or --captain-requested, checked by the escalation gate)" : "no (epic gate owns the review round - captain ruling 2026-08-19)";
  } else if (staged) {
    if (reviewFlag === "no") fail("staged flow requires review=yes; --review no is not allowed");
    review = "yes";
  } else if (mode === "crew-ship") {
    if (reviewFlag === "no") fail("crew-ship requires review=yes; --review no is not allowed");
    review = "yes";
  } else {
    if (reviewFlag === "yes") {
      // The exact row only, never the family's (W8).
      const l = readLedger();
      let exact = "";
      if (l.rc === 0)
        for (const r of records(l.text)) {
          if (!/^- \[[ x]\] /.test(r)) continue;
          const f = acDoneline(r);
          if (f.id !== id) continue;
          exact = f.contract;
          break;
        }
      if (pinOf(exact, "rev") === "yes") reviewLine = "yes (pinned on the backlog row)";
      else {
        if (!declared)
          fail(
            `review=yes on direct + ${mode} is the CAPTAIN's call, not a chief's (delivery-review skill: 'no by default, optional yes when the captain requests independent review'); if they asked for it, PIN rev:yes on the backlog row's contract group or re-run with --captain-requested '<their words, or the order ref>' - if they did not, drop --review yes`,
          );
        if (ref === "") fail("--captain-requested needs a non-empty ref: name the captain words or order this review carries out");
        reviewLine = `yes (captain-requested: ${ref})`;
      }
    }
    review = reviewFlag || "no";
  }
  reviewLine ||= review;

  const rowContract = rowContractForId(u8(id), readLedger()) ?? contractUnread();
  let pinFlow = "";
  let pinMode = "";
  let pinRev = "";
  let pinQa = "";
  for (const tok of rowContract.split(/[ \t\n]+/)) {
    if (tok.startsWith("flow:")) pinFlow = tok.slice(5);
    else if (tok.startsWith("mode:")) pinMode = tok.slice(5);
    else if (tok.startsWith("rev:")) pinRev = tok.slice(4);
    else if (tok.startsWith("qa:")) pinQa = tok.slice(3);
  }
  let unauthorized = "";
  let wantsAny = false;
  if (stage !== "scout") {
    if (staged) {
      wantsAny = true;
      if (pinFlow !== "staged" && !declared) unauthorized += " flow:staged";
    }
    if (mode === "crew-ship") {
      wantsAny = true;
      if (pinMode !== "crew-ship" && !declared) unauthorized += " mode:crew-ship";
    }
    if (profiles.length > 0) {
      wantsAny = true;
      if (pinQa !== "yes" && !declared) unauthorized += " qa:yes";
    }
    // A discretionary review is spent here; one staged or crew-ship mandates
    // rides that token's own authority.
    if (review === "yes" && !staged && mode !== "crew-ship") wantsAny = true;
    if (review === "yes" && staged && epicBranch !== "") {
      wantsAny = true;
      if (pinRev !== "yes" && !declared) unauthorized += " rev:yes";
    }
  }
  if (unauthorized !== "")
    fail(
      `time-expensive mode(s) not confirmed:${unauthorized} - the captain's rule: confirm BEFORE using staged/crew-ship/qa/independent review. Put ONE ask to the captain carrying (1) the REASON each is warranted for THIS task (the signal: financial surface, behavioral surface, multi-file risk, ...), (2) the options, (3) your lean - then either PIN the answer on the backlog row's contract group (e.g. [src:cap flow:staged mode:crew-ship rev:yes qa:no]) so it is never re-asked, or re-run with --captain-requested '<the captain's words, or the order ref>' (nothing scaffolded)`,
    );
  if (declared && !wantsAny && reviewFlag !== "yes") fail("--captain-requested with nothing to authorize: this call uses no time-expensive mode (staged/crew-ship/qa/review) - drop the flag");
  if (declared && wantsAny) {
    if (reason === "")
      fail(
        "--captain-requested authorizes time-expensive mode(s) but carries no --reason '<the justification you gave the captain>': the reason must ride the record, not just the ask (nothing scaffolded)",
      );
    if (/[\n\r]/.test(reason)) fail("--reason must be a single line");
  }
  if (reason !== "" && !declared)
    fail(
      "--reason without --captain-requested documents an ask that never happened: a pinned row needs no reason (the pin is the captain's own act) and the cheap path spends nothing - drop the flag",
    );
  let escalation = "";
  if (declared && wantsAny) {
    let spent = "";
    if (staged) spent += " flow:staged";
    if (mode === "crew-ship") spent += " mode:crew-ship";
    if (profiles.length > 0) spent += " qa:yes";
    if (review === "yes") spent += " rev:yes";
    escalation = `Escalation:${spent} - captain-requested: ${ref} - reason: ${reason}`;
  }
  const esc = escalation === "" ? "" : `\n${escalation}`;

  mkdirP(taskDir);
  const branch = b8(crewBranch(u8(id)));
  const captain = captainRead();
  const famOfId = b8(familyOfId(u8(id)));

  // A caller whose cwd has no name resolves no relative path: bun sits in the
  // distro root then, where a project named `src` would name the distro's own.
  const projDir = (p: string): string | null => {
    if (atCaller || p.startsWith("/")) {
      const d = projectDir(u8(p));
      return d === null ? null : b8(d);
    }
    const under = `${mint(`${home}/projects`)}/${p}`;
    if (!isDir(under)) return null;
    const d = projectDir(u8(under));
    return d === null ? null : b8(d);
  };

  const signals = (suffix = ""): string => `When done, print exactly one line starting with \`done: <one-line summary>\`${suffix}.
If blocked, print \`blocked: <reason>\`. If you need a decision, print \`needs-decision: <question>\`.
The MOMENT you print any of those lines, RUN the push as well - a printed line
alone leaves your chief waiting for the watcher's next poll:
\`${root}/bin/ac-done.sh ${id} '<the exact line you printed>'\`
Before you end a turn to wait on your OWN background work (a shell or monitor
you started, a pipeline or CI run, a long command), print \`paused: <the job> - resumes when <what ends it>\` and push it the same way;
otherwise your chief sees only a silent ended turn and must read your pane.`;

  const primaryAccident = (): string => `Edited the primary by mistake? STOP and REPORT it - do NOT clean it up.
\`git checkout --\`, \`git restore\` and \`git reset --hard\` there silently DESTROY
uncommitted captain work at that path, and no lease needs the primary tidy - it
resets from a REF. Leave the edit where it is; the captain owns that tree.`;

  const poolRule = (): string => `Never administer the worktree pool: do not create, remove, return, prune or move
a slot (\`git worktree add|remove|prune\`, \`bin/ac-tree.sh\`), and never write into
a sibling slot. Verifier and qa checkouts come only through \`bin/ac-verify.sh\` /
\`bin/ac-qa.sh\`; needing any other checkout is a \`blocked:\` line saying why.
Keep proof and scratch output (logs, evidence, screenshots, notes) under \`${taskDir}/\` or a temp dir, never inside the worktree, and leave the worktree clean before \`done:\`.`;

  // Baked as RUNNABLE lines carrying --home: the crewmate's pane has no
  // AC_HOME, so its own ac-know.sh would resolve - and write - another record.
  // No clone names nothing: a wrong target is worse than none.
  const knowledge = (): string => {
    const dir = projDir(project);
    if (dir === null) return "";
    const file = knowledgeFile(u8(dir));
    if (file === null) return "";
    const rec = b8(file);
    return `
## Repo knowledge

Facts earlier families verified about this codebase - and the fleet's L2 scene
store above them. PULL by your QUESTION before your first change, and again
whenever you are about to re-derive something a prior family may have proved:
a stale fact stated confidently is worse than no fact, and re-deriving a
proved one burns your window. Run these VERBATIM - they carry the fleet home
your pane cannot resolve:

    ask:      ${root}/bin/ac-know.sh recall '<your question - subject/mechanism/terms>' --home ${home} --repo "$(git rev-parse --show-toplevel)"
    cite:     the ask's output hands you the exact cite/open command per hit -
              run it for the ONE you actually rely on (heat is the fleet's
              re-verify/retire priority; an uncited read is an invisible read)
    full:     cat ${rec}   (the whole record, unranked and unbudgeted - only when
              the ask's hits do not settle it)
    re-check: ${root}/bin/ac-know.sh verify --home ${home} --repo "$(git rev-parse --show-toplevel)"
    record:   ${root}/bin/ac-know.sh add --home ${home} --repo "$(git rev-parse --show-toplevel)" --family ${famOfId} \\
                --src-file <path>:<line> --fact '<what you learned>'

\`--repo "$(git rev-parse --show-toplevel)"\` binds YOUR OWN tree's ROOT,
resolved by your shell when you run the command - never the primary clone,
and not your cwd's subdirectory either.`;
  };

  const designContract = (): string => `
## Report contract

Authoritative contract - per-stage required content and exit criteria
(read it before your first report):
${root}/docs/staged-design-flow-spec.md
Every report carries six required-and-gated sections: Inputs, Summary,
Evidence, Needs Decisions, Risks, Self-Review. A required section with
nothing material to report records one line, \`n/a: <reason>\` - complete,
not missing.
\`## Lessons\` rides alongside those six, in the same report file after
them - never a seventh gated section, never \`n/a\`.
The crewmate layer owns that obligation and its empty form is \`none\`; no
stage exit criterion names it.
Write it in the same pass as the report, before you announce that report ready.
The pre-implement gate re-hashes every admitted report against the
\`report_sha256\` its approval carries, so a Lessons line appended after
that gate changes the hash and reopens it - each report carries the
lessons of the work that produced it.
The heading is the exact string \`## Lessons\` at column 0.
Trace IDs are stage-owned and family-stable: \`R#\` requirements, \`AC#\`
acceptance criteria, \`D#\` architecture decisions, \`T#\` plan tasks.
Append-only across revisions: never renumber or reuse an ID; a removed
item's ID is retired with a one-line note, and no active content references
a retired ID. A revision lists every added, changed, and retired Trace ID.
Reference each accepted prior report by absolute path plus the
\`report_sha256\` your chief's approval carries (the room's \`GATE-ROUTING:\`
receipt); reference its content by Trace ID - never restate it.
Before announcing a report ready, run the inline self-review yourself (no
extra agent, no pane), all nine checks: placeholder scan, consistency
with accepted prior reports, scope, ambiguity, coverage, evidence,
retired-ID check, the architecture Diagram Rule (an accurate diagram when
a trigger applies, else a reasoned \`n/a\`), and the plan TDD check (a
genuine expected RED failure and its verification per behavior-changing
task; each permitted exception carries replacement evidence). The
Self-Review section lists only failures found and fixed, then \`pass\`. A
failure you cannot fix alone never records \`pass\`: an unresolved product
or policy choice becomes \`needs-decision:\`; a contradiction with an
accepted upstream report is announced so the chief returns work to the
earliest affected stage.`;

  // A captain STANDING rule reaches every brief mechanically, selected by the
  // rule-block convention (a `- ` line and its indented continuations) and
  // the STANDING token; a token outside a block is surfaced, never widened
  // into the selector - prose merely mentioning it is no rule.
  const standingRules = (): string => {
    const src = `${recordsDir()}/captain.md`;
    let s = `
## Fleet standing rules

Every STANDING-marked rule block in ${src} (fleet-wide only - a domain-scoped
\`STANDING (domain:<name>):\` block is delivered to that domain's roomchief
directly at intake, not through this brief). Law here like anything else in
this brief.

`;
    try {
      accessSync(fsPath(src), constants.R_OK);
    } catch {
      return noLF(`${s}(no standing preferences file on record)\n`);
    }
    let text = "";
    try {
      text = readFileSync(fsPath(src), "latin1");
    } catch {}
    const blocks: string[] = [];
    const warned: string[] = [];
    let block = "";
    const flush = (): void => {
      if (block !== "" && STANDING.test(block) && !block.includes("STANDING (domain:")) blocks.push(block);
      block = "";
    };
    const lines = records(text);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]!;
      if (line.startsWith("- ")) {
        flush();
        block = line;
      } else if (block !== "" && /^[ \t]/.test(line)) block += `\n${line}`;
      else {
        flush();
        if (STANDING.test(line)) warned.push(`${i + 1}: ${line}`);
      }
    }
    flush();
    s += blocks.length > 0 ? `${blocks.join("\n\n")}\n` : `(no STANDING-marked entries found in ${src})\n`;
    const warn = noLF(warned.join("\n"));
    if (warn !== "")
      s += `\nUNPARSED - mentions STANDING but is not a \`- \` bulleted block, so it is NOT selected above (this channel invents no grammar for it; fix the source line, not this channel) - ${src}:\n${warn}\n`;
    return noLF(s);
  };

  let body: () => string;
  if (stage === "scout")
    body = () => `# Scout brief: ${id}

Project: ${project}
Kind: scout (report only - NEVER open a PR or push)
Captain: ${captain}

## Task

<!-- Orchestrator: describe the investigation here. -->

## Deliverable

Write your findings to ${taskDir}/report.md.
${primaryAccident()}
${poolRule()}
${knowledge()}
${standingRules()}

${signals()}
`;
  else if (stage === "spec")
    body = () => `# Spec brief: ${id}

Project: ${project}
Kind: scout stage: spec (report only - NEVER open a PR, push, or change code)${esc}
Captain: ${captain}

## Task

<!-- Orchestrator: paste the captain's order verbatim here. -->

## Deliverable

Turn the order into a spec at ${taskDir}/report.md:
problem statement, requirements, ACCEPTANCE CRITERIA the captain can check,
edge cases, and explicit out-of-scope. Read the project code as needed to
ground every requirement in reality. Ambiguities you cannot resolve from
the code are \`needs-decision:\` questions - never invent product behavior.
${designContract()}
${primaryAccident()}
${poolRule()}
${knowledge()}
${standingRules()}

${signals()}
`;
  else if (stage === "architecture")
    body = () => `# Architecture brief: ${id}

Project: ${project}
Kind: scout stage: architecture (report only - NEVER open a PR, push, or change code)${esc}
Captain: ${captain}

## Inputs

<!-- Orchestrator: link earlier stage reports by ABSOLUTE path, e.g.
     ${dataDir}/<task>/spec/report.md - otherwise paste the order verbatim.
     The crewmate must read every linked input before starting. -->

## Deliverable

Design the change at system level in ${taskDir}/report.md:
components/modules touched or introduced, their interfaces and contracts,
data flow, and how it fits the EXISTING architecture (read the real code -
name real modules, not imagined ones). For every affected component, verify
that readers can understand the component without reading its internals and
that its internals can change without breaking consumers that honor that contract.
Present the viable alternatives
with tradeoffs and state which one you recommend and why; a design with no
rejected alternative was not designed. Cover the non-functional angles that
apply (compatibility, migration, performance, security). Include the
smallest useful diagram when the Diagram Rule applies, else a reasoned
\`n/a\`. Decisions that
belong to the captain are \`needs-decision:\` questions.
${designContract()}
${primaryAccident()}
${poolRule()}
${knowledge()}
${standingRules()}

${signals()}
`;
  else if (stage === "plan")
    body = () => `# Plan brief: ${id}

Project: ${project}
Kind: scout stage: plan (report only - NEVER open a PR, push, or change code)${esc}
Captain: ${captain}

## Inputs

<!-- Orchestrator: link the spec and architecture reports by ABSOLUTE path
     when they exist, e.g. ${dataDir}/<task>/spec/report.md,
     ${dataDir}/<task>/arch/report.md - otherwise paste the order verbatim.
     The crewmate must read every linked input before starting. -->

## Deliverable

Write the implementation plan to ${taskDir}/report.md:
ordered steps, exact files to touch, test strategy, a
RED -> GREEN -> VERIFY -> REFACTOR TDD sequence per behavior-changing
task, risks and their mitigations, and what would make you abort. Ground
it by reading the real code; a plan that names wrong files is a failed
plan.
${designContract()}
${primaryAccident()}
${poolRule()}
${knowledge()}
${standingRules()}

${signals()}
`;
  else if (stage === "design") {
    const fam = sub.slice(0, sub.indexOf("/"));
    body = () => `# Design brief: ${id}

Project: ${project}
Kind: scout stage: design - the admitted spec/architecture/plan stages in ONE session, gated per report (report only - NEVER change code, push, or open a PR)
Mode: ${mode}
Review: ${reviewLine}${esc}
Captain: ${captain}

## Inputs

<!-- Orchestrator: the captain's order verbatim, plus scouted pointers.
     Record one STAGE-ADMISSION: receipt per stage (admit|skip + grounds)
     in the family room BEFORE this spawn, then cross out the skipped
     sub-stages below; the three-tier pre-implement gate always applies to
     the LAST report produced. -->

## Contract - up to three reports, one session, a GATE between each

Work the needed sub-stages IN ORDER; one report per sub-stage:
1. spec -> ${dataDir}/${fam}/spec/report.md: problem, requirements,
   ACCEPTANCE CRITERIA the captain can check (verbatim, testable),
   edge cases, assumptions, out-of-scope.
2. architecture -> ${dataDir}/${fam}/arch/report.md: components, interfaces,
   the viable alternatives WITH tradeoffs, why the chosen one fits the
   existing system, and the smallest useful diagram when the Diagram Rule
   applies (else a reasoned n/a). For every affected component, verify that
   readers can understand the component without reading its internals and
   that its internals can change without breaking consumers that honor that contract.
3. plan -> ${dataDir}/${fam}/plan/report.md: ordered steps, exact files,
   test strategy per step, and a RED -> GREEN -> VERIFY -> REFACTOR TDD
   sequence per behavior-changing task.

After EACH report print \`done: <sub-stage> report ready (awaiting gate)\`
and STOP - the orchestrator reviews EVERY report before releasing the
next sub-stage; do not start it until they reply with approval or
feedback. Apply feedback as a revision of the SAME report in this
session, then announce it again the same way.
Ground every claim in the real code (cite file:line). Anything you cannot
resolve from the code is a \`needs-decision: <question>\` - never invent
product behavior.
${designContract()}
${primaryAccident()}
${poolRule()}
${knowledge()}
${standingRules()}

${signals()}
`;
  } else if (stage === "implement") {
    const fam = famOfId;
    let reviewBlock: string;
    let deliveryMode: string;
    let signalsSuffix = "";
    if (mode === "crew-ship") {
      reviewBlock = "Review is required and is fulfilled exactly once by the `ac-ship` review step inside the `crew-ship` engine. Do not invoke `ac-verify codereview` separately.";
      deliveryMode = deliveryModeBlock("crew-ship", branch, "", "", "");
      if (epicBranch !== "")
        deliveryMode += `\n- EPIC TARGET: start the engine with \`--target ${epicBranch}\` - this story integrates on the epic branch, and the pipeline's review/base/push/PR all follow that target.`;
      signalsSuffix = " (include the PR URL)";
    } else {
      if (review === "yes") {
        reviewBlock = `Review is required. After delivery preparation and a clean implementation commit, invoke the canonical independent verifier before test/document/lint - the \`crew-verify\` skill seeded in this worktree carries the call, how to read the verdict, and the fix/re-review loop. Use the exact current ref and target base with this command shape (set \`TARGET_REF\` first; run it in the FOREGROUND, never as a harness background task):
\`${root}/bin/ac-verify.sh codereview --repo "$PWD" --ref HEAD --family ${fam} --caller "$AC_CREW_ID" --base "$TARGET_REF" --intent ${brief} --output ${taskDir}/verification/review.json\``;
        deliveryMode = deliveryModeBlock(mode, branch, prBase, epicBranch, "the ordered review/check/doc loop below");
      } else {
        reviewBlock = "Review is not required for this direct task. Skip independent code review unless the captain changes the intake obligation to `review=yes`.";
        deliveryMode = deliveryModeBlock(mode, branch, prBase, epicBranch, "the ordered check/doc loop below");
      }
      if (mode === "direct-pr") signalsSuffix = " (include the PR URL)";
    }
    body = () => `# Crew brief: ${id}

Project: ${project}
Kind: execution (IMPLEMENT + DELIVERY)
Mode: ${mode}
Review: ${reviewLine}${esc}
Captain: ${captain}

## Inputs

<!-- Orchestrator: link accepted stage reports by ABSOLUTE path, e.g.
     ${dataDir}/<task>/spec/report.md, ${dataDir}/<task>/arch/report.md,
     ${dataDir}/<task>/plan/report.md. The crewmate must READ every linked
     input before its first commit and follow the accepted spec/plan.
     Delete this section for single-stage tasks. -->

## Task

<!-- Orchestrator: describe the change here. -->

## Deliverable

You owe exactly one artifact next to this brief: ${taskDir}/report.md, a
handback note whose only required section is \`## Lessons\` - one line per
durable lesson in your own words, or \`none\` when there genuinely are none.
This obligation is UNCONDITIONAL: it fires at every ending - \`done:\`,
\`blocked:\`, \`needs-decision:\`, or \`failed:\` - never only a landed one.

## Working rules

You are in a disposable git worktree at detached HEAD on the clean default branch.
Create or continue branch \`${branch}\` before your first commit and commit all work there.
Never touch the primary checkout or other worktrees.
${poolRule()}
Concretely: \`git rev-parse --show-toplevel\` prints YOUR worktree - commit only
there, on \`${branch}\`. Its \`git-common-dir\` parent is the PRIMARY checkout,
shared by every worktree; never commit there (a pre-commit guard refuses it).
Edited the primary by mistake? STOP and REPORT it - do NOT clean it up.
\`git checkout --\`, \`git restore\` and \`git reset --hard\` there silently DESTROY
uncommitted captain work at that path, and no lease needs the primary tidy - it
resets from a REF. Leave the edit where it is; the captain owns that tree.
IMPLEMENT with TDD: add a failing regression test, make the smallest code change,
run focused checks, then use exactly one implementer self-review path.
Prefer an applicable code-review plugin, with project-provided plugins first, and
give the selected plugin the full current diff.
Only when no applicable plugin exists, manually self-review the full diff.
Do not run a second manual full-diff review after the plugin.
Repair its findings, rerun affected focused checks, then commit.
The implementer owns repairs from
verification; the verifier only reports findings and may suggest a fix.

## Delivery

${deliveryMode}

Follow this order:
1. Prepare delivery inputs and identify the exact target base.
2. Independent review when \`Review: yes\`.
   ${reviewBlock}
   A \`fix\` finding returns here: repair, test, repeat the same plugin-first
   self-review rule, commit, then run a fresh verifier: round 1 reviews the full
   base-to-ref diff; later rounds verify the immediately previous round's open
   findings and review \`previous reviewed_ref..current ref\`. An \`ask-user\` finding holds
   delivery: print \`needs-decision:\` so chief/roomchief relays it to the captain;
   continue only after the recorded decision. Advisory \`suggested_fix\` text is
   input to the implementer, never permission for the verifier to edit.
3. Run tests required by task/project policy; record an explicit skip otherwise.
   VERIFY GATE = changed-file tests + do-not-break tests ONLY - that is
   your per-change check; NEVER run \`tests/run-suite.sh\` (the full suite)
   here, it is not a landing gate and runs only as its own periodic task
   immediately before each Learning DISTILL run.
4. Run the documentation pass and keep relevant docs synchronized.
5. Run lint required by task/project policy; record an explicit skip otherwise.
6. Push only for \`crew-ship\` or \`direct-pr\`.
7. Open the PR for \`crew-ship\`/\`direct-pr\`. For \`local-only\`, who lands \`${branch}\` from here is this fleet's own standing rule, not distro law - see \`## Fleet standing rules\` below; absent one, leave it as a handover for the chief.

Optional QA runs after delivery through \`ac-qa.sh agent\`; a QA defect returns
to IMPLEMENT and invalidates delivery/review evidence affected by the fix.
The FLEET HOME is baked below and passed VERBATIM: your pane carries no
AC_HOME, and every durable source the QA profile freezes descends from that
ONE value, with no per-source flag to supply any of them separately. The qa
charter bakes \`--home\` for its own \`start\` line, but \`agent\` never reads that
charter, so without this line the call can only answer
\`QA_PROFILE_STATUS=needs-profile\`. Fill the placeholders; copy the flag as-is:
\`${root}/bin/ac-qa.sh agent --home ${home} --target <delivered-sha> --task ${fam}-qa --brief <qa-charter> --evidence <dir> [--scope <name> --app <name>] [--ship-run <ship run id>] [--qa-rule <number|default>]\`

${knowledge()}
${standingRules()}
${signals(signalsSuffix)}
`;
  } else {
    const fam = sub.slice(0, sub.indexOf("/"));
    const homeDirective = `Fleet home (pass this VERBATIM as \`--home <path>\` on step 1's \`start\` line - your pane has no AC_HOME to resolve it):
${home}`;
    // The store is NAMED by the one deriver: a second one interpolating
    // data/qa-store/<project> would skip store-dir's scope lowercasing. A
    // brief that names a wrong store is worse than one that names none.
    let storeDirective =
      "No knowledge store is wired for this project yet (no clone to resolve, or store-dir could not resolve one). Run store-less per the `qa` skill: derive every case fresh, skip curation, and SAY SO in the testplan and report.";
    const storeRoot = projDir(project);
    if (storeRoot !== null) {
      const r = run([`${b8(STARTED_BIN)}/ac-qa.sh`, "store-dir"], { cwd: storeRoot, out: "pipe", err: "ignore" });
      if (r.status === 0)
        storeDirective = `Knowledge store (pass this VERBATIM as \`--store <path>\` on step 1's \`start\` line - your pane has no AC_HOME to resolve it):
${subst(r.out)}`;
    }
    body = () => `# QA brief: ${id}

Project: ${project}
Kind: qa charter (verify only - NEVER fix, commit, push, or open a PR; executed by the qa PANE AGENT via ac-qa.sh agent --brief <this file>, never by a crewmate)
Captain: ${captain}

## Inputs

<!-- Orchestrator: name the TARGET (branch ${branch} / PR / commit), link the
     acceptance criteria by ABSOLUTE path (e.g. ${dataDir}/${fam}/spec/report.md
     or the design report), and when a separate e2e repo applies, the
     PRE-LEASED e2e worktree path. The crewmate must read every input first. -->

## Deliverable

Run the \`qa\` skill (it drives the bin/ac-qa.sh pipeline).
${storeDirective}
${homeDirective}

Derive the testplan (testplan.md HERE, next to this brief), boot the
task-scoped infra, exercise the live service per tier (api/db via the e2e
suite, web via the real browser with screenshots), and deliver
${taskDir}/report.md - first line \`verdict: passed|failed|unverifiable\`,
the per-case evidence table, findings, and the QA_* envelope.
Evidence lands in ${taskDir}/evidence/. Proposed e2e specs are a PATCH in
the evidence dir, never a commit.
${poolRule()}
${knowledge()}
${standingRules()}

${signals()}
`;
  }

  // The brief is created before its blocks are read, as the shell opened the
  // redirection before expanding the heredoc.
  let fd: number;
  try {
    fd = openSync(fsPath(brief), "wx");
  } catch (e) {
    if ((e as { code?: string }).code === "EEXIST") fail(`brief already exists: ${brief}`);
    process.exit(1);
  }
  try {
    writeAll(fd, fsPath(body()));
  } catch {
    process.exit(1);
  }
  closeSync(fd);

  if (profiles.length > 0) {
    const qadir = `${dataDir}/${famOfId}/qa`;
    mkdirP(qadir);
    let srcRef = "";
    const pdir = projDir(project);
    if (pdir !== null) srcRef = subst(run(["git", "-C", pdir, "rev-parse", b8(defaultBranch(u8(pdir), true))], { out: "pipe", err: "ignore" }).out);
    const manifest = `${qadir}/manifest.json`;
    let tmp: { path: string; fd: number };
    try {
      tmp = exclusiveTemp(u8(`${manifest}.tmp`));
    } catch {
      process.exit(1);
    }
    const drop = (status: number): never => {
      closeSync(tmp.fd);
      rmSync(tmp.path, { force: true });
      process.exit(status);
    };
    try {
      if (isFile(manifest)) fchmodSync(tmp.fd, statSync(fsPath(manifest)).mode & 0o7777);
    } catch {}
    const jq = run(
      ["jq", "-n", "--arg", "task", famOfId, "--arg", "src", srcRef, "{task: $task, source_ref: $src, required_profiles: ($ARGS.positional | map({profile_key: .}))}", "--args", ...profiles],
      { out: "pipe" },
    );
    if (jq.status !== 0) drop(jq.status);
    try {
      writeAll(tmp.fd, jq.out);
    } catch {
      drop(1);
    }
    closeSync(tmp.fd);
    try {
      renameSync(tmp.path, fsPath(manifest));
    } catch {
      rmSync(tmp.path, { force: true });
      process.exit(1);
    }
    out(`required-profile manifest: ${manifest} (${profiles.length} profile(s))\n`);
  }

  out(`brief scaffolded: ${brief} (stage: ${stage})\n`);
}

main();
