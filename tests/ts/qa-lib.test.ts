// qa-lib.test.ts - src/qa-lib.ts held to the frozen tests/fixtures/ac-qa-lib.sh
// functions it twins, which the frozen tests/fixtures/ac-qa.sh and ac-verify.sh
// keep calling: the bundle (QB rows), the test-plan manifest render and validate (QM, QV), the receipt
// timestamp (QT), the coverage ladder (QC), the ship receipt status (QS), the
// runtime receipt and gate (QR, QG), the tier/boundary table (QH), the path
// identity (QP), the receipt path (QK), the browser manifest (QW), the
// boundary receipt (QX) and the store learning loop - the case body hash (QD),
// the history append (QI), the promotion (QO) and the calibration (QL). Also
// src/lib.ts's yamlKeys/yamlHas held to tests/fixtures/ac-pipeline-lib.sh (QY) and its
// knowledgeScopes to bin/ac-lib.sh's ac_knowledge_scopes (QN), the two qa
// readers src/qa.ts calls beside them. Every reachable refusal of each
// validator has a row; bundle refusals no input reaches (the store or ship dir
// as a link, which the symlink sweep refuses first; an unsafe store entry
// path, which the inventory comparison refuses first) and the full-flow case
// that is not passing (the coverage loop refuses it first) have none, nor does
// the calibration's kappa of 0.0 for pe == 1 (pe is 1 only when every pair
// agrees).
//
// DISPUTED: the implementation of each twin (the bash vs src/qa-lib.ts or src/lib.ts)
// HELD-CONSTANT: one side root per side and row, seeded alike by the same bash snippet over the same seed library (a profile bundle, a git repo with fixed commit dates, a test plan, a QA run dir, a store's plan, ledger and history); argv; env (PATH = the host's bun, jq and git, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq - the store rows put a date stub answering one instant first; LC_ALL=C unless a row names a locale; HOME and TMPDIR the test root; SIDE the side root; AC_HOME only where a row names it); cwd (the distro root); stdin (/dev/null); stdout, stderr and the status (the side root spelled S) and the side root's world after the call - every path with its mode and bytes - compared whole. A row naming a shell-own line asserts it on the bash side and drops it there before the comparison (the twin writes none: SHELL-OWN STDERR); a row naming awk's own lines does the same with them.
import { afterAll, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { retiredBin } from "./retired-bin.ts";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const RBIN = retiredBin();
const QA = join(ROOT, "src", "qa-lib.ts");
const LIB = join(ROOT, "src", "lib.ts");
const ROOTUSER = process.getuid?.() === 0;
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-qa-lib-ts-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["herdr", "orca", "docker", "codegraph", "jq", "git"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["bun", "jq", "git"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const PATH = `${TOOLS}:${BASE}`;
const SHA = "1111111111111111111111111111111111111111";
// The store rows' clock: both sides read one instant through date(1).
const DATESTUB = join(W, "datestub");
mkdirSync(DATESTUB);
writeFileSync(
  join(DATESTUB, "date"),
  '#!/bin/sh\ncase "$*" in\n  "-u +%Y-%m-%d") echo 2026-10-10 ;;\n  "-u +%Y-%m-%dT%H:%M:%SZ") echo 2026-10-10T12:00:00Z ;;\n  *) exec /bin/date "$@" ;;\nesac\n',
  { mode: 0o755 },
);
const DATE_PATH = `${DATESTUB}:${PATH}`;

// The seed library every row's seed sources: SIDE is the side root.
const SEEDLIB = join(W, "seedlib.sh");
writeFileSync(
  SEEDLIB,
  String.raw`
SHA=${SHA}
sha() { shasum -a 256 <"$1" | awk '{print $1}'; }
# store_manifest <bundle> - the store manifest from the store's own files
store_manifest() {
  local b="$1" f e="[]"
  while IFS= read -r f; do
    e="$(jq -c --arg p "$f" --arg s "$(sha "$b/store/$f")" '. + [{path:$p,sha256:$s}]' <<<"$e")"
  done < <(cd "$b/store" && find . -type f ! -path ./manifest.json | sed 's#^\./##' | LC_ALL=C sort)
  jq -n --argjson e "$e" '{schema:"agentcrew.qa-store-snapshot/v1",entries:$e}' >"$b/store/manifest.json"
}
# snap <bundle> - every snapshot hash; phash <bundle> - the canonical profile hash
snap() {
  local b="$1"
  jq --arg c "$(sha "$b/config.yaml")" --arg s "$(sha "$b/scopes.tsv")" --arg m "$(sha "$b/store/manifest.json")" --arg r "$(sha "$b/ship/test-receipt.env")" \
    '.snapshots.config_sha256=$c | .snapshots.scopes_sha256=$s | .snapshots.store_manifest_sha256=$m | .snapshots.ship_test_receipt_sha256=$r' "$b/profile.json" >"$b/p.tmp"
  mv "$b/p.tmp" "$b/profile.json"
}
phash() {
  local b="$1" h
  h="$(jq -S 'del(.profile_sha256,.provenance.resolved_at,.provenance.project_config_path,.provenance.repo_knowledge_path,.e2e.repo_path)' "$b/profile.json" | shasum -a 256 | awk '{print $1}')"
  jq --arg h "$h" '.profile_sha256=$h' "$b/profile.json" >"$b/p.tmp"
  mv "$b/p.tmp" "$b/profile.json"
}
refresh() { store_manifest "$1"; snap "$1"; phash "$1"; }
# mk_bundle <dir> [<source-sha>] - a valid immutable profile bundle
mk_bundle() {
  local b="$1" src="${"$"}{2:-$SHA}"
  mkdir -p "$b/store" "$b/ship"
  printf 'qa:\n  serve: "true"\n  health: "true"\n' >"$b/config.yaml"
  : >"$b/scopes.tsv"
  printf 'schema=agentcrew.ship-test-receipt/v1\nsource_sha=%s\nqualification=qualifies\nreason=executed\nship_run=fixture\ncommand_sha256=c\noutput_sha256=o\nstarted_at=2026-07-24T00:00:00Z\ncompleted_at=2026-07-24T00:00:05Z\nexit_code=0\n' "$src" >"$b/ship/test-receipt.env"
  printf 'one\n' >"$b/store/data.txt"
  jq -n --arg src "$src" '{schema:"agentcrew.qa-profile/v1",profile_key:"p/s/a",project:"p",source:{repo:"p",ref:$src},service:{serve:"true",health:"true"},provenance:{project_config_path:"x",resolved_at:"2026-07-24T00:00:00Z"},snapshots:{config_file:"config.yaml",scopes_file:"scopes.tsv",store_manifest_file:"store/manifest.json",ship_test_receipt_file:"ship/test-receipt.env"}}' >"$b/profile.json"
  refresh "$b"
}
# sedset <file> <expression> - rewrite a file through sed
sedset() { sed "$2" "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }
# jqset <file> <program> - rewrite a JSON file through jq
jqset() { jq "$2" "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }
# mk_repo <dir> - the source repo: a regular test, an executable one, a link to
# a file and a link to a directory, at one commit with fixed dates; its sha in
# <dir>.sha
mk_repo() {
  local r="$1"
  git init -q -b main "$r"
  mkdir -p "$r/tests/deep"
  printf 'test\n' >"$r/tests/unit.test.ts"
  printf '#!/bin/sh\n' >"$r/tests/exec.sh"
  chmod +x "$r/tests/exec.sh"
  printf 'deep\n' >"$r/tests/deep/d.test.ts"
  ln -s unit.test.ts "$r/tests/link.ts"
  ln -s tests "$r/linkdir"
  git -C "$r" add -A
  GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$r" rev-parse HEAD >"$r.sha"
}
# The plan every QM/QC row starts from.
PLAN='# Plan

## Coverage

coverage: AC-1 | ut | tests/unit.test.ts#works | -
coverage: AC-2 | it | - | case-api
coverage: AC-3 | e2e | - | case-web

${"```"}
coverage: AC-9 | ut | ignored/in/a/fence.ts | -
${"```"}

## Full Flow

full-flow: case-web
'
# mk_run <run> <repo> - a QA run whose frozen manifest, ship receipt and ledger
# satisfy the plan: case-api completes before case-web starts.
mk_run() {
  local run="$1" repo="$2" tsha
  tsha="$(cat "$repo.sha")"
  mkdir -p "$run/profile/ship" "$run/boundaries/case-api" "$run/boundaries/case-web"
  printf '%s' "$PLAN" >"$SIDE/plan.md"
  ( . "$BIN/ac-lib.sh"; . "$BIN/ac-pipeline-lib.sh"; . "$BIN/ac-qa-lib.sh"; ac_qa_testplan_manifest_render "$repo" "$tsha" "$SIDE/plan.md" ) >"$run/testplan-manifest.json"
  printf 'testplan_path=%s\ntestplan_manifest_sha256=%s\n' "$SIDE/plan.md" "$(sha "$run/testplan-manifest.json")" >"$run/run.meta"
  printf 'schema=agentcrew.ship-test-receipt/v1\nsource_sha=%s\nqualification=qualifies\nreason=executed\ncommand_sha256=c\noutput_sha256=o\nstarted_at=s\ncompleted_at=e\nexit_code=0\n' "$tsha" >"$run/profile/ship/test-receipt.env"
  printf 'started_at=2026-01-01T00:00:00Z\ncompleted_at=2026-01-01T00:01:00Z\n' >"$run/boundaries/case-api/receipt.env"
  printf 'started_at=2026-01-01T00:02:00Z\ncompleted_at=2026-01-01T00:03:00Z\n' >"$run/boundaries/case-web/receipt.env"
  row case-api api pass http "$run/boundaries/case-api/receipt.env" >"$run/cases.tsv"
  row case-web web pass web "$run/boundaries/case-web/receipt.env" >>"$run/cases.tsv"
}
# row <id> <tier> <status> <boundary> <receipt> - one 12-column ledger row
row() { printf '%s\t%s\t%s\tg\tc\t-\tr\tn\te\tv\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
# The store loop's fixtures: a test plan holding three case rows (padded
# cells, a numeric id); crow <id> <tier> <status> <class> - a ledger row;
# hrow <sha> <case> <status> <class> <body> - a history row; bodysha <id> -
# the bash's own body hash; hl <sha> <case> <status> <class> and
# ll <sha> <case> <label> - the calibration's history and label rows.
mk_plan() {
  printf '%s\n' \
    '| id | title | tier | n | precondition | steps | expected | surface |' \
    '| C-1 | login | api | - | user exists | POST /login | 200 | http |' \
    '|  C-2  |  list  |  web  | - |  logged in  |  open /list  |  rows  |  browser  |' \
    '| 1 | numeric | db | - | p | s | e | sql |' >"$SIDE/plan.md"
}
crow() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
hrow() { printf '%s\t2026-01-01\t%s\tapi\t%s\t%s\t%s\tm\tt\n' "$1" "$2" "$3" "$4" "$5" >>"$SIDE/store/history.tsv"; }
bodysha() { ( . "$BIN/ac-lib.sh"; . "$BIN/ac-pipeline-lib.sh"; . "$BIN/ac-qa-lib.sh"; qa_store_case_body_sha "$SIDE/plan.md" "$1" ); }
hl() { printf '%s\t2026-01-01\t%s\tapi\t%s\t%s\tb\tm\tt\n' "$1" "$2" "$3" "$4" >>"$SIDE/h.tsv"; }
ll() { printf '%s\t%s\t%s\tchief\t2026-01-01T00:00:00Z\n' "$1" "$2" "$3" >>"$SIDE/l.tsv"; }
`,
);

type Row = {
  bash: string;
  twin: string;
  args?: string[];
  seed?: string;
  env?: Record<string, string>;
  // the bash's own shell writes `<file>.sh: line N: ...` lines here
  shell?: boolean;
  // ...and awk its own lines, matching this
  own?: RegExp;
};
type Side = { out: string; err: string; world: string; status: number | null };

function world(s: string): string {
  const lines: string[] = [];
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      const st = lstatSync(p);
      const rel = p.slice(s.length);
      if (st.isSymbolicLink()) lines.push(`${rel} -> ${readlinkSync(p)}`);
      else if (st.isDirectory()) {
        lines.push(`${rel}/ ${(st.mode & 0o7777).toString(8)}`);
        if (name === ".git") continue;
        try {
          walk(p);
        } catch {
          lines.push(`${rel}/<unlistable>`);
        }
      } else {
        let body = "<unreadable>";
        try {
          body = readFileSync(p, "latin1");
        } catch {}
        lines.push(`${rel} ${(st.mode & 0o7777).toString(8)}\n${body}`);
      }
    }
  };
  walk(s);
  return lines.join("\n");
}

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-pipeline-lib.sh" || exit $?; . "$0/ac-qa-lib.sh" || exit $?; S="$SIDE"; rc=0; ${row.bash}`, RBIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { readFileSync, writeSync } from "node:fs"; const Q = await import(${JSON.stringify(QA)}); const L = await import(${JSON.stringify(LIB)}); const lat = (s) => Buffer.from(s, "utf8").toString("latin1"); const A = ${JSON.stringify(args)}.map(lat); const S = lat(process.env.SIDE); const out = (b) => writeSync(1, typeof b === "string" ? Buffer.from(b, "latin1") : b); const said = (e) => out(e === null ? "#0" : "#1" + e); ${row.twin}`,
      ];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 60000 });
  const norm = (t: string): string => t.replaceAll(s, "S");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode };
}

// Both sides of a row, seeded alike and run: the oracle's and the twin's
// results and side roots.
function pair(label: string, row: Row): { o: Side; t: Side; so: string; st: string } {
  const root = join(W, `r${rows++}`);
  const got: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    mkdirSync(s, { recursive: true });
    if (row.seed) {
      const r = Bun.spawnSync(["/bin/bash", "-c", `set -e; . "$SEEDLIB"; ${row.seed}`], {
        cwd: s,
        env: { PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s, SEEDLIB, BIN: RBIN },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
        timeout: 60000,
      });
      if (r.exitCode !== 0) throw new Error(`seed failed for ${label}: ${r.stderr.toString()}`);
    }
    got.push(side(row, s, name === "o"));
  }
  return { o: got[0]!, t: got[1]!, so: join(root, "o"), st: join(root, "t") };
}

function same(label: string, row: Row): Side {
  const { o, t } = pair(label, row);
  for (const own of [row.shell ? /\.sh: line [0-9]+: / : null, row.own ?? null]) {
    if (own === null) continue;
    expect(o.err).toMatch(own);
    o.err = o.err
      .split("\n")
      .filter((l) => !own.test(l))
      .join("\n");
  }
  const view = (x: Side) => ({ label, out: x.out, err: x.err, status: x.status, world: x.world });
  expect(view(t)).toEqual(view(o));
  return o;
}

const kvFile = (file: string, kv: Record<string, string>): string =>
  `: >${file}; ${Object.entries(kv)
    .filter(([, v]) => v !== "<absent>")
    .map(([k, v]) => `printf '%s=%s\\n' '${k}' '${v}' >>${file}`)
    .join("; ")}`;

// A validator row: the bash's `#<rc><its error variable>` beside the twin's
// `#0` (null) or `#1<error>`.
const validator = (fn: string, errVar: string, twinFn: string) => (label: string, args: string[], seed?: string, env?: Record<string, string>, shell = false): Side =>
  same(label, {
    args,
    seed,
    env,
    shell,
    bash: `${fn} "$@" || rc=$?; printf '#%s%s' "$rc" "\${${errVar}-}"`,
    twin: `said(Q.${twinFn}(...A));`,
  });

// --- QB: ac_qa_bundle_validate -----------------------------------------------
const bundle = validator("ac_qa_bundle_validate", "AC_QA_BUNDLE_ERROR", "qaBundleValidate");
const B = ["@S/b/profile.json", SHA];

test("QB: a valid bundle, with a fixture pack, a runtime.json and a routing receipt", () => {
  expect(bundle("valid", B, "mk_bundle b").out).toBe("#0");
  bundle("a fixture pack", B, `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1","runner":"run.sh","selectors":["s"],"capabilities":[],"mutation":"read-only","retry":"read-only","assets":["a/x.txt"]}' >b/store/fixtures/p1/manifest.json; printf x >b/store/fixtures/p1/run.sh; mkdir -p b/store/fixtures/p1/a; printf y >b/store/fixtures/p1/a/x.txt; refresh b`);
  bundle("a runtime.json root entry", B, "mk_bundle b; printf '{}' >b/runtime.json");
  bundle("a default routing receipt", B, `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:"default",use:{harness:"codex",model:"m",effort:"high"},dispatch_sha256:"${"a".repeat(64)}"}'; phash b`);
  bundle("a numbered routing receipt", B, `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:2,when:"w",why:"y",use:{harness:"codex",model:"",effort:""},dispatch_sha256:"${"a".repeat(64)}"}'; phash b`);
}, 120000);

test("QB: every reachable refusal, in the bash's order", () => {
  bundle("the file is not profile.json", ["@S/b/other.json", SHA], "mk_bundle b; cp b/profile.json b/other.json");
  bundle("no bundle directory", ["@S/nope/profile.json", SHA]);
  bundle("a spelling that is not the fixed path", ["@S/b/./profile.json", SHA], "mk_bundle b");
  bundle("a path through a linked directory", ["@S/link/profile.json", SHA], "mk_bundle b; ln -s b link");
  bundle("a symlink inside", B, "mk_bundle b; ln -s data.txt b/store/l");
  bundle("an unknown root entry", B, "mk_bundle b; : >b/extra");
  bundle("a root entry whose name holds a LF", B, "mk_bundle b; : >\"b/x\nconfig.yaml\"");
  bundle("the store is a file", B, "mk_bundle b; rm -r b/store; : >b/store");
  bundle("no ship dir", B, "mk_bundle b; rm -r b/ship");
  bundle("no config", B, "mk_bundle b; rm b/config.yaml");
  bundle("no store manifest", B, "mk_bundle b; rm b/store/manifest.json");
  bundle("a profile off its schema", B, "mk_bundle b; jqset b/profile.json '.schema=\"x\"'");
  bundle("a routing rule of 0", B, `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:0,when:"w",why:"y",use:{harness:"codex",model:"",effort:""},dispatch_sha256:"${"a".repeat(64)}"}'`);
  bundle("a default rule carrying when", B, `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:"default",when:"w",use:{harness:"codex",model:"",effort:""},dispatch_sha256:"${"a".repeat(64)}"}'`);
  bundle("another source sha", ["@S/b/profile.json", "2222222222222222222222222222222222222222"], "mk_bundle b");
  bundle("a changed config", B, "mk_bundle b; printf '# x\\n' >>b/config.yaml");
  bundle("a changed scope map", B, "mk_bundle b; printf 's\\ta\\n' >>b/scopes.tsv");
  bundle("a changed store manifest", B, "mk_bundle b; jqset b/store/manifest.json '.extra=1'");
  bundle("a changed ship receipt", B, "mk_bundle b; printf 'x=1\\n' >>b/ship/test-receipt.env");
  bundle("a ship receipt of another schema", B, "mk_bundle b; sedset b/ship/test-receipt.env 's/^schema=.*/schema=other/'; snap b; phash b");
  bundle("a ship receipt of another sha", B, "mk_bundle b; sedset b/ship/test-receipt.env 's/^source_sha=.*/source_sha=2222/'; snap b; phash b");
  bundle("an invalid store manifest", B, "mk_bundle b; printf '{\"schema\":\"x\"}' >b/store/manifest.json; snap b; phash b");
  bundle("an unlisted store file", B, "mk_bundle b; printf 'two\\n' >b/store/more.txt");
  bundle("a listed file whose @tsv spelling names no file", B, "mk_bundle b; printf 'x\\n' >'b/store/a\\b.txt'; refresh b");
  bundle("a store file changed after the manifest", B, "mk_bundle b; printf 'changed\\n' >b/store/data.txt");
  bundle("an invalid fixture pack", B, `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1"}' >b/store/fixtures/p1/manifest.json; refresh b`);
  bundle("an unsafe fixture-pack path", B, `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1","runner":"../run.sh","selectors":["s"],"capabilities":[],"mutation":"read-only","retry":"read-only"}' >b/store/fixtures/p1/manifest.json; refresh b`);
  bundle("a missing fixture-pack file", B, `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1","runner":"run.sh","selectors":["s"],"capabilities":[],"mutation":"read-only","retry":"read-only"}' >b/store/fixtures/p1/manifest.json; refresh b`);
  bundle("a profile changed after its hash", B, "mk_bundle b; jqset b/profile.json '.profile_key=\"p/s/b\"'");
}, 120000);

test.skipIf(ROOTUSER)("QB: an unreadable ship receipt hashes as nothing", () => {
  bundle("unreadable", B, "mk_bundle b; chmod 000 b/ship/test-receipt.env", undefined, true);
}, 120000);

// --- QM / QV: ac_qa_testplan_manifest_render / _validate ----------------------
const render = (label: string, seed: string, args = ["@S/r", "=SHA", "@S/plan.md"], env?: Record<string, string>): Side =>
  same(label, {
    seed,
    args,
    env,
    bash: 'for i in 1 2 3; do [ "${!i}" != =SHA ] || set -- "${@:1:$((i - 1))}" "$(cat "$S/r.sha")" "${@:$((i + 1))}"; done; ac_qa_testplan_manifest_render "$@" || rc=$?; printf \'#%s%s\' "$rc" "${AC_QA_MANIFEST_ERROR-}"',
    twin: 'const a = A.map((x) => (x === "=SHA" ? readFileSync(S + "/r.sha", "latin1").trim() : x)); const r = Q.qaTestplanManifestRender(a[0], a[1], a[2]); out(r.out); out("#" + r.status + r.error);',
  });
const plan = (label: string, text: string): Side => render(label, `mk_repo r; cat >plan.md <<'EOF'\n${text}\nEOF`);
const PLAN = (cov: string, flow = "full-flow: case-web"): string => `## Coverage\n${cov}\n## Full Flow\n${flow}`;
const COV = "coverage: AC-1 | ut | tests/unit.test.ts#works | -\ncoverage: AC-3 | e2e | - | case-web";

test("QM: the canonical manifest of a test plan", () => {
  expect(render("the seed plan", 'mk_repo r; printf \'%s\' "$PLAN" >plan.md').out).toContain('"full_flow":["case-web"]');
  plan("an executable test", PLAN(`coverage: AC-1 | ut | tests/exec.sh | -\n${COV}`));
  plan("a nested test", PLAN(`coverage: AC-1 | ut | tests/deep/d.test.ts#x | -\n${COV}`));
}, 120000);

test("QM: the parser's own refusals, its lines and the declarations before them in one text", () => {
  plan("no space after coverage:", PLAN(`coverage:AC-1 | ut | t | -\n${COV}`));
  plan("three fields", PLAN(`coverage: AC-1 | ut | t\n${COV}`));
  plan("a padded field", PLAN(`coverage: AC-1 |  ut | t | -\n${COV}`));
  plan("a bad AC id", PLAN(`coverage: A..1 | ut | t | -\n${COV}`));
  plan("a bad rung", PLAN(`coverage: AC-1 | unit | t | -\n${COV}`));
  plan("a UT row with a case", PLAN(`coverage: AC-1 | ut | t | case-x\n${COV}`));
  plan("an IT row with a test", PLAN(`coverage: AC-2 | it | t | case-x\n${COV}`));
  plan("a duplicate", PLAN(`${COV}\n${COV}`));
  plan("a full-flow without its space", PLAN(COV, "full-flow:case-web"));
  plan("a bad full-flow id", PLAN(COV, "full-flow: a..b"));
  plan("a duplicate full-flow", PLAN(COV, "full-flow: case-web\nfull-flow: case-web"));
  plan("an unterminated fence", `${PLAN(COV)}\n${"```"}`);
  plan("two coverage sections", `${PLAN(COV)}\n## Coverage\n${COV}`);
  plan("no full-flow section", `## Coverage\n${COV}`);
  plan("no coverage line", PLAN(""));
  plan("no full-flow line", PLAN(COV, ""));
  plan("a full-flow case no coverage cites", PLAN(COV, "full-flow: case-x"));
  for (const loc of ["C", "en_US.UTF-8"])
    render(`a byte that is no UTF-8 (${loc})`, `mk_repo r; printf '## Coverage\\ncoverage: AC-1 | ut | t\\351.ts | -\\n${COV.replace(/\n/g, "\\n")}\\n## Full Flow\\nfull-flow: case-web\\n' >plan.md`, undefined, { LC_ALL: loc });
}, 120000);

test("QM: the UT references checked against the exact Git tree", () => {
  plan("an empty selector", PLAN(`coverage: AC-1 | ut | tests/unit.test.ts# | -\n${COV}`));
  plan("a selector holding #", PLAN(`coverage: AC-1 | ut | tests/unit.test.ts#a#b | -\n${COV}`));
  plan("a ./ path", PLAN(`coverage: AC-1 | ut | ./tests/unit.test.ts | -\n${COV}`));
  plan("an absolute path", PLAN(`coverage: AC-1 | ut | /tests/unit.test.ts | -\n${COV}`));
  plan("a .. step", PLAN(`coverage: AC-1 | ut | tests/../tests/unit.test.ts | -\n${COV}`));
  plan("an empty step", PLAN(`coverage: AC-1 | ut | tests//unit.test.ts | -\n${COV}`));
  plan("a trailing slash", PLAN(`coverage: AC-1 | ut | tests/ | -\n${COV}`));
  plan("a tree", PLAN(`coverage: AC-1 | ut | tests | -\n${COV}`));
  plan("a link", PLAN(`coverage: AC-1 | ut | tests/link.ts | -\n${COV}`));
  plan("a missing file", PLAN(`coverage: AC-1 | ut | tests/none.ts | -\n${COV}`));
  plan("a missing parent", PLAN(`coverage: AC-1 | ut | none/unit.test.ts | -\n${COV}`));
  plan("a linked parent", PLAN(`coverage: AC-1 | ut | linkdir/unit.test.ts | -\n${COV}`));
  render("no such commit", 'mk_repo r; printf \'%s\' "$PLAN" >plan.md', ["@S/r", "2222222222222222222222222222222222222222", "@S/plan.md"]);
  render("no source repo", 'mk_repo r; printf \'%s\' "$PLAN" >plan.md', ["@S/none", "=SHA", "@S/plan.md"]);
  render("no plan", "mk_repo r", ["@S/r", "=SHA", "@S/none.md"]);
}, 120000);

const validate = (label: string, seed: string, manifestSha = "=MSHA"): Side =>
  same(label, {
    seed: `mk_repo r; printf '%s' "$PLAN" >plan.md; ( . "$BIN/ac-lib.sh"; . "$BIN/ac-pipeline-lib.sh"; . "$BIN/ac-qa-lib.sh"; ac_qa_testplan_manifest_render "$SIDE/r" "$(cat r.sha)" "$SIDE/plan.md" ) >m.json; sha m.json >m.sha; ${seed}`,
    args: [manifestSha],
    bash: 'm="$1"; [ "$m" != =MSHA ] || m="$(cat "$S/m.sha")"; ac_qa_testplan_manifest_validate "$S/r" "$(cat "$S/r.sha")" "$S/plan.md" "$S/m.json" "$m" || rc=$?; printf \'#%s%s\' "$rc" "${AC_QA_MANIFEST_ERROR-}"',
    twin: 'const rd = (f) => readFileSync(S + "/" + f, "latin1").trim(); const m = A[0] === "=MSHA" ? rd("m.sha") : A[0]; said(Q.qaTestplanManifestValidate(S + "/r", rd("r.sha"), S + "/plan.md", S + "/m.json", m));',
  });

test("QV: the frozen manifest re-rendered and hashed", () => {
  expect(validate("valid", ":").out).toBe("#0");
  validate("no manifest", "rm m.json");
  validate("a plan that no longer parses", "printf 'x\\n' >plan.md");
  validate("a plan changed after the freeze", "printf '\\n' >>plan.md");
  validate("an edited manifest", "printf ' ' >>m.json");
  validate("an empty expected hash", ":", "");
  validate("another expected hash", ":", "abc");
}, 120000);

// --- QT: ac_qa_timestamp_epoch -----------------------------------------------
test("QT: jq's fromdateiso8601, nothing for what it refuses", () => {
  for (const ts of ["2026-01-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-01-01T00:00:00.5Z", "2026-01-01T00:00:00+07:00", "", "x"])
    same(`stamp ${ts || "(empty)"}`, {
      args: [ts],
      bash: 'v="$(ac_qa_timestamp_epoch "$1")" || rc=1; printf \'%s#%s\' "$v" "$rc"',
      twin: 'const v = Q.qaTimestampEpoch(A[0]); out((v ?? "") + "#" + (v === null ? 1 : 0));',
    });
}, 120000);

// --- QC: ac_qa_coverage_validate ---------------------------------------------
const coverage = (label: string, seed: string): Side =>
  same(label, {
    seed: `mk_repo r; mk_run "$SIDE/run" "$SIDE/r"; ${seed}`,
    bash: 'ac_qa_coverage_validate "$S/run" "$S/r" "$(cat "$S/r.sha")" || rc=$?; printf \'#%s%s\' "$rc" "${AC_QA_MANIFEST_ERROR-}"',
    twin: 'said(Q.qaCoverageValidate(S + "/run", S + "/r", readFileSync(S + "/r.sha", "latin1").trim()));',
  });
const LEDGER = (rows: string): string => `{ ${rows}; } >run/cases.tsv`;
const API = 'row case-api api pass http "$SIDE/run/boundaries/case-api/receipt.env"';
const WEB = 'row case-web web pass web "$SIDE/run/boundaries/case-web/receipt.env"';

test("QC: the ladder against the effective ledger and the receipts' times", () => {
  expect(coverage("valid", ":").out).toBe("#0");
  coverage("an e2e case on an e2e boundary", LEDGER(`${API}; row case-web api pass e2e "$SIDE/run/boundaries/case-web/receipt.env"`));
  coverage("a ledger row ending in one TAB", `printf '%s\\t\\n' "$(${API})" >run/cases.tsv; ${WEB} >>run/cases.tsv`);
  coverage("a ledger row past 12 columns", `printf '%s\\tEXTRA\\n' "$(${API})" >run/cases.tsv; ${WEB} >>run/cases.tsv`);
}, 120000);

test("QC: every refusal, in the bash's order", () => {
  coverage("a plan changed after the freeze", "printf '\\n' >>plan.md");
  coverage("no qualifying ship receipt", "rm run/profile/ship/test-receipt.env");
  coverage("no row for an IT case", LEDGER(WEB));
  coverage("two rows for an IT case", LEDGER(`${API}; ${API}; ${WEB}`));
  coverage("a failing IT case", LEDGER(`row case-api api fail http x; ${WEB}`));
  coverage("an IT case of tier web", LEDGER(`row case-api web pass web x; ${WEB}`));
  coverage("an E2E case with no web or e2e evidence", LEDGER(`${API}; row case-web api pass http x`));
  coverage("no ledger", "rm run/cases.tsv");
  coverage("a bad started_at", "printf 'started_at=x\\ncompleted_at=2026-01-01T00:01:00Z\\n' >run/boundaries/case-api/receipt.env");
  coverage("a bad completed_at", "printf 'started_at=2026-01-01T00:00:00Z\\n' >run/boundaries/case-api/receipt.env");
  coverage("completed before started", "printf 'started_at=2026-01-01T00:05:00Z\\ncompleted_at=2026-01-01T00:01:00Z\\n' >run/boundaries/case-api/receipt.env");
  coverage("a full-flow case of another tier", LEDGER(`${API}; row case-web foo pass e2e "$SIDE/run/boundaries/case-web/receipt.env"`));
  coverage("the final group started before a component completed", "printf 'started_at=2026-01-01T00:00:00Z\\ncompleted_at=2026-01-01T00:10:00Z\\n' >run/boundaries/case-api/receipt.env");
  coverage("awk's numeric match finds a row the ledger read does not name", `PLAN="$(printf '%s' "$PLAN" | sed 's/case-web/1/g')"; mk_run "$SIDE/run" "$SIDE/r"; ${LEDGER(`${API}; row 01 web pass web "$SIDE/run/boundaries/case-web/receipt.env"`)}`);
}, 120000);

// --- QS: ac_qa_ship_receipt_status -------------------------------------------
const RECEIPT = (o: Record<string, string>): string =>
  kvFile("rcpt.env", { schema: "agentcrew.ship-test-receipt/v1", source_sha: SHA, qualification: "qualifies", reason: "executed", exit_code: "0", command_sha256: "c", output_sha256: "o", started_at: "s", completed_at: "e", ...o });
const ship = (label: string, seed: string, args = ["@S/rcpt.env", SHA]): Side =>
  same(label, {
    seed,
    args,
    bash: 'ac_qa_ship_receipt_status "$@"; printf \'#%s\' "$?"',
    twin: 'out(Q.qaShipReceiptStatus(A[0], A[1]) + "\\n#0");',
  });

test("QS: one closed qualification answer per receipt", () => {
  expect(ship("executed", RECEIPT({})).out).toBe("qualifies:executed\n#0");
  ship("an execution attestation", RECEIPT({ reason: "execution-attestation" }));
  ship("no receipt", ":");
  ship("an empty path", ":", ["", SHA]);
  ship("another schema", RECEIPT({ schema: "x" }));
  ship("an unknown reason", RECEIPT({ reason: "lucky" }));
  ship("another sha", RECEIPT({ source_sha: "2222" }));
  ship("no sha asked for", RECEIPT({}), ["@S/rcpt.env", ""]);
  ship("executed but not qualifying", RECEIPT({ qualification: "not-qualifies" }));
  ship("scoped", RECEIPT({ qualification: "not-qualifies", reason: "scoped" }));
  ship("qualifying for a non-execution reason", RECEIPT({ reason: "absent" }));
  ship("a non-zero exit", RECEIPT({ exit_code: "1" }));
  ship("an exit of 00", RECEIPT({ exit_code: "00" }));
  ship("a command hash of -", RECEIPT({ command_sha256: "-" }));
  ship("no completed_at", RECEIPT({ completed_at: "<absent>" }));
}, 120000);

test.skipIf(ROOTUSER)("QS: an unreadable receipt is invalid, its warning said", () => {
  ship("unreadable", `${RECEIPT({})}; chmod 000 rcpt.env`);
}, 120000);

// --- QR / QG: ac_qa_runtime_receipt_validate / ac_qa_runtime_gate_validate ---
const runtime = validator("ac_qa_runtime_receipt_validate", "AC_QA_RECEIPT_ERROR", "qaRuntimeReceiptValidate");
const RT_ARGS = ["@S/rt.env", "src", "prof", "serve", "health", "desc"];
const RT = (o: Record<string, string>): string =>
  kvFile("rt.env", { schema: "agentcrew.qa-runtime-receipt/v1", source_sha: "src", profile_sha256: "prof", serve_command_sha256: "serve", health_command_sha256: "health", runtime_descriptor_sha256: "desc", serve_started_at: "t0", health_completed_at: "t1", process_group: "123", ...o });

test("QR: the boot receipt's shape, schema and identity", () => {
  expect(runtime("valid", RT_ARGS, RT({})).out).toBe("#0");
  runtime("a process group of 00", RT_ARGS, RT({ process_group: "00" }));
  runtime("missing", RT_ARGS);
  for (const [k, v] of [
    ["schema", "x"],
    ["source_sha", "x"],
    ["profile_sha256", "x"],
    ["serve_command_sha256", "x"],
    ["health_command_sha256", "x"],
    ["runtime_descriptor_sha256", "x"],
    ["serve_started_at", "<absent>"],
    ["health_completed_at", "<absent>"],
    ["process_group", "0"],
    ["process_group", ""],
    ["process_group", "12a"],
  ] as const)
    runtime(`${k}=${v}`, RT_ARGS, RT({ [k]: v }));
}, 120000);

const gate = validator("ac_qa_runtime_gate_validate", "AC_QA_RECEIPT_ERROR", "qaRuntimeGateValidate");
const GT_ARGS = ["@S/gate.env", "src", "prof", "rsha", "health", "123"];
const GT = (o: Record<string, string>): string =>
  kvFile("gate.env", { schema: "agentcrew.qa-runtime-gate/v1", source_sha: "src", profile_sha256: "prof", runtime_receipt_sha256: "rsha", health_command_sha256: "health", process_group: "123", alive: "1", health_exit_code: "0", validated_at: "t", ...o });

test("QG: the final live-process record", () => {
  expect(gate("valid", GT_ARGS, GT({})).out).toBe("#0");
  gate("missing", GT_ARGS);
  for (const [k, v] of [
    ["schema", "x"],
    ["source_sha", "x"],
    ["profile_sha256", "x"],
    ["runtime_receipt_sha256", "x"],
    ["health_command_sha256", "x"],
    ["process_group", "124"],
    ["alive", "0"],
    ["health_exit_code", "1"],
    ["validated_at", "<absent>"],
  ] as const)
    gate(`${k}=${v}`, GT_ARGS, GT({ [k]: v }));
}, 120000);

// --- QH: ac_qa_boundary_coherent ---------------------------------------------
test("QH: the closed tier/boundary table", () => {
  const tiers = ["api", "db", "workflow", "web", "e2e", "constructor"];
  const boundaries = ["http", "grpc", "client-cli", "workflow", "queue", "schedule", "web", "e2e"];
  const o = same("every pair", {
    args: [tiers.join(","), boundaries.join(",")],
    bash: 'IFS=, read -ra T <<<"$1"; IFS=, read -ra B <<<"$2"; for t in "${T[@]}" ""; do for b in "${B[@]}" ""; do ac_qa_boundary_coherent "$t" "$b" && printf "%s:%s=0\\n" "$t" "$b" || printf "%s:%s=1\\n" "$t" "$b"; done; done',
    twin: 'const T = [...A[0].split(","), ""]; const B = [...A[1].split(","), ""]; for (const t of T) for (const b of B) out(`${t}:${b}=${Q.qaBoundaryCoherent(t, b) ? 0 : 1}\\n`);',
  });
  expect(o.out).toContain("web:web=0");
  expect(o.out).toContain("web:http=1");
}, 120000);

// --- QP: ac_qa_path_sha ------------------------------------------------------
const pathSha = (label: string, seed: string, path: string, shell = false): Side =>
  same(label, { seed, shell, args: [path], bash: 'printf \'[%s]\' "$(ac_qa_path_sha "$1")"', twin: 'out("[" + Q.qaPathSha(A[0]) + "]");' });

test("QP: a file's hash, a directory's manifest hash", () => {
  pathSha("a file", "printf 'A' >f", "@S/f");
  pathSha("a directory", "mkdir -p d/b d/.h; printf A >d/a; printf 'C\\n' >d/b/c; printf H >d/.h/x; printf Z >d/Z", "@S/d");
  pathSha("an empty directory", "mkdir d", "@S/d");
  pathSha("a link to a directory", "mkdir d; printf A >d/a; ln -s d l", "@S/l");
  pathSha("a directory holding a link", "mkdir d; printf A >d/a; ln -s a d/l", "@S/d");
  pathSha("a missing path", ":", "@S/none", true);
}, 120000);

test.skipIf(ROOTUSER)("QP: what it cannot read hashes as nothing", () => {
  pathSha("an unreadable file", "printf A >f; chmod 000 f", "@S/f", true);
  pathSha("an unreadable file in a directory", "mkdir d; printf A >d/a; printf B >d/b; chmod 000 d/b", "@S/d", true);
  pathSha("a directory it cannot enter", "mkdir d; printf A >d/a; chmod 000 d", "@S/d", true);
}, 120000);

// --- QK: ac_qa_receipt_path_ok -----------------------------------------------
const receiptPath = (label: string, seed: string, args: string[]): Side =>
  same(label, {
    seed,
    args,
    bash: 'ac_qa_receipt_path_ok "$@" || rc=$?; printf \'#%s\' "$rc"',
    twin: 'out("#" + (Q.qaReceiptPathOk(A[0], A[1], A[2]) ? 0 : 1));',
  });
const RK = "mkdir -p run/boundaries/c1 other; printf r >run/boundaries/c1/r.env; printf r >other/r.env";

test("QK: a regular receipt whose parent is the case's own boundary dir", () => {
  receiptPath("valid", RK, ["@S/run", "c1", "@S/run/boundaries/c1/r.env"]);
  receiptPath("through ..", RK, ["@S/run", "c1", "@S/run/boundaries/c1/../c1/r.env"]);
  receiptPath("another dir", RK, ["@S/run", "c1", "@S/other/r.env"]);
  receiptPath("a link", `${RK}; ln -s ../../../other/r.env run/boundaries/c1/l.env`, ["@S/run", "c1", "@S/run/boundaries/c1/l.env"]);
  receiptPath("a linked case dir", `${RK}; ln -s ../../other run/boundaries/c2`, ["@S/run", "c2", "@S/run/boundaries/c2/r.env"]);
  receiptPath("a directory", RK, ["@S/run", "boundaries", "@S/run/boundaries/c1"]);
  receiptPath("-", RK, ["@S/run", "c1", "-"]);
  receiptPath("an empty case id", RK, ["@S/run", "", "@S/run/boundaries/c1/r.env"]);
  receiptPath("missing", RK, ["@S/run", "c1", "@S/run/boundaries/c1/none.env"]);
}, 120000);

// --- QW: ac_qa_browser_manifest_ok -------------------------------------------
const browser = validator("ac_qa_browser_manifest_ok", "AC_QA_RECEIPT_ERROR", "qaBrowserManifestOk");
const QW = (o: { visual?: string; tsv?: string; extra?: string } = {}): string =>
  [
    "mkdir -p run/boundaries/c1 shots",
    "printf PNG >shots/v.png",
    `printf 'visual %s\\n' "${o.visual ?? "$(sha shots/v.png)"}" >run/boundaries/c1/b.manifest`,
    `printf 'evidence_sha256=%s\\n' "$(sha run/boundaries/c1/b.manifest)" >rcpt.env`,
    o.tsv ?? `printf '%s\\tx\\ty\\tc1\\tz\\n' "$SIDE/shots/v.png" >run/visuals.tsv`,
    o.extra ?? ":",
  ].join("; ");
const BW = ["@S/run", "c1", "@S/rcpt.env"];

test("QW: a browser receipt's manifest and screenshot still hash as registered", () => {
  expect(browser("valid", BW, QW()).out).toBe("#0");
  browser("a second manifest first in order", BW, QW({ extra: "printf 'visual x\\n' >run/boundaries/c1/a.manifest" }));
  browser("no manifest", BW, QW({ extra: "rm run/boundaries/c1/b.manifest" }));
  browser("a hidden manifest only", BW, QW({ extra: "mv run/boundaries/c1/b.manifest run/boundaries/c1/.b.manifest" }));
  browser("a manifest edited after the receipt", BW, QW({ extra: "printf 'x\\n' >>run/boundaries/c1/b.manifest" }));
  browser("no visual line", BW, `${QW({ extra: "printf 'other y\\n' >run/boundaries/c1/b.manifest" })}; printf 'evidence_sha256=%s\\n' "$(sha run/boundaries/c1/b.manifest)" >rcpt.env`);
  browser("no visuals ledger", BW, QW({ tsv: ":" }), undefined, true);
  browser("a visual of another case", BW, QW({ tsv: `printf '%s\\tx\\ty\\tc2\\tz\\n' "$SIDE/shots/v.png" >run/visuals.tsv` }));
  browser("a screenshot changed after registration", BW, QW({ extra: "printf PNG2 >shots/v.png" }));
  browser("a registered screenshot that is gone", BW, QW({ extra: "rm shots/v.png" }));
}, 120000);

// --- QX: ac_qa_boundary_receipt_validate -------------------------------------
const boundary = validator("ac_qa_boundary_receipt_validate", "AC_QA_RECEIPT_ERROR", "qaBoundaryReceiptValidate");
const QX = (o: Record<string, string>): string =>
  kvFile("b.env", { schema: "agentcrew.qa-boundary-receipt/v1", case_id: "c1", source_sha: "src", profile_sha256: "prof", runtime_receipt_sha256: "rsha", boundary: "http", driver: "command", stimulus_sha256: "st", evidence_sha256: "ev", started_at: "t0", completed_at: "t1", exit_code: "0", ...o });
const BX = (tier = "api", status = "pass", expected?: string): string[] => ["@S/b.env", "c1", tier, status, "src", "prof", "rsha", ...(expected === undefined ? [] : [expected])];

test("QX: one client-boundary receipt per terminal case", () => {
  expect(boundary("valid", BX(), QX({})).out).toBe("#0");
  boundary("a web case driven by a browser", BX("web"), QX({ boundary: "web", driver: "browser" }));
  boundary("an e2e wrapper with its upstream", BX("api"), QX({ boundary: "e2e", driver: "e2e", upstream_receipt_sha256: "up" }));
  boundary("the expected evidence", BX("api", "pass", "ev"), QX({}));
  boundary("an expected evidence of -", BX("api", "pass", "-"), QX({}));
  boundary("a failing case with a non-zero exit", BX("api", "fail"), QX({ exit_code: "1" }));
}, 120000);

test("QX: every refusal, in the bash's order", () => {
  boundary("missing", BX());
  for (const [k, v] of [
    ["schema", "x"],
    ["case_id", "c2"],
    ["source_sha", "x"],
    ["profile_sha256", "x"],
    ["runtime_receipt_sha256", "x"],
    ["boundary", "carrier-pigeon"],
    ["stimulus_sha256", "<absent>"],
    ["evidence_sha256", "<absent>"],
    ["started_at", "<absent>"],
    ["completed_at", "<absent>"],
    ["exit_code", "<absent>"],
    ["exit_code", "1a"],
    ["exit_code", "1"],
    ["exit_code", "00"],
  ] as const)
    boundary(`${k}=${v}`, BX(), QX({ [k]: v }));
  boundary("a tier its boundary cannot satisfy", BX("web"), QX({}));
  boundary("a web boundary driven by a command", BX("web"), QX({ boundary: "web", driver: "command" }));
  boundary("an http boundary driven by a browser", BX(), QX({ driver: "browser" }));
  boundary("an e2e boundary driven by a command", BX(), QX({ boundary: "e2e" }));
  boundary("an e2e wrapper binding no upstream", BX(), QX({ boundary: "e2e", driver: "e2e", upstream_receipt_sha256: "-" }));
  boundary("an evidence hash changed after publication", BX("api", "pass", "other"), QX({}));
}, 120000);

// --- QD: qa_store_case_body_sha ----------------------------------------------
const bodySha = (label: string, id: string, seed = "mk_plan", env?: Record<string, string>): Side =>
  same(label, {
    seed,
    args: [id],
    env,
    bash: 'printf \'[%s]\' "$(qa_store_case_body_sha "$S/plan.md" "$1")"',
    twin: 'out("[" + Q.qaStoreCaseBodySha(S + "/plan.md", A[0]) + "]");',
  });

test("QD: a test-plan row's body hash, - where there is none", () => {
  expect(bodySha("a row", "C-1").out).toMatch(/^\[[0-9a-f]{64}\]$/);
  bodySha("a row whose cells are padded", "C-2");
  bodySha("the header row's id", "id");
  bodySha("01 is the row of 1 to awk's ==", "01");
  bodySha("an id no row has", "C-9");
  bodySha("no plan", "C-1", ":");
  bodySha("a row holding only its id", "C-1", "printf '| C-1 |\\n' >plan.md");
  for (const loc of ["C", "en_US.UTF-8"])
    bodySha(`a byte that is no UTF-8 (${loc})`, "C-1", "printf '| C-1 | t | api | - | caf\\351 | s | e | x |\\n' >plan.md", { LC_ALL: loc });
}, 120000);

// --- QI: qa_store_history_append ---------------------------------------------
const history = (label: string, seed: string, args = ["s3", "m", "t"], env: Record<string, string> = {}, shell = false): Side =>
  same(label, {
    seed: `mk_plan; ${seed}`,
    args,
    env: { PATH: DATE_PATH, ...env },
    shell,
    bash: 'n="$(qa_store_history_append "$S/store" "$S/cases.tsv" "$S/plan.md" "$@")"; printf \'[%s]\' "$n"',
    twin: 'out("[" + Q.qaStoreHistoryAppend(S + "/store", S + "/cases.tsv", S + "/plan.md", ...A) + "]");',
  });
const LEDGER3 = "{ crow C-1 api pass g; crow C-2 web fail defect; crow 1 db pass flaky; } >cases.tsv";
const PLAN_BYTE = "printf '| C-1 | t | api | - | caf\\351 | s | e | x |\\n' >plan.md";

test("QI: one history line per ledger row this sha has not recorded", () => {
  expect(history("a fresh store", LEDGER3).out).toBe("[3]");
  history("no ledger", ":");
  history("the same sha again appends nothing", `${LEDGER3}; mkdir -p store; hrow s3 C-1 pass g x; hrow s3 C-2 fail defect x; hrow s3 1 pass flaky x`);
  history("only the rows this sha has not recorded", `${LEDGER3}; mkdir -p store; hrow s3 C-1 pass g x; hrow s2 C-2 fail defect x`);
  history("01 is the history's 1 to awk's ==", "crow 01 db pass g >cases.tsv; mkdir -p store; hrow s3 1 pass g x");
  history("an empty class, model and task read -", "crow C-1 api pass '' >cases.tsv", ["s3", "", ""]);
  history("no model or task given", "crow C-1 api pass g >cases.tsv", ["s3"]);
  history("an empty column is no field to IFS=TAB read", "printf 'C-1\\t\\tpass\\tg\\n' >cases.tsv");
  history("a blank line, a leading TAB and an unterminated last line", "printf '\\n\\tC-2\\tweb\\tpass\\nC-1\\tapi\\tpass\\tg' >cases.tsv");
  history("no plan: every body is -", `${LEDGER3}; rm plan.md`);
  history("a store that is a file: every write fails, every row counts", `${LEDGER3}; : >store`, undefined, {}, true);
  for (const loc of ["C", "en_US.UTF-8"]) history(`a plan byte that is no UTF-8 (${loc})`, `crow C-1 api pass g >cases.tsv; ${PLAN_BYTE}`, undefined, { LC_ALL: loc });
}, 120000);

// --- QO: qa_store_promote ----------------------------------------------------
const PROMOTE_BASH = 'p="$(qa_store_promote "$S/store" "$S/cases.tsv" "$S/plan.md" s3 "$@")"; printf \'[%s]\' "$p"';
const PROMOTE_TWIN = 'out("[" + Q.qaStorePromote(S + "/store", S + "/cases.tsv", S + "/plan.md", "s3", ...A) + "]");';
const promote = (label: string, seed: string, after?: string, shell = false): Side =>
  same(label, { seed: `mk_plan; mkdir -p store; ${seed}`, args: after === undefined ? [] : [after], env: { PATH: DATE_PATH }, shell, bash: PROMOTE_BASH, twin: PROMOTE_TWIN });
// passes <row>... - C-1's history rows, oldest first, "$b" its plan body's hash
const passes = (...rows: string[]): string => `b="$(bodysha C-1)"; ${rows.map((r) => `hrow ${r}`).join("; ")}`;
const RUN = "crow C-1 api pass g >cases.tsv";
const THREE = passes('s1 C-1 pass g "$b"', 's2 C-1 pass g "$b"', 's3 C-1 pass g "$b"');

test("QO: consecutive passes of one body promote a run-local case", () => {
  expect(promote("three passes in a row, the catalog started", `${RUN}; ${THREE}`).out).toBe("[promoted=1 reverified=0]");
  promote("an existing catalog appended to", `${RUN}; printf '# Case catalog\\n- X | y (z) | e | verified a b\\n' >store/catalog.md; ${THREE}`);
  promote("two passes are short of three", `${RUN}; ${passes('s2 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`);
  promote("two passes meet a promote-after of 2", `${RUN}; ${passes('s2 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`, "2");
  promote("a fail ends the streak", `${RUN}; ${passes('s1 C-1 pass g "$b"', 's2 C-1 fail defect "$b"', 's3 C-1 pass g "$b"')}`);
  promote("a flaky row neither counts nor ends it", `${RUN}; ${passes('s1 C-1 pass g "$b"', 's2 C-1 pass g "$b"', 's25 C-1 fail flaky "$b"', 's3 C-1 pass g "$b"')}`);
  promote("one sha counts once", `${RUN}; ${passes('s1 C-1 pass g "$b"', 's3 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`);
  promote("a changed body ends the streak", `${RUN}; ${passes("s1 C-1 pass g other", 's2 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`);
  promote("the run's row is no pass", `crow C-1 api fail defect >cases.tsv; ${THREE}`);
  promote("the run's pass is flaky", `crow C-1 api pass flaky >cases.tsv; ${THREE}`);
  promote("no plan: no body to match", `${RUN}; ${THREE}; rm plan.md`);
  promote("a promote-after that [ cannot compare", `${RUN}; ${THREE}`, "x", true);
  promote("no history", RUN);
  promote("no ledger", THREE);
}, 120000);

test("QO: a stored case that passed again is re-verified", () => {
  expect(
    promote(
      "its verified line and its catalog line moved",
      `mkdir -p store/cases; printf '# C-1\\nsurface: api (http)\\nverified: s1 2026-01-01\\nstatus: active\\n' >store/cases/C-1.md; printf '# Case catalog\\n- C-1 | api (http) | 200 | verified s1 2026-01-01\\n- C-10 | api (http) | 200 | verified s1 2026-01-01\\n' >store/catalog.md; hrow s1 C-1 pass g x; ${RUN}`,
    ).out,
  ).toBe("[promoted=0 reverified=1]");
  promote("no verified line: one appended, no catalog", `mkdir -p store/cases; printf '# C-1\\n' >store/cases/C-1.md; hrow s1 C-1 pass g x; ${RUN}`);
}, 120000);

test("QO: a planted <f>.tmp - the bash writes through it, the twin takes its own temp (EXCLUSIVE TEMP FILES, W14)", () => {
  const { o, t, so, st } = pair("a planted temp", {
    seed: `mk_plan; mkdir -p store/cases; printf '# C-1\\nverified: s1 2026-01-01\\n' >store/cases/C-1.md; printf 'outside\\n' >outside.txt; ln -s ../../outside.txt store/cases/C-1.md.tmp; hrow s1 C-1 pass g x; ${RUN}`,
    env: { PATH: DATE_PATH },
    bash: PROMOTE_BASH,
    twin: PROMOTE_TWIN,
  });
  const moved = "# C-1\nverified: s3 2026-10-10\n";
  expect(o.out).toBe("[promoted=0 reverified=1]");
  expect(t.out).toBe(o.out);
  expect(lstatSync(join(so, "store/cases/C-1.md")).isSymbolicLink()).toBe(true);
  expect(readFileSync(join(so, "outside.txt"), "latin1")).toBe(moved);
  expect(lstatSync(join(st, "store/cases/C-1.md")).isFile()).toBe(true);
  expect(readFileSync(join(st, "store/cases/C-1.md"), "latin1")).toBe(moved);
  expect(lstatSync(join(st, "store/cases/C-1.md.tmp")).isSymbolicLink()).toBe(true);
  expect(readFileSync(join(st, "outside.txt"), "latin1")).toBe("outside\n");
}, 120000);

// --- QL: qa_store_calibration ------------------------------------------------
const calibration = (label: string, seed: string): Side =>
  same(label, {
    seed,
    env: { PATH: DATE_PATH },
    bash: 'c="$(qa_store_calibration "$S/h.tsv" "$S/l.tsv")" || rc=$?; printf \'%s#%s\' "$c" "$rc"',
    twin: 'const r = Q.qaStoreCalibration(S + "/h.tsv", S + "/l.tsv"); out(r.out + "#" + r.status);',
  });

test("QL: Cohen's kappa between the pane's defect calls and the chief's labels", () => {
  expect(calibration("no labels", "hl s1 C-1 fail defect").out).toBe('{"n":0,"agreement":null,"kappa":null,"computed_at":"2026-10-10T12:00:00Z"}#0');
  calibration("no history", "ll s1 C-1 confirmed");
  calibration(
    "agreement, kappa and both sides' positives",
    "hl s1 C-1 fail defect; ll s1 C-1 confirmed; hl s1 C-2 pass g; ll s1 C-2 not-a-defect; hl s2 C-1 fail defect; ll s2 C-1 not-a-defect; hl s2 C-2 pass g; ll s2 C-2 confirmed; hl s3 C-3 pass g; ll s3 C-3 not-a-defect",
  );
  calibration("every pair a defect on both sides: pe is 1", "hl s1 C-1 fail defect; ll s1 C-1 confirmed; hl s2 C-1 fail defect; ll s2 C-1 confirmed");
  calibration(
    "no defect claim, no label and an unknown label word are passed over",
    "hl s1 C-1 fail environment; ll s1 C-1 confirmed; hl s1 C-2 unverifiable -; ll s1 C-2 confirmed; hl s1 C-3 pass flaky; ll s1 C-3 not-a-defect; hl s2 C-4 pass g; hl s1 C-5 fail defect; ll s1 C-5 maybe",
  );
  calibration("no pair at all", "hl s1 C-1 fail defect; ll s9 C-1 confirmed");
  calibration("a label given twice: the last word wins", "hl s1 C-1 fail defect; ll s1 C-1 confirmed; ll s1 C-1 not-a-defect");
}, 120000);

test.skipIf(ROOTUSER)("QL: a label file awk cannot read", () => {
  calibration("unreadable labels", "hl s1 C-1 fail defect; ll s1 C-1 confirmed; chmod 000 l.tsv");
}, 120000);

// --- QY: ac_yaml_keys / ac_yaml_has ------------------------------------------
const YAML = [
  "# a comment",
  "qa:",
  '  serve: "npm start"',
  "  scopes:",
  "    shop:",
  "      apps:",
  "        web:",
  "          serve: x",
  "    blog:",
  "      seed: y",
  "",
  "  e2e:",
  "     odd: five spaces",
  "    endpoint_env:",
  "      API: http://x",
  "      DB: y",
  "  empty:",
  "  # an indented comment",
  "other: z",
].join("\n");
const KEYS = ["qa", "qa.scopes", "qa.scopes.shop", "qa.scopes.shop.apps", "qa.scopes.shop.apps.web", "qa.e2e", "qa.e2e.endpoint_env", "qa.serve", "qa.empty", "qa.none", "other", "nope.deeper"];
const yaml = (label: string, seed: string, file = "c.yaml", keys = KEYS, env?: Record<string, string>): Side =>
  same(label, {
    seed,
    args: [file, keys.join(",")],
    env,
    bash: 'IFS=, read -ra K <<<"$2"; for k in "${K[@]}" ""; do printf \'<%s>\' "$k"; ac_yaml_keys "$S/$1" "$k"; printf \'#%s\\n\' "$?"; ac_yaml_has "$S/$1" "$k"; printf \'has#%s\\n\' "$?"; done',
    twin: 'for (const k of [...A[1].split(","), ""]) { out("<" + k + ">"); const r = L.yamlKeys(S + "/" + A[0], k); out(r.out); out("#" + r.status + "\\n"); out("has#" + L.yamlHas(S + "/" + A[0], k) + "\\n"); }',
  });

test("QY: a block's immediate child keys and a key's presence, through the bash's own awk", () => {
  expect(yaml("the flat subset", `cat >c.yaml <<'EOF'\n${YAML}\nEOF`).out).toContain("<qa.scopes>shop\nblog\n#0\nhas#0\n");
  yaml("no such file", ":", "none.yaml", ["qa"]);
  yaml("a last line with no LF", "printf 'qa:\\n  scopes:\\n    a: 1' >c.yaml", "c.yaml", ["qa", "qa.scopes"]);
  for (const loc of ["C", "en_US.UTF-8"])
    yaml(`a key byte that is no UTF-8 (${loc})`, "printf 'qa:\\n  caf\\351: x\\n  scopes:\\n    a: 1\\n' >c.yaml", "c.yaml", ["qa", "qa.scopes"], { LC_ALL: loc });
}, 120000);

// --- QN: ac_knowledge_scopes -------------------------------------------------
const AWK_OWN = /^awk: |^ source line number |^ input record number /;
const SCOPES_BASH = 'ac_knowledge_scopes "$1" || rc=$?; printf \'#%s\' "$rc"';
const SCOPES_TWIN = 'const r = L.knowledgeScopes(A[0]); out(r.out); writeSync(2, Buffer.from(r.err, "latin1")); out("#" + r.status);';
const RECORD = (text: string): string => `mk_repo r; mkdir -p home/records/repo-knowledge; printf -- '${text}' >home/records/repo-knowledge/r.md`;
const scopes = (label: string, text: string | null, o: { env?: Record<string, string>; repo?: string; seed?: string; own?: RegExp } = {}): Side =>
  same(label, {
    seed: `${text === null ? "mk_repo r; mkdir -p home/records/repo-knowledge" : RECORD(text)}; ${o.seed ?? ":"}`,
    args: [o.repo ?? "@S/r"],
    env: o.env ?? { AC_HOME: "@S/home" },
    own: o.own,
    bash: SCOPES_BASH,
    twin: SCOPES_TWIN,
  });

test("QN: the live scope map, refused whole when it is ambiguous", () => {
  expect(scopes("a live map", "# r\\n- scope shop = web, api | src: file:a:1 | by: f\\n- scope blog = app1\\n- fact x | src: y\\n").out).toBe("shop\tweb,api\nblog\tapp1\n#0");
  scopes("no scope line", "- fact a | src: x\\n");
  scopes("no record", null);
  scopes("a superseded section is not read", "- scope a = x\\n## Superseded\\n- scope a = y\\n- scope bad name\\n");
  scopes("a malformed name", "- scope bad name = x\\n- scope ok = y\\n");
  scopes("a name given three times: its first line reprinted each time", "- scope a = x\\n- scope b = y\\n- scope a = z\\n- scope a = w\\n");
  scopes("an empty app between commas", "- scope a = x,,y\\n");
  scopes("no ' = '", "- scope a\\n");
  scopes("an empty app list", "- scope a = \\n");
  scopes("a CR the src cut does not take", "- scope a = x\\r\\n");
  scopes("a CR the src cut takes", "- scope a = x | src: y\\r\\n");
  scopes("an unterminated last line", "- scope a = x");
  scopes("a byte that is no UTF-8, under C", "- scope caf\\351 = x\\n- fact caf\\351\\n- scope b = y\\n");
  scopes("homeless", "- scope a = x\\n", { env: {} });
  scopes("a dir that is no repo", "- scope a = x\\n", { repo: "@S/plain", seed: "mkdir plain" });
  scopes("a linked worktree reads its main repo's record", "- scope a = x\\n", { repo: "@S/wt", seed: 'git -C r worktree add -q --detach "$SIDE/wt" HEAD' });
}, 120000);

test.skipIf(ROOTUSER)("QN: a record awk cannot read is refused, awk's own lines not reproduced", () => {
  scopes("unreadable", "- scope a = x\\n", { seed: "chmod 000 home/records/repo-knowledge/r.md", own: AWK_OWN });
}, 120000);

test("QN: under a UTF-8 locale a byte that is no UTF-8 aborts the bash's awk; the twin reads bytes (named)", () => {
  const { o, t } = pair("a UTF-8 caller", {
    seed: RECORD("- fact caf\\351\\n- scope a = x\\n"),
    args: ["@S/r"],
    env: { AC_HOME: "@S/home", LC_ALL: "en_US.UTF-8" },
    bash: SCOPES_BASH,
    twin: SCOPES_TWIN,
  });
  expect(o.out).toBe("#2");
  expect(o.err).toContain("towc");
  expect(t.out).toBe("a\tx\n#0");
  expect(t.err).toBe("");
}, 120000);
