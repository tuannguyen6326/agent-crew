// relocate.test.ts - src/lib.ts's relocate twins held to the LIVE bash they
// twin: shellQuote to bash 3.2's `printf %q` (every byte, under C and under
// the operators' UTF-8 locale), windowFamily and wsFamilyLabel to
// ac_window_family and herdr_ws_family_label (bin/ac-lib.sh,
// bin/ac-backend.sh), and herdrResolveWorkspace, herdrTabCreate and
// herdrCloseDefaultTabs to their herdr helpers in bin/ac-backend.sh, each run
// where bin/ac-relocate.sh's frozen original ran it - inside `$( )`, or at top
// level under errexit. Every row compares stdout, stderr, the status, the stub
// log and the home's tree.
//
// DISPUTED: the implementation of relocate's helpers (bin/ac-lib.sh + bin/ac-backend.sh vs src/lib.ts's relocate twins)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home, the stub's sentinels and log at <side>/stub); argv; env (PATH = the stub, the host's jq, and /bin plus /usr/bin without jq, herdr or orca - no row can reach a real herdr or orca; HOME, TMPDIR, LC_ALL=C unless a row names UTF-8, RSTUB, AC_HOME unless homeless, the row's own names); cwd (the side root); stdin /dev/null.
import { afterAll, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-relocate-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["jq", "herdr", "orca"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const JQ = join(W, "jq");
mkdirSync(JQ);
symlinkSync(Bun.which("jq")!, join(JQ, "jq"));

// A file-backed herdr: <verb>.err is written to stderr, <verb>.out replaces
// the answer, <verb>.rc then ends the call with that status; tabs-<ws> is that
// workspace's tab list (tabs-<ws>.rc its status). Every call is logged with
// its argv bracketed.
const STUB = join(W, "stub");
mkdirSync(STUB);
writeFileSync(
  join(STUB, "herdr"),
  `#!/bin/sh
d="$RSTUB"
{ printf herdr; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; } >>"$d/log"
v="$1-$2"
[ ! -e "$d/$v.err" ] || cat "$d/$v.err" >&2
[ ! -e "$d/$v.out" ] || cat "$d/$v.out"
[ ! -e "$d/$v.rc" ] || exit "$(cat "$d/$v.rc")"
[ ! -e "$d/$v.out" ] || exit 0
case "$v" in
  workspace-list) printf '{"result":{"workspaces":[]}}\\n' ;;
  workspace-create) printf '{"result":{"workspace":{"workspace_id":"wNEW"}}}\\n' ;;
  tab-list)
    [ ! -e "$d/tabs-$4.rc" ] || exit "$(cat "$d/tabs-$4.rc")"
    if [ -e "$d/tabs-$4" ]; then cat "$d/tabs-$4"; else printf '{"result":{"tabs":[]}}\\n'; fi ;;
  tab-close) [ ! -e "$d/close-$3.rc" ] || exit "$(cat "$d/close-$3.rc")" ;;
  tab-create) printf '{"result":{"tab":{"tab_id":"wNEW:tN"},"root_pane":{"pane_id":"pN"}}}\\n' ;;
esac
exit 0
`,
  { mode: 0o755 },
);
const PATH = `${STUB}:${JQ}:${BASE}`;

const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");

type Row = { seed?: (s: string) => void; env?: Record<string, string>; homeless?: boolean; lc?: string };
type Side = { out: string; err: string; rc: number | null; log: string; world: string };

function world(h: string, rel = ""): string {
  let names: string[];
  try {
    names = readdirSync(join(h, rel));
  } catch {
    return "";
  }
  let w = "";
  for (const name of names.sort()) {
    const r = rel ? `${rel}/${name}` : name;
    if (lstatSync(join(h, r)).isDirectory()) w += `${r}/\n${world(h, r)}`;
    else w += `${r} = ${JSON.stringify(readFileSync(join(h, r), "latin1"))}\n`;
  }
  return w;
}

let rows = 0;
// One row: the bash call on one side, the twin's on the other. <bash> is the
// call as relocate made it, <ts> the module body over the imported lib `L`
// and `say` (stdout, latin1); both read <args> (latin1 bytes) from a file -
// argv would reach them decoded - the bash as its positional parameters, the
// twin as `args`.
function same(label: string, row: Row, bash: string, ts: string, args: string[]): { o: Side; t: Side } {
  const r = join(W, `r${rows++}`);
  const sides: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(r, name);
    for (const sub of ["home/state", "home/data", "home/config", "stub"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    const env: Record<string, string> = { PATH, HOME: process.env.HOME!, TMPDIR: W, LC_ALL: row.lc ?? "C", RSTUB: join(s, "stub") };
    if (!row.homeless) env.AC_HOME = join(s, "home");
    for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
    writeFileSync(join(s, "args"), Buffer.from(args.map((a) => `${a}\0`).join(""), "latin1"));
    let cmd: string[];
    if (name === "o")
      cmd = ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; a=(); while IFS= read -r -d '' x; do a+=("$x"); done <args; set -- \${a[@]+"\${a[@]}"}; ${bash}`, BIN];
    else {
      const script = join(r, "t.ts");
      writeFileSync(
        script,
        `import { writeSync } from "node:fs";\nconst L = await import(${JSON.stringify(LIB)});\nconst say = (s: string): void => void writeSync(1, Buffer.from(s, "latin1"));\nconst args = require("node:fs").readFileSync("args", "latin1").split("\\0").slice(0, -1);\n${ts}\n`,
      );
      cmd = [process.execPath, "--no-env-file", script];
    }
    const p = Bun.spawnSync(cmd, { cwd: s, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    // bash 3.2's `set -m` (herdr_rpc_bounded) races the child it backgrounds
    // and now and then prints `<script>: child setpgid (<pid> to <pid>):
    // Operation not permitted` - shell-own stderr, never reproduced, so it is
    // dropped as tests/sh/ac-relocate.test.sh's rnorm drops it.
    const norm = (t: string): string => t.replaceAll(s, "S").replace(/^.*: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted\n/gm, "");
    let log = "";
    try {
      log = readFileSync(join(s, "stub", "log"), "latin1");
    } catch {}
    sides.push({ out: norm(p.stdout.toString("latin1")), err: norm(p.stderr.toString("latin1")), rc: p.exitCode, log: norm(log), world: norm(world(join(s, "home"))) });
  }
  const [o, t] = sides as [Side, Side];
  expect({ label, ...t }).toEqual({ label, ...o });
  return { o, t };
}

const put = (s: string, rel: string, body: string): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  writeFileSync(join(s, rel), Buffer.from(body, "latin1"));
};

test("shellQuote spells every byte as bash 3.2's printf %q does, under C and under UTF-8", () => {
  const cases: string[] = [];
  for (let b = 1; b < 256; b++) cases.push(String.fromCharCode(b), `a${String.fromCharCode(b)}b`);
  cases.push("", "#a", "a#b", "~a", "a=~b", "/tmp/x y", "p$x", "-x", "%s", lat("日本"), lat("é"), lat("/tmp/日本 x"), "a\nb", "\r\\'\"", lat("a·b"), "\xad", "a\xa0\\");
  const input = join(W, "q.in");
  writeFileSync(input, Buffer.from(cases.map((c) => `${c}\0`).join(""), "latin1"));
  for (const lc of ["C", "en_US.UTF-8"]) {
    const o = Bun.spawnSync(["/bin/bash", "-c", `while IFS= read -r -d '' s; do printf '%q\\0' "$s"; done <"$0"`, input], { env: { LC_ALL: lc, PATH: BASE }, stdout: "pipe" });
    const want = o.stdout.toString("latin1").split("\0").slice(0, -1);
    expect(want.length).toBe(cases.length);
    const t = Bun.spawnSync([process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const cs = require("node:fs").readFileSync(${JSON.stringify(input)}, "latin1").split("\\0").slice(0, -1); process.stdout.write(Buffer.from(cs.map((c) => L.shellQuote(c) + "\\0").join(""), "latin1"));`], {
      env: { LC_ALL: lc, PATH: process.env.PATH! },
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(t.stderr.toString()).toBe("");
    const got = t.stdout.toString("latin1").split("\0").slice(0, -1);
    expect(cases.map((c, i) => ({ lc, c, q: got[i] }))).toEqual(cases.map((c, i) => ({ lc, c, q: want[i] })));
  }
}, 30000);

test("windowFamily and wsFamilyLabel answer what ac_window_family and herdr_ws_family_label answer", () => {
  const family = "fam=\"$(ac_window_family \"$1\")\"; printf '[%s]|rc=%s' \"$fam\" \"$?\"";
  const familyTs = `say("[" + L.windowFamily(Buffer.from(args[0], "latin1").toString("utf8")).replace(/\\n+$/, "") + "]|rc=0");`;
  const stages = (s: string): void => (mkdirSync(join(s, "home", "data", "famR", "chief"), { recursive: true }), mkdirSync(join(s, "home", "data", "fam2", "spec"), { recursive: true }));
  const rowsF: [string, string, Row][] = [
    ["a flat id", "t1", {}],
    ["a chief with its family's stage dir", "famR-chief", { seed: stages }],
    ["a chief without it", "famR-chief", {}],
    ["a staged revision", "fam2-spec-r2", { seed: stages }],
    ["a bare revision", "foo-r3", {}],
    ["AC_SCOPE first", "t1", { env: { AC_SCOPE: "other", AC_FLEET_SCOPE: "fs" } }],
    ["AC_SCOPE outside the grammar is skipped", "t1", { env: { AC_SCOPE: "a/b", AC_FLEET_SCOPE: "fs" } }],
    ["AC_FLEET_SCOPE", "t1", { env: { AC_FLEET_SCOPE: "f_s-1" } }],
    ["both outside the grammar", "t1", { env: { AC_SCOPE: "a b", AC_FLEET_SCOPE: "x.y" } }],
    ["an empty AC_SCOPE", "t1", { env: { AC_SCOPE: "", AC_FLEET_SCOPE: "fs" } }],
  ];
  for (const [label, id, row] of rowsF) same(`window family: ${label}`, row, family, familyTs, [id]);
  const lbl = "l=\"$(herdr_ws_family_label \"$1\")\"; printf '[%s]|rc=%s' \"$l\" \"$?\"";
  const lblTs = `say("[" + L.wsFamilyLabel(args[0]).replace(/\\n+$/, "") + "]|rc=0");`;
  const rowsL: [string, string, Row][] = [
    ["the root", "", {}],
    ["a family", "famR", {}],
    ["a family with a space", "a b", {}],
    ["a family's UTF-8 bytes", lat("café"), {}],
    ["a byte that is not UTF-8", "a\xe9", {}],
    ["a symlinked home names its target", "f", { seed: (s) => (mkdirSync(join(s, "real", "fleetX"), { recursive: true }), symlinkSync(join(s, "real", "fleetX"), join(s, "link"))), env: { AC_HOME: "@S/link" } }],
    ["homeless, AC_FLEET_NAME", "f", { homeless: true, env: { AC_FLEET_NAME: "named" } }],
    ["homeless, no name", "f", { homeless: true }],
  ];
  for (const [label, fam, row] of rowsL) same(`label: ${label}`, row, lbl, lblTs, [fam]);
}, 60000);

const RESOLVE = "ws=\"$(herdr_resolve_workspace \"$1\")\"; printf '[%s]|rc=%s' \"$ws\" \"$?\"";
const RESOLVE_TS = `const ws = L.herdrResolveWorkspace(args[0]); say(ws === null ? "[]|rc=1" : "[" + ws + "]|rc=0");`;
const ws = (s: string, body: string): void => put(s, "stub/workspace-list.out", body);
const LBL = lat("home · famR");
const twin = (id: string, tabs: number | null, label = LBL): string => `{"workspace_id":"${id}","label":"${label}"${tabs === null ? "" : `,"tab_count":${tabs}`}}`;

test("herdrResolveWorkspace adopts, sweeps and creates as herdr_resolve_workspace did", () => {
  const rowsR: [string, Row][] = [
    ["no twin: created", {}],
    ["one twin: adopted, nothing swept", { seed: (s) => ws(s, `{"result":{"workspaces":[${twin("w1", 3)}]}}\n`) }],
    [
      "the busiest of four adopted; an empty twin closed, a held one and an unreadable one warned, another label ignored",
      {
        seed: (s) => {
          ws(s, `{"result":{"workspaces":[${twin("w1", 1)},${twin("w2", 5)},${twin("w3", null)},${twin("w4", 0)},${twin("w5", 2)},${twin("w9", 9, "other")}]}}\n`);
          put(s, "stub/tabs-w1", '{"result":{"tabs":[{"label":"1"},{"label":"1"}]}}\n');
          put(s, "stub/tabs-w3", '{"result":{"tabs":[{"label":"crew:x"}]}}\n');
          put(s, "stub/tabs-w4.rc", "1\n");
          put(s, "stub/tabs-w5", "not json\n");
        },
      },
    ],
    [
      "a refused close names workspace_group_close_required; another refusal is silent",
      {
        seed: (s) => {
          ws(s, `{"result":{"workspaces":[${twin("w2", 5)},${twin("w1", 1)}]}}\n`);
          put(s, "stub/workspace-close.rc", "3\n");
          put(s, "stub/workspace-close.err", '{"error":{"code":"workspace_group_close_required"}}\n');
        },
      },
    ],
    ["a refusal without the code", { seed: (s) => (ws(s, `{"result":{"workspaces":[${twin("w2", 5)},${twin("w1", 1)}]}}\n`), put(s, "stub/workspace-close.rc", "3\n"), put(s, "stub/workspace-close.err", "nope\n")) }],
    ["the code on stdout", { seed: (s) => (ws(s, `{"result":{"workspaces":[${twin("w2", 5)},${twin("w1", 1)}]}}\n`), put(s, "stub/workspace-close.rc", "3\n"), put(s, "stub/workspace-close.out", "workspace_group_close_required\n")) }],
    ["a tab list that is no array reads unreadable", { seed: (s) => (ws(s, `{"result":{"workspaces":[${twin("w2", 5)},${twin("w1", 1)}]}}\n`), put(s, "stub/tabs-w1", '{"result":{"tabs":"x"}}\n')) }],
    ["two tab lists in one answer read unreadable", { seed: (s) => (ws(s, `{"result":{"workspaces":[${twin("w2", 5)},${twin("w1", 1)}]}}\n`), put(s, "stub/tabs-w1", '{"result":{"tabs":[]}}\n{"result":{"tabs":[{"label":"x"}]}}\n')) }],
    ["an empty first id creates, the rest swept", { seed: (s) => ws(s, `{"result":{"workspaces":[${twin("", 9)},${twin("w7", 1)}]}}\n`) }],
    ["a repeated id is the adopted one", { seed: (s) => ws(s, `{"result":{"workspaces":[${twin("w1", 2)},${twin("w1", 1)}]}}\n`) }],
    ["a list that is not JSON creates", { seed: (s) => ws(s, "oops\n") }],
    ["a list that fails creates", { seed: (s) => put(s, "stub/workspace-list.rc", "1\n") }],
    ["a create that fails dies, herdr's own stderr first", { seed: (s) => (put(s, "stub/workspace-create.rc", "1\n"), put(s, "stub/workspace-create.err", '{"error":{"code":"server_not_running"}}\n')) }],
    ["a create answer without the id dies", { seed: (s) => put(s, "stub/workspace-create.out", '{"result":{}}\n') }],
    ["a create answer that is not JSON: jq's line, then the parse refusal", { seed: (s) => put(s, "stub/workspace-create.out", "oops\n") }],
    ["a create answer with two ids", { seed: (s) => put(s, "stub/workspace-create.out", '{"result":{"workspace":{"workspace_id":"a"}}}\n{"result":{"workspace":{"workspace_id":"b"}}}\n') }],
    ["a session rides every RPC", { env: { AC_HERDR_SESSION: "s1" }, seed: (s) => ws(s, `{"result":{"workspaces":[${twin("w2", 5)},${twin("w1", 1)}]}}\n`) }],
  ];
  for (const [label, row] of rowsR) same(`resolve: ${label}`, row, RESOLVE, RESOLVE_TS, [LBL]);
}, 60000);

test("herdrTabCreate and herdrCloseDefaultTabs run what herdr_tab_create and herdr_close_default_tabs ran", () => {
  const create = "out=\"$(herdr_tab_create \"$@\")\"; printf '[%s]|rc=%s' \"$out\" \"$?\"";
  const createTs = `const r = L.herdrTabCreate(args[0], args[1], args[2]); say("[" + r.out + "]|rc=" + r.status);`;
  const rowsC: [string, string[], Row][] = [
    ["into a workspace", ["wC", "/tmp/x y", "t1"], {}],
    ["no workspace", ["", "/tmp", "t1"], {}],
    ["a failing create keeps herdr's stderr", ["wC", "/tmp", "t1"], { seed: (s) => (put(s, "stub/tab-create.rc", "4\n"), put(s, "stub/tab-create.err", "boom\n")) }],
    ["the answer as `$( )` reads it", ["wC", "/tmp", "t1"], { seed: (s) => put(s, "stub/tab-create.out", "a\0b\n\n\n") }],
  ];
  for (const [label, args, row] of rowsC) same(`tab create: ${label}`, row, create, createTs, args);
  const closeB = `set -e; trap 'printf "|rc=%s" "$?"' EXIT; herdr_close_default_tabs "$1"`;
  const closeTs = `const rc = L.herdrCloseDefaultTabs(args[0]); say("|rc=" + rc); process.exit(rc);`;
  const rowsD: [string, Row][] = [
    ["none", {}],
    [
      "the default tabs closed, a failing close ignored, a tab without an id closed as null",
      { seed: (s) => (put(s, "stub/tabs-wC", '{"result":{"tabs":[{"label":"1","tab_id":"wC:t0"},{"label":"crew:x","tab_id":"wC:t9"},{"label":"1","tab_id":"wC:t2"},{"label":"1"}]}}\n'), put(s, "stub/close-wC:t0.rc", "7\n")) },
    ],
    ["a list that fails", { seed: (s) => put(s, "stub/tabs-wC.rc", "1\n") }],
    ["a list that is not JSON ends the caller with jq's status", { seed: (s) => put(s, "stub/tabs-wC", "oops\n") }],
    ["a tab that is no object ends it too", { seed: (s) => put(s, "stub/tabs-wC", '{"result":{"tabs":["x"]}}\n') }],
    ["tabs that are no array close nothing", { seed: (s) => put(s, "stub/tabs-wC", '{"result":{"tabs":"x"}}\n') }],
  ];
  for (const [label, row] of rowsD) same(`default tabs: ${label}`, row, closeB, closeTs, ["wC"]);
}, 60000);
