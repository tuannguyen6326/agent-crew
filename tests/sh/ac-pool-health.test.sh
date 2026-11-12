#!/usr/bin/env bash
# ac-pool-health.test.sh - the session-start pool-health digest block: it
# must render the exact reclaim command for every available-dirty slot, name
# a leased slot as active (never stuck), and stay completely silent when the
# pool is healthy.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo)"

# Build a real pool: two leases, one returned clean, one dirtied after return
# so it becomes available-dirty (stuck); the other stays leased (active).
wt1="$("$BIN/ac-tree.sh" get --repo "$repo" --id t1 2>/dev/null)"
wt2="$("$BIN/ac-tree.sh" get --repo "$repo" --id t2 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wt1" 2>/dev/null
printf 'unlanded\n' >>"$wt1/file.txt"

# RENDERS: with >=1 available-dirty slot, the header, repo name, stuck-dirty
# count, verbatim reclaim command and the dirty slot's path all appear; the
# still-leased slot is never flagged.
out="$("$BIN/ac-pool-health.sh" --repo "$repo")"
assert_contains "$out" "-- pool (worktree health) --" "header prints when unhealthy"
assert_contains "$out" "$(basename "$repo")" "repo name printed"
assert_contains "$out" "1 stuck-dirty" "stuck-dirty count printed"
assert_contains "$out" "bin/ac-tree.sh remove --force <worktree-path>" "verbatim reclaim command"
assert_contains "$out" "$wt1" "dirty slot's worktree path printed"
case "$out" in
  *"$wt2"*) fail "leased slot must never be flagged as stuck" ;;
  *"reclaim each broken slot"*) fail "a dirty-only pool must not print the broken reclaim hint (0 broken)" ;;
esac

# QUIET: clear the dirt (return --force resets it to available); no
# available-dirty slots remain, so the block prints nothing at all.
"$BIN/ac-tree.sh" return "$wt1" --force 2>/dev/null
out2="$("$BIN/ac-pool-health.sh" --repo "$repo")"
assert_eq "$out2" "" "quiet when every slot is available or leased"

# A tree parked on purpose (QA infra, an investigation) is protected by
# `ac-tree.sh lease`, not by staying dirty: leased state-only, it leaves the
# stuck-dirty bucket and the block stays quiet.
printf 'parked\n' >>"$wt1/file.txt"
"$BIN/ac-tree.sh" lease 1-repo --repo "$repo" --id park --holder self:park 2>/dev/null \
  || fail "fixture: lease of the available slot must succeed"
out3="$("$BIN/ac-pool-health.sh" --repo "$repo")"
assert_eq "$out3" "" "a slot leased state-only is active, never stuck-dirty"
"$BIN/ac-tree.sh" return "$wt1" --force 2>/dev/null

# BROKEN, own bucket: a slot released to the pool (leased=0) whose gitdir
# pointer is then broken must be named as its own bucket - never silently
# counted as leasable (wrong bucket) and never folded into stuck-dirty
# (different chief action). A broken-ONLY pool must still render.
repoB="$(make_repo broken)"
wtB="$("$BIN/ac-tree.sh" get --repo "$repoB" --id b1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtB" 2>/dev/null
rm -rf "$repoB/.git/worktrees/1-broken"
git -C "$wtB" rev-parse --git-dir >/dev/null 2>&1 && fail "fixture: the worktree must be broken"

outB="$("$BIN/ac-pool-health.sh" --repo "$repoB")"
assert_contains "$outB" "-- pool (worktree health) --" "header prints for a broken-only pool"
assert_contains "$outB" "0 leasable" "broken slot must never be counted as leasable"
assert_contains "$outB" "0 stuck-dirty" "a broken slot is not a dirty slot"
assert_contains "$outB" "1 broken" "broken count printed"
assert_contains "$outB" "$wtB" "broken slot's worktree path printed"
assert_contains "$outB" "bin/ac-tree.sh remove --force <worktree-path>" "broken-slot reclaim command printed"
case "$outB" in
  *"reclaim each dirty slot"*) fail "a broken-only pool must not print the dirty reclaim hint (0 stuck-dirty)" ;;
esac

# ARITHMETIC, mixed pool: 1 dirty + 1 broken + 1 leased. leasable + stuck +
# broken must account for every NON-LEASED slot (2 here) with no slot
# silently missing - "leasable + stuck < total" alone is not diagnostic
# since a leased slot matches neither bucket either.
repoM="$(make_repo mixed)"
wtM1="$("$BIN/ac-tree.sh" get --repo "$repoM" --id m1 2>/dev/null)"
wtM2="$("$BIN/ac-tree.sh" get --repo "$repoM" --id m2 2>/dev/null)"
"$BIN/ac-tree.sh" get --repo "$repoM" --id m3 >/dev/null 2>&1
"$BIN/ac-tree.sh" return "$wtM1" 2>/dev/null
printf 'unlanded\n' >>"$wtM1/file.txt"
"$BIN/ac-tree.sh" return "$wtM2" 2>/dev/null
rm -rf "$repoM/.git/worktrees/2-mixed"

outM="$("$BIN/ac-pool-health.sh" --repo "$repoM")"
assert_contains "$outM" "0 leasable" "mixed pool: no genuinely clean available slot"
assert_contains "$outM" "1 stuck-dirty" "mixed pool: exactly one dirty slot"
assert_contains "$outM" "1 broken" "mixed pool: exactly one broken slot"
assert_contains "$outM" "3 total" "mixed pool: all three slots counted"

# AGED-LEASED, own bucket: a durable lease (empty owner_pid - "no owner =
# durable", ac-tree.sh lease_reclaimable) held past the threshold has no other reporting
# path (acquire/prune/remove all skip a leased slot by design), so it must be
# named here with the reclaim command - and a FRESH lease must not be flagged.
repoA="$(make_repo aged)"
wtA1="$("$BIN/ac-tree.sh" get --repo "$repoA" --id a1 2>/dev/null)"
wtA2="$("$BIN/ac-tree.sh" get --repo "$repoA" --id a2 2>/dev/null)"
metaA1="$repoA/.crew/slots/1-aged.meta"
old_ts="$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)"
sed "s/^leased_at=.*/leased_at=$old_ts/" "$metaA1" >"$metaA1.tmp" && mv "$metaA1.tmp" "$metaA1"

outA="$("$BIN/ac-pool-health.sh" --repo "$repoA")"
assert_contains "$outA" "-- pool (worktree health) --" "header prints for an aged-leased pool"
assert_contains "$outA" "1 aged-leased" "aged-leased count printed"
assert_contains "$outA" "bin/ac-tree.sh remove --include-leased <worktree-path>" "verbatim aged-lease reclaim command (no --force: the gates stay armed)"
assert_contains "$outA" "$wtA1" "aged slot's worktree path printed"
# The stamp is UTC (ac_iso), so its age is read in UTC whatever the host zone:
# read as local time it was off by the zone's offset either way.
for zone in Asia/Ho_Chi_Minh America/Los_Angeles; do
  assert_contains "$(TZ="$zone" "$BIN/ac-pool-health.sh" --repo "$repoA")" "leased 48h ago" "a 2-day lease reads 48h under TZ=$zone"
done
case "$outA" in
  *"$wtA2"*) fail "a fresh lease must never be flagged as aged" ;;
  *"1 stuck-dirty"*) fail "an aged lease is not a dirty slot" ;;
esac

# A lease with a recorded --owner pid is NOT durable (it self-heals via
# lease_reclaimable on a dead pid) - age reporting is scoped to durable
# (empty owner_pid) leases only, so an owned lease stays unflagged however old.
metaA2="$repoA/.crew/slots/2-aged.meta"
sed -e "s/^leased_at=.*/leased_at=$old_ts/" -e 's/^owner_pid=.*/owner_pid=99999999/' "$metaA2" \
  >"$metaA2.tmp" && mv "$metaA2.tmp" "$metaA2"
outA2="$("$BIN/ac-pool-health.sh" --repo "$repoA")"
case "$outA2" in
  *"$wtA2"*) fail "an owner-pid lease is not durable and must not be reported as aged" ;;
esac
assert_contains "$outA2" "1 aged-leased" "the durable lease is still the only one reported"

# QUIET: an aged pool with the aged slot returned has nothing left to report
# (the other slot's owner-pid lease was never reportable to begin with).
"$BIN/ac-tree.sh" return "$wtA1" --force 2>/dev/null
outA3="$("$BIN/ac-pool-health.sh" --repo "$repoA")"
assert_eq "$outA3" "" "quiet once the aged lease is returned"

# --- the block, byte for byte, pool by pool -------------------------------------
report() {  # report <args...> - a report run: exit 0, silent on stderr; stdout lands in $TMP/n.out
  local rc=0
  "$BIN/ac-pool-health.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" || rc=$?
  assert_eq "$rc:$(cat "$TMP/n.err")" "0:" "a report exits 0, silent on stderr, for '$*'"
}
quiet() {  # quiet <label> <args...> - a report that prints nothing, not even a newline
  local label="$1"; shift
  report "$@"
  [ ! -s "$TMP/n.out" ] || fail "$label: expected no output, got: $(cat "$TMP/n.out")"
}
stamp() {  # stamp <meta> <leased_at> <owner_pid> - rewrite a lease the way the legs above do
  sed -e "s/^leased_at=.*/leased_at=$2/" -e "s/^owner_pid=.*/owner_pid=$3/" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# A: two slots, one returned clean, one leased with a live owner pid.
dA="$(make_repo dA)"
wtA1="$("$BIN/ac-tree.sh" get --repo "$dA" --id da1 2>/dev/null)"
"$BIN/ac-tree.sh" get --repo "$dA" --id da2 --owner $$ >/dev/null 2>&1
"$BIN/ac-tree.sh" return "$wtA1" 2>/dev/null
quiet "a healthy pool" --repo "$dA"
printf 'unlanded\n' >>"$wtA1/file.txt"
report --repo "$dA"
assert_eq "$(cat "$TMP/n.out")" "-- pool (worktree health) --
dA: 0 leasable / 2 total, 1 stuck-dirty (unleasable), 0 broken (unleasable), 0 aged-leased (>=24h, unconfirmed)
  reclaim each dirty slot: bin/ac-tree.sh remove --force <worktree-path>
  slot 1-dA  da1  $wtA1" "the whole block of a stuck-dirty pool, byte for byte"

# C: dirty + broken + durable aged in one pool.
dC="$(make_repo dC)"
wtC1="$("$BIN/ac-tree.sh" get --repo "$dC" --id dc1 2>/dev/null)"
wtC2="$("$BIN/ac-tree.sh" get --repo "$dC" --id dc2 2>/dev/null)"
wtC3="$("$BIN/ac-tree.sh" get --repo "$dC" --id dc3 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtC1" 2>/dev/null
printf 'unlanded\n' >>"$wtC1/file.txt"
"$BIN/ac-tree.sh" return "$wtC2" 2>/dev/null
rm -rf "$dC/.git/worktrees/2-dC"
stamp "$dC/.crew/slots/3-dC.meta" "$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)" ""
report --repo "$dC"
assert_eq "$(cat "$TMP/n.out")" "-- pool (worktree health) --
dC: 0 leasable / 3 total, 1 stuck-dirty (unleasable), 1 broken (unleasable), 1 aged-leased (>=24h, unconfirmed)
  reclaim each dirty slot: bin/ac-tree.sh remove --force <worktree-path>
  reclaim each broken slot: bin/ac-tree.sh remove --force <worktree-path>
  reclaim each aged lease (the broken/dirty/unmerged gates stay armed - it refuses instead of discarding if the slot still holds real content): bin/ac-tree.sh remove --include-leased <worktree-path>
  slot 1-dC  dc1  $wtC1
  slot 2-dC  dc2  $wtC2
  slot 3-dC  dc3  leased 48h ago  $wtC3" "hints dirty->broken->aged, slot lines stuck->broken->aged"

# D (repoA: an owner-pid lease, however old) beside E: a `leased dirty` durable
# lease at 25h (90000 s reads 25h, truncated).
dE="$(make_repo dE)"
wtE1="$("$BIN/ac-tree.sh" get --repo "$dE" --id de1 2>/dev/null)"
printf 'mid-task\n' >>"$wtE1/file.txt"
stamp "$dE/.crew/slots/1-dE.meta" "$(date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)" ""
report --repo "$repoA" --repo "$dE"
assert_contains "$(cat "$TMP/n.out")" "leased 25h ago" "a leased-dirty durable lease is aged like a clean one"
case "$(cat "$TMP/n.out")" in *"$(basename "$repoA"): "*) fail "a silent repo must not get a block" ;; esac

# Three repos: one header, the unhealthy blocks in argv order, nothing between.
report --repo "$dA" --repo "$repo" --repo "$repoB"
assert_eq "$(grep -c -- '-- pool' "$TMP/n.out")" "1" "the header prints once"
assert_eq "$(grep -n '^[^ ]' "$TMP/n.out" | cut -d: -f1,2 | tr '\n' ' ')" "1:-- pool (worktree health) -- 2:dA 5:broken " "dA's block then broken's, the clean repo between contributes nothing"

# F/G: the 86400 s threshold, padded 10 s either side so the two runs need not
# share a second.
dF="$(make_repo dF)"
"$BIN/ac-tree.sh" get --repo "$dF" --id df1 >/dev/null 2>&1
stamp "$dF/.crew/slots/1-dF.meta" "$(date -u -v-86410S +%Y-%m-%dT%H:%M:%SZ)" ""
dG="$(make_repo dG)"
"$BIN/ac-tree.sh" get --repo "$dG" --id dg1 >/dev/null 2>&1
stamp "$dG/.crew/slots/1-dG.meta" "$(date -u -v-86390S +%Y-%m-%dT%H:%M:%SZ)" ""
report --repo "$dF"
assert_contains "$(cat "$TMP/n.out")" "leased 24h ago" "a lease just past the threshold reads 24h"
quiet "a lease just short of the threshold" --repo "$dG"

# H: durable leases stamped with what BSD strptime refuses (month 13, hour 24),
# rolls (Feb 30, day 00) or cannot read at all.
dH="$(make_repo dH)"
i=0
for ts in 2026-13-01T00:00:00Z 2026-01-01T24:00:00Z 2024-02-30T00:00:00Z 2024-01-00T00:00:00Z bogus; do
  i=$((i + 1))
  "$BIN/ac-tree.sh" get --repo "$dH" --id "dh$i" >/dev/null 2>&1
  stamp "$dH/.crew/slots/$i-dH.meta" "$ts" ""
done
report --repo "$dH"
assert_contains "$(cat "$TMP/n.out")" "2 aged-leased" "the two rolled stamps are aged; month 13, hour 24 and bogus are not"
case "$(cat "$TMP/n.out")" in *"slot 1-dH"*|*"slot 2-dH"*|*"slot 5-dH"*) fail "a stamp strptime refuses must never read as aged" ;; esac

# I: a meta with an empty task= lists as the quoted '-' and prints verbatim.
dI="$(make_repo dI)"
wtI1="$("$BIN/ac-tree.sh" get --repo "$dI" --id di1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtI1" 2>/dev/null
printf 'unlanded\n' >>"$wtI1/file.txt"
sed 's/^task=.*/task=/' "$dI/.crew/slots/1-dI.meta" >"$TMP/m.tmp" && mv "$TMP/m.tmp" "$dI/.crew/slots/1-dI.meta"
report --repo "$dI"
assert_contains "$(cat "$TMP/n.out")" "  slot 1-dI  '-'  $wtI1" "the '-' placeholder and the two-space columns"

# Discovery under a home: p1 a dirty pool, p2 a clean pool, notgit a plain dir,
# nopool a repo with no pool.
home2="$TMP/home2"
mkdir -p "$home2/projects/notgit"
for p in p1 p2 nopool; do mv "$(make_repo "$p")" "$home2/projects/"; done
wtP1="$("$BIN/ac-tree.sh" get --repo "$home2/projects/p1" --id p1a 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtP1" 2>/dev/null
printf 'unlanded\n' >>"$wtP1/file.txt"
wtP2="$("$BIN/ac-tree.sh" get --repo "$home2/projects/p2" --id p2a 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtP2" 2>/dev/null
AC_HOME="$home2" report
assert_contains "$(cat "$TMP/n.out")" "
p1: 0 leasable / 1 total, 1 stuck-dirty" "discovery renders the dirty pool under its basename (no trailing slash)"
case "$(cat "$TMP/n.out")" in *"p2: "*|*notgit*|*nopool*) fail "discovery must skip a clean pool, a plain dir and a repo without a pool" ;; esac
# projects/ absent at the start: it is minted and nothing is scanned.
mkdir -p "$TMP/home3"
AC_HOME="$TMP/home3" quiet "discovery over a freshly minted projects/"
[ -d "$TMP/home3/projects" ] || fail "discovery mints projects/"

# Homeless: the refusal line on stderr, nothing on stdout, exit 0.
n_rc=0; AC_HOME= "$BIN/ac-pool-health.sh" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out"):$(cat "$TMP/n.err")" "0::ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" "homeless: the refusal line, nothing on stdout"

# A missing repo is silent (ac-tree.sh's refusal is discarded), an unknown
# word and a dangling --repo refuse.
quiet "a missing repo" --repo /nonexistent
n_rc=0; "$BIN/ac-pool-health.sh" --bogus >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out"):$(cat "$TMP/n.err")" "1::ERROR: ac-pool-health.sh: unknown argument --bogus" "unknown argument refusal"
n_rc=0; "$BIN/ac-pool-health.sh" --repo >"$TMP/n.out" 2>/dev/null || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out")" "1:" "a dangling --repo refuses"

# A relative --repo resolves from the caller's cwd and is named as given.
(cd "$dA" && report --repo .)
assert_eq "$(sed -n 2p "$TMP/n.out" | cut -c1-3)" ".: " "--repo . is named '.'"

# Environmental failures stay a report, exit 0, nothing printed (unprivileged
# only: root reads a mode-000 dir).
if [ "$(id -u)" -ne 0 ]; then
  hU="$TMP/home-unreadable"; mkdir -p "$hU/projects/p1/.crew/slots"; chmod 000 "$hU/projects"
  AC_HOME="$hU" quiet "an unreadable projects/"
  chmod 755 "$hU/projects"
fi
hF="$TMP/home-filed"; mkdir -p "$hF"; : >"$hF/projects"
AC_HOME="$hF" quiet "projects/ occupied by a file"
# No git on PATH: every candidate is skipped and every list is empty - a PATH
# farm of the host's tools minus git (bun stays for the shim).
farm="$TMP/nogit"; mkdir -p "$farm"
for f in /bin/* /usr/bin/* "$(command -v bun)"; do [ -x "$f" ] && [ "$(basename "$f")" != git ] && ln -s "$f" "$farm/$(basename "$f")" 2>/dev/null; done
PATH="$farm" quiet "without git the unhealthy pool reads as empty" --repo "$dC"
# A home that cannot be resolved (missing, a file, no search permission) scans
# nothing.
: >"$TMP/home-file"; mkdir -p "$TMP/home-noexec"; chmod 000 "$TMP/home-noexec"
for h in /nonexistent/home "$TMP/home-file" "$TMP/home-noexec"; do
  [ "$h" = "$TMP/home-noexec" ] && [ "$(id -u)" -eq 0 ] && continue
  AC_HOME="$h" quiet "unresolvable home $h"
done
chmod 755 "$TMP/home-noexec"
# A search-only home (mode 0100): resolving the home needs no read permission
# on the home itself, and its readable projects/ still lists the unhealthy pool
# (unprivileged only).
if [ "$(id -u)" -ne 0 ]; then
  hS="$TMP/home-searchonly"; mkdir -p "$hS/projects"; ln -s "$dC" "$hS/projects/dC"
  chmod 0100 "$hS"
  AC_HOME="$hS" report
  chmod 755 "$hS"
  assert_contains "$(cat "$TMP/n.out")" "dC: " "a search-only home still reports its unhealthy pool"
fi
# A repo alias whose name ends in newlines: the block label drops them.
ln -s "$dC" "$TMP/alias"$'\n\n'
report --repo "$TMP/alias"$'\n\n'
assert_contains "$(cat "$TMP/n.out")" "alias: " "the label is the alias name without its trailing newlines"
# Discovery names are native strings: APFS refuses a name that is not UTF-8
# (mkdir: Illegal byte sequence), so on this platform none exists to be lost;
# a filesystem that allows one is the unpinned case, named here.

pass
