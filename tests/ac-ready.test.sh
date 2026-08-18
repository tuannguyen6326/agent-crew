#!/usr/bin/env bash
# ac-ready.test.sh - the queued-work scheduler primitive: READY when blockers
# are all Done clean and the epic is under cap - a plain unblocked item
# included; STUCK on missing/failed blockers; map validation (reserved
# suffixes, missing lines, cycles);
# overlap - the intake file-interlock check (LANDED ledger hits <7d,
# INFLIGHT crew/* branch diffs, BRIEF in-flight briefs; silent when clean).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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

# Marker POSITION, not prose - AGENTS.md section 9 puts the terminal marker
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

# A blocked-by line that slips the pinned grammar (AGENTS.md section 9) reads
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

# The room the overlap hit names is REQUIRED READING (AGENTS.md section 5), and
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

# Intra-family fan-out (AGENTS.md section 5): a roomchief fanning out into one
# execution crewmate per sub-deliverable spawns `<family>-<slug>` ids directly
# (never a backlog `epic:` story), so watch-set for the family still computes
# to EXACTLY the family id - the same non-epic case as `solowork` above. That
# is sufficient: ac-watch.sh's in_scope <fam>-* prefix match (tests/ac-watch.
# test.sh) admits any `<family>-<slug>` pane under that one id, no matter what
# the slug is - no watch-set change needed for fan-out coverage.
assert_eq "$("$BIN/ac-ready.sh" watch-set fanfam)" "fanfam" \
  "a fan-out family (sub-deliverables spawned directly, no epic stories) still computes to exactly its id"

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
# the same backtick-wrap convention `bin/ac-spawn.sh:1096` already uses for
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
assert_contains "$out" "HELD   heldcampaign - captain hold; release is a captain act (AGENTS.md section 9)" "(round 7) a leading-run [@held] row reports the genuine captain-hold message in full, not just the HELD prefix a malformed misdiagnosis also shares"
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

pass

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
