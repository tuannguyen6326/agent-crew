#!/usr/bin/env bash
# ac-promote.test.sh - scout-to-ship promotion and the scout teardown
# backstop. Covers: teardown refuses a scout holding unlanded commits on
# crew/<id> even when report.md exists (and points at ac-promote.sh);
# a landed crew branch does not trip the backstop; ac-promote.sh flips
# kind/mode in the meta (registry default and --mode override) so ship
# teardown rules apply; --force still discards; promote refuses non-scout,
# unknown tasks, and bad --mode values; a live window gets the notice.
# Pure git + meta except the final notice case, which drives the fake
# herdr backend (tests/sh/helpers.sh).

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# The fake herdr CLI keeps every backend call hermetic (panes are files
# under $FAKE_HERDR): backend_kill_window and the notice send below can
# never reach the operator's live server.
make_fake_herdr

make_home

mk_meta() {
  # mk_meta <id> <repo> <kind> - the minimal crewmate meta teardown/promote read.
  local m="$AC_HOME/state/$1.meta"
  {
    printf 'project=%s\n' "$(basename "$2")"
    printf 'project_dir=%s\n' "$2"
    printf 'worktree=%s\n' "$2/.crew/worktrees/1"
    printf 'kind=%s\n' "$3"
    printf 'mode=-\n'
  } >"$m"
}

add_crew() {
  # add_crew <repo> <id> - crew/<id> one commit ahead of main, back on main.
  git -C "$1" checkout -q -b "crew/$2"
  printf 'crew change\n' >"$1/crewfile.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "scout wrote code"
  git -C "$1" checkout -q main
}

meta_get() { awk -F= -v k="$2" '$1==k{v=substr($0,length(k)+2)} END{print v}' "$AC_HOME/state/$1.meta"; }

# ---- Case 1: scout with report but UNLANDED crew branch -> teardown refuses -
repo="$(make_repo p1)"
printf -- '- p1 [local-only] - promote test repo (added 2026-07-16)\n' >"$AC_HOME/records/projects.md"
mkdir -p "$AC_HOME/data/s1"
printf 'findings\n' >"$AC_HOME/data/s1/report.md"
mk_meta s1 "$repo" scout
# A GONE window, faithfully: the pane handle a spawn records survives, but
# the herdr pane behind it no longer exists (no fake pane files) - so
# liveness probes fail while teardown's kill path can still resolve the tab.
printf 'p10 t10\n' >"$AC_HOME/state/.pane-s1"
add_crew "$repo" s1
out="$("$BIN/ac-teardown.sh" s1 2>&1)" && fail "teardown must refuse a scout with an unlanded crew branch"
assert_contains "$out" "unlanded work" "refusal names the unlanded work"
assert_contains "$out" "ac-promote.sh s1" "refusal points at ac-promote.sh"
assert_file "$AC_HOME/state/s1.meta" "meta survives the refusal"

# ---- Case 2: promote in place -> kind=ship, mode EXPLICIT (per-task) --------
# Mode is per-task: a bare promote refuses - the
# registry default is gone, and a promotion is exactly the moment the task
# acquires a mode.
out="$("$BIN/ac-promote.sh" s1 2>&1)" && fail "a bare promote must refuse: mode is per-task now"
assert_contains "$out" "mode unspecified" "the refusal names the missing mode"
assert_eq "$(meta_get s1 kind)" "scout" "a refused promote flips nothing"
out="$("$BIN/ac-promote.sh" s1 --mode local-only)"
assert_contains "$out" "kind scout -> ship" "promote prints the kind flip"
assert_contains "$out" "mode=local-only" "the explicit mode is recorded"
assert_contains "$out" "window not reachable" "gone window reported, not fatal"
assert_eq "$(meta_get s1 kind)" "ship" "meta kind flipped to ship"
assert_eq "$(meta_get s1 mode)" "local-only" "meta mode recorded"
assert_contains "$(cat "$AC_HOME/state/s1.status")" "promoted: scout -> ship" "status logged"

# ---- Case 3: promoted task now falls under SHIP teardown rules --------------
out="$("$BIN/ac-teardown.sh" s1 2>&1)" && fail "ship rules must still refuse the unlanded branch"
assert_contains "$out" "not landed" "ship-rule refusal message"

# ---- Case 4: --force still discards (captain's explicit call) ---------------
"$BIN/ac-teardown.sh" s1 --force >/dev/null
assert_no_file "$AC_HOME/state/s1.meta" "meta archived on --force"
assert_file "$AC_HOME/state/archive/s1/meta"
assert_eq "$(awk -F= '$1=="kind"{v=$2} END{print v}' "$AC_HOME/state/archive/s1/meta")" "ship" "archived meta keeps the promotion"

# ---- Case 5: LANDED crew branch does not trip the scout backstop ------------
repo5="$(make_repo p5)"
mkdir -p "$AC_HOME/data/s5"
printf 'findings\n' >"$AC_HOME/data/s5/report.md"
mk_meta s5 "$repo5" scout
printf 'p50 t50\n' >"$AC_HOME/state/.pane-s5"
add_crew "$repo5" s5
git -C "$repo5" merge -q --ff-only crew/s5
"$BIN/ac-teardown.sh" s5 >/dev/null
assert_file "$AC_HOME/state/archive/s5/meta" "landed scout branch tears down normally"

# ---- Case 6: promote refuses non-scout, unknown tasks, bad --mode -----------
repo6="$(make_repo p6)"
mk_meta n1 "$repo6" ship
out="$("$BIN/ac-promote.sh" n1 2>&1)" && fail "promote must refuse a non-scout task"
assert_contains "$out" "not scout" "non-scout refusal names the kind rule"
assert_eq "$(meta_get n1 kind)" "ship" "non-scout meta untouched"
assert_fails "$BIN/ac-promote.sh" nope
mk_meta s6 "$repo6" scout
assert_fails "$BIN/ac-promote.sh" s6 --mode bogus
assert_eq "$(meta_get s6 kind)" "scout" "bad --mode leaves the meta untouched"

# ---- Case 7: cheap modes promote on the chief's own authority ---------------
"$BIN/ac-promote.sh" s6 --mode direct-pr >/dev/null
assert_eq "$(meta_get s6 kind)" "ship" "--mode promote flips kind"
assert_eq "$(meta_get s6 mode)" "direct-pr" "the explicit mode is the record"
rm -f "$AC_HOME/state/s6.meta" "$AC_HOME/state/s6.status"

# ---- Case 7b: crew-ship is a time-expensive choice - captain's word only ----
repo7="$(make_repo p7)"
mk_meta s7 "$repo7" scout
out="$("$BIN/ac-promote.sh" s7 --mode crew-ship 2>&1)" \
  && fail "promoting into crew-ship without the captain's word must refuse"
assert_contains "$out" "time-expensive" "the refusal names the escalation rule"
assert_contains "$out" "REASON" "the refusal demands the reason ride the ask"
assert_contains "$out" "--captain-requested" "the refusal names the remedy"
assert_eq "$(meta_get s7 kind)" "scout" "a refused promotion flips nothing"
out="$("$BIN/ac-promote.sh" s7 --mode direct-pr --captain-requested 'order ref' 2>&1)" \
  && fail "declaring authority the cheap path never needed must refuse"
assert_contains "$out" "nothing to authorize" "an idle declaration is refused"
out="$("$BIN/ac-promote.sh" s7 --mode crew-ship --captain-requested 'captain: run the pipeline on s7' 2>&1)" \
  && fail "the captain's word without the chief's --reason must refuse: the reason rides the record"
assert_contains "$out" "--reason" "the refusal names the missing reason"
"$BIN/ac-promote.sh" s7 --mode crew-ship --captain-requested 'captain: run the pipeline on s7' --reason 'financial surface: the change touches the ledger math' >/dev/null
assert_eq "$(meta_get s7 mode)" "crew-ship" "the declared promotion records the mode"
assert_contains "$(cat "$AC_HOME/state/s7.status")" "captain-requested: captain: run the pipeline on s7" \
  "the captain's word rides the status record"
assert_contains "$(cat "$AC_HOME/state/s7.status")" "reason: financial surface" \
  "the chief's reason rides the status record too"
rm -f "$AC_HOME/state/s7.meta" "$AC_HOME/state/s7.status"

# ---- Case 8: a live window gets the ship-contract notice ---------------------
# Simulate s8's live pane: the recorded pane handle + live fake pane files
# (what a real spawn would have left behind).
repo8="$(make_repo p8)"
mk_meta s8 "$repo8" scout
printf 'p80 t80\n' >"$AC_HOME/state/.pane-s8"
printf 'p80\n' >"$FAKE_HERDR/tabs/t80"
: >"$FAKE_HERDR/panes/p80.buf"
out="$("$BIN/ac-promote.sh" s8 --mode local-only)"
assert_contains "$out" "notified crewmate s8" "live window gets the notice"
assert_contains "$(cat "$(fake_pane_buf s8)")" "crew/s8" "notice names the crew branch"

# The promoted crewmate gets the SAME mode-specific delivery contract a
# briefed worker gets, not just the mode name - a free-form notice left the
# never-push and PR rules behind, the drift one shared renderer kills.
si="$AC_HOME/data/s8/ship-instructions.md"
assert_file "$si" "promotion writes the full ship instructions"
assert_contains "$(cat "$si")" "Mode local-only" "the contract names the mode"
assert_contains "$(cat "$si")" "Never push" "local-only carries its never-push rule"
assert_contains "$(cat "$si")" "crew/s8" "the contract names the crew branch"
assert_contains "$(cat "$(fake_pane_buf s8)")" "ship-instructions.md" \
  "the notice points the crewmate at the full contract"

# ...and a direct-pr promotion renders that mode's PR contract (no pane needed:
# the instructions are written either way).
repo9="$(make_repo p9)"
mk_meta s9 "$repo9" scout
"$BIN/ac-promote.sh" s9 --mode direct-pr >/dev/null
assert_contains "$(cat "$AC_HOME/data/s9/ship-instructions.md")" "open a PR" \
  "direct-pr instructions carry the push-and-PR contract"

# --- the CLI contract, row by row ---------------------------------------------
# One fleet home ($H); each run starts at $TMP with LC_ALL=C, the fake herdr on
# PATH (make_fake_herdr above; pane p80's buffer and composer emptied before
# each run) and one PATH `date` stub freezing the stamp.
H="$TMP/nh"; STUBS="$TMP/pstubs"
mkdir -p "$STUBS"
cat >"$STUBS/date" <<'DATE'
#!/bin/sh
case "$*" in "-u +%Y-%m-%dT%H:%M:%SZ") echo 2026-01-01T00:00:00Z ;; *) exec /bin/date "$@" ;; esac
DATE
chmod +x "$STUBS/date"
ISO=2026-01-01T00:00:00Z
PANE=p80   # the live fake pane case 8 minted (tabs/t80, panes/p80.buf)

LAST_RC=0
run() {  # run <args...> - one promote from $TMP, as a chief runs it; sets LAST_RC, stdout and stderr in $TMP/n.out and n.err
  : >"$FAKE_HERDR/panes/$PANE.buf"; : >"$FAKE_HERDR/panes/$PANE.in"
  LAST_RC=0
  (cd "$TMP" && env AC_HOME="${AC_HOME_ROW:-$H}" LC_ALL=C PATH="${DATE_STUB:-$STUBS}:$PATH" "$BIN/ac-promote.sh" "$@") >"$TMP/n.out" 2>"$TMP/n.err" || LAST_RC=$?
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
shim_buf() { cat "$FAKE_HERDR/panes/$PANE.buf"; }
reset_homes() {  # reset_homes [bare] - an empty home, state/ and data/ minted unless bare
  rm -rf "$H"; mkdir -p "$H"
  [ "${1-}" = bare ] || mkdir -p "$H/state" "$H/data"
}
seed() { mkdir -p "$(dirname "$H/$1")"; printf -- "$2" >"$H/$1"; }  # seed <relpath> <printf-format>
mk() {  # mk <id> [tail-format] - the mk_meta shape; the tail defaults to kind=scout, mode=-
  seed "state/$1.meta" "project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\n${2-kind=scout\\nmode=-\\n}"
}
file_is() {  # file_is <path> <printf-format> - the file holds exactly these bytes
  printf -- "$2" | cmp -s - "$1" || fail "bytes of $1: $(od -c "$1" | head -n 6)"
}
shim_meta_is() { file_is "$H/state/${2:-s1}.meta" "$1"; }
instructions_are() {  # instructions_are <id> <mode-line> - data/<id>/ship-instructions.md, byte for byte
  cat >"$TMP/want.md" <<EOF
# Ship contract: $1 (promoted from scout)

This task now delivers a PROJECT CHANGE on \`crew/$1\`; a report alone no
longer lands it. Start the ship branch from a clean base carrying only the
intended changes - scout scratch commits and debug edits never ride along.

$2

Escalate ask-user findings and needs-decision questions through your status
line as before; the chief relays them to the captain.
EOF
  cmp -s "$TMP/want.md" "$H/data/$1/ship-instructions.md" || fail "ship-instructions.md for $1: $(diff "$TMP/want.md" "$H/data/$1/ship-instructions.md" | head -n 6)"
}
LOCAL_LINE='- Mode local-only: after delivery preparation, leave `crew/ID` clean and fully committed. Never push or open a PR.'
DIRECT_LINE='- Mode direct-pr: after delivery preparation, push `crew/ID` and open a PR against the recorded target branch. The PR body covers intent, changes, and verification evidence, and ends with `Closes #<n>` only for the GitHub issue the brief says this task fixes; never put close, fix or resolve before any other `#<n>` - GitHub closes that issue on merge.'
CREW_LINE='- Mode crew-ship: run the `crew-ship` skill. Its `ac-ship` engine owns the guarded 8-step delivery pipeline (intent, rebase, review, test, document, lint, push, pr). Hand over only after checks pass and include the PR URL.'
USAGE="ERROR: usage: ac-promote.sh <id> --mode <crew-ship|direct-pr|local-only> [--captain-requested '<ref>']"
GONE="crewmate window not reachable; promotion recorded in meta only"

# 1. argument errors, checked before the meta is read: usage, flags before the id, an unknown token, a flag with no or an empty value
reset_homes; mk s1
run
assert_eq "$LAST_RC" 1 "no args exits 1"
assert_eq "$(shim_err)" "$USAGE" "usage refusal"
run ''
assert_eq "$(shim_err)" "$USAGE" "an empty id is usage"
run --mode local-only s1
assert_eq "$(shim_err)" "ERROR: unknown argument: local-only" "a flag before the id becomes the id"
run s1 --bogus
assert_eq "$(shim_err)" "ERROR: unknown argument: --bogus" "an unknown token"
run nope --bogus
assert_eq "$(shim_err)" "ERROR: unknown argument: --bogus" "arg errors precede the meta read"
run s1 --mode
assert_eq "$(shim_err)" "ERROR: missing value for --mode" "--mode as the last token"
run s1 --mode ''
assert_eq "$(shim_err)" "ERROR: missing value for --mode" "an empty --mode value"
run s1 --captain-requested
assert_eq "$(shim_err)" "ERROR: missing value for --captain-requested" "--captain-requested with no value"
run s1 --reason ''
assert_eq "$(shim_err)" "ERROR: missing value for --reason" "an empty --reason value"
assert_eq "$(shim_out)" "" "a refused promote prints nothing"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=scout\nmode=-\n'
assert_no_file "$H/state/s1.status" "nothing written by an arg refusal"

# 2. the meta: unknown id, a directory where the meta should be, an unreadable meta
run nope --mode local-only
assert_eq "$LAST_RC" 1 "unknown id exits 1"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for nope" "no meta"
reset_homes; mkdir -p "$H/state/s1.meta"
run s1 --mode local-only
assert_eq "$(shim_err)" "ERROR: no crewmate meta for s1" "a directory is no meta"
if [ "$(id -u)" != 0 ]; then
  reset_homes; mk s1; chmod 000 "$H/state/s1.meta"
  run s1 --mode local-only
  assert_eq "$LAST_RC" 1 "an unreadable meta exits 1"
  assert_eq "$(shim_err)" "WARN: cannot read meta file $H/state/s1.meta" "the helper's WARN is the only line"
  assert_eq "$(shim_out)" "" "nothing promoted"
  chmod 644 "$H/state/s1.meta"
  shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=scout\nmode=-\n'
fi

# 3. kind: ship, absent, `scout\r`, `Scout`, twice, last wins
reset_homes; mk s1 'kind=ship\nmode=-\n'
run s1 --mode local-only
assert_eq "$(shim_err)" "ERROR: task s1 is kind=ship, not scout (only scouts promote)" "kind=ship"
reset_homes; mk s1 'mode=-\n'
run s1 --mode local-only
assert_eq "$(shim_err)" "ERROR: task s1 is kind=unset, not scout (only scouts promote)" "an absent kind reads unset"
reset_homes; mk s1 'kind=scout\r\nmode=-\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 1 "kind=scout CR is not scout"
file_is "$TMP/n.err" 'ERROR: task s1 is kind=scout\r, not scout (only scouts promote)\n'
reset_homes; mk s1 'kind=Scout\nmode=-\n'
run s1 --mode local-only
assert_eq "$(shim_err)" "ERROR: task s1 is kind=Scout, not scout (only scouts promote)" "the compare is byte-exact"
reset_homes; mk s1 'kind=scout\nkind=scout\nmode=-\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 0 "kind twice promotes"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=local-only\n'
reset_homes; mk s1 'kind=ship\nkind=scout\nmode=-\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 0 "the LAST kind= wins"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=local-only\n'

# 4. mode refusals, in the entry's order; --mode repeated, last wins
reset_homes; mk s1
run s1
assert_eq "$(shim_err)" "ERROR: mode unspecified for promoting 's1': pass --mode <crew-ship|direct-pr|local-only>. Mode is per-task now - the registry default is gone" "bare promote"
run s1 --mode bogus
assert_eq "$(shim_err)" "ERROR: invalid --mode: bogus (want crew-ship|direct-pr|local-only)" "a bogus mode"
run s1 --mode feature-pr
assert_eq "$(shim_err)" "ERROR: invalid --mode: feature-pr (want crew-ship|direct-pr|local-only)" "feature-pr is invalid HERE though briefs take it (W4)"
run s1 --mode crew-ship
assert_eq "$(shim_err)" "ERROR: promoting 's1' into crew-ship is a time-expensive choice: it needs the captain's confirmation, with your REASON stated in the ask - then declare it with --captain-requested '<the captain's words, or the order ref>' --reason '<the justification you gave>'. Nothing promoted" "crew-ship without the word"
run s1 --mode crew-ship --captain-requested ref
assert_eq "$(shim_err)" "ERROR: promoting 's1' into crew-ship carries the captain's word but no --reason '<the justification you gave the captain>': the reason must ride the record. Nothing promoted" "the word without a reason"
run s1 --mode direct-pr --captain-requested ref
assert_eq "$(shim_err)" "ERROR: --captain-requested has nothing to authorize here: promoting into direct-pr is the cheap path. Drop the flag - declaring authority that was never needed muddies the record" "an idle word"
run s1 --mode local-only --reason r
assert_eq "$(shim_err)" "ERROR: --reason has nothing to justify here: promoting into local-only is the cheap path. Drop the flag" "an idle reason"
run s1 --mode local-only --reason r --captain-requested ref
assert_eq "$(shim_err)" "ERROR: --reason has nothing to justify here: promoting into local-only is the cheap path. Drop the flag" "the reason refusal precedes the word refusal"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=scout\nmode=-\n'
assert_no_file "$H/state/s1.status" "every mode refusal writes nothing"
run s1 --mode local-only --mode direct-pr
assert_eq "$LAST_RC" 0 "--mode repeated promotes"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=direct-pr\n'
assert_contains "$(shim_out)" "mode=direct-pr" "the last --mode wins"

# 5. the happy local-only path with a GONE pane (the handle survives, the fake pane does not)
reset_homes; mk s1; seed state/.pane-s1 'p10 t10\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 0 "promoted"
assert_eq "$(shim_out)" "promoted s1: kind scout -> ship, mode=local-only (ship teardown protection now applies)
$GONE" "the two stdout lines"
assert_eq "$(shim_err)" "" "silent on stderr"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=local-only\n'
assert_eq "$(cat "$H/state/s1.status")" "$ISO promoted: scout -> ship (mode=local-only)" "the status line under the frozen clock"
assert_eq "$(cat "$H/data/s1/timeline.log")" "$ISO promoted: scout -> ship (mode=local-only)" "the timeline mirror in the flat task dir"
instructions_are s1 "${LOCAL_LINE//ID/s1}"
assert_eq "$(ls "$H/state")" "s1.meta
s1.status" "no temp sibling is left behind"
assert_eq "$(stat -f %Lp "$H/state/s1.meta")" "644" "the meta's mode"

# 6. direct-pr and crew-ship: the status suffixes, the renderer line per mode; a ref of spaces rides
reset_homes; mk s1
run s1 --mode direct-pr
assert_eq "$(cat "$H/state/s1.status")" "$ISO promoted: scout -> ship (mode=direct-pr)" "direct-pr status"
instructions_are s1 "${DIRECT_LINE//ID/s1}"
reset_homes; mk s1
run s1 --mode crew-ship --captain-requested 'captain: go' --reason 'ledger math'
assert_eq "$(cat "$H/state/s1.status")" "$ISO promoted: scout -> ship (mode=crew-ship) captain-requested: captain: go reason: ledger math" "crew-ship status carries the word and the reason"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=crew-ship\n'
instructions_are s1 "$CREW_LINE"
reset_homes; mk s1
run s1 --mode crew-ship --captain-requested ' ' --reason r
assert_eq "$(cat "$H/state/s1.status")" "$ISO promoted: scout -> ship (mode=crew-ship) captain-requested:   reason: r" "a ref of only spaces is non-empty and rides"

# 7. a LIVE fake pane gets the notice: the second stdout line, the buffer holds the notice with the contract's absolute path
reset_homes; mk s8; seed state/.pane-s8 'p80 t80\n'
run s8 --mode local-only
assert_eq "$(shim_out)" "promoted s8: kind scout -> ship, mode=local-only (ship teardown protection now applies)
notified crewmate s8 of the ship contract" "the notified line"
assert_eq "$(shim_buf)" "NOTICE: this task was promoted to SHIP - deliver the project change on crew/s8; delivery per mode=local-only. Read your full contract: $H/data/s8/ship-instructions.md. A report alone no longer lands it." "the notice in the pane"
instructions_are s8 "${LOCAL_LINE//ID/s8}"

# 9. meta shapes: `mode=-` replaced, two mode= lines dropped, kind= mid-file keeps the other lines' order, an unterminated tail
reset_homes; seed state/s1.meta 'mode=x\na=1\nkind=scout\nmode=y\nz=9'
run s1 --mode direct-pr
shim_meta_is 'a=1\nz=9\nkind=ship\nmode=direct-pr\n'

# 10. a staged id: the status mirror lands in the nested task dir
reset_homes; mk fam-spec; seed data/fam/spec/brief.md 'b\n'
run fam-spec --mode local-only
assert_eq "$(cat "$H/data/fam/spec/timeline.log")" "$ISO promoted: scout -> ship (mode=local-only)" "the mirror follows the task dir"

# 11. a meta holding a NUL byte keeps its bytes
reset_homes; seed state/s1.meta 'note=a\0b\nkind=scout\nmode=-\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 0 "a NUL in the meta still promotes"
shim_meta_is 'note=a\0b\nkind=ship\nmode=local-only\n'

# 13. an AC_HOME that cannot be entered is named, exit 1
reset_homes
AC_HOME_ROW="$TMP/missing-home" run s1 --mode local-only
assert_eq "$LAST_RC" 1 "an unenterable home exits 1"
assert_contains "$(shim_err)" "ERROR: AC_HOME is not a readable directory: $TMP/missing-home" "the unenterable home is named"
assert_eq "$(shim_out)" "" "nothing promoted"

# 14. reason and ref bytes: `$`, back-ticks, a newline, 2 KB ride the status line raw
reset_homes; mk s1
big="$(printf 'x%.0s' $(seq 1 2048))"
run s1 --mode crew-ship --captain-requested 'ref $HOME `id` %s' --reason "two
lines $big"
assert_eq "$LAST_RC" 0 "odd bytes promote"
assert_eq "$(cat "$H/state/s1.status")" "$ISO promoted: scout -> ship (mode=crew-ship) captain-requested: ref \$HOME \`id\` %s reason: two
lines $big" "the bytes ride raw, nothing expanded"
# bun decodes argv, so a reason byte that is not UTF-8 is recorded as U+FFFD
reset_homes; mk s1
run s1 --mode crew-ship --captain-requested ref --reason "$(printf 'caf\351')"
assert_eq "$LAST_RC" 0 "a non-UTF-8 reason promotes"
file_is "$H/state/s1.status" "$ISO promoted: scout -> ship (mode=crew-ship) captain-requested: ref reason: caf\357\277\275\n"
shim_meta_is 'project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=crew-ship\n'

# 15. data/<id>/ pre-existing with an old contract (overwritten); data/ absent (minted)
reset_homes; mk s1; seed data/s1/ship-instructions.md 'stale contract\n'; seed data/s1/report.md 'findings\n'
run s1 --mode direct-pr
instructions_are s1 "${DIRECT_LINE//ID/s1}"
assert_eq "$(cat "$H/data/s1/report.md")" "findings" "the task dir's other files stay"
reset_homes bare; mk s1
run s1 --mode local-only
assert_eq "$LAST_RC" 0 "an absent data/ is minted"
assert_file "$H/data/s1/ship-instructions.md"
assert_file "$H/data/s1/timeline.log"

# 16. a NUL in the kind value: the value is cut at the NUL, so `scout<NUL>` promotes
reset_homes; seed state/s1.meta 'kind=scout\0\nmode=-\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 0 "NUL kind: the run promotes"
assert_eq "$(shim_out)" "promoted s1: kind scout -> ship, mode=local-only (ship teardown protection now applies)
$GONE" "NUL kind: the receipt"
shim_meta_is 'kind=ship\nmode=local-only\n'

# 17. the writes that fail after the meta flipped; no notice is attempted
# a date that fails when the status is stamped: date's status, meta flipped,
# no status line, no instructions
mkdir -p "$TMP/baddate"; printf '#!/bin/sh\ncase "$*" in "-u +%%Y-%%m-%%dT%%H:%%M:%%SZ") exit 3 ;; *) exec /bin/date "$@" ;; esac\n' >"$TMP/baddate/date"; chmod +x "$TMP/baddate/date"
FLIPPED='project=p1\nproject_dir=/p1\nworktree=/p1/.crew/worktrees/1\nkind=ship\nmode=local-only\n'
reset_homes; mk s1
DATE_STUB="$TMP/baddate" run s1 --mode local-only
assert_eq "$LAST_RC" 3 "date failing: the run ends with date's status"
assert_eq "$(shim_out)$(shim_err)" "" "date failing: nothing printed"
assert_eq "$(shim_buf)" "" "date failing: no notice"
shim_meta_is "$FLIPPED"
assert_no_file "$H/state/s1.status" "date failing: no status line"
assert_no_file "$H/data/s1/ship-instructions.md" "date failing: no instructions"
# a status file that cannot be appended: refused, exit 1; meta flipped, no mirror
if [ "$(id -u)" != 0 ]; then
  reset_homes; mk s1; seed state/s1.status ''
  chmod 000 "$H/state/s1.status"
  run s1 --mode local-only
  chmod 644 "$H/state/s1.status"
  assert_eq "$LAST_RC" 1 "unwritable status: exit 1"
  assert_eq "$(shim_out)" "" "unwritable status: no receipt"
  assert_eq "$(shim_err)" "ERROR: cannot append $H/state/s1.status" "unwritable status: the refusal"
  assert_eq "$(shim_buf)" "" "unwritable status: no notice"
  shim_meta_is "$FLIPPED"
  assert_no_file "$H/data/s1/timeline.log" "unwritable status: no mirror after the failed primary"
  assert_no_file "$H/data/s1/ship-instructions.md" "unwritable status: no instructions"
fi
# data/<id> blocked by a FILE: the spawned mkdir -p fails, exit 1; meta and
# status written, no instructions, no notice
reset_homes; mk s1; seed data/s1 'a file\n'
run s1 --mode local-only
assert_eq "$LAST_RC" 1 "mkdir blocked: exit 1 with mkdir's status"
assert_eq "$(shim_out)" "promoted s1: kind scout -> ship, mode=local-only (ship teardown protection now applies)" "mkdir blocked: the first line only"
assert_eq "$(shim_buf)" "" "mkdir blocked: no notice"
assert_file "$H/state/s1.status"
# the instructions path is a directory: refused, exit 1, no notice
reset_homes; mk s1
mkdir -p "$H/data/s1/ship-instructions.md"
run s1 --mode local-only
assert_eq "$LAST_RC" 1 "instructions a directory: exit 1"
assert_eq "$(shim_err)" "ERROR: cannot write $H/data/s1/ship-instructions.md: EISDIR" "instructions a directory: the refusal"
assert_eq "$(shim_buf)" "" "instructions a directory: no notice"

pass
