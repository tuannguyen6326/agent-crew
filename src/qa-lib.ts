// qa-lib.ts - the TypeScript twins of the closed QA validators in
// tests/fixtures/ac-qa-lib.sh that src/verify.ts's qa verb calls, of the QA store
// learning loop src/qa.ts's store-curate and store-calibration call, and of
// the helpers those call in turn. THIS header is the twins' spec; src/qa.ts
// and src/verify.ts call the twins, and the frozen bash originals
// (tests/fixtures/ac-qa.sh, tests/fixtures/ac-verify.sh) still source every
// one, so each twin is pinned to its LIVE original by tests/ts/qa-lib.test.ts
// - two implementations until the last bash caller goes. The bash's comments
// own WHY each check exists; this file owns how the twin reads it.
//
//   qaBundleValidate(profile, sha)            ac_qa_bundle_validate
//   qaTestplanManifestRender(repo, sha, plan) ac_qa_testplan_manifest_render
//   qaTestplanManifestValidate(repo, sha, plan, manifest, manifestSha)
//                                             ac_qa_testplan_manifest_validate
//   qaTimestampEpoch(ts)                      ac_qa_timestamp_epoch
//   qaCoverageValidate(run, repo, sha)        ac_qa_coverage_validate
//   qaShipReceiptStatus(receipt, sha)         ac_qa_ship_receipt_status
//   qaRuntimeReceiptValidate(f, ...)          ac_qa_runtime_receipt_validate
//   qaRuntimeGateValidate(f, ...)             ac_qa_runtime_gate_validate
//   qaBoundaryCoherent(tier, boundary)        ac_qa_boundary_coherent
//   qaPathSha(path)                           ac_qa_path_sha
//   qaReceiptPathOk(run, caseId, path)        ac_qa_receipt_path_ok
//   qaBrowserManifestOk(run, caseId, receipt) ac_qa_browser_manifest_ok
//   qaBoundaryReceiptValidate(f, ...)         ac_qa_boundary_receipt_validate
//   qaStoreCaseBodySha(plan, id)              qa_store_case_body_sha
//   qaStoreHistoryAppend(store, cases, plan, sha, model, task)
//                                             qa_store_history_append
//   qaStorePromote(store, cases, plan, sha, after)
//                                             qa_store_promote
//   qaStoreCalibration(hist, labels)          qa_store_calibration
//
// A validator answers null where the bash returned 0, else the text the bash
// left in its error variable (AC_QA_BUNDLE_ERROR, AC_QA_MANIFEST_ERROR or
// AC_QA_RECEIPT_ERROR) - "" where it returned 1 without setting one. The
// render answers its status, stdout and error; the receipt status, the
// timestamp and the path identity answer what their `$(...)` callers read
// (the line without its LF; null for a failing jq). Arguments, file bytes and
// every answer are bytes, held as latin1 strings: a path reaches the
// filesystem as its bytes, but a spawned tool's argv decodes it as UTF-8, so a
// byte that is not UTF-8 reaches the tool as U+FFFD (named, as the qa-gate
// twins' W17).
//
// Every jq and awk program is the bash's verbatim and SPAWNED, as are find,
// sed, git and the awk field reads, so their bytes, locale and errors stay the
// tools'; each child's stderr goes where the bash left it. `LC_ALL=C sort`
// is byte order of the lines; `$(...)` drops NULs and trailing LFs; a `while
// read` loop reads complete lines only, each cut at its first NUL (bash 3.2);
// `IFS=$'\t' read` is tabFields, and the cases.tsv read through
// `IFS=$'\037'` keeps empty fields and drops one trailing separator from its
// last field when nothing follows it. ac_config_sha256 of a file it cannot
// read is "". ac_meta_get is metaGet, its warning on an unreadable file
// included. The render's pipeline status is read under pipefail, as both
// callers set it.
//
// The store loop runs as its `$(...)` callers ran it, errexit asleep: a failed
// mkdir, append or write is passed over and its row still counts. It answers
// what they read - the appended count, the `promoted=<k> reverified=<m>` line,
// the body hash or `-`, the calibration's JSON line with awk's status. Its
// `date -u +%Y-%m-%d` and ac_iso's date are spawned, so a PATH stub binds both
// sides; the run's ledger is read as `IFS=$'\t' read` reads it (tabFields).
//
// Named divergences: the shell's own error lines (a failed `<"$f"`, `>"$f"`
// or `>>"$f"` redirection, `cd`'s, `[`'s "integer expression expected") are
// not written - their statuses are kept; a `cd` the bash took under an
// exported CDPATH and a directory name ending in a LF read as HOME RESOLUTION
// has them;
// ac_qa_testplan_manifest_validate renders into a mktemp file in TMPDIR and
// refuses with no error text when that temp cannot be made, where this renders
// in memory; ac_qa_receipt_path_ok starts src/paths.ts through bun (exiting 1
// with `required tool not found: bun` when bun is absent), where this calls
// its receiptOk in process; the browser manifests are offered in byte order,
// where the bash glob's order is the locale's collation under UTF-8; a
// `[!0-9]` class is the ASCII digits; a case body is hashed in process, where
// the bash piped it to shasum or sha256sum (with neither on PATH its hash was
// empty); qa_store_promote's two `awk >"$f.tmp" && mv` rewrites take an
// exclusive temp, `<f>.tmp.<pid>` (EXCLUSIVE TEMP FILES), where the bash wrote
// through whatever sat at `<f>.tmp` (W14).

import { createHash } from "node:crypto";
import { appendFileSync, closeSync, lstatSync, openSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { exclusiveTemp, iso, metaGet, physicalDir, shellStatus, spawnShellSync, tabFields, testInt } from "./lib.ts";
import { receiptOk } from "./paths.ts";

const latBuf = (s: string): Buffer => Buffer.from(s, "latin1");
const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const argv = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const subst = (b: Buffer): string => b.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const sha256 = (b: Buffer | string): string => createHash("sha256").update(typeof b === "string" ? latBuf(b) : b).digest("hex");

function run(cmd: string[], stdin: Buffer | "inherit", stderr: "inherit" | "ignore" = "inherit", cwd?: string): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout: "pipe", stderr, cwd });
  } catch {}
  return { status: shellStatus(r), out: r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

const jqText = (args: string[], stderr: "inherit" | "ignore" = "inherit"): string => run(["jq", ...args], "inherit", stderr).out.toString("latin1");
const jqOk = (args: string[], stderr: "inherit" | "ignore" = "ignore"): boolean => run(["jq", ...args], "inherit", stderr).status === 0;

const stat = (p: string, follow: boolean): ReturnType<typeof statSync> | null => {
  try {
    return follow ? statSync(latBuf(p)) : lstatSync(latBuf(p));
  } catch {
    return null;
  }
};
const isFile = (p: string): boolean => stat(p, true)?.isFile() ?? false;
const isDir = (p: string): boolean => stat(p, true)?.isDirectory() ?? false;
const isLink = (p: string): boolean => stat(p, false)?.isSymbolicLink() ?? false;

// metaGet takes a string, but its fs calls and its warning take the path's
// bytes as a Buffer gives them.
function meta(f: string, key: string): string {
  try {
    return metaGet(latBuf(f) as unknown as string, key);
  } catch {
    return "";
  }
}

function fileSha(p: string): string {
  try {
    return sha256(readFileSync(latBuf(p)));
  } catch {
    return "";
  }
}

// The complete lines a `while read` loop takes from a stream.
function lines(text: string): string[] {
  const l = text.split("\n");
  l.pop();
  return l.map((x) => x.split("\0", 1)[0]!);
}

// `<stream> | LC_ALL=C sort`, the lines it prints.
function cSort(text: string): string[] {
  const l = text.split("\n");
  if (l[l.length - 1] === "") l.pop();
  return l.sort();
}

const sortedSubst = (text: string): string => subst(latBuf(cSort(text).map((l) => `${l}\n`).join("")));

// basename(1) and dirname(1) as `$(...)` read them.
function baseOf(p: string): string {
  if (p === "") return "";
  const t = p.replace(/\/+$/, "");
  return (t === "" ? "/" : t.slice(t.lastIndexOf("/") + 1)).replace(/\n+$/, "");
}

function dirOf(p: string): string {
  const t = p.replace(/\/+$/, "");
  if (t === "") return p === "" ? "." : "/";
  const i = t.lastIndexOf("/");
  if (i < 0) return ".";
  return (t.slice(0, i).replace(/\/+$/, "") || "/").replace(/\n+$/, "");
}

// `IFS=$'\037' read -r <n names>`: \037 is no IFS whitespace, so every
// separator splits and empty fields stay; the last name keeps the rest of the
// line less one separator that ends it.
function usFields(line: string, n: number): string[] {
  const f: string[] = [];
  let rest = line;
  for (let i = 1; i < n; i++) {
    const at = rest.indexOf("\x1f");
    f.push(at < 0 ? rest : rest.slice(0, at));
    rest = at < 0 ? "" : rest.slice(at + 1);
  }
  const at = rest.indexOf("\x1f");
  f.push(at >= 0 && at === rest.length - 1 ? rest.slice(0, at) : rest);
  return f;
}

const unsafeRel = (r: string): boolean => r.startsWith("/") || r === ".." || r.startsWith("../") || r.includes("/../") || r.endsWith("/..");

const PROFILE_JQ = `
    type == "object"
    and .schema == "agentcrew.qa-profile/v1"
    and (.profile_key | type == "string" and length > 0)
    and (.profile_sha256 | type == "string" and length > 0)
    and (.source.ref | type == "string" and length > 0)
    and .snapshots.config_file == "config.yaml"
    and .snapshots.scopes_file == "scopes.tsv"
    and .snapshots.store_manifest_file == "store/manifest.json"
    and .snapshots.ship_test_receipt_file == "ship/test-receipt.env"
    and (.snapshots.ship_test_receipt_sha256 | type == "string" and length > 0)
    and (
      if has("routing") then
        (.routing | type) == "object"
        and .routing.kind == "qa"
        and (.routing.use | type) == "object"
        and (.routing.use.harness | type) == "string"
        and (.routing.use.harness | length) > 0
        and (.routing.use.model | type) == "string"
        and (.routing.use.effort | type) == "string"
        and (.routing.dispatch_sha256 | type) == "string"
        and (.routing.dispatch_sha256 | test("^[0-9a-f]{64}$"))
        and (
          if .routing.rule == "default" then
            (((.routing | has("when")) or (.routing | has("why"))) | not)
          else
            (.routing.rule | type) == "number"
            and .routing.rule >= 1
            and (.routing.rule | floor) == .routing.rule
            and (.routing.when | type) == "string"
            and (.routing.when | length) > 0
            and (.routing.why | type) == "string"
            and (.routing.why | length) > 0
          end)
      else true end
    )
  `;

const STORE_MANIFEST_JQ = `
    type == "object"
    and .schema == "agentcrew.qa-store-snapshot/v1"
    and (.entries | type == "array")
    and all(.entries[];
      type == "object"
      and (.path | type == "string" and length > 0)
      and (.sha256 | type == "string" and length > 0))
  `;

const FIXTURE_PACK_JQ = `
      type == "object"
      and .schema == "agentcrew.qa-fixture-pack/v1"
      and (.id | type) == "string" and (.id | length) > 0
      and (.runner | type) == "string" and (.runner | length) > 0
      and (.selectors | type) == "array" and (.selectors | length) > 0
      and all(.selectors[]; type == "string" and length > 0)
      and ((.selectors | unique | length) == (.selectors | length))
      and (.capabilities | type) == "array"
      and (.mutation as $m | ["read-only","read-write"] | index($m) != null)
      and (.retry as $r | ["idempotent","read-only"] | index($r) != null)
      and (if .mutation == "read-write" then .retry == "idempotent" else true end)
      and ((.assets // []) | type) == "array"
      and all((.assets // [])[]; type == "string" and length > 0)
    `;

const CANONICAL_JQ = `
    del(.profile_sha256,
        .provenance.resolved_at,
        .provenance.project_config_path,
        .provenance.repo_knowledge_path,
        .e2e.repo_path)
  `;

const ROOT_ENTRIES = ["profile.json", "config.yaml", "scopes.tsv", "store", "runtime.json", "ship"];

export function qaBundleValidate(profile: string, wantSha: string): string | null {
  if (baseOf(profile) !== "profile.json") return "profile filename must be profile.json";
  const named = physicalDir(argv(dirOf(profile)));
  if (named === null) return "bundle directory is unreadable";
  const bundle = lat(named).replace(/\n+$/, "");
  if (profile !== `${bundle}/profile.json`) return "profile path is not the fixed bundle file";
  if (subst(run(["find", argv(bundle), "-type", "l", "-print", "-quit"], "inherit", "ignore").out) !== "") return "bundle contains a symlink";
  for (const entry of cSort(run(["find", argv(bundle), "-mindepth", "1", "-maxdepth", "1", "-print"], "inherit").out.toString("latin1")))
    if (!ROOT_ENTRIES.includes(baseOf(entry))) return `unknown bundle root entry: ${baseOf(entry)}`;
  const config = `${bundle}/config.yaml`;
  const scopes = `${bundle}/scopes.tsv`;
  const manifest = `${bundle}/store/manifest.json`;
  const shipReceipt = `${bundle}/ship/test-receipt.env`;
  if (!isDir(`${bundle}/store`) || isLink(`${bundle}/store`)) return "bundle store is missing or symlinked";
  if (!isDir(`${bundle}/ship`) || isLink(`${bundle}/ship`)) return "bundle ship receipt directory is missing or symlinked";
  for (const got of [profile, config, scopes, manifest, shipReceipt]) if (!isFile(got) || isLink(got)) return `missing or symlinked bundle file: ${got}`;
  if (!jqOk(["-e", PROFILE_JQ, argv(profile)])) return "invalid profile schema or fixed snapshot names";
  const field = (prog: string): string => subst(latBuf(jqText(["-r", prog, argv(profile)])));
  if (field(".source.ref") !== wantSha) return "profile source ref does not match exact source lease";
  const configSha = fileSha(config);
  const scopesSha = fileSha(scopes);
  const manifestSha = fileSha(manifest);
  if (configSha !== field('.snapshots.config_sha256 // ""')) return "config snapshot hash mismatch";
  if (scopesSha !== field('.snapshots.scopes_sha256 // ""')) return "scope snapshot hash mismatch";
  if (manifestSha !== field('.snapshots.store_manifest_sha256 // ""')) return "store manifest hash mismatch";
  if (fileSha(shipReceipt) !== field('.snapshots.ship_test_receipt_sha256 // ""')) return "frozen ship test receipt hash mismatch";
  if (meta(shipReceipt, "schema") !== "agentcrew.ship-test-receipt/v1") return "frozen ship test receipt has the wrong schema";
  if (meta(shipReceipt, "source_sha") !== wantSha) return "frozen ship test receipt binds another source sha";
  if (!jqOk(["-e", STORE_MANIFEST_JQ, argv(manifest)])) return "invalid store manifest";
  const listed = sortedSubst(jqText(["-r", ".entries[].path", argv(manifest)]));
  const found = run(["find", argv(`${bundle}/store`), "-type", "f", "!", "-path", argv(manifest), "-print"], "inherit").out;
  const actual = sortedSubst(run(["sed", argv(`s#^${bundle}/store/##`)], found).out.toString("latin1"));
  if (listed !== actual) return "store manifest/file inventory mismatch";
  for (const line of lines(jqText(["-r", ".entries[] | [.path,.sha256] | @tsv", argv(manifest)]))) {
    const [rel, want] = tabFields(line, 2) as [string, string];
    if (rel === "") continue;
    if (unsafeRel(rel) || rel.includes("\t") || rel.includes("\n")) return `unsafe store entry path: ${rel}`;
    const entry = `${bundle}/store/${rel}`;
    if (!isFile(entry) || isLink(entry)) return `missing store entry: ${rel}`;
    if (fileSha(entry) !== want) return `store entry hash mismatch: ${rel}`;
  }
  const packs = run(["find", argv(`${bundle}/store/fixtures`), "-mindepth", "2", "-maxdepth", "2", "-name", "manifest.json", "-type", "f"], "inherit", "ignore").out;
  for (const fm of cSort(packs.toString("latin1"))) {
    if (fm === "") continue;
    const pack = dirOf(fm);
    if (!jqOk(["-e", FIXTURE_PACK_JQ, argv(fm)])) return `invalid fixture-pack manifest: ${fm.startsWith(`${bundle}/store/`) ? fm.slice(bundle.length + 7) : fm}`;
    for (const rel of lines(jqText(["-r", ".runner, (.assets // [])[]", argv(fm)]))) {
      if (rel === "" || unsafeRel(rel)) return `unsafe fixture-pack path: ${rel}`;
      if (!isFile(`${pack}/${rel}`) || isLink(`${pack}/${rel}`)) return `missing fixture-pack file: ${rel}`;
    }
  }
  const canonical = sha256(run(["jq", "-S", CANONICAL_JQ, argv(profile)], "inherit").out);
  if (canonical !== field('.profile_sha256 // ""')) return "canonical profile hash mismatch";
  return null;
}

// The test plan's declaration parser, verbatim; its `fail` lines go to the
// same pipe as its declarations (`2>&1`), so a /bin/sh does that redirection.
const TESTPLAN_AWK = String.raw`
    function fail(message) {
      print message >"/dev/stderr"
      failed=1
      exit 1
    }
    function valid_id(value) {
      return value ~ /^[A-Za-z0-9_.-]+$/ \
        && value != "." && value != ".." \
        && value !~ /\.\./ && value ~ /[A-Za-z0-9]/
    }
    /^[[:space:]]*${"```"}/ || /^[[:space:]]*~~~/ { fenced = !fenced; next }
    fenced { next }
    /^## / {
      section=""
      if ($0 == "## Coverage") {
        coverage_sections++
        section="coverage"
      } else if ($0 == "## Full Flow") {
        flow_sections++
        section="flow"
      }
      next
    }
    section == "coverage" && /^coverage:/ {
      if ($0 !~ /^coverage: / || $0 ~ /[[:space:]]$/)
        fail("malformed coverage declaration at line " NR)
      rest=substr($0, 11)
      count=split(rest, field, / [|] /)
      if (count != 4)
        fail("coverage declaration needs four exact fields at line " NR)
      for (i=1; i<=4; i++)
        if (field[i] == "" || field[i] ~ /^[[:space:]]/ || field[i] ~ /[[:space:]]$/)
          fail("coverage declaration has an empty or padded field at line " NR)
      ac=field[1]; rung=field[2]; proof=field[3]; case_id=field[4]
      if (!valid_id(ac))
        fail("invalid acceptance-criterion id at line " NR ": " ac)
      if (rung != "ut" && rung != "it" && rung != "e2e")
        fail("invalid coverage rung at line " NR ": " rung)
      if (rung == "ut") {
        if (proof == "-" || case_id != "-")
          fail("UT coverage needs a test reference and no QA case at line " NR)
      } else if (proof != "-" || !valid_id(case_id)) {
        fail("IT/E2E coverage needs a case id and no test reference at line " NR)
      }
      key=ac SUBSEP rung SUBSEP proof SUBSEP case_id
      if (coverage_seen[key]++)
        fail("duplicate coverage declaration at line " NR)
      if (rung != "ut")
        covered_case[case_id]=1
      coverage_count++
      printf "C\t%s\t%s\t%s\t%s\n", ac, rung, proof, case_id
      next
    }
    section == "flow" && /^full-flow:/ {
      if ($0 !~ /^full-flow: / || $0 ~ /[[:space:]]$/)
        fail("malformed full-flow declaration at line " NR)
      case_id=substr($0, 12)
      if (!valid_id(case_id))
        fail("invalid full-flow case id at line " NR ": " case_id)
      if (flow_seen[case_id]++)
        fail("duplicate full-flow declaration at line " NR ": " case_id)
      flow_order[++flow_count]=case_id
      printf "F\t%s\n", case_id
      next
    }
    END {
      if (failed) exit 1
      if (fenced)
        fail("unterminated fenced code block in test plan")
      if (coverage_sections != 1)
        fail("test plan needs exactly one ## Coverage section")
      if (flow_sections != 1)
        fail("test plan needs exactly one ## Full Flow section")
      if (coverage_count < 1)
        fail("test plan needs at least one coverage declaration")
      if (flow_count < 1)
        fail("test plan needs at least one full-flow declaration")
      for (i=1; i<=flow_count; i++)
        if (!covered_case[flow_order[i]])
          fail("full-flow case is not cited by IT/E2E coverage: " flow_order[i])
    }
  `;

const MANIFEST_JQ = String.raw`
    split("\n")
    | map(select(length > 0) | split("\t")) as $rows
    | {
        schema: "agentcrew.qa-testplan-manifest/v1",
        testplan_sha256: $plan_sha,
        coverage: [
          $rows[]
          | select(.[0] == "C")
          | {ac: .[1], rung: .[2], proof: .[3], case: .[4]}
        ],
        full_flow: [
          $rows[]
          | select(.[0] == "F")
          | .[1]
        ]
      }
  `;

const UNSAFE_TEST_PATH = /^$|^\/|^\.$|^\.\.$|^\.\/|\/\.\/|\/\.$|^\.\.\/|\/\.\.\/|\/\.\.$|[#|\t\r\n]/;

export function qaTestplanManifestRender(sourceRepo: string, targetSha: string, testplan: string): { status: number; out: Buffer; error: string } {
  const refuse = (error: string) => ({ status: 1, out: Buffer.alloc(0), error });
  if (!isDir(sourceRepo) || run(["git", "-C", argv(sourceRepo), "cat-file", "-e", argv(`${targetSha}^{commit}`)], "inherit", "ignore").status !== 0)
    return refuse(`target source commit is unavailable: ${targetSha}`);
  if (!isFile(testplan)) return refuse(`test plan is missing: ${testplan}`);
  const p = run(["/bin/sh", "-c", 'exec awk "$0" "$1" 2>&1', TESTPLAN_AWK, argv(testplan)], "inherit");
  const parsed = subst(p.out);
  if (p.status !== 0) return refuse(parsed || "test-plan manifest parse failed");
  for (const line of lines(`${parsed}\n`)) {
    const [kind, ac, rung, proof] = tabFields(line, 5) as [string, string, string, string];
    if (kind !== "C" || rung !== "ut") continue;
    let path = proof;
    const hash = proof.indexOf("#");
    if (hash >= 0) {
      path = proof.slice(0, hash);
      const selector = proof.slice(hash + 1);
      if (selector === "" || /[#|\t\r\n]/.test(selector)) return refuse(`UT coverage ${ac} has an invalid selector: ${proof}`);
    }
    const unsafe = `UT coverage ${ac} has an unsafe repository test path: ${path}`;
    if (UNSAFE_TEST_PATH.test(path)) return refuse(unsafe);
    let prefix = "";
    for (const part of path.split("/")) {
      if (part === "") return refuse(unsafe);
      prefix = prefix === "" ? part : `${prefix}/${part}`;
      const tree = run(["git", "-C", argv(sourceRepo), "ls-tree", argv(targetSha), "--", argv(prefix)], "inherit").out;
      const mode = subst(run(["awk", "NR==1 { print $1 }"], tree).out);
      if (prefix === path) {
        if (mode !== "100644" && mode !== "100755") return refuse(`UT coverage ${ac} does not name a regular tracked blob at ${targetSha}: ${path}`);
      } else if (mode !== "040000") return refuse(`UT coverage ${ac} crosses a missing or symlinked Git-tree parent: ${prefix}`);
    }
  }
  const rows = run(["jq", "-Rsc", "--arg", "plan_sha", fileSha(testplan), MANIFEST_JQ], latBuf(`${parsed}\n`));
  const canon = run(["jq", "-cS", "."], rows.out);
  return { status: canon.status || rows.status, out: canon.out, error: "" };
}

export function qaTestplanManifestValidate(sourceRepo: string, targetSha: string, testplan: string, manifest: string, expectedSha: string): string | null {
  if (!isFile(manifest)) return `frozen test-plan manifest is missing: ${manifest}`;
  const r = qaTestplanManifestRender(sourceRepo, targetSha, testplan);
  if (r.status !== 0) return r.error;
  let frozen: Buffer | null = null;
  try {
    frozen = readFileSync(latBuf(manifest));
  } catch {}
  if (frozen === null || !frozen.equals(r.out)) return "current test plan disagrees with the frozen manifest";
  if (expectedSha === "" || fileSha(manifest) !== expectedSha) return "frozen manifest hash mismatch";
  return null;
}

export function qaTimestampEpoch(ts: string): string | null {
  const r = run(["jq", "-nr", "--arg", "timestamp", argv(ts), "$timestamp | fromdateiso8601"], "inherit", "ignore");
  return r.status === 0 ? subst(r.out) : null;
}

export function qaCoverageValidate(runDir: string, sourceRepo: string, targetSha: string): string | null {
  const runMeta = `${runDir}/run.meta`;
  const evidenceRoot = meta(runMeta, "evidence") || `${runDir}/evidence`;
  const testplan = meta(runMeta, "testplan_path") || `${dirOf(evidenceRoot)}/testplan.md`;
  const manifest = `${runDir}/testplan-manifest.json`;
  const manifestSha = meta(runMeta, "testplan_manifest_sha256");
  const frozen = qaTestplanManifestValidate(sourceRepo, targetSha, testplan, manifest, manifestSha);
  if (frozen !== null) return frozen;
  const shipStatus = qaShipReceiptStatus(`${runDir}/profile/ship/test-receipt.env`, targetSha);
  const cases = `${runDir}/cases.tsv`;
  for (const line of lines(jqText(["-r", ".coverage[] | [.ac,.rung,.proof,.case] | @tsv", argv(manifest)]))) {
    const [ac, rung, , caseId] = tabFields(line, 4) as [string, string, string, string];
    if (rung === "ut") {
      if (!shipStatus.startsWith("qualifies:")) return `UT coverage ${ac} requires a qualifying exact-SHA ship receipt (got ${shipStatus}); escalate this AC to IT`;
    } else if (rung === "it" || rung === "e2e") {
      const byId = (prog: string): string => subst(run(["awk", "-F\\t", "-v", `id=${argv(caseId)}`, prog, argv(cases)], "inherit").out);
      if (byId("$1 == id { n++ } END { print n+0 }") !== "1") return `${rung} coverage ${ac} needs exactly one effective case row for ${caseId}`;
      const row = byId("$1 == id { print; exit }");
      const col = (n: number): string => subst(run(["awk", "-F\\t", `{print $${n}}`], latBuf(`${row}\n`)).out);
      const tier = col(2);
      const status = col(3);
      const boundary = col(11);
      if (status !== "pass") return `${rung} coverage ${ac} cites non-passing case ${caseId}`;
      if (rung === "it") {
        if (!["api", "db", "workflow"].includes(tier)) return `IT coverage ${ac} cites case ${caseId} with non-IT tier ${tier}`;
      } else if (tier !== "web" && boundary !== "e2e") return `E2E coverage ${ac} cites case ${caseId} without web or e2e evidence`;
    }
  }
  let ledger = "";
  try {
    ledger = readFileSync(latBuf(cases)).toString("latin1");
  } catch {}
  let minFlow = "";
  let maxComponent = "";
  for (const line of lines(ledger.replace(/\t/g, "\x1f"))) {
    const [id, tier, status, , , , , , , , , receipt] = usFields(line, 12) as string[];
    if (id === "") continue;
    const started = meta(receipt!, "started_at");
    const completed = meta(receipt!, "completed_at");
    const start = qaTimestampEpoch(started);
    if (start === null) return `case ${id} has an invalid boundary started_at timestamp: ${started}`;
    const done = qaTimestampEpoch(completed);
    if (done === null) return `case ${id} has an invalid boundary completed_at timestamp: ${completed}`;
    const s = testInt(start);
    const c = testInt(done);
    if (s === null || c === null || c < s) return `case ${id} boundary completed_at precedes started_at`;
    if (run(["jq", "-e", "--arg", "id", argv(id!), ".full_flow | index($id) != null", argv(manifest)], "inherit").status === 0) {
      if (status !== "pass") return `full-flow case ${id} is not passing`;
      if (!["api", "db", "workflow", "web"].includes(tier!)) return `full-flow case ${id} has invalid tier ${tier}`;
      if (minFlow === "" || testInt(minFlow)! > s) minFlow = start;
    } else if (maxComponent === "" || testInt(maxComponent)! < c) maxComponent = done;
  }
  if (minFlow === "") return "no declared full-flow case exists in the effective ledger";
  if (maxComponent !== "" && testInt(minFlow)! < testInt(maxComponent)!) return "full-flow final group started before all component cases completed";
  return null;
}

const RECEIPT_REASONS = ["executed", "execution-attestation", "absent", "incomplete", "non-zero", "stale", "invalid", "scoped"];

// The line ac_qa_ship_receipt_status prints, without its LF.
export function qaShipReceiptStatus(src: string, wantSha: string): string {
  if (src === "" || !isFile(src)) return "not-qualifies:absent";
  if (meta(src, "schema") !== "agentcrew.ship-test-receipt/v1") return "not-qualifies:invalid";
  const qual = meta(src, "qualification");
  const reason = meta(src, "reason");
  const sha = meta(src, "source_sha");
  if (!RECEIPT_REASONS.includes(reason)) return "not-qualifies:invalid";
  if (wantSha === "" || sha !== wantSha) return "not-qualifies:stale";
  const executed = reason === "executed" || reason === "execution-attestation";
  if (qual !== "qualifies") return executed ? "not-qualifies:invalid" : `not-qualifies:${reason}`;
  const exitCode = meta(src, "exit_code");
  const ids = ["command_sha256", "output_sha256", "started_at", "completed_at"].map((k) => meta(src, k));
  if (!executed) return "not-qualifies:invalid";
  if (exitCode !== "0" || ids.some((v) => v === "" || v === "-")) return "not-qualifies:invalid";
  return `qualifies:${reason}`;
}

// The `[!0-9]` class and a process group's `0` refusal.
const positiveGroup = (g: string): boolean => /^[0-9]+$/.test(g) && g !== "0";

export function qaRuntimeReceiptValidate(f: string, sourceSha: string, profileSha: string, serveSha: string, healthSha: string, descSha: string): string | null {
  if (!isFile(f)) return `runtime receipt is missing: ${f}`;
  if (meta(f, "schema") !== "agentcrew.qa-runtime-receipt/v1") return "runtime receipt has the wrong schema";
  if (meta(f, "source_sha") !== sourceSha) return "runtime receipt binds another source sha";
  if (meta(f, "profile_sha256") !== profileSha) return "runtime receipt binds another profile hash";
  if (meta(f, "serve_command_sha256") !== serveSha) return "runtime receipt binds another serve command";
  if (meta(f, "health_command_sha256") !== healthSha) return "runtime receipt binds another health command";
  if (meta(f, "runtime_descriptor_sha256") !== descSha) return "runtime receipt binds another runtime descriptor";
  if (meta(f, "serve_started_at") === "" || meta(f, "health_completed_at") === "") return "runtime receipt has no boot/health timestamps";
  if (!positiveGroup(meta(f, "process_group"))) return "runtime receipt has no positive process group";
  return null;
}

export function qaRuntimeGateValidate(f: string, sourceSha: string, profileSha: string, runtimeSha: string, healthSha: string, pgid: string): string | null {
  if (!isFile(f)) return `runtime gate receipt is missing: ${f}`;
  if (meta(f, "schema") !== "agentcrew.qa-runtime-gate/v1") return "runtime gate receipt has the wrong schema";
  if (meta(f, "source_sha") !== sourceSha) return "runtime gate receipt binds another source sha";
  if (meta(f, "profile_sha256") !== profileSha) return "runtime gate receipt binds another profile hash";
  if (meta(f, "runtime_receipt_sha256") !== runtimeSha) return "runtime gate receipt binds another boot receipt";
  if (meta(f, "health_command_sha256") !== healthSha) return "runtime gate receipt binds another health command";
  if (meta(f, "process_group") !== pgid) return "runtime gate receipt binds another process group";
  if (meta(f, "alive") !== "1" || meta(f, "health_exit_code") !== "0") return "runtime gate receipt does not record a live zero-exit probe";
  if (meta(f, "validated_at") === "") return "runtime gate receipt has no validation timestamp";
  return null;
}

const COHERENT: Record<string, string[]> = {
  api: ["http", "grpc", "client-cli", "e2e"],
  db: ["http", "grpc", "client-cli", "workflow", "queue", "schedule", "e2e"],
  workflow: ["workflow", "queue", "schedule", "e2e"],
  web: ["web", "e2e"],
};

export function qaBoundaryCoherent(tier: string, boundary: string): boolean {
  return Object.hasOwn(COHERENT, tier) && COHERENT[tier]!.includes(boundary);
}

// A directory's identity is the hash of its `<./relpath> <sha>` manifest,
// find's listing (run inside it; a directory it cannot enter lists nothing)
// in byte order, each file's hash "" when it cannot be read.
export function qaPathSha(p: string): string {
  if (!isDir(p)) return fileSha(p);
  let listing = "";
  try {
    listing = Buffer.from(spawnShellSync(["find", ".", "-type", "f", "-print"], { cwd: argv(p), stdin: "inherit", stdout: "pipe", stderr: "inherit" }).stdout).toString("latin1");
  } catch {}
  return sha256(cSort(listing).map((f) => `${f} ${fileSha(f.startsWith("/") ? f : `${p}/${f}`)}\n`).join(""));
}

export function qaReceiptPathOk(runDir: string, caseId: string, path: string): boolean {
  const a = [runDir, caseId, path].map(argv);
  if (a.some((x) => x.includes("�"))) return false;
  return receiptOk(a[0]!, a[1]!, a[2]!, () => process.cwd());
}

export function qaBrowserManifestOk(runDir: string, caseId: string, f: string): string | null {
  const want = meta(f, "evidence_sha256");
  const dir = `${runDir}/boundaries/${caseId}`;
  let names: string[] = [];
  try {
    names = readdirSync(latBuf(dir), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  let m = "";
  for (const n of names.filter((x) => !x.startsWith(".") && x.endsWith(".manifest")).sort()) {
    const cand = `${dir}/${n}`;
    if (isFile(cand) && fileSha(cand) === want) {
      m = cand;
      break;
    }
  }
  if (m === "") return `browser evidence manifest for case ${caseId} is missing or tampered`;
  const vsha = subst(run(["awk", '$1=="visual"{print $2}', argv(m)], "inherit").out);
  if (vsha === "") return `browser evidence manifest for case ${caseId} names no visual`;
  let visuals: string | null = null;
  try {
    visuals = readFileSync(latBuf(`${runDir}/visuals.tsv`)).toString("latin1");
  } catch {}
  for (const line of visuals === null ? [] : lines(visuals)) {
    const [path, , , rest] = tabFields(line, 5) as [string, string, string, string];
    if (rest !== caseId || !isFile(path)) continue;
    if (qaPathSha(path) === vsha) return null;
  }
  return `the registered screenshot for case ${caseId} no longer matches its browser boundary receipt`;
}

const BOUNDARIES = ["http", "grpc", "client-cli", "workflow", "queue", "schedule", "web", "e2e"];

export function qaBoundaryReceiptValidate(
  f: string,
  caseId: string,
  tier: string,
  status: string,
  sourceSha: string,
  profileSha: string,
  runtimeSha: string,
  expectedEvidence = "",
): string | null {
  if (!isFile(f)) return `boundary receipt is missing: ${f}`;
  if (meta(f, "schema") !== "agentcrew.qa-boundary-receipt/v1") return "boundary receipt has the wrong schema";
  if (meta(f, "case_id") !== caseId) return "boundary receipt names another case id";
  if (meta(f, "source_sha") !== sourceSha) return "boundary receipt binds another source sha";
  if (meta(f, "profile_sha256") !== profileSha) return "boundary receipt binds another profile hash";
  if (meta(f, "runtime_receipt_sha256") !== runtimeSha) return "boundary receipt is not bound to this run's booted runtime";
  const boundary = meta(f, "boundary");
  if (!BOUNDARIES.includes(boundary)) return `boundary receipt has an unknown boundary '${boundary}'`;
  if (!qaBoundaryCoherent(tier, boundary)) return `tier '${tier}' cannot be satisfied by boundary '${boundary}'`;
  const driver = meta(f, "driver");
  const pair = `${boundary}:${driver}`;
  if (pair !== "web:browser" && pair !== "e2e:e2e" && (boundary === "web" || boundary === "e2e" || !pair.endsWith(":command")))
    return `boundary '${boundary}' cannot be driven by '${driver}'`;
  if (meta(f, "stimulus_sha256") === "" || meta(f, "evidence_sha256") === "") return "boundary receipt has no stimulus/evidence identity";
  if (expectedEvidence !== "" && expectedEvidence !== "-" && meta(f, "evidence_sha256") !== expectedEvidence)
    return "boundary receipt's registered evidence hash no longer matches the artifact on disk (tampered or substituted after publication)";
  if (meta(f, "started_at") === "" || meta(f, "completed_at") === "") return "boundary receipt has no execution timestamps";
  if (driver === "e2e" && (meta(f, "upstream_receipt_sha256") === "" || meta(f, "upstream_receipt_sha256") === "-")) return "e2e boundary wrapper binds no upstream receipt";
  const exitCode = meta(f, "exit_code");
  if (!/^[0-9]+$/.test(exitCode)) return "boundary receipt has no numeric exit code";
  if (status === "pass" && exitCode !== "0") return `a passing case cannot bind a non-zero boundary execution (exit ${exitCode})`;
  return null;
}

// --- the QA store learning loop ---------------------------------------------
// Each awk program is the bash's verbatim to the byte, its leading LF and
// indent included: awk's own error lines name the program's source line.

const BODY_AWK = String.raw`
    { for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
    $2 == id { print $4 "|" $6 "|" $7 "|" $8; exit }`;

const HISTORY_SEEN_AWK = "$1 == s && $3 == c { f = 1 } END { exit(f ? 0 : 1) }";

const VERIFIED_AWK = "/^verified: / { print v; next } { print }";

const CATALOG_VERIFIED_AWK = `
        index($0, "- " id " | ") == 1 { sub(/verified [^|]*$/, v) } { print }`;

const STREAK_AWK = String.raw`
      $3 == c { rows[++n] = $1 "\t" $5 "\t" $6 "\t" $7 }
      END {
        seen = ""; s = 0
        for (i = n; i >= 1; i--) {
          split(rows[i], r, "\t")
          if (index(seen, "[" r[1] "]")) continue
          seen = seen "[" r[1] "]"
          if (r[3] == "flaky") continue
          if (r[2] == "pass" && r[4] == b) s++; else break
        }
        print s
      }`;

const CASE_AWK = String.raw`
      { for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
      $2 == id {
        printf "# %s\n\n", id
        printf "surface: %s (%s)\n", $4, $9
        printf "needs: -\n"
        printf "fixtures: -\n"
        printf "precondition: %s\n", $6
        printf "steps: %s\n", $7
        printf "expected: %s\n", $8
        printf "provenance: promoted after consecutive passes (store-curate)\n"
        printf "verified: %s %s\n", sha, today
        printf "status: active\n"
        exit
      }`;

const CATALOG_AWK = String.raw`
      { for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
      $2 == id { printf "- %s | %s (%s) | %s | verified %s %s\n", id, $4, $9, $8, sha, today; exit }`;

const CALIBRATION_AWK = String.raw`
    FNR == NR {
      if ($3 == "confirmed") human[$1 "\t" $2] = "defect"
      else if ($3 == "not-a-defect") human[$1 "\t" $2] = "pass"
      next
    }
    {
      k = $1 "\t" $3
      if (!(k in human)) next
      if ($5 == "fail" && $6 == "defect") j = "defect"
      else if ($5 == "pass") j = "pass"
      else next
      h = human[k]; n++
      if (j == h) agree++
      if (j == "defect") jd++
      if (h == "defect") hd++
    }
    END {
      if (n == 0) { printf "{\"n\":0,\"agreement\":null,\"kappa\":null,\"computed_at\":\"%s\"}\n", at; exit }
      po = agree / n
      pe = (jd / n) * (hd / n) + ((n - jd) / n) * ((n - hd) / n)
      if (pe == 1) kappa = (po == 1) ? 1.0 : 0.0; else kappa = (po - pe) / (1 - pe)
      printf "{\"n\":%d,\"agreement\":%.4f,\"kappa\":%.4f,\"positives_judge\":%d,\"positives_human\":%d,\"computed_at\":\"%s\"}\n", n, po, kappa, jd, hd, at
    }`;

const today = (): string => subst(run(["date", "-u", "+%Y-%m-%d"], "inherit").out);

function readText(p: string): string {
  try {
    return readFileSync(latBuf(p)).toString("latin1");
  } catch {
    return "";
  }
}

function append(p: string, text: string): void {
  try {
    appendFileSync(latBuf(p), latBuf(text));
  } catch {}
}

function writeText(p: string, text: string): void {
  try {
    writeFileSync(latBuf(p), latBuf(text));
  } catch {}
}

function toFd(cmd: string[], fd: number): number {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout: fd, stderr: "inherit" });
  } catch {
  } finally {
    closeSync(fd);
  }
  return shellStatus(r);
}

// `<cmd> >"$f"` or `>>"$f"`: the shell opens the file before the command
// starts, so one it cannot open runs nothing.
function runInto(cmd: string[], p: string, flag: "w" | "a"): void {
  let fd: number;
  try {
    fd = openSync(latBuf(p), flag);
  } catch {
    return;
  }
  toFd(cmd, fd);
}

// `<cmd> >"$f.tmp" && mv "$f.tmp" "$f"`: a command that fails leaves the temp
// and <f> as they were.
function rewrite(cmd: string[], p: string): void {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(argv(`${p}.tmp`));
  } catch {
    return;
  }
  if (toFd(cmd, t.fd) === 0) run(["mv", t.path, argv(p)], "inherit");
}

// The line qa_store_case_body_sha prints, without its LF.
export function qaStoreCaseBodySha(plan: string, id: string): string {
  if (!isFile(plan)) return "-";
  const body = subst(run(["awk", "-F|", "-v", `id=${argv(id)}`, BODY_AWK, argv(plan)], "inherit").out);
  return body === "" ? "-" : sha256(body);
}

// The count qa_store_history_append prints, without its LF. <model> and
// <task> empty read `-`, as their `${5:--}` defaults did.
export function qaStoreHistoryAppend(store: string, cases: string, plan: string, sha: string, model = "", task = ""): string {
  const hist = `${store}/history.tsv`;
  if (!isFile(cases)) return "0";
  run(["mkdir", "-p", argv(store)], "inherit");
  const day = today();
  let n = 0;
  for (const line of lines(readText(cases))) {
    const [id = "", tier = "", status = "", cls = ""] = tabFields(line, 5);
    if (id === "") continue;
    if (isFile(hist) && run(["awk", "-F\\t", "-v", `s=${argv(sha)}`, "-v", `c=${argv(id)}`, HISTORY_SEEN_AWK, argv(hist)], "inherit").status === 0) continue;
    const body = qaStoreCaseBodySha(plan, id);
    append(hist, `${sha}\t${day}\t${id}\t${tier}\t${status}\t${cls || "-"}\t${body}\t${model || "-"}\t${task || "-"}\n`);
    n++;
  }
  return `${n}`;
}

// The line qa_store_promote prints, without its LF. A streak or <after> that
// `[ -ge ]` cannot compare passes the row over, as its error status did.
export function qaStorePromote(store: string, cases: string, plan: string, sha: string, after = "3"): string {
  const hist = `${store}/history.tsv`;
  if (!isFile(cases) || !isFile(hist)) return "promoted=0 reverified=0";
  run(["mkdir", "-p", argv(`${store}/cases`)], "inherit");
  const day = today();
  const catalog = `${store}/catalog.md`;
  let promoted = 0;
  let reverified = 0;
  for (const line of lines(readText(cases))) {
    const [id = "", , status = "", cls = ""] = tabFields(line, 5);
    if (id === "" || status !== "pass" || cls === "flaky") continue;
    const f = `${store}/cases/${id}.md`;
    if (isFile(f)) {
      if (run(["grep", "-q", "^verified: ", argv(f)], "inherit").status === 0) rewrite(["awk", "-v", `v=verified: ${argv(sha)} ${day}`, VERIFIED_AWK, argv(f)], f);
      else append(f, `verified: ${sha} ${day}\n`);
      if (isFile(catalog)) rewrite(["awk", "-v", `id=${argv(id)}`, "-v", `v=verified ${argv(sha)} ${day}`, CATALOG_VERIFIED_AWK, argv(catalog)], catalog);
      reverified++;
      continue;
    }
    const body = qaStoreCaseBodySha(plan, id);
    if (body === "-") continue;
    const streak = subst(run(["awk", "-F\\t", "-v", `c=${argv(id)}`, "-v", `b=${body}`, STREAK_AWK, argv(hist)], "inherit").out);
    const s = testInt(streak || "0");
    const a = testInt(after);
    if (s === null || a === null || s < a) continue;
    const vars = ["-v", `id=${argv(id)}`, "-v", `sha=${argv(sha)}`, "-v", `today=${day}`];
    runInto(["awk", "-F|", ...vars, CASE_AWK, argv(plan)], f, "w");
    if (!isFile(catalog)) writeText(catalog, "# Case catalog\n");
    runInto(["awk", "-F|", ...vars, CATALOG_AWK, argv(plan)], catalog, "a");
    promoted++;
  }
  return `promoted=${promoted} reverified=${reverified}`;
}

// qa_store_calibration's JSON line as its `$(...)` caller read it, and its
// status: awk's, or 0 when either file is no regular file.
export function qaStoreCalibration(hist: string, labels: string): { status: number; out: string } {
  if (!isFile(hist) || !isFile(labels)) return { status: 0, out: `{"n":0,"agreement":null,"kappa":null,"computed_at":"${iso()}"}` };
  const r = run(["awk", "-F\\t", "-v", `at=${iso()}`, CALIBRATION_AWK, argv(labels), argv(hist)], "inherit");
  return { status: r.status, out: subst(r.out) };
}
