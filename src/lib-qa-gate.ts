// lib-qa-gate.ts - the qa-gate twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { records } from "./backlog.ts";
import { existsSync, readFileSync, readdirSync, statSync, writeSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import {
  capturedText,
  die,
  familyOfId,
  isFile,
  lat,
  latBuf,
  projectConfigName,
  qaConfigFile,
  repoRoot,
  shellPrefix,
  softSubdir,
  spawnShellSync,
  tabFields,
  warn,
} from "./lib.ts";

const QA_SEGMENT = /^[A-Za-z0-9_-]+$/;

// ac_qa_required's twin: is the gate ENFORCED for <repo>? A policy that
// cannot be read writes its refusal and throws status 1, as the RETIRED copy
// does: a `git --version` that does not start or fails (no repo resolves to a
// policy), then a <repo>/.git that exists (`[ -e ]`) where git cannot name
// the repo, then a canonical yaml that is a regular file and cannot be read.
// The config is resolved loud, then quiet, and read as `$(cat)` read it. Then
// the grammar over that text and one LF, in the C locale: a column-0 `qa:`
// with optional space and an optional `#` comment or a flow mapping's `{`
// opens the block, a later column-0 line that is no comment closes it. A key
// is `require_for_ship`, bare or quoted with `"` or `'`, optional space, a
// colon, looked for in each block line's whole text (the flow header's too,
// a comment's too): at the line's start past its indent (the value runs to
// the line's end), or past a `{` or `,` and optional space (the value ends at
// the next `,` or `}`). ANY key whose value - a comment (`#` after a space)
// cut, `"` and `'` deleted, its ends trimmed - is no false spelling enforces;
// no key is not enforced.
export function qaRequired(repo: string): boolean {
  let gitRuns = false;
  try {
    gitRuns = spawnShellSync(["git", "--version"], { stdin: "inherit", stdout: "ignore", stderr: "ignore" }).exitCode === 0;
  } catch {}
  if (!gitRuns) {
    writeSync(2, `ERROR: qa.require_for_ship: git did not run (is it on PATH?), so the project policy for '${repo}' cannot be resolved - refusing the merge rather than reading it as not enforced\n`);
    throw Object.assign(new Error("git did not run"), { status: 1 });
  }
  if (existsSync(`${repo}/.git`) && projectConfigName(repo) === null) {
    writeSync(
      2,
      `ERROR: qa.require_for_ship: git could not read the repo at '${repo}' (it holds .git, but git rev-parse failed there - a corrupt repo, or one safe.directory refuses), so its project policy cannot be resolved - refusing the merge rather than reading it as not enforced\n`,
    );
    throw Object.assign(new Error("git could not read the repo"), { status: 1 });
  }
  qaConfigFile(repo, true);
  const cfg = qaConfigFile(repo, false);
  let text = "";
  if (cfg !== null) {
    try {
      text = capturedText(readFileSync(latBuf(cfg)));
    } catch {
      writeSync(2, latBuf(`ERROR: qa.require_for_ship: the project policy ${cfg} cannot be read - refusing the merge rather than reading it as not enforced\n`));
      throw Object.assign(new Error(`unreadable project policy ${cfg}`), { status: 1 });
    }
  }
  const on = (v: string): boolean =>
    !/^(false|False|FALSE|no|No|NO|off|Off|OFF)$/.test(
      v
        .replace(/[ \t\n\v\f\r]#[\s\S]*/, "")
        .replace(/["']/g, "")
        .replace(/^[ \t\n\v\f\r]+/, "")
        .replace(/[ \t\n\v\f\r]+$/, ""),
    );
  let inq = false;
  for (let l of records(`${text}\n`)) {
    if (/^qa:[ \t\n\v\f\r]*(#[\s\S]*)?$/.test(l)) {
      inq = true;
      continue;
    }
    if (/^[^ \t\n\v\f\r#]/.test(l)) inq = /^qa:[ \t\n\v\f\r]*\{/.test(l);
    if (!inq) continue;
    const block = /^[ \t\n\v\f\r]+(?:require_for_ship|"require_for_ship"|'require_for_ship')[ \t\n\v\f\r]*:/.exec(l);
    if (block && on(l.slice(block[0].length))) return true;
    for (let m; (m = /[{,][ \t\n\v\f\r]*(?:require_for_ship|"require_for_ship"|'require_for_ship')[ \t\n\v\f\r]*:/.exec(l)); ) {
      l = l.slice(m.index + m[0].length);
      if (on(l.replace(/[,}][\s\S]*/, ""))) return true;
    }
  }
  return false;
}

// ac_knowledge_scopes' twin: its stdout and stderr bytes (latin1) and its
// status. 0 with the live map's `<scope>\t<app>,<app>` rows, or with none (no
// repo name, no record, no live `- scope` line); 2 for AMBIGUOUS - a malformed
// live `- scope` line, or each repeat of a name after its first line (that
// first line reprinted every time) - with the AMBIGUOUS header and those lines
// on stderr and no row, or for a record it cannot read (awk's own `can't open`
// lines are not reproduced). records/ is minted once the name resolves
// (ac_knowledge_file's `$(ac_records_dir)`). The scan stops at `## Superseded`;
// ` | src: ` cuts the rest of a line, a CR included as awk's `.` takes one.
// The record is read as BYTES, in the C locale the gate's call sets: under a
// UTF-8 caller locale (the bash ac-qa.sh's calls) its awk aborts on a byte that
// is no UTF-8 (towc, exit 2) - named, the "read bytes" precedent.
export function knowledgeScopes(repo: string): { status: 0 | 2; out: string; err: string } {
  const none = { status: 0 as const, out: "", err: "" };
  const name = projectConfigName(repo);
  if (name === null) return none;
  const rec = latBuf(`${lat(softSubdir("records", false))}/repo-knowledge/${lat(name)}.md`);
  if (!isFile(rec)) return none;
  let text: string;
  try {
    text = readFileSync(rec, "latin1");
  } catch {
    return { status: 2, out: "", err: "" };
  }
  const first = new Map<string, string>();
  const bad: string[] = [];
  let rows = "";
  for (const line of records(text)) {
    if (line.startsWith("## Superseded")) break;
    if (!line.startsWith("- scope ")) continue;
    const subj = line.slice("- scope ".length).replace(/ \| src: [\s\S]*$/, "");
    const i = subj.indexOf(" = ");
    const scope = subj.slice(0, i);
    const apps = subj.slice(i + 3).replace(/[ \t]/g, "");
    if (i < 0 || !QA_SEGMENT.test(scope) || apps === "" || !apps.split(",").every((a) => QA_SEGMENT.test(a))) bad.push(line);
    else if (first.has(scope)) bad.push(first.get(scope)!, line);
    else {
      first.set(scope, line);
      rows += `${scope}\t${apps}\n`;
    }
  }
  if (bad.length === 0) return { status: 0, out: rows, err: "" };
  return { status: 2, out: "", err: `ac_knowledge_scopes: the scope map is AMBIGUOUS - refusing rather than picking a winner:\n${bad.map((l) => `  ${l}\n`).join("")}` };
}

// ac_yaml_has <cfg> qa.scopes, its awk's descent: a `scopes:` key PRESENT
// (children or not) one level under a column-0 `qa:`. Blank and comment lines
// are skipped, the indent is the leading SPACES / 2 floored, a key is
// `^[A-Za-z0-9_-]+:`, a shallower key ends the descent. A yaml it cannot read
// is absent, as awk's exit 2 was.
function qaScopesDeclared(cfg: string): boolean {
  let text: string;
  try {
    text = readFileSync(latBuf(cfg), "latin1");
  } catch {
    return false;
  }
  const parts = ["qa", "scopes"];
  let depth = 0;
  for (const line of records(text)) {
    if (/^[ \t\n\v\f\r]*(#|$)/.test(line)) continue;
    const spaces = /^ */.exec(line)![0].length;
    const key = /^[A-Za-z0-9_-]+(?=:)/.exec(line.slice(spaces));
    if (!key) continue;
    const ind = Math.floor(spaces / 2);
    if (ind < depth) depth = ind;
    if (ind === depth && key[0] === parts[depth]) {
      if (depth + 1 === parts.length) return true;
      depth++;
    }
  }
  return false;
}

const QA_KEYS = new Set(["schema", "outcome", "run", "task", "completed_at", "source_sha", "profile_key", "profile_sha256", "config_sha256", "cases_passed", "cases_total", "scope", "app", "qa_rule", "e2e_repo", "e2e_sha"]);

// ac_qa_attestation_parse's twin: null when the v2 marker holds for <sha>
// (and <scope>/<app>, or flat when <scope> is ""), else the bash's
// AC_QA_ATTESTATION_ERROR text, the checks in its order. Lines are what
// `IFS= read -r` gave - each cut at its first NUL, an unterminated last one
// read unless that leaves it empty - split at the first `=`. A marker that
// cannot be read has no lines (`unsupported schema`; the shell's own
// redirection line is not reproduced). Each count is canonical decimal (no
// leading zero, so at least 1) or `invalid case counts`.
export function qaAttestationParse(file: string, sha: string, scope: string, app: string, psha = "", e2e = ""): string | null {
  let size = -1;
  try {
    const st = statSync(latBuf(file));
    if (st.isFile()) size = st.size;
  } catch {}
  if (size < 0) return "not a regular file";
  if (size === 0) return "empty marker";
  let text = "";
  try {
    text = readFileSync(latBuf(file), "latin1");
  } catch {}
  const lines = text.split("\n").map((l) => l.split("\0", 1)[0]!);
  if (lines[lines.length - 1] === "") lines.pop();
  const kv = new Map<string, string>();
  for (const line of lines) {
    const eq = line.indexOf("=");
    if (eq < 0) return "malformed line";
    const key = line.slice(0, eq);
    if (!QA_KEYS.has(key)) return `unknown key '${key}'`;
    if (kv.has(key)) return `duplicate key '${key}'`;
    kv.set(key, line.slice(eq + 1));
  }
  const v = (k: string): string => kv.get(k) ?? "";
  if (v("schema") !== "agentcrew.qa-attestation/v2") return "unsupported schema";
  if (v("outcome") !== "passed") return "outcome is not passed";
  if (!v("run") || !v("task") || !v("completed_at")) return "missing run/task/completed_at";
  if (v("source_sha") !== sha) return "source_sha mismatch";
  if (!v("profile_key") || !v("profile_sha256") || !v("config_sha256")) return "missing profile/config identity";
  if (!/^[1-9][0-9]*$/.test(v("cases_passed")) || !/^[1-9][0-9]*$/.test(v("cases_total"))) return "invalid case counts";
  if (v("cases_passed") !== v("cases_total")) return "case counts differ";
  if (scope !== "") {
    if (v("scope") !== scope || v("app") !== app) return "scope/app body mismatch";
  } else if (kv.has("scope") || kv.has("app")) return "flat marker carries scope/app";
  const rule = v("qa_rule");
  if (kv.has("qa_rule") && rule !== "default" && (/[^0-9]/.test(rule) || rule === "0" || rule === "")) return "invalid qa_rule";
  if ((kv.has("e2e_repo") || kv.has("e2e_sha")) && (!v("e2e_repo") || !v("e2e_sha"))) return "partial E2E identity";
  if (psha !== "" && v("profile_sha256") !== psha) return "profile hash mismatch";
  if (e2e !== "" && v("e2e_sha") !== e2e) return "E2E hash mismatch";
  return null;
}

const QA_MATRIX_JQ = '.required_profiles[]? | [.profile_key // "", .profile_sha256 // "", .e2e_sha // ""] | @tsv';

// ac_qa_gate_matrix's twin, the required-profile arm: jq SPAWNED with the
// bash's program (number spellings, several documents and errors are jq's),
// any failure or no row the EMPTY refusal; each row read as `IFS=$'\t' read
// -r` (tabFields - a missing field shifts the next into it); a key's LAST two
// segments name the `<sha>.<scope>.<app>` marker; the first unmet row refuses.
function qaGateMatrix(manifest: string, dir: string, sha: string): boolean {
  let rows = "";
  try {
    const r = spawnShellSync(["jq", "-r", QA_MATRIX_JQ, latBuf(manifest).toString("utf8")], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
    if (r.exitCode === 0) rows = capturedText(Buffer.from(r.stdout));
  } catch {}
  if (rows === "") {
    warn(latBuf(`qa.require_for_ship: the task's required-profile manifest is empty or unreadable (${manifest}) - refusing rather than merging against an undefined required set`));
    return false;
  }
  const sha12 = shellPrefix(sha, 12);
  let n = 0;
  let satisfied = "";
  for (const row of rows.split("\n")) {
    const [key, psha, e2e] = tabFields(row, 3) as [string, string, string];
    if (key === "") {
      warn(latBuf(`qa.require_for_ship: a required-profile manifest entry has no profile_key (${manifest}) - refusing rather than guessing which profile it means`));
      return false;
    }
    n++;
    const app = key.slice(key.lastIndexOf("/") + 1);
    const rest = key.includes("/") ? key.slice(0, key.lastIndexOf("/")) : key;
    const scope = rest.slice(rest.lastIndexOf("/") + 1);
    for (const [seg, what] of [
      [scope, "scope"],
      [app, "app"],
    ]) {
      if (QA_SEGMENT.test(seg!)) continue;
      warn(latBuf(`qa.require_for_ship: required profile '${key}' does not parse to <project>/<scope>/<app> (${what} segment invalid) - fix the task manifest`));
      return false;
    }
    const marker = `${dir}/${sha}.${scope}.${app}`;
    if (!isFile(latBuf(marker))) {
      warn(latBuf(`qa.require_for_ship: required profile '${key}' has no passing crew-qa attestation for ${sha12} - run crew-qa for EVERY required profile at this head before merging`));
      return false;
    }
    const err = qaAttestationParse(marker, sha, scope, app, psha, e2e);
    if (err !== null) {
      warn(latBuf(`qa.require_for_ship: the attestation for '${key}' is invalid (${err}) - re-run crew-qa for this exact profile and head`));
      return false;
    }
    satisfied += ` ${key}`;
  }
  writeSync(1, latBuf(`qa: all ${n} required profile(s) satisfied for ${sha12}:${satisfied}\n`));
  return true;
}

// ac_qa_gate_ok's twin: true = open (not enforced, or proven), false =
// refused, its WARN written; the RETIRED die is qaRequired's throw. The
// markers are <main>/.crew/qa/passed, <main> the dirname of git's common dir
// (a linked worktree's main repo), <repo> as given when git cannot say. A
// task whose family holds data/<family>/qa/manifest.json (data/ minted on
// the way) is judged by the matrix alone. Otherwise the mode is read
// TWO-SIDED, the scope map and the yaml's qa.scopes: both silent is FLAT (the
// bare <sha> marker), one alone the MODE MISMATCH, both SCOPED - every
// regular `<sha>.<scope>.<app>` in byte order (the oracle's C glob), a name
// off that grammar or a body the parse refuses skipped and named, a
// directory skipped unnamed, the proven pairs printed. The bash's `command
// -v ac_yaml_has` refusal has no twin: nothing here is sourced.
export function qaGateOk(repo: string, sha: string, task = ""): boolean {
  if (!qaRequired(repo)) return true;
  const dir = `${lat(repoRoot(repo) ?? repo)}/.crew/qa/passed`;
  if (task !== "") {
    const manifest = `${lat(softSubdir("data", true))}/${lat(familyOfId(task))}/qa/manifest.json`;
    if (isFile(latBuf(manifest))) return qaGateMatrix(manifest, dir, sha);
  }
  const map = knowledgeScopes(repo);
  const mapScoped = map.out !== "";
  if (map.status === 2) {
    warn(
      "qa.require_for_ship: the project's scope map is AMBIGUOUS (two live entries for one scope, or a malformed line) - refusing the merge rather than guessing which profile a marker proves. Fix it with bin/ac-know.sh scope-proposal, then re-run: bin/ac-know.sh verify",
    );
    return false;
  }
  const cfg = qaConfigFile(repo, false);
  const yamlScoped = cfg !== null && qaScopesDeclared(cfg);
  const sha12 = shellPrefix(sha, 12);
  const bare = latBuf(`${dir}/${sha}`);
  if (!mapScoped && !yamlScoped) {
    if (isFile(bare)) {
      const err = qaAttestationParse(`${dir}/${sha}`, sha, "", "");
      if (err === null) return true;
      warn(latBuf(`qa.require_for_ship: ignored invalid flat QA attestation for ${sha12}: ${err}`));
    }
    warn(latBuf(`qa.require_for_ship: no passing crew-qa run recorded for ${sha12} - run crew-qa on this head before merging`));
    return false;
  }
  if (!mapScoped || !yamlScoped) {
    warn(
      mapScoped
        ? "qa.require_for_ship: MODE MISMATCH - the repo-knowledge record declares scopes but the fleet-home config carries no qa.scopes block, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge."
        : "qa.require_for_ship: MODE MISMATCH - the fleet-home config declares scopes but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge.",
    );
    return false;
  }
  let names: string[] = [];
  try {
    // Bun hands the names back as Uint8Array, whose toString ignores "latin1".
    names = readdirSync(latBuf(dir), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  let pairs = "";
  let skipped = "";
  for (const entry of names.filter((e) => e.startsWith(`${sha}.`)).sort()) {
    const m = `${dir}/${entry}`;
    if (!isFile(latBuf(m))) continue;
    // `$(basename "$m")` lost the name's trailing LFs.
    const base = entry.replace(/\n+$/, "");
    const rest = base.slice(sha.length + 1);
    const dot = rest.indexOf(".");
    const scope = rest.slice(0, dot);
    const app = rest.slice(dot + 1);
    if (dot < 0 || app.includes(".") || !QA_SEGMENT.test(scope) || !QA_SEGMENT.test(app)) {
      skipped += ` ${base}`;
      continue;
    }
    const err = qaAttestationParse(m, sha, scope, app);
    if (err === null) pairs += ` ${scope}/${app}`;
    else skipped += ` ${base}(${err})`;
  }
  if (pairs !== "") {
    writeSync(1, latBuf(`qa: passed profiles for ${sha12}:${pairs}\n`));
    return true;
  }
  const bareSaid = isFile(bare)
    ? " A bare sha-only marker IS on disk; it names no scope+app, so it proves nothing about WHICH profile ran and cannot satisfy the gate here - re-run crew-qa naming the scope and app."
    : "";
  warn(
    latBuf(
      `qa.require_for_ship: no passing crew-qa run recorded for ${sha12} on this SCOPED project - a run must name the scope+app it proved.${bareSaid}${skipped === "" ? "" : ` Malformed markers ignored:${skipped}`}`,
    ),
  );
  return false;
}
