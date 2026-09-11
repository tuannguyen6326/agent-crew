#!/usr/bin/env bash
# ac-qa-store.test.sh - the QA store learning loop (contract: QA STORE
# LEARNING LOOP in bin/ac-qa-lib.sh): history rows per curated run, machine
# promotion after N consecutive same-body passes, re-verification of store
# cases, the flaky and body-change resets, and the judge-vs-human kappa.
# Pure functions over explicit paths - no live run, no docker.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
lib() { AC_HOME="$AC_HOME" bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; $1"; }

store="$TMP/store"; mkdir -p "$store"
plan="$TMP/testplan.md"
cat >"$plan" <<'EOF'
## Cases
| id | priority | tier | rw | precondition | steps | expected | AC-ref |
| C-1 | P1 | api | ro | none | GET /health | 200 ok | AC-1 |
| C-2 | P2 | web | rw | logged in | click buy | order created | AC-2 |
EOF
cases() { # cases <file> <id:status[:cls]>...
  local f="$1"; shift; : >"$f"
  for spec in "$@"; do
    IFS=: read -r id st cls <<<"$spec"
    printf '%s\tapi\t%s\t%s\t-\tA\te/%s\t-\t-\t-\thttp\tr\n' "$id" "$st" "${cls:--}" "$id" >>"$f"
  done
}

# --- history: one row per case per run, idempotent per (sha, case) -----------
cases "$TMP/run1.tsv" C-1:pass C-2:fail:defect
assert_eq "$(lib "qa_store_history_append '$store' '$TMP/run1.tsv' '$plan' aaa1 gpt-x t1")" "2" "two rows appended"
assert_eq "$(lib "qa_store_history_append '$store' '$TMP/run1.tsv' '$plan' aaa1 gpt-x t1")" "0" "the same run appends nothing twice"
assert_eq "$(wc -l <"$store/history.tsv" | tr -d ' ')" "2" "history holds exactly the run's rows"
body1="$(awk -F'\t' '$3=="C-1"{print $7}' "$store/history.tsv")"
[ "${#body1}" = 64 ] || fail "a case with a testplan row carries its body sha: $body1"
printf 'X-9\tapi\tpass\t-\t-\tA\te\t-\t-\t-\thttp\tr\n' >"$TMP/adhoc.tsv"
lib "qa_store_history_append '$store' '$TMP/adhoc.tsv' '$plan' aaa1 gpt-x t1" >/dev/null
assert_eq "$(awk -F'\t' '$3=="X-9"{print $7}' "$store/history.tsv")" "-" "a case with no testplan row carries no body sha"

# --- promotion: three consecutive same-body passes, distinct shas -------------
out="$(lib "qa_store_promote '$store' '$TMP/run1.tsv' '$plan' aaa1 3")"
assert_eq "$out" "promoted=0 reverified=0" "one pass promotes nothing"
cases "$TMP/run2.tsv" C-1:pass C-2:pass
lib "qa_store_history_append '$store' '$TMP/run2.tsv' '$plan' aaa2 gpt-x t2" >/dev/null
assert_eq "$(lib "qa_store_promote '$store' '$TMP/run2.tsv' '$plan' aaa2 3")" "promoted=0 reverified=0" "two passes promote nothing"
cases "$TMP/run3.tsv" C-1:pass C-2:pass
lib "qa_store_history_append '$store' '$TMP/run3.tsv' '$plan' aaa3 gpt-x t3" >/dev/null
out="$(lib "qa_store_promote '$store' '$TMP/run3.tsv' '$plan' aaa3 3")"
assert_eq "$out" "promoted=1 reverified=0" "C-1 passed three runs in a row and is promoted; C-2 has one fail in its streak"
assert_file "$store/cases/C-1.md" "the promoted case lands in cases/"
assert_contains "$(cat "$store/cases/C-1.md")" "steps: GET /health" "the case body comes from the testplan row"
assert_contains "$(cat "$store/cases/C-1.md")" "verified: aaa3 " "the case is verified at the promoting run"
assert_contains "$(cat "$store/cases/C-1.md")" "status: active" "a promoted case is active"
assert_contains "$(cat "$store/catalog.md")" "- C-1 | api (AC-1) | 200 ok | verified aaa3 " "the catalog gains its line"

# a store case that passes again is re-verified, not re-promoted
cases "$TMP/run4.tsv" C-1:pass C-2:pass
lib "qa_store_history_append '$store' '$TMP/run4.tsv' '$plan' aaa4 gpt-x t4" >/dev/null
out="$(lib "qa_store_promote '$store' '$TMP/run4.tsv' '$plan' aaa4 3")"
assert_eq "$out" "promoted=1 reverified=1" "C-2 now has three passes and is promoted; C-1 is re-verified"
assert_contains "$(cat "$store/cases/C-1.md")" "verified: aaa4 " "the verified line moves to the newest pass"
assert_eq "$(grep -c '^verified: ' "$store/cases/C-1.md")" "1" "exactly one verified line"
assert_contains "$(cat "$store/catalog.md")" "- C-1 | api (AC-1) | 200 ok | verified aaa4 " "the catalog line follows"

# a flaky pass neither counts nor resets; a body change starts a new streak
store2="$TMP/store2"; mkdir -p "$store2"
cases "$TMP/f1.tsv" C-1:pass; lib "qa_store_history_append '$store2' '$TMP/f1.tsv' '$plan' b1 m t" >/dev/null
cases "$TMP/f2.tsv" C-1:pass:flaky; lib "qa_store_history_append '$store2' '$TMP/f2.tsv' '$plan' b2 m t" >/dev/null
cases "$TMP/f3.tsv" C-1:pass; lib "qa_store_history_append '$store2' '$TMP/f3.tsv' '$plan' b3 m t" >/dev/null
assert_eq "$(lib "qa_store_promote '$store2' '$TMP/f3.tsv' '$plan' b3 3")" "promoted=0 reverified=0" "a flaky pass does not count toward the streak"
cases "$TMP/f4.tsv" C-1:pass; lib "qa_store_history_append '$store2' '$TMP/f4.tsv' '$plan' b4 m t" >/dev/null
assert_eq "$(lib "qa_store_promote '$store2' '$TMP/f4.tsv' '$plan' b4 3")" "promoted=1 reverified=0" "...and does not reset it either"
store3="$TMP/store3"; mkdir -p "$store3"
plan2="$TMP/testplan2.md"; sed 's/GET \/health/GET \/healthz/' "$plan" >"$plan2"
cases "$TMP/g1.tsv" C-1:pass; lib "qa_store_history_append '$store3' '$TMP/g1.tsv' '$plan' c1 m t" >/dev/null
cases "$TMP/g2.tsv" C-1:pass; lib "qa_store_history_append '$store3' '$TMP/g2.tsv' '$plan' c2 m t" >/dev/null
cases "$TMP/g3.tsv" C-1:pass; lib "qa_store_history_append '$store3' '$TMP/g3.tsv' '$plan2' c3 m t" >/dev/null
assert_eq "$(lib "qa_store_promote '$store3' '$TMP/g3.tsv' '$plan2' c3 3")" "promoted=0 reverified=0" "a changed body starts a new streak"

# --- calibration: judge (pane) vs human (chief), Cohen's kappa ---------------
hist="$TMP/h.tsv"; labels="$TMP/l.tsv"
printf 'k1\td\tA\tapi\tfail\tdefect\t-\tm\tt\nk1\td\tB\tapi\tpass\t-\t-\tm\tt\nk2\td\tA\tapi\tfail\tdefect\t-\tm\tt\nk2\td\tB\tapi\tfail\tdefect\t-\tm\tt\nk2\td\tC\tapi\tunverifiable\t-\t-\tm\tt\n' >"$hist"
printf 'k1\tA\tconfirmed\tchief\tnow\nk1\tB\tnot-a-defect\tchief\tnow\nk2\tA\tconfirmed\tchief\tnow\nk2\tB\tnot-a-defect\tchief\tnow\nk2\tC\tconfirmed\tchief\tnow\n' >"$labels"
out="$(lib "qa_store_calibration '$hist' '$labels'")"
assert_eq "$(jq -r .n <<<"$out")" "4" "unverifiable rows are skipped: the judge made no defect claim there"
assert_eq "$(jq -r .agreement <<<"$out")" "0.7500" "three of four pairs agree"
assert_eq "$(jq -r .kappa <<<"$out")" "0.5000" "kappa = (0.75 - 0.5) / (1 - 0.5)"
assert_eq "$(jq -r .positives_judge <<<"$out")" "3" "the judge called three defects"
assert_eq "$(jq -r .positives_human <<<"$out")" "2" "the human confirmed two"
out="$(lib "qa_store_calibration '$TMP/none.tsv' '$labels'")"
assert_eq "$(jq -r .n <<<"$out")" "0" "no history means n=0, never a crash"
printf 'k1\td\tA\tapi\tpass\t-\t-\tm\tt\n' >"$hist"; printf 'k1\tA\tnot-a-defect\tchief\tnow\n' >"$labels"
assert_eq "$(jq -r .kappa <<<"$(lib "qa_store_calibration '$hist' '$labels'")")" "1.0000" "pe == 1 with full agreement is kappa 1"

pass
