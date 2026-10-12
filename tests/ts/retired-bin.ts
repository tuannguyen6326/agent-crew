// retired-bin.ts - the TypeScript side of tests/sh/helpers.sh's
// make_retired_bin: a bin/ holding every live script plus the sourced libs with
// no live caller left, frozen whole under tests/fixtures/, under a root that
// links src/ and dashboard/. ac-qa-lib.sh sources ac-bun.sh from its own
// directory, so a test sources it from here, never from tests/fixtures/.

import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const RETIRED = ["ac-qa-lib.sh", "ac-pipeline-lib.sh"];
let built = "";

export function retiredBin(): string {
  if (built) return built;
  const root = realpathSync(mkdtempSync(join(tmpdir(), "retired-bin-")));
  process.on("exit", () => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, "bin");
  mkdirSync(bin);
  for (const f of readdirSync(join(ROOT, "bin"))) if (f.endsWith(".sh")) copyFileSync(join(ROOT, "bin", f), join(bin, f));
  for (const f of RETIRED) copyFileSync(join(ROOT, "tests", "fixtures", f), join(bin, f));
  symlinkSync(join(ROOT, "src"), join(root, "src"));
  symlinkSync(join(ROOT, "dashboard"), join(root, "dashboard"));
  built = bin;
  return bin;
}
