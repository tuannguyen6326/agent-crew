// promote.ts - promote a scout task to a ship task IN PLACE: kind=scout flips
// to kind=ship and mode= is set from --mode, after which bin/ac-teardown.sh's
// FULL ship protection applies (landed proof for crew/<id> plus a clean
// worktree, not only a report.md). The entry is bin/ac-promote.sh (a shim that
// starts this file through bin/ac-bun.sh); THIS header is the authoritative
// spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-promote.sh as the oracle the differential leg of
// tests/sh/ac-promote.test.sh holds this module to.
//
//   ac-promote.sh <id> --mode <crew-ship|direct-pr|local-only>
//                      [--captain-requested '<ref>' --reason '<one line>']
//
// A scout steered mid-flight into writing code on crew/<id> stops being a
// report-only task. Mode is per-task (captain order 2026-08-10) and the
// registry default is gone, so --mode is REQUIRED: a promotion is exactly the
// moment the task GAINS a delivery mode. Promoting into crew-ship is a
// time-expensive choice: it needs the captain's word, declared with
// --captain-requested '<the captain's words, or the order ref>', and the
// chief's --reason rides the record with it (a mid-flight promotion has no
// backlog row to pin). feature-pr is NOT a mode here, though briefs and
// contractLint take it.
//
// Arguments: <id> is $1 and must be non-empty (a flag in its place IS the id,
// so `--mode local-only s1` fails on `unknown argument: local-only`). The
// flags follow in any order, repeatable, the last value winning; each takes
// the next token as its value, and a missing or empty one refuses. Every
// argument error precedes the meta read.
//
// Refusals, each `ERROR: <msg>` on stderr, exit 1, nothing written, in order:
//   usage: ac-promote.sh <id> --mode <crew-ship|direct-pr|local-only> [--captain-requested '<ref>']
//                                        no id or an empty one
//   missing value for --mode|--captain-requested|--reason
//                                        the flag is the last token, or its
//                                        value is empty
//   unknown argument: <tok>              any other token
//   no crewmate meta for <id>            state/<id>.meta is not a regular file
//                                        (state/ minted by the look; the id is
//                                        taken as given, so `../t1` names
//                                        <home>/t1.meta)
//   task <id> is kind=<kind|unset>, not scout (only scouts promote)
//                                        the meta's LAST kind= line is not the
//                                        bytes `scout` (`scout\r` and `Scout`
//                                        are not; `scout<NUL>` IS - awk handed
//                                        the shell a C string, cut at the NUL);
//                                        no kind= reads `unset`
//   mode unspecified for promoting '<id>': pass --mode <crew-ship|direct-pr|local-only>. Mode is per-task now - the registry default is gone
//   invalid --mode: <v> (want crew-ship|direct-pr|local-only)
//   promoting '<id>' into crew-ship is a time-expensive choice: ... Nothing promoted
//                                        crew-ship without --captain-requested
//   promoting '<id>' into crew-ship carries the captain's word but no --reason ...: the reason must ride the record. Nothing promoted
//   --reason has nothing to justify here: promoting into <mode> is the cheap path. Drop the flag
//   --captain-requested has nothing to authorize here: promoting into <mode> is the cheap path. Drop the flag - declaring authority that was never needed muddies the record
//                                        (the --reason refusal precedes this
//                                        one when both idle flags are given)
// A meta that is there but cannot be read ends the run with the helper's
// `WARN: cannot read meta file <meta>` alone, exit 1 - the bash's unguarded
// `kind="$(ac_meta_get ...)"` fired errexit with no ERROR line of its own.
// Homeless (no AC_HOME): the refusal `ERROR: AC_HOME is not set - ...` is
// printed and the meta look goes on at `/<id>.meta`, so stderr carries that
// line AND `no crewmate meta for <id>`, exit 1 - the bash's wart, kept (its
// `$(ac_state_dir)` lost the inner status). An AC_HOME cd cannot enter prints
// `ERROR: AC_HOME is not a readable directory: <h>` in place of the shell's
// own `cd:` line (named divergence), then the same `no crewmate meta`.
//
// Writes, in this order, through the twins of ac_meta_set, ac_status_append
// and ac_delivery_mode_block (src/lib.ts, where each one's bytes and named
// divergences are stated):
//   state/<id>.meta   every `kind=` line removed and `kind=ship` appended at
//                     the END, then the same for `mode=<mode>` (a `mode=-`
//                     placeholder goes with the rest); every other line byte
//                     for byte in order, an unterminated tail
//                     newline-terminated. Two rewrites, each a sibling temp
//                     renamed over the meta - created EXCLUSIVELY where the
//                     bash wrote through a planted `<meta>.tmp.<pid>`; a meta
//                     holding a NUL byte keeps its bytes here where the bash's
//                     `grep -v` left `Binary file <path> matches` plus the new
//                     lines (exit 0 both) - the named divergences, pinned in
//                     the leg; the mode is kept where the bash left 0644.
//   state/<id>.status `<iso> promoted: scout -> ship (mode=<mode>)[ captain-requested: <ref>][ reason: <reason>]\n`
//                     appended, <iso> from the PATH's date(1) (a date that
//                     fails ends the run with ITS status, the meta already
//                     rewritten - the bash's errexit on `ts="$(ac_iso)"`); a
//                     failed append refuses `ERROR: cannot append <status>`,
//                     exit 1, before any mirror. A ref of only spaces is
//                     non-empty and rides.
//   <taskDir>/timeline.log  the same line, fail-soft (taskDir, src/lib.ts):
//                     for a staged id it lands in the NESTED stage dir
//                     (data/fam/spec/) while the instructions below land in
//                     the FLAT data/<id>/ - the bash's wart (W2), kept.
//   stdout line 1     promoted <id>: kind scout -> ship, mode=<mode> (ship teardown protection now applies)
//   data/<id>/ship-instructions.md  `mkdir -p data/<id>` spawned (its failure
//                     ends the run with mkdir's status and stderr), then the
//                     contract written whole, overwriting an old one:
//                       # Ship contract: <id> (promoted from scout)
//                       <blank>
//                       This task now delivers a PROJECT CHANGE on `crew/<id>`; a report alone no
//                       longer lands it. Start the ship branch from a clean base carrying only the
//                       intended changes - scout scratch commits and debug edits never ride along.
//                       <blank>
//                       <deliveryModeBlock(mode, "crew/<id>", "the recorded target branch", "the recorded integration branch", "delivery preparation")>
//                       <blank>
//                       Escalate ask-user findings and needs-decision questions through your status
//                       line as before; the chief relays them to the captain.
//                     A write that fails refuses `ERROR: cannot write <path>: <code>`, exit 1,
//                     in place of the shell's own redirection line.
//   the pane notice   <distro root>/bin/ac-send.sh <id> '<notice>' is SPAWNED
//                     (it stays bash) with stdout and stderr discarded, where
//                     the notice is
//                       NOTICE: this task was promoted to SHIP - deliver the project change on crew/<id>; delivery per mode=<mode>. Read your full contract: <abs path of ship-instructions.md>. A report alone no longer lands it.
//                     Exit 0 prints stdout line 2 `notified crewmate <id> of
//                     the ship contract`; ANY other outcome - a gone window, a
//                     blocked pane, an unverified submit, a solo session's
//                     refusal (AC_SOLO=1), an ac-send.sh that cannot start -
//                     prints `crewmate window not reachable; promotion
//                     recorded in meta only`. Exit 0 either way: a gone
//                     window is not an error, the promotion stands. The one
//                     line hides which failure it was (W3) - the bash's `if
//                     cmd; then` kept only the boolean, and so does this.
// id, mode, ref and reason print and record as their bytes. An argv byte that
// is not valid UTF-8 reaches this module as U+FFFD (bun's argv decoding), so
// such a reason is recorded as EF BF BD where the bash carried the byte -
// named divergence. An id carrying `$` or a back-tick is interpolated
// literally on both sides (the bash quoted its heredoc's expansions).
//
// Callers: none in bin/, src/, dashboard/ or .agents/ run this entry -
// chiefs run it by hand on bin/ac-teardown.sh's remedy text (`promote it
// (ac-promote.sh <id>)`), and tests/sh/ac-spawn-teardown.test.sh runs it. No
// `set -e` caller to audit. A bun-less run answers `ERROR: required tool not
// found: bun`, exit 1, from the shim.
import { statSync, writeFileSync, writeSync } from "node:fs";
import { resolve } from "node:path";
import { dataDir, deliveryModeBlock, die, enterCaller, metaGet, metaSet, statusAppend, taskMeta, taskStatus } from "./lib.ts";

const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const b = (s: string): Buffer => Buffer.from(s, "latin1");

const { args } = enterCaller(process.argv.slice(2));
const id = args[0] ?? "";
if (!id) die("usage: ac-promote.sh <id> --mode <crew-ship|direct-pr|local-only> [--captain-requested '<ref>']");

let modeFlag = "";
let captainRef = "";
let reason = "";
for (let i = 1; i < args.length; i += 2) {
  const flag = args[i]!;
  const value = args[i + 1] ?? "";
  if (flag !== "--mode" && flag !== "--captain-requested" && flag !== "--reason") die(b(`unknown argument: ${bytes(flag)}`));
  if (!value) die(`missing value for ${flag}`);
  if (flag === "--mode") modeFlag = value;
  else if (flag === "--captain-requested") captainRef = value;
  else reason = value;
}

const meta = taskMeta(id);
let isFile = false;
try {
  isFile = statSync(meta).isFile();
} catch {}
if (!isFile) die(b(`no crewmate meta for ${bytes(id)}`));

let kind: string;
try {
  // awk's C string: the value ends at its first NUL, as the shell received it.
  kind = metaGet(meta, "kind").replace(/\0[\s\S]*$/, "");
} catch {
  process.exit(1);
}
if (kind !== "scout") die(b(`task ${bytes(id)} is kind=${kind || "unset"}, not scout (only scouts promote)`));

if (!modeFlag) die(b(`mode unspecified for promoting '${bytes(id)}': pass --mode <crew-ship|direct-pr|local-only>. Mode is per-task now - the registry default is gone`));
if (!["crew-ship", "direct-pr", "local-only"].includes(modeFlag)) die(b(`invalid --mode: ${bytes(modeFlag)} (want crew-ship|direct-pr|local-only)`));
const mode = modeFlag;
if (mode === "crew-ship" && !captainRef) {
  die(b(`promoting '${bytes(id)}' into crew-ship is a time-expensive choice: it needs the captain's confirmation, with your REASON stated in the ask - then declare it with --captain-requested '<the captain's words, or the order ref>' --reason '<the justification you gave>'. Nothing promoted`));
}
if (mode === "crew-ship" && !reason) {
  die(b(`promoting '${bytes(id)}' into crew-ship carries the captain's word but no --reason '<the justification you gave the captain>': the reason must ride the record. Nothing promoted`));
}
if (reason && mode !== "crew-ship") die(`--reason has nothing to justify here: promoting into ${mode} is the cheap path. Drop the flag`);
if (captainRef && mode !== "crew-ship") die(`--captain-requested has nothing to authorize here: promoting into ${mode} is the cheap path. Drop the flag - declaring authority that was never needed muddies the record`);

try {
  metaSet(meta, "kind", "ship");
  metaSet(meta, "mode", mode);
} catch (e) {
  const err = e as { code?: string; status?: number };
  if (err.code === "EMV") process.exit(err.status ?? 1);
  die(b(`cannot rewrite ${bytes(meta)}: ${err.code ?? "error"}`));
}
const suffix = (captainRef ? ` captain-requested: ${bytes(captainRef)}` : "") + (reason ? ` reason: ${bytes(reason)}` : "");
let appended = false;
try {
  appended = statusAppend(id, `promoted: scout -> ship (mode=${mode})${suffix}`, true);
} catch (e) {
  const err = e as { code?: string; status?: number };
  if (err.code === "EDATE") process.exit(err.status ?? 1);
  throw e;
}
if (!appended) die(b(`cannot append ${bytes(taskStatus(id))}`));
writeSync(1, b(`promoted ${bytes(id)}: kind scout -> ship, mode=${mode} (ship teardown protection now applies)\n`));

const instructions = `${dataDir()}/${id}/ship-instructions.md`;
const made = Bun.spawnSync(["mkdir", "-p", `${dataDir()}/${id}`], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
if (made.exitCode !== 0) process.exit(made.exitCode ?? 1);
const contract = `# Ship contract: ${id} (promoted from scout)

This task now delivers a PROJECT CHANGE on \`crew/${id}\`; a report alone no
longer lands it. Start the ship branch from a clean base carrying only the
intended changes - scout scratch commits and debug edits never ride along.

${deliveryModeBlock(mode, `crew/${id}`, "the recorded target branch", "the recorded integration branch", "delivery preparation")}

Escalate ask-user findings and needs-decision questions through your status
line as before; the chief relays them to the captain.
`;
try {
  writeFileSync(instructions, contract);
} catch (e) {
  die(b(`cannot write ${bytes(instructions)}: ${(e as { code?: string }).code ?? "error"}`));
}

const notice = `NOTICE: this task was promoted to SHIP - deliver the project change on crew/${id}; delivery per mode=${mode}. Read your full contract: ${instructions}. A report alone no longer lands it.`;
let sent = false;
try {
  sent = Bun.spawnSync([resolve(import.meta.dir, "..", "bin", "ac-send.sh"), id, notice], { stdin: "inherit", stdout: "ignore", stderr: "ignore", env: process.env }).exitCode === 0;
} catch {}
writeSync(1, sent ? b(`notified crewmate ${bytes(id)} of the ship contract\n`) : Buffer.from("crewmate window not reachable; promotion recorded in meta only\n"));
