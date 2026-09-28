// pane-agent.test.ts - Bun unit tests for src/pane-agent.ts, the JSON readers
// and writers bin/ac-pane-agent.sh and ac_transcript_final_epoch start. Every
// expected string is what python3's json module (3.14.7) produced for the same
// input: the user's files were written in that serialization, so it is the
// contract. Run through tests/sh/src.test.sh.

import { test, expect, afterAll } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decodeStrict, dumps, hasFinalText, isoEpoch, loads, mergeStopHook, pidGone, seedTrust, strip, truthy, wrapTranscript,
} from "../../src/pane-agent.ts";

const MODULE = join(import.meta.dir, "..", "..", "src", "pane-agent.ts");
const made: string[] = [];
function tempDir(): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), "pane-agent-ts-")));
  made.push(d);
  return d;
}
afterAll(() => made.forEach((d) => rmSync(d, { recursive: true, force: true })));

function cli(caller: string, args: string[], opts: { stdin?: Uint8Array | string; env?: Record<string, string> } = {}) {
  const p = Bun.spawnSync([process.execPath, "--no-env-file", MODULE, caller, ...args], {
    stdin: opts.stdin === undefined ? "ignore" : Buffer.from(opts.stdin as string),
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "", ...opts.env },
  });
  return { code: p.exitCode, stdout: p.stdout, stderr: p.stderr.toString() };
}

test("dumps reproduces python's compact and indent=2 serialization", () => {
  const cases: [string, string, string][] = [
    ['{"b":1,"10":2,"a":3,"2":4}', '{"b": 1, "10": 2, "a": 3, "2": 4}', '{\n  "b": 1,\n  "10": 2,\n  "a": 3,\n  "2": 4\n}'],
    [
      "[1.0, -0.0, 0.00001, 0.0001, 1e16, 1e15, 123456789012345678901234567890, -0, 1E400, -1e400, 5e-324, 1.5E+3, 0e0, 0.1, 1e22, 1e-7, 123.456, 9999999999999998.0, 1.7976931348623157e308, 100000000000000001]",
      "[1.0, -0.0, 1e-05, 0.0001, 1e+16, 1000000000000000.0, 123456789012345678901234567890, 0, Infinity, -Infinity, 5e-324, 1500.0, 0.0, 0.1, 1e+22, 1e-07, 123.456, 9999999999999998.0, 1.7976931348623157e+308, 100000000000000001]",
      "[\n  1.0,\n  -0.0,\n  1e-05,\n  0.0001,\n  1e+16,\n  1000000000000000.0,\n  123456789012345678901234567890,\n  0,\n  Infinity,\n  -Infinity,\n  5e-324,\n  1500.0,\n  0.0,\n  0.1,\n  1e+22,\n  1e-07,\n  123.456,\n  9999999999999998.0,\n  1.7976931348623157e+308,\n  100000000000000001\n]",
    ],
    ["[NaN, Infinity, -Infinity]", "[NaN, Infinity, -Infinity]", "[\n  NaN,\n  Infinity,\n  -Infinity\n]"],
    [
      '"caf\\u00e9 \\ud83d\\ude00 \\u2028 \\" \\\\ \\/ \\b\\f\\n\\r\\t \\u0000 \\u007f \\ud800 \\uDC00x"',
      '"caf\\u00e9 \\ud83d\\ude00 \\u2028 \\" \\\\ / \\b\\f\\n\\r\\t \\u0000 \\u007f \\ud800 \\udc00x"',
      '"caf\\u00e9 \\ud83d\\ude00 \\u2028 \\" \\\\ / \\b\\f\\n\\r\\t \\u0000 \\u007f \\ud800 \\udc00x"',
    ],
    ['"caf\u{e9} \u{1F600} \u{2028}"', '"caf\\u00e9 \\ud83d\\ude00 \\u2028"', '"caf\\u00e9 \\ud83d\\ude00 \\u2028"'],
    ['{"a":1,"b":2,"a":3}', '{"a": 3, "b": 2}', '{\n  "a": 3,\n  "b": 2\n}'],
    [
      ' \t\n\r{"k" : [ ] , "e" : { } , "n" : null , "t" : true , "f" : false } \n',
      '{"k": [], "e": {}, "n": null, "t": true, "f": false}',
      '{\n  "k": [],\n  "e": {},\n  "n": null,\n  "t": true,\n  "f": false\n}',
    ],
    [
      '{"x":{"y":[1,{"z":[]},{}],"w":{}}}',
      '{"x": {"y": [1, {"z": []}, {}], "w": {}}}',
      '{\n  "x": {\n    "y": [\n      1,\n      {\n        "z": []\n      },\n      {}\n    ],\n    "w": {}\n  }\n}',
    ],
  ];
  for (const [doc, compact, indented] of cases) {
    expect(dumps(loads(doc))).toBe(compact);
    expect(dumps(loads(doc), 2)).toBe(indented);
  }
});

test("loads refuses exactly what python's json module refuses", () => {
  const bad = ["\u{feff}{}", "[1,]", "01", "1.", "-", "", " ", '"a\x01"', "'a'", "nan", "-NaN", '{"a"}', "{} x", "{,}",
    '"\\x"', '"\\u12"', "[1 2]", '{"a":1,}', "1e", ".5", "+1", '"\\ud83d', "tru", "NaNx", "[01]", "-Infinityx", "1E+", "0x10"];
  for (const b of bad) expect(() => loads(b)).toThrow();
  expect(dumps(loads('"\x7f"'))).toBe('"\\u007f"');
});

test("truthy is python's truthiness", () => {
  for (const v of [null, false, 0n, 0, -0, "", [], new Map()]) expect(truthy(v)).toBe(false);
  for (const v of [true, 1n, NaN, 0.5, "x", [0], new Map([["a", null]])]) expect(truthy(v)).toBe(true);
});

test("strip removes python's whitespace set and nothing else", () => {
  expect(strip("\x1c\x1d\x1e\x1f\x85\xa0\u{1680}\u{2000}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000} \t\n\v\f\rx\t")).toBe("x");
  expect(strip("\u{feff}x\u{200b}")).toBe("\u{feff}x\u{200b}");
});

test("decodeStrict keeps a BOM and refuses any byte that is not UTF-8", () => {
  expect(decodeStrict(new Uint8Array([0xef, 0xbb, 0xbf, 0x61]))).toBe("\u{feff}a");
  expect(() => decodeStrict(new Uint8Array([0x61, 0xff]))).toThrow();
  expect(() => decodeStrict(new Uint8Array([0xed, 0xa0, 0x80]))).toThrow();
});

test("seedTrust sets both flags in place, and leaves a trusted entry alone", () => {
  const d = loads('{"projects":{"/w":{"hasCompletedProjectOnboarding":[],"keep":"x"}},"z":1}');
  expect(seedTrust(d, "/w")).toBe(true);
  expect(dumps(d)).toBe('{"projects": {"/w": {"hasCompletedProjectOnboarding": true, "keep": "x", "hasTrustDialogAccepted": true}}, "z": 1}');
  const fresh = loads('{"a":1}');
  expect(seedTrust(fresh, "/w")).toBe(true);
  expect(dumps(fresh)).toBe('{"a": 1, "projects": {"/w": {"hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true}}}');
  const done = loads('{"projects":{"/w":{"hasTrustDialogAccepted":"no","hasCompletedProjectOnboarding":1}}}');
  expect(seedTrust(done, "/w")).toBe(false);
  for (const shape of ["[1]", '{"projects":null}', '{"projects":{"/w":"x"}}', '{"projects":[]}'])
    expect(() => seedTrust(loads(shape), "/w")).toThrow();
});

test("mergeStopHook drops only our own dead hooks and appends ours last", () => {
  const cmd = (c: string) => `{"hooks":[{"type":"command","command":${JSON.stringify(c)}}]}`;
  const groups = [
    cmd("touch '/s/ac-pane-turnend.a-b.7'"),
    cmd("touch '/s/ac-pane-turnend.a-b.7'\n"),
    cmd("touch 'ac-pane-turnend.a-b.7'"),
    cmd("touch '/s\r/ac-pane-turnend.a-b.7'"),
    cmd("touch '/s/ac-pane-turnend.a/b.7'"),
    cmd("touch '/s\n/ac-pane-turnend.a-b.7'"),
    cmd("touch '/s/ac-pane-turnend.a-b.7' "),
    cmd("touch '/s/ac-pane-turnend.a-b.8'"),
    '{"hooks":[{"type":"command","command":7}]}',
    '{"hooks":[{"type":"command"}]}',
    `{"hooks":[{"command":"touch '/s/ac-pane-turnend.a-b.7'"},{"command":"x"}]}`,
    '"not a group"',
    '{"hooks":["touch"]}',
  ];
  const doc = loads(`{"a":1,"hooks":{"x":2,"Stop":[${groups.join(",")}]},"z":3}`);
  const out = mergeStopHook(doc, "/m/ac-pane-turnend.w-1.9", (pid) => pid === 7n);
  expect(dumps(out)).toBe(
    '{"a": 1, "hooks": {"x": 2, "Stop": [' +
      '{"hooks": [{"type": "command", "command": "touch \'/s/ac-pane-turnend.a/b.7\'"}]}, ' +
      '{"hooks": [{"type": "command", "command": "touch \'/s\\n/ac-pane-turnend.a-b.7\'"}]}, ' +
      '{"hooks": [{"type": "command", "command": "touch \'/s/ac-pane-turnend.a-b.7\' "}]}, ' +
      '{"hooks": [{"type": "command", "command": "touch \'/s/ac-pane-turnend.a-b.8\'"}]}, ' +
      '{"hooks": [{"type": "command", "command": 7}]}, ' +
      '{"hooks": [{"type": "command"}]}, ' +
      '{"hooks": [{"command": "touch \'/s/ac-pane-turnend.a-b.7\'"}, {"command": "x"}]}, ' +
      '"not a group", ' +
      '{"hooks": ["touch"]}, ' +
      '{"hooks": [{"type": "command", "command": "touch \'/m/ac-pane-turnend.w-1.9\'"}]}]}, "z": 3}',
  );
  const soft = '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "touch \'/m\'"}]}]}}';
  for (const start of [undefined, loads("[1]"), loads('"x"')]) expect(dumps(mergeStopHook(start, "/m", () => true))).toBe(soft);
  expect(dumps(mergeStopHook(loads('{"a":1,"hooks":[1],"z":2}'), "/m", () => true))).toBe(
    '{"a": 1, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "touch \'/m\'"}]}]}, "z": 2}',
  );
  expect(dumps(mergeStopHook(loads('{"hooks":{"Stop":{"a":1},"y":1}}'), "/m", () => true))).toBe(
    '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "touch \'/m\'"}]}], "y": 1}}',
  );
});

test("pidGone: only a pid that answers no-such-process is gone", () => {
  expect(pidGone(99999999n)).toBe(true);
  expect(pidGone(BigInt(process.pid))).toBe(false);
  expect(pidGone(1n)).toBe(false);
  expect(pidGone(2147483648n)).toBe(false);
});

test("wrapTranscript writes python's one-message line", () => {
  expect(wrapTranscript("")).toBe('{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": ""}]}}\n');
  expect(wrapTranscript('\u{feff}caf\u{e9} \u{1F600} "q" \\ /\t\r\n\x7f\x00')).toBe(
    '{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "\\ufeffcaf\\u00e9 \\ud83d\\ude00 \\"q\\" \\\\ /\\t\\r\\n\\u007f\\u0000"}]}}\n',
  );
});

test("hasFinalText: any assistant text anywhere, unless the file trips python's reader", () => {
  const text = (t: string) => `{"type":"assistant","message":{"content":[{"type":"text","text":${JSON.stringify(t)}}]}}`;
  const yes = [
    text("done"),
    `garbage\n${text("done")}`,
    `${text("done")}\n${text(" ")}`,
    `{"type":"user"}\n${text("done")}\n{"type":"assistant","message":null}`,
    `\u{a0}${text("done")}`,
    text("\u{feff}"),
    `{"type":"assistant","n":NaN,"message":{"content":[{"type":"text","text":"a"},{"type":"tool_use"},{"type":"text"}]}}`,
    `${text("done")}\r\n`,
  ];
  const no = [
    "",
    text(" \x1c\xa0"),
    `${text("done")}\n[1]`,
    "5",
    '"s"',
    "null",
    `${text("done")}\n{"type":"assistant","message":"x"}`,
    `${text("done")}\n{"type":"assistant","message":[1]}`,
    '{"type":"assistant","message":{"content":"text"}}',
    '{"type":"assistant","message":{"content":{"type":"text","text":"a"}}}',
    `${text("done")}\n{"type":"assistant","message":{"content":5}}`,
    `${text("done")}\n{"type":"assistant","message":{"content":true}}`,
    `${text("done")}\n{"type":"assistant","message":{"content":[{"type":"text","text":5}]}}`,
    `${text("done")}\n{"type":"assistant","message":{"content":[{"type":"text","text":null}]}}`,
    '{"type":"assistant",\r"message":{"content":[{"type":"text","text":"a"}]}}',
    `\u{feff}${text("done")}`,
    '{"type":"text","message":{"content":[{"type":"text","text":"a"}]}}',
  ];
  for (const t of yes) expect([t, hasFinalText(t)]).toEqual([t, true]);
  for (const t of no) expect([t, hasFinalText(t)]).toEqual([t, false]);
});

test("isoEpoch answers the calendar forms, truncating toward zero, and nothing else", () => {
  const cases: [string, number | null][] = [
    ["2026-07-20T10:00:00Z", 1784541600],
    ["2026-07-20T10:00:00.123Z", 1784541600],
    ["2026-07-20T10:00:00.9999999Z", 1784541600],
    ["2026-07-20T10:00:00,5Z", 1784541600],
    ["2026-07-20T10:00:00+07:00", 1784516400],
    ["2026-07-20T10:00:00-05:30", 1784561400],
    ["2026-07-20T10:00+07:00", 1784516400],
    ["2026-07-20 10:00:00Z", 1784541600],
    ["2026-07-20T10:00:00-00:00", 1784541600],
    ["1969-12-31T23:59:59Z", -1],
    ["1969-12-31T23:59:59.5Z", 0],
    ["1969-12-31T23:59:59.9999999Z", 0],
    ["0001-01-01T00:00:00Z", -62135596800],
    ["9999-12-31T23:59:59Z", 253402300799],
    ["2024-02-29T00:00:00Z", 1709164800],
    ["2026-02-29T00:00:00Z", null],
    ["2026-02-30T00:00:00Z", null],
    ["2026-07-20T24:00:00Z", null],
    ["2026-07-20T10:00:60Z", null],
    ["2026-07-20T10:00:00+24:00", null],
    ["0000-01-01T00:00:00Z", null],
    ["2026-07-20t10:00:00z", null],
    ["2026-07-20T10:00:00.Z", null],
    [" 2026-07-20T10:00:00Z", null],
    ["2026-07-20T10:00:00Z ", null],
    ["2026-07-20T10:00:00ZZ", null],
    ["2026-7-20T10:00:00Z", null],
    ["\u{ff12}\u{ff10}\u{ff12}\u{ff16}-07-20T10:00:00Z", null],
    ["", null],
    ["Z", null],
    ["yesterday", null],
  ];
  for (const [ts, want] of cases) expect([ts, isoEpoch(ts)]).toEqual([ts, want]);
});

test("iso-epoch reads a stamp with no offset as local time", () => {
  for (const [ts, want] of [["2026-07-20T10:00:00", "1784516400\n"], ["2026-07-20", "1784480400\n"]]) {
    const r = cli("", ["iso-epoch", ts], { env: { TZ: "Asia/Ho_Chi_Minh" } });
    expect([r.code, r.stdout.toString()]).toEqual([0, want]);
  }
  const bad = cli("", ["iso-epoch", "yesterday"]);
  expect([bad.code, bad.stdout.toString()]).toEqual([1, ""]);
});

test("wrap-transcript copies stdin, or fails with no output on bytes that are not UTF-8", () => {
  const ok = cli("", ["wrap-transcript"], { stdin: "a\r\nb" });
  expect([ok.code, ok.stdout.toString()]).toEqual([0, wrapTranscript("a\r\nb")]);
  const bad = cli("", ["wrap-transcript"], { stdin: new Uint8Array([0x61, 0xff]) as unknown as string });
  expect([bad.code, bad.stdout.length]).toEqual([1, 0]);
});

test("has-final-text answers by exit status, 1 for a file it cannot read", () => {
  const d = tempDir();
  writeFileSync(join(d, "t.jsonl"), '{"type":"assistant","message":{"content":[{"type":"text","text":"a"}]}}\n');
  writeFileSync(join(d, "bad.jsonl"), Buffer.from([0x7b, 0xff, 0x7d, 0x0a]));
  expect(cli(d, ["has-final-text", "t.jsonl"]).code).toBe(0);
  expect(cli(d, ["has-final-text", "bad.jsonl"]).code).toBe(1);
  expect(cli(d, ["has-final-text", "missing.jsonl"]).code).toBe(1);
  expect(cli("", ["has-final-text", "t.jsonl"]).code).toBe(1);
});

test("stop-hook and seed-trust publish through <file>.ac-pane-agent and a rename", () => {
  const d = tempDir();
  const settings = join(d, "settings.local.json");
  writeFileSync(settings, '{"keep":1.0}');
  chmodSync(settings, 0o600);
  writeFileSync(`${settings}.ac-pane-agent`, "stale");
  chmodSync(`${settings}.ac-pane-agent`, 0o640);
  expect(cli(d, ["stop-hook", "settings.local.json", "/m"]).code).toBe(0);
  expect(readFileSync(settings, "utf8")).toBe('{"keep": 1.0, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "touch \'/m\'"}]}]}}');
  expect(statSync(settings).mode & 0o777).toBe(0o640);
  expect(cli("", ["stop-hook", "settings.local.json", "/m"]).code).toBe(1);
  expect(cli(d, ["stop-hook", join(d, "no-such-dir", "s.json"), "/m"]).code).toBe(1);

  const home = tempDir();
  const cj = join(home, ".claude.json");
  writeFileSync(cj, '{"projects":{}}');
  expect(cli(d, ["seed-trust", "/w"], { env: { HOME: `${home}//` } }).code).toBe(0);
  expect(readFileSync(cj, "utf8")).toBe('{\n  "projects": {\n    "/w": {\n      "hasTrustDialogAccepted": true,\n      "hasCompletedProjectOnboarding": true\n    }\n  }\n}');
  expect(statSync(cj).mode & 0o777).toBe(0o666 & ~process.umask());
  rmSync(cj);
  expect(cli(d, ["seed-trust", "/w"], { env: { HOME: home } }).code).toBe(0);
  expect(() => statSync(cj)).toThrow();
  writeFileSync(cj, '{"projects":[]}');
  expect(cli(d, ["seed-trust", "/w"], { env: { HOME: home } }).code).toBe(1);
  expect(readFileSync(cj, "utf8")).toBe('{"projects":[]}');
});

test("stop-hook leaves a settings file too deep to parse as it was, never rewriting it as {}", () => {
  const d = tempDir();
  const settings = join(d, "settings.local.json");
  const deep = `{"keep":${"[".repeat(60000)}${"]".repeat(60000)}}`;
  writeFileSync(settings, deep);
  expect(cli(d, ["stop-hook", "settings.local.json", "/m"]).code).toBe(1);
  expect(readFileSync(settings, "utf8")).toBe(deep);
});
