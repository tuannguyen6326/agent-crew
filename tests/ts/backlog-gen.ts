// backlog-gen.ts <seed> <count> <seed-rows-file> - a deterministic corpus for
// the Leg A differential in tests/sh/ac-backlog.test.sh: <count> lines on stdout,
// alternately built from the backlog grammar's tokens and made by mutating a
// `- [` row of <seed-rows-file>, written as raw bytes. The alphabet carries
// the bytes a byte-exact reading must not treat as ASCII - NBSP, U+0130,
// U+212A, invalid UTF-8 - next to CR, VT and FF. Never LF (a line is one
// record) and never NUL, which awk strings cannot hold.

import { readFileSync, writeSync } from "node:fs";

const [seedArg, countArg, seedFile] = process.argv.slice(2);
let s = Number(seedArg) >>> 0 || 1;
const rnd = () => {
  s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0;
  return s / 4294967296;
};
const pick = <T>(a: T[]): T => a[Math.floor(rnd() * a.length)];
const u = (x: string) => Buffer.from(x, "utf8").toString("latin1");

const HEAD = ["- [ ] ", "- [x] ", "- [X] ", "-  [ ] ", "  - [ ] ", "- [x]\t", "- [ ]  ", "- [ ]", "- [", "[", ""];
const ID = ["t1", "a-b-c", "fix_foo", "Upper-Id", "a[b]", "`q`", "x", "e1", "s1", "s2", "p4", "n1", u("é-id"), ""];
const GROUP = [
  "[EPIC]", "[failed]", "[abandoned]", "[FAILED]", "[EPIC 3 stories]", "[x]", "[]", "[a[b]", "[x]]", "[needs-decision]",
  "[@held]", "[@held until 2026-01-02]", "[@held until 2026-1-02]", "[@HELD]", "[@hold]", "[held]", "[hold]", "[on-hold]",
  "[the guardrail held]", "`[@held]`", "`[held]", "[@held]`",
  "[src:cap]", "[src:cap mode:x]", "[ src:cap]", "[src:cap ]", "[src:cap\tqa:yes]", "[bogus:v src:cap]", "`[src:cap]`",
  "[flow:staged mode:crew-ship rev:yes qa:yes]", "[promote:no]", "[CAPTAIN-ORDERED 2026-07-30 \"a - b\"]", "[epic:e1]",
];
const TOKEN = [
  "epic:e1", "epic:Foo_bar", "noepic:x", "feature:f1", "feature:", "blocked-by: a,b", "blocked-by: s1", "blocked-by: a,,b",
  "Blocked-By: a", "blocked-by:a", "blocked-by: a-", "blocked-by: a,b-", "xblocked-by: a", "unblocked-by: a",
  "; domain:pay", "; domain:pay (repo: x)", "domain:pay", "`domain:pay`", "; domain:Pay", "(repo: alpha)", "(repo: a) (repo: b)",
  "(merged 2026-08-09)", "(done 2026-01-01; note (nested))", "2026-02-03", "closed 2026-04-05", "(2026-01-01)", "()",
  "(merged 2026-08-09; a b) tail 2026-09-01", "delivered2026-01-01", "(:2026-01-01)", "( merged  2026-02-02 )", "12026-01-011",
  "(\x0bmerged 2026-03-03)", "-", " - ", "text", "stories: s1,s2",
];
const ODD = [u(" "), u("İ"), u("K"), u("é"), u("—"), "\xff", "\x80", "\xc3", "\r", "\x0b", "\x0c"];
const SEP = [" ", "", "\t", "  ", " - ", "` ", "`", " (", ") ", ";", "; "];
const CHAR = "[]`()-:,@ \tabdehklopstxyEPICHOLD0123456789;/_".split("").concat(ODD);

const seeds = readFileSync(seedFile, "latin1").split("\n").filter((l) => l.startsWith("- ["));
const out: string[] = [];
for (let i = 0; i < Number(countArg); i++) {
  let l: string;
  if (i % 2 === 0) {
    l = pick(HEAD) + pick(ID);
    for (let k = Math.floor(rnd() * 8); k > 0; k--) {
      const r = rnd();
      l += pick(SEP) + (r < 0.4 ? pick(GROUP) : r < 0.9 ? pick(TOKEN) : pick(ODD));
    }
    if (rnd() < 0.1) l += pick([" ", "\r", "\t", "  "]);
  } else {
    l = pick(seeds);
    for (let k = 1 + Math.floor(rnd() * 5); k > 0; k--) {
      const p = Math.floor(rnd() * (l.length + 1));
      const r = rnd();
      if (r < 0.4) l = l.slice(0, p) + pick(CHAR) + l.slice(p);
      else if (r < 0.65) l = l.slice(0, p) + l.slice(p + 1);
      else if (r < 0.8) l = l.slice(0, p) + pick(CHAR) + l.slice(p + 1);
      else l = l.slice(0, p) + pick(SEP) + pick(rnd() < 0.5 ? GROUP : TOKEN) + l.slice(p);
    }
  }
  out.push(l);
}
const buf = Buffer.from(out.map((l) => l + "\n").join(""), "latin1");
for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
