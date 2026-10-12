// fleet-view.test.ts - the lib.ts twins src/fleet-view.ts introduced, held to
// their bash originals differentially: crewMetas against ac_crew_metas (the
// glob in byte order - the bash side under LC_ALL=C - dotted and hidden names,
// the first-entry-only `[ -e ]`, every skip class, last kind wins, and awk's
// own arms: the directory abort with its stderr, an unreadable or dangling
// later meta counted, an LF-named meta splitting in two), and crewState
// against `$(<root>/bin/ac-crew-state.sh <id> 2>/dev/null || printf unknown)`
// over the `unknown` suffix shapes and both stdin modes. The CLI contract
// itself is tests/sh/ac-fleet-view.test.sh's, whose differential leg runs the
// frozen bash original beside the shim.
import { afterEach, expect, test } from "bun:test";
import { chmodSync, closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = join(import.meta.dir, "..", "..");
const binDir = join(root, "bin");
const LIB = join(root, "src", "lib.ts");
const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) {
    try {
      chmodSync(join(d, "state", "u5.meta"), 0o644);
    } catch {}
    rmSync(d, { recursive: true, force: true });
  }
});
const tmp = (): string => {
  const d = realpathSync(mkdtempSync(join(tmpdir(), "ac-fleet-view-ts-")));
  dirs.push(d);
  return d;
};
const ENV = { PATH: process.env.PATH!, LC_ALL: "C" };

type Answer = { out: string; err: string };
function bashMetas(sd: string, skips: string[]): Answer {
  const r = Bun.spawnSync(["bash", "-c", '. "$1/ac-lib.sh"; shift; ac_crew_metas "$@"', "--", binDir, sd, ...skips], { env: ENV, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}
function tsMetas(sd: string, skips: string[]): Answer {
  const body = `const L = await import(${JSON.stringify(LIB)}); for await (const p of L.crewMetas(...${JSON.stringify([sd, ...skips])})) process.stdout.write(Buffer.from(p + "\\n"));`;
  const r = Bun.spawnSync([process.execPath, "-e", body], { env: ENV, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}
function sameMetas(sd: string, skips: string[]): string[] {
  const want = bashMetas(sd, skips);
  expect({ skips, ...tsMetas(sd, skips) }).toEqual({ skips, ...want });
  const lines = Buffer.from(want.out, "latin1").toString("utf8").replace(/\n$/, "").split("\n");
  return want.out === "" ? [] : lines.map((p) => (p.startsWith(`${sd}/`) ? p.slice(sd.length + 1) : p));
}
const meta = (sd: string, name: string, body: string): void => writeFileSync(join(sd, name), body);

test("crewMetas lists what ac_crew_metas lists: non-dot *.meta in byte order, each skip class, the last kind= winning", () => {
  const sd = join(tmp(), "state");
  expect(sameMetas(sd, [])).toEqual([]);
  mkdirSync(sd);
  expect(sameMetas(sd, ["verify"])).toEqual([]);
  for (const n of ["_u", "A2", "b1", "a10", "a3", "é", "b8.y", "x.meta"]) meta(sd, `${n}.meta`, "kind=ship\n");
  meta(sd, ".hidden.meta", "kind=ship\n");
  meta(sd, ".meta", "kind=ship\n");
  meta(sd, "n1.status", "x\n");
  meta(sd, "v1.meta", "kind=verify-codereview\n");
  meta(sd, "v2.meta", "kind=verify-x\nkind=ship\n");
  meta(sd, "v3.meta", "kind=ship\nkind=verify-x\n");
  meta(sd, "s1.meta", "kind=self\n");
  meta(sd, "c1.meta", "kind=roomchief\n");
  meta(sd, "c2.meta", "kind=crewdeputy\n");
  meta(sd, "k0.meta", "project=nokind\n");
  meta(sd, "k1.meta", "kind=\n");
  meta(sd, "k2.meta", "kind=self \n");
  meta(sd, "k3.meta", "");
  const all = sameMetas(sd, []);
  expect(all).toEqual(["A2.meta", "_u.meta", "a10.meta", "a3.meta", "b1.meta", "b8.y.meta", "c1.meta", "c2.meta", "k0.meta", "k1.meta", "k2.meta", "k3.meta", "s1.meta", "v1.meta", "v2.meta", "v3.meta", "x.meta.meta", "é.meta"]);
  expect(sameMetas(sd, ["verify"])).toEqual(all.filter((n) => n !== "v1.meta" && n !== "v3.meta"));
  expect(sameMetas(sd, ["self"])).toEqual(all.filter((n) => n !== "s1.meta"));
  expect(sameMetas(sd, ["chiefs"])).toEqual(all.filter((n) => n !== "c1.meta" && n !== "c2.meta"));
  sameMetas(sd, ["verify", "self"]);
  sameMetas(sd, ["chiefs", "self", "verify"]);
}, 30_000); // bash probes that pass 5 s under load - past bun's default

test("crewMetas keeps ac_crew_metas's awk arms: first-entry-only [ -e ], a later dangling or unreadable meta counted, an LF-named meta split in two, a directory aborting the rest", () => {
  const sd = join(tmp(), "state");
  mkdirSync(sd);
  for (const n of ["a1", "c3"]) meta(sd, `${n}.meta`, "kind=ship\n");
  symlinkSync("nowhere", join(sd, "z9dangle.meta"));
  meta(sd, "b7\nx.meta", "kind=ship\n");
  meta(sd, "b8\nv.meta", "kind=verify-x\n");
  meta(sd, "u5.meta", "kind=verify-x\n");
  chmodSync(join(sd, "u5.meta"), 0o000);
  expect(sameMetas(sd, ["verify"])).toEqual(["a1.meta", "b7", "x.meta", "c3.meta", "u5.meta", "z9dangle.meta"]);
  symlinkSync("nowhere", join(sd, "0dangle.meta"));
  expect(sameMetas(sd, ["verify"])).toEqual([]);
  rmSync(join(sd, "0dangle.meta"));
  mkdirSync(join(sd, "b2.meta"));
  expect(sameMetas(sd, ["verify"])).toEqual(["a1.meta"]);
  expect(tsMetas(sd, ["verify"]).err).toBe(`awk: i/o error occurred on ${sd}/b2.meta\n source line number 7\n`);
});

test("crewMetas runs ac_crew_metas's awk program verbatim", () => {
  const sh = readFileSync(join(binDir, "ac-lib.sh"), "utf8");
  const open = `awk -v sv="$sv" -v ss="$ss" -v sc="$sc" '`;
  const from = sh.indexOf(open, sh.indexOf("ac_crew_metas() {")) + open.length;
  const program = sh.slice(from, sh.indexOf(`' "$@"`, from));
  expect(program).toContain("print file");
  expect(readFileSync(LIB, "utf8")).toContain(program);
});

function stateRoot(stub: string | null, mode = 0o755): string {
  const r = tmp();
  mkdirSync(join(r, "bin"));
  if (stub !== null) {
    writeFileSync(join(r, "bin", "ac-crew-state.sh"), `#!/bin/sh\n${stub}\n`);
    chmodSync(join(r, "bin", "ac-crew-state.sh"), mode);
  }
  return r;
}
function stdinFile(text: string): number {
  const f = join(tmp(), "stdin");
  writeFileSync(f, text);
  return openSync(f, "r");
}
function bashState(r: string, id: string, stdin: "ignore" | number): string {
  const s = Bun.spawnSync(["bash", "-c", 'printf %s "$("$1/bin/ac-crew-state.sh" "$2" 2>/dev/null || printf unknown)"', "--", r, id], { env: ENV, stdin, stdout: "pipe", stderr: "pipe" });
  expect(s.stderr.toString()).toBe("");
  return s.stdout.toString("latin1");
}
function tsState(r: string, id: string, mode: "ignore" | "inherit", stdin: "ignore" | number): string {
  const body = `const L = await import(${JSON.stringify(LIB)}); process.stdout.write(Buffer.from(L.crewState(${JSON.stringify(r)}, ${JSON.stringify(id)}, ${JSON.stringify(mode)}), "latin1"));`;
  const s = Bun.spawnSync([process.execPath, "-e", body], { env: ENV, stdin, stdout: "pipe", stderr: "pipe" });
  expect(s.stderr.toString()).toBe("");
  return s.stdout.toString("latin1");
}
function sameState(stub: string | null, want: string, mode = 0o755, id = "t1"): void {
  const r = stateRoot(stub, mode);
  expect(bashState(r, id, "ignore")).toBe(want);
  expect(tsState(r, id, "ignore", "ignore")).toBe(want);
}

test("crewState reads what the substitution read: the child's stdout, `unknown` appended on any failure, NULs dropped, trailing LFs stripped, stderr dropped", () => {
  sameState("printf 'busy\\n'", "busy");
  sameState("printf 'half'; exit 3", "halfunknown");
  sameState("printf 'x\\n'; exit 1", "x\nunknown");
  sameState("printf 'part'; kill -TERM $$", "partunknown");
  sameState("printf 'a\\000b\\n\\n\\n'", "ab");
  sameState("printf 'one\\ntwo\\n'", "one\ntwo");
  sameState("printf 'done: x\\n' >&2; exit 7", "unknown");
  sameState("printf '[%s]' \"$1\"", "[x y]", 0o755, "x y");
  sameState(null, "unknown");
  sameState("printf 'never'", "unknown", 0o644);
}, 30_000); // bash probes that pass 5 s under load - past bun's default

test("crewState hands the child the caller's stdin only when told to inherit it", () => {
  const r = stateRoot("IFS= read -r l; printf 'got:%s' \"$l\"");
  for (const [mode, want] of [["inherit", "got:line1"], ["ignore", "got:"]] as const) {
    const fd = stdinFile("line1\nline2\n");
    try {
      expect(bashState(r, "t1", mode === "inherit" ? fd : "ignore")).toBe(want);
    } finally {
      closeSync(fd);
    }
    const fd2 = stdinFile("line1\nline2\n");
    try {
      expect(tsState(r, "t1", mode, fd2)).toBe(want);
    } finally {
      closeSync(fd2);
    }
  }
});
