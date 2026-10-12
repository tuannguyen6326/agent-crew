// gate-watch.test.ts - the lib.ts twin src/gate-watch.ts prints from, held to
// its LIVE bash original: fleetName against ac_fleet_name, which the bash
// backend, spawn and lib code still call (the physical home's basename, then
// AC_FLEET_NAME, then the fixed `agent-crew`). The CLI contract itself is
// tests/sh/ac-gate-watch.test.sh's, whose differential leg runs the frozen
// original beside the shim.
//
// DISPUTED: the implementation of the fleet name (ac_fleet_name in bin/ac-lib.sh vs fleetName in src/lib.ts)
// HELD-CONSTANT: one scratch root holding home/, a link to it and no nope/; argv (none); env (PATH the host's, AC_HOME and AC_FLEET_NAME only as a row sets them, HOME and TMPDIR the root); cwd (the distro root); stdin (/dev/null); stdout and the status compared whole, stderr too wherever the shell printed none of its own.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-gate-watch-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));
mkdirSync(join(W, "home"));
symlinkSync(join(W, "home"), join(W, "link"));

type Side = { out: string; err: string; rc: number | null };

function side(env: Record<string, string>, oracle: boolean): Side {
  const cmd = oracle
    ? ["/bin/bash", "-c", '. "$0/ac-lib.sh" || exit $?; ac_fleet_name', BIN]
    : [process.execPath, "-e", `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); writeSync(1, L.fleetName() + "\\n");`];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env: { PATH: process.env.PATH!, HOME: W, TMPDIR: W, ...env }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode };
}

const same = (label: string, env: Record<string, string>): Side => {
  const o = side(env, true);
  const t = side(env, false);
  expect({ label, ...t }).toEqual({ label, ...o });
  return t;
};

test("fleetName answers ac_fleet_name's ladder: the physical home, AC_FLEET_NAME, agent-crew", () => {
  expect(same("home", { AC_HOME: join(W, "home") }).out).toBe("home\n");
  expect(same("a link reads the physical name", { AC_HOME: join(W, "link") }).out).toBe("home\n");
  expect(same("a home beats AC_FLEET_NAME", { AC_HOME: join(W, "home"), AC_FLEET_NAME: "other" }).out).toBe("home\n");
  expect(same("homeless with a name", { AC_FLEET_NAME: "fleet-x" }).out).toBe("fleet-x\n");
  expect(same("an empty AC_HOME is homeless", { AC_HOME: "", AC_FLEET_NAME: "fleet-y" }).out).toBe("fleet-y\n");
  expect(same("homeless", {}).out).toBe("agent-crew\n");
  expect(same("the root", { AC_HOME: "/" }).out).toBe("/\n");
});

test("fleetName of a home cd cannot enter is empty, as basename of the failed ac_home printed", () => {
  const env = { AC_HOME: join(W, "nope") };
  const o = side(env, true);
  const t = side(env, false);
  expect([t.out, t.rc]).toEqual([o.out, o.rc]);
  expect(o.out).toBe("\n");
  expect(o.err).toContain("cd: ");
  expect(t.err).toBe("");
});
