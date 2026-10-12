#!/usr/bin/env bash
# ac-notify-surface.test.sh - the ac-notify.sh call-site invariant, held
# repo-wide: a notification is only ever for a block on the captain.
# ac-notify.sh fires ONLY on the blocked-by-captain
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
#
# Since the room and notify moved to TypeScript (src/room.ts, src/notify.ts)
# the one call is an IMPORT plus a `notify(` call inside src/room.ts's post,
# and bin/ac-room.sh is a shim naming no notify at all - so the guard reads the
# TypeScript too: every non-comment line of src/*.ts and dashboard/*.ts (the
# module's own file excluded) that names notify.ts or ac-notify.sh, or calls
# `notify(`, must be exactly that import and that call, and bin/ must name the
# script nowhere.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# notify_call_sites <dir> - file:line:content for every NON-COMMENT mention
# of the literal script name ac-notify.sh across <dir>/*.sh, excluding
# ac-notify.sh's own file (its header/usage lines describe the script, they
# never invoke it). A comment is a line whose content, after the grep
# file:line: prefix is stripped, starts with optional whitespace then '#' -
# the shape of every legitimate mention this family's own fix added. No
# mention outside ac-notify.sh is the passing case, and there `grep -v` selects
# nothing and exits 1 - under pipefail that must not end the suite.
notify_call_sites() {
  grep -n 'ac-notify\.sh' "$1"/*.sh \
    | grep -v '^'"$1"'/ac-notify.sh:' \
    | awk -F: '{ line=$0; sub(/^[^:]*:[^:]*:/, "", line); if (line !~ /^[[:space:]]*#/) print }' \
    || true
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

# notify_ts_sites <dir>... - file:line:content for every NON-COMMENT line of
# <dir>/*.ts naming the module (notify.ts, ac-notify.sh) or calling `notify(`,
# notify.ts's own file excluded. A comment is a line whose content starts with
# optional whitespace then '//'.
notify_ts_sites() {
  local d
  for d in "$@"; do
    grep -nE 'notify\.ts|ac-notify\.sh|(^|[^A-Za-z0-9_])notify\(' "$d"/*.ts \
      | grep -v '^'"$d"'/notify.ts:' \
      | awk -F: '{ line=$0; sub(/^[^:]*:[^:]*:/, "", line); if (line !~ /^[[:space:]]*\/\//) print }' \
      || true
  done
}

# --- RED proof, TypeScript: a planted importer, and a second call line in the
# --- one importer, each show up on an isolated fixture.
tsfix="$TMP/notify-surface-ts"
mkdir -p "$tsfix"
cat >"$tsfix/notify.ts" <<'EOF'
// notify.ts - fixture stand-in: its own notify( and notify.ts never count.
export function notify(title: string, message: string): void {}
notify("a", "b");
EOF
cat >"$tsfix/room.ts" <<'EOF'
// room.ts calls notify( on the edge; this comment never counts.
import { notify } from "./notify.ts";
function post(): void {
  notify("crew blocked", "fam: GATE: x");
}
EOF
assert_eq "$(notify_ts_sites "$tsfix" | grep -c . || true)" "2" \
  "ts fixture baseline: one import and one call, the comment mentions must not count"
cat >"$tsfix/planted.ts" <<'EOF'
import { notify as ring } from "./notify.ts";
EOF
assert_eq "$(notify_ts_sites "$tsfix" | grep -c . || true)" "3" "the guard catches a planted TypeScript importer"
rm -f "$tsfix/planted.ts"
printf '  notify("crew report", "t1: done");\n' >>"$tsfix/room.ts"
assert_eq "$(notify_ts_sites "$tsfix" | grep -c . || true)" "3" "the guard catches a second notify( call in the one importer"

# --- the real invariant, over the actual repo -------------------------------
sites="$(notify_call_sites "$BIN")"
count="$(printf '%s\n' "$sites" | grep -c . || true)"
assert_eq "$count" "0" "bin/ must name ac-notify.sh nowhere - its one caller is src/room.ts (repo-wide blocked-by-captain invariant) - found:
$sites"

tsites="$(notify_ts_sites "$ROOT/src" "$ROOT/dashboard")"
want="$ROOT/src/room.ts:$(grep -n '^import { notify } from "./notify.ts";$' "$ROOT/src/room.ts" | cut -d: -f1):import { notify } from \"./notify.ts\";"
assert_eq "$(printf '%s\n' "$tsites" | grep -c . || true)" "2" "exactly one notify import and one notify( call must remain in src/ and dashboard/ - found:
$tsites"
assert_eq "$(printf '%s\n' "$tsites" | head -n 1)" "$want" "the one import is src/room.ts's - found:
$tsites"
case "$(printf '%s\n' "$tsites" | tail -n 1)" in
  "$ROOT/src/room.ts:"*'notify("crew blocked", '*) : ;;
  *) fail "the one notify( call must be src/room.ts's post, on the blocked-by-captain edge - found:
$tsites" ;;
esac

pass
