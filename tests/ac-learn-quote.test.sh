#!/usr/bin/env bash
# ac-learn-quote.test.sh - the mechanical quote check at the landing seam: a
# `(by: <id>, first-hand)` source bullet whose backtick/double-quoted fragment
# of >= 6 words is not verbatim (whitespace-normalized) in that task's
# report.md is flagged `quote-unverified:` under the bullet in the evidence
# archive, and the land line carries the count. Visibility only: the entry
# still lands, and a bullet with no openable source is never flagged.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"

make_home

# The report soft-wraps the verbatim quote across two lines: whitespace
# normalization is what makes it match.
mkdir -p "$AC_HOME/data/t-quote"
{
  printf '# report\n\n## Lessons\n'
  printf -- '- A brief that says "show the command and its\n  output in your report" asks for an artifact the flow never creates.\n'
  printf -- '- Run the suite before handing back.\n'
} >"$AC_HOME/data/t-quote/report.md"

b_verbatim='- A brief that says "show the command and its output in your report" asks for an artifact the flow never creates. (by: t-quote, first-hand)'
b_paraphrase='- The chief was told `run the suite before you hand back the branch` and it was never said. (by: t-quote, first-hand)'
b_short='- A short "not in report" quote is below the floor. (by: t-quote, first-hand)'
b_nosource='- The order said "do the thing exactly as it was written here" and nothing else. (by: t-none, first-hand)'
printf '## 2026-09-20 - fam (chief)\n%s\n%s\n%s\n%s\n' \
  "$b_verbatim" "$b_paraphrase" "$b_short" "$b_nosource" >"$AC_HOME/records/learnings.md"

{
  printf 'kind: crewmate\n'
  printf 'name: quote-check\n'
  printf 'description: Quote only what you can open.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-09-20\tquote-check\t%s\n' "$b_verbatim" "$b_paraphrase" "$b_short" "$b_nosource"
  printf '===crewmate===\n'
  printf 'Quote only what you can open.\n'
} >"$TMP/cand-quote.md"

out="$("$BIN/ac-learn.sh" land "$TMP/cand-quote.md")"

# Visibility, never a gate: the entry lands and every source is archived.
grep -qxF '## quote-check' "$AC_HOME/CREWMATE-learned.md" || fail "the entry still lands with an unverified quote"
evidence="$AC_HOME/records/learnings-archive/quote-check.md"
assert_file "$evidence" "evidence archive written"
grep -qF 'source-count: 4' "$evidence" || fail "all four sources are archived"

# Exactly the paraphrase is flagged, right under its bullet.
assert_eq "$(grep -c '^quote-unverified: ' "$evidence")" "1" "exactly one fragment is flagged"
grep -qxF 'quote-unverified: run the suite before you hand back the branch' "$evidence" \
  || fail "the paraphrase wearing backticks is flagged by its fragment"
grep -A2 -F -- "$b_paraphrase" "$evidence" | grep -q '^quote-unverified: ' \
  || fail "the flag sits under the bullet it belongs to"
if grep -qF 'quote-unverified: show the command' "$evidence"; then
  fail "a verbatim quote (soft-wrapped in the report) is never flagged"
fi

# The land line reports the count.
assert_contains "$out" 'quote-unverified: 1' "land line carries the flagged count"

# A land with nothing to flag says nothing about quotes.
printf '## 2026-09-20 - fam (chief)\n- LESSON: plain, no quotes at all.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: crewmate\n'
  printf 'name: quote-clean\n'
  printf 'description: Nothing quoted.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-09-20\tquote-clean\t- LESSON: plain, no quotes at all.\n'
  printf '===crewmate===\n'
  printf 'Say it plainly.\n'
} >"$TMP/cand-clean.md"
out2="$("$BIN/ac-learn.sh" land "$TMP/cand-clean.md")"
case "$out2" in *quote-unverified*) fail "a clean land prints no quote count" ;; esac
if grep -q '^quote-unverified: ' "$AC_HOME/records/learnings-archive/quote-clean.md"; then
  fail "a clean archive carries no quote-unverified line"
fi

pass
