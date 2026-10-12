// github.test.ts - the two lib.ts twins src/github.ts introduced, each held to
// its bash original differentially: redactPublish against ac_redact_publish in
// tests/fixtures/ac-pipeline-lib.sh, whose frozen bash copy tests/sh/
// ac-pipeline-lib.test.sh sources too - a comment PUBLISHES, so a twin that redacts less than
// the bash leaks an operator path or a URL credential to GitHub; and
// cksumPosix against /usr/bin/cksum, whose number names every
// `commented-pr-<n>-<cksum>` idempotence file - one bit off and every verdict
// already posted is posted again. The CLI contract itself is
// tests/sh/ac-github.test.sh's, whose differential leg runs the frozen bash
// original beside the shim.
import { expect, test } from "bun:test";
import { join } from "node:path";
import { cksumPosix } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");

type Answer = { out: string; err: string; rc: number };
type Env = Record<string, string | undefined>;

function envOf(extra: Env): Record<string, string> {
  const env: Record<string, string> = { PATH: process.env.PATH! };
  for (const [k, v] of Object.entries(extra)) if (v !== undefined) env[k] = v;
  return env;
}

// The entry runs the helper under `set -euo pipefail`, which is what turns an
// unset HOME into a refusal rather than an empty BRE.
function bashSide(text: Buffer, env: Env): Answer {
  const r = Bun.spawnSync(["bash", "-c", 'set -euo pipefail; . "$1/../tests/fixtures/ac-pipeline-lib.sh"; ac_redact_publish', "--", binDir], {
    stdin: text,
    stdout: "pipe",
    stderr: "pipe",
    env: envOf(env),
  });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

// In a child so sed's own stderr is captured; an unset HOME answers 99, the
// refusal the twin throws before any spawn.
function tsSide(text: Buffer, env: Env): Answer {
  const body = `const L = await import(${JSON.stringify(LIB)});
const input = Buffer.from(await Bun.stdin.arrayBuffer()).toString("latin1");
try { process.stdout.write(Buffer.from(L.redactPublish(input), "latin1")); }
catch (e) { process.exit(e.code === "ENOHOME" ? 99 : e.status); }`;
  const r = Bun.spawnSync([process.execPath, "-e", body], { stdin: text, stdout: "pipe", stderr: "pipe", env: envOf(env) });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

function same(text: string | Buffer, env: Env): Answer {
  const bytes = typeof text === "string" ? Buffer.from(text, "utf8") : text;
  const want = bashSide(bytes, env);
  const got = tsSide(bytes, env);
  expect({ text: bytes.toString("latin1"), env, ...got }).toEqual({ text: bytes.toString("latin1"), env, ...want });
  return got;
}

const C = { LC_ALL: "C" };
const U = { LC_ALL: "en_US.UTF-8" };

test("redactPublish redacts what ac_redact_publish redacts: the pipeline-lib sample, foreign homes, userinfo, every line, the rest byte-intact", () => {
  for (const loc of [C, U]) {
    const env = { ...loc, HOME: "/Users/tester" };
    const sample = same("ran /Users/tester/proj/x then /Users/operator/lab/y and /home/op2/z via https://x:tok123@example.com/repo done\n", env);
    expect(sample).toEqual({ out: "ran ~/proj/x then ~/lab/y and ~/z via https://***@example.com/repo done\n", err: "", rc: 0 });
    same("failed at /Users/operator/lab/run.log after push to https://x:tok9@github.com/a/b\n", env);
    same("line one /home/a.b-c_d/x\n\nline three https://u@h/p and ftp://a:b@c@d/e\n", env);
    same("no trailing newline /Users/x", env);
    same("", env);
    same("& \\1 \\n | ~ * [x] $ ^ stay as they are\n", env);
    same("/Users/ /home/ ://@h/ s:///@x\n", env);
  }
});

test("redactPublish reads HOME as sed reads it - a BRE, `.` one character under UTF-8 and one byte under C", () => {
  for (const loc of [C, U]) {
    const dot = same("at /UsersXop/k and /Users.op/j and /Users\u00e9op/m\n", { ...loc, HOME: "/Users.op" });
    expect(dot.out.startsWith("at ~/k and ~/j and ")).toBe(true);
    same("/Users/b /Users/aaab /Users/ab\n", { ...loc, HOME: "/Users/a*b" });
    same("/srv/x1/y /srv/xz/y\n", { ...loc, HOME: "/srv/x[0-9]" });
  }
  // The one locale-dependent answer, pinned so the comparison above is known
  // to have bitten: under UTF-8 `.` takes the whole é.
  expect(same("/Users\u00e9op/m\n", { ...U, HOME: "/Users.op" }).out).toBe("~/m\n");
  expect(same("/Users\u00e9op/m\n", { ...C, HOME: "/Users.op" }).out).toBe(Buffer.from("/Users\u00e9op/m\n", "utf8").toString("latin1"));
});

test("redactPublish's userinfo class is sed's [:space:] - Unicode under UTF-8, the ASCII six under C", () => {
  const text = "https://a\u00a0b:t@h/ ftp://x\u2003y@h/ s://u\tv@h/ https://ok:tok@h/\n";
  const c = same(text, { ...C, HOME: "/Users/tester" });
  const u = same(text, { ...U, HOME: "/Users/tester" });
  expect(c.out).toBe("https://***@h/ ftp://***@h/ s://u\tv@h/ https://***@h/\n");
  expect(Buffer.from(u.out, "latin1").toString("utf8")).toBe("https://a\u00a0b:t@h/ ftp://x\u2003y@h/ s://u\tv@h/ https://***@h/\n");
});

test("redactPublish refuses as the bash refuses: sed's own refusal and status for a HOME no BRE can hold, and HOME unset before any spawn", () => {
  for (const home of ["", "/Users/a|b", "/Users/a\\"]) {
    const r = same("x\n", { ...C, HOME: home });
    expect(r.rc).not.toBe(0);
    expect(r.err).toMatch(/^sed: /);
  }
  const bash = bashSide(Buffer.from("x\n"), { ...C, HOME: undefined });
  expect(bash.rc).toBe(1);
  expect(bash.err).toContain("HOME: unbound variable");
  expect(tsSide(Buffer.from("x\n"), { ...C, HOME: undefined })).toEqual({ out: "", err: "", rc: 99 });
});

function cksum(bytes: Uint8Array): number {
  const r = Bun.spawnSync(["/usr/bin/cksum"], { stdin: bytes, stdout: "pipe", stderr: "pipe" });
  expect(r.exitCode).toBe(0);
  return Number(r.stdout.toString().split(/\s+/)[0]);
}

test("cksumPosix is /usr/bin/cksum's CRC bit for bit, over every length class of the appended length bytes", () => {
  expect(cksumPosix(Buffer.from("LGTM, tests pass"))).toBe(3103439218);
  expect(cksumPosix(new Uint8Array(0))).toBe(4294967295);
  const every = Buffer.alloc(256);
  for (let i = 0; i < 256; i++) every[i] = i;
  const big = Buffer.alloc(70000);
  for (let i = 0; i < big.length; i++) big[i] = (i * 7919 + 13) & 0xff;
  const bodies: Uint8Array[] = [
    Buffer.from(""),
    Buffer.from("LGTM, tests pass"),
    Buffer.from("LGTM, tests pass\n"),
    Buffer.from("a"),
    Buffer.from("\n"),
    Buffer.from("\0"),
    Buffer.from("line1\nline2"),
    Buffer.from("line1\nline2\n\n"),
    Buffer.from("failed at ~/lab/run.log after push to https://***@github.com/a/b"),
    Buffer.from("caf\u00e9 \u2014 na\u00efve \u{1f680} \u4e2d\u6587", "utf8"),
    Buffer.from([0xff, 0xfe, 0x80, 0x00, 0x7f]),
    every,
    every.subarray(0, 255),
    Buffer.alloc(255, 0x61),
    Buffer.alloc(256, 0x61),
    Buffer.alloc(65535, 0x00),
    Buffer.alloc(65536, 0xff),
    big,
    big.subarray(0, 65537),
    Buffer.from("x".repeat(1000) + "\n".repeat(3)),
    Buffer.from("Actually, one nit to fix"),
  ];
  for (const b of bodies) expect([b.length, cksumPosix(b)]).toEqual([b.length, cksum(b)]);
});
