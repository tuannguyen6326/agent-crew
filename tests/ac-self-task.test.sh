#!/usr/bin/env bash
# ac-self-task.test.sh - the chief-self-but-visible mechanism:
#   - `start` leases a pooled worktree, opens a labelled pane tailing the
#     progress log, and writes a kind=self meta - ALL of it before the chief
#     makes its first edit,
#   - `log` appends to that progress log, so the pane and every fleet view
#     (ac-crew-state.sh) show the chief's progress,
#   - a kind=self meta is excluded from SUPERVISION: it holds no agent, so it
#     neither demands a watcher nor is polled for captain markers - while a
#     real crewmate meta in the same fleet still does both,
#   - `start` refuses an id that already exists.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
repo="$(make_repo proj)"
state="$AC_HOME/state"

# --- start: worktree + pane + meta, all before the first edit ------------------
out="$("$BIN/ac-self-task.sh" start s1 "$repo")"
assert_contains "$out" "self-task s1" "start reports the task it opened"
assert_file "$state/s1.meta" "start writes the task meta"
assert_eq "$(awk -F= '$1=="kind"{print $2}' "$state/s1.meta")" self "the meta records kind=self"
worktree="$(awk -F= '$1=="worktree"{print $2}' "$state/s1.meta")"
[ -n "$worktree" ] && [ -d "$worktree" ] || fail "start leases a pooled worktree and records it"
case "$worktree" in "$repo"/.crew/worktrees/*) ;; *) fail "the lease must come from the repo's own pool: $worktree" ;; esac
assert_eq "$(awk -F= '$1=="leases"{print $2}' "$state/s1.meta")" "$worktree" \
  "the lease is recorded so teardown gives it back"
assert_eq "$(awk -F= '$1=="project_dir"{print $2}' "$state/s1.meta")" "$repo" \
  "the meta records the project dir ac-merge-local.sh lands from"
[ -n "$(awk -F= '$1=="window"{print $2}' "$state/s1.meta")" ] || fail "the meta records the pane"
assert_eq "$(awk -F= '$1=="mode"{print $2}' "$state/s1.meta")" "local-only" \
  "an unflagged start keeps the local-only default"

# The pane tails the progress log - that is the whole of "the pane shows chief
# progress"; no agent runs in it.
pane="$(cat "$(fake_pane_buf s1)")"
assert_contains "$pane" "tail -f" "the pane tails the progress log"
assert_contains "$pane" "$state/s1.status" "the pane tails THIS task's progress log"

# --- log: the chief's progress reaches the pane and every fleet view ----------
"$BIN/ac-self-task.sh" log s1 'working: edited bin/ac-foo.sh'
assert_contains "$(cat "$state/s1.status")" "working: edited bin/ac-foo.sh" \
  "log appends to the progress log the pane tails"
assert_contains "$("$BIN/ac-crew-state.sh" s1)" "edited bin/ac-foo.sh" \
  "the fleet's current-state line shows the chief's progress"

# --- supervision: a pane with no agent demands no watcher --------------------
# ac_meta_is_verify is EXCLUDED FROM ACCOUNTING, NEVER FROM SUPERVISION, because
# a verifier pane holds an agent. A self task is the opposite case: the chief IS
# the agent, so waking it about its own pane is a self-loop.
rm -f "$state/.last-watcher-beat"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "a self task alone must not block the turn end on a stale beacon"
case "$("$BIN/ac-guard.sh" 2>&1)" in
  *WATCHER-DOWN*) fail "a self task alone must not raise WATCHER-DOWN" ;;
esac
# ...and the watcher does not poll it for captain markers.
printf 'done: chief finished the edit\n' >>"$(fake_pane_buf s1)"
case "$(bash "$BIN/ac-watch.sh" --once 2>/dev/null || true)" in
  *s1*) fail "the watcher must not wake on a pane no agent lives in" ;;
esac
# DISPUTED: the meta's kind. HELD-CONSTANT: the same pane, the same marker
# already in its tail, the same watcher invocation - so the skip is what the
# first run proved, not an inert fixture.
sed -i.bak 's/^kind=self$/kind=ship/' "$state/s1.meta"; rm -f "$state/s1.meta.bak"
case "$(bash "$BIN/ac-watch.sh" --once 2>/dev/null || true)" in
  *s1*) ;;
  *) fail "the watcher must still wake on an ordinary crewmate pane" ;;
esac
sed -i.bak 's/^kind=ship$/kind=self/' "$state/s1.meta"; rm -f "$state/s1.meta.bak"

# --- ...while a REAL crewmate meta still demands both -------------------------
# The watcher run above refreshed the beacon; the demand is only meaningful
# against a stale one.
rm -f "$state/.last-watcher-beat"
printf 'window=crew:t9\n' >"$state/t9.meta"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "a real crewmate still blocks the turn end on a stale beacon"
assert_contains "$("$BIN/ac-guard.sh" 2>&1)" "WATCHER-DOWN" \
  "a real crewmate still raises WATCHER-DOWN"
rm -f "$state/t9.meta"

# --- start refuses an id that already exists ---------------------------------
err="$("$BIN/ac-self-task.sh" start s1 "$repo" 2>&1 1>/dev/null || true)"
assert_contains "$err" "already exists" "start refuses a duplicate id"

# --- branch collision refusal: the SAME hazard as ac-spawn.sh, shared --------
# A self task also commits on crew/<id> and lands via ac-merge-local.sh, so it
# carries the identical branch-collision hazard ac-spawn.sh refuses
# (tests/ac-spawn-branch-collision.test.sh covers that side) - proven here via
# ac_family_owned (bin/ac-lib.sh), the ONE predicate both callers share.

# control: no crew/<id> ref => start proceeds exactly as before.
"$BIN/ac-self-task.sh" start s2 "$repo" >/dev/null
assert_file "$state/s2.meta" "an id with no crew branch starts as before"
"$BIN/ac-teardown.sh" s2 --force >/dev/null 2>&1

# an UNOWNED crew/<id> ref refuses start, names the ref, touches no ref, and
# leaves no lease/meta behind.
git -C "$repo" branch crew/s3 main
sha="$(git -C "$repo" rev-parse --verify crew/s3)"
err="$("$BIN/ac-self-task.sh" start s3 "$repo" 2>&1 1>/dev/null || true)"
assert_contains "$err" "crew/s3" "the refusal names the colliding ref"
assert_contains "$err" "branch -m crew/s3" "the refusal states the rename command"
assert_contains "$err" "branch -D crew/s3" "the refusal states the delete command"
assert_no_file "$state/s3.meta" "the refused start writes no meta"
assert_eq "$(git -C "$repo" rev-parse --verify crew/s3)" "$sha" \
  "start never renames or deletes the ref - that is the operator's call"
case "$("$BIN/ac-tree.sh" list --repo "$repo" 2>/dev/null || true)" in
  *"self:s3"*) fail "the refused start must not leak a worktree lease" ;;
esac

# a LIVE family sibling owns the branch => start proceeds (the same <fam>-r2
# recovery property AGENTS.md section 5 sanctions on the spawn side).
"$BIN/ac-self-task.sh" start s4 "$repo" >/dev/null
git -C "$repo" branch crew/s4 main
"$BIN/ac-self-task.sh" start s4-r2 "$repo" >/dev/null
assert_file "$state/s4-r2.meta" \
  "a branch a live family sibling owns is continued, not refused"
"$BIN/ac-teardown.sh" s4-r2 --force >/dev/null 2>&1
"$BIN/ac-teardown.sh" s4 --force >/dev/null 2>&1

# --- teardown is the EXISTING path, plus the knowledge-loop gate -------------
# kind=self takes the ordinary committing-task landed proof, then answers for
# its knowledge loop (the gate section below); the leases= key it reads is one
# this script writes by hand - a typo there would strand the pool slot forever.
printf '# Backlog\n## Queued\n## Done\n- [x] s1 - the first slice\n' >"$AC_HOME/records/backlog.md"
"$BIN/ac-teardown.sh" s1 --no-lesson 'fixture' --no-fact 'fixture' >/dev/null 2>&1 \
  || fail "teardown must land a clean self task"
assert_no_file "$state/s1.meta" "teardown archives the self task's meta"
case "$("$BIN/ac-tree.sh" list --repo "$repo" 2>/dev/null || true)" in
  *"self:s1"*) fail "teardown must give the self task's lease back" ;;
esac

# --- the leased worktree is seeded like a crewmate's -------------------------
# The chief/solo works the tree itself (or the captain opens a session INSIDE
# it), and work on a worktree follows the crewmate layer - so the lease seeds
# what a crew spawn seeds: instructions, settings, skills.
printf 'fleet crewmate law marker\n' >"$AC_HOME/CREWMATE.md"
mkdir -p "$AC_HOME/.claude"
printf '{"marker":true}\n' >"$AC_HOME/.claude/settings.json"
"$BIN/ac-self-task.sh" start s7 "$repo" >/dev/null
s7wt="$(awk -F= '$1=="worktree"{print $2}' "$state/s7.meta")"
assert_contains "$(cat "$s7wt/.claude/CLAUDE.md" 2>/dev/null)" "fleet crewmate law marker" \
  "the crewmate instruction layer is seeded into the chief-leased worktree"
assert_contains "$(cat "$s7wt/.claude/settings.json" 2>/dev/null)" '"marker":true' \
  "the fleet harness settings are seeded like a crewmate worktree"
[ -L "$s7wt/.claude/skills/crew-ship" ] \
  || fail "the crewmate skills must be seeded into the chief-leased worktree"
"$BIN/ac-teardown.sh" s7 --force >/dev/null 2>&1

# A solo session is not only claude (`ac <fleet> <harness> --solo`): --harness
# routes the seed to the instruction file THAT harness actually loads, the
# same as a crew spawn - codex reads AGENTS.md, and its skills live under
# .agents/skills.
"$BIN/ac-self-task.sh" start s8 "$repo" --harness codex >/dev/null
s8wt="$(awk -F= '$1=="worktree"{print $2}' "$state/s8.meta")"
assert_contains "$(cat "$s8wt/AGENTS.md" 2>/dev/null)" "fleet crewmate law marker" \
  "--harness codex seeds the layer into AGENTS.md, the file codex loads"
[ -L "$s8wt/.agents/skills/crew-ship" ] \
  || fail "--harness codex must seed skills where codex discovers them"
"$BIN/ac-teardown.sh" s8 --force >/dev/null 2>&1

# A repo that ships its OWN instruction file forces the seed to a FALLBACK
# path the harness never auto-loads - a fallback swallowed by >/dev/null
# points the session at the shipped law while the real crewmate layer sits
# unannounced. The start must SURFACE the fallback durably.
printf 'the shipped chief law\n' >"$repo/AGENTS.md"
git -C "$repo" add -f AGENTS.md
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "ship AGENTS.md"
"$BIN/ac-self-task.sh" start s9 "$repo" --harness codex >/dev/null
s9wt="$(awk -F= '$1=="worktree"{print $2}' "$state/s9.meta")"
assert_contains "$(cat "$state/s9.status")" ".claude/CREWMATE.md" \
  "the fallback path is surfaced on the status record, never swallowed"
assert_contains "$(cat "$s9wt/.claude/CREWMATE.md" 2>/dev/null)" "fleet crewmate law marker" \
  "the crewmate layer really sits at the surfaced fallback path"
"$BIN/ac-teardown.sh" s9 --force >/dev/null 2>&1
git -C "$repo" rm -qf AGENTS.md && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "drop AGENTS.md"

# --- mode: recorded, never hardcoded -----------------------------------------
# local-only is the DEFAULT (a chief self task lands with ac-merge-local.sh),
# not a hardcode: a SOLO session takes real slices that land per the repo's
# mode, PR included, and the fleet views display what the meta records.
"$BIN/ac-self-task.sh" start s5 "$repo" --mode direct-pr >/dev/null
assert_eq "$(awk -F= '$1=="mode"{print $2}' "$state/s5.meta")" "direct-pr" \
  "a solo slice's PR mode reaches the meta the fleet views display"
"$BIN/ac-teardown.sh" s5 --force >/dev/null 2>&1
err="$("$BIN/ac-self-task.sh" start s6 "$repo" --mode bogus 2>&1 1>/dev/null || true)"
assert_contains "$err" "invalid --mode" "an unknown mode refuses rather than records nonsense"
assert_no_file "$state/s6.meta" "the refused start writes no meta"

# --base-branch only ever reaches the orca lease call site; on a herdr fleet
# (the ambient default here) it would otherwise silently no-op instead of
# failing loud - the exact silent-outcome defect this fleet's own
# conventions refuse.
err="$("$BIN/ac-self-task.sh" start s7 "$repo" --base-branch release 2>&1 1>/dev/null || true)"
assert_contains "$err" "requires an orca-backend fleet" \
  "--base-branch on a herdr-backend fleet must die, not silently no-op"
assert_no_file "$state/s7.meta" "the refused start writes no meta"

# --- orca fleet: the self-task worktree is ORCA-MANAGED ----------------------
# The lease follows the fleet backend like every other isolated checkout
# (crew, verifier): an orca fleet leases through the Orca CLI, records
# worktree_backend=orca so teardown routes to the release arm, and lands on
# crew/<id> (the orca lease already switches there).
make_fake_orca
printf 'â³ fake
' >"$FAKE_ORCA/.default-title"
printf 'orca
' >"$AC_HOME/config/backend"
"$BIN/ac-self-task.sh" start so1 "$repo" >/dev/null \
  || fail "an orca-backend self task must start on the fake orca"
so_wt="$(sed -n 's/^worktree=//p' "$AC_HOME/state/so1.meta" | head -1)"
case "$so_wt" in "$FAKE_ORCA/orca-wt/"*) ;; *) fail "the self-task worktree must be orca-managed (got: $so_wt)" ;; esac
assert_eq "$(sed -n 's/^worktree_backend=//p' "$AC_HOME/state/so1.meta")" "orca" \
  "the meta records the orca worktree provenance for teardown"
assert_eq "$(git -C "$so_wt" branch --show-current)" "crew/so1" \
  "the orca self-task tree sits on the crew contract branch"
# The tail is the PANE'S OWN command - nothing is ever typed into a booting
# shell (measured: a typed `tail -f` raced the shell's cd+exec and landed as
# interleaved fragments; the first start died and left an orphan status line).
grep -q "exec tail -f" "$FAKE_ORCA/log" \
  || fail "the orca self-task pane must start WITH the tail as its command"
case "$(cat "$FAKE_ORCA/log")" in *"--text tail"*) \
  fail "the tail must never be typed into the pane after boot" ;; esac
# lease_ids is a POOL concept; an orca lease has no slot meta to read it from.
assert_eq "$(sed -n 's/^lease_ids=//p' "$AC_HOME/state/so1.meta")" "" \
  "no pool lease_id is invented for an orca worktree"
"$BIN/ac-teardown.sh" so1 --force >/dev/null 2>&1
[ ! -d "$so_wt" ] || fail "teardown must remove the orca-managed self-task worktree"

# --base-branch (orca-lease-cuts-from-wrong-branch): an explicit override
# threads through to the orca lease and wins over the live checkout (main).
repo2="$(make_repo proj2)"
git -C "$repo2" checkout -qb release
printf 'release marker
' >"$repo2/release.txt"
git -C "$repo2" add release.txt
git -C "$repo2" commit -qm "release marker"
release_sha="$(git -C "$repo2" rev-parse release)"
git -C "$repo2" checkout -q main
"$BIN/ac-self-task.sh" start so2 "$repo2" --base-branch release >/dev/null \
  || fail "--base-branch must thread through to an orca self-task start"
so2_wt="$(sed -n 's/^worktree=//p' "$AC_HOME/state/so2.meta" | head -1)"
assert_eq "$(git -C "$so2_wt" merge-base HEAD "$release_sha")" "$release_sha" \
  "--base-branch release wins over the live checkout (main) end to end through ac-self-task.sh"
[ -f "$so2_wt/release.txt" ] || fail "the leased tree must carry the release branch's content"
"$BIN/ac-teardown.sh" so2 --force >/dev/null 2>&1

printf 'herdr
' >"$AC_HOME/config/backend"

# --- window-liveness contract (bin/ac-backend.sh WINDOW LIVENESS): only a ----
# --- DEFINITE code may proceed; everything else (127 included) refuses ------

# rc=0 (a genuinely alive orphan pane, the shape an interrupted start with no
# meta yet written would leave behind) still refuses "already exists" - the
# case's 0) branch is untouched by the 127 fix below.
printf 'pOR1 tOR1\n' >"$state/.pane-or1"
printf 'pOR1\n' >"$FAKE_HERDR/tabs/tOR1"
: >"$FAKE_HERDR/panes/pOR1.buf"
err="$("$BIN/ac-self-task.sh" start or1 "$repo" 2>&1 1>/dev/null || true)"
assert_contains "$err" "already exists" "a genuinely alive orphan pane still refuses as before"
assert_no_file "$state/or1.meta" "the refused start leaves no task in flight"
rm -f "$state/.pane-or1" "$FAKE_HERDR/tabs/tOR1" "$FAKE_HERDR/panes/pOR1.buf"

# rc=2 (an unreadable backend) still refuses exactly as it does today.
printf 'pOR2 tOR2\n' >"$state/.pane-or2"
printf 'pOR2\n' >"$FAKE_HERDR/tabs/tOR2"
: >"$FAKE_HERDR/panes/pOR2.buf"
touch "$FAKE_HERDR/.unreachable"
err="$("$BIN/ac-self-task.sh" start or2 "$repo" 2>&1 1>/dev/null || true)"
rm -f "$FAKE_HERDR/.unreachable"
assert_contains "$err" "could not be READ" "an unreadable backend still refuses exactly as before"
assert_no_file "$state/or2.meta" "the refused start leaves no task in flight"
rm -f "$state/.pane-or2" "$FAKE_HERDR/tabs/tOR2" "$FAKE_HERDR/panes/pOR2.buf"

# rc=127 (a driver failed to LOAD) must refuse the SAME way, never proceed to
# open the pane (contract: ac-backend.sh WINDOW LIVENESS; ac_backend_route's
# per-call dispatch means a missing driver function makes bash itself return
# 127 from the very call being classified - the real production shape, not a
# hand-picked sentinel). A `case` with only 0)/2) branches and no default lets
# 127 fall straight through to the pane-open step below it.
make_loadfail_bin
: >"$FAKE_HERDR/log"
err="$("$LOADFAIL_BIN/ac-self-task.sh" start lf1 "$repo" 2>&1 1>/dev/null || true)"
assert_contains "$err" "could not be READ" "a 127 (driver load failure) refuses like an unreadable backend"
assert_no_file "$state/lf1.meta" "the refused start leaves no task in flight"
assert_eq "$(grep -c 'tab create' "$FAKE_HERDR/log" || true)" "0" \
  "a 127 driver failure must never reach the pane-open step - that is the fail-OPEN this closes"

# --- the pane OPEN failing: named, and nothing left behind -------------------
# A stopped herdr server fails the tab create itself. Under errexit that death
# is SILENT (the chief sees rc=1 and an unrelated pool WARN), and the partial
# start used to leave its seeded status file on disk - so a retry reads as a
# task already in flight in every fleet view.
touch "$FAKE_HERDR/.server-stopped"
rc=0; err="$("$BIN/ac-self-task.sh" start sdown "$repo" 2>&1 1>/dev/null)" || rc=$?
rm -f "$FAKE_HERDR/.server-stopped"
[ "$rc" != 0 ] || fail "a pane that cannot be opened must fail the start"
assert_contains "$err" "could not open the pane" "the failure NAMES what could not be done"
assert_contains "$err" "herdr server is not running" \
  "the backend can say why it refused, so the failure says it"
assert_contains "$err" "attach the session" "the reason carries the call that fixes it"
assert_no_file "$state/sdown.status" "the trap removes the status file the start seeded"
assert_no_file "$state/sdown.meta" "the trap removes the partial meta"
assert_no_file "$AC_HOME/data/sdown" "a start that never wrote a meta mints no task dir"
assert_eq "$("$BIN/ac-tree.sh" list --repo "$repo" 2>/dev/null | awk -F'\t' '$3=="sdown"{print $2}')" \
  "available" "the trap gives the lease back"

# --- the knowledge-loop gate at landing --------------------------------------
# The solo contract owes three writes per slice and no chief asks whether
# they happened: teardown of a landed kind=self task REFUSES while a lesson,
# a repo fact or the Done row is missing - naming the exact command for each -
# and ticks the Learning cadence itself once all three are there. "Nothing
# new" is said out loud, never inferred: --no-lesson / --no-fact '<why>' waive
# those two on the record; the Done row is never waived.
"$BIN/ac-self-task.sh" start s10 "$repo" >/dev/null
out="$("$BIN/ac-teardown.sh" s10 2>&1)" && fail "a slice that wrote nothing must not land: $out"
assert_file "$state/s10.meta" "the refused teardown leaves the slice in flight"
tl="$AC_HOME/data/s10/timeline.log"
assert_contains "$(cat "$tl" 2>/dev/null)" "knowledge loop: lessons=none repo-knowledge=none done-row=none" \
  "a slice that wrote nothing is told so on its durable timeline"
assert_contains "$out" "ac-learn.sh note" "the missing lesson names its command"
assert_contains "$out" "ac-know.sh add" "the missing repo fact names its command"
assert_contains "$out" "## Done" "the missing Done row names its place"
assert_contains "$out" "--no-lesson" "the refusal names the waiver for a slice with nothing new"
"$BIN/ac-learn.sh" note "### 2026-09-09 (solo s10)" "- measure before widening a bound" >/dev/null 2>&1 \
  || fail "ac-learn.sh note must accept a solo heading"
mkdir -p "$AC_HOME/records/repo-knowledge"
printf -- '# proj knowledge\n- fact the widget lock lives in file.txt | src: file:file.txt:1 | at: abc 2026-09-09 | by: s10\n' \
  >"$AC_HOME/records/repo-knowledge/proj.md"
printf '# Backlog\n## Queued\n## Done\n- [x] s10 - landed the widget lock note\n' >"$AC_HOME/records/backlog.md"
out="$("$BIN/ac-teardown.sh" s10 2>&1)" || fail "teardown must land once all three writes exist: $out"
assert_contains "$(cat "$tl")" "knowledge loop: lessons=yes repo-knowledge=yes done-row=yes" \
  "a slice that wrote all three is told so"
case "$out" in *"missing - the solo contract"*) fail "nothing missing must print no hints: $out" ;; esac
assert_contains "$(cat "$tl")" "learning tick:" "the landing ticks the Learning cadence on the record"
assert_contains "$("$BIN/ac-learn.sh" tick s10 2>&1)" "already counted" \
  "the teardown's tick is the keyed one, so the landing is counted exactly once"
"$BIN/ac-self-task.sh" start s11 "$repo" >/dev/null
printf '# Backlog\n## Queued\n## Done\n- [x] s11 - a doc-only slice\n' >"$AC_HOME/records/backlog.md"
out="$("$BIN/ac-teardown.sh" s11 --no-lesson 'nothing new - a doc-only slice' --no-fact 'no repo fact was verified' 2>&1)" \
  || fail "waived lesson and fact land with the Done row: $out"
assert_contains "$(cat "$AC_HOME/data/s11/timeline.log")" "knowledge loop: lessons=waived repo-knowledge=waived done-row=yes" \
  "a waiver is recorded as waived, never as yes"
assert_contains "$(cat "$AC_HOME/data/s11/timeline.log")" "lesson waived: nothing new - a doc-only slice" \
  "the waiver's why lands on the record"
assert_contains "$(cat "$AC_HOME/data/s11/timeline.log")" "repo fact waived: no repo fact was verified" \
  "the fact waiver's why lands on the record"
"$BIN/ac-self-task.sh" start s12 "$repo" >/dev/null
out="$("$BIN/ac-teardown.sh" s12 --no-lesson 'x' --no-fact 'y' 2>&1)" && fail "the Done row is never waived: $out"
assert_file "$state/s12.meta" "a missing Done row keeps the slice in flight"
out="$("$BIN/ac-teardown.sh" s12 --no-lesson '' 2>&1)" && fail "an empty waiver must be refused: $out"
assert_contains "$out" "--no-lesson carries" "an empty waiver says why it is refused"
out="$("$BIN/ac-teardown.sh" s12 --force 2>&1)"
case "$out" in *"knowledge loop"*) fail "a forced teardown discards the work and owes no checkpoint: $out" ;; esac
assert_no_file "$state/s12.meta" "a forced teardown still lands the discard"

# --- fleet-memory read at slice open ----------------------------------------
# The knowledge law names `ac-brain.sh recall` at intake; the start makes it
# machine-made: the slice id and project are the query, the hits print to the
# session AND land on the status record (the durable channel - the pane tails
# it), through the same prompt-time hook every harness runs, so a solo
# session's slice opens on the home's history without remembering to ask.
if command -v bun >/dev/null 2>&1; then
  mkdir -p "$AC_HOME/data/fam-one"
  printf '# Room: fam-one\nA distinctive sentence about zanzibar quorum reconciliation lives here.\n' \
    >"$AC_HOME/data/fam-one/room.md"
  "$BIN/ac-brain.sh" sync --home "$AC_HOME" --compact >/dev/null 2>&1 || fail "fixture brain sync failed"
  out="$(cd "$AC_HOME" && AC_SOLO=1 "$BIN/ac-self-task.sh" start zanzibar-quorum-reconciliation "$repo")"
  assert_contains "$out" "data/fam-one/room.md" "the start prints the brain hits for the slice"
  assert_contains "$(cat "$state/zanzibar-quorum-reconciliation.status")" "data/fam-one/room.md" \
    "the hits land on the status record"
  assert_contains "$(grep -o '"by":"[^"]*"' "$AC_HOME/state/brain-usage.jsonl" | tail -1)" "solo" \
    "a solo start is attributed solo"
  "$BIN/ac-teardown.sh" zanzibar-quorum-reconciliation --force >/dev/null 2>&1
  # The query is the slice id plus the PROJECT name, so the no-hit case needs
  # a project whose name matches nothing in the corpus either.
  repo_nohit="$(make_repo qqqzzrepo)"
  out="$(cd "$AC_HOME" && AC_SOLO=1 "$BIN/ac-self-task.sh" start qqqxzv-wwwqzx "$repo_nohit")"
  case "$out" in *"ac-brain recall"*) fail "a slice with no hits prints no recall block: $out" ;; esac
  "$BIN/ac-teardown.sh" qqqxzv-wwwqzx --force >/dev/null 2>&1
fi

# --- a SOLO CHIEF's slice: scoped start, LANDED: receipt at landing ----------
# A solo chief (a roomchief promoted --solo, AC_SCOPE set) works its family's
# slices through this same verb. Two things differ from a chief/solo-session
# slice: the meta carries the family scope, so fleet views and the watcher
# skip set group it under the family; and at landing the Done row - which the
# ledger guard fences from every scoped session - is stood in for by a
# `LANDED:` receipt in the family room, the one record a roomchief may write.
AC_SCOPE=scf "$BIN/ac-self-task.sh" start scf-fix "$repo" >/dev/null
assert_eq "$(awk -F= '$1=="fleet_scope"{print $2}' "$state/scf-fix.meta")" "scf" \
  "a scoped start records the family on the meta"
out="$("$BIN/ac-teardown.sh" scf-fix --no-lesson 'fixture' --no-fact 'fixture' 2>&1)" \
  && fail "a scoped slice with no LANDED: receipt must not land: $out"
assert_contains "$out" "landed-receipt=none" "the gate reports the receipt, not a Done row, for a scoped slice"
assert_contains "$out" "ac-room.sh post scf" "the missing receipt names the room post that writes it"
case "$out" in *"## Done"*) fail "a scoped slice is never asked for a Done row it may not write: $out" ;; esac
AC_SCOPE=scf "$BIN/ac-room.sh" post scf scf-chief 'LANDED: scf-fix - the fix, local main @abc' >/dev/null
out="$("$BIN/ac-teardown.sh" scf-fix --no-lesson 'fixture' --no-fact 'fixture' 2>&1)" \
  || fail "the LANDED: receipt lands the scoped slice: $out"
assert_contains "$(cat "$AC_HOME/data/scf-fix/timeline.log")" \
  "landed-receipt=yes" "the receipt is read from the family room"
assert_no_file "$state/scf-fix.meta" "the scoped slice is torn down"

# --- the slice that CANNOT land: UNLANDABLE is the other exit, in full -------
# Found by the solo-chief live probe and then mis-fixed once: when main moves
# under a slice, a SCOPED actor cannot land it - ac-merge-local.sh withholds
# --no-ff from any session carrying AC_CREW_ID/AC_SCOPE, the fence captain.md
# relies on - and a chief that cannot land can never truthfully post LANDED.
# The first fix taught it to post HANDBACK, which is the FAMILY's tenure-ending
# verb (ac_room_handback_families): it flipped the whole family into HANDBACK
# and wedged the crewchief's turn end. And its test tore down a slice with NO
# commits, so it never crossed landed_proof - the fence that actually holds an
# unlanded branch - and proved nothing about the scenario in its own comment.
# This one drives the real thing: a commit on the slice, main moved, the scoped
# land refused, the receipt posted, and the teardown still refusing until the
# crewchief lands it.
scg_default="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
AC_SCOPE=scg "$BIN/ac-self-task.sh" start scg-stuck "$repo" >/dev/null
scg_wt="$(awk -F= '$1=="worktree"{print $2}' "$state/scg-stuck.meta")"
git -C "$scg_wt" checkout -q -B crew/scg-stuck
printf 'slice work\n' >"$scg_wt/scg.txt"
git -C "$scg_wt" add scg.txt && git -C "$scg_wt" -c user.name=t -c user.email=t@t commit -q -m "scg: slice work"
printf 'main moved\n' >"$repo/moved.txt"
git -C "$repo" add moved.txt && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "main: moved under the slice"

rc=0; out="$(AC_SCOPE=scg "$BIN/ac-merge-local.sh" scg-stuck 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a scoped actor must be refused the land once main has moved: $out"
assert_contains "$out" "no-ff is not available" "...and told why (the fence, not a merge conflict)"

# A family HANDBACK that merely MENTIONS the slice is not the slice's receipt.
AC_SCOPE=scg "$BIN/ac-room.sh" post scg scg-chief 'HANDBACK: scg mostly done; scg-stuck was superseded' >/dev/null
rc=0; out="$("$BIN/ac-teardown.sh" scg-stuck --no-lesson 'fixture' --no-fact 'fixture' 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "an unlanded slice must not tear down on a family hand-back that names it: $out"
assert_contains "$out" "unlanded" "the branch fence holds first - the work is still on crew/scg-stuck"
# ...and it did not flip the family into HANDBACK either (that receipt is the
# family's; the slice never posts it).
AC_SCOPE=scg "$BIN/ac-room.sh" post scg scg-chief 'HANDBACK-REFUSED: fixture reset' >/dev/null

AC_SCOPE=scg "$BIN/ac-room.sh" post scg scg-chief \
  'UNLANDABLE: scg-stuck - main moved and a scoped actor is withheld --no-ff; crewchief to land' >/dev/null
rc=0; out="$("$BIN/ac-teardown.sh" scg-stuck --no-lesson 'fixture' --no-fact 'fixture' 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "the receipt is a RECORD, not a key to the branch fence: unlanded work still refuses: $out"
assert_contains "$out" "unlanded" "...with the same refusal, so the chief knows the crewchief has not landed it yet"
case "$(AC_HOME="$AC_HOME" "$BIN/ac-room.sh" list 2>/dev/null)" in
  *"HANDBACK"*"scg"*) fail "UNLANDABLE must not read as a family hand-back" ;;
esac

# The crewchief (unscoped) lands it --no-ff, and THEN the slice tears down on
# the receipt it was able to write truthfully.
"$BIN/ac-merge-local.sh" scg-stuck --no-ff >/dev/null 2>&1 || fail "the crewchief's --no-ff land must succeed"
out="$("$BIN/ac-teardown.sh" scg-stuck --no-lesson 'fixture' --no-fact 'fixture' 2>&1)" \
  || fail "once landed by the crewchief, UNLANDABLE discharges the receipt: $out"
assert_contains "$(cat "$AC_HOME/data/scg-stuck/timeline.log")" "landed-receipt=yes" \
  "the UNLANDABLE receipt is read as the slice's record"
assert_no_file "$state/scg-stuck.meta" "the slice is torn down"
git -C "$repo" branch -q -f "$scg_default" HEAD 2>/dev/null || true

# The receipt match is anchored on the receipt SHAPE, never a substring: a
# LANDED: line about another slice that mentions this one is not this one's.
AC_SCOPE=scz "$BIN/ac-self-task.sh" start scz-fix "$repo" >/dev/null
AC_SCOPE=scz "$BIN/ac-room.sh" post scz scz-chief 'LANDED: scz-other - done; scz-fix was folded in' >/dev/null
rc=0; out="$("$BIN/ac-teardown.sh" scz-fix --no-lesson 'fixture' --no-fact 'fixture' 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a LANDED: receipt for ANOTHER slice must not discharge this one: $out"
assert_contains "$out" "landed-receipt=none" "the mention is not a receipt"
AC_SCOPE=scz "$BIN/ac-room.sh" post scz scz-chief 'LANDED: scz-fix - landed' >/dev/null
"$BIN/ac-teardown.sh" scz-fix --no-lesson 'fixture' --no-fact 'fixture' >/dev/null 2>&1 \
  || fail "the slice's own LANDED: receipt lands it"

# --- the lesson gate reads the ATTRIBUTION, exactly ---------------------------
# The probe's roomchief filed five correct first-hand lessons under the heading
# its contract gives a family - `### <date> (family <fam>)` - and the gate,
# grepping the heading for `(solo <id>)`, reported lessons=none. The `(by: <id>,
# first-hand)` attribution is what the crewmate contract mandates per LINE, so
# that is what is read - and read whole, so `sch-fix-2`'s lesson is not
# `sch-fix`'s.
AC_SCOPE=sch "$BIN/ac-self-task.sh" start sch-fix "$repo" >/dev/null
"$BIN/ac-learn.sh" note "### 2026-09-19 (family sch)" \
  "- a lesson from the OTHER slice (by: sch-fix-2, first-hand)" >/dev/null
AC_SCOPE=sch "$BIN/ac-room.sh" post sch sch-chief 'LANDED: sch-fix - landed' >/dev/null
rc=0; out="$("$BIN/ac-teardown.sh" sch-fix --no-fact 'fixture' 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a lesson attributed to sch-fix-2 must not satisfy sch-fix: $out"
assert_contains "$out" "lessons=none" "the prefix match is not an attribution"
"$BIN/ac-learn.sh" note "- a lesson written under the family heading, attributed to the slice (by: sch-fix, first-hand)" >/dev/null
out="$("$BIN/ac-teardown.sh" sch-fix --no-fact 'fixture' 2>&1)" \
  || fail "a lesson attributed to the slice counts however its heading is spelled: $out"
assert_contains "$(cat "$AC_HOME/data/sch-fix/timeline.log")" "lessons=yes" \
  "the gate reads the (by: <id>, attribution the crewmate contract already mandates"

pass
