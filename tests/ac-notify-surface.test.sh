#!/usr/bin/env bash
# ac-notify-surface.test.sh - the ac-notify.sh call-site invariant (captain
# 2026-07-30: "can t duyet moi call ac-notify" + "block boi captain" +
# "apply cho ca repo"). ac-notify.sh fires ONLY on the blocked-by-captain
# transition - a room GATE:/ASK: pending on them (ac_room_pending's edge
# into >0, bin/ac-room.sh's cmd_post). This test is the repo-wide guard the
# scope asked for: it greps every bin/*.sh for a NON-COMMENT mention of the
# SCRIPT NAME ac-notify.sh - not one particular call idiom - and fails the
# moment a second call site appears anywhere, so a future caller cannot
# quietly reintroduce a non-captain notify the way the removed
# ask/gone/unobservable/handback/remote-order calls once did.
#
# NAME, not idiom (roomchief verification finding, 2026-07-30): this repo
# runs sibling-script calls through TWO live shapes -
# "$(dirname "$0")/<script>" (127 uses) and "$(ac_root)/bin/<script>" (7
# uses, in bin/ac-backend.sh, bin/ac-brief.sh, bin/ac-lib.sh). Matching only
# the first idiom leaves the second as a silent bypass for exactly the
# accident this test exists to catch - a later ac-lib.sh/ac-backend.sh/
# ac-brief.sh change could add a non-captain notify in the idiom those files
# already prefer and this test would never see it. A non-comment line naming
# ac-notify.sh, in ANY shape, counts; the RED-proof section below drives a
# planted ac_root-idiom call through the same check, on an isolated fixture
# (never a real bin/ script), to prove the widened guard actually catches it.
#
# Adding a genuinely new blocked-by-captain notify path: it still has to run
# through cmd_post's own edge (there is exactly one predicate,
# ac_room_pending, and exactly one place that acts on its transition) - so a
# second call site anywhere else is by construction a non-captain notify and
# this test is meant to fail on it.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# notify_call_sites <dir> - file:line:content for every NON-COMMENT mention
# of the literal script name ac-notify.sh across <dir>/*.sh, excluding
# ac-notify.sh's own file (its header/usage lines describe the script, they
# never invoke it). A comment is a line whose content, after the grep
# file:line: prefix is stripped, starts with optional whitespace then '#' -
# the shape of every legitimate mention this family's own fix added.
notify_call_sites() {
  grep -n 'ac-notify\.sh' "$1"/*.sh \
    | grep -v '^'"$1"'/ac-notify.sh:' \
    | awk -F: '{ line=$0; sub(/^[^:]*:[^:]*:/, "", line); if (line !~ /^[[:space:]]*#/) print }'
}

# --- RED proof: the guard must catch a call site in the OTHER live
# --- sibling-call idiom, not just the one this family's fix happens to use.
# --- Built on an ISOLATED fixture dir - never by mutating a real bin/ script.
fixture="$TMP/notify-surface-fixture"
mkdir -p "$fixture"
cat >"$fixture/ac-notify.sh" <<'EOF'
#!/usr/bin/env bash
# ac-notify.sh - fixture stand-in, never invoked. Mentions of its own name
# here must never count as a call site.
EOF
cat >"$fixture/ac-room.sh" <<'EOF'
#!/usr/bin/env bash
# a comment mentioning ac-notify.sh in prose must never count as a call site.
cmd_post() {
  "$(dirname "$0")/ac-notify.sh" "crew blocked" "$family: $text" 2>/dev/null || true
}
EOF

baseline="$(notify_call_sites "$fixture" | grep -c . || true)"
assert_eq "$baseline" "1" \
  "fixture baseline: one real call site (dirname-\$0 idiom), the comment mention must not count"

cat >"$fixture/ac-lib-planted.sh" <<'EOF'
#!/usr/bin/env bash
# a hypothetical second caller using the OTHER live sibling-call idiom this
# repo already runs on (bin/ac-backend.sh, bin/ac-brief.sh, bin/ac-lib.sh)
queue_wake() {
  "$(ac_root)/bin/ac-notify.sh" "crew report" "$id: $payload" 2>/dev/null || true
}
EOF
planted="$(notify_call_sites "$fixture" | grep -c . || true)"
assert_eq "$planted" "2" \
  "the guard must catch a call site in the ac_root/bin idiom too, not just dirname-\$0 - a NAME-based check, never an idiom-based one"

rm -f "$fixture/ac-lib-planted.sh"
restored="$(notify_call_sites "$fixture" | grep -c . || true)"
assert_eq "$restored" "1" \
  "removing the planted second call site returns the fixture to exactly one (GREEN)"

# --- the real invariant, over the actual repo -------------------------------
sites="$(notify_call_sites "$BIN")"
count="$(printf '%s\n' "$sites" | grep -c . || true)"
assert_eq "$count" "1" "exactly one ac-notify.sh call site must remain in bin/ (repo-wide blocked-by-captain invariant) - found:
$sites"

printf '%s\n' "$sites" | grep -q '^'"$BIN"'/ac-room.sh:' \
  || fail "the one remaining ac-notify.sh call site must be in bin/ac-room.sh (cmd_post's blocked-by-captain edge) - found:
$sites"

pass
