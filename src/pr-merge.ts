// pr-merge.ts - merge a crewmate's GitHub PR after captain approval: pinned to
// the head bin/ac-pr-check.sh recorded (the head the captain approved), behind
// the qa.require_for_ship gate, with the landing interlock, and with the
// OUTCOME proven by the forge before the landed proof bin/ac-teardown.sh
// trusts is written. The entry is bin/ac-pr-merge.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, and the
// bash original it replaced stays frozen at tests/fixtures/ac-pr-merge.sh as
// the oracle the differential leg of tests/sh/ac-pr-merge.test.sh holds this
// module to.
//
//   ac-pr-merge.sh <id> <github-pr-url> [-- <gh merge flags>]
//
// ORDER, every refusal on stderr as `ERROR: <text>`, exit 1 unless named:
// 1. `required tool not found: gh` (the live PATH), before the arguments.
// 2. `usage: ac-pr-merge.sh <id> <pr-url> [-- <gh flags>]` when <id> or <url>
//    is empty.
// 3. The meta, state/<id>.meta (state/ minted; the id a path component as
//    given, so `../x` names <home>/x.meta): homeless prints the AC_HOME
//    refusal and then `no crewmate meta for <id>` (W1, the bash's
//    `$(ac_task_meta)` swallow, kept); no regular file there is that line
//    alone.
// 4. `not a full GitHub PR URL: <url>` unless the url matches the shell
//    pattern `https://github.com/*/*/pull/[0-9]*` - `*` spans `/` and may be
//    empty, anything may follow the digit, case and scheme are exact.
// 5. THE TAIL: only when the third argument is exactly `--` are the rest gh
//    flags; any other tail is DROPPED silently (W2: `<id> <url> --merge`
//    merges with --squash). Every flag word, a VALUE too (W3), is scanned in
//    order: `--repo`, `--repo=*` or `-R*` refuses `--repo/-R overrides are not
//    allowed; the PR URL decides` before any gh call; `--merge`, `--rebase` or
//    `--squash` drops the default --squash (`-- --subject --merge` merges with
//    no method flag of ours).
// 6. THE QA GATE. project_dir is the meta's last project_dir= (cut at a NUL as
//    awk handed it over); a meta that is there and unreadable is metaGet's
//    `WARN: cannot read meta file <meta>` alone, exit 1 (W8 - the bash's bare
//    assignment). When project_dir is non-empty and a directory,
//    qaRequired <project_dir> reads the policy in process - src/lib.ts's
//    twins of ac_qa_required and ac_qa_gate_ok, held to the bash functions by
//    tests/ts/qa-gate.test.ts, their named divergences at that block; the
//    ERROR they throw for a policy they cannot read (a legacy config's
//    RETIRED copy, a yaml they cannot read, a git that cannot run) is the
//    run's exit 1, before any gh call. Enforced, the head is `gh pr view
//    <url> --json headRefOid -q .headRefOid` (stderr dropped, its status
//    unseen, read as `$(...)` read it: NULs dropped, trailing newlines cut);
//    empty is `merge blocked:
//    qa.require_for_ship is enforced but the PR head SHA could not be resolved
//    (gh pr view failed or returned empty) - run crew-qa and retry once the
//    head resolves`. Then qaGateOk <project_dir> <head> <id>, which reads the
//    policy again as the bash gate did: its `qa:` lines on stdout, its WARNs
//    on stderr, and a refusal is `merge blocked by qa.require_for_ship (see
//    message above)`. A lab bin/ (the ROOT seam) supplies the remedy's
//    ac-know.sh, never the gate.
// 7. THE HEAD PIN. rec is the meta's pr_head; unless rec is non-empty AND the
//    meta's pr= is exactly <url> (an empty `pr_head=`, another PR's pr=, a
//    trailing space all refuse): `merge refused: no head is recorded for <url>
//    on <id>, so no approved head can bind the merge - record it
//    (bin/ac-pr-check.sh <id> <url>), have the captain approve that head, then
//    merge`. The live head is the gate's when the gate resolved one (ONE
//    headRefOid read in all), else a fresh read; an EMPTY live head skips the
//    check, a different one refuses `merge refused: the PR head moved since it
//    was recorded (recorded <rec12>, now <live12>) - the approval covered the
//    recorded head; re-record it (bin/ac-pr-check.sh <id> <url>) and ask
//    again`. <x12> is `${x:0:12}` (shellPrefix: characters under a UTF-8
//    locale, bytes under any other). The merge is pinned to rec.
// 8. THE INTERLOCK (contract: ac-lib.sh's landing-ledger block). family is
//    familyOfId(id) (a stage suffix whose data dir exists names the family).
//    The landed set is the lines of `gh pr diff <url> --name-only` (stderr
//    dropped, its status unseen) as `while IFS= read -r` read them: a blank
//    line is the path "" (W5 - it becomes an empty-path ledger record), blanks
//    and TABs kept, NULs dropped, an unterminated last line dropped. A
//    non-empty set gets landingWarn (src/lib.ts: one LANDING-OVERLAP WARN per
//    <24h record of another family; an unreadable ledger ends the run with
//    awk's 2, an empty-family record whose path the shell's arithmetic refuses
//    with 1 - both before the merge). knowledgeWarn (the KNOWLEDGE-GAP flag,
//    its remedy naming <STARTED_BIN>/ac-know.sh and the physical home) runs on
//    EVERY landing that gets here, whatever the set.
// 9. THE MERGE. pr_attempt=<url> is written first (metaSet): a write that
//    fails ends the run before any merge, with mv's status or 1. Then `gh pr
//    merge <url> [--squash] [<flags>...] --match-head-commit <rec>`, stdio
//    inherited; merge_rc is the shell's status for it (128+signal for a
//    signalled gh - W9 -, 127 for one that cannot start).
// 10. THE PROOF. Up to three `gh pr view <url> --json state -q .state` reads
//    (stderr dropped), each but a MERGED one followed by a spawned `sleep 1` -
//    the third too (W4); a sleep that fails ends the run with its status. Not
//    MERGED (`OPEN`, `merged`, empty): status `merge-unproven: <url>
//    state=<s|unreadable> merge_rc=<rc>` and `merge NOT proven for <url> - gh
//    pr merge exited <rc> and the forge answered state=<s|unreadable> across 3
//    reads (auto-merge queued? protected branch? unreadable API?). pr= and
//    pr_merged stay unset so teardown keeps refusing; re-check with: gh pr
//    view <url> --json state, then re-run this command`. A merge call that
//    exited 0 merged rec. One that failed is judged by a FRESH headRefOid
//    read: empty is status `merge-unproven: <url> is MERGED but its merged
//    head is unreadable` and `the PR is MERGED, but no pinned call of this run
//    merged it and the forge answered no merged head - pr_merged stays unset
//    so teardown keeps refusing; re-run once gh pr view <url> --json
//    headRefOid answers`; another head is status `merge-unproven: <url>
//    merged at <m12>, not the approved <h12>` and `the PR is MERGED at <m12>,
//    not the approved head <h12> - pr_merged stays unset; re-record the
//    merged head (bin/ac-pr-check.sh <id> <url>), get it approved, then
//    re-run`; rec itself prints on stdout `note: the merge call failed (exit
//    <rc>) but the PR is MERGED - an earlier attempt landed; recording the
//    proof.`
// 11. THE RECORD. A non-empty landed set gets landingRecord (src/lib.ts: the
//    7-day prune and the append under state/.landings.lock, the UNSERIALIZED
//    WARN past ten spawned `sleep 1`s): a failed mv exits 1 with mv's line,
//    the temp left and NO proof written - for a merge that LANDED (W6;
//    teardown then refuses merged work until a re-run reaches the recovery
//    arm). Then the META PROOF, each key dropped and appended (metaSet):
//    pr=<url>, pr_merged_head=<the merged head>, pr_merged=1 - pr_merged=1 is
//    the landed proof src/teardown.ts's headLanded accepts, bounded to the
//    worktree heads pr_merged_head contains. Then the status `merged: <url>`
//    and on stdout `merged <url>`, exit 0.
// Every status line is statusAppend's UNGUARDED arm (the bash ran
// ac_status_append bare): `<iso> <line>` appended to state/<id>.status and
// mirrored to the task's timeline.log; a date that fails ends the run with its
// status, an append that fails with 1 before the mirror - for `merged:` that
// is AFTER pr_merged=1, with no merged line (W7).
//
// EXIT: 0 merged and proven; 1 for every ERROR and the cases above; awk's 2
// for an unreadable ledger; mv's status for a meta write mv refused; a sleep's
// or date's own status where one failed.
//
// DIVERGENCES from the original:
// - SHELL-OWN STDERR is not reproduced: bash's job notice for a signalled gh
//   (`line 124: <pid> Terminated: 15 gh "${merge_args[@]}"`, W9), the
//   redirection lines of a status log that cannot be written (a meta whose
//   directory takes no temp is the meta lock's WARN on both sides now),
//   the arithmetic line of an empty-family ledger record, awk's `can't open
//   file` for an unreadable ledger (the differential leg's rows 6, 7, 10).
// - The meta and ledger temps are created EXCLUSIVELY (metaSet,
//   landingRecord - the bash wrote through a planted `.tmp.<pid>` sibling;
//   tests/ts/pr-check.test.ts and tests/ts/merge-local.test.ts).
// - require reads PATH through Bun.which, which refuses a non-executable PATH
//   file `command -v` accepted (every port shares it).
// - argv and the meta's bytes: an argument arrives decoded, and a project_dir,
//   head or landed path that is not UTF-8 is spawned decoded (as U+FFFD).
//
// CALLERS: no bin/, src/, dashboard/ or hook runs this entry - the chief runs
// it by hand after the captain approves (.agents/skills/task-lifecycle,
// docs/getting-started.md), so no `set -e` caller dies on it and nothing fails
// soft; a bun-less run answers `ERROR: required tool not found: bun`, exit 1,
// from the shim, before any forge call. Its products are read elsewhere:
// pr_merged=1 and pr_merged_head by src/teardown.ts (headLanded),
// pr_merged by dashboard/app.ts, pr= by dashboard/lib.ts and this entry's next
// run, the ledger by src/merge-local.ts and bin/ac-ready.sh.
import { statSync, writeSync } from "node:fs";
import {
  die,
  enterCaller,
  familyOfId,
  knowledgeWarn,
  landingRecord,
  landingWarn,
  metaGet,
  metaSet,
  qaGateOk,
  qaRequired,
  require,
  shellPrefix,
  shellStatus,
  spawnShellSync,
  statusAppend,
  taskMeta,
} from "./lib.ts";

const b = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const native = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (buf: Buffer): string => buf.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

// A lib twin throws the status where the bash's errexit ended the run.
function exitWith(e: unknown): never {
  const s = (e as { status?: number }).status;
  if (s === undefined) throw e;
  process.exit(s);
}

function stat(p: string): ReturnType<typeof statSync> | null {
  try {
    return statSync(p);
  } catch {
    return null;
  }
}

// `gh ... 2>/dev/null || true` inside `$(...)` or `< <(...)`: the caller's
// stdin, stderr dropped, the status never read.
function ghOut(a: string[]): Buffer {
  try {
    return Buffer.from(spawnShellSync(["gh", ...a], { stdin: "inherit", stdout: "pipe", stderr: "ignore" }).stdout);
  } catch {
    return Buffer.alloc(0);
  }
}

const { args } = enterCaller(process.argv.slice(2));
require("gh");
const id = args[0] ?? "";
const url = args[1] ?? "";
if (!id || !url) die("usage: ac-pr-merge.sh <id> <pr-url> [-- <gh flags>]");
const I = bytes(id);
const U = bytes(url);
const meta = taskMeta(id);
if (!stat(meta)?.isFile()) die(b(`no crewmate meta for ${I}`));
if (!/^https:\/\/github\.com\/[\s\S]*\/[\s\S]*\/pull\/[0-9]/.test(url)) die(b(`not a full GitHub PR URL: ${U}`));

const extra = args[2] === "--" ? args.slice(3) : [];
let method = "--squash";
for (const f of extra) {
  if (f === "--repo" || f.startsWith("--repo=") || f.startsWith("-R")) die("--repo/-R overrides are not allowed; the PR URL decides");
  if (f === "--merge" || f === "--rebase" || f === "--squash") method = "";
}

// `x="$(ac_meta_get ...)"` bare under errexit: an unreadable meta ends the run
// after metaGet's WARN.
const metaValue = (key: string): string => {
  try {
    return metaGet(meta, key).replace(/\0[\s\S]*$/, "");
  } catch {
    process.exit(1);
  }
};
const viewHead = (): string => subst(ghOut(["pr", "view", url, "--json", "headRefOid", "-q", ".headRefOid"]));

const projectDir = metaValue("project_dir");
const dir = native(projectDir);
let headSha = "";
if (projectDir !== "" && stat(dir)?.isDirectory()) {
  let required = false;
  try {
    required = qaRequired(dir);
  } catch (e) {
    exitWith(e);
  }
  if (required) {
    headSha = viewHead();
    if (headSha === "")
      die(
        "merge blocked: qa.require_for_ship is enforced but the PR head SHA could not be resolved (gh pr view failed or returned empty) - run crew-qa and retry once the head resolves",
      );
    let open = false;
    try {
      open = qaGateOk(dir, headSha, id);
    } catch (e) {
      exitWith(e);
    }
    if (!open) die("merge blocked by qa.require_for_ship (see message above)");
  }
}

const recHead = metaValue("pr_head");
// Read inside `[ ]` of an `&&` list, where errexit slept: unreadable is "".
const recordedPr = (): string => {
  try {
    return metaGet(meta, "pr").replace(/\0[\s\S]*$/, "");
  } catch {
    return "";
  }
};
if (recHead === "" || recordedPr() !== U)
  die(
    b(
      `merge refused: no head is recorded for ${U} on ${I}, so no approved head can bind the merge - record it (bin/ac-pr-check.sh ${I} ${U}), have the captain approve that head, then merge`,
    ),
  );
const liveHead = headSha !== "" ? headSha : viewHead();
if (liveHead !== "" && liveHead !== recHead)
  die(
    b(
      `merge refused: the PR head moved since it was recorded (recorded ${shellPrefix(recHead, 12)}, now ${shellPrefix(liveHead, 12)}) - the approval covered the recorded head; re-record it (bin/ac-pr-check.sh ${I} ${U}) and ask again`,
    ),
  );
headSha = recHead;

const family = familyOfId(id);
const lines = ghOut(["pr", "diff", url, "--name-only"]).toString("latin1").split("\n");
lines.pop();
const landed = lines.map((p) => native(p.replace(/\0/g, "")));
try {
  if (landed.length > 0) landingWarn(family, landed);
} catch (e) {
  exitWith(e);
}
knowledgeWarn(family, dir);

// `ac_meta_set` bare under errexit: mv's status, or 1 for a temp the shell
// could not write.
const metaWrite = (key: string, value: string): void => {
  try {
    metaSet(meta, key, value);
  } catch (e) {
    const err = e as { code?: string; status?: number };
    process.exit(err.code === "EMV" ? err.status ?? 1 : 1);
  }
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
const run = (cmd: string[]): number => {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  } catch {}
  return shellStatus(r);
};

metaWrite("pr_attempt", U);
const mergeRc = run(["gh", "pr", "merge", url, ...(method ? [method] : []), ...extra, "--match-head-commit", native(headSha)]);

let state = "";
for (let i = 0; i < 3; i++) {
  state = subst(ghOut(["pr", "view", url, "--json", "state", "-q", ".state"]));
  if (state === "MERGED") break;
  const s = run(["sleep", "1"]);
  if (s !== 0) process.exit(s);
}
if (state !== "MERGED") {
  const said = state || "unreadable";
  appendStatus(`merge-unproven: ${U} state=${said} merge_rc=${mergeRc}`);
  die(
    b(
      `merge NOT proven for ${U} - gh pr merge exited ${mergeRc} and the forge answered state=${said} across 3 reads (auto-merge queued? protected branch? unreadable API?). pr= and pr_merged stay unset so teardown keeps refusing; re-check with: gh pr view ${U} --json state, then re-run this command`,
    ),
  );
}
// Only this run's pinned call is known to have merged headSha; a PR found
// MERGED after a failed call was merged by something else, at whatever head
// the forge names.
let mergedHead = headSha;
if (mergeRc !== 0) {
  mergedHead = viewHead();
  if (mergedHead === "") {
    appendStatus(`merge-unproven: ${U} is MERGED but its merged head is unreadable`);
    die(
      b(
        `the PR is MERGED, but no pinned call of this run merged it and the forge answered no merged head - pr_merged stays unset so teardown keeps refusing; re-run once gh pr view ${U} --json headRefOid answers`,
      ),
    );
  }
  if (mergedHead !== headSha) {
    const m12 = shellPrefix(mergedHead, 12);
    const h12 = shellPrefix(headSha, 12);
    appendStatus(`merge-unproven: ${U} merged at ${m12}, not the approved ${h12}`);
    die(
      b(
        `the PR is MERGED at ${m12}, not the approved head ${h12} - pr_merged stays unset; re-record the merged head (bin/ac-pr-check.sh ${I} ${U}), get it approved, then re-run`,
      ),
    );
  }
  writeSync(1, `note: the merge call failed (exit ${mergeRc}) but the PR is MERGED - an earlier attempt landed; recording the proof.\n`);
}

let recorded = true;
try {
  if (landed.length > 0) recorded = landingRecord(family, landed);
} catch (e) {
  exitWith(e);
}
if (!recorded) process.exit(1);
metaWrite("pr", U);
metaWrite("pr_merged_head", mergedHead);
metaWrite("pr_merged", "1");
appendStatus(`merged: ${U}`);
writeSync(1, b(`merged ${U}\n`));
