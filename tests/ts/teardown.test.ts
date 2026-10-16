// teardown.test.ts - what src/teardown.ts brought into src/lib.ts, held to the
// LIVE bash helpers it twins: taskStamps (ac_task_stamps), portSlotRelease
// (ac_port_slot_release), soloLandingCheck (ac_solo_landing_check),
// backendKillWindow (backend_kill_window, both drivers, with herdr_ws_close's
// group arm) and orcaWorktreeRelease (orca_worktree_release); and the
// module's killServePid against kill_serve_pid lifted from the frozen
// tests/fixtures/ac-teardown.sh, both sides driven through a kill SPY - no row
// sends a real signal. The CLI contract itself is
// tests/sh/ac-teardown.test.sh's, whose differential leg runs the frozen
// original beside the shim.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts / src/teardown.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with state/ records/ data/ config/, the stubs' sentinels and log at <side>/stub); argv; env (PATH = the herdr/orca/sleep/date stubs, the host's jq and git, /bin and /usr/bin without herdr, orca or docker; LC_ALL=C unless a row names UTF-8; HOME, TMPDIR, STUB_DIR, AC_HOME unless homeless, a row's own names); cwd (the distro root, so `ac_root` and STARTED_BIN name one bin/); stdin (/dev/null); stdout, stderr and the status compared whole (the side root spelled S, the process's pid PID), then the home's tree and the stub log.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));

test("transcriptTokens sums each model once per message, across the main transcript and its subagents", async () => {
  const { transcriptTokens } = await import("../../src/teardown.ts");
  const u = (id: string, model: string, i: number, cw: number, cr: number, o: number) =>
    JSON.stringify({ message: { id, model, usage: { input_tokens: i, cache_creation_input_tokens: cw, cache_read_input_tokens: cr, output_tokens: o } } });
  const main = [u("m1", "opus", 10, 100, 1000, 5), u("m1", "opus", 10, 100, 1000, 50), "not json", "", JSON.stringify({ type: "user" }), u("m2", "opus", 1, 2, 3, 4)].join("\n");
  const sub = u("s1", "haiku", 7, 8, 9, 6);
  expect([...transcriptTokens([main, sub]).entries()]).toEqual([["haiku", [7, 8, 9, 6]], ["opus", [11, 102, 1003, 54]]]);
  expect(transcriptTokens([""]).size).toBe(0);
});

const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const TEARDOWN = join(ROOT, "src", "teardown.ts");
const FIXTURE = join(ROOT, "tests", "fixtures", "ac-teardown.sh");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-teardown-ts-")));
const ROOTED = process.getuid?.() === 0;
afterAll(() => rmSync(W, { recursive: true, force: true }));

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["jq", "herdr", "orca", "docker", "codegraph", "sleep", "date"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["jq", "git"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));

// herdr: tabs are <stub>/tab-<id> files holding the label; `tab close` honours
// close-rc (exit it, the tab kept) and close-drops (exit 1, the tab gone);
// `tab list` serves <stub>/list (list-fails: exit 1); `workspace close`
// refuses with workspace_group_close_required while ws-group-<ws> exists
// (the --group form then fails while group-fails exists), or with another
// text while ws-close-fails exists; unreachable fails every call.
const HERDR = `#!/bin/sh
d="$STUB_DIR"
printf 'herdr %s [%s]\\n' "$*" "\${HERDR_SESSION:-}" >>"$d/log"
[ ! -e "$d/unreachable" ] || { echo '{"error":{"code":"protocol_mismatch"}}' >&2; exit 1; }
case "$1 $2" in
  "tab get") [ -e "$d/tab-$3" ] || exit 1; printf '{"result":{"tab":{"tab_id":"%s","label":"%s"}}}\\n' "$3" "$(cat "$d/tab-$3")" ;;
  "tab close")
    [ ! -e "$d/close-drops" ] || { rm -f "$d/tab-$3"; exit 1; }
    [ ! -e "$d/close-rc" ] || exit "$(cat "$d/close-rc")"
    rm -f "$d/tab-$3" ;;
  "tab list") [ ! -e "$d/list-fails" ] || exit 1; [ ! -e "$d/list" ] || cat "$d/list" ;;
  "workspace close")
    if [ "$4" = --group ]; then [ ! -e "$d/group-fails" ] || exit 1; rm -f "$d/ws-group-$3"; exit 0; fi
    [ ! -e "$d/ws-group-$3" ] || { echo '{"error":{"code":"workspace_group_close_required"}}' >&2; exit 1; }
    [ ! -e "$d/ws-close-fails" ] || { echo 'some other refusal' >&2; exit 1; }
    : ;;
  *) exit 2 ;;
esac
`;
// orca: <stub>/terms lists "<handle> <tab>" per terminal; `terminal close`
// marks the handle closed (close-fails: exit 1), and `terminal list` keeps a
// closed handle listed while <stub>/linger counts down (list-raw is served
// as is; list-fails exits 1); `worktree rm` answers ok unless rm-refuses
// (ok:false) or rm-fails (exit 1).
const ORCA = `#!/bin/sh
d="$STUB_DIR"
printf 'orca %s\\n' "$*" >>"$d/log"
case "$1 $2" in
  "terminal close") [ ! -e "$d/close-fails" ] || exit 1; : >"$d/closed-$4"; echo '{"ok":true,"result":{}}' ;;
  "terminal list")
    [ ! -e "$d/list-fails" ] || exit 1
    [ ! -e "$d/list-raw" ] || { cat "$d/list-raw"; exit 0; }
    n=$(cat "$d/linger" 2>/dev/null || echo 0)
    [ "$n" -le 0 ] || echo $((n - 1)) >"$d/linger"
    printf '{"ok":true,"result":{"terminals":['
    sep=""
    while read -r h t; do
      [ -n "$h" ] || continue
      if [ -e "$d/closed-$h" ] && [ "$n" -le 0 ]; then continue; fi
      printf '%s{"handle":"%s","tabId":"%s"}' "$sep" "$h" "$t"; sep=,
    done <"$d/terms"
    printf ']}}\\n' ;;
  "worktree rm")
    [ ! -e "$d/rm-fails" ] || exit 1
    if [ -e "$d/rm-refuses" ]; then echo '{"ok":false,"error":{"message":"selector_not_found"}}'; else echo '{"ok":true,"result":{}}'; fi ;;
  *) exit 2 ;;
esac
`;
const STUBS = join(W, "stubs");
mkdirSync(STUBS);
writeFileSync(join(STUBS, "herdr"), HERDR, { mode: 0o755 });
writeFileSync(join(STUBS, "orca"), ORCA, { mode: 0o755 });
writeFileSync(join(STUBS, "sleep"), `#!/bin/sh\nprintf 'sleep %s\\n' "$*" >>"$STUB_DIR/log"\n`, { mode: 0o755 });
writeFileSync(join(STUBS, "date"), `#!/bin/sh\ncase "$*" in *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;; *%Y-%m-%d*) echo 2026-01-01 ;; *%s*) echo 1767225600 ;; *) exec /bin/date "$@" ;; esac\n`, { mode: 0o755 });
const PATH = `${STUBS}:${TOOLS}:${BASE}`;

type Row = {
  // the bash call, run after sourcing ac-lib.sh and ac-backend.sh, its
  // arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  homeless?: boolean;
  lc?: string;
  // RLIMIT_FSIZE in 512-byte blocks, SIGXFSZ ignored, so a write past it
  // fails as on a full disk
  fsize?: string;
};
type Side = { out: string; err: string; rc: number | null; log: string; world: string };

const GIT_ENV = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t", GIT_AUTHOR_DATE: "2026-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2026-01-01T00:00:00Z", GIT_CONFIG_NOSYSTEM: "1" };

function world(h: string, rel = ""): string {
  let names: string[];
  try {
    names = readdirSync(join(h, rel));
  } catch {
    return "";
  }
  let w = "";
  for (const name of names.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    const r = rel ? `${rel}/${name}` : name;
    if (r.endsWith("/.git") || r === ".git") continue;
    const st = lstatSync(join(h, r));
    const mode = (st.mode & 0o777).toString(8);
    if (st.isSymbolicLink()) w += `${r} -> ${readlinkSync(join(h, r))}\n`;
    else if (st.isDirectory()) w += `${r}/ ${mode}\n${world(h, r)}`;
    else {
      let body = "<unreadable>";
      try {
        body = readFileSync(join(h, r), "latin1");
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

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: row.lc ?? "C", STUB_DIR: join(s, "stub"), ...GIT_ENV };
  if (!row.homeless) env.AC_HOME = join(s, "home");
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const A = ${JSON.stringify(args)}; const rc = await (async () => { ${row.twin} })(); writeSync(1, "|rc=" + rc);`,
      ];
  const run = row.fsize === undefined ? cmd : ["/bin/sh", "-c", `ulimit -f ${row.fsize}; trap "" XFSZ; exec "$@"`, "sh", ...cmd];
  const r = Bun.spawnSync(run, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const norm = (t: string): string => t.replaceAll(s, "S").replace(/\.tmp\.[0-9]+/g, ".tmp.PID");
  let err = norm(r.stderr.toString("latin1"));
  if (oracle) err = err.replace(/^.*: line [0-9]+: .*\n/gm, "");
  return { out: norm(r.stdout.toString("latin1")), err, rc: r.exitCode, log: norm(read(join(s, "stub", "log"))), world: norm(world(join(s, "home"))) };
}

function pair(row: Row): { o: Side; t: Side; root: string } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    for (const sub of ["home/state", "home/records", "home/data", "home/config", "stub"]) mkdirSync(join(s, sub), { recursive: true });
    writeFileSync(join(s, "stub", "terms"), "");
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]!, root };
}

function same(label: string, row: Row): { o: Side; t: Side; root: string } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, rc: x.rc, log: x.log, world: x.world });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const put = (s: string, rel: string, body: string, mode = 0o644): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  writeFileSync(join(s, rel), Buffer.from(body.replaceAll("@S", s), "latin1"), { mode });
  chmodSync(join(s, rel), mode);
};
const stub = (s: string, name: string, body = ""): void => put(s, `stub/${name}`, body);
const pane = (s: string, id: string, body: string): void => put(s, `home/state/.pane-${id}`, body);

test("taskStamps: the thirteen per-id stamp paths, in ac_task_stamps' order", () => {
  for (const id of ["t1", "a b", "x-verify-codereview"]) {
    const p = same(`stamps ${id}`, { bash: `ac_task_stamps "$1" "$2"`, twin: `for (const f of L.taskStamps(A[0], A[1])) writeSync(1, f + "\\n"); return 0;`, args: ["@S/home/state", id] });
    expect(p.t.out.split("\n").length).toBe(14);
  }
});

test("portSlotRelease: the worktree's row dropped under the registry lock; no home, no registry or a lock not taken leave it, silently", () => {
  const REG = "home/state/port-slots.tsv";
  const rel: Row = { bash: `ac_port_slot_release "$1"`, twin: `L.portSlotRelease(A[0]); return 0;`, args: ["@S/wt2"] };
  const three = (s: string): void => put(s, REG, "1\t@S/wt1\tp\t2026\n2\t@S/wt2\tp\t2026\n3\t@S/wt3\tp\t2026\n");
  const p = same("a row dropped", { ...rel, seed: three });
  expect(p.t.world).toContain('port-slots.tsv 644 = "1\\tS/wt1\\tp\\t2026\\n3\\tS/wt3\\tp\\t2026\\n"');
  same("no row for it", { ...rel, args: ["@S/wt9"], seed: three });
  same("no registry", { ...rel });
  same("homeless", { ...rel, homeless: true, seed: three });
  same("an empty registry", { ...rel, seed: (s) => put(s, REG, "") });
  same("awk -v reads its escapes", { ...rel, args: ["@S/w\\tt"], seed: (s) => put(s, REG, "1\t@S/w\tt\tp\n2\t@S/w\\tt\tp\n") });
  // W20: a live holder outlasts the ten PATH sleeps; the row stays, nothing said.
  const held = same("a lock held by a live pid", { ...rel, seed: (s) => (three(s), put(s, `${REG}.lock/pid`, `${process.pid}\n`)) });
  expect(held.t.log).toBe("sleep 1\n".repeat(10));
  expect(held.t.world).toContain("2\\tS/wt2");
  same("a lock left by a dead pid is reclaimed", { ...rel, seed: (s) => (three(s), put(s, `${REG}.lock/pid`, "999999\n")) });
  if (!ROOTED) {
    // awk cannot read it: its own line, the temp it was given left behind,
    // the registry as it was.
    const un = same("an unreadable registry", { ...rel, seed: (s) => (three(s), chmodSync(join(s, REG), 0o000)) });
    expect(un.t.err).toMatch(/^awk: can't open file S\/home\/state\/port-slots.tsv/);
    expect(un.t.world).toContain("port-slots.tsv.tmp.PID 644");
  }
});

// Never a teardown failure, the write side included: a temp that outgrows the
// file-size limit mid-write (the registry past 512 bytes under `ulimit -f 1`)
// and a lock whose pid cannot be written (`ulimit -f 0`) leave the registry
// whole and answer as on success, on both sides.
test("portSlotRelease: a registry temp or lock pid that cannot be written leaves the registry whole", () => {
  const REG = "home/state/port-slots.tsv";
  const rows40 = Array.from({ length: 40 }, (_, i) => `${i}\t@S/wt${i}\tp\t2026\n`).join("");
  const rel: Row = { bash: `ac_port_slot_release "$1"`, twin: `L.portSlotRelease(A[0]); return 0;`, args: ["@S/wt2"], seed: (s) => put(s, REG, rows40) };
  for (const fsize of ["1", "0"]) {
    const p = pair({ ...rel, fsize });
    for (const [who, x] of [["bash", p.o], ["twin", p.t]] as const) {
      // The bash's failed pid printf stays in its builtin's buffer and comes
      // out ahead of the marker - bash 3.2's stdio, not a result.
      expect([fsize, who, x.out.endsWith("|rc=0")]).toEqual([fsize, who, true]);
      const sideRoot = join(p.root, who === "bash" ? "o" : "t");
      expect([fsize, who, read(join(sideRoot, REG))]).toEqual([fsize, who, rows40.replaceAll("@S", sideRoot)]);
    }
  }
});

test("portSlotRelease, named: the temp is created exclusively and keeps the registry's mode", () => {
  // DISPUTED: whether a planted symlink at <reg>.tmp.<pid> is written through
  // HELD-CONSTANT: the registry, the row released, the planted link and its victim
  const REG = "home/state/port-slots.tsv";
  const plant = (s: string, pid: string): string =>
    `ln -s "${s}/victim" "${s}/${REG}.tmp.${pid}"`;
  const p = pair({
    bash: `${plant("$STUB_DIR/..", "$$")}; ac_port_slot_release "$1"`,
    twin: `Bun.spawnSync(["ln", "-s", process.env.STUB_DIR + "/../victim", process.env.STUB_DIR + "/../${REG}.tmp." + process.pid]); L.portSlotRelease(A[0]); return 0;`,
    args: ["@S/wt2"],
    seed: (s) => (put(s, REG, "1\t@S/wt1\n2\t@S/wt2\n", 0o600), put(s, "victim", "victim bytes\n")),
  });
  expect(read(join(p.root, "t", "victim"))).toBe("victim bytes\n");
  expect(read(join(p.root, "o", "victim"))).toBe(`1\t${join(p.root, "o")}/wt1\n`);
  expect(lstatSync(join(p.root, "o", REG)).isSymbolicLink()).toBe(true);
  expect(lstatSync(join(p.root, "t", REG)).isSymbolicLink()).toBe(false);
  expect(read(join(p.root, "t", REG))).toBe(`1\t${join(p.root, "t")}/wt1\n`);
  expect((lstatSync(join(p.root, "t", REG)).mode & 0o777).toString(8)).toBe("600");
  const left = readdirSync(join(p.root, "t", "home", "state")).filter((n) => n.includes(".tmp."));
  expect(left.length).toBe(1);
  expect(lstatSync(join(p.root, "t", "home", "state", left[0]!)).isSymbolicLink()).toBe(true);
  const mode = pair({ bash: `umask 022; ac_port_slot_release "$1"`, twin: `process.umask(0o022); L.portSlotRelease(A[0]); return 0;`, args: ["@S/wt2"], seed: (s) => put(s, REG, "2\t@S/wt2\n", 0o600) });
  expect(mode.o.world).toContain("port-slots.tsv 644");
  expect(mode.t.world).toContain("port-slots.tsv 600");
});

// A repo whose main checkout is <s>/<name>, so its config name is <name>.
function repo(s: string, name: string): void {
  const r = join(s, name);
  for (const args of [["init", "-q", "-b", "main", r], ["-C", r, "commit", "-q", "--allow-empty", "-m", "init"]])
    Bun.spawnSync(["git", ...args], { env: { PATH, HOME: W, ...GIT_ENV }, stdin: "ignore", stdout: "ignore", stderr: "ignore" });
}

test("soloLandingCheck: the line on the record and stdout, the hint per missing write, the answer", () => {
  const solo = (args: string[], seed: (s: string) => void, extra: Partial<Row> = {}): Row => ({
    bash: `ac_solo_landing_check "$@"`,
    twin: `return L.soloLandingCheck(A[0], A[1], A[2], A[3], A[4]) ? 0 : 1;`,
    args,
    seed: (s) => (put(s, "home/state/s1.meta", "kind=self\n"), repo(s, "proj"), seed(s)),
    ...extra,
  });
  const P = "@S/proj";
  const none = same("nothing written", solo(["s1", P, "", "", ""], () => {}));
  expect(none.t.out).toBe(
    `knowledge loop: lessons=none repo-knowledge=none done-row=none\nmissing - the solo contract owes these at landing:\n  lesson: ${ROOT}/bin/ac-learn.sh note '### 2026-01-01 (solo s1)' '- <one method lesson>'   (or --no-lesson '<why nothing new>')\n  repo fact: ${ROOT}/bin/ac-know.sh add --home S/home --repo S/proj --family s1 --src-file <path>:<line> --fact '<verified fact>'   (or --no-fact '<why none verified>')\n  done row: append '- [x] s1 - <outcome>' under ## Done in S/home/records/backlog.md\n|rc=1`,
  );
  expect(none.t.world).toContain('state/s1.status 644 = "2026-01-01T00:00:00Z knowledge loop: lessons=none repo-knowledge=none done-row=none\\n"');
  same("no repo at all", solo(["s1", "", "", "", ""], () => {}));
  same("a repo that is no directory", solo(["s1", "@S/nope", "", "", ""], () => {}));
  const all = same(
    "all three written",
    solo(["s1", P, "", "", ""], (s) => {
      put(s, "home/records/learnings.md", "# L\n### 2026-01-01 (solo s1)\n- a lesson\n");
      put(s, "home/records/repo-knowledge/proj.md", "# K\n- a fact | by: s1\n");
      put(s, "home/records/backlog.md", "# B\n## Done\n- [x] s1 - done\n");
    }),
  );
  expect(all.t.out).toBe("knowledge loop: lessons=yes repo-knowledge=yes done-row=yes\n|rc=0");
  same("waived", solo(["s1", P, "nothing new", "none verified", ""], (s) => put(s, "home/records/backlog.md", "## Done\n- [x] s1 - x\n")));
  same("a (by: s1, line", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/learnings.md", "### 2026 (family f)\n- x (by: s1, first-hand)\n")));
  same("only (by: s1-2,", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/learnings.md", "### 2026 (family f)\n- x (by: s1-2, first-hand)\n")));
  same("the lesson past ## Distilled", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/learnings.md", "## Distilled\n### 2026 (solo s1)\n")));
  same("the fact past ## Superseded", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/repo-knowledge/proj.md", "## Superseded\n- a fact | by: s1\n")));
  same("a fact not at the end", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/repo-knowledge/proj.md", "- a fact | by: s1 x\n")));
  same("a Done row not under ## Done", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/backlog.md", "## Queued\n- [x] s1 - x\n## Done\n")));
  same("a Done row for s1-2", solo(["s1", P, "", "", ""], (s) => put(s, "home/records/backlog.md", "## Done\n- [x] s1-2 - x\n")));
  const scoped = same("scoped, no receipt", solo(["f-s1", P, "", "", "f"], () => {}));
  expect(scoped.t.out).toContain(`  landed receipt: ${ROOT}/bin/ac-room.sh post f f-chief 'LANDED: f-s1 - <outcome>'`);
  same("scoped, LANDED", solo(["f-s1", P, "w", "w", "f"], (s) => put(s, "home/data/f/room.md", "- [2026] f-chief> LANDED: f-s1 - ok\n")));
  same("scoped, UNLANDABLE", solo(["f-s1", P, "w", "w", "f"], (s) => put(s, "home/data/f/room.md", "- [2026] f-chief> UNLANDABLE: f-s1 - why\n")));
  same("scoped, another slice's receipt", solo(["f-s1", P, "w", "w", "f"], (s) => put(s, "home/data/f/room.md", "- [2026] f-chief> LANDED: f-s1-2 - ok\n")));
  same("scoped, the receipt in prose", solo(["f-s1", P, "w", "w", "f"], (s) => put(s, "home/data/f/room.md", "  LANDED: f-s1 - ok\n")));
  same("an empty id", solo(["", P, "", "", ""], () => {}));
  same("UTF-8, a lesson heading", { ...solo(["s1", P, "", "", ""], (s) => put(s, "home/records/learnings.md", "### caf\xc3\xa9 (solo s1)\n")), lc: "en_US.UTF-8" });
  if (!ROOTED) {
    const un = same("an unreadable learnings.md", solo(["s1", P, "", "", ""], (s) => (put(s, "home/records/learnings.md", "x\n"), chmodSync(join(s, "home", "records", "learnings.md"), 0o000))));
    expect(un.t.err).toMatch(/^awk: can't open file S\/home\/records\/learnings.md/);
    same("a status the append cannot write", solo(["s1", P, "", "", ""], (s) => (put(s, "home/state/s1.status", ""), chmodSync(join(s, "home", "state", "s1.status"), 0o444))));
  }
});

const KILL: Row = { bash: `backend_kill_window "$1"`, twin: `const r = L.backendKillWindow(A[0]); if (r.exited) process.exit(r.status); return r.status;`, args: ["k1"] };
const herdrPane = (s: string, tab = "w1:t1", label = "crew:k1"): void => {
  pane(s, "k1", `p1 ${tab}\n`);
  stub(s, `tab-${tab}`, label);
};

test("backendKillWindow herdr: the label proof, the last-tab fallback and its workspace close, the files swept", () => {
  const cases: [string, (s: string) => void, number][] = [
    ["no handle file", () => {}, 0],
    ["a handle with no tab", (s) => pane(s, "k1", "p1\n"), 0],
    ["owned and closed", (s) => herdrPane(s), 0],
    ["a stale label", (s) => herdrPane(s, "w1:t1", "crew:other"), 0],
    ["no label at all", (s) => herdrPane(s, "w1:t1", ""), 0],
    ["the tab gone", (s) => pane(s, "k1", "p1 w1:t1\n"), 0],
    ["herdr unreachable (W18)", (s) => (herdrPane(s), stub(s, "unreachable")), 0],
    ["refused, the workspace closeable", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[{"tab_id":"w1:t1","label":"crew:k1"},{"tab_id":"w1:t2","label":"1"}]}}')), 0],
    ["refused, closeable, group required then --group", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[]}}'), stub(s, "ws-group-w1")), 0],
    ["refused, closeable, group required and --group fails", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[]}}'), stub(s, "ws-group-w1"), stub(s, "group-fails")), 0],
    ["refused, closeable, another refusal", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[]}}'), stub(s, "ws-close-fails")), 0],
    ["refused, the workspace occupied", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[{"tab_id":"w1:t2","label":"crew:x"}]}}')), 1],
    ["refused, the list unreadable", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list-fails")), 1],
    ["refused, the list empty", (s) => (herdrPane(s), stub(s, "close-rc", "1")), 1],
    ["refused, no tabs array", (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{}}')), 1],
    ["refused, the tab gone", (s) => (herdrPane(s), stub(s, "close-drops")), 1],
    ["refused with rc 7, the tab kept", (s) => (herdrPane(s), stub(s, "close-rc", "7"), stub(s, "list", '{"result":{"tabs":[]}}')), 0],
    ["a tab id with no workspace part", (s) => (herdrPane(s, "t9"), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[]}}')), 0],
  ];
  for (const [label, seed, rc] of cases) {
    const p = same(label, { ...KILL, seed: (s) => (seed(s), put(s, "home/state/.captain-wait-k1", "")) });
    expect({ label, rc: p.t.out }).toEqual({ label, rc: `|rc=${rc}` });
    expect({ label, swept: p.t.world.includes(".pane-k1") || p.t.world.includes(".captain-wait-k1") }).toEqual({ label, swept: false });
  }
  same("the session knob", { ...KILL, env: { AC_HERDR_SESSION: "s9" }, seed: (s) => (herdrPane(s), stub(s, "close-rc", "1"), stub(s, "list", '{"result":{"tabs":[]}}'), stub(s, "ws-group-w1")) });
  same("config/herdr-session", { ...KILL, seed: (s) => (herdrPane(s), put(s, "home/config/herdr-session", "cfg\n")) });
  same("W6: an unsupported task backend", { ...KILL, env: { AC_BACKEND: "tmux" }, seed: (s) => herdrPane(s) });
});

const orcaPane = (s: string, h = "term1", tab = "tab1"): void => {
  pane(s, "k1", `${h} ${tab}\n`);
  put(s, "stub/terms", `${h} ${tab}\n`);
};
const ORCA_ = { AC_BACKEND: "orca" };

test("backendKillWindow orca: the terminal closed, the bounded wait for it to leave its tab, the emptied tab's family records retired", () => {
  const fams = (s: string): void => {
    put(s, "home/state/.orca-fam-f1", "tab1\n");
    put(s, "home/state/.orca-fam-f2", "tab2\n");
    put(s, "home/state/.orca-fam-f3", "tab1");
  };
  const cases: [string, (s: string) => void][] = [
    ["closed at once, its tab emptied", (s) => (orcaPane(s), fams(s))],
    ["listed for three more polls", (s) => (orcaPane(s), fams(s), stub(s, "linger", "3"))],
    ["listed past the eighth poll", (s) => (orcaPane(s), fams(s), stub(s, "linger", "20"))],
    ["a sibling left in the tab", (s) => (orcaPane(s), put(s, "stub/terms", "term1 tab1\nterm2 tab1\n"), fams(s))],
    ["the close refused", (s) => (orcaPane(s), fams(s), stub(s, "close-fails"))],
    ["the list unreadable", (s) => (orcaPane(s), fams(s), stub(s, "list-fails"))],
    ["a list with no terminals array", (s) => (orcaPane(s), fams(s), stub(s, "list-raw", '{"ok":true,"result":{}}'))],
    ["a handle with no tab", (s) => (pane(s, "k1", "term1\n"), fams(s))],
    ["no handle file", (s) => fams(s)],
    ["a family record that is a directory", (s) => (orcaPane(s), mkdirSync(join(s, "home", "state", ".orca-fam-d"), { recursive: true }))],
  ];
  for (const [label, seed] of cases) {
    const p = same(label, { ...KILL, env: ORCA_, seed: (s) => (seed(s), put(s, "home/state/.captain-wait-k1", "")) });
    expect({ label, rc: p.t.out }).toEqual({ label, rc: "|rc=0" });
  }
  const eight = same("eight sleeps at most", { ...KILL, env: ORCA_, seed: (s) => (orcaPane(s), stub(s, "linger", "20")) });
  expect(eight.t.log.split("\n").filter((l) => l === "sleep 0.25").length).toBe(8);
});

test("orcaWorktreeRelease: the CLI's rm, its failure and an ok:false answer both refused", () => {
  const rel: Row = { bash: `orca_worktree_release "$1"`, twin: `return L.orcaWorktreeRelease(A[0]) ? 0 : 1;`, args: ["@S/wt"] };
  expect(same("removed", rel).t.out).toBe("|rc=0");
  expect(same("ok:false", { ...rel, seed: (s) => stub(s, "rm-refuses") }).t.out).toBe("|rc=1");
  expect(same("the CLI fails", { ...rel, seed: (s) => stub(s, "rm-fails") }).t.out).toBe("|rc=1");
});

// kill_serve_pid lifted from the frozen original, beside the port's
// killServePid, each handed a spy for `kill`: the spy logs every call as the
// builtin's arguments, and answers by the row's knobs - alive (kill -0),
// group-fails (the group TERM), pid-fails (the pid TERM) - so a row proves
// what WOULD be signalled without a signal ever being sent.
function serve(label: string, body: string | null, knobs: string[] = [], mode = 0o644): { o: Side; t: Side; root: string } {
  const lifted = readFileSync(FIXTURE, "latin1").match(/^kill_serve_pid\(\) \{[\s\S]*?^\}$/m)![0];
  return same(label, {
    bash: `kill() { printf '%s\\n' "$*" >>"$STUB_DIR/kills"; case "$1 $2" in "-0 "*) [ -e "$STUB_DIR/alive" ] ;; "-TERM --") [ ! -e "$STUB_DIR/group-fails" ] ;; *) [ ! -e "$STUB_DIR/pid-fails" ] ;; esac; }; ${lifted}; kill_serve_pid "$1"`,
    twin: `const T = await import(${JSON.stringify(TEARDOWN)}); const fs = await import("node:fs"); const d = process.env.STUB_DIR; T.killServePid(A[0], (pid, sig) => { const w = sig === 0 ? "-0 " + pid : pid < 0 ? "-TERM -- " + pid : "-TERM " + pid; fs.appendFileSync(d + "/kills", w + "\\n"); const ok = sig === 0 ? fs.existsSync(d + "/alive") : pid < 0 ? !fs.existsSync(d + "/group-fails") : !fs.existsSync(d + "/pid-fails"); if (!ok) throw new Error("ESRCH"); }); return 0;`,
    args: ["@S/run/serve.pid"],
    seed: (s) => {
      mkdirSync(join(s, "run"), { recursive: true });
      if (body !== null) put(s, "run/serve.pid", body, mode);
      for (const k of knobs) stub(s, k);
    },
  });
}

test("killServePid: only a decimal above 1 is signalled - the group first, then the pid - and a refused, unreadable or gone pid is named", () => {
  for (const v of ["1", "0", "00", "007", "-1", "-5", "12x", " 12", "12 ", "+3", "1\n\n"]) {
    const p = serve(`'${JSON.stringify(v)}' refused`, `${v}\n`, ["alive"]);
    expect({ v, kills: read(join(p.root, "t", "stub", "kills")) }).toEqual({ v, kills: "" });
    expect(p.t.err).toContain("not a process id");
    expect(existsSync(join(p.root, "t", "run", "serve.pid"))).toBe(true);
  }
  const live = serve("a live pid", "4242\n", ["alive"]);
  expect(read(join(live.root, "t", "stub", "kills"))).toBe("-0 4242\n-TERM -- -4242\n");
  expect(existsSync(join(live.root, "t", "run", "serve.pid"))).toBe(false);
  expect(read(join(serve("the group refused", "4242", ["alive", "group-fails"]).root, "t", "stub", "kills"))).toBe("-0 4242\n-TERM -- -4242\n-TERM 4242\n");
  expect(serve("both refused", "4242", ["alive", "group-fails", "pid-fails"]).t.err).toBe("WARN: could not kill qa serve pid 4242 (S/run/serve.pid)\n");
  expect(serve("gone", "4242").t.err).toBe("WARN: qa serve pid 4242 already gone (S/run/serve.pid)\n");
  expect(serve("empty", "").t.err).toBe("");
  serve("absent", null);
  if (!ROOTED) {
    const un = serve("unreadable", "4242", ["alive"], 0o000);
    expect(un.t.err).toBe("WARN: could not read S/run/serve.pid: a qa serve process may still be running and could not be identified\n");
  }
});

// A value past pid_t: bash 3.2's builtin refuses the word before any syscall
// (`kill: 4294967295: arguments must be process or job IDs`, probed with
// signal 0 only), so `kill -0` fails and the pid reads as gone; the port never
// hands such a value to its kill, so the spy sees no call at all.
test("killServePid: a decimal past pid_t is never handed to kill", () => {
  const s = join(W, "pidt");
  mkdirSync(s, { recursive: true });
  writeFileSync(join(s, "serve.pid"), "4294967295\n");
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const T = await import(${JSON.stringify(TEARDOWN)}); const calls = []; T.killServePid(${JSON.stringify(join(s, "serve.pid"))}, (p, g) => { calls.push([p, g]); }); process.stdout.write(JSON.stringify(calls));`],
    { cwd: ROOT, env: { PATH, HOME: W }, stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  expect({ out: r.stdout.toString(), err: r.stderr.toString() }).toEqual({ out: "[]", err: `WARN: qa serve pid 4294967295 already gone (${s}/serve.pid)\n` });
});
