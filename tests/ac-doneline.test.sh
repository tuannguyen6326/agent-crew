#!/usr/bin/env bash
# ac-doneline.test.sh - the ONE shared backlog Done-line parser (ac-lib.sh's
# AC_DONELINE_AWK / ac_doneline()): id + terminal marker + epic + blocked-by +
# date + verb, extracted from REAL records/backlog.md + backlog-archive.md
# shapes. The fixture is grepped-verbatim real Done lines - the awkward ones the
# earlier INERT learn-flow parser mis-handled: verbs beyond merged/reported, a
# date mid-parenthetical with trailing prose, verb+date sitting outside any
# group, a nested-paren tail, [EPIC]/[abandoned] markers, epic:<id> story lines,
# and the two lines whose PROSE mentions [failed] at a non-grammar position (the
# false positive the fixed-position terminal check now refuses).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }
. "$BIN/ac-lib.sh"

# One field row per line: id|terminal|epic|blockers|date|verb
parse() {
  awk "$AC_DONELINE_AWK"'
    /^- \[[ x]\] / {
      ac_doneline($0, o)
      printf "%s|%s|%s|%s|%s|%s\n", o["id"], o["terminal"], o["epic"], o["blockers"], o["date"], o["verb"]
    }
  ' "$1"
}

# id|blockers|malformed - the blocked-by half alone.
parse_blockers() {
  awk "$AC_DONELINE_AWK"'
    /^- \[[ x]\] / {
      ac_doneline($0, o)
      printf "%s|%s|%s\n", o["id"], o["blockers"], o["blockers_malformed"]
    }
  ' "$1"
}

# Real Done lines, grepped verbatim from the drydock ledger + archive (the awkward
# ones), plus one section-9 Queued line to exercise epic + blocked-by extraction.
FX="$TMP/doneshapes.md"
cat >"$FX" <<'EOF'
## Queued
- [ ] recon - reconciliation; epic:payv2 blocked-by: checkout,refund - needs both APIs

## Done
- [x] crewmate-missing-from-agents-grouped-view - NOT REPRODUCED on herdr 0.7.3 (all ac-spawn panes ARE detected as agents in the grouped view); root cause was the captain's herdr SERVER on a pre-#318 build - FIXED UPSTREAM by herdr #318 - so NO agent-crew change needed; captain accepted close (reported 2026-07-24)
- [x] ac-gate-second-chief-unavailable-captain-md-over-cap - ac-gate no longer ac_dies on an over-cap captain.md: it feeds a bounded-with-notice captain.md to the second chief instead of aborting, so gates run + the board opens again (captain.md>8000 no longer blinds every gate) - local main @6123f8e (bin/ac-gate.sh + tests, self-reviewed, changed-file tests green) (merged 2026-07-24; captain iterated further gate work @c538321). Fix landed via a 6th crewmate-edits instance (dropped 28892c8) - captain hand-recovered main, all fixes now present.
- [x] crewmate-edits-primary-checkout - GUARD landed: a pre-commit hook (in bin/ac-tree.sh, seeded lease-time) REFUSES a crewmate/roomchief git-commit in the primary checkout (fail-closed, fail-open on rev-parse error) + brief/spawn path-clarity - closes the recurring silent-main-advance bug (6 instances, incl a DATA-LOSS one that dropped landed 28892c8) - local main @da5a33c (4 files +365, self-reviewed + changed-file tests green) (merged 2026-07-24)
- [x] qa-profile-resolve [EPIC] - DONE 5/5 stories landed on local main + integration-verified (2026-07-24). Delivered the fail-closed QA PROFILE RESOLVE: project-config-path@5b2b45e (canonical config path + 3-state migration) flow=direct mode=local-only review=no per captain ruling (repo: agent-crew; no push/PR). [captain [EPIC] 2026-07-23; closed 2026-07-24]
- [x] qa-profile-guidance - removed normal-run repo/infra onboarding discovery from crew-qa/crew-ship SKILL.md + regression test; a fresh QA verifier receives a resolved profile and does not re-discover - local main @cd1efa4 (merged 2026-07-24) [epic:qa-profile-resolve story 5; review=no; changed-file tests green (ac-skills-catalog + new ac-qa-profile-guidance); docs/skill only, clean crew-branch + FF]
- [x] reports-suffix-md [abandoned] - MOOT, superseded (cleared 2026-07-24 after backlog-validity-audit): the cited "Reports discovery name filter" no longer exists. Evidence: current code state (audit could not pin the exact resolving commit - the dashboard path-based rewrite). (abandoned 2026-07-24)
- [x] codegraph-hook-fix - MITIGATION (2) LANDED: CODEGRAPH_NO_PROMPT_HOOK=1 now rides every crew launch line via a codegraph_env constant in bin/ac-spawn.sh - stops the 161s (30s-capped) stall on every chief spawn - local main @5c625d4 (merged 2026-07-21; captain-ordered "chay ngay unpromoted", off-cap; ref data/codegraph-hook-timeout-diag/report.md §8(2))
- [x] stress-sh-sweep-guard [abandoned] - premise FALSIFIED against the tree (design scout): reap guard present since f9ac3a1 - trap kill_runs EXIT + reap_hogs (tests/stress.sh:69-75) + host budget cores/2 (:38-50) - Karpathy drop (2026-07-20)
- [x] ready-marker-matches-prose-not-position - ac-ready.sh snapshot() now anchors the [EPIC]/[failed]/[abandoned] terminal marker to its grammar position (token after the id) instead of substring-matching the whole line - local main @20d29cb (2 files, +36/-3; 3 colocated tests in tests/ac-ready.test.sh; run-suite 69/69) (merged 2026-07-23). WIDER THAN BRIEFED: it also stranded dependents of a cleanly-merged ## Done line.
- [x] remote-poll-family-thread-gc - a thread is INACTIVE when its family's backlog line is TERMINAL ([x]/[failed]/[abandoned]) OR its room is closed - local main @bc2107d (merged 2026-07-22). Follow-up: config-selffill has no backlog line in either ledger - now auto-GC'd by this fix (no reconcile needed)
EOF

got="$(parse "$FX")"

want() { assert_contains "$got" "$1" "${2:-$1}"; }

# Queued line: epic + blocked-by (comma-joined, no spaces), no date/verb.
want "recon||payv2|checkout,refund||" "epic + blocked-by extraction on a Queued line"

# Verb beyond merged/reported, date ends the group (simple case).
want "crewmate-missing-from-agents-grouped-view||||2026-07-24|reported" "verb=reported"

# Date mid-parenthetical with trailing prose, then a later date-less group ->
# fallback to the last YYYY-MM-DD anywhere; verb = the word before it.
want "ac-gate-second-chief-unavailable-captain-md-over-cap||||2026-07-24|merged" "date mid-group + trailing (dropped ...) group falls back to last date"

want "crewmate-edits-primary-checkout||||2026-07-24|merged" "plain (merged <date>) group"

# [EPIC] terminal at the grammar position; the last group carries no date so the
# verb/date come from the trailing `closed 2026-07-24` outside any group.
want "qa-profile-resolve|epic|||2026-07-24|closed" "[EPIC] marker + verb=closed from a verb+date outside any group"

# epic:<id> story line whose date group has trailing [epic:...] prose after it.
want "qa-profile-guidance||qa-profile-resolve||2026-07-24|merged" "epic story line, date group + trailing prose"

# [abandoned] marker at position 2; date group present.
want "reports-suffix-md|abandoned|||2026-07-24|abandoned" "[abandoned] marker + (abandoned <date>) group"

# Nested-paren tail (§8(2)) defeats the non-nested group walk -> fallback to the
# last YYYY-MM-DD anywhere; verb = word before it.
want "codegraph-hook-fix||||2026-07-21|merged" "nested-paren tail falls back to the last date on the line"

# date-only group -> verb has no leading word -> unknown; terminal wins downstream.
want "stress-sh-sweep-guard|abandoned|||2026-07-20|unknown" "[abandoned] + a bare (date) group yields verb=unknown"

# THE REGRESSION: a line whose PROSE mentions [failed]/[abandoned] at a
# non-grammar position is NOT terminal - the shared parser keys the terminal
# marker on position rp[2] (a `-`), so it resolves to its real verb/date. The
# earlier inert learn-flow parser substring-matched [failed] and mislabelled
# these two as terminal=failed.
want "ready-marker-matches-prose-not-position||||2026-07-23|merged" "prose [failed] at a non-grammar position is NOT a terminal marker (regression: was failed)"
want "remote-poll-family-thread-gc||||2026-07-22|merged" "prose [failed] in a fixed-earlier-failure description is NOT terminal (regression: was failed)"

# And no real Done line above is ever mislabelled terminal=failed by prose.
case "$got" in *"|failed|"*) fail "no fixture line carries a real [failed] marker - none must resolve terminal=failed" ;; esac

# --- blocked-by: a grammar slip reads MALFORMED, never "no blockers" ---------
#
# AGENTS.md section 9 pins `blocked-by: id1,id2 - reason` (one space,
# lowercase, comma-joined, no spaces). Every slip used to parse to an EMPTY
# blockers field, and ac-ready.sh reads empty blockers as READY - so under the
# standing autonomous-drain rule a chief starts a story whose dependency is
# still flying. The opposite slip (`, ` inside the list) yielded a trailing
# empty blocker id that can never be Done: a permanently stuck row whose STUCK
# line names no blocker at all.
BFX="$TMP/blockedby.md"
cat >"$BFX" <<'EOF'
## Queued
- [ ] legal - the pinned shape (repo: r) blocked-by: checkout,refund - needs both
- [ ] nospace - no space after the colon (repo: r) blocked-by:checkout,refund - needs both
- [ ] twospace - two spaces after the colon (repo: r) blocked-by:  checkout,refund - needs both
- [ ] upper - capitalised verb (repo: r) Blocked-by: checkout,refund - needs both
- [ ] listspace - a space inside the id list (repo: r) blocked-by: checkout, refund - needs both
- [ ] nolink - a row with no dependency at all (repo: r)
- [ ] tail - the token ends the line (repo: r) blocked-by: checkout
- [ ] unblocked - reads "unblocked-by the checkout fix" in prose (repo: r)
EOF
bgot="$(parse_blockers "$BFX")"
# EXACT LINE, never a substring: the malformed flag is the LAST field, so a
# contains-assert for `id|blockers|` matches `id|blockers|1` too and cannot
# tell a clean row from a malformed one (it read GREEN against the pre-fix
# parser when checked).
bwant() {
  printf '%s\n' "$bgot" | grep -qxF "$1" \
    || fail "${2:-$1}: no line exactly '$1' in: $bgot"
}

bwant "legal|checkout,refund|" "the pinned shape parses unchanged, and is not malformed"
bwant "tail|checkout|" "a token ending the line parses unchanged"
bwant "nolink||" "a line carrying no blocked-by token at all is neither blocked nor malformed"
bwant "nospace||1" "a missing space reads MALFORMED, not 'no blockers'"
bwant "twospace||1" "a double space reads MALFORMED"
bwant "upper||1" "a capitalised Blocked-by reads MALFORMED"
bwant "listspace||1" "a space inside the id list reads MALFORMED, not a trailing empty id"
# The lenient detector is word-broken: a longer word merely ENDING in the token
# is not a blocked-by declaration, so it must not strand a startable row.
bwant "unblocked||" "prose containing 'unblocked-by' is neither a blocker nor malformed"

pass

# ---- domain:<name> (crewdomain-token) -------------------------------------
# Two-arm position rule: authoritative before a trailing (repo: ...) group or
# at end-of-line; anywhere else unquoted = malformed (fail-visible); a
# backtick-wrapped run is a documentation mention. epic: and domain: coexist.
parse_domain() {
  awk "$AC_DONELINE_AWK"'
    /^- \[[ x]\] / {
      ac_doneline($0, o)
      printf "%s|%s|%s|%s\n", o["id"], o["domain"], o["domain_malformed"], o["epic"]
    }
  ' "$1"
}

DFX="$TMP/domainshapes.md"
cat >"$DFX" <<'DEOF'
## Queued
- [ ] payfix - round the payout row; domain:payments (repo: payments-core)
- [ ] payfix2 - waits on api (repo: payments-core) blocked-by: payapi - contract first; domain:payments
- [ ] story1 - conversion leg; epic:payv2; domain:payments (repo: ledger-api)
- [ ] prose1 - the row merely mentions domain:payments in prose (repo: notify-svc)
- [ ] prose2 - documents the `domain:payments` token shape (repo: notify-svc)
- [ ] misplaced - forgot the semicolon domain:payments (repo: notify-svc)

## Done
- [x] payland - landed the rounding fix - local main (merged 2026-08-18); domain:payments
DEOF

dgot="$(parse_domain "$DFX")"
assert_contains "$dgot" "payfix|payments||" "arm 1: token before the trailing (repo:) group"
assert_contains "$dgot" "payfix2|payments||" "arm 2: token at end-of-line on a blocked row"
assert_contains "$dgot" "story1|payments||payv2" "epic: and domain: coexist on one story row"
assert_contains "$dgot" "prose1||1|" "an unquoted prose mention is malformed, never authoritative"
assert_contains "$dgot" "prose2|||" "a backtick-quoted mention is inert - no token, no flag"
assert_contains "$dgot" "misplaced||1|" "a token off both arms is malformed, fail-visible"
assert_contains "$dgot" "payland|payments||" "a Done row keeps its token (arm 2) as durable provenance"

# The token is date-free by charset: date/verb extraction unmoved by the stamp.
dv="$(awk "$AC_DONELINE_AWK"'
  /^- \[x\] payland/ { ac_doneline($0, o); printf "%s|%s\n", o["verb"], o["date"] }
' "$DFX")"
assert_eq "$dv" "merged|2026-08-18" "date/verb parse is inert to a trailing domain token"
