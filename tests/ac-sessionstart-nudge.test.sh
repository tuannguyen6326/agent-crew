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

# 3. Crewdeputy home, unowned: NUDGED. The `ac <deputy>` launcher opens a
#    plain chief session there with no kickoff to order session-start; a
#    SPAWNED deputy holds a live lock or eats one redundant line - harmless.
d="$TMP/deputy"; mkdir -p "$d/state"; : >"$d/.ac-crewdeputy-home"
run "$d"
assert_eq "$rc" 0 "crewdeputy home: exit 0"
assert_contains "$out" "$line" "an unowned crewdeputy home is nudged - a plain session has no kickoff to say it"
# ... and under a LIVE lock it goes silent like any owned home.
printf 'pid=%s\nsince=2026-07-18T00:00:00Z\n' "$$" >"$d/state/.session-lock"
run "$d"
[ -z "$out" ] || fail "a crewdeputy home under a LIVE lock must not be nudged (got: $out)"
rm -f "$d/state/.session-lock"

# 4. Linked worktree = a crewmate checkout (the self-hosting footgun): silent.
#    A real git worktree is the only faithful way to make git-dir != common-dir.
repo="$(make_repo nudgerepo)"
wt="$TMP/linked-wt"
git -C "$repo" worktree add -q --detach "$wt" >/dev/null 2>&1
run "$wt"
assert_eq "$rc" 0 "linked worktree: exit 0"
[ -z "$out" ] || fail "a crewmate's linked worktree must never be nudged (got: $out)"

# A SOLO session (AC_SOLO=1) is ORIENTED, not deputized: session-start still
# runs (it goes read-only under AC_SOLO), and the one write path is self-task.
out="$(AC_SOLO=1 AC_HOME="$g" "$NUDGE" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "solo session: exit 0"
assert_contains "$out" "SOLO" "solo session gets the solo orientation"
assert_contains "$out" "NOT the crewchief" "the orientation denies the chief identity outright"
assert_contains "$out" "ac-self-task.sh" "the orientation names the one write path"
assert_contains "$out" "ac-session-start.sh" "solo still runs session-start (read-only)"
# Subagent discipline: the seeded crewmate layer reaches a subagent only
# through the prompt (instruction files load by the SESSION's cwd, never by
# the tree a subagent touches), so the orientation must carry the pointer
# rule and the one-writer rule.
assert_contains "$out" "at the seeded crewmate instruction file" "the orientation points write-subagents at the seeded layer"
assert_contains "$out" "one at a time" "the orientation carries the one-writer-per-worktree rule"
# The crewmate layer is read FROM THE SEEDED TREE, per slice - self-task
# start already seeds the full merge (container baseline, learned, fleet,
# domain) into the worktree, so the two-file direct read at $AC_HOME is gone.
# "Instruction file", not a hardcoded path: a solo session is not only
# claude, and --harness routes the seed to the file that harness loads.
assert_contains "$out" "begin each slice by reading the seeded crewmate instruction file" "the orientation sends the slice read to the seeded worktree file"
case "$out" in *'$AC_HOME/CREWMATE.md'*) fail "the two-file direct read must be gone - the seeded tree is the one source" ;; esac
# ...and the orientation is UNCONDITIONAL: it must survive every silence gate
# below it - a LIVE chief session-lock (the exact solo scenario: a second
# session beside a working chief) and even a home the gates cannot resolve.
printf 'pid=%s\nsince=2026-08-28T00:00:00Z\n' "$$" >"$g/state/.session-lock"
out="$(AC_SOLO=1 AC_HOME="$g" "$NUDGE" 2>/dev/null)"
assert_contains "$out" "NOT the crewchief" "the solo orientation survives a live chief lock"
rm -f "$g/state/.session-lock"
out="$(AC_SOLO=1 "$NUDGE" 2>/dev/null)"
assert_contains "$out" "NOT the crewchief" "the solo orientation survives an unresolvable home"

# 5. Fail open: an unresolvable home exits 0 silently, never blocking init.
run "$TMP/does-not-exist"
assert_eq "$rc" 0 "a broken home fails open (exit 0), never blocks session init"

pass
