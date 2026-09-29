// lib.test.ts - Bun unit tests for src/lib.ts, the TypeScript twin of the
// bin/ac-lib.sh helpers a ported script needs. Run through tests/sh/src.test.sh.

import { test, expect, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync, existsSync, symlinkSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { envHome, configRead, stateDir, enterCaller, bunChild, sha256File, contractLint } from "../../src/lib.ts";

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

// ac-task.sh and ac-brief.sh still judge a contract through ac_contract_lint,
// so the scheduler's copy must answer exactly what the shell does. No glob
// characters: the shell's unquoted walk would expand them against the cwd,
// and no parsed contract token can hold one (src/backlog.ts, contract).
test("contractLint answers exactly what ac_contract_lint prints", () => {
  const binDir = join(import.meta.dir, "..", "..", "bin");
  const contracts = [
    "", "   ", "src:cap flow:direct mode:local-only rev:no qa:no", "src:bogus flow:sideways mode:yolo rev:maybe qa:perhaps",
    "promote:no", "promote:always", "flow:staged rev:no", "mode:crew-ship rev:no", "flow:staged\trev:no\nmode:crew-ship",
    "flow:staged rev:no flow:direct", "rev:no rev:yes mode:crew-ship", "src:", "noColon", "a:b:c", "flow:x:y",
    ":lead", "unknown:key src:crew", "  src:gh  qa:yes ",
  ];
  for (const c of contracts) {
    const bash = Bun.spawnSync(["bash", "-c", '. "$1/ac-lib.sh"; ac_contract_lint "$2"', "--", binDir, c], {
      env: { PATH: process.env.PATH! },
    });
    expect(bash.exitCode).toBe(0);
    expect([c, contractLint(c).map((v) => `${v}\n`).join("")]).toEqual([c, bash.stdout.toString()]);
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
