// lock.test.ts - the one lib.ts twin src/lock.ts introduced, held to its bash
// original: HARNESS_RE is a copy of AC_HARNESS_RE (bin/ac-harness.sh), the ERE
// the lock's ancestry walk classifies command lines with. It is lifted from the
// file, as tests/ts/lib.test.ts lifts HARNESSES, so the two copies cannot
// drift apart silently - and it is NOT the HARNESSES registry joined: the
// regex names cursor's PROCESS (`cursor-agent`), the registry its id. The CLI
// contract (every verb, the walk, stdout, stderr, exit, the lock file) is
// tests/sh/ac-lock.test.sh's, whose differential leg runs the frozen bash
// original beside the shim.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { HARNESS_RE, HARNESSES } from "../../src/lib.ts";

test("HARNESS_RE is the AC_HARNESS_RE text of bin/ac-harness.sh", () => {
  const src = readFileSync(join(import.meta.dir, "..", "..", "bin", "ac-harness.sh"), "utf8");
  const m = /^AC_HARNESS_RE='([^']*)'$/m.exec(src);
  expect(m).not.toBeNull();
  expect(HARNESS_RE).toBe(m![1]);
  // The regex text, not the registry: the one alternative they disagree on.
  expect(HARNESS_RE.split("|")).toContain("cursor-agent");
  expect(HARNESS_RE).not.toBe(HARNESSES.join("|"));
});
