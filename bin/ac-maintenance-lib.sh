#!/usr/bin/env bash
# ac-maintenance-lib.sh - the Learning/Curate cadence + maintenance-transaction
# concern, split out of ac-lib.sh (audit-f3, codebase-audit-2026-07-29 finding
# 3). Not an entrypoint; sourced after ac-lib.sh by any script that needs it -
# ac-lib.sh does NOT source this file (the ac-pipeline-lib.sh pattern: the
# CALLER sources both).
#
# Owns: the learning-loop DISTILL cadence gate (ac_learn_meta / ac_learn_migrate
# / ac_learn_tick / ac_learn_generation / ac_learn_ticks / ac_learn_tick_claim /
# ac_learn_due - the durable per-debrief counter that tells the chief when
# enough raw material has accrued to warrant a learning run), the DISTILL run's
# backup + counter reset (ac_records_backup / ac_learn_backup / ac_learn_reset),
# the records-wide CURATE interval gate (ac_curate_meta / ac_curate_tick /
# ac_curate_generation / ac_curate_due / ac_curate_reset), and the shared
# Learning/Curate maintenance transaction (ac_maintenance_target_allowed /
# ac_maintenance_path_plain / ac_maintenance_move_source /
# ac_maintenance_plan_validate / ac_maintenance_incomplete_other /
# ac_maintenance_incomplete / ac_maintenance_receipt_field /
# ac_maintenance_receipt_validate / _ac_maintenance_hold / ac_maintenance_apply
# - the closed, hash-bound plan Learning and Curate mutate fleet-local
# knowledge through: one fleet-wide writer lock, a pre-mutation backup, an
# action journal, and atomic file replacement).
#
# LAYERING: depends only on ac-lib.sh core (ac_state_dir, ac_home, ac_now,
# ac_meta_get, ac_meta_set, ac_lock_acquire, ac_lock_release, ac_records_dir,
# ac_skills_dir, ac_config_read, ac_sha256_file, ...). Never depended on by
# another sub-lib.

# --- learning-loop DISTILL trigger (Slice 2) ----------------------------------
# The cadence gate for the distill loop: a durable per-debrief counter that
# tells the chief when enough raw material has accrued to warrant a learning
# run. Ported from Hermes's in-process creation-nudge counter (report §3.1) -
# the knowledge-producing event agent-crew counts is a DEBRIEF (a batch of
# durable lessons hitting learnings.md), not a chat turn. Durable on disk, so a
# restart reads the true count with no resume-modulo.
#
# The counter lives at state/.learn.meta - DOT-PREFIXED so it stays OUTSIDE the
# state/*.meta task-meta namespace the fleet enumerates as crewmates; a bare
# learn.meta reads as a phantom crewmate (WATCHER-DOWN, a spurious gone: wake
# from the watcher, fleet-view/statusline pollution). Two writers: ac_learn_tick
# advances the counter, and ac_learn_reset zeroes it at the END of a successful
# DISTILL run (ac-learn.sh cmd_run, and still at a manual land) - never at tick.
# The level this counter reaches is what fires the ACT: ac-learn.sh autoroom
# opens the cap-exempt learning room off it at the next fleet drain.
#
# Key history: the counter key was `stows` until the skill rename (stow ->
# debrief, 2026-07-18). Live fleets carry .learn.meta files with the old key,
# so the WRITERS migrate on first touch (ac_learn_migrate) and the pure reader
# falls back to the legacy key - a fleet that never ticks again still reports
# its true count.

ac_learn_meta() { printf '%s/.learn.meta\n' "$(ac_state_dir)"; }

ac_learn_migrate() {
  # ac_learn_migrate <file> - one-time key rename stows -> debriefs: carry the
  # live count over, strip the legacy line (ac_meta_set cannot remove a key).
  # WRITERS call this; ac_learn_due stays pure and merely falls back on read.
  # When both keys exist (a half-migrated file), debriefs wins - never clobber.
  local f="$1" old tmp
  [ -f "$f" ] || return 0
  old="$(ac_meta_get "$f" stows)"
  [ -n "$old" ] || return 0
  [ -n "$(ac_meta_get "$f" debriefs)" ] || ac_meta_set "$f" debriefs "$old"
  tmp="$f.tmp.$$"
  grep -v '^stows=' "$f" >"$tmp" || true
  mv "$tmp" "$f"
}

ac_learn_tick() {
  # ac_learn_tick - advance the per-debrief counter by one (absent/garbage => 0).
  local f cur gen lock
  f="$(ac_learn_meta)"
  lock="$(ac_state_dir)/.learn-cadence.lock"
  # Loud in ac_learn_tick_claim's shape/register (F19) - the two are called two
  # lines apart in ac-learn.sh cmd_tick, and a silent failure here read as a
  # successful tick right after a loud claim. Missing a tick only delays the
  # next distill (the LEVEL trigger still fires); it costs latency, never
  # correctness - but only if the reader is TOLD, instead of believing the
  # counter moved when it did not.
  ac_lock_acquire "$lock" 10 || {
    ac_warn "learning tick: cadence lock $lock could not be acquired within 10s - the debrief counter was NOT advanced. Missing a tick only delays the next distill (the LEVEL trigger still fires); it never loses a landing outright, but a caller that assumes success will believe the counter moved when it did not."
    return 1
  }
  ac_learn_migrate "$f"
  cur="$(ac_meta_get "$f" debriefs)"
  gen="$(ac_meta_get "$f" generation)"
  case "$cur" in '' | *[!0-9]*) cur=0 ;; esac
  case "$gen" in '' | *[!0-9]*) gen=0 ;; esac
  ac_meta_set "$f" generation "$gen"
  ac_meta_set "$f" debriefs "$((cur + 1))"
  ac_lock_release "$lock"
}

ac_learn_generation() {
  local gen
  gen="$(ac_meta_get "$(ac_learn_meta)" generation)"
  case "$gen" in '' | *[!0-9]*) gen=0 ;; esac
  printf '%s\n' "$gen"
}

# The LANDING STAMPS - what makes a landing's tick idempotent. A landing debrief
# has two possible actors (the roomchief before its handback, the crewchief at
# close-out) and NEITHER can see the other's tick, so the counter advanced twice
# per promoted family's landing. The stamps also cover the case no rule naming a
# single actor could: ONE actor re-running its own tick after a failed
# invocation. Same namespace lesson as the counter above - one DOT-prefixed file
# at state/.learn-ticks, never a bare state/*.meta.
#
# Shape copied from the landing ledger (ac_landing_record, ac-lib.sh): a TSV
# `epoch \t key` appended with the expiry prune folded into the same atomic
# tmp+mv, so the file stays bounded with no separate sweep.

ac_learn_ticks() { printf '%s/.learn-ticks\n' "$(ac_state_dir)"; }

ac_learn_tick_claim() {
  # ac_learn_tick_claim <key> - claim the ONE tick a landing is owed. Exit 0 when
  # the claim is fresh (the caller advances the counter), 1 when <key> is already
  # stamped inside the dedupe window (the caller must NOT).
  #
  # The window is 24h, the same horizon ac_landing_warn reads the landing ledger
  # at, and it is deliberately far WIDER than the minutes between one landing's
  # two actors: the two errors are not symmetric. Counting a landing twice
  # consumes a retro window nothing ever re-examines (ac_learn_reset stamps
  # last_run past it) and is unrecoverable; missing one only delays the next
  # distill, which the LEVEL trigger still fires later. So the window errs long.
  #
  # SERIALIZED under the cadence lock ac_learn_tick already takes, because the
  # claim is a check-then-rewrite and its two actors are separate PROCESSES:
  # the roomchief's pre-handback tick racing the crewchief's close-out tick is
  # ordinary under parallel rooms. Unserialized, both read "not stamped" and
  # both advance the counter - the unrecoverable direction this stamp exists to
  # prevent - or one whole-file rewrite loses the other's stamp to last-mv-wins
  # and double-counts later. The lock is taken and RELEASED here, never held
  # across ac_learn_tick: the mkdir lock is not re-entrant, so a caller holding
  # it around both would spin its own timeout and fail. Serializing the claim
  # alone is what the invariant needs - the loser reads the winner's stamp and
  # never reaches the tick at all.
  local key="$1" f now tmp win=86400 lock rc=0
  f="$(ac_learn_ticks)"
  lock="$(ac_state_dir)/.learn-cadence.lock"
  # A failed acquire returns "not claimed", the recoverable direction - but it
  # SAYS so, because the caller renders a bare 1 as "already counted" and that
  # is a different fact.
  ac_lock_acquire "$lock" 10 || {
    ac_warn "learning tick: cadence lock $lock could not be acquired within 10s - landing '$key' was NOT claimed. Missing a tick only delays the next distill (the LEVEL trigger still fires); counting one twice consumes a retro window and cannot be undone."
    return 1
  }
  now="$(ac_now)"
  if [ -f "$f" ] && awk -F'\t' -v now="$now" -v k="$key" -v win="$win" \
    '$2 == k && now - $1 < win { hit = 1 } END { if (!hit) exit 1 }' "$f"; then
    ac_lock_release "$lock"
    return 1
  fi
  tmp="$f.tmp.$$"
  {
    [ ! -f "$f" ] || awk -F'\t' -v now="$now" -v win="$win" 'now - $1 < win' "$f"
    printf '%s\t%s\n' "$now" "$key"
  } >"$tmp"
  mv "$tmp" "$f" || rc=1
  ac_lock_release "$lock"
  return "$rc"
}

ac_learn_due() {
  # ac_learn_due - print `<debriefs> <learn-every>`: the durable debrief count
  # and the config threshold (config/learn-every, default 8 - Q7). PURE: reads
  # only, never writes the counter, so the session-start digest can print the
  # signal even in read-only mode - which is also why the legacy `stows` key is
  # read as a fallback here instead of migrated. Both fields are ALWAYS numeric
  # (absent/garbage => 0 / 8) so a caller's numeric compare never crashes on a
  # typo'd knob.
  local cur every
  cur="$(ac_meta_get "$(ac_learn_meta)" debriefs)"
  [ -n "$cur" ] || cur="$(ac_meta_get "$(ac_learn_meta)" stows)"
  case "$cur" in '' | *[!0-9]*) cur=0 ;; esac
  every="$(ac_config_read learn-every 8)"
  case "$every" in '' | *[!0-9]*) every=8 ;; esac
  printf '%s %s\n' "$cur" "$every"
}

# --- learning-loop DISTILL run: backup + counter reset (Slice 3) ---------------
# Slice 2 shipped the read-only cadence (tick/due). Slice 3 adds the two durable
# side effects a distill RUN owns: the pre-run backup (the Q8 reversibility
# floor) taken at its start, and the counter reset taken at its end - the run is
# the examination the counter counts, so a distill that proposes nothing still
# consumes its cycle. A manual `land` resets too, covering a land with no run in
# between. `ac_learn_due` stays pure - only these write.

ac_records_backup() {
  # ac_records_backup <prefix> - snapshot the fleet's mutable truth (records/ +
  # the skills store) to state/backups/<prefix>-<epoch>.tar.gz, and print its
  # path. The shared body of the layer-3 reversibility floor (Q8, captain "k
  # dùng git, track bằng backup"): ac_learn_backup passes `learn`, the records
  # CURATE pass (ac-curate.sh) passes `curate`, so a backup's provenance is
  # legible from its name and a bad land OR curate is undone by restoring its
  # archive. The archive lives in a DEDICATED backups/ subdir, never loose in
  # state/ - a loose file there would read as a phantom crewmate against the
  # state/*.meta glob (the Slice 2 namespace lesson). records/ and skills/ are
  # resolved (and created) first so the tar always has both members even on a
  # fresh home; paths are stored relative to the home so a restore is
  # `tar -xzf <arc> -C <home>`.
  local prefix="$1" home bdir arc
  local -a members
  home="$(ac_home)"
  ac_records_dir >/dev/null   # ensure records/ exists
  ac_skills_dir >/dev/null    # ensure skills/ exists
  bdir="$(ac_state_dir)/backups"
  mkdir -p "$bdir"
  arc="$bdir/$prefix-$(ac_now).tar.gz"
  members=(records skills)
  # Crewdomain packages hold mutable truth too - a domain backlog and a projects
  # detail file - and they live OUTSIDE records/, so without this they would sit
  # outside the reversibility floor. Extending the one shared function is what
  # lets assign/unassign/learn/curate all inherit coverage; a per-verb tar would
  # replicate the logic and silently omit the next mutator anyone adds.
  # PATH-SPECIFIC members per package, never the bare crewdomains dir: a foreign
  # directory under it then contributes nothing and needs no classifying. And
  # never crewdeputies/ - a deputy home is a separate home that backs itself up
  # against its own $AC_HOME, with its own records/ and its own clones.
  local pkgrec
  for pkgrec in "$home"/crewdomains/*/records; do
    [ -d "$pkgrec" ] || continue
    local pkgname; pkgname="$(basename "$(dirname "$pkgrec")")"
    members+=("crewdomains/$pkgname/records")
    [ ! -f "$(dirname "$pkgrec")/CREWMATE.md" ] \
      || members+=("crewdomains/$pkgname/CREWMATE.md")
    # The projects/ VIEW is authoritative membership state and the registry
    # deliberately does not duplicate it, so a restore without it recovers the
    # backlog and the prose but loses which projects the domain may work. It
    # rides as LINKS - the tar must never gain -h - so no clone content follows.
    [ ! -d "$(dirname "$pkgrec")/projects" ] \
      || members+=("crewdomains/$pkgname/projects")
  done
  [ ! -f "$home/state/.learn.meta" ] || members+=(state/.learn.meta)
  [ ! -f "$home/state/.curate.meta" ] || members+=(state/.curate.meta)
  # The machine-owned crewmate lesson layer is mutable truth a learning
  # transaction rewrites - same reversibility floor as records/ and skills/.
  [ ! -f "$home/CREWMATE-learned.md" ] || members+=(CREWMATE-learned.md)
  tar -czf "$arc" -C "$home" "${members[@]}"
  printf '%s\n' "$arc"
}

ac_learn_backup() {
  # ac_learn_backup - the DISTILL run's pre-run backup: ac_records_backup with
  # the `learn` prefix (state/backups/learn-<epoch>.tar.gz). Shares its body
  # with the CURATE pass's backup - see ac_records_backup.
  ac_records_backup learn
}

ac_learn_reset() {
  # ac_learn_reset - the RESET Slice 2 deferred to here: zero the per-debrief
  # counter and stamp last_run=<epoch>. Primary caller: the END of a SUCCESSFUL
  # DISTILL run (ac-learn.sh cmd_run) - the run is the examination the counter
  # counts, so a run that proposes nothing still consumes its cycle. `land` calls
  # it too, which now usually re-does what the run just did but still covers a
  # manual land with no run in between. Never at tick. Extends the same
  # state/.learn.meta primitive; ac_learn_due keeps reading `debriefs` unchanged.
  # last_run is ALSO the retro window anchor (ac-learn.sh learn_retro_snapshot),
  # so every caller must have read the anchor it needs BEFORE calling this.
  #
  # It deliberately does NOT prune the landing stamps (ac_learn_tick_claim). A
  # distill run completes ASYNCHRONOUSLY to any landing, so a reset can fall
  # BETWEEN a landing's two actors; dropping the stamp there would let the second
  # actor advance the fresh cycle - the double-advance the stamps exist to stop,
  # re-opened exactly at the cycle boundary. Their own 24h expiry bounds the file.
  local f expected="${1:-}" current lock
  f="$(ac_learn_meta)"
  lock="$(ac_state_dir)/.learn-cadence.lock"
  ac_lock_acquire "$lock" 10 || return 1
  ac_learn_migrate "$f"
  current="$(ac_learn_generation)"
  if [ -n "$expected" ] && [ "$expected" != "$current" ]; then
    ac_lock_release "$lock"
    return 1
  fi
  ac_meta_set "$f" generation "$((current + 1))"
  ac_meta_set "$f" debriefs 0
  ac_meta_set "$f" last_run "$(ac_now)"
  ac_lock_release "$lock"
}

# --- records-wide CURATE interval gate (Slice 4) ------------------------------
# The cadence gate for the CURATE pass - the exact analogue of the DISTILL
# trigger above, one rung up. The knowledge-producing event it counts is a
# LEARNING-RUN (the DISTILL run is the fleet's "tick", report §2.4), not a
# debrief, so ac_curate_tick is wired into ac-learn.sh's cmd_run (once per run),
# not into the debrief path. Durable on disk, so a restart reads the true count.
#
# The counter lives at state/.curate.meta - DOT-PREFIXED (the Slice 2 namespace
# lesson) so it stays OUTSIDE the state/*.meta task-meta namespace; a bare
# curate.meta reads as a phantom crewmate (WATCHER-DOWN, a spurious gone: wake,
# fleet-view/statusline pollution). ac_curate_due stays PURE - the session-start
# digest reads it read-only; only tick/reset write.

ac_curate_meta() { printf '%s/.curate.meta\n' "$(ac_state_dir)"; }

ac_curate_tick() {
  # ac_curate_tick - advance the per-learning-run counter by one (absent/garbage
  # => 0). Called ONCE per learning-run, from ac-learn.sh cmd_run (the distill
  # run is the tick, report §2.4).
  local f cur gen lock
  f="$(ac_curate_meta)"
  lock="$(ac_state_dir)/.curate-cadence.lock"
  ac_lock_acquire "$lock" 10 || return 1
  cur="$(ac_meta_get "$f" runs_since)"
  gen="$(ac_meta_get "$f" generation)"
  case "$cur" in '' | *[!0-9]*) cur=0 ;; esac
  case "$gen" in '' | *[!0-9]*) gen=0 ;; esac
  ac_meta_set "$f" generation "$gen"
  ac_meta_set "$f" runs_since "$((cur + 1))"
  ac_lock_release "$lock"
}

ac_curate_generation() {
  local gen
  gen="$(ac_meta_get "$(ac_curate_meta)" generation)"
  case "$gen" in '' | *[!0-9]*) gen=0 ;; esac
  printf '%s\n' "$gen"
}

ac_curate_due() {
  # ac_curate_due - print `<runs_since> <curate-every>`: the durable
  # learning-run count since the last curate and the config threshold
  # (config/curate-every, default 5 - Q7). PURE: reads only, never writes the
  # counter, so the digest can print the signal even in read-only mode. Both
  # fields are ALWAYS numeric (absent/garbage => 0 / 5) so a caller's numeric
  # compare never crashes on a typo'd knob. Exact analogue of ac_learn_due.
  local cur every
  cur="$(ac_meta_get "$(ac_curate_meta)" runs_since)"
  case "$cur" in '' | *[!0-9]*) cur=0 ;; esac
  every="$(ac_config_read curate-every 5)"
  case "$every" in '' | *[!0-9]*) every=5 ;; esac
  printf '%s %s\n' "$cur" "$every"
}

ac_curate_reset() {
  # ac_curate_reset - zero the per-learning-run counter and stamp
  # last_run=<epoch>. Fires only at a completed CURATE pass (ac-curate.sh run),
  # the analogue of ac_learn_reset. ac_curate_due keeps reading `runs_since`.
  local f expected="${1:-}" current lock
  f="$(ac_curate_meta)"
  lock="$(ac_state_dir)/.curate-cadence.lock"
  ac_lock_acquire "$lock" 10 || return 1
  current="$(ac_curate_generation)"
  if [ -n "$expected" ] && [ "$expected" != "$current" ]; then
    ac_lock_release "$lock"
    return 1
  fi
  ac_meta_set "$f" generation "$((current + 1))"
  ac_meta_set "$f" runs_since 0
  ac_meta_set "$f" last_run "$(ac_now)"
  ac_lock_release "$lock"
}

# --- shared Learning / Curate maintenance transaction -------------------------
# Learning and Curate are allowed to mutate fleet-local knowledge automatically
# only through one closed, hash-bound plan. These helpers own the common
# validation and apply boundary: no shell fields, no arbitrary paths, one
# fleet-wide writer lock, a pre-mutation backup, an action journal, and atomic
# file replacement. A replay of a committed plan is a no-op; a replay after a
# crash resumes from hashes rather than guessing whether a write landed.
# ac_sha256_file lives in CORE (bin/ac-lib.sh), not here: ac_seed_install also
# calls it, and core may not depend on a sub-lib.

ac_maintenance_target_allowed() {
  # CREWMATE-learned.md is the ONE home-root target: the machine-owned crewmate
  # lesson layer (learning-output-reroute). An exact literal, never a glob -
  # the home root also holds config/ and CREWMATE.md, which stay out of reach.
  case "$1" in
    records/*|skills/*|state/.learn.meta|state/.curate.meta|CREWMATE-learned.md) return 0 ;;
    *) return 1 ;;
  esac
}

ac_crewmate_learned_no_loss() {
  # ac_crewmate_learned_no_loss <live> <staged> <retired-file-or-empty> - the
  # no-silent-loss guard every CREWMATE-learned.md rewrite must pass (adopted
  # from openclaw's preserve-prior-entries gate): every '## <slug>' heading
  # present in <live> and absent from <staged> must be named in the staged
  # retired file, else the rewrite refuses. A missing live file passes
  # trivially (first write); an empty third argument means nothing may drop.
  local live="$1" staged="$2" retired="$3" head
  [ -f "$live" ] || return 0
  [ -f "$staged" ] || return 1
  while IFS= read -r head; do
    grep -qxF "$head" "$staged" && continue
    [ -n "$retired" ] && [ -f "$retired" ] \
      && grep -qF "${head#\#\# }" "$retired" && continue
    return 1
  done < <(grep '^## ' "$live" || true)
  return 0
}

ac_maintenance_path_plain() {
  # ac_maintenance_path_plain <root> <relative-path> - prove that an already
  # existing path component is not a symlink. Plan paths are restricted to a
  # conservative portable character set before reaching this helper.
  local root="$1" rel="$2" rest part cur
  cur="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
  rest="$rel"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    [ -n "$part" ] || return 1
    cur="$cur/$part"
    [ ! -L "$cur" ] || return 1
    if [ "$rest" = "$part" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
  done
}

ac_maintenance_move_source() {
  # ac_maintenance_move_source <archive-target> - infer the live source for the
  # closed move-skill action. A move target is always inside the fleet-local
  # skills archive; no arbitrary source path is accepted from a model plan.
  local target="$1" prefix
  prefix="skills/$AC_SKILLS_ARCHIVE_BASENAME/"
  case "$target" in
    "$prefix"*/*) printf 'skills/%s\n' "${target#"$prefix"}" ;;
    *) return 1 ;;
  esac
}

ac_maintenance_plan_validate() {
  # ac_maintenance_plan_validate <plan.json> <run-dir>
  local plan="$1" run="$2" home op target source staged staged_abs expected actual
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$plan" ] && [ ! -L "$plan" ] && [ -d "$run" ] && [ ! -L "$run" ] \
    || return 1
  home="$(ac_home)"

  jq -e '
    type == "object"
    and keys == ["actions","input_manifest_sha256","mode","run_id","schema","subject"]
    and .schema == "agentcrew.maintenance-plan/v1"
    and (.mode == "learning" or .mode == "curate")
    and (.run_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.subject | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.input_manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.actions | type == "array")
    and ([.actions[].target] | length == (unique | length))
    and all(.actions[];
      type == "object"
      and keys == ["new_sha256","old_sha256","op","staged","target"]
      and (.op == "write-skill"
        or .op == "patch-skill"
        or .op == "move-skill"
        or .op == "append-archive"
        or .op == "rewrite-ledger"
        or .op == "rewrite-index"
        or .op == "rewrite-registry"
        or .op == "rewrite-crewmate-learned"
        or .op == "update-cadence")
      and (.target | type == "string"
        and test("^[A-Za-z0-9._/-]+$")
        and (test("(^|/)\\.\\.?(/|$)") | not)
        and (startswith("/") | not))
      and (.staged | type == "string"
        and test("^staged/[A-Za-z0-9._/-]+$")
        and (test("(^|/)\\.\\.?(/|$)") | not))
      and (.old_sha256 | type == "string"
        and (. == "-" or test("^[0-9a-f]{64}$")))
      and (.new_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    )
  ' "$plan" >/dev/null 2>&1 || return 1

  while IFS=$'\t' read -r op target staged expected; do
    ac_maintenance_target_allowed "$target" || return 1
    ac_maintenance_path_plain "$home" "$target" || return 1
    ac_maintenance_path_plain "$run" "$staged" || return 1
    staged_abs="$run/$staged"
    [ -f "$staged_abs" ] && [ ! -L "$staged_abs" ] || return 1
    actual="$(ac_sha256_file "$staged_abs")" || return 1
    [ "$actual" = "$expected" ] || return 1
    if [ "$op" = move-skill ]; then
      [ "$(jq -r --arg target "$target" \
        '.actions[] | select(.target == $target) | .old_sha256' "$plan")" = "-" ] \
        || return 1
      source="$(ac_maintenance_move_source "$target")" || return 1
      ac_maintenance_path_plain "$home" "$source" || return 1
      if [ -f "$home/$source" ] && [ ! -L "$home/$source" ]; then
        [ "$(ac_sha256_file "$home/$source")" = "$expected" ] || return 1
      elif [ -f "$home/$target" ] && [ ! -L "$home/$target" ]; then
        [ "$(ac_sha256_file "$home/$target")" = "$expected" ] || return 1
      else
        return 1
      fi
    fi
  done < <(jq -r '.actions[] | [.op,.target,.staged,.new_sha256] | @tsv' "$plan")
}

ac_maintenance_incomplete_other() {
  # ac_maintenance_incomplete_other <transactions-root> <current-dir> - 0 when
  # some OTHER transaction is unsettled, which refuses this one. A transaction
  # is settled when it reached `complete`, or when a captain explicitly
  # ABANDONED it (ac-learn.sh maintenance abandon): an abandoned journal is a
  # kept record of a decision, not an open claim, and without that state a
  # transaction interrupted mid-apply refused every future Learning/Curate run
  # forever with no verb able to end it.
  local root="$1" current="$2" dir journal
  [ -d "$root" ] || return 1
  for dir in "$root"/*; do
    [ -d "$dir" ] && [ "$dir" != "$current" ] || continue
    journal="$dir/journal"
    [ -f "$journal" ] || continue
    case "$(ac_meta_get "$journal" status)" in
      complete | abandoned) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

ac_maintenance_incomplete() {
  # ac_maintenance_incomplete <transactions-root> - print one line per UNSETTLED
  # transaction: `<txid>\t<status>\t<actions-committed>\t<plan-or-'-'>`. Silent
  # when the loop is clean, so a digest can print a header only when there is a
  # signal. PURE: reads only.
  #
  # This exists because an unsettled transaction is INVISIBLE otherwise while
  # refusing every other one (ac_maintenance_incomplete_other above): the next
  # Learning run warns about a stale continue receipt, Curate ac_dies, and
  # neither names the transaction actually holding the claim.
  local root="$1" dir journal txid status idx done_n plan
  [ -d "$root" ] || return 0
  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    journal="$dir/journal"
    [ -f "$journal" ] || continue
    status="$(ac_meta_get "$journal" status)"
    case "$status" in complete | abandoned) continue ;; esac
    txid="$(basename "$dir")"
    done_n=0
    idx=0
    while [ "$(ac_meta_get "$journal" "action_$idx")" = complete ]; do
      done_n=$((done_n + 1))
      idx=$((idx + 1))
    done
    plan="$(ac_meta_get "$journal" plan)"
    printf '%s\t%s\t%s\t%s\n' "$txid" "${status:-unknown}" "$done_n" "${plan:--}"
  done
}

ac_maintenance_receipt_field() {
  # ac_maintenance_receipt_field <receipt> <key> - read one quoted frontmatter
  # scalar. The closed validator below proves uniqueness before this is used.
  local receipt="$1" key="$2" value
  value="$(awk -v key="$key" '
    NR == 1 && $0 == "---" { front = 1; next }
    front && $0 == "---" { exit }
    front && index($0, key ":") == 1 {
      sub("^[^:]+:[[:space:]]*", "")
      print
    }
  ' "$receipt")"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$value"
}

ac_maintenance_receipt_validate() {
  # ac_maintenance_receipt_validate <receipt.md> <plan.json> <manifest>
  # Print the validated decision. This is the authorization boundary shared by
  # Learning and Curate; an `approved:` candidate header never reaches it.
  local receipt="$1" plan="$2" manifest="$3" mode subject decision input_sha plan_sha run
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ -f "$manifest" ] \
    && [ ! -L "$manifest" ] || return 1
  run="$(cd "$(dirname "$plan")" 2>/dev/null && pwd -P)" || return 1
  [ "$(basename "$run")" != plans ] || run="$(cd "$run/.." && pwd -P)"
  ac_maintenance_plan_validate "$plan" "$run" || return 1
  awk '
    NR == 1 && $0 == "---" { front = 1; next }
    front && $0 == "---" { front = 0; closed = 1; next }
    front {
      if ($0 !~ /^[A-Za-z0-9_]+: ".*"$/) exit 2
      key = $0; sub(/:.*/, "", key)
      allowed = (key == "schema" || key == "mode" || key == "subject" || key == "decision" || key == "authority" || key == "engine" || key == "model" || key == "input_manifest_sha256" || key == "action_plan_sha256" || key == "reviewed_at")
      if (!allowed) exit 2
      seen[key]++
    }
    END {
      required[1] = "schema"; required[2] = "mode"; required[3] = "subject"
      required[4] = "decision"; required[5] = "authority"; required[6] = "engine"
      required[7] = "model"; required[8] = "input_manifest_sha256"
      required[9] = "action_plan_sha256"; required[10] = "reviewed_at"
      if (!closed) exit 2
      for (i = 1; i <= 10; i++) if (seen[required[i]] != 1) exit 2
    }
  ' "$receipt" || return 1
  [ "$(ac_maintenance_receipt_field "$receipt" schema)" = "agentcrew.maintenance-gate/v1" ] \
    || return 1
  mode="$(ac_maintenance_receipt_field "$receipt" mode)" || return 1
  subject="$(ac_maintenance_receipt_field "$receipt" subject)" || return 1
  decision="$(ac_maintenance_receipt_field "$receipt" decision)" || return 1
  case "$decision" in continue|revise|ask-captain) ;; *) return 1 ;; esac
  [ "$mode" = "$(jq -r '.mode' "$plan")" ] || return 1
  [ "$subject" = "$(jq -r '.subject' "$plan")" ] || return 1
  input_sha="$(ac_sha256_file "$manifest")" || return 1
  plan_sha="$(ac_sha256_file "$plan")" || return 1
  [ "$input_sha" = "$(jq -r '.input_manifest_sha256' "$plan")" ] || return 1
  [ "$input_sha" = "$(ac_maintenance_receipt_field "$receipt" input_manifest_sha256)" ] \
    || return 1
  [ "$plan_sha" = "$(ac_maintenance_receipt_field "$receipt" action_plan_sha256)" ] \
    || return 1
  awk '
    /^## Grounds[[:space:]]*$/ { section = "grounds"; next }
    /^## Proposed Process[[:space:]]*$/ { section = "process"; next }
    /^## / { section = ""; next }
    section == "grounds" && /[^[:space:]]/ { grounds = 1 }
    section == "process" && /[^[:space:]]/ { process = 1 }
    END { exit(grounds && process ? 0 : 1) }
  ' "$receipt" || return 1
  printf '%s\n' "$decision"
}

_ac_maintenance_hold() {
  # _ac_maintenance_hold <journal> <txn> <committed> <total> <why> - the ONE
  # exit every failure past the claim takes, and the answer to the apply loop
  # having NO atomicity across actions: the actions that already ran STAY on
  # disk, so a bare `return 1` reported a half-applied plan exactly like a plan
  # that never started. The transaction is left RESUMABLE (status stays
  # `applying`, and the journal carries the plan+run a replay needs) - it is
  # hash-bound, so a replay skips what already landed and re-checks the rest -
  # and this SAYS so, with how much landed and the two verbs that settle it.
  local journal="$1" txn="$2" committed="$3" total="$4" why="$5" txid
  txid="$(basename "$txn")"
  ac_meta_set "$journal" held_committed "$committed"
  ac_meta_set "$journal" held_reason "$why"
  ac_warn "maintenance transaction $txid is HELD ($why): $committed of its $total action(s) are already committed to disk and are NOT rolled back. It stays claimed, so every other Learning/Curate transaction refuses until it is settled. Fix the cause and replay it (already-applied actions are skipped by hash), or drop it and keep the record: bin/ac-learn.sh maintenance resume $txid | bin/ac-learn.sh maintenance abandon $txid"
}

ac_maintenance_apply() {
  # ac_maintenance_apply <plan.json> <run-dir> - apply or resume one immutable
  # maintenance plan. The gate/receipt caller validates authorization; this
  # layer validates the closed action plan and owns recoverable file mutation.
  #
  # RESUMABLE, NOT ALL-OR-NOTHING, and that is a decision rather than an
  # omission: the plan mutates N independent files (and a move-skill removes a
  # source), and no shell can commit N renames atomically - a crash between two
  # of them lands a partial state whatever the staging discipline. So the
  # apply is idempotent per action instead, keyed on hashes: an action whose
  # target already holds the planned bytes is skipped, one whose target still
  # holds the pre-state is applied, anything else refuses. A replay of the same
  # plan therefore finishes exactly the actions that did not land. What was
  # missing was never the recovery - it was SAYING a partial apply happened
  # (_ac_maintenance_hold) and having a verb to run the replay
  # (ac-learn.sh maintenance resume|abandon, off the plan/run recorded here).
  local plan="$1" run="$2" home root run_id subject txn journal lock plan_sha
  local recorded_sha backup idx op target old_sha new_sha staged target_abs
  local source source_abs source_dir skills_root staged_abs actual tmp mode
  local plan_abs run_abs total

  ac_maintenance_plan_validate "$plan" "$run" || return 1
  home="$(ac_home)"
  root="$(ac_state_dir)/.maintenance-transactions"
  mkdir -p "$root"
  run_id="$(jq -r '.run_id' "$plan")"
  subject="$(jq -r '.subject' "$plan")"
  mode="$(jq -r '.mode' "$plan")"
  txn="$root/$run_id-$subject"
  journal="$txn/journal"
  lock="$(ac_state_dir)/.maintenance.lock"
  plan_sha="$(ac_sha256_file "$plan")" || return 1

  if [ -f "$journal" ] && [ "$(ac_meta_get "$journal" status)" = "complete" ]; then
    [ "$(ac_meta_get "$journal" plan_sha256)" = "$plan_sha" ]
    return
  fi

  ac_lock_acquire "$lock" 30 || return 1
  if ! ac_maintenance_plan_validate "$plan" "$run"; then
    ac_lock_release "$lock"
    return 1
  fi

  mkdir -p "$txn"
  recorded_sha="$(ac_meta_get "$journal" plan_sha256)"
  if [ -n "$recorded_sha" ] && [ "$recorded_sha" != "$plan_sha" ]; then
    ac_lock_release "$lock"
    return 1
  fi
  if ac_maintenance_incomplete_other "$root" "$txn"; then
    ac_lock_release "$lock"
    return 1
  fi

  # The plan and its run dir are recorded BEFORE the first mutation: they are
  # what a later `maintenance resume` needs to replay this exact plan, and a
  # crash leaves the journal as the only thing that knows them (cmd_run mints a
  # fresh run_id and cmd_land a fresh txid, so neither can find their way back).
  plan_abs="$(cd "$(dirname "$plan")" && pwd -P)/$(basename "$plan")"
  run_abs="$(cd "$run" && pwd -P)"
  total="$(jq -r '.actions | length' "$plan")"
  ac_meta_set "$journal" plan_sha256 "$plan_sha"
  ac_meta_set "$journal" plan "$plan_abs"
  ac_meta_set "$journal" run "$run_abs"
  ac_meta_set "$journal" actions_total "$total"
  ac_meta_set "$journal" status applying
  backup="$(ac_meta_get "$journal" backup)"
  if [ -z "$backup" ]; then
    if ! backup="$(ac_records_backup "$mode")"; then
      _ac_maintenance_hold "$journal" "$txn" 0 "$total" "the pre-mutation backup could not be taken"
      ac_lock_release "$lock"
      return 1
    fi
    ac_meta_set "$journal" backup "$backup"
  elif [ ! -f "$backup" ]; then
    _ac_maintenance_hold "$journal" "$txn" 0 "$total" "the recorded pre-mutation backup is missing"
    ac_lock_release "$lock"
    return 1
  fi

  # Every failure below leaves the earlier actions committed, so each one exits
  # through _ac_maintenance_hold: the transaction is held (resumable and named)
  # rather than silently half-applied.
  idx=0
  while IFS=$'\t' read -r op target old_sha new_sha staged; do
    target_abs="$home/$target"
    staged_abs="$run/$staged"
    if [ -f "$target_abs" ] && [ ! -L "$target_abs" ]; then
      actual="$(ac_sha256_file "$target_abs")" || {
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "target $target could not be hashed"
        ac_lock_release "$lock"
        return 1
      }
    elif [ ! -e "$target_abs" ]; then
      actual="-"
    else
      _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "target $target is not a plain file"
      ac_lock_release "$lock"
      return 1
    fi

    if [ "$actual" != "$new_sha" ]; then
      [ "$actual" = "$old_sha" ] || {
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "target $target no longer matches the state the plan was staged against"
        ac_lock_release "$lock"
        return 1
      }
      if ! mkdir -p "$(dirname "$target_abs")"; then
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "the directory for $target could not be created"
        ac_lock_release "$lock"
        return 1
      fi
      if ! ac_maintenance_path_plain "$home" "$target"; then
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "a path component of $target is a symlink"
        ac_lock_release "$lock"
        return 1
      fi
      tmp="$target_abs.maintenance.$$.$idx"
      if ! cp "$staged_abs" "$tmp"; then
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "the staged bytes for $target could not be copied"
        ac_lock_release "$lock"
        return 1
      fi
      if [ "$(ac_sha256_file "$tmp")" != "$new_sha" ]; then
        rm -f "$tmp"
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "the copied bytes for $target do not match the planned hash"
        ac_lock_release "$lock"
        return 1
      fi
      if ! mv "$tmp" "$target_abs"; then
        rm -f "$tmp"
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "$target could not be replaced atomically"
        ac_lock_release "$lock"
        return 1
      fi
    fi
    if [ "$op" = move-skill ]; then
      source="$(ac_maintenance_move_source "$target")" || {
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "the live source for $target could not be inferred"
        ac_lock_release "$lock"
        return 1
      }
      source_abs="$home/$source"
      if [ -f "$source_abs" ] && [ ! -L "$source_abs" ]; then
        [ "$(ac_sha256_file "$source_abs")" = "$new_sha" ] || {
          _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "live source $source does not match the archived bytes"
          ac_lock_release "$lock"
          return 1
        }
        if ! rm "$source_abs"; then
          _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "live source $source could not be removed"
          ac_lock_release "$lock"
          return 1
        fi
      elif [ -e "$source_abs" ] || [ -L "$source_abs" ]; then
        _ac_maintenance_hold "$journal" "$txn" "$idx" "$total" "live source $source is not a plain file"
        ac_lock_release "$lock"
        return 1
      fi
      # Remove only now-empty directories below the live skills root. A failed
      # rmdir means another file remains and is intentionally preserved.
      skills_root="$home/skills"
      source_dir="$(dirname "$source_abs")"
      while [ "$source_dir" != "$skills_root" ]; do
        rmdir "$source_dir" 2>/dev/null || break
        source_dir="$(dirname "$source_dir")"
      done
    fi
    ac_meta_set "$journal" "action_$idx" complete
    idx=$((idx + 1))
  done < <(jq -r '.actions[] | [.op,.target,.old_sha256,.new_sha256,.staged] | @tsv' "$plan")

  ac_meta_set "$journal" status complete
  ac_lock_release "$lock"
}

