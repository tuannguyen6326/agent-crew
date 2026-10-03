// dash.test.ts - the lib.ts twin src/dash.ts introduced, held to its bash
// original differentially: projectsDir against ac_projects_dir (the physical
// path, the mkdir side effect, the homeless refusal). The CLI contract itself
// (the five sections, --watch, every exit) is tests/sh/ac-dash.test.sh's, whose
// differential leg runs the frozen bash original beside the shim.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { projectsDir } from "../../src/lib.ts";

const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");
const binDir = join(import.meta.dir, "..", "..", "bin");

function bashProjectsDir(env: Record<string, string>): { out: string; err: string; rc: number } {
  const r = Bun.spawnSync(["bash", "-c", '. "$1/ac-lib.sh"; ac_projects_dir', "--", binDir], {
    env: { PATH: process.env.PATH!, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { out: r.stdout.toString(), err: r.stderr.toString(), rc: r.exitCode ?? -1 };
}

function tsProjectsDir(env: Record<string, string>): { out: string; err: string; rc: number } {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); process.stdout.write(L.projectsDir() + "\\n")`],
    { env: { PATH: process.env.PATH!, ...env }, stdout: "pipe", stderr: "pipe" },
  );
  return { out: r.stdout.toString(), err: r.stderr.toString(), rc: r.exitCode ?? -1 };
}

test("projectsDir mints projects/ under the physical home, where ac_projects_dir does", () => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "ac-dash-projects-")));
  try {
    const real = join(base, "real");
    mkdirSync(real);
    symlinkSync(real, join(base, "link"));
    const want = bashProjectsDir({ AC_HOME: join(base, "link") });
    expect(want).toEqual({ out: `${real}/projects\n`, err: "", rc: 0 });
    expect(existsSync(join(real, "projects"))).toBe(true);
    rmSync(join(real, "projects"), { recursive: true });
    process.env.AC_HOME = join(base, "link");
    expect(projectsDir()).toBe(join(real, "projects"));
    expect(existsSync(join(real, "projects"))).toBe(true);
  } finally {
    delete process.env.AC_HOME;
    rmSync(base, { recursive: true, force: true });
  }
});

test("projectsDir refuses a homeless caller with ac_projects_dir's line and status", () => {
  const want = bashProjectsDir({});
  expect(want.rc).toBe(1);
  expect(want.out).toBe("");
  expect(want.err).toStartWith("ERROR: AC_HOME is not set");
  expect(tsProjectsDir({})).toEqual(want);
});

test("projectsDir refuses an unreadable home with ac_projects_dir's status; the line is the shell's own", () => {
  const want = bashProjectsDir({ AC_HOME: "/nonexistent/ac-dash-home" });
  const got = tsProjectsDir({ AC_HOME: "/nonexistent/ac-dash-home" });
  expect(want.rc).toBe(1);
  expect(got.rc).toBe(1);
  expect(got.out).toBe(want.out);
  expect(got.err).toBe("ERROR: AC_HOME is not a readable directory: /nonexistent/ac-dash-home\n");
});
