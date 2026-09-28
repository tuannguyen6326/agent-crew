#!/usr/bin/env bash
# TWO independent suites over the same script, appended - neither replaces the
# other. ORDER IS LOAD-BEARING: the qa-infra suite runs FIRST, in the pristine
# home helpers.sh exports; the crewdeputy suite runs SECOND and is insulated
# because it drives the digest with AC_HOME pointed at a home it creates
# itself. Swapped, the qa-infra suite would inherit a fake herdr on PATH and a
# crewdeputies/ dir under $AC_HOME that it was never written against.
#
# ac-session-start.test.sh - the per-project qa-infra reap sweep (the last
# ride-along before the fleet view) is BOUNDED: a wedged docker daemon
# (`docker ps -a` hangs, observed live 2026-07-28: 6m27s and still hung) must
# warn and CONTINUE the digest, never park session start forever. A fast,
# ordinary docker with nothing to reap must print no spurious warning (the
# reap pipeline ends in `| grep '^reaped'`, which exits 1 - the pre-existing
# no-match case - under `set -o pipefail`; only a real timeout (124) warns).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# A qa-eligible project: the sweep only looks at projects carrying .crew (see
# ac-session-start.sh's own gate), and ac-qa.sh itself requires a real git
# repo before it ever reaches the docker call.
proj="$AC_HOME/projects/proj1"
mkdir -p "$proj/.crew"
git init -q "$proj"

dstub="$TMP/dstub"; mkdir -p "$dstub"
export PATH="$dstub:$PATH"
export AC_SESSION_QA_TIMEOUT=1   # the production bound must not be sat out by a test

# (1) A HUNG docker (daemon wedged: `docker ps -a` never returns) is killed by
# the watchdog and the digest still completes past the bound instead of
# hanging forever.
cat >"$dstub/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"$TMP/hang.pid"
exec sleep 30
EOF
chmod +x "$dstub/docker"

"$BIN/ac-session-start.sh" >"$TMP/hung.out" 2>&1 &
sspid=$!
# A ceiling of the test's own: without it an unbounded sweep hangs the suite
# instead of failing it, and a hang proves nothing.
i=0
while [ "$i" -lt 50 ] && kill -0 "$sspid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$sspid" 2>/dev/null; then
  kill -9 "$sspid" 2>/dev/null || true
  fail "a hung docker parked session start at the qa-infra reap sweep"
fi
wait "$sspid" || fail "a hung docker must not fail session start"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
hung="$(cat "$TMP/hung.out")"
assert_contains "$hung" "proj1" "the warning names the stuck project"
assert_contains "$hung" "ac-qa.sh infra reap" "the warning names the recovery command"
assert_contains "$hung" "-- fleet --" "the digest continues past the hung sweep"

# (1b) The SAME hung docker (dstub/docker still the hanging stub from case
# (1)), but with session start's stdout captured through a PIPE (command
# substitution) rather than redirected to a file - the actual shape a chief
# uses every session (AGENTS.md section 3: run ac-session-start.sh and read
# its output, or a harness tool call capturing stdout). A file has no
# writer/EOF semantics, so case (1) alone cannot see an orphaned
# `grep '^reaped'` left holding a caller fd open; a pipe can, and does,
# unless the bounded child's fds are kept off the caller's entirely.
(
  piped_out="$("$BIN/ac-session-start.sh" 2>/dev/null)"
  printf '%s' "$piped_out" >"$TMP/piped.out"
  : >"$TMP/piped.done"
) &
pipedpid=$!
i=0
while [ "$i" -lt 50 ] && [ ! -f "$TMP/piped.done" ]; do sleep 0.2; i=$((i + 1)); done
if [ ! -f "$TMP/piped.done" ]; then
  kill -9 "$pipedpid" 2>/dev/null || true
  fail "a hung docker parked a PIPED session-start capture past the bound"
fi
wait "$pipedpid" || fail "a hung docker must not fail a piped session start"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
assert_contains "$(cat "$TMP/piped.out")" "-- fleet --" "a piped capture still completes past the hung sweep"

# (1c) The SAME hung docker again, captured with a MERGED `2>&1` pipe - the
# same shape case (2) below already uses for an ordinary run. stdout alone
# being redirected to a temp file (case 1b's fix) still leaves the bounded
# subshell's fd 2 inherited from the caller; an orphaned grep holding THAT
# open blocks a `2>&1` capture just as surely as fd 1 alone blocked case (1b).
rm -f "$TMP/hang.pid" "$TMP/piped.done"
(
  piped_out="$("$BIN/ac-session-start.sh" 2>&1)"
  printf '%s' "$piped_out" >"$TMP/piped2.out"
  : >"$TMP/piped.done"
) &
pipedpid=$!
i=0
while [ "$i" -lt 50 ] && [ ! -f "$TMP/piped.done" ]; do sleep 0.2; i=$((i + 1)); done
if [ ! -f "$TMP/piped.done" ]; then
  kill -9 "$pipedpid" 2>/dev/null || true
  fail "a hung docker parked a MERGED (2>&1) session-start capture past the bound"
fi
wait "$pipedpid" || fail "a hung docker must not fail a merged-capture session start"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
assert_contains "$(cat "$TMP/piped2.out")" "-- fleet --" "a merged capture still completes past the hung sweep"

# (1d) The warning's remedy is a command the reader pastes into a shell, so a
# project path holding a space (captain 2026-09-28: such fleet homes are
# supported) must reach that shell as ONE word.
sp_home="$TMP/sp ace home"
mkdir -p "$sp_home/state" "$sp_home/config" "$sp_home/records" "$sp_home/data" "$sp_home/projects/proj1/.crew"
git init -q "$sp_home/projects/proj1"
rm -f "$TMP/hang.pid"
sp_out="$(AC_HOME="$sp_home" "$BIN/ac-session-start.sh" 2>&1)"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
sp_cd="${sp_out##*reap by hand once fixed: (cd }"
sp_cd="${sp_cd%% && *}"
assert_eq "$(eval "cd $sp_cd" 2>/dev/null && pwd -P)" "$(cd "$sp_home/projects/proj1" && pwd -P)" \
  "the printed remedy's cd reaches the project in a spaced fleet home"

# (2) An ordinary FAST docker with nothing to reap prints no warning - the
# reap pipeline's own no-match exit (grep '^reaped' finds nothing) must not
# be mistaken for a timeout.
cat >"$dstub/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$dstub/docker"
out="$("$BIN/ac-session-start.sh" 2>&1)"
case "$out" in
  *"WARN:"*"proj1"*) fail "an ordinary empty reap must not warn: $out" ;;
esac
assert_contains "$out" "-- fleet --" "the digest still completes"

rm -f "$dstub/docker"
unset AC_SESSION_QA_TIMEOUT

# (3) Toolchain digest: a diagnostic-only INERT: line (ac-bootstrap.sh
# never fails rc for one) must not be followed by the all-clear
# "(all required tools present)" reassurance - printing both together
# reads as a contradiction (found live, 2026-08-23, developing the
# PATH-shadow probe: this host's own real jq shadow tripped it). Fixed
# jq copies, not the ambient host's, so this is host-independent - a
# guaranteed-newer fake sits at the very end of PATH regardless of what
# the real host has installed.
mkdir -p "$dstub/jq-old" "$dstub/jq-new"
cat >"$dstub/jq-old/jq" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf 'jq-1.2\n'; exit 0; }
exit 0
EOF
cat >"$dstub/jq-new/jq" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf 'jq-9.9\n'; exit 0; }
exit 0
EOF
chmod +x "$dstub/jq-old/jq" "$dstub/jq-new/jq"
tc_out="$(PATH="$dstub/jq-old:$PATH:$dstub/jq-new" "$BIN/ac-session-start.sh" 2>&1)"
tc_section="$(printf '%s\n' "$tc_out" | awk '/^-- toolchain --$/{f=1;next} /^-- /{f=0} f')"
assert_contains "$tc_section" "INERT: jq installed but inert" "the inert jq is diagnosed in the digest"
case "$tc_section" in
  *"all required tools present"*) fail "the all-clear line must not print alongside an INERT: warning: $tc_section" ;;
esac
rm -rf "$dstub/jq-old" "$dstub/jq-new"

# ac-session-start.test.sh - the crewdeputy config-converge ride-along
# (bin/ac-session-start.sh:72-83) must resolve its PARENT config dir from the
# LIVE AC_HOME by walking `$home/../../config` - tests/ac-config-converge.test.sh
# only ever drives the underlying ac_config_converge_from_parent function with
# a hand-picked parent path, never through this script's own path derivation,
# and tests/ac-lock.test.sh/ac-learn.test.sh drive other digest blocks without
# ever using a crewdeputy home. An off-by-one here would silently starve every
# crewdeputy of its inherited config with nothing else to catch it.

make_fake_herdr
make_home

dep="$AC_HOME/crewdeputies/dep1"
mkdir -p "$dep/state" "$dep/config"
: >"$dep/.ac-crewdeputy-home"
printf 'opus\n' >"$AC_HOME/config/model"

out="$(AC_HOME="$dep" "$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$out" "-- config converge (from parent) --" "the ride-along header prints for a crewdeputy home"
assert_contains "$out" "converged: model" "it pulls a drifted inheritable knob from the REAL parent path"
assert_eq "$(cat "$dep/config/model")" "opus" "the value actually lands in the deputy's own config"

# --- the crewdomain routing block, and the detection that rides on it --------
# It prints UNCONDITIONALLY beside the crewdeputy block, and it carries one
# duty that block does not (crewdomain-token): `ac-domain.sh list` runs the
# token census, so an ORPHAN token - a fleet row naming a domain with no
# VALID registry line - is surfaced at EVERY crewchief session start.
mkdir -p "$AC_HOME/crewdomains/payments/records"
printf -- '- payments - the payments domain - scope: money (added 2026-08-02T00:00:00Z)\n' \
  >"$AC_HOME/records/crewdomains.md"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] stray-row - names a retired domain; domain:ghosts (repo: alpha)\n\n## Done\n' \
  >"$AC_HOME/records/backlog.md"

dig="$("$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$dig" "-- crewdomains (routing table) --" "the crewdomain block prints unconditionally"
assert_contains "$dig" "payments" "... naming the registered domain"
assert_contains "$dig" "ORPHAN-TOKEN" "... and surfacing a token no VALID line backs"
assert_contains "$dig" "stray-row" "... by id, so the chief can unassign or re-new it"
assert_contains "$dig" "-- crewdeputies (routing table) --" "the crewdeputy block still prints beside it"

# Nor may a ledger the parser could not read.
failbun="$TMP/failbun"
mkdir -p "$failbun"
printf '#!/bin/sh\nexit 1\n' >"$failbun/bun"
chmod +x "$failbun/bun"
dig="$(PATH="$failbun:$PATH" "$BIN/ac-session-start.sh" 2>/dev/null)" \
  || fail "a ledger the parser could not read must not take session start down"
assert_contains "$dig" "WARN"$'\t'"ledger unreadable" "the crewdomain block names the unread ledger"
assert_contains "$dig" "-- supervision --" "the blocks after the crewdomain block still print"

# A digest block may never take session start down: even a corrupt registry
# leaves the run exit 0, the rule ac-deputy.sh states for its own list.
printf 'not a registry line\n- broken\n' >"$AC_HOME/records/crewdomains.md"
"$BIN/ac-session-start.sh" >/dev/null 2>&1 \
  || fail "a corrupt crewdomain registry must not take session start down"
rm -f "$AC_HOME/records/crewdomains.md"

# --- the scheduler block ----------------------------------------------------
# A scheduler that could not run prints nothing, which is exactly what "no
# item to start" looks like - the digest has to say which one it was. A bin/
# whose ac-ready.sh fails; every other script is the real one.
ssbin="$TMP/ssbin"
mkdir -p "$ssbin"
for f in "$ROOT"/bin/*.sh; do ln -sf "$f" "$ssbin/$(basename "$f")"; done
rm -f "$ssbin/ac-ready.sh"
printf '#!/usr/bin/env bash\nexit 3\n' >"$ssbin/ac-ready.sh"
chmod +x "$ssbin/ac-ready.sh"
dig="$("$ssbin/ac-session-start.sh" 2>/dev/null)"
bl_section="$(printf '%s\n' "$dig" | awk '/^-- backlog \(head\) --$/{f=1;next} /^-- projects --$/{f=0} f')"
assert_contains "$bl_section" "WARN   scheduler unavailable: ac-ready.sh exited 3" "a scheduler that could not run is named in the digest's backlog block"

# --- DISTRO-LAG (identity header) ---------------------------------------------
# The pointer state/.ac-root (ac_root_pointer_path) names the tree to measure
# when it exists and names a git repo; the whole point of the line is that it
# ALWAYS prints, including the in-sync (0) case - a silent no-op would be the
# exact blindness this line exists to close.
ptr="$AC_HOME/state/.ac-root"
rm -f "$ptr"

lag_repo="$(make_repo lag-behind)"
first_sha="$(git -C "$lag_repo" rev-parse HEAD)"
git -C "$lag_repo" commit -q --allow-empty -m second
git -C "$lag_repo" checkout -q "$first_sha"

printf '%s\n' "$lag_repo" >"$ptr"
out="$("$BIN/ac-session-start.sh" 2>&1)"
assert_contains "$out" "DISTRO-LAG: 1 behind main" "pointer'd tree behind the default branch reports the exact count"

git -C "$lag_repo" checkout -q main
printf '%s\n' "$lag_repo" >"$ptr"
out="$("$BIN/ac-session-start.sh" 2>&1)"
assert_contains "$out" "DISTRO-LAG: in sync with main" "the 0 case is an explicit readable line, never a silent no-op"

# Pointer names a path that names no git repo (gone, or never a repo at all):
# FAIL-SOFT falls back to ac_root() (the checkout that owns the running bin/ -
# this very worktree, a real repo) rather than dying, hanging or spilling git
# errors - never printed as "unknown", since the fallback itself succeeds.
printf '%s\n' "$TMP/gone-entirely" >"$ptr"
out="$("$BIN/ac-session-start.sh" 2>&1)" || fail "a pointer to a missing path must not take session start down"
assert_contains "$out" "DISTRO-LAG:" "a non-repo/missing pointer still prints one line (fallback to ac_root())"
case "$out" in *"DISTRO-LAG: unknown"*) fail "ac_root() fallback must succeed, not report unknown: $out" ;; esac

# No pointer at all (a home that has never run ac-remote.sh, e.g. a fresh
# crewdeputy home) falls back to ac_root() the same way.
rm -f "$ptr"
out="$("$BIN/ac-session-start.sh" 2>&1)"
assert_contains "$out" "DISTRO-LAG:" "an absent pointer still prints one line (fallback to ac_root())"
case "$out" in *"DISTRO-LAG: unknown"*) fail "ac_root() fallback must succeed, not report unknown: $out" ;; esac

# --- AC_SOLO=1: the read-only digest WITHOUT touching the lock ---------------
# A solo session is a second session beside the chief: it must not take the
# session lock and must not CONSUME wakes (a drain claims and deletes - that
# is the chief's channel), while the digest still orients it.
solo_home="$TMP/solo-home"
mkdir -p "$solo_home/state/.wake-spool" "$solo_home/config" "$solo_home/data" "$solo_home/records" "$solo_home/projects"
printf '9	report	solo-t1	done: x
' >"$solo_home/state/.wake-spool/1.1.000000"
rc=0; out="$(AC_SOLO=1 AC_HOME="$solo_home" "$BIN/ac-session-start.sh" 2>&1)" || rc=$?
assert_contains "$out" "SOLO" "the digest announces the solo session"
assert_no_file "$solo_home/state/.session-lock" "a solo session never takes the chief lock"
[ -e "$solo_home/state/.wake-spool/1.1.000000" ] \
  || fail "a solo session must not consume the chief's wake records"

# --- AC_CHIEF_SOLO=1: a SOLO CHIEF's digest names its role --------------------
# A solo chief is a roomchief (AC_SCOPE set) that works its family's slices
# itself; the digest tells it so on every start, since nothing else it loads
# does. Scoped, so it still takes no fleet lock and still leaves the fleet
# spool alone - the solo-session rail's two invariants hold here too.
rc=0; out="$(AC_CHIEF_SOLO=1 AC_SCOPE=scfam AC_HOME="$solo_home" "$BIN/ac-session-start.sh" 2>&1)" || rc=$?
assert_contains "$out" "SOLO CHIEF" "the digest announces the solo chief"
assert_contains "$out" "ac-self-task.sh start scfam-" "...and names the slice verb with its family prefix"
assert_no_file "$solo_home/state/.session-lock" "a scoped session never takes the fleet lock"
[ -e "$solo_home/state/.wake-spool/1.1.000000" ] \
  || fail "a scoped session must not consume the fleet spool"

# --- the knowledge block counts ENTRIES ---------------------------------------
# A repo-knowledge record's live entries sit above `## Superseded`; below it is
# history (bin/ac-know.sh header), never an entry.
mkdir -p "$AC_HOME/records/repo-knowledge"
printf -- '- fact live one | src: cmd:true | at: abc 2026-08-01 | by: fam\n\n## Superseded\n\n- fact old one | src: cmd:true | at: abc 2026-07-01 | by: fam\n' \
  >"$AC_HOME/records/repo-knowledge/kproj.md"
dig="$("$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$dig" "kproj: 1 entries" "a superseded entry is history, not a counted entry"
rm -rf "$AC_HOME/records/repo-knowledge"

# The always-loaded layer's skill-pointer section is not an entry, and the date
# grammar must hold under mawk 1.3.4 before its 20200724 snapshot, which has
# no interval expressions: `[0-9]{4}` there is a digit then the literal text
# `{4}` (probed: mawk 1.3.4-20200120 in node:22.12.0). This awk hands the
# host's own awk every argument with its intervals turned into exactly those
# literal braces.
mawk_real="$(command -v awk)"
mkdir -p "$TMP/mawkbin"
cat >"$TMP/mawkbin/awk" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  args+=("$(printf '%s\n' "$a" | sed -E 's/[{]([0-9]+(,[0-9]*)?)[}]/\\{\1\\}/g')")
done
exec "$MAWK_MODEL_REAL_AWK" "${args[@]}"
EOF
chmod +x "$TMP/mawkbin/awk"
printf '# H\n\n## old-e\n\nb\n\n(learned 2026-01-01)\n\n## when to reach for a learned skill\n- when x -> use skill y\n\n## new-e\n\nb\n\n(learned %s)\n' "$(date -u +%F)" \
  >"$AC_HOME/CREWMATE-learned.md"
dig="$("$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$dig" "always-loaded: 2 entries, 1 stale" "the skill-pointer section is not counted as an entry"
dig="$(PATH="$TMP/mawkbin:$PATH" MAWK_MODEL_REAL_AWK="$mawk_real" "$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$dig" "always-loaded: 2 entries, 1 stale" "under mawk the digest still reads the clocks"
rm -f "$AC_HOME/CREWMATE-learned.md"

pass
