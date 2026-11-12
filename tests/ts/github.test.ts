// github.test.ts - the two lib.ts twins src/github.ts introduced:
// redactPublish (ac_redact_publish's) held to the redaction its spec states - a
// comment PUBLISHES, so a twin that redacts less leaks an operator path or a URL
// credential to GitHub; and cksumPosix against /usr/bin/cksum, whose number
// names every `commented-pr-<n>-<cksum>` idempotence file - one bit off and
// every verdict already posted is posted again. The CLI contract itself is
// tests/sh/ac-github.test.sh's.
import { expect, test } from "bun:test";
import { join } from "node:path";
import { cksumPosix } from "../../src/lib.ts";

const LIB = join(import.meta.dir, "..", "..", "src", "lib.ts");

type Answer = { out: string; err: string; rc: number };
type Env = Record<string, string | undefined>;

function envOf(extra: Env): Record<string, string> {
  const env: Record<string, string> = { PATH: process.env.PATH! };
  for (const [k, v] of Object.entries(extra)) if (v !== undefined) env[k] = v;
  return env;
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

function redact(text: string, env: Env): Answer {
  return tsSide(Buffer.from(text, "utf8"), env);
}

const C = { LC_ALL: "C" };
const U = { LC_ALL: "en_US.UTF-8" };

test("redactPublish: HOME, then any /Users/<name> or /home/<name>, to ~, URL userinfo to ***, on every line, the rest byte-intact", () => {
  const rows: [string, string][] = [
    ["ran /Users/tester/proj/x then /Users/operator/lab/y and /home/op2/z via https://x:tok123@example.com/repo done\n", "ran ~/proj/x then ~/lab/y and ~/z via https://***@example.com/repo done\n"],
    ["failed at /Users/operator/lab/run.log after push to https://x:tok9@github.com/a/b\n", "failed at ~/lab/run.log after push to https://***@github.com/a/b\n"],
    ["line one /home/a.b-c_d/x\n\nline three https://u@h/p and ftp://a:b@c@d/e\n", "line one ~/x\n\nline three https://***@h/p and ftp://***@c@d/e\n"],
    ["no trailing newline /Users/x", "no trailing newline ~"],
    ["", ""],
    ["& \\1 \\n | ~ * [x] $ ^ stay as they are\n", "& \\1 \\n | ~ * [x] $ ^ stay as they are\n"],
    ["/Users/ /home/ ://@h/ s:///@x\n", "/Users/ /home/ ://@h/ s:///@x\n"],
  ];
  for (const loc of [C, U]) for (const [text, out] of rows) expect([loc, text, redact(text, { ...loc, HOME: "/Users/tester" })]).toEqual([loc, text, { out, err: "", rc: 0 }]);
});

test("redactPublish reads HOME as sed reads it - a BRE, `.` one character under UTF-8 and one byte under C", () => {
  for (const loc of [C, U]) {
    expect(redact("/Users/b /Users/aaab /Users/ab\n", { ...loc, HOME: "/Users/a*b" })).toEqual({ out: "~ ~ ~\n", err: "", rc: 0 });
    expect(redact("/srv/x1/y /srv/xz/y\n", { ...loc, HOME: "/srv/x[0-9]" })).toEqual({ out: "~/y /srv/xz/y\n", err: "", rc: 0 });
  }
  const dot = "at /UsersXop/k and /Users.op/j and /Users\u00e9op/m\n";
  expect(redact(dot, { ...U, HOME: "/Users.op" })).toEqual({ out: "at ~/k and ~/j and ~/m\n", err: "", rc: 0 });
  expect(redact(dot, { ...C, HOME: "/Users.op" })).toEqual({ out: `at ~/k and ~/j and ${Buffer.from("/Users\u00e9op/m\n", "utf8").toString("latin1")}`, err: "", rc: 0 });
});

test("redactPublish's userinfo class is sed's [:space:] - Unicode under UTF-8, the ASCII six under C", () => {
  const text = "https://a\u00a0b:t@h/ ftp://x\u2003y@h/ s://u\tv@h/ https://ok:tok@h/\n";
  const c = redact(text, { ...C, HOME: "/Users/tester" });
  const u = redact(text, { ...U, HOME: "/Users/tester" });
  expect(c.out).toBe("https://***@h/ ftp://***@h/ s://u\tv@h/ https://***@h/\n");
  expect(Buffer.from(u.out, "latin1").toString("utf8")).toBe("https://a\u00a0b:t@h/ ftp://x\u2003y@h/ s://u\tv@h/ https://***@h/\n");
});

test("redactPublish refuses with sed's own line and status for a HOME no BRE can hold, and throws ENOHOME for HOME unset before any spawn", () => {
  for (const loc of [C, U])
    for (const home of ["", "/Users/a|b", "/Users/a\\"]) {
      const r = redact("x\n", { ...loc, HOME: home });
      expect([loc, home, r.out, r.rc]).toEqual([loc, home, "", 1]);
      expect(r.err).toMatch(/^sed: /);
    }
  expect(redact("x\n", { ...C, HOME: undefined })).toEqual({ out: "", err: "", rc: 99 });
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
