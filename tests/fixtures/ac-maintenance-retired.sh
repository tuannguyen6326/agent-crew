#!/usr/bin/env bash
# ac-maintenance-retired.sh - the bash Learning/Curate cadence writers and the
# shared maintenance transaction, frozen verbatim when their last bash caller
# was ported (src/learn.ts) and they were retired from bin/ac-maintenance-lib.sh
# and bin/ac-lib.sh. Not sourced by anything live. A differential leg appends it
# to its oracle's own ac-maintenance-lib.sh copy, so the frozen entries that
# call these helpers (tests/fixtures/ac-learn.sh, ac-curate.sh, ac-gate.sh,
# ac-deputy.sh, ac-domain.sh) keep running the code they were frozen with; a
# tests/ts or tests/sh pin that holds a TypeScript twin to its bash original
# sources it after the live libs (bin/ac-bun.sh first, for the three helpers
# that start src/maintenance-receipt.ts). The live readers that stayed -
# ac_learn_meta, ac_learn_due, ac_curate_meta, ac_curate_due,
# ac_maintenance_incomplete, AC_MAINTENANCE_QUOTE_MIN - are the live lib's;
# their twins and the writers' are src/lib.ts's.
command -v ac_bun_exec >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"

# The skills-consolidate archive (ac-curate.sh) is a reserved subdir INSIDE the
# fleet store: a MOVE target for retired prefix-cluster siblings, never a skill.
# One source of truth for the name so the seed loop (ac_seed_crew_skills, class 2)
# and the curator agree - a mismatch would re-seed archived skills. It rides
# under skills/, so ac_records_backup already tars it (no extra backup wiring).
ac_skills_archive_dir() { printf '%s\n' "$(ac_skills_dir)/$AC_SKILLS_ARCHIVE_BASENAME"; }

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
  local lock
  lock="$(ac_state_dir)/.learn-cadence.lock"
  # Loud in ac_learn_tick_keyed's shape/register (F19): a silent failure here
  # read as a successful tick. Missing a tick only delays the
  # next distill (the LEVEL trigger still fires); it costs latency, never
  # correctness - but only if the reader is TOLD, instead of believing the
  # counter moved when it did not.
  ac_lock_acquire "$lock" 10 || {
    ac_warn "learning tick: cadence lock $lock could not be acquired within 10s - the debrief counter was NOT advanced. Missing a tick only delays the next distill (the LEVEL trigger still fires); it never loses a landing outright, but a caller that assumes success will believe the counter moved when it did not."
    return 1
  }
  ac_learn_count_one
  ac_lock_release "$lock"
}

ac_learn_count_one() {
  # ac_learn_count_one - the counter's +1 itself, for a caller that already
  # holds the cadence lock (the mkdir lock is not re-entrant).
  local f cur gen
  f="$(ac_learn_meta)"
  ac_learn_migrate "$f"
  cur="$(ac_meta_get "$f" debriefs)"
  gen="$(ac_meta_get "$f" generation)"
  case "$cur" in '' | *[!0-9]*) cur=0 ;; esac
  case "$gen" in '' | *[!0-9]*) gen=0 ;; esac
  ac_meta_set "$f" generation "$gen"
  ac_meta_set "$f" debriefs "$((cur + 1))"
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

ac_learn_tick_keyed() {
  # ac_learn_tick_keyed <key> - claim the ONE tick a landing is owed and count
  # it. Exit 0 when the claim was fresh and the counter advanced, 1 when <key>
  # is already stamped inside the dedupe window (nothing counted).
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
  # and double-counts later. The count happens under the SAME hold as the
  # stamp (ac_learn_count_one): released in between, another holder could keep
  # the lock past the count's timeout, leaving the landing stamped as counted
  # with the counter unmoved - and every re-run then skipped it. The stamp
  # goes first, so a count that fails after it under-counts, the recoverable
  # direction.
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
  # `in`, never ==: awk compares numeric-looking keys as numbers (07 == 7).
  if [ -f "$f" ] && awk -F'\t' -v now="$now" -v k="$key" -v win="$win" \
    'BEGIN { w[k] } ($2 in w) && now - $1 < win { hit = 1 } END { if (!hit) exit 1 }' "$f"; then
    ac_lock_release "$lock"
    return 1
  fi
  tmp="$f.tmp.$$"
  {
    [ ! -f "$f" ] || awk -F'\t' -v now="$now" -v win="$win" 'now - $1 < win' "$f"
    printf '%s\t%s\n' "$now" "$key"
  } >"$tmp"
  mv "$tmp" "$f" || rc=1
  [ "$rc" != 0 ] || ac_learn_count_one
  ac_lock_release "$lock"
  return "$rc"
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
  # the skills store) to state/backups/<prefix>-<epoch>[-<n>].tar.gz, and print its
  # path. The shared body of the layer-3 reversibility floor (Q8: no git,
  # tracked by backups): ac_learn_backup passes `learn`, the records
  # CURATE pass (ac-curate.sh) passes `curate`, so a backup's provenance is
  # legible from its name and a bad land OR curate is undone by restoring its
  # archive. The archive lives in a DEDICATED backups/ subdir, never loose in
  # state/ - a loose file there would read as a phantom crewmate against the
  # state/*.meta glob (the Slice 2 namespace lesson). records/ and skills/ are
  # resolved (and created) first so the tar always has both members even on a
  # fresh home; paths are stored relative to the home so a restore is
  # `tar -xzf <arc> -C <home>`.
  local prefix="$1" home bdir arc now n=0
  local -a members
  home="$(ac_home)"
  ac_records_dir >/dev/null   # ensure records/ exists
  ac_skills_dir >/dev/null    # ensure skills/ exists
  bdir="$(ac_state_dir)/backups"
  mkdir -p "$bdir"
  # NEVER-CLOBBER: the name is claimed with noclobber's exclusive create before
  # tar writes it, because tar -czf truncates whatever already holds the name and
  # two backups inside one second share an epoch - the earlier transaction's
  # pre-mutation archive would then hold the later one's pre-state instead. A
  # failed tar drops its claim and fails, so no empty archive passes for a floor.
  now="$(ac_now)"
  arc="$bdir/$prefix-$now.tar.gz"
  until (set -C; : >"$arc") 2>/dev/null; do
    [ -e "$arc" ] || {
      ac_warn "records backup: could not create $arc (is $bdir writable?) - no backup archive was taken"
      return 1
    }
    n=$((n + 1))
    arc="$bdir/$prefix-$now-$n.tar.gz"
  done
  members=(records skills)
  # Crewdomain packages hold mutable truth too - the projects detail file and
  # the CREWMATE layer (no ledger since the crewdomain-token refactor: rows
  # live in the fleet backlog.md, already inside the floor) - and they live
  # OUTSIDE records/, so without this they would sit outside the floor. Extending the one shared function is what
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
    # prose but loses which projects the domain may work. It
    # rides as LINKS - the tar must never gain -h - so no clone content follows.
    [ ! -d "$(dirname "$pkgrec")/projects" ] \
      || members+=("crewdomains/$pkgname/projects")
  done
  [ ! -f "$home/state/.learn.meta" ] || members+=(state/.learn.meta)
  [ ! -f "$home/state/.curate.meta" ] || members+=(state/.curate.meta)
  # The machine-owned crewmate lesson layer is mutable truth a learning
  # transaction rewrites - same reversibility floor as records/ and skills/.
  [ ! -f "$home/CREWMATE-learned.md" ] || members+=(CREWMATE-learned.md)
  tar -czf "$arc" -C "$home" "${members[@]}" || { rm -f "$arc"; return 1; }
  printf '%s\n' "$arc"
}

ac_learn_backup() {
  # ac_learn_backup - the DISTILL run's pre-run backup: ac_records_backup with
  # the `learn` prefix (state/backups/learn-<epoch>[-<n>].tar.gz). Shares its body
  # with the CURATE pass's backup - see ac_records_backup.
  ac_records_backup learn
}

ac_learn_reset() {
  # ac_learn_reset - the RESET Slice 2 deferred to here: zero the per-debrief
  # counter and stamp last_run=<epoch>. Primary caller: the END of a SUCCESSFUL
  # DISTILL run (src/learn.ts cmdRun) - the run is the examination the counter
  # counts, so a run that proposes nothing still consumes its cycle. `land` calls
  # it too, which now usually re-does what the run just did but still covers a
  # manual land with no run in between. Never at tick. Extends the same
  # state/.learn.meta primitive; ac_learn_due keeps reading `debriefs` unchanged.
  # last_run is ALSO the retro window anchor (src/learn.ts retroSnapshot),
  # so every caller must have read the anchor it needs BEFORE calling this.
  #
  # It deliberately does NOT prune the landing stamps (ac_learn_tick_keyed). A
  # distill run completes ASYNCHRONOUSLY to any landing, so a reset can fall
  # BETWEEN a landing's two actors; dropping the stamp there would let the second
  # actor advance the fresh cycle - the double-advance the stamps exist to stop,
  # re-opened exactly at the cycle boundary. Their own 24h expiry bounds the file.
  local f expected="${1:-}" current lock
  f="$(ac_learn_meta)"
  lock="$(ac_state_dir)/.learn-cadence.lock"
  ac_lock_acquire "$lock" 10 || {
    ac_warn "learning reset: cadence lock $lock could not be acquired within 10s - the debrief counter was NOT reset and its generation did NOT advance, so a due DISTILL cycle stays due. This is a lock failure, not a newer cadence generation."
    return 1
  }
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

ac_curate_tick() {
  # ac_curate_tick - advance the per-learning-run counter by one (absent/garbage
  # => 0). Called ONCE per learning-run, from src/learn.ts cmdRun (the distill
  # run is the tick, report §2.4).
  local f cur gen lock
  f="$(ac_curate_meta)"
  lock="$(ac_state_dir)/.curate-cadence.lock"
  ac_lock_acquire "$lock" 10 || {
    ac_warn "curate tick: cadence lock $lock could not be acquired within 10s - the learning-run counter was NOT advanced. Missing a tick only delays the next Curate pass, but a caller that assumes success will believe the counter moved when it did not."
    return 1
  }
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

ac_curate_reset() {
  # ac_curate_reset - zero the per-learning-run counter and stamp
  # last_run=<epoch>. Fires only at a completed CURATE pass (ac-curate.sh run),
  # the analogue of ac_learn_reset. ac_curate_due keeps reading `runs_since`.
  local f expected="${1:-}" current lock
  f="$(ac_curate_meta)"
  lock="$(ac_state_dir)/.curate-cadence.lock"
  ac_lock_acquire "$lock" 10 || {
    ac_warn "curate reset: cadence lock $lock could not be acquired within 10s - the learning-run counter was NOT reset and its generation did NOT advance, so a due Curate pass stays due. This is a lock failure, not a newer cadence generation."
    return 1
  }
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

  # Slurped, because `jq -e` judges only the LAST output of a stream while every
  # loop below and in apply walks the actions of every document in the file.
  # \A...\z, never ^...$: jq's $ also matches before a final newline, and a
  # value let through with one reaches the @tsv loops below as another file.
  jq -e -s 'length == 1 and (.[0] |
    type == "object"
    and keys == ["actions","input_manifest_sha256","mode","run_id","schema","subject"]
    and .schema == "agentcrew.maintenance-plan/v1"
    and (.mode == "learning" or .mode == "curate")
    and (.run_id | type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z"))
    and (.subject | type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z"))
    and (.input_manifest_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))
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
        and test("\\A[A-Za-z0-9._/-]+\\z")
        and (test("(^|/)\\.\\.?(/|$)") | not)
        and (startswith("/") | not))
      and (.staged | type == "string"
        and test("\\Astaged/[A-Za-z0-9._/-]+\\z")
        and (test("(^|/)\\.\\.?(/|$)") | not))
      and (.old_sha256 | type == "string"
        and (. == "-" or test("\\A[0-9a-f]{64}\\z")))
      and (.new_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))
    ))
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

ac_maintenance_evidence_value() {
  # ac_maintenance_evidence_value <label> - stdin = the receipt, or the raw judge
  # body before it becomes one. Print the trimmed value of the one
  # `- <label>: <value>` line inside `## Inputs Read`; return 1 unless exactly
  # one such line exists there. Spec: src/maintenance-receipt.ts evidence-value.
  ( ac_bun_exec src/maintenance-receipt.ts evidence-value "$1" )
}

ac_maintenance_read_evidence() {
  # ac_maintenance_read_evidence <manifest> <plan.json> - stdin = the receipt, or
  # the raw judge body before it becomes one. 0 when `## Inputs Read` proves the
  # judge opened the manifest, the plan, and the bytes the cited action writes.
  # The receipt boundary below gets the check from this one definition, and
  # the gate's write-time check is the same module's readEvidence, imported by
  # src/gate.ts (the frozen gate at tests/fixtures/ac-gate.sh calls this
  # wrapper). Spec: src/maintenance-receipt.ts read-evidence.
  ( ac_bun_exec src/maintenance-receipt.ts read-evidence "$1" "$2" "$AC_MAINTENANCE_QUOTE_MIN" )
}

ac_maintenance_receipt_validate() {
  # ac_maintenance_receipt_validate <receipt.md> <plan.json> <manifest>
  # Print the validated decision. This is the authorization boundary shared by
  # Learning and Curate; an `approved:` candidate header never reaches it. The
  # plan's closed schema is checked here; every receipt rule, read-evidence
  # included, is src/maintenance-receipt.ts receipt-check.
  local receipt="$1" plan="$2" manifest="$3" run
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ -f "$manifest" ] \
    && [ ! -L "$manifest" ] || return 1
  run="$(cd "$(dirname "$plan")" 2>/dev/null && pwd -P)" || return 1
  [ "$(basename "$run")" != plans ] || run="$(cd "$run/.." && pwd -P)"
  ac_maintenance_plan_validate "$plan" "$run" || return 1
  ( ac_bun_exec src/maintenance-receipt.ts receipt-check "$receipt" "$plan" "$manifest" \
    "$AC_MAINTENANCE_QUOTE_MIN" )
}

ac_maintenance_gate_failure_reason() {
  # ac_maintenance_gate_failure_reason <gate-exit-code> - the ONE place both
  # maintenance callers turn bin/ac-gate.sh's own documented maintenance exit
  # codes (src/gate.ts's header: 0 receipt written, 3 the engine/judge ran but produced
  # no usable decision - failure, invalid response, timeout, or a declared
  # environment-error, all folded into one code by the gate itself, never
  # split here by guessing at its prose, 4 config/gate-agent=off, anything
  # else a usage/input error before the engine ever ran) into the one
  # captain-facing category each demands. Exit code only, never grounds text.
  case "$1" in
    4) printf 'The maintenance gate is disabled (config/gate-agent=off).\n' ;;
    3) printf 'The maintenance gate ran but produced no usable decision (an engine failure, an invalid response, a timeout, or a declared environment-error).\n' ;;
    *) printf 'The maintenance gate rejected its own invocation before it could run (usage or input error, exit %s).\n' "$1" ;;
  esac
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
    recorded_sha="$(ac_meta_get "$journal" plan_sha256)"
    [ "$recorded_sha" != "$plan_sha" ] || return 0
    ac_warn "maintenance apply: transaction $run_id-$subject already completed a different plan (plan_sha256 $recorded_sha, this one $plan_sha), so this plan was not applied. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt."
    return 1
  fi

  ac_lock_acquire "$lock" 30 || {
    ac_warn "maintenance apply: writer lock $lock could not be acquired within 30s - another Learning/Curate transaction holds it, so $run_id-$subject was neither claimed nor written. This is a busy lock, not a stale receipt or a refused plan."
    return 1
  }
  if ! ac_maintenance_plan_validate "$plan" "$run"; then
    ac_lock_release "$lock"
    return 1
  fi

  mkdir -p "$txn"
  recorded_sha="$(ac_meta_get "$journal" plan_sha256)"
  if [ -n "$recorded_sha" ] && [ "$recorded_sha" != "$plan_sha" ]; then
    ac_warn "maintenance apply: transaction $run_id-$subject already recorded a different plan (plan_sha256 $recorded_sha, this one $plan_sha), so this plan was neither claimed nor written. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt."
    ac_lock_release "$lock"
    return 1
  fi
  if ac_maintenance_incomplete_other "$root" "$txn"; then
    ac_warn "maintenance apply: another Learning/Curate transaction is still unsettled, so $run_id-$subject was neither claimed nor written. This is another transaction's claim, not a stale receipt or a refused plan - bin/ac-learn.sh maintenance status names it, and resume or abandon settles it."
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
