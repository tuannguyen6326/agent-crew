// delegation-guard.ts - PreToolUse hook: refuse harness-native delegation
// from a CHIEF's own checkout.
// The entry is bin/ac-delegation-guard.sh, the fail-open hook shim that starts
// this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-delegation-guard.sh as the oracle the differential leg of
// tests/sh/ac-delegation-guard.test.sh holds this module to.
//
// Wired in .claude/settings.json and .codex/hooks.json under PreToolUse; reads
// the hook payload JSON on stdin and inspects .tool_name.
//
// WHY IT EXISTS. Work created through a harness-native delegation tool has no
// state/<id>.meta. Supervision counts metas, and ac-turnend-guard.sh goes inert
// at zero - so such work is not merely unsupervised: the whole guard stack goes
// structurally inert for the rest of the session, and the work dies with the
// session that made it. That cost is not hypothetical - a fleet running this
// design without the fence lost two workers mid-flight and 73 minutes of
// unnoticed supervision downtime to exactly this. AGENTS.md section 1 already
// forbids it in prose; this is the same rule with an enforcement point.
//
// TWO SIDES, TWO MECHANISMS, because the two directions fail at different
// prices. CREATE side: classified by SHAPE, never a fixed list - a non-MCP
// tool whose name is exactly `Task`, or contains `Agent` or `Workflow`,
// creates delegated work. A deny list would be fail-open against a
// create-tool that ships later: miss one and the whole supervision stack goes
// inert for the rest of the session - a cost this project has actually paid
// (two workers, 73 minutes). Most observe-or-stop names (TaskList, TaskGet,
// TaskOutput, TaskStop, TaskUpdate) never reach this classifier at all - they
// are not exactly `Task` and carry neither `Agent` nor `Workflow`, so the
// shape simply does not match; that is an accident of spelling, not a rule
// about observe verbs. The rare observe verb whose name DOES shape-match
// (ListAgents, only because it contains `Agent`) is carved out by an
// EXACT-NAME allowlist, checked before the shape test. That allowlist is
// deliberately never a second shape rule: a `List*` exemption would
// pre-authorize a future tool nobody has named yet. A shape-matching observe
// verb NOT on the allowlist is DENIED - asymmetric on purpose, because
// missing a create-tool is unsafe (supervision goes inert) while missing an
// observe-tool is only ever degraded (a read gets blocked). mcp__* names are
// excluded outright on both sides: an MCP server's tools are the captain's
// own integrations, not this harness's delegation surface.
//
// SCOPE, three arms: (1) the FLEET HOME - physical cwd == physical AC_HOME. A
// live home is a symlink-based dir, not a git checkout, so the git predicate
// alone left every real fleet's chief session unfenced - measured:
// `git rev-parse` at such a home answers "not a git repository", which fails
// open. A crewmate's cwd is never its fleet's home, so the equality is safe.
// A SOLO session (AC_SOLO=1) is exempt from EVERY arm: it is WORKER-shaped, not
// chief-shaped, and keeps its own subagents exactly as a crewmate's worktree
// does - the slice stays its responsibility, its self-task meta keeps the work
// visible, and the captain is watching it live.
// (2) a genuine PRIMARY checkout (git-dir == git-common-dir, the same
// predicate ac-turnend-guard.sh and ac-sessionstart-nudge.sh use) - a fleet
// hosted on a repo itself. A crewmate's leased worktree is a LINKED checkout
// and is never touched - a crewmate using subagents inside its own worktree is
// a capability it legitimately has, and removing it is a different decision
// than the one this guard makes. This is why the guard can live in the
// repo-tracked settings.json at all: the file is shared with every crewmate
// worktree (seedCrewSettings keeps a repo-shipped copy), and only the scope
// test tells the two apart.
// (3) AC_HOME ABSENT. Arms 1 and 2 both need a home - arm 1 to compare against,
// arm 2 because the fleet home it misses is not a git checkout at all - so a
// chief that LOST its home fell through both and was allowed: a drydock chief
// ran three days like that with the fence down. This arm owns that whole case,
// and no home is resolved, named or guessed for it (bin/ac-lib.sh: "A fleet
// home is NAMED, never guessed"). The discriminator is ac-sessionstart-nudge.sh's,
// reused whole, because it answers exactly this question - which homeless
// session OUGHT to have had a home: the BADGES a session is given INSTEAD of one
// (AC_CREW_ID, AC_FLEET_NAME - set on the crewmate launch line and nowhere else),
// then linked-worktree geometry on the cwd for a crewmate that carries no
// scalars at all. AC_SCOPE is deliberately NOT a badge: a roomchief is given
// AC_HOME *and* AC_SCOPE together, so a scope with no home is a chief that lost
// one - the incident's own shape, and the one this arm must catch. The arm is
// keyed on the VARIABLE, unset or empty, never on a resolved path: an AC_HOME
// that is set but cannot be entered keeps arms 1 and 2 exactly.
//
// ESCAPE HATCH: AC_ALLOW_DELEGATION=1 in the environment. Deliberate, and set
// at launch - a chief cannot grant it to itself mid-turn.
//
// Fails open: non-matching payloads, an unparseable payload, a missing
// DEPENDENCY (jq anywhere, git under arm 3; bun, through the shim), a linked
// worktree, or a checkout git cannot read all exit 0 - a broken guard must
// never wedge the harness. EXACTLY ONE of those is narrower under arm 3,
// deliberately: a cwd git reads as no repo at all is indistinguishable from a
// live fleet home, the very shape arm 3 exists to catch, so homeless it DENIES
// where a session with a home still allows. That is a bounded trade, not a
// blanket one - arm 3 reads git's EMPTY answer as the deny, so git is a
// dependency there and not just a probe (a missing git would read as "not a
// repo" and fence a crewmate), and it is guarded like jq; only a genuine
// not-a-repo answer denies.
// What keeps that deny from reaching a session outside any fleet is the WIRING,
// not a predicate here. BOTH entry points gate on the guard being present in
// the tree - .claude/settings.json runs "$CLAUDE_PROJECT_DIR"/bin/<entry> and
// .codex/hooks.json runs "$(pwd -P)"/bin/<entry>, each behind its own [ -x ] -
// so a tree that does not carry the entry never runs it. A fleet home always
// does (its bin/ is symlinked to the distro). Both are pinned by the test file:
// the budget rests on them, so neither may be enumerated alone.
// Exit codes: 0 allow, 2 deny; nothing on stdout, the refusal one line on
// stderr. Files: none.
//
// THE READS, the original's: the payload is stdin to its end with NULs
// dropped and trailing LFs stripped (empty allows), and the name is jq's
// `-r '.tool_name // empty'` over it plus one LF, spawned, its stdout taken
// whatever jq's status, NULs dropped and trailing LFs stripped. `git -C <cwd>
// rev-parse --path-format=absolute --git-dir` and `--git-common-dir` are
// spawned the same way, stderr dropped, stdin inherited. The cwd is the
// physical one bin/ac-bun.sh hands over; AC_HOME is entered as physicalDir
// enters it, and one that cannot be entered reads as no home path.
//
// A BROKEN PORT. The frozen original needs only bash and jq: copying
// tests/fixtures/ac-delegation-guard.sh over bin/ac-delegation-guard.sh in the
// checkout the fleets run (the wiring names that path) restores it whole until
// the fix lands; the captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - every value jq printed before its first parse error is the name, joined
//   by LF: `{"tool_name":"Task"} x` refuses, and two values `Read` and `Agent`
//   refuse naming `Read<LF>Agent`;
// - a name that is no string is judged by jq's JSON text: an object holding
//   an `Agent` key refuses, `["Task"]` allows;
// - a NUL in the name (raw on stdin or `\u0000`) is dropped and a trailing LF
//   stripped before the shape test: `Ta\u0000sk` refuses, `m\u0000cp__Agent`
//   is an mcp__ name.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: with no bun on PATH the shim allows at once, saying nothing, where
//   the original judged; a module that cannot load or crashes allows too.
// - HOME RESOLUTION: a home or cwd whose name ends in LF is the directory it
//   names, where the original's `$(...)` dropped the LF and compared the
//   sibling; a relative AC_HOME is entered without CDPATH, where an exported
//   CDPATH made cd echo its destination into the original's captured path, so
//   the fleet home read as no home.
// - A caller whose cwd Bun cannot enter (a name ending in a backslash)
//   resolves no relative AC_HOME: arm 2 decides.
// - TEMP: the original fed jq a here-string, a temp file under $TMPDIR, else
//   /tmp; with neither writable it allowed with bash's own line, where the
//   port pipes jq's stdin and judges.
// - BYTES: an environment value arrives decoded, so a non-UTF-8 byte in
//   AC_HOME reaches the filesystem as U+FFFD and the home reads as unresolved.
//
// CALLERS: the PreToolUse wiring of .claude/settings.json and
// .codex/hooks.json, each behind its own [ -x ] gate; no script runs it.

import { writeSync } from "node:fs";
import { commandV, enterCaller, hookCapture, hookJq, hookPayload, physicalDir } from "./lib.ts";

const { atCaller } = enterCaller(process.argv.slice(2));
const here = process.argv[2] ?? "";

if (process.env.AC_ALLOW_DELEGATION === "1" || process.env.AC_SOLO === "1") process.exit(0);
if (!commandV("jq")) process.exit(0);
const payload = hookPayload();
if (payload === "") process.exit(0);

const tool = hookJq(".tool_name // empty", payload);
if (tool === "" || tool.startsWith("mcp__")) process.exit(0);
if (tool === "ListAgents") process.exit(0);
if (tool !== "Task" && !tool.includes("Agent") && !tool.includes("Workflow")) process.exit(0);

if (here === "") process.exit(0);
const gitDir = (which: "--git-dir" | "--git-common-dir"): string => hookCapture(["git", "-C", here, "rev-parse", "--path-format=absolute", which]);
const home = process.env.AC_HOME ?? "";
if (home === "") {
  if (!commandV("git")) process.exit(0);
  const gd = gitDir("--git-dir");
  const gcd = gitDir("--git-common-dir");
  if (gd !== "" && gd !== gcd) process.exit(0);
  // GEOMETRY OUTRANKS THE BADGES, and only here: a badge is an ordinary
  // exported string and no worker is ever AT a primary checkout (a crewmate
  // and a verification pane both lease a LINKED worktree), so honouring one
  // there would silently re-open this very cell while buying nothing. On a cwd
  // that is not a repo at all - the fleet-home shape - the badges are the
  // whole discriminator.
  if (gd === "" && (process.env.AC_CREW_ID || process.env.AC_FLEET_NAME)) process.exit(0);
} else {
  const homeP = atCaller || home.startsWith("/") ? physicalDir(home) : null;
  if (homeP === null || here !== homeP) {
    const gd = gitDir("--git-dir");
    const gcd = gitDir("--git-common-dir");
    if (gd === "" || gcd === "" || gd !== gcd) process.exit(0);
  }
}

writeSync(2, Buffer.from(`ac-delegation-guard: ${tool} creates work with no state/<id>.meta, which leaves the whole supervision stack inert and dies with this session. Delegate through bin/ac-spawn.sh instead (AGENTS.md section 1). Deliberate override: launch with AC_ALLOW_DELEGATION=1.\n`, "latin1"));
process.exit(2);
