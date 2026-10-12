// merge-local.test.ts - what src/merge-local.ts brought into src/, held to its
// bash originals differentially: landingWarn against ac_landing_warn and
// landingRecord against ac_landing_record over one ledger (the 24 h window,
// the own-family skip, awk's numeric reading of the epoch and the family, a
// header line, a path with spaces, the empty-family record that shifts the
// read, the 7-day prune), the record's exclusive temp past a planted symlink,
// knowledgeWarn against ac_knowledge_warn, and qaGateOk against a direct bash
// call of ac_qa_gate_ok along one fixture (tests/ts/qa-gate.test.ts holds the
// gate's whole matrix). The bash runs as the entry ran these helpers - bare,
// under `set -euo pipefail`.
// The CLI contract itself is tests/sh/ac-merge-local.test.sh's, whose
// differential leg runs the frozen bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { landingRecord } from "../../src/lib.ts";
import { retiredBin } from "./retired-bin.ts";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const binDir = join(ROOT, "bin");
const RBIN = retiredBin();
const LIB = join(ROOT, "src", "lib.ts");
const NOW = 1767225600;
const made: string[] = [];
afterAll(() => {
  delete process.env.AC_HOME;
  delete process.env.EPOCHSECONDS;
  made.forEach((d) => rmSync(d, { recursive: true, force: true }));
});

function freshHome(): string {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-merge-local-")));
  made.push(h);
  mkdirSync(join(h, "state"), { recursive: true });
  return h;
}

type Run = { out: string; err: string; rc: number };
const read = (r: ReturnType<typeof Bun.spawnSync>): Run => ({ out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 });
const envFor = (home: string): Record<string, string> => ({ PATH: process.env.PATH!, LC_ALL: "C", AC_HOME: home, EPOCHSECONDS: String(NOW) });

// The bash helpers sourced from this checkout's bin/, $1.. the arguments.
function bash(home: string, libs: string, script: string, args: string[]): Run {
  return read(Bun.spawnSync(["/bin/bash", "-c", `set -euo pipefail; . "$0/ac-lib.sh"; ${libs}${script}`, binDir, ...args], { env: envFor(home), stdout: "pipe", stderr: "pipe" }));
}

// The twin in a bun child started in the distro root, as bin/ac-bun.sh starts
// a module (STARTED_BIN is <root>/bin), so its fd 2 and its exit are captured.
function twin(home: string, body: string): Run {
  const src = `import * as L from ${JSON.stringify(LIB)};\nconst A = JSON.parse(process.env.TWIN_ARGS ?? "[]");\ntry { ${body} } catch (e) { const s = (e as { status?: number }).status; if (s === undefined) throw e; process.exit(s); }\n`;
  return read(Bun.spawnSync([process.execPath, "-e", src], { env: { ...envFor(home), TWIN_ARGS: JSON.stringify(twinArgs) }, cwd: ROOT, stdout: "pipe", stderr: "pipe" }));
}
let twinArgs: string[] = [];

const LEDGER = [
  `${NOW - 3600}\tdrain-race\tcrewfile.txt`,
  `${NOW - 60}\tfam\tcrewfile.txt`,
  `${NOW - 25 * 3600}\tstranger\tcrewfile.txt`,
  "epoch\tfamily\tcrewfile.txt",
  `${NOW - 7200}\t07\tcrewfile.txt`,
  `${NOW - 100}x\tprefixed\ta b.txt`,
  `0x${(NOW - 5 * 3600).toString(16)}\thex\tcrewfile.txt`,
  `${NOW + 3600}\tfuture\tcrewfile.txt`,
  `${NOW - 10}\tother\tnot-landed.txt`,
  `${NOW - 10}\tfan\tcrewfile.txt\textra`,
  `${NOW - 10}\t\t5`,
  `${NOW - 8 * 86400}\told\tcrewfile.txt`,
  `${NOW - 30}\tcr\tcrewfile.txt\r`,
].join("\n");

test("landingWarn prints what ac_landing_warn prints: the window, the own family (numeric too), awk's reading of every epoch, the archived room", () => {
  const h = freshHome();
  writeFileSync(join(h, "state", ".landings"), `${LEDGER}\n${NOW - 20}\tlast\ta b.txt`);
  mkdirSync(join(h, "data", "archive", "2026", "hex"), { recursive: true });
  writeFileSync(join(h, "data", "archive", "2026", "hex", "room.md"), "x\n");
  for (const args of [["fam", "crewfile.txt", "a b.txt", "5"], ["7", "crewfile.txt"], ["fam"], ["nobody", "a b.txt"]]) {
    twinArgs = args;
    const want = bash(h, "", 'ac_landing_warn "$@"', args);
    const got = twin(h, "L.landingWarn(A[0], A.slice(1));");
    expect({ args, ...got }).toEqual({ args, ...want });
  }
  twinArgs = ["fam"];
  expect(twin(h, "L.landingWarn(A[0], A.slice(1));").err).toBe("");
  twinArgs = ["fam", "crewfile.txt"];
  const one = twin(h, "L.landingWarn(A[0], A.slice(1));").err;
  expect(one).toContain(`WARN: LANDING-OVERLAP: crewfile.txt landed 1h ago by family drain-race - required reading: ${h}/data/drain-race/room.md\n`);
  expect(one).toContain(`landed 5h ago by family hex - required reading: ${h}/data/archive/2026/hex/room.md\n`);
  expect(one).toContain("landed -1h ago by family future");
  expect(one).toContain("by family 07 ");
  twinArgs = ["7", "crewfile.txt"];
  const seven = twin(h, "L.landingWarn(A[0], A.slice(1));").err;
  expect(seven).not.toContain("family 07");
  expect(seven).toContain("by family drain-race ");
});

test("landingWarn: an empty-family record shifts the read - a path the shell's arithmetic refuses ends the run with 1, an unreadable ledger with awk's 2", () => {
  const h = freshHome();
  writeFileSync(join(h, "state", ".landings"), `${NOW - 10}\t\tg\n`);
  twinArgs = ["fam", "g"];
  const want = bash(h, "", 'ac_landing_warn "$@"', twinArgs);
  const got = twin(h, "L.landingWarn(A[0], A.slice(1));");
  expect(want.rc).toBe(1);
  expect(want.err).toContain("g: unbound variable");
  expect({ rc: got.rc, out: got.out, err: got.err }).toEqual({ rc: 1, out: "", err: "" });
  if (process.getuid?.() !== 0) {
    writeFileSync(join(h, "state", ".landings"), `${NOW - 10}\tx\tg\n`);
    chmodSync(join(h, "state", ".landings"), 0);
    const w = bash(h, "", 'ac_landing_warn "$@"', twinArgs);
    const g = twin(h, "L.landingWarn(A[0], A.slice(1));");
    expect(w.rc).toBe(2);
    expect(w.err).toContain("can't open file");
    expect({ rc: g.rc, out: g.out, err: g.err }).toEqual({ rc: 2, out: "", err: "" });
  }
});

test("landingRecord writes the ledger ac_landing_record writes: the 7-day prune by awk's numbers, the new records, no lock and no temp left", () => {
  const ledger = `${LEDGER}\n123abc\tgarbage\tx\n${NOW - 604800}\tedge\ty\n${NOW - 20}\tlast\tno-lf`;
  const hb = freshHome();
  const ht = freshHome();
  for (const h of [hb, ht]) writeFileSync(join(h, "state", ".landings"), ledger);
  twinArgs = ["fam", "crewfile.txt", "a b.txt"];
  const want = bash(hb, "", 'ac_landing_record "$@"', twinArgs);
  const got = twin(ht, "process.stdout.write(String(L.landingRecord(A[0], A.slice(1))));");
  expect(want).toEqual({ out: "", err: "", rc: 0 });
  expect(got).toEqual({ out: "true", err: "", rc: 0 });
  const recB = readFileSync(join(hb, "state", ".landings"), "latin1");
  expect(readFileSync(join(ht, "state", ".landings"), "latin1")).toBe(recB);
  expect(recB).toContain(`${NOW - 604800}\tedge\ty\n`);
  expect(recB).not.toContain("old\t");
  expect(recB.endsWith(`${NOW}\tfam\tcrewfile.txt\n${NOW}\tfam\ta b.txt\n`)).toBe(true);
  expect(readdirSync(join(ht, "state")).sort()).toEqual(readdirSync(join(hb, "state")).sort());
  // no paths: no write, no lock, nothing minted
  const hn = freshHome();
  twinArgs = ["fam"];
  expect(twin(hn, "process.stdout.write(String(L.landingRecord(A[0], A.slice(1))));").out).toBe("true");
  expect(readdirSync(join(hn, "state"))).toEqual([]);
});

test("landingRecord creates its temp exclusively: a planted symlink at <ledger>.tmp.<pid> is never written through", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  process.env.EPOCHSECONDS = String(NOW);
  const f = join(h, "state", ".landings");
  writeFileSync(f, `${NOW - 10}\tprior\tp\n`);
  writeFileSync(join(h, "victim"), "victim\n");
  symlinkSync(join(h, "victim"), `${f}.tmp.${process.pid}`);
  expect(landingRecord("fam", ["crewfile.txt"])).toBe(true);
  expect(readFileSync(join(h, "victim"), "latin1")).toBe("victim\n");
  expect(readlinkSync(`${f}.tmp.${process.pid}`)).toBe(join(h, "victim"));
  expect(lstatSync(f).isFile()).toBe(true);
  expect(readFileSync(f, "latin1")).toBe(`${NOW - 10}\tprior\tp\n${NOW}\tfam\tcrewfile.txt\n`);
  expect(readdirSync(join(h, "state")).sort()).toEqual([".landings", `.landings.tmp.${process.pid}`]);
});

function gitRepo(dir: string): void {
  mkdirSync(dir, { recursive: true });
  for (const a of [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["commit", "-q", "--allow-empty", "-m", "i"]])
    expect(Bun.spawnSync(["git", "-C", dir, ...a]).exitCode).toBe(0);
}

test("knowledgeWarn flags what ac_knowledge_warn flags: no record, a sibling's entry, a superseded or CRLF one; silent on the family's own and on a dead or non-repo dir", () => {
  const h = freshHome();
  const repo = join(h, "projects", "proj");
  gitRepo(repo);
  expect(Bun.spawnSync(["git", "-C", repo, "worktree", "add", "-q", join(h, "wt"), "-b", "side"]).exitCode).toBe(0);
  mkdirSync(join(h, "plain"));
  const rec = join(h, "records", "repo-knowledge", "proj.md");
  const cases: [string, string | null, string[]][] = [
    ["none", null, ["fam", repo]],
    ["sibling", "- fact x | src: cmd:true | at: d 2026-07-21 | by: other\n", ["fam", repo]],
    ["own", "- fact x | src: cmd:true | at: d 2026-07-21 | by: fam\n", ["fam", repo]],
    ["own via the worktree", "- fact x | by: fam\n", ["fam", join(h, "wt")]],
    ["superseded", "## Superseded\n- fact x | by: fam\n", ["fam", repo]],
    ["crlf", "- fact x | by: fam\r\n", ["fam", repo]],
    ["not a bullet", "fact x | by: fam\n", ["fam", repo]],
    ["escaped family", "- fact x | by: a\tb\n", ["a\\tb", repo]],
    ["dead dir", null, ["fam", join(h, "gone")]],
    ["non-repo dir", null, ["fam", join(h, "plain")]],
    ["no family", null, ["", repo]],
  ];
  for (const [name, body, args] of cases) {
    rmSync(rec, { force: true });
    if (body !== null) {
      mkdirSync(join(rec, ".."), { recursive: true });
      writeFileSync(rec, body);
    }
    twinArgs = args;
    const want = bash(h, "", 'ac_knowledge_warn "$@"', args);
    const got = twin(h, "L.knowledgeWarn(A[0], A[1]);");
    expect({ name, ...got }).toEqual({ name, ...want });
  }
  rmSync(rec, { force: true });
  twinArgs = ["fam", repo];
  expect(twin(h, "L.knowledgeWarn(A[0], A[1]);").err).toBe(
    `WARN: KNOWLEDGE-GAP: family fam is landing on proj with no repo-knowledge entry -\nrecord what it learned (${ROOT}/bin/ac-know.sh add --home ${h} --repo ${repo} --family fam --src-file <path>:<line> --fact '<what you learned>')\nor dismiss if it learned nothing about the codebase. Record: ${rec}\n`,
  );
});

test("qaGateOk answers as ac_qa_gate_ok sourced by hand: not required, flat refusal, scoped pass, the matrix, and the RETIRED die as an exit", () => {
  const h = freshHome();
  const repo = join(h, "projects", "gproj");
  gitRepo(repo);
  const sha = Bun.spawnSync(["git", "-C", repo, "rev-parse", "HEAD"]).stdout.toString().trim();
  const yaml = join(h, "projects", "gproj.yaml");
  const passed = join(repo, ".crew", "qa", "passed");
  mkdirSync(passed, { recursive: true });
  const marker = (scope: string, app: string, key: string): string =>
    `schema=agentcrew.qa-attestation/v2\noutcome=passed\nrun=r\ntask=t\ncompleted_at=2026-07-24T00:00:00Z\nsource_sha=${sha}\nprofile_key=${key}\nprofile_sha256=p\nconfig_sha256=c\ncases_passed=1\ncases_total=1\nscope=${scope}\napp=${app}\n`;
  const steps: [string, () => void][] = [
    ["not required", () => {}],
    ["flat, no marker", () => writeFileSync(yaml, "qa:\n  require_for_ship: true\n")],
    [
      "scoped pass",
      () => {
        writeFileSync(yaml, 'qa:\n  require_for_ship: true\n  scopes:\n    orchid:\n      seed: "true"\n');
        mkdirSync(join(h, "records", "repo-knowledge"), { recursive: true });
        writeFileSync(join(h, "records", "repo-knowledge", "gproj.md"), "- scope orchid = orchid-service | src: cmd:true | at: d 2026-07-21 | by: f\n");
        writeFileSync(join(passed, `${sha}.orchid.orchid-service`), marker("orchid", "orchid-service", "gproj/orchid/orchid-service"));
      },
    ],
    [
      "matrix, one of two",
      () => {
        mkdirSync(join(h, "data", "t1", "qa"), { recursive: true });
        writeFileSync(join(h, "data", "t1", "qa", "manifest.json"), '{"required_profiles":[{"profile_key":"gproj/orchid/orchid-service"},{"profile_key":"gproj/cedar/cedar-service"}]}\n');
      },
    ],
    [
      "RETIRED legacy config",
      () => {
        mkdirSync(join(h, "config", "projects"), { recursive: true });
        writeFileSync(join(h, "config", "projects", "gproj.yaml"), "qa:\n  require_for_ship: true\n");
      },
    ],
  ];
  twinArgs = [repo, sha, "t1"];
  for (const [name, seed] of steps) {
    seed();
    const want = bash(h, `. "${RBIN}/ac-pipeline-lib.sh"; . "${RBIN}/ac-qa-lib.sh"; `,'ac_qa_gate_ok "$@" && rc=0 || rc=$?; printf "#%s" "$rc"', twinArgs);
    const got = twin(h, 'process.stdout.write("#" + (L.qaGateOk(A[0], A[1], A[2]) ? 0 : 1));');
    expect({ name, ...got }).toEqual({ name, ...want });
  }
  const last = twin(h, 'L.qaGateOk(A[0], A[1], A[2]); process.stdout.write("returned");');
  expect(last).toEqual({ out: "", err: expect.stringContaining("RETIRED legacy path"), rc: 1 });
}, 30000);
