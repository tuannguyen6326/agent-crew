// self-task.test.ts - familyOwned's twin (src/lib.ts) held to the LIVE bash
// ac_family_owned it twins, called in the context the bash self-task entry
// gave it: inside an `if`. Compares stdout, stderr (less the shell's own
// `line N:` lines), the status, the stub log and the side's tree.
// backendWindowNew has no twin here - see the GAP comment below.
//
// DISPUTED: the implementation of ac_family_owned (the live bash vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with state/ records/ data/ config/, the stubs' sentinels, call counters and log at <side>/stub, TMPDIR at <side>/tmp); argv; env (PATH = refusing claude/codex/opencode/pi/cursor-agent/docker/codegraph/gh/orca stand-ins, then sleep and date stubs, the host's jq and git, bun alone, /bin plus /usr/bin without those names - no row can reach a real backend or harness; LC_ALL=C; HOME an empty dir; STUB_DIR, TMPDIR, AC_HOME, the row's own names); cwd (the distro root, so ac_root and STARTED_BIN name one bin/); stdin (/dev/null).
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-self-task-ts-")));
const ROOTED = process.getuid?.() === 0;
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const STOOD_IN = ["claude", "codex", "opencode", "pi", "cursor-agent", "docker", "codegraph", "gh", "orca"];
const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if ([...STOOD_IN, "jq", "herdr", "sleep", "date", "bun"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const GUARD = join(W, "guard");
mkdirSync(GUARD);
for (const t of STOOD_IN) writeFileSync(join(GUARD, t), `#!/bin/sh\necho "refused stand-in: ${t}" >&2\nexit 97\n`, { mode: 0o755 });
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["jq", "git"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const BUN = join(W, "bun");
mkdirSync(BUN);
symlinkSync(process.execPath, join(BUN, "bun"));

const SLEEP = String.raw`#!/bin/sh
printf 'sleep %s\n' "$*" >>"$STUB_DIR/log"
`;
const DATE = String.raw`#!/bin/sh
case "$*" in *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;; *%s*) echo 1767225600 ;; *) exec /bin/date "$@" ;; esac
`;
function stubs(name: string): string {
  const d = join(W, name);
  mkdirSync(d);
  writeFileSync(join(d, "sleep"), SLEEP, { mode: 0o755 });
  writeFileSync(join(d, "date"), DATE, { mode: 0o755 });
  return d;
}
const PATH = `${GUARD}:${stubs("stubs")}:${TOOLS}:${BUN}:${BASE}`;
const NOHOME = join(W, "nohome");
mkdirSync(NOHOME);

type Row = {
  // the bash call, after sourcing ac-lib.sh and ac-backend.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments, sayU writes UTF-8
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
};
type Side = { out: string; err: string; rc: number | null; log: string; world: string };

const byBytes = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));

// The side's tree, TMPDIR and the stub's bookkeeping skipped.
function world(s: string, rel = ""): string {
  let names: string[];
  try {
    names = readdirSync(join(s, rel));
  } catch {
    return "";
  }
  let w = "";
  for (const name of names.sort(byBytes)) {
    const r = rel ? `${rel}/${name}` : name;
    if (r === "tmp" || r === "stub") continue;
    const p = join(s, r);
    const st = lstatSync(p);
    const mode = (st.mode & 0o777).toString(8);
    if (st.isSymbolicLink()) w += `${r} -> ${readlinkSync(p)}\n`;
    else if (st.isDirectory()) w += `${r}/ ${mode}\n${world(s, r)}`;
    else {
      let body = "<unreadable>";
      try {
        body = readFileSync(p, "latin1");
      } catch {}
      w += `${r} ${mode} = ${JSON.stringify(body)}\n`;
    }
  }
  return w;
}

function read(f: string): string {
  try {
    return readFileSync(f, "latin1");
  } catch {
    return "";
  }
}

const PRE = `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const sayU = (s) => void writeSync(1, Buffer.from(s, "utf8"));`;

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: NOHOME, TMPDIR: join(s, "tmp"), LC_ALL: "C", STUB_DIR: join(s, "stub"), AC_HOME: join(s, "home") };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [process.execPath, "-e", `${PRE} const A = ${JSON.stringify(args)}; const rc = await (async () => { ${row.twin} })(); writeSync(1, "|rc=" + rc); process.exit(0);`];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  // bash 3.2's `set -m` now and then prints its own `child setpgid` line -
  // shell-own stderr, never reproduced. Defensive: nothing in the dispatch
  // path this file drives sets -m today, but a stray line here would be
  // cryptic to chase, so the filter stays.
  const norm = (t: string): string => t.replaceAll(s, "S").replace(/^.*: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted\n/gm, "");
  let err = norm(r.stderr.toString("latin1"));
  if (oracle) err = err.replace(/^.*: line [0-9]+: .*\n/gm, "");
  const out = { out: norm(r.stdout.toString("latin1")), err, rc: r.exitCode, log: norm(read(join(s, "stub", "log"))), world: norm(world(s)) };
  Bun.spawnSync(["chmod", "-R", "u+rwX", s]);
  return out;
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    for (const sub of ["home/state", "home/records", "home/data", "home/config", "stub", "tmp"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  const view = (x: Side) => ({ label, ...x });
  expect(view(out[1]!)).toEqual(view(out[0]!));
  return { o: out[0]!, t: out[1]! };
}

const put = (s: string, rel: string, body: string, mode = 0o644): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  writeFileSync(join(s, rel), Buffer.from(body, "latin1"), { mode });
  chmodSync(join(s, rel), mode);
};
const meta = (s: string, name: string, kind: string): void => put(s, `home/state/${name}.meta`, kind === "" ? "backend=orca\n" : `kind=${kind}\nbackend=orca\n`);

const OWNED: Row = {
  bash: `if ac_family_owned "$1" "$2"; then printf owned; else printf free; fi`,
  twin: `sayU((await L.familyOwned(A[0], A[1])) ? "owned" : "free"); return 0;`,
};
const owned = (id: string): Row => ({ ...OWNED, args: [id, "@S/home/state"] });

test("familyOwned reads what ac_family_owned reads: an in-flight meta of the id's family, verifiers and chiefs skipped", () => {
  same("no meta in flight", owned("fam"));
  same("the flat family's own meta", { ...owned("fam"), seed: (s) => meta(s, "fam", "ship") });
  same("a revision id owned by its base", { ...owned("fam-r2"), seed: (s) => meta(s, "fam", "ship") });
  same("a staged sibling owns the family", { ...owned("fam"), seed: (s) => (mkdirSync(join(s, "home/data/fam/plan"), { recursive: true }), meta(s, "fam-plan", "ship")) });
  same("a stage id whose stage dir exists", { ...owned("fam-ship"), seed: (s) => (mkdirSync(join(s, "home/data/fam/ship"), { recursive: true }), meta(s, "fam", "self")) });
  same("a stage-shaped id with no stage dir is its own family", { ...owned("fam-ship"), seed: (s) => meta(s, "fam", "ship") });
  same("a kind=self sibling is in flight", { ...owned("fam"), seed: (s) => meta(s, "fam", "self") });
  same("a kind-less meta counts", { ...owned("fam"), seed: (s) => meta(s, "fam", "") });
  same("a verifier is skipped", { ...owned("fam"), seed: (s) => meta(s, "fam-verify-qa", "verify-qa") });
  same("a roomchief is skipped", { ...owned("fam"), seed: (s) => (mkdirSync(join(s, "home/data/fam/chief"), { recursive: true }), meta(s, "fam-chief", "roomchief")) });
  same("a crewdeputy is skipped", { ...owned("dep"), seed: (s) => meta(s, "dep", "crewdeputy") });
  same("another family", { ...owned("fam"), seed: (s) => meta(s, "other", "ship") });
  same("a dangling meta sorting first hides the rest", { ...owned("fam"), seed: (s) => (symlinkSync(join(s, "nowhere"), join(s, "home/state/a.meta")), meta(s, "fam", "ship")) });
  same("a dot meta is no task", { ...owned("fam"), seed: (s) => meta(s, ".fam", "ship") });
  if (!ROOTED) same("an unreadable meta counts", { ...owned("fam"), seed: (s) => (meta(s, "fam", "verify-qa"), chmodSync(join(s, "home/state/fam.meta"), 0o000)) });
  same("no state dir", { ...owned("fam"), args: ["fam", "@S/home/none"] });
}, 120000);
