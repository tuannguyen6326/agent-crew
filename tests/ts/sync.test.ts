// sync.test.ts - the lib.ts twin src/sync.ts introduced, held to its bash
// original differentially: projectDir against ac_project_dir + ac_repo_root
// (a directory argument first, then projects/<name>; the MAIN repo root for a
// linked worktree; the physical path for a symlink; the homeless refusal the
// `[ -d "$(ac_projects_dir)/$arg" ]` test swallows). The CLI contract itself
// (every line, stderr, exit, the bounded fetch) is tests/sh/ac-sync.test.sh's,
// whose differential leg runs the frozen bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const binDir = join(import.meta.dir, "..", "..", "bin");
const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");
const made: string[] = [];
afterAll(() => made.forEach((d) => rmSync(d, { recursive: true, force: true })));

type Answer = { out: string; err: string; rc: number };

// Both sides run in a child so the ERROR lines ac_projects_dir prints inside
// the swallowed substitution are captured, not only the path and the status.
function bashSide(arg: string, cwd: string, home: string | undefined): Answer {
  const r = Bun.spawnSync(["bash", "-c", `. "$1/ac-lib.sh"; ac_project_dir "$2"`, "--", binDir, arg], {
    cwd,
    env: home === undefined ? { PATH: process.env.PATH! } : { PATH: process.env.PATH!, AC_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { out: r.stdout.toString("latin1").replace(/\n$/, ""), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}
function tsSide(arg: string, cwd: string, home: string | undefined): Answer {
  const body = `const L = await import(${JSON.stringify(LIB)}); const d = L.projectDir(${JSON.stringify(arg)}); if (d === null) process.exit(1); process.stdout.write(d);`;
  const r = Bun.spawnSync([process.execPath, "-e", body], {
    cwd,
    env: home === undefined ? { PATH: process.env.PATH! } : { PATH: process.env.PATH!, AC_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}
function same(arg: string, cwd: string, home: string | undefined): Answer {
  const want = bashSide(arg, cwd, home);
  const got = tsSide(arg, cwd, home);
  expect({ arg, ...got }).toEqual({ arg, ...want });
  return got;
}

const git = (dir: string, ...args: string[]): void => {
  const r = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "ignore", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString()}`);
};
function repo(dir: string): string {
  mkdirSync(join(dir, "sub"), { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  git(dir, "config", "user.email", "test@test");
  git(dir, "config", "user.name", "test");
  writeFileSync(join(dir, "sub", "f"), "x\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "init");
  return dir;
}

test("projectDir resolves what ac_project_dir resolves: a directory argument (nested, symlinked, a linked worktree, a bare repo), else projects/<name>, null for a non-repo or a missing name", () => {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-sync-ts-")));
  made.push(h);
  mkdirSync(join(h, "projects"));
  const p = repo(join(h, "projects", "p"));
  repo(join(h, "elsewhere", "src"));
  symlinkSync(join(h, "elsewhere", "src"), join(h, "projects", "link"));
  git(p, "worktree", "add", "-q", join(h, "wt"), "-b", "wtb");
  git(h, "clone", "-q", "--bare", p, join(h, "bare.git"));
  mkdirSync(join(h, "plain"));
  for (const arg of ["p", "link", "p/", `${h}/projects/p`, `${h}/projects/p/sub/`, `${h}/projects/link`, `${h}/projects/link/sub`, `${h}/wt`, `${h}/wt/sub`, `${h}/bare.git`, `${h}/plain`, "plain", "nope", "", "projects/p", "./projects/p/sub"]) {
    same(arg, h, h);
  }
  expect(same("p", h, h)).toEqual({ out: `${h}/projects/p`, err: "", rc: 0 });
  expect(same("link", h, h).out).toBe(`${h}/elsewhere/src`);
  expect(same(`${h}/wt/sub`, h, h).out).toBe(`${h}/projects/p`);
  // A bare repo names its PARENT: the common dir is the bare dir itself (kept - a wart of the original).
  expect(same(`${h}/bare.git`, h, h).out).toBe(h);
  expect(same("nope", h, h)).toEqual({ out: "", err: "", rc: 1 });
  expect(same(`${h}/plain`, h, h).rc).toBe(1);
});

test("projectDir mints projects/ under the home as ac_projects_dir does, and a homeless name prints the AC_HOME refusal once per swallowed substitution", () => {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-sync-ts-")));
  made.push(h);
  const p = repo(join(h, "repo"));
  for (const side of ["o", "n"]) {
    const home = join(h, side);
    mkdirSync(home);
    const r = side === "o" ? bashSide("nope", h, home) : tsSide("nope", h, home);
    expect({ side, ...r }).toEqual({ side, out: "", err: "", rc: 1 });
    expect(existsSync(join(home, "projects"))).toBe(true);
  }
  // Homeless: a name - the die inside `$(ac_projects_dir)` is swallowed by
  // `[ -d ]`, so the refusal is printed and the lookup goes on to `/<name>`;
  // a directory argument never consults the home.
  const nope = same("nope", h, undefined);
  expect(nope.rc).toBe(1);
  expect(nope.err).toMatch(/^ERROR: AC_HOME is not set - .*\n$/);
  expect(same(p, h, undefined)).toEqual({ out: p, err: "", rc: 0 });
  expect(same("repo", h, undefined)).toEqual({ out: p, err: "", rc: 0 });
});
