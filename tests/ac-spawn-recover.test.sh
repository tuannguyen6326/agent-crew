#!/usr/bin/env bash
# ac-spawn-recover.test.sh - the widened --recover guard for a crewmate or
# roomchief whose pane/tab was destroyed (contract: GUARDED RECOVERY in
# bin/ac-spawn.sh's header). Three probe states, three verdicts: ALIVE (0)
# refuses as a duplicate, UNOBSERVABLE (2) refuses naming the backend, and
# only a DEFINITE gone (1) recovers - the recorded worktree is reused (no new
# lease, no reset, no branch change), one fresh pane opens the ordinary spawn
# way, the recorded claude session is resumed in it, the meta's window field
# alone is rewritten, and state/<id>.status gains a `recovered:` line.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
export AC_SPAWN_SETTLE=0
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5

make_home
repo="$(make_repo proj)"

# A claude stub so the claude-harness spawns pass ac-spawn's command -v check;
# the fake herdr never executes the launch line.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
chmod +x "$TMP/stub/claude"
export PATH="$TMP/stub:$PATH"

meta_field() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"; }
kill_pane() { rm -f "$FAKE_HERDR/panes/$(fake_pane "$1")".*; }

# --- nothing to recover ------------------------------------------------------------

err="$("$BIN/ac-spawn.sh" nometa "$repo" --recover 2>&1)" && fail "--recover with no meta must refuse"
assert_contains "$err" "nothing to recover" "a missing meta is named as nothing to recover"

# --- a crewmate: alive refuses, unobservable refuses, gone recovers ----------------

"$BIN/ac-brief.sh" r1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" r1 "$repo" --harness claude --mode local-only >/dev/null 2>&1 \
  || fail "the claude crewmate must spawn"
meta="$AC_HOME/state/r1.meta"
old_handle="$(cat "$AC_HOME/state/.pane-r1")"
old_sid="$(meta_field "$meta" session_id)"
old_wt="$(meta_field "$meta" worktree)"
[ -n "$old_sid" ] || fail "fixture: the claude spawn must record a session_id"
[ -d "$old_wt" ] || fail "fixture: the recorded worktree must exist"
cp "$AC_HOME/data/r1/brief.md" "$TMP/brief.before"
cp "$AC_HOME/data/r1/kickoff.md" "$TMP/kickoff.before"
printf 'wip\n' >"$old_wt/wip.txt"

# ALIVE (0): the duplicate-agent refusal stands, nothing is touched.
err="$("$BIN/ac-spawn.sh" r1 "$repo" --recover 2>&1)" && fail "--recover must refuse while the pane is ALIVE"
assert_contains "$err" "LIVE" "the alive refusal says why"
assert_eq "$(cat "$AC_HOME/state/.pane-r1")" "$old_handle" "an alive refusal keeps the pane handle"
assert_eq "$(meta_field "$meta" window)" "herdr:pane-$(fake_pane r1)" "an alive refusal keeps the meta window"

# UNOBSERVABLE (2): the backend cannot answer - never a verdict about the pane.
# DISPUTED: whether the backend can be read. HELD-CONSTANT: the pane's own
# files are all still there, so the pane really is alive.
touch "$FAKE_HERDR/.pane-api-down"
err="$("$BIN/ac-spawn.sh" r1 "$repo" --recover 2>&1)" && rc=0 || rc=$?
rm -f "$FAKE_HERDR/.pane-api-down"
[ "${rc:-0}" != 0 ] || fail "--recover must refuse when the backend is UNOBSERVABLE"
assert_contains "$err" "BACKEND could not be READ" "the unobservable refusal blames the backend, not the pane"
assert_eq "$(cat "$AC_HOME/state/.pane-r1")" "$old_handle" "an unobservable refusal keeps the pane handle"

# GONE (1): recovered in place.
kill_pane r1
: >"$FAKE_HERDR/log"
out="$("$BIN/ac-spawn.sh" r1 "$repo" --recover 2>/dev/null)" || fail "--recover must accept a DEFINITELY gone pane"
assert_contains "$out" "recovered r1" "the outcome line names the recovery"
new_handle="$(cat "$AC_HOME/state/.pane-r1")"
[ "$new_handle" != "$old_handle" ] || fail "recovery must open a FRESH pane"
assert_eq "$(meta_field "$meta" window)" "herdr:pane-$(fake_pane r1)" "the meta window field follows the fresh pane"
assert_eq "$(meta_field "$meta" worktree)" "$old_wt" "the recorded worktree is reused, never re-leased"
assert_eq "$(meta_field "$meta" session_id)" "$old_sid" "the session id is untouched"
assert_eq "$(meta_field "$meta" kind)" "ship" "the rest of the meta is untouched"
assert_eq "$(cat "$old_wt/wip.txt")" "wip" "uncommitted work in the worktree is untouched"
assert_eq "$(ls "$repo/.crew/slots/" | grep -c '\.meta$')" "1" "no second pool slot is leased"
cmp -s "$AC_HOME/data/r1/brief.md" "$TMP/brief.before" || fail "the brief is untouched"
cmp -s "$AC_HOME/data/r1/kickoff.md" "$TMP/kickoff.before" || fail "the original kickoff file is untouched"
assert_contains "$(tail -n 1 "$AC_HOME/state/r1.status")" "recovered:" "the status log gains a recovered: line"
buf="$(cat "$(fake_pane_buf r1)")"
assert_contains "$buf" "claude --permission-mode auto --resume $old_sid" "the fresh pane resumes the recorded session"
assert_contains "$buf" "AC_FLEET_STATE=" "the crewmate's launch env rides the resume line (its completion push needs it)"
assert_contains "$buf" "AC_CREW_ID=r1" "the crewmate's own id rides the resume line"
assert_contains "$buf" "has been RECOVERED" "the agent is told its pane was recovered"
case "$(cat "$FAKE_HERDR/log")" in *"tab close"*) fail "recovery closes nothing - the old pane was already gone" ;; esac
assert_contains "$(cat "$FAKE_HERDR/log")" "tab create --workspace" "the fresh pane lands in a family workspace the ordinary spawn way"

# ...and once recovered it is ALIVE again: a second --recover refuses.
err="$("$BIN/ac-spawn.sh" r1 "$repo" --recover 2>&1)" && fail "a recovered pane is alive - a second --recover must refuse"
assert_contains "$err" "LIVE" "the second refusal says why"

# --- a roomchief: same guard, its own scope on the resume line ---------------------

"$BIN/ac-room.sh" post famr crewchief "the captain order for famr, posted before the promote" >/dev/null
"$BIN/ac-spawn.sh" --roomchief famr --harness claude >/dev/null 2>&1 || fail "the roomchief must promote"
cmeta="$AC_HOME/state/famr-chief.meta"
csid="$(meta_field "$cmeta" session_id)"
[ -n "$csid" ] || fail "fixture: the roomchief must record a session_id"

err="$("$BIN/ac-spawn.sh" --roomchief famr --recover 2>&1)" && fail "a live roomchief must not be recovered over"
assert_contains "$err" "LIVE" "the live roomchief refusal says why"

kill_pane famr-chief
"$BIN/ac-spawn.sh" --roomchief famr --recover >/dev/null 2>&1 || fail "a gone roomchief tab must recover"
assert_eq "$(meta_field "$cmeta" window)" "herdr:pane-$(fake_pane famr-chief)" "the roomchief meta window follows the fresh pane"
assert_eq "$(meta_field "$cmeta" kind)" "roomchief" "the roomchief meta is otherwise untouched"
cbuf="$(cat "$(fake_pane_buf famr-chief)")"
assert_contains "$cbuf" "AC_SCOPE=famr" "the roomchief resumes under its own scope"
assert_contains "$cbuf" "claude --permission-mode auto --resume $csid" "the roomchief's session is resumed"
assert_contains "$cbuf" 'AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set famr)' "the roomchief is told to re-arm its family watcher, which died with the tab"
assert_contains "$(tail -n 1 "$AC_HOME/state/famr-chief.status")" "recovered:" "the roomchief status log gains a recovered: line"

pass
