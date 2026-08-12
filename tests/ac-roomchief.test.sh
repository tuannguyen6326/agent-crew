#!/usr/bin/env bash
# ac-roomchief.test.sh - design C: promote a room to its own session
# (spawn --roomchief), demotion guarded by family in-flight, and the
# watcher family filters (AC_WATCH_ONLY / AC_WATCH_SKIP).
# Driven end to end through the file-backed fake herdr CLI (tests/helpers.sh):
# the launch line and kickoff prompt land VERBATIM in the pane buffer
# (nothing executes them), crewmate output is injected by appending to the
# buffer, and a task with no pane handle reads as a vanished window.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
# Deliver the kickoff prompt immediately (default 8s) so the suite stays fast.
export AC_SPAWN_SETTLE=0
# Every pane here clears the composer-ready observation (bin/ac-spawn.sh
# kickoff_wait_input_ready) immediately - this suite is not testing that gate
# (tests/ac-spawn-kickoff-ready.test.sh owns it), it just needs its spawns to
# complete without a real harness's boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5

make_home
printf 'echo roomchief __ID__; sleep 300\n' >"$AC_HOME/config/launch-fake"

seed_pane() {
  # seed_pane <id> <p> <t> - a live fake pane for <id> without a spawn:
  # handle + tab + empty buffer (the ac-backend.test.sh p90/t90 idiom).
  printf '%s %s\n' "$2" "$3" >"$AC_HOME/state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
}

room_seed() {
  # room_seed <family> [<text>] - the ORDER GATE precondition every real promote
  # meets. `--roomchief` takes no brief - the room IS the brief - so ac-spawn
  # refuses a promote into a room holding no entry (below). Production posts the
  # order (crewchief) or the charter (bin/ac-learn.sh:1711) BEFORE promoting, so
  # these fixtures do the same rather than being exempted from the gate. The
  # default text opens with NO marker verb: a fixture must not mint a pending
  # item, and the gate matches the entry LINE SHAPE, never the prose.
  "$BIN/ac-room.sh" post "$1" crewchief \
    "${2:-the captain order for $1, posted before the promote}" >/dev/null
}

# --- THE ORDER GATE: a promote into an EMPTY room refuses ----------------------
# `--roomchief` takes no brief - the room IS the brief (bin/ac-spawn.sh header)
# and the generated kickoff tells the new chief "Read the room first" - but
# NOTHING checked the room actually held the order, so promote-then-ac-send left
# a roomchief orienting on nothing and re-triaging when the order finally landed:
# two sources of truth for one task (measured 2026-07-30 on the drydock fleet -
# 54 of 272 rooms carrying a PROMOTED entry had it as their FIRST entry line).
# Fail-CLOSED: refusing costs one command, an orderless roomchief costs a wrong
# triage.

# (1) no room at all -> refused, naming the post-then-promote fix, with NO meta
#     (the header's exit contract: non-zero means nothing was written, retry).
out="$("$BIN/ac-spawn.sh" --roomchief og1 --harness fake 2>&1)" \
  && fail "a promote into a room holding no entry must refuse"
assert_contains "$out" "holds no entry" "the refusal says what is wrong"
assert_contains "$out" "bin/ac-room.sh post og1" "the refusal names the exact fix"
assert_no_file "$AC_HOME/state/og1-chief.meta" "a refused promote writes no meta"
assert_no_file "$AC_HOME/data/og1/room.md" "a refused promote posts no PROMOTED entry"

# (2) FILE EXISTENCE IS NOT THE PREDICATE: cmd_post creates the room with a
#     `# Room: <family>` header and a blank line before any entry, so a
#     header-only room is still an empty room.
mkdir -p "$AC_HOME/data/og2"
printf '# Room: og2\n\n' >"$AC_HOME/data/og2/room.md"
out="$("$BIN/ac-spawn.sh" --roomchief og2 --harness fake 2>&1)" \
  && fail "a header-only room must still refuse - file existence is not the predicate"
assert_contains "$out" "holds no entry" "a room with only its header reads as empty"
assert_no_file "$AC_HOME/state/og2-chief.meta" "no meta for the header-only room"

# (3) the CHARTER-FIRST pattern passes (bin/ac-learn.sh:1711-1713 posts the
#     charter, then promotes) - and ANY entry satisfies the gate, so a CHARTER:
#     entry counts exactly like an ORDER: one. No prose shape-matching.
room_seed og3 "CHARTER: room og3 carries the captain standing order"
"$BIN/ac-spawn.sh" --roomchief og3 --harness fake >/dev/null 2>&1 \
  || fail "the charter-first promote must pass the gate"
assert_file "$AC_HOME/state/og3-chief.meta" "the charter-first promote writes its meta"
"$BIN/ac-teardown.sh" og3-chief >/dev/null 2>&1

# (4) the HOT-ROOM UPGRADE - `--roomchief`'s original use case - passes for the
#     same reason: a room hot enough to deserve its own chief already has
#     entries. The gate separates it from the spawn-then-send case above.
room_seed og4 "the crewchief and the captain traded three rounds in this room"
"$BIN/ac-spawn.sh" --roomchief og4 --harness fake >/dev/null 2>&1 \
  || fail "the hot-room upgrade must pass the gate"
assert_file "$AC_HOME/state/og4-chief.meta" "the hot-room promote writes its meta"
"$BIN/ac-teardown.sh" og4-chief >/dev/null 2>&1

# --- PART 1: code-owned START announce (remote-mirror=chief) -------------------
# Under mirror=chief NOBODY owned the family's Slack BIRTH post: the roomchief
# authors the narrative but the START stamp was un-owned by code (missed twice
# in 2 days). The --roomchief path now posts ONE code-owned START template,
# idempotent on the thread file's existence (family_send self-registers
# state/remote-threads/<fam>.thread on the first post - that IS the "already
# announced" marker). A remote-reply hook makes the post observable.
ANNLOG="$TMP/ann.log"
export AC_ANN_LOG="$ANNLOG"
cat >"$AC_HOME/config/remote-reply" <<'EOF'
#!/usr/bin/env bash
cat >>"$AC_ANN_LOG"
printf '[rid=%s]\n' "$AC_REMOTE_RID" >>"$AC_ANN_LOG"
printf '1700.1\n'
EOF
chmod +x "$AC_HOME/config/remote-reply"

# mirror=chief + no thread file -> ONE START post; the thread is now registered.
printf 'chief\n' >"$AC_HOME/config/remote-mirror"
room_seed ann-a
: >"$ANNLOG"
"$BIN/ac-spawn.sh" --roomchief ann-a --harness fake >/dev/null 2>&1
assert_file "$AC_HOME/state/remote-threads/ann-a.thread" "START post registers the family thread"
assert_contains "$(cat "$ANNLOG")" "[START] [ann-a]" "code-owned START header posted"
case "$(cat "$ANNLOG")" in *"•"*) fail "graceful minimal body: header only when the room carries no ORDER and the backlog has nothing" ;; esac
assert_contains "$(cat "$ANNLOG")" "[rid=ann-a]" "posted into the family's own thread"
"$BIN/ac-teardown.sh" ann-a-chief >/dev/null 2>&1

# A pre-existing thread file -> NO double-post (the idempotency marker).
mkdir -p "$AC_HOME/state/remote-threads"
printf 'thread_ts=1699.9\ncursor=1699.9\n' >"$AC_HOME/state/remote-threads/ann-b.thread"
room_seed ann-b
: >"$ANNLOG"
"$BIN/ac-spawn.sh" --roomchief ann-b --harness fake >/dev/null 2>&1
assert_eq "$(cat "$ANNLOG")" "" "a pre-existing thread suppresses the START post (no double-post)"
"$BIN/ac-teardown.sh" ann-b-chief >/dev/null 2>&1

# mirror=off keeps its current behavior: no thread, no post.
printf 'off\n' >"$AC_HOME/config/remote-mirror"
room_seed ann-c
: >"$ANNLOG"
"$BIN/ac-spawn.sh" --roomchief ann-c --harness fake >/dev/null 2>&1
assert_no_file "$AC_HOME/state/remote-threads/ann-c.thread" "mirror=off posts no START"
assert_eq "$(cat "$ANNLOG")" "" "mirror=off is silent"
"$BIN/ac-teardown.sh" ann-c-chief >/dev/null 2>&1

# ORDER present: the START body OPENS with the newest ORDER from the room, so
# the thread carries what the task is - not a bare placeholder.
printf 'chief\n' >"$AC_HOME/config/remote-mirror"
"$BIN/ac-room.sh" post ann-d captain "ORDER: distinctive-order-annD open the thread with the task content" >/dev/null 2>&1
: >"$ANNLOG"
"$BIN/ac-spawn.sh" --roomchief ann-d --harness fake >/dev/null 2>&1
assert_contains "$(cat "$ANNLOG")" "[START] [ann-d]" "START header still posted with an ORDER source"
assert_contains "$(cat "$ANNLOG")" "distinctive-order-annD" "START body carries the newest ORDER text"
assert_contains "$(cat "$ANNLOG")" "• " "task content emitted as a bullet"
"$BIN/ac-teardown.sh" ann-d-chief >/dev/null 2>&1

# Fallback: no ORDER in the room, but a family backlog line -> the START body
# falls back to that line (the reliably-present source at spawn time).
printf -- '- [ ] ann-e - distinctive-backlog-annE open the thread with content (repo: agent-crew, since 2026-07-19)\n' >>"$AC_HOME/records/backlog.md"
room_seed ann-e
: >"$ANNLOG"
"$BIN/ac-spawn.sh" --roomchief ann-e --harness fake >/dev/null 2>&1
assert_contains "$(cat "$ANNLOG")" "distinctive-backlog-annE" "START body falls back to the family's backlog line"
"$BIN/ac-teardown.sh" ann-e-chief >/dev/null 2>&1

# Regression (bug adc178e): an ORDER longer than 320 chars makes `cut -c1-320`
# genuinely truncate, so the `ann_snip="${ann_cut}…"` branch actually fires.
# Pre-fix that line read `"$ann_cut…"` - a bare $var glued to the multibyte
# ellipsis, which under a UTF-8 ctype bash reads as the identifier
# `ann_cut<byte>` (unbound) and aborts the spawn under set -u BEFORE the
# announce. ann-d/ann-e use short snippets, so they never enter this branch -
# that gap is how the bug shipped green. The invocation MUST force a UTF-8
# locale: helpers.sh pins none, and under LC_ALL=C the byte is not an
# identifier char, so the test would pass even on the broken code.
annF_order="ORDER: distinctive-order-annF this order is deliberately far longer than three hundred and twenty characters so that the cut c1 320 step genuinely truncates the snippet and the truncated assignment branch that appends the ellipsis actually fires which is the exact code path that shipped broken and had to be hand delivered twice today"
"$BIN/ac-room.sh" post ann-f captain "$annF_order" >/dev/null 2>&1
: >"$ANNLOG"
LC_ALL=en_US.UTF-8 "$BIN/ac-spawn.sh" --roomchief ann-f --harness fake >/dev/null 2>&1 || true
assert_file "$AC_HOME/state/remote-threads/ann-f.thread" "long ORDER: spawn completes past the announce (pre-fix it died on the unbound var)"
assert_contains "$(cat "$ANNLOG")" "[START] [ann-f]" "long ORDER: START header posted (pre-fix the spawn aborted before this)"
# The cut fired AND `${ann_cut}…` was assigned: the body bullet ends with the ellipsis.
annF_body="$(grep '^•' "$ANNLOG" | tail -n 1)"
case "$annF_body" in *…) ;; *) fail "long ORDER: announce body must end with the ellipsis (cut fired + \${ann_cut}… assigned): got '$annF_body'" ;; esac
"$BIN/ac-teardown.sh" ann-f-chief >/dev/null 2>&1

rm -f "$AC_HOME/config/remote-reply" "$AC_HOME/config/remote-mirror"

# Promote: derived id, no brief required, no worktree lease, room receipt.
room_seed fam1
out="$("$BIN/ac-spawn.sh" --roomchief fam1 --harness fake 2>/dev/null)"
assert_contains "$out" "spawned fam1-chief" "derived id"
assert_contains "$out" "kind=roomchief" "kind"
assert_contains "$out" "scope=fam1" "scope printed"
assert_eq "$(awk -F= '$1=="kind"{print $2}' "$AC_HOME/state/fam1-chief.meta")" "roomchief" "meta kind"
assert_contains "$(cat "$AC_HOME/data/fam1/room.md")" "PROMOTED" "room receipt"
[ -d "$AC_HOME/projects" ] && [ -z "$(ls "$AC_HOME/projects" 2>/dev/null)" ] || true

# The fake pane is a file the spawn wrote SYNCHRONOUSLY: launch line and
# kickoff prompt sit in the buffer verbatim, so content asserts read it
# directly. (The old tmux backend needed a 30s render poll and could only
# capture the %q-escaped launch-line copy - both were pty races, gone with
# the backend.)
buf="$(cat "$(fake_pane_buf fam1-chief)")"
assert_contains "$buf" \
  "You are the ROOMCHIEF of family fam1" "kickoff prompt content"
# The Slack narrative duty rides the per-fleet flag (default off): no flag,
# no thread-post clause in the charter; remote-mirror=chief adds it.
case "$buf" in *"thread-post fam1"*) fail "the Slack duty must stay out of the charter while the flag is off" ;; esac
printf 'chief\n' >"$AC_HOME/config/remote-mirror"
room_seed fam9
"$BIN/ac-spawn.sh" --roomchief fam9 --harness fake >/dev/null 2>&1
assert_contains "$(cat "$(fake_pane_buf fam9-chief)")" \
  "thread-post fam9" "remote-mirror=chief puts the Slack duty into the charter"
assert_contains "$(cat "$(fake_pane_buf fam9-chief)")" \
  "done-stamp fam9" "the charter wires the landing done-stamp so the guard is a backstop, not the path"
rm -f "$AC_HOME/config/remote-mirror"
assert_contains "$buf" \
  "debrief the family" "kickoff prompt orders the pre-handback debrief"
assert_contains "$buf" \
  "handback fam1" "kickoff prompt carries the handback verb"
# The arm instruction computes the watch set (its own family + in-flight
# stories) instead of a bare single-family AC_WATCH_ONLY=$fam, so an epic
# roomchief's scoped watcher covers its story crewmate panes
# (epic-roomchief-watch-only-omits-story-ids). The command substitution must
# reach the pane LITERAL (the roomchief runs it each re-arm), not be expanded
# by the spawn.
assert_contains "$buf" \
  'AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set fam1) bin/ac-watch.sh' \
  "kickoff prompt arms the watcher with the computed story set"
# The launch line pins the home: a fresh pane shell inherits nothing from the
# crewchief, and without AC_HOME a roomchief resolves NO data/ at all -
# ac_home refuses an unset AC_HOME (ac-lib.sh, ac_home).
assert_contains "$buf" \
  "AC_HOME=" "launch line pins AC_HOME for the fresh shell"
# The codegraph front-load prompt-hook kill-switch: the roomchief kickoff mandate
# is the fleet prompt that actually pays the hook's whole-tree query (measured
# 161.72s against Claude Code's 30s hook budget), so the pane must launch with it.
assert_contains "$buf" \
  "CODEGRAPH_NO_PROMPT_HOOK=1" "launch line disarms the codegraph prompt hook"

# --- crew-dispatch panes.roomchief: harness resolution -------------------------
# The roomchief branch used to resolve its harness DIRECTLY from
# config/crew-harness, bypassing crew-dispatch.json entirely - the branch
# exit 0's long before the crew path's ac_resolve_profile call, so the
# dispatch table was UNREACHABLE for a chief. It now consults the KEYED
# panes.roomchief profile (ac-dispatch-select.sh --pane roomchief), mirroring
# bin/ac-gate.sh's panes.gate resolution (roomchief-spawn-bypasses-crew-dispatch).

# (1) panes.roomchief present with a harness -> that harness wins, with NO
# --harness flag on the spawn. codex (not the config/crew-harness default of
# claude) so a spawn that never reads the profile fails this on the harness
# alone. model/effort in the profile are IGNORED (scope bound, matching the
# crewmate path): codex records a model in the meta if one is read, and none
# is, since neither --model nor config/model is set.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"roomchief": {"harness": "codex", "model": "profile-model", "effort": "high"}}}
EOF
room_seed dpk1
"$BIN/ac-spawn.sh" --roomchief dpk1 >/dev/null 2>&1
assert_eq "$(awk -F= '$1=="harness"{print $2}' "$AC_HOME/state/dpk1-chief.meta")" "codex" \
  "panes.roomchief's harness is picked with no --harness flag"
assert_eq "$(awk -F= '$1=="model"{print $2}' "$AC_HOME/state/dpk1-chief.meta")" "" \
  "panes.roomchief's model is ignored (harness-only, matching the crewmate path)"
"$BIN/ac-teardown.sh" dpk1-chief >/dev/null 2>&1

# (2) an explicit --harness still wins outright over a configured
# panes.roomchief (the profile above names codex).
room_seed dpk2
"$BIN/ac-spawn.sh" --roomchief dpk2 --harness fake >/dev/null 2>&1
assert_eq "$(awk -F= '$1=="harness"{print $2}' "$AC_HOME/state/dpk2-chief.meta")" "fake" \
  "--harness wins over a configured panes.roomchief"
"$BIN/ac-teardown.sh" dpk2-chief >/dev/null 2>&1
rm -f "$AC_HOME/config/crew-dispatch.json"

# (3) panes.roomchief ABSENT (table present, no roomchief key) falls through to
# TODAY's behaviour unchanged: config/crew-harness, default claude. This is the
# load-bearing case - a fleet with a dispatch table but no panes.roomchief key
# sees no behaviour change from this feature landing.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"qa": {"harness": "claude"}}}
EOF
printf 'fake\n' >"$AC_HOME/config/crew-harness"
room_seed dpk3
"$BIN/ac-spawn.sh" --roomchief dpk3 >/dev/null 2>&1
assert_eq "$(awk -F= '$1=="harness"{print $2}' "$AC_HOME/state/dpk3-chief.meta")" "fake" \
  "absent panes.roomchief falls through to config/crew-harness unchanged"
"$BIN/ac-teardown.sh" dpk3-chief >/dev/null 2>&1
rm -f "$AC_HOME/config/crew-harness" "$AC_HOME/config/crew-dispatch.json"

# (4) panes.roomchief PRESENT but naming no harness DIES rather than silently
# falling back - a misconfigured profile is not an absent one (mirrors
# bin/ac-gate.sh's panes.gate handling, bin/ac-gate.sh:622-623).
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"roomchief": {"model": "sonnet"}}}
EOF
room_seed dpk4
assert_fails "$BIN/ac-spawn.sh" --roomchief dpk4
assert_no_file "$AC_HOME/state/dpk4-chief.meta" "a misconfigured panes.roomchief dies before any meta is written"
rm -f "$AC_HOME/config/crew-dispatch.json"

# (5) EVIDENCE: the real Learning-shaped call - --system-initiated with NO
# --harness at all (bin/ac-learn.sh:1583's exact shape) - against a ROUTED
# panes.roomchief carrying the now-MANDATORY `default` (captain ruling
# 2026-07-28, routed-pane-rules-for-gate-codereview-roomchief). It must
# resolve the default DETERMINISTICALLY and must NOT die: this is precisely
# the caller the mandatory default exists to serve - no agent anywhere in the
# loop to read the routed rule's `when` clause.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "panes": {
    "roomchief": {
      "rules": [
        {"when": "a captain-initiated promote with an agent in the loop",
         "use": {"harness": "claude"}, "why": "n/a for this test"}
      ],
      "default": {"harness": "fake", "model": "ignored", "effort": "ignored"}
    }
  }
}
EOF
room_seed dpk5
"$BIN/ac-spawn.sh" --roomchief dpk5 --system-initiated "bin/ac-learn.sh Learning DISTILL trigger" >/dev/null 2>&1 \
  || fail "a routed panes.roomchief with a mandatory default must not die on a --harness-less system-initiated promote"
assert_eq "$(awk -F= '$1=="harness"{print $2}' "$AC_HOME/state/dpk5-chief.meta")" "fake" \
  "the system-initiated promote resolves the routed default's harness, read back from the meta"
"$BIN/ac-teardown.sh" dpk5-chief >/dev/null 2>&1
rm -f "$AC_HOME/config/crew-dispatch.json"

# open = consented redirect: focuses the live chief; refuses unpromoted rooms.
"$BIN/ac-room.sh" open fam1 >/dev/null || fail "open must focus a live roomchief"
assert_fails "$BIN/ac-room.sh" open never-promoted

# A chief parked at a captain gate is expected-quiet: stale suppressed
# while its room has an unanswered GATE, back on once DECIDED lands.
# The subject is ac-watch's gate-parked branch and nothing else: check_fleet
# emits ONE event per pass (it returns at the first actionable id) walking
# state/*.meta in glob order, where fam1-chief sorts first - and under
# AC_STALE=0 fam1-chief (no pending gate of its own) would take the very
# pass this block asserts on. Park its meta for the block.
mv "$AC_HOME/state/fam1-chief.meta" "$TMP/fam1-chief.meta.parked"
seed_pane stq-chief pSTQ tSTQ
printf 'kind=roomchief\nbackend=herdr\n' >"$AC_HOME/state/stq-chief.meta"
# AC_SCOPE=stq stands in for the live roomchief itself (its launch line sets
# AC_SCOPE to its own family) - without it, the family-owned-receipt guard in
# cmd_post would refuse this GATE as an unscoped write into a family whose
# roomchief (stq-chief, seeded live above) is up.
AC_SCOPE=stq "$BIN/ac-room.sh" post stq chief 'GATE: plan awaiting captain' >/dev/null
out="$(AC_STALE=0 "$BIN/ac-watch.sh" --once)" || true
case "$out" in *stale:stq-chief*) fail "gate-parked chief must not go stale" ;; esac
# DECIDED is guarded too (occurrence 3) - AC_SCOPE=stq for the same reason
# as the GATE above.
AC_SCOPE=stq "$BIN/ac-room.sh" post stq captain 'DECIDED: approve' >/dev/null
out="$(AC_STALE=0 "$BIN/ac-watch.sh" --once)" || true
assert_contains "$out" "stale:stq-chief" "answered gate: stale applies again"
rm -f "$FAKE_HERDR/panes/pSTQ.buf" "$FAKE_HERDR/tabs/tSTQ" "$AC_HOME/state/.pane-stq-chief"
rm -f "$AC_HOME/state/stq-chief.meta" "$AC_HOME/state/.stale-stq-chief" \
  "$AC_HOME/state/.hash-stq-chief" "$AC_HOME/state/.change-stq-chief" \
  "$AC_HOME/state/.seen-stq-chief" "$AC_HOME/state/stq-chief.status" \
  "$AC_HOME/state"/*.status
rm -rf "$AC_HOME/state"/.wake-spool*
mv "$TMP/fam1-chief.meta.parked" "$AC_HOME/state/fam1-chief.meta"

# Demotion refused while the family flies; allowed after; DEMOTED posted.
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real fam1-spec task always has one,
# since ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/fam1/spec"
printf 'kind=scout\nbackend=herdr\nworktree=/tmp/x\nproject_dir=/tmp/x\n' >"$AC_HOME/state/fam1-spec.meta"
assert_fails "$BIN/ac-teardown.sh" fam1-chief
rm -f "$AC_HOME/state/fam1-spec.meta"

# Membership is AUTHORITATIVE, never an id prefix. An UNRELATED family whose id
# merely STARTS WITH this one blocked the demote - the distro's own fixed
# `learning` room against a `learning-curate-automation` epic - and the cascade
# (room stuck in HANDBACK, turn-end guard refusing) took a --force on a family
# with nothing unlanded. An epic STORY still blocks: it belongs by neither
# suffix rule, only by its meta fleet_scope.
printf 'kind=ship\nbackend=herdr\nworktree=/tmp/x\nproject_dir=/tmp/x\n' \
  >"$AC_HOME/state/fam1-curate-automation.meta"
printf 'kind=ship\nbackend=herdr\nworktree=/tmp/x\nproject_dir=/tmp/x\nfleet_scope=fam1\n' \
  >"$AC_HOME/state/storyx.meta"
assert_fails "$BIN/ac-teardown.sh" fam1-chief
rm -f "$AC_HOME/state/storyx.meta"
"$BIN/ac-teardown.sh" fam1-chief >/dev/null   # the prefix family alone: allowed
assert_contains "$(cat "$AC_HOME/data/fam1/room.md")" "DEMOTED" "room demotion receipt"
assert_file "$AC_HOME/state/archive/fam1-chief/meta"
rm -f "$AC_HOME/state/fam1-curate-automation.meta"

# Watcher family filters: two dead-window tasks in different families (a
# herdr meta with no pane handle IS a vanished window - nothing to seed).
# AC_WATCH_SKIP is only honored while famA's OWN scoped coverage is LIVE
# (watcher-skip-staleness, ac-watch.sh), so seed a live famA-chief + a fresh
# family beacon before the SKIP pass - else the skip is revoked and famA-x
# surfaces instead of famB-y.
printf 'kind=ship\nbackend=herdr\n' >"$AC_HOME/state/famA-x.meta"
printf 'kind=ship\nbackend=herdr\n' >"$AC_HOME/state/famB-y.meta"
seed_pane famA-chief pFAC tFAC
printf 'kind=roomchief\nbackend=herdr\n' >"$AC_HOME/state/famA-chief.meta"
date +%s >"$AC_HOME/state/.last-watcher-beat.famA"
out="$(AC_WATCH_ONLY=famA "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:famA-x" "ONLY watches its family"
rm -f "$AC_HOME/state/.gone-famA-x"
out="$(AC_WATCH_SKIP=famA "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:famB-y" "SKIP ignores a LIVE promoted family"

# The <fam>-chief pane belongs to the FLEET scope, not the family:
# ONLY=<fam> must not self-watch it, SKIP=<fam> must not hide it. Kill famA's
# scoped coverage (its chief window + beacon) so the chief pane reads gone; it
# sorts before famA-x and is fleet-scoped, so it surfaces even under SKIP=famA.
rm -f "$FAKE_HERDR/panes/pFAC.buf" "$FAKE_HERDR/tabs/tFAC" \
  "$AC_HOME/state/.pane-famA-chief" "$AC_HOME/state/.last-watcher-beat.famA" \
  "$AC_HOME/state/.skip-revoked-famA"
out="$(AC_WATCH_ONLY=famA "$BIN/ac-watch.sh" --once)"
case "$out" in *gone:famA-chief*) fail "ONLY must not self-watch the chief" ;; esac
out="$(AC_WATCH_SKIP=famA "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "gone:famA-chief" "SKIP keeps the chief on the fleet watch"

# Scope isolation end-to-end against a promoted chief with a LIVE fake pane:
# the liveness probe runs through the real backend code (backend_window_alive),
# only the CLI under it is the file-backed fake.
rm -rf "$AC_HOME/state"/.wake-spool*
seed_pane famE-chief pFE tFE
printf 'kind=roomchief\nbackend=herdr\n' >"$AC_HOME/state/famE-chief.meta"
mkdir -p "$AC_HOME/state/.wake-spool.famE"
printf '%s\treport\tfamE-t1\tdone: family work\n' "$(date +%s)" >"$AC_HOME/state/.wake-spool.famE/1.1.000000"

# While the chief's window is alive its spool is ITS OWN: the fleet leaves it.
out="$("$BIN/ac-wake-drain.sh")"
case "$out" in *"family work"*) fail "the fleet must not drain a LIVE roomchief's spool" ;; esac
assert_file "$AC_HOME/state/.wake-spool.famE/1.1.000000" "a live family's records survive the fleet drain"
assert_contains "$(AC_SCOPE=famE "$BIN/ac-wake-drain.sh")" "report famE-t1 done: family work" \
  "the roomchief drains its own spool"

# Demotion archives the chief meta and kills its window - that is exactly
# what makes the family an orphan, so the next fleet pass picks up whatever
# was still queued for it. Teardown itself never touches a wake store.
printf '%s\treport\tfamE-t2\tdone: late work\n' "$(date +%s)" >"$AC_HOME/state/.wake-spool.famE/1.1.000001"
"$BIN/ac-teardown.sh" famE-chief >/dev/null
assert_contains "$("$BIN/ac-wake-drain.sh")" "report famE-t2 done: late work" \
  "after demotion the fleet drains the family's orphaned records"
assert_eq "$(find "$AC_HOME/state/.wake-spool.famE" -type f | wc -l | tr -d ' ')" "0" \
  "the orphaned records are consumed, not stranded"

# --- orphan-window safety: the window/meta race --------------------------------
# ac-spawn runs under set -e and backend_send_line returns 1 on a strand, so a
# roomchief spawn could die AFTER its window existed and BEFORE the first byte of
# state/<id>.meta - leaving a tab NOTHING could address (ac-send.sh and
# ac-teardown.sh both key off that meta) and a retry wedged on the window
# refusal. Contract: ORPHAN-WINDOW SAFETY in bin/ac-spawn.sh.

# (1) the launch line strands: the spawn dies, and takes its own window with it.
# The drop pattern targets the LAUNCH line only (AC_SCOPE= never appears in the
# kickoff prompt), and the pane id is predicted the ac-spawn-teardown.test.sh way
# - the chiefs workspace already exists here, so the next handle is the next id.
n="$(cat "$FAKE_HERDR/.n")"; opane="p$((n + 1))"; otab="t$((n + 1))"
printf '9 AC_SCOPE=\n' >"$FAKE_HERDR/panes/$opane.drop-enters"
: >"$FAKE_HERDR/log"
room_seed orph1
assert_fails "$BIN/ac-spawn.sh" --roomchief orph1 --harness fake
assert_no_file "$AC_HOME/state/orph1-chief.meta" "a died spawn leaves no meta"
assert_contains "$(cat "$FAKE_HERDR/log")" "tab close $otab" "the trap reaps the window it created"
assert_no_file "$FAKE_HERDR/tabs/$otab" "no orphan tab survives the death"
assert_no_file "$AC_HOME/state/.pane-orph1-chief" "no orphan pane handle survives it either"

# (2) a kill -9 leaves a window no trap could ever reap. The retry REAPS it and
# recreates instead of dead-ending on 'window ... already exists' (--recover is
# crewdeputy-only, so a stranded chief tab has no recovery verb at all), and the
# meta it writes carries every key its consumers depend on.
printf 'pORPH crew:orph2-chief\n' >"$FAKE_HERDR/tabs/tORPH"
: >"$FAKE_HERDR/panes/pORPH.buf"
printf 'tORPH\n' >"$FAKE_HERDR/panes/pORPH.tab"
printf 'pORPH tORPH\n' >"$AC_HOME/state/.pane-orph2-chief"
: >"$FAKE_HERDR/log"
room_seed orph2
out="$("$BIN/ac-spawn.sh" --roomchief orph2 --harness fake 2>&1)" \
  || fail "the retry must not dead-end on the orphan window: $out"
assert_contains "$out" "spawned orph2-chief" "the retry is not wedged by the orphan window"
assert_contains "$(cat "$FAKE_HERDR/log")" "tab close tORPH" "the orphan tab is reaped before the new one opens"
assert_no_file "$FAKE_HERDR/tabs/tORPH" "the orphan tab is gone"
for k in backend window worktree project project_dir harness kind initiated_by mode spawned_at; do
  [ -n "$(awk -F= -v k="$k" '$1==k{print $2}' "$AC_HOME/state/orph2-chief.meta")" ] \
    || fail "the meta written after a reap must carry $k (its consumers key off it)"
done
assert_eq "$(awk -F= '$1=="kind"{print $2}' "$AC_HOME/state/orph2-chief.meta")" "roomchief" \
  "kind - the room-parallel cap counts on it"
assert_eq "$(awk -F= '$1=="initiated_by"{print $2}' "$AC_HOME/state/orph2-chief.meta")" "chief" \
  "initiated_by - the cap counts on it too (absent reads as chief-initiated)"
"$BIN/ac-teardown.sh" orph2-chief >/dev/null

# (3) the reap stays INSIDE the KILL OWNERSHIP PROOF (ac-backend.sh header): a
# tab no longer labelled crew:<id> is a co-tenant, and closing one has taken the
# whole chiefs workspace down three times. It is refused and warned about, and
# the spawn simply opens its own window.
printf 'pFOR crew:someone-else\n' >"$FAKE_HERDR/tabs/tFOR"
: >"$FAKE_HERDR/panes/pFOR.buf"
printf 'tFOR\n' >"$FAKE_HERDR/panes/pFOR.tab"
printf 'pFOR tFOR\n' >"$AC_HOME/state/.pane-orph3-chief"
room_seed orph3
out="$("$BIN/ac-spawn.sh" --roomchief orph3 --harness fake 2>&1)" \
  || fail "a refused reap must still spawn: $out"
assert_contains "$out" "spawned orph3-chief" "a refused reap still spawns"
assert_contains "$out" "not closing tab tFOR" "a foreign tab is refused, never closed"
assert_file "$FAKE_HERDR/tabs/tFOR" "the co-tenant's tab survives the reap attempt"
"$BIN/ac-teardown.sh" orph3-chief >/dev/null

pass
