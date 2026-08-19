#!/usr/bin/env bash
# ac-rig.sh - the rig manifest and its drift check.
#
# Usage: ac-rig.sh drift
#
# THE MANIFEST is records/rig.json, one JSON object per fleet home, written
# and maintained BY HAND. It is the DECLARED source for the entries below;
# `drift` compares it against the surfaces that hold that truth today and
# reports every divergence. Nothing else reads it - a manifest that decided
# behaviour would be a config file, and this is a record.
#
# JSON, not the records/*.md line grammar its neighbours use, for two reasons.
# jq is a hard dependency (bin/ac-bootstrap.sh:44 is `need jq`, not `opt`), so
# parsing costs one `jq -r` and cannot drift; and the *.md grammars are
# hand-rolled sed that mis-parses free text - fed a value containing its own
# delimiter words, bin/ac-standing-jobs.sh:49-50 returns the wrong cadence and
# the wrong action, silently. A manifest carrying paths and commands walks
# into that on day one. YAML was never a candidate: this distro has no yq,
# only ac_yaml_get (bin/ac-pipeline-lib.sh:23), which cannot read a list.
#
# GRAMMAR (this header is the authoritative spec):
#
#   {
#     "home":    { "name": "<fleet>", "path": "<absolute home path>" },
#     "wiring":  { "distro_checkout": "<absolute path>" },
#     "config":  { "knobs": [ {"name":"<knob>"}                       # present
#                           , {"name":"<knob>", "value":"<v>"}        # pinned
#                           , {"name":"<knob>", "state":"default"} ]  # absent
#                },
#     "standing_jobs": [ "<job id>", ... ]
#   }
#
# VERDICTS - three, never two. `OK` and `DRIFT` are the mechanical ones;
# `UNVERIFIABLE` is a first-class third answer for a fact no read-only command
# on this host can settle, and it is what keeps the manifest honest rather
# than confident. The vocabulary is not invented here: `ac-know.sh verify`
# already grades entries FRESH / SUSPECT / UNVERIFIABLE / MANUAL.
#
#   OK:           <class>/<id> - <what matched>
#   DRIFT:        <class>/<id> - declared <x>, reality <y>
#                   fix: <the exact command or edit>
#   UNVERIFIABLE: <class>/<id> - <why> - settle it with: <the act>
#   rig: <n> ok, <n> drift, <n> unverifiable
#
# EXIT: 0 clean (UNVERIFIABLE alone never fails), 1 any DRIFT, 2 usage or an
# unreadable manifest. FAIL DIRECTION, stated because the two errors are not
# symmetric: a FALSE OK is the unrecoverable one - it makes the verb
# decorative. So an absent, unparseable or wrong-home manifest REFUSES; it is
# never graded clean. This is the `validate` half of the distro's list/validate
# split (bin/ac-deputy.sh:48-50): a strict twin that exits non-zero, not a
# digest renderer that may never take session start down.
#
# WHAT IS DELIBERATELY NOT DECLARED, so a reader does not add it back:
# - SERVICE LIVENESS (dashboard, remote poll, brain). There is no pid file and
#   no registry anywhere by explicit design (bin/ac-dashboard.sh:8), the
#   dashboard's port lives solely in argv, and the watcher beacon is stood
#   down to 0 on every normal exit (bin/ac-watch.sh:888-896) - a declared
#   expected liveness would be a false-drift generator.
# - PROJECTS. records/projects.md is already its own single source; a copy
#   here would be a second one.
# - CREWDEPUTIES / CREWDOMAINS. Both already have a declared file plus a
#   strict checker (bin/ac-deputy.sh:196, bin/ac-domain.sh:812).
# - TOOLCHAIN BINARIES. bin/ac-bootstrap.sh's need/opt list is the source and
#   already gates.
#
# There is no verb that GENERATES the manifest from the live home: one
# regenerated from reality can never disagree with it, and generating the
# first one would silently bless whatever rot the home already carries.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

# Tab cannot separate these rows: it is IFS WHITESPACE, so `read` collapses a
# run of them and an empty middle field silently shifts every later one left
# (a knob declared `state: default` read back as a pinned value). The unit
# separator does not collapse - same fix, same constant, as bin/ac-deputy.sh:129.
FS_US=$'\037'

# ac_die exits 1, which is this verb's DRIFT code - a refusal must not be
# mistakable for a finding.
refuse() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

ok=0
drift=0
unver=0

say_ok()    { printf 'OK: %s - %s\n' "$1" "$2"; ok=$((ok + 1)); }
say_unver() { printf 'UNVERIFIABLE: %s - %s - settle it with: %s\n' "$1" "$2" "$3"; unver=$((unver + 1)); }
say_drift() {
  # say_drift <class/id> <what disagrees> <the fix>
  printf 'DRIFT: %s - %s\n  fix: %s\n' "$1" "$2" "$3"
  drift=$((drift + 1))
}

canon() {
  # canon <path> - the resolved path, or the literal when it does not exist.
  # A declared path that is simply GONE must still print as declared, so this
  # falls back rather than failing: the DRIFT line's job is to quote both
  # sides, and "" tells the reader nothing.
  cd "$1" 2>/dev/null && pwd -P || printf '%s\n' "$1"
}

cmd_drift() {
  local home manifest declared_home
  # ac_home refuses through ac_die, which exits 1 - this verb's DRIFT code, so
  # a caller branching on the status would read a missing AC_HOME as one
  # drifted entry. Every refusal this verb makes has to leave 1 alone.
  home="$(ac_home 2>/dev/null)" \
    || refuse "AC_HOME is not set - name the fleet home whose records/rig.json to check"
  manifest="$(ac_records_dir)/rig.json"

  [ -f "$manifest" ] \
    || refuse "no rig manifest at records/rig.json - the drift check has nothing to compare against (grammar: the bin/ac-rig.sh header)"
  jq -e . "$manifest" >/dev/null 2>&1 \
    || refuse "records/rig.json does not parse as JSON - fix it; a manifest that cannot be read is never graded clean (grammar: the bin/ac-rig.sh header)"

  # HOME BINDING FIRST, and it refuses rather than measuring. ac-home-seed.sh
  # copies a parent's config into a crewdeputy home, so a manifest can
  # physically arrive in the wrong one - and grading drydock's manifest
  # against another home's reality would print a wall of drift that is really
  # one mistake.
  declared_home="$(jq -r '.home.path // empty' "$manifest")"
  [ -n "$declared_home" ] \
    || refuse "records/rig.json declares no home.path - the manifest must name the rig it describes"
  if [ "$(canon "$declared_home")" != "$(canon "$home")" ]; then
    refuse "records/rig.json describes $declared_home but AC_HOME is $home - refusing to grade one rig against another"
  fi
  # The NAME is checked too, not merely echoed into the OK line. A field the
  # manifest declares and nothing compares is the seed of exactly the drift
  # this file exists to catch - and a manifest copied by ac-home-seed.sh into
  # another home, then path-corrected, keeps the old name.
  local declared_name fleet
  declared_name="$(jq -r '.home.name // empty' "$manifest")"
  fleet="$(ac_fleet_name)"
  [ -n "$declared_name" ] \
    || refuse "records/rig.json declares no home.name - the manifest must name the rig it describes"
  [ "$declared_name" = "$fleet" ] \
    || refuse "records/rig.json calls this fleet '$declared_name' but it is '$fleet' - refusing to grade one rig against another"
  say_ok "home/$declared_name" "manifest binds this home ($home)"

  check_wiring "$manifest" "$home"
  check_config "$manifest" "$home"
  check_standing_jobs "$manifest"

  printf 'rig: %s ok, %s drift, %s unverifiable\n' "$ok" "$drift" "$unver"
  [ "$drift" -eq 0 ] || return 1
  return 0
}

check_wiring() {
  local manifest="$1" home="$2" declared ptr actual
  declared="$(jq -r '.wiring.distro_checkout // empty' "$manifest")"
  # An absent key is NOT a pass. Returning silently meant a one-character typo
  # in the key name disabled this whole class with no line and no tally entry -
  # the false OK this verb's fail direction calls the unrecoverable error.
  if [ -z "$declared" ]; then
    say_unver "wiring/distro_checkout" \
      "records/rig.json declares no wiring.distro_checkout, so there is nothing to compare the fleet's checkout against" \
      "declare it in records/rig.json (grammar: the bin/ac-rig.sh header)"
    return 0
  fi

  # state/.ac-root ONLY, deliberately no ac_root() fallback. ac_root() is the
  # checkout that owns the INVOKED bin/, so from a leased pool worktree it
  # answers that worktree - falling back to it would grade WHO RAN THE VERB
  # instead of the rig, and every crewmate invocation and the whole test suite
  # would read as drift. An unseeded pointer is a thing this host cannot
  # settle, which is exactly what the third verdict is for.
  ptr="$(ac_root_pointer_path)"
  if [ ! -s "$ptr" ]; then
    say_unver "wiring/distro_checkout" \
      "state/.ac-root is unseeded, and it is the only record of the tree this FLEET runs from (its one writer is ac_seed_root_pointer, called from bin/ac-remote.sh)" \
      "run any bin/ac-remote.sh verb from the fleet's own checkout, then re-run this check"
    return 0
  fi

  actual="$(cat "$ptr" 2>/dev/null || true)"
  if [ "$(canon "$declared")" != "$(canon "$actual")" ]; then
    say_drift "wiring/distro_checkout" \
      "declared $declared, state/.ac-root says $actual" \
      "correct records/rig.json, or repoint the checkout this fleet runs from"
    return 0
  fi
  if ! git -C "$actual" rev-parse --git-dir >/dev/null 2>&1; then
    say_drift "wiring/distro_checkout" \
      "declared $declared, and the path is not a git repository" \
      "restore the checkout at $actual, or correct records/rig.json"
    return 0
  fi
  say_ok "wiring/distro_checkout" "$actual (state/.ac-root)"
}

check_config() {
  local manifest="$1" home="$2" rows name kind value f declared_names entry base
  # NOT @tsv: it escapes `\`, tab and newline, and `read -r` never un-escapes
  # them - a knob whose value contains a backslash read as drift on a correct
  # rig, and the `fix:` line then told the reader to write the ESCAPED bytes
  # back. join emits the value raw.
  # The row's KIND is decided here, by has("value"), not downstream by testing
  # the value for emptiness: jq's `//` is falsy on `false` as well as null, and
  # an intentionally pinned EMPTY value (config/gate-model is documented as
  # "absent = the engine default") is a real declaration that an emptiness test
  # silently downgrades to a presence-only check.
  rows="$(jq -r '.config.knobs // [] | .[]
                 | [ (.name | tostring)
                   , (if has("value") then "pinned"
                      elif (.state // "") == "default" then "default"
                      else "present" end)
                   , (if has("value") then (.value | tostring) else "" end) ]
                 | join("\u001f")' "$manifest")"
  declared_names="$(jq -r '.config.knobs // [] | .[] | .name' "$manifest")"

  # Direction A - every declared knob is what the manifest says it is.
  while IFS="$FS_US" read -r name kind value; do
    [ -n "${name:-}" ] || continue
    f="$home/config/$name"
    if [ "$kind" = default ]; then
      if [ -e "$f" ]; then
        say_drift "config/$name" \
          "declared absent (this fleet takes the reader's default), but config/$name exists" \
          "remove $f, or give the row a value in records/rig.json"
      else
        say_ok "config/$name" "declared absent - runs on the reader's default"
      fi
      continue
    fi
    if [ ! -f "$f" ]; then
      say_drift "config/$name" \
        "declared present, but there is no config/$name" \
        "create $f, or declare the row \"state\": \"default\" in records/rig.json"
      continue
    fi
    if [ "$kind" = pinned ]; then
      # ac_config_read, never a byte compare: it trims whitespace and CR
      # (bin/ac-lib.sh:349-351), so raw bytes would report drift on a CRLF no
      # reader in the fleet can see.
      local actual
      actual="$(ac_config_read "$name" "")"
      if [ "$actual" != "$value" ]; then
        say_drift "config/$name" "declared '$value', config/$name reads '$actual'" \
          "printf '%s\\n' '$value' > $f, or update records/rig.json"
      else
        say_ok "config/$name" "pinned value '$value'"
      fi
      continue
    fi
    say_ok "config/$name" "declared present"
  done <<EOF
$rows
EOF

  # Direction B - CLOSURE. Without it the manifest is a partial list that can
  # never notice what appeared beside it, which is how config/ grew three
  # retired herdr-workspace* knobs nothing reads.
  for entry in "$home"/config/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    # Structural entries, not knobs: a directory, a dotted receipt log, and
    # the *.prev captain-veto sidecar (AGENTS.md section 10). Reporting these
    # would train the reader to ignore the verb.
    [ -d "$entry" ] && continue
    case "$base" in .* | *.prev) continue ;; esac
    printf '%s\n' "$declared_names" | grep -qxF -- "$base" && continue
    say_drift "config/$base" \
      "present in config/, declared nowhere in records/rig.json" \
      "add {\"name\": \"$base\"} to records/rig.json, or remove $entry"
  done
}

check_standing_jobs() {
  local manifest="$1" declared actual id n
  declared="$(jq -r '.standing_jobs // [] | .[]' "$manifest")"
  # The id list comes from the file that OWNS the grammar, never re-parsed
  # here: bin/ac-standing-jobs.sh --ids. One grammar, one parser (AGENTS.md
  # sections 2 and 13), the shape bin/ac-pool-health.sh already uses against
  # ac-tree.sh list.
  # No `|| true`: an empty id set is indistinguishable from "no jobs declared",
  # so swallowing the child's failure reported every declared job as drift with
  # a fix naming a line already sitting in the file. A verb that is fail-closed
  # about its own manifest has to be fail-closed about its inputs too.
  actual="$("$bin_dir/ac-standing-jobs.sh" --ids 2>/dev/null)" \
    || refuse "bin/ac-standing-jobs.sh --ids failed - the declared standing-job id set could not be read, and grading it as empty would report every declared job as drift"

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if printf '%s\n' "$actual" | grep -qxF -- "$id"; then
      say_ok "standing_jobs/$id" "declared in records/standing-jobs.md"
    else
      say_drift "standing_jobs/$id" \
        "declared in records/rig.json, absent from records/standing-jobs.md" \
        "add the job line to records/standing-jobs.md, or drop the id from records/rig.json"
    fi
  done <<EOF
$declared
EOF

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$declared" | grep -qxF -- "$id" && continue
    say_drift "standing_jobs/$id" \
      "declared in records/standing-jobs.md, absent from records/rig.json" \
      "add \"$id\" to standing_jobs in records/rig.json"
  done <<EOF
$actual
EOF

  # LIVENESS, the half no read-only command settles. CronCreate is
  # session-only: the job lives in harness session memory, is never written to
  # disk, and dies with the session (bin/ac-standing-jobs.sh:6-14, which
  # refuses to claim PRESENT/MISSING for the same reason). Every on-disk
  # footprint was checked and none attributes a run to a job - the github
  # store is a de-dup key that writes nothing when a poll finds nothing new,
  # .brain-last-sync has three writers, and the monitor leaves no trace at
  # all. So this says unknown, and names the one act that would answer.
  n="$(printf '%s\n' "$declared" | grep -c '[^[:space:]]' || true)"
  [ "$n" -gt 0 ] || return 0
  say_unver "standing_jobs/liveness" \
    "$n declared job(s); CronCreate is session-only, so no on-disk signal says whether any of them is scheduled right now" \
    "CronList in the harness - no shell on this host can answer it"
}

case "${1:-}" in
  drift) shift; [ $# -eq 0 ] || refuse "usage: ac-rig.sh drift"; cmd_drift ;;
  -h | --help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'usage: ac-rig.sh drift\n' >&2; exit 2 ;;
esac
