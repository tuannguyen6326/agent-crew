#!/usr/bin/env bash
# ac-skills-catalog.test.sh - the catalog-wide schema contract for the built-in
# skill packages under .agents/skills/. Asserts every TRACKED SKILL.md complies
# with the Agent Skills specification (https://agentskills.io/specification):
# dir == name, portable lowercase name <=64, non-empty description <=1024,
# top-level frontmatter keys limited to the supported set (no non-standard
# `user-invocable`), metadata values all strings, no reference `.md` content
# misplaced under assets/, and SKILL.md stays < 500 lines. Scope is
# git-tracked packages ONLY - transient learned skills seeded into a worktree
# (they carry legacy `origin: learned` and are governed by ac-learn.sh's
# emitter + read-compat, not this contract) are excluded by construction.
# Negative cases prove each rule bites.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# check_skill <SKILL.md path> - exit 0 if the package complies, 1 (with a reason
# on stderr) otherwise. Derives the package dir/name from the path.
check_skill() {
  local f="$1" dir pkg
  dir="$(dirname "$f")"
  pkg="$(basename "$dir")"
  awk -v pkg="$pkg" '
    function bad(msg) { if (rc==0) { rc=1; reason=msg } }
    /^---[[:space:]]*$/ { d++; if (d==2) endfence=1; next }
    d!=1 { next }
    {
      line=$0
      if (line ~ /^[[:space:]]/) {                       # indented (metadata entry)
        if (inmeta && line ~ /^[[:space:]]+[^:[:space:]][^:]*:/) {
          val=line; sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", val); sub(/[[:space:]]+$/, "", val)
          if (val ~ /^-?[0-9][0-9_]*$/ || val ~ /^-?[0-9]*\.[0-9]+$/)
            bad("metadata value must be a string (numeric): " line)
          else {
            lv=tolower(val)
            if (lv=="true"||lv=="false"||lv=="yes"||lv=="no"||lv=="on"||lv=="off"||lv=="null"||val=="~")
              bad("metadata value must be a string (bool/null): " line)
          }
        }
        next
      }
      inmeta=0
      if (line ~ /^#/) next                              # comment line
      if (line !~ /^[A-Za-z0-9_-]+:/) { bad("malformed frontmatter line: " line); next }
      key=line; sub(/:.*/, "", key)
      val=line; sub(/^[^:]*:[[:space:]]*/, "", val); sub(/[[:space:]]+$/, "", val)
      # Supported top-level keys per the Agent Skills spec (the set the official
      # skills-ref validator enforces): name, description, license, allowed-tools,
      # compatibility, metadata. `user-invocable` is called out for a clear reason.
      if (key=="user-invocable")
        bad("non-standard top-level key: user-invocable")
      else if (key!="name" && key!="description" && key!="license" && key!="allowed-tools" && key!="compatibility" && key!="metadata")
        bad("unsupported top-level key: " key)
      if (key=="name") {
        haveName=1
        if (val!=pkg) bad("name (" val ") != package dir (" pkg ")")
        if (length(val)>64) bad("name > 64 chars")
        if (val !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/ || val ~ /--/) bad("name not a portable slug: " val)
      }
      if (key=="description") {
        haveDesc=1
        if (length(val)<1) bad("description empty")
        if (length(val)>1024) bad("description > 1024 chars")
      }
      if (key=="metadata") inmeta=1
    }
    END {
      if (rc==0 && !endfence) bad("no closing frontmatter fence")
      if (rc==0 && !haveName)  bad("missing required name")
      if (rc==0 && !haveDesc)  bad("missing required description")
      if (rc!=0) { print "INVALID(" pkg "): " reason > "/dev/stderr"; exit 1 }
    }
  ' "$f" || return 1
  # Progressive disclosure: reference docs (.md) belong under references/, never
  # under assets/ (assets/ holds runtime artifacts like compose.yaml).
  if [ -d "$dir/assets" ] && find "$dir/assets" -maxdepth 1 -type f -name '*.md' | grep -q .; then
    printf 'INVALID(%s): reference .md under assets/ (belongs in references/)\n' "$pkg" >&2
    return 1
  fi
  # Size ceiling: each SKILL.md stays < 500 lines (AGENTS.md section 12).
  local lines
  lines="$(wc -l <"$f")"
  if [ "$lines" -ge 500 ]; then
    printf 'INVALID(%s): SKILL.md >= 500 lines (%s)\n' "$pkg" "$lines" >&2
    return 1
  fi
  return 0
}

# --- Positive: every tracked built-in package complies -----------------------

skills=()
while IFS= read -r rel; do
  [ -n "$rel" ] && skills+=("$rel")
done < <(git -C "$ROOT" ls-files -- '.agents/skills/' | grep -E '/SKILL\.md$')
[ "${#skills[@]}" -ge 11 ] || fail "expected >=11 tracked built-in skill packages, found ${#skills[@]}"
found_debrief=0
for rel in "${skills[@]}"; do
  case "$rel" in */debrief/SKILL.md) found_debrief=1 ;; esac
  check_skill "$ROOT/$rel" || fail "built-in package fails the schema contract: $rel"
done
[ "$found_debrief" = 1 ] || fail "catalog scan did not reach the real .agents/skills (debrief missing)"

# --- Positive synthetic: minimal and string-metadata packages accepted --------

mk_pkg() { # mk_pkg <name> <frontmatter-body...>  -> prints the SKILL.md path
  local name="$1"; shift
  local d="$TMP/cat/$name"
  mkdir -p "$d"
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n\n# %s\n' "$name"; } >"$d/SKILL.md"
  printf '%s\n' "$d/SKILL.md"
}

good_min="$(mk_pkg good-min 'name: good-min' 'description: A minimal valid package.')"
check_skill "$good_min" || fail "minimal name+description package must be accepted"

# The shape ac-learn.sh emits after this migration: string metadata (quoted epoch).
good_meta="$(mk_pkg good-meta 'name: good-meta' 'description: A learned package.' 'metadata:' '  origin: learned' '  landed: "1784426868"')"
check_skill "$good_meta" || fail "package with all-string metadata must be accepted"

# --- Negative: each rule bites ------------------------------------------------

n_userinv="$(mk_pkg n-userinv 'name: n-userinv' 'description: has a banned key.' 'user-invocable: true')"
assert_fails check_skill "$n_userinv"        # unsupported top-level key: user-invocable

n_otherkey="$(mk_pkg n-otherkey 'name: n-otherkey' 'description: has an unknown key.' 'internal: true')"
assert_fails check_skill "$n_otherkey"        # unsupported top-level key

n_metaint="$(mk_pkg n-metaint 'name: n-metaint' 'description: integer metadata.' 'metadata:' '  landed: 1784426868')"
assert_fails check_skill "$n_metaint"         # non-string (integer) metadata

n_metabool="$(mk_pkg n-metabool 'name: n-metabool' 'description: boolean metadata.' 'metadata:' '  internal: true')"
assert_fails check_skill "$n_metabool"        # non-string (boolean) metadata

n_mismatch="$(mk_pkg n-mismatch 'name: not-the-dir' 'description: name != dir.')"
assert_fails check_skill "$n_mismatch"        # name/dir mismatch

bigname="$(printf 'a%.0s' $(seq 1 70))"
n_bigname="$(mk_pkg "$bigname" "name: $bigname" 'description: oversized name.')"
assert_fails check_skill "$n_bigname"         # name > 64 chars

bigdesc="$(printf 'x%.0s' $(seq 1 1100))"
n_bigdesc="$(mk_pkg n-bigdesc 'name: n-bigdesc' "description: $bigdesc")"
assert_fails check_skill "$n_bigdesc"         # description > 1024 chars

n_emptydesc="$(mk_pkg n-emptydesc 'name: n-emptydesc' 'description:')"
assert_fails check_skill "$n_emptydesc"       # empty description

# Misplaced reference content: a .md under assets/ instead of references/.
n_misplaced="$(mk_pkg n-misplaced 'name: n-misplaced' 'description: misplaced reference.')"
mkdir -p "$TMP/cat/n-misplaced/assets"
printf '# a reference doc\n' >"$TMP/cat/n-misplaced/assets/guide.md"
assert_fails check_skill "$n_misplaced"       # reference .md under assets/

# SKILL.md >= 500 lines: AGENTS.md's ceiling, otherwise unenforced.
n_toolong_dir="$TMP/cat/n-toolong"
mkdir -p "$n_toolong_dir"
{
  printf -- '---\nname: n-toolong\ndescription: oversized skill file.\n---\n\n'
  for i in $(seq 1 500); do printf 'line %s\n' "$i"; done
} >"$n_toolong_dir/SKILL.md"
assert_fails check_skill "$n_toolong_dir/SKILL.md"    # SKILL.md >= 500 lines

pass
