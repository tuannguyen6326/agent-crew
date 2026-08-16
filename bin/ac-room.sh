#!/usr/bin/env bash
# ac-room.sh - per-task-family rooms: the captain-facing thread of one task.
#
# A room is data/<family>/room.md - an append-only, timestamped ledger of
# everything the captain cares about for that family: stage transitions,
# gates, escalations, decisions. Rooms solve captain-side multiplexing:
# one file tells one task's whole story, and `list` is the captain's inbox
# of rooms still waiting on them.
#
# Usage:
#   ac-room.sh post <family> <actor> <text...>   # append one entry
#   ac-room.sh show <family> [<n>]               # last n entries (default all)
#   ac-room.sh list                              # all rooms; PENDING = gates/asks
#                                                #   not yet settled by DECIDED:
#                                                #   or DECIDED <family>:; a room
#                                                #   both PENDING and in HANDBACK
#                                                #   shows both, never masked; a
#                                                #   room whose accounting reads
#                                                #   0 but whose <fam>-chief pane
#                                                #   is LIVE-BLOCKED (watcher's
#                                                #   own state/.ask-<id> stamp)
#                                                #   still shows PENDING+BLOCKED
#                                                #   - a silent pane-select
#                                                #   escalation must never read
#                                                #   as inbox: clear
#   ac-room.sh close <family> <outcome...>       # verify closable (no family
#                                                #   metas in flight, pending 0,
#                                                #   roomchief demoted), post
#                                                #   the CLOSED: entry, then
#                                                #   remove the family's OWN
#                                                #   wake-spool dir if empty
#                                                #   (refuse, and say so, if
#                                                #   it still holds a record)
#   ac-room.sh open <family>                     # focus the promoted room's
#                                                #   chief window - the CONSENTED
#                                                #   redirect verb: run it only
#                                                #   after the captain says yes
#   ac-room.sh pending <family>                  # print the pending count
#                                                #   (0 when no room exists)
#   ac-room.sh handback <family> <text...>       # roomchief reports back:
#                                                #   posts HANDBACK: to the room
#                                                #   AND queues a durable wake,
#                                                #   nudging the fleet watcher
#                                                #   like ac-done.sh's push -
#                                                #   the room shows HANDBACK in
#                                                #   `list` until DEMOTED/CLOSED
#   ac-room.sh gate-route <family> <stage>       # derive and append one
#     --report <file> --uncertainty <yes|no>     # GATE-ROUTING receipt:
#     --consequence <low|high>                   # captain authority wins;
#     --authority <chief|captain>                # else uncertainty OR high
#     --grounds <text...>                        # consequence -> second-chief;
#                                                # else -> chief
#   ac-room.sh gate-verify <family> <stage>      # append one structured
#     --round <1|2> --report <file>              # GATE-VERIFY chief-pass
#     --grounds <text...>                        # receipt before a gate pane
#   ac-room.sh disposition <family> <stage>      # append one structured
#     --r1 <file> --accepted <ids|none>           # R1-DISPOSITION receipt
#     --disputed <ids|none> --authority <class>   # before R2; ids partition
#     --grounds <text...>                         # R1 Required Changes
#
# Entry format: `- [<utc>] <actor>> <text>` - owned here. Pending accounting:
# an entry whose text starts with `GATE:` or `ASK:` waits on the captain; each
# `DECIDED:` or captain-attribution `DECIDED <family>:` entry settles one
# of them (oldest first). The MATCHER for that is ac_room_pending (ac-wake-lib.sh),
# shared with ac-statusline.sh - change the counting grammar there, not here.
# `post` REFUSES a GATE/ASK/DECIDED-opening message that does not close with
# that same grammar (e.g. a DASH where the shape needs a colon) - the write-side
# twin, ac_room_marker_malformed (ac-wake-lib.sh), kept in lockstep with
# ac_room_pending by living in the same function block.
# `TRIAGE:` (intake
# flow/mode/promote + why), `SELF-APPROVED: <stage> - grounds: ...`,
# `GATE-PASSED (auto): ...` (auto pre-implement tier: chief + gate
# judge concur) and `GATE-LOOPED: ...` (a gate the chief looped back to the
# crewmate after its judge REJECTED it, no captain involved) are the
# orchestrator's reasoned-decision RECEIPTS: informational, no pending effect
# - the captain vetoes by replying. Why GATE-LOOPED is non-pending, and why a
# real captain `GATE:` still pends past it, is ac_room_pending's contract.
# `GATE-ROUTING:` is the owning chief's per-report route receipt. It binds the
# exact report SHA-256 and records the two routing inputs plus authority. The
# command DERIVES route deterministically: authority=captain -> captain;
# otherwise uncertainty=yes OR consequence=high -> second-chief; otherwise
# chief. A report existing is never, by itself, grounds to consume a pane.
# `GATE-VERIFY:` is a roomchief pass receipt before any staged second-chief
# pane opens. It binds family/stage/round, the exact report SHA-256, pass
# verdict, and one-line grounds. A chief rejection loops locally to the
# crewmate and consumes no gate round.
# `R1-DISPOSITION:` is a roomchief receipt before R2. It is informational, not
# pending: the owning roomchief records exactly which R1 Required Changes it
# accepted or disputed, binds that adjudication to the immutable R1 artifact
# SHA-256 and the current chief-verified report SHA-256, and states whether
# disputes are chief-owned, captain-owned, mixed, or none. ac-gate.sh reads the
# latest valid matching receipt before opening R2.
# `STAGE-ADMISSION:` is the owning chief's per-stage admission receipt for the
# staged design flow - the latest valid receipt per stage is the canonical
# stage set (grammar and semantics: docs/staged-design-flow-spec.md).
# Informational, no pending effect; hand-posted via `post` in v1 (a write-side
# verb is the spec's intended follow-up hardening).
# `post` ALSO REFUSES an unscoped write of a family-owned receipt
# (GATE:/ASK:/TRIAGE:/SELF-APPROVED:/LANDED:/HANDBACK:/GATE-ROUTING:/R1-DISPOSITION:/
# DECIDED:/STAGE-ADMISSION:) into a family whose roomchief is LIVE (ac_roomchief_live,
# bin/ac-wake-lib.sh) - "unscoped" means AC_SCOPE does not equal that family,
# never the actor STRING (a live roomchief posts under more than one actor
# string across a session, measured 2026-07-30). Two chiefs writing the same
# family's own receipts is a role violation (AGENTS.md section 8), not a
# defect a human should have to keep catching in the room. PROMOTED/DEMOTED/
# CLOSED (the crewchief's own lifecycle bookkeeping about the family's
# existence), CORRECTION (the crewchief retracting its own prior entry) and
# HANDBACK-REFUSED: (the crewchief refusing its roomchief's hand-back,
# always unscoped while that roomchief is still live - AGENTS.md section 8)
# are deliberately NOT in the guarded set. DECIDED is guarded like the rest,
# with ONE named exception: ac-spawn.sh's cap-gate exemption receipt is
# itself a bare, unscoped `DECIDED:` posted the instant a roomchief is
# promoted (meta+window already live), textually indistinguishable from a
# real family decision - so that ONE call site (and only that one) sets
# AC_ROOM_PROMOTE_RECEIPT=1 to DECLARE what it is (roomchief 2026-07-30: an
# explicit caller signal, not text-shape matching, since this guard is an
# ACCIDENT guard, not a security boundary - no forgery-proofing). Fails OPEN
# on an uncertain/absent roomchief, the same direction ac_roomchief_live's
# other callers use: refusing a real write here is worse than missing a
# rare duplicate.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

# The WRITE path: `post` and `close` always address the LIVE room, never an
# archived one (ac_room_file's header owns why). Reads use ac_room_file, which
# falls back to the archive - `show` on a family bin/ac-archive.sh has moved must
# still print its room, or archiving is data loss wearing a rename.
room_file() { printf '%s/%s/room.md\n' "$(ac_data_dir)" "$1"; }

stage_short() {
  case "$1" in
    spec) printf 'spec\n' ;;
    architecture) printf 'arch\n' ;;
    plan) printf 'plan\n' ;;
    design) printf 'design\n' ;;
    *) return 1 ;;
  esac
}

cmd_post() {
  local family="${1:-}" actor="${2:-}"
  shift 2 2>/dev/null || ac_die "usage: ac-room.sh post <family> <actor> <text...>"
  local text="$*"
  [ -n "$family" ] && [ -n "$actor" ] && [ -n "$text" ] \
    || ac_die "usage: ac-room.sh post <family> <actor> <text...>"
  case "$family" in *[!a-zA-Z0-9_-]*) ac_die "family must be [a-zA-Z0-9_-]: $family" ;; esac
  # A GATE/ASK/DECIDED-opening message that does not close with the "optional
  # word, optional (parenthetical), then colon" shape ac_room_pending requires
  # settles/opens nothing - it reads as answered to a human while every
  # machine reader (close, the inbox, the turn-end guard) still counts it
  # pending. Refuse at authoring time, where it is one keystroke to fix,
  # rather than at close, in another chief session.
  ac_room_marker_malformed "$text" \
    && ac_die "post: '$text' opens with a GATE/ASK/DECIDED verb but is not well-formed (needs a colon, after an optional word and/or (parenthetical)) - fix the message; a malformed marker settles/opens nothing and can hang this room PENDING forever"
  # A promoted family's OWN receipts - intake TRIAGE, gate escalation/
  # self-judgment, hand-back, captain decision - belong to whichever chief is
  # actually running that family's stages: the LIVE roomchief, once one
  # exists (AGENTS.md section 5 for TRIAGE; section 8, "Two chiefs on one
  # family is a role violation, not extra help"). Refuse a post of one of
  # those verbs when this call is NOT the family's own roomchief (AC_SCOPE,
  # never the actor STRING - a live roomchief posts under more than one
  # actor string across a session, measured 2026-07-30) while
  # ac_roomchief_live says that roomchief is up. PROMOTED/DEMOTED/CLOSED/
  # CORRECTION stay unguarded - see the header block for why. `HANDBACK:*`
  # (colon-precise, never the broader `HANDBACK*`) deliberately excludes
  # HANDBACK-REFUSED: - that receipt is the CREWCHIEF refusing its
  # roomchief's hand-back (AGENTS.md section 8; ac_room_handback_families,
  # bin/ac-wake-lib.sh:607), always posted unscoped while the roomchief it is
  # refusing is still live, and it is the turn-end guard's only way to clear
  # an owed hand-back without demoting the family (bin/ac-turnend-guard.sh:
  # 237) - review-confirmed 2026-07-30 (CR-001): a broad `HANDBACK*` would
  # deadlock that exact path. DECIDED is guarded like every verb above, with
  # ONE named exception: ac-spawn.sh's cap-gate exemption receipt is itself a
  # bare, unscoped DECIDED: posted the instant a roomchief is promoted
  # (meta+window already live) - that ONE call site DECLARES itself via
  # AC_ROOM_PROMOTE_RECEIPT=1 (roomchief ruling 2026-07-30: an explicit
  # caller signal, never text-shape matching against ac-spawn.sh's receipt
  # prose - this guard is an ACCIDENT guard, not a security boundary, so a
  # caller declaring its own intent is the right shape, not forgery-proofing
  # a hostile one). Fails OPEN (allows the post) whenever ac_roomchief_live
  # answers NOT LIVE, whether truly not live or merely uncertain - the same
  # fail-safe direction its other callers use, and the right one here:
  # refusing a real write is worse than missing a rare duplicate.
  # STAGE-ADMISSION (AGENTS.md section 5, the staged-design-flow spec's
  # canonical stage set) is guarded like the verbs it rides with: a promoted
  # family's admission receipts belong to its live roomchief; the crewchief's
  # own pre-promote receipts pass because the guard fails open with no live
  # roomchief yet. Colon-precise (`STAGE-ADMISSION:*`, the HANDBACK:*
  # precedent) so narrative prose MENTIONING the token ("STAGE-ADMISSION
  # receipts recorded") is never refused - the receipt grammar always opens
  # with the colon, and a colon-less receipt attempt is invalid anyway (never
  # the canonical set), so letting it through this accident guard loses
  # nothing.
  case "$text" in
    GATE*|ASK*|TRIAGE*|SELF-APPROVED*|LANDED*|HANDBACK:*|R1-DISPOSITION*|DECIDED*|STAGE-ADMISSION:*)
      if [ "${AC_SCOPE:-}" != "$family" ] && [ "${AC_ROOM_PROMOTE_RECEIPT:-}" != "1" ] \
        && ac_roomchief_live "$(ac_state_dir)" "$family"; then
        ac_die "post: $family has a LIVE roomchief - its own TRIAGE/GATE/ASK/SELF-APPROVED/LANDED/HANDBACK/GATE-ROUTING/R1-DISPOSITION/DECIDED/STAGE-ADMISSION receipts belong to it, never to an unscoped caller (AGENTS.md: 'Two chiefs on one family is a role violation, not extra help')"
      fi
      ;;
  esac
  local f entry verb body head chief pending pending_before
  f="$(room_file "$family")"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '# Room: %s\n\n' "$family" >"$f"
  chief="$family-chief"
  # Captured BEFORE this entry is appended - the blocked-by-captain notify
  # below fires on the EDGE (0 -> >0), and `pending` a few lines down is
  # computed from the file AFTER the append, so it always includes this entry.
  pending_before="$(ac_room_pending "$f" 2>/dev/null || printf 0)"
  case "$pending_before" in ''|*[!0-9]*) pending_before=0 ;; esac
  entry="[$(ac_iso)] $actor> $text"
  printf -- '- %s\n' "$entry" >>"$f"
  pending="$(ac_room_pending "$f" 2>/dev/null || printf 0)"
  case "$pending" in ''|*[!0-9]*) pending=0 ;; esac
  # The ONE captain notification (ac-notify fires only when captain approval
  # is what blocks; the rule is repo-wide) - the fleet is
  # blocked BY THE CAPTAIN exactly when ac_room_pending is >0 (unchanged,
  # never re-derived: FENCE, see bin/ac-wake-lib.sh's ac_room_pending). Fire
  # on the TRANSITION into blocked (pending_before 0 -> pending >0), never on
  # every post while already blocked: a captain with one unanswered gate must
  # not be buzzed by every subsequent room line, including a SECOND GATE:/
  # ASK: posted while the first is still open (a strict edge, not a per-item
  # count - the captain already has a pending room open).
  if [ "$pending_before" = "0" ] && [ "$pending" -gt 0 ]; then
    "$(dirname "$0")/ac-notify.sh" "crew blocked" "$family: $text" 2>/dev/null || true
  fi
  # A ROOMCHIEF post carrying NO marker at all, while its family currently has
  # NO pending item, is the SHAPE of a silent escalation: the accounting says
  # nothing is pending while the chief may be waiting on an answer that will
  # never come (a chief that stops work and escalates in PROSE instead of a
  # GATE:/ASK: falls through ac_room_pending unseen - the lived case, VERIFIED
  # 2026-07-21, was a Vietnamese sentence with no ASCII-uppercase marker verb
  # at all). WARN only - never refuse: a markerless narrative post is a
  # legitimate, common thing and blocking it would break the room as a record.
  # Deliberately NOT a classifier: it fires on ANY markerless post under these
  # two conditions, ordinary status narrative included - the omission is what
  # must become visible, not whether the prose LOOKS like an escalation. The
  # verb set is section 8's closed grammar list plus this file's own
  # receipt-only additions (GATE-PASSED/GATE-LOOPED/GATE-VERIFY covered by the
  # GATE prefix) plus section 5's STAGE-ADMISSION (the staged-design-flow
  # spec's stage-set receipt - a real marker, so warning on it is noise).
  if [ "$actor" = "$chief" ] && [ "$pending" = "0" ]; then
    case "$text" in
      GATE*|ASK*|DECIDED*|TRIAGE*|SELF-APPROVED*|LANDED*|HANDBACK*|PROMOTED*|DEMOTED*|CLOSED*|CORRECTION*|R1-DISPOSITION*|STAGE-ADMISSION*) : ;;
      *) ac_warn "post: $chief posted with no marker while $family has 0 pending - if you are actually waiting on the captain, post an ASK:/GATE: instead" ;;
    esac
  fi
  # AUTO-mirror, OPT-IN (config/remote-mirror=on; fixed policy:
  # chiefs COMPOSE their family's Slack narrative themselves via
  # `ac-remote.sh thread-post` - the machine mirror is the opt-in
  # alternative, never the default). When on: every room entry rides along
  # into the family's remote thread - highlighted header
  # `emoji *[UTC+7 ts] [VERB] [<family>]* <actor>`, body bulleted on the
  # two marker families (ALL-CAPS section tokens, numbered items);
  # GATE:/ASK: carry the captain mention. Records keep the raw entry.
  # Best-effort: a failed mirror warns and the room post above already
  # succeeded.
  if [ "$(ac_config_read remote-mirror off)" = "on" ]; then
    verb="${text%%:*}"
    body="${text#*: }"
    case "$text" in
      [A-Z]*:*) head="$(ac_verb_emoji "$verb") *[$(ac_vn_ts)] [$verb] [$family]* $actor" ;;
      *) head="📝 *[$(ac_vn_ts)] [$family]* $actor"; body="$text" ;;
    esac
    body="• $(printf '%s\n' "$body" \
      | sed -E $'s/ ([A-Z][A-Z_-]{2,}: )/\\\n• \\1/g; s/ (\\([0-9]+\\) )/\\\n• \\1/g')"
    case "$text" in
      GATE:*|ASK:*)
        printf '%s\n%s\n' "$head" "$body" \
          | "$(dirname "$0")/ac-remote.sh" thread-post "$family" --mention-captain >/dev/null 2>&1 \
          || ac_warn "room mirror to remote thread failed for $family (room entry saved)" ;;
      *)
        printf '%s\n%s\n' "$head" "$body" \
          | "$(dirname "$0")/ac-remote.sh" thread-post "$family" >/dev/null 2>&1 \
          || ac_warn "room mirror to remote thread failed for $family (room entry saved)" ;;
    esac
  fi
  # Pending gates/asks drive the promoted chief pane's CAPTAIN-WAIT STAMP
  # (contract: ac-backend.sh): a family whose room waits on the captain
  # shows its <family>-chief tab BLOCKED in the herdr UI, and the settling
  # DECIDED clears it - mechanical, driven by the room grammar itself, no
  # reliance on the chief remembering a needs-decision: marker. Advisory:
  # stamp failures never fail the post. `pending` was already computed above
  # for the markerless-escalation warning; reused here rather than re-forked.
  if [ -f "$(ac_task_meta "$chief")" ]; then
    if [ "$pending" -gt 0 ]; then
      backend_mark_wait "$chief" "ĐANG CHỜ captain - $pending mục trong room $family" 2>/dev/null || true
    else
      backend_clear_wait "$chief" 2>/dev/null || true
    fi
  fi
  printf 'posted to %s\n' "$f"
}

# Pending accounting is ac_room_pending (ac-wake-lib.sh) - shared with
# ac-statusline.sh, which counts the same rooms on a no-fork budget. The
# HANDBACK state is ac_room_handback_families, in the same block and for the
# same reason: ac-turnend-guard.sh reads it on every fleet turn end.

cmd_handback() {
  # The roomchief's report-back verb: never a pane line alone. Posts the
  # room record AND publishes a durable wake for the crewchief's next drain,
  # then NUDGES the covering watcher exactly as bin/ac-done.sh's push does
  # (ac_watcher_nudge, whose contract is ac-wake-lib.sh's WATCHER NUDGE block), so a
  # hand-back wakes the crewchief in milliseconds instead of waiting out the
  # poll cycle. ADVISORY: the record is the guarantee, so the nudge never fails
  # the hand-back nor changes its exit status - it only reports its outcome.
  # HARD-WIRED FLEET (scope '' below, never AC_SCOPE): a hand-back must wake
  # the CREWCHIEF - filing it under the family would hand the family's own
  # demotion notice to the roomchief that is demoting itself. The nudge targets
  # that same fleet scope, for the same reason. Published from this script's
  # main shell (ac_wake_publish's subshell contract).
  local family="${1:-}" chief nudged
  shift 1 2>/dev/null || ac_die "usage: ac-room.sh handback <family> <text...>"
  local text="$*"
  [ -n "$family" ] && [ -n "$text" ] || ac_die "usage: ac-room.sh handback <family> <text...>"
  chief="${family}-chief"
  cmd_post "$family" "$chief" "HANDBACK: $text" >/dev/null
  ac_wake_publish "$(ac_state_dir)" '' handback "$chief" "$text"
  nudged="$(ac_watcher_nudge "$(ac_state_dir)" '' 2>/dev/null || true)"
  printf 'handback posted and queued for %s - %s\n' "$family" "$nudged"
}

cmd_pending() {
  # Public pending count - the one authoritative accounting (ac_room_pending);
  # the watcher uses it to keep gate-parked roomchiefs out of stale wakes.
  local family="${1:-}" f
  [ -n "$family" ] || ac_die "usage: ac-room.sh pending <family>"
  f="$(ac_room_file "$family")"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  ac_room_pending "$f"
}

review_body() {
  awk 'BEGIN{fm=0} /^---[[:space:]]*$/{fm++; next} fm>=2{print}' "$1"
}

r1_required_change_ids() {
  review_body "$1" | awk '
    /^## Required Changes[[:space:]]*$/ { insec=1; next }
    insec && /^## / { exit }
    insec && /^[[:space:]]*[0-9]+\./ {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      sub(/\..*/, "", line)
      print line
    }'
}

normalize_id_list() {
  local raw="$1"
  awk -v raw="$raw" '
    BEGIN {
      if (raw == "none") { print "none"; exit 0 }
      n = split(raw, a, ",")
      if (n < 1) exit 1
      for (i = 1; i <= n; i++) {
        if (a[i] !~ /^[0-9]+$/) exit 1
        id = a[i] + 0
        if (seen[id]) exit 1
        seen[id] = 1
        if (id > max) max = id
      }
      out = ""
      for (i = 1; i <= max; i++) {
        if (!seen[i]) continue
        out = out (out ? "," : "") i
      }
      if (out == "") exit 1
      print out
    }'
}

validate_disposition_partition() {
  local expected="$1" accepted="$2" disputed="$3" authority="$4"
  awk -v expected="$expected" -v accepted="$accepted" -v disputed="$disputed" -v authority="$authority" '
    function load(list, arr, label,    n, a, i) {
      if (list == "none") return 0
      n = split(list, a, ",")
      for (i = 1; i <= n; i++) {
        if (arr[a[i]]) exit 1
        arr[a[i]] = 1
      }
      return n
    }
    BEGIN {
      if (expected == "") exit 1
      load(expected, expected_map, "expected")
      ac = load(accepted, acc, "accepted")
      dc = load(disputed, dis, "disputed")
      for (id in acc) {
        if (!(id in expected_map)) exit 1
        if (id in dis) exit 1
      }
      for (id in dis) if (!(id in expected_map)) exit 1
      for (id in expected_map) if (!(id in acc) && !(id in dis)) exit 1
      if (dc == 0 && authority == "none") exit 0
      if (dc == 0 && authority != "none") exit 1
      if (dc > 0 && authority == "none") exit 1
      if (authority == "chief-owned" || authority == "captain-owned" || authority == "mixed") exit 0
      exit 1
    }'
}

cmd_gate_verify() {
  local family="${1:-}" stage="${2:-}" round="" report="" grounds="" short expected_report report_sha
  shift 2 2>/dev/null || ac_die "usage: ac-room.sh gate-verify <family> <stage> --round <1|2> --report <file> --grounds <text...>"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --round) round="${2:-}"; shift 2 ;;
      --report) report="${2:-}"; shift 2 ;;
      --grounds) shift; grounds="$*"; break ;;
      *) ac_die "usage: ac-room.sh gate-verify <family> <stage> --round <1|2> --report <file> --grounds <text...>" ;;
    esac
  done
  [ -n "$family" ] && [ -n "$stage" ] && [ -n "$round" ] && [ -n "$report" ] \
    && [ -n "${grounds//[[:space:]]/}" ] \
    || ac_die "usage: ac-room.sh gate-verify <family> <stage> --round <1|2> --report <file> --grounds <text...>"
  case "$grounds" in *$'\n'*|*$'\r'*) ac_die "gate-verify grounds must be one physical line" ;; esac
  case "$family" in *[!a-zA-Z0-9_-]*) ac_die "family must be [a-zA-Z0-9_-]: $family" ;; esac
  case "$round" in 1|2) ;; *) ac_die "gate-verify --round must be 1 or 2" ;; esac
  short="$(stage_short "$stage")" || ac_die "gate-verify stage must be spec|architecture|plan|design"
  [ -s "$report" ] && [ ! -L "$report" ] || ac_die "gate-verify --report must name a non-empty plain file"
  report="$(cd "$(dirname "$report")" && pwd -P)/$(basename "$report")"
  expected_report="$(ac_data_dir)/$family/$short/report.md"
  [ "$report" = "$expected_report" ] || ac_die "gate-verify --report must be $expected_report"
  report_sha="$(ac_sha256_file "$report")"
  cmd_post "$family" "$family-chief" \
    "GATE-VERIFY: stage=$stage round=$round report_sha256=$report_sha verdict=pass grounds=$grounds"
}

cmd_gate_route() {
  local family="${1:-}" stage="${2:-}" report="" uncertainty="" consequence="" authority="" grounds=""
  local short expected_report report_sha route
  shift 2 2>/dev/null || ac_die "usage: ac-room.sh gate-route <family> <stage> --report <file> --uncertainty <yes|no> --consequence <low|high> --authority <chief|captain> --grounds <text...>"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) report="${2:-}"; shift 2 ;;
      --uncertainty) uncertainty="${2:-}"; shift 2 ;;
      --consequence) consequence="${2:-}"; shift 2 ;;
      --authority) authority="${2:-}"; shift 2 ;;
      --grounds) shift; grounds="$*"; break ;;
      *) ac_die "usage: ac-room.sh gate-route <family> <stage> --report <file> --uncertainty <yes|no> --consequence <low|high> --authority <chief|captain> --grounds <text...>" ;;
    esac
  done
  [ -n "$family" ] && [ -n "$stage" ] && [ -n "$report" ] \
    && [ -n "$uncertainty" ] && [ -n "$consequence" ] && [ -n "$authority" ] \
    && [ -n "${grounds//[[:space:]]/}" ] \
    || ac_die "usage: ac-room.sh gate-route <family> <stage> --report <file> --uncertainty <yes|no> --consequence <low|high> --authority <chief|captain> --grounds <text...>"
  case "$grounds" in *$'\n'*|*$'\r'*) ac_die "gate-route grounds must be one physical line" ;; esac
  case "$family" in *[!a-zA-Z0-9_-]*) ac_die "family must be [a-zA-Z0-9_-]: $family" ;; esac
  case "$uncertainty" in yes|no) ;; *) ac_die "gate-route --uncertainty must be yes|no" ;; esac
  case "$consequence" in low|high) ;; *) ac_die "gate-route --consequence must be low|high" ;; esac
  case "$authority" in chief|captain) ;; *) ac_die "gate-route --authority must be chief|captain" ;; esac
  short="$(stage_short "$stage")" || ac_die "gate-route stage must be spec|architecture|plan|design"
  [ -s "$report" ] && [ ! -L "$report" ] || ac_die "gate-route --report must name a non-empty plain file"
  report="$(cd "$(dirname "$report")" && pwd -P)/$(basename "$report")"
  expected_report="$(ac_data_dir)/$family/$short/report.md"
  [ "$report" = "$expected_report" ] || ac_die "gate-route --report must be $expected_report"
  if [ "$authority" = captain ]; then
    route=captain
  elif [ "$uncertainty" = yes ] || [ "$consequence" = high ]; then
    route=second-chief
  else
    route=chief
  fi
  report_sha="$(ac_sha256_file "$report")"
  cmd_post "$family" "$family-chief" \
    "GATE-ROUTING: stage=$stage report_sha256=$report_sha uncertainty=$uncertainty consequence=$consequence authority=$authority route=$route grounds=$grounds"
}

cmd_disposition() {
  local family="${1:-}" stage="${2:-}" r1="" accepted="" disputed="" authority="" grounds="" expected r1_sha report report_sha short expected_r1 expected_report
  shift 2 2>/dev/null || ac_die "usage: ac-room.sh disposition <family> <stage> --r1 <file> --accepted <ids|none> --disputed <ids|none> --authority <chief-owned|captain-owned|mixed|none> --grounds <text...>"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --r1) r1="${2:-}"; shift 2 ;;
      --accepted) accepted="${2:-}"; shift 2 ;;
      --disputed) disputed="${2:-}"; shift 2 ;;
      --authority) authority="${2:-}"; shift 2 ;;
      --grounds) shift; grounds="$*"; break ;;
      *) ac_die "usage: ac-room.sh disposition <family> <stage> --r1 <file> --accepted <ids|none> --disputed <ids|none> --authority <chief-owned|captain-owned|mixed|none> --grounds <text...>" ;;
    esac
  done
  [ -n "$family" ] && [ -n "$stage" ] && [ -n "$r1" ] && [ -n "$accepted" ] \
    && [ -n "$disputed" ] && [ -n "$authority" ] && [ -n "${grounds//[[:space:]]/}" ] \
    || ac_die "usage: ac-room.sh disposition <family> <stage> --r1 <file> --accepted <ids|none> --disputed <ids|none> --authority <chief-owned|captain-owned|mixed|none> --grounds <text...>"
  case "$grounds" in *$'\n'*|*$'\r'*) ac_die "disposition grounds must be one physical line" ;; esac
  case "$family" in *[!a-zA-Z0-9_-]*) ac_die "family must be [a-zA-Z0-9_-]: $family" ;; esac
  short="$(stage_short "$stage")" || ac_die "disposition stage must be spec|architecture|plan|design"
  case "$authority" in chief-owned|captain-owned|mixed|none) ;; *) ac_die "disposition authority must be chief-owned|captain-owned|mixed|none" ;; esac
  [ -s "$r1" ] && [ ! -L "$r1" ] || ac_die "disposition --r1 must name a non-empty plain file"
  r1="$(cd "$(dirname "$r1")" && pwd -P)/$(basename "$r1")"
  expected_r1="$(ac_data_dir)/$family/$short/second-chief-r1.md"
  [ "$r1" = "$expected_r1" ] || ac_die "disposition --r1 must be $expected_r1"
  expected_report="$(ac_data_dir)/$family/$short/report.md"
  [ -s "$expected_report" ] && [ ! -L "$expected_report" ] || ac_die "disposition requires a non-empty current report at $expected_report"
  report="$(cd "$(dirname "$expected_report")" && pwd -P)/$(basename "$expected_report")"
  expected="$(r1_required_change_ids "$r1" | paste -sd, -)"
  [ -n "$expected" ] || ac_die "disposition R1 has no numbered Required Changes to adjudicate"
  accepted="$(normalize_id_list "$accepted")" || ac_die "disposition --accepted must be comma-separated numeric ids or none"
  disputed="$(normalize_id_list "$disputed")" || ac_die "disposition --disputed must be comma-separated numeric ids or none"
  validate_disposition_partition "$expected" "$accepted" "$disputed" "$authority" \
    || ac_die "disposition accepted/disputed ids must exactly partition R1 Required Changes, with valid authority"
  r1_sha="$(ac_sha256_file "$r1")"
  report_sha="$(ac_sha256_file "$report")"
  cmd_post "$family" "$family-chief" \
    "R1-DISPOSITION: stage=$stage r1_sha256=$r1_sha report_sha256=$report_sha accepted=$accepted disputed=$disputed authority=$authority grounds=$grounds"
}

cmd_show() {
  local family="${1:-}" n="${2:-0}" f
  [ -n "$family" ] || ac_die "usage: ac-room.sh show <family> [<n>]"
  f="$(ac_room_file "$family")"
  [ -f "$f" ] || ac_die "no room for $family"
  if [ "$n" -gt 0 ] 2>/dev/null; then
    head -n 2 "$f"
    # `|| true`: same no-match-under-pipefail trap as cmd_list - a room with no
    # entries yet is a header and nothing after it, not an error.
    grep '^- \[' "$f" | tail -n "$n" || true
  else
    cat "$f"
  fi
}

cmd_list() {
  local data_dir state_dir family pending hb last found=0 blocked disp
  data_dir="$(ac_data_dir)"
  set -- "$data_dir"/*/room.md
  if [ -f "$1" ]; then
    state_dir="$(ac_state_dir)"
    # BATCHED: ac_room_list_rows (bin/ac-wake-lib.sh) makes ONE awk pass over
    # every room.md instead of forking ac_room_pending + ac_room_handback_families
    # + basename/dirname + grep|tail|cut per room - the same anti-pattern those
    # two helpers' own headers warn against, just never applied here until now.
    # `last` comes back UNTRUNCATED; `${last:0:120}` truncates it by CHARACTER,
    # matching the original `cut -c1-120` in this UTF-8 locale (verified to
    # diverge from awk's own byte-based substr() on this fleet's everyday
    # multi-byte room text) - never re-truncate inside the shared awk.
    while IFS=$'\x1f' read -r pending hb family last; do
      found=1
      last="${last:0:120}"
      # SILENT escalation, one rung earlier than the markerless-POST warn in
      # cmd_post above: a roomchief that opens a pane SELECT and blocks posts
      # NOTHING to its room at all, so ac_room_pending (a room-marker count) has
      # no event to see and reads 0 - the inbox would then read `ok`/`clear`
      # while the captain is genuinely being waited on
      # (pane-select-escalation-leaves-the-inbox-reading-zero). Consulted ONLY
      # when the room's own accounting is already 0: ac_room_pending itself
      # (ac-wake-lib.sh) is never widened, so ac_chief_gate_parked, the turn-end
      # guard and the statusline - every consumer built on the room-marker count
      # - see exactly what they see today. The liveness source is the watcher's
      # OWN live stamp, state/.ask-<id> (bin/ac-watch.sh: touched the instant
      # backend_agent_blocked is true, removed the instant it clears) - never
      # the status log's last line, which stays `needs-decision:` forever after
      # the pane resumes and would pin every once-blocked family into the inbox
      # permanently. $state_dir is resolved ONCE above the loop, not forked per
      # room - the loop-scoped hoist a per-call-site cache cannot achieve
      # (every ac_state_dir caller captures its stdout via command
      # substitution, so a cache inside the shared function is invisible to
      # this loop once that subshell exits).
      blocked=0
      if [ "$pending" = 0 ] && [ -e "$state_dir/.ask-${family}-chief" ]; then
        blocked=1
      fi
      disp="$pending"
      [ "$blocked" = 1 ] && disp=1
      # A room that is BOTH pending AND in-handback surfaces both: HANDBACK must
      # never be masked behind a gate (it could rot until the gate clears). The
      # PENDING-CAPTAIN(<n>) token stays the byte-identical line prefix so the
      # downstream prefix-greps (ac-fleets.sh, ac-dash.sh, ac-session-start.sh)
      # still tally it; the three single-status forms are unchanged, and so is
      # PENDING-CAPTAIN(<n>) itself whenever a real room marker is what set it.
      if [ "$disp" -gt 0 ] && [ "$hb" = 1 ]; then
        printf 'PENDING-CAPTAIN(%s)+HANDBACK  %s\t%s\n' "$disp" "$family" "$last"
      elif [ "$blocked" = 1 ]; then
        printf 'PENDING-CAPTAIN(%s)+BLOCKED  %s\t%s\n' "$disp" "$family" "$last"
      elif [ "$disp" -gt 0 ]; then
        printf 'PENDING-CAPTAIN(%s)  %s\t%s\n' "$disp" "$family" "$last"
      elif [ "$hb" = 1 ]; then
        printf 'HANDBACK            %s\t%s\n' "$family" "$last"
      else
        printf 'ok                  %s\t%s\n' "$family" "$last"
      fi
    done < <(ac_room_list_rows "$@")
  fi
  [ "$found" = 1 ] || printf '(no rooms yet)\n'
  return 0
}

cmd_close() {
  local family="${1:-}"
  shift 2>/dev/null || true
  local outcome="${*:-landed}"
  [ -n "$family" ] || ac_die "usage: ac-room.sh close <family> <outcome...>"
  local f
  f="$(room_file "$family")"
  [ -f "$f" ] || ac_die "no room for $family"
  # Fail closed on all three conditions: no family member in flight, no
  # un-demoted chief, inbox empty. MEMBERSHIP is authoritative, never an id
  # PREFIX - same rule and same two sources as ac-teardown.sh's roomchief demote,
  # whose header owns the incident and the why: ac_family_of_id over the CLOSED
  # suffix grammar, or the pane's own fleet_scope. The un-demoted <fam>-chief is
  # still named EXPLICITLY as defense-in-depth: ac_family_of_id DOES resolve
  # <fam>-chief to <fam> once the nested data/<fam>/chief dir exists
  # (board-detail-shows-every-artifact), but that dir is created lazily by the
  # first status-timeline mirror, so an id check that does not depend on disk
  # timing still catches a chief in flight before its dir is ever written.
  local m other
  for m in "$(ac_state_dir)"/*.meta; do
    [ -e "$m" ] || continue
    # A VERIFICATION agent is not crew (ac_meta_is_verify owns the class): it
    # carries no backlog row and nobody demotes it, so counting it here would
    # let a ship reviewer hold its own family's room open forever.
    ac_meta_is_verify "$m" && continue
    other="$(basename "$m" .meta)"
    if [ "$other" = "$family-chief" ] \
      || [ "$(ac_family_of_id "$other")" = "$family" ] \
      || [ "$(ac_meta_get "$m" fleet_scope)" = "$family" ]; then
      ac_die "close: $other is still in flight"
    fi
  done
  [ "$(ac_room_pending "$f")" = "0" ] || ac_die "close: room $family still has pending gates/asks (answer them first)"
  printf -- '- [%s] crewchief> CLOSED: %s\n' "$(ac_iso)" "$outcome" >>"$f"
  # A promoted family's OWN wake-spool dir (state/.wake-spool.<family>/) is
  # never removed by task teardown - a family outlives its individual tasks -
  # so it grows by one per promote, forever, unless something removes it once
  # the family is genuinely done. HERE, not teardown, is that place: the
  # preflight above already confirmed no family crewmate/roomchief is in
  # flight, so no producer can still reach this scope. REFUSE (never silently
  # skip) to remove a NON-EMPTY spool - an undrained wake record must never be
  # deleted to tidy up - via ac_spool_has_record, the ONE spool-pending
  # predicate (ac-wake-lib.sh), so this can never disagree with
  # ac_wake_pending/ac-wake-drain.sh about what counts as non-empty. The bare
  # rmdir only ever succeeds truly empty, so even a last-instant race is safe.
  local spool
  spool="$(ac_wake_spool_path "$(ac_state_dir)" "$family")"
  if [ -d "$spool" ]; then
    if ac_spool_has_record "$spool"/*; then
      ac_warn "close: $family's wake spool ($spool) still holds undrained records - not removing it"
    else
      rmdir "$spool" 2>/dev/null \
        || ac_warn "close: $family's wake spool ($spool) could not be removed"
    fi
  fi
  printf 'room %s closed: %s\n' "$family" "$outcome"
}

cmd_open() {
  # The consented redirect: focus the promoted room's chief window. Callers
  # (the gate) run this ONLY after the captain confirmed the hop.
  local family="${1:-}" chief meta
  [ -n "$family" ] || ac_die "usage: ac-room.sh open <family>"
  chief="${family}-chief"
  meta="$(ac_task_meta "$chief")"
  [ -f "$meta" ] || ac_die "room $family is not promoted (no $chief in flight); promote with ac-spawn.sh --roomchief $family, or keep talking here"
  AC_BACKEND="$(ac_task_backend "$chief")"
  export AC_BACKEND
  backend_window_alive "$chief" || ac_die "roomchief window is gone; respawn (--roomchief $family) or teardown $chief"
  backend_focus "$chief" || ac_die "could not focus $chief"
  printf 'focused %s (%s)\n' "$chief" "$(backend_target "$chief")"
}

case "${1:-}" in
  post) shift; cmd_post "$@" ;;
  show) shift; cmd_show "$@" ;;
  list) shift; cmd_list "$@" ;;
  close) shift; cmd_close "$@" ;;
  open) shift; cmd_open "$@" ;;
  pending) shift; cmd_pending "$@" ;;
  handback) shift; cmd_handback "$@" ;;
  gate-route|route-gate) shift; cmd_gate_route "$@" ;;
  gate-verify|verify-gate) shift; cmd_gate_verify "$@" ;;
  disposition) shift; cmd_disposition "$@" ;;
  *) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
