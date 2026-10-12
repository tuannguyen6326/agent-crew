// spawn-twins.test.ts - the spawn twins of src/lib.ts held to the LIVE bash
// helpers they twin, which the frozen oracles of ac-learn, ac-pane-agent and
// ac-verify keep calling, each run in the call context the frozen oracle
// (tests/fixtures/ac-spawn.sh) gives it: inside `$(...)`, behind `||`, or
// bare under errexit (`set -e`, the status read by an EXIT trap).
// bin/ac-harness.sh: harnessInstructionFile,
// harnessStartupKey, recordLaunchOpts; bin/ac-lib.sh: compactPctEnv,
// domainBinding, seedCrewmateMd (and the install, exclude and disposable
// helpers under it), seedCrewSettings, seedCrewSkills (and the usage bump),
// seedPortsEnv (and the slot allocation); bin/ac-backend.sh: claudeConfigEnv,
// buildLaunch, resolveProfile, paneProfile, backendWindowNew's herdr arm (with
// the legacy-group sweep), backendDialogAnswer(Pane), backendAgentIdle(Pane),
// backendSubmitVerified, backendStartupDialogs (startupDialogs over the
// id-keyed verbs); bin/ac-backend-orca.sh: backendWindowNew's orca arm
// (orcaPlacePane) and orcaWorktreeLease. Every row compares stdout, stderr
// (less the shell's own `line N:` lines), the status, the stub log and the
// side's tree; a lease row also the repo's refs and worktrees.
//
// DISPUTED: the implementation of each helper (the live bash vs src/lib.ts's spawn twins)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with state/ records/ data/ config/, the container .claude at <side>/.claude, worktrees and repos under <side>, the stubs' sentinels, call counters and log at <side>/stub, TMPDIR at <side>/tmp); argv; env (PATH = refusing claude/codex/opencode/pi/cursor-agent/docker/codegraph/gh stand-ins, then herdr, orca, sleep and date stubs, the host's jq and git, bun alone, /bin plus /usr/bin without those names - no row can reach a real backend or harness; LC_ALL=C unless a row names UTF-8; HOME an empty dir; STUB_DIR, TMPDIR, AC_HOME unless homeless, fixed git identities and dates, the row's own names); cwd (the distro root, so ac_root and STARTED_BIN name one bin/); stdin (/dev/null).
import { afterAll, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-spawn-twins-ts-")));
const ROOTED = process.getuid?.() === 0;
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const STOOD_IN = ["claude", "codex", "opencode", "pi", "cursor-agent", "docker", "codegraph", "gh"];
const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if ([...STOOD_IN, "jq", "herdr", "orca", "sleep", "date", "bun"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const GUARD = join(W, "guard");
mkdirSync(GUARD);
for (const t of STOOD_IN) writeFileSync(join(GUARD, t), `#!/bin/sh\necho "refused stand-in: ${t}" >&2\nexit 97\n`, { mode: 0o755 });
const TOOLS = join(W, "tools");
const TOOLS_NOJQ = join(W, "tools-nojq");
for (const [dir, names] of [[TOOLS, ["jq", "git"]], [TOOLS_NOJQ, ["git"]]] as const) {
  mkdirSync(dir);
  for (const t of names) symlinkSync(Bun.which(t)!, join(dir, t));
}
const BUN = join(W, "bun");
mkdirSync(BUN);
symlinkSync(process.execPath, join(BUN, "bun"));

// A file-backed herdr: every call logged with its argv bracketed and the
// HERDR_SESSION it saw; the n-th call of a verb (`<a>-<b>`) answers from
// <verb>.<n>.{err,out,rc} when any exists, else <verb>.{err,out,rc}, else the
// verb's default (a tab create mints wNEW:t<n> / p<n>; `tab list --workspace
// <ws>` serves tabs-<ws>).
const HERDR = String.raw`#!/bin/sh
d="$STUB_DIR"
{ printf herdr; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' {%s}\n' "$HERDR_SESSION"; } >>"$d/log"
v="$1-$2"
n=$(($(cat "$d/$v.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/$v.n"
for f in "$v.$n" "$v"; do
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ] || [ -e "$d/$f.err" ]; then
    [ ! -e "$d/$f.err" ] || cat "$d/$f.err" >&2
    [ ! -e "$d/$f.out" ] || cat "$d/$f.out"
    exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
  fi
done
case "$v" in
  workspace-list) printf '{"result":{"workspaces":[]}}\n' ;;
  workspace-create) printf '{"result":{"workspace":{"workspace_id":"wNEW"}}}\n' ;;
  tab-list) if [ -e "$d/tabs-$4" ]; then cat "$d/tabs-$4"; else printf '{"result":{"tabs":[]}}\n'; fi ;;
  tab-create) printf '{"result":{"tab":{"tab_id":"wNEW:t%s"},"root_pane":{"pane_id":"p%s"}}}\n' "$n" "$n" ;;
esac
exit 0
`;
// orca, the same file-backed shape; `worktree create` cuts a REAL linked
// worktree at <stub>/wt/<name> on tester/<name> from the base ref (the CLI's
// own minted branch) unless a sentinel answers for it; `worktree show`
// resolves nothing by default; a terminal create mints h<n>/tab<n>.
const ORCA = String.raw`#!/bin/sh
d="$STUB_DIR"
{ printf orca; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"$d/log"
v="$1-$2"
n=$(($(cat "$d/$v.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/$v.n"
for f in "$v.$n" "$v"; do
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ] || [ -e "$d/$f.err" ]; then
    [ ! -e "$d/$f.err" ] || cat "$d/$f.err" >&2
    [ ! -e "$d/$f.out" ] || cat "$d/$f.out"
    exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
  fi
done
case "$v" in
  worktree-create)
    repo="" name="" base=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo=$(printf '%s' "$2" | sed 's/^path://'); shift ;;
        --name) name="$2"; shift ;;
        --base-branch) base="$2"; shift ;;
      esac
      shift
    done
    p="$d/wt/$name"
    mkdir -p "$d/wt"
    git -C "$repo" worktree add -q -b "tester/$name" "$p" "$base" >/dev/null 2>&1 || { echo '{"ok":false}'; exit 1; }
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s","branch":"refs/heads/tester/%s"}}}\n' "$name" "$p" "$name" ;;
  worktree-show) echo '{"ok":false}'; exit 1 ;;
  terminal-create) printf '{"ok":true,"result":{"terminal":{"handle":"h%s","tabId":"tab%s"}}}\n' "$n" "$n" ;;
  terminal-list) printf '{"ok":true,"result":{"terminals":[]}}\n' ;;
  terminal-show) printf '{"ok":true,"result":{"terminal":{"connected":true}}}\n' ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
`;
const SLEEP = String.raw`#!/bin/sh
printf 'sleep %s\n' "$*" >>"$STUB_DIR/log"
[ ! -e "$STUB_DIR/sleep.rc" ] || { echo "sleep: refused" >&2; exit "$(cat "$STUB_DIR/sleep.rc")"; }
`;
const DATE = String.raw`#!/bin/sh
case "$*" in *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;; *%s*) echo 1767225600 ;; *) exec /bin/date "$@" ;; esac
`;
function stubs(name: string, herdr: boolean, orca: boolean): string {
  const d = join(W, name);
  mkdirSync(d);
  if (herdr) writeFileSync(join(d, "herdr"), HERDR, { mode: 0o755 });
  if (orca) writeFileSync(join(d, "orca"), ORCA, { mode: 0o755 });
  writeFileSync(join(d, "sleep"), SLEEP, { mode: 0o755 });
  writeFileSync(join(d, "date"), DATE, { mode: 0o755 });
  return d;
}
const PATHS = {
  all: `${GUARD}:${stubs("stubs", true, true)}:${TOOLS}:${BUN}:${BASE}`,
  noherdr: `${GUARD}:${stubs("stubs-noherdr", false, true)}:${TOOLS}:${BUN}:${BASE}`,
  noorca: `${GUARD}:${stubs("stubs-noorca", true, false)}:${TOOLS}:${BUN}:${BASE}`,
  nojq: `${GUARD}:${join(W, "stubs")}:${TOOLS_NOJQ}:${BUN}:${BASE}`,
};
const NOHOME = join(W, "nohome");
mkdirSync(NOHOME);
const GIT_ENV = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t", GIT_AUTHOR_DATE: "2026-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2026-01-01T00:00:00Z", GIT_CONFIG_NOSYSTEM: "1" };

type Row = {
  // the bash call, after sourcing ac-lib.sh and ac-backend.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments, say/sayU write latin1/UTF-8
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  homeless?: boolean;
  lc?: string;
  // the call bare under `set -e`, its status read by an EXIT trap
  errexit?: boolean;
  path?: keyof typeof PATHS;
  // a repo (relative to the side) whose refs and worktrees are compared
  repo?: string;
};
type Side = { out: string; err: string; rc: number | null; log: string; world: string; git: string };

const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const byBytes = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));
const sha = (body: string): string => createHash("sha256").update(Buffer.from(body, "latin1")).digest("hex");

// A seed stamp hashes bytes that may carry the side's own root, so a stamp
// that is the hash of the file it stamps reads as that, on either side.
function stampView(s: string, r: string, body: string): string {
  const m = /^(.*)\/\.claude\/\.ac-seed\/([^/]+?)(\.sha256)?$/.exec(r);
  if (!m) return body;
  const rel = m[2]!.replaceAll("%", "/");
  return body === `${sha(read(join(s, m[1]!, rel)))}\n` ? `<sha256 of ${rel}>\n` : body;
}

// The side's tree: TMPDIR and the stub's bookkeeping skipped (an orca
// worktree under <stub>/wt kept), a .git dir as its info/exclude alone.
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
    if (r === "tmp") continue;
    if (r === "stub") {
      w += world(s, "stub/wt");
      continue;
    }
    const p = join(s, r);
    const st = lstatSync(p);
    if (name === ".git" && st.isDirectory()) {
      const ex = join(p, "info", "exclude");
      w += existsSync(ex) ? `${r}/info/exclude = ${JSON.stringify(readFileSync(ex, "latin1"))}\n` : `${r}/ (no info/exclude)\n`;
      continue;
    }
    const mode = (st.mode & 0o777).toString(8);
    if (st.isSymbolicLink()) w += `${r} -> ${readlinkSync(p)}\n`;
    else if (st.isDirectory()) w += `${r}/ ${mode}\n${world(s, r)}`;
    else {
      let body = "<unreadable>";
      try {
        body = readFileSync(p, "latin1");
      } catch {}
      w += `${r} ${mode} = ${JSON.stringify(stampView(s, r, body))}\n`;
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

const git = (dir: string, args: string[]): string =>
  Bun.spawnSync(["git", "-C", dir, ...args], { env: { PATH: PATHS.all, HOME: NOHOME, ...GIT_ENV }, stdin: "ignore", stdout: "pipe", stderr: "pipe" }).stdout.toString("latin1");

const PRE = `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const say = (s) => void writeSync(1, Buffer.from(s, "latin1")); const sayU = (s) => void writeSync(1, Buffer.from(s, "utf8"));`;

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH: PATHS[row.path ?? "all"], HOME: NOHOME, TMPDIR: join(s, "tmp"), LC_ALL: row.lc ?? "C", STUB_DIR: join(s, "stub"), ...GIT_ENV };
  if (!row.homeless) env.AC_HOME = join(s, "home");
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const head = row.errexit ? `set -euo pipefail; trap 'printf "|rc=%s" "$?"' EXIT` : "set -uo pipefail";
  const cmd = oracle
    ? ["/bin/bash", "-c", `${head}; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; ${row.bash}${row.errexit ? "" : `; printf '|rc=%s' "$?"`}`, BIN, ...args]
    : [process.execPath, "-e", `${PRE} const A = ${JSON.stringify(args)}; const rc = await (async () => { ${row.twin} })(); writeSync(1, "|rc=" + rc); process.exit(${row.errexit ? "rc" : "0"});`];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  // bash 3.2's `set -m` (herdr_rpc_bounded) now and then prints its own
  // `child setpgid` line - shell-own stderr, never reproduced.
  const norm = (t: string): string =>
    t.replaceAll(s, "S").replace(/\.tmp\.[0-9]+/g, ".tmp.PID").replace(/\/ac-seed\.[A-Za-z0-9]{6}\b/g, "/ac-seed.XXXXXX").replace(/^.*: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted\n/gm, "");
  let err = norm(r.stderr.toString("latin1"));
  if (oracle) err = err.replace(/^.*: line [0-9]+: .*\n/gm, "");
  const gitView = row.repo ? norm(git(join(s, row.repo), ["for-each-ref", "--format=%(refname) %(objectname)"]) + git(join(s, row.repo), ["worktree", "list", "--porcelain"])) : "";
  const out = { out: norm(r.stdout.toString("latin1")), err, rc: r.exitCode, log: norm(read(join(s, "stub", "log"))), world: norm(world(s)), git: gitView };
  Bun.spawnSync(["chmod", "-R", "u+rwX", s]);
  return out;
}

function pair(row: Row): { o: Side; t: Side; root: string } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    for (const sub of ["home/state", "home/records", "home/data", "home/config", "stub", "tmp"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]!, root };
}

function same(label: string, row: Row): { o: Side; t: Side; root: string } {
  const p = pair(row);
  const view = (x: Side) => ({ label, ...x });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const put = (s: string, rel: string, body: string, mode = 0o644): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  writeFileSync(join(s, rel), Buffer.from(body.replaceAll("@S", s), "latin1"), { mode });
  chmodSync(join(s, rel), mode);
};
const link = (s: string, target: string, rel: string): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  symlinkSync(target.replaceAll("@S", s), join(s, rel));
};
const gitInit = (s: string, rel: string): void => {
  git(s, ["init", "-q", "-b", "main", rel]);
  git(join(s, rel), ["commit", "-q", "--allow-empty", "-m", "init"]);
};
const pane = (s: string, id: string, body: string): void => put(s, `home/state/.pane-${id}`, body);

test("harnessInstructionFile and harnessStartupKey answer what the registry's facets answer", () => {
  const file: Row = {
    bash: `x="$(ac_harness_instruction_file "$1")"; s=$?; printf '[%s]' "$x"; (exit $s)`,
    twin: `const r = L.harnessInstructionFile(A[0]); sayU("[" + (r ?? "") + "]"); return r === null ? 1 : 0;`,
  };
  for (const h of ["claude", "", "codex", "opencode", "pi", "cursor", "agy", "bogus", "café"]) same(`file: '${h}'`, { ...file, args: [h] });
  same("file: a custom template", { ...file, args: ["fake"], seed: (s) => put(s, "home/config/launch-fake", "fake __BRIEF__\n") });
  same("file: a template that is a directory", { ...file, args: ["fake"], seed: (s) => mkdirSync(join(s, "home/config/launch-fake")) });
  if (!ROOTED) same("file: homeless, a custom name", { ...file, args: ["fake"], homeless: true });
  const key: Row = { bash: `x="$(ac_harness_startup_key "$1")"; printf '[%s]' "$x"`, twin: `say("[" + L.harnessStartupKey(A[0]) + "]"); return 0;` };
  for (const h of ["codex", "claude", "", "opencode", "Codex"]) same(`key: '${h}'`, { ...key, args: [h] });
}, 60000);

test("recordLaunchOpts writes only what each harness's built-in launch applies, one key at a time", () => {
  const rec: Row = {
    bash: `ac_record_launch_opts "$@"`,
    twin: `try { L.recordLaunchOpts(A[0], A[1], A[2], A[3], A[4]); return 0; } catch (e) { return e.status ?? 1; }`,
    errexit: true,
    seed: (s) => put(s, "home/state/t1.meta", "kind=ship\nmodel=old\n"),
  };
  const M = "@S/home/state/t1.meta";
  for (const h of ["claude", "codex", "opencode", "pi", "cursor", "fake"])
    for (const [m, e, a] of [["m1", "high", ""], ["m1", "ultracode", "xhigh"], ["", "low", ""], ["m1", "", "xhigh"], ["", "", ""]] as const)
      same(`${h} model=${m} effort=${e} applied=${a}`, { ...rec, args: [M, h, m, e, a] });
  same("four arguments: the applied effort is the effort", { ...rec, args: [M, "codex", "m", "max"] });
  same("a UTF-8 model", { ...rec, args: [M, "claude", "mödel", "high", ""] });
  if (!ROOTED) same("a meta dir the lock cannot be made in ends the caller", { ...rec, args: [M, "claude", "m1", "high", ""], seed: (s) => (put(s, "home/state/t1.meta", "x=1\n"), chmodSync(join(s, "home/state"), 0o555)) });
}, 120000);

test("compactPctEnv and claudeConfigEnv print the launch-line prefixes the bash printed", () => {
  const pct: Row = { bash: `x="$(ac_compact_pct_env)"; printf '[%s]' "$x"`, twin: `say("[" + L.compactPctEnv() + "]"); return 0;` };
  same("pct: unset", pct);
  for (const v of ["80", "007", "1", "100", "0", "101", "-5", "abc", "4 2", " 42 ", "99999999999999999999", ""]) same(`pct: '${v}'`, { ...pct, seed: (s) => put(s, "home/config/compact-pct", `${v}\n`) });
  same("pct: UTF-8, not digits", { ...pct, lc: "en_US.UTF-8", seed: (s) => put(s, "home/config/compact-pct", "caf\xc3\xa9\n") });
  same("pct: CRLF", { ...pct, seed: (s) => put(s, "home/config/compact-pct", "50\r\n") });
  if (!ROOTED) same("pct: a knob head cannot read", { ...pct, seed: (s) => put(s, "home/config/compact-pct", "50\n", 0o000) });
  const cc: Row = { bash: `x="$(ac_claude_config_env)"; printf '[%s]' "$x"`, twin: `say("[" + L.claudeConfigEnv() + "]"); return 0;` };
  same("config dir: unset", cc);
  same("config dir: empty", { ...cc, env: { CLAUDE_CONFIG_DIR: "" } });
  for (const lc of ["C", "en_US.UTF-8"])
    for (const d of ["/x/y", "/x/café dir", "/x/it's", "/x/$HOME", "~/x"]) same(`config dir: ${lc} '${d}'`, { ...cc, lc, env: { CLAUDE_CONFIG_DIR: d } });
}, 120000);

test("buildLaunch composes each built-in launch as ac_build_launch did, and refuses any other name", () => {
  const bl: Row = { bash: `x="$(ac_build_launch "$@")"; s=$?; printf '[%s]' "$x"; (exit $s)`, twin: `const r = L.buildLaunch(...A); sayU("[" + (r ?? "") + "]"); return r === null ? 1 : 0;` };
  for (const h of ["claude", "codex", "opencode", "pi", "cursor"])
    for (const args of [[h], [h, "m1"], [h, "", "high"], [h, "m1", "xhigh", "", "sid-1"], [h, "m1", "low", "rsid-1", "sid-1"], [h, "", "", "rsid-1"], [h, "a b", "x y"]])
      same(args.join("|"), { ...bl, args });
  same("an unknown harness: the ERROR names config/launch-<h>, config/ minted", { ...bl, args: ["fake"], seed: (s) => rmSync(join(s, "home/config"), { recursive: true }) });
  same("an empty harness", { ...bl, args: [""] });
  if (!ROOTED) same("homeless, an unknown harness", { ...bl, args: ["fake"], homeless: true });
}, 120000);

test("resolveProfile and paneProfile resolve through ac-dispatch-select as the bash did", () => {
  const dispatch = readFileSync(join(ROOT, "docs", "examples", "crew-dispatch.json"), "latin1");
  const table = (s: string): void => put(s, "home/config/crew-dispatch.json", dispatch);
  const rp: Row = { bash: `x="$(ac_resolve_profile "$@")"; s=$?; printf '[%s]' "$x"; (exit $s)`, twin: `const r = L.resolveProfile(A); say("[" + r.out + "]"); return r.status;` };
  same("named knobs, no table", { ...rp, args: ["--harness", "codex", "--model", "m1"] });
  same("no flag, no table: claude", rp);
  same("no flag: config/crew-harness", { ...rp, seed: (s) => put(s, "home/config/crew-harness", "codex\n") });
  same("no flag, a table: refused", { ...rp, seed: table });
  same("--harness beside a table", { ...rp, args: ["--harness", "codex", "--effort", "high"], seed: table });
  same("--rule 1", { ...rp, args: ["--rule", "1"], seed: table });
  same("--rule 2, the model and effort named", { ...rp, args: ["--rule", "2", "--model", "mine", "--effort", "low"], seed: table });
  same("--rule 1, the harness named", { ...rp, args: ["--harness", "codex", "--rule", "1"], seed: table });
  same("--rule 9: the selector's own refusal and status", { ...rp, args: ["--rule", "9"], seed: table });
  same("--rule without a table", { ...rp, args: ["--rule", "1"] });
  same("an empty --rule is no rule", { ...rp, args: ["--rule", ""], seed: (s) => put(s, "home/config/crew-harness", "pi\n") });
  same("a flag without its value", { ...rp, args: ["--harness"] });
  same("an unknown flag", { ...rp, args: ["--bogus", "x"] });
  same("a name that is an object property", { ...rp, args: ["toString", "x"] });
  const pp: Row = { bash: `x="$(ac_pane_profile "$1")"; s=$?; printf '[%s]' "$x"; (exit $s)`, twin: `const r = L.paneProfile(A[0]); say("[" + r.out + "]"); return r.status;` };
  for (const kind of ["codereview", "qa", "gate", "roomchief", "nope"]) same(`pane ${kind}`, { ...pp, args: [kind], seed: table });
  same("pane: no table", { ...pp, args: ["codereview"] });
  same("pane: a table that is no JSON", { ...pp, args: ["codereview"], seed: (s) => put(s, "home/config/crew-dispatch.json", "{oops\n") });
}, 180000);

test("domainBinding reads AC_DOMAIN, else the domain= of the chief meta AC_SCOPE names", () => {
  const db: Row = { bash: `x="$(ac_domain_binding)"; printf '[%s]' "$x"`, twin: `sayU("[" + L.domainBinding() + "]"); return 0;` };
  const chief = (s: string): void => put(s, "home/state/fam-chief.meta", "kind=roomchief\ndomain=dX\n");
  same("neither", db);
  same("AC_DOMAIN", { ...db, env: { AC_DOMAIN: "d1" }, seed: chief });
  same("AC_SCOPE names a domainchief", { ...db, env: { AC_SCOPE: "fam" }, seed: chief });
  same("AC_SCOPE names an ordinary chief", { ...db, env: { AC_SCOPE: "fam" }, seed: (s) => put(s, "home/state/fam-chief.meta", "kind=roomchief\n") });
  same("AC_SCOPE names no meta", { ...db, env: { AC_SCOPE: "fam" } });
  same("AC_SCOPE outside the grammar", { ...db, env: { AC_SCOPE: "a/b" }, seed: chief });
  same("the last domain= wins, an empty one reads none", { ...db, env: { AC_SCOPE: "fam" }, seed: (s) => put(s, "home/state/fam-chief.meta", "domain=dA\ndomain=\n") });
  if (!ROOTED) same("an unreadable meta warns and reads none", { ...db, env: { AC_SCOPE: "fam" }, seed: (s) => put(s, "home/state/fam-chief.meta", "domain=dX\n", 0o000) });
}, 60000);

test("domainBinding, named (W10): AC_SCOPE's grammar is read per the text under UTF-8", () => {
  // DISPUTED: whether `café` is a legal AC_SCOPE under en_US.UTF-8
  // HELD-CONSTANT: the scope, its chief meta and the locale
  const p = pair({ bash: `x="$(ac_domain_binding)"; printf '[%s]' "$x"`, twin: `sayU("[" + L.domainBinding() + "]"); return 0;`, lc: "en_US.UTF-8", env: { AC_SCOPE: "café" }, seed: (s) => put(s, "home/state/café-chief.meta", "domain=dZ\n") });
  expect(p.o.out).toBe("[dZ]|rc=0");
  expect(p.t.out).toBe("[]|rc=0");
}, 60000);

const MD: Row = { bash: `x="$(ac_seed_crewmate_md "$1" "$2")"; printf '[%s]' "$x"`, twin: `sayU("[" + L.seedCrewmateMd(A[0], A[1]) + "]"); return 0;`, args: ["@S/wt", "claude"] };
const wt = (s: string): void => gitInit(s, "wt");
const fleetLaw = (s: string): void => put(s, "home/CREWMATE.md", "fleet law\n");
const allLayers = (s: string): void => {
  put(s, ".claude/CLAUDE.md", "container law\n");
  put(s, "home/CREWMATE-learned.md", "learned\n");
  fleetLaw(s);
  put(s, "home/crewdomains/d1/CREWMATE.md", "domain law\n");
};
// <rel> in the worktree as the seed wrote it: the bytes and their stamp
// (the suffix-less legacy name when <legacy>).
const stamped = (s: string, rel: string, body: string, legacy = false): void => {
  put(s, `wt/${rel}`, body);
  put(s, `wt/.claude/.ac-seed/${rel.replaceAll("/", "%")}${legacy ? "" : ".sha256"}`, `${sha(body)}\n`);
};

test("seedCrewmateMd composes the layers there are and installs them where the harness reads, or at the fallback it names", () => {
  same("no layer at all", { ...MD, seed: wt });
  same("the fleet layer alone, byte-identical", { ...MD, seed: (s) => (wt(s), fleetLaw(s)) });
  same("all four layers, in order, each behind its header", { ...MD, env: { AC_DOMAIN: "d1" }, seed: (s) => (wt(s), allLayers(s)) });
  for (const h of ["codex", "opencode", "pi", "cursor", ""]) same(`harness '${h}'`, { ...MD, args: ["@S/wt", h], seed: (s) => (wt(s), put(s, ".claude/CLAUDE.md", "container law\n"), fleetLaw(s)) });
  same("a custom harness with its template", { ...MD, args: ["@S/wt", "fake"], seed: (s) => (wt(s), fleetLaw(s), put(s, "home/config/launch-fake", "fake\n")) });
  same("an unknown harness: the ERROR, then the fallback", { ...MD, args: ["@S/wt", "bogus"], seed: (s) => (wt(s), fleetLaw(s)) });
  same("a repo-shipped instruction file wins; the fallback is named", { ...MD, seed: (s) => (wt(s), fleetLaw(s), put(s, "wt/.claude/CLAUDE.md", "shipped\n")) });
  same("a repo-shipped AGENTS.md for codex", { ...MD, args: ["@S/wt", "codex"], seed: (s) => (wt(s), fleetLaw(s), put(s, "wt/AGENTS.md", "chief law\n")) });
  same("the file and the fallback both someone else's", { ...MD, seed: (s) => (wt(s), fleetLaw(s), put(s, "wt/.claude/CLAUDE.md", "shipped\n"), put(s, "wt/.claude/CREWMATE.md", "mine\n")) });
  same("the seed's own copy, unchanged", { ...MD, seed: (s) => (wt(s), fleetLaw(s), stamped(s, ".claude/CLAUDE.md", "fleet law\n")) });
  same("the seed's own copy, refreshed", { ...MD, seed: (s) => (wt(s), fleetLaw(s), stamped(s, ".claude/CLAUDE.md", "old law\n")) });
  same("an edited copy is someone else's", { ...MD, seed: (s) => (wt(s), fleetLaw(s), stamped(s, ".claude/CLAUDE.md", "old law\n"), put(s, "wt/.claude/CLAUDE.md", "edited\n")) });
  same("a stamp that holds no hash", { ...MD, seed: (s) => (wt(s), fleetLaw(s), put(s, "wt/.claude/CLAUDE.md", "old\n"), put(s, "wt/.claude/.ac-seed/.claude%CLAUDE.md.sha256", "junk\r\n")) });
  same("a legacy stamp that verifies is migrated", { ...MD, seed: (s) => (wt(s), fleetLaw(s), stamped(s, ".claude/CLAUDE.md", "old law\n", true)) });
  same("a legacy stamp that does not verify is dropped", { ...MD, seed: (s) => (wt(s), fleetLaw(s), stamped(s, ".claude/CLAUDE.md", "old law\n", true), put(s, "wt/.claude/CLAUDE.md", "edited\n")) });
  same("ac-verify's neutralized stub is overwritten", { ...MD, seed: (s) => (wt(s), fleetLaw(s), put(s, "wt/.claude/CLAUDE.md", "# Neutralized by ac-verify: round r1\nsee x\n")) });
  same("a dangling link at the target is written through", { ...MD, seed: (s) => (wt(s), fleetLaw(s), link(s, "@S/elsewhere.md", "wt/.claude/CLAUDE.md")) });
  same("a directory at the target", { ...MD, seed: (s) => (wt(s), fleetLaw(s), mkdirSync(join(s, "wt/.claude/CLAUDE.md"), { recursive: true })) });
  same("the exclude lines already there", { ...MD, seed: (s) => (wt(s), fleetLaw(s), put(s, "wt/.git/info/exclude", "/.claude/CLAUDE.md\n/.claude/.ac-seed/\n")) });
  same("no info/ dir: both installs land and neither is named", { ...MD, seed: (s) => (wt(s), fleetLaw(s), rmSync(join(s, "wt/.git/info"), { recursive: true, force: true })) });
  same("a worktree that is no repo", { ...MD, seed: (s) => (mkdirSync(join(s, "wt")), fleetLaw(s)) });
  same("a linked worktree's lines land in its main repo", { ...MD, args: ["@S/lwt", "claude"], seed: (s) => (wt(s), fleetLaw(s), git(join(s, "wt"), ["worktree", "add", "-q", "--detach", join(s, "lwt")])) });
  same("the domain a domainchief's meta names", { ...MD, env: { AC_SCOPE: "fam" }, seed: (s) => (wt(s), allLayers(s), put(s, "home/state/fam-chief.meta", "kind=roomchief\ndomain=d1\n")) });
  same("a bound domain without a layer", { ...MD, env: { AC_DOMAIN: "d9" }, seed: (s) => (wt(s), fleetLaw(s)) });
  same("a layer that is a directory is none", { ...MD, seed: (s) => (wt(s), fleetLaw(s), mkdirSync(join(s, "home/CREWMATE-learned.md"))) });
  same("mktemp cannot stage", { ...MD, env: { TMPDIR: "@S/nope" }, seed: (s) => (wt(s), fleetLaw(s)) });
  same("UTF-8, all four layers", { ...MD, lc: "en_US.UTF-8", env: { AC_DOMAIN: "d1" }, seed: (s) => (wt(s), allLayers(s)) });
}, 180000);

test("seedCrewSettings copies each settings file from the fleet, else the container, where the seed owns it", () => {
  const set: Row = { bash: `ac_seed_crew_settings "$1"`, twin: `L.seedCrewSettings(A[0]); return 0;`, errexit: true, args: ["@S/wt"] };
  const cont = (s: string): void => (put(s, ".claude/settings.json", '{"c":1}\n'), put(s, ".claude/settings.local.json", '{"cl":1}\n'));
  same("no source", { ...set, seed: wt });
  same("the container's two", { ...set, seed: (s) => (wt(s), cont(s)) });
  same("the fleet's settings.json, the container's local", { ...set, seed: (s) => (wt(s), cont(s), put(s, "home/.claude/settings.json", '{"f":1}\n')) });
  same("a home .claude linked into the distro is no fleet layer", { ...set, seed: (s) => (wt(s), cont(s), link(s, join(ROOT, ".claude"), "home/.claude")) });
  same("a repo-shipped settings.json is left", { ...set, seed: (s) => (wt(s), cont(s), put(s, "wt/.claude/settings.json", '{"repo":1}\n')) });
  same("the seed's own copy refreshed", { ...set, seed: (s) => (wt(s), cont(s), stamped(s, ".claude/settings.json", '{"old":1}\n')) });
  same("a source that is a directory", { ...set, seed: (s) => (wt(s), mkdirSync(join(s, ".claude/settings.json"), { recursive: true })) });
  same("a worktree that is no repo", { ...set, seed: (s) => (mkdirSync(join(s, "wt")), cont(s)) });
  if (!ROOTED) same("a source that cannot be read", { ...set, seed: (s) => (wt(s), cont(s), chmodSync(join(s, ".claude/settings.json"), 0o000)) });
}, 120000);

test("seedCrewSkills links the crew skills where the harness scans and excludes what it owns, ending where errexit ended", () => {
  const sk: Row = { bash: `ac_seed_crew_skills "$1" "$2"`, twin: `return L.seedCrewSkills(A[0], A[1]);`, errexit: true, args: ["@S/wt", "claude"] };
  const learned = (s: string): void => {
    put(s, "home/skills/l1/SKILL.md", "l1\n");
    put(s, "home/skills/l2/SKILL.md", "l2\n");
    put(s, "home/skills/l2/.usage.meta", "seeded_count=4\nlast_seeded=1\n");
    put(s, "home/skills/skills-archive/old/SKILL.md", "old\n");
    put(s, "home/skills/afile", "x\n");
  };
  same("the defaults in a fresh repo", { ...sk, seed: wt });
  same("codex scans .agents/skills", { ...sk, args: ["@S/wt", "codex"], seed: wt });
  same("a container skill wins its name", { ...sk, seed: (s) => (wt(s), put(s, ".claude/skills/crew-ship/SKILL.md", "c\n")) });
  same("learned skills linked and bumped, the archive and a file skipped", { ...sk, seed: (s) => (wt(s), learned(s)) });
  same("a learned skill already linked is not bumped", { ...sk, seed: (s) => (wt(s), learned(s), link(s, "@S/home/skills/l2", "wt/.claude/skills/l2")) });
  same("a dangling link is removed and relinked", { ...sk, seed: (s) => (wt(s), link(s, "@S/gone", "wt/.claude/skills/crew-ship"), link(s, "@S/gone", "wt/.claude/skills/retired")) });
  same("a repo-shipped skill keeps its name and gets no line", { ...sk, seed: (s) => (wt(s), put(s, "wt/.claude/skills/crew-qa/SKILL.md", "shipped\n")) });
  same("a skills dir linked inside the worktree", { ...sk, seed: (s) => (wt(s), mkdirSync(join(s, "wt/agents-skills")), link(s, "../agents-skills", "wt/.claude/skills")) });
  same("a skills dir linked outside the worktree", { ...sk, seed: (s) => (wt(s), mkdirSync(join(s, "outside")), link(s, "@S/outside", "wt/.claude/skills")) });
  same("a worktree that is no repo", { ...sk, seed: (s) => mkdirSync(join(s, "wt")) });
  same("an exclude line already there", { ...sk, seed: (s) => (wt(s), put(s, "wt/.git/info/exclude", "/.claude/skills/crew-ship\n")) });
  same("a usage count 010 reads octal", { ...sk, seed: (s) => (wt(s), put(s, "home/skills/l1/.usage.meta", "seeded_count=010\n")) });
  same("a usage count that is no number reads 0", { ...sk, seed: (s) => (wt(s), put(s, "home/skills/l1/.usage.meta", "seeded_count=abc\n")) });
  same("a usage count 09 ends bash itself", { ...sk, seed: (s) => (wt(s), put(s, "home/skills/l1/.usage.meta", "seeded_count=09\n")) });
  same("AC_CREW_SKILLS split on blanks", { ...sk, env: { AC_CREW_SKILLS: "crew-ship  nope\tdocument" }, seed: wt });
  same("an empty AC_CREW_SKILLS is the default", { ...sk, env: { AC_CREW_SKILLS: "" }, seed: wt });
  same("no info/ dir: the first line not appended ends it", { ...sk, seed: (s) => (wt(s), rmSync(join(s, "wt/.git/info"), { recursive: true, force: true })) });
  same("a .claude that is a file: mkdir -p ends it", { ...sk, seed: (s) => (wt(s), put(s, "wt/.claude", "file\n")) });
  same("UTF-8, a learned skill named café", { ...sk, lc: "en_US.UTF-8", seed: (s) => (wt(s), put(s, "home/skills/café/SKILL.md", "c\n")) });
}, 180000);

const REG = "home/state/port-slots.tsv";
const PORTS: Row = {
  bash: `ac_seed_ports_env "$1" "$2"`,
  twin: `const r = L.seedPortsEnv(A[0], A[1]); if (r !== null) say(r + "\\n"); return r === null ? 1 : 0;`,
  args: ["@S/wt", "proj"],
};

test("seedPortsEnv allocates the worktree's slot and writes its range as ac_seed_ports_env did", () => {
  const dirs = (s: string): void => ["wt", "wt1", "wt2", "wt3"].forEach((d) => mkdirSync(join(s, d)));
  same("a fresh registry", { ...PORTS, seed: dirs });
  same("a dead worktree's row dropped, the lowest free slot taken", { ...PORTS, seed: (s) => (dirs(s), put(s, REG, "1\t@S/gone\tp\tx\n3\t@S/wt2\tq\ty\n")) });
  same("its own row reused", { ...PORTS, seed: (s) => (dirs(s), put(s, REG, "1\t@S/wt1\tp\tx\n2\t@S/wt\tproj\ty\n")) });
  same("slots 1-3 taken", { ...PORTS, seed: (s) => (dirs(s), put(s, REG, "1\t@S/wt1\tp\tx\n2\t@S/wt2\tp\tx\n3\t@S/wt3\tp\tx\n")) });
  same("AC_PORT_BASE", { ...PORTS, env: { AC_PORT_BASE: "30000" }, seed: dirs });
  same("a worktree that is no directory", { ...PORTS, args: ["@S/nope", "proj"] });
  same("a git worktree gets its .crew/ line", { ...PORTS, seed: (s) => (dirs(s), gitInit(s, "wt")) });
  same("a .crew that is a file", { ...PORTS, seed: (s) => (dirs(s), put(s, "wt/.crew", "x\n")) });
  const held = same("a lock a live pid holds", { ...PORTS, seed: (s) => (dirs(s), put(s, `${REG}.lock/pid`, `${process.pid}\n`)) });
  expect(held.t.log).toBe("sleep 1\n".repeat(10));
  same("a lock a dead pid left", { ...PORTS, seed: (s) => (dirs(s), put(s, `${REG}.lock/pid`, "999999\n")) });
  if (!ROOTED) same("homeless: the refusal, then the root's lock waited on", { ...PORTS, homeless: true, seed: dirs });
}, 120000);

test("seedPortsEnv, named: the registry temp is created exclusively", () => {
  // DISPUTED: whether a planted symlink at <reg>.tmp.<pid> is written through
  // HELD-CONSTANT: the registry, the worktree, the planted link and its victim
  const p = pair({
    ...PORTS,
    bash: `ln -s "$STUB_DIR/../victim" "$AC_HOME/state/port-slots.tsv.tmp.$$"; ac_seed_ports_env "$1" "$2"`,
    twin: `Bun.spawnSync(["ln", "-s", process.env.STUB_DIR + "/../victim", process.env.AC_HOME + "/state/port-slots.tsv.tmp." + process.pid]); ${PORTS.twin}`,
    seed: (s) => (mkdirSync(join(s, "wt")), mkdirSync(join(s, "wt1")), put(s, REG, "1\t@S/wt1\tp\tx\n"), put(s, "victim", "victim bytes\n")),
  });
  expect(read(join(p.root, "t", "victim"))).toBe("victim bytes\n");
  expect(lstatSync(join(p.root, "o", REG)).isSymbolicLink()).toBe(true);
  expect(lstatSync(join(p.root, "t", REG)).isSymbolicLink()).toBe(false);
  expect(p.t.out).toBe(p.o.out);
}, 60000);

const LEASE: Row = {
  bash: `x="$(orca_worktree_lease "$@")"; s=$?; printf '[%s]' "$x"; (exit $s)`,
  twin: `const r = L.orcaWorktreeLease(A[0], A[1], A[2] ?? ""); sayU("[" + r.out + "]"); return r.status;`,
  args: ["t1", "@S/repo", ""],
  env: { AC_BACKEND: "orca" },
  repo: "repo",
};
const repo = (s: string): void => gitInit(s, "repo");
const fence = (s: string, entry = "repo epic/ep1"): void => {
  put(s, "home/records/backlog.md", "## Queued\n\n- [ ] t1 - story; epic:ep1\n");
  put(s, "home/data/ep1/branches", `${entry}\n`);
};
const origin = (s: string): void => {
  git(s, ["clone", "-q", "--bare", "repo", "origin.git"]);
  git(join(s, "repo"), ["remote", "add", "origin", join(s, "origin.git")]);
  git(join(s, "repo"), ["fetch", "-q", "origin"]);
};

test("orcaWorktreeLease leases an Orca worktree on the crew branch as orca_worktree_lease did inside `$(...)`", () => {
  same("the live branch, node_modules carried", { ...LEASE, seed: (s) => (repo(s), put(s, "repo/node_modules/a", "x\n")) });
  same("a detached checkout is cut from its HEAD", { ...LEASE, seed: (s) => (repo(s), git(join(s, "repo"), ["checkout", "-q", "--detach"])) });
  same("--base-branch names the branch", { ...LEASE, args: ["t1", "@S/repo", "feat"], seed: (s) => (repo(s), git(join(s, "repo"), ["branch", "feat"])) });
  same("an existing crew branch is adopted", { ...LEASE, seed: (s) => (repo(s), git(join(s, "repo"), ["branch", "crew/t1"])) });
  same("a family id leases its family's branch", { ...LEASE, args: ["t1-spec", "@S/repo", ""], seed: (s) => (repo(s), mkdirSync(join(s, "home/data/t1/spec"), { recursive: true })) });
  same("a switch git refuses gives the worktree back", { ...LEASE, seed: (s) => (repo(s), git(join(s, "repo"), ["branch", "crew/t1"]), git(join(s, "repo"), ["worktree", "add", "-q", join(s, "other"), "crew/t1"])) });
  same("an unregistered repo whose add fails is warned", { ...LEASE, seed: (s) => (repo(s), put(s, "stub/repo-show.rc", "1\n"), put(s, "stub/repo-add.rc", "1\n")) });
  same("a create that fails", { ...LEASE, seed: (s) => (repo(s), put(s, "stub/worktree-create.rc", "1\n")) });
  same("a create with no path releases its id", { ...LEASE, seed: (s) => (repo(s), put(s, "stub/worktree-create.out", '{"ok":true,"result":{"worktree":{"id":"wt-9"}}}\n')) });
  same("a create whose path is no directory", { ...LEASE, seed: (s) => (repo(s), put(s, "stub/worktree-create.out", '{"ok":true,"result":{"worktree":{"path":"@S/nowhere"}}}\n')) });
  same("the CLI's startup terminals are closed", {
    ...LEASE,
    seed: (s) => (repo(s), put(s, "stub/terminal-list.out", '{"ok":true,"result":{"terminals":[{"handle":"s1","worktreePath":"@S/stub/wt/crew-t1"},{"handle":"x","worktreePath":"@S/other"},{"handle":"s2","worktreePath":"@S/stub/wt/crew-t1"}]}}\n')),
  });
  same("a terminal list without terminals: jq's line, nothing closed", { ...LEASE, seed: (s) => (repo(s), put(s, "stub/terminal-list.out", '{"ok":true,"result":{}}\n')) });
  same("the fence: cut from the integration branch", { ...LEASE, seed: (s) => (repo(s), fence(s), git(join(s, "repo"), ["branch", "epic/ep1"])) });
  same("the fence: the branch missing", { ...LEASE, seed: (s) => (repo(s), fence(s)) });
  same("the fence: --base-branch disagrees", { ...LEASE, args: ["t1", "@S/repo", "feat"], seed: (s) => (repo(s), fence(s), git(join(s, "repo"), ["branch", "epic/ep1"])) });
  same("the fence: --base-branch agrees", { ...LEASE, args: ["t1", "@S/repo", "epic/ep1"], seed: (s) => (repo(s), fence(s), git(join(s, "repo"), ["branch", "epic/ep1"])) });
  same("the fence with origin: fetched, the remote ref judged", {
    ...LEASE,
    seed: (s) => (repo(s), fence(s), git(join(s, "repo"), ["branch", "epic/ep1"]), origin(s), git(join(s, "repo"), ["push", "-q", "origin", "epic/ep1"]), git(join(s, "repo"), ["update-ref", "-d", "refs/remotes/origin/epic/ep1"])),
  });
  same("the fence with origin, push=deferred: the local ref judged", { ...LEASE, seed: (s) => (repo(s), fence(s, "repo epic/ep1 push=deferred"), git(join(s, "repo"), ["branch", "epic/ep1"]), origin(s)) });
  same("the fence with an origin that cannot be fetched", { ...LEASE, seed: (s) => (repo(s), fence(s), git(join(s, "repo"), ["branch", "epic/ep1"]), git(join(s, "repo"), ["remote", "add", "origin", join(s, "nope.git")])) });
  same("UTF-8", { ...LEASE, lc: "en_US.UTF-8", seed: repo });
  if (!ROOTED) same("the fence: a ledger that cannot be read", { ...LEASE, seed: (s) => (repo(s), fence(s), chmodSync(join(s, "home/records/backlog.md"), 0o000)) });
}, 240000);

const WN: Row = { bash: `backend_window_new "$1" "$2"`, twin: `return L.backendWindowNew(A[0], A[1]).status;`, errexit: true, args: ["t1", "@S/wt"] };
const wtDir = (s: string): void => mkdirSync(join(s, "wt"));
const DEFAULT_TABS = '{"result":{"tabs":[{"tab_id":"wNEW:t0","label":"1"},{"tab_id":"wNEW:t1","label":"crew:t1"},{"tab_id":"wNEW:t9","label":"1"}]}}\n';

test("backendWindowNew herdr: the legacy sweep, the family workspace, the tab, the default tabs, the handle written last", () => {
  same("a fresh workspace, its default tabs closed", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/tabs-wNEW", DEFAULT_TABS)) });
  same("AC_WINDOW_FAMILY names the family", { ...WN, env: { AC_WINDOW_FAMILY: "fam" }, seed: wtDir });
  same("AC_WINDOW_FAMILY empty: the fleet root", { ...WN, env: { AC_WINDOW_FAMILY: "" }, seed: wtDir });
  same("AC_SCOPE", { ...WN, env: { AC_SCOPE: "sc" }, seed: wtDir });
  same("a staged id groups under its family", { ...WN, args: ["t1-spec", "@S/wt"], seed: (s) => (wtDir(s), mkdirSync(join(s, "home/data/t1/spec"), { recursive: true })) });
  same("the retired per-role groups swept once provably empty", {
    ...WN,
    seed: (s) => {
      wtDir(s);
      put(s, "stub/workspace-list.out", '{"result":{"workspaces":[{"workspace_id":"w7","label":"home (crewmate)"},{"workspace_id":"w8","label":"home (crewchief)"},{"workspace_id":"w9","label":"other (pane-agent)"},{"workspace_id":"w6","label":"home (pane-agent)"}]}}\n');
      put(s, "stub/tabs-w7", '{"result":{"tabs":[{"label":"1"}]}}\n');
      put(s, "stub/tabs-w8", '{"result":{"tabs":[{"label":"crew:x"}]}}\n');
      put(s, "stub/tabs-w6", "oops\n");
    },
  });
  same("the sweep's list failing ends the caller with its status", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/workspace-list.rc", "3\n")) });
  same("the sweep's list no JSON ends the caller with jq's", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/workspace-list.out", "junk\n")) });
  same("an existing family workspace adopted", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/workspace-list.out", lat('{"result":{"workspaces":[{"workspace_id":"w5","label":"home · t1","tab_count":2}]}}\n'))) });
  same("a workspace create that fails", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/workspace-create.rc", "1\n"), put(s, "stub/workspace-create.err", "server down\n")) });
  same("a tab create that fails", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/tab-create.rc", "4\n"), put(s, "stub/tab-create.err", "boom\n")) });
  same("a tab create answer that is no JSON", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/tab-create.out", "oops\n")) });
  same("a tab create answer without ids", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/tab-create.out", '{"result":{}}\n')) });
  same("W5: a default-tab list that is no JSON ends it before the handle", { ...WN, seed: (s) => (wtDir(s), put(s, "stub/tabs-wNEW", "oops\n")) });
  same("a handle the shell cannot write", { ...WN, seed: (s) => (wtDir(s), mkdirSync(join(s, "home/state/.pane-t1"))) });
  same("herdr missing", { ...WN, path: "noherdr", seed: wtDir });
  same("jq missing", { ...WN, path: "nojq", seed: wtDir });
  same("an unsupported backend", { ...WN, env: { AC_BACKEND: "tmux" }, seed: wtDir });
  same("a herdr session rides every call", { ...WN, env: { AC_HERDR_SESSION: "s1" }, seed: wtDir });
  same("UTF-8, a dir and family with UTF-8 bytes", { ...WN, lc: "en_US.UTF-8", args: ["t1", "@S/wt é"], env: { AC_WINDOW_FAMILY: "fé" }, seed: (s) => mkdirSync(join(s, "wt é")) });
  // Homeless, the handle refused: bash re-expands a redirection it cannot open
  // to name it in its error, so the handle path's `$(ac_state_dir)` prints its
  // ERROR twice - a refusal printed twice (FAIL-PATH), not reproduced.
  if (!ROOTED) {
    const p = pair({ ...WN, homeless: true, env: { AC_FLEET_NAME: "fl" }, seed: wtDir });
    const once = p.o.err.replace(/^(ERROR: AC_HOME is not set.*\n)\1/m, "$1");
    expect(once).not.toBe(p.o.err);
    expect(p.t).toEqual({ ...p.o, err: once });
  }
}, 240000);

const ORCA_ = { AC_BACKEND: "orca" };
const HOMEPANE: Row = { ...WN, args: ["fam-chief", "@S/home"], env: { ...ORCA_, AC_WINDOW_FAMILY: "fam" } };
const famTab = (s: string): void => {
  put(s, "home/state/.orca-fam-fam", "tabF\n");
  put(s, "stub/terminal-list.1.out", '{"ok":true,"result":{"terminals":[{"handle":"hB","tabId":"tabF"},{"handle":"hA","tabId":"tabF"},{"handle":"hX","tabId":"other"}]}}\n');
  put(s, "stub/terminal-list.2.out", '{"ok":true,"result":{"terminals":[{"handle":"hB","tabId":"tabF"},{"handle":"hA","tabId":"tabF"}]}}\n');
  put(s, "stub/terminal-list.3.out", '{"ok":true,"result":{"terminals":[{"handle":"hB","tabId":"tabF"},{"handle":"hA","tabId":"tabF"},{"handle":"hC","tabId":"tabF"}]}}\n');
};

test("backendWindowNew orca: worktree panes under their node, home panes in their family tab, the handle written last", () => {
  same("a worktree pane, no node resolving", { ...WN, env: ORCA_, seed: wtDir });
  same("a worktree pane whose node resolves", { ...WN, env: ORCA_, seed: (s) => (wtDir(s), put(s, "stub/worktree-show.1.out", '{"ok":true,"result":{}}\n')) });
  same("a home pane creates its family tab", HOMEPANE);
  same("a home pane at config/orca-node", { ...HOMEPANE, seed: (s) => put(s, "home/config/orca-node", "id:node-1\n") });
  same("a home pane joins its family tab by split", { ...HOMEPANE, seed: famTab });
  same("a family tab with no live handle is created afresh", { ...HOMEPANE, seed: (s) => put(s, "home/state/.orca-fam-fam", "tabGone\n") });
  same("a split that fails", { ...HOMEPANE, seed: (s) => (famTab(s), put(s, "stub/terminal-split.rc", "1\n")) });
  same("a split whose pane cannot be found", { ...HOMEPANE, seed: (s) => (famTab(s), put(s, "stub/terminal-list.3.out", '{"ok":true,"result":{"terminals":[{"handle":"hA","tabId":"tabF"}]}}\n')) });
  const held = same("a split lock held: forty waits, then on unlocked", { ...HOMEPANE, seed: (s) => (famTab(s), mkdirSync(join(s, "home/state/.orca-split.lock"))) });
  expect(held.t.log.split("\n").filter((l) => l === "sleep 0.25").length).toBe(40);
  same("a create that fails", { ...WN, env: ORCA_, seed: (s) => (wtDir(s), put(s, "stub/terminal-create.rc", "1\n")) });
  same("a create answer without a tab", { ...WN, env: ORCA_, seed: (s) => (wtDir(s), put(s, "stub/terminal-create.out", '{"ok":true,"result":{"terminal":{"handle":"h9"}}}\n')) });
  same("a home pane, AC_WINDOW_FAMILY unset", { ...HOMEPANE, env: ORCA_ });
  same("a home pane, AC_WINDOW_FAMILY empty: _root", { ...HOMEPANE, env: { ...ORCA_, AC_WINDOW_FAMILY: "" } });
  same("orca missing", { ...WN, env: ORCA_, path: "noorca", seed: wtDir });
  same("a handle the shell cannot write", { ...WN, env: ORCA_, seed: (s) => (wtDir(s), mkdirSync(join(s, "home/state/.pane-t1"))) });
}, 240000);

const H = (s: string): void => pane(s, "c1", "p1 w1:t1\n");
const O = (s: string): void => pane(s, "c1", "h1 tab1\n");
const verb = (call: string, ts: string, args: string[]): Row => ({ bash: `${call} "$@"`, twin: `const r = ${ts}; if (r.exited) process.exit(r.status); return r.status;`, args });
const IO = `{ stderr: "inherit" }`;
const BLK = (rule: string): string => `{"state":"blocked","matched_rule":{"id":"${rule}"}}\n`;
const OSHOW = (terminal: string): string => `{"ok":true,"result":{"terminal":${terminal}}}\n`;

test("backendDialogAnswer and its raw-pane form answer the named startup dialogs as the drivers did", () => {
  const id = verb("backend_dialog_answer", `L.backendDialogAnswer(A[0], ${IO})`, ["c1"]);
  const raw = verb("backend_dialog_answer_pane", `L.backendDialogAnswerPane(A[0], ${IO})`, ["p1"]);
  same("herdr: no handle", id);
  same("herdr: explain fails", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.rc", "1\n")) });
  same("herdr: explain names no state", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", "{}\n")) });
  same("herdr: explain is no JSON", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", "oops\n")) });
  same("herdr: nothing pending", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", '{"state":"idle"}\n')) });
  same("herdr: an unnamed dialog", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("trust"))) });
  same("herdr: startup_update answered 2, its tab focused", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("startup_update")), put(s, "stub/pane-get.out", '{"result":{"pane":{"tab_id":"w1:t7"}}}\n')) });
  same("herdr: startup_update, no tab to focus", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("startup_update")), put(s, "stub/pane-get.rc", "1\n")) });
  same("herdr: startup_update, the press fails", { ...id, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("startup_update")), put(s, "stub/pane-send-keys.rc", "1\n")) });
  same("herdr raw: startup_update", { ...raw, seed: (s) => put(s, "stub/agent-explain.out", BLK("startup_update")) });
  same("herdr raw: no pane", { ...raw, args: [""] });
  same("orca: no handle", { ...id, env: ORCA_ });
  same("orca: show fails", { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.rc", "1\n")) });
  same("orca: nothing pending", { ...id, env: ORCA_, seed: O });
  for (const reason of ["codex-update-prompt", "codex-hooks-review-prompt", "other"])
    same(`orca: ${reason}`, { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.out", OSHOW(`{"connected":true,"agentWait":{"reason":"${reason}"}}`))) });
  same("orca: the press fails", { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.out", OSHOW('{"agentWait":{"reason":"codex-update-prompt"}}')), put(s, "stub/terminal-send.rc", "1\n")) });
  same("orca raw: a named dialog", { ...raw, args: ["h1"], env: ORCA_, seed: (s) => put(s, "stub/terminal-show.out", OSHOW('{"agentWait":{"reason":"codex-update-prompt"}}')) });
  same("an unsupported backend", { ...id, env: { AC_BACKEND: "tmux" }, seed: H });
}, 180000);

test("backendAgentIdle and its raw-pane form read idle as the drivers did", () => {
  const id = verb("backend_agent_idle", `L.backendAgentIdle(A[0], ${IO})`, ["c1"]);
  const raw = verb("backend_agent_idle_pane", `L.backendAgentIdlePane(A[0], ${IO})`, ["p1"]);
  same("herdr: no handle", id);
  same("herdr: pane get fails", { ...id, seed: (s) => (H(s), put(s, "stub/pane-get.rc", "1\n")) });
  for (const st of ["idle", "done", "working", "blocked", ""]) same(`herdr: ${st || "no status"}`, { ...id, seed: (s) => (H(s), put(s, "stub/pane-get.out", `{"result":{"pane":{"agent_status":"${st}"}}}\n`)) });
  same("herdr: an answer that is no JSON (jq's line)", { ...id, seed: (s) => (H(s), put(s, "stub/pane-get.out", "oops\n")) });
  same("herdr raw: idle", { ...raw, seed: (s) => put(s, "stub/pane-get.out", '{"result":{"pane":{"agent_status":"idle"}}}\n') });
  same("herdr raw: no pane", { ...raw, args: [""] });
  same("orca: no handle", { ...id, env: ORCA_ });
  same("orca: claude's idle glyph", { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.out", lat(OSHOW('{"connected":true,"title":"✳ Claude Code"}')))) });
  same("orca: a spinner", { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.out", lat(OSHOW('{"connected":true,"title":"◐ working"}')))) });
  same("orca: a dialog", { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.out", OSHOW('{"connected":true,"agentWait":{"reason":"x"}}'))) });
  same("orca: tui-idle satisfied", { ...id, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-wait.out", '{"ok":true,"result":{"wait":{"satisfied":true}}}\n')) });
  same("orca: a codex screen still across a timed-out wait", {
    ...id,
    env: ORCA_,
    seed: (s) => (O(s), put(s, "stub/terminal-show.out", OSHOW('{"connected":true,"agentIdentity":"codex","title":"repo"}')), put(s, "stub/terminal-read.out", '{"ok":true,"result":{"terminal":{"tail":["a","b"]}}}\n'), put(s, "stub/terminal-wait.out", '{"ok":false,"error":{"code":"timeout"}}\n')),
  });
  same("orca raw: no pane", { ...raw, args: [""], env: ORCA_ });
}, 180000);

test("backendSubmitVerified presses Enter once and reads the render as the drivers did", () => {
  const sv = verb("backend_submit_verified", `L.backendSubmitVerified(A[0], A[1] ?? "", ${IO})`, ["c1", "hello"]);
  same("herdr: the render reacts", { ...sv, seed: (s) => (H(s), put(s, "stub/pane-read.1.out", "a\n"), put(s, "stub/pane-read.out", "b\n")) });
  same("herdr: the render never reacts", { ...sv, seed: (s) => (H(s), put(s, "stub/pane-read.out", "a\n")) });
  same("herdr: the read fails", { ...sv, seed: (s) => (H(s), put(s, "stub/pane-read.rc", "1\n")) });
  same("herdr: no handle", sv);
  same("orca: a dialog owns the pane", { ...sv, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-show.out", OSHOW('{"agentWait":{"reason":"x"}}'))) });
  same("orca: the render reacts", { ...sv, env: ORCA_, seed: (s) => (O(s), put(s, "stub/terminal-read.1.out", '{"ok":true,"result":{"terminal":{"tail":["a"]}}}\n'), put(s, "stub/terminal-read.out", '{"ok":true,"result":{"terminal":{"tail":["b"]}}}\n')) });
  same("an unsupported backend", { ...sv, env: { AC_BACKEND: "tmux" }, seed: H });
}, 120000);

test("backendStartupDialogs runs ac_startup_dialogs' sequence over the id-keyed verbs", () => {
  const sd: Row = { bash: `backend_startup_dialogs "$1" "$2"`, twin: `return L.backendStartupDialogs(A[0], A[1], ${IO}).status;`, errexit: true, args: ["c1", "codex"] };
  const upCodex = (s: string): void => put(s, "stub/pane-process-info.out", '{"result":{"process_info":{"foreground_processes":[{"argv0":"codex"}]}}}\n');
  same("herdr: named, unnamed, then up", {
    ...sd,
    seed: (s) => (H(s), upCodex(s), put(s, "stub/agent-explain.1.out", BLK("startup_update")), put(s, "stub/agent-explain.2.out", BLK("trust")), put(s, "stub/agent-explain.3.out", '{"state":"idle"}\n'), put(s, "stub/pane-get.out", '{"result":{"pane":{"tab_id":"w1:t1"}}}\n')),
  });
  same("herdr: an unnamed dialog twice: the key once", { ...sd, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("trust"))) });
  same("herdr: claude has no key", { ...sd, args: ["c1", "claude"], seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("trust"))) });
  same("herdr: unobservable: the key, once, and out", { ...sd, seed: H });
  same("herdr: answered every round, the budget spent", { ...sd, env: { AC_STARTUP_DIALOG_BUDGET: "2" }, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("startup_update"))) });
  same("herdr: a budget [ -lt ] cannot read", { ...sd, env: { AC_STARTUP_DIALOG_BUDGET: "abc" }, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("startup_update"))) });
  same("herdr: nothing pending, up unreadable until the budget", { ...sd, env: { AC_STARTUP_DIALOG_BUDGET: "1" }, seed: (s) => (H(s), put(s, "stub/agent-explain.out", '{"state":"idle"}\n')) });
  same("herdr: nothing pending, a bare shell", { ...sd, seed: (s) => (H(s), put(s, "stub/agent-explain.out", '{"state":"idle"}\n'), put(s, "stub/pane-process-info.out", '{"result":{"process_info":{"foreground_processes":[{"argv0":"-zsh"}]}}}\n')) });
  same("a sleep that fails ends the caller", { ...sd, seed: (s) => (H(s), put(s, "stub/agent-explain.out", BLK("startup_update")), put(s, "stub/sleep.rc", "3\n")) });
  same("orca: both codex prompts answered, then up", {
    ...sd,
    env: ORCA_,
    seed: (s) => (O(s), put(s, "stub/terminal-show.1.out", OSHOW('{"connected":true,"agentWait":{"reason":"codex-update-prompt"}}')), put(s, "stub/terminal-show.2.out", OSHOW('{"connected":true,"agentWait":{"reason":"codex-hooks-review-prompt"}}')), put(s, "stub/terminal-show.out", OSHOW('{"connected":true,"agentIdentity":"codex"}'))),
  });
  same("an unsupported backend", { ...sd, env: { AC_BACKEND: "tmux" }, seed: H });
}, 180000);
