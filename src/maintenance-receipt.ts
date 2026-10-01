// maintenance-receipt.ts - the parsing half of the maintenance authorization
// boundary Learning and Curate share: the receipt check and the read-evidence
// check. bin/ac-maintenance-lib.sh starts it through bin/ac-bun.sh, always
// inside a subshell because ac_bun_exec execs, behind the unchanged bash names
// ac_maintenance_evidence_value, ac_maintenance_read_evidence and
// ac_maintenance_receipt_validate; THIS header is the authoritative spec. The
// lib's READ-EVIDENCE block owns the rationale, and its one copy of
// AC_MAINTENANCE_QUOTE_MIN (bin/ac-gate.sh prints it into the judge prompt)
// arrives here as <quote-min>.
//
// Usage (the caller's cwd arrives first, from ac_bun_exec):
//   evidence-value <label>                               stdin = a receipt
//       Prints the value of the one `- <label>: <value>` line inside
//       `## Inputs Read`, trimmed of [[:space:]] at both ends, with no
//       newline; exit 1, nothing printed, unless exactly one such line exists.
//   read-evidence <manifest> <plan.json> <quote-min>     stdin = a receipt
//       Exit 0 when `## Inputs Read` proves the judge opened the manifest, the
//       plan and the bytes the cited action writes (READ-EVIDENCE below), else
//       1. Stdin may also be the raw judge body before it becomes a receipt.
//   receipt-check <receipt.md> <plan.json> <manifest> <quote-min>
//       Prints the receipt's decision and a newline when it passes every rule
//       under RECEIPT-CHECK, else exit 1 with nothing printed. The caller has
//       already proved the receipt and the manifest plain files and passed the
//       plan through ac_maintenance_plan_validate, which stays bash.
// A usage error, and a relative path when the caller's cwd has no name, exit 1
// with an ERROR line on stderr - a refusal, never a pass.
//
// `## Inputs Read` opens at a line that is that heading plus any trailing
// [[:space:]], closes at the next line starting `## `, and a second heading
// reopens it.
//
// READ-EVIDENCE - three proofs, each checked against the files themselves:
//   - ACTION PLAN NEW SHA-256, with every backtick deleted: one of the plan's
//     .actions[].new_sha256, and neither the manifest's nor the plan's own
//     SHA-256 - the two values the prompt printed.
//   - STAGED PAYLOAD QUOTE: the value, or the value less one wrapping pair of
//     backticks, occurs in the staged file of the FIRST action carrying the
//     cited hash and scores at least that file's bearable floor: <quote-min>,
//     or the file's best line score when that is less. A floor of 0 needs no
//     quote line, but only when every action's staged file scores 0 too.
//   - INPUT MANIFEST QUOTE: the value, or the value unwrapped the same way,
//     occurs in the manifest and scores at least <quote-min>.
// A score is the largest number of bytes one line keeps once the plan's run
// id, then its subject, then its mode are deleted - every non-overlapping
// occurrence, left to right - and every [[:punct:]] and [[:space:]] byte is
// dropped. A staged path is <run>/<staged>, where <run> is the plan's
// directory resolved physically, or that directory's parent when it is named
// `plans`; a symlink or anything but a regular file fails.
//
// RECEIPT-CHECK, all of:
//   - Frontmatter: line 1 is `---`, and every line up to the closing `---`
//     matches ^[A-Za-z0-9_]+: ".*"$ with a key from schema, mode, subject,
//     decision, authority, engine, model, input_manifest_sha256,
//     action_plan_sha256, reviewed_at - each exactly once. A value is the text
//     between the first and the last double quote.
//   - schema is agentcrew.maintenance-gate/v1. decision is continue, revise or
//     ask-captain - never environment-error, the judge's declaration that it
//     could not judge. mode and subject equal the plan's. The manifest's
//     SHA-256 equals both the plan's input_manifest_sha256 and the receipt's,
//     and the plan's own SHA-256 equals action_plan_sha256.
//   - `## Grounds` and `## Proposed Process`, each a heading plus any trailing
//     [[:space:]], each hold a line with a byte outside [[:space:]] before the
//     next line starting `## `.
//   - authority repository-policy is the one exemption from READ-EVIDENCE (the
//     lib's header names its minters); any other value, recognised or not,
//     owes it over the receipt's own bytes.
//
// BYTE-EXACT C: save the divergences listed below, this is
// what the bash did under LC_ALL=C with onetrue awk, sed and grep -F. Files and
// stdin are read as latin1, so a byte is one character, <label> is matched as
// the bytes it arrived as, and output is written back the same way.
// [[:space:]] is space, tab, LF, VT, FF and CR, [[:punct:]] is ASCII
// punctuation, and no byte past 0x7f is either. A line is what awk reads:
// split at LF, the empty element after a final LF dropped, CR kept, and a NUL
// ends it. A quote occurs in a file when it is a byte substring of it - grep
// -F, since a value holds no LF. Read-evidence's stdin, and the receipt it is
// run over, first lose every NUL and trailing LF, as the shell's $(cat) did.
// A plan field reads as $(jq -r ...) did: the string's UTF-8 bytes less NULs
// and trailing LFs, because the jq regexes of ac_maintenance_plan_validate let
// one trailing LF through. The plan is parsed as JSON after one leading UTF-8
// BOM is dropped, which jq accepts too.
//
// Deliberate divergences; only the last is reachable from a caller in this
// repository:
//   - A plan field that is not a string fails, where jq printed its JSON;
//     both callers validate the plan first.
//   - <label> is taken literally, where awk -v read backslash escapes in it;
//     every caller passes a constant holding none.
//   - <run> comes from realpath, which on a case-insensitive volume spells a
//     component as the disk does, where bash's `pwd -P` kept the caller's
//     spelling - so the `plans` test differs for a plan whose directory is
//     spelled in another case than on disk. Learning and Curate both write
//     `$run/plans/` and pass it back spelled the same way.
//   - A relative plan path resolves from the caller's physical cwd, where
//     bash's `cd` walked a `..` up the logical one, so under a symlinked cwd
//     the payload came from the logical parent while the manifest and the
//     plan came from the physical one. Every caller passes an absolute path.
//   - Bun decodes argv as UTF-8 with replacement, so an argument carrying
//     U+FFFD is refused rather than naming a different file (src/paths.ts).
//   - A quote longer than 65536 bytes is a byte substring like any other.
//     BSD grep -F failed on such a pattern ("out of memory", exit 2, and near
//     1 MiB its argv was too long), so the bash refused it even when it
//     occurred verbatim - the honest-reader refusal the lib's READ-EVIDENCE
//     block rules out. Only a judge quoting more than 64 KiB reaches this,
//     through bin/ac-gate.sh or the receipt boundary.

import { lstatSync, readFileSync, realpathSync, writeSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import { die, enterCaller, sha256File } from "./lib.ts";

const SPACE = "[ \\t\\n\\v\\f\\r]";
const TRIM = new RegExp(`^${SPACE}+|${SPACE}+$`, "g");
const INSIGNIFICANT = /[!-/:-@[-`{-~ \t\n\v\f\r]/g;
const INPUTS_READ = new RegExp(`^## Inputs Read${SPACE}*$`);
const GROUNDS = new RegExp(`^## Grounds${SPACE}*$`);
const PROCESS = new RegExp(`^## Proposed Process${SPACE}*$`);
const CONTENT = new RegExp(`[^ \\t\\n\\v\\f\\r]`);
const FRONT_LINE = /^([A-Za-z0-9_]+): "(.*)"$/s;
const FRONT_KEYS = ["schema", "mode", "subject", "decision", "authority", "engine", "model",
  "input_manifest_sha256", "action_plan_sha256", "reviewed_at"];

function lines(text: string): string[] {
  const r = text.split("\n");
  if (r[r.length - 1] === "") r.pop();
  return r.map((l) => l.split("\0", 1)[0]);
}

const readLatin1 = (path: string) => readFileSync(path).toString("latin1");
const shellBody = (text: string) => `${text.replace(/\0/g, "").replace(/\n+$/, "")}\n`;
const unfence = (v: string) => (v.length >= 2 && v.startsWith("`") && v.endsWith("`") ? v.slice(1, -1) : v);

function jqRaw(v: unknown): string | null {
  if (typeof v !== "string") return null;
  return Buffer.from(v, "utf8").toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
}

type Plan = { mode?: unknown; subject?: unknown; run_id?: unknown; input_manifest_sha256?: unknown;
  actions?: { new_sha256?: unknown; staged?: unknown }[] };

function readPlan(path: string): Plan | null {
  try {
    const doc = JSON.parse(new TextDecoder().decode(readFileSync(path)));
    return doc && typeof doc === "object" && Array.isArray(doc.actions) ? doc : null;
  } catch {
    return null;
  }
}

// cd's ladder, as envHome in src/lib.ts climbs it: the logical spelling, then
// the physical one.
function cdPwdP(dir: string): string | null {
  for (const d of [resolve(dir), dir]) {
    try {
      return realpathSync(d);
    } catch {}
  }
  return null;
}

function runDir(plan: string): string | null {
  const run = cdPwdP(dirname(plan));
  return run !== null && basename(run) === "plans" ? dirname(run) : run;
}

function plainFile(path: string): boolean {
  try {
    return lstatSync(path).isFile();
  } catch {
    return false;
  }
}

export function evidenceValue(text: string, label: string): string | null {
  const want = `- ${label}: `;
  let open = false;
  let n = 0;
  let value = "";
  for (const line of lines(text)) {
    if (INPUTS_READ.test(line)) {
      open = true;
      continue;
    }
    if (open && line.startsWith("## ")) open = false;
    if (open && line.startsWith(want)) {
      value = line.slice(want.length);
      n++;
    }
  }
  return n === 1 ? value.replace(TRIM, "") : null;
}

export function significance(text: string, runId: string, subject: string, mode: string): number {
  const del = (s: string, t: string) => (t === "" ? s : s.split(t).join(""));
  let max = 0;
  for (const line of lines(text)) {
    const kept = del(del(del(line, runId), subject), mode).replace(INSIGNIFICANT, "").length;
    if (kept > max) max = kept;
  }
  return max;
}

export function readEvidence(manifest: string, planPath: string, input: string, quoteMin: number): boolean {
  let manifestBytes: string;
  let inputSha: string;
  let planSha: string;
  try {
    manifestBytes = readLatin1(manifest);
    inputSha = sha256File(manifest);
    planSha = sha256File(planPath);
  } catch {
    return false;
  }
  const plan = readPlan(planPath);
  if (plan === null) return false;
  const actions = plan.actions ?? [];
  const [mode, subject, runId] = [jqRaw(plan.mode), jqRaw(plan.subject), jqRaw(plan.run_id)];
  if (mode === null || subject === null || runId === null) return false;
  const score = (text: string) => significance(text, runId, subject, mode);

  const body = shellBody(input);
  const cited = evidenceValue(body, "ACTION PLAN NEW SHA-256")?.replace(/`/g, "");
  if (cited === undefined || cited === inputSha || cited === planSha) return false;
  const action = actions.find((a) => typeof a.new_sha256 === "string"
    && Buffer.from(a.new_sha256, "utf8").toString("latin1") === cited);
  if (action === undefined) return false;

  const run = runDir(planPath);
  const stagedRel = jqRaw(action.staged);
  if (run === null || stagedRel === null) return false;
  const stagedBytes = (rel: string): string | null => {
    const path = `${run}/${rel}`;
    if (!plainFile(path)) return null;
    try {
      return readLatin1(path);
    } catch {
      return null;
    }
  };
  const staged = stagedBytes(stagedRel);
  if (staged === null) return false;
  const floor = Math.min(score(staged), quoteMin);
  if (floor <= 0) {
    for (const a of actions) {
      const rel = jqRaw(a.staged);
      if (rel === null) return false;
      if (rel === "") continue;
      const other = stagedBytes(rel);
      if (other === null || Math.min(score(other), quoteMin) > 0) return false;
    }
  } else {
    const payload = evidenceValue(body, "STAGED PAYLOAD QUOTE");
    if (payload === null) return false;
    if (![payload, unfence(payload)].some((f) => f !== "" && staged.includes(f) && score(f) >= floor)) return false;
  }

  const quote = evidenceValue(body, "INPUT MANIFEST QUOTE");
  if (quote === null) return false;
  return [quote, unfence(quote)].some((f) => f !== "" && manifestBytes.includes(f) && score(f) >= quoteMin);
}

export function frontmatter(receipt: string[]): Map<string, string> | null {
  if (receipt[0] !== "---") return null;
  const fields = new Map<string, string>();
  for (const line of receipt.slice(1)) {
    if (line === "---") return fields.size === FRONT_KEYS.length ? fields : null;
    const m = FRONT_LINE.exec(line);
    if (m === null || !FRONT_KEYS.includes(m[1]) || fields.has(m[1])) return null;
    fields.set(m[1], m[2]);
  }
  return null;
}

export function receiptCheck(receiptPath: string, planPath: string, manifest: string, quoteMin: number): string | null {
  let receipt: string;
  let inputSha: string;
  let planSha: string;
  try {
    receipt = readLatin1(receiptPath);
    inputSha = sha256File(manifest);
    planSha = sha256File(planPath);
  } catch {
    return null;
  }
  const plan = readPlan(planPath);
  const receiptLines = lines(receipt);
  const f = frontmatter(receiptLines);
  if (plan === null || f === null) return null;
  const decision = f.get("decision") as string;
  if (f.get("schema") !== "agentcrew.maintenance-gate/v1") return null;
  // environment-error must never join this set: a judge declaring it could not
  // judge authorizes nothing. bin/ac-gate.sh refuses to write one; this is the
  // second layer, which trusts nothing any gate wrote.
  if (!["continue", "revise", "ask-captain"].includes(decision)) return null;
  if (f.get("mode") !== jqRaw(plan.mode) || f.get("subject") !== jqRaw(plan.subject)) return null;
  if (inputSha !== jqRaw(plan.input_manifest_sha256) || inputSha !== f.get("input_manifest_sha256")) return null;
  if (planSha !== f.get("action_plan_sha256")) return null;

  let section = "";
  const held = new Set<string>();
  for (const line of receiptLines) {
    if (GROUNDS.test(line)) section = "grounds";
    else if (PROCESS.test(line)) section = "process";
    else if (line.startsWith("## ")) section = "";
    else if (section !== "" && CONTENT.test(line)) held.add(section);
  }
  if (held.size !== 2) return null;

  if (f.get("authority") !== "repository-policy" && !readEvidence(manifest, planPath, receipt, quoteMin))
    return null;
  return decision;
}

function out(text: string): void {
  const buf = Buffer.from(text, "latin1");
  for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
}

function stdin(): string {
  try {
    return readFileSync(0).toString("latin1");
  } catch {
    return "";
  }
}

const USAGE = "usage: maintenance-receipt.ts evidence-value <label> | read-evidence <manifest> <plan.json> <quote-min> | receipt-check <receipt.md> <plan.json> <manifest> <quote-min>";

function main(args: string[], atCaller: boolean): number {
  const [verb, ...a] = args;
  const quoteMin = (s: string | undefined) => (s !== undefined && /^[0-9]+$/.test(s) ? Number(s) : die(USAGE));
  const paths = (p: string[]) => {
    if (!atCaller && p.some((x) => !isAbsolute(x))) die("the current directory cannot be resolved, so a relative path cannot be either");
  };
  if (a.some((x) => x.includes("\ufffd"))) return 1;
  if (verb === "evidence-value" && a.length === 1) {
    const v = evidenceValue(stdin(), Buffer.from(a[0], "utf8").toString("latin1"));
    if (v === null) return 1;
    out(v);
    return 0;
  }
  if (verb === "read-evidence" && a.length === 3) {
    const q = quoteMin(a[2]);
    paths(a.slice(0, 2));
    return readEvidence(a[0], a[1], stdin(), q) ? 0 : 1;
  }
  if (verb === "receipt-check" && a.length === 4) {
    const q = quoteMin(a[3]);
    paths(a.slice(0, 3));
    const decision = receiptCheck(a[0], a[1], a[2], q);
    if (decision === null) return 1;
    out(`${decision}\n`);
    return 0;
  }
  die(USAGE);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  process.exit(main(args, atCaller));
}
