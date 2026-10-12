// ready.test.ts - the lib.ts twin src/ready.ts's overlap reads its LANDED
// lines from, held to its LIVE bash original: landingOverlaps against
// ac_landing_overlaps at the intake check's call (the 7-day window, the
// family '' that excludes nothing - and with it every empty-family record),
// over one ledger: awk's reading of each epoch, a header line, a numeric
// family, a future record, a third field with a CR or a field after it, and
// path lists of one, several, repeated and spaced paths. The CLI contract is
// tests/sh/ac-ready.test.sh's, whose differential leg runs the frozen original
// beside the shim.
// DISPUTED: the implementation of the landing lookup (ac_landing_overlaps in bin/ac-lib.sh vs landingOverlaps in src/lib.ts)
// HELD-CONSTANT: one scratch home per test holding state/.landings; argv (the window, '' and the paths); env (PATH the host's, LC_ALL=C, AC_HOME the home, EPOCHSECONDS fixed); cwd (the distro root); stdin (/dev/null); stdout, stderr and the status compared whole.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const LIB = join(ROOT, "src", "lib.ts");
const NOW = 1767225600;
const made: string[] = [];
afterAll(() => made.forEach((d) => rmSync(d, { recursive: true, force: true })));

function freshHome(ledger: string): string {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-ready-ts-")));
  made.push(h);
  mkdirSync(join(h, "state"), { recursive: true });
  writeFileSync(join(h, "state", ".landings"), ledger);
  return h;
}

type Run = { out: string; err: string; rc: number };
const read = (r: ReturnType<typeof Bun.spawnSync>): Run => ({ out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 });
const envFor = (home: string): Record<string, string> => ({ PATH: process.env.PATH!, LC_ALL: "C", AC_HOME: home, EPOCHSECONDS: String(NOW) });

function bash(home: string, paths: string[]): Run {
  return read(
    Bun.spawnSync(["/bin/bash", "-c", 'set -euo pipefail; . "$0/ac-lib.sh"; ac_landing_overlaps 604800 "" "$@"', join(ROOT, "bin"), ...paths], {
      env: envFor(home),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    }),
  );
}

function twin(home: string, paths: string[]): Run {
  const src = `import { writeSync } from "node:fs";\nimport * as L from ${JSON.stringify(LIB)};\ntry { for (const h of L.landingOverlaps(604800, "", JSON.parse(process.env.TWIN_ARGS!))) writeSync(1, Buffer.from(h + "\\n", "latin1")); } catch (e) { const s = (e as { status?: number }).status; if (s === undefined) throw e; process.exit(s); }\n`;
  return read(Bun.spawnSync([process.execPath, "-e", src], { env: { ...envFor(home), TWIN_ARGS: JSON.stringify(paths) }, cwd: ROOT, stdin: "ignore", stdout: "pipe", stderr: "pipe" }));
}

const LEDGER = [
  `${NOW - 3600}\tdrain-race\tsrc/a.js`,
  `${NOW - 6 * 86400}\tweek\tsrc/a.js`,
  `${NOW - 8 * 86400}\told\tsrc/a.js`,
  "epoch\tfamily\tsrc/a.js",
  `${NOW - 7200}\t07\tsrc/b.js`,
  `${NOW - 100}x\tprefixed\ta b.txt`,
  `0x${(NOW - 5 * 3600).toString(16)}\thex\tsrc/a.js`,
  `${NOW + 7300}\tfuture\tsrc/a.js`,
  `${NOW - 10}\t\tsrc/a.js`,
  `${NOW - 10}\tfan\tsrc/a.js\textra`,
  `${NOW - 30}\tcr\tsrc/a.js\r`,
  `${NOW - 40}\tlast\ta b.txt`,
].join("\n");

test("landingOverlaps answers ac_landing_overlaps 604800 '' for every path list", () => {
  const h = freshHome(`${LEDGER}\n`);
  for (const paths of [["src/a.js"], ["src/a.js", "src/b.js", "a b.txt"], ["src/a.js", "src/a.js"], ["nothing"], ["src/a.js\r"], [""]]) {
    expect({ paths, ...twin(h, paths) }).toEqual({ paths, ...bash(h, paths) });
  }
  const some = twin(h, ["src/a.js"]).out;
  expect(some).toContain("week\t518400\tsrc/a.js\n");
  expect(some).toContain("future\t-7300\tsrc/a.js\n");
  expect(some.split("\n").some((l) => l.startsWith("\t"))).toBe(false);
});

test("landingOverlaps: an unreadable ledger is awk's status 2, nothing printed", () => {
  if (process.getuid?.() === 0) return;
  const h = freshHome(`${NOW - 10}\tx\tsrc/a.js\n`);
  chmodSync(join(h, "state", ".landings"), 0);
  const want = bash(h, ["src/a.js"]);
  expect(want.rc).toBe(2);
  expect({ ...twin(h, ["src/a.js"]) }).toEqual({ out: "", err: "", rc: 2 });
});
