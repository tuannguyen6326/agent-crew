// promote.test.ts - the lib.ts twin src/promote.ts introduced, held to its bash
// original differentially: deliveryModeBlock against ac_delivery_mode_block in
// bin/ac-pipeline-lib.sh, whose bash copy STAYS LIVE for bin/ac-brief.sh - two
// renderers of one delivery contract, so every mode the bash renders (and the
// empty answer for one it does not) is compared byte for byte, with no trailing
// newline, over argument bytes printf's %s passes untouched. The CLI contract
// itself is tests/sh/ac-promote.test.sh's, whose differential leg runs the
// frozen bash original beside the shim.
import { expect, test } from "bun:test";
import { join } from "node:path";
import { deliveryModeBlock } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");

function bash(fn: string, ...args: string[]) {
  const r = Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-pipeline-lib.sh"; ${fn} "$@"`, binDir, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...(process.env as Record<string, string>), LC_ALL: "C" },
  });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

const ARGS: [string, string, string, string][] = [
  ["crew/s1", "the recorded target branch", "the recorded integration branch", "delivery preparation"],
  ["crew/t9", "", "", ""],
  ["crew/x", "main", "feature/eb", "the ordered review/check/doc loop below"],
  ["crew/%s `tick`", "base %d", "integ\\n", "loop with  two  spaces"],
];

test("deliveryModeBlock renders every mode ac_delivery_mode_block renders, byte for byte, no trailing newline", () => {
  for (const mode of ["crew-ship", "direct-pr", "feature-pr", "local-only", "bogus", "", "Crew-Ship"]) {
    for (const a of ARGS) {
      const o = bash("ac_delivery_mode_block", mode, ...a);
      expect([mode, a, o.rc, o.err]).toEqual([mode, a, 0, ""]);
      expect([mode, a, deliveryModeBlock(mode, ...a)]).toEqual([mode, a, o.out]);
    }
  }
  // The shape itself, once per mode, so the comparison above is known to be of
  // the right bytes.
  const [branch, base, integ, loop] = ARGS[0]!;
  expect(deliveryModeBlock("crew-ship", branch, base, integ, loop)).toBe(
    "- Mode crew-ship: run the `crew-ship` skill. Its `ac-ship` engine owns the guarded 8-step delivery pipeline (intent, rebase, review, test, document, lint, push, pr). Hand over only after checks pass and include the PR URL.",
  );
  expect(deliveryModeBlock("direct-pr", branch, base, integ, loop)).toBe(
    "- Mode direct-pr: after delivery preparation, push `crew/s1` and open a PR against the recorded target branch. The PR body covers intent, changes, and verification evidence.",
  );
  expect(deliveryModeBlock("feature-pr", branch, base, integ, loop)).toBe(
    "- Mode feature-pr: after delivery preparation, leave `crew/s1` clean and fully committed - it lands onto the feature integration branch `the recorded integration branch` (the chief runs ac-merge-local). Never push or open a PR; publication happens ONCE at the feature ship.",
  );
  expect(deliveryModeBlock("local-only", branch, base, integ, loop)).toBe(
    "- Mode local-only: after delivery preparation, leave `crew/s1` clean and fully committed. Never push or open a PR.",
  );
  expect(deliveryModeBlock("bogus", branch, base, integ, loop)).toBe("");
});
