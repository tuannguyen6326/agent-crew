#!/usr/bin/env bash
# ac-fleets.test.sh - READ-ONLY cross-fleet overview (ac-fleets.sh):
# per-home crew/inbox/watcher/wakes/lock blocks (incl. the none-in-flight
# render and a receipts-only room counting as 0 pending), crewdeputy nesting,
# non-home skipping, container resolution (arg > env > AC_HOME parent),
# graceful degrade (empty/partial/missing container, and a regular FILE passed
# as the container), and a fixture-container + AC_HOME proof that a run creates
# or modifies NOTHING.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
# A home with rooms but no state/: its inbox read goes through ac-room.sh
# list, which must create nothing either.
c2="$TMP/container-rooms-no-state"
mkdir -p "$c2/delta/config" "$c2/delta/data/dfam"
printf 'TN\n' >"$c2/delta/config/captain"
printf '# Room: dfam\n\n- [%s] crewchief> GATE: a question?\n' "$(iso)" >"$c2/delta/data/dfam/room.md"
before2="$(snapshot "$c2")"
out_d="$(fleets "$c2")" || fail "ac-fleets.sh must exit 0 on a home with rooms but no state/"
[ "$before2" = "$(snapshot "$c2")" ] || fail "run MUTATED a home with rooms but no state/: $(diff <(printf '%s\n' "$before2") <(snapshot "$c2") | head -5)"
assert_contains "$out_d" "1 pending" "a home with rooms but no state/ still reads its inbox"

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
# with - captain ruling); a meta without one carries null.
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

# -- --paths: the CHEAP source for allowedHomePaths (dashboard/app.ts)--------------
# dashboard/app.ts's allowedHomePaths() reads ONLY h.path/h.crewdeputies from
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
# downstream. A copied lab bin/ is the bin/ the module calls its siblings
# from (src/fleets.ts resolves ac-room.sh beside the bin/ it was started
# from), the same technique tests/sh/ac-watch-autoarm.test.sh uses to stub a
# sibling; the shim needs ac-bun.sh beside it and src/ linked beside the bin/
# (the make_oracle_bin shape), since bin/ac-bun.sh starts <bin>/../src/<module>.
lab="$TMP/fleets-lab"
mkdir -p "$lab/bin"
cp "$BIN/ac-fleets.sh" "$BIN/ac-bun.sh" "$BIN/ac-lib.sh" "$BIN/ac-wake-lib.sh" "$BIN/ac-harness.sh" "$lab/bin/"
ln -s "$ROOT/src" "$lab/src"
roomcalls="$TMP/room-calls"
: >"$roomcalls"
cat >"$lab/bin/ac-room.sh" <<STUB
#!/usr/bin/env bash
printf '.' >>"$roomcalls"
STUB
chmod +x "$lab/bin/ac-room.sh"
"$lab/bin/ac-fleets.sh" --paths "$container" >/dev/null || fail "ac-fleets.sh --paths must exit 0 (lab copy)"
assert_eq "$(wc -c <"$roomcalls" | tr -d ' ')" "0" \
  "--paths never shells out to ac-room.sh - the inbox tally is skipped entirely, not just discarded"
# --json, unchanged, still calls it (alpha + gamma) - proving the lab harness
# itself is sound, not merely silent.
: >"$roomcalls"
"$lab/bin/ac-fleets.sh" --json "$container" >/dev/null || fail "ac-fleets.sh --json must exit 0 (lab copy)"
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

# A zero-padded beat is unreadable (bash arithmetic reads 0009 as octal and
# dies on it), never an age - and never drops the home from the survey.
printf '0009\n' >"$alpha/state/.last-watcher-beat"
outp="$(fleets "$container")" || fail "a zero-padded beat must not fail the survey"
assert_contains "$outp" "down (no beat on record" "a zero-padded beat renders no computable age"
assert_eq "$(jq -r '.homes[] | select(.name=="alpha") | .watcher.age' <<<"$(fleets --json "$container")")" \
  "null" "--json keeps the home, with a null age, on a zero-padded beat"

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

# -- the SELF-TASK class: listed, but owing no watcher coverage ------------------
# AGENTS.md section 7: "A `kind=self` meta is excluded from
# supervision but stays in accounting - every fleet view lists it". Both halves bind at once, so a home
# whose in-flight set is entirely self tasks LISTS them and still reads as a
# home with no supervision gap - the down-watcher line keeps its benign
# qualifier and the cross-fleet alarm stays 0.
sc="$TMP/self-container"
mkdir -p "$sc/selfhome/state" "$sc/selfhome/data" "$sc/selfhome/config"
printf 'TN\n' >"$sc/selfhome/config/captain"
printf 'kind=self\nproject=agent-crew\nmode=local-only\nwindow=w1\nbackend=herdr\n' >"$sc/selfhome/state/slice-one.meta"
printf '%s editing\n' "$(iso)" >"$sc/selfhome/state/slice-one.status"
printf 'kind=self\nproject=agent-crew\nmode=local-only\nwindow=w2\nbackend=herdr\n' >"$sc/selfhome/state/slice-two.meta"

out_self="$(fleets "$sc")"
assert_contains "$out_self" "crew    : 2 in flight" "a self task stays in ACCOUNTING (crew count lists it)"
assert_contains "$out_self" "slice-one" "the self task row is rendered"
assert_contains "$out_self" "no supervised crew in flight (2 self task(s) owe none)"   "a home whose in-flight set is all self tasks owes no watcher coverage"
sj="$(fleets --json "$sc")"
assert_eq "$(jq -r '.homes[] | select(.name=="selfhome") | .crew.count' <<<"$sj")" "2"   "--json crew.count still counts the rows it lists"
assert_eq "$(jq -r '.homes[] | select(.name=="selfhome") | .crew.supervised' <<<"$sj")" "0"   "--json crew.supervised excludes self metas"
assert_eq "$(jq -r '.totals.watchers_down' <<<"$sj")" "0"   "--json watchers_down does not alarm on a self-only home"

# the control, so the qualifier is not simply always on: one real crewmate
# beside the self tasks and the same down watcher IS a coverage gap.
printf 'kind=ship\nproject=agent-crew\nbackend=herdr\n' >"$sc/selfhome/state/real-crew.meta"
out_mixed="$(fleets "$sc")"
case "$out_mixed" in *"crew in flight ("*|*"no crew in flight"*) fail "a real crewmate beside self tasks must not read as benign" ;; esac
mj="$(fleets --json "$sc")"
assert_eq "$(jq -r '.homes[] | select(.name=="selfhome") | .crew.supervised' <<<"$mj")" "1"   "--json crew.supervised counts the real crewmate"
assert_eq "$(jq -r '.totals.watchers_down' <<<"$mj")" "1"   "--json watchers_down alarms once a supervised task is in flight"

# An unreadable room fails `ac-room.sh list` - no answer, so the inbox reads
# UNKNOWN, never "clear", in text and in --json (inbox.unreadable). Skipped
# under root, which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  c3="$TMP/container-unreadable"
  mkdir -p "$c3/eps/config" "$c3/eps/data/efam"
  printf '# Room: efam\n\n- [%s] crewchief> GATE: a question?\n' "$(iso)" >"$c3/eps/data/efam/room.md"
  chmod 000 "$c3/eps/data/efam/room.md"
  rc=0; out_u="$(fleets "$c3")" || rc=$?
  uj="$(fleets --json "$c3")" || rc=$?
  chmod 644 "$c3/eps/data/efam/room.md"
  assert_eq "$rc" "0" "an unreadable room set still renders the survey"
  assert_contains "$out_u" "inbox   : UNKNOWN" "an unreadable room set reads UNKNOWN"
  case "$out_u" in *"inbox   : clear"*) fail "an unreadable room set must never read clear: $out_u" ;; esac
  assert_eq "$(jq -r '.homes[] | select(.name=="eps") | .inbox.unreadable' <<<"$uj")" "true" "--json flags the unreadable inbox"
  assert_eq "$(jq -r '.homes[] | select(.name=="eps") | .inbox.unreadable' <<<"$(fleets --json "$c3")")" "false" "...and only while it is unreadable"
fi

# --- differential: src/fleets.ts against the frozen bash original -------------
# DISPUTED: the implementation (tests/fixtures/ac-fleets.sh under bash vs src/fleets.ts through bin/ac-fleets.sh)
# HELD-CONSTANT: the fixture containers on disk (both sides read them and run the same live ac-room.sh), argv, cwd, AC_HOME, AC_HOMES_CONTAINER, HOME, AC_GUARD_GRACE, the locale; stdout, stderr and exit status compared whole after ONE normalisation - generated_at and the clock-dependent beat age (`beat <n>s`, `"age": <n>`), nothing else
# LC_ALL=C on both sides: the port lists dirs and metas in byte order, and
# under a UTF-8 locale bash 3.2's glob follows libc collation instead (the
# named divergence; no JS collator reproduces it). The two rows that pin
# CHARACTER counting (status truncation, `${ref:0:12}`) run both sides under
# en_US.UTF-8 with ASCII home names, where the two orders agree.
export LC_ALL=C
obin="$(make_oracle_bin ac-fleets)"
norm() { LC_ALL=C sed -e 's/"generated_at": "[^"]*"/"generated_at": "T"/' -e 's/beat [0-9]*s/beat Ns/g' -e 's/"age": -\{0,1\}[0-9][0-9]*/"age": N/'; }
same() {  # same <args...> - the oracle and the shim answer byte-identically
  local o_rc=0 n_rc=0
  "$obin/ac-fleets.sh" "$@" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  "$BIN/ac-fleets.sh" "$@" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  norm <"$TMP/o.raw" >"$TMP/o.out"
  norm <"$TMP/n.raw" >"$TMP/n.out"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
  cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
}
nout() { cat "$TMP/n.raw"; }

# 1-3: the test's own fixture (alpha/beta/gamma/notahome) in every mode, with
# the cadence/config pins re-seeded for --json; alpha's fresh beacon is the
# clock-dependent field the normalisation covers.
printf 'debriefs=6\nlast_run=1700000000\n' >"$alpha/state/.learn.meta"
printf 'runs_since=5\n' >"$alpha/state/.curate.meta"
printf '8\n' >"$alpha/config/learn-every"
printf 'direct\n' >"$alpha/config/flow"
# The beacon is re-struck here: the legs above took real seconds, and a beat
# older than the grace flips alpha's watcher between the two runs.
date +%s >"$alpha/state/.last-watcher-beat"
same "$container"
assert_contains "$(nout)" "⚓ alpha   captain: TN" "the anchor line, byte for byte"
same --json "$container"
same --paths "$container"

# 4-5: the three not-found shapes for a missing dir and a regular file, and
# an existing empty container.
for c in "$TMP/does-not-exist" "$TMP/afile"; do
  same "$c"; same --json "$c"; same --paths "$c"
done
same "$TMP/c2"; same --json "$TMP/c2"; same --paths "$TMP/c2"
assert_eq "$(nout | jq -c '.homes')" "[]" "--paths on an empty container"

# 6: glob order. Both sides run under LC_ALL=C and agree on byte order; under
# en_US.UTF-8 the original's glob would interleave case and ignore punctuation
# (libc collation) - the one named ordering divergence of the port.
c6="$TMP/c6"
for h in Zeta ac-fleets ac_fleets ac.fleets AC a10 a2 2025 ä; do mkdir -p "$c6/$h/config"; done
same "$c6"; same --json "$c6"; same --paths "$c6"
assert_eq "$(nout | jq -r '[.homes[].path | sub(".*/"; "")] | join(" ")')" "2025 AC Zeta a10 a2 ac-fleets ac.fleets ac_fleets ä" "homes are listed in BYTE order"

# 7: meta edges, under the operators' UTF-8 locale - the `%-Ns` columns pad by
# BYTES (bash's printf) while `${#status} -gt 100` / `${status:0:97}` count
# CHARACTERS; an empty kind, mode=-, a repeated key (last wins), a value
# holding `=`, a status line with no space, a trailing blank status line, an
# id overflowing its column, a hidden meta.
c7="$TMP/c7"; mkdir -p "$c7/edge/state"
u110="$(printf 'ü%.0s' $(seq 1 110))"; u96="$(printf 'ü%.0s' $(seq 1 96))"
printf 'kind=\nmode=-\nproject=p1\nproject=a=b\n' >"$c7/edge/state/e1.meta"
printf '2026 A%sZ\n' "$u110" >"$c7/edge/state/e1.status"
printf 'kind=ship\n' >"$c7/edge/state/e2.meta"
printf 'nospace\n' >"$c7/edge/state/e2.status"
printf 'kind=ship\nproject=x\n' >"$c7/edge/state/e3.meta"
printf '2026 running\n\n' >"$c7/edge/state/e3.status"
printf 'kind=ship\nproject=héllo\nmode=local-only\n' >"$c7/edge/state/crêpe.meta"
printf '2026 running\n' >"$c7/edge/state/crêpe.status"
printf 'kind=scout\n' >"$c7/edge/state/averyveryverylongid00.meta"
printf 'kind=ship\n' >"$c7/edge/state/.hidden.meta"
LC_ALL=en_US.UTF-8 same "$c7"
assert_contains "$(nout)" "A${u96}..." "a status over 100 CHARACTERS keeps its first 97 characters, then ..."
case "$(nout)" in *"A${u96}ü"*) fail "the truncation must count characters, not bytes" ;; esac
assert_contains "$(nout)" "     crêpe           ship   héllo         running" "columns pad by BYTES: a 6-byte id gets 10 spaces, a 6-byte project 8"
assert_contains "$(nout)" "     averyveryverylongid00 scout  -              -" "an id past 16 bytes overflows its column"
assert_contains "$(nout)" "     e2               ship   -              nospace" "a status line with no space passes whole"
assert_contains "$(nout)" "     e3               ship   x$(printf '%14s' '')
" "an empty last status line reads as an empty status (13 pad bytes, the separator, nothing)"
case "$(nout)" in *hidden*) fail "a dot meta is never listed" ;; esac
LC_ALL=en_US.UTF-8 same --json "$c7"
assert_eq "$(nout | jq -r '.homes[0].crew.tasks[] | select(.id=="e1") | [.kind, .mode, .project] | @tsv')" "$(printf '\t\ta=b')" "kind= is null, mode=- is null, the LAST project= wins with its ="

# 8: the verification class, with a 40-hex ref and a multibyte one - `${ref:0:12}`
# counts characters.
c8="$TMP/c8"; mkdir -p "$c8/vh/state"
printf 'kind=verify-codereview\nproject=agent-crew\ncaller=flow-implement\nfamily=flow\nref=0123456789abcdef0123456789abcdef01234567\nworktree=/tmp/vt\n' >"$c8/vh/state/v1.meta"
printf '2026 reviewing the diff\n' >"$c8/vh/state/v1.status"
e20="$(printf 'é%.0s' $(seq 1 20))"; e12="$(printf 'é%.0s' $(seq 1 12))"
printf 'kind=verify-qa\nref=%s\n' "$e20" >"$c8/vh/state/v2.meta"
printf 'kind=ship\n' >"$c8/vh/state/c1.meta"
LC_ALL=en_US.UTF-8 same "$c8"
assert_contains "$(nout)" "caller=flow-implement family=flow ref=0123456789ab" "the ref is cut to 12"
assert_contains "$(nout)" "caller=- family=- ref=${e12}" "...12 CHARACTERS, with - for an absent caller/family"
case "$(nout)" in *"ref=${e12}é"*) fail "the ref cut must count characters" ;; esac
LC_ALL=en_US.UTF-8 same --json "$c8"
assert_eq "$(nout | jq -r '.homes[0] | [.crew.count, (.verify | length), (.verify[1].caller | tostring)] | @tsv')" "$(printf '1\t2\tnull')" "verifiers sit in verify[], not crew"

# 9: self-only and mixed homes (the watcher qualifier and totals.watchers_down).
c9="$TMP/c9"; mkdir -p "$c9/selfonly/state"
printf 'kind=self\n' >"$c9/selfonly/state/s1.meta"; printf 'kind=self\n' >"$c9/selfonly/state/s2.meta"
same "$c9"; same --json "$c9"
same "$sc"; same --json "$sc"

# 10: beacon states, each with and without an owner (one padded with
# whitespace); a home with crew so the qualifier stays off, and one without.
c10="$TMP/c10"; mkdir -p "$c10/w/state" "$c10/q/config"
printf 'kind=ship\n' >"$c10/w/state/t.meta"
nowb="$(date +%s)"
for owner in none "4242
" "  77
"; do
  rm -f "$c10/w/state/.watcher-owner"
  [ "$owner" = none ] || printf '%s' "$owner" >"$c10/w/state/.watcher-owner"
  for beacon in absent "0
" "0009
" "12
34
" "$((nowb - 500))
" "$nowb
"; do
    rm -f "$c10/w/state/.last-watcher-beat"
    [ "$beacon" = absent ] || printf '%s' "$beacon" >"$c10/w/state/.last-watcher-beat"
    same "$c10"; same --json "$c10"
  done
done
assert_contains "$(nout | jq -r '.homes[] | select(.path | endswith("/w")) | .watcher.detail')" "armed (beat " "the last beacon is fresh"
assert_eq "$(nout | jq -r '.homes[] | select(.path | endswith("/w")) | .watcher.owner')" "77" "the owner file is read with every [:space:] deleted"

# 11: the session lock: absent, held by this shell, a dead pid, no pid at all,
# a `+1` that ps accepts.
c11="$TMP/c11"; mkdir -p "$c11/l/state"
for lock in absent "pid=$$
since=2026-01-01T00:00:00Z
" "pid=999999
since=2026-01-01T00:00:00Z
" "since=x
" "pid=+1
"; do
  rm -f "$c11/l/state/.session-lock"
  [ "$lock" = absent ] || printf '%s' "$lock" >"$c11/l/state/.session-lock"
  same "$c11"; same --json "$c11"
done
assert_eq "$(nout | jq -r '.homes[0].lock.detail')" "held pid=+1 since=?" "ps -p accepts +1, so the lock reads held"

# 12: wakes across the fleet spool and the family spools; a dotted family
# name, a drain claim dir and a dotfile inside a spool are never counted.
c12="$TMP/c12"; mkdir -p "$c12/wk/state/.wake-spool" "$c12/wk/state/.wake-spool.fam1" "$c12/wk/state/.wake-spool.bad.name" "$c12/wk/state/.wake-spool-draining.1"
for f in 1 2 3; do : >"$c12/wk/state/.wake-spool/1.1.00000$f"; done
: >"$c12/wk/state/.wake-spool.fam1/a"; : >"$c12/wk/state/.wake-spool.fam1/b"; : >"$c12/wk/state/.wake-spool.fam1/.dot"
: >"$c12/wk/state/.wake-spool.bad.name/x"; : >"$c12/wk/state/.wake-spool-draining.1/y"
same "$c12"; same --json "$c12"
assert_eq "$(nout | jq -r '.homes[0].wakes')" "5" "3 fleet + 2 family wakes; the rest excluded"

# 13: the inbox over every ac-room.sh list shape: PENDING-CAPTAIN(2), HANDBACK,
# the combined PENDING-CAPTAIN(1)+HANDBACK, a receipts-only room (hidden), a
# last entry carrying a TAB and HANDBACK prose, an entry with a quote - and a
# home whose data/ holds no room at all.
c13="$TMP/c13"; mkdir -p "$c13/ib/data/two" "$c13/ib/data/hb" "$c13/ib/data/both" "$c13/ib/data/rcpt" "$c13/ib/data/prose" "$c13/norooms/data"
printf '# Room: two\n\n- [2026-01-01T00:00:00Z] crewchief> GATE: one?\n- [2026-01-01T00:00:01Z] crewchief> ASK: two "quoted"?\n' >"$c13/ib/data/two/room.md"
printf '# Room: hb\n\n- [2026-01-01T00:00:00Z] hb-chief> HANDBACK: shipped\n' >"$c13/ib/data/hb/room.md"
printf '# Room: both\n\n- [2026-01-01T00:00:00Z] crewchief> GATE: awaiting\n- [2026-01-01T00:00:01Z] both-chief> HANDBACK: landed\n' >"$c13/ib/data/both/room.md"
printf '# Room: rcpt\n\n- [2026-01-01T00:00:00Z] crewchief> TRIAGE: flow=direct\n' >"$c13/ib/data/rcpt/room.md"
printf '# Room: prose\n\n- [2026-01-01T00:00:00Z] crewchief> GATE: q?\n- [2026-01-01T00:00:01Z] crewchief> note:\tno HANDBACK yet\n' >"$c13/ib/data/prose/room.md"
same "$c13"; same --json "$c13"
assert_eq "$(nout | jq -r '.homes[] | select(.path | endswith("/ib")) | [.inbox.pending, .inbox.handback, (.inbox.entries | length)] | @tsv')" "$(printf '4\t2\t4')" "pending 2+1+1, handback 1+1, four entries"
assert_eq "$(nout | jq -r '.homes[] | select(.path | endswith("/ib")) | .inbox.entries[] | select(.family=="both") | .status')" "PENDING-CAPTAIN(1)+HANDBACK" "the combined status token is the entry's status"

# 14: an unreadable room (skipped under root).
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$c3/eps/data/efam/room.md"
  same "$c3"; same --json "$c3"
  chmod 644 "$c3/eps/data/efam/room.md"
  assert_eq "$(nout | jq -r '.homes[0].inbox.unreadable, .totals.inbox_unreadable' | tr '\n' ' ')" "true 1 " "an unreadable room set is UNKNOWN on both sides"
fi

# 15: cadence and config edges: a non-numeric learn-every (default 8), a
# legacy stows counter, a non-numeric last_run (null), curate-every=0 (always
# due), config values wrapped in CR, BOM and tabs.
c15="$TMP/c15"; mkdir -p "$c15/cad/state" "$c15/cad/config"
printf 'abc\n' >"$c15/cad/config/learn-every"
printf 'stows=3\nlast_run=notanumber\n' >"$c15/cad/state/.learn.meta"
printf '0\n' >"$c15/cad/config/curate-every"
printf '\tdirect\r\n' >"$c15/cad/config/flow"
printf '\xef\xbb\xbfalways\n' >"$c15/cad/config/promote"
printf '  chief  \n' >"$c15/cad/config/remote-mirror"
same --json "$c15"
assert_eq "$(nout | jq -r '.homes[0] | [.cadence.learn.count, .cadence.learn.every, (.cadence.learn.last_run | tostring), .cadence.curate.every, .cadence.curate.due, .config.flow, .config.mirror] | @tsv')" "$(printf '3\t8\tnull\t0\ttrue\tdirect\tchief')" "cadence/config edges"
assert_eq "$(nout | jq -r '.homes[0].config.promote' | od -An -c | tr -d ' ')" '357273277always\n' "a BOM is not [:space:] - it stays"

# 16: crewdeputies three deep, a seven-deep chain, a crewdeputy child that is
# not a home, and an empty crewdeputies/ (no label line).
c16="$TMP/c16"
mkdir -p "$c16/three/config/" "$c16/three/crewdeputies/a/crewdeputies/b/crewdeputies/c/config" "$c16/three/crewdeputies/a/config" "$c16/three/crewdeputies/a/crewdeputies/b/config"
mkdir -p "$c16/deep/config"; p="$c16/deep"; for i in 1 2 3 4 5 6 7; do p="$p/crewdeputies/n$i"; mkdir -p "$p/config"; done
mkdir -p "$c16/nothome/config" "$c16/nothome/crewdeputies/junk"
mkdir -p "$c16/emptycd/config" "$c16/emptycd/crewdeputies"
same "$c16"
assert_eq "$(grep -c 'crewdeputies:' "$TMP/n.out")" "10" "the label prints once per home with a home child, the depth-6 one included"
assert_eq "$(grep -c '⚓' "$TMP/n.out")" "13" "the depth-7 home prints nothing"
same --paths "$c16"
assert_eq "$(nout | jq '[.. | objects | select(has("path"))] | length')" "14" "--paths has no depth cap"
# --json: the DEPTH POISON, a defect of the original reproduced on purpose -
# its command substitutions ran without errexit, so the depth-7 home's empty
# object failed every enclosing --argjson and the whole top-level home
# vanished from homes[] and totals, exit 0. The oracle's stderr is jq's own
# noise (not reproduced); exit and stdout are compared, stderr named.
o_rc=0; "$obin/ac-fleets.sh" --json "$c16" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; "$BIN/ac-fleets.sh" --json "$c16" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
norm <"$TMP/o.raw" >"$TMP/o.out"; norm <"$TMP/n.raw" >"$TMP/n.out"
assert_eq "$n_rc $o_rc" "0 0" "depth poison: both exit 0"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "depth poison: stdout differs: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
assert_eq "$(nout | jq -r '([.homes[].name] | join(" ")), .totals.homes' | tr '\n' ' ')" "emptycd nothome three 6 " "the seven-deep top-level home vanishes from homes[] and totals (defect slice: the original's errexit-less subshells)"
assert_contains "$(cat "$TMP/o.err")" "jq: invalid JSON text passed to --argjson" "...the original's stderr was jq's own"
assert_eq "$(cat "$TMP/n.err")" "" "...the port prints no tool-own stderr"

# 17: the container rungs with no argument: AC_HOMES_CONTAINER, AC_HOME's
# parent (a symlinked AC_HOME gives the link's parent), and HOME with and
# without Work/ac-homes.
AC_HOMES_CONTAINER="$container" same
AC_HOME="$container/alpha" same
mkdir -p "$TMP/h17/Work/ac-homes/x/config"
AC_HOME= HOME="$TMP/h17" same
assert_contains "$(nout)" "== fleet homes: $TMP/h17/Work/ac-homes ==" "the HOME rung"
AC_HOME= HOME="$TMP/h17b" same
assert_contains "$(nout)" "(fleet homes container not found: $TMP/h17b/Work/ac-homes)" "the HOME rung, missing"
mkdir -p "$TMP/c17"; ln -s "$container/alpha" "$TMP/c17/alphalink"
AC_HOME="$TMP/c17/alphalink" same
assert_contains "$(nout)" "== fleet homes: $TMP/c17 ==" "a symlinked AC_HOME resolves to the LINK's parent, as cd's logical walk does"

# 18: argument oddities: an unknown flag is the container, the first bare word
# wins, the last mode flag wins, and -h after a container still prints the
# header - the port's is the src/fleets.ts header (named divergence), so only
# exit and stderr are compared there.
same --bogus; same --json --bogus; same --paths --bogus
same "$container" "$TMP/c2"
same --json --paths "$container"
assert_eq "$(nout | jq -r 'has("totals")')" "false" "the last mode flag wins"
same --paths --json "$container"
assert_eq "$(nout | jq -r 'has("totals")')" "true" "...either way round"
o_rc=0; "$obin/ac-fleets.sh" "$container" -h >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; "$BIN/ac-fleets.sh" "$container" -h >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "0 0" "-h after a container: exit 0 on both sides"
assert_eq "$(cat "$TMP/o.err")$(cat "$TMP/n.err")" "" "-h: nothing on stderr"
assert_eq "$(head -n1 "$TMP/o.raw" | cut -c1-14)" "ac-fleets.sh -" "the original printed its own header"
assert_eq "$(nout)" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/fleets.ts" | sed 's|^// \{0,1\}||')" "the port prints the src/fleets.ts header, its spec"
n_rc=0; "$BIN/ac-fleets.sh" --help >"$TMP/n2.out" 2>&1 || n_rc=$?
assert_eq "$n_rc $(cmp -s "$TMP/n.raw" "$TMP/n2.out" && echo same)" "0 same" "--help is -h"

# 19: AC_GUARD_GRACE, huge and zero, against alpha's fresh beacon. Zero is
# only deterministic when the clock stands still: both sides read `date +%s`
# through a PATH stub frozen at the beacon's own second (one tick between the
# two runs would flip armed/down), the rest of date passes through.
mkdir -p "$TMP/clockstub"
printf '#!/bin/sh\ncase "$*" in "+%%s") echo 1700000000 ;; *) exec /bin/date "$@" ;; esac\n' >"$TMP/clockstub/date"; chmod +x "$TMP/clockstub/date"
printf '1700000000\n' >"$alpha/state/.last-watcher-beat"
export PATH="$TMP/clockstub:$PATH"
AC_GUARD_GRACE=100000 same "$container"; AC_GUARD_GRACE=100000 same --json "$container"
assert_eq "$(nout | jq -r '.grace, (.homes[] | select(.name=="alpha") | .watcher.state)' | tr '\n' ' ')" "100000 armed " "a huge grace keeps the beaconed home armed"
AC_GUARD_GRACE=0 same "$container"; AC_GUARD_GRACE=0 same --json "$container"
assert_contains "$(nout)" '"state": "armed"' "grace 0 with a beat this second: armed"
PATH="${PATH#"$TMP/clockstub:"}"; export PATH
date +%s >"$alpha/state/.last-watcher-beat"

# 20: jq's escaping through the ONE spawned `jq .`: DEL and a control byte as
# \u00XX, é and U+2028 raw, an invalid byte replaced by U+FFFD exactly as the
# original's --arg values were - jq 1.8.2 swallows the byte AFTER an invalid
# lead into that one U+FFFD (probed: `e\xe9f` prints `e` U+FFFD, no `f`), on
# both paths alike; a captain with a quote and a backslash.
c20="$TMP/c20"; mkdir -p "$c20/j/state" "$c20/j/config"
printf 'kind=ship\n' >"$c20/j/state/t.meta"
printf '2026 a\x7fb\x01c\xc3\xa9d\xe2\x80\xa8e\xe9f\n' >"$c20/j/state/t.status"
printf 'T"N\\x\n' >"$c20/j/config/captain"
same --json "$c20"; same "$c20"
same --json "$c20"
assert_contains "$(nout)" '"status": "a\u007fb\u0001cé'"$(printf 'd\xe2\x80\xa8e\xef\xbf\xbd')"'"' "jq's own escaping and U+FFFD replacement (the f after the bad byte goes with it)"
assert_contains "$(nout)" '"captain": "T\"N\\x"' "a quote and a backslash in a value"
# ...and the port forks jq exactly once per run (the <=9 leg above would also
# pass a port that never forked it at all).
: >"$jqcount"
PATH="$TMP/jqstub:$PATH" "$BIN/ac-fleets.sh" --json "$zc" >/dev/null || fail "jq-count run must exit 0"
assert_eq "$(wc -c <"$jqcount" | tr -d ' ')" "1" "--json forks jq exactly once"
: >"$jqcount"
PATH="$TMP/jqstub:$PATH" "$BIN/ac-fleets.sh" --paths "$zc" >/dev/null || fail "jq-count run must exit 0"
assert_eq "$(wc -c <"$jqcount" | tr -d ' ')" "1" "--paths forks jq exactly once"

# 21: a per-home read this user cannot make. TEXT: `set -e` ended the original
# on that assignment with exit 1 after the header, every earlier home and the
# blank line before the dying one - the port ends there too (an unreadable
# meta: the same WARN; an unreadable status or config: the tool's own stderr
# is not reproduced - named). --json: the read sat inside a command
# substitution, the value is "" and the survey goes on, exit 0, on both sides.
# Root reads everything, so unprivileged only.
if [ "$(id -u)" -ne 0 ]; then
  c21="$TMP/c21"; mkdir -p "$c21/a/state" "$c21/h/state" "$c21/h/config"
  printf 'kind=ship\n' >"$c21/h/state/t1.meta"; chmod 000 "$c21/h/state/t1.meta"
  o_rc=0; "$obin/ac-fleets.sh" "$c21" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; "$BIN/ac-fleets.sh" "$c21" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc $o_rc" "1 1" "unreadable meta, text: both end with exit 1"
  cmp -s "$TMP/o.raw" "$TMP/n.raw" || fail "unreadable meta, text: the partial stdout differs: $(diff "$TMP/o.raw" "$TMP/n.raw" | head -n 6)"
  assert_eq "$(nout | tail -n 2 | head -n 1)" "   lock    : free" "unreadable meta, text: the earlier home printed whole, then the blank line"
  assert_eq "$(cat "$TMP/n.err")" "$(cat "$TMP/o.err")" "unreadable meta, text: the same WARN, nothing else"
  same --json "$c21"
  assert_eq "$(nout | jq -r '.totals.homes, .homes[1].crew.tasks[0].kind')" "2
null" "unreadable meta, --json: the survey goes on, the kind reads empty"
  chmod 644 "$c21/h/state/t1.meta"
  printf 'x y\n' >"$c21/h/state/t1.status"; chmod 000 "$c21/h/state/t1.status"
  o_rc=0; "$obin/ac-fleets.sh" "$c21" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; "$BIN/ac-fleets.sh" "$c21" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc $o_rc" "1 1" "unreadable status, text: both end with exit 1"
  cmp -s "$TMP/o.raw" "$TMP/n.raw" || fail "unreadable status, text: the partial stdout differs"
  assert_eq "$(cat "$TMP/n.err")" "" "unreadable status, text: tail's own line is not reproduced (named)"
  o_rc=0; "$obin/ac-fleets.sh" --json "$c21" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; "$BIN/ac-fleets.sh" --json "$c21" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc $o_rc" "0 0" "unreadable status, --json: both go on"
  assert_eq "$(norm <"$TMP/n.raw")" "$(norm <"$TMP/o.raw")" "unreadable status, --json: the same document"
  assert_contains "$(cat "$TMP/o.err")" "Permission denied" "unreadable status, --json: tail's own line on the original"
  assert_eq "$(cat "$TMP/n.err")" "" "unreadable status, --json: not reproduced (named)"
  chmod 644 "$c21/h/state/t1.status"
  # config/captain is the one read the original guarded (`head ... 2>/dev/null
  # || true`): "" in both modes, exit 0, nothing on stderr
  printf 'TN\n' >"$c21/h/config/captain"; chmod 000 "$c21/h/config/captain"
  same "$c21"
  assert_eq "$(nout | /usr/bin/grep -c 'captain:')" "0" "unreadable captain, text: no captain, the survey goes on"
  same --json "$c21"
  assert_eq "$(nout | jq -r '.homes[1].captain')" "null" "unreadable captain, --json: reads empty, not the default"
  chmod 644 "$c21/h/config/captain"
  # a nested home dying: the parent's block and its crewdeputies label are out
  mkdir -p "$c21/h/crewdeputies/d/state"; printf 'kind=ship\n' >"$c21/h/crewdeputies/d/state/x.meta"; chmod 000 "$c21/h/crewdeputies/d/state/x.meta"
  o_rc=0; "$obin/ac-fleets.sh" "$c21" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; "$BIN/ac-fleets.sh" "$c21" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  chmod 644 "$c21/h/crewdeputies/d/state/x.meta"
  assert_eq "$n_rc $o_rc" "1 1" "unreadable nested meta, text: both end with exit 1"
  cmp -s "$TMP/o.raw" "$TMP/n.raw" || fail "unreadable nested meta, text: the partial stdout differs: $(diff "$TMP/o.raw" "$TMP/n.raw" | head -n 6)"
  assert_eq "$(nout | tail -n 1)" "   crewdeputies:" "unreadable nested meta, text: the parent printed through its label"
fi

# 22: a zero-padded cadence counter reads as its decimal value on both sides
# (jq takes `--argjson 007` as 7) - probed here, not assumed; and `due` compares
# the integers themselves, so 2^53 against 2^53+1 is not due
c22="$TMP/c22"; mkdir -p "$c22/h/state" "$c22/h/config"; printf 'debriefs=007\n' >"$c22/h/state/.learn.meta"
same --json "$c22"
assert_eq "$(jq -r '.totals.homes, .homes[0].cadence.learn.count' "$TMP/n.raw" | tr '\n' ' ')" "1 7 " "007: the home stays and the count reads 7"
printf 'debriefs=9007199254740992\n' >"$c22/h/state/.learn.meta"; printf '9007199254740993\n' >"$c22/h/config/learn-every"
printf 'runs_since=9007199254740992\n' >"$c22/h/state/.curate.meta"; printf '9007199254740993\n' >"$c22/h/config/curate-every"
same --json "$c22"
assert_eq "$(jq -r '.homes[0].cadence.learn.due, .homes[0].cadence.curate.due, .totals.learning_due' "$TMP/n.raw" | tr '\n' ' ')" "false false 0 " "2^53 is not due against 2^53+1"
# bash's signed 64-bit domain: 2^63-1 against 8 is due; 2^63 made `[` refuse
# (its own line on stderr - shell-own, not reproduced) and read false
printf 'debriefs=9223372036854775807\n' >"$c22/h/state/.learn.meta"; printf '8\n' >"$c22/h/config/learn-every"
printf 'runs_since=9223372036854775807\n' >"$c22/h/state/.curate.meta"; printf '8\n' >"$c22/h/config/curate-every"
same --json "$c22"
assert_eq "$(jq -r '.homes[0].cadence.learn.due, .homes[0].cadence.curate.due' "$TMP/n.raw" | tr '\n' ' ')" "true true " "2^63-1 is due against 8"
printf 'debriefs=9223372036854775808\n' >"$c22/h/state/.learn.meta"; printf 'runs_since=9223372036854775808\n' >"$c22/h/state/.curate.meta"
o_rc=0; "$obin/ac-fleets.sh" --json "$c22" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; "$BIN/ac-fleets.sh" --json "$c22" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "0 0" "2^63: both exit 0"
assert_eq "$(norm <"$TMP/n.raw")" "$(norm <"$TMP/o.raw")" "2^63: the same document"
assert_eq "$(jq -r '.homes[0].cadence.learn.due, .homes[0].cadence.curate.due, .totals.learning_due, .totals.curate_due' "$TMP/n.raw" | tr '\n' ' ')" "false false 0 0 " "2^63 is past bash's range: not due"
assert_contains "$(cat "$TMP/o.err")" "integer expression expected" "2^63: the original's [ refused (shell-own stderr)"

# 23: a meta value is awk's C string, cut at its first NUL: `kind=self<NUL>`
# is self (unsupervised, no coverage alarm), `kind=veri<NUL>fy-qa` is `veri`
c23="$TMP/c23"; mkdir -p "$c23/h/state"
printf 'kind=self\0\nproject=x\n' >"$c23/h/state/s.meta"
printf 'kind=veri\0fy-qa\n' >"$c23/h/state/v.meta"
same "$c23"; same --json "$c23"
assert_eq "$(nout | jq -r '.homes[0].crew.supervised, .totals.watchers_down, .homes[0].crew.tasks[1].kind')" "1
1
veri" "NUL-cut meta values: self is self, veri<NUL>fy-qa is veri and counts as crew"

# 24: the C locale: bash counts BYTES and [:space:] is ASCII there, so a status
# of 60 � (120 bytes) is cut at 97 bytes, a ref of 20 � at 12 bytes, and a
# non-breaking space around captain, flow and owner stays; the same inputs
# under en_US.UTF-8 count characters and trim the space (rows 7-8's reading)
c24="$TMP/c24"; mkdir -p "$c24/h/state" "$c24/h/config"
printf 'kind=ship\n' >"$c24/h/state/t.meta"; printf '2026 %s\n' "$(printf '\303\274%.0s' $(seq 1 60))" >"$c24/h/state/t.status"
printf 'kind=verify-qa\ncaller=c\nfamily=f\nref=%s\n' "$(printf '\303\251%.0s' $(seq 1 20))" >"$c24/h/state/v.meta"
printf '\302\240TN\302\240\n' >"$c24/h/config/captain"; printf '\302\240direct\302\240\n' >"$c24/h/config/flow"
printf '\302\24077\302\240\n' >"$c24/h/state/.watcher-owner"; date +%s >"$c24/h/state/.last-watcher-beat"
LC_ALL=C same "$c24"
assert_eq "$(nout | /usr/bin/grep -a -o 'ref=[^ ]*' | LC_ALL=C /usr/bin/sed 's/ref=//' | wc -c | awk '{print $1}')" "13" "C: the text ref column is cut at 12 bytes (6 e-acute)"
LC_ALL=C same --json "$c24"
assert_eq "$(nout | jq -r '.homes[0].captain, .homes[0].config.flow, .homes[0].watcher.owner')" "$(printf '\302\240TN\302\240\n\302\240direct\302\240\n\302\24077\302\240')" "C: the non-breaking spaces stay"
LC_ALL=en_US.UTF-8 same "$c24"
assert_contains "$(nout)" "captain: TN" "UTF-8: the non-breaking spaces are trimmed"
assert_eq "$(nout | /usr/bin/grep -a -o 'ref=[^ ]*' | /usr/bin/sed 's/ref=//' | wc -c | awk '{print $1}')" "25" "UTF-8: the text ref column is cut at 12 characters (12 e-acute)"
LC_ALL=en_US.UTF-8 same --json "$c24"

# 25: grace is one standalone `--argjson` value: a canonical integer is placed
# as is, `007` and `1e2` are what jq makes of them, and `300,"x":1` is jq's
# refusal (exit 2, its own stderr) - never spliced into the document
AC_GUARD_GRACE=007 same --json "$container"
# a grace `[ -le ]` cannot read made bash print its own `integer expression
# expected` line (shell-own stderr, not reproduced): exit and stdout compared
for g in 1e2 '300,"injected":true' abc; do
  o_rc=0; AC_GUARD_GRACE="$g" "$obin/ac-fleets.sh" --json "$container" >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; AC_GUARD_GRACE="$g" "$BIN/ac-fleets.sh" --json "$container" >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "grace '$g': the same exit"
  assert_eq "$(norm <"$TMP/n.raw")" "$(norm <"$TMP/o.raw")" "grace '$g': the same document"
done
AC_GUARD_GRACE='300,"injected":true' "$BIN/ac-fleets.sh" --json "$container" >"$TMP/n.raw" 2>"$TMP/n.err" && fail "an injected grace must be refused" || true
assert_eq "$(cat "$TMP/n.raw")" "" "injected grace: nothing on stdout"
assert_contains "$(cat "$TMP/n.err")" "invalid JSON text passed to --argjson" "injected grace: jq's own refusal"

pass
