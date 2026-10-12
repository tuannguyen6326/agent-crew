// send.test.ts - what src/send.ts brought into src/lib.ts, held to the bash
// it twins in the live bin/ac-lib.sh: bareMarkerVerbs against
// ac_bare_marker_verbs (tokens, the dedupe, the [[:space:]] class under C and
// UTF-8, the verb list read from AC_CAPTAIN_RE), and arrivalWait against
// ac_arrival_wait as ac-send.sh ran it under `set -euo pipefail` (the three
// verdicts, the arrived text handed back, the transcript glob and its root's
// rungs, the read cadence, the jq program lifted byte for byte). The CLI
// contract itself is tests/sh/ac-send.test.sh's, whose differential leg runs
// the frozen bash original beside the shim.
//
// DISPUTED: the implementation of the two helpers (bin/ac-lib.sh vs src/lib.ts)
// HELD-CONSTANT: per row one bash and one bun child with the same argv, env (PATH with a logging sleep first, LC_ALL, AC_CAPTAIN_RE or the transcript knobs as the row names them) and stdin (/dev/null); stdout, stderr, the verdict and the sleep log compared.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-send-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

const STUB = join(W, "stub");
mkdirSync(STUB);
writeFileSync(join(STUB, "sleep"), '#!/bin/sh\nprintf "sleep %s\\n" "$*" >>"$SLEEP_LOG"\nexec /bin/sleep "$@"\n', { mode: 0o755 });

type Run = { code: number | null; out: string; err: string };

function bash(script: string, env: Record<string, string>, args: string[] = []): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", `set -euo pipefail; . "$0/ac-lib.sh"; ${script}`, BIN, ...args], {
    env: { PATH: `${STUB}:${process.env.PATH!}`, LC_ALL: "C", HOME: W, ...env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

function twin(body: string, env: Record<string, string>): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const say = (s) => process.stdout.write(Buffer.from(String(s), "latin1")); ${body}`],
    { cwd: ROOT, env: { PATH: `${STUB}:${process.env.PATH!}`, LC_ALL: "C", HOME: W, ...env }, stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 30000 },
  );
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

let n = 0;
function dir(name: string): string {
  const d = join(W, `${name}${n++}`);
  mkdirSync(d, { recursive: true });
  return d;
}

const TEXTS = [
  "print done: or blocked: when you stop",
  "nothing to see here, all done",
  "blocked: x and done: y then done: z",
  "line one\nfailed:",
  "print `done:` now",
  "that is a real needs-decision",
  "done:\tx",
  "done:\rx",
  "paused: x and paused: y",
  "merged:",
  "checks-passed: PR up, needs-decision: none",
  "ack: and nak: x",
  "Done: X",
  "a:b done:done: c",
  "",
];

test("bareMarkerVerbs is ac_bare_marker_verbs over every token shape, under C and UTF-8, and every AC_CAPTAIN_RE shape", () => {
  const res = ["", "^(ack|nak):", "no group here", "(ack|n_k):", "^(a b):", "(x|y):\n(nak):", "(ack|nak):|(done|merged):", "^[^x]*(done|blocked):([[:space:]]|$)"];
  for (const loc of ["C", "en_US.UTF-8"])
    for (const re of res) {
      const env: Record<string, string> = { LC_ALL: loc, ...(re ? { AC_CAPTAIN_RE: re } : {}) };
      const want = bash('for t in "$@"; do if v="$(ac_bare_marker_verbs "$t")"; then printf "%s|0\\n--\\n" "$v"; else printf "|1\\n--\\n"; fi; done', env, TEXTS);
      const got = twin(`for (const t of ${JSON.stringify(TEXTS)}) { const v = L.bareMarkerVerbs(t); say(v === null ? "|1\\n--\\n" : v + "|0\\n--\\n"); }`, env);
      expect({ loc, re, out: got.out, err: got.err }).toEqual({ loc, re, out: want.out, err: want.err });
    }
  expect(twin(`say(L.bareMarkerVerbs("paused:\\u00a0x and paused: y"))`, { LC_ALL: "en_US.UTF-8" }).out).toBe("paused:\xc2\xa0\npaused:");
  expect(twin(`say(L.bareMarkerVerbs("blocked: x and done: y then done: z"))`, {}).out).toBe("blocked:\ndone:");
}, 30000);

test("bareMarkerVerbs reads a verb list off its text as none under every locale, where bash 3.2's collating range let an uppercase verb through under UTF-8 (named)", () => {
  const env = { LC_ALL: "en_US.UTF-8", AC_CAPTAIN_RE: "^(Done|x):" };
  expect(bash('if v="$(ac_bare_marker_verbs "$1")"; then printf "%s" "$v"; else printf none; fi', env, ["Done: X"]).out).toBe("Done:");
  expect(twin('const v = L.bareMarkerVerbs("Done: X"); say(v === null ? "none" : v)', env).out).toBe("none");
  expect(bash('if v="$(ac_bare_marker_verbs "$1")"; then printf "%s" "$v"; else printf none; fi', { AC_CAPTAIN_RE: "^(Done|x):" }, ["Done: X"]).out).toBe("none");
});

test("arrivalWait spawns ac_claude_last_typed_turn's jq program byte for byte", () => {
  const lib = readFileSync(join(BIN, "ac-lib.sh"), "latin1");
  const fn = lib.slice(lib.indexOf("ac_claude_last_typed_turn() {"));
  const start = fn.indexOf("jq -rs '") + "jq -rs '".length;
  const ts = readFileSync(LIB, "latin1");
  const tstart = ts.indexOf("const LAST_TYPED_TURN = `") + "const LAST_TYPED_TURN = `".length;
  expect(ts.slice(tstart, ts.indexOf("`;", tstart))).toBe(fn.slice(start, fn.indexOf("'", start)));
});

const turn = (content: unknown): string =>
  `${JSON.stringify({ type: "user", promptSource: "typed", origin: { kind: "human" }, message: { role: "user", content } })}\n`;

test("arrivalWait is ac_arrival_wait: its verdict, the arrived text it hands back, and the reads it paces, on every transcript shape", () => {
  const root = dir("root");
  const at = (p: string, body: string): void => {
    mkdirSync(join(root, p, ".."), { recursive: true });
    writeFileSync(join(root, p), body);
  };
  at("proj/s-ok.jsonl", turn("old line") + turn("exact text"));
  at("proj/s-lf.jsonl", turn("ends\n\n"));
  at("proj/s-cut.jsonl", turn(" the tail"));
  at("proj/s-two.jsonl", turn("two"));
  at("proj2/s-two.jsonl", turn("two"));
  at("proj/s-bad.jsonl", turn("bad") + "{not json\n");
  at("proj/s-tool.jsonl", turn([{ type: "tool_result" }]));
  at("proj/s-nul.jsonl", turn("a\u0000b"));
  at("proj/s-empty.jsonl", turn(""));
  at("proj/s-dark.jsonl", turn("dark"));
  at(".hidden/s-dark2.jsonl", turn("hidden"));
  at("proj/s*.jsonl", turn("literal star"));
  writeFileSync(join(root, "plainfile"), "");
  symlinkSync("nowhere", join(root, "proj", "s-dangle.jsonl"));
  const long = Array.from({ length: 250 }, (_, i) => turn(`line ${i}`)).join("");
  at("proj/s-long.jsonl", turn("far back") + long);
  at("proj/s-oldbad.jsonl", "{not json\n" + long);
  const rows: [string, string][] = [
    ["s-ok", "exact text"],
    ["s-ok", "exact text\n\n"],
    ["s-ok", "old line"],
    ["s-lf", "ends"],
    ["s-cut", "the head and the tail"],
    ["", "anything"],
    ["s-none", "anything"],
    ["s-two", "two"],
    ["s-bad", "bad"],
    ["s-tool", "x"],
    ["s-nul", "ab"],
    ["s-empty", "x"],
    ["s-dark2", "hidden"],
    ["s*", "literal star"],
    ["s-dangle", "x"],
    ["s-long", "line 249"],
    ["s-long", "far back"],
    ["s-oldbad", "line 249"],
  ];
  for (const [sid, text] of rows) {
    const env = { AC_CLAUDE_TRANSCRIPT_ROOT: root, AC_SEND_SETTLE: "0", SLEEP_LOG: join(W, `sleep-b-${n}`) };
    const want = bash('rc=0; ac_arrival_wait "$1" "$2" || rc=$?; printf "%s|%s" "$rc" "$AC_ARRIVAL_LAST"', env, [sid, text]);
    const tenv = { ...env, SLEEP_LOG: join(W, `sleep-t-${n++}`) };
    const got = twin(`const a = L.arrivalWait(${JSON.stringify(sid)}, ${JSON.stringify(text)}); say(a.status + "|" + a.last)`, tenv);
    const sleeps = (f: string): string => {
      try {
        return readFileSync(f, "latin1");
      } catch {
        return "";
      }
    };
    expect({ sid, text, out: got.out, err: got.err, sleeps: sleeps(tenv.SLEEP_LOG) }).toEqual({ sid, text, out: want.out, err: want.err, sleeps: sleeps(env.SLEEP_LOG) });
  }
  expect(twin('const a = L.arrivalWait("s-cut", "the head and the tail"); say(a.status + "|" + a.last)', { AC_CLAUDE_TRANSCRIPT_ROOT: root, AC_SEND_SETTLE: "0", SLEEP_LOG: join(W, "x") }).out).toBe("1| the tail");
}, 30000);

test("arrivalWait's transcript root: AC_CLAUDE_TRANSCRIPT_ROOT, else CLAUDE_CONFIG_DIR/projects, else HOME/.claude/projects, as ac_claude_transcript_root's ladder", () => {
  const h = dir("home");
  const cfg = dir("cfg");
  mkdirSync(join(h, ".claude", "projects", "p"), { recursive: true });
  mkdirSync(join(cfg, "projects", "p"), { recursive: true });
  writeFileSync(join(h, ".claude", "projects", "p", "s1.jsonl"), turn("from home"));
  writeFileSync(join(cfg, "projects", "p", "s1.jsonl"), turn("from cfg"));
  for (const env of [
    { HOME: h },
    { HOME: h, CLAUDE_CONFIG_DIR: cfg },
    { HOME: h, CLAUDE_CONFIG_DIR: cfg, AC_CLAUDE_TRANSCRIPT_ROOT: join(W, "nowhere") },
    { HOME: h, CLAUDE_CONFIG_DIR: "", AC_CLAUDE_TRANSCRIPT_ROOT: "" },
  ]) {
    for (const text of ["from home", "from cfg"]) {
      const e = { ...env, AC_SEND_SETTLE: "0", SLEEP_LOG: join(W, "ladder") };
      const want = bash('rc=0; ac_arrival_wait s1 "$1" || rc=$?; printf "%s|%s" "$rc" "$AC_ARRIVAL_LAST"', e, [text]);
      const got = twin(`const a = L.arrivalWait("s1", ${JSON.stringify(text)}); say(a.status + "|" + a.last)`, e);
      expect({ env, text, out: got.out }).toEqual({ env, text, out: want.out });
    }
  }
}, 30000);
