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

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
# (tests/sh/ac-spawn-branch-collision.test.sh covers that side) - proven here via
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
# recovery property the delivery-review skill sanctions on the spawn side).
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

# An orca lease that fails left no worktree to give back: the cleanup releases
# nothing - and still removes the status the start seeded.
touch "$FAKE_ORCA/.unreachable"; : >"$FAKE_ORCA/log"
"$BIN/ac-self-task.sh" start sofail "$repo" >/dev/null 2>&1 && fail "an unreachable orca must fail the lease"
rm -f "$FAKE_ORCA/.unreachable"
assert_no_file "$state/sofail.status" "an orca lease failure leaves no status either"
case "$(cat "$FAKE_ORCA/log")" in
  *"worktree rm"*) fail "a lease that never happened must release nothing: $(cat "$FAKE_ORCA/log")" ;;
esac

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

# Any code but 0 and 1 must refuse the SAME way, never proceed to open the pane
# (contract: ac-backend.sh WINDOW LIVENESS). This row once drove a driver that
# failed to LOAD (bash's 127, through a lab bin/ with the herdr driver
# renamed); the backend verbs are native now (src/lib.ts backendCall), so no
# driver can fail to load, and the row reaches the same unreadable verdict with
# herdr absent from PATH (the liveness ladder's 2), an orphan handle planted so
# the probe has a pane to ask about.
printf 'pLF1 tLF1\n' >"$state/.pane-lf1"
nh_path="$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$nh_path" command -v herdr || true)" ]; then
  : >"$FAKE_HERDR/log"
  err="$(PATH="$nh_path" "$BIN/ac-self-task.sh" start lf1 "$repo" 2>&1 1>/dev/null || true)"
  assert_contains "$err" "could not be READ" "a 127 (driver load failure) refuses like an unreadable backend"
  assert_no_file "$state/lf1.meta" "the refused start leaves no task in flight"
  assert_eq "$(grep -c 'tab create' "$FAKE_HERDR/log" || true)" "0" \
    "a 127 driver failure must never reach the pane-open step - that is the fail-OPEN this closes"
else
  printf 'SKIP: self-task with herdr absent - bun shares its directory with a herdr on this host\n'
fi
rm -f "$state/.pane-lf1"

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

# --- the LEASE failing: the seeded status goes too ----------------------------
# The status seed comes before the lease, so a lease failure is a partial start
# like any later one: a left-behind status reads as a task in flight, and a
# retry of the id appends to a dead slice's log.
repoF="$(make_repo projfull)"
rc=0; err="$(AC_MAX_TREES=0 "$BIN/ac-self-task.sh" start sfull "$repoF" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" != 0 ] || fail "a lease that cannot be had must fail the start"
assert_contains "$err" "pool is full" "the failure is the lease's own"
assert_no_file "$state/sfull.status" "the trap removes the status file when the LEASE fails"
assert_no_file "$state/sfull.meta" "...and leaves no meta"

# --- the knowledge-loop gate at landing --------------------------------------
# The solo contract owes three writes per slice and no chief asks whether
# they happened: teardown of a landed kind=self task REFUSES while a lesson,
# a repo fact or the Done row is missing - naming the exact command for each -
# and ticks the Learning cadence itself once all three are there. "Nothing
# new" is said out loud, never inferred: --no-lesson / --no-fact '<why>' waive
# those two on the record; the Done row is never waived.
"$BIN/ac-self-task.sh" start s10 "$repo" >/dev/null
# A QA verifier mid-run on the slice: the evidence preflight is DURABLE, so a
# landing this gate refuses must not have written it - the landed-proof rule
# (ac-spawn-teardown.test.sh, t23) holds for every refusal before the archive.
printf 'kind=verify-qa\nfamily=s10\ncaller=s10\nworktree=\nleases=\n' >"$state/s10-verify-qa.meta"
out="$("$BIN/ac-teardown.sh" s10 2>&1)" && fail "a slice that wrote nothing must not land: $out"
assert_file "$state/s10.meta" "the refused teardown leaves the slice in flight"
assert_no_file "$AC_HOME/data/s10/verification" "a refused solo landing writes no verifier evidence"
assert_file "$state/s10-verify-qa.meta" "...and leaves the live verifier alone"
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
assert_file "$(printf '%s\n' "$AC_HOME/data/s10/verification/s10-verify-qa-incomplete-"*/incomplete-run.md | head -n1)" \
  "past the gate the incomplete QA artifact is still preserved"
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
# The keyed tick dedupes for 24h only, so a landing must not tick on an
# attempt that can still die: a preflight that cannot preserve QA evidence
# leaves the slice in flight, and its retry a day later would count it twice.
"$BIN/ac-self-task.sh" start s13 "$repo" >/dev/null
printf '# Backlog\n## Queued\n## Done\n- [x] s13 - a slice whose QA evidence cannot be kept\n' >"$AC_HOME/records/backlog.md"
printf 'kind=verify-qa\nfamily=s13\ncaller=s13\nevidence=/dev/null/no-such-dir\nworktree=\nleases=\n' >"$state/s13-verify-qa.meta"
out="$("$BIN/ac-teardown.sh" s13 --no-lesson 'x' --no-fact 'y' 2>&1)" && fail "an unpreservable QA verifier must stop the landing: $out"
assert_contains "$out" "cannot preserve incomplete QA verifier" "the preflight's own refusal"
assert_file "$state/s13.meta" "...leaves the slice in flight"
grep -q "	s13$" "$state/.learn-ticks" 2>/dev/null && fail "a landing that died in the preflight must not have ticked"
sed -i.bak '/^evidence=/d' "$state/s13-verify-qa.meta"; rm -f "$state/s13-verify-qa.meta.bak"
out="$("$BIN/ac-teardown.sh" s13 --no-lesson 'x' --no-fact 'y' 2>&1)" || fail "the repaired retry lands: $out"
assert_eq "$(grep -c "	s13$" "$state/.learn-ticks")" "1" "...and ticks exactly once"
"$BIN/ac-self-task.sh" start s12 "$repo" >/dev/null
out="$("$BIN/ac-teardown.sh" s12 --no-lesson 'x' --no-fact 'y' 2>&1)" && fail "the Done row is never waived: $out"
assert_file "$state/s12.meta" "a missing Done row keeps the slice in flight"
out="$("$BIN/ac-teardown.sh" s12 --no-lesson '' 2>&1)" && fail "an empty waiver must be refused: $out"
assert_contains "$out" "--no-lesson carries" "an empty waiver says why it is refused"
out="$("$BIN/ac-teardown.sh" s12 --force 2>&1)"
case "$out" in *"knowledge loop"*) fail "a forced teardown discards the work and owes no checkpoint: $out" ;; esac
assert_no_file "$state/s12.meta" "a forced teardown still lands the discard"
# A reused id (a re-promoted roomchief, a retried slice) keeps EVERY epoch's
# archive: the latest at the fixed slot every reader resolves, the one it
# displaced in its own stamped dir beside it.
"$BIN/ac-self-task.sh" start s12 "$repo" >/dev/null
"$BIN/ac-self-task.sh" log s12 'the second epoch' >/dev/null
"$BIN/ac-teardown.sh" s12 --force >/dev/null 2>&1
assert_contains "$(cat "$state/archive/s12/status")" "the second epoch" "the fixed slot holds the LATEST epoch"
prior="$(find "$state/archive/s12" -mindepth 1 -maxdepth 1 -type d)"
assert_eq "$(printf '%s\n' "$prior" | grep -c .)" "1" "the earlier epoch moved to one stamped dir"
assert_file "$prior/meta" "...with its meta"
assert_contains "$(cat "$prior/status")" "knowledge loop: lessons=waived repo-knowledge=waived done-row=none" "...and its own status, intact"
case "$(cat "$prior/status")" in *"the second epoch"*) fail "the earlier epoch's status must be its own" ;; esac

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
# commits, so it never crossed landedProof - the fence that actually holds an
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

# The prompt hook also peeks a chief's queued wakes, so its stdout is no
# longer recall hits alone: a queued wake with zero hits must not be recorded
# as a fleet-memory read.
mkdir -p "$state/.wake-spool"; printf 'x\n' >"$state/.wake-spool/1.1.000001"
(cd "$AC_HOME" && "$BIN/ac-self-task.sh" start s-peek "$repo" >/dev/null)
case "$(cat "$state/s-peek.status" 2>/dev/null)" in
  *"fleet memory read"*) fail "a wake-count line is not a fleet-memory read" ;;
esac
rm -rf "$state/.wake-spool"

# --- differential: src/self-task.ts against the frozen bash original ----------
# Every row rebuilds one world at one path for each side and compares the calls
# (exit, stdout, stderr) and the world they leave; a named divergence (the
# DIVERGENCES block of the src/self-task.ts header) is pinned per side instead.
# DISPUTED: the implementation (tests/fixtures/ac-self-task.sh under bash vs src/self-task.ts through bin/ac-self-task.sh)
# HELD-CONSTANT: ONE world path ($XW) rebuilt by the row's own setup before each pass - a home ($XW/home, or the row's own name beside it) with config/ records/ data/ state/ and projects/proj linking the repo, the repo $XW/proj made under one git identity and one commit date, the container's .claude/CLAUDE.md, the fake herdr's and fake orca's dirs ($XW/herdr, $XW/orca), HOME=$XW/hh (bun's cache, never compared), TMPDIR=$XW/tmp; argv, env (AC_SEND_SETTLE=0, AC_HERDR_RPC_TIMEOUT=10, brain-auto-sync off, unless a row names others), cwd $XW/cwd unless a row names the home, stdin /dev/null, LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - date answering one instant for every format (holding at a meta's spawned_at stamp where a row says), sleep logging each call and returning at once (holding where a row says), od answering /dev/urandom from a per-world counter (holding where a row says) - ahead of the fake herdr and orca; the live bin/ siblings beside each entry, the oracle's root also linking .agents. Every call's exit, stdout and stderr compared whole once normalised (either root ROOT, a temp pid PID, bash's `child setpgid` noise dropped), then the world: every path under $XW but hh/, the brain's own files and every repo's .git dir with mode and bytes (a link: its target), and the repo's refs, worktrees and info/exclude.
cd "$TMP" || fail "cd TMP"
xobin="$(make_oracle_bin ac-self-task)"
cmp -s "$xobin/ac-self-task.sh" "$ROOT/tests/fixtures/ac-self-task.sh" || fail "the oracle bin holds the frozen original"
cmp -s "$BIN/ac-self-task.sh" "$ROOT/tests/fixtures/ac-self-task.sh" && fail "the live entry is the shim, not the original"
# The seed links skills from <root>/.agents/skills: the oracle's root must
# offer the same tree the port's does.
ln -s "$ROOT/.agents" "$TMP/oracle-ac-self-task/.agents"
XW="$TMP/xw"; XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig" \
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
# date: one instant; with stub/hold-date naming a meta, the iso stamp taken
# once that meta says kind=self (its spawned_at) holds until stub/release.
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case " $* " in *" -r "*|*" -j "*|*" -f "*) exec /bin/date "$@" ;; esac
if [ -e "$XSTUB/hold-date" ] && [ "$*" = "-u +%Y-%m-%dT%H:%M:%SZ" ] \
   && /usr/bin/grep -qx 'kind=self' "$(cat "$XSTUB/hold-date")" 2>/dev/null; then
  : >"$XSTUB/held"
  i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done
fi
exec /bin/date -r 1767225600 "$@"
STUB
# sleep: a call whose argument is the world's stub/hold-sleep holds until
# stub/release (stub/held marks it), so a signal row can land inside it.
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$XSTUB/sleep.log"
if [ -n "$*" ] && [ "$*" = "$(cat "$XSTUB/hold-sleep" 2>/dev/null)" ]; then
  : >"$XSTUB/held"
  i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done
fi
case "$*" in *[0-9]*) case "$*" in *[!0-9.]*) ;; *) exit 0 ;; esac ;; esac
exec /bin/sleep "$@"
STUB
# od: /dev/urandom is the n-th read's own bytes (lease ids differ per lease,
# match per pass); with stub/hold-od it holds like sleep does.
cat >"$XSTUBS/od" <<'STUB'
#!/bin/bash
args=()
for a in "$@"; do
  if [ "$a" = /dev/urandom ]; then
    n=$(( $(cat "$XSTUB/od.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" >"$XSTUB/od.n"
    printf '%064d' "$n" >"$XSTUB/od.rand"; a="$XSTUB/od.rand"
    if [ -e "$XSTUB/hold-od" ]; then
      : >"$XSTUB/held"
      i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    fi
  fi
  args+=("$a")
done
exec /usr/bin/od "${args[@]}"
STUB
chmod +x "$XSTUBS"/*

XHN=home
xworld() {  # xworld - a fresh world: the home $XW/$XHN, the repo $XW/proj (one commit on main) linked as projects/proj, the container .claude, both fakes' dirs
  rm -rf "$XW"
  mkdir -p "$XW/$XHN/state" "$XW/$XHN/data" "$XW/$XHN/records" "$XW/$XHN/config" "$XW/$XHN/projects" \
    "$XW/tmp" "$XW/stub" "$XW/hh" "$XW/cwd" "$XW/herdr/panes" "$XW/herdr/tabs" "$XW/orca/terminals" "$XW/.claude"
  printf 'off\n' >"$XW/$XHN/config/wedge-alarm"
  printf 'off\n' >"$XW/$XHN/config/brain-auto-sync"
  printf 'the container crewmate layer\n' >"$XW/.claude/CLAUDE.md"
  printf '\342\234\263 fake\n' >"$XW/orca/.default-title"
  git init -q "$XW/proj"
  printf 'base\n' >"$XW/proj/f.txt"; git -C "$XW/proj" add f.txt; git -C "$XW/proj" commit -qm base
  ln -s "$XW/proj" "$XW/$XHN/projects/proj"
}
xorca() { xworld; printf 'orca\n' >"$XW/$XHN/config/backend"; }   # an orca fleet's world
XLC=C; XENV=(); XPATH=""; XHOME=1; XCWD=cwd; XCLOSE=""; XPASS=o; XALT=(o); XCALL=0; XOBIN="$xobin"; XNBIN="$BIN"
xe() {  # xe - the call environment into XE: the leg's stubs ahead of the fakes and the host, the world's home, tmp, HOME and backends, then the row's XENV
  local path="$XSTUBS:$PATH" x
  [ -z "$XPATH" ] || path="$XPATH"
  XE=(env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_CHIEF_SOLO -u AC_FLEET_SCOPE -u AC_CREW_ID -u AC_DOMAIN
    -u AC_BACKEND -u AC_HERDR_SESSION -u AC_WINDOW_FAMILY -u AC_SEND_UNPROVEN -u AC_MAX_TREES -u AC_PORT_BASE
    -u AC_CREW_SKILLS -u AC_PROMPT_RECALL_LIMIT -u AC_BRAIN_SYNC_IV -u CDPATH
    "LC_ALL=$XLC" "PATH=$path" "HOME=$XW/hh" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub" "FAKE_HERDR=$XW/herdr" "FAKE_ORCA=$XW/orca"
    "AC_SEND_SETTLE=0" "AC_HERDR_RPC_TIMEOUT=10")
  [ -z "$XHOME" ] || XE+=("AC_HOME=$XW/$XHN")
  for x in ${XENV[@]+"${XENV[@]}"}; do XE+=("$x"); done
}
xrun() {  # xrun <cmd> <args...> - a setup step in the world's environment, quiet; a failure ends the leg
  xe; (cd "$XW/cwd" && exec "${XE[@]}" "$@") </dev/null >/dev/null 2>&1 || fail "self-task differential setup failed at line $(xrow): $*"
}
xput() { mkdir -p "$(dirname "$XW/$1")"; printf '%b' "$2" >"$XW/$1"; }   # xput <path under the world> <printf %b bytes>
xside() { local side="${XALT[$((XCALL % ${#XALT[@]}))]}"; XCALL=$((XCALL + 1)); XBIN="$XOBIN"; [ "$side" != n ] || XBIN="$XNBIN"; }   # xside - this call's entry dir into XBIN, the sides taken in turn
xc() {  # xc <args...> - one call by this pass's side for the call, its transcript appended
  local bin rc=0
  xside; bin="$XBIN"; xe
  if [ -n "$XCLOSE" ]; then (cd "$XW/$XCWD" && exec "${XE[@]}" "$bin/ac-self-task.sh" "$@" >&-) </dev/null 2>"$TMP/x.err" || rc=$?; : >"$TMP/x.out"
  else (cd "$XW/$XCWD" && exec "${XE[@]}" "$bin/ac-self-task.sh" "$@") </dev/null >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?; fi
  { printf '== %s\nrc=%s\n-- out\n' "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
xsig() {  # xsig <signal> <args...> - one call in the background; once the world holds stub/held, <signal> to its pid alone, then the hold released
  local sig="$1" bin pid rc=0 i=0; shift
  xside; bin="$XBIN"; xe
  # Job control gives the job its own group with SIGINT at its default - a
  # plain `&` job of a non-interactive shell starts with SIGINT ignored.
  {
    set -m
    (cd "$XW/$XCWD" && exec "${XE[@]}" "$bin/ac-self-task.sh" "$@") </dev/null >"$TMP/x.out" 2>"$TMP/x.err" &
    pid=$!
    set +m
    while [ ! -e "$XW/stub/held" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.05; i=$((i + 1)); done
    [ -e "$XW/stub/held" ] || fail "self-task differential at line $(xrow): the run never reached its hold"
    kill -"$sig" "$pid"
    /bin/sleep 0.5
    : >"$XW/stub/release"
    wait "$pid" || rc=$?
  } 2>/dev/null
  /bin/sleep 0.3
  rm -f "$XW/stub/held" "$XW/stub/release" "$XW/stub/hold-sleep" "$XW/stub/hold-od" "$XW/stub/hold-date"
  { printf '== %s %s\nrc=%s\n-- out\n' "$sig" "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
xnorm() {  # xnorm <file> - either root ROOT, a temp pid PID, bash's `child setpgid` noise dropped
  LC_ALL=C sed -E -e "s#$TMP/oracle-ac-self-task#ROOT#g" -e "s#$TMP/xlab-[on]#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e 's#\.tmp\.[0-9]+#.tmp.PID#g' -e '/child setpgid \([0-9]+ to [0-9]+\): Operation not permitted/d' "$1"
}
xsnap() {  # xsnap <pass> - the world as one listing
  local n f
  (cd "$XW" && find . \( -path ./hh -o -name .git -type d -o -path './*/state/brain*' -o -path './*/state/.brain*' \) -prune -o -print) \
    | sed 's#^\./##' >"$TMP/xnames"
  xnorm "$TMP/xnames" | paste - "$TMP/xnames" | LC_ALL=C sort | while IFS=$'\t' read -r n f; do
    if [ -L "$XW/$f" ]; then printf '== %s -> %s\n' "$n" "$(readlink "$XW/$f")"; continue; fi
    printf '== %s %s\n' "$n" "$(stat -f %Sp "$XW/$f")"
    [ -d "$XW/$f" ] || { cat "$XW/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'; }
  done >"$TMP/xw.$1"
  { printf -- '-- refs\n'; git -C "$XW/proj" for-each-ref --format='%(refname) %(objectname)'
    printf -- '-- worktrees\n'; git -C "$XW/proj" worktree list --porcelain
    printf -- '-- exclude\n'; cat "$XW/proj/.git/info/exclude" 2>/dev/null || true
  } >>"$TMP/xw.$1"
}
xpass() {  # xpass <pass> <setup> <body> <side>... - rebuild the world, then the body's calls by the sides in turn
  XPASS="$1"; : >"$TMP/xt.$1"; XCALL=0; XALT=("${@:4}")
  XLC=C; XENV=(); XPATH=""; XHOME=1; XCWD=cwd; XCLOSE=""; XHN=home; XOBIN="$xobin"; XNBIN="$BIN"
  $2; $3; xsnap "$1"
  xnorm "$TMP/xt.$1" >"$TMP/xt2.$1"; xnorm "$TMP/xw.$1" >"$TMP/xw2.$1"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xcmpt() { cmp -s "$TMP/xt2.$1" "$TMP/xt2.$2" || fail "self-task differential calls differ ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xt2.$1" "$TMP/xt2.$2" | head -n 14)"; }
xcmpw() { cmp -s "$TMP/xw2.$1" "$TMP/xw2.$2" || fail "self-task differential world differs ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xw2.$1" "$TMP/xw2.$2" | head -n 14)"; }
xcmp() { xcmpt "$1" "$2"; xcmpw "$1" "$2"; }   # xcmp <pass> <pass> - transcripts and worlds identical
xsame() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; xcmp o n; }   # xsame <setup> <body> - the oracle alone, then the port alone
xboth() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; }   # xboth <setup> <body> - both passes, compared by the row (a named divergence)
xcont() {  # xcont <setup> <body> - the oracle alone, then the two sides alternating call by call, either side first
  xpass o "$1" "$2" o; xpass a "$1" "$2" o n; xpass b "$1" "$2" n o; xcmp o a; xcmp o b
}
xt() { cat "$TMP/xt2.${1:-n}"; }
xhas() { assert_contains "$(xt "${2:-n}")" "$1" "self-task differential at line $(xrow)"; }   # xhas <text> [<pass>] - the normalised transcript holds <text>
xlacks() { case "$(xt "${2:-n}")" in *"$1"*) fail "self-task differential at line $(xrow): '$1' found" ;; esac; }
xwhas() { assert_contains "$(cat "$TMP/xw2.${2:-n}")" "$1" "self-task differential world at line $(xrow)"; }
xwlacks() { case "$(cat "$TMP/xw2.${2:-n}")" in *"$1"*) fail "self-task differential world at line $(xrow): '$1' found" ;; esac; }
# SHELL-OWN STDERR (named): bash's own error lines - a redirection or a printf
# write error - are not reproduced; xownless sets them aside in the oracle's
# transcript.
xownless() { LC_ALL=C sed -E -i.bak '/^ROOT\/bin\/[a-z-]+\.sh: line [0-9]+: /d' "$TMP/xt2.o"; }
xwithout() {  # xwithout <tool> - the leg's stubs and PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$XSTUBS:$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/no$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do [ "$(basename "$f")" = "$1" ] || ln -sf "$f" "$mirror/$(basename "$f")" 2>/dev/null || true; done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
xself() { xworld; xput home/state/s1.meta 'kind=self\nbackend=herdr\nproject=proj\n'; }   # a world holding a self task's meta

# -- leg 1: before the verb -------------------------------------------------------
x1a() {
  xc; xc -h; xc bogus; xc start; xc log; xc start Ab proj; xc log Ab x
  xc start s1; xc log s1; xc log s1 ''
}
xsame xworld x1a
xhas "usage: ac-self-task.sh start <id> <project> | ac-self-task.sh log <id> '<line>'"
xhas 'usage: ac-self-task.sh start <id> ...'
xhas 'id must be [a-z0-9-]: Ab'
xhas 'usage: ac-self-task.sh start <id> <project-name-or-dir>'
xhas "usage: ac-self-task.sh log <id> '<line>'"
# W14 (at parity): an unsupported backend refuses every argv, usage included -
# and a config/backend that only the start reads, past an env pin.
x1b() {
  XENV=(AC_BACKEND=tmux); xc; xc log s1 x
  XENV=(); printf 'tmux\n' >"$XW/home/config/backend"; xc -h
  XENV=(AC_BACKEND=herdr); xc start s2 proj
}
xsame xself x1b
xhas "unsupported backend 'tmux'"
x1c() { XHOME=""; xc start s1 proj; xc log s1 x; }
xsame xworld x1c
xhas 'AC_HOME is not set'
# W3 (at parity): `log` needs git too.
x1d() { XPATH="$(xwithout git)"; xc log s1 x; xc start s2 proj; }
xsame xself x1d
xhas 'required tool not found: git'
# BUN (named): with no bun the original's `log` runs and its herdr start ends
# at the lease's shim; the port's shim refuses both before anything.
x1e() { XPATH="$(xwithout bun)"; xc log s1 'working: no bun'; xc start s2 proj; }
xboth xself x1e
xhas $'== log s1 working: no bun\nrc=0' o
xhas $'== start s2 proj\nrc=1\n-- out\n-- err\nERROR: required tool not found: bun' o
xwhas 'working: no bun' o
xwlacks '== home/state/s2.status ' o
assert_eq "$(grep -c '^ERROR: required tool not found: bun$' "$TMP/xt2.n")" "2" "the port's shim refuses both calls on bun alone"
xwlacks 'working: no bun' n
# W4 (at parity): the charset by its text under a UTF-8 locale, and a
# dash-only id that passes it.
x1f() {
  XLC=en_US.UTF-8; xc start aB proj; xc start é proj; xc log é x
  XLC=C; xc start -- proj --mode bogus; xc start -- proj
}
xsame xworld x1f
xhas 'id must be [a-z0-9-]: aB'
xhas 'id must be [a-z0-9-]: é'
xhas 'invalid --mode: bogus'
xwhas '== home/state/--.meta '

# -- leg 2: log -------------------------------------------------------------------
# W5 (at parity): the refusal's second, unsilenced read of kind=; W10 (at
# parity): a line holding LF.
xlogs() {
  xself
  xput home/state/sk.meta 'kind=ship\nbackend=herdr\n'; xput home/state/sn.meta 'backend=herdr\n'
  xput home/state/su.meta 'kind=self\n'; xput home/state/scr.meta 'kind=self\r\n'
}
x2a() {
  xc log nometa x; xc log sk 'working: x'; xc log sn 'working: x'; xc log scr 'working: x'
  chmod 000 "$XW/home/state/su.meta"; xc log su 'working: x'; chmod 644 "$XW/home/state/su.meta"
  xc log s1 'working: edited a file' extra args; xc log s1 $'two\nlines'
}
xsame xlogs x2a
xhas 'no self task for nometa (start it first)'
xhas 'sk is kind=ship, not self'
xhas 'sn is kind=, not self'
xhas 'WARN: cannot read meta file'
xwhas 'working: edited a file'
xwhas '== home/data/s1/timeline.log '
# W11 (named, SHELL-OWN): a status that is a directory ends the append 1, the
# original's own `Is a directory` line set aside.
x2b() { mkdir -p "$XW/home/state/s1.status"; xc log s1 x; }
xboth xself x2b
xhas 'Is a directory' o
xownless; xcmp o n
xhas $'== log s1 x\nrc=1'

# -- leg 3: start's flags, the duplicate, the project -------------------------------
x3a() {
  xc start s1 proj --bogus; xc start s1 proj --mode; xc start s1 proj --harness; xc start s1 proj --base-branch
  xc start s1 proj --mode ''; xc start s1 proj --base-branch main; xc start s1 proj --mode crew-ship --mode direct-pr
}
xsame xworld x3a
xhas 'unknown argument: --bogus'
xhas 'invalid --mode: empty'
xhas '--harness names the harness working this slice'
xhas '--base-branch names the branch the orca lease is cut from'
xhas 'requires an orca-backend fleet (config/backend=herdr here)'
xwhas 'mode=direct-pr'
# W9 (at parity): a dangling link at the meta path passes the duplicate check.
x3b() { xc start s1 proj; xc start s1 proj; ln -s "$XW/nowhere" "$XW/home/state/s2.meta"; xc start s2 proj; }
xsame xworld x3b
xhas 'task s1 already exists (see '
xhas 'self-task s2 kind=self project=proj'
# The project: a name, a linked name, a path inside the repo, a non-repo, a
# missing one, and W7 (at parity) - a non-repo dir in the cwd shadowing
# projects/<name>.
xprojects() { xworld; mkdir -p "$XW/proj/sub" "$XW/plain"; ln -s "$XW/proj" "$XW/home/projects/alias"; }
x3c() {
  xc start s1 proj; xc start s2 alias; xc start s3 "$XW/proj/sub"; xc start s4 "$XW/proj"
  xc start s5 "$XW/plain"; xc start s6 nope; mkdir "$XW/cwd/proj"; xc start s7 proj
}
xsame xprojects x3c
xhas 'self-task s2 kind=self project=proj'
xhas 'project not found: nope'
xhas 'project not found: proj'

# -- leg 4: the branch collision -----------------------------------------------------
xcollide() {
  xworld; git -C "$XW/proj" branch crew/s3; git -C "$XW/proj" branch crew/fam; git -C "$XW/proj" branch crew/s4
  mkdir -p "$XW/home/data/fam/ship"; xput home/state/s4.meta 'kind=self\nbackend=herdr\n'
}
x4a() { xc start s3 proj; xc start fam-ship proj; xc start s4-r2 proj; }
xsame xcollide x4a
xhas 'crew/s3 already exists in '
xhas 'then start again'
xhas 'crew/fam already exists in '
xhas 'self-task s4-r2 kind=self'
xwhas 'refs/heads/crew/s3'

# -- leg 5: the herdr start ------------------------------------------------------------
x5a() { xc start s1 proj; xc start s2 proj --mode direct-pr; }
xsame xworld x5a
xhas 'self-task s1 kind=self project=proj backend=herdr window=herdr:pane-p1 worktree='
xwhas 'tail -f'
xwhas 'working: self task started by the chief'
xwhas '== home/state/port-slots.tsv '
# The scope rides the meta; W2 (at parity): an env orca pin with no config
# leases from the herdr pool.
x5b() { XENV=(AC_SCOPE=fam); xc start fam-one proj --mode direct-pr; XENV=(AC_BACKEND=orca); xc start s2 proj; }
xsame xworld x5b
xwhas 'fleet_scope=fam'
xhas 'self-task s2 kind=self project=proj backend=herdr'

# -- leg 6: the crewmate layer -----------------------------------------------------------
xlayers() { xworld; rm -f "$XW/.claude/CLAUDE.md"; printf 'the fleet crewmate layer\n' >"$XW/home/CREWMATE.md"; }
x6a() { xc start s1 proj; xc start s2 proj --harness codex; }
xsame xlayers x6a
xwhas 'AGENTS.md'
xwhas '.agents/skills'
xshipped() { xworld; mkdir -p "$XW/proj/.claude"; printf 'the shipped law\n' >"$XW/proj/.claude/CLAUDE.md"; git -C "$XW/proj" add -f .claude/CLAUDE.md; git -C "$XW/proj" commit -qm shipped; }
x6b() { xc start s1 proj; }
xsame xshipped x6b
xhas 'crewmate layer at FALLBACK path: .claude/CREWMATE.md'
xwhas 'layer: crewmate layer at FALLBACK path .claude/CREWMATE.md'
# W1 (at parity): an unknown --harness starts, its ERROR printed - with no
# layer source, and with one landing at the FALLBACK path though the repo
# ships nothing.
xbare() { xworld; rm -f "$XW/.claude/CLAUDE.md"; }
x6c() { xc start s1 proj --harness bogus; }
xsame xbare x6c
xhas "unknown harness 'bogus'"
xhas 'self-task s1 kind=self'
xsame xworld x6c
xhas 'crewmate layer at FALLBACK path: .claude/CREWMATE.md'
# A skills seed that fails ends the start after the lease: the rollback
# returns the slot and removes the status.
xskillsfile() { xworld; mkdir -p "$XW/proj/.claude"; printf 'x\n' >"$XW/proj/.claude/skills"; git -C "$XW/proj" add -f .claude/skills; git -C "$XW/proj" commit -qm skills-file; }
x6d() { xc start s1 proj; }
xsame xskillsfile x6d
xhas $'== start s1 proj\nrc=1'
xwlacks '== home/state/s1.status '
xwlacks '== home/state/s1.meta '
xwhas 'leased=0'

# -- leg 7: the fleet-memory read ---------------------------------------------------------
xbrain() {
  xworld; mkdir -p "$XW/home/data/fam-one"
  printf '# Room: fam-one\nA distinctive sentence about zanzibar quorum reconciliation lives here.\n' >"$XW/home/data/fam-one/room.md"
  xrun "$BIN/ac-brain.sh" sync --home "$XW/home" --compact
}
x7a() { XENV=(AC_SOLO=1); xc start zanzibar-quorum-reconciliation proj; xc start qqqxzv-wwwqzx proj; }
xsame xbrain x7a
xhas 'data/fam-one/room.md'
xwhas 'working: fleet memory read, opening the pane'
# A chief at the home with a queued wake: the hook's `agent-crew:` line is
# dropped, the hits kept.
x7b() { mkdir -p "$XW/home/state/.wake-spool"; printf 'x\n' >"$XW/home/state/.wake-spool/1.1.000001"; XCWD=home; xc start zanzibar-quorum-reconciliation proj; }
xsame xbrain x7b
xhas 'data/fam-one/room.md'
xlacks 'agent-crew: '
# W8 (at parity): a `"` in the project name breaks the hook's JSON and the
# read vanishes.
xquote() { xbrain; git init -q "$XW/q\"x"; printf 'b\n' >"$XW/q\"x/f"; git -C "$XW/q\"x" add f; git -C "$XW/q\"x" commit -qm b; }
x7c() { XENV=(AC_SOLO=1); xc start zanzibar-quorum-reconciliation "$XW/q\"x"; }
xsame xquote x7c
xhas 'project=q"x'
xlacks 'ac-brain recall'

# -- leg 8: the pane's refusals, each after the lease ----------------------------------------
# A live orphan window, an unreadable backend, herdr absent from PATH, a
# stopped server: each rolls the lease and the status back, and W6 (at parity)
# leaves the port slot's registry row.
x8a() {
  xput home/state/.pane-or1 'pOR1 tOR1\n'; xput herdr/tabs/tOR1 'pOR1 crew:or1\n'; : >"$XW/herdr/panes/pOR1.buf"
  xc start or1 proj
  xput home/state/.pane-or2 'pOR2 tOR2\n'; : >"$XW/herdr/.unreachable"; xc start or2 proj; rm -f "$XW/herdr/.unreachable"
  : >"$XW/herdr/.server-stopped"; xc start sdown proj; rm -f "$XW/herdr/.server-stopped"
}
xsame xworld x8a
xhas 'window herdr:pane-pOR1 already exists'
xhas 'the BACKEND could not be READ for or2'
xhas 'herdr workspace create failed (is the herdr server running?)'
xhas 'could not open the pane for sdown on the herdr backend: the herdr server is not running - attach the session'
xwhas '== home/state/.pane-or1 '
xwhas '== home/state/port-slots.tsv '
xwlacks '== home/state/sdown.status '
x8b() { xput home/state/.pane-lf1 'pLF1 tLF1\n'; XPATH="$(xwithout herdr)"; xc start lf1 proj; }
xsame xworld x8b
xhas 'the BACKEND could not be READ for lf1'
# A meta write refused after the pane (its lock held by a live pid): the
# rollback reaps the tab too.
x8c() { mkdir -p "$XW/home/state/.s1.meta.lock"; printf '%s\n' "$$" >"$XW/home/state/.s1.meta.lock/pid"; xc start s1 proj; }
xsame xworld x8c
xhas 'cannot lock meta file'
xwlacks '== home/state/s1.meta '
xwlacks '== home/state/.pane-s1 '
xwlacks '== home/state/s1.status '
xwhas 'leased=0'
# A tail whose Enter is never acknowledged warns, and the start goes on.
x8d() { printf '9\n' >"$XW/herdr/panes/p1.drop-enters"; xc start s1 proj; }
xsame xworld x8d
xhas 'the pane may not have started tailing'
xhas 'self-task s1 kind=self'
# A meta rewrite whose mv dies by TERM: mv's status is the start's, the
# rollback whole but for the temp (bash's own `Terminated` report set aside -
# SHELL-OWN).
xmvterm() {
  xworld; mkdir -p "$XW/stub/mt"
  printf '#!/bin/sh\ncase "$1" in */state/s1.meta.tmp.*) kill -TERM $$ ;; esac\nexec /bin/mv "$@"\n' >"$XW/stub/mt/mv"
  chmod +x "$XW/stub/mt/mv"
}
x8e() { XPATH="$XSTUBS:$XW/stub/mt:$PATH"; xc start s1 proj; }
xboth xmvterm x8e
xhas 'Terminated' o
xownless; xcmp o n
xhas $'== start s1 proj\nrc=143'
xwhas '== home/state/s1.meta.tmp.PID '
xwlacks '== home/state/s1.meta '
xwlacks '== home/state/.pane-s1 '
xwlacks '== home/state/s1.status '
xwhas 'leased=0'

# -- leg 9: the lease's refusals -------------------------------------------------------------
x9a() { XENV=(AC_MAX_TREES=0); xc start sfull proj; }
xsame xworld x9a
xhas 'pool is full'
xwlacks '== home/state/sfull.status '
# A lease whose child dies by TERM: its status is the start's, the status
# removed.
xlab() {  # xlab <name> <bin> - a scratch root running <bin>'s scripts with an ac-tree.sh that kills itself with TERM
  local d="$TMP/xlab-$1"
  rm -rf "$d"; mkdir -p "$d/bin"; cp "$2"/*.sh "$d/bin/"
  ln -s "$ROOT/src" "$d/src"; ln -s "$ROOT/dashboard" "$d/dashboard"; ln -s "$ROOT/.agents" "$d/.agents"
  printf '#!/bin/sh\nkill -TERM $$\n' >"$d/bin/ac-tree.sh"; chmod +x "$d/bin/ac-tree.sh"
  printf '%s\n' "$d/bin"
}
xlabo="$(xlab o "$xobin")"; xlabn="$(xlab n "$BIN")"
x9b() { XOBIN="$xlabo"; XNBIN="$xlabn"; xc start s1 proj; }
xsame xworld x9b
xhas $'== start s1 proj\nrc=143'
xwlacks '== home/state/s1.status '
# The orca lease: an unreachable runtime, and the epic-branch fence refusing
# a missing integration branch - nothing leased, nothing released.
x9c() { : >"$XW/orca/.unreachable"; xc start sofail proj; }
xsame xorca x9c
xhas 'could not lease an Orca worktree for sofail'
xwlacks 'worktree rm'
xfence() {
  xorca; mkdir -p "$XW/home/data/ofe"; printf 'proj epic/ofe\n' >"$XW/home/data/ofe/branches"
  printf '# Backlog\n## Queued\n- [ ] ofs5 - story; epic:ofe (repo: proj)\n## Done\n' >"$XW/home/records/backlog.md"
}
x9d() { xc start ofs5 proj; }
xsame xfence x9d
xhas 'epic/ofe'
xwlacks '== home/state/ofs5.status '

# -- leg 10: the orca start ------------------------------------------------------------------
x10a() { XENV=(AC_SCOPE=fam); xc start fam-o1 proj --base-branch main; }
xsame xorca x10a
xhas 'self-task fam-o1 kind=self project=proj backend=orca window=orca:'
xwhas 'worktree_backend=orca'
xwhas 'exec tail -f'
xwlacks 'lease_ids='
# A terminal the runtime refuses: the driver's WARN, the start's ERROR, the
# Orca worktree released.
xorcadown() {
  xorca; mkdir -p "$XW/stub/oc"
  printf '#!/bin/sh\ncase "$*" in "terminal create"*) echo "{\\"ok\\":false}"; exit 1 ;; esac\nexec "%s" "$@"\n' "$TMP/stubbin/orca" >"$XW/stub/oc/orca"
  chmod +x "$XW/stub/oc/orca"
}
x10b() { XPATH="$XSTUBS:$XW/stub/oc:$PATH"; xc start s1 proj; }
xsame xorcadown x10b
xhas 'orca terminal create failed for '
xhas 'orca pane placement failed for s1 at '
xwhas 'worktree rm'

# -- leg 11: %q (the status path's spelling in the tail) ------------------------------------
# A home path holding a space and é, spelled by bash 3.2's %q under C and under
# UTF-8 - the herdr send-text argument and the orca terminal command.
xqworld() { XHN='hé x'; xworld; }
xqorca() { XHN='hé x'; xorca; }
x11a() { xc start s1 proj; XLC=en_US.UTF-8; xc start s2 proj; }
xsame xqworld x11a
xwhas 'tail -f'
xsame xqorca x11a
xwhas 'exec tail -f'

# -- leg 12: signals -------------------------------------------------------------------------
# W15 (at parity): TERM held through the lease acts as it returns - the slot
# stays leased, the status goes.
x12a() { : >"$XW/stub/hold-od"; xsig TERM start s1 proj; }
xsame xworld x12a
xhas $'== TERM start s1 proj\nrc=143'
xwlacks '== home/state/s1.status '
xwhas 'leased=1'
xwlacks 'leased=0'
# TERM, HUP and INT held through the meta's spawned_at stamp: the whole
# rollback - lease returned, tab reaped, handle, meta and status gone.
xstamp() { xworld; printf '%s\n' "$XW/home/state/s1.meta" >"$XW/stub/hold-date"; }
x12b() { xsig TERM start s1 proj; }
xsame xstamp x12b
xhas $'== TERM start s1 proj\nrc=143'
xwlacks '== home/state/s1.meta '
xwlacks '== home/state/.pane-s1 '
xwlacks '== home/state/s1.status '
xwhas 'leased=0'
x12c() { xsig HUP start s1 proj; }
xsame xstamp x12c
xhas $'== HUP start s1 proj\nrc=129'
x12d() { xsig INT start s1 proj; }
xsame xstamp x12d
xhas $'== INT start s1 proj\nrc=130'
xstamporca() { xorca; printf '%s\n' "$XW/home/state/s1.meta" >"$XW/stub/hold-date"; }
xsame xstamporca x12b
xhas $'== TERM start s1 proj\nrc=143'
xwhas 'worktree rm'
# W16 (at parity): TERM held through the orca placement acts as it returns -
# the terminal stays, no handle is written, the worktree is released.
xorcahold() {
  xorca; mkdir -p "$XW/stub/oh"
  printf '#!/bin/sh\ncase "$*" in "terminal create"*) : >"$XSTUB/held"; i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done ;; esac\nexec "%s" "$@"\n' "$TMP/stubbin/orca" >"$XW/stub/oh/orca"
  chmod +x "$XW/stub/oh/orca"
}
x12e() { XPATH="$XSTUBS:$XW/stub/oh:$PATH"; xsig TERM start s1 proj; }
xsame xorcahold x12e
xhas $'== TERM start s1 proj\nrc=143'
xwlacks '== home/state/.pane-s1 '
xwhas 'terminal create'
# SIGNALS (named): during the tail's send, a plain child of the original, TERM
# acted at once - the send cut short, the tab left (W16) - where the port
# finishes the send first; INT the original swallowed there and completed,
# where the port ends 130 with the rollback.
xsettle() { xworld; printf '7\n' >"$XW/stub/hold-sleep"; }
x12f() { XENV=(AC_SEND_SETTLE=7); xsig TERM start s1 proj; }
xboth xsettle x12f
xhas $'== TERM start s1 proj\nrc=143' o
xhas $'== TERM start s1 proj\nrc=143' n
xwlacks '== home/state/s1.status ' o
xwlacks '== home/state/s1.status ' n
xwhas '== home/state/.pane-s1 ' o
xwhas '== home/state/.pane-s1 ' n
x12g() { XENV=(AC_SEND_SETTLE=7); xsig INT start s1 proj; }
xboth xsettle x12g
xhas $'== INT start s1 proj\nrc=0' o
xwhas '== home/state/s1.meta ' o
xhas $'== INT start s1 proj\nrc=130' n
xwlacks '== home/state/s1.meta ' n
# SIGNALS (named): held through the final meta rewrite's mv, a plain child of
# the original, TERM and HUP acted at once - the rollback ran while the mv
# went on, so whether it landed the meta before or after the rollback's rm is
# the original's race, unpinned - and INT was swallowed, the start reported;
# the port lands the rewrite, then rolls the whole start back. xmvdone waits
# that mv out, the original's orphan included, before the world is read.
xmvhold() {
  xworld; mkdir -p "$XW/stub/mh"
  printf '#!/bin/sh\ncase "$1" in */state/s1.meta.tmp.*) if /usr/bin/grep -q "^spawned_at=" "$1"; then : >"$XSTUB/held"; i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done; /bin/mv "$@"; s=$?; : >"$XSTUB/mv-done"; exit $s; fi ;; esac\nexec /bin/mv "$@"\n' >"$XW/stub/mh/mv"
  chmod +x "$XW/stub/mh/mv"
}
xmvdone() {  # xmvdone - the held mv released again and waited for
  local i=0; : >"$XW/stub/release"
  while [ ! -e "$XW/stub/mv-done" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  [ -e "$XW/stub/mv-done" ] || fail "self-task differential at line $(xrow): the held mv never finished"
  rm -f "$XW/stub/release"
}
x12h() { XPATH="$XSTUBS:$XW/stub/mh:$PATH"; xsig TERM start s1 proj; xmvdone; }
xboth xmvhold x12h
xhas $'== TERM start s1 proj\nrc=143' o
xwlacks '== home/state/s1.status ' o
xwlacks '== home/state/.pane-s1 ' o
xwhas 'leased=0' o
xhas $'== TERM start s1 proj\nrc=143' n
xwlacks '== home/state/s1.meta ' n
xwlacks '== home/state/.s1.meta.lock ' n
xwlacks '== home/state/s1.status ' n
xwlacks '== home/state/.pane-s1 ' n
xwhas 'leased=0' n
x12i() { XPATH="$XSTUBS:$XW/stub/mh:$PATH"; xsig HUP start s1 proj; xmvdone; }
xboth xmvhold x12i
xhas $'== HUP start s1 proj\nrc=129' o
xhas $'== HUP start s1 proj\nrc=129' n
xwlacks '== home/state/s1.meta ' n
x12j() { XPATH="$XSTUBS:$XW/stub/mh:$PATH"; xsig INT start s1 proj; xmvdone; }
xboth xmvhold x12j
xhas $'== INT start s1 proj\nrc=0' o
xhas 'self-task s1 kind=self' o
xhas $'== INT start s1 proj\nrc=130' n
xlacks 'self-task s1 kind=self' n
xwlacks '== home/state/s1.meta ' n
# SIGNALS (named): held through log's date, TERM, HUP and INT ended the
# original with nothing appended; the port appends the line, then ends 128+n.
xlogdate() { xself; printf '%s\n' "$XW/home/state/s1.meta" >"$XW/stub/hold-date"; }
x12k() { xsig TERM log s1 'working: logged under TERM'; }
xboth xlogdate x12k
xhas $'== TERM log s1 working: logged under TERM\nrc=143' o
xhas $'== TERM log s1 working: logged under TERM\nrc=143' n
xwlacks 'working: logged under TERM' o
xwhas 'working: logged under TERM' n
x12l() { xsig HUP log s1 'working: logged under HUP'; }
xboth xlogdate x12l
xhas $'== HUP log s1 working: logged under HUP\nrc=129' o
xhas $'== HUP log s1 working: logged under HUP\nrc=129' n
x12m() { xsig INT log s1 'working: logged under INT'; }
xboth xlogdate x12m
xhas $'== INT log s1 working: logged under INT\nrc=130' o
xhas $'== INT log s1 working: logged under INT\nrc=130' n

# -- leg 13: continuation -----------------------------------------------------------------------
# A slice started by one side is logged by the other and torn down after,
# either side first.
x13a() { xc start s1 proj; xc log s1 'working: the other side logs it'; xrun "$BIN/ac-teardown.sh" s1 --force; }
xcont xworld x13a
xhas 'self-task s1 kind=self' a
xwhas 'the other side logs it' b

# -- leg 14: a closed stdout --------------------------------------------------------------------
# The start's first write to stdout fails and ends it 1 where it stands - the
# start line, the FALLBACK notice, the recall block; a log writes none (bash's
# own `printf: write error` set aside - SHELL-OWN).
x14a() { XCLOSE=1; xc start s1 proj; xc log s1 'working: logged with stdout closed'; }
xboth xworld x14a
xhas 'printf: write error' o
xownless; xcmp o n
xhas $'== start s1 proj\nrc=1'
xhas $'== log s1 working: logged with stdout closed\nrc=0'
xwhas '== home/state/s1.meta '
x14b() { XCLOSE=1; xc start s1 proj; }
xboth xshipped x14b
xhas 'printf: write error' o
xownless; xcmp o n
xhas $'== start s1 proj\nrc=1'
x14c() { XCLOSE=1; XENV=(AC_SOLO=1); xc start zanzibar-quorum-reconciliation proj; }
xboth xbrain x14c
xhas 'write error' o
xownless; xcmp o n
xhas $'== start zanzibar-quorum-reconciliation proj\nrc=1'

pass
