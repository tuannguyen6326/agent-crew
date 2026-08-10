#!/usr/bin/env bash
# ac-spawn-teardown.test.sh - e2e: spawn a fake-harness crewmate into an
# in-repo worktree + herdr tab, verify fleet state, then fail-closed
# teardown (refuses unlanded branch work, --force discards).
# Driven through the fake herdr CLI (tests/helpers.sh): launch lines land
# VERBATIM in the pane buffer, nothing executes them.

# FAIL-CLOSED SOURCING (this suite pushes): run from anywhere but tests/, the
# source below no-ops, errexit is never armed, every helper var stays EMPTY -
# and `git -C "" push origin main` below then hits the REAL repo (incident
# 2026-07-20). Abort instead of running unsourced.
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
repo="$(make_repo proj)"

# A claude stub so the claude-harness spawns below pass ac-spawn's
# command -v check; the fake herdr never executes the launch line.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
chmod +x "$TMP/stub/claude"
export PATH="$TMP/stub:$PATH"

# A fake harness template; its text sits unexecuted in the pane buffer.
printf 'echo crew __ID__ reading __BRIEF__; sleep 300\n' >"$AC_HOME/config/launch-fake"

"$BIN/ac-brief.sh" t1 proj --mode local-only >/dev/null
assert_fails "$BIN/ac-spawn.sh" tX "$repo" --harness fake --mode bogus

# Mint-side grammar is [a-z0-9-] - the same charset ac-brief.sh mints, tighter
# than the loose read-path charset ([a-zA-Z0-9_-]) other tools still accept
# for an EXISTING id/family. Underscore and uppercase must be refused BEFORE
# any worktree lease or window - no meta, no pane handle.
err="$("$BIN/ac-spawn.sh" "bad_id" "$repo" --harness fake 2>&1 || true)"
assert_contains "$err" "id must be [a-z0-9-]" "underscore id refused, naming the tightened charset"
assert_no_file "$AC_HOME/state/bad_id.meta" "no meta leased for a refused id"
assert_no_file "$AC_HOME/state/.pane-bad_id" "no pane handle for a refused id"
err="$("$BIN/ac-spawn.sh" "BadId" "$repo" --harness fake 2>&1 || true)"
assert_contains "$err" "id must be [a-z0-9-]" "uppercase id refused, naming the tightened charset"
assert_no_file "$AC_HOME/state/BadId.meta" "no meta leased for a refused id"
err="$("$BIN/ac-spawn.sh" --roomchief "bad_family" --harness fake 2>&1 || true)"
assert_contains "$err" "family must be [a-z0-9-]" "underscore family refused, naming the tightened charset"
assert_no_file "$AC_HOME/state/bad_family-chief.meta" "no meta leased for a refused roomchief family"
err="$("$BIN/ac-spawn.sh" --roomchief "BadFamily" --harness fake 2>&1 || true)"
assert_contains "$err" "family must be [a-z0-9-]" "uppercase family refused, naming the tightened charset"
assert_no_file "$AC_HOME/state/BadFamily-chief.meta" "no meta leased for a refused roomchief family"
# Slack task thread: with a remote-reply hook wired AND the auto-mirror
# opted in (remote-mirror=on), spawn announces the task start into its
# family thread (thread-post; best-effort - asserted working here, and
# spawn must survive without the hook everywhere else).
printf 'on\n' >"$AC_HOME/config/remote-mirror"
export AC_SPAWN_TEST_TLOG="$TMP/spawn-thread.log"
cat >"$AC_HOME/config/remote-reply" <<'EOF'
#!/usr/bin/env bash
cat >>"$AC_SPAWN_TEST_TLOG"
printf 'rid=%s\n' "$AC_REMOTE_RID" >>"$AC_SPAWN_TEST_TLOG"
printf '1700.11\n'
EOF
chmod +x "$AC_HOME/config/remote-reply"
out="$("$BIN/ac-spawn.sh" t1 "$repo" --harness fake --mode local-only 2>/dev/null)"
assert_contains "$out" "spawned t1 harness=fake kind=ship mode=local-only" "per-task --mode overrides the registry default"
assert_contains "$(cat "$TMP/spawn-thread.log")" "] [START] [t1]*" "announce header carries ts, verb, family in brackets"
assert_contains "$(cat "$TMP/spawn-thread.log")" "bắt đầu task t1 (ship)" "spawn announced the start into the family thread (VN framing, ids verbatim)"
assert_contains "$(cat "$TMP/spawn-thread.log")" "rid=t1" "announce addressed to the family"
# A spawn from a SCOPED session (a roomchief) announces into the CHIEF's
# family thread - slice ids (<fam>-s1) are flat by the stage grammar but
# they are that family's crewmates (captain ruling 2026-07-18).
"$BIN/ac-brief.sh" lgrp-s1 proj --mode local-only >/dev/null
sout="$(AC_SCOPE=lgrp "$BIN/ac-spawn.sh" lgrp-s1 "$repo" --harness fake --mode local-only 2>/dev/null)"
assert_contains "$sout" "spawned lgrp-s1" "scoped slice spawn succeeds"
assert_contains "$(cat "$TMP/spawn-thread.log")" "rid=lgrp" "scoped spawn announces into the chief's family thread"
assert_contains "$(cat "$TMP/spawn-thread.log")" "] [START] [lgrp]*" "announce header names the chief family, not the slice id"
# Give the slot back and drop the fixture task so the pool numbering the
# later sections assert on stays untouched.
"$BIN/ac-tree.sh" return "${sout##*worktree=}" --force 2>/dev/null
rm -f "$AC_HOME/state/lgrp-s1.meta" "$AC_HOME/state/lgrp-s1.status" "$AC_HOME/state/.pane-lgrp-s1"
rm -f "$AC_HOME/config/remote-reply" "$AC_HOME/config/remote-mirror"
# Custom launch template (config/launch-fake exists) keeps AC_PROMPT on the
# launch line; the tty-1024 guard only strips it for BUILT-IN templates.
assert_contains "$(cat "$(fake_pane_buf t1)")" "AC_PROMPT=" "custom template keeps AC_PROMPT"
assert_contains "$out" "worktree=$repo/.crew/worktrees/1" "in-repo worktree"

meta="$AC_HOME/state/t1.meta"
assert_file "$meta"
assert_file "$AC_HOME/state/.pane-t1" "pane handle recorded (window alive)"
assert_contains "$("$BIN/ac-tree.sh" list --repo "$repo")" "leased" "lease recorded"

# AC3: the kickoff prompt lands as its OWN typed line (literal spaces), after
# the bare launch line. The launch line only carries the escaped AC_PROMPT=
# value (backslash-escaped spaces), so a real-spaces match can only be the
# separately delivered prompt line.
assert_contains "$(cat "$(fake_pane_buf t1)")" \
  "You are an agent-crew crewmate. Read and follow the brief" "kickoff prompt delivered as its own line"

assert_fails "$BIN/ac-spawn.sh" t1 "$repo" --harness fake

# Unlanded branch work blocks teardown; --force discards and cleans up.
wt="$(awk -F= '$1=="worktree"{print $2}' "$meta")"
git -C "$wt" checkout -q -b crew/t1
printf 'work\n' >"$wt/work.txt"
git -C "$wt" add -A
git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "unlanded work"
assert_fails "$BIN/ac-teardown.sh" t1
"$BIN/ac-teardown.sh" t1 --force >/dev/null
assert_no_file "$meta" "meta archived"
assert_file "$AC_HOME/state/archive/t1/meta"
assert_no_file "$AC_HOME/state/.pane-t1" "window survived teardown"
assert_contains "$("$BIN/ac-tree.sh" list --repo "$repo")" "available" "worktree back in pool"

# claude spawns pin a session id in the meta; --resume-from reopens it
# (the claude stub above only satisfies the command -v check).
# Slot-affinity setup: pin slot 1 under another lease so t2 lands in slot 2 -
# the resume assertions below must distinguish "old slot" from "first free
# slot" (normal selection would hand out slot 1).
hold="$("$BIN/ac-tree.sh" get --repo "$repo" --id hold 2>/dev/null)"
assert_eq "$hold" "$repo/.crew/worktrees/1" "hold pins slot 1"
"$BIN/ac-brief.sh" t2 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t2 "$repo" --harness claude >/dev/null 2>&1
assert_eq "$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t2.meta")" \
  "$repo/.crew/worktrees/2" "t2 leased slot 2"
sid="$(awk -F= '$1=="session_id"{print $2}' "$AC_HOME/state/t2.meta")"
[ -n "$sid" ] || fail "claude spawn must record session_id"
grep -q -- "--session-id $sid" "$(fake_pane_buf t2)" || fail "launch line pins the session id"
"$BIN/ac-teardown.sh" t2 --force >/dev/null 2>&1
"$BIN/ac-tree.sh" return "$hold" 2>/dev/null

# Resume lands in the OLD slot (claude keys sessions by cwd): slots 1 and 2
# are both free and normal selection would pick 1, but the resume must
# reclaim slot 2 where t2's session lives.
"$BIN/ac-brief.sh" t2-r2 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t2-r2 "$repo" --resume-from t2 >/dev/null 2>&1
sid2="$(awk -F= '$1=="session_id"{print $2}' "$AC_HOME/state/t2-r2.meta")"
assert_eq "$sid2" "$sid" "revision resumes the same session"
assert_eq "$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t2-r2.meta")" \
  "$repo/.crew/worktrees/2" "resume lands in the old slot (cwd affinity)"
grep -q -- "--resume $sid" "$(fake_pane_buf t2-r2)" || fail "resume launch line"
"$BIN/ac-teardown.sh" t2-r2 --force >/dev/null 2>&1

# Per-role pane-agent knobs thread onto the crewmate launch line so its homeless
# codereview/qa panes can read config/<role>-<knob> (which config/ cannot resolve
# in a crewmate). Only emitted when the fleet pins them. All THREE knobs per role
# ride together (captain 2026-07-28, routed-pane-rules-for-gate-codereview-
# roomchief TASK 2): an agent pin whose model/effort stayed behind would let the
# pane compose a model onto a harness the knob did not choose.
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
printf 'sonnet\n' >"$AC_HOME/config/codereview-model"
printf 'xhigh\n' >"$AC_HOME/config/codereview-effort"
printf 'claude\n' >"$AC_HOME/config/qa-agent"
printf 'haiku\n' >"$AC_HOME/config/qa-model"
printf 'low\n' >"$AC_HOME/config/qa-effort"
"$BIN/ac-brief.sh" tmr proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tmr "$repo" --harness claude >/dev/null 2>&1
mrbuf="$(cat "$(fake_pane_buf tmr)")"
case "$mrbuf" in *"AC_FLEET_AGENT_CODEREVIEW=codex"*) ;; *) fail "config/codereview-agent must thread as AC_FLEET_AGENT_CODEREVIEW" ;; esac
case "$mrbuf" in *"AC_FLEET_MODEL_CODEREVIEW=sonnet"*) ;; *) fail "config/codereview-model must thread as AC_FLEET_MODEL_CODEREVIEW" ;; esac
case "$mrbuf" in *"AC_FLEET_EFFORT_CODEREVIEW=xhigh"*) ;; *) fail "config/codereview-effort must thread as AC_FLEET_EFFORT_CODEREVIEW" ;; esac
case "$mrbuf" in *"AC_FLEET_AGENT_QA=claude"*) ;; *) fail "config/qa-agent must thread as AC_FLEET_AGENT_QA" ;; esac
case "$mrbuf" in *"AC_FLEET_MODEL_QA=haiku"*) ;; *) fail "config/qa-model must thread as AC_FLEET_MODEL_QA" ;; esac
case "$mrbuf" in *"AC_FLEET_EFFORT_QA=low"*) ;; *) fail "config/qa-effort must thread as AC_FLEET_EFFORT_QA" ;; esac
"$BIN/ac-teardown.sh" tmr --force >/dev/null 2>&1
rm -f "$AC_HOME/config/codereview-agent" "$AC_HOME/config/codereview-model" \
      "$AC_HOME/config/codereview-effort" "$AC_HOME/config/qa-agent" \
      "$AC_HOME/config/qa-model" "$AC_HOME/config/qa-effort"

# A fleet pinning NONE of them leaves the launch line free of every per-role
# rung - the byte-identical no-change property for a fleet that configures
# nothing (both real fleets today: neither key set on drydock or lab).
"$BIN/ac-brief.sh" tmr0 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tmr0 "$repo" --harness claude >/dev/null 2>&1
case "$(cat "$(fake_pane_buf tmr0)")" in
  *AC_FLEET_AGENT_*|*AC_FLEET_MODEL_CODEREVIEW*|*AC_FLEET_MODEL_QA*|*AC_FLEET_EFFORT_CODEREVIEW*|*AC_FLEET_EFFORT_QA*)
    fail "an unpinned fleet must thread no per-role rung at all" ;;
esac
"$BIN/ac-teardown.sh" tmr0 --force >/dev/null 2>&1

# The DISPATCHED pane profile threads on that same rung, and for the harder
# version of the same reason: ac-ship.sh review-agent and ac-qa.sh agent are
# themselves homeless, so nobody downstream can resolve it. A fleet that
# configures no panes block must leave this launch line byte-identical.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"rules": [{"when": "anything", "use": {"harness": "claude"}}]}
EOF
"$BIN/ac-brief.sh" tnp proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tnp "$repo" --harness claude >/dev/null 2>&1
case "$(cat "$(fake_pane_buf tnp)")" in
  *AC_FLEET_PROFILE_*) fail "no panes block must thread no profile at all" ;;
esac
"$BIN/ac-teardown.sh" tnp --force >/dev/null 2>&1

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"harness": "claude", "model": "opus"},
           "qa": {"harness": "claude"},
           "learning": {"harness": "claude", "model": "haiku"}}}
EOF
"$BIN/ac-brief.sh" tpp proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tpp "$repo" --harness claude >/dev/null 2>&1
ppbuf="$(cat "$(fake_pane_buf tpp)")"
case "$ppbuf" in *"AC_FLEET_PROFILE_CODEREVIEW=harness=claude"*) ;; *) fail "panes.codereview must thread as AC_FLEET_PROFILE_CODEREVIEW" ;; esac
case "$ppbuf" in *"AC_FLEET_PROFILE_QA=harness=claude"*) ;; *) fail "panes.qa must thread as AC_FLEET_PROFILE_QA" ;; esac
# The learning scout is HOMED - it reads the block first-hand - so threading it
# would be a rung nobody reads, carried on every crewmate launch line.
case "$ppbuf" in *AC_FLEET_PROFILE_LEARNING*) fail "a homed kind needs no threaded rung" ;; esac
"$BIN/ac-teardown.sh" tpp --force >/dev/null 2>&1
rm -f "$AC_HOME/config/crew-dispatch.json"

# --codereview-rule pins a ROUTED panes.codereview deliberately at spawn time
# (captain decision 2026-07-28, routed-pane-rules-for-gate-codereview-
# roomchief: the chief is the only actor ever in a position to judge a `when`
# clause here, since an execution crewmate never gets AC_HOME). Read back
# from the REAL launch line, not inferred.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "panes": {
    "codereview": {
      "rules": [
        {"when": "financial or irreversible risk",
         "use": {"harness": "claude", "model": "opus", "effort": "xhigh"},
         "why": "max reasoning"},
        {"when": "routine review", "use": {"harness": "claude", "model": "sonnet"},
         "why": "cheaper routine review"}
      ],
      "default": {"harness": "claude", "model": "haiku"}
    }
  }
}
EOF
"$BIN/ac-brief.sh" tcr1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tcr1 "$repo" --harness claude --codereview-rule 1 >/dev/null 2>&1
cr1buf="$(cat "$(fake_pane_buf tcr1)")"
case "$cr1buf" in *"AC_FLEET_PROFILE_CODEREVIEW=harness=claude"*) ;; *) fail "--codereview-rule 1 must pin rule 1's harness onto AC_FLEET_PROFILE_CODEREVIEW" ;; esac
case "$cr1buf" in *"model=opus"*) ;; *) fail "--codereview-rule 1 must pin rule 1's model" ;; esac
case "$cr1buf" in *"effort=xhigh"*) ;; *) fail "--codereview-rule 1 must pin rule 1's effort, not the mandatory default's" ;; esac
"$BIN/ac-teardown.sh" tcr1 --force >/dev/null 2>&1

# --codereview-rule default is an explicit selection, equal to the no-flag
# fallback (the mandatory default) - proven by comparing both launch lines.
"$BIN/ac-brief.sh" tcr2 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tcr2 "$repo" --harness claude --codereview-rule default >/dev/null 2>&1
cr2buf="$(cat "$(fake_pane_buf tcr2)")"
case "$cr2buf" in *"AC_FLEET_PROFILE_CODEREVIEW=harness=claude"*) ;; *) fail "--codereview-rule default must pin the mandatory default's harness onto AC_FLEET_PROFILE_CODEREVIEW" ;; esac
case "$cr2buf" in *"model=haiku"*) ;; *) fail "--codereview-rule default must pin the mandatory default's model" ;; esac
"$BIN/ac-teardown.sh" tcr2 --force >/dev/null 2>&1

"$BIN/ac-brief.sh" tcr3 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" tcr3 "$repo" --harness claude >/dev/null 2>&1
cr3buf="$(cat "$(fake_pane_buf tcr3)")"
# Same two fields asserted on cr2buf above (--codereview-rule default) - no
# flag at all must resolve the SAME mandatory default, not something else.
case "$cr3buf" in *"AC_FLEET_PROFILE_CODEREVIEW=harness=claude"*) ;; *) fail "no --codereview-rule must still pin the mandatory default's harness" ;; esac
case "$cr3buf" in *"model=haiku"*) ;; *) fail "no --codereview-rule must resolve the same mandatory default as --codereview-rule default" ;; esac
"$BIN/ac-teardown.sh" tcr3 --force >/dev/null 2>&1

# A wrong selector DIES before any window/meta is opened - never a silent
# fall-through to the default the caller did not ask for.
"$BIN/ac-brief.sh" tcr4 proj --mode local-only >/dev/null
assert_fails "$BIN/ac-spawn.sh" tcr4 "$repo" --harness claude --codereview-rule 9
assert_no_file "$AC_HOME/state/tcr4.meta" "an unresolvable --codereview-rule must die before any meta is written"
rm -f "$AC_HOME/config/crew-dispatch.json"

# --codereview-rule with NO panes.codereview at all is equally a wrong
# request, not a silent no-op: nothing to select from.
"$BIN/ac-brief.sh" tcr5 proj --mode local-only >/dev/null
assert_fails "$BIN/ac-spawn.sh" tcr5 "$repo" --harness claude --codereview-rule 1
assert_no_file "$AC_HOME/state/tcr5.meta" "--codereview-rule against an absent panes.codereview must die, not thread nothing silently"

# --codereview-rule requires a plain crew spawn - it resolves panes.codereview,
# which only ever threads to an execution crewmate.
assert_fails "$BIN/ac-spawn.sh" --roomchief tcr6 --codereview-rule 1
assert_no_file "$AC_HOME/state/tcr6-chief.meta" "--codereview-rule on a roomchief promote must die before any meta is written"

# A separate ship crewmate is no longer a normal execution surface. Delivery
# stays with the execution crewmate, so the old model-ship spawn selector is
# rejected instead of creating a third production role.
printf 'sonnet\n' >"$AC_HOME/config/model-ship"
"$BIN/ac-brief.sh" tship proj --mode local-only >/dev/null
assert_fails "$BIN/ac-spawn.sh" tship "$repo" --harness claude --stage ship
rm -f "$AC_HOME/config/model-ship"

# Affinity miss: the old slot is leased by someone else, so the resume falls
# back to another slot and warns loudly that the session cwd changed.
hold2="$("$BIN/ac-tree.sh" get --repo "$repo" --id hold2 --prefer 2 2>/dev/null)"
assert_eq "$hold2" "$repo/.crew/worktrees/2" "hold2 pins the old slot"
"$BIN/ac-brief.sh" t2-r3 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" t2-r3 "$repo" --resume-from t2 2>&1)"
assert_contains "$out" \
  "resume may not find the old session (cwd changed: $repo/.crew/worktrees/2 -> $repo/.crew/worktrees/1)" \
  "affinity miss warns loudly"
assert_eq "$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t2-r3.meta")" \
  "$repo/.crew/worktrees/1" "affinity miss fell back to a free slot"
"$BIN/ac-teardown.sh" t2-r3 --force >/dev/null 2>&1
"$BIN/ac-tree.sh" return "$hold2" 2>/dev/null

# Fresh-fallback guard: resuming a non-claude task refuses loudly.
assert_fails "$BIN/ac-spawn.sh" t3 "$repo" --resume-from t1

# A spawn that dies after leasing gives the lease back (no leaked slot).
# Simulate an already-live t4 window: pane handle + live fake pane files.
printf 'p90 t90\n' >"$AC_HOME/state/.pane-t4"
printf 'p90\n' >"$FAKE_HERDR/tabs/t90"
: >"$FAKE_HERDR/panes/p90.buf"
"$BIN/ac-brief.sh" t4 proj --mode local-only >/dev/null
assert_fails "$BIN/ac-spawn.sh" t4 "$repo" --harness fake
assert_no_file "$AC_HOME/state/t4.meta" "no half-written meta"
"$BIN/ac-tree.sh" list --repo "$repo" | grep -q 'leased.*t4' && fail "leaked leased slot for t4"
rm -f "$AC_HOME/state/.pane-t4" "$FAKE_HERDR/tabs/t90" "$FAKE_HERDR/panes/p90.buf"

# Staged-flow layout: a --stage brief nests under the family; spawn resolves
# it, hands the crewmate the NESTED path, and the scout teardown fail-closed
# check looks for the report next to that brief.
"$BIN/ac-brief.sh" t5-spec proj --mode local-only --stage spec --captain-requested 'test fixture: staged pinned by the captain' --reason 'fixture: exercising the staged path' >/dev/null
assert_file "$AC_HOME/data/t5/spec/brief.md"
"$BIN/ac-spawn.sh" t5-spec "$repo" --scout --harness fake >/dev/null 2>&1
assert_contains "$(cat "$(fake_pane_buf t5-spec)")" \
  "data/t5/spec/brief.md" "spawn hands the crewmate the nested brief path"
assert_fails "$BIN/ac-teardown.sh" t5-spec          # scout, no report yet
printf 'findings\n' >"$AC_HOME/data/t5/spec/report.md"
"$BIN/ac-teardown.sh" t5-spec >/dev/null            # nested report satisfies fail-closed
assert_file "$AC_HOME/state/archive/t5-spec/meta"

# Merged-design teardown: a --stage design scout keeps its ONE brief at
# <family>/design/ but writes each sub-stage report at
# <family>/{spec,arch,plan}/report.md - never design/report.md. The scout proof
# must accept those sub-stage reports; checking only design/report.md
# mis-detected the layout and refused a fully-delivered design (backlog flag).
"$BIN/ac-brief.sh" md-design proj --mode local-only --stage design --captain-requested 'test fixture: staged pinned by the captain' --reason 'fixture: exercising the staged path' >/dev/null
assert_file "$AC_HOME/data/md/design/brief.md"
"$BIN/ac-spawn.sh" md-design "$repo" --scout --harness fake >/dev/null 2>&1
assert_fails "$BIN/ac-teardown.sh" md-design        # no sub-stage report yet
mkdir -p "$AC_HOME/data/md/arch"
printf 'arch findings\n' >"$AC_HOME/data/md/arch/report.md"
"$BIN/ac-teardown.sh" md-design >/dev/null          # a sub-stage report satisfies fail-closed
assert_file "$AC_HOME/state/archive/md-design/meta"

# Scout backstop: a scout steered into writing code holds commits on
# crew/<id> inside its worktree; even with the report in place, teardown
# refuses until ac-promote.sh flips it to ship (then ship rules apply) or
# the captain discards with --force.
"$BIN/ac-brief.sh" t6 proj --scout >/dev/null
"$BIN/ac-spawn.sh" t6 "$repo" --scout --harness fake >/dev/null 2>&1
printf 'findings\n' >"$AC_HOME/data/t6/report.md"
wt6="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t6.meta")"
git -C "$wt6" checkout -q -b crew/t6
printf 'code\n' >"$wt6/code.txt"
git -C "$wt6" add -A
git -C "$wt6" -c user.email=t@t -c user.name=t commit -qm "scout wrote code"
out="$("$BIN/ac-teardown.sh" t6 2>&1)" && fail "teardown must refuse a scout with an unlanded crew branch"
assert_contains "$out" "ac-promote.sh t6" "refusal points at promote"
out="$("$BIN/ac-promote.sh" t6 --mode local-only)"
assert_contains "$out" "notified crewmate t6" "live pane gets the ship notice"
assert_eq "$(awk -F= '$1=="kind"{v=$2} END{print v}' "$AC_HOME/state/t6.meta")" "ship" "promote flips kind in place"
assert_fails "$BIN/ac-teardown.sh" t6              # ship rules: branch still unlanded
"$BIN/ac-teardown.sh" t6 --force >/dev/null
assert_file "$AC_HOME/state/archive/t6/meta"

# The same backstop one step earlier: work a steered scout EDITED but never
# committed dies just as silently at the pool return (ac-tree.sh resets the
# tree), so the scout proof mirrors the ship sibling's dirty-tree refusal.
"$BIN/ac-brief.sh" t22 proj --scout >/dev/null
"$BIN/ac-spawn.sh" t22 "$repo" --scout --harness fake >/dev/null 2>&1
printf 'findings\n' >"$AC_HOME/data/t22/report.md"
wt22="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t22.meta")"
printf 'scratch code\n' >"$wt22/uncommitted.txt"
out="$("$BIN/ac-teardown.sh" t22 2>&1)" && fail "teardown must refuse a scout holding uncommitted work"
assert_contains "$out" "worktree is dirty" "the refusal names the dirty tree, like the ship sibling"
assert_file "$AC_HOME/state/t22.meta" "a refused scout stays in flight"
# The let-through direction: a delivered scout with a clean tree still lands.
rm -f "$wt22/uncommitted.txt"
"$BIN/ac-teardown.sh" t22 >/dev/null
assert_file "$AC_HOME/state/archive/t22/meta"

# --- kickoff acknowledgement: a booting TUI drops Enters; spawn re-SUBMITS ------
# (never re-types) until the render reacts - the 2026-07-16 eaten-kickoff was
# two blind sends appending into one garbled line. The drop knob targets the
# PROMPT only ("crewmate" never appears on the claude launch line), so the
# launch line submits normally and only the kickoff strands.
n="$(cat "$FAKE_HERDR/.n")"; kpane="p$((n + 1))"
# 3 drops: send_line burns its two verified submits (plain + focused), the
# kickoff's first resubmit still strands, its second lands.
printf '3 crewmate\n' >"$FAKE_HERDR/panes/$kpane.drop-enters"
"$BIN/ac-brief.sh" t7 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" t7 "$repo" --harness claude 2>&1)"
assert_contains "$out" "spawned t7" "spawn survives dropped kickoff Enters"
case "$out" in *"NOT acknowledged"*) fail "a recovered kickoff must not warn" ;; esac
assert_eq "$(grep -c "You are an agent-crew crewmate" "$(fake_pane_buf t7)")" "1" \
  "kickoff resubmit lands the prompt exactly once (no re-type, no garble)"
"$BIN/ac-teardown.sh" t7 --force >/dev/null 2>&1

# never acknowledged: spawn still completes, warns LOUDLY, names the ac-send
# fallback - and the prompt honestly sits in the composer, not in the transcript.
n="$(cat "$FAKE_HERDR/.n")"; kpane="p$((n + 1))"
printf '99 crewmate\n' >"$FAKE_HERDR/panes/$kpane.drop-enters"
"$BIN/ac-brief.sh" t8 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" t8 "$repo" --harness claude 2>&1)"
assert_contains "$out" "spawned t8" "spawn must not die on an unacknowledged kickoff"
assert_contains "$out" "kickoff prompt NOT acknowledged" "unacknowledged kickoff warns loudly"
assert_contains "$out" "ac-send.sh t8" "warning names the manual fallback"
assert_contains "$(cat "$FAKE_HERDR/panes/$kpane.in")" "You are an agent-crew crewmate" \
  "prompt sits stranded in the composer, reported not hidden"
case "$(cat "$(fake_pane_buf t8)")" in *"You are an agent-crew crewmate"*) \
  fail "an unacknowledged prompt must not appear submitted" ;; esac
"$BIN/ac-teardown.sh" t8 --force >/dev/null 2>&1

# The UNSUFFIXED staged implement id resolves through the existence probe:
# spawn must hand the crewmate data/t5/implement/brief.md, not data/t5/brief.md.
"$BIN/ac-brief.sh" t5 proj --mode local-only --stage implement --captain-requested 'test fixture: staged pinned by the captain' --reason 'fixture: exercising the staged path' >/dev/null
assert_file "$AC_HOME/data/t5/implement/brief.md"
"$BIN/ac-spawn.sh" t5 "$repo" --harness fake >/dev/null 2>&1
assert_contains "$(cat "$(fake_pane_buf t5)")" \
  "data/t5/implement/brief.md" "spawn resolves the unsuffixed staged implement brief"
"$BIN/ac-teardown.sh" t5 --force >/dev/null 2>&1

# --- landed proof spans BOTH default refs (local and origin) -------------------
# A local-only project never pushes: its landing is a ff-merge into LOCAL main,
# which leaves origin/main stale. Proving containment in origin/main alone
# reported such work as unlanded and forced every teardown through --force.
oremote="$TMP/proj9-origin.git"
git init -q --bare -b main "$oremote"
repo9="$(make_repo proj9)"
git -C "$repo9" remote add origin "$oremote"
git -C "$repo9" push -q origin main
git -C "$repo9" fetch -q origin

# t9: local-only - local main is AHEAD of origin/main and contains the head.
"$BIN/ac-brief.sh" t9 proj9 --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t9 "$repo9" --harness fake --mode local-only >/dev/null 2>&1
wt9="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t9.meta")"
git -C "$wt9" checkout -q -b crew/t9
printf 'landed locally\n' >"$wt9/local.txt"
git -C "$wt9" add -A
git -C "$wt9" -c user.email=t@t -c user.name=t commit -qm "local-only work"
git -C "$repo9" merge -q --ff-only crew/t9
git -C "$repo9" merge-base --is-ancestor crew/t9 origin/main 2>/dev/null \
  && fail "fixture broken: origin/main must NOT contain the head"
"$BIN/ac-teardown.sh" t9 >/dev/null || fail "local-only landed work needs no --force"
assert_file "$AC_HOME/state/archive/t9/meta"

# t10: push mode - only ORIGIN contains the head; local main stays behind.
# The brief IS the mode record now: spawn refuses a flag that contradicts it
# (delivery-contract-on-the-row), so the brief carries direct-pr from the
# start and spawn simply agrees.
"$BIN/ac-brief.sh" t10 proj9 --mode direct-pr >/dev/null
"$BIN/ac-spawn.sh" t10 "$repo9" --harness fake --mode direct-pr >/dev/null 2>&1
wt10="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t10.meta")"
git -C "$wt10" checkout -q -b crew/t10
printf 'pushed work\n' >"$wt10/pushed.txt"
git -C "$wt10" add -A
git -C "$wt10" -c user.email=t@t -c user.name=t commit -qm "push-mode work"
git -C "$repo9" push -q origin crew/t10:main
git -C "$repo9" fetch -q origin
git -C "$repo9" merge-base --is-ancestor crew/t10 main 2>/dev/null \
  && fail "fixture broken: local main must NOT contain the head"
# The landed proof and `git branch -d` are DIFFERENT tests, so this same
# fixture is also where they legitimately disagree: the proof accepts origin
# containment, while -d checks the project repo's own HEAD - still behind. The
# delete therefore REFUSES here, and that refusal must be REPORTED: teardown
# used to print `complete` while the branch survived with nothing said.
err10="$("$BIN/ac-teardown.sh" t10 2>&1 >"$TMP/t10.out")" \
  || fail "origin-landed work still needs no --force"
assert_contains "$(cat "$TMP/t10.out")" "teardown t10 complete" \
  "a kept branch never stops the run short of the steps after it"
assert_file "$AC_HOME/state/archive/t10/meta"
git -C "$repo9" rev-parse --verify --quiet refs/heads/crew/t10 >/dev/null \
  || fail "fixture broken: -d must refuse origin-only containment, so crew/t10 must survive"
assert_contains "$err10" "kept crew/t10" "the branch teardown could not drop is named"
assert_contains "$err10" "merged" "git's own reason for keeping it travels with the warning"

# --- family-scoped id: teardown targets the FAMILY branch, not a raw alias ----
# id t12-r2 belongs to family t12 (ac_family_of_id strips the -r2 revision
# suffix); the crew branch actually created (via ac_crew_branch, the SAME
# derivation ac-brief.sh/ac-merge-local.sh use) is crew/t12, never a hand-made
# crew/t12-r2 alias. Before the fix, ac-teardown.sh built the raw "crew/$id"
# name, found no such branch, and never targeted crew/t12 for deletion - so a
# fully landed family branch survived teardown, orphaned.
"$BIN/ac-brief.sh" t12-r2 proj9 --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t12-r2 "$repo9" --harness fake --mode local-only >/dev/null 2>&1
wt12="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t12-r2.meta")"
git -C "$wt12" checkout -q -b crew/t12
printf 'family-scoped work\n' >"$wt12/fam.txt"
git -C "$wt12" add -A
git -C "$wt12" -c user.email=t@t -c user.name=t commit -qm "family-scoped work"
git -C "$repo9" merge -q --ff-only crew/t12
"$BIN/ac-teardown.sh" t12-r2 >/dev/null \
  || fail "family-scoped id: landed crew/<family> needs no --force"
git -C "$repo9" rev-parse --verify --quiet refs/heads/crew/t12 >/dev/null 2>&1 \
  && fail "teardown must drop the landed FAMILY branch crew/t12 for a family-scoped id, not leave it orphaned"

# --- guarded crewdeputy recovery (--recover) -----------------------------------
# The naive "teardown then spawn" path is blocked exactly when recovery matters:
# spawn refuses while a meta exists, and crewdeputy teardown refuses while the
# deputy's home still holds crew in flight.

dhome="$("$BIN/ac-home-seed.sh" dep1 --no-projects 2>/dev/null)"
mkdir -p "$AC_HOME/data/dep1"
printf 'charter for dep1\n' >"$AC_HOME/data/dep1/brief.md"

# --recover is a crewdeputy verb only: on a crew spawn it is a mistake, not a no-op.
assert_fails "$BIN/ac-spawn.sh" t11 "$repo" --harness fake --recover

"$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake >/dev/null 2>&1
assert_file "$AC_HOME/state/dep1.meta" "the crewdeputy spawned"
assert_contains "$(cat "$(fake_pane_buf dep1)")" "IDLE BY DEFAULT" \
  "the kickoff carries the idle contract, so it travels with the live deputy"
assert_contains "$(cat "$(fake_pane_buf dep1)")" "ac-deputy.sh report" \
  "the kickoff carries the return channel, so an answer never lives only in chat"
# The codegraph prompt-hook kill-switch rides EVERY crew launch line, deputy
# included - its kickoff is structural too, so it pays the same whole-tree query.
assert_contains "$(cat "$(fake_pane_buf dep1)")" "CODEGRAPH_NO_PROMPT_HOOK=1" \
  "the crewdeputy launch line disarms the codegraph prompt hook"

# A LIVE pane is never double-spawned - two chiefs on one home is the failure.
err="$("$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover 2>&1)" \
  && fail "--recover must refuse while the window is alive"
assert_contains "$err" "LIVE" "the refusal names why"
assert_file "$AC_HOME/state/dep1.meta" "a refused recovery leaves the meta in place"

# Crewdeputy teardown still refuses while the deputy's home holds crew in
# flight - and recovery must not become a bypass of that refusal.
printf 'backend=herdr\n' >"$dhome/state/inner.meta"
assert_fails "$BIN/ac-teardown.sh" dep1
assert_file "$AC_HOME/state/dep1.meta" "the refused teardown kept the meta"

# The pane died: recovery ARCHIVES the stale meta (the routed-order history
# stays readable), respawns through the ordinary path, and never touches the
# deputy's own state.
archived_with() { grep -rl -- "$1" "$AC_HOME/state/archive/dep1" 2>/dev/null | wc -l | tr -d ' '; }
kill_pane() { rm -f "$FAKE_HERDR/panes/$(fake_pane dep1)".*; }

"$BIN/ac-send.sh" dep1 'routed order EPOCH1' >/dev/null
kill_pane
"$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover >/dev/null 2>&1 \
  || fail "--recover must respawn once the window is gone"
assert_eq "$(archived_with 'routed order EPOCH1')" "1" \
  "what was asked is archived, not deleted"
assert_file "$AC_HOME/state/dep1.meta" "the recovered deputy has a fresh meta"
assert_file "$dhome/state/inner.meta" "the deputy's OWN crew is untouched by recovery"
assert_file "$AC_HOME/state/.pane-dep1" \
  "the pane handle survives, so the spawn path's own window-collision check can still resolve it"

# A crewdeputy is a LONG-LIVED identity recovered repeatedly, unlike a crewmate
# id that teardown archives exactly once: a second retirement must get its own
# slot, never overwrite the first one's routed-order history (acceptance A2).
"$BIN/ac-send.sh" dep1 'routed order EPOCH2' >/dev/null
kill_pane
"$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover >/dev/null 2>&1 \
  || fail "a second --recover must respawn too"
assert_eq "$(archived_with 'routed order EPOCH1')" "1" \
  "the FIRST retirement's routed-order history is STILL readable after a second recovery"
assert_eq "$(archived_with 'routed order EPOCH2')" "1" "the second retirement is archived too"

# ORPHAN-WINDOW SAFETY on the crewdeputy path (contract: bin/ac-spawn.sh): the
# launch line strands under set -e, so the spawn dies after its window exists and
# before the first meta byte - and must take that window with it. The drop
# pattern targets the LAUNCH line only (AC_HOME= never appears in the kickoff
# prompt, which spells the same name out in prose).
dhome2="$("$BIN/ac-home-seed.sh" dep2 --no-projects 2>/dev/null)"
mkdir -p "$AC_HOME/data/dep2"
printf 'charter for dep2\n' >"$AC_HOME/data/dep2/brief.md"
n="$(cat "$FAKE_HERDR/.n")"; dtab="t$((n + 1))"
printf '9 AC_HOME=\n' >"$FAKE_HERDR/panes/p$((n + 1)).drop-enters"
: >"$FAKE_HERDR/log"
assert_fails "$BIN/ac-spawn.sh" dep2 --crewdeputy --harness fake
assert_no_file "$AC_HOME/state/dep2.meta" "a died crewdeputy spawn leaves no meta"
assert_contains "$(cat "$FAKE_HERDR/log")" "tab close $dtab" "it reaps the window it created"
assert_no_file "$AC_HOME/state/.pane-dep2" "no orphan pane handle survives"
# ...and the retry is not wedged: with the window gone it is an ordinary spawn.
"$BIN/ac-spawn.sh" dep2 --crewdeputy --harness fake >/dev/null 2>&1 \
  || fail "the retry after a died crewdeputy spawn must succeed"
assert_file "$AC_HOME/state/dep2.meta" "the retry wrote its meta"
rm -rf "$dhome2"

# THE POST-META BOOKKEEPING TAIL, crewdeputy path (contract: bin/ac-spawn.sh,
# mirrors the roomchief case in ac-room-parallel-cap.test.sh). trap - EXIT
# fires one line above ac_status_append here, so a failing status write must
# WARN by name and the spawn still succeed - the deputy already exists and is
# addressable.
dhome3="$("$BIN/ac-home-seed.sh" dep3 --no-projects 2>/dev/null)"
mkdir -p "$AC_HOME/data/dep3"
printf 'charter for dep3\n' >"$AC_HOME/data/dep3/brief.md"
mkdir -p "$AC_HOME/state/dep3.status"
set +e
out="$("$BIN/ac-spawn.sh" dep3 --crewdeputy --harness fake 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "a post-meta bookkeeping failure never fails the crewdeputy spawn"
assert_file "$AC_HOME/state/dep3.meta" "the deputy meta is present: the spawn HAPPENED and is not retryable"
assert_contains "$out" "spawned dep3" "the spawn still reports its own outcome"
assert_contains "$out" "status line could not be appended" "the lost bookkeeping write is named in the warning, never silently dropped"
rm -rf "$dhome3"

# The --recover ladder's live-pane guard is NOT the meta-race orphan, so it stays
# a REFUSAL: the ladder deliberately leaves state/.pane-<id> behind so this check
# can still catch a LIVE deputy its own probe could not answer for (a meta naming
# an unsupported backend is exactly such a probe), and reaping there would
# double-spawn onto a living deputy's tab.
printf 'backend=bogus\nkind=crewdeputy\n' >"$AC_HOME/state/dep1.meta"
err="$("$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover 2>&1)" \
  && fail "--recover must refuse a window collision, never reap it"
assert_contains "$err" "already exists" "the recover collision stays a refusal"
assert_file "$AC_HOME/state/.pane-dep1" "the refused recovery left the live deputy's window alone"

# ...and an UNREADABLE backend is refused at BOTH window-collision guards, for a
# DIFFERENT reason that has to be said in different words: rc 2 means nothing was
# learned about the pane, so proceeding would open a SECOND window onto one that
# may well be alive (contract: ORPHAN-WINDOW SAFETY in bin/ac-spawn.sh, WINDOW
# LIVENESS in bin/ac-backend.sh). `.pane-api-down` is the partial outage that
# makes this bite: the liveness probe is blind while `tab create` still works, so
# an unguarded spawn really does create the second window.
touch "$FAKE_HERDR/.pane-api-down"
: >"$FAKE_HERDR/log"
err="$("$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover 2>&1)" \
  && fail "--recover must refuse a backend it cannot READ, never spawn onto a possibly-live deputy"
rm -f "$FAKE_HERDR/.pane-api-down"
assert_contains "$err" "could not be READ" "the refusal blames the BACKEND, not the pane"
case "$err" in *"already exists"*) fail "an unreadable backend is not a window-already-exists verdict" ;; esac
assert_eq "$(grep -c 'tab create' "$FAKE_HERDR/log" || true)" "0" "no second deputy window was created"
assert_file "$AC_HOME/state/.pane-dep1" "the blind recovery left the deputy's window alone"

# The crew path's own guard, same defect: reaching it PROVES no meta exists (the
# duplicate-meta refusal above dies on one), so the orphan handle a SIGKILLed
# spawn leaves behind is exactly what it must still resolve - and a blind backend
# is no licence to open a second window beside it.
"$BIN/ac-brief.sh" bw1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" bw1 "$repo" --harness fake --mode local-only >/dev/null 2>&1
rm -f "$AC_HOME/state/bw1.meta"   # the SIGKILL-mid-spawn orphan: handle, no meta
touch "$FAKE_HERDR/.pane-api-down"
: >"$FAKE_HERDR/log"
err="$("$BIN/ac-spawn.sh" bw1 "$repo" --harness fake --mode local-only 2>&1)" \
  && fail "a crew spawn must refuse a backend it cannot READ, never open a second window"
rm -f "$FAKE_HERDR/.pane-api-down"
assert_contains "$err" "could not be READ" "the crew refusal blames the BACKEND, not the pane"
case "$err" in *"already exists"*) fail "an unreadable backend is not a window-already-exists verdict" ;; esac
assert_eq "$(grep -c 'tab create' "$FAKE_HERDR/log" || true)" "0" "no second crewmate window was created"
assert_no_file "$AC_HOME/state/bw1.meta" "the refused spawn leaves no task in flight"

# Ladder step 2: the home is gone on disk. Repairing or removing a registry
# line is a captain decision, so recovery refuses rather than spawning a deputy
# into a home that no longer exists.
rm -f "$AC_HOME/state/dep1.meta"
rm -rf "$dhome"
assert_fails "$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover

# Ladder step 1: no parseable registry entry - there is nothing to recover.
printf '# Crewdeputies\n\n' >"$AC_HOME/records/crewdeputies.md"
assert_fails "$BIN/ac-spawn.sh" dep1 --crewdeputy --harness fake --recover

# --- gone-window teardown: the durable index survives a death at the pane-kill -
# Three recorded incidents ended ac-teardown.sh AT the pane-kill step (exit 144,
# no output). While the state archive ran LAST, such a death stranded
# state/<id>.meta and .status behind a torn-down task: the fleet survey kept
# listing a phantom crewmate and the monitor raised crew-signal-stale. The
# archive is now the FIRST durable act of the teardown proper, so the fleet
# index is already correct when the kill step ends the run.
"$BIN/ac-brief.sh" t12 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t12 "$repo" --harness fake --mode local-only >/dev/null 2>&1
wt12="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t12.meta")"
# The recorded scenario: the crewmate's pane is ALREADY gone, teardown still
# runs its kill step, and that step kills the run. The tab stays (still
# labelled crew:t12) so the kill gets its ownership proof and reaches the
# close - ac-backend.sh KILL OWNERSHIP PROOF; an unprovable tab is refused,
# and a refusal is exactly the path that CANNOT kill the run.
rm -f "$FAKE_HERDR/panes/$(fake_pane t12)".*
: >"$FAKE_HERDR/.kill-caller-on-tab-close"
# The inner shell (not exec-optimized, hence the trailing exit) owns the
# killed child, so bash's "Killed: 9" job report stays out of the suite output.
rc=0
bash -c '"$0" t12 >/dev/null 2>&1; exit $?' "$BIN/ac-teardown.sh" 2>/dev/null || rc=$?
rm -f "$FAKE_HERDR/.kill-caller-on-tab-close"
if [ "$rc" = 0 ]; then fail "fixture broken: the pane-kill step must end the run"; fi
# The exit code is NOT the assertion (the run was killed mid-flight and cannot
# report 0); the durable end-state is.
assert_no_file "$AC_HOME/state/t12.meta" "no phantom crewmate after a killed teardown"
assert_file "$AC_HOME/state/archive/t12/meta" "meta archived before the pane-kill"
assert_file "$AC_HOME/state/archive/t12/status" "status archived with it (one unit)"
# What such a death DOES leave: the pool lease, reclaimable with the pool's own
# verb (the header's recoverability claim).
grep -q "leased.*t12" <<<"$("$BIN/ac-tree.sh" list --repo "$repo")" \
  || fail "the killed run should leave its lease behind, reclaimable by ac-tree.sh"
"$BIN/ac-tree.sh" return "$wt12" --force >/dev/null 2>&1

# --- end-of-task pane-agent sweep ---------------------------------------------
# The pane agents a task starts (the ship reviewer, the qa agent, the ship/qa
# watch panes) and the qa serve process are retired only by ac-ship.sh /
# ac-qa.sh finish - which a crewmate killed at the pane-kill step never reaches,
# so they outlived teardown (captain-caught twice). Teardown owns that sweep,
# and it must run BEFORE the lease goes back: ac-tree.sh return rm -rf's
# .crew/qa, so a sweep placed after it could never see the qa records at all.
"$BIN/ac-brief.sh" t13 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t13 "$repo" --harness fake --mode local-only >/dev/null 2>&1
wt13="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t13.meta")"
assert_eq "$(awk -F= '$1=="leases"{print $2}' "$AC_HOME/state/t13.meta")" "$wt13" \
  "spawn records every lease it took as leases="
# lease_ids= runs alongside leases=, so teardown can bind each return to the
# acquisition that took the slot instead of to its (reusable) path.
assert_eq "$(awk -F= '$1=="lease_ids"{print $2}' "$AC_HOME/state/t13.meta")" \
  "$(sed -n 's/^lease_id=//p' "$repo/.crew/slots/$(basename "$wt13").meta")" \
  "spawn records the slot's acquisition identity as lease_ids="

mkdir -p "$wt13/.crew/qa/qrun" "$wt13/.crew/qa/other" "$wt13/.crew/qa/nameless" \
         "$wt13/.crew/ship/srun"
printf 'pQA\n' >"$wt13/.crew/qa/agent-t13.pane"             # keyed by task
printf 'task=t13\n' >"$wt13/.crew/qa/qrun/run.meta"
printf 'pQW\n' >"$wt13/.crew/qa/qrun/watch.pane"
printf 'task=t99\n' >"$wt13/.crew/qa/other/run.meta"        # a CO-TENANT's run
printf 'pOTHER\n' >"$wt13/.crew/qa/other/watch.pane"
printf 'target=main\n' >"$wt13/.crew/qa/nameless/run.meta"  # attributable to NO ONE
printf 'pNAMELESS\n' >"$wt13/.crew/qa/nameless/watch.pane"
printf 'branch=crew/t13\n' >"$wt13/.crew/ship/srun/run.meta"
printf 'pREV\n' >"$wt13/.crew/ship/srun/review.pane"
printf 'pSW\n' >"$wt13/.crew/ship/srun/watch.pane"
# Execution-triggered verifiers live in fleet state, not in the caller's
# worktree. Teardown attributes modern records by caller=, archives them, and
# preserves an explicit artifact before cleaning incomplete QA.
vreview=t13-verify-codereview
cat >"$AC_HOME/state/$vreview.meta" <<EOF
kind=verify-codereview
family=t13
caller=t13
worktree=
leases=
EOF
printf 'pVC tVC\n' >"$AC_HOME/state/.pane-$vreview"
vqa=t13-verify-qa
vqa_evidence="$AC_HOME/data/t13/verification/qa-evidence"
mkdir -p "$vqa_evidence"
printf 'partial verdict\n' >"$vqa_evidence/verdict.json"
cat >"$AC_HOME/state/$vqa.meta" <<EOF
kind=verify-qa
family=t13
caller=t13
worktree=
leases=
evidence=$vqa_evidence
EOF
printf 'pVQ tVQ\n' >"$AC_HOME/state/.pane-$vqa"
# Same family but another explicit caller is a co-tenant and must survive.
cat >"$AC_HOME/state/other-verify-codereview.meta" <<'EOF'
kind=verify-codereview
family=t13
caller=other
worktree=
leases=
EOF
printf 'pOTHERVERIFY tOV\n' >"$AC_HOME/state/.pane-other-verify-codereview"
# A pane the close does NOT take on: it still resolves afterwards (the fake
# keeps a pane with a .buf alive), which is what reap-pane's `closed` reports.
mkdir -p "$wt13/.crew/qa/qstuck"
printf 'task=t13\n' >"$wt13/.crew/qa/qstuck/run.meta"
printf 'pSTUCK\n' >"$wt13/.crew/qa/qstuck/watch.pane"
: >"$FAKE_HERDR/panes/pSTUCK.buf"
# A live serve process group: started from a subshell that exits at once, so the
# sleep is reparented and never a zombie child of this suite (kill -0 would
# report a zombie as alive and make the assertion below unfalsifiable).
( sleep 30 & printf '%s' "$!" >"$wt13/.crew/qa/qrun/serve.pid" )
spid="$(cat "$wt13/.crew/qa/qrun/serve.pid")"
kill -0 "$spid" 2>/dev/null || fail "fixture broken: the serve pid must start alive"

: >"$FAKE_HERDR/log"
out="$("$BIN/ac-teardown.sh" t13 --force 2>&1)" || fail "the sweep must never fail teardown"
log="$(cat "$FAKE_HERDR/log")"
for p in pQA pQW pREV pSW pVC pVQ; do
  assert_contains "$log" "pane close $p" "teardown reaped $p"
done
case "$log" in *"pane close pOTHERVERIFY"*) fail "another caller's verifier must never be reaped" ;; esac
assert_file "$AC_HOME/state/archive/$vreview/meta" "caller-linked codereview meta is archived"
assert_file "$AC_HOME/state/archive/$vqa/meta" "caller-linked QA meta is archived"
assert_file "$vqa_evidence/incomplete-run.md" "incomplete QA is preserved before explicit teardown"
assert_file "$AC_HOME/state/other-verify-codereview.meta" "co-tenant verifier meta survives"
case "$log" in *"pane close pOTHER"*) fail "a run attributed to ANOTHER task must never be reaped" ;; esac
case "$log" in *"pane close pNAMELESS"*) fail "an unattributable run must never be reaped" ;; esac
assert_contains "$out" "pNAMELESS" "an unattributable pane is warned by id"
assert_contains "$out" "$wt13/.crew/qa/nameless/watch.pane" "an unattributable pane is warned by path"
# A reap ATTEMPTED but not taken is surfaced too. reap-pane always exits 0 by
# contract, so the sweep could previously not tell a retired pane from one it
# left running - the silence that let pane agents orphan unnoticed.
assert_contains "$out" "pSTUCK" "a pane the reap did not close is warned by id"
case "$out" in *"pQA"*) fail "a pane that DID close must not be warned about" ;; esac
i=0
while [ "$i" -lt 25 ] && kill -0 "$spid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
kill -0 "$spid" 2>/dev/null && fail "teardown must kill a live qa serve process group"
# Herestring, never `list | grep -q`: -q exits on the first match, ac-tree.sh
# dies of SIGPIPE, and under pipefail the pipeline then reports 141 - so the
# `&& fail` could never fire and the assertion would be unfalsifiable.
grep -q "leased.*t13" <<<"$("$BIN/ac-tree.sh" list --repo "$repo")" \
  && fail "the sweep must not cost the task its lease return"

# --- the evidence preflight runs INSIDE the gate ------------------------------
# The preflight is DURABLE: it mints verification/<vid>-incomplete-*/ carrying
# an incomplete-run.md that states the verifier "was explicitly torn down".
# Running it before the landed proof recorded exactly that on the path the gate
# exists to REFUSE - about a verifier that keeps running - and its own ac_die
# sites could end teardown with a preservation error instead of the refusal the
# captain must see. The gate's promise is that a refusal writes nothing durable.
"$BIN/ac-brief.sh" t23 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t23 "$repo" --harness fake --mode local-only >/dev/null 2>&1
wt23="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t23.meta")"
git -C "$wt23" checkout -q -b crew/t23
printf 'unlanded\n' >"$wt23/t23.txt"
git -C "$wt23" add -A
git -C "$wt23" -c user.email=t@t -c user.name=t commit -qm "unlanded work"
# A QA verifier mid-run: no verdict, no relay report, no run-state - exactly
# what the preflight preserves, and with no evidence= it MINTS the artifact dir.
cat >"$AC_HOME/state/t23-verify-qa.meta" <<EOF
kind=verify-qa
family=t23
caller=t23
worktree=
leases=
EOF
out="$("$BIN/ac-teardown.sh" t23 2>&1)" && fail "teardown must refuse an unlanded crew branch"
assert_contains "$out" "refusing teardown of t23" \
  "the refusal is the landed-proof one, not a preservation error"
assert_no_file "$AC_HOME/data/t23/verification" "a refused teardown writes NOTHING durable"
assert_file "$AC_HOME/state/t23-verify-qa.meta" "a refused teardown leaves the live verifier alone"
# The let-through direction: past the gate the preflight still runs, before the
# task meta is archived (header: VERIFIER SWEEP).
git -C "$repo" merge -q --ff-only crew/t23
"$BIN/ac-teardown.sh" t23 >/dev/null 2>&1 || fail "a landed task must tear down"
assert_file "$AC_HOME/state/archive/t23/meta"
ev23="$(printf '%s\n' "$AC_HOME/data/t23/verification/t23-verify-qa-incomplete-"*/incomplete-run.md | head -n1)"
assert_file "$ev23" "past the gate the incomplete QA artifact is still preserved"

# Direct verifier recovery is its own lifecycle: it never enters ship landed
# proof or looks for a crew/<verify-id> branch.
cat >"$AC_HOME/state/direct-verify-codereview.meta" <<EOF
kind=verify-codereview
family=direct
caller=direct
backend=herdr
project_dir=$repo
worktree=
leases=
EOF
printf 'pDIRECTVERIFY tDV\n' >"$AC_HOME/state/.pane-direct-verify-codereview"
# The watcher polls and stamps EVERY meta including verify-* ones (excluded
# from accounting, never from supervision), so a verifier accumulates the same
# per-id litter a crewmate does. Before the fix, the verifier branch's early
# exit skipped removing it entirely - the live evidence: 11 orphan .change-*
# stamps, every one a verify-codereview id.
for stamp in hash change seen seen-hash stale gone ask unobservable report-hash superseded; do
  : >"$AC_HOME/state/.$stamp-direct-verify-codereview"
done
"$BIN/ac-teardown.sh" direct-verify-codereview >/dev/null
assert_file "$AC_HOME/state/archive/direct-verify-codereview/meta" \
  "direct verifier teardown skips ship landed proof"
for stamp in hash change seen seen-hash stale gone ask unobservable report-hash superseded; do
  assert_no_file "$AC_HOME/state/.$stamp-direct-verify-codereview" \
    "verifier teardown sweeps the watcher's .$stamp-<id> stamp too"
done

# Story 3: a dual-ref QA verifier record carries TWO leases (source:e2e). The
# failure/timeout cleanup for the SECOND (E2E) worktree runs through teardown,
# not only ac-verify's own success path, so teardown must return BOTH - the
# source lease from its repo AND the E2E lease from the separate E2E repo.
dual_src="$("$BIN/ac-tree.sh" get --repo "$repo" --id dualsrc --holder verify | tail -n1)"
dual_e2e_repo="$(make_repo dual-e2e)"
dual_e2e="$("$BIN/ac-tree.sh" get --repo "$dual_e2e_repo" --id duale2e --holder verify | tail -n1)"
mkdir -p "$AC_HOME/data/dualqa/verification/ev"
cat >"$AC_HOME/state/dualqa-verify-qa.meta" <<EOF
kind=verify-qa
family=dualqa
caller=dualqa
backend=herdr
project_dir=$repo
worktree=$dual_src
leases=$dual_src:$dual_e2e
evidence=$AC_HOME/data/dualqa/verification/ev
EOF
printf 'pDUALQA tDQA\n' >"$AC_HOME/state/.pane-dualqa-verify-qa"
"$BIN/ac-teardown.sh" dualqa-verify-qa >/dev/null 2>&1 \
  || fail "a dual-ref verifier teardown must not fail"
assert_file "$AC_HOME/state/archive/dualqa-verify-qa/meta" "the dual-ref verifier meta is archived"
grep -q "leased.*dualsrc" <<<"$("$BIN/ac-tree.sh" list --repo "$repo")" \
  && fail "teardown must return the SOURCE lease of a dual-ref verifier"
grep -q "leased.*duale2e" <<<"$("$BIN/ac-tree.sh" list --repo "$dual_e2e_repo")" \
  && fail "teardown must return the E2E lease of a dual-ref verifier"

# Back-compat: a meta written before leases= existed carries only worktree=, and
# teardown must still return that one tree (no migration script).
"$BIN/ac-brief.sh" t14 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t14 "$repo" --harness fake --mode local-only >/dev/null 2>&1
grep -v '^leases=' "$AC_HOME/state/t14.meta" >"$TMP/t14.meta"
mv "$TMP/t14.meta" "$AC_HOME/state/t14.meta"
"$BIN/ac-teardown.sh" t14 --force >/dev/null 2>&1
grep -q "leased.*t14" <<<"$("$BIN/ac-tree.sh" list --repo "$repo")" \
  && fail "a pre-leases meta must still get its worktree back"

# --- vanished lease dir: the lease record and the disk have DIVERGED -----------
# Same defect class as the branch -d silence above (@4e80718), one statement
# earlier in this same loop: something removed a leased worktree out from
# under the pool, and the old predicate (`[ -n "$lease" ] && [ -d "$lease" ] ||
# continue`) swallowed it with no warning at all - the sweep, the return,
# everything the loop iteration owed for that lease simply never ran.
"$BIN/ac-brief.sh" t16 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t16 "$repo" --harness fake --mode local-only >/dev/null 2>&1
wt16="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t16.meta")"
rm -rf "$wt16"
err16="$("$BIN/ac-teardown.sh" t16 2>&1 >"$TMP/t16.out")" \
  || fail "a vanished lease dir must not stop teardown short of completion"
assert_contains "$(cat "$TMP/t16.out")" "teardown t16 complete" \
  "a vanished lease never stops the run short of the steps after it"
assert_contains "$err16" "WARN:" "the vanished lease is reported on the warning channel"
assert_contains "$err16" "$wt16" "the warning names the vanished lease path"
assert_file "$AC_HOME/state/archive/t16/meta"

# An EMPTY lease entry is a DIFFERENT, ORDINARY state - a meta whose leases=
# carries no path at all - and must stay silent; the same predicate has to
# tell the two apart. Hand-written like the dem-chief/dem-spec metas above:
# kind=ship with no leases= and no worktree= reaches this loop with lease=""
# (`printf '%s\n' "" | tr ':' '\n'` yields one empty line). Normal spawn never
# produces this shape - ac-spawn.sh/ac-self-task.sh always set leases= equal
# to worktree=, itself always non-empty on a successful spawn - but the
# back-compat fallback (`[ -n "$leases" ] || leases="$worktree"`) still has to
# handle it correctly rather than warn spuriously on every ordinary teardown.
printf 'kind=ship\nbackend=herdr\nproject_dir=%s\nworktree=\nleases=\n' "$repo" \
  >"$AC_HOME/state/t17.meta"
out17="$("$BIN/ac-teardown.sh" t17 2>&1)" || fail "an empty lease must not fail teardown"
assert_contains "$out17" "teardown t17 complete" "an empty lease still reaches completion"
# The assertion is scoped to LEASE warnings, not to "no WARN at all". Teardown
# legitimately warns about OTHER subsystems in the same output - on a host where
# the docker BINARY exists but the daemon is unusable, the qa-infra sweep warns
# after its 30s bound - and an unscoped match failed on that, reporting a lease
# defect that was never there (this case was red on main for exactly that
# reason; DEBUG showed out17 held only the qa-infra warning). The two warnings
# this loop can actually emit are "skipping vanished lease" and "could not
# return worktree", so match those.
case "$out17" in *"WARN: skipping vanished lease"*|*"WARN: could not return worktree"*) fail "an empty lease entry must stay silent, no spurious lease WARN" ;; esac

# --- kept-branch warning: the reclaim command is CASE-CORRECT, not borrowed ----
# @4e80718 made the git-branch -d refusal speak, but it only carries a reclaim
# command because git's own hint happens to say `git branch -D <branch>` -
# absent under advice.forceDeleteBranch=false (CASE B) and WRONG when the
# branch is checked out in a worktree (CASE C, where -D refuses IDENTICALLY -
# verified empirically on git 2.55.0: same "used by worktree" message, exit 1).
"$BIN/ac-brief.sh" t18 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t18 "$repo" --harness fake --mode local-only >/dev/null 2>&1
wt18="$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t18.meta")"
git -C "$wt18" checkout -q -b crew/t18
printf 'unmerged work\n' >"$wt18/t18.txt"
git -C "$wt18" add -A
git -C "$wt18" -c user.email=t@t -c user.name=t commit -qm "unmerged work"
git -C "$repo" config advice.forceDeleteBranch false
err18="$("$BIN/ac-teardown.sh" t18 --force 2>&1 >"$TMP/t18.out")" \
  || fail "a kept branch must not stop teardown short of completion"
git -C "$repo" config --unset advice.forceDeleteBranch
assert_contains "$(cat "$TMP/t18.out")" "teardown t18 complete" \
  "a kept branch never stops the run short of the steps after it"
assert_contains "$err18" "kept crew/t18" "the branch teardown could not drop is named"
assert_contains "$err18" "not fully merged" "git's own reason for keeping it travels with the warning"
case "$err18" in *hint:*) fail "CASE B: git emits no hint under advice.forceDeleteBranch=false, so any hint text here is not git's own" ;; esac
assert_contains "$err18" "git branch -D crew/t18" \
  "CASE B: git's hint is absent, so the warning must supply its own reclaim command"

"$BIN/ac-brief.sh" t19 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" t19 "$repo" --harness fake --mode local-only >/dev/null 2>&1
stray19="$TMP/stray-t19"
git -C "$repo" worktree add -q -b crew/t19 "$stray19"
printf 'stray work\n' >"$stray19/t19.txt"
git -C "$stray19" add -A
git -C "$stray19" -c user.email=t@t -c user.name=t commit -qm "stray work"
err19="$("$BIN/ac-teardown.sh" t19 --force 2>&1 >"$TMP/t19.out")" \
  || fail "a worktree-held branch must not stop teardown short of completion"
assert_contains "$(cat "$TMP/t19.out")" "teardown t19 complete" \
  "a worktree-held branch never stops the run short of the steps after it"
assert_contains "$err19" "kept crew/t19" "the branch teardown could not drop is named"
assert_contains "$err19" "used by worktree" "git's own reason for keeping it travels with the warning"
case "$err19" in
  *"reclaim: git branch -D crew/t19"*)
    fail "CASE C: a bare -D suggestion (the CASE A/B wording, unqualified) refuses IDENTICALLY when a worktree holds the branch - it must be sent into freeing the worktree first, not straight into a second refusal" ;;
esac
case "$err19" in *worktree*"git branch -D crew/t19"*) ;; *) fail "CASE C: the reclaim instruction must still lead to -D, but only after dealing with the worktree" ;; esac
git -C "$repo" worktree remove --force "$stray19" >/dev/null 2>&1 || true
git -C "$repo" branch -D crew/t19 >/dev/null 2>&1 || true

# --- the same silence one loop away: a verifier's own vanished lease ----------
# bin/ac-teardown.sh:471 (archive_and_reap_verifier) carries the IDENTICAL
# predicate @9b39f00 fixed one statement above it in the sibling loop - a
# verifier lease whose directory has vanished was skipped in total silence.
# Torn down directly (the dualqa idiom above): a verifier meta IS the id.
vlease20="$TMP/vanished-verifier-lease-t20"
rm -rf "$vlease20"
printf 'kind=verify-codereview\nbackend=herdr\nfamily=t20\ncaller=t20-verify\nproject_dir=%s\nleases=%s\n' \
  "$repo" "$vlease20" >"$AC_HOME/state/t20-verify.meta"
err20="$("$BIN/ac-teardown.sh" t20-verify 2>&1 >"$TMP/t20.out")" \
  || fail "a vanished verifier lease dir must not stop teardown short of completion"
assert_contains "$(cat "$TMP/t20.out")" "teardown t20-verify complete (verifier)" \
  "a vanished verifier lease never stops the run short of the steps after it"
assert_contains "$err20" "WARN:" "the vanished verifier lease is reported on the warning channel"
assert_contains "$err20" "$vlease20" "the warning names the vanished verifier lease path"
assert_file "$AC_HOME/state/archive/t20-verify/meta"

# An EMPTY verifier lease is the normal back-compat case (no lease held at
# all) and must stay silent - the same distinction @9b39f00 drew for its twin.
printf 'kind=verify-codereview\nbackend=herdr\nfamily=t21\ncaller=t21-verify\nproject_dir=%s\nleases=\n' \
  "$repo" >"$AC_HOME/state/t21-verify.meta"
out21="$("$BIN/ac-teardown.sh" t21-verify 2>&1)" || fail "an empty verifier lease must not fail teardown"
assert_contains "$out21" "teardown t21-verify complete (verifier)" "an empty verifier lease still reaches completion"
case "$out21" in *"WARN: skipping vanished lease"*|*"WARN: could not return worktree"*) fail "an empty verifier lease entry must stay silent, no spurious lease WARN" ;; esac

# --- orphan-window safety on the crew path -------------------------------------
# The crew trap gave the lease back and removed the half-written meta, but left
# its TAB behind - an un-addressable orphan, since every consumer keys off
# state/<id>.meta (contract: ORPHAN-WINDOW SAFETY in bin/ac-spawn.sh). The launch
# line strands the way a real one does; the drop pattern targets it only
# (AC_FLEET_STATE never appears in the kickoff prompt).
"$BIN/ac-brief.sh" t15 proj --mode local-only >/dev/null
n="$(cat "$FAKE_HERDR/.n")"; otab="t$((n + 1))"
printf '9 AC_FLEET_STATE\n' >"$FAKE_HERDR/panes/p$((n + 1)).drop-enters"
: >"$FAKE_HERDR/log"
assert_fails "$BIN/ac-spawn.sh" t15 "$repo" --harness fake --mode local-only
assert_no_file "$AC_HOME/state/t15.meta" "no half-written meta"
assert_contains "$(cat "$FAKE_HERDR/log")" "tab close $otab" "the crew trap now reaps the window it created"
assert_no_file "$AC_HOME/state/.pane-t15" "no orphan pane handle survives"
grep -q "leased.*t15" <<<"$("$BIN/ac-tree.sh" list --repo "$repo")" \
  && fail "the trap must still give the lease back"

# --- roomchief DEMOTE vs the verification-agent class -------------------------
# landed_proof refuses a demote while any member of the family stands (member =
# ac_family_of_id, or the meta's fleet_scope). A VERIFICATION agent carries a
# family id but is NOT crew, and nobody tears it down - counting it would strand
# the roomchief undemotable. No project_dir on these metas, so the qa-infra
# sweep is skipped (this case is about landed_proof, not docker).
"$BIN/ac-room.sh" post dem crewchief "spawned dem-review" >/dev/null
printf 'kind=roomchief\nbackend=herdr\n' >"$AC_HOME/state/dem-chief.meta"
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real dem-spec task always has one, since
# ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/dem/spec"
printf 'kind=ship\nbackend=herdr\n' >"$AC_HOME/state/dem-spec.meta"
assert_fails "$BIN/ac-teardown.sh" dem-chief          # real crew still flies
rm -f "$AC_HOME/state/dem-spec.meta"
printf 'kind=verify-codereview\nbackend=herdr\n' >"$AC_HOME/state/dem-review.meta"
"$BIN/ac-teardown.sh" dem-chief >/dev/null || fail "a verifier meta must not block the demote"
assert_contains "$(cat "$AC_HOME/data/dem/room.md")" "DEMOTED" "the demote receipt still posts"
rm -f "$AC_HOME/state/dem-review.meta"

# --- DEMOTED room post failure is no longer swallowed in total silence --------
# bin/ac-teardown.sh:615 posted DEMOTED with `>/dev/null 2>&1 || true`, which
# swallowed BOTH the room record AND ac-room.sh's own refusal text - unlike
# every other best-effort step in this file, which at least ac_warns. A family
# name with a space is a real, deterministic refusal (ac-room.sh post's own
# charset guard: [a-zA-Z0-9_-]), reached here by giving the roomchief id itself
# an embedded space - ac-teardown.sh applies no charset check of its own to id.
printf 'kind=roomchief\nbackend=herdr\n' >"$AC_HOME/state/dem bad-chief.meta"
err23="$("$BIN/ac-teardown.sh" "dem bad-chief" 2>&1 >"$TMP/t23.out")" \
  || fail "a DEMOTED post failure must not stop teardown short of completion"
assert_contains "$(cat "$TMP/t23.out")" "teardown dem bad-chief complete" \
  "a DEMOTED post failure never stops the run short of the steps after it"
assert_contains "$err23" "WARN:" "the DEMOTED post failure is reported on the warning channel"
assert_contains "$err23" "could not post DEMOTED to room dem bad" "the warning names the family"
assert_contains "$err23" "family must be" "ac-room.sh's own refusal text travels with the warning"
assert_contains "$err23" "post it by hand:" "the warning names the exact command to post the entry by hand"
assert_contains "$err23" "ac-room.sh post dem bad crewchief" "the hand command names the family and actor"

# --- reap_pane_file: a read failure keeps the record instead of deleting it ---
# bin/ac-teardown.sh:305 (reap_pane_file) collapsed "could not read the file"
# into the same silent rm -f as "no first field" - the function's own header
# (:294-297) promises a read failure is warned by pane id/path AND the record
# KEPT so a later attempt still has it. Verified empirically on this host
# (awk, under this script's `set -euo pipefail`):
# DISPUTED: whether `awk 'NR==1{print $1}' "$f" 2>/dev/null` exits non-zero on
#   an unreadable EXISTING file and zero on an empty READABLE file, and
#   whether that exit status survives `p="$(...)"` used in an `if` test.
# HELD-CONSTANT: the awk program, the file's existence, `set -euo pipefail`.
#   f=/tmp/awktest_noread; : > "$f"; chmod 000 "$f"
#   if p="$(awk 'NR==1{print $1}' "$f" 2>/dev/null)"; then echo "ok=[$p]"
#   else echo "failed exit=$?"; fi   # -> "failed exit=2"
#   f=/tmp/awktest_empty; : > "$f"
#   if p="$(awk 'NR==1{print $1}' "$f" 2>/dev/null)"; then echo "ok=[$p]"
#   else echo "failed"; fi          # -> "ok=[]"
# archive_and_reap_verifier's own pane record (state/.pane-<id>) is the clean
# target: it lives in fleet state, not a leased worktree, so nothing downstream
# resets or deletes it out from under this test the way a worktree return does.
vunread=t22-verify
printf 'kind=verify-codereview\nbackend=herdr\nfamily=t22\ncaller=t22-verify\nproject_dir=%s\nleases=\n' \
  "$repo" >"$AC_HOME/state/$vunread.meta"
printf 'pUNREAD tUR\n' >"$AC_HOME/state/.pane-$vunread"
chmod 000 "$AC_HOME/state/.pane-$vunread"
err22="$("$BIN/ac-teardown.sh" "$vunread" 2>&1 >"$TMP/t22.out")" \
  || fail "an unreadable pane file must not stop teardown short of completion"
chmod 644 "$AC_HOME/state/.pane-$vunread" 2>/dev/null || true
assert_contains "$(cat "$TMP/t22.out")" "teardown $vunread complete (verifier)" \
  "an unreadable pane file never stops the run short of the steps after it"
assert_contains "$err22" "WARN:" "the unreadable pane file is reported on the warning channel"
assert_contains "$err22" "could not read" "the warning says the file could not be read"
assert_contains "$err22" "$AC_HOME/state/.pane-$vunread" "the warning names the unreadable pane path"
assert_file "$AC_HOME/state/.pane-$vunread" "an unreadable pane file record is KEPT, not deleted"

# --- kill_serve_pid: a read failure keeps the record instead of deleting it ---
# bin/ac-teardown.sh:340 is symmetric with reap_pane_file above: unreadable and
# empty collapsed into the same silent no-op-then-delete, so a genuinely
# running qa serve process behind an unreadable pid file was abandoned with its
# record erased and no signal - the next qa run then hits a port collision with
# no clue why. Same disputed variable, same construct, verified the same way
# (`cat` in place of `awk`; DISPUTED/HELD-CONSTANT declared above covers it).
# leases= is pointed at a REAL, existing directory that is NOT a registered
# pool slot: sweep_pane_agents runs on it (and must see the unreadable
# serve.pid) before the unconditional `ac-tree.sh return` that follows - that
# return refuses ("not an agent-crew pool worktree"), caught by the existing
# `|| ac_warn`, so this directory is never reset and the kept-vs-deleted file
# is directly observable after teardown completes (unlike a real leased
# worktree, whose pool reset would erase the evidence either way).
fake_lease24="$TMP/fake-lease-t24"
mkdir -p "$fake_lease24/.crew/qa/qrun24"
printf 'task=t24\n' >"$fake_lease24/.crew/qa/qrun24/run.meta"
printf '4242\n' >"$fake_lease24/.crew/qa/qrun24/serve.pid"
chmod 000 "$fake_lease24/.crew/qa/qrun24/serve.pid"
printf 'kind=ship\nbackend=herdr\nproject_dir=%s\nworktree=%s\nleases=%s\n' \
  "$repo" "$fake_lease24" "$fake_lease24" >"$AC_HOME/state/t24.meta"
err24="$("$BIN/ac-teardown.sh" t24 --force 2>&1 >"$TMP/t24.out")" \
  || fail "an unreadable serve.pid must not stop teardown short of completion"
chmod 644 "$fake_lease24/.crew/qa/qrun24/serve.pid" 2>/dev/null || true
assert_contains "$(cat "$TMP/t24.out")" "teardown t24 complete" \
  "an unreadable serve.pid never stops the run short of the steps after it"
assert_contains "$err24" "WARN:" "the unreadable serve.pid is reported on the warning channel"
assert_contains "$err24" "could not read" "the warning says the file could not be read"
assert_contains "$err24" "$fake_lease24/.crew/qa/qrun24/serve.pid" "the warning names the unreadable serve.pid path"
assert_file "$fake_lease24/.crew/qa/qrun24/serve.pid" "an unreadable serve.pid record is KEPT, not deleted"

# --- bounded qa-infra sweep: docker can no longer park or silence teardown -----
# The last step (ac-qa.sh infra down) had no bound and no evidence channel: a
# HUNG docker parked teardown there forever, so neither the completion line nor
# the roomchief advisory ever ran, an unusable docker passed for a clean sweep,
# and the deaths recorded at this step exited 144 (signal 16, SIGURG) in total
# silence. The metas below are written by hand (the ac-room-parallel-cap.test.sh
# idiom) and kind=roomchief on purpose: a chief holds no lease and no crew
# branch, so the qa-infra step and the tail after it are all that runs.
dstub="$TMP/dstub"; mkdir -p "$dstub"
export PATH="$dstub:$PATH"
export AC_TEARDOWN_QA_TIMEOUT=1   # the production bound is 30s; a test may not sit for it
qa_chief() {
  printf 'kind=roomchief\nbackend=herdr\nworktree=%s\nproject_dir=%s\n' "$repo" "$repo" \
    >"$AC_HOME/state/$1.meta"
  printf 'p20 t20\n' >"$AC_HOME/state/.pane-$1"
}
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] nextup - ordinary queued work (repo: proj)
EOF

# (1) a HUNG docker is killed by the watchdog and the whole tail still runs.
# `exec sleep` so the recorded pid IS the sleeper: the watchdog kills teardown's
# own child, the shim is orphaned, and this file is how the suite reaps it.
cat >"$dstub/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"$TMP/hang.pid"
exec sleep 30
EOF
chmod +x "$dstub/docker"
qa_chief hung-chief
"$BIN/ac-teardown.sh" hung-chief >"$TMP/hung.out" 2>&1 &
tdpid=$!
# A ceiling of the test's own: without it an unbounded sweep hangs the suite
# instead of failing it, and a hang proves nothing.
i=0
while [ "$i" -lt 50 ] && kill -0 "$tdpid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$tdpid" 2>/dev/null; then
  kill -9 "$tdpid" 2>/dev/null || true
  fail "a hung docker parked teardown at the qa-infra sweep"
fi
wait "$tdpid" || fail "a hung docker must not fail teardown"
if [ -s "$TMP/hang.pid" ]; then kill "$(cat "$TMP/hang.pid")" 2>/dev/null || true; fi
hung="$(cat "$TMP/hung.out")"
assert_contains "$hung" "status 124" "the watchdog timeout is warned by status"
assert_contains "$hung" "infra down --task hung-chief" "the warning names the reclaim command"
assert_contains "$hung" "teardown hung-chief complete" "the completion line still prints"
assert_contains "$hung" "next queued family: nextup" "the roomchief advisory still prints"

# (2) an UNUSABLE docker (present, exits non-zero) warns instead of passing for
# a successful sweep - ac-qa.sh `infra down` returns the compose status.
printf '#!/usr/bin/env bash\nexit 7\n' >"$dstub/docker"
qa_chief broke-chief
out="$("$BIN/ac-teardown.sh" broke-chief 2>&1)" || fail "an unusable docker must not fail teardown"
assert_contains "$out" "status 7" "an unusable docker surfaces its own status"
assert_contains "$out" "teardown broke-chief complete" "the completion line still prints"

# (3) a signal AT THIS STEP names itself. The shim delivers the recorded killer
# (signal 16) to teardown from inside the step; SIGURG is the one the header
# called untrappable, so this test is the proof, not the assumption.
cat >"$dstub/docker" <<EOF
#!/usr/bin/env bash
while [ ! -s "$TMP/td.pid" ]; do sleep 0.05; done
kill -URG "\$(cat "$TMP/td.pid")"
exit 0
EOF
rm -f "$TMP/td.pid"
qa_chief sig-chief
"$BIN/ac-teardown.sh" sig-chief >"$TMP/sig.out" 2>&1 &
tdpid=$!
printf '%s\n' "$tdpid" >"$TMP/td.pid"
wait "$tdpid" || fail "a signal bash ignores by default must not fail teardown"
sigout="$(cat "$TMP/sig.out")"
assert_contains "$sigout" "SIGURG" "the trap names WHICH signal"
assert_contains "$sigout" "qa-infra sweep" "the trap names WHICH step"
assert_contains "$sigout" "teardown sig-chief complete" "the run still finishes"
rm -f "$dstub/docker"
unset AC_TEARDOWN_QA_TIMEOUT

# --- the DERIVED crewdomain binding on the roomchief promote (R3) ------------
# A promote of a family whose row sits in a crewdomain backlog becomes a
# DOMAINCHIEF: AC_DOMAIN on the launch line (for the session and everything it
# spawns) and domain= in the meta (for every OTHER process, which reads durable
# state, not the chief's environment). The binding is DERIVED from the
# assignment, never passed - so a mis-bind is impossible, and a family the
# chief never assigned cannot become a domainchief at all.

dom_reg="$AC_HOME/records/crewdomains.md"
dom_pkg() { printf '%s/crewdomains/%s\n' "$AC_HOME" "$1"; }
# This suite does not source ac-lib.sh, so the meta is read the way the rest of
# the file reads one - directly off disk.
meta_field() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"; }
dom_seed() {  # dom_seed <domain> <family>... - a registered domain holding rows
  mkdir -p "$(dom_pkg "$1")/records"
  { printf '# Backlog: %s\n\n## In flight\n\n## Queued\n\n' "$1"
    shift
    for f in "$@"; do printf -- '- [ ] %s - assigned work; assigned:crewchief (repo: proj)\n' "$f"; done
    printf '\n## Done\n'
  } >"$(dom_pkg "$1")/records/backlog.md"
}
dom_register() { printf -- '- %s - the %s domain - scope: %s work (added 2026-08-02T00:00:00Z)\n' "$1" "$1" "$1" >>"$dom_reg"; }
room_seed() { "$BIN/ac-room.sh" post "$1" crewchief "the captain order for $1, posted before the promote" >/dev/null; }

# AC-3.1 - an ASSIGNED family binds in both places.
dom_register payments
dom_seed payments dfam1
room_seed dfam1
"$BIN/ac-spawn.sh" --roomchief dfam1 --harness fake >/dev/null 2>&1
assert_eq "$(meta_field "$AC_HOME/state/dfam1-chief.meta" domain)" "payments" \
  "AC-3.1: the domain rides the meta, where every other process reads it"
assert_contains "$(cat "$(fake_pane_buf dfam1-chief)")" "AC_DOMAIN=payments" \
  "AC-3.1: and the launch line, for the session and everything it spawns"

# R2-CR-001 - the derivation requires the PROVENANCE, not merely a matching row.
# Without it a HAND-ADDED row mints a domainchief and gets worked, and R3's
# claim that chief-only-add is STRUCTURAL at the session level is false.
mkdir -p "$(dom_pkg payments)/records"
printf '# Backlog: payments\n\n## In flight\n\n## Queued\n\n- [ ] dfam1b - hand-added, nobody assigned it (repo: proj)\n\n## Done\n' \
  >"$(dom_pkg payments)/records/backlog.md"
room_seed dfam1b
"$BIN/ac-spawn.sh" --roomchief dfam1b --harness fake >/dev/null 2>&1
assert_eq "$(meta_field "$AC_HOME/state/dfam1b-chief.meta" domain)" "" \
  "R2-CR-001: an untokened row mints NO domainchief - inventing a row buys no domain session"
case "$(cat "$(fake_pane_buf dfam1b-chief)")" in
  *AC_DOMAIN*) fail "R2-CR-001: and its launch line carries no AC_DOMAIN" ;;
esac
dom_seed payments dfam1

# AC-3.2 - an UNASSIGNED family is an ordinary roomchief, byte-identically.
# This is the regression guard for every promote in the fleet: the whole
# feature is gated on a resolved domain, so silence here is the contract.
room_seed dfam2
"$BIN/ac-spawn.sh" --roomchief dfam2 --harness fake >/dev/null 2>&1
assert_eq "$(meta_field "$AC_HOME/state/dfam2-chief.meta" domain)" "" \
  "AC-3.2: an unassigned family writes no domain= in its meta"
case "$(cat "$(fake_pane_buf dfam2-chief)")" in
  *AC_DOMAIN*) fail "AC-3.2: an unassigned family's launch line must carry no AC_DOMAIN" ;;
esac

# AC-3.3 - the same id in TWO domain backlogs is corrupt state, not a coin
# flip: refuse fail-closed naming both, before any window, lease or meta.
dom_register infra
dom_seed infra dfam3
mkdir -p "$(dom_pkg payments)/records"
printf '# Backlog: payments\n\n## In flight\n\n## Queued\n\n- [ ] dfam3 - also here; assigned:crewchief (repo: proj)\n\n## Done\n' \
  >"$(dom_pkg payments)/records/backlog.md"
room_seed dfam3
err="$("$BIN/ac-spawn.sh" --roomchief dfam3 --harness fake 2>&1 || true)"
assert_contains "$err" "payments" "AC-3.3: the refusal names the first domain"
assert_contains "$err" "infra" "AC-3.3: and the second"
assert_no_file "$AC_HOME/state/dfam3-chief.meta" "AC-3.3: refused before any meta was written"

# AC-3.4 - the GHOST DOMAIN. Retirement is a manual records act, so a package
# whose registry line was removed while it still holds rows would otherwise go
# on minting domainchiefs forever - a domain nothing routes to and nothing
# lists. The derivation demands a VALID entry, symmetric with assign.
dom_seed ghosts dfam4
room_seed dfam4
err="$("$BIN/ac-spawn.sh" --roomchief dfam4 --harness fake 2>&1 || true)"
assert_contains "$err" "crewdomains/ghosts" "AC-3.4: the refusal names the package path"
assert_contains "$err" "unassign" "AC-3.4: and the unassign-and-clean remedy"
assert_contains "$err" "crewdomains.md" "AC-3.4: and the restore-the-registry-line remedy"
assert_no_file "$AC_HOME/state/dfam4-chief.meta" "AC-3.4: refused before any window, lease or meta"

# An INVALID registry line is not a VALID entry either - same refusal, so a
# typo in the ledger cannot quietly authorize a binding.
printf -- '- ghosts - a charter - home: /wrong - scope: x (added 2026-08-02T00:00:00Z)\n' >>"$dom_reg"
err="$("$BIN/ac-spawn.sh" --roomchief dfam4 --harness fake 2>&1 || true)"
assert_contains "$err" "crewdomains/ghosts" "AC-3.4: an INVALID line is not a VALID entry"
assert_no_file "$AC_HOME/state/dfam4-chief.meta" "AC-3.4: and still nothing is written"

# AC-10.1/AC-10.2 - a domain family is an ORDINARY promote: it passes through
# the existing room-parallel counter with no cap code changed, so it is refused
# at the cap exactly like any other family. Asserted here rather than by editing
# tests/ac-room-parallel-cap.test.sh, because no cap CODE changes.
printf '1\n' >"$AC_HOME/config/room-parallel"
dom_seed payments dfam5
room_seed dfam5
err="$("$BIN/ac-spawn.sh" --roomchief dfam5 --harness fake 2>&1 || true)"
assert_contains "$err" "room-parallel" "AC-10.1: a domain family is refused at the FLEET cap like any other"
assert_no_file "$AC_HOME/state/dfam5-chief.meta" "AC-10.2: no path starts a domain family around the counter"
rm -f "$AC_HOME/config/room-parallel"

# --- the DOMAINCHIEF kickoff (R4, R8, R10) -----------------------------------
# Every clause below is a contract that lives ONLY here - there is no file on
# disk a domainchief would otherwise find it in - so each one is asserted
# against the pane buffer. A kickoff clause that silently disappears in a later
# edit is a duty nobody performs and nothing catches.

dom_seed payments dfam6
room_seed dfam6
"$BIN/ac-spawn.sh" --roomchief dfam6 --harness fake >/dev/null 2>&1
kick="$(cat "$(fake_pane_buf dfam6-chief)")"

# (1) standing rules - the FLEET captain file, plus the prefix convention. The
# domain has no captain.md of its own; asserting its ABSENCE is the regression
# guard against re-adding the member.
assert_contains "$kick" "STANDING (domain:payments): " "(1) the kickoff names the domain standing-rule convention"
assert_contains "$kick" "FLEET records/captain.md" "(1) and points at the fleet captain file as the base"
case "$kick" in
  *"crewdomains/payments/captain.md"*) fail "(1) the kickoff must name NO package captain.md" ;;
esac

# (2) learnings - the FLEET ledger with a filterable prefix. The domain has no
# learnings.md, so a clause pointing at one would send lessons nowhere.
assert_contains "$kick" "(domain:payments)" "(2) lessons carry the domain prefix"
assert_contains "$kick" "FLEET records/learnings.md" "(2) and go to the fleet ledger"
case "$kick" in
  *"crewdomains/payments/records/learnings.md"*) fail "(2) the kickoff must name NO domain learnings ledger" ;;
esac

# (3) projects, membership - the view, and that work outside it is REFUSED.
assert_contains "$kick" "crewdomains/payments/projects/" "(3) the kickoff names the project view"
assert_contains "$kick" "REFUSED" "(3) and says work outside it is refused"

# (4) projects, detail - required reading, with both boundaries stated: the
# fleet registry keeps [mode] and the description, and code facts belong in the
# repo-knowledge store.
assert_contains "$kick" "crewdomains/payments/records/projects.md" "(4) the detail file is required reading"
assert_contains "$kick" "[mode]" "(4) the fleet registry stays authoritative for [mode]"
assert_contains "$kick" "records/repo-knowledge/" "(4) and code facts belong in the repo-knowledge store"

# (5) backlog - move the row, never mint one.
assert_contains "$kick" "crewdomains/payments/records/backlog.md" "(5) the domain backlog is named"
assert_contains "$kick" "assigned:crewchief" "(5) and the provenance token that makes a minted row detectable"

# (6) overlap - fleet-wide, because the domain shares the fleet's clones.
assert_contains "$kick" "ac-ready.sh overlap" "(6) the overlap duty is named"
assert_contains "$kick" "git status" "(6) including the live-lease half"

# (7) handback - the ordinary roomchief channel, no domain-specific one.
assert_contains "$kick" "ac-room.sh handback dfam6" "(7) the hand-back channel is the roomchief's own"

# (8) distil before handback - two classes, and with no domain ledger the fold
# into the curated files is the ONLY per-domain memory write path.
assert_contains "$kick" "crewdomains/payments/CREWMATE.md" "(8) the distil target is named"
assert_contains "$kick" "ONLY per-domain memory write path" "(8) and why it is load-bearing"

# (9) ABSENCE - a promote with no domain emits none of it. dfam2 above is that
# promote; its buffer must carry no domain section at all.
nodom="$(cat "$(fake_pane_buf dfam2-chief)")"
for needle in 'DOMAINCHIEF' 'STANDING (domain:' 'crewdomains/'; do
  case "$nodom" in
    *"$needle"*) fail "(9) an ordinary roomchief's kickoff must not carry '$needle'" ;;
  esac
done

# AC-4.2 - an absent overlay is not an error, asserted as BEHAVIOUR not prose:
# a domain whose detail file is empty and whose CREWMATE.md does not exist still
# promotes. Nothing in the read path may require an overlay to exist.
dom_register bare
dom_seed bare dfam7
: >"$(dom_pkg bare)/records/projects.md"
rm -f "$(dom_pkg bare)/CREWMATE.md"
room_seed dfam7
"$BIN/ac-spawn.sh" --roomchief dfam7 --harness fake >/dev/null 2>&1
assert_eq "$(meta_field "$AC_HOME/state/dfam7-chief.meta" domain)" "bare" \
  "AC-4.2: a domain with no CREWMATE.md and an empty detail file still promotes"

# --- AC-12.2 / CR-007: the crew-spawn view guard -----------------------------
# A view nothing enforces is decoration. The refusal sits immediately after the
# project resolves and before the worktree lease, so a wrong-project spawn costs
# no slot. It reads MEMBERSHIP through ac_domain_view_entry - the same predicate
# `ac-domain.sh validate` reports with - not mere existence: a plain directory
# and a link resolving outside the fleet clones both EXIST and are both invalid.
#
# The view can only ever select from $AC_HOME/projects/, so the fixture repo
# lives there; $repo above sits in $TMP and is deliberately NOT a fleet clone.
vproj="$AC_HOME/projects/vproj"
git init -q -b main "$vproj"
git -C "$vproj" config user.email t@t; git -C "$vproj" config user.name t
printf 'x\n' >"$vproj/f.txt"; git -C "$vproj" add -A; git -C "$vproj" commit -qm init
mkdir -p "$(dom_pkg bare)/projects"            # a domain whose view is EMPTY
lease_count() { find "$vproj/.crew/worktrees" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ' || true; }

"$BIN/ac-brief.sh" outsider vproj --mode local-only >/dev/null 2>&1 || true
slots_before="$(lease_count)"
err="$(AC_DOMAIN=bare "$BIN/ac-spawn.sh" outsider "$vproj" --harness fake 2>&1 || true)"
assert_contains "$err" "project view" "AC-12.2: the refusal names the view"
assert_contains "$err" "bare" "AC-12.2: and the domain"
assert_eq "$(lease_count)" "$slots_before" \
  "AC-12.2: refused BEFORE any lease - no worktree slot was taken"
assert_no_file "$AC_HOME/state/outsider.meta" "AC-12.2: and no meta was written"

# CR-007 - EXISTS is not MEMBERSHIP. A plain directory...
mkdir -p "$(dom_pkg bare)/projects/vproj"
err="$(AC_DOMAIN=bare "$BIN/ac-spawn.sh" outsider "$vproj" --harness fake 2>&1 || true)"
assert_contains "$err" "not-symlink" "CR-007: a plain directory in the view is refused, naming the class"
assert_no_file "$AC_HOME/state/outsider.meta" "CR-007: and nothing was written"
rmdir "$(dom_pkg bare)/projects/vproj"

# ... and a live link pointing OUTSIDE the fleet clones.
ln -s "$repo" "$(dom_pkg bare)/projects/vproj"
err="$(AC_DOMAIN=bare "$BIN/ac-spawn.sh" outsider "$vproj" --harness fake 2>&1 || true)"
assert_contains "$err" "outside" "CR-007: a link resolving outside the fleet clones is refused"
assert_no_file "$AC_HOME/state/outsider.meta" "CR-007: and nothing was written"
rm -f "$(dom_pkg bare)/projects/vproj"

# A PROPER view entry spawns normally - so the guard is the membership check,
# not a blanket refusal of every domain-bound spawn.
ln -s "../../../projects/vproj" "$(dom_pkg bare)/projects/vproj"
AC_DOMAIN=bare "$BIN/ac-spawn.sh" outsider "$vproj" --harness fake >/dev/null 2>&1
assert_file "$AC_HOME/state/outsider.meta" "AC-12.2: a project properly INSIDE the view spawns normally"
rm -f "$(dom_pkg bare)/projects/vproj"

# And a spawn with NO AC_DOMAIN never meets the guard at all: every domain
# effect is gated on the binding, so an ordinary crew spawn is unchanged.
rm -f "$(dom_pkg bare)/projects/$(basename "$repo")"
"$BIN/ac-brief.sh" outsider2 vproj --mode local-only >/dev/null 2>&1 || true
err="$("$BIN/ac-spawn.sh" outsider2 "$vproj" --harness fake 2>&1 || true)"
case "$err" in *"project view"*) fail "AC-12.2: a spawn with no AC_DOMAIN must not meet the view guard" ;; esac

pass
