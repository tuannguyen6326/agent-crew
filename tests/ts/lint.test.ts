// lint.test.ts - the lib.ts twin src/lint.ts introduced (src/page-lint.ts
// shares it), held to its bash original differentially: commandV against
// bash's `command -v` over one PATH - an executable anywhere, else the first
// entry that exists, found unless it is a directory. The CLI contracts are
// tests/sh/ac-lint.test.sh's and tests/sh/ac-page-lint.test.sh's, whose
// differential legs run the frozen bash originals beside the shims.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");
const made: string[] = [];
afterAll(() => made.forEach((d) => rmSync(d, { recursive: true, force: true })));

function bashFinds(name: string, path: string, cwd: string): boolean {
  return Bun.spawnSync(["/bin/bash", "-c", 'command -v "$1" >/dev/null', "--", name], { cwd, env: { PATH: path }, stdout: "ignore", stderr: "ignore" }).exitCode === 0;
}
function twinFinds(name: string, path: string, cwd: string): boolean {
  const body = `const L = await import(${JSON.stringify(LIB)}); process.exit(L.commandV(${JSON.stringify(name)}) ? 0 : 1);`;
  return Bun.spawnSync([process.execPath, "-e", body], { cwd, env: { PATH: path }, stdout: "ignore", stderr: "inherit" }).exitCode === 0;
}
function same(name: string, path: string, cwd: string): boolean {
  const want = bashFinds(name, path, cwd);
  expect({ name, path, found: twinFinds(name, path, cwd) }).toEqual({ name, path, found: want });
  return want;
}

test("commandV finds what bash's `command -v` finds: an executable anywhere, else the first existing entry unless a directory, an empty element being the cwd", () => {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-lint-ts-")));
  made.push(h);
  const d = join(h, "d");
  mkdirSync(join(d, "adir"), { recursive: true });
  writeFileSync(join(d, "exe"), "#!/bin/sh\n");
  chmodSync(join(d, "exe"), 0o755);
  writeFileSync(join(d, "plain"), "#!/bin/sh\n");
  chmodSync(join(d, "plain"), 0o644);
  symlinkSync(join(h, "nowhere"), join(d, "dangling"));
  symlinkSync(join(d, "adir"), join(d, "todir"));
  symlinkSync(join(d, "plain"), join(d, "toplain"));
  mkdirSync(join(h, "later"));
  writeFileSync(join(h, "later", "adir"), "");
  writeFileSync(join(h, "here"), "");
  mkdirSync(join(h, "rel"));
  writeFileSync(join(h, "rel", "relhit"), "");

  expect(same("exe", d, h)).toBe(true);
  expect(same("plain", d, h)).toBe(true);
  expect(same("toplain", d, h)).toBe(true);
  expect(same("adir", d, h)).toBe(false);
  expect(same("todir", d, h)).toBe(false);
  expect(same("dangling", d, h)).toBe(false);
  expect(same("absent", d, h)).toBe(false);
  // Failing an executable, the first entry that exists decides: a directory
  // hides a later plain file, a plain file is found ahead of a later
  // directory, and an executable anywhere wins.
  expect(same("adir", `${d}:${join(h, "later")}`, h)).toBe(false);
  expect(same("adir", `${join(h, "later")}:${d}`, h)).toBe(true);
  mkdirSync(join(h, "x1", "exe"), { recursive: true });
  expect(same("exe", `${join(h, "x1")}:${d}`, h)).toBe(true);
  expect(same("plain", `${join(h, "later")}:${d}`, h)).toBe(true);
  expect(same("here", `${d}:`, h)).toBe(true);
  expect(same("here", `:${d}`, h)).toBe(true);
  expect(same("here", d, h)).toBe(false);
  expect(same("relhit", "rel", h)).toBe(true);
  expect(same("relhit", "rel", d)).toBe(false);
});
