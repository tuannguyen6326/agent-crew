// ledger-guard.ts - PreToolUse hook: refuse a SCOPED session (a roomchief,
// AC_SCOPE set) writing records/backlog.md, records/projects.md or
// records/captain.md.
// The entry is bin/ac-ledger-guard.sh, the fail-open hook shim that starts
// this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-ledger-guard.sh as the oracle the differential leg of
// tests/sh/ac-ledger-guard.test.sh holds this module to.
//
// Wired in .claude/settings.json and .codex/hooks.json under PreToolUse;
// reads the hook payload JSON on stdin and inspects .tool_name / .tool_input
// - the sibling of src/delegation-guard.ts, same shape.
//
// WHY IT EXISTS. AGENTS.md section 8 once stated the roomchief charter in prose
// only ("it never touches the backlog/registry - the crewchief keeps those"):
// nothing mechanically held it. A roomchief with no fleet-wide context can
// renumber an epic rollup or move a line while the crewchief is mid-decision,
// and nothing would detect it - lived 2026-07-21 (gate-via-pane-agent
// roomchief edited records/backlog.md and ran crewchief-owned landing verbs
// itself; only its own self-declared handback caught it). A WARN-only receipt
// was considered and rejected: it needs a baseline-snapshot mechanism that
// does not exist, and a guard running inside the roomchief's own session
// cannot tell a crewchief's legitimate edit from its own - a real refusal
// is cheaper and cannot false-positive that way.
//
// SCOPE: only a session with AC_SCOPE set (a roomchief) is fenced - the
// crewchief itself runs unscoped and owns these files. Matched by PATH SUFFIX
// (a session's cwd may be the fleet home or a path relative to it), never a
// fixed absolute value, since the fleet home path varies per operator.
//
// THE CANONICAL SHAPE. Every test below judges the path lowercased, its
// slash runs squeezed, and every `/./` and a leading `./` dropped: APFS is
// case-insensitive by default (Records/Backlog.md opens the fenced file), and
// a tool path need not be normalized (records//backlog.md,
// records/./backlog.md). The three steps are the original's filters, spawned
// over the path's bytes under the caller's locale - `tr '[:upper:]'
// '[:lower:]'`, `tr -s /`, `sed -e ':a' -e 's#/\./#/#' -e 'ta' -e 's#^\./##'`
// - each one's stderr the hook's, the last one's stdout read as a command
// substitution reads it.
//
// THE CREWDOMAIN DETAIL FILE IS EXEMPT, and the exemption has to be an
// EXPLICIT branch rather than the absence of a matching pattern: in a bash
// `case` - whose globs the tests below keep verbatim - `*` matches `/`, so
// `*/records/projects.md` MATCHES crewdomains/payments/records/projects.md (a
// claim once made false-wise and disproven by RUNNING the patterns). The
// exemption NARROWED with the crewdomain-token refactor: the per-domain
// backlog.md no longer exists, so the domainchief's one remaining records/
// write duty is enriching its projects detail before handback (CREWMATE.md
// sits at the package root, outside every fenced pattern). A package-relative
// backlog path no longer earns an exemption - there is no ledger there for a
// scoped session to own. A `..` ANYWHERE disqualifies the exemption before it
// is considered: `crewdomains/payments/records/../../../records/captain.md`
// matches the allow glob and resolves to the FLEET captain file, so a raw-path
// allow arm would hand a scoped session the very layer it is governed by.
// Refusing to exempt a traversing path is fail-closed - the fence still judges
// it. A `..` hop can land on a ledger from any directory
// (records/scenes/../backlog.md), so a traversing path that ENDS at a
// ledger's name is fenced wherever it starts.
//
// records/captain.md is fenced because the FLEET captain file carries domain
// standing rules - the `STANDING (domain:<name>): ` lines a domainchief reads
// as its LAW. A scoped session that is governed by a layer must not be able to
// edit that layer; it is the same argument this guard makes for the backlog,
// arriving at a file that became load-bearing for scoped sessions.
//
// Fails open: no AC_SCOPE, a non-matching tool, missing jq, an unparseable
// payload, or a path that resolves empty all exit 0 (no bun, and a module
// that cannot load, are the shim's) - a broken guard must never wedge the
// harness. Exit codes: 0 allow, 2 deny; nothing on stdout, the refusal one
// line on stderr. Files: none.
//
// RESIDUAL: this hook covers the `claude` harness's Edit/Write/NotebookEdit
// tools only. A write performed through the Bash tool (sed, echo >, a
// heredoc) still gets through - the same fail-open shape
// src/delegation-guard.ts already accepts, not extended here to close it.
//
// THE READS, the original's: the payload is stdin to its end with NULs
// dropped and trailing LFs stripped (empty allows); the name is jq's
// `-r '.tool_name // empty'` and the path jq's `-r '.tool_input.file_path //
// empty'` (Edit, Write) or `-r '.tool_input.notebook_path // empty'`
// (NotebookEdit), each over the payload plus one LF, spawned, its stdout
// taken whatever jq's status, NULs dropped and trailing LFs stripped.
//
// A BROKEN PORT. The frozen original needs only bash, jq, tr and sed: copying
// tests/fixtures/ac-ledger-guard.sh over bin/ac-ledger-guard.sh in the
// checkout the fleets run (the wiring names that path) restores it whole until
// the fix lands; the captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - THE CASE-FOLD GAP: the canonical shape LOWERCASES while APFS FOLDS case,
//   so a code point whose fold is an ASCII letter opens a fenced ledger
//   unjudged: `record<U+017F>/backlog.md` (LATIN SMALL LETTER LONG S folds to
//   s; tr leaves it, being lowercase) under any locale, and
//   `records/bac<U+212A>log.md` (KELVIN SIGN folds to k) under the C locale,
//   where tr lowercases ASCII only.
// - the path is jq's text: a file_path that is no string is judged by its
//   JSON text, and a payload holding a second value judges the name and path
//   jq printed for both, joined by LF (an `Edit<LF>Edit` name is no tool);
// - sed reads lines: a path holding an LF has each line canonicalized alone.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: with no bun on PATH the shim allows at once, saying nothing, where
//   the original judged; a module that cannot load or crashes allows too.
// - SHELL-OWN STDERR: a filter that cannot start reads as empty on both sides
//   (the path then judges unfenced), and the original's `<name>: command not
//   found` line is not reproduced.
// - TEMP: the original fed jq a here-string, a temp file under $TMPDIR, else
//   /tmp; with neither writable it allowed with bash's own line, where the
//   port pipes jq's stdin and judges.
// - BYTES: AC_SCOPE arrives decoded, so a byte of it that is not UTF-8 prints
//   in the refusal as U+FFFD.
//
// CALLERS: the PreToolUse wiring of .claude/settings.json and
// .codex/hooks.json, each behind its own [ -x ] gate; no script runs it.

import { writeSync } from "node:fs";
import { commandV, enterCaller, hookJq, hookPayload, spawnShellSync } from "./lib.ts";

enterCaller(process.argv.slice(2));
const scope = process.env.AC_SCOPE ?? "";
if (scope === "") process.exit(0);
if (!commandV("jq")) process.exit(0);
const payload = hookPayload();
if (payload === "") process.exit(0);

const tool = hookJq(".tool_name // empty", payload);
if (tool === "" || tool.startsWith("mcp__")) process.exit(0);
const filter = tool === "Edit" || tool === "Write" ? ".tool_input.file_path // empty" : tool === "NotebookEdit" ? ".tool_input.notebook_path // empty" : null;
if (filter === null) process.exit(0);
const path = hookJq(filter, payload);
if (path === "") process.exit(0);

let shaped = Buffer.from(path, "latin1");
for (const argv of [["tr", "[:upper:]", "[:lower:]"], ["tr", "-s", "/"], ["sed", "-e", ":a", "-e", "s#/\\./#/#", "-e", "ta", "-e", "s#^\\./##"]]) {
  try {
    shaped = Buffer.from(spawnShellSync(argv, { stdin: shaped, stdout: "pipe", stderr: "inherit" }).stdout);
  } catch {
    shaped = Buffer.alloc(0);
  }
}
const canon = shaped.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

const literal = (s: string): string => s.replace(/[.\\+?^${}()|[\]]/g, "\\$&");
const glob = (...pats: string[]): RegExp => new RegExp(`^(?:${pats.map((p) => p.split("*").map(literal).join("[\\s\\S]*")).join("|")})$`);
const EXEMPT = glob("crewdomains/*/records/projects.md", "*/crewdomains/*/records/projects.md");
const FENCED = glob(
  "records/backlog.md", "*/records/backlog.md",
  "records/projects.md", "*/records/projects.md",
  "records/captain.md", "*/records/captain.md",
  "*..*/backlog.md", "*..*/projects.md", "*..*/captain.md",
);
if (!canon.includes("..") && EXEMPT.test(canon)) process.exit(0);
if (!FENCED.test(canon)) process.exit(0);

const scopeBytes = Buffer.from(scope, "utf8").toString("latin1");
writeSync(2, Buffer.from(`ac-ledger-guard: ${tool} on ${path} is refused in a scoped session (AC_SCOPE=${scopeBytes}) - the crewchief owns records/backlog.md, records/projects.md and records/captain.md; a scoped chief (roomchief or domainchief) reads them but never edits them. Report the change instead (hand it back to the crewchief, or note it in your report.md) rather than editing the ledger yourself. A crewdomain detail file at crewdomains/<name>/records/projects.md is YOURS to edit and is not fenced.\n`, "latin1"));
process.exit(2);
