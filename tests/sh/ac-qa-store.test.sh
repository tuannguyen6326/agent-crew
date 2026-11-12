#!/usr/bin/env bash
# ac-qa-store.test.sh - the chief-side QA store verbs (store-dir,
# store-install, store-label, store-calibration) all key the ONE path
# store-dir prints, and a refused install releases its lock. The store's
# history, promotion and kappa arithmetic is held in tests/ts/qa-lib.test.ts.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# --- the chief-side verbs key ONE store: the path store-dir prints ------------
# The repo name sanitizes to a different key (My.App -> my-app), so a verb
# that keyed the raw basename would install where label/calibration never look.
keyrepo="$(make_repo My.App)"
cand="$TMP/candidate"; mkdir -p "$cand/store"
printf 'abc123\t2026-09-28\tC-1\tapi\tfail\tdefect\t-\tm\tt\n' >"$cand/store/history.tsv"
jq -n '{schema:"agentcrew.qa-store-snapshot/v1",entries:[]}' | shasum -a 256 | awk '{print $1}' >"$cand/base-manifest.sha256"
sd="$(cd "$keyrepo" && "$BIN/ac-qa.sh" store-dir)"
assert_contains "$(cd "$keyrepo" && "$BIN/ac-qa.sh" store-install "$cand")" "QA-STORE-INSTALLED: $sd " \
  "store-install replaces the store store-dir names"
assert_file "$sd/history.tsv" "the installed history sits in that store"
(cd "$keyrepo" && "$BIN/ac-qa.sh" store-label C-1 --run abc123 confirmed) >/dev/null
assert_file "$sd.labels.tsv" "store-label writes beside that store"
out="$(cd "$keyrepo" && "$BIN/ac-qa.sh" store-calibration)"
assert_eq "$(jq -r .n <<<"$out")" "1" "calibration pairs the installed history with the label"

# An install that dies inside its lock (an unsafe path in the current store)
# releases it, so the next install is not refused by a dead holder's lock.
: >"$sd/$(printf 'bad\tname')"
out="$(cd "$keyrepo" && "$BIN/ac-qa.sh" store-install "$cand" 2>&1)" && fail "an unsafe path in the store must refuse the install"
assert_contains "$out" "unsafe relative path" "the refusal names the unsafe path"
assert_no_file "$sd.lock" "a refused install leaves no lock behind"

pass
