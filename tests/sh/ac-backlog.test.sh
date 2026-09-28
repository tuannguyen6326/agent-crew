#!/usr/bin/env bash
# ac-backlog.test.sh - bin/ac-backlog.sh's CLI contract (the v1 wire, --get,
# stdin, exit codes, a closed pipe), the AC_DONELINE_AWK binding every awk site
# reaches it through (bin/ac-lib.sh), and Leg A: src/backlog.ts held to
# tests/fixtures/doneline.awk, the awk parser frozen as it stood before the
# sites cut over to this one, over the seed and NUL-bearing rows below plus
# 20,000 lines tests/ts/backlog-gen.ts derives from a fixed seed.
#
# The oracle stays frozen against drift, not against the captain: a ruling that
# changes the grammar changes the oracle the same way in the same diff (TN
# 2026-09-28: a `blocked-by` run the strict read did not consume is MALFORMED
# wherever it sits), so Leg A keeps comparing two readings of ONE grammar.
#
# Leg C is local only: `bash tests/sh/ac-backlog.test.sh <ledger>...` runs every
# ledger named on the command line through Leg A as well, so a live
# records/backlog.md is checked without ever being committed.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# --- the binding: AC_DONELINE_AWK in bin/ac-lib.sh ------------------------------
. "$BIN/ac-lib.sh"
# Shaped like the real sites: an END of its own, with an exit status of its own.
site() {
  awk "$AC_DONELINE_AWK"'/^- \[/ { ac_doneline($0, o); print o["id"] "|" o["hold_until"] "|" o["contract"] } END { print "site END"; exit 1 }' "$@"
}
rc=0
out="$(site "$wire")" || rc=$?
assert_eq "$out" "t3||src:cap${T}qa:yes"$'\n'"t2||"$'\n'"q1|2026-09-01|"$'\n'"site END" "a site reads this parser's fields, a TAB in contract included, and still runs its own END"
assert_eq "$rc" "1" "a healthy parse leaves the site's own exit status alone"

stub="$TMP/stub-bun"
mkdir -p "$stub" "$TMP/nobun"
cat >"$stub/bun" <<'EOF'
#!/bin/sh
case "$STUB_BUN" in
  short) printf 'e\t5\n' ;;
  other) printf 'e\t0\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stub/bun"
for t in bash env dirname awk; do ln -s "$(command -v "$t")" "$TMP/nobun/$t"; done

# binding_dies <label> <stderr substring> <site stdout> <site status>
binding_dies() {
  assert_eq "$4" "2" "$1: exit status"
  assert_contains "$(cat "$TMP/site.err")" "ERROR: $2" "$1: stderr"
  case "$3" in *"site END"*) fail "$1: the site's END ran after the parser failed" ;; esac
}
rc=0; out="$(export PATH="$stub:$PATH" STUB_BUN=fail; site "$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "a parser that exits 1" "the backlog parser failed on $wire" "$out" "$rc"
rc=0; out="$(export PATH="$stub:$PATH" STUB_BUN=short; site "$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "a trailer counting records never printed" "the backlog parser failed on $wire" "$out" "$rc"
rc=0; out="$(export PATH="$stub:$PATH" STUB_BUN=other; site "$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "a line the parse never saw" "$wire changed between the parse and this read" "$out" "$rc"
rc=0; out="$(export PATH="$TMP/nobun"; site "$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "no bun on PATH" "the backlog parser failed on $wire" "$out" "$rc"
rc=0; out="$(site <"$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "stdin" "ac_doneline reads its ledger as a file operand, never stdin" "$out" "$rc"
rc=0; out="$(site - <"$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "- as the ledger" "ac_doneline reads its ledger as a file operand, never stdin" "$out" "$rc"
rc=0; out="$(site /dev/stdin <"$wire" 2>"$TMP/site.err")" || rc=$?
binding_dies "/dev/stdin as the ledger" "ac_doneline reads its ledger as a file operand, never stdin" "$out" "$rc"
rc=0; out="$(site <(cat "$wire") 2>"$TMP/site.err")" || rc=$?
binding_dies "a process substitution as the ledger" "ac_doneline reads its ledger as a file operand, never stdin" "$out" "$rc"

# Neither path is ever shell text, and the parser is found from ac-lib.sh's own
# directory even when it was sourced by a relative name and the caller moved.
# CR and LF are the bytes an awk string literal cannot hold raw.
odd="$TMP/it's \$(touch pwned) \`touch pwned\` \"q\" b\\s"$'\r\n'nl
mkdir -p "$odd" "$TMP/cwd"
ln -s "$BIN" "$odd/bin"
cp "$wire" "$odd/backlog.md"
out="$(cd "$TMP/cwd" && . "$odd/bin/ac-lib.sh" && awk "$AC_DONELINE_AWK"'/^- \[/ { ac_doneline($0, o); print o["id"] }' "$odd/backlog.md")" \
  || fail "a ledger and a distro under a path full of shell syntax: the site exited $?"
assert_eq "$out" "t3"$'\n'"t2"$'\n'"q1" "a ledger and a distro under a path full of shell syntax parse"
assert_no_file "$TMP/cwd/pwned" "a path full of shell syntax runs nothing"
out="$(cd "$odd" && . bin/ac-lib.sh && cd "$TMP/cwd" && awk "$AC_DONELINE_AWK"'/^- \[/ { ac_doneline($0, o); print o["id"] }' "$wire")" \
  || fail "ac-lib.sh sourced by a relative name: the site exited $? after a cd"
assert_eq "$out" "t3"$'\n'"t2"$'\n'"q1" "ac-lib.sh sourced by a relative name still finds the parser after a cd"

counter="$TMP/count-bun"
mkdir -p "$counter"
cat >"$counter/bun" <<EOF
#!/bin/sh
printf x >>"$TMP/bun.starts"
exec "$(command -v bun)" "\$@"
EOF
chmod +x "$counter/bun"
out="$(export PATH="$counter:$PATH"; awk "$AC_DONELINE_AWK"'NR == FNR { if (/^- \[/) ac_doneline($0, o); next } /^- \[/ { ac_doneline($0, o); print o["id"] }' "$wire" "$wire")"
assert_eq "$out" "t3"$'\n'"t2"$'\n'"q1" "a two-pass site reads its second pass"
assert_eq "$(cat "$TMP/bun.starts" 2>/dev/null)" "x" "a site reading one ledger twice starts the parser once"

# F1: under a UTF-8 ctype the awk parser died on a hand-typed check mark
# (`towc: multibyte conversion failure`), and the report printed nothing.
printf '## Queued\n- [ ] q1 - a plain row (repo: alpha)\n- [\342\234\223] q2 - a hand-typed check mark (repo: alpha)\n' \
  >"$AC_HOME/records/backlog.md"
rc=0
out="$(LC_ALL=en_US.UTF-8 "$BIN/ac-ready.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "a hand-typed [✓] row under a UTF-8 locale: ac-ready.sh exit status"
assert_contains "$out" "READY  q1" "a hand-typed [✓] row under a UTF-8 locale leaves the rest of the queue readable"

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
- [ ] q9 - word-prefixed, re-blocked-by: a, - a slip after a word character (repo: r)
- [ ] q10 - a read run then another (repo: r) blocked-by: a - see blocked-by: b

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
  { cat "$seeds"; bun "$ROOT/tests/ts/backlog-gen.ts" 20260927 20000 "$seeds"; } >"$corpus"
  assert_eq "$(wc -l <"$corpus" | tr -d ' ')" "$(( $(wc -l <"$seeds") + 20000 ))" "the corpus is the seed rows plus 20,000 generated lines"
  leg_a "$corpus"
  unexercised="$(LC_ALL=C awk -F"$T" '
    NR == 1 { for (i = 3; i <= 16; i++) name[i - 1] = $i }
    $1 == "r" { for (i = 2; i <= 15; i++) if ($i != "") seen[i] = 1 }
    END { for (i = 2; i <= 15; i++) if (!(i in seen)) printf " %s", name[i] }' "$TMP/ts.wire")"
  assert_eq "$unexercised" "" "every field is non-empty somewhere in the corpus, or a zero diff proves nothing about it"
  # A NUL byte ends awk's record, so a site reads the fields of the bytes
  # before it - through the binding exactly as through the frozen parser -
  # also for a clean row that shares those bytes.
  nul="$TMP/nul.md"
  printf -- '- [ ] n1 [failed]\0 x\n- [ ] n2 do the thing\n- [ ] n2 do the thing\0 blocked-by: zz - waits\n- [ ] a\0b do x\n' >"$nul"
  leg_a "$nul"
  every='/^- \[/ { ac_doneline($0, o); r = ""; for (i = 1; i <= 14; i++) r = r "|" o[K[i]]; print r }'
  every="BEGIN { split(\"id terminal hold hold_until hold_malformed epic feature blockers blockers_malformed date verb contract domain domain_malformed\", K, \" \") } $every"
  want_nul="$(LC_ALL=C /usr/bin/awk "$(cat "$ROOT/tests/fixtures/doneline.awk")$every" "$nul")"
  rc=0; out="$(LC_ALL=C /usr/bin/awk "$AC_DONELINE_AWK$every" "$nul" 2>&1)" || rc=$?
  assert_eq "$rc" "0" "a site over NUL-bearing rows: exit status"
  assert_eq "$out" "$want_nul" "a site over NUL-bearing rows reads what the frozen awk parser read"
  for ledger in "$@"; do
    leg_a "$ledger"
    printf 'Leg C: %s - %s records identical\n' "$ledger" "$(tail -n 1 "$TMP/ts.wire" | cut -f2)"
  done
fi

pass
