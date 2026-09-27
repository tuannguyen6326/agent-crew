// paths.test.ts - Bun unit tests for src/paths.ts: the places where python's
// os.path semantics differ from node:path and fs.realpathSync, each expected
// value read off python 3.14's os.path over the same tree. The callers' CLI
// contract stays owned by tests/ac-qa.test.sh and tests/ac-verify.test.sh.
// Run through tests/src.test.sh.

import { test, expect, afterAll } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pyDirname, pyJoin, pyRealpath, receiptOk, within } from "../src/paths.ts";

const PATHS = join(import.meta.dir, "..", "src", "paths.ts");

const F = realpathSync(mkdtempSync(join(tmpdir(), "ac-paths-ts-")));
afterAll(() => rmSync(F, { recursive: true, force: true }));
for (const d of ["root/sub", "root/C1", "out", "root2"]) mkdirSync(join(F, d), { recursive: true });
for (const f of ["root/f", "root/sub/g", "root/-", "root/C1/r", "out/x", "root2/y"]) writeFileSync(join(F, f), "x\n");
for (const [target, link] of [
  ["../out", "root/esc"], ["sub", "root/in"], ["nowhere", "root/dangle"], ["loop1", "root/loop2"],
  ["loop2", "root/loop1"], [join(F, "root"), "rootlink"], ["../out", "root/C9"], ["missing/../sub", "root/weird"],
  ["r", "root/C1/rlink"],
]) symlinkSync(target, join(F, link));

const cwdSub = () => join(F, "root/sub");
const noCwd = () => {
  throw new Error("cwd consulted");
};

test("pyRealpath follows os.path.realpath over existing, missing and looping paths", () => {
  for (const [input, want] of [
    ["", "$F/root/sub"],
    [".", "$F/root/sub"],
    ["..", "$F/root"],
    ["x/..", "$F/root/sub"],
    ["missing", "$F/root/sub/missing"],
    ["missing/../f", "$F/root/sub/f"],
    ["missing/../../out", "$F/root/out"],
    ["../f/..", "$F/root"],
    ["$F/root/f/..", "$F/root"],
    ["$F/root/f/x/..", "$F/root/f"],
    ["$F/root/esc/x", "$F/out/x"],
    ["$F/root/in/../f", "$F/root/f"],
    ["$F/root/dangle", "$F/root/nowhere"],
    ["$F/root/dangle/..", "$F/root"],
    ["$F/root/loop1", "$F/root/loop1"],
    ["$F/root/loop1/x", "$F/root/loop1/x"],
    ["$F/root/loop1/..", "$F/root"],
    ["$F/rootlink/sub/../f", "$F/root/f"],
    ["//", "/"],
    ["///x//y/", "/x/y"],
    ["$F/root/./sub/", "$F/root/sub"],
    ["$F/root/C9/..", "$F"],
    ["$F/root/weird", "$F/root/sub"],
    ["$F/root/esc/../root/f", "$F/root/f"],
    ["/..", "/"],
    ["/../x", "/x"],
  ]) {
    expect([input, pyRealpath(input.replace("$F", F), cwdSub)]).toEqual([input, want.replace("$F", F)]);
  }
});

test("pyRealpath asks for the cwd only for a relative path", () => {
  expect(pyRealpath(join(F, "root/in/g"), noCwd)).toBe(join(F, "root/sub/g"));
  expect(() => pyRealpath("g", noCwd)).toThrow("cwd consulted");
});

test("pyRealpath keeps a component's spelled case where fs.realpathSync folds it", () => {
  if (!existsSync(join(F, "ROOT"))) return;
  expect(pyRealpath(join(F, "ROOT/f"), noCwd)).toBe(join(F, "ROOT/f"));
});

test("pyJoin and pyDirname are posixpath.join and posixpath.dirname", () => {
  expect(pyJoin("a", "b")).toBe("a/b");
  expect(pyJoin("a/", "b")).toBe("a/b");
  expect(pyJoin("a", "/b")).toBe("/b");
  expect(pyJoin("", "b")).toBe("b");
  expect(pyJoin("a", "")).toBe("a/");
  expect(pyJoin("a", "b", "/c", "d")).toBe("/c/d");
  for (const [p, want] of [
    ["f", ""], ["/f", "/"], ["a//b", "a"], ["//x", "//"], ["///x", "///"], ["a/b/", "a/b"], ["", ""], ["/", "/"], ["a/b//", "a/b"],
  ]) {
    expect([p, pyDirname(p)]).toEqual([p, want]);
  }
});

test("within is commonpath over resolved paths, plus existence", () => {
  const root = join(F, "root");
  for (const [r, c, want] of [
    [root, root, true],
    [root, "", true],
    [root, "-", true],
    [root, "f", true],
    [root, "in/g", true],
    [root, "missing/../f", true],
    [join(F, "rootlink"), "f", true],
    ["/", join(root, "f"), true],
    [root, "esc/x", false],
    [root, "C9", false],
    [root, "C9/..", false],
    [root, "dangle", false],
    [root, "loop1", false],
    [root, "nothing", false],
    [root, "../root2/y", false],
    [root, join(F, "root2/y"), false],
  ] as const) {
    expect([r, c, within(r, c, noCwd)]).toEqual([r, c, want]);
  }
  expect(within("root", "f", () => F)).toBe(true);
});

test("receiptOk: a regular non-link file whose resolved parent is the resolved case dir", () => {
  const rd = join(F, "root");
  expect(receiptOk(rd, "C1", join(rd, "C1/r"), noCwd)).toBe(false);
  mkdirSync(join(rd, "boundaries"), { recursive: true });
  symlinkSync(join(rd, "C1"), join(rd, "boundaries/C1"));
  expect(receiptOk(rd, "C1", join(rd, "C1/r"), noCwd)).toBe(true);
  expect(receiptOk(rd, "C1", join(rd, "C1/rlink"), noCwd)).toBe(false);
  expect(receiptOk(rd, "C1", "r", () => join(rd, "C1"))).toBe(true);
  expect(receiptOk(rd, join(F, "out"), join(F, "out/x"), noCwd)).toBe(true);
  for (const args of [["", "C1", join(rd, "C1/r")], [rd, "", join(rd, "C1/r")], [rd, "C1", ""], [rd, "C1", "-"]] as const) {
    expect(receiptOk(args[0], args[1], args[2], noCwd)).toBe(false);
  }
});

function run(caller: string, ...args: string[]) {
  const p = Bun.spawnSync([process.execPath, "--no-env-file", PATHS, caller, ...args], { cwd: F });
  return { code: p.exitCode, out: p.stdout.toString(), err: p.stderr.toString() };
}

test("realpath prints python's line: the path and one newline", () => {
  expect(run(F, "realpath", "root/in/../f")).toEqual({ code: 0, out: `${F}/root/f\n`, err: "" });
});

test("a relative input with no caller cwd is refused, never read from the distro root", () => {
  const r = run("", "within", "root", "f");
  expect(r.code).toBe(1);
  expect(r.err).toContain("ERROR: ");
  expect(run("", "within", join(F, "root"), "f")).toEqual({ code: 0, out: "", err: "" });
});

test("free-port prints one port number and a newline", () => {
  const r = run(F, "free-port");
  expect(r.code).toBe(0);
  expect(r.out).toMatch(/^[1-9][0-9]*\n$/);
  expect(Number(r.out)).toBeLessThanOrEqual(65535);
});

test("a wrong argument count is a usage error", () => {
  const r = run(F, "within", "only-one");
  expect(r.code).toBe(1);
  expect(r.err).toContain("usage");
});

// Bun decodes an argument's non-UTF-8 bytes to U+FFFD, so a path spelled with
// one could name a different, real file: the checks refuse rather than judge it.
test("a path carrying U+FFFD is refused by within and receipt-ok", () => {
  const root = mkdtempSync(join(tmpdir(), "paths-fffd-"));
  try {
    writeFileSync(join(root, "\ufffd"), "x");
    const run = (args: string[]) =>
      Bun.spawnSync([process.execPath, join(import.meta.dir, "..", "src", "paths.ts"), root, ...args]).exitCode;
    expect(run(["within", root, join(root, "\ufffd")])).toBe(1);
    mkdirSync(join(root, "boundaries", "c1"), { recursive: true });
    writeFileSync(join(root, "boundaries", "c1", "r\ufffd.json"), "{}");
    expect(run(["receipt-ok", root, "c1", join(root, "boundaries", "c1", "r\ufffd.json")])).toBe(1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
