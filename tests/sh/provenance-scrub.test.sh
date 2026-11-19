#!/usr/bin/env bash
# provenance-scrub.test.sh - published text states a rule as a design fact,
# never with the dated ruling that made it. The repository is public: a dated
# ruling in a comment, doc or skill hands every clone the captain's private
# decision timeline, and the provenance it records already lives in the
# fleet's own records. The pattern is narrow on purpose - a ruling WITH its
# date - so evidence dates (VERIFIED, measured) and "captain" as role
# vocabulary stay legal.
#
# The same leak has two more shapes, caught by scan_residue below: a concrete
# `data/<family>/<file>` cited as evidence (vs. the distro's own generic
# `data/<id>/...` LAYOUT docs, a literal placeholder that never matches), and
# any bare calendar date surviving in a non-test file's comments/docs at all -
# a measurement stamp keeps its tool+version and drops only the date. Both are
# scoped to NON-TEST files only (tests/fixtures are out of scope for the scrub
# this guard locks in), unlike the ruling scan above which also reads
# tests/sh's own prose.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# `[^.]`, never `[^.\n]`: inside a bracket expression a backslash is a literal,
# so `\n` there refused the letter n too and let a `captain decision` with its
# date through. The scan is line-based, so no newline ever reaches it.
RULING_RE='captain[^.]{0,40}20[0-9]{2}-[0-9]{2}-[0-9]{2}|ruling[s]? 20[0-9]{2}-[0-9]{2}-[0-9]{2}|captain-ordered 20[0-9]{2}'

# The one exempt string: src/brief.ts prints it into a brief byte for byte.
# Only the string is exempt, never the rest of its line.
PARITY_HELD='epic gate owns the review round - captain ruling 2026-08-19'

# shell_prose <file>... - FILE:LINE:TEXT for each comment line outside a
# heredoc. A suite's code lines and heredoc bodies are its input data (a ledger
# row, a captain.md fixture), so they are never prose.
shell_prose() {
  awk -v q="'" '
    FNR == 1 { tag = "" }
    tag != "" { l = $0; if (dash) sub(/^\t+/, "", l); if (l == tag) tag = ""; next }
    /^[ \t]*#/ { print FILENAME ":" FNR ":" $0; next }
    {
      s = $0
      while ((i = index(s, "<<")) > 0) {
        s = substr(s, i + 2)
        if (substr(s, 1, 1) == "<") { s = substr(s, 2); continue }
        dash = (substr(s, 1, 1) == "-")
        if (dash) s = substr(s, 2)
        sub(/^[ \t]*/, "", s)
        c = substr(s, 1, 1)
        if (c == "\"" || c == q) s = substr(s, 2)
        if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) { tag = substr(s, 1, RLENGTH); break }
      }
    }' "$@"
}

# scan <repo> - PATH:LINE:TEXT for every published line that dates a ruling.
# bin/, src/, .agents/, docs/, dashboard/ and the root docs are prose
# throughout; tests/sh contributes its comments only.
scan() {
  local rc=0 hit f
  git -C "$1" grep -n -I -E -e "$RULING_RE" -- bin src .agents docs dashboard \
    AGENTS.md CLAUDE.md README.md CONTRIBUTING.md >"$TMP/scan.hits" || rc=$?
  [ "$rc" -le 1 ] || fail "git grep could not scan $1 (rc=$rc)"
  : >"$TMP/scan.prose"
  while IFS= read -r f; do
    (cd "$1" && shell_prose "$f") >>"$TMP/scan.prose" || fail "cannot read $1/$f"
  done < <(git -C "$1" ls-files -- 'tests/sh/*.sh')
  rc=0; grep -E -e "^[^:]+:[0-9]+:.*($RULING_RE)" "$TMP/scan.prose" >>"$TMP/scan.hits" || rc=$?
  [ "$rc" -le 1 ] || fail "grep could not scan the tests/sh comments of $1 (rc=$rc)"
  while IFS= read -r hit; do
    rc=0; grep -qE -e "$RULING_RE" <<<"${hit//"$PARITY_HELD"/}" || rc=$?
    [ "$rc" -le 1 ] || fail "grep could not recheck a hit of $1 (rc=$rc)"
    [ "$rc" = 1 ] || printf '%s\n' "$hit"
  done <"$TMP/scan.hits"
}

hits="$(scan "$ROOT")"
assert_eq "$hits" "" "published text states rules as design facts, never with a dated ruling"

# A concrete family citation as evidence, e.g. `data/codex-crewmate/room.md`.
# `[a-z]` as the first char refuses both the generic `<family>` placeholder
# (starts with `<`) and a glob like `data/*/*/gate.json`.
PROVENANCE_PATH_RE='data/[a-z][a-z0-9-]*/[A-Za-z0-9._/-]*\.(md|json|log)'
DATE_RE='20[0-9]{2}-[0-9]{2}-[0-9]{2}'

# Exempt substrings, same strip-then-retest shape as PARITY_HELD above: a
# structural (non-family) data/ path this distro's own code/docs name
# generically, and the dated examples this scrub proved FUNCTIONAL - a
# documented format spec, a measured tool+version with no date left to drop,
# or (the last one) PARITY_HELD itself, read here too since it also matches
# DATE_RE.
FUNCTIONAL_KEEP=(
  'data/external/hermes-dashboard-uiux-guide.md'
  'data/curate/room.md'
  'gh version 2.51.0 (2024-06-13)'
  'migration lands, 2026-09-01'
  '(added 2026-09-25)'
  '2026-08-10 ...]'
  '(2026-09-26T08:00:00Z)'
  '(2024-02-30 reads as 2024-03-01)'
  'protocolVersion || "2025-06-18"'
  '2026-08-19)`; staged'
  "$PARITY_HELD"
  '2026-11-01", "until 10:30"'
)

# scan_residue <repo> - PATH:LINE:TEXT for every tracked NON-TEST file citing
# a concrete data/<family>/<file> as provenance, or carrying a bare calendar
# date, outside the FUNCTIONAL_KEEP allowlist above. Same non-test path list
# as the ruling scan; tests/sh is deliberately NOT read here.
scan_residue() {
  local rc=0 hit clean item
  git -C "$1" grep -n -I -E -e "$PROVENANCE_PATH_RE" -e "$DATE_RE" -- bin src .agents docs dashboard \
    AGENTS.md CLAUDE.md README.md CONTRIBUTING.md ':!dashboard/*.test.ts' ':!docs/**/*.test.*' \
    >"$TMP/residue.hits" || rc=$?
  [ "$rc" -le 1 ] || fail "git grep could not scan $1 for residue (rc=$rc)"
  while IFS= read -r hit; do
    clean="$hit"
    for item in "${FUNCTIONAL_KEEP[@]}"; do
      clean="${clean//"$item"/}"
    done
    rc=0; grep -qE -e "$PROVENANCE_PATH_RE" -e "$DATE_RE" <<<"$clean" || rc=$?
    [ "$rc" -le 1 ] || fail "grep could not recheck a residue hit of $1 (rc=$rc)"
    [ "$rc" = 1 ] || printf '%s\n' "$hit"
  done <"$TMP/residue.hits"
}

residue_hits="$(scan_residue "$ROOT")"
assert_eq "$residue_hits" "" "tracked non-test files carry no data/<family> provenance citation and no bare calendar date outside the functional-keep allowlist"

# The residue guard itself: a concrete family citation and a bare date are
# caught; the generic data/<id> placeholder and a functional-keep date are
# not, and a test file's own comment is never read by this scan at all.
rfx="$TMP/residue-fixture"
mkdir -p "$rfx/bin" "$rfx/docs" "$rfx/tests/sh"
printf '# verified against data/some-real-family/report.md\n' >"$rfx/bin/x.sh"
{
  printf 'measured on %s\n' '2026-01-02'
  printf 'the generic layout is data/<family>/brief.md, never a real one\n'
  printf 'kept: gh version 2.51.0 (2024-06-13)\n'
} >"$rfx/docs/d.md"
printf '# a dated residue in a test comment: %s\n' '2026-03-04' >"$rfx/tests/sh/t.test.sh"
git -C "$rfx" init -q && git -C "$rfx" add -A
assert_eq "$(scan_residue "$rfx" | cut -d: -f1,2)" "bin/x.sh:1
docs/d.md:1" "a concrete family citation and a bare date are caught; the generic placeholder, a functional-keep date and a test file's own comment are not"

# The guard itself: a dated ruling in a script, a doc and a suite comment is
# caught, while a suite's data lines, a heredoc body, an undated mention and the
# parity-held string are not.
fx="$TMP/provenance-fixture"
mkdir -p "$fx/bin" "$fx/docs" "$fx/src" "$fx/tests/sh"
printf '#!/bin/sh\n# a rule (captain %s)\n# the captain decides\n' '2026-01-02' >"$fx/bin/x.sh"
printf 'a captain decision %s here\n' '2026-01-03' >"$fx/docs/d.md"
printf 'const s = "%s";\n' "$PARITY_HELD" >"$fx/src/p.ts"
{
  printf '# fixture rows (ruling %s)\n' '2026-01-04'
  printf "row='captain %s'\n" '2026-01-05'
  printf "cat <%s'EOF'\n# captain %s in a heredoc\nEOF\n" '<' '2026-01-06'
  printf '# after the heredoc\n'
} >"$fx/tests/sh/t.test.sh"
git -C "$fx" init -q && git -C "$fx" add -A
assert_eq "$(scan "$fx" | cut -d: -f1,2)" "bin/x.sh:2
docs/d.md:1
tests/sh/t.test.sh:1" "a dated ruling in prose is caught; data, a heredoc body and the parity-held string are not"

# A recheck grep that errors fails the scan; it never drops the hit as clean.
mkdir -p "$TMP/grep-err"
printf '#!/bin/sh\n[ "$1" != -qE ] || exit 2\nexec %s "$@"\n' "$(command -v grep)" >"$TMP/grep-err/grep"
chmod +x "$TMP/grep-err/grep"
recheck_err() { PATH="$TMP/grep-err:$PATH"; scan "$fx"; }
assert_fails_with "FAIL: grep could not recheck a hit of $fx (rc=2)" -- recheck_err

pass
