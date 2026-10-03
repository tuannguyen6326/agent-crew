// rig.test.ts - the lib.ts twin src/rig.ts introduced, held to its bash
// original differentially: physicalDir against `cd "$1" && pwd -P`, the
// chdir round-trip ac_home and ac-rig.sh's canon both resolve through. The
// CLI contract itself (the verb, every refusal, the report lines, exit) is
// tests/sh/ac-rig.test.sh's, whose differential leg runs the frozen bash
// original beside the shim.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { physicalDir } from "../../src/lib.ts";

function bashCd(path: string, cwd: string): { out: string; rc: number } {
  const r = Bun.spawnSync(["bash", "-c", 'cd "$1" 2>/dev/null && pwd -P', "--", path], { cwd, stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString().replace(/\n$/, ""), rc: r.exitCode ?? -1 };
}

test("physicalDir answers `cd && pwd -P` over every spelling a manifest can carry", () => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "ac-rig-physical-")));
  const here = process.cwd();
  try {
    const real = join(base, "real");
    mkdirSync(join(real, "sub"), { recursive: true });
    symlinkSync(real, join(base, "link"));
    writeFileSync(join(base, "afile"), "x\n");
    process.chdir(base);
    // "" included: `cd ""` is a no-op in bash 3.2 and answers the cwd, which
    // ac-rig.sh's canon reaches through a state/.ac-root holding only newlines.
    for (const p of [real, join(base, "link"), join(base, "link", "sub", ".."), `${real}/`, "real", "link/sub", "", join(base, "gone"), join(base, "afile"), "/nonexistent/ac-rig"]) {
      const want = bashCd(p, base);
      expect(physicalDir(p)).toBe(want.rc === 0 ? want.out : null);
    }
    expect(physicalDir(join(base, "link", "sub", ".."))).toBe(real);
    expect(physicalDir("")).toBe(base);
    expect(physicalDir(join(base, "gone"))).toBeNull();
    // The cwd is the caller's again after every round-trip, found or not.
    expect(process.cwd()).toBe(base);
  } finally {
    process.chdir(here);
    rmSync(base, { recursive: true, force: true });
  }
});
