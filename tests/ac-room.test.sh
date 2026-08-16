#!/usr/bin/env bash
# ac-room.test.sh - per-family rooms: post/show, pending accounting
# (GATE/ASK opened, DECIDED settles oldest-first), the captain inbox list.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

"$BIN/ac-room.sh" post widget crewchief "spawned widget-spec (staged)" >/dev/null
"$BIN/ac-room.sh" post widget crewchief "GATE: spec awaiting captain - 13 ACs, recommend approve" >/dev/null
assert_contains "$("$BIN/ac-room.sh" show widget)" "GATE: spec awaiting" "entries recorded"
assert_contains "$("$BIN/ac-room.sh" list)" "PENDING-CAPTAIN(1)" "open gate pending"

"$BIN/ac-room.sh" post widget captain "DECIDED: approve" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list)" "ok" "decided settles the gate"
case "$("$BIN/ac-room.sh" list)" in *PENDING-CAPTAIN*) fail "no pending expected" ;; esac

# Two opens, one decision -> still one pending.
"$BIN/ac-room.sh" post widget crewchief "ASK: rename flag? options a/b, lean a" >/dev/null
"$BIN/ac-room.sh" post widget crewchief "GATE: pre-implement review page ready" >/dev/null
"$BIN/ac-room.sh" post widget captain "DECIDED: a" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list)" "PENDING-CAPTAIN(1)" "oldest-first settling"

# TRIAGE / SELF-APPROVED are receipts: recorded, never pending.
"$BIN/ac-room.sh" post widget crewchief "TRIAGE: flow=staged mode=crew-ship promote=no - why: multi-file, one gate, fleet quiet" >/dev/null
"$BIN/ac-room.sh" post widget crewchief "SELF-APPROVED: spec - grounds: answers the brief, no open needs-decision" >/dev/null
"$BIN/ac-room.sh" post widget crewchief "GATE-PASSED (auto): plan - gate-agent[codex]: approve + chief concur - implement starting" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending widget)" "1" "receipts add no pending"

# GATE-ROUTING: the owning chief records why one exact report stays with the
# chief, receives an independent second-chief challenge, or goes to the captain.
# The command derives the route: captain authority wins; otherwise uncertainty
# OR high consequence invokes the second chief; clear, low-risk work stays local.
mkdir -p "$AC_HOME/data/widget/spec"
printf '# report\nchief-reviewed report.\n' >"$AC_HOME/data/widget/spec/report.md"
report="$AC_HOME/data/widget/spec/report.md"
reportsha="$(shasum -a 256 <"$report" | awk '{print $1}')"
"$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty no \
  --consequence low --authority chief --grounds "Evidence is clear and the decision is reversible." >/dev/null
route_line="$(grep 'GATE-ROUTING:' "$AC_HOME/data/widget/room.md" | tail -1)"
assert_contains "$route_line" "widget-chief> GATE-ROUTING:" "gate routing is posted by the roomchief actor"
assert_contains "$route_line" "report_sha256=$reportsha" "gate routing binds the exact report"
assert_contains "$route_line" "uncertainty=no" "gate routing records uncertainty"
assert_contains "$route_line" "consequence=low" "gate routing records consequence"
assert_contains "$route_line" "authority=chief" "gate routing records authority"
assert_contains "$route_line" "route=chief" "low-risk settled judgment stays with the chief"

"$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty yes \
  --consequence low --authority chief --grounds "Two technically valid options remain." >/dev/null
assert_contains "$(grep 'GATE-ROUTING:' "$AC_HOME/data/widget/room.md" | tail -1)" \
  "route=second-chief" "uncertainty invokes the second chief"

"$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty no \
  --consequence high --authority chief --grounds "A wrong call would cross subsystem contracts." >/dev/null
assert_contains "$(grep 'GATE-ROUTING:' "$AC_HOME/data/widget/room.md" | tail -1)" \
  "route=second-chief" "high consequence invokes the second chief even when the chief is confident"

"$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty no \
  --consequence low --authority captain --grounds "The unresolved choice changes product scope." >/dev/null
assert_contains "$(grep 'GATE-ROUTING:' "$AC_HOME/data/widget/room.md" | tail -1)" \
  "route=captain" "captain-owned authority bypasses second-chief adjudication"
assert_eq "$("$BIN/ac-room.sh" pending widget)" "1" "GATE-ROUTING adds no pending"
assert_fails "$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty maybe --consequence low --authority chief --grounds bad
assert_fails "$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty no --consequence medium --authority chief --grounds bad
assert_fails "$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty no --consequence low --authority mixed --grounds bad
assert_fails "$BIN/ac-room.sh" gate-route widget spec --report "$report" --uncertainty no --consequence low --authority chief --grounds $'multi\nline'

# GATE-VERIFY: structured roomchief pass before a second-chief gate pane. It
# binds family/stage/round, exact current report SHA, pass verdict, and one-line
# grounds; it is informational and adds no pending.
"$BIN/ac-room.sh" gate-verify widget spec --round 1 --report "$report" \
  --grounds "Chief passed the report before R1." >/dev/null
verify_line="$(grep 'GATE-VERIFY:' "$AC_HOME/data/widget/room.md" | tail -1)"
assert_contains "$verify_line" "widget-chief> GATE-VERIFY:" "gate verification is posted by the roomchief actor"
assert_contains "$verify_line" "stage=spec" "gate verification records stage"
assert_contains "$verify_line" "round=1" "gate verification records round"
assert_contains "$verify_line" "report_sha256=$reportsha" "gate verification binds exact report sha"
assert_contains "$verify_line" "verdict=pass" "gate verification records pass verdict"
assert_contains "$verify_line" "grounds=Chief passed" "gate verification records grounds"
assert_eq "$("$BIN/ac-room.sh" pending widget)" "1" "GATE-VERIFY adds no pending"
assert_fails "$BIN/ac-room.sh" gate-verify widget spec --round 3 --report "$report" --grounds bad-round
assert_fails "$BIN/ac-room.sh" gate-verify widget learning --round 1 --report "$report" --grounds bad-stage
assert_fails "$BIN/ac-room.sh" gate-verify widget spec --round 1 --report "$report" --grounds $'multi\nline'

# R1-DISPOSITION: structured roomchief receipt before R2. It binds family/stage,
# exact immutable R1 SHA, an accepted/disputed partition of R1 Required Changes,
# authority, and non-empty grounds; it is informational and adds no pending.
mkdir -p "$AC_HOME/data/widget/spec"
r1="$AC_HOME/data/widget/spec/second-chief-r1.md"
cat >"$r1" <<'EOF'
---
schema: agentcrew.second-chief/v1
decision: revise
engine: codex
round: 1
brief_sha256: 0000000000000000000000000000000000000000000000000000000000000000
report_sha256: 1111111111111111111111111111111111111111111111111111111111111111
previous_review: none
reviewed_at: 2026-07-26T00:00:00Z
---
# Second-Chief Decision
## Summary
Needs revision.
## What Looks Solid
The goal is clear.
## Concerns
Two closure items remain.
## Decision
revise
## Proposed Process
Revise once.
## Grounds
The report lacks two checks.
## Required Changes
1. **Problem** - Missing API test.
   **Evidence** - The report names no API test.
   **Required change** - Add the API test.
   **Closure condition** - The test is named.
2. **Problem** - Missing rollback note.
   **Evidence** - The report names no rollback note.
   **Required change** - Add the rollback note.
   **Closure condition** - The note is named.
## Questions for the Owning Chief
None.
EOF
r1sha="$(shasum -a 256 <"$r1" | awk '{print $1}')"
"$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1 --disputed 2 \
  --authority chief-owned --grounds "Item 1 accepted; item 2 is chief-owned." >/dev/null
disp_line="$(grep 'R1-DISPOSITION:' "$AC_HOME/data/widget/room.md" | tail -1)"
assert_contains "$disp_line" "stage=spec" "disposition records stage"
assert_contains "$disp_line" "r1_sha256=$r1sha" "disposition binds exact R1 sha"
assert_contains "$disp_line" "accepted=1" "disposition records accepted ids"
assert_contains "$disp_line" "disputed=2" "disposition records disputed ids"
assert_contains "$disp_line" "authority=chief-owned" "disposition records authority"
assert_contains "$disp_line" "grounds=Item 1 accepted" "disposition records grounds"
assert_eq "$("$BIN/ac-room.sh" pending widget)" "1" "R1-DISPOSITION adds no pending"
assert_fails "$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1 --disputed 1 --authority chief-owned --grounds overlap
assert_fails "$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1 --disputed none --authority none --grounds missing
assert_fails "$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1,3 --disputed 2 --authority mixed --grounds extra
assert_fails "$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1 --disputed 2 --authority none --grounds bad-authority
assert_fails "$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1,2 --disputed none --authority chief-owned --grounds no-dispute-authority
assert_fails "$BIN/ac-room.sh" disposition widget spec --r1 "$r1" --accepted 1 --disputed 2 --authority chief-owned --grounds $'multi\nline'

# handback: posts the room record, publishes a durable wake (a record in the
# fleet spool), shows in list until DEMOTED/CLOSED settles it.
"$BIN/ac-room.sh" post gizmo crewchief "spawned gizmo (staged)" >/dev/null
"$BIN/ac-room.sh" handback gizmo "landed: PR merged, family torn down" >/dev/null
assert_contains "$(cat "$AC_HOME/data/gizmo/room.md")" "HANDBACK: landed" "handback recorded in the room"
# The nudge is ADVISORY: with no watcher armed it reports the quiet outcome and
# the hand-back still succeeds (the durable record above is the guarantee). The
# nudge mechanism itself is ac_watcher_nudge, covered in ac-done.test.sh.
hbout="$("$BIN/ac-room.sh" handback gizmo "landed: nudge path")"
assert_contains "$hbout" "no armed watcher" "an unwatched hand-back reports the quiet nudge outcome"
assert_contains "$hbout" "handback posted and queued for gizmo" "and the hand-back still succeeds"
assert_contains "$(cat "$AC_HOME/state/.wake-spool"/* 2>/dev/null)" "handback	gizmo-chief" "durable wake published"
assert_contains "$("$BIN/ac-room.sh" list)" "HANDBACK            gizmo" "list surfaces the pending hand-back"
"$BIN/ac-room.sh" post gizmo crewchief "DEMOTED: roomchief closed" >/dev/null
case "$("$BIN/ac-room.sh" list)" in *"HANDBACK            gizmo"*) fail "DEMOTED must settle the hand-back" ;; esac
rm -rf "$AC_HOME/state"/.wake-spool*

# A hand-back is chief-owned, not captain-approval - captain ruling
# ("block boi captain") moved the one captain notification off it: it still
# posts and nudges (both asserted above), it just no longer rings ac-notify.sh.
notify_log="$TMP/notify-handback.log"
notify_hook="$TMP/notify-handback-hook.sh"
cat >"$notify_hook" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$AC_NOTIFY_TITLE" "\$AC_NOTIFY_MESSAGE" >>"$notify_log"
EOF
chmod +x "$notify_hook"
printf 'command:%s\n' "$notify_hook" >"$AC_HOME/config/wedge-alarm"
: >"$notify_log"
"$BIN/ac-room.sh" post gizmo2 crewchief "spawned gizmo2 (staged)" >/dev/null
"$BIN/ac-room.sh" handback gizmo2 "landed: no captain notify" >/dev/null
assert_eq "$(wc -l <"$notify_log" | tr -d ' ')" "0" \
  "handback no longer notifies (chief-owned, not blocked-by-captain)"
printf 'off\n' >"$AC_HOME/config/wedge-alarm"
rm -f "$notify_log" "$notify_hook"
rm -rf "$AC_HOME/state"/.wake-spool*

# A hand-back must wake the CREWCHIEF, so it is filed on the FLEET spool -
# even though it is posted from inside the roomchief's own scoped session.
# Filing it under the family would hand the family's own demotion notice to
# the roomchief that is demoting itself, where nobody would ever drain it.
AC_SCOPE=gizmo "$BIN/ac-room.sh" handback gizmo "landed: second pass" >/dev/null
assert_contains "$(cat "$AC_HOME/state/.wake-spool"/* 2>/dev/null)" "handback	gizmo-chief" \
  "a hand-back from a scoped session still wakes the fleet"
assert_no_file "$AC_HOME/state/.wake-spool.gizmo" "a hand-back is never filed to its own family"
rm -rf "$AC_HOME/state"/.wake-spool*

# pending: the public count (watcher uses it); unknown room = 0.
assert_eq "$("$BIN/ac-room.sh" pending widget)" "1" "pending subcommand counts"
assert_eq "$("$BIN/ac-room.sh" pending nosuchroom)" "0" "unknown room pends 0"

# show <n> tails entries; invalid family refused.
assert_eq "$("$BIN/ac-room.sh" show widget 2 | grep -c '^- \[')" "2" "bounded show"
assert_fails "$BIN/ac-room.sh" post "bad family" crewchief hi
assert_fails "$BIN/ac-room.sh" show nosuchroom

# close: fail-closed on pending gates, in-flight family tasks (incl. an
# un-demoted chief), then posts CLOSED.
assert_fails "$BIN/ac-room.sh" close widget shipped        # 1 pending remains
"$BIN/ac-room.sh" post widget captain "DECIDED: approve" >/dev/null
printf 'kind=ship\n' >"$AC_HOME/state/widget.meta"
assert_fails "$BIN/ac-room.sh" close widget shipped        # task in flight
mv "$AC_HOME/state/widget.meta" "$AC_HOME/state/widget-chief.meta"
assert_fails "$BIN/ac-room.sh" close widget shipped        # chief not demoted
rm -f "$AC_HOME/state/widget-chief.meta"
# Membership is AUTHORITATIVE, never an id prefix - LINK 2 of the cascade that
# made a chief undemotable: an UNRELATED family whose id merely STARTS WITH this
# one (the distro's fixed `learning` room against a `learning-curate-automation`
# epic) held the room open, so the deadlock outlived the demote fix. An epic
# STORY still blocks: it belongs by its meta fleet_scope alone.
printf 'kind=ship\n' >"$AC_HOME/state/widget-curate-automation.meta"
printf 'kind=ship\nfleet_scope=widget\n' >"$AC_HOME/state/storyw.meta"
assert_fails "$BIN/ac-room.sh" close widget shipped        # epic story in flight
rm -f "$AC_HOME/state/storyw.meta"
# A VERIFICATION agent's meta carries a family id but is NOT crew - it holds no
# backlog row and nobody tears it down, so counting it here would let a ship
# reviewer block its own family's room from ever closing. The prefix family is
# still standing here: it is not a member and must not hold the room either.
printf 'kind=verify-codereview\n' >"$AC_HOME/state/widget-review.meta"
"$BIN/ac-room.sh" close widget "shipped to main" >/dev/null
rm -f "$AC_HOME/state/widget-review.meta" "$AC_HOME/state/widget-curate-automation.meta"
assert_contains "$(cat "$AC_HOME/data/widget/room.md")" "CLOSED: shipped to main" "closed entry"
assert_fails "$BIN/ac-room.sh" close nosuchroom "done"

# close removes the family's OWN wake-spool dir once closable (Part 3A) - a
# family outlives its individual tasks, so nothing at teardown ever removes
# it, and it grew by one per promote forever. An EMPTY spool is gone after
# close; a NON-EMPTY one is REFUSED, visibly, and survives.
"$BIN/ac-room.sh" post spoolempty crewchief "spawned spoolempty (staged)" >/dev/null
mkdir -p "$AC_HOME/state/.wake-spool.spoolempty"
"$BIN/ac-room.sh" close spoolempty "landed local-only" >/dev/null
assert_no_file "$AC_HOME/state/.wake-spool.spoolempty" "an empty family spool is removed on close"

"$BIN/ac-room.sh" post spoolfull crewchief "spawned spoolfull (staged)" >/dev/null
mkdir -p "$AC_HOME/state/.wake-spool.spoolfull"
printf 'ts\tkind\tid\tpayload\n' >"$AC_HOME/state/.wake-spool.spoolfull/1.1.000001"
closeerr="$("$BIN/ac-room.sh" close spoolfull "landed local-only" 2>&1)"
assert_contains "$closeerr" "still holds undrained records" "a non-empty spool refusal is visible"
assert_file "$AC_HOME/state/.wake-spool.spoolfull/1.1.000001" "the undrained record itself survives"
assert_contains "$(cat "$AC_HOME/data/spoolfull/room.md")" "CLOSED: landed local-only" \
  "close itself still succeeds despite the spool refusal"
rm -rf "$AC_HOME/state/.wake-spool.spoolfull"

# No spool at all: close is a no-op on that front, no error.
"$BIN/ac-room.sh" post spoolnone crewchief "spawned spoolnone (staged)" >/dev/null
"$BIN/ac-room.sh" close spoolnone "landed local-only" >/dev/null
assert_contains "$(cat "$AC_HOME/data/spoolnone/room.md")" "CLOSED: landed local-only" \
  "close with no spool at all still succeeds"

# Bug 1: a room BOTH pending AND in-handback surfaces both tokens on ONE line -
# PENDING-CAPTAIN(<n>) stays the byte-identical prefix (downstream greps rely on
# it) and HANDBACK is no longer masked behind the gate (it could rot otherwise).
"$BIN/ac-room.sh" post combo crewchief "spawned combo (staged)" >/dev/null
"$BIN/ac-room.sh" post combo crewchief "GATE: spec awaiting captain" >/dev/null
"$BIN/ac-room.sh" handback combo "landed part 1, please close" >/dev/null
combo_line="$("$BIN/ac-room.sh" list | grep combo)"
combo_status="${combo_line%%combo*}"   # the status field, before the family name
assert_contains "$combo_status" "PENDING-CAPTAIN(1)" "combined room keeps the pending token"
assert_contains "$combo_status" "HANDBACK" "combined room surfaces the hand-back in the status field"
case "$combo_status" in "PENDING-CAPTAIN(1)"*) : ;; *) fail "PENDING-CAPTAIN must stay the line prefix" ;; esac
rm -rf "$AC_HOME/state"/.wake-spool*

# The two pre-existing single-token forms keep their fixed 20-char status field
# (only the combined form widens); handback-only is already locked above.
"$BIN/ac-room.sh" post padchk crewchief "GATE: awaiting" >/dev/null
pline="$("$BIN/ac-room.sh" list | grep padchk)"
ppad="${pline%%padchk*}"
assert_eq "${#ppad}" "20" "pending-only status field stays 20 chars wide"
case "$pline" in "PENDING-CAPTAIN(1)  padchk"*) : ;; *) fail "pending-only form byte-identical" ;; esac

"$BIN/ac-room.sh" post okchk crewchief "spawned okchk, no gate" >/dev/null
okline="$("$BIN/ac-room.sh" list | grep okchk)"
okpad="${okline%%okchk*}"
assert_eq "${#okpad}" "20" "neither-case status field stays 20 chars wide"
case "$okline" in "ok"*) : ;; *) fail "neither case must start with ok" ;; esac

# Bug 2: the captain-attribution form `DECIDED <family>: <answer>` (section 8,
# to disambiguate one chat stream across many tasks) settles a pending item,
# exactly like the bare `DECIDED:` form.
"$BIN/ac-room.sh" post attrib crewchief "GATE: spec awaiting captain" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending attrib)" "1" "gate opens one pending"
"$BIN/ac-room.sh" post attrib captain "DECIDED attrib: approve" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending attrib)" "0" "DECIDED <family>: settles the gate"
case "$("$BIN/ac-room.sh" list | grep attrib)" in *PENDING-CAPTAIN*) fail "attributed decision must clear PENDING" ;; esac

# Still requires the colon: a bare `DECIDED` with no colon settles nothing -
# and post now REFUSES to author it (Part 1: a malformed marker never reaches
# the room in the first place).
"$BIN/ac-room.sh" post nocolon crewchief "GATE: awaiting" >/dev/null
assert_fails "$BIN/ac-room.sh" post nocolon captain "DECIDED looks fine but has no colon"
assert_eq "$("$BIN/ac-room.sh" pending nocolon)" "1" "the refused post never reached the room"
# ac_room_pending itself stays tolerant of a malformed line already ON DISK
# (hand-edited, or written before this validator existed) - appended directly,
# bypassing post, to prove the READ-side matcher is unchanged.
printf -- '- [%s] captain> DECIDED looks fine but has no colon\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>"$AC_HOME/data/nocolon/room.md"
assert_eq "$("$BIN/ac-room.sh" pending nocolon)" "1" "bare DECIDED (no colon) on disk still settles nothing"

# SPOOFING: the matcher's actor field is POSITION-pinned, so a marker inside
# the MESSAGE never re-anchors it. The realistic vector is a Slack-quote relay
# (`> ` opening a quoted line): an embedded `> DECIDED:` silently settled a
# real captain gate (the inbox drops an item - fail-open), and an embedded
# `> GATE:` minted a phantom pending that blocks room close. post authors
# these fine - they are legal message TEXT, not markers - so the read-side
# matcher is what must refuse them.
"$BIN/ac-room.sh" post spoof crewchief "GATE: spec awaiting captain" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending spoof)" "1" "gate opens one pending"
"$BIN/ac-room.sh" post spoof crewchief "relaying the captain thread verbatim: > DECIDED: approve" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending spoof)" "1" \
  "a quoted DECIDED inside the message settles nothing"
"$BIN/ac-room.sh" post spoof crewchief "and they quoted me back: > GATE: spec" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending spoof)" "1" \
  "a quoted GATE inside the message mints no phantom pending"
# The genuine markers at the line-opening position still count, both ways.
"$BIN/ac-room.sh" post spoof captain "DECIDED: approve" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending spoof)" "0" "a real DECIDED at the verb position still settles"

# SPOOFING, same shape, two siblings (routed out of ac-lib-shared-helper-
# hardening rather than fixed inline, per Karpathy): ac_room_pending's actor
# field was position-pinned above, but ac_room_review_rulings and
# ac_room_handback_families shared the same greedy `.*> ` and were left
# unpinned. ac_room_handback_families drives `list`'s HANDBACK state directly,
# so it is exercised through the CLI exactly like the pending spoof above.
"$BIN/ac-room.sh" post hbspoof crewchief "spawned hbspoof (direct)" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list | grep hbspoof)" "ok" "no handback yet"
"$BIN/ac-room.sh" post hbspoof crewchief "relaying verbatim: > HANDBACK: fabricated" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list | grep hbspoof)" "ok" \
  "a quoted HANDBACK inside the message body must not fabricate a handback state"
"$BIN/ac-room.sh" handback hbspoof "real handback text" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list | grep hbspoof)" "HANDBACK" "a genuine HANDBACK is still recorded"
"$BIN/ac-room.sh" post hbspoof crewchief "and they quoted me back: > DEMOTED: fabricated" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list | grep hbspoof)" "HANDBACK" \
  "a quoted DEMOTED inside the message body must not clear a real handback"
"$BIN/ac-room.sh" post hbspoof crewchief "DEMOTED: roomchief closed" >/dev/null
case "$("$BIN/ac-room.sh" list | grep hbspoof)" in *HANDBACK*) fail "a real line-opening DEMOTED still settles the handback" ;; esac

# Same spoof, the new HANDBACK-REFUSED: arm: a Slack-quoted `> HANDBACK-REFUSED:`
# inside a message body must not clear a real hand-back either. Checked on the
# STATUS column (field 1, cut on the tab) rather than the whole grep line: the
# `last` column echoes the posted text verbatim, and that text legitimately
# contains the literal substring "HANDBACK" once the verb under test is
# HANDBACK-REFUSED - a whole-line match would pass either way.
hbr_status() { "$BIN/ac-room.sh" list | grep hbrspoof | cut -f1; }
"$BIN/ac-room.sh" handback hbrspoof "real handback text" >/dev/null
assert_contains "$(hbr_status)" "HANDBACK" "a genuine HANDBACK is recorded"
"$BIN/ac-room.sh" post hbrspoof crewchief "and they quoted me back: > HANDBACK-REFUSED: fabricated" >/dev/null
assert_contains "$(hbr_status)" "HANDBACK" \
  "a quoted HANDBACK-REFUSED inside the message body must not clear a real handback"
"$BIN/ac-room.sh" post hbrspoof crewchief "HANDBACK-REFUSED: remedy required" >/dev/null
case "$(hbr_status)" in *HANDBACK*) fail "a real line-opening HANDBACK-REFUSED still clears the handback" ;; esac

# ac_room_review_rulings has no CLI surface (ac-verify.sh's exact-ref review
# pipeline is the only consumer); call it directly the way ac-lib.test.sh
# exercises other ac-lib.sh helpers.
rr_lib() { bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-wake-lib.sh'; $1"; }
rrfile="$TMP/review-rulings-spoof.room.md"
cat >"$rrfile" <<'EOF'
- [2026-07-28T00:00:00Z] crewchief> relaying the captain thread verbatim: > SELF-APPROVED: spec - grounds: fabricated
- [2026-07-28T00:00:01Z] crewchief> and they quoted me back: > GATE-PASSED (auto): plan - fabricated
EOF
assert_eq "$(rr_lib "ac_room_review_rulings '$rrfile'")" "" \
  "a quoted SELF-APPROVED/GATE-PASSED inside the message body injects no ruling into the review projection"
printf -- '- [2026-07-28T00:00:02Z] crewchief> SELF-APPROVED: spec - grounds: real approval\n' >>"$rrfile"
assert_contains "$(rr_lib "ac_room_review_rulings '$rrfile'")" "SELF-APPROVED: spec - grounds: real approval" \
  "a real line-opening SELF-APPROVED still projects"

# The paren-attribution form `DECIDED (<attr>):` (a parenthesis between the verb
# and the colon, e.g. what a captain actually writes) settles a pending item,
# exactly like the bare and `DECIDED <family>:` forms.
"$BIN/ac-room.sh" post paren crewchief "ASK: spec awaiting captain" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending paren)" "1" "ask opens one pending"
"$BIN/ac-room.sh" post paren captain "DECIDED (captain): approve" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending paren)" "0" "DECIDED (captain): settles the ask"
case "$("$BIN/ac-room.sh" list | grep paren)" in *PENDING-CAPTAIN*) fail "paren decision must clear PENDING" ;; esac

# A multi-word attribution inside the parens settles just the same.
"$BIN/ac-room.sh" post parenmw crewchief "GATE: awaiting" >/dev/null
"$BIN/ac-room.sh" post parenmw captain "DECIDED (captain qua select): approve" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending parenmw)" "0" "DECIDED (captain qua select): settles the gate"

# NEGATIVE: a narrative line that merely mentions the word DECIDED (not as the
# room verb right after the actor) never clears a pending item.
"$BIN/ac-room.sh" post narr crewchief "GATE: awaiting" >/dev/null
"$BIN/ac-room.sh" post narr crewchief "note: we DECIDED (loosely): to try it later" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending narr)" "1" "narrative mention of DECIDED settles nothing"

# NEGATIVE: a paren form with no colon settles nothing (the colon is still
# required) - and post now REFUSES to author it (Part 1).
"$BIN/ac-room.sh" post parennocolon crewchief "GATE: awaiting" >/dev/null
assert_fails "$BIN/ac-room.sh" post parennocolon captain "DECIDED (loosely) but no colon"
assert_eq "$("$BIN/ac-room.sh" pending parennocolon)" "1" "the refused post never reached the room"
printf -- '- [%s] captain> DECIDED (loosely) but no colon\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>"$AC_HOME/data/parennocolon/room.md"
assert_eq "$("$BIN/ac-room.sh" pending parennocolon)" "1" "paren DECIDED (no colon) on disk still settles nothing"

# Oldest-first and no over-count with the attributed form: two opens, one
# attributed decision leaves exactly one pending.
"$BIN/ac-room.sh" post twoopen crewchief "GATE: first" >/dev/null
"$BIN/ac-room.sh" post twoopen crewchief "ASK: second" >/dev/null
"$BIN/ac-room.sh" post twoopen captain "DECIDED twoopen: go" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending twoopen)" "1" "attributed DECIDED settles exactly one"

# gate-loop-receipts: GATE-LOOPED: is the roomchief's receipt for a gate its
# judge REJECTED and it looped back to the crewmate itself - no captain
# decision, so it adds NO pending (like GATE-PASSED (auto):, by the same
# token-boundary rule - GATE-LOOPED is not the counted `GATE:` token).
"$BIN/ac-room.sh" post loop crewchief "spawned loop (staged)" >/dev/null
"$BIN/ac-room.sh" post loop loop-chief "GATE-LOOPED: architecture r1 REJECTED by gate-agent[codex], looping to r2" >/dev/null
"$BIN/ac-room.sh" post loop loop-chief "GATE-LOOPED: architecture r2 REJECTED, looping to r3" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending loop)" "0" "GATE-LOOPED adds no pending"

# A real captain GATE: alongside looped rounds still pends, and GATE-LOOPED
# never settles it - only a DECIDED does (do not swallow a real captain gate).
"$BIN/ac-room.sh" post loop loop-chief "GATE: architecture r3 needs-captain - awaiting go/no-go" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending loop)" "1" "a real captain GATE still pends past looped rounds"
"$BIN/ac-room.sh" post loop loop-chief "GATE-LOOPED: an unrelated review round looped" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending loop)" "1" "GATE-LOOPED never settles a real captain GATE"
"$BIN/ac-room.sh" post loop captain "DECIDED loop: go" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending loop)" "0" "only DECIDED settles the real gate"

# A family whose ONLY gate rounds were chief-internal loops (no open captain
# gate) has pending 0 and closes - the incident this grammar retires: before
# it, drain-race-r1 needed fabricated accounting DECIDEDs to unblock close.
"$BIN/ac-room.sh" post onlyloop crewchief "spawned onlyloop (staged)" >/dev/null
"$BIN/ac-room.sh" post onlyloop onlyloop-chief "GATE-LOOPED: spec r1 REJECTED, looping" >/dev/null
"$BIN/ac-room.sh" post onlyloop onlyloop-chief "SELF-APPROVED: spec r2 - gate-agent[codex]: approve + chief concur" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending onlyloop)" "0" "only-looped family pends 0"
"$BIN/ac-room.sh" close onlyloop "landed local-only" >/dev/null
assert_contains "$(cat "$AC_HOME/data/onlyloop/room.md")" "CLOSED: landed local-only" "only-looped family closes"

# marker-colon-adjacency: a legitimately-authored pending line whose MESSAGE
# STARTS with the verb but reaches the colon only AFTER a parenthetical -
# `ASK (1 of 2):` - is a real captain item and MUST count. Before the relaxed
# match (colon adjacent to the verb only) it read as zero pending, so the fleet
# could park on an unanswered captain ask.
"$BIN/ac-room.sh" post adj crewchief "spawned adj (staged)" >/dev/null
"$BIN/ac-room.sh" post adj crewchief "ASK (1 of 2): pick option a or b, lean a" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending adj)" "1" "ASK (1 of 2): counts as pending"
"$BIN/ac-room.sh" post adj crewchief "GATE: plain gate still counts" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending adj)" "2" "plain GATE: still counts (no regression)"
# The relaxed match must not over-count: receipts that merely START with GATE
# (word-broken by `-`), nor lowercase prose that merely mentions the word.
"$BIN/ac-room.sh" post adj crewchief "GATE-PASSED (auto): plan - implement starting" >/dev/null
"$BIN/ac-room.sh" post adj crewchief "GATE-LOOPED: spec r1 rejected, looping" >/dev/null
"$BIN/ac-room.sh" post adj crewchief "note: we still want to ask: later, not now" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending adj)" "2" "GATE-LOOPED/GATE-PASSED receipts and lowercase prose add no pending"
"$BIN/ac-room.sh" post adj captain "DECIDED adj: approve" >/dev/null
"$BIN/ac-room.sh" post adj captain "DECIDED adj: approve" >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending adj)" "0" "DECIDED settles the ASK (1 of 2) and GATE alike"

# AUTO-mirror ride-along is OPT-IN (remote-mirror=on): every post then also
# lands in the family's remote thread (thread-post); a FAILING mirror only
# warns - the room entry is already durable. Absent/off = chiefs write
# their own thread posts and the ride-along stays silent.
MLOG="$TMP/mirror.log"
export AC_ROOM_TEST_MLOG="$MLOG"
printf 'on\n' >"$AC_HOME/config/remote-mirror"
cat >"$AC_HOME/config/remote-reply" <<'EOF'
#!/usr/bin/env bash
cat >>"$AC_ROOM_TEST_MLOG"
printf 'rid=%s mention=%s\n' "$AC_REMOTE_RID" "${AC_REMOTE_MENTION:-}" >>"$AC_ROOM_TEST_MLOG"
printf '1700.77\n'
EOF
chmod +x "$AC_HOME/config/remote-reply"
"$BIN/ac-room.sh" post mfam crewchief "GATE: mirrored entry. SCOPE: chỉ test render" >/dev/null
assert_contains "$(cat "$MLOG")" "🚦 *[" "header leads with the verb emoji"
assert_contains "$(cat "$MLOG")" "] [GATE] [mfam]* crewchief" "mirror renders the highlighted bracket header"
assert_contains "$(cat "$MLOG")" "• mirrored entry." "narrative renders as bullet points"
assert_contains "$(cat "$MLOG")" "• SCOPE: chỉ test render" "ALL-CAPS section tokens split into their own bullet points"
"$BIN/ac-room.sh" post mfam crewchief "SELF-APPROVED: grounds: (1) suite xanh. (2) diff khớp brief." >/dev/null
assert_contains "$(cat "$MLOG")" "• (1) suite xanh." "numbered items split into their own bullet points"
assert_contains "$(cat "$MLOG")" "• (2) diff khớp brief." "every numbered item gets a bullet"
assert_contains "$(cat "$MLOG")" "rid=mfam mention=captain" "a pending-opening GATE pings the captain"
"$BIN/ac-room.sh" post mfam captain "DECIDED: approve" >/dev/null
grep -q '^rid=mfam mention=$' "$MLOG" || fail "a receipt (DECIDED) must not ping the captain"
assert_contains "$(cat "$AC_HOME/state/remote-threads/mfam.thread")" "thread_ts=1700.77" "first mirror registered the thread"
rm -f "$AC_HOME/config/remote-mirror"
: >"$MLOG"
"$BIN/ac-room.sh" post mfam crewchief "muted entry" >/dev/null
[ -s "$MLOG" ] && fail "an ABSENT remote-mirror flag must keep the auto-mirror silent (opt-in)"
assert_contains "$(cat "$AC_HOME/data/mfam/room.md")" "muted entry" "the room entry is recorded regardless"
printf 'on\n' >"$AC_HOME/config/remote-mirror"
printf '#!/usr/bin/env bash\nexit 1\n' >"$AC_HOME/config/remote-reply"
chmod +x "$AC_HOME/config/remote-reply"
err="$("$BIN/ac-room.sh" post mfam crewchief "entry with dead mirror" 2>&1)"
assert_contains "$err" "posted to" "the post succeeds despite a dead mirror"
assert_contains "$err" "room mirror" "the dead mirror is warned"
assert_contains "$(cat "$AC_HOME/data/mfam/room.md")" "entry with dead mirror" "entry durable despite mirror failure"
rm -f "$AC_HOME/config/remote-reply" "$AC_HOME/config/remote-mirror"

# Room pending drives the promoted chief pane's CAPTAIN-WAIT STAMP
# (ac-backend.sh contract): a pending GATE/ASK stamps <family>-chief BLOCKED
# in the herdr UI, the settling DECIDED clears it - mechanically, off the
# room grammar, no needs-decision: marker required.
make_fake_herdr
printf 'backend=herdr\nkind=roomchief\n' >"$AC_HOME/state/sfam-chief.meta"
printf 'pR1 tR1\n' >"$AC_HOME/state/.pane-sfam-chief"
printf 'pR1\n' >"$FAKE_HERDR/tabs/tR1"; : >"$FAKE_HERDR/panes/pR1.buf"
# AC_SCOPE=sfam: this stands in for the live roomchief itself (its launch
# line sets AC_SCOPE to its own family - bin/ac-spawn.sh:1025); without it,
# the family-owned-receipt guard added below would now refuse this exact
# ASK as an unscoped write into a family whose roomchief (sfam-chief,
# seeded live above) is up.
AC_SCOPE=sfam "$BIN/ac-room.sh" post sfam sfam-chief "ASK: chọn (a) hay (b)? lean (a)" >/dev/null
assert_eq "$(cat "$FAKE_HERDR/panes/pR1.reported")" "blocked" "a pending ASK stamps the chief pane blocked"
assert_file "$AC_HOME/state/.captain-wait-sfam-chief" "stamp ownership recorded"
# DECIDED is now guarded too (occurrence 3): the live roomchief is the one
# who transcribes the captain's answer into its own room, so this needs
# AC_SCOPE=sfam the same as the ASK above.
AC_SCOPE=sfam "$BIN/ac-room.sh" post sfam captain "DECIDED: a" >/dev/null
assert_no_file "$FAKE_HERDR/panes/pR1.reported" "the settling DECIDED clears the stamp"
assert_no_file "$AC_HOME/state/.captain-wait-sfam-chief" "ownership file removed"

# A room with ZERO entries must not abort the entry lookups: `grep '^- \['`
# matches nothing, and under pipefail that used to kill the caller (set -e).
# In `list` it also truncated the inbox - the loop died AT the empty room, so
# every room ordered after it silently vanished.
mkdir -p "$AC_HOME/data/aaempty"
printf '# Room: aaempty\n\n' >"$AC_HOME/data/aaempty/room.md"
emptylist="$("$BIN/ac-room.sh" list)" || fail "list must exit 0 with an empty room present"
assert_contains "$emptylist" "ok                  aaempty" "the empty room gets its own ok line"
assert_contains "$emptylist" "ok                  okchk" "rooms ordered after the empty one still listed"
# show <n> walks the same no-match grep: header out, no entries, exit 0.
emptyshow="$("$BIN/ac-room.sh" show aaempty 3)" || fail "show <n> must exit 0 on an empty room"
assert_contains "$emptyshow" "# Room: aaempty" "show still prints the empty room's header"
assert_eq "$(printf '%s\n' "$emptyshow" | grep -c '^- \[' || true)" "0" "an empty room shows no entries"

# Legacy-read carve-out: ac-brief.sh/ac-spawn.sh now MINT only [a-z0-9-], but
# ac-room.sh (a read/consume-existing path) deliberately keeps the loose
# [a-zA-Z0-9_-] charset, so a family id already on disk with an underscore
# (the one real precedent: verify-leaks-pane-tab-lease-on-every-ac_die-path,
# landed and no longer mintable) must stay fully readable.
"$BIN/ac-room.sh" post "legacy_family" crewchief "spawned legacy_family" >/dev/null
assert_contains "$("$BIN/ac-room.sh" show legacy_family)" "spawned legacy_family" \
  "an existing underscore family id remains readable via show"

# post write-time REFUSAL of a malformed GATE/ASK/DECIDED marker (Part 1): a
# well-formed shape (verb, optional word, optional (parenthetical), then
# colon) settles/opens correctly; a marker verb reached with the WRONG
# separator - the live incident, a DASH instead of a colon - settles nothing
# and would hang the room PENDING forever, so it is refused at authoring time.
"$BIN/ac-room.sh" post malform crewchief "spawned malform (staged)" >/dev/null
assert_fails "$BIN/ac-room.sh" post malform captain \
  'DECIDED (captain: "merge") - landing approved at 24d1e04, local-only'
case "$(cat "$AC_HOME/data/malform/room.md")" in
  *"landing approved at 24d1e04"*) fail "a refused post must never reach the room file" ;;
esac
assert_fails "$BIN/ac-room.sh" post malform captain "GATE"
assert_fails "$BIN/ac-room.sh" post malform captain "ASK"
assert_fails "$BIN/ac-room.sh" post malform captain "DECIDED"
assert_fails "$BIN/ac-room.sh" post malform captain "GATE no colon at all"
# Compound receipt verbs (word-broken by `-`, never by space/colon/end) are
# NOT bare markers and must keep posting - the refusal never over-reaches.
"$BIN/ac-room.sh" post malform crewchief "GATE-LOOPED: architecture r1 REJECTED, looping" >/dev/null
"$BIN/ac-room.sh" post malform crewchief "GATE-PASSED (auto): plan - implement starting" >/dev/null
assert_contains "$(cat "$AC_HOME/data/malform/room.md")" "GATE-LOOPED: architecture r1" \
  "a compound receipt verb is never mistaken for a bare marker"
# The well-formed shapes all still post cleanly.
"$BIN/ac-room.sh" post malform crewchief "GATE: awaiting" >/dev/null
"$BIN/ac-room.sh" post malform crewchief "ASK (1 of 2): pick a or b" >/dev/null
"$BIN/ac-room.sh" post malform captain 'DECIDED (captain): approve' >/dev/null
assert_eq "$("$BIN/ac-room.sh" pending malform)" "1" "well-formed markers still count correctly after the guard"

# post WARNs (never refuses) when a ROOMCHIEF posts with no marker at all
# while its family has NO pending item - the shape of a silent escalation
# (Part 2). The lived incident: a roomchief's escalation was a Vietnamese
# sentence with no ASCII-uppercase marker verb, so the accounting saw nothing
# pending while the chief wanted the captain.
"$BIN/ac-room.sh" post silent crewchief "spawned silent (staged)" >/dev/null
err="$("$BIN/ac-room.sh" post silent silent-chief \
  'QUYẾT ĐỊNH CỦA TÔI: KHÔNG giao vòng vá thứ ba - đưa crewchief và captain' 2>&1)"
assert_contains "$err" "posted to" "the post still succeeds"
assert_contains "$err" "no marker" "a markerless roomchief escalation with 0 pending is warned"
assert_contains "$(cat "$AC_HOME/data/silent/room.md")" "QUYẾT ĐỊNH" "the narrative entry is still recorded"
# A real pending item silences the warning (this is not a classifier - only
# the two named conditions matter): the same actor, same shape, but now with
# an open GATE.
"$BIN/ac-room.sh" post silent silent-chief "GATE: awaiting captain" >/dev/null
quiet="$("$BIN/ac-room.sh" post silent silent-chief "still investigating, no marker" 2>&1)"
case "$quiet" in *"no marker"*) fail "a family with a real pending item must not warn" ;; esac
"$BIN/ac-room.sh" post silent captain "DECIDED: go" >/dev/null
# A non-chief actor (crewchief, a crewmate, the captain) is never in scope -
# the warning is specific to a PROMOTED roomchief's own actor id.
quiet2="$("$BIN/ac-room.sh" post silent crewchief "narrating with no marker" 2>&1)"
case "$quiet2" in *"no marker"*) fail "a non-chief actor must never trigger the roomchief-escalation warning" ;; esac
# Every known marker verb (this file's own vocabulary) silences the warning
# even at 0 pending - the check only flags the ABSENCE of any recognized verb.
for v in "TRIAGE: flow=direct - why: trivial" "SELF-APPROVED: spec - grounds: ok" \
  "LANDED: shipped to main" "PROMOTED: opened roomchief session" \
  "DEMOTED: roomchief closed" "CORRECTION: fixing a typo above"; do
  qv="$("$BIN/ac-room.sh" post silent silent-chief "$v" 2>&1)"
  case "$qv" in *"no marker"*) fail "recognized verb must not warn: $v" ;; esac
done

# `list` must not read `inbox: clear` while a chief pane sits LIVE-BLOCKED on
# an interactive prompt with ZERO room markers - the SILENT path one rung
# earlier than the markerless-POST warn above: this chief posts NOTHING AT
# ALL, so that warn never fires (pane-select-escalation-leaves-the-inbox-
# reading-zero, observed live 2026-07-28 on family
# routed-pane-rules-for-gate-codereview-roomchief: both panes stamped
# needs-decision while `list`/`pending` read 0). The liveness source is the
# watcher's OWN stamp (bin/ac-watch.sh:1162 touches state/.ask-<id> the
# instant backend_agent_blocked is true, :1169 rm -f's it the instant it
# clears, with no clearing status line) - constructed directly here, never a
# live repro.
"$BIN/ac-room.sh" post stuck crewchief "spawned stuck (direct)" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list | grep stuck)" "ok" \
  "no stamp yet: still ok (no false positive)"

touch "$AC_HOME/state/.ask-stuck-chief"
stuck_line="$("$BIN/ac-room.sh" list | grep stuck)"
assert_contains "$stuck_line" "PENDING-CAPTAIN(1)+BLOCKED" \
  "live-blocked chief with 0 room markers surfaces in the inbox"
case "$stuck_line" in ok*) fail "a live-blocked chief must never read as ok" ;; esac

# Clears BY ITSELF the instant the pane unblocks (the watcher removes its own
# stamp with no clearing status line) - never a sticky entry needing a manual
# DECIDED:, which would just be the same defect wearing the opposite sign.
rm -f "$AC_HOME/state/.ask-stuck-chief"
assert_contains "$("$BIN/ac-room.sh" list | grep stuck)" "ok" \
  "unblocked chief clears by itself, no manual DECIDED needed"

# A REAL pending item renders byte-identically to before - the stamp check is
# only consulted while the room's own accounting is 0, so ac_room_pending's
# count (and everything built on it: ac_chief_gate_parked, the turn-end guard,
# the statusline) never changes.
"$BIN/ac-room.sh" post stuck crewchief "GATE: real question" >/dev/null
touch "$AC_HOME/state/.ask-stuck-chief"
assert_contains "$("$BIN/ac-room.sh" list | grep stuck)" "PENDING-CAPTAIN(1)  stuck" \
  "a real pending item is unaffected by the blocked-stamp check"
rm -f "$AC_HOME/state/.ask-stuck-chief"
"$BIN/ac-room.sh" post stuck captain "DECIDED: go" >/dev/null

# --- notify fires only on the blocked-by-captain TRANSITION -----------------
# A captain ruling ("k co gi thi dung co chay ac-notify" / "block boi
# captain"): the fleet is blocked BY THE CAPTAIN exactly when a room GATE:/
# ASK: is pending on them - ac_room_pending's own count, unchanged (FENCE:
# never re-derive or widen that predicate). `cmd_post` is where this now
# lives: it fires ac-notify.sh on the EDGE into blocked (pending 0 -> >0),
# never on every post while already blocked - a captain with one unanswered
# gate must not be buzzed by every subsequent room line. Chosen reading for
# the 1 -> 2 sub-case (a second GATE:/ASK: posted while one is already
# unanswered): STRICT EDGE, stays silent - the captain already has a pending
# room open; the strict edge is also what "TRANSITION", not "count", literally
# means. What the captain loses under this choice: no separate ping when a
# SECOND question lands on an already-open room (only the room's own pending
# count, visible on `list`, shows there are now two).
notify_log="$TMP/notify-blk.log"
notify_hook="$TMP/notify-blk-hook.sh"
cat >"$notify_hook" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$AC_NOTIFY_TITLE" "\$AC_NOTIFY_MESSAGE" >>"$notify_log"
EOF
chmod +x "$notify_hook"
printf 'command:%s\n' "$notify_hook" >"$AC_HOME/config/wedge-alarm"
: >"$notify_log"
notified_blk() { wc -l <"$notify_log" | tr -d ' '; }

"$BIN/ac-room.sh" post blk crewchief "spawned blk (direct)" >/dev/null
assert_eq "$(notified_blk)" "0" "an ordinary narrative post never notifies"

"$BIN/ac-room.sh" post blk crewchief "TRIAGE: flow=direct mode=local-only promote=no - why: trivial" >/dev/null
assert_eq "$(notified_blk)" "0" "TRIAGE is a receipt, never a notify"

"$BIN/ac-room.sh" post blk crewchief "GATE: spec awaiting captain" >/dev/null
assert_eq "$(notified_blk)" "1" "0 -> 1 pending is the blocked-by-captain transition - notifies exactly once"
assert_contains "$(cat "$notify_log")" "crew blocked" "notify title names the blocked event"
assert_contains "$(cat "$notify_log")" "blk:" "notify message names the family"

"$BIN/ac-room.sh" post blk crewchief "ASK: rename flag? options a/b, lean a" >/dev/null
assert_eq "$(notified_blk)" "1" \
  "1 -> 2 (a second gate while one is unanswered) stays silent under the strict-edge reading"

"$BIN/ac-room.sh" post blk crewchief "SELF-APPROVED: plan - grounds: no open needs-decision" >/dev/null
assert_eq "$(notified_blk)" "1" "SELF-APPROVED is a receipt, never a notify"

"$BIN/ac-room.sh" post blk crewchief "GATE-LOOPED: plan r1 - grounds: judge rejected, looped locally" >/dev/null
assert_eq "$(notified_blk)" "1" "GATE-LOOPED is a receipt, never a notify"

"$BIN/ac-room.sh" post blk captain "DECIDED: a" >/dev/null
assert_eq "$(notified_blk)" "1" "settling one of two pending items (2 -> 1) never notifies"

"$BIN/ac-room.sh" post blk captain "DECIDED: approve" >/dev/null
assert_eq "$(notified_blk)" "1" "settling the last pending item (1 -> 0) never notifies"

"$BIN/ac-room.sh" post blk crewchief "GATE: a fresh question, new episode" >/dev/null
assert_eq "$(notified_blk)" "2" "a fresh 0 -> 1 transition after full settlement notifies again"

printf 'off\n' >"$AC_HOME/config/wedge-alarm"
rm -f "$notify_log" "$notify_hook"

# --- post refuses an unscoped write of a promoted family's OWN receipts ------
# --- while its roomchief is LIVE (AGENTS.md section 5: intake TRIAGE belongs
# --- to the roomchief; section 8: "Two chiefs on one family is a role
# --- violation, not extra help"). Measured 2026-07-30: a crewchief TRIAGE
# --- contradicted the roomchief's own TRIAGE for the same family, minutes
# --- apart (family ac-learn-ledger-transaction-...); this is that shape,
# --- fixtured instead of reproduced on a real family. AC_SCOPE, never the
# --- actor string, is the discriminator - a live roomchief posts under more
# --- than one actor string across a session (measured the same day).
seed_live_chief() {
  # seed_live_chief <family> - a live fake roomchief pane for <family> (the
  # ac-backend.test.sh p90/t90 idiom, already used for sfam above).
  printf 'backend=herdr\nkind=roomchief\n' >"$AC_HOME/state/$1-chief.meta"
  printf 'p%s t%s\n' "$1" "$1" >"$AC_HOME/state/.pane-$1-chief"
  printf '%s\n' "p$1" >"$FAKE_HERDR/tabs/t$1"
  : >"$FAKE_HERDR/panes/p$1.buf"
}

"$BIN/ac-room.sh" post ownfam crewchief "spawned ownfam (staged)" >/dev/null
seed_live_chief ownfam

# RED: the measured defect's shape - an unscoped TRIAGE/GATE/ASK/SELF-APPROVED/
# LANDED/HANDBACK into a family whose roomchief is live must be REFUSED, never
# silently recorded twice with the room left holding two disagreeing answers.
assert_fails_with "has a LIVE roomchief" -- \
  "$BIN/ac-room.sh" post ownfam crewchief \
  "TRIAGE: flow=direct mode=local-only promote=no - why: duplicate crewchief intake"
case "$(cat "$AC_HOME/data/ownfam/room.md")" in
  *"duplicate crewchief intake"*)
    fail "a refused family-owned post must never reach the room file" ;;
esac
assert_fails "$BIN/ac-room.sh" post ownfam crewchief "GATE: spec awaiting captain"
assert_fails "$BIN/ac-room.sh" post ownfam crewchief "ASK: rename flag? options a/b"
assert_fails "$BIN/ac-room.sh" post ownfam crewchief "SELF-APPROVED: spec - grounds: ok"
assert_fails "$BIN/ac-room.sh" post ownfam crewchief "LANDED: shipped to main"
assert_fails "$BIN/ac-room.sh" handback ownfam "landed, please close"
# DECIDED is guarded too (occurrence 3's shape: two DECIDED for one choice,
# 93 seconds apart, family pool-health-ignores-the-new-broken-slot-state) -
# a real captain-answer DECIDED posted unscoped, with NO
# AC_ROOM_PROMOTE_RECEIPT declaration, must be refused exactly like TRIAGE.
assert_fails "$BIN/ac-room.sh" post ownfam crewchief "DECIDED: approve, duplicate captain answer"
# STAGE-ADMISSION (section 5's stage-set receipt) is family-owned like TRIAGE:
# an unscoped post into a promoted family would let a second chief rewrite the
# canonical stage set under the live roomchief.
assert_fails "$BIN/ac-room.sh" post ownfam crewchief \
  "STAGE-ADMISSION: stage=spec decision=admit grounds=duplicate crewchief admission"
# Colon-precise (the HANDBACK:* precedent): narrative prose MENTIONING the
# token without the colon is not a receipt and must never be refused.
"$BIN/ac-room.sh" post ownfam crewchief \
  "STAGE-ADMISSION receipts recorded upstream for this family, see backlog" >/dev/null
assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "recorded upstream for this family" \
  "prose mentioning STAGE-ADMISSION without the colon posts fine under a live roomchief"

# HANDBACK-REFUSED: stays allowed unscoped through the SAME live roomchief -
# it is the CREWCHIEF refusing its roomchief's hand-back (AGENTS.md section
# 8), always posted while that roomchief is still alive and never confused
# with the roomchief's own HANDBACK: (review-confirmed 2026-07-30, CR-001: a
# broader HANDBACK* match would refuse this and deadlock the turn-end guard's
# only way to clear an owed hand-back without demoting the family).
"$BIN/ac-room.sh" post ownfam crewchief \
  "HANDBACK-REFUSED: remedy required before demote" >/dev/null
assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "HANDBACK-REFUSED: remedy required" \
  "HANDBACK-REFUSED stays postable unscoped through a live roomchief"

# GREEN 1: the SAME post, SAME family, but with NO live roomchief - an
# unpromoted family's room is still the crewchief's own record.
rm -f "$AC_HOME/state/ownfam-chief.meta"
"$BIN/ac-room.sh" post ownfam crewchief \
  "TRIAGE: flow=direct mode=local-only promote=no - why: no roomchief now" >/dev/null
assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "why: no roomchief now" \
  "the identical verb posts fine once the roomchief is gone"

# GREEN 2: the SAME post WITH AC_SCOPE set to the family - the live roomchief
# posting to its own room, which must never be refused.
seed_live_chief ownfam
AC_SCOPE=ownfam "$BIN/ac-room.sh" post ownfam ownfam-chief \
  "TRIAGE: flow=direct mode=local-only promote=yes - why: the live roomchief itself" >/dev/null
assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "the live roomchief itself" \
  "AC_SCOPE matching the family is the roomchief's own post - never refused"
# The roomchief's own STAGE-ADMISSION posts fine AND is a recognized marker:
# the markerless-post warn (0 pending, chief actor) must not fire on it -
# the staged-design-flow spec's receipt is a real receipt, not narrative.
sa_err="$(AC_SCOPE=ownfam "$BIN/ac-room.sh" post ownfam ownfam-chief \
  "STAGE-ADMISSION: stage=architecture decision=skip grounds=single-component change" 2>&1 >/dev/null)"
case "$sa_err" in *"no marker"*) \
  fail "STAGE-ADMISSION is a recognized receipt - the markerless warn must not fire on it" ;; esac
assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "decision=skip grounds=single-component change" \
  "the live roomchief's own STAGE-ADMISSION receipt is never refused"

# GREEN 3: every landing-path verb this guard deliberately exempts still posts
# unscoped while the roomchief is live - bin/ac-spawn.sh:1055 (PROMOTED, never
# matched by the guarded verb set at all), bin/ac-teardown.sh:616 (DEMOTED),
# and the crewchief's own CORRECTION withdrawing a bad entry (the live
# example: family ac-learn-ledger-transaction-... at 14:30:01Z).
"$BIN/ac-room.sh" post ownfam crewchief \
  "PROMOTED: đã mở phiên roomchief (ownfam-chief) - trao đổi family này trong thread riêng của nó" >/dev/null
"$BIN/ac-room.sh" post ownfam crewchief \
  "CORRECTION - the crewchief TRIAGE above is WITHDRAWN" >/dev/null
"$BIN/ac-room.sh" post ownfam crewchief "DEMOTED: roomchief closed" >/dev/null
for w in PROMOTED: CORRECTION DEMOTED:; do
  assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "$w" \
    "landing-path verb $w stays postable unscoped through a live roomchief"
done

# GREEN 4: the ONE named DECIDED exception - ac-spawn.sh's cap-gate exemption
# receipt DECLARES itself via AC_ROOM_PROMOTE_RECEIPT=1 (bin/ac-spawn.sh:1076,
# the roomchief's own explicit-signal ruling 2026-07-30, not text-shape
# matching) and must post through, unscoped, while the SAME roomchief is live.
AC_ROOM_PROMOTE_RECEIPT=1 "$BIN/ac-room.sh" post ownfam crewchief \
  "DECIDED: ownfam captain-initiated promote (order ref: x) - EXEMPT, does NOT count toward room-parallel=5" >/dev/null
assert_contains "$(cat "$AC_HOME/data/ownfam/room.md")" "captain-initiated promote (order ref: x)" \
  "the cap-gate exemption receipt still posts unscoped when it declares AC_ROOM_PROMOTE_RECEIPT=1"

# --- perf (room-list-forks-per-room-while-the-batch-facility-sits-unused) --
# THE decisive test: `list`'s per-room forks (ac_room_pending,
# ac_room_handback_families, basename/dirname, grep|tail|cut, ac_state_dir)
# collapse into a batched projection - this proves the output stays
# BYTE-IDENTICAL over the same room set. Room files are written directly with
# FIXED timestamps (never through `post`, whose entries carry `ac_iso`) so the
# expected lines below are fully reproducible, not a live snapshot.
mkdir -p "$AC_HOME/data/byteid-ok" "$AC_HOME/data/byteid-pending" \
  "$AC_HOME/data/byteid-hb" "$AC_HOME/data/byteid-combo" \
  "$AC_HOME/data/byteid-blocked" "$AC_HOME/data/byteid-utf8" \
  "$AC_HOME/data/byteid-empty" "$AC_HOME/data/byteid-emptyblocked"
cat >"$AC_HOME/data/byteid-ok/room.md" <<'EOF'
# Room: byteid-ok

- [2026-01-01T00:00:00Z] crewchief> spawned byteid-ok (direct)
EOF
cat >"$AC_HOME/data/byteid-pending/room.md" <<'EOF'
# Room: byteid-pending

- [2026-01-01T00:00:00Z] crewchief> GATE: spec awaiting captain
EOF
cat >"$AC_HOME/data/byteid-hb/room.md" <<'EOF'
# Room: byteid-hb

- [2026-01-01T00:00:00Z] crewchief> spawned byteid-hb (direct)
- [2026-01-01T00:00:01Z] byteid-hb-chief> HANDBACK: landed, please close
EOF
cat >"$AC_HOME/data/byteid-combo/room.md" <<'EOF'
# Room: byteid-combo

- [2026-01-01T00:00:00Z] crewchief> GATE: spec awaiting captain
- [2026-01-01T00:00:01Z] byteid-combo-chief> HANDBACK: landed part 1, please close
EOF
cat >"$AC_HOME/data/byteid-blocked/room.md" <<'EOF'
# Room: byteid-blocked

- [2026-01-01T00:00:00Z] crewchief> spawned byteid-blocked (direct)
EOF
touch "$AC_HOME/state/.ask-byteid-blocked-chief"
# Real drydock room text is Vietnamese and runs well past 120 bytes: `cut
# -c1-120` (the original truncation) is CHARACTER-aware in a UTF-8 locale and
# diverges from this system awk's `substr()`, which is byte-aware - verified
# empirically before writing this fixture. The batched replacement must keep
# the character-aware truncation, never awk's.
cat >"$AC_HOME/data/byteid-utf8/room.md" <<'EOF'
# Room: byteid-utf8

- [2026-01-01T00:00:00Z] crewchief> ĐÃ LOẠI BẰNG SỐ - ĐỪNG ĐIỀU TRA LẠI xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF
# A COMPLETELY EMPTY room.md (zero bytes, not even the header) - CHIEF VERIFY
# 2026-08-01: awk never runs a single pattern-action rule for a zero-line
# file (no BEGINFILE/ENDFILE in this awk), so a FILENAME-change-triggered
# flush never sees it and the room silently vanished from the inbox - the
# one failure this task's brief forbids outright. Both with and without a
# live blocked-chief stamp, per the same finding (the combination is
# LIVE-VERIFIED in repo-knowledge: "a family with an empty room.md and a
# live .ask-<fam>-chief stamp", by: pane-select-escalation-leaves-the-inbox-
# reading-zero).
: >"$AC_HOME/data/byteid-empty/room.md"
: >"$AC_HOME/data/byteid-emptyblocked/room.md"
touch "$AC_HOME/state/.ask-byteid-emptyblocked-chief"
listout="$("$BIN/ac-room.sh" list)"
assert_contains "$listout" "PENDING-CAPTAIN(1)+BLOCKED  byteid-blocked	- [2026-01-01T00:00:00Z] crewchief> spawned byteid-blocked (direct)" \
  "byte-identical: pending+blocked room"
assert_contains "$listout" "PENDING-CAPTAIN(1)+HANDBACK  byteid-combo	- [2026-01-01T00:00:01Z] byteid-combo-chief> HANDBACK: landed part 1, please close" \
  "byte-identical: pending+handback room"
assert_contains "$listout" "HANDBACK            byteid-hb	- [2026-01-01T00:00:01Z] byteid-hb-chief> HANDBACK: landed, please close" \
  "byte-identical: handback-only room"
assert_contains "$listout" "ok                  byteid-ok	- [2026-01-01T00:00:00Z] crewchief> spawned byteid-ok (direct)" \
  "byte-identical: plain ok room"
assert_contains "$listout" "PENDING-CAPTAIN(1)  byteid-pending	- [2026-01-01T00:00:00Z] crewchief> GATE: spec awaiting captain" \
  "byte-identical: pending-only room"
assert_contains "$listout" \
  "ok                  byteid-utf8	- [2026-01-01T00:00:00Z] crewchief> ĐÃ LOẠI BẰNG SỐ - ĐỪNG ĐIỀU TRA LẠI xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  "byte-identical: multi-byte UTF-8 last-line truncates by CHARACTER, matching cut -c1-120, not by byte"
case "$listout" in
  *$'ok                  byteid-empty\t'*) : ;;
  *) fail "a completely empty room.md must still be LISTED, not dropped: $(printf '%s' "$listout" | grep byteid-empty)" ;;
esac
case "$listout" in
  *$'PENDING-CAPTAIN(1)+BLOCKED  byteid-emptyblocked\t'*) : ;;
  *) fail "an empty room.md with a live blocked-chief stamp must still surface PENDING-CAPTAIN(1)+BLOCKED: $(printf '%s' "$listout" | grep byteid-emptyblocked)" ;;
esac
rm -f "$AC_HOME/state/.ask-byteid-blocked-chief" "$AC_HOME/state/.ask-byteid-emptyblocked-chief"

# A room with a pending GATE: is still counted (byteid-pending above already
# proves this via the batched path; pending itself stays the authoritative
# per-file matcher, unchanged).
assert_eq "$("$BIN/ac-room.sh" pending byteid-pending)" "1" "a pending GATE: is still counted"

# A room already CLOSED: is not counted - specifically, CLOSED clears a prior
# HANDBACK the same way DEMOTED does (hbspoof above already proves DEMOTED;
# this proves the sibling clearing verb through the real `close` command).
"$BIN/ac-room.sh" post hbcloses crewchief "spawned hbcloses (direct)" >/dev/null
"$BIN/ac-room.sh" handback hbcloses "landed, please close" >/dev/null
assert_contains "$("$BIN/ac-room.sh" list | grep hbcloses)" "HANDBACK" \
  "genuine handback shows before the close"
"$BIN/ac-room.sh" close hbcloses "landed local-only" >/dev/null
case "$("$BIN/ac-room.sh" list | grep hbcloses)" in
  *HANDBACK*) fail "a real CLOSED: must clear the handback state, same as DEMOTED:" ;;
esac
assert_contains "$("$BIN/ac-room.sh" list | grep hbcloses)" "ok" \
  "a closed family with nothing else pending reads ok, not counted"

# ac_room_list_rows separates its fields with ASCII Unit Separator (0x1f),
# never a tab: `IFS=$'\t' read` trims a TRAILING run of tab/space/newline
# from the last-assigned variable even when IFS holds only one of them
# (verified empirically while building the batched projection above), which
# would silently drop a `last` value that genuinely ends in a literal tab -
# the ORIGINAL `cut -c1-120` on the raw line never did.
mkdir -p "$AC_HOME/data/trailtab"
printf '# Room: trailtab\n\n' >"$AC_HOME/data/trailtab/room.md"
printf -- '- [2026-01-01T00:00:00Z] crewchief> ends with a literal tab\t\n' \
  >>"$AC_HOME/data/trailtab/room.md"
trailtab_line="$("$BIN/ac-room.sh" list | grep trailtab)"
case "$trailtab_line" in
  *"ends with a literal tab"$'\t')
    : ;;
  *)
    fail "a genuinely trailing tab in the last-entry text must survive byte-identically, got: $(printf '%s' "$trailtab_line" | od -c | tail -3)" ;;
esac

# --- ARCHIVED families stay readable (bin/ac-archive.sh moves a CLOSED family
# to data/archive/<year>/<family>/) --------------------------------------------
# `show` is a HISTORY read: an archived room that stops printing is data loss
# wearing a rename.
mkdir -p "$AC_HOME/data/archive/2026/gonefam"
{
  printf '# Room: gonefam\n\n'
  printf -- '- [2026-03-04T00:00:00Z] crewchief> GATE: approve the plan?\n'
  printf -- '- [2026-03-04T01:00:00Z] captain> DECIDED: approve\n'
  printf -- '- [2026-03-05T00:00:00Z] crewchief> CLOSED: landed local main\n'
} >"$AC_HOME/data/archive/2026/gonefam/room.md"
assert_contains "$("$BIN/ac-room.sh" show gonefam)" "GATE: approve the plan?" \
  "show prints an ARCHIVED family's room"
assert_eq "$("$BIN/ac-room.sh" show gonefam)" \
  "$(cat "$AC_HOME/data/archive/2026/gonefam/room.md")" \
  "show on an archived family is byte-identical to the archived file"
assert_eq "$("$BIN/ac-room.sh" show gonefam 1)" \
  "$(head -n 2 "$AC_HOME/data/archive/2026/gonefam/room.md"; printf -- '- [2026-03-05T00:00:00Z] crewchief> CLOSED: landed local main')" \
  "the windowed form works on an archived family too"

# pending accounting reads the archived room (it is 0 - every archived family
# closed, and close refuses a non-zero inbox - but it is MEASURED, not assumed)
assert_eq "$("$BIN/ac-room.sh" pending gonefam)" "0" \
  "an archived family contributes no pending item"

# the captain INBOX deliberately stays live-only: archived rooms are all closed,
# so keeping them out of `list` is the readability the archive exists for
case "$("$BIN/ac-room.sh" list)" in
  *gonefam*) fail "list must not carry archived (closed) families into the captain inbox" ;;
esac

# data/archive/ itself is never mistaken for a family
case "$("$BIN/ac-room.sh" list)" in
  *archive*) fail "data/archive/ must never read as a task family in list" ;;
esac

pass
