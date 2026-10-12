// dispatch-select.test.ts - Bun unit tests for src/dispatch-select.ts's pure
// layer: the places where a jq program's semantics differ from plain JS and a
// naive port would drift. The CLI contract itself stays owned by the
// black-box tests/sh/ac-dispatch-select.test.sh. Run through tests/sh/src.test.sh.

import { test, expect } from "bun:test";
import {
  Refusal, alt, jqText, profileLine, ruleListLines, paneListLines,
  validQaPane, validRoutedPane, duplicateLane, rrPick, qaReceipt, counterValue, childStatus,
} from "../../src/dispatch-select.ts";

test("alt treats null AND false as absent, like jq's //", () => {
  expect(alt(null, "d")).toBe("d");
  expect(alt(false, "d")).toBe("d");
  expect(alt(undefined, "d")).toBe("d");
  expect(alt("", "d")).toBe("");
  expect(alt(0, "d")).toBe(0);
});

test("jqText renders scalars the way jq -r and \\(...) do", () => {
  expect(jqText("a b")).toBe("a b");
  expect(jqText(null)).toBe("null");
  expect(jqText(true)).toBe("true");
  expect(jqText(3)).toBe("3");
  expect(jqText({ a: [1, "x"] })).toBe('{"a":[1,"x"]}');
});

test("profileLine is the TAB wire, model and effort may be empty", () => {
  expect(profileLine({ harness: "codex", model: "gpt 5 high", effort: "medium" }))
    .toBe("harness=codex\tmodel=gpt 5 high\teffort=medium");
  expect(profileLine({ harness: "grok" })).toBe("harness=grok\tmodel=\teffort=");
  expect(profileLine({ harness: "grok", model: false, effort: null })).toBe("harness=grok\tmodel=\teffort=");
});

test("profileLine refuses a profile with no usable harness, quoting it compactly", () => {
  for (const [p, shown] of [
    [{ model: "x" }, '{"model":"x"}'],
    [{ harness: "" }, '{"harness":""}'],
    [{ harness: false }, '{"harness":false}'],
    [null, "null"],
    ["claude", '"claude"'],
  ] as const) {
    expect(() => profileLine(p as any)).toThrow(new Refusal(`dispatch profile has no harness: ${shown}`));
  }
});

test("ruleListLines summarizes static and balanced rules like --list always has", () => {
  const cfg = {
    rules: [
      { when: "needs fresh web context", use: { harness: "grok" } },
      { when: "big refactor", use: [{ harness: "claude" }, { harness: "codex" }] },
      { when: "pinned", use: { harness: "codex", model: "gpt", effort: "high" } },
      { when: null, use: null },
      { when: "empty model is jq-truthy", use: { harness: "codex", model: "" } },
    ],
  };
  expect(ruleListLines(cfg)).toEqual([
    "1\tneeds fresh web context\tgrok",
    "2\tbig refactor\tclaude/codex (balanced)",
    "3\tpinned\tcodex gpt high",
    "4\tnull\t?",
    "5\tempty model is jq-truthy\tcodex ",
  ]);
  expect(ruleListLines({})).toEqual([]);
});

test("paneListLines prints numbered routed rules, then the default row", () => {
  const pane = {
    rules: [
      { when: "ui work", use: { harness: "claude", model: "opus", effort: "" }, why: "sees pixels" },
      { when: "api", use: { harness: "codex" }, why: "fast" },
    ],
    default: { harness: "claude", effort: "high" },
  };
  expect(paneListLines(pane)).toEqual([
    "1\tui work\tclaude opus\tsees pixels",
    "2\tapi\tcodex\tfast",
    "default\t\tclaude high\t",
  ]);
  expect(paneListLines({ rules: pane.rules })).toEqual(["1\tui work\tclaude opus\tsees pixels", "2\tapi\tcodex\tfast"]);
});

const RULE = { when: " w ", use: { harness: "codex" }, why: "y" };

test("validQaPane: static or routed with an OPTIONAL default", () => {
  expect(validQaPane({ harness: "claude" })).toBe(true);
  expect(validQaPane({ harness: "claude", model: "m", effort: "e" })).toBe(true);
  expect(validQaPane({ harness: " " })).toBe(false);
  expect(validQaPane({ harness: "claude", model: 5 })).toBe(false);
  expect(validQaPane({ harness: "claude", default: { harness: "x" } })).toBe(false);
  expect(validQaPane({ rules: [RULE] })).toBe(true);
  expect(validQaPane({ rules: [RULE], default: { harness: "x" } })).toBe(true);
  expect(validQaPane({ rules: [RULE], default: { harness: "" } })).toBe(false);
  expect(validQaPane({ rules: [RULE], harness: "x" })).toBe(false);
  expect(validQaPane({ rules: [] })).toBe(false);
  expect(validQaPane({ rules: [{ ...RULE, why: "\t\n" }] })).toBe(false);
  expect(validQaPane({ rules: [{ ...RULE, use: [{ harness: "codex" }] }] })).toBe(false);
  expect(validQaPane("claude")).toBe(false);
});

test("validRoutedPane: the default is MANDATORY", () => {
  expect(validRoutedPane({ rules: [RULE], default: { harness: "claude" } })).toBe(true);
  expect(validRoutedPane({ rules: [RULE] })).toBe(false);
  expect(validRoutedPane({ rules: [RULE], default: { harness: "claude", model: false } })).toBe(true);
  expect(validRoutedPane({ rules: [RULE], default: { harness: "claude", model: 1 } })).toBe(false);
  expect(validRoutedPane({ rules: [RULE], default: { harness: "claude" }, effort: "x" })).toBe(false);
});

test("duplicateLane names the first duplicate in jq group_by (sorted) order", () => {
  expect(duplicateLane([{ harness: "claude" }, { harness: "codex" }])).toBe("");
  expect(duplicateLane([{ harness: "claude", model: "a" }, { harness: "claude", model: "b" }])).toBe("");
  expect(duplicateLane([
    { harness: "zed" }, { harness: "zed" },
    { harness: "claude", model: "opus" }, { harness: "claude", model: "opus" },
  ])).toBe("claude model opus");
  expect(duplicateLane([{ harness: "codex" }, { harness: "codex", model: false }])).toBe("codex");
});

test("rrPick indexes like jq, negative counts from the end", () => {
  const use = ["a", "b", "c"];
  expect(rrPick(use, 0)).toBe("a");
  expect(rrPick(use, 4)).toBe("b");
  expect(rrPick(use, -1)).toBe("c");
});

test("qaReceipt is the compact routing receipt, rule number or default", () => {
  const cfg = { panes: { qa: {
    rules: [{ when: "w", use: { harness: "codex", model: "gpt" }, why: "y" }],
    default: { harness: "claude", effort: "high" },
  } } };
  expect(qaReceipt(cfg, "1", "abc")).toBe(
    '{"kind":"qa","rule":1,"when":"w","use":{"harness":"codex","model":"gpt","effort":""},"why":"y","dispatch_sha256":"abc"}');
  expect(qaReceipt(cfg, "default", "abc")).toBe(
    '{"kind":"qa","rule":"default","use":{"harness":"claude","model":"","effort":"high"},"dispatch_sha256":"abc"}');
});

// The three cases below were measured against jq 1.8.2 on the bash original.
test("non-blank checks use jq's whitespace set: U+0085 is space, U+FEFF is not", () => {
  expect(validQaPane({ harness: "\u0085" })).toBe(false);
  expect(validQaPane({ harness: "\ufeff" })).toBe(true);
});

test("duplicateLane sorts by code point, not by UTF-16 unit", () => {
  expect(duplicateLane([
    { harness: "\u{1F600}" }, { harness: "\u{1F600}" }, { harness: "\uffff" }, { harness: "\uffff" },
  ])).toBe("\uffff");
});

test("compact JSON escapes DEL the way jq -c does", () => {
  const cfg = { panes: { qa: { rules: [{ when: "w\u007f", use: { harness: "codex" }, why: "y" }] } } };
  expect(qaReceipt(cfg, "1", "s")).toBe(
    '{"kind":"qa","rule":1,"when":"w\\u007f","use":{"harness":"codex","model":"","effort":""},"why":"y","dispatch_sha256":"s"}');
  expect(jqText({ a: "\u007f" })).toBe('{"a":"\\u007f"}');
});

// Each field used to pass through the shell's $(...), which drops NUL bytes and
// trailing newlines - so a newline- or NUL-only harness was no harness, and a
// value ending in a newline never split the one-line TAB wire.
test("profileLine renders each field the way the shell's $(...) captured it", () => {
  expect(profileLine({ harness: "codex\n", model: "gpt\n\n", effort: "hi\n" })).toBe("harness=codex\tmodel=gpt\teffort=hi");
  expect(profileLine({ harness: "co\u0000dex" })).toBe("harness=codex\tmodel=\teffort=");
  expect(() => profileLine({ harness: "\n" })).toThrow(new Refusal('dispatch profile has no harness: {"harness":"\\n"}'));
  expect(() => profileLine({ harness: "\u0000" })).toThrow(new Refusal('dispatch profile has no harness: {"harness":"\\u0000"}'));
  expect(profileLine({ harness: "x", model: { k: "\u007f" } })).toBe('harness=x\tmodel={\n  "k": "\\u007f"\n}\teffort=');
});

test("duplicateLane names a duplicate the way $(...) captured jq's answer", () => {
  expect(duplicateLane([{ harness: "a\u0000" }, { harness: "a\u0000" }])).toBe("a");
  expect(duplicateLane([{ harness: "a", model: "m\n" }, { harness: "a", model: "m\n" }])).toBe("a model m");
  expect(duplicateLane([{ harness: "\u0000" }, { harness: "\u0000" }])).toBe("");
});

// Bash arithmetic skipped only blanks and newlines around the counter.
test("counterValue reads the round-robin counter as a plain decimal", () => {
  expect(counterValue(" 3\n")).toBe(3);
  expect(counterValue("010")).toBe(10);
  expect(counterValue("-1")).toBe(-1);
  expect(counterValue("\r3")).toBe(0);
  expect(counterValue("\u00a03")).toBe(0);
  expect(counterValue("x")).toBe(0);
  expect(counterValue("")).toBe(0);
});

test("childStatus reports a signal death as 128+N, like the shell did", () => {
  expect(childStatus({ exitCode: 3, signalCode: null })).toBe(3);
  expect(childStatus({ exitCode: null, signalCode: "SIGTERM" })).toBe(143);
  expect(childStatus({ exitCode: null, signalCode: "SIGKILL" })).toBe(137);
});
