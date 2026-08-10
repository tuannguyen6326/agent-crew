#!/usr/bin/env bash
# ac-session-start.sh - single ordered session-start digest for the
# orchestrator. Run at the start of every session, before anything else.
#
# Acquires the per-home session lock (ac-lock.sh acquire) FIRST. When another
# live session already owns the home (exit 2) the digest degrades to
# READ-ONLY: a prominent banner is printed, the wake-drain and qa-reap steps
# are SKIPPED (the owning session drains its own wakes), and the rest of the
# digest renders informationally.
#
# Composes: home identity, session lock, config convergence (crewdeputy
# homes), toolchain doctor, orphaned-shell-snapshot sweep, queued-wake drain
# + watcher health, clone staleness hints, worktree-pool health hints, fleet
# view, backlog head, project registry, and the supervision instruction block.
#
# The orphaned-shell-snapshot sweep (ac_orphan_snapshot_scan) is a read-only
# host check: it surfaces ppid==1 Claude shell-snapshot processes burning CPU
# (the orphan-busy-loop incident) so an accumulation is visible within ONE
# digest. It counts and hints, never kills, and prints only when something is
# wrong - so it is safe in read-only mode too (a pure ps scan, no writes).
#
# Ride-alongs after the lock, both non-blocking:
# - crewdeputy homes pull the parent's inheritable config knobs
#   (ac_config_converge_from_parent; skipped in read-only mode - convergence
#   writes config);
# - a clone-staleness HINT computed from LOCAL refs only (checked-out default
#   branch behind the already-fetched origin ref). No network fetch runs
#   here: ac-sync.sh's per-project fetch watchdog (default 60s) can burn its
#   full deadline per project when offline, which would stall the digest -
#   the real sync stays a printed `run bin/ac-sync.sh` suggestion.
#
# The per-project qa-infra reap sweep is BOUNDED (default 10s per project;
# AC_SESSION_QA_TIMEOUT overrides, non-numeric falls back - the same shape as
# ac-teardown.sh's AC_TEARDOWN_QA_TIMEOUT/qa_infra_timeout, itself the
# fetch_bounded watchdog at bin/ac-sync.sh:55-75): a wedged docker daemon
# (`docker ps -a` hangs) is killed on timeout, warned once by project, and
# the digest continues - session start sweeps EVERY registered project
# serially, so one wedged daemon must never block the whole fleet digest.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-maintenance-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"
home="$(ac_home)"

printf '== agent-crew session start ==\n'
printf 'home: %s\n' "$home"
printf 'captain: %s\n' "$(ac_captain)"
printf 'backend: %s\n' "$(ac_config_read backend herdr)"
printf 'flow: %s\n' "$(ac_config_read flow auto)"
printf 'promote: %s\n' "$(ac_config_read promote always)"

printf -- '-- session lock --\n'
read_only=0
lock_rc=0
lock_out="$("$bin_dir/ac-lock.sh" acquire 2>&1)" || lock_rc=$?
[ -n "$lock_out" ] && printf '%s\n' "$lock_out"
if [ "$lock_rc" -eq 2 ]; then
  read_only=1
  cat <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! READ-ONLY: another chief session owns this fleet.           !!
!! The digest below is informational only: no wake-drain, no   !!
!! qa reap, and spawning crew from this session is not advised.!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
elif [ "$lock_rc" -ne 0 ]; then
  ac_warn "session lock acquire failed (rc=$lock_rc) - continuing unlocked"
fi

# Crewdeputy ride-along: converge inheritable config from the parent home
# (see header). Non-blocking - a failed pull only warns.
if ac_is_crewdeputy_home; then
  printf -- '-- config converge (from parent) --\n'
  if [ "$read_only" -eq 1 ]; then
    printf '(read-only: converge skipped - it writes config)\n'
  else
    parent_cfg="$(cd "$home/../.." 2>/dev/null && pwd -P)/config"
    conv_out="$(ac_config_converge_from_parent "$parent_cfg" 2>&1)" || true
    if [ -n "$conv_out" ]; then printf '%s\n' "$conv_out"; else printf '(no drift)\n'; fi
  fi
fi

printf -- '-- toolchain --\n'
if "$bin_dir/ac-bootstrap.sh" --quiet; then
  printf '(all required tools present)\n'
fi

# Orphaned shell-snapshot sweep: surface ppid==1 snapshot processes burning
# CPU (the orphan-busy-loop incident) within ONE digest, before an hour of
# cores burns. Read-only - a count + inspect hint, never a kill (ac-lib.sh
# owns the contract). Prints only when something is wrong, like the clones
# hint below. Safe in read-only mode: a pure ps scan that writes nothing.
orphan_out="$(ac_orphan_snapshot_scan 2>/dev/null || true)"
if [ -n "$orphan_out" ]; then
  printf -- '-- orphaned shell-snapshots (host) --\n'
  printf '%s\n' "$orphan_out"
fi

printf -- '-- wakes --\n'
if [ "$read_only" -eq 1 ]; then
  printf '(read-only: wake-drain skipped - the owning session drains wakes)\n'
else
  "$bin_dir/ac-wake-drain.sh"
fi

# Orphaned qa infra sweep: reap crew-qa docker stacks whose run state is
# gone (crashed crewmates never fire traps). Quiet no-op without docker,
# skipped entirely in read-only mode. Each project's reap runs under a
# watchdog (header: the fetch_bounded shape) - a timeout (124) warns by
# name and the sweep moves on; any OTHER non-zero (including the ordinary
# no-orphans-to-reap case, where `| grep '^reaped'` finds nothing and exits
# 1 under `pipefail`) stays silent, exactly as the unbounded call did before.
session_qa_timeout() {
  local t="${AC_SESSION_QA_TIMEOUT:-10}"
  case "$t" in
    '' | *[!0-9]*) t=10 ;;
  esac
  printf '%s\n' "$t"
}

infra_reap_bounded() {
  # infra_reap_bounded <dir> <secs> <outfile> - one project's `ac-qa.sh infra
  # reap` under a watchdog (the fetch_bounded shape, bin/ac-sync.sh:55-75):
  # the child is killed once <secs> elapse (TERM, short grace, KILL).
  # Returns the reap's own status, or 124 on timeout. The docker grandchild
  # several levels down (ac-qa.sh -> docker ps -a) is orphaned, not reaped -
  # same as ac-teardown.sh's qa_infra_down_bounded - bounding THIS sweep is
  # the point, and the orphan is harmless bookkeeping noise on a wedged
  # daemon EXCEPT for one thing it must never hold onto: the caller's own
  # fds. The reap pipeline's tail (`grep '^reaped'`) is redirected to
  # <outfile> on fd 1 AND fd 2 goes to /dev/null - NEVER left to inherit
  # session start's own fds - an orphaned grep still blocked reading from a
  # wedged docker would otherwise keep whichever of the caller's fds it
  # inherited open past the point session start itself exits, so a caller
  # that captures the digest through EITHER fd (`out="$(...)"`, a merged
  # `out="$(... 2>&1)"`, `| tee`, a harness tool call) would hang forever
  # even though the timeout already fired and printed its WARN (verified:
  # a stdout-only redirect fixes a plain `$(...)` capture but a merged
  # `2>&1` one still hangs on the inherited fd 2 - both must go somewhere
  # that is not the caller's own descriptor. ac-teardown.sh's own child
  # avoids the same trap by discarding BOTH to /dev/null, which this sweep
  # cannot do for fd 1 alone since the reaped lines are real digest output).
  local dir="$1" secs="$2" outfile="$3" pid start
  ( cd "$dir" && "$bin_dir/ac-qa.sh" infra reap 2>/dev/null | grep '^reaped' ) >"$outfile" 2>/dev/null &
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}

if [ "$read_only" -eq 0 ] && command -v docker >/dev/null 2>&1; then
  qa_secs="$(session_qa_timeout)"
  for p in "$(ac_projects_dir)"/*/; do
    # qa run state lives in the main repo's .crew/qa OR inside pool
    # worktrees; reap resolves both - gate only on .crew existing.
    [ -d "$p/.crew" ] || continue
    # mktemp failing (an unwritable TMPDIR) must degrade this ONE project's
    # reaped-line output, never abort the whole digest under set -e: an
    # unguarded `reap_out="$(mktemp)"` would do exactly that.
    reap_out="$(mktemp 2>/dev/null)" || reap_out=""
    reap_rc=0
    infra_reap_bounded "$p" "$qa_secs" "${reap_out:-/dev/null}" || reap_rc=$?
    if [ -n "$reap_out" ]; then
      cat "$reap_out" 2>/dev/null
      rm -f "$reap_out"
    fi
    if [ "$reap_rc" -eq 124 ]; then
      ac_warn "infra-reap sweep for $(basename "$p") did not complete (bound ${qa_secs}s) - docker is unusable or hung; reap by hand once fixed: (cd $p && $bin_dir/ac-qa.sh infra reap)"
    fi
  done
fi

# Clone staleness ride-along: HINT from LOCAL refs only, never a network
# fetch (see header). Non-blocking and read-only - safe in every mode.
stale_lines=""
for p in "$(ac_projects_dir)"/*/; do
  [ -d "$p" ] || continue
  git -C "$p" rev-parse --git-dir >/dev/null 2>&1 || continue
  b="$(ac_default_branch "$p" 2>/dev/null)" || continue
  behind="$(git -C "$p" rev-list --count "refs/heads/$b..refs/remotes/origin/$b" 2>/dev/null)" || continue
  case "$behind" in '' | 0 | *[!0-9]*) continue ;; esac
  stale_lines="${stale_lines}stale $(basename "$p"): $b is $behind behind the already-fetched origin/$b
"
done
if [ -n "$stale_lines" ]; then
  printf -- '-- clones (local-ref staleness hint) --\n'
  printf '%s' "$stale_lines"
  printf 'run bin/ac-sync.sh to fast-forward (no network fetch was attempted here)\n'
fi

# Pool-health ride-along: surface stuck available-dirty worktree-pool slots
# (AGENTS.md section 6) with the exact reclaim command. Silent when every
# scanned pool is healthy; the script owns the whole block (ac-pool-health.sh).
"$bin_dir/ac-pool-health.sh"

printf -- '-- fleet --\n'
"$bin_dir/ac-fleet-view.sh"

printf -- '-- rooms (captain inbox) --\n'
"$bin_dir/ac-room.sh" list

records_dir="$(ac_records_dir)"
printf -- '-- backlog (head) --\n'
if [ -s "$records_dir/backlog.md" ]; then
  head -n 20 "$records_dir/backlog.md"
  # Scheduler: every READY item to start now, STUCK dependents to escalate.
  sched="$("$(dirname "$0")/ac-ready.sh" 2>/dev/null || true)"
  [ -n "$sched" ] && { printf -- '-- scheduler --\n'; printf '%s\n' "$sched"; }
else
  printf '(no backlog yet - records/backlog.md)\n'
fi

printf -- '-- projects --\n'
if [ -s "$records_dir/projects.md" ]; then
  cat "$records_dir/projects.md"
else
  printf '(no projects registered - records/projects.md)\n'
fi

# Crewdeputy routing table: the chief routes captain orders project-first,
# deputy-second, so the table reads right after the projects registry. UNLIKE
# the signal-only blocks below, this one ALWAYS prints - ABSENT and
# present-but-empty are different facts and only distinguishable if it does.
# Read-only (parses the ledger, probes windows), so it is safe in every mode.
printf -- '-- crewdeputies (routing table) --\n'
"$bin_dir/ac-deputy.sh" list

# The crewdomain routing table, printed UNCONDITIONALLY beside its neighbour and
# for the same reason - but it carries one duty the deputy block does not: `list`
# calls the provenance audit, so an UNAUTHORIZED domain-backlog row (one no
# `assign` stamped) is surfaced at EVERY crewchief session start with no new
# discipline. Chief-only-add is only as strong as its detection. Read-only, and
# `ac-domain.sh list` always exits 0 - a digest block may never take session
# start down.
printf -- '-- crewdomains (routing table) --\n'
"$bin_dir/ac-domain.sh" list

# Knowledge layers (L1 repo-knowledge + L2 scenes): the two durable stores a
# chief reads at intake, reported as COUNTS only. Both are O(1) in entries, and
# that bound is why neither re-derives anything here: `ac-know.sh verify` is an
# 8-second git walk over 487 entries (measured 2026-08-09), so the digest reads
# the STAMP that run left instead - and says plainly when there is none, or when
# the tree has moved past the one it graded. A verb nobody runs is a verb that
# does not exist; a count nobody can see is rot nobody fixes.
know_dir="$AC_HOME/records/repo-knowledge"
scene_dir="$AC_HOME/records/scenes"
know_lines=""
if [ -d "$know_dir" ]; then
  for kf in "$know_dir"/*.md; do
    [ -f "$kf" ] || continue
    kname="$(basename "$kf" .md)"
    kn="$(grep -c '^- fact\|^- scope' "$kf" 2>/dev/null || true)"
    kstamp="$AC_HOME/state/.know-verify-$kname.meta"
    if [ ! -f "$kstamp" ]; then
      know_lines="$know_lines
  $kname: $kn entries, NEVER verified - bin/ac-know.sh verify --repo <clone>"
    else
      ksus="$(ac_meta_get "$kstamp" suspect)"; kfresh="$(ac_meta_get "$kstamp" fresh)"
      kran="$(ac_meta_get "$kstamp" ran)"; khead="$(ac_meta_get "$kstamp" head)"
      know_lines="$know_lines
  $kname: $kn entries - ${kfresh:-0} fresh / ${ksus:-0} suspect (verified ${kran%%T*} @${khead:0:9})"
    fi
  done
fi
alw_line=""
alw_file="$AC_HOME/CREWMATE-learned.md"
if [ -f "$alw_file" ]; then
  alw_days="$(ac_config_read learn-stale-days 30)"
  case "$alw_days" in ''|*[!0-9]*) alw_days=30 ;; esac
  # Count-only, O(1) per entry (a string compare each): YYYY-MM-DD compares
  # correctly as text, so the stale test is `date <= cutoff` with the cutoff
  # computed ONCE by date(1) - deliberately no awk mktime, which BSD awk (this
  # host's) does not have. The full grading with remedies is `ac-learn.sh
  # stale`; the digest's job is to make the rot visible, not to relist it.
  alw_cutoff="$(date -u -v-"${alw_days}"d +%F 2>/dev/null || date -u -d "-${alw_days} days" +%F 2>/dev/null)"
  read -r alw_n alw_stale < <(awk -v cutoff="$alw_cutoff" '
    /^## /       { n++ }
    /^\(learned / {
      line = $0; d = ""
      if (match(line, /reinforced [0-9]{4}-[0-9]{2}-[0-9]{2}/)) d = substr(line, RSTART + 11, 10)
      else if (match(line, /learned [0-9]{4}-[0-9]{2}-[0-9]{2}/)) d = substr(line, RSTART + 8, 10)
      if (d != "" && cutoff != "" && d <= cutoff) stale++
    }
    END { print n + 0, stale + 0 }
  ' "$alw_file" 2>/dev/null || printf '0 0')
  if [ "${alw_n:-0}" -gt 0 ]; then
    alw_line="
  always-loaded: $alw_n entries, ${alw_stale:-0} stale (>${alw_days}d - ac-learn.sh stale)"
  fi
fi
scene_line=""
if [ -d "$scene_dir" ]; then
  sn="$(ls "$scene_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$sn" -gt 0 ]; then
    smax="$(ac_config_read scene-max 30)"
    # The hottest scene names what this fleet actually keeps reaching for.
    shot="$(for sf in "$scene_dir"/*.md; do
      [ -f "$sf" ] || continue
      printf '%s\t%s\n' "$(sed -n '2p' "$sf" | tr ' ' '\n' | sed -n 's/^heat=//p')" "$(basename "$sf" .md)"
    done | sort -rn | head -1 | cut -f2)"
    scene_line="
  scenes: $sn/$smax${shot:+ (hottest: $shot)}"
  fi
fi
if [ -n "$know_lines" ] || [ -n "$scene_line" ] || [ -n "$alw_line" ]; then
  printf -- '-- knowledge --'
  printf '%s%s%s\n' "$know_lines" "$alw_line" "$scene_line"
fi

# Learning-loop DISTILL trigger (Slice 2): surface when the per-debrief counter has
# reached config/learn-every, so the chief knows a learning run is due. READ-ONLY
# (ac_learn_due never writes the counter) and SILENT below threshold - the header
# prints only when there is a signal, matching the scheduler/clones blocks.
read -r learn_n learn_x < <(ac_learn_due)
if [ "$learn_n" -ge "$learn_x" ]; then
  printf -- '-- learning --\n'
  printf 'LEARNING DUE: %s/%s\n' "$learn_n" "$learn_x"
fi

# Records-wide CURATE trigger (Slice 4): surface when the per-learning-run
# counter has reached config/curate-every, so the chief knows a maintenance pass
# over the ledgers is due (ac-curate.sh run). Byte-for-byte the same shape as the
# learning block above: READ-ONLY (ac_curate_due never writes) and SILENT below
# threshold. NO cron, NO daemon.
read -r curate_n curate_x < <(ac_curate_due)
if [ "$curate_n" -ge "$curate_x" ]; then
  printf -- '-- curate --\n'
  printf 'CURATE DUE: %s/%s\n' "$curate_n" "$curate_x"
  # NAME WHAT WILL FIRE IT, because nothing here will. Curate has no firing path
  # of its own: it runs only as a side-effect of a Learning DISTILL run
  # (bin/ac-learn.sh), and this counter counts DISTILL RUNS, not landings - so
  # the threshold is reached long before the next DISTILL is, and the flag then
  # stands up for the rest of that interval. Measured on this fleet: `CURATE
  # DUE: 3/2` printed while the landing counter stood at 23/60, i.e. 37 landings
  # from the only event that would have discharged it. A due flag nobody can act
  # on is a flag nobody reads, so the digest says the distance and the manual
  # command rather than repeating a number that will not move.
  if [ "$learn_n" -lt "$learn_x" ]; then
    printf 'its automatic run rides the next Learning DISTILL, %s landing(s) away (%s/%s); to curate now: bin/ac-curate.sh run\n' \
      "$((learn_x - learn_n))" "$learn_n" "$learn_x"
  else
    printf 'the DUE Learning DISTILL above discharges it on its next run; to curate now: bin/ac-curate.sh run\n'
  fi
fi

# An UNSETTLED maintenance transaction refuses every OTHER Learning/Curate
# transaction (ac_maintenance_incomplete_other), so one crash between the claim
# and the final `complete` - or one plan whose second action failed - stops the
# whole knowledge-maintenance loop. It used to do that INVISIBLY: the next
# learning run warned about a stale receipt and Curate died, neither naming the
# transaction holding the claim. Silent when the loop is clear, same shape as
# the two blocks above; READ-ONLY.
maint_rows="$(ac_maintenance_incomplete "$(ac_state_dir)/.maintenance-transactions" 2>/dev/null || true)"
if [ -n "$maint_rows" ]; then
  printf -- '-- maintenance --\n'
  printf '%s\n' "$maint_rows" | while IFS="$(printf '\t')" read -r tx st done_n _; do
    [ -n "$tx" ] || continue
    printf 'INCOMPLETE TXN: %s (status=%s, %s action(s) committed) - it blocks every Learning/Curate transaction\n' \
      "$tx" "$st" "$done_n"
  done
  printf 'settle it: bin/ac-learn.sh maintenance status\n'
fi

# Standing-jobs ride-along: the CronCreate-scheduled fleet jobs (monitor,
# Slack STATUS) live only in harness session memory and die with the
# session, so a fresh session has no idea they are supposed to exist unless
# told. Placed last, right before supervision: this is the block a chief
# reads on the way OUT of the digest and into work, the exact point the
# measured failure (straight into the backlog, monitor never re-created)
# skipped past.
"$bin_dir/ac-standing-jobs.sh"

printf -- '-- supervision --\n'
cat <<'EOF'
While ANY crewmate is in flight, keep exactly one watcher armed as a
background task: run `bin/ac-watch.sh` in the background; when it exits it
prints one reason line (report:<id> | gone:<id> | stale:<id> | heartbeat).
On wake: run bin/ac-wake-drain.sh, handle each wake (peek, steer, teardown,
escalate to the captain), then re-arm the watcher. Never end a turn with
crew in flight and no armed watcher - the Stop hook enforces this.
EOF
