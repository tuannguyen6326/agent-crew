#!/usr/bin/env bash
# ac-maintenance-lib.sh - the Learning/Curate cadence readers and the
# maintenance-transaction status reader, split out of ac-lib.sh (audit-f3,
# codebase-audit-2026-07-29 finding 3). Not an entrypoint; sourced after
# ac-lib.sh by any script that needs it - ac-lib.sh does NOT source this file
# (the CALLER sources both).
#
# Owns the PURE readers bin/ac-session-start.sh prints from: the DISTILL
# cadence (ac_learn_meta / ac_learn_due), the records-wide CURATE cadence
# (ac_curate_meta / ac_curate_due), the unsettled-transaction list
# (ac_maintenance_incomplete), and AC_MAINTENANCE_QUOTE_MIN with the
# READ-EVIDENCE rationale behind it. The writers - the counters' ticks and
# resets, the pre-run backup, and the shared Learning/Curate maintenance
# transaction with its plan and receipt validation - run in TypeScript
# (src/lib.ts `// --- learn twins ---` and `// --- curate twins ---`,
# src/maintenance-receipt.ts receiptValidate), called by src/learn.ts and
# src/curate.ts; their bash originals are frozen at
# tests/fixtures/ac-maintenance-retired.sh for the oracles that still run them.
#
# LAYERING: depends only on ac-lib.sh core (ac_state_dir, ac_meta_get,
# ac_config_read). Never depended on by another sub-lib.

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
# from the watcher, fleet-view pollution). Two writers, both in
# src/lib.ts: learnTick advances the counter, and learnReset zeroes it at the
# END of a successful DISTILL run (src/learn.ts cmdRun, and still at a manual
# land) - never at tick.
# The level this counter reaches is what fires the ACT: ac-learn.sh autoroom
# opens the cap-exempt learning room off it at the next fleet drain.
#
# Key history: the counter key was `stows` until the skill rename (stow ->
# debrief, 2026-07-18). Live fleets carry .learn.meta files with the old key,
# so the WRITERS migrate on first touch (learnMigrate) and the pure reader
# falls back to the legacy key - a fleet that never ticks again still reports
# its true count.


ac_learn_meta() { printf '%s/.learn.meta\n' "$(ac_state_dir)"; }

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

# --- records-wide CURATE interval gate (Slice 4) ------------------------------
# The cadence gate for the CURATE pass - the exact analogue of the DISTILL
# trigger above, one rung up. The knowledge-producing event it counts is a
# LEARNING-RUN (the DISTILL run is the fleet's "tick", report §2.4), not a
# debrief, so curateTick (src/lib.ts) is wired into src/learn.ts cmdRun (once
# per run), not into the debrief path. Durable on disk, so a restart reads the true count.
#
# The counter lives at state/.curate.meta - DOT-PREFIXED (the Slice 2 namespace
# lesson) so it stays OUTSIDE the state/*.meta task-meta namespace; a bare
# curate.meta reads as a phantom crewmate (WATCHER-DOWN, a spurious gone: wake,
# fleet-view pollution). ac_curate_due stays PURE - the session-start
# digest reads it read-only; only curateTick/curateReset (src/lib.ts) write.

ac_curate_meta() { printf '%s/.curate.meta\n' "$(ac_state_dir)"; }

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

# --- the shared Learning / Curate maintenance transaction ---------------------
# Learning and Curate mutate fleet-local knowledge automatically only through
# one closed, hash-bound plan, applied by maintenanceApply (src/lib.ts): one
# fleet-wide writer lock, a pre-mutation backup, an action journal, atomic file
# replacement, and resume by hash. What stays here is the reader that names an
# unsettled transaction, which session start prints.

ac_maintenance_incomplete() {
  # ac_maintenance_incomplete <transactions-root> - print one line per UNSETTLED
  # transaction: `<txid>\t<status>\t<actions-committed>\t<plan-or-'-'>`. Silent
  # when the loop is clean, so a digest can print a header only when there is a
  # signal. PURE: reads only.
  #
  # This exists because an unsettled transaction is INVISIBLE otherwise while
  # refusing every other one (maintenanceApply refuses its claim while one is):
  # the next Learning run warns about a stale continue receipt, Curate dies,
  # and neither names the transaction actually holding the claim.
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

# --- READ-EVIDENCE: the judge must prove it OPENED the inputs -----------------
# The gate prompt inlines no candidate content - it hands the judge two absolute
# paths and the two SHA-256 values the receipt is later checked against - so a
# judge that never opened either file can echo those hashes back and mint a
# valid authorization over Learning's and Curate's own mutations. The counter-
# check is the falsifiable property that already costs nothing: content of the
# inputs that the prompt never carried is something only a reader has.
#
# The inputs are different in kind, so the proof each can carry is too. The
# manifest is free-form candidate evidence, and the only thing a reader of it
# provably holds is a VERBATIM excerpt. The action plan is generated JSON whose
# every header field is prompt-supplied - only `.actions` is not - and its
# `new_sha256` values are the exact bytes the plan authorizes to be written:
# unguessable, unambiguous to copy, and an exact set membership to check, with
# no length heuristic an honest engine could fail. A heuristic that rejects an
# honest judge would switch the maintenance loop off silently, which is worse
# than the hole it replaces, so each side takes the strictest EXACT check it can
# bear rather than one uniform approximate one. The action hash is the lock that
# cannot be forged; the quote is the second one, and it is tuned to never reject
# an honest reader rather than to carry the proof alone.
#
# THE ACTION HASH PROVES THE PLAN WAS OPENED, NEVER THE PAYLOAD. The caller is
# the side that hashes `<run>/staged/<...>`: the plan validation
# (maintenancePlanValidate, src/lib.ts) reads every staged file and compares it
# to the `new_sha256` the plan carries,
# BEFORE any pane opens. So a `new_sha256` copied straight out of plan.json is
# free to a judge that never read one byte of what `apply` will write - and a
# payload-blind `continue` authorizes a real mutation of the ledger, the
# crewmate layer, captain.md or a skill, not merely a burnt retro window. The
# third proof closes that: a verbatim line of the staged file BELONGING TO THE
# ACTION WHOSE HASH WAS CITED. What the binding buys is exactly that the hash and
# the bytes speak for the SAME action - an unbound quote would let a judge cite
# action A's hash and quote action B's payload, and then neither proof covers
# either action whole. What it does NOT buy, and this is the residual rather than
# an oversight: the judge still chooses WHICH action to speak for, so a plan's
# other payloads are proved only transitively. Proving every action instead would
# mean one quote per action, and a move-skill plan stages one action per file of
# a package - a judge that must find a qualifying line in each of a dozen copied
# files is precisely the honest judge this block refuses to reject.
#
# THE FLOOR HAS TO SIT INSIDE A MEASURED WINDOW, which is the whole reason it is
# 12 and not a rounder number. Above it: what a prompt-supplied value leaves
# behind once deleted is its bare key, and the longest of those is `subject` at
# 7 significant characters. Below it: the shortest genuine content line a
# generated manifest emits, measured across the real ones - a curate subject
# manifest's `"path": "projects/<name>",` at 13 for a one-character name, 15 for
# `projects/lab`, 21 for `records/projects.md`. A floor of 24 sat above that
# lower edge and rejected the very lines the prompt tells the judge to pick.
#
# THE FLOOR THAT PAYLOAD CAN BEAR IS NOT ALWAYS 12, and that is measured, not
# cautious. Every payload a producer COMPOSES bears the full 12 - measured over
# the write-skill, rewrite-ledger, append-archive, rewrite-crewmate-learned and
# rewrite-registry payloads a real land emits, and over every file of every
# package in this fleet's skills store. Their tightest LINES are `  origin:
# learned` at 13 and `# Learning Ledger` at 14, with the archive entry's
# `gate: data/<txid>/gates/<subject>/decision.md` at 23 and the crewmate layer's
# header comment at 63 far above, so 12 sits just under that lower edge exactly
# as it does under the manifest's. But the payload set is OPEN: a move-skill
# action stages a VERBATIM COPY of whatever files a skill package holds
# (src/curate.ts prepareSkill's `find -type f` walk), and this store's own root
# already carries a file measuring 0; a curate registry rewrite that drops the
# last row stages an empty one. A fixed floor would refuse EVERY honest judge of
# those actions - the silent switch-off in its most literal form - so the floor
# is what THIS payload can bear: AC_MAINTENANCE_QUOTE_MIN, or its own best line
# when that is less. The ceiling is derived from the staged bytes themselves, so
# the gate still infers nothing from the judge. The outright WAIVER, for a
# payload holding no significant line at all, is keyed on the whole PLAN and not
# on the cited action: the judge picks what it cites, so a per-action waiver
# would hand it a lever - cite the one contentless file and the proof vanishes
# for every other action in the plan. Waived only when no action could have
# carried it, which is a fact about what the caller staged.
AC_MAINTENANCE_QUOTE_MIN=12
