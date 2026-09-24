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

# rc is captured through `||` so a non-zero exit REPORTS through the assertion
# below it: unprotected, errexit kills the suite with no message, and "the hook
# exited non-zero" is exactly what these cases exist to state out loud.
run() { rc=0; out="$(AC_HOME="$1" "$NUDGE" 2>/dev/null)" || rc=$?; }

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
# A self task left in flight by an earlier session is named at the next start,
# with both ways out - in the solo orientation and in the chief nudge alike.
mkdir -p "$g/state"
printf 'kind=self\nproject=alpha\nworktree=/nonexistent\n' >"$g/state/s9.meta"
sout="$(AC_SOLO=1 AC_HOME="$g" "$NUDGE" 2>/dev/null)"
assert_contains "$sout" "self task s9 (alpha" "solo orientation names the in-flight self task"
assert_contains "$sout" "ac-teardown.sh s9 --force" "...with the discard command"
cout="$(AC_HOME="$g" "$NUDGE" 2>/dev/null)"
assert_contains "$cout" "self task s9 (alpha" "the chief nudge names it too"
rm -f "$g/state/s9.meta"
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

# --- 6. THE HOMELESS SESSION ------------------------------------------------
# AC_HOME absent is the one state no ac- hook can otherwise report: ac_home
# refuses by design, all four hooks swallow the refusal into exit 0, and the
# trace that would have recorded the silence lives under the home they cannot
# resolve. This hook is the venue, and the whole difficulty is the
# DISCRIMINATOR - a crewmate is LEGITIMATELY homeless (ac-spawn.sh: "A crewmate
# gets no AC_HOME"), and this same settings.json is seeded into every crewmate
# worktree, so a signal keyed on the refusal alone would shout at the whole crew.
sig="AC_HOME is not set in this session"
# rc is captured WITHOUT letting errexit abort: a non-zero exit is the very
# thing acceptance asks about (it would block session init), so it must be
# reported by an assertion, not by the suite dying silently.
homeless() { rc=0; out="$(cd "$1" && shift && env -u AC_HOME "$@" "$NUDGE" 2>/dev/null)" || rc=$?; }

# (a) CHIEF-SHAPED: no crew scalars, and a cwd that is not a git checkout at
#     all - the shape of every fleet home (workspace = home, repo = code).
chief="$TMP/homeless-chief"; mkdir -p "$chief/state"
if git -C "$chief" rev-parse --git-dir >/dev/null 2>&1; then
  fail "fixture precondition: $chief must not sit inside a git repo - a fleet home is not one"
fi
homeless "$chief"
assert_eq "$rc" 0 "homeless chief: exit 0 - a SessionStart hook must never block init"
assert_contains "$out" "$sig" "a chief-shaped homeless session is told its hooks are inert"
assert_contains "$out" "RELAUNCH" "...and told the only remedy, which is not available from inside the session"
# Order item (6) fences the nudge's own FUNCTION for a homeless session: it must
# not be handed the session-start reminder it cannot act on anyway (that script
# dies on the same predicate). The detector reports the state; it never revives
# the reminder.
case "$out" in *ac-session-start.sh*) fail "the homeless signal must not revive the session-start reminder (order item 6)" ;; esac

# (b) A PRIMARY checkout with no crew scalars is chief-shaped too - a fleet
#     hosted on a repo itself (AGENTS.md section 1, and bin/ac-delegation-guard.sh
#     fences exactly that shape). Pinned so the trade-off cannot flip silently:
#     a captain hacking on the distro eats one informational line per session,
#     and the fleet hosted there keeps its detector.
primary="$(make_repo homeless-primary)"
homeless "$primary"
assert_eq "$rc" 0 "homeless primary checkout: exit 0"
assert_contains "$out" "$sig" "a primary checkout carries no crew scalars, so it is chief-shaped"

# (c) CREWMATE by its own badge: AC_CREW_ID and AC_FLEET_NAME are what a session
#     is handed INSTEAD of a home (bin/ac-spawn.sh's crewmate launch line, and
#     bin/ac-pane-agent.sh's ENVPIN, which pins the fleet NAME exactly when the
#     caller had no home to pin). Nothing else in bin/ sets either.
homeless "$chief" AC_CREW_ID=greet2
assert_eq "$rc" 0 "homeless crewmate: exit 0"
[ -z "$out" ] || fail "a crewmate is LEGITIMATELY homeless and must never be signalled (got: $out)"
homeless "$chief" AC_FLEET_NAME=drydock AC_CREW_ID=greet2 AC_FLEET_STATE="$chief/state"
[ -z "$out" ] || fail "a fully-dressed crewmate must never be signalled (got: $out)"

# (d) ...and by GEOMETRY, independently of the badge: a linked worktree is a
#     crewmate checkout. This arm also covers a captain who opened a plain
#     session inside a leased worktree to read the work.
homeless "$wt"
assert_eq "$rc" 0 "homeless linked worktree: exit 0"
[ -z "$out" ] || fail "a linked worktree is a crewmate checkout and must never be signalled (got: $out)"

#     A verification pane carries the NAME alone (ENVPIN) and no crew id.
homeless "$chief" AC_FLEET_NAME=drydock
[ -z "$out" ] || fail "a pane given the fleet NAME instead of a home must never be signalled (got: $out)"

# (e) AC_SCOPE is deliberately NOT a silencing badge, and this is the case that
#     decides it: bin/ac-spawn.sh gives a roomchief AC_HOME *and* AC_SCOPE
#     together, so a scope with NO home is a roomchief that LOST one - which is
#     this defect, not an exemption from it. bin/ac-relocate.sh builds exactly
#     that resume line (AC_SCOPE=<fam> claude --resume <sid>, no AC_HOME; its
#     crewdeputy arm does pass AC_HOME, and tests/ac-relocate.test.sh pins the
#     asymmetry), so the class is real, not hypothetical.
homeless "$chief" AC_SCOPE=greet2
assert_contains "$out" "$sig" "a relocated roomchief lost its home and must be told, not silenced"

# (e2) AC_HOME SET but unusable is a DIFFERENT state, not this one: ac_home
#      refuses on the ABSENCE of AC_HOME alone, so the detector keys on exactly
#      that predicate and never on cd failing. Proven from $chief, not from the
#      suite's own cwd - the suite runs inside a linked worktree, where the
#      geometry arm would silence it anyway and hide a missing check.
rc=0; out="$(cd "$chief" && AC_HOME="$TMP/does-not-exist" "$NUDGE" 2>/dev/null)" || rc=$?
assert_eq "$rc" 0 "set-but-unusable home: exit 0"
[ -z "$out" ] || fail "a set-but-unusable AC_HOME is not a homeless session (got: $out)"

# (e3) A SUBDIRECTORY of a primary checkout is still that checkout. The bare
#      rev-parse pair answers an ABSOLUTE --git-dir against a RELATIVE
#      --git-common-dir there, which compares unequal and reads as a linked
#      worktree; --path-format=absolute is what keeps this arm honest.
mkdir -p "$primary/sub"
homeless "$primary/sub"
assert_contains "$out" "$sig" "a subdirectory of a primary checkout is not a linked worktree"

# (f) A SOLO session gets its own orientation and never this signal - it is told
#     what it is without resolving a home at all.
homeless "$chief" AC_SOLO=1
assert_eq "$rc" 0 "homeless solo session: exit 0"
assert_contains "$out" "NOT the crewchief" "a homeless solo session still gets the solo orientation"
case "$out" in *"$sig"*) fail "a solo session is not a chief that lost its home" ;; esac

# (g) AC_HOME SET: the healthy path does not move. Every case above this block
#     already runs with a home; this is the direct statement of the invariant.
run "$g"
assert_contains "$out" "$line" "AC_HOME set: the ordinary nudge is unchanged"
case "$out" in *"$sig"*) fail "the homeless signal must never fire while AC_HOME is set" ;; esac
# ...and NOTHING ELSE arrives on that path. Two substring tests would pass while
# an unrelated new line rode along; the healthy path is supposed to be
# byte-identical, so count what it prints.
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1 \
  "AC_HOME set: exactly one line - the healthy path gains nothing"

# --- COMPACT: a compacted session re-grounds from disk -----------------------
# A chief that compacts still holds its own live lock, which is exactly the
# state the ordinary nudge is silenced by - so without its own arm a compacted
# chief got nothing at all.
compact() { # compact <cwd> [env...]
  local cwd="$1"; shift
  rc=0; out="$(cd "$cwd" && printf '{"source":"compact"}' | env "$@" "$NUDGE" 2>/dev/null)" || rc=$?
}
printf 'pid=%s\nsince=2026-07-18T00:00:00Z\n' "$$" >"$g/state/.session-lock"
compact "$g" AC_HOME="$g"
assert_eq "$rc" 0 "compacted chief: exit 0"
assert_contains "$out" "COMPACTED" "a compacted chief under its own live lock is re-oriented"
assert_contains "$out" "ac-brain.sh context_pack" "the re-orientation names the rebuild command"
case "$out" in *"queued wake"*) fail "no wake is pending, none is claimed: $out" ;; esac
mkdir -p "$g/state/.wake-spool"; printf 'x\n' >"$g/state/.wake-spool/1.1.000001"
compact "$g" AC_HOME="$g"
assert_contains "$out" "1 queued wake" "a compacted chief is told its pending wakes"
rm -rf "$g/state/.wake-spool"
compact "$g" AC_HOME="$g" AC_SCOPE=fam-x
assert_contains "$out" "--entities data/fam-x/room" "a compacted roomchief rebuilds from its own room"
# The ordinary startup path under the same live lock stays silent.
rc=0; out="$(printf '{"source":"startup"}' | AC_HOME="$g" "$NUDGE" 2>/dev/null)" || rc=$?
[ -z "$out" ] || fail "startup under a live lock is still silent (got: $out)"
rm -f "$g/state/.session-lock"
# A crewmate is homeless in a linked worktree: it is pointed back at its brief.
compact "$wt" AC_HOME= AC_CREW_ID=crew-z
assert_eq "$rc" 0 "compacted crewmate: exit 0"
assert_contains "$out" "brief" "a compacted crewmate is sent back to its brief"
case "$out" in *"$sig"*) fail "a crewmate is not a chief that lost its home" ;; esac
case "$(jq -r '.hooks.SessionStart[].matcher' "$ROOT/.claude/settings.json")" in
  *compact*) ;;
  *) fail "claude SessionStart wiring must fire on compact" ;;
esac

pass
