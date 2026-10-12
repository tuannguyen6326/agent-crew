// scene.test.ts - the lib.ts twins src/scene.ts introduced, held to their bash
// originals differentially: iso against ac_iso (both read the PATH's date, so
// one stub freezes both), and lockAcquire's wait seam against ac_lock_acquire's
// `sleep 1` (the PATH's sleep, so one stub fast-forwards both, through the one
// lock-dir grammar that keeps a bash and a TypeScript writer excluding each
// other). The CLI contract itself (every verb, stdout, stderr, exit, the store
// left behind) is tests/sh/ac-scene.test.sh's, whose differential leg runs the
// frozen bash original beside the shim.
import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { iso, lockAcquire, lockRelease } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
const bashLib = (body: string, env: Record<string, string>, ...args: string[]) =>
  Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; ${body}`, binDir, ...args], { env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });

function stubBin(stubs: Record<string, string>): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), "ac-scene-stub-")));
  for (const [name, body] of Object.entries(stubs)) {
    writeFileSync(join(d, name), `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(join(d, name), 0o755);
  }
  return d;
}

test("iso stamps what ac_iso stamps: the PATH's date, so a stub freezes both sides", async () => {
  const stub = stubBin({ date: 'printf "%s\\n" "$*" >"$0.args"; echo 2026-01-02T03:04:05Z' });
  const env = { PATH: `${stub}:${process.env.PATH}` };
  try {
    const want = bashLib("ac_iso", env);
    expect(want.stdout.toString()).toBe("2026-01-02T03:04:05Z\n");
    const r = Bun.spawnSync([process.execPath, "-e", 'import { iso } from "./src/lib.ts"; process.stdout.write(iso())'], {
      cwd: join(import.meta.dir, "..", ".."),
      env: { ...process.env, ...env },
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(r.stdout.toString()).toBe("2026-01-02T03:04:05Z");
    await expect(Bun.file(join(stub, "date.args")).text()).resolves.toBe("-u +%Y-%m-%dT%H:%M:%SZ\n");
  } finally {
    rmSync(stub, { recursive: true, force: true });
  }
  // Unstubbed, the same shape (UTC, seconds, no fraction) as ac_iso's.
  const live = bashLib("ac_iso", {}).stdout.toString().trim();
  expect(live).toMatch(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/);
  expect(iso()).toMatch(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/);
  expect(iso().slice(0, 13)).toBe(live.slice(0, 13));
});

test("lockAcquire waits through the caller's wait, once per second of timeout, on the one lock-dir grammar", async () => {
  const d = realpathSync(mkdtempSync(join(tmpdir(), "ac-scene-lock-")));
  const lock = join(d, ".lock");
  const stub = stubBin({ sleep: 'printf "%s\\n" "$*" >>"$0.calls"; exit 0' });
  const env = { PATH: `${stub}:${process.env.PATH}` };
  try {
    // A live holder (this process): a wait that spawns the PATH's sleep is
    // called timeout times, and the stub makes a 30 s timeout instant.
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), `${process.pid}\n`);
    const spawned: number[] = [];
    const wait = () => {
      spawned.push(Bun.spawnSync(["sleep", "1"], { env: { ...process.env, ...env }, stdin: "ignore", stdout: "ignore", stderr: "ignore" }).exitCode);
    };
    const t0 = Date.now();
    expect(lockAcquire(lock, 30, wait)).toBe(false);
    expect(Date.now() - t0).toBeLessThan(5000);
    expect(spawned).toEqual(new Array(30).fill(0));
    expect((await Bun.file(join(stub, "sleep.calls")).text()).split("\n").filter((l) => l !== "")).toEqual(new Array(30).fill("1"));
    // The bash side, under the same stub, refuses the same way.
    const r = bashLib('ac_lock_acquire "$1" 30 && echo got || echo refused', env, lock);
    expect(r.stdout.toString().trim()).toBe("refused");
    rmSync(lock, { recursive: true, force: true });
    // The default wait is untouched for the other caller: a 0 timeout never waits.
    let calls = 0;
    expect(lockAcquire(lock, 0)).toBe(true);
    expect(lockAcquire(lock, 0, () => void calls++)).toBe(false);
    expect(calls).toBe(0);
    // A TypeScript holder taken through the scene wait refuses a bash writer,
    // and a bash holder refuses the scene wait: one dir, one pid file.
    expect(bashLib('ac_lock_acquire "$1" 0 && echo got || echo refused', env, lock).stdout.toString().trim()).toBe("refused");
    lockRelease(lock);
    expect(existsSync(lock)).toBe(false);
    const holder = Bun.spawn(["bash", "-c", '. "$0/ac-lib.sh"; ac_lock_acquire "$1" 5 && sleep 2; ac_lock_release "$1"', binDir, lock]);
    while (!existsSync(join(lock, "pid"))) await Bun.sleep(20);
    expect(lockAcquire(lock, 1, wait)).toBe(false);
    await holder.exited;
    expect(existsSync(lock)).toBe(false);
  } finally {
    rmSync(stub, { recursive: true, force: true });
    rmSync(d, { recursive: true, force: true });
  }
});
