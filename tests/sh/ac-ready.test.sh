#!/usr/bin/env bash
# ac-ready.test.sh - the queued-work scheduler primitive: READY when blockers
# are all Done clean and the epic is under cap - a plain unblocked item
# included; STUCK on missing/failed blockers; map validation (reserved
# suffixes, missing lines, cycles);
# overlap - the intake file-interlock check (LANDED ledger hits <7d,
# INFLIGHT crew/* branch diffs, BRIEF in-flight briefs; silent when clean).

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
B="$AC_HOME/records/backlog.md"

cat >"$B" <<'EOF'
# Backlog

## In flight
- [ ] payv2 [EPIC] - payments v2 stories: checkout,refund,recon,report (repo: shop, since 2026-07-15)
- [ ] checkout - build checkout; epic:payv2 (repo: shop, since 2026-07-15)

## Queued
- [ ] recon - reconciliation; epic:payv2 blocked-by: checkout,refund - needs both APIs
- [ ] report - reporting; epic:payv2 blocked-by: refund - needs refund fields
- [ ] loosetask - unrelated queued work (repo: shop)
- [ ] cursed - doomed; epic:payv2 blocked-by: ghost - blocker never existed

## Done
- [x] refund - refund API - PR url (merged 2026-07-15)
EOF

out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "READY  report (epic:payv2)" "blocker done + under cap = ready"
assert_contains "$out" "STUCK  cursed blocker ghost missing" "missing blocker = stuck"
case "$out" in *"READY  recon"*) fail "recon still waits on checkout (in flight)" ;; esac
assert_contains "$out" "READY  loosetask" "an unblocked non-epic queued item is startable, so the report lists it"

# queued: the room-parallel advisory's selector - the same startable set as
# bare ids, pipeable because it carries no STUCK line.
out="$("$BIN/ac-ready.sh" queued)"
assert_contains "$out" "loosetask" "plain queued items are what this selector is for"
assert_contains "$out" "report" "blockers all Done clean = startable"
case "$out" in *recon*) fail "recon still waits on checkout (in flight)" ;; esac
case "$out" in *cursed*) fail "a dependent stuck on a missing blocker is not startable" ;; esac

# Failed blockers never satisfy; they mark dependents stuck.
perl -pi -e 's/- \[x\] refund - refund API - PR url \(merged 2026-07-15\)/- [x] refund [failed] - refund API - died (2026-07-15)/' "$B"
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "STUCK  report blocker refund failed" "failed blocker = stuck dependent"
case "$("$BIN/ac-ready.sh" queued)" in *report*) fail "a terminal blocker never satisfies, so it never makes a dependent startable" ;; esac

# Cap: with 2 stories already flying, a ready story stays unlisted.
perl -pi -e 's/- \[x\] refund \[failed\] - refund API - died \(2026-07-15\)/- [x] refund - refund API - PR url (merged 2026-07-15)/' "$B"
perl -pi -e 's/^- \[ \] checkout - build checkout; epic:payv2.*$/- [ ] checkout - build checkout; epic:payv2 (repo: shop, since 2026-07-15)\n- [ ] extra - another; epic:payv2 (repo: shop, since 2026-07-15)/' "$B"
out="$("$BIN/ac-ready.sh")"
case "$out" in *"READY  report"*) fail "cap 2 must hold report back (2 flying)" ;; esac
case "$("$BIN/ac-ready.sh" queued)" in *report*) fail "a story over its epic's cap cannot start, so it is not startable" ;; esac
printf '3\n' >"$AC_HOME/config/epic-parallel"
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "READY  report (epic:payv2)" "raised cap releases the story"
rm -f "$AC_HOME/config/epic-parallel"

# Marker POSITION, not prose - docs/backlog.md puts the terminal marker
# immediately after the id. A live incident (2026-07-22, drydock) showed an
# in-flight epic story documenting its own two terminal states in prose
# (SETTLED-FAIL->[failed] - a convention every two-terminal-state story
# hits) misread as if it carried the marker, stranding its dependents STUCK.
perl -0777 -pi -e 's/(## In flight\n)/$1- [ ] prosey - a two-terminal story (mentions [EPIC] scope in passing) SETTLED-FAIL->[failed] SETTLED-ABANDON->[abandoned] (repo: shop, since 2026-07-22)\n/' "$B"
perl -0777 -pi -e 's/(## Queued\n)/$1- [ ] prosey-dep - depends on prosey; blocked-by: prosey - needs prosey outcome\n/' "$B"
out="$("$BIN/ac-ready.sh")"
case "$out" in *"STUCK  prosey-dep"*) fail "prosey's PROSE mentions [failed]/[abandoned]/[EPIC] but carries no marker at the grammar position - prosey-dep must not be stranded" ;; esac

# The same misread, on a RESOLVED blocker: a Done item's one-line summary
# mentioning "[failed]" in prose (e.g. describing a fixed earlier failure) is
# a plain satisfied blocker, not a terminal one - its dependent must be READY
# in the report and startable via the queued selector.
perl -0777 -pi -e 's/(## Done\n)/$1- [x] flakyfix - fixed the earlier [failed] attempt at retries - PR url (merged 2026-07-22)\n/' "$B"
perl -0777 -pi -e 's/(## Queued\n)/$1- [ ] flakyfix-dep - depends on flakyfix; blocked-by: flakyfix - needs the fix\n/' "$B"
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "READY  flakyfix-dep" "a done blocker whose prose merely mentions [failed] is a plain satisfied blocker"
case "$out" in *"STUCK  flakyfix-dep"*) fail "flakyfix carries no real marker - its dependent must not be STUCK" ;; esac
assert_contains "$("$BIN/ac-ready.sh" queued)" "flakyfix-dep" "queued lists it too - the same startable set as report"

# A legit [abandoned] marker AT the grammar position still stalls its
# dependent - the fix must not overcorrect into ignoring real markers.
perl -0777 -pi -e 's/(## Done\n)/$1- [x] abandonme [abandoned] - gave up on the retry path (2026-07-22)\n/' "$B"
perl -0777 -pi -e 's/(## Queued\n)/$1- [ ] abandonme-dep - depends on abandonme; blocked-by: abandonme - needs a decision\n/' "$B"
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "STUCK  abandonme-dep blocker abandonme abandoned" "a legit [abandoned] marker at the grammar position still stalls its dependent"

# A blocked-by line that slips the pinned grammar (docs/backlog.md) reads
# MALFORMED, never READY. Empty blockers mean "nothing to wait on" here, so a
# missing space, a double space or a capital B used to make the whole
# dependency VANISH - and under the standing autonomous-drain rule the chief
# starts that story while its blocker is still flying. The report must name it
# and the queued selector must never offer it.
perl -0777 -pi -e 's/(## Queued\n)/$1- [ ] slip - typo\x27d dependency (repo: shop) blocked-by:checkout,refund - needs both\n/' "$B"
out="$("$BIN/ac-ready.sh")"
case "$out" in *"READY  slip"*) fail "a malformed blocked-by line must never read READY" ;; esac
assert_contains "$out" "STUCK  slip blocked-by malformed" "the report names the malformed row"
case "$("$BIN/ac-ready.sh" queued)" in *slip*) fail "the queued selector must never offer a malformed row" ;; esac
perl -ni -e 'print unless /^- \[ \] slip /' "$B"
# A run the strict read did not consume is MALFORMED
# wherever it sits - after a word character, or beside a run that was read.
perl -0777 -pi -e 's/(## Queued\n)/$1- [ ] wordslip - x (repo: shop) re-blocked-by: checkout, - trailing comma\n- [ ] tworuns - x (repo: shop) blocked-by: refund - also blocked-by: checkout\n/' "$B"
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "STUCK  wordslip blocked-by malformed" "a slipped run after a word character reads MALFORMED, never READY"
assert_contains "$out" "STUCK  tworuns blocked-by malformed" "a second run beside the one read reads MALFORMED, never READY"
perl -ni -e 'print unless /^- \[ \] (wordslip|tworuns) /' "$B"

# validate: happy map, reserved-suffix id, missing line, cycle.
"$BIN/ac-ready.sh" validate payv2 >/dev/null || fail "clean map must validate (cursed's ghost edge is outside the story set)"
perl -pi -e 's/stories: checkout,refund,recon,report/stories: checkout,refund,recon,report,bad-review/' "$B"
rc=0; out="$("$BIN/ac-ready.sh" validate payv2)" || rc=$?
assert_contains "$out" "INVALID id bad-review" "reserved suffix rejected"
assert_contains "$out" "MISSING story line for bad-review" "unregistered story rejected"
[ "$rc" != 0 ] || fail "invalid map must exit nonzero"
perl -pi -e 's/stories: checkout,refund,recon,report,bad-review/stories: checkout,refund,recon,report/' "$B"
perl -pi -e 's/^- \[x\] refund - refund API - PR url \(merged 2026-07-15\)$//' "$B"
printf -- '- [ ] refund - refund API; epic:payv2 blocked-by: recon - CYCLE test\n' >>"$B"
rc=0; out="$("$BIN/ac-ready.sh" validate payv2)" || rc=$?
assert_contains "$out" "CYCLE" "cycle detected"
[ "$rc" != 0 ] || fail "cyclic map must exit nonzero"
# A blocker named twice is one edge: counted twice, it kept the story's
# in-degree above zero once its only blocker was removed - a CYCLE with no cycle.
perl -pi -e 's/blocked-by: recon - CYCLE test$/blocked-by: checkout,checkout - named twice/' "$B"
rc=0; out="$("$BIN/ac-ready.sh" validate payv2)" || rc=$?
assert_eq "$out" "map OK: 4 stories, DAG acyclic" "a blocker named twice is one edge, never a cycle"
assert_eq "$rc" "0" "a map whose only oddity is a repeated blocker validates"

# overlap: the intake file-interlock check - LANDED (<7d ledger hits with the
# prior family's room), INFLIGHT (crew/* branch diffs vs the default branch),
# BRIEF (in-flight briefs naming the path); nothing when clean.
now="$(date +%s)"
printf '%s\tdrain-race\tsrc/app.js\n%s\tancient\tsrc/app.js\n' \
  "$((now - 7200))" "$((now - 8 * 86400))" >"$AC_HOME/state/.landings"
repo="$AC_HOME/projects/shop"
git init -q -b main "$repo"
git -C "$repo" config user.email test@test
git -C "$repo" config user.name test
printf 'base\n' >"$repo/base.txt"
git -C "$repo" add -A && git -C "$repo" commit -qm init
git -C "$repo" checkout -q -b crew/wip
mkdir -p "$repo/src" && printf 'wip\n' >"$repo/src/app.js"
git -C "$repo" add -A && git -C "$repo" commit -qm wip
git -C "$repo" checkout -q main
mkdir -p "$AC_HOME/data/livetask" "$AC_HOME/data/deadtask"
printf 'touch src/app.js please\n' >"$AC_HOME/data/livetask/brief.md"
printf 'also names src/app.js\n' >"$AC_HOME/data/deadtask/brief.md"
printf 'kind=ship\n' >"$AC_HOME/state/livetask.meta"          # in flight
out="$("$BIN/ac-ready.sh" overlap src/app.js)"
assert_contains "$out" "LANDED  src/app.js by drain-race" "ledger hit <7d reported with its family"
assert_contains "$out" "data/drain-race/room.md" "ledger hit names the room as required reading"
case "$out" in *ancient*) fail "a >7d ledger record is not an overlap" ;; esac
assert_contains "$out" "INFLIGHT  src/app.js on crew/wip (repo: shop)" "in-flight crew branch diff reported"
assert_contains "$out" "BRIEF  src/app.js named in in-flight data/livetask/brief.md" "in-flight brief naming the path reported"
case "$out" in *deadtask*) fail "a brief with no live meta is not in flight" ;; esac
assert_eq "$("$BIN/ac-ready.sh" overlap docs/clean.md)" "" "clean path prints nothing"
# Silence means clean, so a check that cannot find its home must refuse.
assert_fails_with "AC_HOME is not set" -- env -u AC_HOME "$BIN/ac-ready.sh" overlap src/app.js

# The room the overlap hit names is REQUIRED READING (intake-triage skill), and
# an overlapping family has landed - the exact class bin/ac-archive.sh moves.
# The pointer must therefore resolve to where the room actually IS, or the
# intake check sends the next chief to a path that no longer exists.
mkdir -p "$AC_HOME/data/archive/2026/drain-race"
printf '# Room: drain-race\n\n- [2026-07-01T00:00:00Z] crewchief> CLOSED: landed\n' \
  >"$AC_HOME/data/archive/2026/drain-race/room.md"
out="$("$BIN/ac-ready.sh" overlap src/app.js)"
assert_contains "$out" "data/archive/2026/drain-race/room.md" \
  "an ARCHIVED family's overlap pointer names its archived room"
room_pointer="$(printf '%s\n' "$out" | sed -n 's/.*- read \(.*\)$/\1/p')"
assert_file "$room_pointer" "the pointer the overlap check prints is a path that exists"

# watch-set: the roomchief's read-only AC_WATCH_ONLY computation - its own
# family id plus its IN-FLIGHT story family ids (reusing the epic/story
# grammar), so its scoped watcher covers the story crewmate panes it owns.
# Recomputed at each re-arm, so it tracks stories as they start and land
# (behavior: epic-roomchief-watch-only-omits-story-ids). A NON-epic family
# (no stories of its own) computes to EXACTLY its family id - byte-identical to
# the pre-epic single-family arming.
cat >"$B" <<'EOF'
# Backlog

## In flight
- [ ] payv2 [EPIC] - payments v2 stories: checkout,refund,recon (repo: shop, since 2026-07-20)
- [ ] checkout - build checkout; epic:payv2 (repo: shop, since 2026-07-20)
- [ ] recon - reconciliation; epic:payv2 (repo: shop, since 2026-07-20)
- [ ] solowork - an unrelated non-epic family (repo: shop, since 2026-07-20)

## Queued
- [ ] refund - refund API; epic:payv2 (repo: shop)

## Done
EOF
assert_eq "$("$BIN/ac-ready.sh" watch-set payv2)" "payv2,checkout,recon" \
  "an epic computes its family id plus its IN-FLIGHT stories, in backlog order (a QUEUED story is not watched)"
assert_eq "$("$BIN/ac-ready.sh" watch-set solowork)" "solowork" \
  "a non-epic family computes to exactly its family id (byte-identical to today)"
assert_eq "$("$BIN/ac-ready.sh" watch-set neverheard)" "neverheard" \
  "a family with no backlog line still computes to exactly its id (safe default)"

# Intra-family fan-out (rooms-threads skill): a roomchief fanning out into one
# execution crewmate per sub-deliverable spawns `<family>-<slug>` ids directly
# (never a backlog `epic:` story), so watch-set for the family still computes
# to EXACTLY the family id - the same non-epic case as `solowork` above. That
# is sufficient: ac-watch.sh's in_scope <fam>-* prefix match (tests/sh/ac-watch.
# test.sh) admits any `<family>-<slug>` pane under that one id, no matter what
# the slug is - no watch-set change needed for fan-out coverage.
assert_eq "$("$BIN/ac-ready.sh" watch-set fanfam)" "fanfam" \
  "a fan-out family (sub-deliverables spawned directly, no epic stories) still computes to exactly its id"

# Ids are text: awk's == compares numeric-looking strings as numbers, so epic
# 07's story joined epic 7's watch set and row 01 answered for story 1.
perl -0777 -pi -e 's/(## In flight\n)/$1- [ ] s7 - a story of epic 07; epic:07 (repo: shop, since 2026-07-20)\n- [ ] 7 [EPIC] - a numeric epic stories: 1 (repo: shop, since 2026-07-20)\n/' "$B"
perl -0777 -pi -e 's/(## Queued\n)/$1- [ ] 01 - an unrelated row that reads as the same number (repo: shop)\n/' "$B"
assert_eq "$("$BIN/ac-ready.sh" watch-set 7)" "7" "watch-set 7 never takes epic 07's story"
rc=0; out="$("$BIN/ac-ready.sh" validate 7)" || rc=$?
assert_contains "$out" "MISSING story line for 1" "validate never takes row 01 for story 1"
[ "$rc" != 0 ] || fail "a map naming a story with no row must exit nonzero"

# Captain hold: `[@held]` refuses to offer a row, even once every blocker
# lands - the measured bug (brief captain-hold-has-no-machine-representation:
# a live row's dependency list emptied and ac-ready.sh printed
# READY despite a prose-only captain hold). `[@held]` is neither the
# dependency token (no blocker id, no STUCK semantics) nor terminal (nothing
# lands to clear it): fail-closed on a mis-typed attempt, same direction as
# blocked-by malformed, but detection scans every `[...]` group on the line
# (not a bare-word whole-line scan) so a row's own prose about the hold
# FEATURE never holds itself.
# ROUND 2 (roomchief verify probe on 304078b): a rp[2]-only reading of that
# design fails open twice on a live ledger, where rp[2] is usually already
# ANOTHER bracket tag - the nearest-miss spelling (present tense) and a
# well-formed token placed in a SECOND `[...]` group after that existing tag
# both read READY. Fixed by scanning every group, not just rp[2].
# ROUND 3 (roomchief verify probe on 8843ecf): scanning every group on the
# bare word "held"/"hold" REGRESSED a real, live, unheld drydock row -
# dash-review-polish - because this grammar's OTHER bracket tags
# (`[SLICE ...]`, `[CAPTAIN ORDER LANDED ...]`) carry free-text prose that
# uses "held"/"hold" as an ordinary English verb ("the guardrail held").
# Bracket syntax alone cannot distinguish a token from a sentence inside a
# free-text tag. Fixed by matching the `@` SENTINEL (`@held`/`@hold`) instead
# of the bare word - prose never writes it, so a free-text tag's own prose no
# longer trips detection, proven below with the two real phrases verbatim.
# ROUND 4 (roomchief verify probe on 0002de5): the sentinel fix itself
# overcorrected - forgetting the sentinel outright (`[held]`, `[hold]`, the
# single most likely slip on a sentinel-bearing token) now read READY,
# reproducing exactly the failure this task exists to kill. Fixed by a SECOND
# malformed rule: a `[...]` group whose entire content is ONE WORD (no
# whitespace) can never be a free-text tag's prose - a sentence is always
# multi-word - so "held"/"hold" alone in a one-word group is still a hold
# attempt and needs no sentinel to fail closed. Measured zero false positives
# against the live ledger's actual one-word bracket groups.
# ROUND 5 (fold b, captain-hold-has-no-machine-representation-token): rounds
# 1-4 gave the token no way to be QUOTED - any row, receipt, or documentation
# line that WRITES `[@held]` (or a mis-typed shape) becomes indistinguishable
# from the real thing. Fixed by two context signals bracket syntax alone
# cannot supply: POSITION (only the run of `[...]` groups immediately after
# the id - contiguous, no other text between them - can carry AUTHORITY, so
# only a `[@held]` sitting there ever sets hold=1) and a CODE SPAN (a group
# wrapped in backticks is a QUOTATION, exempt from both hold and malformed,
# the same backtick-wrap convention the roomchief kickoff prompt in `bin/ac-spawn.sh` already uses for
# marker verbs). A bare, unquoted token-shaped group OUTSIDE that leading run
# still falls to `hold malformed` rather than READY - the residual fail-open
# of a position-only rule (a real token typed in the wrong place must never
# silently schedule) closed without reopening the round-2 regression (a
# well-formed `[@held]` immediately after an existing tag, still contiguous
# with the id, stays fully authoritative - `taggedheld` below is unchanged).
# ROUND 6 (fix round 1, captain finding on THIS message): the malformed
# printf text stayed the ROUND-1 wording ("`[@held]` exactly, in a `[...]`
# group") after round 5 added two new causes that shape does not describe -
# a well-formed token OUTSIDE the leading run, and an unquoted mention - so
# `wrongplace` (a line that already spells `[@held]` exactly, in a `[...]`
# group) read a malformed notice telling the reader to do exactly what the
# line already does. The malformed direction (loud, fail-closed, refuses to
# schedule AND SAYS WHY) is exactly the property a wrong reason undermines.
# Fixed by naming all three remedies in the one message: the exact shape,
# the leading-run position, and the backtick-quotation escape - no new rule,
# no new field, just an honest printf.
cat >"$B" <<'EOF'
# Backlog

## In flight
- [ ] lastblocker - the campaign's last blocker, still flying (repo: shop, since 2026-08-01)

## Queued
- [ ] heldcampaign [@held] - captain hold; blocked-by: lastblocker - captain paused it (repo: shop)
- [ ] typoheld [@Held] - a mis-typed hold attempt, sentinel present but wrong (repo: shop)
- [ ] mentionsheld - narrates a captain hold policy in prose, no token at all (repo: shop)
- [ ] sliphold [@hold] - the feature's own name, present tense, sentinel present (repo: shop)
- [ ] taggedheld [CAPTAIN-ORDERED 2026-08-06] [@held] - a well-formed hold in a second group, after an existing tag already occupies rp[2] (repo: shop)
- [ ] nosentinel [held] - the sentinel forgotten outright, one word (repo: shop)
- [ ] nosentinel2 [hold] - same slip, present tense (repo: shop)
- [ ] freetextprose [SLICE NOTE - Held until now on a verified collision, both deferred] [CAPTAIN ORDER LANDED - the guardrail held, the sandbox was never loosened] - two real free-text bracket tags using "held" as an ordinary verb (repo: shop)
- [ ] epicheld [EPIC] [@held] - a well-formed [@held] on an EPIC row; stories: a,b (repo: shop)
- [ ] quoteexact - documenting the grammar, the hold token is `[@held]` (AGENTS.md section 9); an ordinary queued row (repo: shop)
- [ ] quotebare - documenting the grammar, the sentinel-forgotten slip looks like `[held]`; an ordinary queued row (repo: shop)
- [ ] wrongplace - forgot to put the token up front, so it sits deep in the reason instead: [@held] misplaced, no backticks (repo: shop)
- [ ] datedfuture [@held until 2099-01-01] - the dated arm, not yet expired (repo: shop)
- [ ] datedpast [@held until 2000-01-01] - the dated arm, expired long ago (repo: shop)
- [ ] datedbad [@held until soon] - a dated hold whose date is not a date (repo: shop)
- [ ] datedslash [@held until 2099/01/01] - a dated hold with the wrong separator (repo: shop)
- [ ] datedwrongplace - the dated token deep in the reason instead: [@held until 2099-01-01], no backticks (repo: shop)
- [ ] datedquote - documenting the dated arm, which is written `[@held until 2099-01-01]`; an ordinary queued row (repo: shop)

## Done
EOF

out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "HELD   heldcampaign" "(b) a held row still appears in the report, labelled HELD"
# ROUND 7 (task hold-position-rule-has-no-assertion): round 5 made POSITION
# decide authority, but no assertion ever forced `positional = 0` red - every
# existing HELD assertion above matches on the bare `HELD   <id>` prefix,
# which a genuine hold and a hold_malformed misdiagnosis both share, so
# disabling position leaves this file green while heldcampaign silently
# degrades from a genuine hold to a malformed misdiagnosis. Assert the FULL
# distinguishing message instead of the shared prefix, and assert the
# malformed shape is absent.
assert_contains "$out" "HELD   heldcampaign - captain hold; release is a captain act (docs/backlog.md)" "(round 7) a leading-run [@held] row reports the genuine captain-hold message in full, not just the HELD prefix a malformed misdiagnosis also shares"
case "$out" in *"HELD   heldcampaign hold malformed"*) fail "(round 7) a leading-run [@held] row must never be misdiagnosed as hold malformed" ;; esac
assert_contains "$out" "HELD   typoheld hold malformed" "(c) a mis-typed hold token yields HELD, never READY"
assert_contains "$out" "READY  mentionsheld" "(d) a row that merely mentions the hold feature in prose is not held"
assert_contains "$out" "HELD   sliphold hold malformed" "(round 2, finding 1) [@hold] - the feature's own present-tense name - yields HELD, never READY"
assert_contains "$out" "HELD   taggedheld" "(round 2, finding 2) a well-formed [@held] after an existing rp[2] tag still yields HELD, never READY"
assert_contains "$out" "HELD   nosentinel hold malformed" "(round 4, finding 4) [held] with the sentinel forgotten outright still yields HELD, never READY"
assert_contains "$out" "HELD   nosentinel2 hold malformed" "(round 4, finding 4) [hold] with the sentinel forgotten outright still yields HELD, never READY"
assert_contains "$out" "READY  freetextprose" "(round 3, assertion e) real free-text bracket prose using \"held\" as an ordinary verb is not held"
assert_contains "$out" "HELD   epicheld" "(round 5, B3) a well-formed [@held] on an [EPIC] row still holds"
assert_contains "$out" "READY  quoteexact" "(round 5, B1) a row that quotes the exact token in a code span is not held"
assert_contains "$out" "READY  quotebare" "(round 5, B2) a row that quotes a mis-typed hold shape in a code span is not read as malformed"
assert_contains "$out" "HELD   wrongplace hold malformed" "(round 5, residual) a bare unquoted token-shaped group outside the leading run falls to malformed, never silently READY"
wrongplace_line="$(printf '%s\n' "$out" | grep "^HELD   wrongplace ")"
case "$wrongplace_line" in *"leading run"*) ;; *) fail "(round 6, finding 1) the malformed message must name the leading-run remedy, not just repeat the shape a well-formed token already has" ;; esac
case "$wrongplace_line" in *"backtick"*) ;; *) fail "(round 6, finding 1) the malformed message must name the backtick-quotation remedy for an unquoted mention" ;; esac
case "$out" in *"STUCK  heldcampaign"*) fail "a hold is not the dependency token - it must never read as STUCK" ;; esac
case "$out" in *"READY  heldcampaign"*) fail "a held row must never read READY while its blocker still flies" ;; esac
case "$out" in *"READY  typoheld"*) fail "a mis-typed hold token must never read READY" ;; esac
case "$out" in *"READY  sliphold"*) fail "(round 2, finding 1) [@hold] must never read READY" ;; esac
case "$out" in *"READY  taggedheld"*) fail "(round 2, finding 2) a tagged row's [@held] must never read READY" ;; esac
case "$out" in *"STUCK  taggedheld"*) fail "(round 2, finding 2) a held row is not the dependency token - it must never read as STUCK" ;; esac
case "$out" in *"READY  nosentinel"*) fail "(round 4, finding 4) [held]/[hold] with no sentinel must never read READY" ;; esac
case "$out" in *"HELD   freetextprose"*) fail "(round 3) a free-text tag's ordinary use of \"held\"/\"hold\" must never read HELD" ;; esac
case "$out" in *"READY  epicheld"*) fail "(round 5, B3) an [EPIC] row's real hold must never read READY" ;; esac
case "$out" in *"HELD   quoteexact"*) fail "(round 5, B1) quoting the exact token in a code span must never enact a hold" ;; esac
case "$out" in *"HELD   quotebare"*) fail "(round 5, B2) quoting a mis-typed shape in a code span must never read as malformed" ;; esac
case "$out" in *"READY  wrongplace"*) fail "(round 5, residual) an out-of-position bare token must never silently read READY" ;; esac
case "$out" in *"STUCK  wrongplace"*) fail "(round 5, residual) an out-of-position hold-shaped group is not the dependency token - never STUCK" ;; esac
# The DATED arm (docs/backlog.md): the ONE hold that releases itself. It
# inherits every property of the bare token - leading-run position, sentinel,
# code-span exemption - and adds exactly one: the date decides, and a date
# that is not a date is a mis-typed hold, never an accidental release.
assert_contains "$out" "HELD   datedfuture - captain hold until 2099-01-01; it releases itself on that date (docs/backlog.md)" "an unexpired dated hold is HELD, and the line names the date so the captain need not open the ledger"
assert_contains "$out" "READY  datedpast" "a dated hold whose date has passed is READY again, with no hand-edit"
assert_contains "$out" "HELD   datedbad hold malformed" "a dated hold whose date is not a date falls to malformed, never READY"
assert_contains "$out" "HELD   datedslash hold malformed" "a dated hold with the wrong date separator falls to malformed, never READY"
assert_contains "$out" "HELD   datedwrongplace hold malformed" "a dated token outside the leading run falls to malformed, exactly like the bare one"
assert_contains "$out" "READY  datedquote" "a code-span quotation of the dated arm never holds the row that documents it"
case "$out" in *"READY  datedfuture"*) fail "an unexpired dated hold must never read READY" ;; esac
case "$out" in *"HELD   datedpast"*) fail "an expired dated hold must not stay HELD - the date IS the release" ;; esac
case "$out" in *"READY  datedbad"*) fail "a malformed dated hold must never read READY" ;; esac
case "$out" in *"HELD   datedquote"*) fail "quoting the dated arm in a code span must never enact a hold" ;; esac
qout="$("$BIN/ac-ready.sh" queued)"
grep -qx datedpast <<<"$qout" || fail "an expired dated hold must be OFFERED by queued, not just reported READY"
grep -qx datedfuture <<<"$qout" && fail "an unexpired dated hold must never be offered by queued"
grep -qx datedbad <<<"$qout" && fail "a malformed dated hold must never be offered by queued"

queued_out="$("$BIN/ac-ready.sh" queued)"
case "$queued_out" in *heldcampaign*) fail "the queued selector must never offer a held row" ;; esac
case "$queued_out" in *typoheld*) fail "the queued selector must never offer a mis-typed hold row" ;; esac
case "$queued_out" in *sliphold*) fail "(round 2, finding 1) the queued selector must never offer [@hold]" ;; esac
case "$queued_out" in *taggedheld*) fail "(round 2, finding 2) the queued selector must never offer a tagged row's [@held]" ;; esac
case "$queued_out" in *nosentinel*) fail "(round 4, finding 4) the queued selector must never offer [held]/[hold] with no sentinel" ;; esac
case "$queued_out" in *epicheld*) fail "(round 5, B3) the queued selector must never offer an [EPIC] row carrying a real hold" ;; esac
case "$queued_out" in *wrongplace*) fail "(round 5, residual) the queued selector must never offer an out-of-position hold-shaped row" ;; esac
assert_contains "$queued_out" "mentionsheld" "a row merely mentioning the hold feature stays startable via queued too"
assert_contains "$queued_out" "freetextprose" "(round 3) real free-text bracket prose stays startable via queued too"
assert_contains "$queued_out" "quoteexact" "(round 5, B1) quoting the exact token in a code span keeps the row startable via queued too"
assert_contains "$queued_out" "quotebare" "(round 5, B2) quoting a mis-typed hold shape in a code span keeps the row startable via queued too"

# (a) land the row's LAST blocker - the exact measured failure: an emptied
# dependency list must not make a held row READY.
perl -pi -e "s/^- \[ \] lastblocker - the campaign's last blocker.*\n//" "$B"
perl -0777 -pi -e 's/(## Done\n)/$1- [x] lastblocker - the campaign\x27s last blocker - PR url (merged 2026-08-01)\n/' "$B"
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "HELD   heldcampaign" "(a) blocker landed, hold still refuses to offer the row"
case "$out" in *"READY  heldcampaign"*) fail "(a) a landed blocker must never override a captain hold" ;; esac
case "$("$BIN/ac-ready.sh" queued)" in *heldcampaign*) fail "(a) queued must still never offer the held row once its blocker lands" ;; esac

# ---- crewdomain-token: domain rows are promote-only ------------------------
# The auto-fly rule is defined over the report, and `queued` feeds auto-fly
# and teardown's next-promote - so a domain row (own token, or inherited via
# its epic) must SAY its start action in the report and never be offered by
# the pipeable selector (red-team mitigation: no double-scheduling past the
# domain binding).
cat >"$AC_HOME/records/backlog.md" <<'DEOF'
## In flight

## Queued
- [ ] dompay - do it; domain:payments (repo: alpha)
- [ ] domstory - s; epic:dompay (repo: alpha)
- [ ] plainrow - normal (repo: alpha)

## Done
DEOF
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "READY  dompay {domain:payments - start = promote its domainchief}" \
  "a domain row is READY with its start action named"
assert_contains "$out" "READY  domstory (epic:dompay) {domain:payments" \
  "a story INHERITS its epic row's domain in the report"
q="$("$BIN/ac-ready.sh" queued)"
assert_eq "$q" "plainrow" "queued never offers a domain row - promote is its only start"

# An unreadable ledger fails the report: an empty one is what "nothing to
# start" looks like, and the hook callers turn a failure into a WARN line.
# Skipped under root, which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$AC_HOME/records/backlog.md"
  rc=0; "$BIN/ac-ready.sh" >/dev/null 2>&1 || rc=$?
  chmod 644 "$AC_HOME/records/backlog.md"
  [ "$rc" != 0 ] || fail "an unreadable ledger must fail the report, never print an empty one"
fi

# The grammar is byte-exact ASCII, so a byte that is not UTF-8 (a Latin-1 e
# acute) is prose like any other - under a UTF-8 locale it aborted the walk.
printf '## In flight\n\n## Queued\n- [ ] q1 - a plain row (repo: alpha)\n- [ ] q2 - caf\351 menu (repo: alpha)\n\n## Done\n' \
  >"$AC_HOME/records/backlog.md"
rc=0; out="$(LC_ALL=en_US.UTF-8 "$BIN/ac-ready.sh")" || rc=$?
assert_eq "$rc:$out" "0:READY  q1"$'\n'"READY  q2" "a non-UTF-8 byte in a row never aborts the report"
assert_eq "$(LC_ALL=en_US.UTF-8 "$BIN/ac-ready.sh" queued)" "q1"$'\n'"q2" "... nor cuts the queued set short"

# A dated hold is spent on the day date(1) names - ac-task.sh start strips it by
# that clock - so a POSIX TZ string, which the libc reads and ICU does not,
# must decide it the same way here. XYZ-24 is always a day ahead of UTC.
spent="$(TZ=XYZ-24 date +%Y-%m-%d)"
printf '## In flight\n\n## Queued\n- [ ] h1 [@held until %s] - dated (repo: alpha)\n\n## Done\n' "$spent" \
  >"$AC_HOME/records/backlog.md"
assert_eq "$(TZ=XYZ-24 "$BIN/ac-ready.sh")" "READY  h1" "a dated hold is spent on the day date(1) names under the caller's TZ"

# overlap --semantic: the System One fold-or-mint proposer (config/jev). One
# choice question per OPEN row over the order text, all in one request; under
# on it prints Queued rows the model calls related as fold-candidate and In
# flight rows as overlap-flying; Done rows are never asked about.
cat >"$AC_HOME/records/backlog.md" <<'DEOF'
## In flight
- [ ] wf1 - watcher stale arm misses prose asks raised inside a long summary (repo: agent-crew, since 2026-09-01)
  the ended-turn discriminator is the backend idle status, not the tail text

## Queued
- [ ] q1 - CREWMATE-learned.md refuses only a duplicate NAME, not a duplicate lesson (repo: agent-crew)
- [ ] q2 - dashboard review page font colour (repo: agent-crew)

## Done
- [x] d1 - something old (repo: agent-crew) - local main (merged 2026-08-01)
DEOF
mkdir -p "$TMP/stubbin"
cat >"$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; data=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -d) data="$2"; shift ;; esac; shift; done
cat "${data#@}" >"$FAKE_BODY"
n="$(cat "$FAKE_HITS" 2>/dev/null || printf 0)"; printf '%s\n' "$((n + 1))" >"$FAKE_HITS"
cat "$FAKE_RESP" >"$out"
printf '200'
EOF
chmod +x "$TMP/stubbin/curl"
export PATH="$TMP/stubbin:$PATH" FAKE_BODY="$TMP/body" FAKE_HITS="$TMP/hits" FAKE_RESP="$TMP/resp"
printf '%s\n' '{"model":"m","answers":{"wf1":{"type":"choice","choice":"related","probabilities":{"related":0.9,"unrelated":0.05,"unclear":0.05},"confidence":0.8},"q1":{"type":"choice","choice":"related","probabilities":{"related":0.7,"unrelated":0.2,"unclear":0.1},"confidence":0.6},"q2":{"type":"choice","choice":"unrelated","probabilities":{"related":0.1,"unrelated":0.8,"unclear":0.1},"confidence":0.7}},"usage":{"input_tokens":1,"output_tokens":0}}' >"$FAKE_RESP"
printf '{"openrouter":{"api_key":"sk-or-TEST"}}\n' >"$AC_HOME/config/providers.json"
hits() { cat "$FAKE_HITS" 2>/dev/null || printf 0; }
order='a crewmate that asks the chief a question in prose is read as merely quiet'

rm -f "$AC_HOME/config/jev"
out="$("$BIN/ac-ready.sh" overlap --semantic "$order" 2>&1)" || fail "semantic: absent knob must exit 0"
assert_eq "$out" "" "semantic: absent knob prints nothing"
assert_eq "$(hits)" "0" "semantic: absent knob makes no request"

printf 'shadow\n' >"$AC_HOME/config/jev"
out="$("$BIN/ac-ready.sh" overlap --semantic "$order" 2>/dev/null)"
assert_eq "$out" "" "semantic: shadow prints nothing"
assert_eq "$(hits)" "1" "semantic: one request for every open row"
assert_eq "$(jq -r '.questions | keys | join(",")' "$FAKE_BODY")" "q1,q2,wf1" "semantic: one question per open row, none for Done"
assert_eq "$(jq -r '.questions.q1.criteria | keys | join(",")' "$FAKE_BODY")" "related,unclear,unrelated" "semantic: the three verdicts"
assert_contains "$(jq -r '.questions.q1.criteria.related' "$FAKE_BODY")" "same file surface, the same mechanism, or the same defect class" "semantic: docs/backlog.md's rule is the criterion"
st="$(jq -r '.state' "$FAKE_BODY")"
assert_contains "$st" "$order" "semantic: the order is in the state"
assert_contains "$st" "watcher stale arm misses prose asks" "semantic: the row line is in the state"
assert_contains "$st" "the ended-turn discriminator is the backend idle status" "semantic: the row body is in the state"
case "$st" in *"something old"*) fail "semantic: a Done row must not be in the state" ;; esac
assert_eq "$(tail -n1 "$AC_HOME/state/jev-shadow.jsonl" | jq -r '.site')" "overlap" "semantic: shadow record site"

printf 'on\n' >"$AC_HOME/config/jev"
out="$("$BIN/ac-ready.sh" overlap --semantic "$order" 2>/dev/null)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "overlap-flying  wf1  p=0.9" "semantic: an In flight related row is overlap-flying, ledger order first"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "fold-candidate  q1  p=0.7" "semantic: a Queued related row is a fold candidate"
case "$out" in *q2*) fail "semantic: an unrelated row is not printed" ;; esac
assert_contains "$(printf '%s\n' "$out" | tail -n1)" "state_sha=" "semantic: the label key closes the output"
assert_fails "$BIN/ac-ready.sh" overlap --semantic
assert_fails "$BIN/ac-ready.sh" overlap --semantic ""

# --- differential leg: src/ready.ts against the frozen bash original ---------
# The frozen original (tests/fixtures/ac-ready.sh, run from an oracle bin
# beside the live scripts) and the shim answer each row in a world rebuilt from
# nothing before each side. The report, queued, watch-set and validate start
# src/ready.ts on both sides, so their rows pin the dispatch; overlap is the
# ported verb. Both sides run the real bin/ac-jev.sh (the oracle bin's copy
# beside the original) with the leg's curl stub answering, and the request
# body, the hit count and the shadow log are compared too. A divergence the
# port keeps on purpose is asserted on both sides, where it is.
# DISPUTED: the implementation (tests/fixtures/ac-ready.sh under bash vs src/ready.ts through bin/ac-ready.sh)
# HELD-CONSTANT: one world path ($XW: home/, cwd/, tmp/ the TMPDIR, hh/ the HOME, log/ the stub's) rebuilt by the row's world function before each side, git repos copied from one template; argv; env (AC_HOME=$XW/home unless the row is homeless or names another, LC_ALL=C unless the row names en_US.UTF-8, EPOCHSECONDS fixed, TMPDIR=$XW/tmp, HOME=$XW/hh, PATH the leg's curl stub before the suite's unless the row names one, FAKE_BODY/FAKE_HITS/FAKE_RESP the stub's; AC_JEV, AC_JEV_ENDPOINT, CDPATH, LANG, LC_CTYPE, AC_FLEET_STATE and AC_SCOPE unset); cwd ($XW/cwd, deleted first where the row says); stdin (/dev/null); exit status, stdout and stderr compared whole, then the home's tree (paths), TMPDIR's listing, the request body, the hit count and the shadow log less its instants.
xobin="$(make_oracle_bin ac-ready)"
cmp -s "$xobin/ac-ready.sh" "$ROOT/tests/fixtures/ac-ready.sh" || fail "the oracle bin holds the frozen original"
XW="$TMP/xw"; XS="$TMP/xstubs"; XT0="$TMP/xtemplate"
mkdir -p "$XS" "$XT0"
cat >"$XS/curl" <<'STUB'
#!/usr/bin/env bash
out=""; data=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -d) data="$2"; shift ;; esac; shift; done
cat "${data#@}" >"$FAKE_BODY"
n="$(cat "$FAKE_HITS" 2>/dev/null || printf 0)"; printf '%s\n' "$((n + 1))" >"$FAKE_HITS"
cat "$FAKE_RESP" >"$out"
printf '200'
STUB
chmod +x "$XS/curl"
XNOW=1790000000
# The template repos: shop (default main) with crew/wip touching src/a.js and
# src/é.js and crew/two touching base.txt, crew/same with no change; old
# (default master) with crew/x touching src/a.js; and three repos named for
# the ORDER row, each with crew/o touching ord.txt.
xmkrepo() {  # xmkrepo <dir> <default branch>
  git init -q -b "$2" "$1"
  git -C "$1" config user.email test@test
  git -C "$1" config user.name test
  printf 'base\n' >"$1/base.txt"
  git -C "$1" add -A && git -C "$1" commit -qm init
}
xmkrepo "$XT0/shop" main
git -C "$XT0/shop" checkout -q -b crew/wip
mkdir -p "$XT0/shop/src"; printf 'w\n' >"$XT0/shop/src/a.js"; printf 'e\n' >"$XT0/shop/src/é.js"
git -C "$XT0/shop" add -A && git -C "$XT0/shop" commit -qm wip
git -C "$XT0/shop" checkout -q main
git -C "$XT0/shop" checkout -q -b crew/two
printf 'x\n' >"$XT0/shop/base.txt"; git -C "$XT0/shop" commit -qam two
git -C "$XT0/shop" checkout -q main
git -C "$XT0/shop" branch crew/same
xmkrepo "$XT0/old" master
git -C "$XT0/old" checkout -q -b crew/x
mkdir -p "$XT0/old/src"; printf 'o\n' >"$XT0/old/src/a.js"
git -C "$XT0/old" add -A && git -C "$XT0/old" commit -qm x
git -C "$XT0/old" checkout -q master
for xr in _u A2 b1; do
  xmkrepo "$XT0/$xr" main
  git -C "$XT0/$xr" checkout -q -b crew/o
  printf 'o\n' >"$XT0/$xr/ord.txt"
  git -C "$XT0/$xr" add -A && git -C "$XT0/$xr" commit -qm o
  git -C "$XT0/$xr" checkout -q main
done

XLC=C; XHOMELESS=0; XE=""; XPATH=""; XGONE=0; XRC=0
xside() {  # xside <bin> <prefix> <args...> - one side in the current world
  local bin="$1" p="$2" rc=0 x path="$XS:$PATH"
  shift 2
  [ -z "$XPATH" ] || path="$XPATH"
  local e=("PATH=$path" "LC_ALL=$XLC" "EPOCHSECONDS=$XNOW" "TMPDIR=$XW/tmp" "HOME=$XW/hh"
    "FAKE_BODY=$XW/log/body" "FAKE_HITS=$XW/log/hits" "FAKE_RESP=$XW/resp")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$XW/home")
  for x in $XE; do e+=("$x"); done
  ( cd "$XW/cwd" || exit 97
    [ "$XGONE" = 0 ] || rm -rf "$XW/cwd"
    exec env -u AC_HOME -u AC_JEV -u AC_JEV_ENDPOINT -u CDPATH -u LANG -u LC_CTYPE -u AC_FLEET_STATE -u AC_SCOPE "${e[@]}" "$bin/ac-ready.sh" ${@+"$@"}
  ) </dev/null >"$TMP/$p.out" 2>"$TMP/$p.err" || rc=$?
  # From a deleted cwd every bash prints its own getcwd lines, the original
  # one per cd it ran and the shim fewer (SHELL-OWN): both sides drop them.
  if [ "$XGONE" = 1 ]; then
    grep -av -e '^shell-init: error retrieving current directory' -e '^chdir: error retrieving current directory' "$TMP/$p.err" >"$TMP/$p.err.kept" || true
    mv "$TMP/$p.err.kept" "$TMP/$p.err"
  fi
  {
    printf -- '-- tree\n'
    (cd "$XW/home" 2>/dev/null && find . -path './projects/*' -prune -o -print | LC_ALL=C sort) || true
    printf -- '-- tmp\n'
    ls -A "$XW/tmp" 2>/dev/null || true
    printf -- '-- body\n'
    cat "$XW/log/body" 2>/dev/null || true
    printf -- '-- hits\n'
    cat "$XW/log/hits" 2>/dev/null || true
    printf -- '-- shadow\n'
    [ ! -f "$XW/home/state/jev-shadow.jsonl" ] || jq -c 'del(.ts, .latency_ms)' "$XW/home/state/jev-shadow.jsonl"
  } >"$TMP/$p.world"
  XRC=$rc
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <world fn> <args...> - each side in its own fresh world, nothing compared yet
  local wf="$1"
  shift
  "$wf"; xside "$xobin" xo ${@+"$@"}; XO_RC=$XRC
  "$wf"; xside "$BIN" xn ${@+"$@"}; XN_RC=$XRC
}
xline() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }
xsame() {  # xsame <world fn> <args...> - exit, stdout, stderr and the world alike
  xpair "$@"
  local at; at="$(xline)"
  assert_eq "$XN_RC" "$XO_RC" "ready differential exit for '$*' at line $at"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "ready differential stdout differs for '$*' at line $at: $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
  cmp -s "$TMP/xo.err" "$TMP/xn.err" || fail "ready differential stderr differs for '$*' at line $at: $(diff "$TMP/xo.err" "$TMP/xn.err" | head -n 6)"
  cmp -s "$TMP/xo.world" "$TMP/xn.world" || fail "ready differential world differs for '$*' at line $at: $(diff "$TMP/xo.world" "$TMP/xn.world" | head -n 8)"
}
xrefuse() {  # xrefuse <stderr> <world fn> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"
  shift
  xsame "$@"
  assert_eq "$XN_RC:$(cat "$TMP/xn.out"):$(cat "$TMP/xn.err")" "1::$want" "ready refusal for '$*' at line $(xline)"
}
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err"; }
xseed() { rm -rf "$XW"; mkdir -p "$XW/home" "$XW/cwd" "$XW/tmp" "$XW/hh" "$XW/log"; }
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'

# 1. the dispatch: the ledger verbs reach the module on both sides; any other
#    word binds the home first (homeless: the refusal, exit 1); `overlap`
#    alone is its usage.
w_ledger() {
  xseed; mkdir -p "$XW/home/records"
  printf '## In flight\n- [ ] e1 [EPIC] - stories: s1,s2 (repo: r)\n\n## Queued\n- [ ] s1 - a; epic:e1 (repo: r)\n- [ ] s2 - b; epic:e1 blocked-by: s1 - after (repo: r)\n- [ ] q1 - plain (repo: r)\n\n## Done\n' >"$XW/home/records/backlog.md"
}
xsame w_ledger
assert_eq "$(xout)" "READY  s1 (epic:e1)
READY  q1" "row 1: the report"
xsame w_ledger queued
xsame w_ledger queued extra
xsame w_ledger watch-set e1
xsame w_ledger validate e1
xsame w_ledger validate
xsame w_ledger ''
XHOMELESS=1 xrefuse "$XNOHOME" w_ledger overlap a
XHOMELESS=1 xrefuse "$XNOHOME" w_ledger bogus
XHOMELESS=1 xrefuse "$XNOHOME" w_ledger -h
XE="AC_HOME=" xrefuse "$XNOHOME" w_ledger overlap a
xrefuse "ERROR: usage: ac-ready.sh overlap <path>..." w_ledger overlap
xrefuse "ERROR: usage: ac-ready.sh overlap --semantic '<order text>'" w_ledger overlap --semantic
xrefuse "ERROR: usage: ac-ready.sh overlap --semantic '<order text>'" w_ledger overlap --semantic '' more
# USAGE HEADER, named: each side prints its own header on stdout, exit 2.
for xa in bogus -h --help; do
  xpair w_ledger "$xa"
  assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.err")$(xerr)" "2:2:" "USAGE HEADER: '$xa' is the usage on both sides"
  assert_eq "$(cat "$TMP/xo.out")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-ready.sh" | sed 's/^# \{0,1\}//')" "USAGE HEADER: the original printed its own header"
  assert_eq "$(xout)" "$(awk '!/^\/\//{exit} {sub(/^\/\/ ?/, ""); print}' "$ROOT/src/ready.ts")" "USAGE HEADER: the port prints src/ready.ts's header"
done
# HOME RESOLUTION, named: an AC_HOME cd cannot enter is the shell's cd line
# there and the named ERROR here; a relative one is read from a named cwd and
# refused from a cwd that has no name.
XE="AC_HOME=$XW/nope" xpair w_ledger overlap a
assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "1:1:" "HOME RESOLUTION: an unenterable home fails both sides"
assert_contains "$(cat "$TMP/xo.err")" "cd: $XW/nope: No such file or directory" "HOME RESOLUTION: the original printed cd's line"
assert_eq "$(xerr)" "ERROR: AC_HOME is not a readable directory: $XW/nope" "HOME RESOLUTION: the port names the variable"
w_relhome() { w_ledger; mv "$XW/home" "$XW/cwd/h"; }
XE="AC_HOME=h" xsame w_relhome overlap a
XGONE=1 XE="AC_HOME=h" xpair w_relhome overlap a
assert_eq "$XO_RC:$XN_RC" "1:1" "HOME RESOLUTION: a relative home from a nameless cwd fails both sides"
assert_eq "$(xerr)" "ERROR: the current directory cannot be resolved, so a relative AC_HOME cannot be either" "HOME RESOLUTION: the port refuses it"

# 2. overlap <path>... on an empty home: nothing printed, state/ projects/ and
#    data/ minted (records/ not).
xsame xseed overlap src/a.js
assert_contains "$(cat "$TMP/xn.world")" "./data
./projects
./state" "row 2: the dirs the lookups mint"

# 3. LANDED: a record younger than 7 days by the pinned clock, an older one,
#    one with an EMPTY family (never reported), a numeric family, a family
#    with a space, a future record, a path not asked, an archived room; then
#    an unreadable ledger (exit 2; SHELL-OWN, named: awk's own lines).
w_landed() {
  xseed; mkdir -p "$XW/home/state" "$XW/home/data/archive/2026/arch"
  printf '# Room: arch\n' >"$XW/home/data/archive/2026/arch/room.md"
  {
    printf '%s\tfamA\tsrc/a.js\n' "$((XNOW - 7200))"
    printf '%s\told\tsrc/a.js\n' "$((XNOW - 8 * 86400))"
    printf '%s\t\tsrc/a.js\n' "$((XNOW - 60))"
    printf '%s\t07\tsrc/b.js\n' "$((XNOW - 100))"
    printf '%s\tfam B\tsrc/a.js\n' "$((XNOW - 50))"
    printf '%s\tfuture\tsrc/a.js\n' "$((XNOW + 7300))"
    printf '%s\tother\tsrc/c.js\n' "$((XNOW - 10))"
    printf '%s\tarch\tsrc/b.js\n' "$((XNOW - 3 * 3600))"
  } >"$XW/home/state/.landings"
}
xsame w_landed overlap src/a.js src/b.js
assert_eq "$(xout)" "LANDED  src/a.js by famA 2h ago - read $XW/home/data/famA/room.md
LANDED  src/b.js by 07 0h ago - read $XW/home/data/07/room.md
LANDED  src/a.js by fam B 0h ago - read $XW/home/data/fam B/room.md
LANDED  src/a.js by future -2h ago - read $XW/home/data/future/room.md
LANDED  src/b.js by arch 3h ago - read $XW/home/data/archive/2026/arch/room.md" "row 3: the LANDED lines, byte for byte"
xsame w_landed overlap src/a.js src/a.js
if [ "$(id -u)" != 0 ]; then
  w_landed_locked() { w_landed; chmod 000 "$XW/home/state/.landings"; }
  xpair w_landed_locked overlap src/a.js
  assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "2:2:" "SHELL-OWN: an unreadable landing ledger ends both 2, before any line"
  assert_contains "$(cat "$TMP/xo.err")" "awk: can't open file" "SHELL-OWN: the original's line is awk's"
  assert_eq "$(xerr)" "" "SHELL-OWN: the port prints none"
fi

# 4. INFLIGHT and BRIEF: two repos and a non-repo dir, a file and a dot entry
#    in projects/; briefs live and dead, a brief.md that is a directory, a
#    dot dir, `a` and `a-b` (ordered by the whole path's bytes); an empty
#    path, a path holding a LF, a quoted non-ASCII name.
w_inflight() {
  xseed; mkdir -p "$XW/home/projects" "$XW/home/state" "$XW/home/data"
  cp -R "$XT0/shop" "$XT0/old" "$XW/home/projects/"
  mkdir -p "$XW/home/projects/notrepo" "$XW/home/projects/.hidden"
  printf 'f\n' >"$XW/home/projects/afile"
  for b in live a a-b .dot; do mkdir -p "$XW/home/data/$b"; printf 'touch src/a.js and base.txt\n' >"$XW/home/data/$b/brief.md"; : >"$XW/home/state/$b.meta"; done
  mkdir -p "$XW/home/data/dead" "$XW/home/data/dirbrief/brief.md"
  printf 'src/a.js\n' >"$XW/home/data/dead/brief.md"
  : >"$XW/home/state/dirbrief.meta"
  printf 'empty-line-free\n' >"$XW/home/data/live/notes.md"
}
xsame w_inflight overlap src/a.js base.txt "src/é.js"
assert_eq "$(xout)" "INFLIGHT  src/a.js on crew/x (repo: old)
INFLIGHT  base.txt on crew/two (repo: shop)
INFLIGHT  src/a.js on crew/wip (repo: shop)
BRIEF  src/a.js named in in-flight data/a-b/brief.md
BRIEF  base.txt named in in-flight data/a-b/brief.md
BRIEF  src/a.js named in in-flight data/a/brief.md
BRIEF  base.txt named in in-flight data/a/brief.md
BRIEF  src/a.js named in in-flight data/live/brief.md
BRIEF  base.txt named in in-flight data/live/brief.md" "row 4: INFLIGHT and BRIEF, in order"
xsame w_inflight overlap ''
assert_eq "$(xout)" "BRIEF   named in in-flight data/a-b/brief.md
BRIEF   named in in-flight data/a/brief.md
BRIEF   named in in-flight data/live/brief.md" "row 4: an empty path is grep's empty pattern"
xsame w_inflight overlap "$(printf 'zz\nsrc/a.js')"
assert_contains "$(xout)" "INFLIGHT  zz
src/a.js on crew/x (repo: old)" "row 4: a path holding a LF is several patterns"
# grep under a UTF-8 locale finds no path on a line holding a byte that is no
# UTF-8: a spawned grep, so both sides alike.
w_latin() { w_inflight; printf 'caf\351 src/a.js\n' >"$XW/home/data/live/brief.md"; }
XLC=en_US.UTF-8 xsame w_latin overlap src/a.js
case "$(xout)" in *"data/live/brief.md"*) fail "row 4: the latin1 brief line matched under UTF-8" ;; esac
xsame w_latin overlap src/a.js
assert_contains "$(xout)" "BRIEF  src/a.js named in in-flight data/live/brief.md" "row 4: ... and matches under C"
# ORDER, named: under UTF-8 the original's glob collated the repos; the port
# keeps byte order.
w_order() { xseed; mkdir -p "$XW/home/projects"; cp -R "$XT0/_u" "$XT0/A2" "$XT0/b1" "$XW/home/projects/"; }
xsame w_order overlap ord.txt
assert_eq "$(xout)" "INFLIGHT  ord.txt on crew/o (repo: A2)
INFLIGHT  ord.txt on crew/o (repo: _u)
INFLIGHT  ord.txt on crew/o (repo: b1)" "ORDER: byte order under C, both sides"
XLC=en_US.UTF-8 xpair w_order overlap ord.txt
assert_eq "$XO_RC:$XN_RC" "0:0" "ORDER: both run under UTF-8"
assert_eq "$(awk '{print $NF}' "$TMP/xo.out" | tr -d ')' | tr '\n' ' ')" "_u A2 b1 " "ORDER: the original collated the repos under UTF-8"
assert_eq "$(awk '{print $NF}' "$TMP/xn.out" | tr -d ')' | tr '\n' ' ')" "A2 _u b1 " "ORDER: the port keeps byte order"

# 5. overlap --semantic: no ledger, an unreadable ledger, no open row; the
#    knob absent, shadow and on, against one answer; a mktemp that fails.
XRESP_ON='{"model":"m","answers":{"wf1":{"type":"choice","choice":"related","probabilities":{"related":0.9,"unrelated":0.05,"unclear":0.05},"confidence":0.8},"[bad":{"type":"choice","choice":"related","probabilities":{"related":0.99999,"unrelated":0.00001,"unclear":0},"confidence":0.6},"q1":{"type":"choice","choice":"related","probabilities":{"related":1,"unrelated":0,"unclear":0},"confidence":0.6},"q2":{"type":"choice","choice":"unrelated","probabilities":{"related":0.1,"unrelated":0.8,"unclear":0.1},"confidence":0.7}},"usage":{"input_tokens":1,"output_tokens":0}}'
w_sem() {  # w_sem <knob or empty> [<extra Queued row>] - a ledger with rows, bodies and a section change
  xseed; mkdir -p "$XW/home/records" "$XW/home/config" "$XW/home/state"
  [ -z "${1:-}" ] || printf '%s\n' "$1" >"$XW/home/config/jev"
  printf '{"openrouter":{"api_key":"sk-or-TEST"}}\n' >"$XW/home/config/providers.json"
  printf '%s\n' "$XRESP_ON" >"$XW/resp"
  {
    printf '# Backlog\n\n## In flight\n'
    printf -- '- [ ] wf1 - watcher stale arm (repo: agent-crew, since 2026-09-01)\n'
    printf '  the discriminator\twith a tab\t\n'
    printf -- '- [ ] [bad row\t\n'
    printf '\t body after bad row\n'
    printf '## Queued\n'
    printf '  orphan body under queued\n'
    printf -- '- [ ] q1 - learned dup (repo: agent-crew)\n'
    printf -- '- [ ] q2 - font colour (repo: agent-crew)\n'
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    printf '\n'
    printf '## Done\n- [x] d1 - old (repo: agent-crew) - local main (merged 2026-08-01)\n  done body\n'
  } >"$XW/home/records/backlog.md"
}
w_sem_on() { w_sem on; }
w_sem_shadow() { w_sem shadow; }
w_sem_off() { w_sem ""; }
xsame xseed overlap --semantic 'an order'
assert_contains "$(cat "$TMP/xn.world")" "./records" "row 5: records/ is minted"
w_sem_none() { w_sem on; printf '## Queued\n\n## Done\n- [x] d1 - old\n' >"$XW/home/records/backlog.md"; }
xsame w_sem_none overlap --semantic 'an order'
assert_eq "$(xout)$(cat "$XW/log/hits" 2>/dev/null || true)" "" "row 5: no open row asks nothing"
xsame w_sem_off overlap --semantic 'an order'
assert_eq "$(xout)" "" "row 5: the knob absent prints nothing"
xsame w_sem_shadow overlap --semantic 'an order'
assert_eq "$(xout)" "" "row 5: shadow prints nothing"
xsame w_sem_on overlap --semantic "$(printf 'an order\nover two lines')" ignored
assert_eq "$(xout | sed '$d')" "overlap-flying  wf1  p=0.9
overlap-flying  [bad  p=0.99999
fold-candidate  q1  p=1" "row 5: on prints the related rows, ledger order"
assert_contains "$(xout | tail -n 1)" "state_sha=" "row 5: the label key closes it"
assert_eq "$(jq -r .state "$XW/log/body")" "ORDER:
an order
over two lines

OPEN ROWS:
[wf1] (in flight) - [ ] wf1 - watcher stale arm (repo: agent-crew, since 2026-09-01)
  the discriminator	with a tab
[[bad] (in flight) - [ ] [bad row
  body after bad row
  orphan body under queued
[q1] (queued) - [ ] q1 - learned dup (repo: agent-crew)
[q2] (queued) - [ ] q2 - font colour (repo: agent-crew)" "row 5: the state, a body after the section change the last row's"
XE="TMPDIR=$XW/nonexist" xpair w_sem_on overlap --semantic 'an order'
assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "1:1:" "row 5: a mktemp that fails ends both runs with its status"
assert_eq "$(sed 's/semantic\.[A-Za-z0-9]*:/semantic.R:/' "$TMP/xn.err")" "$(sed 's/semantic\.[A-Za-z0-9]*:/semantic.R:/' "$TMP/xo.err")" "row 5: ... and mktemp's own line, its random name aside"
w_sem_dup() { w_sem on '- [ ] q1 - again (repo: agent-crew)'; }
xsame w_sem_dup overlap --semantic 'an order'
assert_eq "$(grep -c '^fold-candidate  q1  ' "$TMP/xn.out")" "2" "row 5: a repeated id is printed twice"
if [ "$(id -u)" != 0 ]; then
  w_sem_locked() { w_sem_on; chmod 000 "$XW/home/records/backlog.md"; }
  xpair w_sem_locked overlap --semantic 'an order'
  assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "2:2:" "SHELL-OWN: an unreadable ledger ends both 2"
  assert_eq "$(xerr)" "" "SHELL-OWN: the port prints none of awk's lines"
fi

# 6. BUN, named: the original's path overlap needed no bun; the shim does.
xnobun="$TMP/xnobun"
mkdir -p "$xnobun"
for x in bash env dirname git grep awk sed mkdir cat rm basename date; do ln -sf "$(command -v "$x")" "$xnobun/$x"; done
XPATH="$xnobun" xpair w_landed overlap src/a.js
assert_eq "$XO_RC:$(head -n 1 "$TMP/xo.out")" "0:LANDED  src/a.js by famA 2h ago - read $XW/home/data/famA/room.md" "BUN: the original answered without bun"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "BUN: the shim refuses"

pass
