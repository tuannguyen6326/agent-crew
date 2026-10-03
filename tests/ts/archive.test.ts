// archive.test.ts - the lib.ts twin src/archive.ts introduced, held to its bash
// original differentially: dataDir against ac_data_dir (the physical path, the
// mkdir side effect, the homeless refusal). The CLI contract itself (every
// verb, stdout, stderr, exit, the tree left behind) is
// tests/sh/ac-archive.test.sh's, whose differential leg runs the frozen bash
// original beside the shim.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { dataDir } from "../../src/lib.ts";

const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");
const binDir = join(import.meta.dir, "..", "..", "bin");

function bashDataDir(env: Record<string, string>): { out: string; err: string; rc: number } {
  const r = Bun.spawnSync(["bash", "-c", '. "$1/ac-lib.sh"; ac_data_dir', "--", binDir], {
    env: { PATH: process.env.PATH!, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { out: r.stdout.toString(), err: r.stderr.toString(), rc: r.exitCode ?? -1 };
}

function tsDataDir(env: Record<string, string>): { out: string; err: string; rc: number } {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); process.stdout.write(L.dataDir() + "\\n")`],
    { env: { PATH: process.env.PATH!, ...env }, stdout: "pipe", stderr: "pipe" },
  );
  return { out: r.stdout.toString(), err: r.stderr.toString(), rc: r.exitCode ?? -1 };
}

test("dataDir mints data/ under the physical home, where ac_data_dir does", () => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "ac-archive-data-")));
  try {
    const real = join(base, "real");
    mkdirSync(real);
    symlinkSync(real, join(base, "link"));
    const want = bashDataDir({ AC_HOME: join(base, "link") });
    expect(want).toEqual({ out: `${real}/data\n`, err: "", rc: 0 });
    expect(existsSync(join(real, "data"))).toBe(true);
    rmSync(join(real, "data"), { recursive: true });
    process.env.AC_HOME = join(base, "link");
    expect(dataDir()).toBe(join(real, "data"));
    expect(existsSync(join(real, "data"))).toBe(true);
  } finally {
    delete process.env.AC_HOME;
    rmSync(base, { recursive: true, force: true });
  }
});

test("dataDir refuses a homeless caller with ac_data_dir's line and status", () => {
  const want = bashDataDir({});
  expect(want.rc).toBe(1);
  expect(want.out).toBe("");
  expect(want.err).toStartWith("ERROR: AC_HOME is not set");
  expect(tsDataDir({})).toEqual(want);
});

test("dataDir refuses an unreadable home with ac_data_dir's status; the line is the shell's own", () => {
  // bash prints `cd: /nonexistent: No such file or directory` with its own
  // script:line prefix; envHome names the variable instead. Exit matches.
  const want = bashDataDir({ AC_HOME: "/nonexistent/ac-archive-home" });
  const got = tsDataDir({ AC_HOME: "/nonexistent/ac-archive-home" });
  expect(want.rc).toBe(1);
  expect(got.rc).toBe(1);
  expect(got.out).toBe(want.out);
  expect(got.err).toBe("ERROR: AC_HOME is not a readable directory: /nonexistent/ac-archive-home\n");
});
