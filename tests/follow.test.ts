// follow.test.ts - Bun unit tests for src/follow.ts's pure layer: the places
// where python's semantics differ from plain JS and a naive port would drift.
// The CLI contract stays owned by the black-box tests/ac-follow.test.sh. Run
// through tests/src.test.sh.

import { test, expect } from "bun:test";
import { ANSI, Malformed, PLAIN, clip, dumps, lines, pyStr, render, truthy } from "../src/follow.ts";

const rendered = (line: string, colors = PLAIN): string => {
  let s = "";
  render(line, colors, (x) => (s += x));
  return s;
};

test("dumps writes json.dumps(ensure_ascii=False): spaced separators, non-ASCII raw", () => {
  expect(dumps({ s: "é\t\u0001\"\\/", n: 2, ok: false, z: null, l: [1, "x"], o: {}, e: [] }))
    .toBe('{"s": "é\\t\\u0001\\"\\\\/", "n": 2, "ok": false, "z": null, "l": [1, "x"], "o": {}, "e": []}');
  expect(dumps(1e400)).toBe("Infinity");
});

test("truthy is python's: empty containers, strings and zero are false", () => {
  for (const v of [null, undefined, false, 0, "", [], {}]) expect(truthy(v)).toBe(false);
  for (const v of [true, 1, "no", [0], { a: 0 }]) expect(truthy(v)).toBe(true);
});

test("pyStr is str() for the scalars", () => {
  expect(pyStr(null)).toBe("None");
  expect(pyStr(undefined)).toBe("None");
  expect(pyStr(true)).toBe("True");
  expect(pyStr(false)).toBe("False");
  expect(pyStr(7)).toBe("7");
  expect(pyStr("s")).toBe("s");
});

test("clip counts code points and marks the rest", () => {
  const x = "x".repeat(1499);
  expect(clip(x + "😀", PLAIN)).toBe(x + "😀");
  expect(clip(x + "😀yy", PLAIN)).toBe(x + "😀...[+2 chars]");
  expect(clip("abc", ANSI, 2)).toBe("ab...\x1b[2m[+1 chars]\x1b[0m");
});

test("lines splits like python's universal newlines and drops no record", () => {
  expect(lines("a\r\nb\rc\nd")).toEqual(["a", "b", "c", "d"]);
  expect(lines("a\n\nb\n")).toEqual(["a", "", "b"]);
  expect(lines("")).toEqual([]);
});

test("render prints each record shape", () => {
  expect(rendered('{"type":"user","message":{"content":"hi"}}')).toBe("\nuser: hi\n");
  expect(rendered('{"type":"user","message":{"content":""}}')).toBe("\nuser: \n");
  expect(rendered('{"type":"assistant","message":{"content":"hi"}}')).toBe("");
  expect(rendered('{"type":"user","message":[]}')).toBe("");
  expect(rendered('{"message":{"content":{}}}')).toBe("");
  expect(rendered("not json")).toBe("");
  expect(rendered("\ufeff{}")).toBe("");
  expect(rendered('{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":[]},{"type":"text","text":1}]}}'))
    .toBe("a1");
  expect(rendered('{"message":{"content":[{"type":"tool_use"},{"type":"tool_use","name":null,"input":null}]}}'))
    .toBe("\ntool ? {}\n\ntool None null\n");
  expect(rendered('{"message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"A"},"s",{"type":"image"},{"text":"B"}]},{"type":"tool_result","is_error":{}}]}}'))
    .toBe("-> AB\n-> None\n");
});

test("render colors each part the way the terminal view does", () => {
  expect(rendered('{"type":"user","message":{"content":"hi"}}', ANSI)).toBe("\n\x1b[1muser:\x1b[0m hi\n");
  expect(rendered('{"message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}', ANSI))
    .toBe("\n\x1b[36mtool Bash\x1b[0m {}\n");
  expect(rendered('{"message":{"content":[{"type":"tool_result","content":"x","is_error":true},{"type":"tool_result","content":"y"}]}}', ANSI))
    .toBe("\x1b[31mERR x\x1b[0m\n\x1b[2m-> y\x1b[0m\n");
});

test("a record of the wrong shape is Malformed, after what was already printed", () => {
  for (const line of [
    "5",
    "null",
    '{"message":"text"}',
    '{"message":{"content":{"a":1}}}',
    '{"message":{"content":3}}',
    '{"message":{"content":[7]}}',
    '{"message":{"content":[{"type":"tool_result","content":[{"text":null}]}]}}',
  ]) expect(() => rendered(line)).toThrow(Malformed);
  let s = "";
  expect(() => render('{"message":{"content":[{"type":"text","text":"before"},7]}}', PLAIN, (x) => (s += x)))
    .toThrow(Malformed);
  expect(s).toBe("before");
});
