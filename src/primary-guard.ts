// primary-guard.ts - PreToolUse hook: refuse a crewmate/roomchief EDITING a
// file that lives in the PRIMARY checkout but outside its own tree.
// The entry is bin/ac-primary-guard.sh, the fail-open hook shim that starts
// this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-primary-guard.sh as the oracle the differential leg of
// tests/sh/ac-primary-guard.test.sh holds this module to.
//
// Wired in .claude/settings.json and .codex/hooks.json under PreToolUse;
// reads the hook payload JSON on stdin and inspects .tool_name / .tool_input
// - the sibling of src/ledger-guard.ts and src/delegation-guard.ts.
//
// WHY IT EXISTS. @da5a33c closed the COMMIT door (the pre-commit guard
// src/tree.ts installs); the EDIT door stayed open and @ad60acb covered it in
// PROSE only (the execution brief seed makes a primary edit a STOP+REPORT).
// On 2026-07-27 that prose failed for the first MEASURED time: a crewmate
// Edited the primary's AGENTS.md by absolute path while running its checks in
// its own worktree, saw an empty diff there, and spent minutes on a false "my
// Read was cached" diagnosis - it was writing one tree and verifying another.
// The hazard behind it is the TIDY-UP the mistake invites: `git checkout --` /
// `git restore` / `git reset --hard` in the primary silently destroy
// uncommitted captain work.
//
// A SECOND LAYER, NOT A REPLACEMENT. The prose stays a layer everywhere. A
// codex PRIMARY on this repo gets this guard too (.codex/hooks.json mirrors
// the claude PreToolUse wiring; live probe pending), with the coverage
// residual below accepted: opencode/pi worktree surfaces wire only the
// bash-tool policy (their plugin APIs gate bash, not Edit/Write), and
// crewmates in a project whose repo ships no hook wiring at all are covered
// by the prose alone.
//
// WHERE (D1, reused from the commit guard verbatim): git-common-dir's PARENT is
// the PRIMARY checkout, shared by every linked worktree; --show-toplevel is the
// session's OWN tree. Deny when the target resolves under the primary and NOT
// under the own tree. A leased worktree is a SUBTREE of the primary
// (<repo>/.crew/worktrees/<n>), so the own-tree test is checked FIRST - and in
// the primary itself the two are the same tree, so a chief's legitimate primary
// write passes by geometry rather than by a special case.
// WHO (D2, likewise): AC_CREW_ID (a crewmate, src/spawn.ts crewLaunchEnv) or
// AC_SCOPE (a roomchief, src/spawn.ts's --roomchief launch line) - the captain
// carries neither and is never fenced, even when their own session runs inside
// a leased worktree.
//
// THE TARGET is resolved PHYSICALLY, so a relative path, a `..` climb and a
// symlink all land on the same footing as git's own absolute answers: the
// path's directory (everything before its last `/`; `.` when it has none, `/`
// when that is empty) is entered as physicalDir enters it - a relative one
// from the cwd bin/ac-bun.sh hands over - and the last component (empty for a
// path ending in `/`) is joined back on. That component need not exist (a
// Write creates it); its parent must.
//
// Fails open: neither crew scalar, a non-matching tool, missing jq, an
// unparseable payload, an empty path, a target whose parent directory does not
// exist, or a rev-parse that errors - all exit 0 (no bun, and a module that
// cannot load, are the shim's). A broken guard must never wedge the harness.
// Exit codes: 0 allow, 2 deny; nothing on stdout, the refusal three lines on
// stderr. Files: none.
//
// RESIDUAL: like its two siblings, this covers the claude harness's
// Edit/Write/NotebookEdit tools only. A write performed through the Bash tool
// (sed, echo >, a heredoc) still gets through - as do the fleet's own shell
// writes to the primary, e.g. ensureGitignore (src/tree.ts), which is why
// they need no exemption here. So does a write that creates a brand-new
// directory tree in the primary: its parent cannot be entered, so it fails
// open.
//
// THE READS, the original's: the payload is stdin to its end with NULs
// dropped and trailing LFs stripped (empty allows); the name is jq's
// `-r '.tool_name // empty'` and the path jq's `-r '.tool_input.file_path //
// empty'` (Edit, Write) or `-r '.tool_input.notebook_path // empty'`
// (NotebookEdit), each over the payload plus one LF, spawned, its stdout
// taken whatever jq's status, NULs dropped and trailing LFs stripped. The own
// tree is `git -C <cwd> rev-parse --show-toplevel` and the common dir
// `git -C <cwd> rev-parse --path-format=absolute --git-common-dir`, spawned
// the same way, stderr dropped, stdin inherited; the primary is the common
// dir less its last `/<component>`.
//
// A BROKEN PORT. The frozen original needs only bash, jq and git: copying
// tests/fixtures/ac-primary-guard.sh over bin/ac-primary-guard.sh in the
// checkout the fleets run (the wiring names that path) restores it whole until
// the fix lands; the captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - the path is jq's text: a file_path that is no string is judged by its JSON
//   text, and a payload holding a second value joins the name jq printed for
//   both with LF (an `Edit<LF>Edit` name is no tool).
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: with no bun on PATH the shim allows at once, saying nothing, where
//   the original judged; a module that cannot load or crashes allows too.
// - HOME RESOLUTION, for the target's directory: a relative one is entered
//   without CDPATH, where an exported CDPATH could send the original's cd to a
//   namesake and its echo made the target a two-line path (`sub/x` from a
//   worktree, with CDPATH naming the primary, refused there); one spelled as
//   a cd operand (`-`, `-L`, `-P`) is the directory of that name, where the
//   original's cd read OLDPWD or an option; one whose name ends in LF is the
//   directory it names, where the original's `$(...)` dropped the LF and
//   judged the sibling.
// - LOGICAL CWD: a relative directory is walked from the physical cwd, where
//   the original's cd walked `..` from its logical $PWD first - from a cwd
//   entered through a symlink, `../x` named a different directory there.
// - A caller whose cwd Bun cannot enter (a name ending in a backslash)
//   resolves no relative target: it allows.
// - TEMP: the original fed jq a here-string, a temp file under $TMPDIR, else
//   /tmp; with neither writable it allowed with bash's own line, where the
//   port pipes jq's stdin and judges.
//
// CALLERS: the PreToolUse wiring of .claude/settings.json and
// .codex/hooks.json, each behind its own [ -x ] gate; no script runs it.

import { writeSync } from "node:fs";
import { commandV, enterCaller, hookCapture, hookJq, hookPayload, physicalDir } from "./lib.ts";

const { atCaller } = enterCaller(process.argv.slice(2));
const here = process.argv[2] ?? "";

if (!process.env.AC_CREW_ID && !process.env.AC_SCOPE) process.exit(0);
if (!commandV("jq")) process.exit(0);
const payload = hookPayload();
if (payload === "") process.exit(0);

const tool = hookJq(".tool_name // empty", payload);
if (tool === "" || tool.startsWith("mcp__")) process.exit(0);
const filter = tool === "Edit" || tool === "Write" ? ".tool_input.file_path // empty" : tool === "NotebookEdit" ? ".tool_input.notebook_path // empty" : null;
if (filter === null) process.exit(0);
const path = hookJq(filter, payload);
if (path === "") process.exit(0);

// The path is bytes (latin1) and so are git's answers; a name handed to the
// filesystem is its UTF-8 spelling, which jq's output always is.
const slash = path.lastIndexOf("/");
const dir = slash < 0 ? "." : path.slice(0, slash) || "/";
const dirP = atCaller || dir.startsWith("/") ? physicalDir(Buffer.from(dir, "latin1").toString("utf8")) : null;
if (dirP === null) process.exit(0);
const target = `${Buffer.from(dirP, "utf8").toString("latin1").replace(/\/$/, "")}/${path.slice(slash + 1)}`;

if (here === "") process.exit(0);
const own = hookCapture(["git", "-C", here, "rev-parse", "--show-toplevel"]);
const common = hookCapture(["git", "-C", here, "rev-parse", "--path-format=absolute", "--git-common-dir"]);
if (own === "" || common === "") process.exit(0);
const cut = common.lastIndexOf("/");
const primary = cut < 0 ? common : common.slice(0, cut);

if (target.startsWith(`${own}/`)) process.exit(0);
if (!target.startsWith(`${primary}/`)) process.exit(0);

writeSync(
  2,
  Buffer.from(
    `ac-primary-guard: REFUSED ${tool} on ${target} - that path is in the PRIMARY checkout (${primary}), not in YOUR tree (${own}).\n` +
      `ac-primary-guard: you probably meant ${own.replace(/\/$/, "")}/${target.slice(primary.length + 1)} - edit YOUR tree, and verify with git -C "$(git rev-parse --show-toplevel)".\n` +
      "ac-primary-guard: already edited the primary? STOP and REPORT it - do NOT tidy up. `git checkout --`, `git restore` and `git reset --hard` there silently DESTROY uncommitted captain work, and nothing needs cleaning (a lease resets from a REF).\n",
    "latin1",
  ),
);
process.exit(2);
