// backlog.test.ts - Bun unit tests for src/backlog.ts's pure layer: one case
// per field, the byte-exact reading, the onetrue awk arithmetic the grammar
// leans on, and records(). Every expected value was read off the awk parser
// (tests/fixtures/doneline.awk under LC_ALL=C); tests/ac-backlog.test.sh owns
// the CLI contract and the generated differential. A string holding bytes
// past 0x7f spells them one latin1 character per byte, as the module reads a
// ledger. Run through tests/src.test.sh.

import { test, expect } from "bun:test";
import { acDoneline, FIELDS, records, type Doneline } from "../src/backlog.ts";

const only = (line: string, want: Partial<Doneline>) =>
  expect(acDoneline(line)).toEqual({ ...Object.fromEntries(FIELDS.map((k) => [k, ""])), ...want });

test("FIELDS is the wire's column order", () => {
  expect(FIELDS).toEqual([
    "id", "terminal", "hold", "hold_until", "hold_malformed", "epic", "feature",
    "blockers", "blockers_malformed", "date", "verb", "contract", "domain", "domain_malformed",
  ]);
});

test("id is the first space, tab or newline token after the checkbox", () => {
  only("- [ ] t1\t[EPIC] - tab after id", { id: "t1", terminal: "epic" });
  only("- [X] t1 [EPIC] - capital X", { id: "-" });
});

test("terminal is read only at the token after the id, byte for byte", () => {
  only("- [x] t1 [EPIC] - epic row", { id: "t1", terminal: "epic" });
  only("- [x] t1 [failed] - x", { id: "t1", terminal: "failed" });
  only("- [x] t1 [abandoned] - x", { id: "t1", terminal: "abandoned" });
  only("- [x] t1 - mentions [failed] later", { id: "t1" });
  only("- [x] t1 [FAILED] - x", { id: "t1" });
});

test("hold is authoritative only unquoted in the leading run, as [@held] or its dated arm", () => {
  only("- [ ] q1 [@held] - x", { id: "q1", hold: "1" });
  only("- [ ] q1 [src:cap] [@held] - x", { id: "q1", hold: "1", contract: "src:cap" });
  only("- [ ] q1 [@held until 2026-09-01] - x",
    { id: "q1", hold: "1", hold_until: "2026-09-01", date: "2026-09-01", verb: "until" });
  only("- [ ] q1 `[@held]` - x", { id: "q1" });
});

test("hold_malformed fails closed on a mis-typed or mis-placed hold, never on multi-word prose", () => {
  for (const line of [
    "- [ ] q1 [@held until 2026-9-1] - x",
    "- [ ] q1 - text [@held] later",
    "- [ ] q1 [held] - x",
    "- [ ] q1 [on-hold] - x",
    "- [ ] q1 [@HOLD] - x",
  ]) only(line, { id: "q1", hold_malformed: "1" });
  only("- [ ] q1 [the guardrail held] - x", { id: "q1" });
});

test("contract is the first unquoted leading-run group whose every token is a closed-set key:value", () => {
  only("- [ ] t1 [src:cap flow:direct mode:local-only rev:no qa:no] - do it (repo: alpha)",
    { id: "t1", contract: "src:cap flow:direct mode:local-only rev:no qa:no" });
  only("- [ ] t2 [EPIC 3 stories] [src:cap] - x", { id: "t2", contract: "src:cap" });
  only("- [ ] t3 [src:cap\tqa:yes] - x", { id: "t3", contract: "src:cap\tqa:yes" });
  only("- [ ] t7 [src:cap] [mode:crew-ship] - first wins", { id: "t7", contract: "src:cap" });
  for (const line of [
    "- [ ] t1 - text mentions [mode:local-only] later",
    "- [ ] t1 [src:cap bogus:v] - x",
    "- [ ] t1 [ src:cap] - x",
    "- [ ] t1 `[@held]` [src:cap] - x",
  ]) only(line, { id: "t1" });
});

test("epic and feature are matched anywhere, with no word boundary", () => {
  only("- [ ] s1 - story; epic:payv2 blocked-by: a,b - x", { id: "s1", epic: "payv2", blockers: "a,b" });
  only("- [ ] s2 - noepic:x epic:y", { id: "s2", epic: "x" });
  only("- [ ] s3 - epic:Foo_bar", { id: "s3", epic: "Foo_bar" });
  only("- [ ] f1 - story; feature:pay-ux (repo: proj)", { id: "f1", feature: "pay-ux" });
});

test("blockers are read strictly, and every slip the strict read leaves is blockers_malformed", () => {
  only("- [ ] b1 - x blocked-by: a", { id: "b1", blockers: "a" });
  only("- [ ] b1 - x blocked-by: a-b\tx", { id: "b1", blockers: "a-b" });
  for (const line of ["- [ ] b1 - x blocked-by:a", "- [ ] b1 - x Blocked-by: a", "- [ ] b1 - x blocked-by: a, b"])
    only(line, { id: "b1", blockers_malformed: "1" });
  only("- [ ] b1 - reads unblocked-by here", { id: "b1" });
});

test("domain is authoritative at its two positions only, and any other unquoted run is domain_malformed", () => {
  only("- [ ] d1 - x; domain:payments (repo: payments-core)", { id: "d1", domain: "payments" });
  only("- [x] d1 - landed (merged 2026-08-18); domain:payments",
    { id: "d1", domain: "payments", date: "2026-08-18", verb: "merged" });
  only("- [ ] d1 - mentions domain:payments in prose", { id: "d1", domain_malformed: "1" });
  only("- [ ] d1 - x; domain:pay  ", { id: "d1", domain_malformed: "1" });
  only("- [ ] d1 - documents `domain:payments` shape", { id: "d1" });
});

test("date and verb come from the last non-nested group, else from the last date anywhere", () => {
  only("- [x] v1 - x (reported 2026-07-24)", { id: "v1", date: "2026-07-24", verb: "reported" });
  only("- [x] v1 [abandoned] - x (2026-07-20)", { id: "v1", terminal: "abandoned", date: "2026-07-20", verb: "unknown" });
  only("- [x] v1 - x (merged 2026-07-21; ref s8(2))", { id: "v1", date: "2026-07-21", verb: "merged" });
  only("- [x] v1 - x closed 2026-07-24 then (no date)", { id: "v1", date: "2026-07-24", verb: "closed" });
});

test("the grammar is byte-exact ASCII: only ASCII spaces space and only ASCII letters lowercase", () => {
  only("- [x] v1 - x (\x0bmerged 2026-01-01)", { id: "v1", date: "2026-01-01", verb: "merged" });
  only("- [x] v1 - x (\xc2\xa0merged 2026-01-01)", { id: "v1", date: "2026-01-01", verb: "unknown" });
  only("- [ ] a\xc2\xa0b [EPIC] - x", { id: "a\xc2\xa0b", terminal: "epic" });
  only("- [ ] a\xffb [failed] - x", { id: "a\xffb", terminal: "failed" });
  only("- [ ] k1 - bloc\xe2\x84\xaaed-by: a", { id: "k1" });
  only("- [x] t1 [EPIC]\r", { id: "t1" });
  only("- [x] v7 - x (merged 2026-01-01)\r", { id: "v7", date: "2026-01-01", verb: "merged" });
});

// A non-row line fails the id match (RLENGTH -1), so the group scan starts at
// 0 and reads its first group one byte early - `x[held]` as `x[held`, no hold
// attempt - while onetrue awk's substr moves that start of 0 to 1 WITHOUT
// shortening the length, which keeps a line-leading group whole.
test("a non-row line keeps onetrue awk's failed-match and substr-from-0 arithmetic", () => {
  only("x[held]", { id: "x[held]" });
  only("[@held] x", { id: "[@held]", hold: "1" });
});

test("acDoneline is self-contained: its own source, evaluated with nothing in scope, parses alike", () => {
  const pasted = new Function(`return (${acDoneline.toString()});`)() as typeof acDoneline;
  for (const line of [
    "- [ ] q1 [src:cap] [@held until 2026-09-01] - x; epic:e1 feature:f blocked-by: a,b - y; domain:pay",
    "- [ ] b1 - x Blocked-by: a (merged 2026-01-01) domain:x [@held]",
    "[@held] x",
  ]) expect(pasted(line)).toEqual(acDoneline(line));
});

test("records splits on LF only, drops one trailing empty element, keeps CR and an unterminated tail, and ends a record at a NUL", () => {
  expect(records("")).toEqual([]);
  expect(records("a\nb")).toEqual(["a", "b"]);
  expect(records("a\r\nb\n")).toEqual(["a\r", "b"]);
  expect(records("a\n\n")).toEqual(["a", ""]);
  expect(records("a\0b c\nd")).toEqual(["a", "d"]);
  expect(records("a\n\0")).toEqual(["a", ""]);
});
