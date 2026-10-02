#!/usr/bin/env bash
# ac-task.test.sh - bin/ac-task.sh: every routine ledger mutation as a VERB on
# the existing backlog grammar. The properties under test are the ones the
# mint named: locked atomic writes, byte-for-byte preservation of untouched
# lines, idempotent verbs with ok:/already: receipts, the body OFF the line
# (opaque to AC_DONELINE_AWK consumers, archived on replace, riding every
# move), the dated hold `[@held until <YYYY-MM-DD>]` expiring back to READY,
# and Done prune into a dated archive.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

ledger="$AC_HOME/records/backlog.md"
today="$(date +%F)"
yesterday="$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)"

cat >"$ledger" <<'EOF'
## In flight
- [ ] flying - already flying (repo: shop, since 2026-08-01)

## Queued
- [ ] first - an existing queued row (repo: shop)

## Done
- [x] landed - old work - local main (merged 2026-08-01)
EOF

# ---- add: inserts exactly one line at the end of Queued, preserves every
#      other line byte-for-byte, and is idempotent.
cp "$ledger" "$TMP/before.md"
out="$("$BIN/ac-task.sh" add newrow 'a fresh row' \
  --contract 'src:cap flow:direct mode:local-only rev:no qa:no' --repo shop)"
assert_contains "$out" "ok:" "add prints an ok receipt"
grep -qxF -- '- [ ] newrow [src:cap flow:direct mode:local-only rev:no qa:no] - a fresh row (repo: shop)' "$ledger" \
  || fail "add did not write the exact grammar line"
delta="$(diff "$TMP/before.md" "$ledger" | grep '^[<>]' || true)"
[ "$(printf '%s\n' "$delta" | wc -l | tr -d ' ')" = 1 ] \
  || fail "add changed more than one line: $delta"
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "READY  newrow [src:cap" "the added row is READY with its contract shown"
cp "$ledger" "$TMP/before2.md"
out="$("$BIN/ac-task.sh" add newrow 'a fresh row')"
assert_contains "$out" "already" "re-adding an existing id reports already"
cmp -s "$TMP/before2.md" "$ledger" || fail "an already add must not touch the file"

# ---- add: an invalid contract value refuses before any write (the CLI emits
#      what contractLint accepts, never a second dialect).
assert_fails_with "src:bogus" -- "$BIN/ac-task.sh" add badcon 'x' --contract 'src:bogus'
cmp -s "$TMP/before2.md" "$ledger" || fail "a refused add must not touch the file"
assert_fails "$BIN/ac-task.sh" add 'Bad Id' 'x'

# ---- update-note: the body rides UNDER the bullet, indented, and every
#      AC_DONELINE_AWK consumer keeps parsing the LINE unchanged.
"$BIN/ac-task.sh" update-note first 'the long narrative that used to bloat the line' >/dev/null
grep -qxF -- '  the long narrative that used to bloat the line' "$ledger" \
  || fail "update-note did not write an indented body line"
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "READY  first" "a body never changes what the scheduler reads"
# Replacing the body archives the old one.
"$BIN/ac-task.sh" update-note first 'a rewritten narrative' >/dev/null
grep -qxF -- '  a rewritten narrative' "$ledger" || fail "replacement body missing"
grep -qF -- 'the long narrative that used to bloat the line' "$ledger" \
  && fail "old body must be gone from the ledger"
arc="$AC_HOME/records/backlog-body-archive.md"
assert_file "$arc" "replaced body is archived"
assert_contains "$(cat "$arc")" "the long narrative that used to bloat the line" "archive holds the old body"
assert_contains "$(cat "$arc")" "first" "archive names the row id"

# A body line shaped like a row is legal: it is written indented, and every
# reader - the awk sites and the dashboard's parseBacklog alike - takes rows at
# column 0 only, so a checkbox list in a body stays body.
"$BIN/ac-task.sh" update-note first $'steps:\n- [ ] one\n   - [x] two' >/dev/null \
  || fail "a body carrying a checkbox list must be accepted"
grep -qxF -- '  - [ ] one' "$ledger" || fail "the body's checkbox line is kept, indented"
grep -qx 'one' < <("$BIN/ac-ready.sh" queued) && fail "a body checkbox must never read as a row"
"$BIN/ac-task.sh" update-note first 'a rewritten narrative' >/dev/null

# ---- start: moves the row (WITH its body) to In flight and stamps since.
out="$("$BIN/ac-task.sh" start first)"
assert_contains "$out" "ok:" "start prints an ok receipt"
grep -qxF -- "- [ ] first - an existing queued row (repo: shop, since $today)" "$ledger" \
  || fail "start did not stamp since inside the repo group"
grep -q "first" < <(awk '/^## Queued/,/^## Done/' "$ledger") && fail "start left the row in Queued"
grep -qxF -- '  a rewritten narrative' < <(awk '/^## In flight/,/^## Queued/' "$ledger") \
  || fail "the body did not ride the move to In flight"
out="$("$BIN/ac-task.sh" start first)"
assert_contains "$out" "already" "re-starting reports already"

# ---- done: flips the checkbox, appends outcome + (verb date), inserts at the
#      TOP of Done (newest-first), body rides.
out="$("$BIN/ac-task.sh" done first 'local main @abc1234' --verb merged)"
assert_contains "$out" "ok:" "done prints an ok receipt"
grep -qxF -- "- [x] first - an existing queued row (repo: shop, since $today) - local main @abc1234 (merged $today)" "$ledger" \
  || fail "done did not write the grammar Done line"
firstdone="$(awk '/^## Done/{f=1;next} f && /^- \[/{print;exit}' "$ledger")"
case "$firstdone" in '- [x] first'*) ;; *) fail "done must insert newest-first, got: $firstdone" ;; esac
grep -qxF -- '  a rewritten narrative' < <(awk '/^## Done/,0' "$ledger") \
  || fail "the body did not ride the move to Done"
out="$("$BIN/ac-task.sh" done first 'x')"
assert_contains "$out" "already" "re-doning reports already"

# ---- hold / unhold: the token lands in the leading run right after the id;
#      a dated hold expires back to READY on and after its date.
"$BIN/ac-task.sh" add heldrow 'holdable work' --repo shop >/dev/null
"$BIN/ac-task.sh" hold heldrow --why 'captain paused it' >/dev/null
grep -qF -- '- [ ] heldrow [@held] - holdable work (repo: shop) - captain paused it' "$ledger" \
  || fail "hold did not write the [@held] token + why"
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "HELD   heldrow" "an undated hold is HELD"
assert_fails_with "held" -- "$BIN/ac-task.sh" start heldrow
"$BIN/ac-task.sh" hold heldrow --until 2099-01-01 >/dev/null
grep -qF -- '[@held until 2099-01-01]' "$ledger" || fail "dated hold token missing"
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "HELD   heldrow" "an unexpired dated hold is HELD"
grep -qx heldrow < <("$BIN/ac-ready.sh" queued) && fail "queued must not offer an unexpired hold"
"$BIN/ac-task.sh" hold heldrow --until "$yesterday" >/dev/null
grep -qF -- "[@held until $yesterday]" "$ledger" || fail "re-hold did not update the date"
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "READY  heldrow" "an expired dated hold is READY again"
grep -qx heldrow < <("$BIN/ac-ready.sh" queued) || fail "queued must offer an expired hold"
"$BIN/ac-task.sh" unhold heldrow >/dev/null
grep -qF -- '@held' "$ledger" && fail "unhold left a hold token behind"
out="$("$BIN/ac-task.sh" unhold heldrow)"
assert_contains "$out" "already" "re-unholding reports already"
assert_fails_with "date" -- "$BIN/ac-task.sh" hold heldrow --until soon

# ---- hold state is read by THE grammar (src/backlog.ts), never a substring
#      scan: a row whose prose QUOTES the token in a code span is not held, so
#      every verb must treat it as an ordinary row - and hold/unhold must
#      never cut the quotation out of the prose.
"$BIN/ac-task.sh" add quoterow 'documenting the grammar, the hold token is `[@held]` (section 9)' --repo shop >/dev/null
"$BIN/ac-task.sh" start quoterow >/dev/null || fail "a quoted hold mention must not refuse start"
"$BIN/ac-task.sh" done quoterow 'x' >/dev/null
"$BIN/ac-task.sh" add quoterow2 'the token is `[@held]` when the captain says so' --repo shop >/dev/null
out="$("$BIN/ac-task.sh" unhold quoterow2)"
assert_contains "$out" "already" "unhold on a quoted mention reports no hold"
grep -qF -- 'the token is `[@held]` when the captain says so' "$ledger" \
  || fail "unhold cut a quoted mention out of the prose"
"$BIN/ac-task.sh" hold quoterow2 >/dev/null
grep -qF -- '- [ ] quoterow2 [@held] - the token is `[@held]` when the captain says so' "$ledger" \
  || fail "hold on a quoting row must insert the token and leave the prose alone"
"$BIN/ac-task.sh" unhold quoterow2 >/dev/null
grep -qF -- '- [ ] quoterow2 - the token is `[@held]` when the captain says so' "$ledger" \
  || fail "unhold must strip ONLY the leading-run token, never the quotation"

# ---- an EXPIRED dated hold is startable: ac-ready offers it, so start must
#      take it - and the spent token is stripped (the date was the release).
"$BIN/ac-task.sh" add expiredrow 'work the captain dated' --repo shop >/dev/null
"$BIN/ac-task.sh" hold expiredrow --until "$yesterday" >/dev/null
grep -qx expiredrow < <("$BIN/ac-ready.sh" queued) || fail "fixture: expired hold must be offered"
out="$("$BIN/ac-task.sh" start expiredrow)"
assert_contains "$out" "ok:" "start takes the row the scheduler offers"
grep -qF -- '[@held' < <(grep -F -- 'expiredrow' "$ledger") \
  && fail "the spent dated token must be stripped when the row starts"
"$BIN/ac-task.sh" done expiredrow 'x' >/dev/null

# ---- start refuses a row whose blockers do not ALL resolve to a clean Done
#      row - the same rule ac-ready.sh schedules by, enforced at the verb, since
#      the scheduler only advises and a chief can name any id.
awk '{ print } /^## Queued/ {
  print "- [ ] onflying - waits on flying (repo: shop) blocked-by: flying - needs it"
  print "- [ ] onfailed - waits on a failure (repo: shop) blocked-by: landed,sank - needs both"
  print "- [ ] onghost - waits on nothing real (repo: shop) blocked-by: nosuchrow - typo"
  print "- [ ] onbad - unreadable dependency (repo: shop) blocked-by: landed, flying - spaced"
  print "- [ ] onlanded - waits on landed work (repo: shop) blocked-by: landed - done"
} /^## Done/ { print "- [x] sank [failed] - it broke - why (2026-08-02)" }' "$ledger" >"$TMP/blk.md" && mv "$TMP/blk.md" "$ledger"
cp "$ledger" "$TMP/before-blk.md"
assert_fails_with "flying (in flight)" -- "$BIN/ac-task.sh" start onflying
assert_fails_with "sank (failed)" -- "$BIN/ac-task.sh" start onfailed
assert_fails_with "nosuchrow (missing)" -- "$BIN/ac-task.sh" start onghost
assert_fails_with "blocked-by malformed" -- "$BIN/ac-task.sh" start onbad
cmp -s "$TMP/before-blk.md" "$ledger" || fail "a blocker refusal must not touch the file"
out="$("$BIN/ac-task.sh" start onlanded)"
assert_contains "$out" "ok:" "a row whose blockers are all clean Done starts"
grep -vE '^- \[[ x]\] (onflying|onfailed|onghost|onbad|onlanded|sank) ' "$ledger" >"$TMP/blk.md" && mv "$TMP/blk.md" "$ledger"

# ---- the blockers are read off the row's OWN line: awk's == compared
#      numeric-looking ids as numbers, so row 01's empty list let 1 start.
awk '{ print } /^## Queued/ {
  print "- [ ] 1 - waits on flying (repo: shop) blocked-by: flying - needs it"
  print "- [ ] 01 - an unrelated row that reads as the same number (repo: shop)"
}' "$ledger" >"$TMP/num.md" && mv "$TMP/num.md" "$ledger"
assert_fails_with "flying (in flight)" -- "$BIN/ac-task.sh" start 1
grep -vE '^- \[[ x]\] (1|01) ' "$ledger" >"$TMP/num.md" && mv "$TMP/num.md" "$ledger"

# ---- a HAND-WRITTEN malformed until date fails CLOSED (HELD, never READY):
#      hand-editing stays legal and a slip may not read as no-hold.
awk '{ print } /^## Queued/ { print "- [ ] badhold [@held until soon] - hand-edited slip (repo: shop)" }' \
  "$ledger" >"$TMP/hand.md" && mv "$TMP/hand.md" "$ledger"
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "HELD   badhold" "a malformed until reads HELD, fail-closed"
case "$ready" in *"READY  badhold"*) fail "a malformed until must never be READY" ;; esac

# ---- prune: keeps the newest N Done rows, moves the rest (bodies included)
#      into a dated archive; idempotent.
"$BIN/ac-task.sh" update-note landed 'body of the oldest done row' >/dev/null
out="$("$BIN/ac-task.sh" prune --keep 1)"
assert_contains "$out" "ok:" "prune prints an ok receipt"
grep -q "^- \[x\] landed" "$ledger" && fail "prune kept more than N rows"
grep -q "^- \[x\] expiredrow" "$ledger" || fail "prune must keep the newest row"
grep -q "^- \[x\] first" "$ledger" && fail "prune must move every row past keep"
parc="$AC_HOME/records/backlog-archive-$today.md"
assert_file "$parc" "prune wrote the dated archive"
assert_contains "$(cat "$parc")" "landed" "archive holds the pruned row"
assert_contains "$(cat "$parc")" "body of the oldest done row" "archive holds the pruned body"
out="$("$BIN/ac-task.sh" prune --keep 1)"
assert_contains "$out" "already" "a second prune has nothing to move"
# Hand-editing stays legal: a section someone added AFTER Done survives a
# prune untouched instead of being swept into the archive.
printf '\n## Notes\nhand-written, not a task row\n' >>"$ledger"
"$BIN/ac-task.sh" done quoterow2 'x' >/dev/null
"$BIN/ac-task.sh" prune --keep 1 >/dev/null
grep -qxF -- '## Notes' "$ledger" || fail "prune swept a trailing hand-written section"
grep -qxF -- 'hand-written, not a task row' "$ledger" || fail "prune swept trailing hand-written content"
grep -qxF -- '## Notes' "$parc" && fail "the archive must not receive the trailing section"

# ---- locked: a live holder refuses the write instead of corrupting it.
lock="$AC_HOME/records/.backlog.md.lock"
mkdir "$lock"; printf '%s\n' "$$" >"$lock/pid"
export AC_TASK_LOCK_TIMEOUT=1
assert_fails_with "lock" -- "$BIN/ac-task.sh" add lockedout 'x'
unset AC_TASK_LOCK_TIMEOUT
rm -rf "$lock"
grep -q lockedout "$ledger" && fail "a lock-refused add must not touch the file"

# ---- the atomic publish keeps the ledger's MODE: mktemp makes a 0600 file and
#      `mv` carries that mode onto the target, so a plain tmp+rename silently
#      tightens a world-readable record to owner-only (measured on the live
#      drydock ledger: 0644 -> 0600 on the first real landing).
chmod 644 "$ledger"
"$BIN/ac-task.sh" add modeprobe 'a row to publish' >/dev/null
assert_eq "$(ls -l "$ledger" | cut -c1-10)" "-rw-r--r--" "the atomic publish preserves the ledger's mode"

# ---- unknown id refuses.
assert_fails "$BIN/ac-task.sh" start ghost
assert_fails "$BIN/ac-task.sh" update-note ghost 'x'

# ---- the id and --verb checks are ASCII: a shell [a-z] range collates under a
#      UTF-8 locale, so it took `Foo` and the verb `Merged` and refused `fooZ`.
assert_fails_with "invalid id" -- env LC_ALL=en_US.UTF-8 "$BIN/ac-task.sh" add Foo 'x'
"$BIN/ac-task.sh" add verbrow 'a row to finish' >/dev/null
assert_fails_with "invalid --verb" -- env LC_ALL=en_US.UTF-8 "$BIN/ac-task.sh" done verbrow 'x' --verb Merged

# ---- rows are found by the parser's id (src/backlog.ts): read up to the first
#      space, a TAB after the id hid the row from start and let add mint a
#      second row with the same id.
awk '{ print } /^## Queued/ { print "- [ ] tabbed\t- a TAB after the id (repo: shop)" }' "$ledger" >"$TMP/tab.md" \
  && mv "$TMP/tab.md" "$ledger"
assert_contains "$("$BIN/ac-task.sh" add tabbed 'a duplicate')" "already" "add sees the TAB-separated id"
assert_contains "$("$BIN/ac-task.sh" start tabbed)" "ok:" "start finds the TAB-separated id"
assert_eq "$(grep -c tabbed "$ledger")" "1" "one row carries the id"

# ---- an unterminated last line is a row like any other: the shell's read never
#      returned it, so the next write deleted that row and still printed ok.
printf -- '- [x] lastrow - written without a final newline (merged 2026-08-01)' >>"$ledger"
"$BIN/ac-task.sh" add eolprobe 'a write after it' >/dev/null
grep -qxF -- '- [x] lastrow - written without a final newline (merged 2026-08-01)' "$ledger" \
  || fail "a write must keep the unterminated last row"

# ---- an argument that is not UTF-8 refuses: its bytes arrive replaced by
#      U+FFFD, and writing that would put text no caller typed into the ledger.
cp "$ledger" "$TMP/before-bytes.md"
assert_fails_with "not valid UTF-8" -- "$BIN/ac-task.sh" add latinrow "$(printf 'caf\351')"
cmp -s "$TMP/before-bytes.md" "$ledger" || fail "a refused argument must not touch the file"

# ---- hold writes a line the parser reads as held, whatever blanks or checkbox
#      the row carries, and a re-hold finds the token it wrote.
awk '{ print } /^## Queued/ { print "- [ ]  spaced - two blanks before the id"; print "- [x] ticked - a ticked row outside Done" }' \
  "$ledger" >"$TMP/odd.md" && mv "$TMP/odd.md" "$ledger"
for r in spaced ticked; do
  "$BIN/ac-task.sh" hold "$r" >/dev/null || fail "hold $r"
  assert_contains "$("$BIN/ac-ready.sh")" "HELD   $r" "hold on $r reads HELD"
  assert_contains "$("$BIN/ac-task.sh" hold "$r")" "already" "a re-hold on $r finds its token"
  assert_contains "$("$BIN/ac-task.sh" unhold "$r")" "ok:" "unhold releases $r"
done

# ---- a ledger missing the section a verb writes into refuses and writes
#      nothing: the shell printed the ERROR, then wrote the row above every
#      section and printed ok.
printf '## Done\n- [x] only - done (merged 2026-08-01)\n' >"$TMP/nosec.md"
cp "$ledger" "$TMP/keep.md"; cp "$TMP/nosec.md" "$ledger"
assert_fails_with "no 'queued' section" -- "$BIN/ac-task.sh" add nosecrow 'x'
cmp -s "$TMP/nosec.md" "$ledger" || fail "a ledger with no Queued section must not be written"
cp "$TMP/keep.md" "$ledger"

# ---- a read-only ledger refuses the write, as the copy-then-write publish
#      always did. Skipped under root, which writes through chmod.
if [ "$(id -u)" != 0 ]; then
  chmod 444 "$ledger"
  assert_fails_with "cannot write" -- "$BIN/ac-task.sh" add rorow 'x'
  chmod 644 "$ledger"
  grep -q rorow "$ledger" && fail "a read-only ledger must not be written"
  assert_eq "$(ls -A "$AC_HOME/records" | grep -c 'backlog.md\.[0-9]')" "0" "a refused write leaves no temp file"
fi

# ---- the domain token keeps its grammar position through start and done.
# `; domain:<name>` is authoritative only right before a trailing (repo: ...)
# group or at end of line (docs/backlog.md): a rewrite that appends after it
# turns the row MALFORMED and drops it out of its domain for good.
cat >"$ledger" <<'EOF'
## In flight

## Queued
- [ ] dom-a - x; domain:alpha (repo: proj)
- [ ] dom-b - y; domain:alpha
- [ ] unclosed - something odd (repo: proj
- [ ] since-prose - retry the push, since the old path fails (repo: proj)

## Done
EOF
"$BIN/ac-task.sh" start dom-a >/dev/null
"$BIN/ac-task.sh" start dom-b >/dev/null
"$BIN/ac-task.sh" done dom-a 'local main' >/dev/null
dom_fields() { "$BIN/ac-backlog.sh" fields --get id,domain,domain_malformed "$ledger" | awk -F'\t' -v id="$1" '$1 == id { print $2 "|" $3 }'; }
assert_eq "$(dom_fields dom-a)" "alpha|" "done keeps an authoritative domain token on the landed row"
assert_eq "$(dom_fields dom-b)" "alpha|" "start keeps a line-end domain token authoritative"
assert_contains "$(grep '^- \[ \] dom-b ' "$ledger")" "(since $today)" "...and still stamps since"
# The since stamp itself: an unclosed repo group is closed, not duplicated, and
# prose that merely says ", since " is no stamp.
"$BIN/ac-task.sh" start unclosed >/dev/null
assert_eq "$(grep '^- \[ \] unclosed ' "$ledger")" "- [ ] unclosed - something odd (repo: proj, since $today)" \
  "an unclosed repo group is stamped once and closed"
"$BIN/ac-task.sh" start since-prose >/dev/null
assert_eq "$(grep '^- \[ \] since-prose ' "$ledger")" \
  "- [ ] since-prose - retry the push, since the old path fails (repo: proj, since $today)" \
  "prose saying ', since ' does not stand in for the stamp"
# Both together: a line-end token on a row whose repo group never closed is
# lifted before the group is closed, never swallowed into it - and survives done.
cat >"$ledger" <<'EOF'
## In flight

## Queued
- [ ] dom-c - z (repo: proj; domain:alpha
- [ ] dom-d - w; domain:alpha (repo: proj

## Done
EOF
"$BIN/ac-task.sh" start dom-c >/dev/null
assert_contains "$(grep '^- \[ \] dom-c ' "$ledger")" "(repo: proj, since $today); domain:alpha" "fixture: dom-c really started"
assert_eq "$(dom_fields dom-c)" "alpha|" "closing an unclosed repo group keeps the line-end domain authoritative"
"$BIN/ac-task.sh" done dom-c 'local main' >/dev/null
assert_eq "$(dom_fields dom-c)" "alpha|" "...through done as well"
# A token already off its position stays visibly malformed: start refuses to
# rewrite the line instead of closing the group under it and authorizing it.
assert_eq "$(dom_fields dom-d)" "|1" "fixture: the token starts malformed"
rc=0; out="$("$BIN/ac-task.sh" start dom-d 2>&1)" || rc=$?
assert_eq "$rc" "1" "start refuses a row whose domain token is off its position: $out"
assert_contains "$out" "fix the line by hand" "...saying how to repair it"
assert_eq "$(dom_fields dom-d)" "|1" "...leaving it visibly malformed"

# ---- a hold on an [EPIC] row joins the leading run AFTER the epic tag: the
# terminal token is read only right after the id, so a hold placed ahead of it
# turned the epic into an ordinary row for as long as the hold stood.
cat >"$ledger" <<'EOF'
## In flight

## Queued
- [ ] ep1 [EPIC] - an epic stories: s1 (repo: proj)

## Done
EOF
"$BIN/ac-task.sh" hold ep1 --why 'waiting on the captain' >/dev/null
assert_eq "$("$BIN/ac-backlog.sh" fields --get id,terminal,hold "$ledger" | awk -F'\t' '$1 == "ep1" { print $2 "|" $3 }')" "epic|1" \
  "a held epic is still an epic, and held"
assert_contains "$(grep '^- \[ \] ep1 ' "$ledger")" "ep1 [EPIC] [@held]" "...the hold sits in a second contiguous group"
"$BIN/ac-task.sh" unhold ep1 >/dev/null
assert_eq "$(grep '^- \[ \] ep1 ' "$ledger")" "- [ ] ep1 [EPIC] - an epic stories: s1 (repo: proj) - waiting on the captain" \
  "unhold takes the hold back out and leaves the epic tag where it was"
# The separator between the id and the epic tag is the row's own: a TAB
# survives the hold and the release byte for byte.
printf -- '- [ ] ep2\t[EPIC] - another epic stories: s2 (repo: proj)\n' >"$TMP/ep2.line"
awk -v l="$(cat "$TMP/ep2.line")" '{ print } /^## Queued/ { print l }' "$ledger" >"$TMP/ep2.ledger" && mv "$TMP/ep2.ledger" "$ledger"
"$BIN/ac-task.sh" hold ep2 >/dev/null
assert_eq "$("$BIN/ac-backlog.sh" fields --get id,terminal,hold "$ledger" | awk -F'\t' '$1 == "ep2" { print $2 "|" $3 }')" "epic|1" \
  "a TAB-separated epic tag stays the epic tag under a hold"
"$BIN/ac-task.sh" unhold ep2 >/dev/null
assert_eq "$(grep '^- \[ \] ep2' "$ledger")" "$(cat "$TMP/ep2.line")" "...and the release restores the line byte for byte"

pass
