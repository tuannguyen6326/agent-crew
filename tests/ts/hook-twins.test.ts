// hook-twins.test.ts - the hook twins of src/lib.ts held to the bash idioms a
// harness hook reads with, each run by /bin/bash over the same stdin bytes:
// hookPayload against `payload="$(cat 2>/dev/null || true)"`, hookJq against
// `$(jq -r <filter> <<<"$payload" 2>/dev/null || true)` and hookCapture
// against `$(<cmd> 2>/dev/null || true)`, and hookTrace against
// ac_hook_trace itself. Each ported hook's own contract is its tests/sh
// suite, whose differential leg runs the frozen bash original.
//
// DISPUTED: the implementation of each read (the bash idiom vs src/lib.ts's hook twins)
// HELD-CONSTANT: the stdin bytes, the filter or command, PATH (the host's jq and cat; the no-jq rows drop jq alone; the trace rows a date stub first), LC_ALL=C, HOME, the cwd (a scratch dir), the trace rows' AC_HOME seeded alike per side
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-hook-twins-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

const TWIN = join(W, "twin.ts");
writeFileSync(
  TWIN,
  `import { writeSync } from "node:fs";
import { hookCapture, hookJq, hookPayload } from ${JSON.stringify(LIB)};
const [mode = "", arg = ""] = process.argv.slice(2);
const out = mode === "payload" ? hookPayload() : mode === "jq" ? hookJq(arg, hookPayload()) : hookCapture(mode === "sh" ? ["/bin/sh", "-c", arg] : [arg]);
writeSync(1, Buffer.from(out, "latin1"));
`,
);
const BASH: Record<string, string> = {
  payload: 'payload="$(cat 2>/dev/null || true)"; printf %s "$payload"',
  jq: 'payload="$(cat 2>/dev/null || true)"; x="$(jq -r "$1" <<<"$payload" 2>/dev/null || true)"; printf %s "$x"',
  sh: 'x="$(/bin/sh -c "$1" 2>/dev/null || true)"; printf %s "$x"',
  argv: 'x="$("$1" 2>/dev/null || true)"; printf %s "$x"',
};

const NOJQ = join(W, "nojq");
mkdirSync(NOJQ);
symlinkSync(Bun.which("cat")!, join(NOJQ, "cat"));
const HOSTPATH = process.env.PATH ?? "";

function both(mode: string, arg: string, stdin: Buffer, path = HOSTPATH): { bash: Buffer; twin: Buffer } {
  const env = { PATH: path, LC_ALL: "C", HOME: W };
  const b = Bun.spawnSync(["/bin/bash", "-c", BASH[mode]!, "bash", arg], { stdin, stdout: "pipe", stderr: "pipe", cwd: W, env });
  const t = Bun.spawnSync([process.execPath, "--no-env-file", TWIN, mode, arg], { stdin, stdout: "pipe", stderr: "pipe", cwd: W, env });
  expect(b.exitCode).toBe(0);
  expect(t.exitCode).toBe(0);
  return { bash: Buffer.from(b.stdout), twin: Buffer.from(t.stdout) };
}

const big = Buffer.concat([Buffer.from('{"pad":"'), Buffer.alloc(200000, "x"), Buffer.from('","tool_name":"Task"}\n')]);
const PAYLOADS: Buffer[] = [
  Buffer.from('{"tool_name":"Task"}'),
  Buffer.from('{"tool_name":"Task"}\n\n\n'),
  Buffer.from("\n\n"),
  Buffer.alloc(0),
  Buffer.from("  "),
  Buffer.from("not json"),
  Buffer.from('{"tool_name":"Ta\0sk"}'),
  Buffer.from('{"tool_name":"Ta\\u0000sk","tool_input":{"file_path":"a\\u0000b"}}'),
  Buffer.from('{"tool_name":"Task"} garbage'),
  Buffer.from('{"tool_name":"Read"}{"tool_name":"Agent"}'),
  Buffer.from('{"tool_name":{"Agent":1},"tool_input":{"file_path":["records/backlog.md"]}}'),
  Buffer.from('{"tool_name":"\xe9Agent","tool_input":{"file_path":"r\xe9cords/x\\n\\n"}}', "latin1"),
  Buffer.from('{"tool_name":"Edit","tool_input":{"file_path":"records/backlog.md\\n"}}'),
  Buffer.from('{"tool_name":"Edit","tool_input":"flat"}'),
  big,
];

test("hookPayload reads stdin as the substitution did", () => {
  for (const p of PAYLOADS) {
    const r = both("payload", "", p);
    expect(r.twin).toEqual(r.bash);
  }
});

test("hookJq answers what jq printed over the here-string, whatever its status", () => {
  for (const filter of [".tool_name // empty", ".tool_input.file_path // empty", ".tool_input.notebook_path // empty"])
    for (const p of PAYLOADS) {
      const r = both("jq", filter, p);
      expect(r.twin).toEqual(r.bash);
    }
  // A partial value before a parse error still counts: the rows are not vacuous.
  expect(both("jq", ".tool_name // empty", Buffer.from('{"tool_name":"Task"} garbage')).twin.toString()).toBe("Task");
});

test("hookJq with no jq on PATH reads empty, as the bash did", () => {
  for (const p of PAYLOADS.slice(0, 3)) {
    const r = both("jq", ".tool_name // empty", p, NOJQ);
    expect(r.twin).toEqual(r.bash);
    expect(r.twin.length).toBe(0);
  }
});

test("hookCapture keeps the child's stdout whatever its status, and nothing of a child that cannot start", () => {
  for (const cmd of ["printf 'a\\000b\\n\\n'", "printf x; exit 3", "echo out; echo err >&2", "printf '\\351\\n\\n'", "kill -TERM $$", "no-such-command-anywhere"]) {
    const r = both("sh", cmd, Buffer.alloc(0));
    expect(r.twin).toEqual(r.bash);
  }
  for (const missing of [join(W, "no-such-binary"), join(W, "nojq")]) {
    const r = both("argv", missing, Buffer.alloc(0));
    expect(r.twin).toEqual(r.bash);
    expect(r.twin.length).toBe(0);
  }
});

// hookTrace against ac_hook_trace itself (bin/ac-lib.sh) under a `set -uo
// pipefail` bash, as the Stop hooks source it: each side its own home and the
// same date stub, the line count's arithmetic followed past the call - an
// identifier ends the bash 0 there, a malformed number discards the command
// the call stood in. The bash side is a script FILE with the call on a line of
// its own, as in both hooks: under `bash -c` bash 3.2 dies 127 from that
// identifier instead, and a discard drops the whole -c line.
const TRACE = join(W, "trace.ts");
writeFileSync(
  TRACE,
  `import { writeSync } from "node:fs";
import { hookTrace } from ${JSON.stringify(LIB)};
let out = "";
try {
  hookTrace(process.argv[2]!, Buffer.from(process.argv[3]!, "utf8").toString("latin1"));
  out = "went on\\n";
} catch (e) {
  const code = (e as { code?: string }).code;
  if (code === "EUNBOUND") process.exit(0);
  if (code !== "EARITH") throw e;
}
writeSync(1, out + "next\\n");
`,
);
const TRACE_BASH = join(W, "trace.sh");
writeFileSync(TRACE_BASH, 'set -uo pipefail\n. "$1/bin/ac-lib.sh"\n{ ac_hook_trace "$2" "$3"; echo "went on"; }\necho next\n');
const DATESTUB = join(W, "datestub");
mkdirSync(DATESTUB);
writeFileSync(join(DATESTUB, "date"), '#!/bin/sh\nprintf "2026-10-10T00:00:00Z\\n"\n', { mode: 0o755 });

type TraceSide = { status: number | null; out: string; log: string | null; state: string[] };
function traceSide(cmd: string[], home: string, env: Record<string, string>): TraceSide {
  const r = Bun.spawnSync(cmd, { stdin: "ignore", stdout: "pipe", stderr: "pipe", cwd: W, env: { PATH: `${DATESTUB}:${HOSTPATH}`, LC_ALL: "C", HOME: W, AC_HOME: home, ...env } });
  const f = join(home, "state", ".stop-hooks.log");
  let log: string | null = null;
  try {
    log = readFileSync(f, "latin1");
  } catch {}
  let state: string[] = [];
  try {
    state = readdirSync(join(home, "state")).map((n) => n.replace(/\.tmp\.[0-9]+(\.[0-9]+)?$/, ".tmp.PID")).sort();
  } catch {}
  return { status: r.exitCode, out: r.stdout.toString(), log, state };
}
function traceBoth(detail: string, env: Record<string, string>, seed: (home: string) => void = () => {}): { bash: TraceSide; twin: TraceSide } {
  const sides = ["bash", "twin"].map((s) => {
    const home = join(W, `trace-${s}`);
    rmSync(home, { recursive: true, force: true });
    mkdirSync(home);
    seed(home);
    return home;
  });
  return {
    bash: traceSide(["/bin/bash", TRACE_BASH, ROOT, "watch-autoarm", detail], sides[0]!, env),
    twin: traceSide([process.execPath, "--no-env-file", TRACE, "watch-autoarm", detail], sides[1]!, env),
  };
}
const oldLog = (n: number) => (home: string): void => {
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", ".stop-hooks.log"), Array.from({ length: n }, (_, i) => `old ${i}\n`).join(""));
};

test("hookTrace appends the line ac_hook_trace appends, minting state/", () => {
  for (const detail of ["verdict=armed reason=loop-start scope=fleet owed=yes", "detail=aéb %s \\n", ""]) {
    const r = traceBoth(detail, {});
    expect(r.twin).toEqual(r.bash);
    expect(r.twin.log).toBe(`2026-10-10T00:00:00Z hook=watch-autoarm ${Buffer.from(detail, "utf8").toString("latin1")}\n`);
  }
});

test("hookTrace trims past keep*2 lines as the bash did", () => {
  for (const keep of ["2", "3", "0", "", "010", "0x1", " 2 "]) {
    const r = traceBoth("x", { AC_STOPHOOK_LOG_KEEP: keep }, oldLog(5));
    expect(r.twin).toEqual(r.bash);
  }
  // A keep tail(1) refuses leaves the temp on both sides, the log untrimmed.
  const r = traceBoth("x", { AC_STOPHOOK_LOG_KEEP: "2#1" }, oldLog(5));
  expect(r.twin).toEqual(r.bash);
  expect(r.twin.state).toEqual([".stop-hooks.log", ".stop-hooks.log.tmp.PID"]);
});

test("hookTrace's keep arithmetic throws what ended or discarded the bash caller", () => {
  for (const keep of ["abc", "1 2", "09", "2#9"]) {
    const r = traceBoth("x", { AC_STOPHOOK_LOG_KEEP: keep }, oldLog(1));
    expect(r.twin).toEqual(r.bash);
    expect(r.twin.log).toBe("old 0\n2026-10-10T00:00:00Z hook=watch-autoarm x\n");
  }
  expect(traceBoth("x", { AC_STOPHOOK_LOG_KEEP: "abc" }).twin.out).toBe("");
  expect(traceBoth("x", { AC_STOPHOOK_LOG_KEEP: "1 2" }).twin.out).toBe("next\n");
});

test("hookTrace writes nothing without a home cd can enter", () => {
  for (const home of ["", join(W, "no-such-home")]) {
    const b = Bun.spawnSync(["/bin/bash", TRACE_BASH, ROOT, "watch-autoarm", "x"], { stdout: "pipe", stderr: "pipe", cwd: W, env: { PATH: `${DATESTUB}:${HOSTPATH}`, LC_ALL: "C", HOME: W, AC_HOME: home } });
    const t = Bun.spawnSync([process.execPath, "--no-env-file", TRACE, "watch-autoarm", "x"], { stdout: "pipe", stderr: "pipe", cwd: W, env: { PATH: `${DATESTUB}:${HOSTPATH}`, LC_ALL: "C", HOME: W, AC_HOME: home } });
    expect(t.stdout.toString()).toBe(b.stdout.toString());
    expect(t.stderr.toString()).toBe("");
  }
  // A log that is a directory takes no line; the bash's redirection complaint
  // is its own (SHELL-OWN STDERR) and the twin's stderr stays empty.
  const r = traceBoth("x", {}, (home) => mkdirSync(join(home, "state", ".stop-hooks.log"), { recursive: true }));
  expect(r.twin.out).toBe(r.bash.out);
  expect(r.twin.state).toEqual(r.bash.state);
});
