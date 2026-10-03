// pr-check.ts - record a crewmate's PR and its head SHA on the task meta: pr=
// (the captain-facing PR link) and pr_head= (the PR's head at record time, the
// head the captain is asked to approve). bin/ac-pr-merge.sh pins its merge to
// pr_head, and bin/ac-teardown.sh's --pr-ready refuses commits past it. The
// entry is bin/ac-pr-check.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-pr-check.sh as the oracle the
// differential leg of tests/sh/ac-pr-check.test.sh holds this module to.
//
//   ac-pr-check.sh <id> <github-pr-url>
//
// Refusals, each `ERROR: <msg>` on stderr, exit 1, nothing written, in order:
//   required tool not found: gh          gh is not on PATH - checked before the
//                                        arguments, so a bare call says this
//   usage: ac-pr-check.sh <id> <pr-url>  either argument missing or empty
//   no crewmate meta for <id>            state/<id>.meta is not a regular file
//                                        (state/ is minted by the look); the id
//                                        is taken as given, so `../t1` names
//                                        <home>/t1.meta
//   not a full GitHub PR URL: <url>      the url misses the shell pattern
//                                        `https://github.com/*/*/pull/[0-9]*`:
//                                        two slash-separated segments (each
//                                        may be empty or hold more slashes),
//                                        then /pull/ and a digit; anything may
//                                        follow; case and scheme are exact
// Homeless (no AC_HOME): the refusal `ERROR: AC_HOME is not set - ...` is
// printed and the meta look goes on at `/<id>.meta`, so stderr carries that
// line AND `no crewmate meta for <id>`, exit 1 - the bash's wart, kept (its
// `$(ac_state_dir)` lost the inner status). An AC_HOME cd cannot enter prints
// `ERROR: AC_HOME is not a readable directory: <h>` in place of the shell's
// own `cd:` line (named divergence), then the same `no crewmate meta`.
//
// Then two gh calls with exactly these arguments, stdout captured, stderr
// passed through, stdin inherited:
//   gh pr view <url> --json headRefOid --jq .headRefOid
//   gh pr view <url> --json state --jq .state
// A failing call ends the run with gh's own exit status (128+signal for a
// signalled gh), nothing written - both calls precede every write. Each
// answer is read as `$(...)` read it: NUL bytes dropped, every trailing LF
// stripped, inner LFs KEPT - so an empty answer records `pr_head=` (which
// ac_meta_get reads as absent) and a two-line answer records two lines, the
// second a bogus meta line (the bash's wart, kept: gh's shape is gh's).
//
// Writes, in order, through the twins of ac_meta_set and ac_status_append
// (src/lib.ts, where each one's bytes and named divergences are stated):
//   state/<id>.meta   every `pr=` line removed and `pr=<url>` appended at the
//                     END, then the same for `pr_head=<head>`; every other
//                     line byte for byte in order (CRLF kept, `prx=` and
//                     `pr_head=` survive the `pr` pass), an unterminated tail
//                     newline-terminated. Two rewrites, each a sibling temp
//                     renamed over the meta. A meta holding a NUL byte keeps
//                     its bytes here where the bash's `grep -v` left `Binary
//                     file <path> matches` plus the new lines (exit 0 both);
//                     one this process cannot read refuses `ERROR: cannot
//                     rewrite <meta>: EACCES` exit 1 where the bash truncated
//                     it to the two new lines, exit 0 - the two named
//                     divergences (W3/W4 in the dossier; the bash helper's
//                     13 remaining callers are a defect slice of their own).
//                     The meta's mode is kept (the bash left 0644).
//   state/<id>.status `<iso> PR ready: <url> (<state>)\n` appended, <iso> from
//                     the PATH's date(1) - a date that fails ends the run with
//                     ITS status, the meta already rewritten, nothing else
//                     written (the bash's errexit on `ts="$(ac_iso)"`); a
//                     failed append refuses `ERROR: cannot append <status>`,
//                     exit 1, before any mirror (errexit on the `>>`).
//   <taskDir>/timeline.log  the same line, fail-soft: created with the dir for
//                     a task whose meta exists, skipped for a `kind=verify-*`
//                     meta or an ambiguous brief layout (taskDir, src/lib.ts);
//                     the dir as `$(ac_task_dir)` captured it, trailing LF
//                     gone, so an id ending in LF mirrors under the LF-less
//                     name while its meta and status keep the LF.
// stdout, exit 0:
//   recorded pr=<url> pr_head=<head> state=<state>
// url, head and state print as their bytes. An argv byte that is not valid
// UTF-8 reaches this module as U+FFFD (bun's argv decoding), so such a url or
// id is checked, passed to gh and recorded as EF BF BD where the bash carried
// the byte - named divergence.
//
// Callers: none in bin/ or src/ run this entry - captains and chiefs run it by
// hand (task-lifecycle skill, docs/getting-started.md); bin/ac-pr-merge.sh and
// bin/ac-teardown.sh only quote its command line in their refusals. A bun-less
// run answers `ERROR: required tool not found: bun`, exit 1, from the shim.
import { statSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { die, enterCaller, metaSet, require, statusAppend, taskMeta, taskStatus } from "./lib.ts";

const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const b = (s: string): Buffer => Buffer.from(s, "latin1");

const { args } = enterCaller(process.argv.slice(2));
require("gh");
const id = args[0] ?? "";
const url = args[1] ?? "";
if (!id || !url) die("usage: ac-pr-check.sh <id> <pr-url>");
const meta = taskMeta(id);
let isFile = false;
try {
  isFile = statSync(meta).isFile();
} catch {}
if (!isFile) die(b(`no crewmate meta for ${bytes(id)}`));
if (!/^https:\/\/github\.com\/[\s\S]*\/[\s\S]*\/pull\/[0-9]/.test(url)) die(b(`not a full GitHub PR URL: ${bytes(url)}`));

function gh(...a: string[]): string {
  const r = Bun.spawnSync(["gh", ...a], { stdin: "inherit", stdout: "pipe", stderr: "inherit", env: process.env });
  if (r.exitCode !== 0) {
    const sig = r.signalCode ? (osConstants.signals as Record<string, number>)[r.signalCode] ?? 0 : 0;
    process.exit(r.exitCode ?? 128 + sig);
  }
  return r.stdout.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
}

const head = gh("pr", "view", url, "--json", "headRefOid", "--jq", ".headRefOid");
const state = gh("pr", "view", url, "--json", "state", "--jq", ".state");
try {
  metaSet(meta, "pr", bytes(url));
  metaSet(meta, "pr_head", head);
} catch (e) {
  const err = e as { code?: string; status?: number };
  if (err.code === "EMV") process.exit(err.status ?? 1);
  die(b(`cannot rewrite ${bytes(meta)}: ${err.code ?? "error"}`));
}
let appended = false;
try {
  appended = statusAppend(id, `PR ready: ${bytes(url)} (${state})`, true);
} catch (e) {
  const err = e as { code?: string; status?: number };
  if (err.code === "EDATE") process.exit(err.status ?? 1);
  throw e;
}
if (!appended) die(b(`cannot append ${bytes(taskStatus(id))}`));
writeSync(1, b(`recorded pr=${bytes(url)} pr_head=${head} state=${state}\n`));
