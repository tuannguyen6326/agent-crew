// gate.test.ts - what src/gate.ts brought into src/lib.ts, held to the LIVE
// bash it twins: harnessKnown (ac_harness_known), chiefBusyPath and
// chiefBusyHeld (ac_chief_busy_path / ac_chief_busy_held, which ac-verify and
// ac-watch keep calling), transcriptFinal (ac_transcript_final),
// maintenancePlanValidate (ac_maintenance_plan_validate, frozen at
// tests/fixtures/ac-maintenance-retired.sh for the oracles) and herdrTabOpen (ac_herdr_tab_open, which ac-ship,
// ac-qa and the pane agent keep calling); and the read-evidence floor the
// prompt prints, held to the lib's AC_MAINTENANCE_QUOTE_MIN. The CLI contract
// itself is tests/sh/ac-gate.test.sh's, whose differential leg runs the frozen
// original beside the shim.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home, a family data dir, markers, transcripts, a maintenance run with its plan and staged files, a fake herdr logging its argv to <side>/herdr.log); argv; env (PATH = a fake-herdr dir, then the host's bun and jq, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C; HOME, TMPDIR, AC_HOME only where a row sets it); cwd (the distro root); stdin (/dev/null); stdout, stderr, the status and the side root's files after the call compared whole (the side root spelled S).
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-gate-ts-")));
afterAll(() => {
  // Rows that take a permission away leave it gone; give it back to remove them.
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["herdr", "orca", "docker", "codegraph", "jq"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["bun", "jq"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const NOJQ = join(W, "nojq");
mkdirSync(NOJQ);
symlinkSync(Bun.which("bun")!, join(NOJQ, "bun"));
const FAKE = join(W, "fake");
mkdirSync(FAKE);
// A herdr that logs its argv and answers from <side>/answers/<verb>-<noun>
// (exit 1 when the answer file is missing).
writeFileSync(
  join(FAKE, "herdr"),
  `#!/bin/sh
printf '%s\\n' "herdr $*" >>"$SIDE/herdr.log"
a="$1"; [ "$a" = --session ] && { shift 2; a="$1"; }
f="$SIDE/answers/$1-$2"
[ -f "$f" ] || exit 1
cat "$f"
`,
);
chmodSync(join(FAKE, "herdr"), 0o755);
const PATH = `${FAKE}:${TOOLS}:${BASE}`;

type Row = {
  // the bash call, run after sourcing ac-lib.sh and <libs>, its arguments "$@"
  bash: string;
  libs?: string[];
  // the twin's body: L is src/lib.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  path?: string;
};
type Side = { out: string; err: string; rc: number | null; files: string; herdr: string };

function listing(s: string): string {
  const lines: string[] = [];
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      lines.push(p.slice(s.length));
      try {
        if (!lstatSync(p).isSymbolicLink() && statSync(p).isDirectory()) walk(p);
      } catch {}
    }
  };
  walk(s);
  return lines.join("\n");
}

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH: row.path ?? PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const libs = (row.libs ?? []).map((l) => `. "$0/${l}" || exit $?;`).join(" ");
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; ${libs} ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const A = ${JSON.stringify(args)}; const rc = await (async () => { ${row.twin} })(); writeSync(1, "|rc=" + rc);`,
      ];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const norm = (t: string): string => t.replaceAll(s, "S");
  const log = join(s, "herdr.log");
  const herdr = existsSync(log) ? norm(readFileSync(log, "latin1")) : "";
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), rc: r.exitCode, files: listing(s), herdr };
}

function pair(row: Row): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    mkdirSync(join(s, "home"), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]! };
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, rc: x.rc, files: x.files, herdr: x.herdr });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const sha = (b: string | Buffer): string => createHash("sha256").update(b).digest("hex");
const put = (p: string, b: string | Buffer): void => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, b);
};

test("harnessKnown: the registry's harness ids, never the process names", () => {
  for (const h of ["claude", "codex", "opencode", "pi", "cursor", "cursor-agent", "agy", "", "Claude", "codex ", "off"])
    same(`harness ${JSON.stringify(h)}`, {
      bash: `ac_harness_known "$1"`,
      twin: `return L.harnessKnown(A[0]) ? 0 : 1;`,
      args: [h],
    });
});

test("chiefBusyPath: <state dir>/.chief-busy-until.<family>", () => {
  for (const f of ["widget", "", "a b", "a/b"])
    same(`path ${f}`, {
      bash: `ac_chief_busy_path "$1" "$2"`,
      libs: ["ac-wake-lib.sh"],
      twin: `writeSync(1, L.chiefBusyPath(A[0], A[1]) + "\\n"); return 0;`,
      args: ["@S/home/state", f],
    });
});

// A live pid that outlives every row: this test process itself.
const LIVE = String(process.pid);
const busy = (seed: (s: string) => void): Row => ({
  bash: `ac_chief_busy_held "$1" "$2" "$3"`,
  libs: ["ac-wake-lib.sh"],
  twin: `return L.chiefBusyHeld(A[0], A[1], A[2]) ? 0 : 1;`,
  args: ["@S/home/state", "fam", "@S/home/data/fam"],
  seed: (s) => {
    mkdirSync(join(s, "home", "state"), { recursive: true });
    mkdirSync(join(s, "home", "data", "fam"), { recursive: true });
    seed(s);
  },
});
const mark = (s: string, rel: string, body: string): void => put(join(s, "home", rel), body);

test("chiefBusyHeld: held while a live gate marker or verifier holder remains, every dead one swept", () => {
  same("nothing", busy(() => {}));
  same("a live gate marker", busy((s) => mark(s, "data/fam/.gate-running.1", `family=fam\npid=${LIVE}\n`)));
  same("a dead gate marker", busy((s) => mark(s, "data/fam/.gate-running.99999999", "pid=99999999\n")));
  same("a live verifier holder", busy((s) => mark(s, "state/.chief-busy-holder.fam.1", `pid=${LIVE}\n`)));
  same("dead and live mixed: the dead swept, the live kept", busy((s) => {
    mark(s, "data/fam/.gate-running.2", "pid=99999998\n");
    mark(s, "state/.chief-busy-holder.fam.3", "pid=99999997\n");
    mark(s, "state/.chief-busy-holder.fam.4", `pid=${LIVE}\n`);
  }));
  same("pid 0, a leading zero, no pid, the last pid line", busy((s) => {
    mark(s, "data/fam/.gate-running.5", "pid=0\n");
    mark(s, "data/fam/.gate-running.6", `pid=0${LIVE}\n`);
    mark(s, "data/fam/.gate-running.7", "family=fam\n");
    mark(s, "data/fam/.gate-running.8", `pid=${LIVE}\npid=99999996\n`);
  }));
  same("another family's holder and a directory are not ours", busy((s) => {
    mark(s, "state/.chief-busy-holder.other.1", `pid=${LIVE}\n`);
    mkdirSync(join(s, "home", "data", "fam", ".gate-running.9"));
  }));
  same("no family data dir", { ...busy(() => {}), args: ["@S/home/state", "fam", "@S/home/data/none"] });
  // A dead mark that cannot be removed is rm's own complaint, never a throw.
  if (process.getuid?.() !== 0)
    same("a dead holder in a state dir that cannot be written", busy((s) => {
      mark(s, "state/.chief-busy-holder.fam.1", "pid=99999999\n");
      chmodSync(join(s, "home", "state"), 0o555);
    }));
});

test("chiefBusyHeld: an unreadable marker warns as ac_meta_get does, reads dead and is swept; quiet says nothing", () => {
  const unreadable = busy((s) => {
    mark(s, "data/fam/.gate-running.1", `pid=${LIVE}\n`);
    chmodSync(join(s, "home", "data", "fam", ".gate-running.1"), 0);
  });
  if (process.getuid?.() === 0) return;
  const p = same("unreadable", unreadable);
  expect(p.t.err).toBe("WARN: cannot read meta file S/home/data/fam/.gate-running.1\n");
  const q = pair({ ...unreadable, twin: `return L.chiefBusyHeld(A[0], A[1], A[2], true) ? 0 : 1;` });
  expect([q.t.out, q.t.err, q.t.files]).toEqual([q.o.out, "", q.o.files]);
});

const TRANSCRIPT: Row = {
  bash: `t="$(ac_transcript_final "$1")"; rc=$?; printf '%s' "$t"; (exit "$rc")`,
  libs: ["../tests/fixtures/ac-pipeline-lib.sh"],
  twin: `const r = L.transcriptFinal(A[0]); writeSync(1, Buffer.from(r.text, "latin1")); return r.status;`,
  args: ["@S/t.jsonl"],
};
const said = (...texts: string[]): string => `${JSON.stringify({ type: "assistant", message: { content: texts.map((t) => ({ type: "text", text: t })) } })}\n`;

test("transcriptFinal: the last assistant message's text parts, jq's status kept", () => {
  const cases: [string, string | null][] = [
    ["one message", said("# Decision\ncontinue\n")],
    ["the last of several, parts joined by LF", said("first") + JSON.stringify({ type: "user", message: { content: [] } }) + "\n" + said("a", "b")],
    ["a tool part between texts", `${JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "x" }, { type: "tool_use" }, { type: "text", text: "y" }] } })}\n`],
    ["no assistant message", `${JSON.stringify({ type: "user" })}\n`],
    ["not JSON", "not json\n"],
    ["empty", ""],
    ["trailing newlines and a NUL", said("body\u0000tail\n\n\n")],
    ["missing", null],
  ];
  for (const [label, body] of cases)
    same(`transcript: ${label}`, { ...TRANSCRIPT, seed: (s) => body !== null && writeFileSync(join(s, "t.jsonl"), body) });
  same("transcript: a directory", { ...TRANSCRIPT, seed: (s) => mkdirSync(join(s, "t.jsonl")) });
});

// A maintenance run under <home>/data with one staged file per action, the
// plan written by <plan> over the defaults.
type Action = { op: string; target: string; old_sha256: string; new_sha256: string; staged: string };
function run(s: string, edit: (p: Record<string, unknown>, a: Action[]) => void = () => {}, extra: (run: string, home: string, plan: string) => void = () => {}): void {
  const home = join(s, "home");
  const r = join(home, "data", "learning-1");
  put(join(r, "input-manifest.md"), "candidate evidence\n");
  put(join(r, "staged", "skills", "x", "SKILL.md"), "skill body\n");
  const actions: Action[] = [{ op: "write-skill", target: "skills/x/SKILL.md", old_sha256: "-", new_sha256: sha("skill body\n"), staged: "staged/skills/x/SKILL.md" }];
  const plan: Record<string, unknown> = { schema: "agentcrew.maintenance-plan/v1", mode: "learning", run_id: "learning-1", subject: "x", input_manifest_sha256: sha("candidate evidence\n"), actions };
  edit(plan, actions);
  extra(r, home, JSON.stringify(plan));
  if (!existsSync(join(r, "plan.json"))) put(join(r, "plan.json"), JSON.stringify(plan));
}
const VALIDATE = (edit?: (p: Record<string, unknown>, a: Action[]) => void, extra?: (run: string, home: string, plan: string) => void): Row => ({
  bash: `ac_maintenance_plan_validate "$1" "$2"`,
  libs: ["ac-maintenance-lib.sh", "ac-bun.sh", "../tests/fixtures/ac-maintenance-retired.sh"],
  twin: `return L.maintenancePlanValidate(A[0], A[1]) ? 0 : 1;`,
  args: ["@S/home/data/learning-1/plan.json", "@S/home/data/learning-1"],
  env: { AC_HOME: "@S/home" },
  seed: (s) => run(s, edit, extra),
});

test("maintenancePlanValidate: the closed schema, the paths and the staged hashes, as the frozen bash judges them", () => {
  const ok = same("a valid plan", VALIDATE());
  expect(ok.t.out).toBe("|rc=0");
  same("a second document", VALIDATE(undefined, (r) => put(join(r, "plan.json"), "{}\n{}\n")));
  same("not JSON", VALIDATE(undefined, (r) => put(join(r, "plan.json"), "nope\n")));
  same("an extra key", VALIDATE((p) => (p.extra = 1)));
  same("a wrong schema", VALIDATE((p) => (p.schema = "v2")));
  same("a wrong mode", VALIDATE((p) => (p.mode = "qa")));
  same("a subject with a newline", VALIDATE((p) => (p.subject = "x\n")));
  same("an uppercase manifest hash", VALIDATE((p) => (p.input_manifest_sha256 = sha("candidate evidence\n").toUpperCase())));
  same("an unknown op", VALIDATE((_, a) => (a[0]!.op = "delete-skill")));
  same("a dotdot target", VALIDATE((_, a) => (a[0]!.target = "skills/../x")));
  same("an absolute target", VALIDATE((_, a) => (a[0]!.target = "/skills/x")));
  same("a target outside the allowed roots", VALIDATE((_, a) => (a[0]!.target = "config/x")));
  same("a staged path outside staged/", VALIDATE((_, a) => (a[0]!.staged = "input-manifest.md")));
  same("a duplicate target", VALIDATE((_, a) => a.push({ ...a[0]! })));
  same("a staged hash mismatch", VALIDATE((_, a) => (a[0]!.new_sha256 = sha("other"))));
  same("a missing staged file", VALIDATE(undefined, (r) => rmSync(join(r, "staged", "skills", "x", "SKILL.md"))));
  same("a staged file that is a link", VALIDATE(undefined, (r) => {
    const f = join(r, "staged", "skills", "x", "SKILL.md");
    rmSync(f);
    put(join(r, "elsewhere"), "skill body\n");
    symlinkSync(join(r, "elsewhere"), f);
  }));
  same("a staged path component that is a link", VALIDATE(undefined, (r) => {
    rmSync(join(r, "staged", "skills"), { recursive: true });
    put(join(r, "real", "x", "SKILL.md"), "skill body\n");
    symlinkSync(join(r, "real"), join(r, "staged", "skills"));
  }));
  same("a target component in the home that is a link", VALIDATE(undefined, (_, home) => {
    mkdirSync(join(home, "elsewhere"));
    symlinkSync(join(home, "elsewhere"), join(home, "skills"));
  }));
  const MOVE = (src: boolean, tgt: boolean, old = "-"): Row =>
    VALIDATE(
      (_, a) => {
        a[0] = { op: "move-skill", target: "skills/skills-archive/x/SKILL.md", old_sha256: old, new_sha256: sha("skill body\n"), staged: "staged/skills/x/SKILL.md" };
      },
      (_, home) => {
        if (src) put(join(home, "skills", "x", "SKILL.md"), "skill body\n");
        if (tgt) put(join(home, "skills", "skills-archive", "x", "SKILL.md"), "skill body\n");
      },
    );
  same("move-skill from its live source", MOVE(true, false));
  same("move-skill already archived", MOVE(false, true));
  same("move-skill with neither", MOVE(false, false));
  same("move-skill with an old hash", MOVE(true, false, sha("x")));
  // A live source that is there but unreadable is judged, never passed over
  // for the archived copy; the bash's own redirect line is not reproduced
  // (SHELL-OWN STDERR), its refusal is.
  if (process.getuid?.() !== 0) {
    const p = pair({
      ...MOVE(true, true),
      seed: (s) => {
        MOVE(true, true).seed!(s);
        chmodSync(join(s, "home", "skills", "x", "SKILL.md"), 0);
      },
    });
    expect([p.t.out, p.t.rc, p.t.files]).toEqual([p.o.out, p.o.rc, p.o.files]);
    expect(p.o.out).toBe("|rc=1");
    expect([p.o.err.includes("S/home/skills/x/SKILL.md: Permission denied"), p.t.err]).toEqual([true, ""]);
  }
  same("a plan that is a link", VALIDATE(undefined, (r, _, plan) => {
    put(join(r, "real-plan.json"), plan);
    symlinkSync(join(r, "real-plan.json"), join(r, "plan.json"));
  }));
  expect(same("no jq on PATH", { ...VALIDATE(), path: `${NOJQ}:${BASE}` }).t.out).toBe("|rc=1");
});

const OPEN: Row = {
  bash: `ac_herdr_tab_open "$1" "$2" "$3" "$4"`,
  libs: ["ac-backend.sh"],
  twin: `const r = L.herdrTabOpen(A[0], A[1], A[2], A[3]); if (r !== null) writeSync(1, Buffer.from(r + "\\n", "latin1")); return r === null ? 1 : 0;`,
  args: ["ses", "ac-gate-watch:fam", "@S/home", "w1"],
};
const answers = (a: Record<string, string>) => (s: string): void => {
  for (const [k, v] of Object.entries(a)) put(join(s, "answers", k), v);
};
const CREATED = '{"result":{"tab":{"tab_id":"t7"},"root_pane":{"pane_id":"p7"}}}\n';

test("herdrTabOpen: a labelled tab, its pane and tab ids by sed, the workspace's default tabs closed", () => {
  const closed = same("in a workspace", {
    ...OPEN,
    seed: answers({ "tab-create": CREATED, "tab-list": '{"result":{"tabs":[{"tab_id":"d1","label":"1"},{"tab_id":"t7","label":"ac-gate-watch:fam"},{"tab_id":"d2","label":"1"}]}}\n' }),
  });
  expect(closed.t.herdr).toContain("herdr --session ses tab close d1\nherdr --session ses tab close d2\n");
  same("no workspace", { ...OPEN, args: ["ses", "ac-gate-watch:fam", "@S/home", ""], seed: answers({ "tab-create": CREATED }) });
  same("the create fails", OPEN);
  same("no pane id", { ...OPEN, seed: answers({ "tab-create": '{"result":{"tab":{"tab_id":"t7"}}}\n' }) });
  same("ids across lines, the last on a line wins", {
    ...OPEN,
    seed: answers({ "tab-create": '{"pane_id":"a1","pane_id":"a2",\n"tab_id":"b1"}\n{"pane_id":"a3"}' }),
  });
  same("an unreadable tab list", { ...OPEN, seed: answers({ "tab-create": CREATED, "tab-list": "nope\n" }) });
});

test("the read-evidence floor the prompt prints is the lib's AC_MAINTENANCE_QUOTE_MIN", () => {
  const r = Bun.spawnSync(["/bin/bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-maintenance-lib.sh"; printf %s "$AC_MAINTENANCE_QUOTE_MIN"`, BIN], { cwd: ROOT, env: { PATH, HOME: W, LC_ALL: "C" }, stdin: "ignore", stdout: "pipe" });
  const src = readFileSync(join(ROOT, "src", "gate.ts"), "utf8");
  expect(/^const QUOTE_MIN = ([0-9]+);$/m.exec(src)?.[1]).toBe(r.stdout.toString());
});
