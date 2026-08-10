#!/usr/bin/env bash
# ac-spawn-model-effort.test.sh - crewmate model/effort setup:
#   - an invalid effort fails fast for the RIGHT reason (before brief/lease),
#   - absent config + absent flag => neither --model nor --effort is emitted,
#   - fleet-wide config/model + config/effort defaults flow into the claude
#     launch line and are recorded in the meta,
#   - a per-spawn --model / --effort overrides the config default,
#   - the --effort FLAG is claude-only: the BUILT-IN codex branch gets -m and
#     the effort as `-c model_reasoning_effort=<e>`, never --effort, and its
#     meta records that tier; opencode's TUI applies no effort, so its meta
#     carries none.
#   - effort=ultracode launches at --effort xhigh (never --effort ultracode),
#     records effort=ultracode in the meta, and types '/effort ultracode' into
#     the built-in claude TUI before the kickoff prompt; codex and custom
#     launch-claude templates get no slash line.
# Launch-line checks read the fake herdr pane buffer (tests/helpers.sh):
# what ac-spawn typed sits there VERBATIM, nothing executes it.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
repo="$(make_repo proj)"

# --- validation: an invalid effort dies at the early effort check, and the
# error names effort (proving it fails BEFORE the missing-brief/project checks,
# not merely with some non-zero exit). ----------------------------------------
err="$("$BIN/ac-spawn.sh" e1 proj --effort bogus 2>&1 1>/dev/null || true)"
assert_contains "$err" "invalid effort: bogus" "invalid effort fails for the right reason"

# --- a malformed AC_ULTRACODE_SETTLE fails an ultracode spawn up-front (before
# any window/lease). A brief is required because effort validation passes for
# ultracode and the check sits past the brief gate. ----------------------------
"$BIN/ac-brief.sh" us proj --mode local-only >/dev/null
err="$(AC_ULTRACODE_SETTLE=x "$BIN/ac-spawn.sh" us proj --effort ultracode 2>&1 1>/dev/null || true)"
assert_contains "$err" "AC_ULTRACODE_SETTLE must be a non-negative number" "bad AC_ULTRACODE_SETTLE fails fast"

# --- a malformed AC_KICKOFF_READY_BUDGET fails the same way, up-front --------
err="$(AC_KICKOFF_READY_BUDGET=x "$BIN/ac-spawn.sh" us proj 2>&1 1>/dev/null || true)"
assert_contains "$err" "AC_KICKOFF_READY_BUDGET must be a non-negative integer" "bad AC_KICKOFF_READY_BUDGET fails fast"

# Deliver the kickoff prompt immediately (default 8s) so the suite stays fast.
export AC_SPAWN_SETTLE=0
export AC_ULTRACODE_SETTLE=0
# Every pane here clears the composer-ready observation (bin/ac-spawn.sh
# kickoff_wait_input_ready) immediately - this suite is not testing that gate
# (tests/ac-spawn-kickoff-ready.test.sh owns it), it just needs its spawns to
# complete without a real harness's boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5

# claude + codex + opencode stubs so the harness spawns below pass ac-spawn's
# command -v check; the fake herdr never executes the launch line.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/codex"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/opencode"
chmod +x "$TMP/stub/claude" "$TMP/stub/codex" "$TMP/stub/opencode"
export PATH="$TMP/stub:$PATH"

# A fake harness (custom template); its text sits unexecuted in the buffer.
printf 'echo crew __ID__ reading __BRIEF__; sleep 300\n' >"$AC_HOME/config/launch-fake"

launch_line() { cat "$(fake_pane_buf "$1")"; }

# --- absent config + absent flag => the launch line carries NEITHER opt -------
# (run before config/model + config/effort are written).
# m0 asserts the DERIVED review obligation rides the launch line, so it needs
# a mode that derives review=yes - crew-ship, captain-authorized per the
# escalation gate.
"$BIN/ac-brief.sh" m0 proj --mode crew-ship --review yes --captain-requested 'fixture: captain ordered the pipeline' --reason 'fixture: pipeline path under test'  >/dev/null
"$BIN/ac-spawn.sh" m0 "$repo" --harness claude >/dev/null 2>&1
line="$(launch_line m0)"
case "$line" in *"--model "*) fail "no config/flag must emit no --model" ;; esac
case "$line" in *"--effort "*) fail "no config/flag must emit no --effort" ;; esac
case "$line" in *"AC_FLEET_MODEL"*) fail "nothing to pass on must export no AC_FLEET_MODEL" ;; esac
case "$line" in *"AC_FLEET_EFFORT"*) fail "nothing to pass on must export no AC_FLEET_EFFORT" ;; esac
# AC_FLEET_STATE is the completion-push CHANNEL, not a pin: a homeless crewmate
# has no AC_HOME to resolve state/ with, so ac-done.sh reaches the wake spool
# (and the watcher to nudge) through this scalar alone - it rides every
# crewmate launch line, pinned fleet or not. An UNSCOPED spawn adds no scope.
assert_contains "$line" "AC_FLEET_STATE=$AC_HOME/state" "the fleet state dir rides every crewmate launch line"
assert_contains "$line" "AC_CREW_ID=m0" "execution identity rides every crewmate launch line"
assert_contains "$line" "AC_FLEET_REVIEW=yes" "derived review obligation rides the launch line"
assert_eq "$(awk -F= '$1=="review"{print $2}' "$AC_HOME/state/m0.meta")" yes \
  "derived review obligation is recorded in crew meta"
case "$line" in *"AC_FLEET_SCOPE"*) fail "an unscoped spawn must export no AC_FLEET_SCOPE" ;; esac
assert_eq "$(awk -F= '$1=="fleet_scope"{print $2}' "$AC_HOME/state/m0.meta")" "" \
  "an unscoped spawn records no fleet_scope (byte-identical meta for a non-epic task)"
# AC_FLEET_NAME rides the same rung and for the same reason: with no AC_HOME the
# herdr workspace label a crewmate's observation tabs resolve (ac_fleet_name)
# fell back to the one group every fleet on the box shares. The fixture home is
# $TMP/home, so the fleet is "home".
assert_contains "$line" "AC_FLEET_NAME=home" "the fleet name rides every crewmate launch line"
# The codegraph front-load prompt-hook kill-switch rides the same rung: not a
# pin, so it is on EVERY crew launch line, pinned fleet or not.
assert_contains "$line" "CODEGRAPH_NO_PROMPT_HOOK=1" \
  "the codegraph prompt-hook kill-switch rides every crewmate launch line"
"$BIN/ac-teardown.sh" m0 --force >/dev/null 2>&1

# Direct local-only defaults review off, while still carrying an explicit
# obligation so the execution crewmate never guesses from the mode again.
"$BIN/ac-brief.sh" mreview proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" mreview "$repo" --harness claude --mode local-only >/dev/null 2>&1
line="$(launch_line mreview)"
assert_contains "$line" "AC_CREW_ID=mreview" "direct execution carries its caller identity"
assert_contains "$line" "AC_FLEET_REVIEW=no" "direct local-only carries review=no"
assert_eq "$(awk -F= '$1=="review"{print $2}' "$AC_HOME/state/mreview.meta")" no \
  "review=no is recorded in crew meta"
"$BIN/ac-teardown.sh" mreview --force >/dev/null 2>&1

# --- a ROOMCHIEF's spawn carries its family scope, so the crewmate's push
# files for the scoped watcher that supervises it (and nudges THAT one) ------
mkdir -p "$AC_HOME/data/fam9"
"$BIN/ac-brief.sh" fam9-t1 proj --mode local-only >/dev/null
AC_SCOPE=fam9 "$BIN/ac-spawn.sh" fam9-t1 "$repo" --harness claude >/dev/null 2>&1
line="$(launch_line fam9-t1)"
assert_contains "$line" "AC_FLEET_SCOPE=fam9" "a scoped spawn carries the family whose watcher covers the task"
# ... and records it ON DISK: the fleet watcher's skip logic reads the crew
# meta (never the backlog in its hot poll loop) to route a story pane's backup
# poll to the epic roomchief instead of the fleet
# (epic-roomchief-watch-only-omits-story-ids).
assert_eq "$(awk -F= '$1=="fleet_scope"{print $2}' "$AC_HOME/state/fam9-t1.meta")" fam9 \
  "a scoped spawn records fleet_scope in crew meta"
"$BIN/ac-teardown.sh" fam9-t1 --force >/dev/null 2>&1

# --- fleet-wide defaults: config/model + config/effort reach the launch line --
printf 'sonnet\n' >"$AC_HOME/config/model"
printf 'high\n' >"$AC_HOME/config/effort"
"$BIN/ac-brief.sh" m1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" m1 "$repo" --harness claude >/dev/null 2>&1
line="$(launch_line m1)"
assert_contains "$line" "--model sonnet" "config/model default on claude launch line"
assert_contains "$line" "--effort high" "config/effort default on claude launch line"
assert_eq "$(awk -F= '$1=="model"{print $2}' "$AC_HOME/state/m1.meta")" sonnet "model recorded in meta"
assert_eq "$(awk -F= '$1=="effort"{print $2}' "$AC_HOME/state/m1.meta")" high "effort recorded in meta"
# The crewmate carries the fleet's knobs FORWARD in two narrow env scalars: the
# pane agents it later starts (ship reviewer, qa) have no AC_HOME to resolve
# config/ with, so without these they judge on claude's own default.
assert_contains "$line" "AC_FLEET_MODEL=sonnet" "crewmate launch line carries the fleet model forward"
assert_contains "$line" "AC_FLEET_EFFORT=high" "crewmate launch line carries the fleet effort forward"
"$BIN/ac-teardown.sh" m1 --force >/dev/null 2>&1

# --- per-spawn flags override the config defaults ------------------------------
"$BIN/ac-brief.sh" m2 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" m2 "$repo" --harness claude --model opus --effort max >/dev/null 2>&1
line="$(launch_line m2)"
assert_contains "$line" "--model opus" "--model flag overrides config/model"
assert_contains "$line" "--effort max" "--effort flag overrides config/effort"
"$BIN/ac-teardown.sh" m2 --force >/dev/null 2>&1

# --- the --effort FLAG stays claude-only, but the effort itself now reaches the
# BUILT-IN codex branch as codex's own config override: codex has no --effort
# flag, so `-c model_reasoning_effort=<e>` is its only form (contract:
# ac_build_launch in bin/ac-backend.sh). config/effort=high is still set, so
# this proves the effort TRAVELS rather than merely being unset.
# The meta follows: ac_record_launch_opts (bin/ac-harness.sh) records what a
# harness's built-in template applies, and codex's template applies the effort -
# so the meta names the tier the process actually received. ---------------------
"$BIN/ac-brief.sh" mc proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" mc "$repo" --harness codex --model cmod >/dev/null 2>&1
line="$(launch_line mc)"
assert_contains "$line" "-m cmod" "codex gets -m on the launch line"
assert_contains "$line" "-c model_reasoning_effort=high" \
  "the fleet effort reaches codex as its config override, not as a dropped flag"
case "$line" in *"--effort"*) fail "built-in codex must not get --effort: the flag does not exist" ;; esac
assert_eq "$(awk -F= '$1=="model"{print $2}' "$AC_HOME/state/mc.meta")" cmod "codex model recorded in meta"
assert_eq "$(awk -F= '$1=="effort"{print $2}' "$AC_HOME/state/mc.meta")" high "codex effort recorded in meta"
"$BIN/ac-teardown.sh" mc --force >/dev/null 2>&1

# --- config/model is harness-specific IN VALUE: a config-fallback model must
# NOT ride onto a resolved harness other than the fleet's own (config/crew-
# harness, unset here so it defaults to claude, same as ac-spawn's own
# fallback) - config/model=sonnet (still set from the block above) is a
# claude-style name, and composing it onto codex as `codex -m sonnet` is a
# model name codex cannot accept. No config/crew-harness is pinned, so codex
# here is a harness OTHER than the fleet's own by construction. --------------
"$BIN/ac-brief.sh" mx proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" mx "$repo" --harness codex >/dev/null 2>&1
line="$(launch_line mx)"
case "$line" in *"-m sonnet"*) fail "a config-fallback model must not ride onto a mismatched harness" ;; esac
case "$line" in *"AC_FLEET_MODEL"*) fail "a dropped model must not export AC_FLEET_MODEL either" ;; esac
assert_eq "$(awk -F= '$1=="model"{print $2}' "$AC_HOME/state/mx.meta")" "" \
  "the dropped model is not recorded in meta (codex got no -m at all)"
"$BIN/ac-teardown.sh" mx --force >/dev/null 2>&1

# --- the same config-fallback model still rides claude, the fleet's own harness -
"$BIN/ac-brief.sh" my proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" my "$repo" --harness claude >/dev/null 2>&1
line="$(launch_line my)"
assert_contains "$line" "--model sonnet" "the fleet's own harness still gets the config-fallback model"
"$BIN/ac-teardown.sh" my --force >/dev/null 2>&1

# --- opencode: the model reaches the TUI as -m, the effort has nowhere to go ---
# opencode's interactive TUI has no `--variant` (it lives on `opencode run`
# only), so config/effort=high must still emit nothing. The meta follows the
# launch line exactly: model recorded, effort not - ac_record_launch_opts records
# only what the built-in template applies.
"$BIN/ac-brief.sh" mo proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" mo "$repo" --harness opencode --model omod >/dev/null 2>&1
line="$(launch_line mo)"
assert_contains "$line" "-m omod" "opencode gets -m on the launch line"
case "$line" in *"--variant"*) fail "the opencode TUI has no --variant: effort must not ride one" ;; esac
assert_eq "$(awk -F= '$1=="model"{print $2}' "$AC_HOME/state/mo.meta")" omod "opencode model recorded in meta"
assert_eq "$(awk -F= '$1=="effort"{print $2}' "$AC_HOME/state/mo.meta")" "" "opencode meta carries no effort"
"$BIN/ac-teardown.sh" mo --force >/dev/null 2>&1

# --- a custom-template harness (verbatim) receives no --effort either ----------
"$BIN/ac-brief.sh" m3 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" m3 "$repo" --harness fake >/dev/null 2>&1
line="$(launch_line m3)"
case "$line" in *"--effort"*) fail "custom-template harness must not get --effort" ;; esac
# ... but it DOES inherit the fleet knobs: the scalars are prefixed outside
# build_launch, so a template emitted verbatim still passes them on.
assert_contains "$line" "AC_FLEET_MODEL=sonnet" "custom-template harness still carries the fleet knobs forward"
"$BIN/ac-teardown.sh" m3 --force >/dev/null 2>&1

# --- effort=ultracode: built-in claude launches at --effort xhigh (NOT
# ultracode), records effort=ultracode, and gets '/effort ultracode' typed in
# BEFORE the kickoff prompt. --------------------------------------------------
"$BIN/ac-brief.sh" u1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" u1 "$repo" --harness claude --effort ultracode >/dev/null 2>&1
line="$(launch_line u1)"
assert_contains "$line" "--effort xhigh" "ultracode launches claude at --effort xhigh"
case "$line" in *"--effort ultracode"*) fail "must never pass --effort ultracode to the CLI" ;; esac
assert_eq "$(awk -F= '$1=="effort"{print $2}' "$AC_HOME/state/u1.meta")" ultracode "meta records effort=ultracode"
# The scalar carries the RAW fleet value, not the mapped flag: what the fleet
# pinned is ultracode, and each consumer maps it for its own surface (a pane
# turn has no TUI, so ac-pane-agent.sh renders it as --effort xhigh).
assert_contains "$line" "AC_FLEET_EFFORT=ultracode" "the raw fleet effort travels in the scalar"
u_ln="$(printf '%s\n' "$line" | grep -n '/effort ultracode' | head -1 | cut -d: -f1)"
p_ln="$(printf '%s\n' "$line" | grep -n 'You are an agent-crew crewmate' | head -1 | cut -d: -f1)"
[ -n "$u_ln" ] || fail "'/effort ultracode' not typed into the pane"
[ -n "$p_ln" ] && [ "$u_ln" -lt "$p_ln" ] || fail "'/effort ultracode' must precede the kickoff prompt"
"$BIN/ac-teardown.sh" u1 --force >/dev/null 2>&1

# --- ultracode is claude-only: codex gets no slash line, no effort in meta -----
"$BIN/ac-brief.sh" uc proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" uc "$repo" --harness codex --effort ultracode >/dev/null 2>&1
line="$(launch_line uc)"
assert_contains "$line" "You are an agent-crew crewmate" "codex ultracode spawn is live (kickoff delivered)"
case "$line" in *"/effort ultracode"*) fail "codex must not get the ultracode slash line" ;; esac
# ultracode is a claude PRESET, not an effort token any CLI accepts: ac-spawn
# maps it to xhigh before the launch mote, so codex receives the reasoning tier
# and never the preset name.
assert_contains "$line" "-c model_reasoning_effort=xhigh" "codex gets ultracode's reasoning tier, xhigh"
case "$line" in *"model_reasoning_effort=ultracode"*) fail "must never pass ultracode to codex as an effort" ;; esac
# ...and the meta names that same APPLIED tier: the slash line withheld above is
# the whole ultracode preset for codex, so effort=ultracode would be a false claim.
assert_eq "$(awk -F= '$1=="effort"{print $2}' "$AC_HOME/state/uc.meta")" xhigh "codex meta records the applied tier, not the preset"
"$BIN/ac-teardown.sh" uc --force >/dev/null 2>&1

# --- a CUSTOM launch-claude template gets no slash line (mirrors the no-effort
# contract for custom templates). --------------------------------------------
printf 'sleep 300\n' >"$AC_HOME/config/launch-claude"
"$BIN/ac-brief.sh" uct proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" uct "$repo" --harness claude --effort ultracode >/dev/null 2>&1
line="$(launch_line uct)"
assert_contains "$line" "You are an agent-crew crewmate" "custom-template ultracode spawn is live (kickoff delivered)"
case "$line" in *"/effort ultracode"*) fail "custom launch-claude must not get the ultracode slash line" ;; esac
"$BIN/ac-teardown.sh" uct --force >/dev/null 2>&1
rm -f "$AC_HOME/config/launch-claude"

# --- ultracode strand: an unacknowledged '/effort ultracode' line WITHHOLDS the
# kickoff prompt (typing it would append to the stranded line and garble both -
# the eaten-kickoff incident shape) and warns loudly. The drop knob targets
# "/effort" (the launch line only carries "--effort", no slash). ---------------
n="$(cat "$FAKE_HERDR/.n")"; upane="p$((n + 1))"
printf '99 /effort\n' >"$FAKE_HERDR/panes/$upane.drop-enters"
"$BIN/ac-brief.sh" u2 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" u2 "$repo" --harness claude --effort ultracode 2>&1)"
assert_contains "$out" "spawned u2" "spawn survives the stranded slash line"
# Needle names the SLASH LINE. ac-spawn.sh:849's GENERIC "kickoff prompt NOT
# acknowledged" contains a bare "NOT acknowledged" too, and a bare needle
# measurably let it answer for this one: with the warning below AND its
# kickoff-withhold deleted, the kickoff was delivered, its Enter was dropped
# in turn, :849 fired - and this assertion stayed green over a warning that
# was gone.
assert_contains "$out" "'/effort ultracode' NOT acknowledged" "stranded '/effort ultracode' warns loudly"
assert_contains "$out" "ac-send.sh u2" "warning names the manual fallback"
assert_contains "$(cat "$FAKE_HERDR/panes/$upane.in")" "/effort ultracode" "slash line sits stranded in the composer"
case "$(cat "$FAKE_HERDR/panes/$upane.in")" in *"You are an agent-crew crewmate"*) \
  fail "the kickoff prompt must be WITHHELD after a stranded slash line" ;; esac
"$BIN/ac-teardown.sh" u2 --force >/dev/null 2>&1

# --- AC_FLEET_HOME_CHECKED / AC_FLEET_PROJECT_CONFIG: ac-spawn.sh resolves the
# project's pipeline config with its OWN real AC_HOME and hands the answer to
# the crewmate, which never gets AC_HOME itself
# (ship-config-and-know-citation-blind-spots) - without this, ac-ship.sh start
# cannot resolve a home at all (ac_home refuses an unset AC_HOME), and before
# it refused it resolved the config-less distro checkout and could never tell
# that miss apart from a project genuinely installed with none. A PINNED key
# (review.model here) must reach the crewmate through this path, not vanish.
mkdir -p "$AC_HOME/projects"
printf 'review:\n  model: opus-pinned\n' >"$AC_HOME/projects/proj.yaml"
"$BIN/ac-brief.sh" mcfg proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" mcfg "$repo" --harness claude >/dev/null 2>&1
line="$(launch_line mcfg)"
assert_contains "$line" "AC_FLEET_HOME_CHECKED=1" "the home-checked signal rides every crewmate launch line"
assert_contains "$line" "AC_FLEET_PROJECT_CONFIG=$AC_HOME/projects/proj.yaml" \
  "the resolved project config path rides the launch line"
"$BIN/ac-teardown.sh" mcfg --force >/dev/null 2>&1

# ...and a project with no installed config still gets the checked signal, with
# no AC_FLEET_PROJECT_CONFIG to go with it - a VERIFIED "none" (a real AC_HOME
# looked and found nothing), never an unresolved home reading the same way.
rm -f "$AC_HOME/projects/proj.yaml"
"$BIN/ac-brief.sh" mnocfg proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" mnocfg "$repo" --harness claude >/dev/null 2>&1
line="$(launch_line mnocfg)"
assert_contains "$line" "AC_FLEET_HOME_CHECKED=1" "home-checked rides even when no config resolved"
case "$line" in *"AC_FLEET_PROJECT_CONFIG"*) fail "no config found must export no AC_FLEET_PROJECT_CONFIG" ;; esac
"$BIN/ac-teardown.sh" mnocfg --force >/dev/null 2>&1

pass
