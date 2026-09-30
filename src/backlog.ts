// backlog.ts - the backlog line parser: decomposes each `records/backlog.md`
// line (docs/backlog.md) into its grammar fields. The entry is
// bin/ac-backlog.sh (a shim that execs this file through bin/ac-bun.sh); THIS
// header is the authoritative spec of the backlog grammar, this parser and
// its wire. Awk sites reach it through the AC_DONELINE_AWK binding in
// bin/ac-lib.sh. tests/sh/ac-backlog.test.sh holds this parser to
// tests/fixtures/doneline.awk, the awk parser it replaced, frozen except where
// the grammar itself changes - such a change edits both, in one diff.
//
// Usage (the caller's cwd arrives first, from ac_bun_exec):
//   ac-backlog.sh fields <file|->
//       the v1 wire below, one record per input record
//   ac-backlog.sh fields --get <f1,f2,...> <file|->
//       the named fields joined by TAB, in the order asked, one line per
//       input record, with no header or trailer - the caller's pipefail
//       status is its proof the parse finished; contract's TAB is written as
//       \t here too
// Exit 0 on success, also when the reader closes the pipe early (silently);
// 1 with `ERROR: cannot read <file>` - a relative <file> is unreadable when
// the caller's cwd has no name; 2 on a usage error or an unknown field.
//
// THE WIRE (v1):
//   h<TAB>v1<TAB>id<TAB>terminal<TAB>...<TAB>domain_malformed   (FIELDS order)
//   r<TAB><the 14 fields><TAB><the raw record>                 one per record
//   e<TAB><the record count>
// Only contract can hold a TAB (its tokens are split on [ \t]+), and it is
// written as the two characters \t: every contract token matches
// ^(src|flow|mode|rev|qa|promote):[a-z][a-z-]*$, so a backslash never occurs
// in one. No other field can hold a TAB. The raw record comes last and
// unescaped, so a TAB inside it shifts no column. The trailer is the proof the
// parser finished for a reader that cannot see its exit status (awk's close()
// does not reliably return it): a missing trailer, or a count other than the
// number of r lines, is a failed parse.
//
// A record is what awk reads: the text split on LF only, the empty element
// after a final LF dropped, and CR and an unterminated last line kept; a NUL
// byte ends its record and drops the rest of that line, as onetrue awk does.
//
// BYTE-EXACT ASCII: the grammar is what onetrue awk
// does under LC_ALL=C. Bytes in, bytes out - the ledger is read and written as
// latin1, so every byte is one character and a byte past 0x7f matches no
// class below except a negated one. The id and the terminal token are split on
// space, tab and newline; [[:space:]] is space, tab, newline, VT, FF and CR;
// lowercasing is ASCII-only; string equality is byte equality. Two of onetrue
// awk's rules carry the grammar's arithmetic on a line that is not a row, and
// are kept: a failed match leaves RSTART 0 and RLENGTH -1, and substr moves a
// start at or below 0 to 1 WITHOUT shortening the length, where POSIX would
// cut a line-leading group's last byte. awk under a UTF-8 locale answers
// differently, or aborts, only on a line carrying a byte past 0x7f (macOS awk
// then compares == by collation, counts U+00A0 as space, and lowercases U+0130
// and U+212A to ASCII).
//
// acDoneline(line) fills these fields, each "" unless stated:
//   id          - first whitespace token after the `- [ ]`/`- [x]` checkbox.
//   terminal    - "epic"|"failed"|"abandoned" when that bracket token sits at
//                 the FIXED grammar position (the token right after the id),
//                 else "". A token check, NEVER a substring match against the
//                 whole line: a prose mention of [failed] is not a terminal
//                 state (the ready-marker-matches-prose-not-position incident).
//   hold        - "1" when the row carries the captain-hold token `[@held]`,
//                 or its DATED arm `[@held until <YYYY-MM-DD>]`, as one of
//                 the line's `[...]` groups (a group holds no `[` or `]`, so
//                 in `[a [b] c]` it is `[b]`) AND that
//                 group sits in the LEADING RUN - the contiguous run of
//                 `[...]` groups starting immediately after the id, nothing
//                 but spaces and TABs between them - else "". A hold is not a
//                 terminal state (nothing lands to clear it) and not the
//                 dependency token (no blocker id, no STUCK semantics) - its
//                 own field. NOT pinned to the token after the id the way
//                 `terminal` is: on a live ledger row that token is usually
//                 ALREADY another bracket tag (`[CAPTAIN-ORDERED ...]`,
//                 `[MONITOR ...]`, `[EPIC]`), so `[@held]` has no legal slot
//                 there on most rows (measured: 3 of 4 open rows on the
//                 drydock ledger) - the WHOLE leading run is checked, not
//                 just its first group.
//                 THE TOKEN CARRIES A SENTINEL (`@`) FOR A MEASURED REASON:
//                 an earlier `[held]` (bare word, no sentinel) design was
//                 still structural - bracket syntax required - and STILL
//                 false-positived on a real ledger row, because this
//                 grammar's OTHER bracket tags (`[SLICE ...]`, `[CAPTAIN
//                 ORDER LANDED ...]`) carry free-text PROSE, and that prose
//                 uses "held"/"hold" as ordinary English verbs ("the
//                 guardrail held", "Held until now on a verified
//                 collision"). Bracket syntax alone cannot tell a token from
//                 a sentence inside a free-text tag. `@` immediately before
//                 the word is the part ordinary prose never writes -
//                 nobody types "the guardrail @held" - so matching on the
//                 SENTINEL rather than the bare word keeps both properties:
//                 structural (still requires `[...]`) AND immune to a
//                 free-text tag's ordinary prose.
//                 LEADING-RUN POSITION IS ALSO MEASURED, not assumed: bracket
//                 syntax and a sentinel still cannot tell a real token from a
//                 QUOTATION of one - a row, a receipt, or AGENTS.md itself
//                 documenting the grammar has to WRITE `[@held]` to describe
//                 it, and a whole-line scan would silently hold that row too
//                 (the exact bug this field exists to kill, reproduced on
//                 itself). Restricting authority to the leading run does not
//                 by itself fix that - a quotation sitting right after some
//                 OTHER id would still be positional - so position combines
//                 with the CODE-SPAN rule below; between them, a `[@held]`
//                 outside the leading run is never authoritative, and one
//                 wrapped in backticks is never authoritative even inside it.
//   hold_until  - the `<YYYY-MM-DD>` of a dated hold, else "". EXPIRY is
//                 not judged here - the parser extracts, `bin/ac-ready.sh`
//                 compares against today, the same extract/judge split
//                 `contract`/`contractLint` already take. A hold whose
//                 date shape is anything else is not a dated hold at all:
//                 it falls to hold_malformed below, so a mis-typed date is
//                 HELD (fail-closed), never an accidental release.
//   hold_malformed - "1" when a `[...]` group is a mis-typed hold
//                 attempt and is NOT wrapped in a code span (see QUOTATION
//                 below), by EITHER of two rules, each catching a different
//                 slip:
//                 (1) the group case-insensitively contains "@held" or
//                     "@hold" but is not an AUTHORITATIVE `[@held]` (see
//                     hold above: exact text AND leading-run position) -
//                     `[@hold]`, `[@HELD]`, `[@Held]`, `[@helds]`, ... AND a
//                     well-formed `[@held]` sitting OUTSIDE the leading run,
//                     unquoted. That last case is deliberate: position
//                     decides AUTHORITY, so a token typed in the WRONG PLACE
//                     never earns hold=1, but it must not silently fall
//                     through to READY either - a real hold mis-placed by a
//                     keystroke is exactly the failure this field exists to
//                     catch, so it fails the SAME closed direction as any
//                     other mis-type instead of opening a second escape.
//                 (2) the group's content (bracket-stripped) is a SINGLE
//                     WORD - no space or TAB - and case-insensitively
//                     contains "held" or "hold": `[held]`, `[hold]`,
//                     `[HELD]`, `[on-hold]`, ... (the sentinel itself
//                     forgotten - the single most likely slip on a
//                     sentinel-bearing token, and the one this field could
//                     not yet catch). A ONE-WORD group can never be prose -
//                     it is exactly one token, not a sentence - so it needs
//                     no sentinel to be recognized as a hold ATTEMPT; a
//                     free-text tag's prose (`[SLICE ...]`, `[CAPTAIN ORDER
//                     LANDED ...]`) is always multi-word and never matches
//                     rule (2) (measured against the live ledger's actual
//                     one-word bracket groups - `[x]`, `[abandoned]`,
//                     `[failed]`, `[project]`, `[needs-decision]`, `[0]` -
//                     zero false positives today). A mis-typed shape is
//                     never authoritative to begin with, so there is no
//                     "wrong place" for it to be demoted from; two things
//                     exempt it: QUOTATION, and being the group claimed as
//                     `contract` below - `[qa:on-hold]` in the leading run is
//                     the contract, and contractLint judges its value,
//                     while the same group anywhere else trips this rule.
//                 Either rule failing CLOSED (HELD, not READY) is the same
//                 direction blockers_malformed already picked for a
//                 mis-typed `blocked-by` (below); "hold" is caught
//                 alongside "held" in both rules because it is the nearest
//                 possible miss: the feature's own name, present-tense.
//                 QUOTATION: a `[...]` group immediately wrapped in a code
//                 span - a backtick directly before `[` and directly after
//                 `]`, the same backtick-wrap convention `bin/ac-spawn.sh`
//                 already uses so a narrative marker verb never trips its
//                 own detector - is a documentation mention, exempt from
//                 BOTH hold and hold_malformed regardless of its
//                 content or position: a row explaining the grammar can
//                 write `` `[@held]` `` or `` `[held]` `` without holding or
//                 flagging itself.
//   epic        - the id in an `epic:<id>` token anywhere on the line, else "".
//   feature     - the name in a `feature:<name>` token anywhere on the line,
//                 else "" (feature-branch-mech). A MEMBERSHIP token exactly
//                 like epic: - same anywhere-match, same charset. A row
//                 carrying BOTH names two integration targets, a ledger
//                 defect: ac_epic_base_for resolves epic first,
//                 deterministically, and ac-feature.sh ship refuses such a
//                 member row.
//   blockers    - the comma-joined ids in a `blocked-by: <ids>` token, else "".
//                 Read STRICTLY, in the pinned shape (docs/backlog.md,
//                 `blocked-by: id1,id2 - reason`): one space, lowercase,
//                 comma-joined with no empty component, and ended by a
//                 space, a TAB or end of line - CR, VT and FF do not end it,
//                 so a CRLF row whose ids end the line reads MALFORMED. Only
//                 the line's first `blocked-by: <ids>` run is judged, and
//                 nothing bounds its left side: `preblocked-by: a` reads `a`.
//   blockers_malformed - "1" when the line carries a `blocked-by`, in any
//                 case and with nothing bounding either side, outside the one
//                 run blockers read: `blocked-byz`,
//                 `re-blocked-by: a,` and a second run before or after the
//                 read one all trip, so blockers can be non-empty beside it
//                 and a consumer checks this field first. Slips are detected
//                 LENIENTLY. An empty blockers field reads READY at
//                 ac-ready.sh, so a one-character slip would authorize
//                 starting a story whose dependency is still flying; a token
//                 the strict read did not consume is therefore MALFORMED, a
//                 state its consumers must refuse to schedule. A prose
//                 mention of the token trips this too; that is the
//                 fail-VISIBLE direction, and the line is one keystroke from
//                 legal.
//   date        - the first YYYY-MM-DD inside the LAST parenthetical group
//                 holding no `(` or `)` (in `(a (b))` that is `(b)`);
//                 fallback to the LAST YYYY-MM-DD anywhere
//                 on the line when that group carries none (a nested-paren tail,
//                 or a verb+date sitting outside any group). No date -> "".
//                 The real ledger annotates the date group with trailing prose
//                 (`(merged <date>; <note>)`) and trails more prose after it, so
//                 the group is not anchored to end-of-line.
//   verb        - from the group, the FIRST [[:space:]]-separated word before
//                 the date (`(captain accepted <date>)` gives `captain`); from
//                 the fallback, the run of letters, `_` and `-` ending right
//                 before the date, trailing [[:space:]] skipped. "unknown"
//                 when there is no such word or it is not verb-shaped (a
//                 letter, then letters, `_` or `-`). The ledger uses
//                 done/closed/ended/delivered/merged/reported and more; this
//                 never invents a verb the ledger did not write.
//   contract    - the DELIVERY-CONTRACT token group (delivery-contract-on-the-
//                 row): the FIRST leading-run, unquoted `[...]` group whose
//                 content, its leading and trailing spaces and TABs trimmed
//                 and split on [ \t]+, gives only `key:value` tokens with a
//                 key from the closed set src|flow|mode|rev|qa|promote - so
//                 `[src:cap rev:yes ]` still pins: a stray space must never
//                 silently drop a pin before any gate reads it - e.g.
//                 `[src:cap flow:direct mode:local-only rev:no qa:no]` -
//                 returned as the trimmed content, else "". The all-tokens-keyed
//                 test is the discriminator that keeps every EXISTING group
//                 class untouched: a provenance tag (`[CAPTAIN-ORDERED
//                 2026-08-10 ...]`) carries non-kv words, `[EPIC]`/`[failed]`/
//                 `[@held]` carry none, and a backtick-quoted group is a
//                 mention exactly as it is for hold. VALUE validity is
//                 deliberately NOT judged here - the parser extracts,
//                 `contractLint` (src/lib.ts) judges - so a typo'd value
//                 surfaces at lint instead of silently vanishing the whole
//                 group.
//   domain      - the name in a `domain:<name>` CREWDOMAIN assignment token
//                 (crewdomain-token) - authoritative ONLY at the two grammar
//                 positions the old `assigned:crewchief` slot defined:
//                 `; domain:<name>` immediately before a trailing
//                 `(repo: ...)` group, or `; domain:<name>` at end of line
//                 (the arm a Done row and a blocked Queued row take). NOT
//                 anywhere-matched like `epic:` - epic is a membership
//                 token, domain is an AUTHORIZATION token (the assignment
//                 itself), so a prose quotation must be inert; the measured
//                 `[@held]` and domain_row_tokened lessons both bind here.
//                 Name charset [a-z0-9-] = ac_domain_name_ok's.
//   domain_malformed - "1" when a `domain:[a-z0-9-]+`-shaped run sits
//                 ANYWHERE ELSE on the line un-backticked (a mis-placed or
//                 mis-typed stamp, or an unquoted prose mention). Fails
//                 VISIBLE like hold_malformed/blockers_malformed: the row
//                 never silently drops out of its domain's slice. A
//                 backtick-wrapped run is a documentation mention, exempt.
// A site needing the failed/abandoned-OR-verb "marker" (ac-learn) composes it:
// terminal in {failed,abandoned} ? terminal : verb.

import { isAbsolute } from "node:path";
import { readFileSync, writeSync } from "node:fs";
import { die, enterCaller } from "./lib.ts";

export const FIELDS = [
  "id", "terminal", "hold", "hold_until", "hold_malformed", "epic", "feature",
  "blockers", "blockers_malformed", "date", "verb", "contract", "domain", "domain_malformed",
] as const;
export type Doneline = Record<(typeof FIELDS)[number], string>;

// Pure and self-contained - every helper nested, nothing read from module
// scope - so its source can be pasted where imports are not allowed.
export function acDoneline(line: string): Doneline {
  let RSTART = 0;
  let RLENGTH = -1;
  const match = (s: string, re: RegExp): boolean => {
    const m = re.exec(s);
    RSTART = m ? m.index + 1 : 0;
    RLENGTH = m ? m[0].length : -1;
    return m !== null;
  };
  const substr = (s: string, m: number, n = s.length): string => {
    const k = s.length + 1;
    m = m < 1 ? 1 : m > k ? k : m;
    n = n < 0 ? 0 : n > k - m ? k - m : n;
    return s.slice(m - 1, m - 1 + n);
  };
  const lower = (s: string) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());
  const DATE = /[0-9]{4}-[0-9]{2}-[0-9]{2}/;

  const f: Doneline = {
    id: "", terminal: "", hold: "", hold_until: "", hold_malformed: "", epic: "", feature: "",
    blockers: "", blockers_malformed: "", date: "", verb: "", contract: "", domain: "", domain_malformed: "",
  };
  const rp = line.replace(/^- \[[ x]\] /, "").split(/[ \t\n]+/).filter((t) => t !== "");
  f.id = rp[0] ?? "";
  if (rp[1] === "[EPIC]") f.terminal = "epic";
  else if (rp[1] === "[failed]") f.terminal = "failed";
  else if (rp[1] === "[abandoned]") f.terminal = "abandoned";

  // A line that is no row fails this match, so the scan below starts at 0 and
  // leans on substr's start-at-0 rule (header).
  match(line, /^- \[[ x]\] [^ \t]+/);
  let hpos = RLENGTH + 1;
  let runpos = hpos;
  let inrun = true;
  for (;;) {
    const hseg = substr(line, hpos);
    if (hseg === "" || !match(hseg, /\[[^\][]*\]/)) break;
    const gstart = hpos + RSTART - 1;
    const hgrp = substr(line, gstart, RLENGTH);
    const gend = gstart + RLENGTH - 1;
    let positional = false;
    if (inrun) {
      if (/^[ \t]*$/.test(substr(line, runpos, gstart - runpos))) {
        positional = true;
        runpos = gend + 1;
      } else inrun = false;
    }
    const leftch = gstart > 1 ? substr(line, gstart - 1, 1) : "";
    const quoted = leftch === "`" && substr(line, gend + 1, 1) === "`";
    const hcontent = substr(hgrp, 2, hgrp.length - 2);
    // Contract-shaped content holds no `@`, so it can never be hold=1 or a
    // rule (1) attempt; claiming it first does take a value like `qa:on-hold`
    // from rule (2), leaving contractLint to judge that value.
    const hbody = hcontent.replace(/^[ \t]+|[ \t]+$/g, "");
    const contract = !quoted && positional && f.contract === "" && hbody !== ""
      && hbody.split(/[ \t]+/).every((t) => /^(src|flow|mode|rev|qa|promote):[a-z][a-z-]*$/.test(t));
    if (contract) f.contract = hbody;
    else if (quoted) {
      // a documentation mention - never a token, never an attempt
    } else if (positional && /^\[@held( until [0-9]{4}-[0-9]{2}-[0-9]{2})?\]$/.test(hgrp)) {
      f.hold = "1";
      if (match(hgrp, DATE)) f.hold_until = substr(hgrp, RSTART, RLENGTH);
    } else if (/@held|@hold/.test(lower(hgrp))) f.hold_malformed = "1";
    else if (!/[ \t]/.test(hcontent) && /held|hold/.test(lower(hcontent))) f.hold_malformed = "1";
    hpos = gend + 1;
  }

  if (match(line, /epic:[a-zA-Z0-9_-]+/)) f.epic = substr(line, RSTART + 5, RLENGTH - 5);
  if (match(line, /feature:[a-zA-Z0-9_-]+/)) f.feature = substr(line, RSTART + 8, RLENGTH - 8);

  let dauth = 0;
  if (match(line, /; domain:[a-z0-9-]+ \(repo: [^()]*\)$/)) {
    const seg = substr(line, RSTART, RLENGTH);
    dauth = RSTART;
    match(seg, /domain:[a-z0-9-]+/);
    dauth += RSTART - 1;
    f.domain = substr(seg, RSTART + 7, RLENGTH - 7);
  } else if (match(line, /; domain:[a-z0-9-]+$/)) {
    dauth = RSTART + 2;
    f.domain = substr(line, RSTART + 9, RLENGTH - 9);
  }
  for (let pos = 1; ; ) {
    const seg = substr(line, pos);
    if (seg === "" || !match(seg, /domain:[a-z0-9-]+/)) break;
    const gstart = pos + RSTART - 1;
    const gend = gstart + RLENGTH - 1;
    const leftch = gstart > 1 ? substr(line, gstart - 1, 1) : "";
    if (gstart !== dauth && !(leftch === "`" && substr(line, gend + 1, 1) === "`")) f.domain_malformed = "1";
    pos = gend + 1;
  }

  let unread = line;
  if (match(line, /blocked-by: [a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*/)) {
    const after = substr(line, RSTART + RLENGTH, 1);
    if (after === "" || after === " " || after === "\t") {
      f.blockers = substr(line, RSTART + 12, RLENGTH - 12);
      unread = substr(line, 1, RSTART - 1) + substr(line, RSTART + RLENGTH);
    }
  }
  if (/blocked-by/.test(lower(unread))) f.blockers_malformed = "1";

  let grp = "";
  for (let pos = 1; ; ) {
    const seg = substr(line, pos);
    if (seg === "" || !match(seg, /\([^()]*\)/)) break;
    grp = substr(seg, RSTART + 1, RLENGTH - 2);
    pos += RSTART + RLENGTH - 1;
  }
  const verbShaped = (w: string) => (/^[A-Za-z][A-Za-z_-]*$/.test(w) ? w : "unknown");
  if (grp !== "" && match(grp, DATE)) {
    f.date = substr(grp, RSTART, RLENGTH);
    const pre = substr(grp, 1, RSTART - 1).replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, "");
    f.verb = pre === "" ? "unknown" : verbShaped(pre.split(/[ \t\n\v\f\r]+/)[0]);
  }
  if (f.date === "") {
    let last = "";
    let laststart = 0;
    for (let pos = 1; ; ) {
      const seg = substr(line, pos);
      if (seg === "" || !match(seg, DATE)) break;
      laststart = pos + RSTART - 1;
      last = substr(seg, RSTART, RLENGTH);
      pos = laststart + RLENGTH;
    }
    if (last !== "") {
      f.date = last;
      const pre = substr(line, 1, laststart - 1).replace(/[ \t\n\v\f\r]+$/, "");
      f.verb = pre === "" ? "unknown" : verbShaped(pre.split(/[^A-Za-z_-]+/).pop() as string);
    }
  }
  return f;
}

export function records(text: string): string[] {
  const r = text.split("\n");
  if (r[r.length - 1] === "") r.pop();
  return r.map((l) => l.split("\0", 1)[0]);
}

function main(args: string[], atCaller: boolean): void {
  const refuse = (msg: string): never => {
    writeSync(2, `ERROR: ${msg}\n`);
    process.exit(2);
  };
  const usage = () => refuse("usage: ac-backlog.sh fields [--get <f1,f2,...>] <file|->");
  if (args[0] !== "fields") usage();
  let rest = args.slice(1);
  let get: string[] | null = null;
  if (rest[0] === "--get") {
    get = (rest[1] ?? "").split(",");
    rest = rest.slice(2);
    const unknown = get.find((k) => !(FIELDS as readonly string[]).includes(k));
    if (unknown !== undefined) refuse(`unknown field: ${unknown}`);
  }
  if (rest.length !== 1) usage();
  const file = rest[0];
  // Without the caller's cwd a relative name would resolve in the distro root.
  if (file !== "-" && !isAbsolute(file) && !atCaller) die(`cannot read ${file}: the current directory has no name`);
  let text: string;
  try {
    text = readFileSync(file === "-" ? 0 : file).toString("latin1");
  } catch {
    die(`cannot read ${file}`);
  }
  const esc = (f: Doneline, k: string) => f[k as keyof Doneline].replace(/\t/g, "\\t");
  const out = get ? [] : [["h", "v1", ...FIELDS].join("\t")];
  const recs = records(text);
  for (const line of recs) {
    const f = acDoneline(line);
    out.push(get ? get.map((k) => esc(f, k)).join("\t") : ["r", ...FIELDS.map((k) => esc(f, k)), line].join("\t"));
  }
  if (!get) out.push(`e\t${recs.length}`);
  const buf = Buffer.from(out.map((l) => l + "\n").join(""), "latin1");
  try {
    for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
  } catch (e) {
    if ((e as { code?: string }).code !== "EPIPE") throw e;
  }
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  main(args, atCaller);
}
