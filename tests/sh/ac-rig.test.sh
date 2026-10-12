#!/usr/bin/env bash
# ac-rig.test.sh - the rig manifest drift check (bin/ac-rig.sh drift).
#
# Every case here BREAKS EXACTLY ONE entry against a manifest that otherwise
# matches reality, then pins the divergence line AND the exit code. A drift
# checker is only worth its exit code if a false OK is impossible, so the
# clean-run case is asserted just as hard as the broken ones.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
# JSON of the wrong shape refuses the same way, before any check reads it.
for bad in '{"config":{"knobs":["model"]}}' '{"standing_jobs":"monitor"}' '{"home":"drydock"}' '[]'; do
  printf '%s\n' "$bad" >"$RIG"
  rc=0; out="$("$BIN/ac-rig.sh" drift 2>&1)" || rc=$?
  assert_eq "$rc" "2" "a wrong-shaped manifest refuses (exit 2): $bad"
  assert_contains "$out" "wrong shape" "the refusal says what is wrong: $bad"
done

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

# --- differential: src/rig.ts against the frozen bash original ---------------
# DISPUTED: the implementation (tests/fixtures/ac-rig.sh under bash vs src/rig.ts through bin/ac-rig.sh)
# HELD-CONSTANT: the one home (drift only reads it), records/rig.json, state/.ac-root, config/, records/standing-jobs.md, argv, the cwd ($TMP), the environment (SAME_ENV applies to both), LC_ALL=C on both sides; stdout, stderr (the home spelled HOME, the checkout ROOT) and exit status compared whole
# LC_ALL=C because bash 3.2's config/* glob follows libc collation under a UTF-8 locale (row 16 shows it apart) - an outside actor's order, never a contract - while the port walks config/ in byte order, the repo's own `LC_ALL=C sort` idiom.
obin="$(make_oracle_bin ac-rig)"
SAME_ENV=
run_oracle() { (cd "$TMP" && env $SAME_ENV LC_ALL="${1:-C}" "$obin/ac-rig.sh" "${@:2}") >"$TMP/o.raw" 2>"$TMP/o.err"; }
run_shim() { (cd "$TMP" && env $SAME_ENV LC_ALL="${1:-C}" "${SHIM_BIN:-$BIN}/ac-rig.sh" "${@:2}") >"$TMP/n.raw" 2>"$TMP/n.err"; }
spell() { LC_ALL=C sed "s#$AC_HOME#HOME#g; s#$root#ROOT#g" "$1"; }
same() {  # same <args...> - the oracle and the shim answer byte-identically
  local o_rc=0 n_rc=0
  run_oracle C "$@" || o_rc=$?
  run_shim C "$@" || n_rc=$?
  spell "$TMP/o.raw" >"$TMP/o.out"; spell "$TMP/o.err" >"$TMP/o.err2"
  spell "$TMP/n.raw" >"$TMP/n.out"; spell "$TMP/n.err" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*' ($SAME_ENV)"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*' ($SAME_ENV): $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*' ($SAME_ENV): $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
manifest() {
  # manifest [<python dict>] - rig.json rebuilt from the clean manifest of leg
  # 1 with the dict's top-level keys replacing the clean ones (None removes a
  # key; add_knobs / add_jobs append to the clean lists). The dict comes from
  # $1, or from stdin when no argument is given.
  if [ $# -gt 0 ]; then printf '%s\n' "$1" >"$TMP/patch"; else cat >"$TMP/patch"; fi
  python3 - "$RIG" "$AC_HOME" "$root" "$TMP/patch" <<'PY'
import json, sys
p, home, root, patch = sys.argv[1:5]
d = {"home": {"name": home.rsplit("/", 1)[1], "path": home},
     "wiring": {"distro_checkout": root},
     "config": {"knobs": [{"name": "flow", "value": "direct"}, {"name": "promote", "value": "always"},
                          {"name": "backend"}, {"name": "wedge-alarm"}, {"name": "scene-max", "state": "default"}]},
     "standing_jobs": ["alpha-job", "beta-job"]}
for k, v in eval(open(patch).read()).items():
    if k == "add_knobs": d["config"]["knobs"] += v
    elif k == "add_jobs": d["standing_jobs"] += v
    elif v is None: d.pop(k, None)
    else: d[k] = v
json.dump(d, open(p, "w"), indent=2)
PY
}
fresh() {  # the clean rig of leg 1, rebuilt: four config knobs, the pointer, two jobs, the matching manifest
  rm -rf "$AC_HOME/config"; mkdir -p "$AC_HOME/config"; printf 'off\n' >"$AC_HOME/config/wedge-alarm"
  seed_reality; manifest '{}'
}
LIVENESS2="UNVERIFIABLE: standing_jobs/liveness - 2 declared job(s); CronCreate is session-only, so no on-disk signal says whether any of them is scheduled right now - settle it with: CronList in the harness - no shell on this host can answer it"

# 1. the clean rig: every line, in order, and the tally
fresh; same drift
assert_eq "$(shim_out)" "OK: home/home - manifest binds this home (HOME)
OK: wiring/distro_checkout - ROOT (state/.ac-root)
OK: config/flow - pinned value 'direct'
OK: config/promote - pinned value 'always'
OK: config/backend - declared present
OK: config/wedge-alarm - declared present
OK: config/scene-max - declared absent - runs on the reader's default
OK: standing_jobs/alpha-job - declared in records/standing-jobs.md
OK: standing_jobs/beta-job - declared in records/standing-jobs.md
$LIVENESS2
rig: 9 ok, 0 drift, 1 unverifiable" "the clean rig: every line, in order, the tally"

# 2. usage: a second argument, an unknown verb, no verb, an empty verb - stderr only, exit 2
same drift x
assert_eq "$(shim_err)" "ERROR: usage: ac-rig.sh drift" "a second argument refuses"
same drift ''
same bogus
assert_eq "$(shim_err)" "usage: ac-rig.sh drift" "an unknown verb"
same
same ''
assert_eq "$(shim_out)" "" "usage prints nothing on stdout"
# -h/--help: exit 0 and each implementation's OWN spec header on stdout - the
# named divergence: the shim's header is a pointer, so the port prints
# src/rig.ts's, where the original printed its bash header.
for flag in -h --help; do
  o_rc=0; run_oracle C $flag extra || o_rc=$?
  n_rc=0; run_shim C $flag extra || n_rc=$?
  assert_eq "$o_rc $n_rc" "0 0" "$flag: both exit 0"
  assert_eq "$(cat "$TMP/o.err" "$TMP/n.err")" "" "$flag: the header goes to stdout only"
  assert_eq "$(cat "$TMP/o.raw")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-rig.sh" | sed 's/^# \{0,1\}//')" "$flag: the original prints its bash header"
  assert_eq "$(cat "$TMP/n.raw")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/rig.ts" | sed 's/^\/\/ \{0,1\}//')" "$flag: the port prints the src/rig.ts spec header"
done
assert_contains "$(cat "$TMP/n.raw")" "ac-rig.sh drift" "the spec header carries the usage"

# 3. no home: unset, empty, a missing directory, a file - refusal 1, exit 2, the manifest unread
for e in '-u AC_HOME' 'AC_HOME=' 'AC_HOME=/nonexistent/ac-rig' "AC_HOME=$RIG"; do
  SAME_ENV="$e" same drift
  assert_eq "$(shim_err)" "ERROR: AC_HOME is not set - name the fleet home whose records/rig.json to check" "no home ($e)"
  assert_eq "$(shim_out)" "" "no home ($e): nothing graded"
done
SAME_ENV=

# 4. the manifest itself: absent; then what jq makes of it - jq is spawned by
#    both sides, so a value stream, a lone null/false (which fail `jq -e`),
#    `nan`, `//` reading false as null, and every wrong shape are jq's own
#    readings, pinned here rather than re-derived.
rm -f "$RIG"; same drift
assert_eq "$(shim_err)" "ERROR: no rig manifest at records/rig.json - the drift check has nothing to compare against (grammar: the bin/ac-rig.sh header)" "no manifest"
R3="ERROR: records/rig.json does not parse as JSON - fix it; a manifest that cannot be read is never graded clean (grammar: the bin/ac-rig.sh header)"
R4="ERROR: records/rig.json has the wrong shape - home, wiring and config are objects, config.knobs an array of objects, standing_jobs an array (grammar: the bin/ac-rig.sh header)"
R5="ERROR: records/rig.json declares no home.path - the manifest must name the rig it describes"
bad() { printf '%s\n' "$1" >"$RIG"; same drift; assert_eq "$(shim_err)" "$2" "manifest '$1'"; assert_eq "$(shim_out)" "" "manifest '$1': nothing graded"; }
for m in 'not json' '' 'null' 'false'; do bad "$m" "$R3"; done
for m in 'nan' '[]' '"x"' '{"home":"x"}' '{"home":false}' '{"wiring":[]}' '{"config":{"knobs":["m"]}}' '{"config":{"knobs":{}}}' '{"config":{"knobs":[[]]}}' '{"standing_jobs":"m"}' '{"standing_jobs":{}}' '{} 5'; do bad "$m" "$R4"; done
for m in '{}' '{"home":null}' '{"home":{}}' '{"home":{"path":false}}' '{"home":{"path":""}}' '{"home":{"path":null}}' '{} {}' '{"config":null,"standing_jobs":false,"wiring":null}'; do bad "$m" "$R5"; done

# 5. home binding: a `..` spelling and a symlink both canonicalize to the home; AC_HOME through a symlink binds too
fresh
manifest "{'home': {'name': 'home', 'path': '$AC_HOME/../home'}}"; same drift
assert_eq "$(head -n 1 "$TMP/n.out")" "OK: home/home - manifest binds this home (HOME)" "a .. spelling binds"
ln -s "$AC_HOME" "$TMP/homelink"
manifest "{'home': {'name': 'home', 'path': '$TMP/homelink'}}"; same drift
assert_eq "$(head -n 1 "$TMP/n.out")" "OK: home/home - manifest binds this home (HOME)" "a symlink spelling binds"
manifest '{}'
SAME_ENV="AC_HOME=$TMP/homelink" same drift
SAME_ENV=
assert_eq "$(head -n 1 "$TMP/n.out")" "OK: home/home - manifest binds this home (HOME)" "AC_HOME through a symlink: the physical home binds and names the fleet"
rm -f "$TMP/homelink"

# 6. the wrong rig: another path (6), no name (7), another name (8) - nothing graded
manifest "{'home': {'name': 'home', 'path': '/nowhere'}}"; same drift
assert_eq "$(shim_err)" "ERROR: records/rig.json describes /nowhere but AC_HOME is HOME - refusing to grade one rig against another" "refusal 6"
for h in "{'path': '$AC_HOME'}" "{'name': '', 'path': '$AC_HOME'}" "{'name': False, 'path': '$AC_HOME'}"; do
  manifest "{'home': $h}"; same drift
  assert_eq "$(shim_err)" "ERROR: records/rig.json declares no home.name - the manifest must name the rig it describes" "refusal 7 ($h)"
done
manifest "{'home': {'name': 'other', 'path': '$AC_HOME'}}"; same drift
assert_eq "$(shim_err)" "ERROR: records/rig.json calls this fleet 'other' but it is 'home' - refusing to grade one rig against another" "refusal 8"
manifest "{'home': {'name': 7, 'path': '$AC_HOME'}}"; same drift
assert_eq "$(shim_err)" "ERROR: records/rig.json calls this fleet '7' but it is 'home' - refusing to grade one rig against another" "refusal 8, a number as jq spells it"
assert_eq "$(shim_out)" "" "a refused run grades nothing"

# 7. wiring: the five shapes, and the pointer's spellings
fresh
for w in "{'wiring': None}" "{'wiring': {}}" "{'wiring': {'distro_checkout': ''}}" "{'wiring': {'distro_checkout': False}}"; do
  manifest "$w"; same drift
  assert_eq "$(sed -n 2p "$TMP/n.out")" "UNVERIFIABLE: wiring/distro_checkout - records/rig.json declares no wiring.distro_checkout, so there is nothing to compare the fleet's checkout against - settle it with: declare it in records/rig.json (grammar: the bin/ac-rig.sh header)" "undeclared checkout ($w)"
done
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 8 ok, 0 drift, 2 unverifiable" "an undeclared checkout: exit 0, counted"
manifest '{}'
rm -f "$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "UNVERIFIABLE: wiring/distro_checkout - state/.ac-root is unseeded, and it is the only record of the tree this FLEET runs from (its one writer is ac_seed_root_pointer, called from bin/ac-remote.sh) - settle it with: run any bin/ac-remote.sh verb from the fleet's own checkout, then re-run this check" "no pointer"
: >"$AC_HOME/state/.ac-root"; same drift
assert_contains "$(sed -n 2p "$TMP/n.out")" "state/.ac-root is unseeded" "an empty pointer"
printf '/somewhere/else\n' >"$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2,3p "$TMP/n.out")" "DRIFT: wiring/distro_checkout - declared ROOT, state/.ac-root says /somewhere/else
  fix: correct records/rig.json, or repoint the checkout this fleet runs from" "a pointer elsewhere"
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 8 ok, 1 drift, 1 unverifiable" "one wiring drift"
mkdir -p "$TMP/notgit"
printf '%s\n' "$TMP/notgit" >"$AC_HOME/state/.ac-root"; manifest "{'wiring': {'distro_checkout': '$TMP/notgit'}}"; same drift
assert_eq "$(sed -n 2,3p "$TMP/n.out")" "DRIFT: wiring/distro_checkout - declared $TMP/notgit, and the path is not a git repository
  fix: restore the checkout at $TMP/notgit, or correct records/rig.json" "a checkout that is no repository"
manifest '{}'
printf '%s' "$root" >"$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "OK: wiring/distro_checkout - ROOT (state/.ac-root)" "no trailing newline"
printf '%s\n\n\n' "$root" >"$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "OK: wiring/distro_checkout - ROOT (state/.ac-root)" "every trailing newline dropped, as \$(cat) dropped them"
printf '%s/\n' "$root" >"$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "OK: wiring/distro_checkout - ROOT/ (state/.ac-root)" "a trailing slash canonicalizes equal and is quoted as written"
printf '%s\n' "$root" >"$AC_HOME/state/.ac-root"
manifest "{'wiring': {'distro_checkout': '$TMP/./distro/'}}"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "OK: wiring/distro_checkout - ROOT (state/.ac-root)" "a declared spelling canonicalizes equal"
# A pointer holding only newlines reads as "" (every trailing newline dropped),
# and `cd ""` is a no-op in bash 3.2: canon answers the cwd. The original's
# reading, kept by the port (physicalDir, pinned in tests/ts/rig.test.ts):
# from $TMP it is drift quoting the empty pointer; from inside the checkout it
# binds, and `git -C ""` is the cwd too.
manifest '{}'; printf '\n' >"$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "DRIFT: wiring/distro_checkout - declared ROOT, state/.ac-root says " "a newline-only pointer, from outside the checkout"
o_rc=0; (cd "$root" && LC_ALL=C "$obin/ac-rig.sh" drift) >"$TMP/o.raw" 2>&1 || o_rc=$?
n_rc=0; (cd "$root" && LC_ALL=C "$BIN/ac-rig.sh" drift) >"$TMP/n.raw" 2>&1 || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "a newline-only pointer, from inside the checkout: both bind"
cmp -s "$TMP/o.raw" "$TMP/n.raw" || fail "a newline-only pointer, from inside the checkout: $(diff "$TMP/o.raw" "$TMP/n.raw" | head -n 4)"
assert_eq "$(sed -n 2p "$TMP/n.raw")" "OK: wiring/distro_checkout -  (state/.ac-root)" "a newline-only pointer canonicalizes to the cwd, as cd \"\" does"
printf '%s\n' "$root" >"$AC_HOME/state/.ac-root"

# 8. pinned values: CRLF and trailing blanks are trimmed, an empty pin, a backslash
fresh
printf 'direct   \r\n' >"$AC_HOME/config/flow"; : >"$AC_HOME/config/gate-model"; printf 'a\\b\n' >"$AC_HOME/config/bs"
manifest "{'add_knobs': [{'name': 'gate-model', 'value': ''}, {'name': 'bs', 'value': 'a\\\\b'}]}"; same drift
assert_eq "$(sed -n '3p;8,9p' "$TMP/n.out")" "OK: config/flow - pinned value 'direct'
OK: config/gate-model - pinned value ''
OK: config/bs - pinned value 'a\\b'" "the three pins match"
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 11 ok, 0 drift, 1 unverifiable" "clean"

# 9. four drift classes at once, in report order, the tally arithmetic; the structural entries skipped
fresh
printf 'staged\n' >"$AC_HOME/config/flow"; rm -f "$AC_HOME/config/backend"; printf '99\n' >"$AC_HOME/config/scene-max"; printf 'x\n' >"$AC_HOME/config/extra-knob"
printf 'old\n' >"$AC_HOME/config/flow.prev"; printf 'log\n' >"$AC_HOME/config/.dash-edits.log"; mkdir -p "$AC_HOME/config/projects"
same drift
assert_eq "$(shim_out)" "OK: home/home - manifest binds this home (HOME)
OK: wiring/distro_checkout - ROOT (state/.ac-root)
DRIFT: config/flow - declared 'direct', config/flow reads 'staged'
  fix: printf '%s\n' 'direct' > HOME/config/flow, or update records/rig.json
OK: config/promote - pinned value 'always'
DRIFT: config/backend - declared present, but there is no config/backend
  fix: create HOME/config/backend, or declare the row \"state\": \"default\" in records/rig.json
OK: config/wedge-alarm - declared present
DRIFT: config/scene-max - declared absent (this fleet takes the reader's default), but config/scene-max exists
  fix: remove HOME/config/scene-max, or give the row a value in records/rig.json
DRIFT: config/extra-knob - present in config/, declared nowhere in records/rig.json
  fix: add {\"name\": \"extra-knob\"} to records/rig.json, or remove HOME/config/extra-knob
OK: standing_jobs/alpha-job - declared in records/standing-jobs.md
OK: standing_jobs/beta-job - declared in records/standing-jobs.md
$LIVENESS2
rig: 6 ok, 4 drift, 1 unverifiable" "four drift blocks in report order"

# 10. a knob that is a DIRECTORY: declared present -> no file; declared default -> exists; direction B is silent on it
fresh; mkdir -p "$AC_HOME/config/dirknob"
manifest "{'add_knobs': [{'name': 'dirknob'}]}"; same drift
assert_eq "$(sed -n 8,9p "$TMP/n.out")" "DRIFT: config/dirknob - declared present, but there is no config/dirknob
  fix: create HOME/config/dirknob, or declare the row \"state\": \"default\" in records/rig.json" "a directory is no file"
assert_eq "$(grep -c '^DRIFT: config/dirknob' "$TMP/n.out")" "1" "direction B skips the directory"
manifest "{'add_knobs': [{'name': 'dirknob', 'state': 'default'}]}"; same drift
assert_eq "$(sed -n 8,9p "$TMP/n.out")" "DRIFT: config/dirknob - declared absent (this fleet takes the reader's default), but config/dirknob exists
  fix: remove HOME/config/dirknob, or give the row a value in records/rig.json" "a directory exists"
assert_eq "$(grep -c '^DRIFT: config/dirknob' "$TMP/n.out")" "1" "direction B skips the directory"

# 11. off-grammar names and values, spelled as jq spells them (`tostring`,
#     `-r`): a numeric name, a nameless knob (`null` - and a file so named is
#     declared), a boolean value, an unknown state (present), an empty name
#     (skipped), `1.0` kept, `1e2` as 1E+2, a big integer intact, an object
#     compact, `-0`, a null value (a pin, has("value")).
fresh
for pair in 7=x null=y k=true k2=z 1.0=1.0 e=1E+2 big=12345678901234567890 'obj={"a":[1,2]}' neg=-0 nul=null; do
  printf '%s\n' "${pair#*=}" >"$AC_HOME/config/${pair%%=*}"
done
cat >"$RIG" <<EOF
{ "home": {"name": "home", "path": "$AC_HOME"}, "wiring": {"distro_checkout": "$root"},
  "config": {"knobs": [
    {"name": "flow", "value": "direct"}, {"name": "promote", "value": "always"}, {"name": "backend"}, {"name": "wedge-alarm"}, {"name": "scene-max", "state": "default"},
    {"name": 7, "value": "x"}, {"value": "y"}, {"name": "k", "value": true}, {"name": "k2", "state": "weird"}, {"name": ""},
    {"name": 1.0, "value": "1.0"}, {"name": "e", "value": 1e2}, {"name": "big", "value": 12345678901234567890},
    {"name": "obj", "value": {"a": [1, 2]}}, {"name": "neg", "value": -0}, {"name": "nul", "value": null} ] },
  "standing_jobs": ["alpha-job", "beta-job"] }
EOF
same drift
assert_eq "$(sed -n 8,17p "$TMP/n.out")" "OK: config/7 - pinned value 'x'
OK: config/null - pinned value 'y'
OK: config/k - pinned value 'true'
OK: config/k2 - declared present
OK: config/1.0 - pinned value '1.0'
OK: config/e - pinned value '1E+2'
OK: config/big - pinned value '12345678901234567890'
OK: config/obj - pinned value '{\"a\":[1,2]}'
OK: config/neg - pinned value '-0'
OK: config/nul - pinned value 'null'" "jq's spellings"
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 19 ok, 0 drift, 1 unverifiable" "every off-grammar row graded, the empty name skipped"

# 12. standing jobs: a duplicate id, an empty id, a manifest-only id, a record-only id; numeric ids
fresh
manifest "{'standing_jobs': ['alpha-job', 'alpha-job', '', 'ghost']}"; same drift
assert_eq "$(sed -n '8,$p' "$TMP/n.out")" "OK: standing_jobs/alpha-job - declared in records/standing-jobs.md
OK: standing_jobs/alpha-job - declared in records/standing-jobs.md
DRIFT: standing_jobs/ghost - declared in records/rig.json, absent from records/standing-jobs.md
  fix: add the job line to records/standing-jobs.md, or drop the id from records/rig.json
DRIFT: standing_jobs/beta-job - declared in records/standing-jobs.md, absent from records/rig.json
  fix: add \"beta-job\" to standing_jobs in records/rig.json
UNVERIFIABLE: standing_jobs/liveness - 3 declared job(s); CronCreate is session-only, so no on-disk signal says whether any of them is scheduled right now - settle it with: CronList in the harness - no shell on this host can answer it
rig: 9 ok, 2 drift, 1 unverifiable" "both directions, the duplicate twice, the empty id skipped and uncounted"
printf -- '- 7 [on] cadence:c recreate:r\n' >>"$AC_HOME/records/standing-jobs.md"
manifest "{'add_jobs': [7, '7']}"; same drift
assert_eq "$(grep -c '^OK: standing_jobs/7 ' "$TMP/n.out")" "2" "7 and \"7\" are one id"
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 11 ok, 0 drift, 1 unverifiable" "clean"

# 13. no standing_jobs key (or an empty list): direction B only, and no liveness line; no config key: direction B on every file
fresh
for p in "{'standing_jobs': None}" "{'standing_jobs': []}"; do
  manifest "$p"; same drift
  assert_eq "$(sed -n '8,$p' "$TMP/n.out")" "DRIFT: standing_jobs/alpha-job - declared in records/standing-jobs.md, absent from records/rig.json
  fix: add \"alpha-job\" to standing_jobs in records/rig.json
DRIFT: standing_jobs/beta-job - declared in records/standing-jobs.md, absent from records/rig.json
  fix: add \"beta-job\" to standing_jobs in records/rig.json
rig: 7 ok, 2 drift, 0 unverifiable" "record-only jobs, no liveness line ($p)"
done
manifest "{'config': None, 'standing_jobs': None}"; same drift
assert_eq "$(grep -c '^DRIFT: config/' "$TMP/n.out")" "4" "no config key: every file is undeclared"
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 2 ok, 6 drift, 0 unverifiable" "no config, no jobs"

# 14. no records/standing-jobs.md: the sibling answers no ids and exit 0, so every declared job drifts and liveness is still printed
fresh; manifest "{'standing_jobs': ['a']}"; rm -f "$AC_HOME/records/standing-jobs.md"; same drift
assert_eq "$(sed -n '8,$p' "$TMP/n.out")" "DRIFT: standing_jobs/a - declared in records/rig.json, absent from records/standing-jobs.md
  fix: add the job line to records/standing-jobs.md, or drop the id from records/rig.json
UNVERIFIABLE: standing_jobs/liveness - 1 declared job(s); CronCreate is session-only, so no on-disk signal says whether any of them is scheduled right now - settle it with: CronList in the harness - no shell on this host can answer it
rig: 7 ok, 1 drift, 1 unverifiable" "no record on disk"

# 15. an unreadable record: the report up to the config lines, then refusal 9, exit 2 (root reads a mode-000 file, so unprivileged only)
if [ "$(id -u)" -ne 0 ]; then
  fresh; chmod 000 "$AC_HOME/records/standing-jobs.md"; same drift; chmod 644 "$AC_HOME/records/standing-jobs.md"
  assert_eq "$(shim_out)" "OK: home/home - manifest binds this home (HOME)
OK: wiring/distro_checkout - ROOT (state/.ac-root)
OK: config/flow - pinned value 'direct'
OK: config/promote - pinned value 'always'
OK: config/backend - declared present
OK: config/wedge-alarm - declared present
OK: config/scene-max - declared absent - runs on the reader's default" "the partial report stays printed"
  assert_eq "$(shim_err)" "ERROR: bin/ac-standing-jobs.sh --ids failed - the declared standing-job id set could not be read, and grading it as empty would report every declared job as drift" "refusal 9"
fi

# 16. direction B order: byte order under LC_ALL=C on both sides. Named
#     divergence: under en_US.UTF-8 the original's glob follows libc collation
#     (B lands after the lowercase names), the same set in another order; the
#     port's order is the locale's business nowhere.
fresh
for f in B _x a-b a.b a1 ab; do printf 'v\n' >"$AC_HOME/config/$f"; done
same drift
assert_eq "$(grep '^DRIFT' "$TMP/n.out" | sed 's/ - .*//')" "DRIFT: config/B
DRIFT: config/_x
DRIFT: config/a-b
DRIFT: config/a.b
DRIFT: config/a1
DRIFT: config/ab" "byte order"
run_oracle en_US.UTF-8 drift || true
assert_eq "$(LC_ALL=C sort "$TMP/o.raw")" "$(LC_ALL=C sort "$TMP/n.raw")" "UTF-8 locale: the original names the same set"
run_shim en_US.UTF-8 drift || true
assert_eq "$(spell "$TMP/n.raw")" "$(shim_out)" "the port's order does not move with the locale"

# 17. a child that cannot be launched keeps the verdict the original gave it:
#     no git on PATH is a checkout that is not a repository; a standing-jobs
#     sibling of mode 000 is refusal 9, exit 2 (root launches it anyway)
fresh
farm="$TMP/nogit"; mkdir -p "$farm"
IFS=: read -ra pathdirs <<<"$PATH"
for d in "${pathdirs[@]}"; do
  for x in "$d"/*; do [ -x "$x" ] && [ ! -e "$farm/$(basename "$x")" ] && ln -s "$x" "$farm/"; done
done 2>/dev/null; rm -f "$farm/git"
SAME_ENV="PATH=$farm"; same drift; SAME_ENV=
assert_contains "$(shim_out)" "DRIFT: wiring/distro_checkout - declared ROOT, and the path is not a git repository" "no git: the wiring drift, not a crash"
assert_eq "$(tail -n 1 "$TMP/n.out")" "rig: 8 ok, 1 drift, 1 unverifiable" "no git: the rest of the report still runs"
if [ "$(id -u)" -ne 0 ]; then
  # The port finds its sibling beside the module it runs from, through the
  # symlink bun resolves, so the shim's tree carries a real copy of src/.
  nroot="$TMP/shim-tree"; mkdir -p "$nroot/bin"
  cp "$BIN"/*.sh "$nroot/bin/"; cp -R "$ROOT/src" "$nroot/src"
  chmod 000 "$obin/ac-standing-jobs.sh" "$nroot/bin/ac-standing-jobs.sh"
  SHIM_BIN="$nroot/bin" same drift; SHIM_BIN=
  chmod 755 "$obin/ac-standing-jobs.sh"
  assert_eq "$(head -c 2 "$obin/ac-rig.sh")" "#!" "the oracle still runs the frozen original"
  cmp -s "$obin/ac-rig.sh" "$ROOT/tests/fixtures/ac-rig.sh" || fail "the oracle tree must hold the fixture, never the shim"
  assert_eq "$(shim_err)" "ERROR: bin/ac-standing-jobs.sh --ids failed - the declared standing-job id set could not be read, and grading it as empty would report every declared job as drift" "an unlaunchable sibling is refusal 9"
  assert_eq "$(tail -n 1 "$TMP/n.out")" "OK: config/scene-max - declared absent - runs on the reader's default" "the report up to the config lines stays printed"
fi

# 18. `$(...)` drops NUL bytes: a home.name or a pointer carrying one binds as
#     the bytes around it
fresh; manifest "{'home': {'name': 'home\x00', 'path': '$AC_HOME'}}"; same drift
assert_eq "$(sed -n 1p "$TMP/n.out")" "OK: home/home - manifest binds this home (HOME)" "a NUL in home.name is dropped as command substitution drops it"
fresh; printf '%s\0\n' "$root" >"$AC_HOME/state/.ac-root"; same drift
assert_eq "$(sed -n 2p "$TMP/n.out")" "OK: wiring/distro_checkout - ROOT (state/.ac-root)" "a NUL in the pointer is dropped"

# 19. a pinned value under LC_ALL=C: [:space:] is the ASCII six there, so a
#     non-breaking space is a value byte and the pin drifts; under a UTF-8
#     locale the reader trims it on both sides and the pin holds
fresh; printf '\302\240direct\302\240\n' >"$AC_HOME/config/flow"; same drift
assert_contains "$(shim_out)" "DRIFT: config/flow - declared 'direct', config/flow reads '$(printf '\302\240direct\302\240')'" "C locale: the non-breaking space is a value byte"
run_oracle en_US.UTF-8 drift || true; run_shim en_US.UTF-8 drift || true
assert_eq "$(grep '^OK: config/flow' "$TMP/n.raw")" "OK: config/flow - pinned value 'direct'" "UTF-8 locale: the port trims it"
assert_eq "$(grep '^OK: config/flow' "$TMP/o.raw")" "$(grep '^OK: config/flow' "$TMP/n.raw")" "UTF-8 locale: as the original does"

pass
