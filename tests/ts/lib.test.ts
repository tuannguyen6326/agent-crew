// lib.test.ts - Bun unit tests for src/lib.ts, the TypeScript twin of the
// bin/ac-lib.sh helpers a ported script needs. Run through tests/sh/src.test.sh.

import { test, expect, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, realpathSync, existsSync, symlinkSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { envHome, configRead, stateDir, enterCaller, bunChild, sha256File, contractLint, pidAlive, lockAcquire, lockRelease, HARNESSES, ONESHOT_ONLY_HARNESSES, harnessLaunchable } from "../../src/lib.ts";

const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");

const made: string[] = [];
function tempDir(prefix: string): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  made.push(d);
  return d;
}
afterAll(() => made.forEach((d) => rmSync(d, { recursive: true, force: true })));

function freshHome(): string {
  const h = tempDir("ac-lib-ts-");
  mkdirSync(join(h, "config"));
  return h;
}

function runLib(body: string, env: Record<string, string | undefined>) {
  const proc = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); ${body}`],
    { env: { PATH: process.env.PATH, ...env } as Record<string, string> },
  );
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

beforeEach(() => {
  delete process.env.AC_HOME;
});

test("die prints the ac_die shape on stderr and exits 1", () => {
  const r = runLib(`L.die("boom here")`, {});
  expect(r.code).toBe(1);
  expect(r.stdout).toBe("");
  expect(r.stderr).toBe("ERROR: boom here\n");
});

test("envHome is empty when AC_HOME is unset or empty", () => {
  expect(envHome()).toBe("");
  process.env.AC_HOME = "";
  expect(envHome()).toBe("");
});

test("envHome resolves AC_HOME physically, like cd && pwd -P", () => {
  const h = freshHome();
  const link = join(tempDir("ac-lib-ts-link-"), "home");
  symlinkSync(h, link);
  process.env.AC_HOME = link;
  expect(envHome()).toBe(h);
});

test("envHome refuses an AC_HOME that is not a directory", () => {
  const r = runLib(`L.envHome()`, { AC_HOME: "/nonexistent/ac-home-xyz" });
  expect(r.code).toBe(1);
  expect(r.stderr).toContain("/nonexistent/ac-home-xyz");
});

// `cd` needs search permission, not read: a home the shell could not enter
// was refused, so reading it as "no config" here would fail open. Root
// searches every directory, so the refusal cannot be forced there.
test.skipIf(process.getuid?.() === 0)("envHome refuses a home it cannot search, like cd did", () => {
  const h = freshHome();
  chmodSync(h, 0o600);
  const r = runLib(`L.envHome()`, { AC_HOME: h });
  chmodSync(h, 0o700);
  expect(r.code).toBe(1);
  expect(r.stderr).toContain(h);
});

// `cd` then `pwd -P`: a search-only home is enough, the spelling may be long,
// odd or backslashed, and link/.. is tried logically before physically.
test("envHome resolves any home cd could enter", () => {
  const h = freshHome();
  const base = tempDir("ac-lib-ts-cd-");
  const odd = join(base, "b\\h");
  mkdirSync(odd);
  process.env.AC_HOME = odd;
  expect(envHome()).toBe(odd);
  process.env.AC_HOME = h + "/.".repeat(600);
  expect(envHome()).toBe(h);
  chmodSync(h, 0o100);
  process.env.AC_HOME = h;
  const searchOnly = envHome();
  chmodSync(h, 0o700);
  expect(searchOnly).toBe(h);
  mkdirSync(join(base, "other", "sub"), { recursive: true });
  mkdirSync(join(base, "nohome"));
  symlinkSync(join(base, "other", "sub"), join(base, "link"));
  process.env.AC_HOME = join(base, "link") + "/../nohome";
  expect(envHome()).toBe(join(base, "nohome"));
  mkdirSync(join(base, "other", "physonly"));
  process.env.AC_HOME = join(base, "link") + "/../physonly";
  expect(envHome()).toBe(join(base, "other", "physonly"));
});

test("configRead answers the default with no home or no file", () => {
  expect(configRead("crew-harness", "claude")).toBe("claude");
  process.env.AC_HOME = freshHome();
  expect(configRead("crew-harness", "claude")).toBe("claude");
  expect(configRead("crew-harness")).toBe("");
});

test("configRead returns the first line trimmed of whitespace and a CR", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  writeFileSync(join(h, "config", "crew-harness"), " \tcodex \r\nsecond line\n");
  expect(configRead("crew-harness", "claude")).toBe("codex");
});

test("configRead keeps a present-but-empty file empty, never the default", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  writeFileSync(join(h, "config", "crew-harness"), "");
  expect(configRead("crew-harness", "claude")).toBe("");
});

// Measured: bash 3.2's [:space:] under the operators' en_US.UTF-8 locale
// trims U+00A0 too (only LC_ALL=C keeps it), so the port trims Unicode space.
test("configRead trims Unicode whitespace, as [:space:] does under a UTF-8 locale", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  writeFileSync(join(h, "config", "crew-harness"), "\u00a0codex\u00a0\n");
  expect(configRead("crew-harness")).toBe("codex");
});

// Measured the same way: [:space:] there keeps U+0085 and U+FEFF.
test("configRead keeps U+0085 and U+FEFF, which [:space:] does not trim", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  writeFileSync(join(h, "config", "crew-harness"), "\u0085codex\ufeff\n");
  expect(configRead("crew-harness")).toBe("\u0085codex\ufeff");
});

test("stateDir mints state/ under the resolved home", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  expect(stateDir()).toBe(join(h, "state"));
  expect(existsSync(join(h, "state"))).toBe(true);
});

test("stateDir refuses without AC_HOME, naming the variable", () => {
  const r = runLib(`L.stateDir()`, {});
  expect(r.code).toBe(1);
  expect(r.stderr).toStartWith("ERROR: AC_HOME is not set");
});

// ac_home_resolve and ac_config_read are each "ONE copy on purpose"
// (bin/ac-lib.sh), so the TypeScript twins are held to them differentially:
// the same home, the same config bytes, and the bash answer is the authority.
test("envHome and configRead answer exactly what ac_home_resolve and ac_config_read do", () => {
  const binDir = join(import.meta.dir, "..", "..", "bin");
  const h = freshHome();
  const link = join(tempDir("ac-lib-ts-diff-"), "home");
  symlinkSync(h, link);
  // ASCII-only bodies: [:space:] beyond ASCII follows the host libc's locale
  // tables, which differ between macOS and Linux - the Unicode trim is pinned
  // by the port-only tests above instead.
  const bodies = ["codex\n", " \tcodex \r\n2nd\n", "\n\ncodex\n", "", "x y\tz\n", "# comment\ncodex\n", "codex"];
  for (const home of [undefined, h, link]) {
    for (const body of home ? [...bodies, null] : [null]) {
      if (home) {
        const f = join(h, "config", "crew-harness");
        if (body === null) Bun.spawnSync(["rm", "-f", f]); else writeFileSync(f, body);
      }
      const env = { PATH: process.env.PATH!, LC_ALL: "en_US.UTF-8", ...(home ? { AC_HOME: home } : {}) };
      const bash = Bun.spawnSync(
        ["bash", "-c", '. "$1/ac-lib.sh"; printf "%s|%s" "$(ac_home_resolve "" "")" "$(ac_config_read crew-harness claude)"', "--", binDir],
        { env },
      );
      expect(bash.exitCode).toBe(0);
      if (home) process.env.AC_HOME = home; else delete process.env.AC_HOME;
      expect(`${envHome()}|${configRead("crew-harness", "claude")}`).toBe(bash.stdout.toString());
    }
  }
});

// Both maintenance hashes a receipt binds - the manifest's and the plan's -
// are compared against values ac_sha256_file wrote, so the twin must print
// the same bytes for any file, whatever it holds.
test("sha256File answers exactly what ac_sha256_file prints", () => {
  const binDir = join(import.meta.dir, "..", "..", "bin");
  const d = tempDir("ac-lib-ts-sha-");
  const bodies: [string, Buffer][] = [
    ["empty", Buffer.alloc(0)],
    ["line", Buffer.from("skill\n")],
    ["unterminated", Buffer.from("no newline")],
    ["crlf", Buffer.from("a\r\nb\r\n")],
    ["nul", Buffer.from([0x61, 0x00, 0x62, 0x0a, 0x00])],
    ["octets", Buffer.from([0xff, 0xfe, 0xc2, 0xa0, 0x80])],
    ["big", Buffer.alloc(3 << 20, "ab\n")],
  ];
  for (const [name, bytes] of bodies) writeFileSync(join(d, name), bytes);
  symlinkSync(join(d, "line"), join(d, "link"));
  for (const name of [...bodies.map(([n]) => n), "link"]) {
    const bash = Bun.spawnSync(["bash", "-c", '. "$1/ac-lib.sh"; ac_sha256_file "$2"', "--", binDir, join(d, name)], {
      env: { PATH: process.env.PATH! },
    });
    expect(bash.exitCode).toBe(0);
    expect([name, `${sha256File(join(d, name))}\n`]).toEqual([name, bash.stdout.toString()]);
  }
});

// Without pipefail the shell's pipeline prints nothing for a file it cannot
// read, and its callers read that empty hash as a mismatch; the twin throws,
// so no caller can compare against an empty hash at all.
test("sha256File throws where ac_sha256_file prints no hash", () => {
  const missing = join(tempDir("ac-lib-ts-sha-miss-"), "missing");
  const bash = Bun.spawnSync(["bash", "-c", '. "$1/ac-lib.sh"; ac_sha256_file "$2"', "--", join(import.meta.dir, "..", "..", "bin"), missing], {
    env: { PATH: process.env.PATH! },
  });
  expect(bash.stdout.toString()).toBe("");
  expect(() => sha256File(missing)).toThrow();
});

const STAGED = "flow:staged with rev:no - staged review is mandatory (AGENTS.md section 5)";
const CREWSHIP = "mode:crew-ship with rev:no - crew-ship review is mandatory (AGENTS.md section 5)";
test("contractLint judges each closed vocabulary and the two outlawed combinations", () => {
  const cases: [string, string[]][] = [
    ["", []],
    ["src:cap flow:direct mode:local-only rev:no qa:no", []],
    ["mode:feature-pr", []],
    ["promote:no", []],
    ["src:boss", ["src:boss invalid - want cap|chief|mon|gh|crew|learn"]],
    ["flow:agile", ["flow:agile invalid - want direct|staged"]],
    ["mode:ship", ["mode:ship invalid - want crew-ship|direct-pr|local-only|feature-pr"]],
    ["rev:maybe", ["rev:maybe invalid - want yes|no"]],
    // qa has no `auto`: chief judgment decides it, never a click.
    ["qa:auto", ["qa:auto invalid - want yes|no"]],
    ["promote:yes", ["promote:yes invalid - want no (always is the default and is never written)"]],
    ["flow:staged rev:no", [STAGED]],
    ["mode:crew-ship rev:no", [CREWSHIP]],
    ["flow:staged\trev:no\nmode:crew-ship", [STAGED, CREWSHIP]],
    ["flow:staged rev:no flow:direct", []],
    ["noColon a:b:c unknown:key", []],
    ["flow:x:y", ["flow:x:y invalid - want direct|staged"]],
    ["src:", ["src: invalid - want cap|chief|mon|gh|crew|learn"]],
  ];
  for (const [c, want] of cases) expect([c, contractLint(c)]).toEqual([c, want]);
});

// src/task.ts takes the backlog lock through the lock-dir protocol every bash
// writer takes through ac_lock_acquire, so an older checkout's ac-task.sh and
// the port must read one lock dir the same way: who is alive, when it is
// stale, and whose it is to release. The shell answer is the authority.
const LIB_BIN = join(import.meta.dir, "..", "..", "bin");
const bashLib = (body: string, ...args: string[]) =>
  Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; ${body}`, LIB_BIN, ...args], { env: { PATH: process.env.PATH! } });

test("pidAlive answers exactly what ac_pid_alive does", () => {
  const gone = Bun.spawnSync(["sh", "-c", "echo $$"]).stdout.toString().trim();
  for (const pid of [String(process.pid), "1", gone, "0", "", "01", "abc", "-5", "99999999999999999999"]) {
    const bash = bashLib('ac_pid_alive "$1" && echo alive || echo dead', pid);
    expect([pid, pidAlive(pid) ? "alive" : "dead"]).toEqual([pid, bash.stdout.toString().trim()]);
  }
});

test("lockAcquire and ac_lock_acquire exclude each other and reclaim alike", async () => {
  const d = tempDir("ac-lib-ts-lock-");
  const lock = join(d, "x.lock");
  const acquire = (timeout: string) => bashLib('ac_lock_acquire "$1" "$2" && echo got || echo refused', lock, timeout).stdout.toString().trim();
  // A live bash holder refuses the TypeScript writer.
  const holder = Bun.spawn(["bash", "-c", '. "$0/ac-lib.sh"; ac_lock_acquire "$1" 5 && sleep 3; ac_lock_release "$1"', LIB_BIN, lock]);
  while (!existsSync(join(lock, "pid"))) await Bun.sleep(20);
  expect(lockAcquire(lock, 1)).toBe(false);
  await holder.exited;
  // A live TypeScript holder refuses the bash writer.
  expect(lockAcquire(lock, 0)).toBe(true);
  expect(acquire("1")).toBe("refused");
  lockRelease(lock);
  expect(existsSync(lock)).toBe(false);
  // A dead owner is stale to both.
  const gone = Bun.spawnSync(["sh", "-c", "echo $$"]).stdout.toString().trim();
  for (const side of ["ts", "bash"]) {
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), `${gone}\n`);
    expect([side, side === "ts" ? (lockAcquire(lock, 0) ? "got" : "refused") : acquire("0")]).toEqual([side, "got"]);
    rmSync(lock, { recursive: true, force: true });
  }
  // A pid-less dir is stale only once its grace has passed.
  for (const [grace, want] of [["60", "refused"], ["0", "got"]]) {
    for (const side of ["ts", "bash"]) {
      mkdirSync(lock);
      process.env.AC_LOCK_STALE_GRACE = grace;
      const got = side === "ts"
        ? (lockAcquire(lock, 0) ? "got" : "refused")
        : bashLib('AC_LOCK_STALE_GRACE="$2" ac_lock_acquire "$1" 0 && echo got || echo refused', lock, grace).stdout.toString().trim();
      delete process.env.AC_LOCK_STALE_GRACE;
      expect([grace, side, got]).toEqual([grace, side, want]);
      rmSync(lock, { recursive: true, force: true });
    }
  }
  // A stale dir that cannot be removed is waited on and refused, never thrown.
  for (const side of ["ts", "bash"]) {
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), `${gone}\n`);
    chmodSync(lock, 0o555);
    let got: string;
    try {
      got = side === "ts" ? (lockAcquire(lock, 0) ? "got" : "refused") : acquire("0");
    } catch (e) {
      got = `threw ${(e as { code?: string }).code}`;
    }
    chmodSync(lock, 0o755);
    expect([side, got]).toEqual([side, "refused"]);
    rmSync(lock, { recursive: true, force: true });
  }
  // Release is owner-checked: another live holder's dir survives both.
  for (const side of ["ts", "bash"]) {
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), "1\n");
    if (side === "ts") lockRelease(lock); else bashLib('ac_lock_release "$1"', lock);
    expect([side, existsSync(lock)]).toEqual([side, true]);
    rmSync(lock, { recursive: true, force: true });
  }
});

test("enterCaller moves to the caller's cwd, its first argument", () => {
  const here = process.cwd();
  const d = tempDir("ac-lib-ts-enter-");
  try {
    expect(enterCaller([d, "--list", "x"])).toEqual({ args: ["--list", "x"], atCaller: true });
    expect(process.cwd()).toBe(d);
    expect(enterCaller(["", "a"])).toEqual({ args: ["a"], atCaller: false });
    expect(enterCaller([])).toEqual({ args: [], atCaller: false });
  } finally {
    process.chdir(here);
  }
});

test("bunChild starts a src module the way bin/ac-bun.sh does", () => {
  const here = process.cwd();
  process.env.BUN_OPTIONS = "--preload=/x.ts";
  process.env.JSC_dumpOptions = "1";
  try {
    const root = join(import.meta.dir, "..", "..");
    enterCaller([""]);
    expect(bunChild("src/brain.ts", ["stats"]).cmd).toEqual([process.execPath, "--no-env-file", join(root, "src/brain.ts"), "", "stats"]);
    enterCaller([here]);
    const c = bunChild("src/brain.ts", ["stats"]);
    expect(c.cmd).toEqual([process.execPath, "--no-env-file", join(root, "src/brain.ts"), here, "stats"]);
    expect(c.cwd).toBe(root);
    expect(Object.keys(c.env).filter((k) => /^(BUN_|JSC_)/.test(k))).toEqual([]);
  } finally {
    delete process.env.BUN_OPTIONS;
    delete process.env.JSC_dumpOptions;
    process.chdir(here);
  }
});

// Bun's process.cwd() drops a trailing backslash from the directory's name, so
// a name it reports is trusted only once it stats as the directory actually
// entered - never a same-named sibling.
test("a home whose name Bun cannot report is refused, never read as its sibling", () => {
  const base = tempDir("ac-lib-ts-bs-");
  mkdirSync(join(base, "home\\"));
  mkdirSync(join(base, "home"));
  const r = runLib(`console.log(L.envHome())`, { AC_HOME: join(base, "home\\") });
  expect(r.stdout).not.toBe(join(base, "home") + "\n");
  expect(r.code).toBe(1);
});

test("a caller cwd Bun cannot report is not entered", () => {
  const here = process.cwd();
  const base = tempDir("ac-lib-ts-bscwd-");
  mkdirSync(join(base, "wd\\"));
  mkdirSync(join(base, "wd"));
  try {
    expect(enterCaller([join(base, "wd\\"), "x"])).toEqual({ args: ["x"], atCaller: false });
    expect(process.cwd()).not.toBe(join(base, "wd"));
  } finally {
    process.chdir(here);
  }
});

test("configRead drops NUL bytes, as the shell's $(...) did", () => {
  const h = freshHome();
  process.env.AC_HOME = h;
  writeFileSync(join(h, "config", "crew-harness"), "co\u0000dex\n");
  expect(configRead("crew-harness")).toBe("codex");
});

// The lists are copies of two bash tables; lifting both keeps the copies honest.
function bashFn(file: string, fn: string): string {
  const src = readFileSync(join(import.meta.dir, "..", "..", "bin", file), "utf8");
  const at = src.indexOf(`\n${fn}() {\n`);
  expect(at).toBeGreaterThan(-1);
  return src.slice(at, src.indexOf("\n}\n", at));
}

test("the harness lists are ac_harness_known's registry plus oneshot_launch's other arms", () => {
  const registry = (/case "\$1" in ([^)]*)\) return 0/.exec(bashFn("ac-harness.sh", "ac_harness_known")) ?? ["", ""])[1]
    .split("|").map((s) => s.trim());
  const oneshot = [...bashFn("ac-pane-agent.sh", "oneshot_launch").matchAll(/^ {4}([a-z-]+)\)\s+printf/gm)].map((m) => m[1]);
  expect(oneshot.length).toBeGreaterThan(0);
  expect([...HARNESSES].sort()).toEqual(registry.sort());
  expect([...HARNESSES, ...ONESHOT_ONLY_HARNESSES].sort()).toEqual([...new Set([...registry, ...oneshot])].sort());
});

test("harnessLaunchable: a registry or one-shot name, or the home's config/launch-<h> template", () => {
  const h = freshHome();
  for (const n of [...HARNESSES, ...ONESHOT_ONLY_HARNESSES]) expect(harnessLaunchable(h, n)).toBe(true);
  expect(harnessLaunchable(h, "ar")).toBe(false);
  writeFileSync(join(h, "config", "launch-ar"), "ar\n");
  expect(harnessLaunchable(h, "ar")).toBe(true);
  // ac-spawn.sh takes a template only when `[ -f ]` holds.
  mkdirSync(join(h, "config", "launch-dir"));
  expect(harnessLaunchable(h, "dir")).toBe(false);
});
