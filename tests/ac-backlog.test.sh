#!/usr/bin/env bash
# ac-backlog.test.sh - bin/ac-backlog.sh's CLI contract (the v1 wire, --get,
# stdin, exit codes, a closed pipe) and Leg A: src/backlog.ts held to a frozen
# copy of the awk parser, tests/fixtures/doneline.awk (AC_DONELINE_AWK
# extracted verbatim from bin/ac-lib.sh), over the seed rows below plus 20,000
# lines tests/backlog-gen.ts derives from a fixed seed.
#
# Leg C is local only: `bash tests/ac-backlog.test.sh <ledger>...` runs every
# ledger named on the command line through Leg A as well, so a live
# records/backlog.md is checked without ever being committed.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

ab="$BIN/ac-backlog.sh"
T=$'\t'
hdr="h${T}v1${T}id${T}terminal${T}hold${T}hold_until${T}hold_malformed${T}epic${T}feature${T}blockers${T}blockers_malformed${T}date${T}verb${T}contract${T}domain${T}domain_malformed"
rec() { local IFS="$T"; printf 'r\t%s\n' "$*"; }

wire="$TMP/wire.md"
printf '%s\n' '## Queued' \
  "- [ ] t3 [src:cap${T}qa:yes] - tab${T}in prose; epic:e1 blocked-by: t2 - why" \
  $'- [x] t2 [failed] - x (merged 2026-01-02)\r' >"$wire"
printf '%s' '- [ ] q1 [@held until 2026-09-01] - x' >>"$wire"
want="$(
  printf '%s\n' "$hdr"
  rec '##' '' '' '' '' '' '' '' '' '' '' '' '' '' '## Queued'
  rec t3 '' '' '' '' e1 '' t2 '' '' '' 'src:cap\tqa:yes' '' '' "- [ ] t3 [src:cap${T}qa:yes] - tab${T}in prose; epic:e1 blocked-by: t2 - why"
  rec t2 failed '' '' '' '' '' '' '' 2026-01-02 merged '' '' '' $'- [x] t2 [failed] - x (merged 2026-01-02)\r'
  rec q1 '' 1 2026-09-01 '' '' '' '' '' 2026-09-01 until '' '' '' '- [ ] q1 [@held until 2026-09-01] - x'
  printf 'e\t4\n'
)"
assert_eq "$("$ab" fields "$wire")" "$want" \
  "the wire: a header, one record per input line with contract's TAB as \\t and the raw line last, then the count"
assert_eq "$("$ab" fields - <"$wire")" "$want" "- reads the same bytes from stdin"
: >"$TMP/empty.md"
assert_eq "$("$ab" fields "$TMP/empty.md")" "$hdr"$'\n'"e${T}0" "an empty ledger is a header and a zero trailer"

assert_eq "$("$ab" fields --get contract,id,blockers "$wire")" \
  "${T}##${T}"$'\n'"src:cap\\tqa:yes${T}t3${T}t2"$'\n'"${T}t2${T}"$'\n'"${T}q1${T}" \
  "--get prints the named fields in the order asked, one line per record, no header or trailer"

# expect_rc <rc> <stderr substring> <label> -- <args...>
expect_rc() {
  local want_rc="$1" want_err="$2" label="$3" rc=0 err
  shift 4
  err="$("$ab" "$@" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "$want_rc" "$label: exit status"
  assert_contains "$err" "$want_err" "$label: stderr"
}
expect_rc 1 "ERROR: cannot read $TMP/missing.md" "a missing ledger" -- fields "$TMP/missing.md"
expect_rc 1 "ERROR: cannot read $TMP" "a directory" -- fields "$TMP"
expect_rc 2 "ERROR: usage:" "no verb" --
expect_rc 2 "ERROR: usage:" "an unknown verb" -- lines "$wire"
expect_rc 2 "ERROR: usage:" "no ledger" -- fields
expect_rc 2 "ERROR: usage:" "two ledgers" -- fields "$wire" "$wire"
expect_rc 2 "ERROR: unknown field: bogus" "an unknown field" -- fields --get id,bogus "$wire"
expect_rc 2 "ERROR: unknown field: " "an empty field list" -- fields --get "" "$wire"

# README.md exists in the distro root, where bun runs: reading it would be
# answering for a file the caller never named.
gone="$TMP/gone"
mkdir -p "$gone"
rc=0
err="$(cd "$gone" && rmdir "$gone" && "$ab" fields README.md 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "1" "a relative ledger from a cwd with no name is unreadable, never the distro root's"
assert_contains "$err" "ERROR: cannot read README.md" "a relative ledger from a nameless cwd names what it could not read"

big="$TMP/big.md"
for _ in $(seq 400); do cat "$wire"; printf '\n'; done >"$big"
set +e
"$ab" fields "$big" 2>"$TMP/pipe.err" | head -c 1 >/dev/null
st=("${PIPESTATUS[@]}")
set -e
assert_eq "${st[0]}" "0" "a reader that closes the pipe early ends the run with status 0"
assert_eq "$(cat "$TMP/pipe.err")" "" "a reader that closes the pipe early ends the run silently"

# --- Leg A: the TypeScript parser against the frozen awk parser ---------------
# DISPUTED: the implementation of ac_doneline (tests/fixtures/doneline.awk vs src/backlog.ts through bin/ac-backlog.sh)
# HELD-CONSTANT: input bytes; LC_ALL=C; /usr/bin/awk onetrue 20200816 (SKIP otherwise); field order; the v1 wire's shape, which the awk side prints the same way
oracle() {
  LC_ALL=C /usr/bin/awk "$(cat "$ROOT/tests/fixtures/doneline.awk")"'
    BEGIN {
      n = split("id terminal hold hold_until hold_malformed epic feature blockers blockers_malformed date verb contract domain domain_malformed", K, " ")
      h = "h\tv1"; for (i = 1; i <= n; i++) h = h "\t" K[i]; print h
    }
    {
      ac_doneline($0, o); gsub(/\t/, "\\t", o["contract"])
      r = "r"; for (i = 1; i <= n; i++) r = r "\t" o[K[i]]; print r "\t" $0
    }
    END { print "e\t" NR }' "$1"
}

leg_a() {
  oracle "$1" >"$TMP/awk.wire"
  "$ab" fields "$1" >"$TMP/ts.wire"
  cmp -s "$TMP/awk.wire" "$TMP/ts.wire" \
    || fail "Leg A: src/backlog.ts and the awk parser disagree on $1:
$(diff "$TMP/awk.wire" "$TMP/ts.wire" | head -n 6 | cut -c1-300)"
}

# Every site still runs AC_DONELINE_AWK, not the frozen copy: were the two to
# part, Leg A would stay green while this parser and the sites disagree. The
# check goes when that variable does.
(. "$BIN/ac-lib.sh" && printf '%s\n' "$AC_DONELINE_AWK") >"$TMP/live.awk"
cmp -s "$TMP/live.awk" "$ROOT/tests/fixtures/doneline.awk" \
  || fail "tests/fixtures/doneline.awk is no longer AC_DONELINE_AWK, the grammar every site runs:
$(diff "$ROOT/tests/fixtures/doneline.awk" "$TMP/live.awk" | head -n 6 | cut -c1-300)"

if [ "$(/usr/bin/awk --version 2>/dev/null)" != "awk version 20200816" ]; then
  printf 'SKIP: /usr/bin/awk is not onetrue awk 20200816 - the Leg A differential skipped\n'
else
  seeds="$TMP/seeds.md"
  cat >"$seeds" <<'EOF'
## Queued
- [ ] recon - reconciliation; epic:payv2 blocked-by: checkout,refund - needs both APIs
- [ ] q1 [src:cap] [@held] - waits on the captain (repo: alpha)
- [ ] q2 [@held until 2026-09-01] [src:cap flow:direct mode:local-only rev:no qa:no] - dated (repo: alpha)
- [ ] q3 [CAPTAIN-ORDERED 2026-07-30] [@hold] - mis-typed hold (repo: alpha)
- [ ] q4 - documents the `[@held]` token and `[held]` too; feature:pay-ux (repo: alpha)
- [ ] q5 [src:cap	qa:yes] - tab-joined contract; domain:payments (repo: payments-core)
- [ ] q6 [EPIC 3 stories] [src:cap] - x blocked-by: a, b - listspace
- [ ] q7 - waits (repo: r) blocked-by: payapi - contract first; domain:payments
- [ ] q8 - mentions domain:payments in prose and Blocked-by: x (repo: r)

## Done
- [x] crewmate-missing-from-agents-grouped-view - NOT REPRODUCED on the pane server; root cause was a pre-fix build - FIXED UPSTREAM - so NO change needed; captain accepted close (reported 2026-07-24)
- [x] qa-profile-resolve [EPIC] - DONE 5/5 stories landed on local main (2026-07-24). [captain [EPIC] 2026-07-23; closed 2026-07-24]
- [x] qa-profile-guidance - removed discovery from the skill - local main @cd1efa4 (merged 2026-07-24) [epic:qa-profile-resolve story 5; review=no]
- [x] reports-suffix-md [abandoned] - MOOT, superseded (cleared 2026-07-24 after an audit). (abandoned 2026-07-24)
- [x] codegraph-hook-fix - MITIGATION LANDED - local main @5c625d4 (merged 2026-07-21; ref data/diag/report.md §8(2))
- [x] stress-sh-sweep-guard [abandoned] - premise FALSIFIED against the tree - Karpathy drop (2026-07-20)
- [x] ready-marker-matches-prose-not-position - anchors the [EPIC]/[failed]/[abandoned] marker to its position (merged 2026-07-23).
- [x] t9 [flow:staged mode:crew-ship rev:yes qa:yes] - heavy row (repo: beta) (merged 2026-08-09)
- [x] payland - landed the rounding fix - local main (merged 2026-08-18); domain:payments
- [x] t10 [failed] - gave up (ended 2026-08-01)
prose that is not a task line [src:cap]
[@held] a line-leading group
EOF
  corpus="$TMP/corpus.md"
  { cat "$seeds"; bun "$ROOT/tests/backlog-gen.ts" 20260927 20000 "$seeds"; } >"$corpus"
  assert_eq "$(wc -l <"$corpus" | tr -d ' ')" "$(( $(wc -l <"$seeds") + 20000 ))" "the corpus is the seed rows plus 20,000 generated lines"
  leg_a "$corpus"
  unexercised="$(LC_ALL=C awk -F"$T" '
    NR == 1 { for (i = 3; i <= 16; i++) name[i - 1] = $i }
    $1 == "r" { for (i = 2; i <= 15; i++) if ($i != "") seen[i] = 1 }
    END { for (i = 2; i <= 15; i++) if (!(i in seen)) printf " %s", name[i] }' "$TMP/ts.wire")"
  assert_eq "$unexercised" "" "every field is non-empty somewhere in the corpus, or a zero diff proves nothing about it"
  for ledger in "$@"; do
    leg_a "$ledger"
    printf 'Leg C: %s - %s records identical\n' "$ledger" "$(tail -n 1 "$TMP/ts.wire" | cut -f2)"
  done
fi

pass
