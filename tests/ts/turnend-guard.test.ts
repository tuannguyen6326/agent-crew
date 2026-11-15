// turnend-guard.test.ts - src/lib.ts's hookTrace as src/turnend-guard.ts calls
// it (a native detail, no catch - strictDecimal never throws), held to the
// live bin/ac-lib.sh ac_hook_trace, each run in the hooks' own context
// (`set -uo pipefail`, the lib sourced) over a copy of one home: the log's
// bytes after the call, the call's stdout and stderr, and its fate under a
// keep knob - held to bash where the two readings agree. The guard's own
// contract is tests/sh/ac-turnend-guard.test.sh.
//
// Where the keep knob's two readings diverge the twin is asserted on its own:
// hookTrace's AC_STOPHOOK_LOG_KEEP is strictDecimal (40e4753e), so `010` is
// ten, never bash's octal eight, and a refusal falls back to 200 - as
// tests/ts/hook-twins.test.ts asserts for watch-autoarm's identical call.
//
// DISPUTED: the implementation of the trace (ac_hook_trace vs src/lib.ts's hookTrace as the guard calls it directly)
// HELD-CONSTANT: the home's bytes (copied per side), the hook name and detail, AC_STOPHOOK_LOG_KEEP, PATH (a date stub frozen at one instant ahead of the host's), LC_ALL=C, the cwd
import { afterAll, expect, test } from "bun:test";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-turnend-twins-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const STUB = join(W, "stub");
mkdirSync(STUB);
writeFileSync(join(STUB, "date"), '#!/bin/sh\necho 2027-01-15T08:00:00Z\n', { mode: 0o755 });
const TWIN = join(W, "twin.ts");
writeFileSync(
  TWIN,
  `import { hookTrace } from ${JSON.stringify(LIB)};
hookTrace(process.argv[2]!, Buffer.from(process.argv[3]!, "utf8").toString("latin1"));
`,
);

// The bash side is a script FILE, as the guard is: under `bash -c` bash 3.2
// dies 127 on a keep naming a variable, where a script dies 0.
const BASH_SIDE = join(W, "trace.sh");
writeFileSync(BASH_SIDE, 'set -uo pipefail\n. "$1/ac-lib.sh" 2>/dev/null || exit 9\nac_hook_trace "$2" "$3"\n');

type Ran = { status: number; out: string; err: string; log: string | null };
function side(kind: "bash" | "twin", home: string | null, keep: string | undefined, detail: string, path = `${STUB}:${process.env.PATH ?? ""}`): Ran {
  const env: Record<string, string> = { PATH: path, LC_ALL: "C", HOME: W };
  if (home !== null) env.AC_HOME = home;
  if (keep !== undefined) env.AC_STOPHOOK_LOG_KEEP = keep;
  const argv =
    kind === "bash"
      ? ["/bin/bash", BASH_SIDE, join(ROOT, "bin"), "turnend-guard", detail]
      : [process.execPath, "--no-env-file", TWIN, "turnend-guard", detail];
  const r = Bun.spawnSync(argv, { stdin: "ignore", stdout: "pipe", stderr: "pipe", cwd: W, env });
  const log = home !== null && existsSync(join(home, "state", ".stop-hooks.log")) ? readFileSync(join(home, "state", ".stop-hooks.log"), "latin1") : null;
  return { status: r.exitCode ?? -1, out: r.stdout.toString(), err: r.stderr.toString(), log };
}

function both(seed: (home: string) => void, keep?: string, detail = "verdict=blocked reason=queued-wakes", path?: string): { bash: Ran; twin: Ran } {
  const base = join(W, `world-${Math.random().toString(36).slice(2)}`);
  mkdirSync(join(base, "state"), { recursive: true });
  seed(base);
  cpSync(base, `${base}.b`, { recursive: true });
  cpSync(base, `${base}.t`, { recursive: true });
  return { bash: side("bash", `${base}.b`, keep, detail, path), twin: side("twin", `${base}.t`, keep, detail, path) };
}

test("the guard's trace appends the line ac_hook_trace appends, and says nothing", () => {
  for (const detail of ["verdict=blocked reason=queued-wakes scope=fleet queued=yes inflight=0 age=n/a handback=none", "x y\tz", ""]) {
    const r = both(() => {}, undefined, detail);
    expect(r.twin.log).toBe(r.bash.log);
    expect(r.twin.out + r.twin.err).toBe("");
    expect(r.bash.out + r.bash.err).toBe("");
  }
});

test("the guard's trace trims past twice the keep as ac_hook_trace does", () => {
  const seed = (n: number) => (home: string) => writeFileSync(join(home, "state", ".stop-hooks.log"), Array.from({ length: n }, (_, i) => `old ${i}\n`).join(""));
  for (const [n, keep] of [[5, "2"], [4, "2"], [3, "2"], [450, undefined], [3, "0"]] as const) {
    const r = both(seed(n), keep);
    expect(r.twin.log).toBe(r.bash.log);
    expect(r.twin.status).toBe(r.bash.status);
  }
});

test("the guard's trace keep is strictDecimal: 010 is ten, a refusal falls back to 200", () => {
  const seed = (n: number) => (home: string) => writeFileSync(join(home, "state", ".stop-hooks.log"), Array.from({ length: n }, (_, i) => `old ${i}\n`).join(""));
  const traceLine = "2027-01-15T08:00:00Z hook=turnend-guard verdict=blocked reason=queued-wakes\n";

  const tenKeep = both(seed(25), "010");
  expect(tenKeep.twin.log).toBe(`${Array.from({ length: 9 }, (_, i) => `old ${16 + i}\n`).join("")}${traceLine}`);
  expect(tenKeep.twin.status).toBe(0);

  const refused = both(seed(3), "-1");
  expect(refused.twin.log).toBe(`${Array.from({ length: 3 }, (_, i) => `old ${i}\n`).join("")}${traceLine}`);
  expect(refused.twin.status).toBe(0);
});

test("a malformed keep (`2x`, `nokeep`) strictDecimal refuses: the twin falls back to 200, trims and keeps per 200, losing no trace line", () => {
  // Past keep*2 (fallback 200: 400) lines so the trim actually runs.
  const n = 401;
  const seedLines = Array.from({ length: n }, (_, i) => `old ${i}\n`);
  const seed = (home: string) => writeFileSync(join(home, "state", ".stop-hooks.log"), seedLines.join(""));
  const traceLine = "2027-01-15T08:00:00Z hook=turnend-guard verdict=blocked reason=queued-wakes\n";
  // tail -n 200 of the (n+1)-line file: the last 199 old lines plus the
  // trace line just appended.
  const expectedLog = `${seedLines.slice(n - 199).join("")}${traceLine}`;
  for (const keep of ["2x", "nokeep"]) {
    const r = both(seed, keep);
    expect([keep, r.twin.status, r.twin.log]).toEqual([keep, 0, expectedLog]);
  }
});

test("homeless, or a state dir that refuses the append, writes and prints nothing", () => {
  const b = side("bash", null, undefined, "d");
  const t = side("twin", null, undefined, "d");
  expect([t.status, t.out, t.err]).toEqual([b.status, b.out, b.err]);
  if (process.getuid?.() === 0) return;
  // The bash's own redirection complaints there are SHELL-OWN STDERR.
  const r = both((home) => chmodSync(join(home, "state"), 0o555));
  expect(r.twin.log).toBe(r.bash.log);
  expect(r.twin.out).toBe(r.bash.out);
  expect(r.twin.err).toBe("");
});

test("a date that cannot start stamps the line empty, as `$(ac_iso)` did", () => {
  const nodate = join(W, "nodate");
  mkdirSync(nodate);
  for (const t of ["mkdir", "wc"]) symlinkSync(Bun.which(t)!, join(nodate, t));
  const r = both(() => {}, undefined, "d", nodate);
  expect(r.bash.log).toBe(" hook=turnend-guard d\n");
  expect(r.twin.log).toBe(r.bash.log);
  expect(r.twin.status).toBe(r.bash.status);
  // The bash's `date: command not found` is SHELL-OWN STDERR.
  expect(r.twin.out + r.twin.err).toBe("");
});
