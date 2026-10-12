// turnend-guard.test.ts - src/lib.ts's hookTrace as src/turnend-guard.ts calls
// it (a native detail, EUNBOUND ending the guard, EARITH only skipping the
// trim), held to the live bin/ac-lib.sh ac_hook_trace, each run in the hooks'
// own context (`set -uo pipefail`, the lib sourced) over a copy of one home:
// the log's bytes after the call, the call's stdout and stderr, and its fate
// under a keep knob that names a variable. The guard's own contract is
// tests/sh/ac-turnend-guard.test.sh, whose leg runs the frozen original.
//
// DISPUTED: the implementation of the trace (ac_hook_trace vs src/lib.ts's hookTrace under the guard's catch)
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
try {
  hookTrace(process.argv[2]!, Buffer.from(process.argv[3]!, "utf8").toString("latin1"));
} catch (e) {
  const code = (e as { code?: string }).code;
  if (code === "EUNBOUND") process.exit(1);
  if (code !== "EARITH") throw e;
}
`,
);

type Ran = { status: number; out: string; err: string; log: string | null };
function side(kind: "bash" | "twin", home: string | null, keep: string | undefined, detail: string, path = `${STUB}:${process.env.PATH ?? ""}`): Ran {
  const env: Record<string, string> = { PATH: path, LC_ALL: "C", HOME: W };
  if (home !== null) env.AC_HOME = home;
  if (keep !== undefined) env.AC_STOPHOOK_LOG_KEEP = keep;
  const argv =
    kind === "bash"
      ? ["/bin/bash", "-c", 'set -uo pipefail; . "$0/ac-lib.sh" 2>/dev/null || exit 9; ac_hook_trace "$1" "$2"', join(ROOT, "bin"), "turnend-guard", detail]
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
  for (const [n, keep] of [[5, "2"], [4, "2"], [3, "2"], [25, "010"], [450, undefined], [3, "0"], [3, "-1"]] as const) {
    const r = both(seed(n), keep);
    expect(r.twin.log).toBe(r.bash.log);
    expect(r.twin.status).toBe(r.bash.status);
  }
});

test("a keep `$(( ))` cannot read skips the trim; one naming a variable ends the hook", () => {
  const seed = (home: string) => writeFileSync(join(home, "state", ".stop-hooks.log"), "a\nb\nc\nd\ne\n");
  const odd = both(seed, "2x");
  expect(odd.twin.log).toBe(odd.bash.log);
  const named = both(seed, "nokeep");
  expect(named.twin.log).toBe(named.bash.log);
  expect(named.bash.status).not.toBe(0);
  expect(named.twin.status).not.toBe(0);
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
