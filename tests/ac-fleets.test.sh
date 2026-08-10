#!/usr/bin/env bash
# ac-fleets.test.sh - READ-ONLY cross-fleet overview (ac-fleets.sh):
# per-home crew/inbox/watcher/wakes/lock blocks (incl. the none-in-flight
# render and a receipts-only room counting as 0 pending), crewdeputy nesting,
# non-home skipping, container resolution (arg > env > AC_HOME parent),
# graceful degrade (empty/partial/missing container, and a regular FILE passed
# as the container), and a fixture-container + AC_HOME proof that a run creates
# or modifies NOTHING.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

fleets() { "$BIN/ac-fleets.sh" "$@"; }

iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# -- build a throwaway homes container -------------------------------------------
# alpha: a fully-populated home (crew in flight, a pending gate, a handback,
#        a fresh watcher beacon + owner, queued wakes, a live-held lock, and a
#        nested crewdeputy home gamma).
# beta:  a partial home (only config/, no state/ or data/) - must render an
#        empty-but-valid block and create NOTHING.
# notahome: has none of data/state/config - must be skipped silently.
container="$TMP/container"
mkdir -p "$container"

alpha="$container/alpha"
mkdir -p "$alpha/state" "$alpha/data" "$alpha/config"
printf 'TN\n' >"$alpha/config/captain"
# crew in flight (state/*.meta + state/*.status; never a backend probe)
printf 'kind=ship\nproject=agent-crew\nmode=local-only\nwindow=w1\nbackend=tmux\n' >"$alpha/state/ac-fleets.meta"
printf '%s spawned\n%s running\n' "$(iso)" "$(iso)" >"$alpha/state/ac-fleets.status"
printf 'kind=scout\nproject=hello\nbackend=tmux\n' >"$alpha/state/greet2-spec.meta"
# rooms: one pending gate, one handback not yet closed, one receipts-only
# (TRIAGE/SELF-APPROVED/GATE-PASSED) that must count as 0 pending / 0 handback.
mkdir -p "$alpha/data/ac-fleets" "$alpha/data/greet2" "$alpha/data/rcpt"
printf '# Room: ac-fleets\n\n- [%s] crewchief> GATE: approve the spec?\n' "$(iso)" >"$alpha/data/ac-fleets/room.md"
printf '# Room: greet2\n\n- [%s] greet2-chief> HANDBACK: shipped, please close\n' "$(iso)" >"$alpha/data/greet2/room.md"
printf '# Room: rcpt\n\n- [%s] crewchief> TRIAGE: flow=direct mode=local-only\n- [%s] crewchief> SELF-APPROVED: spec - grounds: matches order\n- [%s] crewchief> GATE-PASSED (auto): plan - chief+judge concur\n' "$(iso)" "$(iso)" "$(iso)" >"$alpha/data/rcpt/room.md"
# watcher: fresh beacon + owner pid
date +%s >"$alpha/state/.last-watcher-beat"
printf '4242\n' >"$alpha/state/.watcher-owner"
# queued wakes (3 records)
mkdir -p "$alpha/state/.wake-spool"
printf 'a\n' >"$alpha/state/.wake-spool/1.1.000000"
printf 'b\n' >"$alpha/state/.wake-spool/1.1.000001"
printf 'c\n' >"$alpha/state/.wake-spool/1.1.000002"
# session lock held by a LIVE pid (this test's own shell)
printf 'pid=%s\nsince=%s\n' "$$" "$(iso)" >"$alpha/state/.session-lock"
# nested crewdeputy home
gamma="$alpha/crewdeputies/gamma"
mkdir -p "$gamma/state" "$gamma/config"
printf 'TN\n' >"$gamma/config/captain"
touch "$gamma/.ac-crewdeputy-home"

beta="$container/beta"
mkdir -p "$beta/config"          # partial home: NO state/, NO data/
printf 'TN\n' >"$beta/config/captain"

notahome="$container/notahome"
mkdir -p "$notahome"
printf 'junk\n' >"$notahome/readme.txt"

# -- zero-writes proof: snapshot the whole container before and after a run -------
snapshot() {
  ( cd "$1" && find . | LC_ALL=C sort
    printf -- '--- content ---\n'
    find . -type f -exec cksum {} \; 2>/dev/null | LC_ALL=C sort )
}
before="$(snapshot "$container")"
# read-only means NOWHERE, not just inside the scanned homes: the command's
# own AC_HOME (a sibling of the container here) must be untouched too.
home_before="$(snapshot "$AC_HOME")"

out="$(fleets "$container")" || fail "ac-fleets.sh must exit 0"

after="$(snapshot "$container")"
home_after="$(snapshot "$AC_HOME")"
[ "$before" = "$after" ] || {
  printf '%s\n' "$before" >"$TMP/snap.before"
  printf '%s\n' "$after" >"$TMP/snap.after"
  fail "run MUTATED the container (see $TMP/snap.before vs $TMP/snap.after): $(diff "$TMP/snap.before" "$TMP/snap.after" | head)"
}
[ "$home_before" = "$home_after" ] || fail "run wrote into its own AC_HOME ($AC_HOME) - read-only means nowhere"
# the partial home must not have gained a state/ dir
assert_no_file "$beta/state" "read-only run must not create beta/state"

# -- alpha: every field present --------------------------------------------------
assert_contains "$out" "alpha" "lists the alpha home"
assert_contains "$out" "captain: TN" "shows the captain"
# crew from meta + last status line
assert_contains "$out" "ac-fleets" "crew id from state/*.meta"
assert_contains "$out" "greet2-spec" "second crew id"
assert_contains "$out" "running" "crew status from state/*.status last line"
# kind + project columns are part of the crew signal - assert them, so a
# dropped/transposed column is caught, not just the id and status word.
assert_contains "$out" "scout" "crew kind column rendered"
assert_contains "$out" "hello" "crew project column (scout row) rendered"
assert_contains "$out" "agent-crew" "crew project column (ship row) rendered"
# inbox: pending gate + handback; the receipts-only room (rcpt) contributes
# nothing - the count stays 1 (not 2) and rcpt never surfaces in the inbox.
assert_contains "$out" "1 pending" "inbox pending count (receipts add 0)"
assert_contains "$out" "GATE:" "pending gate line surfaced"
assert_contains "$out" "HANDBACK" "handback surfaced"
case "$out" in *rcpt*) fail "receipts-only room must not surface in the inbox" ;; *) : ;; esac
# watcher armed (fresh beacon), with owner
assert_contains "$out" "armed" "fresh beacon = armed"
assert_contains "$out" "owner pid 4242" "watcher owner pid shown"
# wakes
assert_contains "$out" "3 queued" "queued-wake count"
# lock held by the live pid
assert_contains "$out" "held pid=$$" "live lock shows held with pid"
# crewdeputy nesting
assert_contains "$out" "gamma" "nested crewdeputy home surfaced"
assert_contains "$out" "crewdeputies" "crewdeputy section labelled"

# -- --json: additive, read-only re-emission of the SAME walk (D2) ----------------
# `ac-fleets.sh --json` prints the same survey as ONE JSON document: valid JSON,
# the top-level container/homes/totals keys, the per-home fields the text walk
# already computes (crew, inbox, watcher, wakes, lock), plus the cadence line and
# config pins the cross-fleet cards render - and, like every ac-fleets run, it
# writes NOTHING. Seed alpha's cadence/config so those fields pin to real values,
# not just defaults.
command -v jq >/dev/null 2>&1 || fail "the --json shape test needs jq"
printf 'debriefs=6\nlast_run=1700000000\n' >"$alpha/state/.learn.meta"
printf 'runs_since=5\n' >"$alpha/state/.curate.meta"
# gamma (nested crewdeputy, no learn-every/curate-every knob) is over BOTH
# default thresholds. That makes the two tallies differ in VALUE as well as in
# which home they come from - learning_due 1 (gamma) vs curate_due 2 (alpha +
# gamma) - so a totals pass that read the wrong flag could not go unnoticed.
printf 'debriefs=9\n' >"$gamma/state/.learn.meta"
printf 'runs_since=7\n' >"$gamma/state/.curate.meta"
printf '8\n' >"$alpha/config/learn-every"
printf '5\n' >"$alpha/config/curate-every"
printf 'direct\n' >"$alpha/config/flow"
printf 'always\n' >"$alpha/config/promote"
printf 'chief\n' >"$alpha/config/remote-mirror"

jbefore="$(snapshot "$container")"
json="$(fleets --json "$container")" || fail "ac-fleets.sh --json must exit 0"
jafter="$(snapshot "$container")"
[ "$jbefore" = "$jafter" ] || fail "--json run MUTATED the container - --json is read-only too"
printf '%s' "$json" | jq -e . >/dev/null 2>&1 || fail "--json must emit valid JSON"

# top-level shape
assert_eq "$(jq -r '.container' <<<"$json")" "$container" "--json container path"
assert_eq "$(jq -r 'has("generated_at")' <<<"$json")" "true" "--json carries generated_at"
assert_eq "$(jq -r '.grace' <<<"$json")" "300" "--json grace default"
assert_eq "$(jq -r '.homes | type' <<<"$json")" "array" "--json homes is an array"

# alpha home object - the per-home fields
aj="$(jq -c '.homes[] | select(.name=="alpha")' <<<"$json")"
[ -n "$aj" ] || fail "--json must include the alpha home object"
assert_eq "$(jq -r '.captain' <<<"$aj")" "TN" "--json alpha captain"
# path: the home's resolved dir, so the drill-down can read its files
assert_eq "$(jq -r '.path' <<<"$aj")" "$container/alpha" "--json alpha home path"
assert_eq "$(jq -r '.crewdeputies[0].path' <<<"$aj")" "$container/alpha/crewdeputies/gamma" "--json nested crewdeputy path"
# crew: count + structured id/kind/project/status
assert_eq "$(jq -r '.crew.count' <<<"$aj")" "2" "--json alpha crew count"
assert_eq "$(jq -r '.crew.tasks | map(.id) | sort | join(",")' <<<"$aj")" "ac-fleets,greet2-spec" "--json crew ids"
assert_eq "$(jq -r '.crew.tasks[] | select(.id=="greet2-spec") | .kind' <<<"$aj")" "scout" "--json crew kind"
assert_eq "$(jq -r '.crew.tasks[] | select(.id=="ac-fleets") | .project' <<<"$aj")" "agent-crew" "--json crew project"
assert_eq "$(jq -r '.crew.tasks[] | select(.id=="ac-fleets") | .status' <<<"$aj")" "running" "--json crew last status"
# delivery mode rides the task row (dashboard shows the mode a task RUNS
# with - captain order 2026-08-10); a meta without one carries null.
assert_eq "$(jq -r '.crew.tasks[] | select(.id=="ac-fleets") | .mode' <<<"$aj")" "local-only" "--json crew delivery mode"
assert_eq "$(jq -r '.crew.tasks[] | select(.id=="greet2-spec") | .mode' <<<"$aj")" "null" "--json a modeless meta carries null"
# inbox: the SAME accounting as text (1 pending, 1 handback; rcpt receipts add 0)
assert_eq "$(jq -r '.inbox.pending' <<<"$aj")" "1" "--json inbox pending mirrors text"
assert_eq "$(jq -r '.inbox.handback' <<<"$aj")" "1" "--json inbox handback mirrors text"
assert_eq "$(jq -r '.inbox.entries | length' <<<"$aj")" "2" "--json inbox entries (pending + handback)"
assert_eq "$(jq -r '[.inbox.entries[].family] | sort | join(",")' <<<"$aj")" "ac-fleets,greet2" "--json inbox entry families"
# watcher: armed (fresh beacon) with owner pid + a numeric age
assert_eq "$(jq -r '.watcher.state' <<<"$aj")" "armed" "--json watcher state"
assert_eq "$(jq -r '.watcher.owner' <<<"$aj")" "4242" "--json watcher owner pid"
assert_eq "$(jq -r '.watcher.age | type' <<<"$aj")" "number" "--json watcher age numeric"
# wakes
assert_eq "$(jq -r '.wakes' <<<"$aj")" "3" "--json wakes count"
# lock held by the live pid
assert_eq "$(jq -r '.lock.state' <<<"$aj")" "held" "--json lock state"
assert_eq "$(jq -r '.lock.pid' <<<"$aj")" "$$" "--json lock pid"
# config pins the card header renders
assert_eq "$(jq -r '.config.flow' <<<"$aj")" "direct" "--json config flow"
assert_eq "$(jq -r '.config.promote' <<<"$aj")" "always" "--json config promote"
assert_eq "$(jq -r '.config.mirror' <<<"$aj")" "chief" "--json config mirror"
# cadence: count/every + the due boolean, proven BOTH ways
assert_eq "$(jq -r '.cadence.learn.count' <<<"$aj")" "6" "--json learn count"
assert_eq "$(jq -r '.cadence.learn.every' <<<"$aj")" "8" "--json learn every"
assert_eq "$(jq -r '.cadence.learn.due' <<<"$aj")" "false" "--json learn not due (6<8)"
assert_eq "$(jq -r '.cadence.curate.due' <<<"$aj")" "true" "--json curate due (5>=5)"
# last_run: the DISTILL stamp, epoch seconds, as ac_learn_reset writes it
assert_eq "$(jq -r '.cadence.learn.last_run' <<<"$aj")" "1700000000" "--json learn last_run stamp"
# a home with NO .learn.meta reports ZEROS + a null stamp - never a missing key
bj="$(jq -c '.homes[] | select(.name=="beta")' <<<"$json")"
assert_eq "$(jq -r '.cadence.learn.count' <<<"$bj")" "0" "--json stateless home learn count 0"
assert_eq "$(jq -r '.cadence.learn.every' <<<"$bj")" "8" "--json stateless home learn every default"
assert_eq "$(jq -r '.cadence.learn.due' <<<"$bj")" "false" "--json stateless home not learn-due"
assert_eq "$(jq -r '.cadence.learn.last_run' <<<"$bj")" "null" "--json stateless home last_run null"
assert_eq "$(jq -r '.cadence.curate.count' <<<"$bj")" "0" "--json stateless home curate count 0"
assert_eq "$(jq -r '.crewdeputies[0].cadence.learn.due' <<<"$aj")" "true" "--json nested gamma is learn-due (9>=8 default)"
# crewdeputy nesting: gamma nested inside alpha, never a top-level home
assert_eq "$(jq -r '.crewdeputies | length' <<<"$aj")" "1" "--json alpha has one crewdeputy"
assert_eq "$(jq -r '.crewdeputies[0].name' <<<"$aj")" "gamma" "--json gamma nested under alpha"
assert_eq "$(jq -r '[.homes[].name] | index("gamma")' <<<"$json")" "null" "--json gamma is not a top-level home"
# totals across the WHOLE walk (nested crewdeputies included)
assert_eq "$(jq -r '.totals.homes' <<<"$json")" "3" "--json totals homes (alpha+beta+gamma)"
assert_eq "$(jq -r '.totals.crew' <<<"$json")" "2" "--json totals crew (gamma/beta have none)"
assert_eq "$(jq -r '.totals.pending' <<<"$json")" "1" "--json totals pending"
assert_eq "$(jq -r '.totals.handback' <<<"$json")" "1" "--json totals handback"
assert_eq "$(jq -r '.totals.watchers_down' <<<"$json")" "0" "--json watchers_down counts coverage gaps (crew + down), not idle homes"
# the two cadence tallies: HOMES at/over their own threshold, across the whole
# walk (crewdeputies included) - learn is due only in gamma, curate only in alpha
assert_eq "$(jq -r '.totals.learning_due' <<<"$json")" "1" "--json totals learning_due counts only the over-threshold home"
assert_eq "$(jq -r '.totals.curate_due' <<<"$json")" "2" "--json totals curate_due counts BOTH over-threshold homes (a different set than learning_due)"

# restore alpha's pristine fixture so the later text assertions are unaffected
rm -f "$alpha/state/.learn.meta" "$alpha/state/.curate.meta" \
  "$gamma/state/.learn.meta" "$gamma/state/.curate.meta" \
  "$alpha/config/learn-every" "$alpha/config/curate-every" \
  "$alpha/config/flow" "$alpha/config/promote" "$alpha/config/remote-mirror"

# -- --paths: the CHEAP source for allowedHomePaths (dashboard.ts) ---------------
# bin/dashboard.ts's allowedHomePaths() reads ONLY h.path/h.crewdeputies from
# `--json` and throws away the whole per-home crew/inbox/watcher/wakes/lock/
# cadence/config computation that walk pays for (the "batch facility sits
# unused" item (c)). `--paths` is the paths-only sibling: same home-discovery
# walk (is_home, crewdeputy nesting), none of the per-home accounting,
# read-only like every other mode.
command -v jq >/dev/null 2>&1 || fail "the --paths shape test needs jq"
pbefore="$(snapshot "$container")"
pathsjson="$(fleets --paths "$container")" || fail "ac-fleets.sh --paths must exit 0"
pafter="$(snapshot "$container")"
[ "$pbefore" = "$pafter" ] || fail "--paths run MUTATED the container - --paths is read-only too"
printf '%s' "$pathsjson" | jq -e . >/dev/null 2>&1 || fail "--paths must emit valid JSON"
assert_eq "$(jq -r '.homes | type' <<<"$pathsjson")" "array" "--paths homes is an array"
assert_eq "$(jq -r '.homes | length' <<<"$pathsjson")" "2" "--paths lists alpha+beta, notahome skipped"
pj="$(jq -c --arg p "$alpha" '.homes[] | select(.path==$p)' <<<"$pathsjson")"
[ -n "$pj" ] || fail "--paths must include the alpha home path"
assert_eq "$(jq -r '.crewdeputies[0].path' <<<"$pj")" "$gamma" \
  "--paths nests the crewdeputy path the same shape as --json"
assert_eq "$(jq -r --arg g "$gamma" '[.homes[].path] | index($g)' <<<"$pathsjson")" "null" \
  "--paths: gamma is not a top-level home, same as --json"
# never a key --json carries: proves this is the cheap sibling, not --json
# with fields stripped downstream.
assert_eq "$(jq -r 'has("totals")' <<<"$pathsjson")" "false" \
  "--paths carries no totals (nothing downstream needs them)"
assert_eq "$(jq -r '.homes[0] | has("crew")' <<<"$pathsjson")" "false" \
  "--paths home objects carry no crew/inbox/watcher/wakes/lock/cadence"

# --paths must never shell out to ac-room.sh at all: the whole point of item
# (c) is that the per-room inbox tally is SKIPPED, not merely discarded
# downstream. A copied lab bin/ resolves bin_dir to itself (dirname "$0"),
# the same technique tests/ac-watch-autoarm.test.sh uses to stub a sibling.
lab="$TMP/fleets-lab"
mkdir -p "$lab"
cp "$BIN/ac-fleets.sh" "$BIN/ac-lib.sh" "$BIN/ac-wake-lib.sh" "$BIN/ac-harness.sh" "$lab/"
roomcalls="$TMP/room-calls"
: >"$roomcalls"
cat >"$lab/ac-room.sh" <<STUB
#!/usr/bin/env bash
printf '.' >>"$roomcalls"
STUB
chmod +x "$lab/ac-room.sh"
"$lab/ac-fleets.sh" --paths "$container" >/dev/null || fail "ac-fleets.sh --paths must exit 0 (lab copy)"
assert_eq "$(wc -c <"$roomcalls" | tr -d ' ')" "0" \
  "--paths never shells out to ac-room.sh - the inbox tally is skipped entirely, not just discarded"
# --json, unchanged, still calls it (alpha + gamma) - proving the lab harness
# itself is sound, not merely silent.
: >"$roomcalls"
"$lab/ac-fleets.sh" --json "$container" >/dev/null || fail "ac-fleets.sh --json must exit 0 (lab copy)"
[ "$(wc -c <"$roomcalls" | tr -d ' ')" -gt 0 ] || fail "sanity: --json must still call ac-room.sh (lab harness check)"

# -- wakes: a WHOLE-HOME tally across every scope's spool -------------------------
# A home's queued wakes live in per-scope spools, so the survey sums the
# fleet's and every valid family's. Drain claim dirs are not wake stores and
# must not inflate the count.
mkdir -p "$alpha/state/.wake-spool" "$alpha/state/.wake-spool.fam1" \
  "$alpha/state/.wake-spool.fam2" "$alpha/state/.wake-spool-draining.4242"
printf 'a\n' >"$alpha/state/.wake-spool/1.1.000000"
printf 'b\n' >"$alpha/state/.wake-spool/1.1.000001"
printf 'c\n' >"$alpha/state/.wake-spool/1.1.000002"
printf 'd\n' >"$alpha/state/.wake-spool.fam1/1.1.000000"
printf 'e\n' >"$alpha/state/.wake-spool.fam1/1.1.000001"
printf 'f\n' >"$alpha/state/.wake-spool.fam2/1.1.000000"
printf 'r\n' >"$alpha/state/.wake-spool-draining.4242/1.1.000000"
out2="$(fleets "$container")"
assert_contains "$out2" "6 queued" \
  "wakes tally sums fleet + families, excluding the drain claim dir"

# ... and the tally stays STRICTLY read-only: only the pure globs, no mkdir,
# no drain, nothing created or consumed.
assert_file "$alpha/state/.wake-spool.fam1/1.1.000000" "the survey never claims a spool record"
assert_file "$alpha/state/.wake-spool-draining.4242/1.1.000000" "the survey never touches a drain claim dir"
rm -rf "$alpha/state"/.wake-spool*
mkdir -p "$alpha/state/.wake-spool"
printf 'a\n' >"$alpha/state/.wake-spool/1.1.000000"
printf 'b\n' >"$alpha/state/.wake-spool/1.1.000001"
printf 'c\n' >"$alpha/state/.wake-spool/1.1.000002"

# -- beta: empty-but-valid block, no error ---------------------------------------
assert_contains "$out" "beta" "lists the partial beta home"
# beta has no crew -> the crew_count==0 render, no beacon, no lock
case "$out" in *"beta"*) : ;; *) fail "beta block missing" ;; esac
assert_contains "$out" "none in flight" "a home with no crew renders the none-in-flight line"

# -- notahome: skipped silently --------------------------------------------------
case "$out" in *notahome*) fail "non-home dir must be skipped" ;; *) : ;; esac

# -- watcher staleness honors AC_GUARD_GRACE -------------------------------------
# Assert BEACONED-home-specific strings ("(beat ...)"), so the flip is proven on
# alpha itself - the no-beacon homes (beta/gamma) always say "down (no beacon)"
# and would satisfy a bare "down" match no matter how the grace check behaves.
printf '%s\n' "$(( $(date +%s) - 500 ))" >"$alpha/state/.last-watcher-beat"
out2="$(fleets "$container")"
assert_contains "$out2" "down (beat" "stale beacon beyond grace = down, on the beaconed home"
out3="$(AC_GUARD_GRACE=100000 fleets "$container")"
assert_contains "$out3" "armed (beat" "large grace keeps the beaconed home armed"

# A beacon FILE holding 0 - what stand_down_beacon writes on every watcher exit
# - is down like any stale one, but carries no computable age: the same
# convention the drain renders, never the epoch-sized `now - 0`.
printf '0\n' >"$alpha/state/.last-watcher-beat"
outz="$(fleets "$container")"
assert_contains "$outz" "down (no beat on record" "a zero beat renders no computable age"
case "$outz" in *"down (beat "*) fail "no age may be computed from a zero beat: $outz" ;; esac
assert_eq "$(jq -r '.homes[] | select(.name=="alpha") | .watcher.age' <<<"$(fleets --json "$container")")" \
  "null" "--json carries a null age when no beat is on record"

date +%s >"$alpha/state/.last-watcher-beat"   # restore fresh

# -- session lock staleness (dead pid) -------------------------------------------
printf 'pid=%s\nsince=%s\n' "999999" "$(iso)" >"$alpha/state/.session-lock"
out4="$(fleets "$container")"
assert_contains "$out4" "stale pid=999999" "dead-pid lock shows stale"
printf 'pid=%s\nsince=%s\n' "$$" "$(iso)" >"$alpha/state/.session-lock"

# -- container resolution: default = parent of AC_HOME ---------------------------
out5="$(AC_HOME="$alpha" "$BIN/ac-fleets.sh")"
assert_contains "$out5" "alpha" "no-arg run resolves container from AC_HOME parent"
assert_contains "$out5" "beta" "no-arg run scans the whole container"

# -- container resolution: AC_HOMES_CONTAINER env override -----------------------
out6="$(AC_HOMES_CONTAINER="$container" AC_HOME="$TMP/home" "$BIN/ac-fleets.sh")"
assert_contains "$out6" "alpha" "AC_HOMES_CONTAINER selects the container"

# -- container resolution: arg beats env -----------------------------------------
mkdir -p "$TMP/c2"
out7="$(AC_HOMES_CONTAINER="$container" "$BIN/ac-fleets.sh" "$TMP/c2")"
assert_contains "$out7" "no fleet homes" "arg (empty c2) wins over env"
case "$out7" in *alpha*) fail "arg must override env container" ;; *) : ;; esac

# -- graceful: missing container -------------------------------------------------
out8="$("$BIN/ac-fleets.sh" "$TMP/does-not-exist")" || fail "missing container exits 0"
assert_contains "$out8" "not found" "missing container prints a notice"

# -- graceful: a regular FILE passed as the container ----------------------------
printf 'x\n' >"$TMP/afile"
out_file="$("$BIN/ac-fleets.sh" "$TMP/afile")" || fail "file-as-container must exit 0"
assert_contains "$out_file" "not found" "a regular file as container degrades gracefully"

# -- graceful: existing but empty container --------------------------------------
out9="$("$BIN/ac-fleets.sh" "$TMP/c2")" || fail "empty container exits 0"
assert_contains "$out9" "no fleet homes" "empty container notice"

# -- combined room: PENDING-CAPTAIN(n)+HANDBACK counts under BOTH tallies ---------
# ac-room.sh no longer masks HANDBACK behind a pending gate: a room both
# gate-pending AND in HANDBACK emits ONE combined line. This consumer must tally
# it under pending AND handback - else the hand-back is dropped from the
# cross-fleet inbox, the exact rot the fix forbids, one level up.
combodir="$TMP/combo-container/delta"
mkdir -p "$combodir/data/both"
printf '# Room: both\n\n- [%s] crewchief> GATE: awaiting captain\n- [%s] both-chief> HANDBACK: landed, please close\n' \
  "$(iso)" "$(iso)" >"$combodir/data/both/room.md"
out_combo="$(fleets "$TMP/combo-container")"
assert_contains "$out_combo" "1 pending, 1 handback" "combined room tallies under BOTH pending and handback"
assert_contains "$out_combo" "PENDING-CAPTAIN(1)+HANDBACK" "combined room line surfaces both tokens"

# A pending-ONLY room whose trailing entry text merely mentions HANDBACK must
# NOT be mis-tallied under handback: the consumer keys on the status TOKEN, not
# the whole line (which carries the last entry text after the family + a tab).
fpdir="$TMP/fp-container/epsilon"
mkdir -p "$fpdir/data/gateonly"
printf '# Room: gateonly\n\n- [%s] crewchief> GATE: approve the spec?\n- [%s] crewchief> note: no HANDBACK posted yet, still awaiting\n' \
  "$(iso)" "$(iso)" >"$fpdir/data/gateonly/room.md"
out_fp="$(fleets "$TMP/fp-container")"
assert_contains "$out_fp" "1 pending, 0 handback" "pending-only room with HANDBACK in tail text is NOT tallied as handback"

# -- the VERIFICATION-agent class: surveyed apart from crew -----------------------
# A verification pane agent (ship reviewer, gate judge, qa) writes a
# state/<id>.meta so the watcher can supervise it, but it is NOT crew - it holds
# no backlog row. Its short-lived exact-ref lease and caller linkage must be
# visible in its OWN top-level verify[]
# array (interface 2.i), never in crew.tasks[] and never in crew.count.
# The watcher line renders a LIVE age ("beat 3s ago"), which moves between two
# renders no matter what the metas do - normalise exactly that one field out, so
# the byte-identity claim below is about the class and not about the clock.
strip_beat() { sed 's/beat [0-9]*s/beat Ns/g'; }
text_before="$(fleets "$container" | strip_beat)"
printf 'kind=verify-codereview\nproject=agent-crew\nbackend=herdr\ncaller=flow-implement\nfamily=flow\nref=abcdef1234567890\nworktree=/tmp/verify-tree\nleases=/tmp/verify-tree\n' >"$alpha/state/ac-fleets-review.meta"
printf '%s reviewing the diff\n' "$(iso)" >"$alpha/state/ac-fleets-review.status"

vjson="$(fleets --json "$container")"
printf '%s' "$vjson" | jq -e . >/dev/null 2>&1 || fail "--json must stay valid JSON with a verifier present"
vaj="$(jq -c '.homes[] | select(.name=="alpha")' <<<"$vjson")"
assert_eq "$(jq -r '.crew.count' <<<"$vaj")" "2" "a verifier is NOT counted in crew.count"
assert_eq "$(jq -r '.crew.tasks | map(.id) | index("ac-fleets-review")' <<<"$vaj")" "null" \
  "a verifier is never in crew.tasks[]"
assert_eq "$(jq -r '.verify | length' <<<"$vaj")" "1" "the verifier lands in the top-level verify[] array"
assert_eq "$(jq -r '.verify[0].id' <<<"$vaj")" "ac-fleets-review" "--json verify id"
assert_eq "$(jq -r '.verify[0].kind' <<<"$vaj")" "verify-codereview" "--json verify kind"
assert_eq "$(jq -r '.verify[0].project' <<<"$vaj")" "agent-crew" "--json verify project"
assert_eq "$(jq -r '.verify[0].status' <<<"$vaj")" "reviewing the diff" "--json verify last status"
assert_eq "$(jq -r '.verify[0].caller' <<<"$vaj")" "flow-implement" "--json verify caller"
assert_eq "$(jq -r '.verify[0].family' <<<"$vaj")" "flow" "--json verify family"
assert_eq "$(jq -r '.verify[0].ref' <<<"$vaj")" "abcdef1234567890" "--json verify exact ref"
assert_eq "$(jq -r '.verify[0].worktree' <<<"$vaj")" "/tmp/verify-tree" "--json verify lease path"
# every home carries the key, so a consumer never has to guard on its absence
assert_eq "$(jq -r '.homes[] | select(.name=="beta") | .verify | length' <<<"$vjson")" "0" \
  "a home with no verifier still carries an empty verify[]"
# totals stay the CREW tally: a verifier must not inflate the cross-fleet number
assert_eq "$(jq -r '.totals.crew' <<<"$vjson")" "2" "--json totals.crew excludes verifiers"
# the human view labels it distinctly rather than folding it into the crew rows
text_with="$(fleets "$container")"
assert_contains "$text_with" "verify  : 1 in flight" "the human view labels verification agents distinctly"
assert_contains "$text_with" "ac-fleets-review" "the verifier row is rendered"
assert_contains "$text_with" "caller=flow-implement" "the human verifier row names its caller"
assert_contains "$text_with" "crew    : 2 in flight" "the crew line still counts only crew"

# ... and the block leaves NO residue: with the verifier gone the render is
# byte-identical to the one taken before it existed. (The stronger claim - that
# a zero-verifier render matches the PRE-CLASS script - is what the other 66
# suite files prove, since every one of them renders with no verify meta on disk.)
rm -f "$alpha/state/ac-fleets-review.meta" "$alpha/state/ac-fleets-review.status"
assert_eq "$(fleets "$container" | strip_beat)" "$text_before" \
  "a removed verifier leaves the text render byte-identical"

# -- Item 3 (perf audit): homes_json assembly is one `jq -s`, not N re-parses ----
# The old shape (`jq -c '. + [$h]' <<<"$homes_json"` inside the per-home loop)
# forked jq ONCE PER HOME just for the accumulator, on top of re-parsing the
# whole (growing) array every time - O(n^2) forks+parse on the path every
# dashboard request walks. The fix collects one NDJSON line per home and
# slurps them with a single `jq -s` after the loop: N accumulator forks -> 1.
zc="$TMP/zeta-container"
for h in zeta1 zeta2 zeta3 zeta4 zeta5; do
  mkdir -p "$zc/$h/state" "$zc/$h/config"
  printf 'TN\n' >"$zc/$h/config/captain"
done
jqcount="$TMP/jq-calls"
mkdir -p "$TMP/jqstub"
realjq="$(command -v jq)"
cat >"$TMP/jqstub/jq" <<STUB
#!/usr/bin/env bash
printf '.' >>"$jqcount"
exec "$realjq" "\$@"
STUB
chmod +x "$TMP/jqstub/jq"
: >"$jqcount"
tmp_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ac-fleets-*' 2>/dev/null | wc -l | tr -d ' ')"
zjson="$(PATH="$TMP/jqstub:$PATH" fleets --json "$zc")" || fail "zeta-container --json must exit 0"
assert_eq "$(jq -r '.homes | length' <<<"$zjson")" "5" "--json still lists all 5 homes after batching"
zcalls="$(wc -c <"$jqcount" | tr -d ' ')"
# Upper bound, not an exact pin: emit_home itself forks jq ONCE per home
# regardless of this fix (its own `jq -n` object build), so the total
# legitimately scales with home count - 5 (emit_home) + 1 final `jq -s` +
# 1 totals + 1 final render = 8 for 5 homes. What must NOT happen is an
# EXTRA per-home fork for the accumulator on top of that: the pre-fix shape
# measures 12 for the same 5 homes (5 more, one per home).
[ "$zcalls" -le 9 ] || fail "homes_json assembly forks jq more than the batched shape allows: $zcalls calls for 5 homes (want <=9)"

# and no leaked temp files: every mktemp'd ndjson file is cleaned up (compare
# against the pre-run count, not an absolute zero - debris from an unrelated
# prior run must not make this flaky).
tmp_after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ac-fleets-*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$tmp_after" "$tmp_before" "no ac-fleets-*.XXXXXX temp files survive a --json run"

pass
