#!/usr/bin/env bash
# ac-sessionstart-nudge.test.sh - the SessionStart "run session-start" reminder:
# prints on a genuine unowned home, stays silent where a session must NOT be
# nudged (crewmate worktree, crewdeputy home, a home under a live lock), and
# ALWAYS exits 0 so it can never block session init.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

NUDGE="$BIN/ac-sessionstart-nudge.sh"
line="ac-session-start.sh"

run() { out="$(AC_HOME="$1" "$NUDGE" 2>/dev/null)"; rc=$?; }

# 1. Genuine primary home: no marker, not a linked worktree, no lock -> nudge.
g="$TMP/genuine"; mkdir -p "$g/state"
run "$g"
assert_eq "$rc" 0 "genuine home: exit 0"
assert_contains "$out" "$line" "genuine home is nudged"

# 2. A live session lock means session-start already ran (or another session
#    owns the home): silent. pid=$$ is this test process - guaranteed alive.
printf 'pid=%s\nsince=2026-07-18T00:00:00Z\n' "$$" >"$g/state/.session-lock"
run "$g"
assert_eq "$rc" 0 "live-lock home: exit 0"
[ -z "$out" ] || fail "a home under a LIVE lock must not be nudged (got: $out)"

# 2b. A STALE lock (dead holder) is a home whose last session died: a fresh
#     session SHOULD run session-start, so the nudge returns.
printf 'pid=%s\nsince=2026-07-18T00:00:00Z\n' 99999999 >"$g/state/.session-lock"
run "$g"
assert_contains "$out" "$line" "a stale lock still nudges - the prior session is gone"
rm -f "$g/state/.session-lock"

# 3. Crewdeputy home: its spawn kickoff already orders session-start -> silent.
d="$TMP/deputy"; mkdir -p "$d/state"; : >"$d/.ac-crewdeputy-home"
run "$d"
assert_eq "$rc" 0 "crewdeputy home: exit 0"
[ -z "$out" ] || fail "a crewdeputy home must not be nudged (got: $out)"

# 4. Linked worktree = a crewmate checkout (the self-hosting footgun): silent.
#    A real git worktree is the only faithful way to make git-dir != common-dir.
repo="$(make_repo nudgerepo)"
wt="$TMP/linked-wt"
git -C "$repo" worktree add -q --detach "$wt" >/dev/null 2>&1
run "$wt"
assert_eq "$rc" 0 "linked worktree: exit 0"
[ -z "$out" ] || fail "a crewmate's linked worktree must never be nudged (got: $out)"

# 5. Fail open: an unresolvable home exits 0 silently, never blocking init.
run "$TMP/does-not-exist"
assert_eq "$rc" 0 "a broken home fails open (exit 0), never blocks session init"

pass
