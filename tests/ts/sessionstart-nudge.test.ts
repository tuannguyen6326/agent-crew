// sessionstart-nudge.test.ts - selfTasksInFlight, the twin
// src/sessionstart-nudge.ts introduced, held to the live bin/ac-lib.sh
// ac_self_tasks_in_flight that bin/ac-session-start.sh keeps calling, run as
// the nudge ran it (`2>/dev/null || true`, set -u) over one home: the lines,
// their order, the age spellings and the metas that never count. The hook's
// own contract is tests/sh/ac-sessionstart-nudge.test.sh, whose leg runs the
// frozen original.
//
// DISPUTED: the implementation of the listing (ac_self_tasks_in_flight vs src/lib.ts's selfTasksInFlight)
// HELD-CONSTANT: the home and its metas (bytes and mtimes), PATH (a date stub frozen at one instant ahead of the host's), LC_ALL=C, EPOCHSECONDS unset, the cwd
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-nudge-twins-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const NOW = 1800000000;
const STUB = join(W, "stub");
mkdirSync(STUB);
writeFileSync(join(STUB, "date"), `#!/bin/sh\necho ${NOW}\n`, { mode: 0o755 });
const TWIN = join(W, "twin.ts");
writeFileSync(TWIN, `import { writeSync } from "node:fs";\nimport { selfTasksInFlight } from ${JSON.stringify(LIB)};\nwriteSync(1, Buffer.from(await selfTasksInFlight(), "latin1"));\n`);

function both(home: string | null): { bash: string; twin: string } {
  const env: Record<string, string> = { PATH: `${STUB}:${process.env.PATH ?? ""}`, LC_ALL: "C", HOME: W };
  if (home !== null) env.AC_HOME = home;
  const run = (argv: string[]): string => {
    const r = Bun.spawnSync(argv, { stdin: "ignore", stdout: "pipe", stderr: "pipe", cwd: W, env });
    expect(r.exitCode).toBe(0);
    return r.stdout.toString("latin1");
  };
  return {
    bash: run(["/bin/bash", "-c", 'set -u; . "$0/ac-lib.sh" 2>/dev/null && { ac_self_tasks_in_flight 2>/dev/null || true; }', join(ROOT, "bin")]),
    twin: run([process.execPath, "--no-env-file", TWIN]),
  };
}

test("selfTasksInFlight lists what ac_self_tasks_in_flight lists", () => {
  const home = join(W, "home");
  const sd = join(home, "state");
  mkdirSync(sd, { recursive: true });
  const meta = (name: string, body: string | Buffer, age: number): void => {
    writeFileSync(join(sd, name), body);
    utimesSync(join(sd, name), NOW - age, NOW - age);
  };
  meta("a1.meta", "kind=self\nproject=alpha\nworktree=/nowhere\n", 3 * 86400 + 5);
  meta("a2.meta", "kind=self\n", 3599);
  meta("a3.meta", Buffer.from("kind=self\nproject=b\xe9ta\nproject=last\n", "latin1"), 86399);
  meta("b1.meta", "kind=ship\nproject=no\n", 10);
  meta("c1-chief.meta", "kind=roomchief\n", 10);
  meta("v1.meta", "kind=verify-codereview\n", 10);
  meta("d1.meta", "kind=self\r\nproject=crlf\n", 10);
  meta("e1.meta", "kind=self\nproject=future\n", -7200);
  const r = both(home);
  expect(r.twin).toBe(r.bash);
  expect(r.twin).toContain("self task a1 (alpha, opened 3d ago)");
});

test("homeless, or a home with no self task, lists nothing", () => {
  expect(both(null)).toEqual({ bash: "", twin: "" });
  const empty = join(W, "empty");
  mkdirSync(join(empty, "state"), { recursive: true });
  expect(both(empty)).toEqual({ bash: "", twin: "" });
});
