#!/usr/bin/env bash
# ac-rig.test.sh - the rig manifest drift check (bin/ac-rig.sh drift).
#
# Every case here BREAKS EXACTLY ONE entry against a manifest that otherwise
# matches reality, then pins the divergence line AND the exit code. A drift
# checker is only worth its exit code if a false OK is impossible, so the
# clean-run case is asserted just as hard as the broken ones.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

RIG="$AC_HOME/records/rig.json"

seed_reality() {
  # The home helpers.sh already made, brought into agreement with the manifest
  # write_manifest emits: a distro checkout the pointer names, four config
  # files, and two declared standing jobs.
  [ -n "${root:-}" ] || root="$(make_repo distro)"
  printf '%s\n' "$root" >"$AC_HOME/state/.ac-root"
  printf 'direct\n' >"$AC_HOME/config/flow"
  printf 'always\n' >"$AC_HOME/config/promote"
  printf 'herdr\n' >"$AC_HOME/config/backend"
  cat >"$AC_HOME/records/standing-jobs.md" <<'EOF'
# Standing jobs (fixture)

- alpha-job [on] cadence:30m recreate:CronCreate an alpha job
- beta-job [off] cadence:hourly recreate:CronCreate a beta job (disabled)
EOF
}

write_manifest() {
  # write_manifest [<distro-path>] - the matching manifest; the argument
  # overrides only the declared checkout, so one case can break one entry.
  # wedge-alarm is not fixture dressing: helpers.sh seeds it into every test
  # home, so leaving it undeclared makes the closure check fire on it. That it
  # DID fire the first time this ran is the closure direction working.
  cat >"$RIG" <<EOF
{
  "home": { "name": "$(basename "$AC_HOME")", "path": "$AC_HOME" },
  "wiring": { "distro_checkout": "${1:-$root}" },
  "config": {
    "knobs": [
      { "name": "flow", "value": "direct" },
      { "name": "promote", "value": "always" },
      { "name": "backend" },
      { "name": "wedge-alarm" },
      { "name": "scene-max", "state": "default" }
    ]
  },
  "standing_jobs": [ "alpha-job", "beta-job" ]
}
EOF
}

drift_run() {
  # drift_run - set `out` and `rc` from one invocation, without tripping the
  # suite's errexit on the non-zero the verb returns BY DESIGN when it finds
  # drift. Every case reads both, so capturing them separately would let the
  # two disagree.
  rc=0
  out="$("$BIN/ac-rig.sh" drift 2>&1)" || rc=$?
}

# --- 1. a matching rig: every class OK, liveness honestly unverifiable -------
seed_reality
write_manifest
drift_run
assert_eq "$rc" "0" "a matching rig exits 0"
assert_contains "$out" "OK: home/$(basename "$AC_HOME")" "the home header binds and passes"
assert_contains "$out" "OK: wiring/distro_checkout" "the declared checkout matches state/.ac-root"
assert_contains "$out" "OK: config/flow" "a pinned knob whose value matches passes"
assert_contains "$out" "OK: config/backend" "an inventory knob present on disk passes"
assert_contains "$out" "OK: config/scene-max" "a knob declared absent and absent passes"
assert_contains "$out" "OK: standing_jobs/alpha-job" "a job in both declarations passes"
assert_contains "$out" "UNVERIFIABLE: standing_jobs/liveness" "job liveness is reported unverifiable, never OK"
assert_contains "$out" "CronList" "the unverifiable line names the act that would settle it"
assert_contains "$out" "0 drift" "a matching rig reports no drift"
case "$out" in
  *"DRIFT:"*) fail "a matching rig must print no DRIFT line, got: $out" ;;
esac

# --- 2. UNVERIFIABLE never counts as OK, and never fails the run ------------
# The liveness line is unverifiable on a rig with nothing wrong, so the tally
# must carry it in its own column rather than folding it into ok.
assert_contains "$out" "1 unverifiable" "the unverifiable verdict has its own count"

# --- 3. the home binding refuses rather than measuring the wrong rig --------
write_manifest
sed "s#\"path\": \"$AC_HOME\"#\"path\": \"/nowhere/other-home\"#" "$RIG" >"$RIG.tmp" && mv "$RIG.tmp" "$RIG"
drift_run
assert_eq "$rc" "2" "a manifest naming another home refuses (exit 2), never measures"
assert_contains "$out" "/nowhere/other-home" "the refusal names the declared home"
assert_contains "$out" "$AC_HOME" "the refusal names the home actually being measured"
case "$out" in
  *"OK: config/"*) fail "a refused run must not grade any class, got: $out" ;;
esac

# --- 4. wiring: the declared checkout disagrees with state/.ac-root ---------
write_manifest "/somewhere/else"
drift_run
assert_eq "$rc" "1" "one drifted entry exits 1"
assert_contains "$out" "DRIFT: wiring/distro_checkout" "the drifted checkout is named by class and entry"
assert_contains "$out" "/somewhere/else" "the DRIFT line quotes the declared value"
assert_contains "$out" "$root" "the DRIFT line quotes the value reality actually holds"
assert_contains "$out" "1 drift" "the tally counts exactly the one broken entry"

# --- 5. wiring: an unseeded pointer is UNVERIFIABLE, never a silent fallback -
# ac_root() would answer here, but it returns whichever checkout owns the
# INVOKED bin/ - so falling back to it would grade the caller, not the rig.
write_manifest
rm -f "$AC_HOME/state/.ac-root"
drift_run
assert_eq "$rc" "0" "an unverifiable entry does not fail the run"
assert_contains "$out" "UNVERIFIABLE: wiring/distro_checkout" "an unseeded pointer is unverifiable, not drift"
assert_contains "$out" "ac-remote.sh" "the line names what would seed the pointer"
case "$out" in
  *"OK: wiring/distro_checkout"*) fail "an unseeded pointer must never grade OK, got: $out" ;;
esac
printf '%s\n' "$root" >"$AC_HOME/state/.ac-root"

# --- 6. config: a pinned value moved on disk --------------------------------
write_manifest
printf 'staged\n' >"$AC_HOME/config/flow"
drift_run
assert_eq "$rc" "1" "a moved pinned value exits 1"
assert_contains "$out" "DRIFT: config/flow" "the moved pin is named"
assert_contains "$out" "direct" "the DRIFT line quotes the declared value"
assert_contains "$out" "staged" "the DRIFT line quotes the value on disk"
printf 'direct\n' >"$AC_HOME/config/flow"

# --- 7. config: a pinned value differing only by trailing whitespace is NOT
#        drift - ac_config_read trims, so a byte compare would cry wolf.
write_manifest
printf 'direct   \n' >"$AC_HOME/config/flow"
drift_run
assert_eq "$rc" "0" "trailing whitespace no reader can see is not drift"
assert_contains "$out" "OK: config/flow" "the trimmed value still matches its pin"
printf 'direct\n' >"$AC_HOME/config/flow"

# --- 8. config closure, direction A: a file nobody declared -----------------
write_manifest
printf 'x\n' >"$AC_HOME/config/undeclared-knob"
drift_run
assert_eq "$rc" "1" "an undeclared config file exits 1"
assert_contains "$out" "DRIFT: config/undeclared-knob" "the undeclared file is named"
assert_contains "$out" "records/rig.json" "the fix names the manifest to add it to"
rm -f "$AC_HOME/config/undeclared-knob"

# --- 9. config closure, direction B: a declared knob with no file -----------
write_manifest
rm -f "$AC_HOME/config/backend"
drift_run
assert_eq "$rc" "1" "a declared knob with no file exits 1"
assert_contains "$out" "DRIFT: config/backend" "the vanished knob is named"
printf 'herdr\n' >"$AC_HOME/config/backend"

# --- 10. config: a knob declared ABSENT that has grown a file ---------------
# `state: default` is a positive declaration ("this fleet takes the reader's
# default"), so a file appearing under it is a real change of posture.
write_manifest
printf '99\n' >"$AC_HOME/config/scene-max"
drift_run
assert_eq "$rc" "1" "a knob declared absent that now has a file exits 1"
assert_contains "$out" "DRIFT: config/scene-max" "the knob that stopped taking the default is named"
rm -f "$AC_HOME/config/scene-max"

# --- 11. config closure ignores structural entries, not knobs ---------------
# config/ legitimately holds a captain-veto sidecar, a dotted receipt log and
# directories. None is a knob, and reporting them would train the reader to
# ignore the verb.
write_manifest
printf 'old\n' >"$AC_HOME/config/flow.prev"
printf 'log\n' >"$AC_HOME/config/.dash-edits.log"
mkdir -p "$AC_HOME/config/projects"
drift_run
assert_eq "$rc" "0" "a .prev sidecar, a dotfile and a directory are not drift"
case "$out" in
  *"flow.prev"* | *".dash-edits.log"* | *"config/projects"*) fail "structural config entries must not be reported: $out" ;;
esac
rm -f "$AC_HOME/config/flow.prev" "$AC_HOME/config/.dash-edits.log"
rmdir "$AC_HOME/config/projects"

# --- 12. standing jobs, direction A: declared here, absent from the record --
write_manifest
sed 's/"alpha-job", "beta-job"/"alpha-job", "beta-job", "ghost-job"/' "$RIG" >"$RIG.tmp" && mv "$RIG.tmp" "$RIG"
drift_run
assert_eq "$rc" "1" "a job in the manifest only exits 1"
assert_contains "$out" "DRIFT: standing_jobs/ghost-job" "the manifest-only job is named"
assert_contains "$out" "standing-jobs.md" "the DRIFT line names the record it is missing from"

# --- 13. standing jobs, direction B: in the record, absent from the manifest -
write_manifest
cat >>"$AC_HOME/records/standing-jobs.md" <<'EOF'
- gamma-job [on] cadence:daily recreate:CronCreate a gamma job
EOF
drift_run
assert_eq "$rc" "1" "a job the manifest never declared exits 1"
assert_contains "$out" "DRIFT: standing_jobs/gamma-job" "the record-only job is named"

# --- 14. the manifest itself is fail-closed ---------------------------------
seed_reality
printf 'not json at all\n' >"$RIG"
assert_fails_with "records/rig.json" -- "$BIN/ac-rig.sh" drift
rc=0; "$BIN/ac-rig.sh" drift >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "an unparseable manifest refuses (exit 2), never reports OK"

rm -f "$RIG"
drift_run
assert_eq "$rc" "2" "an absent manifest refuses (exit 2)"
assert_contains "$out" "records/rig.json" "the refusal names the file it needs"

# --- 15. usage ---------------------------------------------------------------
write_manifest
assert_fails_with "usage" -- "$BIN/ac-rig.sh" bogus-verb
rc=0; "$BIN/ac-rig.sh" bogus-verb >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "an unknown verb exits 2"

# --- 16. a pinned value carrying a backslash is compared as WRITTEN ---------
# jq's @tsv escapes `\`, tab and newline, and `read -r` never un-escapes them,
# so a correct rig read as drift AND the emitted fix wrote the escaped bytes
# back - following the remedy corrupted the knob.
seed_reality
write_manifest
printf 'a\\b\n' >"$AC_HOME/config/backslash-knob"
python3 - "$RIG" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["config"]["knobs"].append({"name": "backslash-knob", "value": "a\\b"})
json.dump(d, open(p, "w"), indent=2)
PY
drift_run
assert_eq "$rc" "0" "a pinned value containing a backslash matches itself"
assert_contains "$out" "OK: config/backslash-knob" "the backslash value is compared raw, not escaped"
rm -f "$AC_HOME/config/backslash-knob"

# --- 17. a pinned EMPTY value is a pin, not a presence-only row -------------
# `gate-model` and friends are documented as "absent = the engine default", so
# pinning the empty string is a real declaration. Keying the branch on a
# non-empty string made it silently degrade to an inventory check.
write_manifest
: >"$AC_HOME/config/gate-model"
python3 - "$RIG" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["config"]["knobs"].append({"name": "gate-model", "value": ""})
json.dump(d, open(p, "w"), indent=2)
PY
drift_run
assert_eq "$rc" "0" "an empty file matches a pinned empty value"
assert_contains "$out" "OK: config/gate-model" "the empty pin is compared, not skipped"
printf 'gpt\n' >"$AC_HOME/config/gate-model"
drift_run
assert_eq "$rc" "1" "a value appearing under a pinned-empty knob is drift"
assert_contains "$out" "DRIFT: config/gate-model" "the pinned-empty knob is graded, not treated as inventory"
rm -f "$AC_HOME/config/gate-model"

# --- 18. an undeclared wiring key is never graded clean ---------------------
# `[ -n "$declared" ] || return 0` meant a one-character typo in the key
# (`distro-checkout`) disabled the whole class with no line at all - the false
# OK this verb's own fail direction calls the unrecoverable one.
write_manifest
python3 - "$RIG" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.pop("wiring", None)
json.dump(d, open(p, "w"), indent=2)
PY
drift_run
assert_contains "$out" "UNVERIFIABLE: wiring/distro_checkout" "an undeclared checkout is reported, never silently skipped"
case "$out" in
  *"0 unverifiable"*) fail "a class with no verdict must not vanish from the tally: $out" ;;
esac

# --- 19. an unreadable standing-jobs record REFUSES, never grades ------------
# An empty id list is indistinguishable from "no jobs declared", so swallowing
# the read failure reported every declared job as drift with a fix that names
# a line already sitting in the file.
write_manifest
chmod 000 "$AC_HOME/records/standing-jobs.md"
drift_run
chmod 644 "$AC_HOME/records/standing-jobs.md"
assert_eq "$rc" "2" "an unreadable standing-jobs record refuses (exit 2)"
case "$out" in
  *"DRIFT: standing_jobs/"*) fail "an unreadable record must produce no job findings: $out" ;;
esac

# --- 20. home.name is CHECKED, not merely echoed ----------------------------
# The manifest declared a field nothing compared - the seed of the very drift
# this file exists to catch.
write_manifest
python3 - "$RIG" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["home"]["name"] = "some-other-fleet"
json.dump(d, open(p, "w"), indent=2)
PY
drift_run
assert_eq "$rc" "2" "a manifest naming another fleet refuses, like a wrong path does"
assert_contains "$out" "some-other-fleet" "the refusal quotes the declared name"

# --- 21. no home is a REFUSAL, never a finding ------------------------------
# 1 is this verb's drift code, so a caller branching on the status would read
# "no AC_HOME" as "one entry drifted". Every refusal has to leave 1 alone.
rc=0; out="$(env -u AC_HOME "$BIN/ac-rig.sh" drift 2>&1)" || rc=$?
assert_eq "$rc" "2" "a homeless invocation refuses (exit 2), never reports a drift count"
assert_contains "$out" "AC_HOME" "the refusal names what is missing"

pass
