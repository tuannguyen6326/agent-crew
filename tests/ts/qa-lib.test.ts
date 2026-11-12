// qa-lib.test.ts - src/qa-lib.ts's twins held to the answers its header and
// the comment above each twin state: the bundle (QB rows), the test-plan
// manifest render and validate (QM, QV), the receipt timestamp (QT), the
// coverage ladder (QC), the ship receipt status (QS), the runtime receipt and
// gate (QR, QG), the tier/boundary table (QH), the path identity (QP), the
// receipt path (QK), the browser manifest (QW), the boundary receipt (QX) and
// the store learning loop - the case body hash (QD), the history append (QI),
// the promotion (QO) and the calibration (QL); src/lib.ts's yamlKeys/yamlHas
// (QY) likewise; and src/lib.ts's knowledgeScopes held to bin/ac-lib.sh's live
// ac_knowledge_scopes (QN), the qa reader src/qa.ts calls beside them. Every
// reachable refusal of each validator has a row; bundle refusals no input
// reaches (the store or ship dir as a link, which the symlink sweep refuses
// first; an unsafe store entry path, which the inventory comparison refuses
// first) and the full-flow case that is not passing (the coverage loop refuses
// it first) have none, nor does the calibration's kappa of 0.0 for pe == 1 (pe
// is 1 only when every pair agrees). Each row runs the twin on a side root a
// bash seed built and asserts its stdout, stderr, status and what it wrote.
//
// DISPUTED: the implementation of ac_knowledge_scopes (bin/ac-lib.sh vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row, seeded alike by the same bash snippet over the same seed library (a git repo with fixed commit dates and its scope record under a home); argv; env (PATH = the host's bun, jq and git, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C unless a row names a locale; HOME and TMPDIR the test root; SIDE the side root; AC_HOME only where a row names it); cwd (the distro root); stdin (/dev/null); stdout, stderr and the status (the side root spelled S) and the side root's world after the call - every path with its mode and bytes - compared whole. A row naming awk's own lines asserts them on the bash side and drops them there before the comparison.
import { afterAll, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const QA = join(ROOT, "src", "qa-lib.ts");
const LIB = join(ROOT, "src", "lib.ts");
const LIBQ = join(ROOT, "src", "lib-qa-gate.ts");
const ROOTUSER = process.getuid?.() === 0;
const W = realpathSync(mkdtempSync(join(tmpdir(), "qa-lib-ts-")));
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

// The plan every QM/QC row starts from.
const SEED_PLAN = `# Plan

## Coverage

coverage: AC-1 | ut | tests/unit.test.ts#works | -
coverage: AC-2 | it | - | case-api
coverage: AC-3 | e2e | - | case-web

${"```"}
coverage: AC-9 | ut | ignored/in/a/fence.ts | -
${"```"}

## Full Flow

full-flow: case-web
`;

// The seed library every row's seed sources: SIDE is the side root, QA src/qa-lib.ts.
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
PLAN='${SEED_PLAN}'
# render_manifest <repo> <sha> <plan> - the frozen manifest, as the twin renders it
render_manifest() {
  bun -e 'const Q = await import(process.env.QA); const [r, s, p] = process.argv.slice(1); const m = Q.qaTestplanManifestRender(r, s, p); process.stdout.write(m.out); process.exit(m.status);' "$@"
}
# mk_run <run> <repo> - a QA run whose frozen manifest, ship receipt and ledger
# satisfy the plan: case-api completes before case-web starts.
mk_run() {
  local run="$1" repo="$2" tsha
  tsha="$(cat "$repo.sha")"
  mkdir -p "$run/profile/ship" "$run/boundaries/case-api" "$run/boundaries/case-web"
  printf '%s' "$PLAN" >"$SIDE/plan.md"
  render_manifest "$repo" "$tsha" "$SIDE/plan.md" >"$run/testplan-manifest.json"
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
# the twin's body hash; hl <sha> <case> <status> <class> and
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
bodysha() { bun -e 'const Q = await import(process.env.QA); process.stdout.write(Q.qaStoreCaseBodySha(process.env.SIDE + "/plan.md", process.argv[1]));' "$1"; }
hl() { printf '%s\t2026-01-01\t%s\tapi\t%s\t%s\tb\tm\tt\n' "$1" "$2" "$3" "$4" >>"$SIDE/h.tsv"; }
ll() { printf '%s\t%s\t%s\tchief\t2026-01-01T00:00:00Z\n' "$1" "$2" "$3" >>"$SIDE/l.tsv"; }
`,
);

// The commit every mk_repo makes: fixed content, author and dates.
const RSHA = (() => {
  const s = join(W, "rsha");
  mkdirSync(s);
  const r = Bun.spawnSync(["/bin/bash", "-c", '. "$SEEDLIB"; mk_repo "$SIDE/r"'], { env: { PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s, SEEDLIB }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`mk_repo failed: ${r.stderr.toString()}`);
  return readFileSync(join(s, "r.sha"), "latin1").trim();
})();

type Row = {
  // the live bash call, run after sourcing ac-lib.sh, S the side root; none for a row only the twin runs
  bash?: string;
  twin: string;
  args?: string[];
  seed?: string;
  env?: Record<string, string>;
  // awk's own lines on the bash side, matching this
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
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; S="$SIDE"; rc=0; ${row.bash}`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { readFileSync, writeSync } from "node:fs"; const Q = await import(${JSON.stringify(QA)}); const L = { ...await import(${JSON.stringify(LIB)}), ...await import(${JSON.stringify(LIBQ)}) }; const lat = (s) => Buffer.from(s, "utf8").toString("latin1"); const A = ${JSON.stringify(args)}.map(lat); const S = lat(process.env.SIDE); const out = (b) => writeSync(1, typeof b === "string" ? Buffer.from(b, "latin1") : b); const said = (e) => out(e === null ? "#0" : "#1" + e); ${row.twin}`,
      ];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 60000 });
  const norm = (t: string): string => t.replaceAll(s, "S");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode };
}

function seeded(label: string, row: Row, s: string): void {
  mkdirSync(s, { recursive: true });
  if (!row.seed) return;
  const r = Bun.spawnSync(["/bin/bash", "-c", `set -e; . "$SEEDLIB"; ${row.seed}`], {
    cwd: s,
    env: { PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s, SEEDLIB, QA },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    timeout: 60000,
  });
  if (r.exitCode !== 0) throw new Error(`seed failed for ${label}: ${r.stderr.toString()}`);
}

// Both sides of a live-bash row, seeded alike and run.
function pair(label: string, row: Row): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const got: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    seeded(label, row, s);
    got.push(side(row, s, name === "o"));
  }
  return { o: got[0]!, t: got[1]! };
}

function same(label: string, row: Row): Side {
  const { o, t } = pair(label, row);
  if (row.own) {
    const own = row.own;
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

// The twin alone on a fresh side root: its answer, and the root's world before
// and after the call.
function twin(label: string, row: Row): Side & { root: string; before: string } {
  const s = join(W, `r${rows++}`);
  seeded(label, row, s);
  const before = world(s).replaceAll(s, "S");
  return { ...side(row, s, false), root: s, before };
}

// A path under the side root: its bytes, `<dir>` for a directory, null when absent.
function at(root: string, rel: string): string | null {
  const p = join(root, rel);
  if (!existsSync(p)) return null;
  return lstatSync(p).isDirectory() ? "<dir>" : readFileSync(p, "latin1");
}

// The twin's stdout <out> with exit 0 and stderr <err> ("" unless named);
// nothing written unless <wrote> names each path the call leaves.
function is(label: string, row: Row, out: string | RegExp, o: { err?: string | RegExp; wrote?: Record<string, string | null> } = {}): void {
  const t = twin(label, row);
  expect([label, t.status]).toEqual([label, 0]);
  if (out instanceof RegExp) expect(t.out).toMatch(out);
  else expect([label, t.out]).toEqual([label, out]);
  if (o.err instanceof RegExp) expect(t.err).toMatch(o.err);
  else expect([label, t.err]).toEqual([label, o.err ?? ""]);
  if (o.wrote === undefined) expect([label, t.world]).toEqual([label, t.before]);
  else for (const [rel, bytes] of Object.entries(o.wrote)) expect([label, rel, at(t.root, rel)]).toEqual([label, rel, bytes]);
}

const kvFile = (file: string, kv: Record<string, string>): string =>
  `: >${file}; ${Object.entries(kv)
    .filter(([, v]) => v !== "<absent>")
    .map(([k, v]) => `printf '%s=%s\\n' '${k}' '${v}' >>${file}`)
    .join("; ")}`;

// A validator row: the twin's `#0` (null) or `#1<error>`.
const validator = (twinFn: string) => (label: string, args: string[], want: string, seed?: string, env?: Record<string, string>): void =>
  is(label, { args, seed, env, twin: `said(Q.${twinFn}(...A));` }, want);

// --- QB: qaBundleValidate ----------------------------------------------------
const bundle = validator("qaBundleValidate");
const B = ["@S/b/profile.json", SHA];

test("QB: a valid bundle, with a fixture pack, a runtime.json and a routing receipt", () => {
  bundle("valid", B, "#0", "mk_bundle b");
  bundle("a fixture pack", B, "#0", `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1","runner":"run.sh","selectors":["s"],"capabilities":[],"mutation":"read-only","retry":"read-only","assets":["a/x.txt"]}' >b/store/fixtures/p1/manifest.json; printf x >b/store/fixtures/p1/run.sh; mkdir -p b/store/fixtures/p1/a; printf y >b/store/fixtures/p1/a/x.txt; refresh b`);
  bundle("a runtime.json root entry", B, "#0", "mk_bundle b; printf '{}' >b/runtime.json");
  bundle("a default routing receipt", B, "#0", `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:"default",use:{harness:"codex",model:"m",effort:"high"},dispatch_sha256:"${"a".repeat(64)}"}'; phash b`);
  bundle("a numbered routing receipt", B, "#0", `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:2,when:"w",why:"y",use:{harness:"codex",model:"",effort:""},dispatch_sha256:"${"a".repeat(64)}"}'; phash b`);
}, 120000);

test("QB: every reachable refusal, in the spec's order", () => {
  bundle("the file is not profile.json", ["@S/b/other.json", SHA], "#1profile filename must be profile.json", "mk_bundle b; cp b/profile.json b/other.json");
  bundle("no bundle directory", ["@S/nope/profile.json", SHA], "#1bundle directory is unreadable");
  bundle("a spelling that is not the fixed path", ["@S/b/./profile.json", SHA], "#1profile path is not the fixed bundle file", "mk_bundle b");
  bundle("a path through a linked directory", ["@S/link/profile.json", SHA], "#1profile path is not the fixed bundle file", "mk_bundle b; ln -s b link");
  bundle("a symlink inside", B, "#1bundle contains a symlink", "mk_bundle b; ln -s data.txt b/store/l");
  bundle("an unknown root entry", B, "#1unknown bundle root entry: extra", "mk_bundle b; : >b/extra");
  bundle("a root entry whose name holds a LF", B, "#1unknown bundle root entry: x", "mk_bundle b; : >\"b/x\nconfig.yaml\"");
  bundle("the store is a file", B, "#1bundle store is missing or symlinked", "mk_bundle b; rm -r b/store; : >b/store");
  bundle("no ship dir", B, "#1bundle ship receipt directory is missing or symlinked", "mk_bundle b; rm -r b/ship");
  bundle("no config", B, "#1missing or symlinked bundle file: S/b/config.yaml", "mk_bundle b; rm b/config.yaml");
  bundle("no store manifest", B, "#1missing or symlinked bundle file: S/b/store/manifest.json", "mk_bundle b; rm b/store/manifest.json");
  const SCHEMA = "#1invalid profile schema or fixed snapshot names";
  bundle("a profile off its schema", B, SCHEMA, "mk_bundle b; jqset b/profile.json '.schema=\"x\"'");
  bundle("a routing rule of 0", B, SCHEMA, `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:0,when:"w",why:"y",use:{harness:"codex",model:"",effort:""},dispatch_sha256:"${"a".repeat(64)}"}'`);
  bundle("a default rule carrying when", B, SCHEMA, `mk_bundle b; jqset b/profile.json '.routing={kind:"qa",rule:"default",when:"w",use:{harness:"codex",model:"",effort:""},dispatch_sha256:"${"a".repeat(64)}"}'`);
  bundle("another source sha", ["@S/b/profile.json", "2222222222222222222222222222222222222222"], "#1profile source ref does not match exact source lease", "mk_bundle b");
  bundle("a changed config", B, "#1config snapshot hash mismatch", "mk_bundle b; printf '# x\\n' >>b/config.yaml");
  bundle("a changed scope map", B, "#1scope snapshot hash mismatch", "mk_bundle b; printf 's\\ta\\n' >>b/scopes.tsv");
  bundle("a changed store manifest", B, "#1store manifest hash mismatch", "mk_bundle b; jqset b/store/manifest.json '.extra=1'");
  bundle("a changed ship receipt", B, "#1frozen ship test receipt hash mismatch", "mk_bundle b; printf 'x=1\\n' >>b/ship/test-receipt.env");
  bundle("a ship receipt of another schema", B, "#1frozen ship test receipt has the wrong schema", "mk_bundle b; sedset b/ship/test-receipt.env 's/^schema=.*/schema=other/'; snap b; phash b");
  bundle("a ship receipt of another sha", B, "#1frozen ship test receipt binds another source sha", "mk_bundle b; sedset b/ship/test-receipt.env 's/^source_sha=.*/source_sha=2222/'; snap b; phash b");
  bundle("an invalid store manifest", B, "#1invalid store manifest", "mk_bundle b; printf '{\"schema\":\"x\"}' >b/store/manifest.json; snap b; phash b");
  bundle("an unlisted store file", B, "#1store manifest/file inventory mismatch", "mk_bundle b; printf 'two\\n' >b/store/more.txt");
  bundle("a listed file whose @tsv spelling names no file", B, "#1missing store entry: a\\\\b.txt", "mk_bundle b; printf 'x\\n' >'b/store/a\\b.txt'; refresh b");
  bundle("a store file changed after the manifest", B, "#1store entry hash mismatch: data.txt", "mk_bundle b; printf 'changed\\n' >b/store/data.txt");
  bundle("an invalid fixture pack", B, "#1invalid fixture-pack manifest: fixtures/p1/manifest.json", `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1"}' >b/store/fixtures/p1/manifest.json; refresh b`);
  bundle("an unsafe fixture-pack path", B, "#1unsafe fixture-pack path: ../run.sh", `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1","runner":"../run.sh","selectors":["s"],"capabilities":[],"mutation":"read-only","retry":"read-only"}' >b/store/fixtures/p1/manifest.json; refresh b`);
  bundle("a missing fixture-pack file", B, "#1missing fixture-pack file: run.sh", `mk_bundle b; mkdir -p b/store/fixtures/p1; printf '{"schema":"agentcrew.qa-fixture-pack/v1","id":"p1","runner":"run.sh","selectors":["s"],"capabilities":[],"mutation":"read-only","retry":"read-only"}' >b/store/fixtures/p1/manifest.json; refresh b`);
  bundle("a profile changed after its hash", B, "#1canonical profile hash mismatch", "mk_bundle b; jqset b/profile.json '.profile_key=\"p/s/b\"'");
}, 120000);

test.skipIf(ROOTUSER)("QB: an unreadable ship receipt hashes as nothing", () => {
  bundle("unreadable", B, "#1frozen ship test receipt hash mismatch", "mk_bundle b; chmod 000 b/ship/test-receipt.env");
}, 120000);

// --- QM / QV: qaTestplanManifestRender / qaTestplanManifestValidate ----------
const render = (label: string, seed: string, want: string | RegExp, args = ["@S/r", "=SHA", "@S/plan.md"], env?: Record<string, string>): void =>
  is(
    label,
    {
      seed,
      args,
      env,
      twin: 'const a = A.map((x) => (x === "=SHA" ? readFileSync(S + "/r.sha", "latin1").trim() : x)); const r = Q.qaTestplanManifestRender(a[0], a[1], a[2]); out(r.out); out("#" + r.status + r.error);',
    },
    want,
  );
const plan = (label: string, text: string, want: string): void => render(label, `mk_repo r; cat >plan.md <<'EOF'\n${text}\nEOF`, want);
const PLAN = (cov: string, flow = "full-flow: case-web"): string => `## Coverage\n${cov}\n## Full Flow\n${flow}`;
const COV = "coverage: AC-1 | ut | tests/unit.test.ts#works | -\ncoverage: AC-3 | e2e | - | case-web";
// The canonical manifest of a plan's bytes, <coverage> as [ac, rung, proof, case] rows.
const manifest = (planBytes: string, coverage: [string, string, string, string][], flow: string[]): string =>
  `${JSON.stringify({
    coverage: coverage.map(([ac, rung, proof, c]) => ({ ac, case: c, proof, rung })),
    full_flow: flow,
    schema: "agentcrew.qa-testplan-manifest/v1",
    testplan_sha256: createHash("sha256").update(planBytes, "latin1").digest("hex"),
  })}\n#0`;
const AC1: [string, string, string, string] = ["AC-1", "ut", "tests/unit.test.ts#works", "-"];
const AC3: [string, string, string, string] = ["AC-3", "e2e", "-", "case-web"];
// The declarations a refusal's text carries after its own line.
const DECLARED = "\nC\tAC-1\tut\ttests/unit.test.ts#works\t-\nC\tAC-3\te2e\t-\tcase-web";

test("QM: the canonical manifest of a test plan", () => {
  render("the seed plan", 'mk_repo r; printf \'%s\' "$PLAN" >plan.md', manifest(SEED_PLAN, [AC1, ["AC-2", "it", "-", "case-api"], AC3], ["case-web"]));
  const exec = PLAN(`coverage: AC-1 | ut | tests/exec.sh | -\n${COV}`);
  plan("an executable test", exec, manifest(`${exec}\n`, [["AC-1", "ut", "tests/exec.sh", "-"], AC1, AC3], ["case-web"]));
  const deep = PLAN(`coverage: AC-1 | ut | tests/deep/d.test.ts#x | -\n${COV}`);
  plan("a nested test", deep, manifest(`${deep}\n`, [["AC-1", "ut", "tests/deep/d.test.ts#x", "-"], AC1, AC3], ["case-web"]));
}, 120000);

test("QM: the parser's own refusals, its lines and the declarations before them in one text", () => {
  plan("no space after coverage:", PLAN(`coverage:AC-1 | ut | t | -\n${COV}`), "#1malformed coverage declaration at line 2");
  plan("three fields", PLAN(`coverage: AC-1 | ut | t\n${COV}`), "#1coverage declaration needs four exact fields at line 2");
  plan("a padded field", PLAN(`coverage: AC-1 |  ut | t | -\n${COV}`), "#1coverage declaration has an empty or padded field at line 2");
  plan("a bad AC id", PLAN(`coverage: A..1 | ut | t | -\n${COV}`), "#1invalid acceptance-criterion id at line 2: A..1");
  plan("a bad rung", PLAN(`coverage: AC-1 | unit | t | -\n${COV}`), "#1invalid coverage rung at line 2: unit");
  plan("a UT row with a case", PLAN(`coverage: AC-1 | ut | t | case-x\n${COV}`), "#1UT coverage needs a test reference and no QA case at line 2");
  plan("an IT row with a test", PLAN(`coverage: AC-2 | it | t | case-x\n${COV}`), "#1IT/E2E coverage needs a case id and no test reference at line 2");
  plan("a duplicate", PLAN(`${COV}\n${COV}`), `#1duplicate coverage declaration at line 4${DECLARED}`);
  plan("a full-flow without its space", PLAN(COV, "full-flow:case-web"), `#1malformed full-flow declaration at line 5${DECLARED}`);
  plan("a bad full-flow id", PLAN(COV, "full-flow: a..b"), `#1invalid full-flow case id at line 5: a..b${DECLARED}`);
  plan("a duplicate full-flow", PLAN(COV, "full-flow: case-web\nfull-flow: case-web"), `#1duplicate full-flow declaration at line 6: case-web${DECLARED}\nF\tcase-web`);
  plan("an unterminated fence", `${PLAN(COV)}\n${"```"}`, `#1unterminated fenced code block in test plan${DECLARED}\nF\tcase-web`);
  plan("two coverage sections", `${PLAN(COV)}\n## Coverage\n${COV}`, `#1duplicate coverage declaration at line 7${DECLARED}\nF\tcase-web`);
  plan("no full-flow section", `## Coverage\n${COV}`, `#1test plan needs exactly one ## Full Flow section${DECLARED}`);
  plan("no coverage line", PLAN(""), "#1test plan needs at least one coverage declaration\nF\tcase-web");
  plan("no full-flow line", PLAN(COV, ""), `#1test plan needs at least one full-flow declaration${DECLARED}`);
  plan("a full-flow case no coverage cites", PLAN(COV, "full-flow: case-x"), `#1full-flow case is not cited by IT/E2E coverage: case-x${DECLARED}\nF\tcase-x`);
  const byte = `mk_repo r; printf '## Coverage\\ncoverage: AC-1 | ut | t\\351.ts | -\\n${COV.replace(/\n/g, "\\n")}\\n## Full Flow\\nfull-flow: case-web\\n' >plan.md`;
  render("a byte that is no UTF-8 (C)", byte, `#1UT coverage AC-1 does not name a regular tracked blob at ${RSHA}: t\xe9.ts`, undefined, { LC_ALL: "C" });
  // Under UTF-8 the parser's awk aborts on the byte; its own lines are the error.
  render("a byte that is no UTF-8 (en_US.UTF-8)", byte, /^#1awk: /, undefined, { LC_ALL: "en_US.UTF-8" });
}, 120000);

test("QM: the UT references checked against the exact Git tree", () => {
  const ut = (label: string, ref: string, want: string): void => plan(label, PLAN(`coverage: AC-1 | ut | ${ref} | -\n${COV}`), want);
  ut("an empty selector", "tests/unit.test.ts#", "#1UT coverage AC-1 has an invalid selector: tests/unit.test.ts#");
  ut("a selector holding #", "tests/unit.test.ts#a#b", "#1UT coverage AC-1 has an invalid selector: tests/unit.test.ts#a#b");
  for (const ref of ["./tests/unit.test.ts", "/tests/unit.test.ts", "tests/../tests/unit.test.ts", "tests//unit.test.ts", "tests/"])
    ut(`unsafe ${ref}`, ref, `#1UT coverage AC-1 has an unsafe repository test path: ${ref}`);
  for (const ref of ["tests", "tests/link.ts", "tests/none.ts"]) ut(`no blob ${ref}`, ref, `#1UT coverage AC-1 does not name a regular tracked blob at ${RSHA}: ${ref}`);
  ut("a missing parent", "none/unit.test.ts", "#1UT coverage AC-1 crosses a missing or symlinked Git-tree parent: none");
  ut("a linked parent", "linkdir/unit.test.ts", "#1UT coverage AC-1 crosses a missing or symlinked Git-tree parent: linkdir");
  render("no such commit", 'mk_repo r; printf \'%s\' "$PLAN" >plan.md', "#1target source commit is unavailable: 2222222222222222222222222222222222222222", ["@S/r", "2222222222222222222222222222222222222222", "@S/plan.md"]);
  render("no source repo", 'mk_repo r; printf \'%s\' "$PLAN" >plan.md', `#1target source commit is unavailable: ${RSHA}`, ["@S/none", "=SHA", "@S/plan.md"]);
  render("no plan", "mk_repo r", "#1test plan is missing: S/none.md", ["@S/r", "=SHA", "@S/none.md"]);
}, 120000);

const validate = (label: string, seed: string, want: string, manifestSha = "=MSHA"): void =>
  is(
    label,
    {
      seed: `mk_repo r; printf '%s' "$PLAN" >plan.md; render_manifest "$SIDE/r" "$(cat r.sha)" "$SIDE/plan.md" >m.json; sha m.json >m.sha; ${seed}`,
      args: [manifestSha],
      twin: 'const rd = (f) => readFileSync(S + "/" + f, "latin1").trim(); const m = A[0] === "=MSHA" ? rd("m.sha") : A[0]; said(Q.qaTestplanManifestValidate(S + "/r", rd("r.sha"), S + "/plan.md", S + "/m.json", m));',
    },
    want,
  );

test("QV: the frozen manifest re-rendered and hashed", () => {
  validate("valid", ":", "#0");
  validate("no manifest", "rm m.json", "#1frozen test-plan manifest is missing: S/m.json");
  validate("a plan that no longer parses", "printf 'x\\n' >plan.md", "#1test plan needs exactly one ## Coverage section");
  validate("a plan changed after the freeze", "printf '\\n' >>plan.md", "#1current test plan disagrees with the frozen manifest");
  validate("an edited manifest", "printf ' ' >>m.json", "#1current test plan disagrees with the frozen manifest");
  validate("an empty expected hash", ":", "#1frozen manifest hash mismatch", "");
  validate("another expected hash", ":", "#1frozen manifest hash mismatch", "abc");
}, 120000);

// --- QT: qaTimestampEpoch ----------------------------------------------------
test("QT: jq's fromdateiso8601, nothing for what it refuses", () => {
  for (const [ts, want] of [
    ["2026-01-01T00:00:00Z", "1767225600#0"],
    ["2026-02-30T00:00:00Z", "1772409600#0"],
    ["2026-01-01T00:00:00.5Z", "#1"],
    ["2026-01-01T00:00:00+07:00", "#1"],
    ["", "#1"],
    ["x", "#1"],
  ] as const)
    is(`stamp ${ts || "(empty)"}`, { args: [ts], twin: 'const v = Q.qaTimestampEpoch(A[0]); out((v ?? "") + "#" + (v === null ? 1 : 0));' }, want);
}, 120000);

// --- QC: qaCoverageValidate --------------------------------------------------
const coverage = (label: string, seed: string, want: string, err = ""): void =>
  is(
    label,
    {
      seed: `mk_repo r; mk_run "$SIDE/run" "$SIDE/r"; ${seed}`,
      twin: 'said(Q.qaCoverageValidate(S + "/run", S + "/r", readFileSync(S + "/r.sha", "latin1").trim()));',
    },
    want,
    { err: err === "" ? "" : new RegExp(err) },
  );
const LEDGER = (rows: string): string => `{ ${rows}; } >run/cases.tsv`;
const API = 'row case-api api pass http "$SIDE/run/boundaries/case-api/receipt.env"';
const WEB = 'row case-web web pass web "$SIDE/run/boundaries/case-web/receipt.env"';

test("QC: the ladder against the effective ledger and the receipts' times", () => {
  coverage("valid", ":", "#0");
  coverage("an e2e case on an e2e boundary", LEDGER(`${API}; row case-web api pass e2e "$SIDE/run/boundaries/case-web/receipt.env"`), "#0");
  coverage("a ledger row ending in one TAB", `printf '%s\\t\\n' "$(${API})" >run/cases.tsv; ${WEB} >>run/cases.tsv`, "#0");
  coverage("a ledger row past 12 columns", `printf '%s\\tEXTRA\\n' "$(${API})" >run/cases.tsv; ${WEB} >>run/cases.tsv`, "#1case case-api has an invalid boundary started_at timestamp: ");
}, 120000);

test("QC: every refusal, in the spec's order", () => {
  const ONE_ROW = "#1it coverage AC-2 needs exactly one effective case row for case-api";
  coverage("a plan changed after the freeze", "printf '\\n' >>plan.md", "#1current test plan disagrees with the frozen manifest");
  coverage("no qualifying ship receipt", "rm run/profile/ship/test-receipt.env", "#1UT coverage AC-1 requires a qualifying exact-SHA ship receipt (got not-qualifies:absent); escalate this AC to IT");
  coverage("no row for an IT case", LEDGER(WEB), ONE_ROW);
  coverage("two rows for an IT case", LEDGER(`${API}; ${API}; ${WEB}`), ONE_ROW);
  coverage("a failing IT case", LEDGER(`row case-api api fail http x; ${WEB}`), "#1it coverage AC-2 cites non-passing case case-api");
  coverage("an IT case of tier web", LEDGER(`row case-api web pass web x; ${WEB}`), "#1IT coverage AC-2 cites case case-api with non-IT tier web");
  coverage("an E2E case with no web or e2e evidence", LEDGER(`${API}; row case-web api pass http x`), "#1E2E coverage AC-3 cites case case-web without web or e2e evidence");
  coverage("no ledger", "rm run/cases.tsv", ONE_ROW, "^awk: ");
  coverage("a bad started_at", "printf 'started_at=x\\ncompleted_at=2026-01-01T00:01:00Z\\n' >run/boundaries/case-api/receipt.env", "#1case case-api has an invalid boundary started_at timestamp: x");
  coverage("a bad completed_at", "printf 'started_at=2026-01-01T00:00:00Z\\n' >run/boundaries/case-api/receipt.env", "#1case case-api has an invalid boundary completed_at timestamp: ");
  coverage("completed before started", "printf 'started_at=2026-01-01T00:05:00Z\\ncompleted_at=2026-01-01T00:01:00Z\\n' >run/boundaries/case-api/receipt.env", "#1case case-api boundary completed_at precedes started_at");
  coverage("a full-flow case of another tier", LEDGER(`${API}; row case-web foo pass e2e "$SIDE/run/boundaries/case-web/receipt.env"`), "#1full-flow case case-web has invalid tier foo");
  coverage("the final group started before a component completed", "printf 'started_at=2026-01-01T00:00:00Z\\ncompleted_at=2026-01-01T00:10:00Z\\n' >run/boundaries/case-api/receipt.env", "#1full-flow final group started before all component cases completed");
  coverage(
    "awk's numeric match finds a row the ledger read does not name",
    `PLAN="$(printf '%s' "$PLAN" | sed 's/case-web/1/g')"; mk_run "$SIDE/run" "$SIDE/r"; ${LEDGER(`${API}; row 01 web pass web "$SIDE/run/boundaries/case-web/receipt.env"`)}`,
    "#1no declared full-flow case exists in the effective ledger",
  );
}, 120000);

// --- QS: qaShipReceiptStatus -------------------------------------------------
const RECEIPT = (o: Record<string, string>): string =>
  kvFile("rcpt.env", { schema: "agentcrew.ship-test-receipt/v1", source_sha: SHA, qualification: "qualifies", reason: "executed", exit_code: "0", command_sha256: "c", output_sha256: "o", started_at: "s", completed_at: "e", ...o });
const ship = (label: string, seed: string, want: string, args = ["@S/rcpt.env", SHA], err = ""): void =>
  is(label, { seed, args, twin: 'out(Q.qaShipReceiptStatus(A[0], A[1]) + "\\n#0");' }, `${want}\n#0`, { err });

test("QS: one closed qualification answer per receipt", () => {
  ship("executed", RECEIPT({}), "qualifies:executed");
  ship("an execution attestation", RECEIPT({ reason: "execution-attestation" }), "qualifies:execution-attestation");
  ship("no receipt", ":", "not-qualifies:absent");
  ship("an empty path", ":", "not-qualifies:absent", ["", SHA]);
  ship("another schema", RECEIPT({ schema: "x" }), "not-qualifies:invalid");
  ship("an unknown reason", RECEIPT({ reason: "lucky" }), "not-qualifies:invalid");
  ship("another sha", RECEIPT({ source_sha: "2222" }), "not-qualifies:stale");
  ship("no sha asked for", RECEIPT({}), "not-qualifies:stale", ["@S/rcpt.env", ""]);
  ship("executed but not qualifying", RECEIPT({ qualification: "not-qualifies" }), "not-qualifies:invalid");
  ship("scoped", RECEIPT({ qualification: "not-qualifies", reason: "scoped" }), "not-qualifies:scoped");
  ship("qualifying for a non-execution reason", RECEIPT({ reason: "absent" }), "not-qualifies:invalid");
  ship("a non-zero exit", RECEIPT({ exit_code: "1" }), "not-qualifies:invalid");
  ship("an exit of 00", RECEIPT({ exit_code: "00" }), "not-qualifies:invalid");
  ship("a command hash of -", RECEIPT({ command_sha256: "-" }), "not-qualifies:invalid");
  ship("no completed_at", RECEIPT({ completed_at: "<absent>" }), "not-qualifies:invalid");
}, 120000);

test.skipIf(ROOTUSER)("QS: an unreadable receipt is invalid, its warning said", () => {
  ship("unreadable", `${RECEIPT({})}; chmod 000 rcpt.env`, "not-qualifies:invalid", undefined, "WARN: cannot read meta file S/rcpt.env\n");
}, 120000);

// --- QR / QG: qaRuntimeReceiptValidate / qaRuntimeGateValidate ---------------
const runtime = validator("qaRuntimeReceiptValidate");
const RT_ARGS = ["@S/rt.env", "src", "prof", "serve", "health", "desc"];
const RT = (o: Record<string, string>): string =>
  kvFile("rt.env", { schema: "agentcrew.qa-runtime-receipt/v1", source_sha: "src", profile_sha256: "prof", serve_command_sha256: "serve", health_command_sha256: "health", runtime_descriptor_sha256: "desc", serve_started_at: "t0", health_completed_at: "t1", process_group: "123", ...o });

test("QR: the boot receipt's shape, schema and identity", () => {
  runtime("valid", RT_ARGS, "#0", RT({}));
  runtime("a process group of 00", RT_ARGS, "#0", RT({ process_group: "00" }));
  runtime("missing", RT_ARGS, "#1runtime receipt is missing: S/rt.env");
  for (const [k, v, want] of [
    ["schema", "x", "has the wrong schema"],
    ["source_sha", "x", "binds another source sha"],
    ["profile_sha256", "x", "binds another profile hash"],
    ["serve_command_sha256", "x", "binds another serve command"],
    ["health_command_sha256", "x", "binds another health command"],
    ["runtime_descriptor_sha256", "x", "binds another runtime descriptor"],
    ["serve_started_at", "<absent>", "has no boot/health timestamps"],
    ["health_completed_at", "<absent>", "has no boot/health timestamps"],
    ["process_group", "0", "has no positive process group"],
    ["process_group", "", "has no positive process group"],
    ["process_group", "12a", "has no positive process group"],
  ] as const)
    runtime(`${k}=${v}`, RT_ARGS, `#1runtime receipt ${want}`, RT({ [k]: v }));
}, 120000);

const gate = validator("qaRuntimeGateValidate");
const GT_ARGS = ["@S/gate.env", "src", "prof", "rsha", "health", "123"];
const GT = (o: Record<string, string>): string =>
  kvFile("gate.env", { schema: "agentcrew.qa-runtime-gate/v1", source_sha: "src", profile_sha256: "prof", runtime_receipt_sha256: "rsha", health_command_sha256: "health", process_group: "123", alive: "1", health_exit_code: "0", validated_at: "t", ...o });

test("QG: the final live-process record", () => {
  gate("valid", GT_ARGS, "#0", GT({}));
  gate("missing", GT_ARGS, "#1runtime gate receipt is missing: S/gate.env");
  for (const [k, v, want] of [
    ["schema", "x", "has the wrong schema"],
    ["source_sha", "x", "binds another source sha"],
    ["profile_sha256", "x", "binds another profile hash"],
    ["runtime_receipt_sha256", "x", "binds another boot receipt"],
    ["health_command_sha256", "x", "binds another health command"],
    ["process_group", "124", "binds another process group"],
    ["alive", "0", "does not record a live zero-exit probe"],
    ["health_exit_code", "1", "does not record a live zero-exit probe"],
    ["validated_at", "<absent>", "has no validation timestamp"],
  ] as const)
    gate(`${k}=${v}`, GT_ARGS, `#1runtime gate receipt ${want}`, GT({ [k]: v }));
}, 120000);

// --- QH: qaBoundaryCoherent --------------------------------------------------
test("QH: the closed tier/boundary table", () => {
  const coherent: Record<string, string[]> = {
    api: ["http", "grpc", "client-cli", "e2e"],
    db: ["http", "grpc", "client-cli", "workflow", "queue", "schedule", "e2e"],
    workflow: ["workflow", "queue", "schedule", "e2e"],
    web: ["web", "e2e"],
    e2e: [],
    constructor: [],
    "": [],
  };
  const boundaries = ["http", "grpc", "client-cli", "workflow", "queue", "schedule", "web", "e2e", ""];
  const want = Object.entries(coherent)
    .flatMap(([t, ok]) => boundaries.map((b) => `${t}:${b}=${ok.includes(b) ? 0 : 1}\n`))
    .join("");
  is(
    "every pair",
    {
      args: [Object.keys(coherent).filter((t) => t !== "").join(","), boundaries.filter((b) => b !== "").join(",")],
      twin: 'const T = [...A[0].split(","), ""]; const B = [...A[1].split(","), ""]; for (const t of T) for (const b of B) out(`${t}:${b}=${Q.qaBoundaryCoherent(t, b) ? 0 : 1}\\n`);',
    },
    want,
  );
}, 120000);

// --- QP: qaPathSha -----------------------------------------------------------
const pathSha = (label: string, seed: string, path: string, want: string): void => is(label, { seed, args: [path], twin: 'out("[" + Q.qaPathSha(A[0]) + "]");' }, `[${want}]`);
const EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

test("QP: a file's hash, a directory's manifest hash", () => {
  pathSha("a file", "printf 'A' >f", "@S/f", "559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd");
  pathSha("a directory", "mkdir -p d/b d/.h; printf A >d/a; printf 'C\\n' >d/b/c; printf H >d/.h/x; printf Z >d/Z", "@S/d", "ea5a3adf28cda71358fcd1c8da4c2d648b2f14859db8b43a5f5d882aa2357c52");
  pathSha("an empty directory", "mkdir d", "@S/d", EMPTY_SHA);
  pathSha("a link to a directory", "mkdir d; printf A >d/a; ln -s d l", "@S/l", "7d9c60e7b0b429169c633165ae1c5919e9610d27a407dee70834a05aad3ff8a6");
  pathSha("a directory holding a link", "mkdir d; printf A >d/a; ln -s a d/l", "@S/d", "7d9c60e7b0b429169c633165ae1c5919e9610d27a407dee70834a05aad3ff8a6");
  pathSha("a missing path", ":", "@S/none", "");
}, 120000);

test.skipIf(ROOTUSER)("QP: what it cannot read hashes as nothing", () => {
  pathSha("an unreadable file", "printf A >f; chmod 000 f", "@S/f", "");
  pathSha("an unreadable file in a directory", "mkdir d; printf A >d/a; printf B >d/b; chmod 000 d/b", "@S/d", "ccd2a366c3d626e78dfdda9c0f99109914bfefb0094e380cf32ac95c91e7d05b");
  pathSha("a directory it cannot enter", "mkdir d; printf A >d/a; chmod 000 d", "@S/d", EMPTY_SHA);
}, 120000);

// --- QK: qaReceiptPathOk -----------------------------------------------------
const receiptPath = (label: string, seed: string, args: string[], ok: boolean): void =>
  is(label, { seed, args, twin: 'out("#" + (Q.qaReceiptPathOk(A[0], A[1], A[2]) ? 0 : 1));' }, ok ? "#0" : "#1");
const RK = "mkdir -p run/boundaries/c1 other; printf r >run/boundaries/c1/r.env; printf r >other/r.env";

test("QK: a regular receipt whose parent is the case's own boundary dir", () => {
  receiptPath("valid", RK, ["@S/run", "c1", "@S/run/boundaries/c1/r.env"], true);
  receiptPath("through ..", RK, ["@S/run", "c1", "@S/run/boundaries/c1/../c1/r.env"], true);
  receiptPath("another dir", RK, ["@S/run", "c1", "@S/other/r.env"], false);
  receiptPath("a link", `${RK}; ln -s ../../../other/r.env run/boundaries/c1/l.env`, ["@S/run", "c1", "@S/run/boundaries/c1/l.env"], false);
  receiptPath("a linked case dir", `${RK}; ln -s ../../other run/boundaries/c2`, ["@S/run", "c2", "@S/run/boundaries/c2/r.env"], true);
  receiptPath("a directory", RK, ["@S/run", "boundaries", "@S/run/boundaries/c1"], false);
  receiptPath("-", RK, ["@S/run", "c1", "-"], false);
  receiptPath("an empty case id", RK, ["@S/run", "", "@S/run/boundaries/c1/r.env"], false);
  receiptPath("missing", RK, ["@S/run", "c1", "@S/run/boundaries/c1/none.env"], false);
}, 120000);

// --- QW: qaBrowserManifestOk -------------------------------------------------
const browser = validator("qaBrowserManifestOk");
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
  const TAMPERED = "#1browser evidence manifest for case c1 is missing or tampered";
  const MOVED = "#1the registered screenshot for case c1 no longer matches its browser boundary receipt";
  browser("valid", BW, "#0", QW());
  browser("a second manifest first in order", BW, "#0", QW({ extra: "printf 'visual x\\n' >run/boundaries/c1/a.manifest" }));
  browser("no manifest", BW, TAMPERED, QW({ extra: "rm run/boundaries/c1/b.manifest" }));
  browser("a hidden manifest only", BW, TAMPERED, QW({ extra: "mv run/boundaries/c1/b.manifest run/boundaries/c1/.b.manifest" }));
  browser("a manifest edited after the receipt", BW, TAMPERED, QW({ extra: "printf 'x\\n' >>run/boundaries/c1/b.manifest" }));
  browser("no visual line", BW, "#1browser evidence manifest for case c1 names no visual", `${QW({ extra: "printf 'other y\\n' >run/boundaries/c1/b.manifest" })}; printf 'evidence_sha256=%s\\n' "$(sha run/boundaries/c1/b.manifest)" >rcpt.env`);
  browser("no visuals ledger", BW, MOVED, QW({ tsv: ":" }));
  browser("a visual of another case", BW, MOVED, QW({ tsv: `printf '%s\\tx\\ty\\tc2\\tz\\n' "$SIDE/shots/v.png" >run/visuals.tsv` }));
  browser("a screenshot changed after registration", BW, MOVED, QW({ extra: "printf PNG2 >shots/v.png" }));
  browser("a registered screenshot that is gone", BW, MOVED, QW({ extra: "rm shots/v.png" }));
}, 120000);

// --- QX: qaBoundaryReceiptValidate -------------------------------------------
const boundary = validator("qaBoundaryReceiptValidate");
const QX = (o: Record<string, string>): string =>
  kvFile("b.env", { schema: "agentcrew.qa-boundary-receipt/v1", case_id: "c1", source_sha: "src", profile_sha256: "prof", runtime_receipt_sha256: "rsha", boundary: "http", driver: "command", stimulus_sha256: "st", evidence_sha256: "ev", started_at: "t0", completed_at: "t1", exit_code: "0", ...o });
const BX = (tier = "api", status = "pass", expected?: string): string[] => ["@S/b.env", "c1", tier, status, "src", "prof", "rsha", ...(expected === undefined ? [] : [expected])];

test("QX: one client-boundary receipt per terminal case", () => {
  boundary("valid", BX(), "#0", QX({}));
  boundary("a web case driven by a browser", BX("web"), "#0", QX({ boundary: "web", driver: "browser" }));
  boundary("an e2e wrapper with its upstream", BX("api"), "#0", QX({ boundary: "e2e", driver: "e2e", upstream_receipt_sha256: "up" }));
  boundary("the expected evidence", BX("api", "pass", "ev"), "#0", QX({}));
  boundary("an expected evidence of -", BX("api", "pass", "-"), "#0", QX({}));
  boundary("a failing case with a non-zero exit", BX("api", "fail"), "#0", QX({ exit_code: "1" }));
}, 120000);

test("QX: every refusal, in the spec's order", () => {
  boundary("missing", BX(), "#1boundary receipt is missing: S/b.env");
  for (const [k, v, want] of [
    ["schema", "x", "boundary receipt has the wrong schema"],
    ["case_id", "c2", "boundary receipt names another case id"],
    ["source_sha", "x", "boundary receipt binds another source sha"],
    ["profile_sha256", "x", "boundary receipt binds another profile hash"],
    ["runtime_receipt_sha256", "x", "boundary receipt is not bound to this run's booted runtime"],
    ["boundary", "carrier-pigeon", "boundary receipt has an unknown boundary 'carrier-pigeon'"],
    ["stimulus_sha256", "<absent>", "boundary receipt has no stimulus/evidence identity"],
    ["evidence_sha256", "<absent>", "boundary receipt has no stimulus/evidence identity"],
    ["started_at", "<absent>", "boundary receipt has no execution timestamps"],
    ["completed_at", "<absent>", "boundary receipt has no execution timestamps"],
    ["exit_code", "<absent>", "boundary receipt has no numeric exit code"],
    ["exit_code", "1a", "boundary receipt has no numeric exit code"],
    ["exit_code", "1", "a passing case cannot bind a non-zero boundary execution (exit 1)"],
    ["exit_code", "00", "a passing case cannot bind a non-zero boundary execution (exit 00)"],
  ] as const)
    boundary(`${k}=${v}`, BX(), `#1${want}`, QX({ [k]: v }));
  boundary("a tier its boundary cannot satisfy", BX("web"), "#1tier 'web' cannot be satisfied by boundary 'http'", QX({}));
  boundary("a web boundary driven by a command", BX("web"), "#1boundary 'web' cannot be driven by 'command'", QX({ boundary: "web", driver: "command" }));
  boundary("an http boundary driven by a browser", BX(), "#1boundary 'http' cannot be driven by 'browser'", QX({ driver: "browser" }));
  boundary("an e2e boundary driven by a command", BX(), "#1boundary 'e2e' cannot be driven by 'command'", QX({ boundary: "e2e" }));
  boundary("an e2e wrapper binding no upstream", BX(), "#1e2e boundary wrapper binds no upstream receipt", QX({ boundary: "e2e", driver: "e2e", upstream_receipt_sha256: "-" }));
  boundary(
    "an evidence hash changed after publication",
    BX("api", "pass", "other"),
    "#1boundary receipt's registered evidence hash no longer matches the artifact on disk (tampered or substituted after publication)",
    QX({}),
  );
}, 120000);

// --- QD: qaStoreCaseBodySha --------------------------------------------------
// The body hashes of mk_plan's rows C-1, C-2 and 1.
const BODY_C1 = "4f3644d4f51db47048efaa3d260f4f051e98bb3542cf3ef71354d2b31a97c8b5";
const BODY_C2 = "eddf03cd9d398fa436a22de9e2f562f59ca560d90f5ff68c6813c6a6eb856976";
const BODY_1 = "a3a2eb9698b26e0fed9e95ef21a2cf15a1bac7993e0aec3bca180eaad025d454";
// C-1's row with a byte that is no UTF-8 in its precondition, and its body hash under C.
const PLAN_BYTE = "printf '| C-1 | t | api | - | caf\\351 | s | e | x |\\n' >plan.md";
const BODY_BYTE = "08cdd96eb73bc2df1b827ca96aa0c8114bcb68344fa648d3abf9d031c3954296";
const bodySha = (label: string, id: string, want: string, seed = "mk_plan", env?: Record<string, string>, err: string | RegExp = ""): void =>
  is(label, { seed, args: [id], env, twin: 'out("[" + Q.qaStoreCaseBodySha(S + "/plan.md", A[0]) + "]");' }, `[${want}]`, { err });

test("QD: a test-plan row's body hash, - where there is none", () => {
  bodySha("a row", "C-1", BODY_C1);
  bodySha("a row whose cells are padded", "C-2", BODY_C2);
  bodySha("the header row's id", "id", "68fb8fda38ef0d77c2ab8dee572f5a4da3b5b9a3e55007812d2854a9b2dbfee6");
  bodySha("01 is the row of 1 to awk's ==", "01", "-");
  bodySha("an id no row has", "C-9", "-");
  bodySha("no plan", "C-1", "-", ":");
  bodySha("a row holding only its id", "C-1", "be5be69f55e91af25e54ecc2154d4da359b67b3b27e25f5cc0b3ff54eb74dff3", "printf '| C-1 |\\n' >plan.md");
  bodySha("a byte that is no UTF-8 (C)", "C-1", BODY_BYTE, PLAN_BYTE, { LC_ALL: "C" });
  bodySha("a byte that is no UTF-8 (en_US.UTF-8): awk aborts, no body", "C-1", "-", PLAN_BYTE, { LC_ALL: "en_US.UTF-8" }, /^awk: /);
}, 120000);

// --- QI: qaStoreHistoryAppend ------------------------------------------------
const history = (label: string, seed: string, want: string, o: { args?: string[]; env?: Record<string, string>; err?: string | RegExp; wrote?: Record<string, string | null> } = {}): void =>
  is(
    label,
    {
      seed: `mk_plan; ${seed}`,
      args: o.args ?? ["s3", "m", "t"],
      env: { PATH: DATE_PATH, ...o.env },
      twin: 'out("[" + Q.qaStoreHistoryAppend(S + "/store", S + "/cases.tsv", S + "/plan.md", ...A) + "]");',
    },
    `[${want}]`,
    { err: o.err, wrote: o.wrote },
  );
const LEDGER3 = "{ crow C-1 api pass g; crow C-2 web fail defect; crow 1 db pass flaky; } >cases.tsv";
// A history line as qaStoreHistoryAppend writes it on the stub clock's day.
const hist = (id: string, tier: string, status: string, cls: string, body: string, model = "m", task = "t"): string => `s3\t2026-10-10\t${id}\t${tier}\t${status}\t${cls}\t${body}\t${model}\t${task}\n`;
const H = "store/history.tsv";

test("QI: one history line per ledger row this sha has not recorded", () => {
  history("a fresh store", LEDGER3, "3", { wrote: { [H]: hist("C-1", "api", "pass", "g", BODY_C1) + hist("C-2", "web", "fail", "defect", BODY_C2) + hist("1", "db", "pass", "flaky", BODY_1) } });
  history("no ledger", ":", "0");
  history("the same sha again appends nothing", `${LEDGER3}; mkdir -p store; hrow s3 C-1 pass g x; hrow s3 C-2 fail defect x; hrow s3 1 pass flaky x`, "0");
  history("only the rows this sha has not recorded", `${LEDGER3}; mkdir -p store; hrow s3 C-1 pass g x; hrow s2 C-2 fail defect x`, "2", {
    wrote: { [H]: "s3\t2026-01-01\tC-1\tapi\tpass\tg\tx\tm\tt\ns2\t2026-01-01\tC-2\tapi\tfail\tdefect\tx\tm\tt\n" + hist("C-2", "web", "fail", "defect", BODY_C2) + hist("1", "db", "pass", "flaky", BODY_1) },
  });
  history("01 is the history's 1 to awk's ==", "crow 01 db pass g >cases.tsv; mkdir -p store; hrow s3 1 pass g x", "0");
  history("an empty class, model and task read -", "crow C-1 api pass '' >cases.tsv", "1", { args: ["s3", "", ""], wrote: { [H]: hist("C-1", "api", "pass", "-", BODY_C1, "-", "-") } });
  history("no model or task given", "crow C-1 api pass g >cases.tsv", "1", { args: ["s3"], wrote: { [H]: hist("C-1", "api", "pass", "g", BODY_C1, "-", "-") } });
  history("an empty column is no field to IFS=TAB read", "printf 'C-1\\t\\tpass\\tg\\n' >cases.tsv", "1", { wrote: { [H]: hist("C-1", "pass", "g", "-", BODY_C1) } });
  history("a blank line, a leading TAB and an unterminated last line", "printf '\\n\\tC-2\\tweb\\tpass\\nC-1\\tapi\\tpass\\tg' >cases.tsv", "1", { wrote: { [H]: hist("C-2", "web", "pass", "-", BODY_C2) } });
  history("no plan: every body is -", `${LEDGER3}; rm plan.md`, "3", { wrote: { [H]: hist("C-1", "api", "pass", "g", "-") + hist("C-2", "web", "fail", "defect", "-") + hist("1", "db", "pass", "flaky", "-") } });
  history("a store that is a file: every write fails, every row counts", `${LEDGER3}; : >store`, "3", { err: /^mkdir: / });
  history("a plan byte that is no UTF-8 (C)", `crow C-1 api pass g >cases.tsv; ${PLAN_BYTE}`, "1", { env: { LC_ALL: "C" }, wrote: { [H]: hist("C-1", "api", "pass", "g", BODY_BYTE) } });
  history("a plan byte that is no UTF-8 (en_US.UTF-8): no body", `crow C-1 api pass g >cases.tsv; ${PLAN_BYTE}`, "1", { env: { LC_ALL: "en_US.UTF-8" }, err: /^awk: /, wrote: { [H]: hist("C-1", "api", "pass", "g", "-") } });
}, 120000);

// --- QO: qaStorePromote ------------------------------------------------------
const PROMOTE_TWIN = 'out("[" + Q.qaStorePromote(S + "/store", S + "/cases.tsv", S + "/plan.md", "s3", ...A) + "]");';
const promote = (label: string, seed: string, want: string, wrote: Record<string, string | null> | undefined, after?: string): void =>
  is(label, { seed: `mk_plan; mkdir -p store; ${seed}`, args: after === undefined ? [] : [after], env: { PATH: DATE_PATH }, twin: PROMOTE_TWIN }, `[${want}]`, { wrote });
// passes <row>... - C-1's history rows, oldest first, "$b" its plan body's hash
const passes = (...rows: string[]): string => `b="$(bodysha C-1)"; ${rows.map((r) => `hrow ${r}`).join("; ")}`;
const RUN = "crow C-1 api pass g >cases.tsv";
const THREE = passes('s1 C-1 pass g "$b"', 's2 C-1 pass g "$b"', 's3 C-1 pass g "$b"');
const CASE_C1 =
  "# C-1\n\nsurface: api (http)\nneeds: -\nfixtures: -\nprecondition: user exists\nsteps: POST /login\nexpected: 200\nprovenance: promoted after consecutive passes (store-curate)\nverified: s3 2026-10-10\nstatus: active\n";
const CATALOG_C1 = "- C-1 | api (http) | 200 | verified s3 2026-10-10\n";
const PROMOTED = { "store/cases/C-1.md": CASE_C1, "store/catalog.md": `# Case catalog\n${CATALOG_C1}` };
const NONE = { "store/cases": "<dir>", "store/cases/C-1.md": null, "store/catalog.md": null };
const HELD = "promoted=0 reverified=0";

test("QO: consecutive passes of one body promote a run-local case", () => {
  promote("three passes in a row, the catalog started", `${RUN}; ${THREE}`, "promoted=1 reverified=0", PROMOTED);
  promote("an existing catalog appended to", `${RUN}; printf '# Case catalog\\n- X | y (z) | e | verified a b\\n' >store/catalog.md; ${THREE}`, "promoted=1 reverified=0", {
    "store/cases/C-1.md": CASE_C1,
    "store/catalog.md": `# Case catalog\n- X | y (z) | e | verified a b\n${CATALOG_C1}`,
  });
  promote("two passes are short of three", `${RUN}; ${passes('s2 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`, HELD, NONE);
  promote("two passes meet a promote-after of 2", `${RUN}; ${passes('s2 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`, "promoted=1 reverified=0", PROMOTED, "2");
  promote("a fail ends the streak", `${RUN}; ${passes('s1 C-1 pass g "$b"', 's2 C-1 fail defect "$b"', 's3 C-1 pass g "$b"')}`, HELD, NONE);
  promote("a flaky row neither counts nor ends it", `${RUN}; ${passes('s1 C-1 pass g "$b"', 's2 C-1 pass g "$b"', 's25 C-1 fail flaky "$b"', 's3 C-1 pass g "$b"')}`, "promoted=1 reverified=0", PROMOTED);
  promote("one sha counts once", `${RUN}; ${passes('s1 C-1 pass g "$b"', 's3 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`, HELD, NONE);
  promote("a changed body ends the streak", `${RUN}; ${passes("s1 C-1 pass g other", 's2 C-1 pass g "$b"', 's3 C-1 pass g "$b"')}`, HELD, NONE);
  promote("the run's row is no pass", `crow C-1 api fail defect >cases.tsv; ${THREE}`, HELD, NONE);
  promote("the run's pass is flaky", `crow C-1 api pass flaky >cases.tsv; ${THREE}`, HELD, NONE);
  promote("no plan: no body to match", `${RUN}; ${THREE}; rm plan.md`, HELD, NONE);
  promote("a promote-after that [ cannot compare", `${RUN}; ${THREE}`, HELD, NONE, "x");
  promote("no history", RUN, HELD, undefined);
  promote("no ledger", THREE, HELD, undefined);
}, 120000);

test("QO: a stored case that passed again is re-verified", () => {
  promote(
    "its verified line and its catalog line moved",
    `mkdir -p store/cases; printf '# C-1\\nsurface: api (http)\\nverified: s1 2026-01-01\\nstatus: active\\n' >store/cases/C-1.md; printf '# Case catalog\\n- C-1 | api (http) | 200 | verified s1 2026-01-01\\n- C-10 | api (http) | 200 | verified s1 2026-01-01\\n' >store/catalog.md; hrow s1 C-1 pass g x; ${RUN}`,
    "promoted=0 reverified=1",
    {
      "store/cases/C-1.md": "# C-1\nsurface: api (http)\nverified: s3 2026-10-10\nstatus: active\n",
      "store/catalog.md": `# Case catalog\n${CATALOG_C1}- C-10 | api (http) | 200 | verified s1 2026-01-01\n`,
    },
  );
  promote("no verified line: one appended, no catalog", `mkdir -p store/cases; printf '# C-1\\n' >store/cases/C-1.md; hrow s1 C-1 pass g x; ${RUN}`, "promoted=0 reverified=1", {
    "store/cases/C-1.md": "# C-1\nverified: s3 2026-10-10\n",
    "store/catalog.md": null,
  });
}, 120000);

test("QO: a planted <f>.tmp is left alone - the twin takes its own temp (EXCLUSIVE TEMP FILES, W14)", () => {
  const t = twin("a planted temp", {
    seed: `mk_plan; mkdir -p store/cases; printf '# C-1\\nverified: s1 2026-01-01\\n' >store/cases/C-1.md; printf 'outside\\n' >outside.txt; ln -s ../../outside.txt store/cases/C-1.md.tmp; hrow s1 C-1 pass g x; ${RUN}`,
    env: { PATH: DATE_PATH },
    twin: PROMOTE_TWIN,
  });
  expect([t.out, t.err]).toEqual(["[promoted=0 reverified=1]", ""]);
  expect(lstatSync(join(t.root, "store/cases/C-1.md")).isFile()).toBe(true);
  expect(readFileSync(join(t.root, "store/cases/C-1.md"), "latin1")).toBe("# C-1\nverified: s3 2026-10-10\n");
  expect(lstatSync(join(t.root, "store/cases/C-1.md.tmp")).isSymbolicLink()).toBe(true);
  expect(readFileSync(join(t.root, "outside.txt"), "latin1")).toBe("outside\n");
}, 120000);

// --- QL: qaStoreCalibration --------------------------------------------------
const calibration = (label: string, seed: string, want: string, err: string | RegExp = ""): void =>
  is(label, { seed, env: { PATH: DATE_PATH }, twin: 'const r = Q.qaStoreCalibration(S + "/h.tsv", S + "/l.tsv"); out(r.out + "#" + r.status);' }, want, { err });
const AT = '"computed_at":"2026-10-10T12:00:00Z"';
const NO_PAIR = `{"n":0,"agreement":null,"kappa":null,${AT}}#0`;

test("QL: Cohen's kappa between the pane's defect calls and the chief's labels", () => {
  calibration("no labels", "hl s1 C-1 fail defect", NO_PAIR);
  calibration("no history", "ll s1 C-1 confirmed", NO_PAIR);
  calibration(
    "agreement, kappa and both sides' positives",
    "hl s1 C-1 fail defect; ll s1 C-1 confirmed; hl s1 C-2 pass g; ll s1 C-2 not-a-defect; hl s2 C-1 fail defect; ll s2 C-1 not-a-defect; hl s2 C-2 pass g; ll s2 C-2 confirmed; hl s3 C-3 pass g; ll s3 C-3 not-a-defect",
    `{"n":5,"agreement":0.6000,"kappa":0.1667,"positives_judge":2,"positives_human":2,${AT}}#0`,
  );
  calibration("every pair a defect on both sides: pe is 1", "hl s1 C-1 fail defect; ll s1 C-1 confirmed; hl s2 C-1 fail defect; ll s2 C-1 confirmed", `{"n":2,"agreement":1.0000,"kappa":1.0000,"positives_judge":2,"positives_human":2,${AT}}#0`);
  calibration(
    "no defect claim, no label and an unknown label word are passed over",
    "hl s1 C-1 fail environment; ll s1 C-1 confirmed; hl s1 C-2 unverifiable -; ll s1 C-2 confirmed; hl s1 C-3 pass flaky; ll s1 C-3 not-a-defect; hl s2 C-4 pass g; hl s1 C-5 fail defect; ll s1 C-5 maybe",
    `{"n":1,"agreement":1.0000,"kappa":1.0000,"positives_judge":0,"positives_human":0,${AT}}#0`,
  );
  calibration("no pair at all", "hl s1 C-1 fail defect; ll s9 C-1 confirmed", NO_PAIR);
  calibration("a label given twice: the last word wins", "hl s1 C-1 fail defect; ll s1 C-1 confirmed; ll s1 C-1 not-a-defect", `{"n":1,"agreement":0.0000,"kappa":0.0000,"positives_judge":1,"positives_human":0,${AT}}#0`);
}, 120000);

test.skipIf(ROOTUSER)("QL: a label file awk cannot read", () => {
  calibration("unreadable labels", "hl s1 C-1 fail defect; ll s1 C-1 confirmed; chmod 000 l.tsv", "#2", /^awk: /);
}, 120000);

// --- QY: yamlKeys / yamlHas --------------------------------------------------
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
// Per key: `<key>`, its child keys one per line, `#<yamlKeys status>`, `has#<yamlHas answer>`; the empty key last.
const yaml = (label: string, seed: string, file: string, keys: [string, string, number, number][], err: string | RegExp = "", env?: Record<string, string>): void =>
  is(
    label,
    {
      seed,
      args: [file, keys.map(([k]) => k).filter((k) => k !== "").join(",")],
      env,
      twin: 'for (const k of [...A[1].split(","), ""]) { out("<" + k + ">"); const r = L.yamlKeys(S + "/" + A[0], k); out(r.out); out("#" + r.status + "\\n"); out("has#" + L.yamlHas(S + "/" + A[0], k) + "\\n"); }',
    },
    keys.map(([k, children, st, has]) => `<${k}>${children}#${st}\nhas#${has}\n`).join(""),
    { err },
  );

test("QY: a block's immediate child keys and a key's presence, through awk", () => {
  yaml("the flat subset", `cat >c.yaml <<'EOF'\n${YAML}\nEOF`, "c.yaml", [
    ["qa", "serve\nscopes\ne2e\nempty\n", 0, 0],
    ["qa.scopes", "shop\nblog\n", 0, 0],
    ["qa.scopes.shop", "apps\n", 0, 0],
    ["qa.scopes.shop.apps", "web\n", 0, 0],
    ["qa.scopes.shop.apps.web", "serve\n", 0, 0],
    ["qa.e2e", "odd\nendpoint_env\n", 0, 0],
    ["qa.e2e.endpoint_env", "API\nDB\n", 0, 0],
    ["qa.serve", "", 0, 0],
    ["qa.empty", "", 0, 0],
    ["qa.none", "", 0, 1],
    ["other", "", 0, 0],
    ["nope.deeper", "", 0, 1],
    ["", "", 0, 1],
  ]);
  yaml("no such file", ":", "none.yaml", [["qa", "", 2, 2], ["", "", 2, 2]], /^awk: /);
  const twoKeys: [string, string, number, number][] = [["qa", "scopes\n", 0, 0], ["qa.scopes", "a\n", 0, 0], ["", "", 0, 1]];
  yaml("a last line with no LF", "printf 'qa:\\n  scopes:\\n    a: 1' >c.yaml", "c.yaml", twoKeys);
  const byte = "printf 'qa:\\n  caf\\351: x\\n  scopes:\\n    a: 1\\n' >c.yaml";
  yaml("a key byte that is no UTF-8 (C)", byte, "c.yaml", twoKeys, "", { LC_ALL: "C" });
  yaml("a key byte that is no UTF-8 (en_US.UTF-8): awk aborts", byte, "c.yaml", [["qa", "", 2, 0], ["qa.scopes", "", 2, 2], ["", "", 2, 2]], /^awk: /, { LC_ALL: "en_US.UTF-8" });
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
