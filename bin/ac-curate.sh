#!/usr/bin/env bash
# ac-curate.sh - fleet-local Curate maintenance.
#
# Usage:
#   ac-curate.sh learnings              # pointer-integrity check (PROPOSE ONLY)
#   ac-curate.sh captain [--apply]      # compatibility targeted mutation
#   ac-curate.sh backlog [--apply]      # compatibility targeted mutation
#   ac-curate.sh projects               # correctness-audit (PROPOSE ONLY)
#   ac-curate.sh skills-audit           # skill overlap + stale (PROPOSE ONLY)
#   ac-curate.sh skills-consolidate [--apply]  # diagnostic; --apply refuses
#   ac-curate.sh run [--dry-run]        # automatic policy + gated maintenance
#
# Learning runs advance Curate's lock-protected generation/cadence. When
# `runs_since >= config/curate-every` (default 5), `ac-learn.sh run` calls this
# automatic `run`. There is no cron or daemon.
#
# Automatic `run` separates deterministic maintenance from semantic judgment:
#
# - captain.md: move only fully `SUPERSEDED` or non-standing
#   `COMPLETED`/`EXPIRED` blocks verbatim to captain-archive.md. Preserve one
#   stable archive link in captain.md. Live, standing, and partial rules remain.
# - backlog.md: retain the configured recent Done window and move older lines
#   verbatim to backlog-archive.md, while preserving live blocked-by and epic
#   dependencies.
# - a live `SUPERSEDES` ruling with one safely identifiable complete target,
#   an absent project registry entry, and a traceable umbrella-skill
#   consolidation become independent semantic subjects. A hash-bound
#   maintenance-gate `continue` applies each recoverable plan; `revise`
#   preserves it; ambiguity asks the captain.
# - a semantic subject with NO safe plan asks the captain and keeps cadence due
#   for ever, UNLESS `records/curate-acknowledged.md` records that the captain
#   already ruled on that exact material:
#   `- <subject> material=<sha256> ruling: <citation>`. Field 3 is the KEY and
#   the leading subject id is documentation only. The key is a sha256 over the
#   subject's OWN material - a captain subject's live and target rule BLOCKS in
#   full, a project subject's registry line, a skill subject's umbrella plus
#   body - never the index-derived subject id, which shifts whenever an earlier
#   captain.md block is added or removed, and never the containing file, whose
#   unrelated edits would otherwise wipe every acknowledgement. An acknowledged
#   subject prints `settled:` with its ruling, mutates nothing, and lets the run
#   reset cadence; edit that material and the same subject asks again. The ask
#   prints the paste-ready line, fingerprint included; deleting the line undoes
#   the acknowledgement. It can never hide a subject that became ACTIONABLE:
#   one with a safe plan goes to the maintenance gate and never reaches here.
# - learning-pointer defects and stale/overlap signals remain non-mutating
#   findings until a safe semantic plan exists.
#
# Automatic changes are first produced in a shadow home, converted into one
# closed action plan, bound to a deterministic policy receipt, and applied by
# the shared fleet maintenance transaction. That boundary owns the fleet-wide
# lock, pre-write backup, staged hashes (pre-state hashes bound to the
# pre-pass snapshot, so a write landing mid-run is refused rather than
# reverted), atomic replacement, crash journal, and idempotent replay.
# `move-skill` copies and verifies every staged file before removing its live
# source, while the active/archive pointer ledgers participate
# in the same plan. The captured Curate generation resets only after every
# subject settles; an unresolved `ask-captain` keeps the run open and cadence
# due. `run --dry-run` creates no backup, receipt, mutation, or cadence reset.
#
# `learnings` validates canonical `[distilled -> <name>]` pointers against the
# fleet-local skill and archive. Any remaining @fleet/@container pointer is a
# compatibility defect the chief resolves by hand (the one-time `ac-learn.sh
# migrate` ran on every home and is retired); Curate never reads the legacy
# container skill store.
#
# Individual `captain --apply` and `backlog --apply` remain compatibility
# surfaces and take their own backup. `skills-consolidate --apply` is
# deliberately refused because it cannot bypass semantic review or pointer
# integrity. Individual verbs do not reset cadence.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-maintenance-lib.sh"

# --- learnings: pointer-integrity check (PROPOSE ONLY) -----------------------

curate_learnings() {
  local learnings name target broken=0 compatibility=0
  learnings="$(ac_records_dir)/learnings.md"
  printf '== learnings: pointer-integrity check (propose-only; CURATE never compacts) ==\n'
  if [ ! -f "$learnings" ]; then
    printf '  (no learnings.md - nothing to check)\n'
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    target="$(ac_skills_dir)/$name/SKILL.md"
    if [ ! -f "$target" ]; then
      printf '  BROKEN: [distilled -> %s] - fleet-local skill store vanished (missing %s)\n' "$name" "$target"
      broken=$((broken + 1))
    fi
  done < <(grep -oE '\[distilled -> [a-z0-9-]+\]' "$learnings" \
    | sed -E 's/\[distilled -> ([a-z0-9-]+)\]/\1/' | sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '  COMPATIBILITY DEFECT: %s - rung-qualified pointer remains; the migrate command is retired, so rewrite the pointer to the canonical fleet-local form by hand\n' "$name"
    compatibility=$((compatibility + 1))
  done < <(grep -oE '\[distilled -> [a-z0-9-]+ @(fleet|container)\]' "$learnings" || true)
  if [ "$broken" -eq 0 ] && [ "$compatibility" -eq 0 ]; then
    printf '  ok: all distilled pointers resolve\n'
  else
    printf '  %s broken canonical pointer(s), %s migration compatibility defect(s); propose-only\n' \
      "$broken" "$compatibility"
  fi
  return 0
}

# --- captain: consolidate-supersede + expire (AUTO-tier, move-only) ----------

_captain_plan() {
  # _captain_plan <captain.md> - classify each rule BLOCK (a `- ` line plus its
  # indented continuations) and emit one TSV `start<TAB>end<TAB>class<TAB>reason`
  # per block that is a move candidate OR an informational note (kept blocks
  # emit nothing). class in: move-superseded | move-expired | note. Detection is
  # UPPERCASE-marker only and CONSERVATIVE - a `SUPERSEDES` ruling and any
  # partial/standing marker are KEPT.
  awk '
    function flush(   cls, reason) {
      if (bstart == 0) return
      cls = ""; reason = ""
      if (blocktext ~ /SUPERSEDES/) {
        cls = "note"; reason = "declares SUPERSEDES a named earlier rule - live ruling KEPT (retire its dead target manually if fully superseded)"
      } else if (blocktext ~ /SUPERSEDED/) {
        if (tolower(blocktext) ~ /holds/) {
          cls = "note"; reason = "partial supersession (self-marked SUPERSEDED, the rest holds) - NOT auto-moved"
        } else {
          cls = "move-superseded"; reason = "fully-superseded rule (self-marked SUPERSEDED, no partial qualifier)"
        }
      } else if (blocktext ~ /COMPLETED/ || blocktext ~ /EXPIRED/) {
        if (blocktext ~ /STANDING/) {
          cls = "note"; reason = "STANDING rule marked COMPLETED/EXPIRED - NOT auto-moved (a standing rule never expires)"
        } else {
          cls = "move-expired"; reason = "completed one-time order (marked COMPLETED/EXPIRED)"
        }
      }
      if (cls != "") printf "%d\t%d\t%s\t%s\n", bstart, bend, cls, reason
      bstart = 0; blocktext = ""
    }
    /^- / { flush(); bstart = NR; bend = NR; blocktext = $0; next }
    bstart > 0 && /^[ \t]/ { bend = NR; blocktext = blocktext "\n" $0; next }
    { flush() }
    END { flush() }
  ' "$1"
}

curate_captain() {
  local apply="$1" pre_backed="$2"
  local captain archive plan datestr start end cls reason movecount=0
  captain="$(ac_records_dir)/captain.md"
  archive="$(ac_records_dir)/captain-archive.md"
  printf '== captain: consolidate-supersede + expire (AUTO-tier, verbatim move-only) ==\n'
  if [ ! -f "$captain" ]; then
    printf '  (no captain.md - nothing to curate)\n'
    return 0
  fi
  plan="$(_captain_plan "$captain")"
  if [ -z "$plan" ]; then
    printf '  ok: no retirement markers found - nothing to consolidate or expire\n'
    return 0
  fi
  while IFS=$'\t' read -r start end cls reason; do
    [ -n "$start" ] || continue
    printf -- '  --- [%s] captain.md lines %s-%s: %s\n' "$cls" "$start" "$end" "$reason"
    sed -n "${start},${end}p" "$captain" | sed 's/^/    | /'
    case "$cls" in move-*) movecount=$((movecount + 1)) ;; esac
  done <<<"$plan"

  if [ "$apply" != 1 ]; then
    printf '  PROPOSE-ONLY: %s block(s) would move to %s on --apply (notes are informational, never moved)\n' "$movecount" "$archive"
    return 0
  fi
  if [ "$movecount" -eq 0 ]; then
    printf '  --apply: nothing to move (only informational supersede-chain notes)\n'
    return 0
  fi

  # MUTATION path - backup first (unless `run` already took one this pass).
  [ "$pre_backed" = 1 ] || printf '  pre-run backup: %s\n' "$(ac_records_backup curate)"
  datestr="$(ac_iso)"
  [ -f "$archive" ] || printf '# captain-archive - retired captain.md rules (moved by ac-curate.sh, never deleted)\n' >"$archive"

  # Append each moved block VERBATIM under a dated note, reading from the still-
  # intact captain.md; then drop those lines (survivors byte-identical).
  local movetmp droptmp ctmp label note
  movetmp="$(mktemp "${TMPDIR:-/tmp}/ac-curate-cap.XXXXXX")"
  printf '%s\n' "$plan" | awk -F'\t' '$3 ~ /^move-/' >"$movetmp"
  while IFS=$'\t' read -r start end cls reason; do
    [ -n "$start" ] || continue
    case "$cls" in
      move-superseded) label="superseded"; note="superseded-by: self-marked in the retired rule" ;;
      *)               label="expired";    note="completed: retired one-time order" ;;
    esac
    {
      printf '\n## curated %s - %s\n' "$datestr" "$label"
      printf '%s\n' "$note"
      sed -n "${start},${end}p" "$captain"
    } >>"$archive"
  done <"$movetmp"

  droptmp="$(mktemp "${TMPDIR:-/tmp}/ac-curate-drop.XXXXXX")"
  awk -F'\t' '{ for (i = $1; i <= $2; i++) print i }' "$movetmp" | sort -n -u >"$droptmp"
  ctmp="$captain.tmp.$$"
  awk 'NR==FNR { drop[$1] = 1; next } !(FNR in drop)' "$droptmp" "$captain" >"$ctmp"
  if ! grep -qFx 'Archived rulings: [captain-archive.md](captain-archive.md)' "$ctmp"; then
    [ ! -s "$ctmp" ] || printf '\n' >>"$ctmp"
    printf 'Archived rulings: [captain-archive.md](captain-archive.md)\n' >>"$ctmp"
  fi
  mv "$ctmp" "$captain"
  rm -f "$movetmp" "$droptmp"
  printf '  CURATED: moved %s block(s) to %s (verbatim); survivors byte-identical (receipt + captain veto is the roomchief process)\n' "$movecount" "$archive"
  return 0
}

# --- backlog: archive move-only (keep-N recent Done) -------------------------

_backlog_plan() {
  # _backlog_plan <backlog.md> <keep-N> - emit the line numbers of Done lines to
  # ARCHIVE, ascending, one per line. Blocked-by-safe and epic-safe, keyed on the
  # real reader ac-ready.sh's exact grammar. Empty output = nothing to archive.
  awk -v keep="$2" "$AC_DONELINE_AWK"'
    { line[NR] = $0 }
    /^## In flight/ { sec = "inflight" }
    /^## Queued/    { sec = "queued" }
    /^## Done/      { sec = "done" }
    /^- \[[ x]\] / {
      # Field extraction is the ONE shared Done-line parser (AC_DONELINE_AWK in
      # ac-lib.sh); this walk keeps its own NR/line-number bookkeeping.
      ac_doneline($0, o)
      lineid[NR] = o["id"]; idline[o["id"]] = NR
      lineepic[NR] = o["epic"]
      if (sec == "queued" && o["blockers"] != "") {
        nb = split(o["blockers"], bids, ",")
        for (i = 1; i <= nb; i++) blockerref[bids[i]] = 1
      }
      if (sec == "done") { donecount++; doneorder[donecount] = NR }
    }
    END {
      # Tentative: Done lines beyond the N most-recent (newest-first), minus any
      # a live Queued blocked-by references.
      for (k = 1; k <= donecount; k++) {
        nr = doneorder[k]
        if (k <= keep) continue
        if (lineid[nr] in blockerref) continue
        tent[nr] = 1
      }
      # Epic-safe: un-archive a story whose epic line is NOT itself being
      # archived (epic survives -> its stories survive with it).
      for (nr in tent) {
        ep = lineepic[nr]
        if (ep == "") continue
        epicnr = idline[ep]
        if (epicnr == "" || !(epicnr in tent)) delete tent[nr]
      }
      n = 0
      for (nr in tent) out[++n] = nr + 0
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (out[j] < out[i]) { t = out[i]; out[i] = out[j]; out[j] = t }
      for (i = 1; i <= n; i++) print out[i]
    }
  ' "$1"
}

curate_backlog() {
  local apply="$1" pre_backed="$2" keep="${AC_CURATE_KEEP:-20}"
  local backlog archive plan nmove nr droptmp btmp
  backlog="$(ac_records_dir)/backlog.md"
  archive="$(ac_records_dir)/backlog-archive.md"
  printf '== backlog: archive move-only (keep %s recent Done, blocked-by-safe + epic-safe) ==\n' "$keep"
  if [ ! -f "$backlog" ]; then
    printf '  (no backlog.md - nothing to archive)\n'
    return 0
  fi
  plan="$(_backlog_plan "$backlog" "$keep")"
  if [ -z "$plan" ]; then
    printf '  ok: nothing to archive (<= %s Done, or all older ones are blocker/epic-protected)\n' "$keep"
    return 0
  fi
  nmove="$(printf '%s\n' "$plan" | grep -c .)"
  printf '  candidates to archive: %s Done line(s) older than the %s most-recent\n' "$nmove" "$keep"
  while IFS= read -r nr; do
    [ -n "$nr" ] || continue
    sed -n "${nr}p" "$backlog" | sed 's/^/    move | /'
  done <<<"$plan"

  if [ "$apply" != 1 ]; then
    printf '  PROPOSE-ONLY: %s line(s) would move to %s on --apply\n' "$nmove" "$archive"
    return 0
  fi

  [ "$pre_backed" = 1 ] || printf '  pre-run backup: %s\n' "$(ac_records_backup curate)"
  [ -f "$archive" ] || printf '# Backlog archive - moved Done receipts (byte-identical; ac-ready.sh never reads this)\n\n## Done\n' >"$archive"
  # Append moved lines VERBATIM (from the intact backlog), then drop them.
  while IFS= read -r nr; do
    [ -n "$nr" ] || continue
    sed -n "${nr}p" "$backlog"
  done <<<"$plan" >>"$archive"
  droptmp="$(mktemp "${TMPDIR:-/tmp}/ac-curate-bl.XXXXXX")"
  printf '%s\n' "$plan" | sort -n -u >"$droptmp"
  btmp="$backlog.tmp.$$"
  awk 'NR==FNR { drop[$1] = 1; next } !(FNR in drop)' "$droptmp" "$backlog" >"$btmp"
  mv "$btmp" "$backlog"
  rm -f "$droptmp"
  printf '  CURATED: moved %s Done line(s) to %s (byte-identical); backlog survivors untouched\n' "$nmove" "$archive"
  return 0
}

# --- projects: correctness-audit (PROPOSE ONLY) ------------------------------

curate_projects() {
  local projects proj_dir line name mode pd flags=0
  projects="$(ac_records_dir)/projects.md"
  printf '== projects: correctness-audit (propose-only; deletion stays a captain call) ==\n'
  if [ ! -f "$projects" ]; then
    printf '  (no projects.md - nothing to audit)\n'
    return 0
  fi
  proj_dir="$(ac_projects_dir)"
  while IFS= read -r line; do
    case "$line" in '- '*'['*']'*) ;; *) continue ;; esac
    name="$(printf '%s\n' "$line" | sed -n 's/^- \([^ ]*\) \[.*/\1/p')"
    mode="$(printf '%s\n' "$line" | sed -n 's/^- [^[]*\[\([^]]*\)\].*/\1/p')"
    [ -n "$name" ] || continue
    case "$mode" in
      crew-ship | direct-pr | local-only) ;;
      *) printf '  FLAG %s: unknown delivery mode [%s] (expected crew-ship|direct-pr|local-only)\n' "$name" "$mode"; flags=$((flags + 1)) ;;
    esac
    case "$line" in
      *ASSUMED* | *assumed*) printf '  FLAG %s: delivery mode is ASSUMED - confirm with the captain\n' "$name"; flags=$((flags + 1)) ;;
    esac
    pd="$proj_dir/$name"
    if [ ! -e "$pd" ]; then
      printf '  FLAG %s: registered but projects/%s is absent - dead project? (propose drop; deletion is a captain call)\n' "$name" "$name"
      flags=$((flags + 1))
      continue
    fi
    if [ -L "$pd" ] && [ ! -e "$pd/" ]; then
      printf '  FLAG %s: symlink projects/%s -> %s does not resolve\n' "$name" "$name" "$(readlink "$pd")"
      flags=$((flags + 1))
    fi
    if ! git -C "$pd" rev-parse --git-dir >/dev/null 2>&1; then
      printf '  FLAG %s: projects/%s is not a git repo\n' "$name" "$name"
      flags=$((flags + 1))
    fi
  done <"$projects"
  if [ "$flags" -eq 0 ]; then
    printf '  ok: every registered project line verified against reality (no mismatches)\n'
  else
    printf '  %s mismatch(es) proposed with evidence - NO mutation (projects.md audit is propose-only)\n' "$flags"
  fi
  return 0
}

# --- skills: shared helpers (learned stores + frontmatter reader) ------------

_learned_skill_dirs() {
  # Emit `<skill-dir><TAB>fleet` for every active learned skill. The explicit
  # migration command owns legacy container reads; Curate never merges fleets.
  local d
  for d in "$(ac_skills_dir)"/*; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$AC_SKILLS_ARCHIVE_BASENAME" ] && continue
    [ -f "$d/SKILL.md" ] || continue
    printf '%s\tfleet\n' "$d"
  done
}

_skill_field() {
  # _skill_field <SKILL.md> <key> - value of `<key>:` (at any indent) in the YAML
  # frontmatter (between the first two `---` fences). Empty if absent. Restricted
  # to the frontmatter so a `landed:`/`description:` word in the body never leaks.
  awk -v key="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm {
      line=$0
      sub(/^[ \t]+/, "", line)
      if (line ~ "^" key ":") {
        sub("^" key ":", "", line)
        sub(/^[ \t]+/, "", line)
        if (line ~ /^".*"$/) {
          sub(/^"/, "", line)
          sub(/"$/, "", line)
        } else if (line ~ /^\047.*\047$/) {
          sub(/^\047/, "", line)
          sub(/\047$/, "", line)
        }
        print line
        exit
      }
    }
  ' "$1" 2>/dev/null
}

curate_pending_candidate_targets() {
  # Emit fleet skill names that still have an unsettled Learning candidate.
  # A validated/applied transaction removes the subject from consideration via
  # its completed journal; historical candidate artifacts alone are not live.
  local cand name run tx journal
  for cand in "$(ac_data_dir)"/*/candidate-*.md "$(ac_data_dir)"/*/candidates/*.md; do
    [ -f "$cand" ] || continue
    name="$(sed -n 's/^name:[[:space:]]*//p' "$cand" | head -1)"
    case "$name" in ''|*[!a-z0-9-]*) continue ;; esac
    case "$cand" in
      */candidates/*) run="$(dirname "$(dirname "$cand")")" ;;
      *) run="$(dirname "$cand")" ;;
    esac
    tx="$(basename "$run")-$name"
    journal="$(ac_state_dir)/.maintenance-transactions/$tx/journal"
    [ -f "$journal" ] && [ "$(ac_meta_get "$journal" status)" = complete ] \
      && continue
    printf '%s\n' "$name"
  done | sort -u
}

curate_skill_active_dependency() {
  # curate_skill_active_dependency <skill-name> - print the first active task
  # whose seeded skill link resolves to the fleet's only live copy.
  local name="$1" source meta wt linked
  source="$(cd "$(ac_skills_dir)/$name" 2>/dev/null && pwd -P)" || return 1
  for meta in "$(ac_state_dir)"/*.meta; do
    [ -f "$meta" ] || continue
    wt="$(ac_meta_get "$meta" worktree)"
    [ -n "$wt" ] && [ -L "$wt/.claude/skills/$name" ] || continue
    linked="$(cd "$wt/.claude/skills/$name" 2>/dev/null && pwd -P)" || continue
    [ "$linked" = "$source" ] || continue
    basename "$meta" .meta
    return 0
  done
  return 1
}

curate_skill_is_stale() {
  # curate_skill_is_stale <skill-dir> <now> <window-seconds>
  # The canonical pointer is intentionally not a usefulness signal. Freshness
  # instead comes from the newest landing/patch bytes, seeding telemetry,
  # evidence append, unsettled Learning candidates, and active worktree use.
  local d="$1" now="$2" window="$3" name landed skill_mtime latest
  local last_seeded archive archive_mtime dependency
  name="$(basename "$d")"
  landed="$(_skill_field "$d/SKILL.md" landed)"
  case "$landed" in ''|*[!0-9]*) return 1 ;; esac
  skill_mtime="$(ac_file_mtime "$d/SKILL.md" 2>/dev/null || true)"
  case "$skill_mtime" in ''|*[!0-9]*) skill_mtime=0 ;; esac
  latest="$landed"
  [ "$skill_mtime" -le "$latest" ] || latest="$skill_mtime"
  [ "$((now - latest))" -gt "$window" ] || return 1

  last_seeded="$(ac_meta_get "$d/.usage.meta" last_seeded 2>/dev/null || true)"
  case "$last_seeded" in
    ''|*[!0-9]*) ;;
    *) [ "$((now - last_seeded))" -gt "$window" ] || return 1 ;;
  esac

  archive="$(ac_records_dir)/learnings-archive/$name.md"
  if [ -f "$archive" ]; then
    archive_mtime="$(ac_file_mtime "$archive" 2>/dev/null || true)"
    case "$archive_mtime" in ''|*[!0-9]*) return 1 ;; esac
    [ "$((now - archive_mtime))" -gt "$window" ] || return 1
  fi
  curate_pending_candidate_targets | grep -qxF "$name" && return 1
  dependency="$(curate_skill_active_dependency "$name" 2>/dev/null || true)"
  [ -z "$dependency" ] || return 1
  return 0
}

# --- skills-audit: territory overlap + stale candidates (PROPOSE ONLY) --------

_skills_overlap_flags() {
  # _skills_overlap_flags <name-TAB-desc file> - descriptions-first territory
  # overlap. Significant word = a >=6-char alphanumeric token of the description
  # (long tokens carry the territory; short glue like "check"/"gate" is dropped
  # by the length filter, not a hand-tuned stopword list), minus a small set of
  # generic long fillers. Two skills sharing >=2 significant words are flagged as
  # a possible-consolidation pair. Trivial by design (5 skills, no clustering
  # framework); PROPOSE ONLY - a human adjudicates, nothing is moved.
  awk -F'\t' -v min=2 '
    BEGIN {
      split("before after should would could cannot without between against through another because itself always actually", s, " ")
      for (i in s) stop[s[i]] = 1
    }
    {
      cnt = NR; name[cnt] = $1
      d = tolower($2); gsub(/[^a-z0-9]+/, " ", d)
      m = split(d, w, " "); delete seen
      for (i = 1; i <= m; i++) {
        t = w[i]
        if (length(t) < 6 || (t in stop) || (t in seen)) continue
        seen[t] = 1; has[cnt, t] = 1; wl[cnt] = wl[cnt] " " t
      }
    }
    END {
      for (a = 1; a <= cnt; a++) for (b = a + 1; b <= cnt; b++) {
        na = split(wl[a], wa, " "); sh = ""; ns = 0
        for (i = 1; i <= na; i++) { t = wa[i]; if (t != "" && ((b, t) in has)) { sh = sh (ns ? ", " : "") t; ns++ } }
        if (ns >= min) printf "  OVERLAP: %s ~ %s - share %d territory word(s): %s (review for possible consolidation)\n", name[a], name[b], ns, sh
      }
    }
  ' "$1"
}

curate_skills_audit() {
  local dirs now stale_days stale_seconds ndtsv ov flag_ov=0 flag_st=0
  local d store name landed age total
  now="$(ac_now)"
  stale_days="${AC_CURATE_STALE_DAYS:-90}"
  case "$stale_days" in ''|*[!0-9]*) stale_days=90 ;; esac
  stale_seconds=$((stale_days * 86400))
  printf '== skills-audit: territory overlap + stale candidates (propose-only, never mutates) ==\n'
  dirs="$(_learned_skill_dirs)"
  if [ -z "$dirs" ]; then
    printf '  (no learned skills - nothing to audit)\n'
    return 0
  fi
  total="$(printf '%s\n' "$dirs" | grep -c .)"

  # Territory overlap (descriptions-first).
  ndtsv="$(mktemp "${TMPDIR:-/tmp}/ac-curate-skov.XXXXXX")"
  while IFS=$'\t' read -r d store; do
    [ -n "$d" ] || continue
    printf '%s\t%s\n' "$(basename "$d")" "$(_skill_field "$d/SKILL.md" description)"
  done <<<"$dirs" >"$ndtsv"
  ov="$(_skills_overlap_flags "$ndtsv")"
  rm -f "$ndtsv"
  if [ -n "$ov" ]; then
    printf '%s\n' "$ov"
    flag_ov="$(printf '%s\n' "$ov" | grep -c 'OVERLAP:')"
  else
    printf '  ok: no overlapping description territory among learned skills\n'
  fi

  # Stale candidates are semantic, never direct mutations. Quoted and unquoted
  # legacy landed values are both accepted by _skill_field during migration.
  while IFS=$'\t' read -r d store; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    curate_skill_is_stale "$d" "$now" "$stale_seconds" || continue
    landed="$(_skill_field "$d/SKILL.md" landed)"
    age=$(( (now - landed) / 86400 ))
    printf '  STALE: %s [%s] - last landing/patch, seed, and evidence activity exceed %sd; no pending candidate or active worktree dependency\n' \
      "$name" "$store" "$stale_days"
    flag_st=$((flag_st + 1))
  done <<<"$dirs"
  [ "$flag_st" -eq 0 ] && printf '  ok: no stale candidates under the activity, evidence, pending-candidate, and active-worktree predicates\n'

  printf '  audited %s learned skill(s): %s overlap pair(s), %s stale candidate(s) - propose-only, no mutation (even with --apply)\n' \
    "$total" "$flag_ov" "$flag_st"
  return 0
}

# --- skills-consolidate: prefix-cluster umbrella merge, MOVE-to-archive -------

_skills_cluster_plan() {
  # _skills_cluster_plan <fleet-store> - detect first-segment prefix clusters in
  # the FLEET store (consolidate never touches the deliberate promoted rung).
  # prefix(name) = the text before the first `-`. A cluster is CONSOLIDATABLE
  # only when an umbrella skill named EXACTLY the prefix exists AND it has >=1
  # sibling `<prefix>-*` - the conservative gate (an exact-prefix umbrella is a
  # human's deliberate class-level skill). Emits, sorted for determinism:
  #   move<TAB><prefix><TAB><sibling>       - sibling to MOVE under its umbrella
  #   noumbrella<TAB><prefix><TAB><count>   - a >=2-sibling group with NO umbrella
  #                                           (propose only, never moved)
  local store="$1" d name
  for d in "$store"/*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "$AC_SKILLS_ARCHIVE_BASENAME" ] && continue
    [ -f "$d/SKILL.md" ] || continue
    printf '%s\n' "$name"
  done | awk '
    { names[$1] = 1 }
    END {
      for (n in names) {
        p = n; if (index(n, "-") > 0) p = substr(n, 1, index(n, "-") - 1)
        if (n != p) sib[p] = sib[p] " " n
      }
      for (p in sib) {
        c = split(sib[p], a, " "); nn = 0
        for (i = 1; i <= c; i++) if (a[i] != "") nn++
        if (p in names) { for (i = 1; i <= c; i++) if (a[i] != "") print "move\t" p "\t" a[i] }
        else if (nn >= 2) print "noumbrella\t" p "\t" nn
      }
    }
  ' | sort
}

curate_skills_consolidate() {
  local apply="$1" pre_backed="$2"
  local store archive plan kind p arg movers=0 proposed=0
  store="$(ac_skills_dir)"
  archive="$(ac_skills_archive_dir)"
  printf '== skills-consolidate: prefix-cluster umbrella merge, MOVE-to-archive (move-only, never delete) ==\n'
  plan="$(_skills_cluster_plan "$store")"
  if [ -z "$plan" ]; then
    printf '  ok: no prefix cluster with an umbrella - nothing to consolidate\n'
    return 0
  fi
  while IFS=$'\t' read -r kind p arg; do
    [ -n "$kind" ] || continue
    case "$kind" in
      move) printf '  CLUSTER %s: sibling %s -> archive (umbrella %s stays)\n' "$p" "$arg" "$p"; movers=$((movers + 1)) ;;
      noumbrella) printf -- '  cluster %s-*: %s sibling(s) but NO umbrella skill named "%s" - propose-only, not moved (create the umbrella first)\n' "$p" "$arg" "$p"; proposed=$((proposed + 1)) ;;
    esac
  done <<<"$plan"

  if [ "$movers" -eq 0 ]; then
    printf '  PROPOSE-ONLY: %s umbrella-less cluster(s) flagged; 0 movable (an exact-prefix umbrella is required to move a sibling)\n' "$proposed"
    return 0
  fi
  if [ "$apply" = 1 ]; then
    printf '  REFUSED: direct --apply cannot prove behavior preservation or update the canonical pointer atomically.\n'
    printf '  Run ac-curate.sh run; each movable sibling becomes a hash-bound semantic maintenance-gate subject.\n'
    return 2
  fi
  printf '  PROPOSE-ONLY: %s sibling(s) require automatic Curate maintenance-gate review before a recoverable move to %s; %s umbrella-less cluster(s) never move\n' \
    "$movers" "$archive" "$proposed"
  return 0
}

# --- run: automatic deterministic plan + shared maintenance transaction -------

curate_file_sha_or_absent() {
  if [ -f "$1" ] && [ ! -L "$1" ]; then
    ac_sha256_file "$1"
  elif [ ! -e "$1" ] && [ ! -L "$1" ]; then
    printf '%s\n' -
  else
    return 1
  fi
}

curate_plan_action() {
  # curate_plan_action <actions> <op> <target> <staged> <run> [<old_sha256>]
  # Without the 6th arg, old_sha256 is read from the LIVE file at call time -
  # correct only when the staged content was derived directly from that same
  # live read. A caller whose staged content instead derives from an earlier
  # snapshot (cmd_run's shadow passes) must pass that snapshot's sha256
  # explicitly, or a write landing on the live file during the intervening
  # passes is silently accepted as the plan's assumed pre-state and reverted
  # by ac_maintenance_apply.
  local actions="$1" op="$2" target="$3" staged="$4" run="$5" old_sha="${6:-}" new_sha
  if [ -z "$old_sha" ]; then
    old_sha="$(curate_file_sha_or_absent "$(ac_home)/$target")" || return 1
  fi
  new_sha="$(ac_sha256_file "$run/$staged")" || return 1
  jq -nc --arg op "$op" --arg target "$target" --arg old "$old_sha" \
    --arg new "$new_sha" --arg staged "$staged" \
    '{op:$op,target:$target,old_sha256:$old,new_sha256:$new,staged:$staged}' \
    >>"$actions"
}

curate_policy_receipt() {
  # curate_policy_receipt <receipt> <plan> <manifest>
  local receipt="$1" plan="$2" manifest="$3"
  {
    printf -- '---\nschema: "agentcrew.maintenance-gate/v1"\n'
    printf 'mode: "curate"\nsubject: "deterministic-records"\ndecision: "continue"\n'
    printf 'authority: "repository-policy"\nengine: "policy"\nmodel: ""\n'
    printf 'input_manifest_sha256: "%s"\n' "$(ac_sha256_file "$manifest")"
    printf 'action_plan_sha256: "%s"\nreviewed_at: "%s"\n---\n' \
      "$(ac_sha256_file "$plan")" "$(ac_iso)"
    printf '# Maintenance Gate Decision\n## Decision\ncontinue\n'
    printf '## Grounds\nCaptain terminal markers and backlog retention are deterministic, reversible repository policies.\n'
    printf '## Proposed Process\nApply the exact staged files through the shared maintenance transaction.\n'
  } >"$receipt.tmp.$$"
  mv "$receipt.tmp.$$" "$receipt"
}

curate_input_manifest() {
  # curate_input_manifest <out> - exact live hashes the deterministic plan reads.
  local out="$1" records f sha entries
  records="$(ac_records_dir)"
  entries="$(mktemp "${TMPDIR:-/tmp}/ac-curate-manifest.XXXXXX")"
  : >"$entries"
  for f in captain.md captain-archive.md backlog.md backlog-archive.md; do
    sha="$(curate_file_sha_or_absent "$records/$f")" || {
      rm -f "$entries"
      return 1
    }
    jq -nc --arg path "records/$f" --arg sha "$sha" \
      '{path:$path,sha256:$sha}' >>"$entries"
  done
  jq -s --arg keep "${AC_CURATE_KEEP:-20}" \
    '{schema:"agentcrew.curate-input/v1",keep_done:$keep,files:.}' \
    "$entries" >"$out"
  rm -f "$entries"
}

curate_subject_manifest() {
  # curate_subject_manifest <out> <subject> <home-relative-path>...
  local out="$1" subject="$2" entries rel sha
  shift 2
  entries="$(mktemp "${TMPDIR:-/tmp}/ac-curate-subject.XXXXXX")"
  : >"$entries"
  for rel in "$@"; do
    case "$rel" in
      ''|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*[!A-Za-z0-9._/-]*)
        rm -f "$entries"
        return 1 ;;
    esac
    sha="$(curate_file_sha_or_absent "$(ac_home)/$rel")" || {
      rm -f "$entries"
      return 1
    }
    jq -nc --arg path "$rel" --arg sha "$sha" \
      '{path:$path,sha256:$sha}' >>"$entries"
  done
  jq -s --arg subject "$subject" \
    '{schema:"agentcrew.curate-subject-input/v1",subject:$subject,files:(unique_by(.path))}' \
    "$entries" >"$out"
  rm -f "$entries"
}

curate_subject_manifest_validate() {
  # Recheck non-action judgment inputs after the gate returns. Action targets
  # already carry old hashes in the closed plan; this closes the same gap for
  # umbrella/evidence/absence inputs that informed the semantic decision.
  local manifest="$1" rel expected actual
  jq -e '
    type == "object"
    and .schema == "agentcrew.curate-subject-input/v1"
    and (.subject | type == "string")
    and (.files | type == "array")
    and all(.files[];
      type == "object"
      and keys == ["path","sha256"]
      and (.path | type == "string"
        and test("^[A-Za-z0-9._/-]+$")
        and (test("(^|/)\\.\\.?(/|$)") | not))
      and (.sha256 | type == "string"
        and (. == "-" or test("^[0-9a-f]{64}$"))))
  ' "$manifest" >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r rel expected; do
    actual="$(curate_file_sha_or_absent "$(ac_home)/$rel")" || return 1
    [ "$actual" = "$expected" ] || return 1
  done < <(jq -r '.files[] | [.path,.sha256] | @tsv' "$manifest")
}

curate_subject_plan() {
  # curate_subject_plan <out> <run> <subject> <manifest> <actions-ndjson>
  local out="$1" run="$2" subject="$3" manifest="$4" actions="$5"
  jq -s --arg run_id "$(basename "$run")" --arg subject "$subject" \
    --arg manifest "$(ac_sha256_file "$manifest")" \
    '{schema:"agentcrew.maintenance-plan/v1",mode:"curate",run_id:$run_id,
      subject:$subject,input_manifest_sha256:$manifest,actions:.}' \
    "$actions" >"$out"
}

curate_ask_receipt() {
  # Persist a hash-bound non-authorizing receipt when policy or runtime cannot
  # produce a gate decision. This makes every captain escalation link resolvable.
  local receipt="$1" plan="$2" manifest="$3" subject="$4" grounds="$5"
  mkdir -p "$(dirname "$receipt")"
  {
    printf -- '---\nschema: "agentcrew.maintenance-gate/v1"\n'
    printf 'mode: "curate"\nsubject: "%s"\ndecision: "ask-captain"\n' "$subject"
    printf 'authority: "repository-policy"\nengine: "policy"\nmodel: ""\n'
    printf 'input_manifest_sha256: "%s"\n' "$(ac_sha256_file "$manifest")"
    printf 'action_plan_sha256: "%s"\nreviewed_at: "%s"\n---\n' \
      "$(ac_sha256_file "$plan")" "$(ac_iso)"
    printf '# Maintenance Gate Decision\n## Decision\nask-captain\n'
    printf '## Grounds\n%s\n' "$grounds"
    printf '## Proposed Process\nPreserve the live records and ask the captain about this exact hash-bound subject.\n'
  } >"$receipt.tmp.$$"
  mv "$receipt.tmp.$$" "$receipt"
}

curate_captain_escalate() {
  # curate_captain_escalate <run> <subject> <plan> <manifest> <reason>
  #   [<acknowledgement-line>]
  # The optional last argument is the paste-ready acknowledgement for a subject
  # that has NO safe plan: the captain reads the ask here, so the exit that
  # settles it without touching a policy line has to be here too.
  local run="$1" subject="$2" plan="$3" manifest="$4" reason="$5" ack_line="${6:-}"
  local txid plan_sha candidate_rel receipt_rel evidence_rel message
  txid="$(basename "$run")"
  plan_sha="$(ac_sha256_file "$plan")"
  candidate_rel="data/$txid/subjects/$subject.md"
  receipt_rel="data/$txid/gates/$subject/decision.md"
  evidence_rel="${manifest#"$(ac_home)/"}"
  message="ASK: Curate maintenance cannot decide automatically.
why: $reason
subject: $subject; action-plan-sha256: $plan_sha
options: (1) approve this exact recoverable plan; (2) reject and preserve the live records; (3) request a revised plan.
tradeoffs: approve performs the reversible archival now; reject preserves active state and keeps Curate due; revise spends another maintenance-gate round.
recommendation: reject or revise unless the linked evidence proves the complete subject is retired.
links: candidate=$candidate_rel; gate=$receipt_rel; evidence=$evidence_rel"
  [ -z "$ack_line" ] || message="$message
already-ruled: if a standing ruling already answers this subject, record it in records/curate-acknowledged.md and Curate settles it without moving a line - replace the placeholder with that ruling:
$ack_line"
  "$(dirname "$0")/ac-room.sh" post curate curator "$message" >/dev/null 2>&1 \
    || ac_warn "captain escalation for Curate subject $subject could not be posted"
}

curate_gate_subject() {
  # curate_gate_subject <run> <subject> <manifest> <plan>
  # Return 0 when applied/preserved under a settled receipt, 2 when captain
  # input is unresolved, and 1 for an apply failure that must keep cadence due.
  local run="$1" subject="$2" manifest="$3" plan="$4"
  local receipt gate gate_out decision reason
  receipt="$run/gates/$subject/decision.md"
  gate="${AC_GATE:-$(dirname "$0")/ac-gate.sh}"
  mkdir -p "$(dirname "$receipt")"
  if gate_out="$("$gate" maintenance --mode curate --run "$run" \
    --subject "$subject" --manifest "$manifest" --plan "$plan" 2>&1)"; then
    [ -z "$gate_out" ] || printf '  %s\n' "$gate_out"
  else
    reason="The selected maintenance gate was disabled, unavailable, invalid, or timed out."
    [ -e "$receipt" ] || curate_ask_receipt \
      "$receipt" "$plan" "$manifest" "$subject" "$reason"
    curate_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason"
    printf '  ask-captain: %s (gate unavailable; no mutation)\n' "$subject"
    return 2
  fi
  if ! decision="$(ac_maintenance_receipt_validate "$receipt" "$plan" "$manifest")"; then
    reason="The gate receipt did not match the immutable manifest and action-plan hashes."
    curate_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason"
    printf '  ask-captain: %s (invalid gate receipt; no mutation)\n' "$subject"
    return 2
  fi
  case "$decision" in
    continue)
      if ! curate_subject_manifest_validate "$manifest"; then
        reason="A live semantic input changed after the gate reviewed its immutable manifest."
        curate_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason"
        printf '  ask-captain: %s (post-gate input drift; no mutation)\n' "$subject"
        return 2
      fi
      if ! ac_maintenance_apply "$plan" "$run"; then
        ac_warn "continue receipt for Curate subject $subject became stale or could not resume"
        return 1
      fi
      printf '  auto-applied semantic subject: %s\n' "$subject"
      return 0 ;;
    revise)
      printf '  revise: %s (live records preserved; subject settled)\n' "$subject"
      return 0 ;;
    ask-captain)
      curate_captain_escalate "$run" "$subject" "$plan" "$manifest" \
        "The maintenance gate returned ask-captain for this exact subject."
      printf '  ask-captain: %s (gate could not prove the move; no mutation)\n' "$subject"
      return 2 ;;
  esac
}

curate_material_fingerprint() {
  # curate_material_fingerprint <material> - the acknowledgement KEY: a sha256
  # over the subject's own material. Never its index-derived id and never the
  # file that contains it.
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

curate_acknowledged() {
  # curate_acknowledged <fingerprint> - print the ruling recorded for this exact
  # material in records/curate-acknowledged.md, or return 1. The grammar is
  # `- <subject> material=<sha256> ruling: <citation>`; the key is matched at
  # FIELD 3 and a line with no citation never acknowledges anything - an
  # acknowledgement without its pointer is a mute button.
  local fingerprint="$1" ledger
  ledger="$(ac_records_dir)/curate-acknowledged.md"
  [ -f "$ledger" ] || return 1
  awk -v want="material=$fingerprint" '
    $1 == "-" && $3 == want {
      i = index($0, "ruling:")
      if (i == 0) next
      r = substr($0, i + 7)
      gsub(/^[ \t]+|[ \t]+$/, "", r)
      if (r == "") next
      print r
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$ledger"
}

curate_blocked_subject() {
  # curate_blocked_subject <run> <subject> <reason> <material> - publish an
  # immutable empty plan plus a non-authorizing ask receipt when no safe
  # mutation plan exists. Return 0 when <material> already carries a recorded
  # captain ruling, which settles the subject without asking and without moving
  # one policy line; otherwise this is a real unresolved subject and the owning
  # run must not reset cadence.
  local run="$1" subject="$2" reason="$3" material="$4"
  local manifest plan actions receipt subject_rel fingerprint="" ruling ack_line=""
  # Material this run could not identify has NO key. Hashing it anyway would
  # give every such subject the one empty-string digest, and a single
  # acknowledgement would then silence a DIFFERENT subject.
  if [ -n "$material" ]; then
    fingerprint="$(curate_material_fingerprint "$material")"
    if ruling="$(curate_acknowledged "$fingerprint")"; then
      printf '  settled: %s (acknowledged - ruling: %s)\n' "$subject" "$ruling"
      return 0
    fi
    ack_line="- $subject material=$fingerprint ruling: <the records/ line that already decided this>"
  fi
  manifest="$run/manifests/$subject.json"
  plan="$run/plans/$subject.json"
  actions="$run/plans/.$subject.actions"
  receipt="$run/gates/$subject/decision.md"
  subject_rel="data/$(basename "$run")/subjects/$subject.md"
  mkdir -p "$(dirname "$manifest")" "$(dirname "$receipt")" "$run/subjects"
  {
    printf '# Curate Blocked Subject: %s\n\n' "$subject"
    printf '%s\n' "$reason"
    [ -z "$ack_line" ] || {
      printf '\nAlready ruled on? Append this line to records/curate-acknowledged.md,\n'
      printf 'replacing the placeholder with the ruling that decided it:\n\n%s\n' "$ack_line"
    }
  } >"$run/subjects/$subject.md"
  : >"$actions"
  curate_subject_manifest "$manifest" "$subject" "$subject_rel"
  curate_subject_plan "$plan" "$run" "$subject" "$manifest" "$actions"
  rm -f "$actions"
  curate_ask_receipt "$receipt" "$plan" "$manifest" "$subject" "$reason"
  curate_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason" "$ack_line"
  printf '  ask-captain: %s (no unique safe plan; no mutation)\n' "$subject"
  [ -z "$ack_line" ] || printf \
    '    already ruled? record it in records/curate-acknowledged.md:\n      %s\n' "$ack_line"
  return 2
}

curate_project_candidates() {
  # Emit line-number<TAB>name<TAB>verbatim-line for registered projects whose
  # fleet-local project path is absent. Audit-only mismatches are not candidates.
  local registry line nr name
  registry="$(ac_records_dir)/projects.md"
  [ -f "$registry" ] || return 0
  nr=0
  while IFS= read -r line; do
    nr=$((nr + 1))
    case "$line" in '- '*'['*']'*) ;; *) continue ;; esac
    name="$(printf '%s\n' "$line" | sed -n 's/^- \([^ ]*\) \[.*/\1/p')"
    case "$name" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ -e "$(ac_projects_dir)/$name" ] || printf '%s\t%s\t%s\n' "$nr" "$name" "$line"
  done <"$registry"
}

curate_prepare_project_subject() {
  # curate_prepare_project_subject <run> <line-number> <name> <verbatim-line>
  # Print manifest<TAB>plan.
  local run="$1" nr="$2" name="$3" line="$4" subject staged actions manifest plan
  local registry archive
  subject="project-$name"
  staged="$run/staged/$subject/records"
  actions="$run/plans/.$subject.actions"
  manifest="$run/manifests/$subject.json"
  plan="$run/plans/$subject.json"
  registry="$(ac_records_dir)/projects.md"
  archive="$(ac_records_dir)/projects-archive.md"
  [ "$(grep -cFx -- "$line" "$registry" || true)" = 1 ] || return 1
  nr="$(grep -nFx -- "$line" "$registry" | cut -d: -f1)"
  mkdir -p "$staged" "$(dirname "$manifest")" "$run/subjects"
  awk -v drop="$nr" 'NR != drop { print }' "$registry" >"$staged/projects.md"
  [ ! -f "$archive" ] || cp "$archive" "$staged/projects-archive.md"
  [ -f "$archive" ] || printf '# Projects Archive\n\n' >"$staged/projects-archive.md"
  printf '%s\n' "$line" >>"$staged/projects-archive.md"
  {
    printf '# Curate Semantic Subject: %s\n\n' "$subject"
    printf 'The registered project path is absent. The proposed action moves the original registry line verbatim into the fleet archive. It never deletes a clone or remote.\n'
  } >"$run/subjects/$subject.md"
  : >"$actions"
  curate_plan_action "$actions" rewrite-registry records/projects.md \
    "staged/$subject/records/projects.md" "$run"
  curate_plan_action "$actions" append-archive records/projects-archive.md \
    "staged/$subject/records/projects-archive.md" "$run"
  curate_subject_manifest "$manifest" "$subject" \
    records/projects.md records/projects-archive.md "projects/$name"
  curate_subject_plan "$plan" "$run" "$subject" "$manifest" "$actions"
  rm -f "$actions"
  printf '%s\t%s\n' "$manifest" "$plan"
}

curate_skill_pointer_line() {
  # Print the single canonical active pointer for a skill; refuse duplicates.
  local name="$1" ledger count
  ledger="$(ac_records_dir)/learnings.md"
  [ -f "$ledger" ] || return 1
  count="$(grep -cF "[distilled -> $name]" "$ledger" || true)"
  [ "$count" = 1 ] || return 1
  grep -F "[distilled -> $name]" "$ledger"
}

curate_skill_material() {
  # curate_skill_material <umbrella> <name> - the acknowledgement material for a
  # skill subject: the umbrella it would fold into plus the live skill body, so
  # a rewritten skill retires its acknowledgement.
  local umbrella="$1" name="$2" skill
  skill="$(ac_skills_dir)/$name/SKILL.md"
  printf 'umbrella=%s\n' "$umbrella"
  [ ! -f "$skill" ] || cat "$skill"
}

curate_prepare_skill_subject() {
  # curate_prepare_skill_subject <run> <umbrella> <skill>
  # Print manifest<TAB>plan. Every file in the live skill directory moves under
  # the reserved archive, while the canonical pointer changes rung in the same
  # maintenance transaction.
  local run="$1" umbrella="$2" name="$3" subject source archive_dir evidence
  local ledger index pointer sources updated staged actions manifest plan file rel
  local dependency
  subject="skill-$name"
  source="$(ac_skills_dir)/$name"
  archive_dir="$(ac_skills_archive_dir)/$name"
  evidence="$(ac_records_dir)/learnings-archive/$name.md"
  ledger="$(ac_records_dir)/learnings.md"
  index="$(ac_records_dir)/learnings-archive/index.md"
  staged="$run/staged/$subject"
  actions="$run/plans/.$subject.actions"
  manifest="$run/manifests/$subject.json"
  plan="$run/plans/$subject.json"
  [ -f "$(ac_skills_dir)/$umbrella/SKILL.md" ] || return 1
  [ -d "$source" ] && [ ! -L "$source" ] && [ ! -e "$archive_dir" ] || return 1
  [ -f "$evidence" ] && [ ! -L "$evidence" ] || return 1
  pointer="$(curate_skill_pointer_line "$name")" || return 1
  dependency="$(curate_skill_active_dependency "$name" 2>/dev/null || true)"
  [ -z "$dependency" ] || return 1
  [ -z "$(find "$source" -type l -print -quit 2>/dev/null)" ] || return 1
  [ -z "$(find "$source" ! -type d ! -type f -print -quit 2>/dev/null)" ] || return 1

  mkdir -p "$staged/skills/$AC_SKILLS_ARCHIVE_BASENAME/$name" \
    "$staged/records/learnings-archive" "$(dirname "$manifest")" "$run/subjects"
  : >"$actions"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="${file#"$source"/}"
    mkdir -p "$staged/skills/$AC_SKILLS_ARCHIVE_BASENAME/$name/$(dirname "$rel")"
    cp "$file" "$staged/skills/$AC_SKILLS_ARCHIVE_BASENAME/$name/$rel"
    curate_plan_action "$actions" move-skill \
      "skills/$AC_SKILLS_ARCHIVE_BASENAME/$name/$rel" \
      "staged/$subject/skills/$AC_SKILLS_ARCHIVE_BASENAME/$name/$rel" "$run"
  done < <(find "$source" -type f | sort)

  awk -v marker="[distilled -> $name]" 'index($0, marker) == 0 { print }' \
    "$ledger" >"$staged/records/learnings.md"
  [ ! -f "$index" ] || cp "$index" "$staged/records/learnings-archive/index.md"
  [ -f "$index" ] || printf '# Archived Learning Pointers\n\n' \
    >"$staged/records/learnings-archive/index.md"
  sources="$(printf '%s\n' "$pointer" | sed -n 's/^.*sources=\([0-9][0-9]*\).*$/\1/p')"
  updated="$(printf '%s\n' "$pointer" | sed -n 's/^.*updated=\([0-9][0-9-]*\).*$/\1/p')"
  case "$sources" in ''|*[!0-9]*) return 1 ;; esac
  case "$updated" in ????-??-??) ;; *) return 1 ;; esac
  printf -- '- [distilled -> %s] sources=%s updated=%s ([skill](../../skills/%s/%s/SKILL.md); [evidence](%s.md))\n' \
    "$name" "$sources" "$updated" "$AC_SKILLS_ARCHIVE_BASENAME" "$name" "$name" \
    >>"$staged/records/learnings-archive/index.md"
  curate_plan_action "$actions" rewrite-ledger records/learnings.md \
    "staged/$subject/records/learnings.md" "$run"
  curate_plan_action "$actions" rewrite-index records/learnings-archive/index.md \
    "staged/$subject/records/learnings-archive/index.md" "$run"
  {
    printf '# Curate Semantic Subject: %s\n\n' "$subject"
    printf 'Umbrella skill `%s` remains live. The gate must confirm it preserves the behavior of `%s` before authorizing the recoverable move and canonical pointer update.\n' \
      "$umbrella" "$name"
  } >"$run/subjects/$subject.md"

  curate_subject_manifest "$manifest" "$subject" \
    "skills/$umbrella/SKILL.md" "skills/$name/SKILL.md" \
    "skills/$AC_SKILLS_ARCHIVE_BASENAME/$name/SKILL.md" \
    "records/learnings.md" "records/learnings-archive/index.md" \
    "records/learnings-archive/$name.md"
  curate_subject_plan "$plan" "$run" "$subject" "$manifest" "$actions"
  rm -f "$actions"
  printf '%s\t%s\n' "$manifest" "$plan"
}

curate_semantic_projects() {
  local run="$1" nr name line prepared manifest plan rc unresolved=0
  while IFS=$'\t' read -r nr name line; do
    [ -n "$nr" ] || continue
    if ! prepared="$(curate_prepare_project_subject "$run" "$nr" "$name" "$line")"; then
      curate_blocked_subject "$run" "project-$name" \
        "The project registry entry could not be staged as a unique verbatim archive move." \
        "$line" \
        || unresolved=1
      continue
    fi
    IFS=$'\t' read -r manifest plan <<EOF
$prepared
EOF
    curate_gate_subject "$run" "project-$name" "$manifest" "$plan" || {
      rc=$?
      [ "$rc" -eq 2 ] || ac_warn "project subject $name could not apply safely"
      unresolved=1
    }
  done < <(curate_project_candidates)
  [ "$unresolved" -eq 0 ]
}

curate_named_captain_candidates() {
  # Emit subject<TAB>live-first-line<TAB>target-first-line<TAB>classification.
  # Directional "above/below" and an explicit date after SUPERSEDES are the
  # closed target grammar. Anything else is an ambiguous captain subject.
  local captain
  captain="$(ac_records_dir)/captain.md"
  [ -f "$captain" ] || return 0
  awk '
    function flush() {
      if (!start) return
      n++
      first[n] = firstline
      text[n] = block
      start = 0
      block = ""
    }
    /^- / {
      flush()
      start = NR
      firstline = $0
      block = $0
      next
    }
    start && /^[ \t]/ { block = block "\n" $0; next }
    { flush() }
    END {
      flush()
      for (i = 1; i <= n; i++) {
        if (text[i] !~ /SUPERSEDES/) continue
        target = 0
        if (tolower(text[i]) ~ /below/) target = i + 1
        else if (tolower(text[i]) ~ /above/) target = i - 1
        else {
          rest = text[i]
          sub(/^.*SUPERSEDES/, "", rest)
          if (match(rest, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
            date = substr(rest, RSTART, RLENGTH)
            hits = 0
            for (j = 1; j <= n; j++) {
              if (j != i && index(first[j], date)) {
                target = j
                hits++
              }
            }
            if (hits != 1) target = 0
          }
        }
        cls = "movable"
        if (!target || target < 1 || target > n) cls = "ambiguous"
        else if (tolower(text[target]) ~ /holds/) cls = "partial"
        printf "captain-supersedes-%d\t%s\t%s\t%s\n",
          i, first[i], (target ? first[target] : ""), cls
      }
    }
  ' "$captain"
}

curate_captain_block_range() {
  # curate_captain_block_range <captain.md> <block-first-line> - print
  # `<start> <end>` for the rule BLOCK (a `- ` line plus its indented
  # continuations) that first line identifies. A non-unique first line is
  # refused rather than guessed at.
  local captain="$1" first="$2" start end
  [ "$(grep -cFx -- "$first" "$captain" || true)" = 1 ] || return 1
  start="$(grep -nFx -- "$first" "$captain" | cut -d: -f1)"
  end="$(awk -v start="$start" '
    NR < start { next }
    NR > start && /^- / { print NR - 1; exit }
    { last = NR }
    END { if (last >= start) print last }
  ' "$captain" | head -1)"
  [ -n "$end" ] || return 1
  printf '%s %s\n' "$start" "$end"
}

curate_captain_material() {
  # curate_captain_material <live-first> <target-first> - the acknowledgement
  # material for a captain subject: both rule BLOCKS in full, so a captain edit
  # anywhere inside either one retires its acknowledgement, while an edit
  # elsewhere in captain.md leaves that acknowledgement standing.
  local live="$1" target="$2" captain first range
  captain="$(ac_records_dir)/captain.md"
  for first in "$live" "$target"; do
    [ -n "$first" ] || continue
    range="$(curate_captain_block_range "$captain" "$first")" || continue
    sed -n "${range% *},${range#* }p" "$captain"
  done
}

curate_prepare_captain_subject() {
  # curate_prepare_captain_subject <run> <subject> <live-first> <target-first>
  local run="$1" subject="$2" live="$3" target="$4" captain archive start end
  local staged actions manifest plan datestr range
  captain="$(ac_records_dir)/captain.md"
  archive="$(ac_records_dir)/captain-archive.md"
  [ "$(grep -cFx -- "$live" "$captain" || true)" = 1 ] || return 1
  range="$(curate_captain_block_range "$captain" "$target")" || return 1
  start="${range% *}"
  end="${range#* }"
  if sed -n "${start},${end}p" "$captain" | grep -qi 'holds'; then
    return 1
  fi
  staged="$run/staged/$subject/records"
  actions="$run/plans/.$subject.actions"
  manifest="$run/manifests/$subject.json"
  plan="$run/plans/$subject.json"
  mkdir -p "$staged" "$(dirname "$manifest")" "$run/subjects"
  awk -v start="$start" -v end="$end" 'NR < start || NR > end { print }' \
    "$captain" >"$staged/captain.md"
  if ! grep -qFx 'Archived rulings: [captain-archive.md](captain-archive.md)' \
    "$staged/captain.md"; then
    [ ! -s "$staged/captain.md" ] || printf '\n' >>"$staged/captain.md"
    printf 'Archived rulings: [captain-archive.md](captain-archive.md)\n' \
      >>"$staged/captain.md"
  fi
  [ ! -f "$archive" ] || cp "$archive" "$staged/captain-archive.md"
  [ -f "$archive" ] || printf '# captain-archive - retired captain.md rules (moved by ac-curate.sh, never deleted)\n' \
    >"$staged/captain-archive.md"
  datestr="$(ac_iso)"
  {
    printf '\n## curated %s - named supersession\n' "$datestr"
    printf 'superseded-by: %s\n' "$live"
    sed -n "${start},${end}p" "$captain"
  } >>"$staged/captain-archive.md"
  {
    printf '# Curate Semantic Subject: %s\n\n' "$subject"
    printf '## Live ruling (must remain)\n\n%s\n\n' "$live"
    printf '## Named target (proposed verbatim archive)\n\n'
    sed -n "${start},${end}p" "$captain"
  } >"$run/subjects/$subject.md"
  : >"$actions"
  curate_plan_action "$actions" append-archive records/captain-archive.md \
    "staged/$subject/records/captain-archive.md" "$run"
  curate_plan_action "$actions" rewrite-registry records/captain.md \
    "staged/$subject/records/captain.md" "$run"
  curate_subject_manifest "$manifest" "$subject" \
    records/captain.md records/captain-archive.md
  curate_subject_plan "$plan" "$run" "$subject" "$manifest" "$actions"
  rm -f "$actions"
  printf '%s\t%s\n' "$manifest" "$plan"
}

curate_semantic_captain() {
  local run="$1" subject live target cls prepared manifest plan rc unresolved=0
  local archive
  archive="$(ac_records_dir)/captain-archive.md"
  while IFS=$'\t' read -r subject live target cls; do
    [ -n "$subject" ] || continue
    if [ -f "$archive" ] && grep -qFx -- "superseded-by: $live" "$archive"; then
      printf '  settled: %s (named target already archived under this live ruling)\n' \
        "$subject"
      continue
    fi
    if [ "$cls" != movable ] \
      || ! prepared="$(curate_prepare_captain_subject "$run" "$subject" "$live" "$target")"; then
      curate_blocked_subject "$run" "$subject" \
        "A live SUPERSEDES ruling does not identify one wholly retired target, or the named target retains a partial 'holds' qualifier." \
        "$(curate_captain_material "$live" "$target")" \
        || unresolved=1
      continue
    fi
    IFS=$'\t' read -r manifest plan <<EOF
$prepared
EOF
    curate_gate_subject "$run" "$subject" "$manifest" "$plan" || {
      rc=$?
      [ "$rc" -eq 2 ] || ac_warn "captain supersession subject $subject could not apply safely"
      unresolved=1
    }
  done < <(curate_named_captain_candidates)
  [ "$unresolved" -eq 0 ]
}

curate_semantic_skills() {
  local run="$1" kind umbrella name prepared manifest plan rc unresolved=0
  local cluster
  cluster="$(_skills_cluster_plan "$(ac_skills_dir)")"
  while IFS=$'\t' read -r kind umbrella name; do
    [ "$kind" = move ] || continue
    if ! prepared="$(curate_prepare_skill_subject "$run" "$umbrella" "$name")"; then
      curate_blocked_subject "$run" "skill-$name" \
        "The skill lacks a unique safe consolidation plan: its canonical pointer, evidence archive, archive destination, or active-worktree dependency is unresolved." \
        "$(curate_skill_material "$umbrella" "$name")" \
        || unresolved=1
      continue
    fi
    IFS=$'\t' read -r manifest plan <<EOF
$prepared
EOF
    curate_gate_subject "$run" "skill-$name" "$manifest" "$plan" || {
      rc=$?
      [ "$rc" -eq 2 ] || ac_warn "skill subject $name could not apply safely"
      unresolved=1
    }
  done <<<"$cluster"
  [ "$unresolved" -eq 0 ]
}

cmd_run() {
  local dry_run="$1" generation run shadow report actions manifest plan receipt
  local records base op changed=0 decision rn rx unresolved=0 pristine pristine_sha
  if [ "$dry_run" = 1 ]; then
    printf '== records-wide CURATE pass (--dry-run; read-only) ==\n'
    curate_learnings
    curate_captain 0 1
    curate_backlog 0 1
    curate_projects
    curate_skills_audit
    printf '== curate dry-run complete; no backup, mutation, receipt, or cadence reset ==\n'
    return 0
  fi

  generation="$(ac_curate_generation)"
  run="$(ac_data_dir)/curate-$(ac_now)-$$"
  shadow="$run/shadow"
  report="$run/report.md"
  actions="$run/actions.ndjson"
  manifest="$run/input-manifest.json"
  plan="$run/plans/deterministic-records.json"
  receipt="$run/gates/deterministic-records/decision.md"
  pristine="$run/pristine"
  mkdir -p "$shadow/records" "$shadow/state" "$shadow/skills" \
    "$run/staged/records" "$pristine" "$(dirname "$plan")" "$(dirname "$receipt")"

  curate_input_manifest "$manifest" || ac_die "Curate input manifest refused a non-file or symlink"
  records="$(ac_records_dir)"
  for base in captain.md captain-archive.md backlog.md backlog-archive.md; do
    [ ! -f "$records/$base" ] || cp "$records/$base" "$shadow/records/$base"
    # The bytes the passes below are about to read, captured NOW - not a
    # live re-read once they (and a concurrent captain write) may have moved
    # on. curate_plan_action binds the plan's old_sha256 to this file.
    curate_file_sha_or_absent "$shadow/records/$base" >"$pristine/$base" \
      || ac_die "Curate could not hash the pristine $base snapshot"
  done

  # Deterministic test seam standing in for a captain write landing during the
  # real multi-second passes below - never a sleep-and-hope timing race.
  # TEST SEAM, double-keyed (audit-f8): the hook execs whatever executable the
  # env names, so it additionally requires AC_TEST_HOOKS=1 (exported by
  # tests/helpers.sh and nothing else) - one inherited variable in a captain's
  # environment can no longer make a production curate run execute it.
  if [ "${AC_TEST_HOOKS:-}" = 1 ] && [ -n "${AC_CURATE_SNAPSHOT_HOOK:-}" ] \
    && [ -x "${AC_CURATE_SNAPSHOT_HOOK}" ]; then
    "${AC_CURATE_SNAPSHOT_HOOK}" "$records" || true
  fi

  printf '== records-wide CURATE pass (automatic deterministic apply) ==\n'
  curate_learnings
  curate_projects
  curate_skills_audit
  {
    AC_HOME="$shadow" curate_captain 1 1
    AC_HOME="$shadow" curate_backlog 1 1
  } >"$report"
  cat "$report"

  : >"$actions"
  for base in captain-archive.md captain.md backlog-archive.md backlog.md; do
    [ -f "$shadow/records/$base" ] || continue
    if [ -f "$records/$base" ] && cmp -s "$records/$base" "$shadow/records/$base"; then
      continue
    fi
    cp "$shadow/records/$base" "$run/staged/records/$base"
    case "$base" in
      *-archive.md) op=append-archive ;;
      *) op=rewrite-registry ;;
    esac
    pristine_sha="$(cat "$pristine/$base")"
    curate_plan_action "$actions" "$op" "records/$base" "staged/records/$base" "$run" \
      "$pristine_sha"
    changed=$((changed + 1))
  done

  jq -s --arg run_id "$(basename "$run")" \
    --arg manifest "$(ac_sha256_file "$manifest")" \
    '{schema:"agentcrew.maintenance-plan/v1",mode:"curate",run_id:$run_id,
      subject:"deterministic-records",input_manifest_sha256:$manifest,actions:.}' \
    "$actions" >"$plan"
  rm -f "$actions"
  curate_policy_receipt "$receipt" "$plan" "$manifest"
  decision="$(ac_maintenance_receipt_validate "$receipt" "$plan" "$manifest")" \
    || ac_die "Curate policy receipt failed its own hash/schema validation"
  [ "$decision" = continue ] || ac_die "Curate deterministic policy did not authorize its plan"
  ac_maintenance_apply "$plan" "$run" \
    || ac_die "Curate maintenance transaction could not apply or resume safely"

  printf '== semantic Curate subjects (maintenance gate) ==\n'
  curate_semantic_captain "$run" || unresolved=1
  curate_semantic_projects "$run" || unresolved=1
  curate_semantic_skills "$run" || unresolved=1
  if [ "$unresolved" -ne 0 ]; then
    read -r rn rx < <(ac_curate_due)
    printf '== curate pass open: deterministic subjects committed; unresolved semantic/captain subject(s) preserve cadence=%s/%s ==\n' \
      "$rn" "$rx"
    return 0
  fi

  if ! ac_curate_reset "$generation"; then
    ac_warn "Curate committed, but a newer cadence generation exists; its late Learning ticks were preserved"
  fi
  read -r rn rx < <(ac_curate_due)
  printf '== curate pass complete: %s changed record file(s); transaction + policy receipt committed; interval=%s/%s ==\n' \
    "$changed" "$rn" "$rx"
}

cmd="${1:-}"
shift 2>/dev/null || true
apply=0
dry_run=0
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --dry-run) dry_run=1 ;;
    *) ac_die "unknown flag: $a" ;;
  esac
done
case "$cmd" in
  learnings) curate_learnings ;;
  captain) curate_captain "$apply" 0 ;;
  backlog) curate_backlog "$apply" 0 ;;
  projects) curate_projects ;;
  skills-audit) curate_skills_audit ;;
  skills-consolidate) curate_skills_consolidate "$apply" 0 ;;
  run) cmd_run "$dry_run" ;;
  *) ac_die "usage: ac-curate.sh learnings|captain [--apply]|backlog [--apply]|projects|skills-audit|skills-consolidate [--apply]|run [--dry-run]" ;;
esac
