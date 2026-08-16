#!/usr/bin/env bash
# ac-lib.sh - CORE shared helpers sourced by every agent-crew script. Not an
# entrypoint.
#
# Owns: home resolution (AC_HOME), state/data/config/projects/records path
# helpers, key=value meta-file accessors, a mkdir-based lock with stale-owner
# recovery, config reads, crewdeputy config convergence + the crewdeputy
# routing table grammar, task data dir resolution (staged-flow nesting), the
# captain-marker regexes (AC_CAPTAIN_RE/AC_DECISION_RE/AC_BUSY_RE) and their
# write-side twin ac_bare_marker_verbs, the backlog Done-line grammar
# (AC_DONELINE_AWK/ac_doneline - shared by ac-ready.sh/ac-curate.sh/ac-learn.sh,
# none of which otherwise need a sub-lib, so it stays here rather than in
# ac-wake-lib.sh), task state files + the VERIFICATION-agent and SELF-TASK
# meta classes, the landing ledger (cross-family file interlock) + crewmate
# seeding (ac_seed_*), git helpers (ac_repo_root/ac_default_branch/
# ac_default_ref/ac_project_dir/ac_project_config_file/ac_knowledge_file/
# ac_home_resolve), ac_project_mode, the orphaned shell-snapshot detector, and
# small logging/error helpers.
#
# SPLIT (audit-f3, codebase-audit-2026-07-29 finding 3): the ac_qa_*
# validation block, the wake/spool/room/chief-quiet block, and the
# Learning/Curate cadence + maintenance-transaction block moved out to
# bin/ac-qa-lib.sh, bin/ac-wake-lib.sh and bin/ac-maintenance-lib.sh
# respectively - each sourced directly by the callers that need it (this file
# does NOT source them, mirroring bin/ac-pipeline-lib.sh). The two
# herdr-specific pane-agent workspace/tab helpers moved to bin/ac-backend.sh.
#
# The agent-crew home is the directory that holds state/, data/, config/ and
# projects/. Scripts always run from the checkout that owns bin/, and read and
# write fleet state under $AC_HOME, which is REQUIRED: ac_home refuses rather
# than falling back to the checkout, which is not a fleet home. A caller that
# legitimately runs homeless (every crewmate pane does) uses the rung built for
# it - ac_config_read's default, ac_fleet_name's fixed name, ac_home_resolve's
# empty answer - never ac_home.

ac_root() {
  # Directory of the agent-crew checkout that owns this bin/.
  local src="${BASH_SOURCE[0]}"
  cd "$(dirname "$src")/.." && pwd -P
}

ac_home() {
  # A fleet home is NAMED, never guessed. Answering ac_root() when AC_HOME was
  # unset made the DISTRO CHECKOUT a fleet home silently, and every write helper
  # below mkdir -p'd into it: a real fleet's wake spool, watcher beacons and
  # whole family data dirs accumulated in a directory no session-start, turn-end
  # guard or watcher drains, gitignored so nothing ever surfaced it.
  # The refusal keys on the ABSENCE OF AC_HOME and never on what a directory
  # contains, so it cannot false-refuse a real home - the phantom checkout is
  # content-indistinguishable from a genuine home (it grew records/backlog.md,
  # records/projects.md, config/, data/ and state/ from those same writes).
  # Homeless callers are legitimate and stay so: every one of them already has
  # its own rung and none asks here - ac_config_read answers its default,
  # ac_fleet_name a fixed name, ac_home_resolve nothing at all.
  [ -n "${AC_HOME:-}" ] \
    || ac_die "AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one"
  cd "$AC_HOME" && pwd -P
}

# The six path helpers below each bind the home on its OWN statement and RETURN
# on ac_home's refusal. The explicit `|| return 1` is load-bearing, not
# defensive dressing: every caller reads these through `$(...)`, and in that
# context bash (3.2, measured) does not fire errexit for the inner assignment -
# without it the helper would run on to `mkdir -p "/state"` and print "/state"
# with status 0, handing the caller a filesystem-root path instead of a refusal.
ac_state_dir() { local h; h="$(ac_home)" || return 1; mkdir -p "$h/state"; printf '%s\n' "$h/state"; }
ac_data_dir() { local h; h="$(ac_home)" || return 1; mkdir -p "$h/data"; printf '%s\n' "$h/data"; }
# Permanent per-fleet store for learned skills. Legacy container learned skills
# are migration inputs only and are never a normal write or seed source.
ac_skills_dir() { local h; h="$(ac_home)" || return 1; mkdir -p "$h/skills"; printf '%s\n' "$h/skills"; }
# The skills-consolidate archive (ac-curate.sh) is a reserved subdir INSIDE the
# fleet store: a MOVE target for retired prefix-cluster siblings, never a skill.
# One source of truth for the name so the seed loop (ac_seed_crew_skills, class 2)
# and the curator agree - a mismatch would re-seed archived skills. It rides
# under skills/, so ac_records_backup already tars it (no extra backup wiring).
AC_SKILLS_ARCHIVE_BASENAME=skills-archive
ac_skills_archive_dir() { printf '%s\n' "$(ac_skills_dir)/$AC_SKILLS_ARCHIVE_BASENAME"; }
ac_records_dir() {
  # Fleet record files (backlog.md, projects.md, captain.md, learnings.md,
  # crewdeputies.md) live in records/, a SIBLING of data/ (captain-pinned
  # 2026-07-17) - ledgers separate from task dirs. The interim-layout
  # migration (data/records/<f> or data/<f> moved in on first resolve) that
  # used to run here cost 10 stats + an rmdir on EVERY call across 47 call
  # sites; retired by audit-f7 after every fleet home was verified clean of
  # the interim layout (gone since 2026-07-17).
  # The home is bound on its OWN statement, never concatenated into the path.
  # Measured (bash 3.2): in the command-substitution context every caller uses,
  # `r="$(ac_home)/records"` carries exit status 0 even when the substitution
  # died - so ac_home's refusal would be swallowed and r would become
  # "/records", which mkdir then tries to create at the filesystem root.
  local h r
  h="$(ac_home)" || return 1
  r="$h/records"
  [ -d "$r" ] || mkdir -p "$r"
  printf '%s\n' "$r"
}
ac_config_dir() { local h; h="$(ac_home)" || return 1; mkdir -p "$h/config"; printf '%s\n' "$h/config"; }
ac_projects_dir() { local h; h="$(ac_home)" || return 1; mkdir -p "$h/projects"; printf '%s\n' "$h/projects"; }

# state/.ac-root - the last-known distro checkout root for THIS home,
# DOT-PREFIXED like .learn.meta/.curate.meta. A hook deployed at
# $AC_HOME/config/<hook> has no fixed relative path back to the distro and
# cannot rely on the caller's cwd, so it cannot find bin/ac-lib.sh on its
# own; this pointer lets it, from any cwd, with only AC_HOME set. Written by
# ac_seed_root_pointer, called by bin/ac-remote.sh on every invocation (poll
# cadence, reply, thread-post, ack all run through it) so an existing home
# self-heals the pointer with no manual bootstrap step.
ac_root_pointer_path() { printf '%s/.ac-root\n' "$(ac_state_dir)"; }
ac_seed_root_pointer() {
  [ -n "${AC_HOME:-}" ] || return 0
  local ptr root
  ptr="$(ac_root_pointer_path)"; root="$(ac_root)"
  [ "$(cat "$ptr" 2>/dev/null || true)" = "$root" ] || printf '%s\n' "$root" >"$ptr"
}

ac_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ac_warn() { printf 'WARN: %s\n' "$*" >&2; }
# $EPOCHSECONDS (bash 5+) is a builtin that costs no fork, unlike `date +%s`;
# it is referenced fresh (not a shell-startup snapshot), so this stays
# equivalent to a live clock read. Falls back to `date +%s` when unset
# (bash < 5 - this host's own /bin/bash is 3.2.57 and hits this path).
ac_now() { printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}"; }
ac_vn_ts() {
  # Captain-display timestamp: UTC+7, YYYY-MM-DD
  # HH:mm - for Slack-facing renderings only; records keep ac_iso (UTC).
  TZ=Asia/Ho_Chi_Minh date '+%Y-%m-%d %H:%M'
}

ac_verb_emoji() {
  # ac_verb_emoji <verb> - the glanceable emoji leading a Slack header
  #: one look tells the entry class. Unknown
  # verbs get the neutral note - never empty, the header shape stays fixed.
  case "${1:-}" in
    ORDER*) printf '📌' ;;
    TRIAGE*) printf '🧭' ;;
    GATE-PASSED*|SELF-APPROVED*) printf '☑️' ;;
    GATE*) printf '🚦' ;;
    ASK*) printf '❓' ;;
    DECIDED*) printf '✅' ;;
    LANDED*|DONE*) printf '🎉' ;;
    HANDBACK*) printf '🤝' ;;
    PROMOTED*) printf '🧵' ;;
    DEMOTED*) printf '🔻' ;;
    CLOSED*) printf '🔒' ;;
    START*) printf '🚀' ;;
    FAILED*|BLOCKED*) printf '⛔' ;;
    *) printf '📝' ;;
  esac
}

# --- meta files: one `key=value` per line, last write wins -------------------

ac_meta_get() {
  # ac_meta_get <file> <key> -> value (empty if absent)
  # ABSENT AT BOTH INSTANTS: the `-f` test and awk's open() of the same path are
  # two instants, and a meta file legitimately vanishes between them - ac-lock.sh's
  # reaper rm's the session lock while a losing racer reads it. awk exits 2 on
  # `can't open file` and a caller's `var="$(ac_meta_get ...)"` ADOPTS that status,
  # so errexit killed the caller with no message of its own. Gone by the second
  # instant is still gone -> empty, exit 0. Still THERE and unreadable is a real
  # error and still propagates: fail-closed, so a lock nobody can read is never
  # reported pid-less (which would hand it to the next acquirer).
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  # awk's own stderr is silenced because the VANISH is benign and expected; the
  # real-error path says so itself rather than aborting the caller mutely.
  awk -F= -v k="$key" '$1==k { v=substr($0, length(k)+2) } END { if (v != "") print v }' "$file" 2>/dev/null \
    || { [ -e "$file" ] && { ac_warn "cannot read meta file $file"; return 1; } || return 0; }
}

ac_meta_set() {
  # ac_meta_set <file> <key> <value> - atomic rewrite (replace the key,
  # keep the rest); readers still take the last value for a key.
  local file="$1" key="$2" value="$3" tmp="$1.tmp.$$"
  if [ -f "$file" ]; then
    grep -v "^$key=" "$file" >"$tmp" || true
  else
    : >"$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

ac_skill_usage_bump() {
  # ac_skill_usage_bump <skill-dir> - the cheap "seeding-is-use" telemetry
  # (learning-loop Slice 4): bump seeded_count and stamp last_seeded in
  # <skill-dir>/.usage.meta, the canonical sidecar that rides inside the
  # fleet-owned folder and through recoverable archive/migration moves. Called
  # only for fleet-learned skills (ac_seed_crew_skills class 2), on each new
  # symlink - never for class-1 built-ins.
  #
  # BEST-EFFORT and race-tolerant, never failing or blocking the seed: many
  # crewmates seed the same skill at once, so ac_meta_set's atomic rename is what
  # matters - it can never CORRUPT the file, only lose an increment when two
  # seeders read the same count. seeded_count is therefore a lower bound, which
  # is fine for a cheap v1 signal; a lock would be bigger than the value it buys.
  local dir="${1:-}" meta cur
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  meta="$dir/.usage.meta"
  cur="$(ac_meta_get "$meta" seeded_count 2>/dev/null || true)"
  case "$cur" in '' | *[!0-9]*) cur=0 ;; esac
  ac_meta_set "$meta" seeded_count "$((cur + 1))" 2>/dev/null || return 0
  ac_meta_set "$meta" last_seeded "$(ac_now)" 2>/dev/null || return 0
  return 0
}

# (ac_record_launch_opts - which of model/effort a harness's launch actually
# applies - moved to the harness registry, bin/ac-harness.sh, audit-f5.)

# --- mkdir lock with stale-owner recovery ------------------------------------
# Portable to macOS (no flock(1)). `mkdir` is the atomic claim; the lock dir
# then records the owner PID in `pid`. A lock nobody holds any more is STALE
# and is reclaimed - ac_lock_stale below is the ONE definition of that, and it
# covers BOTH shapes a dead holder leaves:
#   - `pid` names a process that no longer exists (it died after publishing);
#   - `pid` is ABSENT or EMPTY - an external kill landed in the window between
#     `mkdir` and the `printf` that publishes the pid. This shape wedged the
#     fleet watcher: a leaked empty dir is owned by nobody, yet every re-arm
#     read it as a live holder and refused with `already running` forever.
# It FAILS CLOSED in every direction: a live owner, an unreadable dir, or a
# pid-less dir younger than AC_LOCK_STALE_GRACE keeps its lock. That grace is
# what separates a corpse from a live acquirer still inside its own (sub-
# millisecond) publish window - reclaiming the latter would let two holders
# each believe they own the lock.
#
# Residual, PRE-EXISTING and not closed here: reclaim is `rm -rf` + re-`mkdir`,
# which is not atomic against a concurrent acquirer, so two reclaimers can
# still both win the same lock. ac_lock_release is owner-checked so that at
# least the loser's release can never delete the winner's LIVE lock dir; a
# fully race-free lock needs an atomic publish (O_EXCL pid file as the claim),
# which is a bigger change than this one.

ac_pid_alive() {
  # ac_pid_alive <pid> - 0 when the process EXISTS. Prefer `ps`: a bare
  # `kill -0` reports EPERM (a process this user may not signal) as failure,
  # which would hand a LIVE holder's lock straight to a second acquirer. Some
  # sandboxes deny `ps` itself, so fall back to kill -0 and distinguish its
  # C-locale permission denial (still live) from ESRCH (dead).
  local pid="${1:-}" err
  # Lock owners are canonical positive process ids. In particular, never pass
  # zero to kill: `kill -0 0` targets the current process group and would make
  # a corrupt pid file look permanently live.
  case "$pid" in ''|*[!0-9]*|0*) return 1 ;; esac
  ps -p "$pid" >/dev/null 2>&1 && return 0
  err="$(LC_ALL=C kill -0 "$pid" 2>&1)" && return 0
  case "$err" in
    *[Oo]peration*not*permitted*|*[Pp]ermission*denied*) return 0 ;;
  esac
  return 1
}

ac_file_mtime() {
  # ac_file_mtime <path> - mtime in epoch seconds; 1 when unstattable.
  # BSD (`stat -f %m`) and GNU (`stat -c %Y`) disagree, and the losing form
  # can PRINT before it fails (GNU `-f` reads %m as a file operand and still
  # reports on the real one), so each candidate is validated as digits before
  # it is trusted - never `cmd1 || cmd2` on raw stdout.
  local m
  m="$(stat -f %m "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[![:digit:]]*) m="$(stat -c %Y "$1" 2>/dev/null)" || m="" ;; esac
  case "$m" in ''|*[![:digit:]]*) return 1 ;; esac
  printf '%s\n' "$m"
}

ac_lock_stale() {
  # ac_lock_stale <lockdir> - 0 when the lock is STALE (see the block above).
  local lockdir="$1" owner mtime grace="${AC_LOCK_STALE_GRACE:-5}"
  owner="$(cat "$lockdir/pid" 2>/dev/null || true)"
  if [ -n "$owner" ]; then
    ac_pid_alive "$owner" && return 1
    return 0
  fi
  mtime="$(ac_file_mtime "$lockdir")" || return 1
  [ "$(( $(ac_now) - mtime ))" -ge "$grace" ]
}

ac_lock_acquire() {
  # ac_lock_acquire <lockdir> [<timeout-secs>] -> 0 on success
  local lockdir="$1" timeout="${2:-10}" waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    if ac_lock_stale "$lockdir"; then
      rm -rf "$lockdir" 2>/dev/null || true
      # Gone -> retry the claim. Still there means either the rm failed or a
      # fresh acquirer already re-made it: either way fall through and WAIT,
      # so an unremovable dir times out instead of spinning forever.
      [ -d "$lockdir" ] || continue
    fi
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" >"$lockdir/pid"
}

ac_lock_release() {
  # ac_lock_release <lockdir> - drop a lock THIS process holds. Owner-checked:
  # a reclaim can hand the dir to another acquirer between our acquire and our
  # release, and a blind `rm -rf` would then delete a LIVE holder's lock. A
  # pid-less dir is ours to clear (it is the shape we leak, not one we lose).
  local lockdir="$1" owner
  owner="$(cat "$lockdir/pid" 2>/dev/null || true)"
  [ -z "$owner" ] || [ "$owner" = "$$" ] || return 0
  rm -rf "$lockdir"
}

ac_pid_chain() {
  # ac_pid_chain [<pid>] - one line naming a process and every ancestor that
  # could reap it: `<pid>(<comm>) < <ppid>(<comm>) < ...`, ending at init.
  # Recorded when the watcher arms, so an external kill is attributable to a
  # NAMED process after the fact instead of a bare pid in a signal log.
  local pid="${1:-$$}" out="" comm depth=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 16 ]; do
    # `${comm##*/}`, not basename(1): a process we cannot read reports an
    # empty comm, and `basename ""` is a usage error, not a name.
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    comm="${comm##*/}"
    [ -n "$comm" ] || comm='?'
    if [ -n "$out" ]; then out="$out < "; fi
    out="$out$pid($comm)"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    depth=$((depth + 1))
  done
  printf '%s\n' "${out:-?}"
}

# --- config -------------------------------------------------------------------

ac_config_read() {
  # ac_config_read <name> [<default>] - first line of config/<name>, trimmed of
  # surrounding whitespace and a trailing CR, or default when the file is absent.
  # Trimming keeps a stray space or a CRLF editor from smuggling an invisible
  # character into a strictly validated value (config/effort, config/backend, ...).
  # Resolves the path WITHOUT ac_config_dir: a read must mint nothing. Going
  # through ac_config_dir's mkdir grew a stray config/ inside every pool
  # worktree and checkout a homeless pane agent read a knob from. Writers still
  # call ac_config_dir.
  # ...and WITHOUT ac_home, for the twin reason: a read must not REFUSE either.
  # ac_home fails closed with no AC_HOME, but a HOMELESS READER is legitimate -
  # every crewmate pane is one, and ac-pane-agent.sh reads its session and
  # model/effort knobs from one on every invocation. No home means no knob file,
  # so the default answers, which is the same value a homeless read already got:
  # the only knob the phantom checkout ever grew is config/herdr-workspace, and
  # that knob is retired and read by nothing (ac-backend.sh:266).
  # ac_home_resolve is THE homeless ladder - one copy on purpose.
  local name="$1" default="${2:-}" h f line
  h="$(ac_home_resolve '' '')"
  [ -n "$h" ] || { printf '%s\n' "$default"; return 0; }
  f="$h/config/$name"
  [ -f "$f" ] || { printf '%s\n' "$default"; return 0; }
  line="$(head -n1 "$f")"
  line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
  line="${line%"${line##*[![:space:]]}"}"   # strip trailing whitespace/CR
  printf '%s\n' "$line"
}

# --- crewdeputy config convergence ---------------------------------------------
# Operational knobs that stay CONVERGED parent -> crewdeputy: on every pull the
# parent's value wins, including its absence (absence-mirroring). Only these
# keys are ever copied or removed; identity and local keys (captain, launch-*,
# herdr-*, local overrides) are never touched and stay downstream-owned.
AC_INHERITABLE_CONFIG="${AC_INHERITABLE_CONFIG:-model effort backend crew-harness codereview-agent codereview-model codereview-effort qa-agent qa-model qa-effort gate-agent gate-model gate-effort epic-parallel room-parallel promote flow learn-every curate-every crew-dispatch.json}"

ac_is_crewdeputy_home() {
  # ac_is_crewdeputy_home - 0 when the resolved home is a seeded crewdeputy
  # home, 1 otherwise. Detection is the .ac-crewdeputy-home marker file
  # ac-home-seed.sh drops at the home root.
  [ -f "$(ac_home)/.ac-crewdeputy-home" ]
}

ac_config_converge_from_parent() {
  # ac_config_converge_from_parent <parent-config-dir> - pull the declared
  # inheritable knobs (AC_INHERITABLE_CONFIG) from the parent config dir into
  # this home's config dir. Per item:
  #   differs from local          -> atomic copy, prints "converged: <item>"
  #   absent at parent, here      -> removed, prints "removed: <item> (absent at parent)"
  #   identical or absent on both -> silent
  # Undeclared keys are never touched; a second run prints nothing
  # (idempotent). Returns 1 with a warning when <parent-config-dir> is not a
  # directory; otherwise 0.
  local parent_dir="${1:-}" cfg item src dst tmp
  [ -d "$parent_dir" ] || { ac_warn "parent config dir not found: $parent_dir"; return 1; }
  cfg="$(ac_config_dir)"
  for item in $AC_INHERITABLE_CONFIG; do
    src="$parent_dir/$item"
    dst="$cfg/$item"
    if [ -f "$src" ]; then
      if ! cmp -s "$src" "$dst" 2>/dev/null; then
        tmp="$dst.tmp.$$"
        cp "$src" "$tmp"
        mv "$tmp" "$dst"
        printf 'converged: %s\n' "$item"
      fi
    elif [ -f "$dst" ]; then
      rm -f "$dst"
      printf 'removed: %s (absent at parent)\n' "$item"
    fi
  done
  return 0
}

# --- crewdeputy routing table ---------------------------------------------------
#
# AUTHORITATIVE for the grammar of records/crewdeputies.md - the registry the
# crewchief routes work against. One crewdeputy per line, plain-dash, fields in
# FIXED order:
#
#   - <id> - <charter summary> - home: <abs-path> - scope: <text> - projects: <p1,p2|none> (added <iso>)
#
# - <id>          leading token; charset [a-zA-Z0-9_-]+, unique in the file, and
#                 EQUAL to basename(home) - a mismatch is registry/disk drift.
# - <charter>     unkeyed free text between the id and ` - home:`; one line, and
#                 it may not contain ` - home:`. The full charter lives in the
#                 deputy's brief; this is the one-liner.
# - home:         ABSOLUTE path to the deputy home.
# - scope:        free text describing the work this deputy owns. It is the
#                 field an order is matched against - matching is the CHIEF
#                 reading the text, never a script. EMPTY = not routable.
# - projects:     comma-joined names with NO spaces (the `blocked-by:` grammar),
#                 or `none`. A NON-EXCLUSIVE clone list, never ownership.
#
# Three validity classes, one per `- ` line:
# - VALID    every field parses, id charset holds, home is absolute. Routable
#            when `scope:` is additionally non-empty.
# - LEGACY   the pre-upgrade shape `- <id> - home: <abs> - <space-separated
#            projects | "no projects"> (added <iso>)`. It READS successfully
#            (charter `(none)`, empty scope, projects normalized to the comma
#            grammar) and is NOT an error, but a scopeless entry is never
#            routable. A mixed file is a supported steady state - nothing here
#            ever rewrites the ledger, which is the chief's to edit.
# - INVALID  anything else. EXCLUDED from routing and reported with a naming
#            reason. Field extraction is INDEX-based (locate ` - home:`, then
#            ` - scope:`, then ` - projects:`, then the trailing ` (added ...)`)
#            so text containing ` - ` never mis-splits silently and every
#            failure yields a reason a reader can act on.
#
# Non-entry lines (the heading, blanks, anything not starting with `- `) are
# IGNORED - never parsed, never reported - the tolerance ac_project_mode has.

ac_deputy_registry() {
  # ac_deputy_registry - path of the routing table (records/crewdeputies.md).
  printf '%s/crewdeputies.md\n' "$(ac_records_dir)"
}

ac_deputy_parse() {
  # ac_deputy_parse [<file>] - one TSV record per `- ` line, in file order:
  #   <class>\t<id>\t<home>\t<charter>\t<scope>\t<projects>\t<reason>
  # <reason> is empty except on INVALID, where it names the FIRST failed check.
  # On INVALID the <id> field carries the VERBATIM source line and every other
  # field is empty: the digest prints it, so a typo is fixable without opening
  # the ledger, and a line that failed to parse has no id worth trusting.
  # PURE - reads the file, writes nothing, probes nothing; safe to call from a
  # read-only session. An absent file yields no records.
  local file="${1:-}"
  [ -n "$file" ] || file="$(ac_deputy_registry)"
  [ -f "$file" ] || return 0
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function base(p) { sub(/\/+$/, "", p); sub(/^.*\//, "", p); return p }
    function bad(reason) { printf "INVALID\t%s\t\t\t\t\t%s\n", $0, reason }
    {
      if (substr($0, 1, 2) != "- ") next
      rest = substr($0, 3)
      if (rest !~ / \(added [^)]*\)$/) { bad("missing \"(added ...)\""); next }
      sub(/ \(added [^)]*\)$/, "", rest)

      p = index(rest, " - home:")            # 8 chars
      if (p == 0) { bad("missing \"home:\" field"); next }
      head = substr(rest, 1, p - 1)
      tail = substr(rest, p + 8)

      q = index(head, " - ")                 # id, then the free-text charter
      if (q > 0) { id = trim(substr(head, 1, q - 1)); charter = trim(substr(head, q + 3)) }
      else { id = trim(head); charter = "" }

      s = index(tail, " - scope:")           # 9 chars
      if (s > 0) {
        home = trim(substr(tail, 1, s - 1))
        after = substr(tail, s + 9)
        r = index(after, " - projects:")     # 12 chars
        if (r == 0) { bad("missing \"projects:\" field"); next }
        scope = trim(substr(after, 1, r - 1))
        projects = trim(substr(after, r + 12))
        if (charter == "") { bad("missing charter field"); next }
        cls = "VALID"
      } else {
        if (charter != "") { bad("missing \"scope:\" field"); next }
        cls = "LEGACY"
        t = index(tail, " - ")
        if (t > 0) { home = trim(substr(tail, 1, t - 1)); projects = trim(substr(tail, t + 3)) }
        else { home = trim(tail); projects = "" }
        charter = "(none)"
        scope = ""
        if (projects == "no projects") projects = ""
        else gsub(/[ \t]+/, ",", projects)
      }
      if (projects == "") projects = "none"

      if (id !~ /^[a-zA-Z0-9_-]+$/) { bad("bad id charset"); next }
      if (substr(home, 1, 1) != "/") { bad("home path is not absolute"); next }
      if (base(home) != id) { bad("id does not match home basename"); next }
      if (id in seen) { bad("duplicate id"); next }
      seen[id] = 1
      printf "%s\t%s\t%s\t%s\t%s\t%s\t\n", cls, id, home, charter, scope, projects
    }
  ' "$file"
}

# --- crewdomain routing table -------------------------------------------------
#
# AUTHORITATIVE for the grammar of records/crewdomains.md - the SECOND routing
# table, read by the crewchief to route work at intake. A crewdomain is durable
# state inside this fleet, not a nested home, so this grammar is a strict subset
# of the crewdeputy one above and the two files never mix:
#
#   - <id> - <charter summary> - scope: <text> (added <iso>)
#
# - <id>       leading token; charset [a-zA-Z0-9_-]+, unique in the file. There
#              is no home to match it against - the package path is derived.
# - <charter>  unkeyed free text between the id and ` - scope:`; one line.
# - scope:     free text describing the work this domain owns, and the LAST
#              field, so it may contain ` - `. It is what an order is matched
#              against - matching is the CHIEF reading the text, never a script.
#              EMPTY = not routable.
#
# Two validity classes only. There is no LEGACY class - nothing has ever written
# this file - and no liveness states, because a crewdomain has no session to be
# alive. Field extraction is INDEX-based, like the deputy parser, so text
# containing ` - ` never mis-splits silently.
#
# An UNKNOWN KEYED FIELD is INVALID and the reason names it. The check is
# general rather than a blocklist of the deputy's `home:`/`projects:`, and it
# spans the scope text too, so a deputy line pasted into this file cannot half-
# parse into a scope that swallowed the rest. The cost is stated rather than
# discovered: a scope may contain ` - `, but not ` - <word>:`.
#
# Non-entry lines (the heading, blanks, anything not starting with `- `) are
# IGNORED - never parsed, never reported.

ac_domain_registry() {
  # ac_domain_registry - path of the crewdomain routing table.
  printf '%s/crewdomains.md\n' "$(ac_records_dir)"
}

ac_domain_parse() {
  # ac_domain_parse [<file>] - one TSV record per `- ` line, in file order:
  #   <class>\t<id>\t<charter>\t<scope>\t<reason>
  # <reason> is empty except on INVALID, where it names the FIRST failed check.
  # On INVALID the <id> field carries the VERBATIM source line and every other
  # field is empty - the same shape ac_deputy_parse uses, for the same reason:
  # the digest prints it, and a line that failed to parse has no id worth
  # trusting. PURE - reads the file, writes nothing, probes nothing. An absent
  # file yields no records.
  local file="${1:-}"
  [ -n "$file" ] || file="$(ac_domain_registry)"
  [ -f "$file" ] || return 0
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function bad(reason) { printf "INVALID\t%s\t\t\t%s\n", $0, reason }
    {
      if (substr($0, 1, 2) != "- ") next
      rest = substr($0, 3)
      if (rest !~ / \(added [^)]*\)$/) { bad("missing \"(added ...)\""); next }
      sub(/ \(added [^)]*\)$/, "", rest)

      # Drop the ONE legitimate keyed field, then any keyed token left over is a
      # field this grammar does not have. Checked BEFORE the scope split so a
      # `home:` line is refused by name rather than by a downstream symptom.
      probe = rest
      sub(/ - scope:/, "", probe)
      if (match(probe, / - [a-zA-Z][a-zA-Z0-9_-]*:/)) {
        bad("unknown field \"" substr(probe, RSTART + 3, RLENGTH - 3) "\""); next
      }

      p = index(rest, " - scope:")           # 9 chars
      if (p == 0) { bad("missing \"scope:\" field"); next }
      head = substr(rest, 1, p - 1)
      scope = trim(substr(rest, p + 9))

      q = index(head, " - ")                 # id, then the free-text charter
      if (q > 0) { id = trim(substr(head, 1, q - 1)); charter = trim(substr(head, q + 3)) }
      else { id = trim(head); charter = "" }
      if (charter == "") { bad("missing charter field"); next }

      # [a-z0-9-], TIGHTER than the loose read-path charset the deputy parser
      # uses, and equal to what `new` mints - because a crewdomain id is
      # CONCATENATED into a package path. A parser calling `Payments` VALID
      # would hand an id to a path verb that refuses it, and `list` (which may
      # never exit non-zero) would then die on the digest. One charset, both
      # ends. NOTE: no apostrophes in this block - the awk program is inside a
      # shell single-quoted string, and one would close it.
      if (id !~ /^[a-z0-9-]+$/) { bad("bad id charset"); next }
      if (id in seen) { bad("duplicate id"); next }
      seen[id] = 1
      printf "VALID\t%s\t%s\t%s\t\n", id, charter, scope
    }
  ' "$file"
}

ac_domain_name_ok() {
  # ac_domain_name_ok <name> - 0 when <name> is a legal crewdomain id.
  # EVERY name-taking verb calls this BEFORE building a path from it: the
  # package root is derived by concatenation, so an unchecked `..` component
  # would reach out of crewdomains/ entirely - into a crewdeputy home, which
  # this feature must never touch, or into the fleet's own records/.
  case "$1" in
    ''|*/*|.|..) return 1 ;;
  esac
  # C collation, in a SUBSHELL so the caller's locale is untouched: under a
  # collation that interleaves case (en_US.UTF-8 orders a,A,b,B,...) a plain
  # a-z range admits most uppercase letters, so this glob would pass `UPPER`.
  # Same trap bin/ac-home-seed.sh:42-46 already documents for its own name check.
  (LC_ALL=C; case "$1" in *[!a-z0-9-]*) exit 1 ;; esac)
}

ac_backlog_id_ok() {
  # ac_backlog_id_ok <id> - 0 when <id> is a legal backlog row id (AGENTS.md
  # section 9: [a-z0-9-]). Callers interpolate ids into awk REGEXES, where an
  # unvalidated `.` or `*` stops being a literal and starts matching other
  # rows - so the charset check is what makes the id a literal again.
  case "$1" in ''|*/*|.|..) return 1 ;; esac
  (LC_ALL=C; case "$1" in *[!a-z0-9-]*) exit 1 ;; esac)
}

ac_domain_view_entry() {
  # ac_domain_view_entry <domain> <entry> - classify one projects/ view entry:
  #   ok | not-symlink | dangling | outside <resolved-target> | mismatch <resolved-target>
  # The MEMBERSHIP invariant is link RESOLUTION, not the link text - which is
  # what makes an absolute link as valid as a relative one and what survives a
  # rename. ONE predicate with TWO consumers: `ac-domain.sh validate` explains
  # each class, and ac-spawn.sh's pre-lease guard accepts only `ok` - a guard
  # that merely tested existence would pass a plain directory or a link
  # resolving outside the fleet clones, leaving the domain scope fail-open.
  # Pure shell (no realpath(1), no python): resolve the link's TARGET against
  # the link's own directory, then resolve that target's directory physically.
  local dom="$1" entry="$2" home link t d clones rl
  home="$(ac_home)"
  link="$home/crewdomains/$dom/projects/$entry"
  [ -L "$link" ] || { printf 'not-symlink\n'; return 1; }
  [ -e "$link" ] || { printf 'dangling\n'; return 1; }
  clones="$(cd -P "$home/projects" 2>/dev/null && pwd -P)" || clones="$home/projects"
  # ONE-HOP CONTAINMENT (captain ruling 2026-08-03, select at the lab session,
  # recorded in ac-homes/drydock/data/domain-view-symlinked-clones/room.md):
  # stop resolving the moment the chain LANDS at $AC_HOME/projects/<name> -
  # never follow further, even when that fleet clone is itself a symlink to a
  # captain checkout. That is exactly the trust level ac-spawn.sh, ac-tree.sh
  # and ac-merge-local.sh already extend to a symlinked clone, so a domain view
  # onto it deserves no stricter a check; a fleet whose every clone is such a
  # symlink (the sanctioned layout the captain approved) could otherwise never
  # pass this guard at all. This supersedes the earlier "follow the whole
  # chain" rule: stopping AT the fleet-clone boundary is a different act from
  # canonicalizing only the parent directory (the bug that reasoning warned
  # against) - the landing point is still required to be EXACTLY
  # $AC_HOME/projects/<entry>, checked below by the identity comparison.
  local hops=0 landed=""
  t="$link"
  while [ -L "$t" ] && [ "$hops" -lt 16 ]; do
    d="$(cd -P "$(dirname "$t")" 2>/dev/null && pwd -P)" || { printf 'dangling\n'; return 1; }
    rl="$(readlink "$t")" || { printf 'dangling\n'; return 1; }
    case "$rl" in /*) t="$rl" ;; *) t="$d/$rl" ;; esac
    hops=$((hops + 1))
    d="$(cd -P "$(dirname "$t")" 2>/dev/null && pwd -P)" || { printf 'dangling\n'; return 1; }
    if [ "$d" = "$clones" ]; then
      t="$d/$(basename "$t")"
      landed=1
      break
    fi
  done
  if [ -z "$landed" ]; then
    [ "$hops" -lt 16 ] || { printf 'dangling\n'; return 1; }
    d="$(cd -P "$(dirname "$t")" 2>/dev/null && pwd -P)" || { printf 'dangling\n'; return 1; }
    t="$d/$(basename "$t")"
  fi
  case "$t/" in
    "$clones"/*) ;;
    *) printf 'outside %s\n' "$t"; return 1 ;;
  esac
  # IDENTITY, not merely containment. `beta -> $AC_HOME/projects/alpha` resolves
  # inside the clones and would pass a containment test, yet the spawn it
  # authorizes runs against projects/beta - a repository the domain never
  # linked. The entry must resolve to ITS OWN clone NAME, compared as a
  # literal string against $clones/$entry - never by canonicalizing that path
  # further (e.g. `cd -P "$clones/$entry"`), which would realpath THROUGH a
  # symlinked clone exactly like the whole-chain resolution this predicate no
  # longer does, silently reopening the very case the one-hop stop above
  # exists to accept.
  [ "$t" = "$clones/$entry" ] || { printf 'mismatch %s\n' "$t"; return 1; }
  printf 'ok\n'
}

ac_domain_tally() {
  # ac_domain_tally [<name>] - "<queued> <inflight> <done>" row counts for one
  # crewdomain backlog, or summed over every package when no name is given.
  # "done" means a row that REALLY finished - a [failed]/[abandoned] Done-
  # section row is terminal but not done, and is EXCLUDED from the done field
  # (same-done-miscount-in-three-more-surfaces; the field's own consumers - see
  # below - never distinguish failed/abandoned themselves, so folding them out
  # here is the one place that can be honest without a field-count/order
  # change). Detection reuses AC_DONELINE_AWK's ac_doneline terminal field -
  # the same position-pinned parser ac-ready.sh's snapshot() uses - rather than
  # a second marker parser.
  #
  # ONE helper with TWO consumers on purpose: `bin/ac-domain.sh list` renders
  # the per-domain counts and the PARKED reminder in ac-turnend-guard.sh reads
  # the total. Two tallies could disagree, and the direction that matters is the
  # reminder's - it gates on ac-ready.sh, which does not read domain backlogs,
  # so a fleet holding assigned-but-unpromoted rows would otherwise read as
  # "nothing READY, safe to park" and the guard would tell the chief to END the
  # session on top of queued work. The guard reads THIS, never a rendered digest
  # block. PURE: reads, writes nothing.
  local name="${1:-}" home f q=0 i=0 d=0
  home="$(ac_home)"
  # The glob stays UNQUOTED and the name filters the result: "${name:-*}" would
  # quote the star into a literal, so the no-name (total) call would match
  # nothing and the PARKED reminder would silently read every fleet as drained.
  for f in "$home"/crewdomains/*/records/backlog.md; do
    [ -f "$f" ] || continue
    if [ -n "$name" ]; then
      case "$f" in "$home/crewdomains/$name/records/backlog.md") ;; *) continue ;; esac
    fi
    eval "$(awk "$AC_DONELINE_AWK"'
      /^## In flight/ { sec = "i"; next }
      /^## Queued/    { sec = "q"; next }
      /^## Done/      { sec = "d"; next }
      /^- \[/ && sec == "d" {
        ac_doneline($0, o)
        if (o["terminal"] != "failed" && o["terminal"] != "abandoned") n["d"]++
        next
      }
      /^- \[/ && sec  { n[sec]++ }
      END { printf "q=$((q+%d)) i=$((i+%d)) d=$((d+%d))\n", n["q"] + 0, n["i"] + 0, n["d"] + 0 }
    ' "$f")"
  done
  printf '%s %s %s\n' "$q" "$i" "$d"
}

ac_require() {
  # ac_require <cmd>... - die unless every command is on PATH.
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || ac_die "required tool not found: $c"
  done
}

ac_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Crewmate status lines the captain must hear about (watcher wake filter).
# Status markers (done/needs-decision/blocked/failed/paused/merged) are anchored
# to the LINE START with TUI-prefix tolerance: the prefix class admits leading
# whitespace and TUI glyphs (bullets, spinners, box-drawing) but rejects
# alphabetic chars and DIGITS/+ (printf/echo/any code, or a diff/line-number
# gutter like "121 +" / "50 ", before the marker), quote chars " ' ` (string
# literals and markdown-code spans), = (assignments), # / * (comment leaders),
# and - (markdown dash bullets) - so a pane merely DISPLAYING code or docs that
# quote the protocol never wakes the chief. The marker colon must be followed by
# whitespace or end-of-line ([[:space:]]|$), so a mid-sentence token list that
# soft-wraps to column 0 (e.g. "done:/blocked:/gate.") no longer wakes. merged
# is now an anchored "merged:" marker (was a bare unanchored phrase that hit
# "merged-ready" and quoted 'merged: local' literals).
# checks-passed: is the crew-ship COMPLETION marker - the PR is up and the pane
# waits on the captain's merge. It is anchored+colon-terminated like the rest and
# its ONE producer is `ac-ship.sh finish checks-passed` (the finish stdout the
# pane shows). It REPLACES three retired bare phrases (PR ready, checks green,
# ready in branch): those had no pane producer at all - "PR ready:" is only a
# status-LOG line from ac-pr-check.sh, and the other two were never emitted - so
# they only ever matched prose that DISPLAYED the words (the docs/config regex
# dump, skill text) and false-woke the chief. Shape-matching the real completion
# line kills that residue while still waking on a real ship completion.
# Residual: a REAL "marker: " phrase that soft-wraps to visual column 0 is still
# indistinguishable from a real marker at the regex layer and can still wake -
# accepted, backstopped by the .seen-<id> dedup, the stale-wake detector, and
# on the ONE producer a chief controls directly, the write-side guard below
# (ac_bare_marker_verbs, wired into bin/ac-send.sh); a full fix needs
# capture-level line-rejoin (out of scope).
_ac_captain_re_default='^[^[:alpha:][:digit:]"'\''`=+#/*-]*(done|needs-decision|blocked|failed|paused|merged|checks-passed):([[:space:]]|$)'
AC_CAPTAIN_RE="${AC_CAPTAIN_RE:-$_ac_captain_re_default}"
# The CAPTAIN-WAIT subset of the captain markers: lines that park a pane on a
# captain ACTION - the two decision verbs (needs-decision:, blocked:) plus the
# crew-ship delivery marker awaiting the captain's merge (checks-passed:,
# anchored like AC_CAPTAIN_RE). done: stays out - a finished pane waits on the
# CHIEF, not the captain. The watcher stamps such panes BLOCKED in the herdr UI
# and any other marker clears the stamp - contract: ac-backend.sh CAPTAIN-WAIT
# STAMP.
_ac_decision_re_default='^[^[:alpha:][:digit:]"'\''`=+#/*-]*(needs-decision|blocked|checks-passed):([[:space:]]|$)'
AC_DECISION_RE="${AC_DECISION_RE:-$_ac_decision_re_default}"
# Per-harness facts (the known set, AC_BUSY_RE, instruction file, pane arm,
# startup key, recorded-opts policy) live in the harness registry - one file
# a 4th harness edits instead of thirteen (audit-f5).
. "$(dirname "${BASH_SOURCE[0]}")/ac-harness.sh"

ac_bare_marker_verbs() {
  # ac_bare_marker_verbs <text> - the WRITE-SIDE twin of AC_CAPTAIN_RE: print
  # every BARE marker verb the text carries, one per line, deduped in
  # first-seen order; return 1 when there is none. Any writer that puts text
  # into a pane can call it (bin/ac-send.sh does) to warn its author before
  # the watcher greps those same words back out of the pane tail.
  # Deliberately BROADER than AC_CAPTAIN_RE, which anchors at a LINE START:
  # text typed into a pane re-wraps, so a mid-sentence marker phrase lands at
  # visual column 0 and matches there - the Residual above, and the lived case.
  # Re-applying AC_CAPTAIN_RE to the outgoing text would miss exactly it.
  # The colon rule is AC_CAPTAIN_RE's own (whitespace or end-of-line after it),
  # which is why neither safe form reports: the backtick-wrapped token
  # (`blocked:`) puts a backtick after the colon, and dropping the colon leaves
  # nothing to match. The verb list is READ from the live AC_CAPTAIN_RE so an
  # override cannot leave the two grammars disagreeing; an unparseable one
  # reports nothing - this warns, it never refuses, so it fails open.
  local verbs hits
  verbs="$(sed -n 's/.*(\([^)]*\)):.*/\1/p' <<<"$AC_CAPTAIN_RE")"
  case "$verbs" in ''|*[!a-z\|-]*) return 1 ;; esac
  hits="$(grep -oE "($verbs):([[:space:]]|\$)" <<<"$1" | awk '!seen[$1]++ { print $1 }')"
  [ -n "$hits" ] || return 1
  printf '%s\n' "$hits"
}

# --- task data dirs (staged-flow nesting) --------------------------------------
# Staged-flow task data nests under its family: data/<family>/<stage>[-rN]
# (stages: spec, arch, plan, implement, review, ship, design, qa - the short names match
# the id suffixes). Direct tasks and plain scouts stay flat at data/<id>.
# Family-level files (room.md, gate artifacts) live at data/<family>/ root.
# A roomchief's own data dir nests the same way, at data/<family>/chief, but
# `chief` is NOT a staged-flow production stage: it carries no brief (the room
# IS the roomchief's brief) and ac-brief.sh's stage whitelist refuses it.

ac_stage_dir_for_id() {
  # ac_stage_dir_for_id <id> - the "<family>/<stage>[-rN]" subpath a staged id
  # maps to, empty for an unsuffixed id. Revision ids keep their suffix:
  #   sample-task-spec -> sample-task/spec
  #   sample-task-spec-r2 -> sample-task/spec-r2
  # -chief is an ordinary arm too (a roomchief's own data dir nests under its
  # family instead of a phantom data/<family>-chief/ sibling):
  #   sample-task-chief -> sample-task/chief
  # Pure suffix grammar, with NO disk check - it doubles as the "where do I
  # CREATE this brief" resolver (ac-brief.sh), which cannot require a dir it
  # is about to create. Family MEMBERSHIP (does this suffix actually name an
  # existing family) is ac_family_of_id's own, stricter concern. ac-brief.sh's
  # own stage whitelist still refuses `--stage chief`, so this never becomes a
  # briefable production stage.
  local id="$1" base rev="" fam stage
  base="$id"
  case "$base" in
    *-r[0-9]|*-r[0-9][0-9]) rev="-r${base##*-r}"; base="${base%-r*}" ;;
  esac
  case "$base" in
    *-spec)   fam="${base%-spec}";   stage=spec ;;
    *-arch)   fam="${base%-arch}";   stage=arch ;;
    *-plan)   fam="${base%-plan}";   stage=plan ;;
    *-review) fam="${base%-review}"; stage=review ;;
    *-ship)   fam="${base%-ship}";   stage=ship ;;
    *-design) fam="${base%-design}"; stage=design ;;
    *-qa)     fam="${base%-qa}";     stage=qa ;;
    *-chief)  fam="${base%-chief}";  stage=chief ;;
    *)
      # A bare revision id (<family>-rN, no stage suffix) is a same-stage
      # implement revision per section 5 - it nests as <family>/implement-rN.
      # Direct -rN ids stay usable: ac_task_dir falls back to the flat dir
      # when no such nested brief exists.
      [ -n "$rev" ] && printf '%s/implement%s\n' "$base" "$rev"
      return 0 ;;
  esac
  [ -n "$fam" ] || return 0
  printf '%s/%s%s\n' "$fam" "$stage" "$rev"
}

ac_task_dir() {
  # ac_task_dir <id> - the data dir holding <id>'s brief/report, resolved by
  # what EXISTS: the nested staged dir when its brief lives there (for an
  # unsuffixed id that means data/<id>/implement), else the flat data/<id>.
  # Briefs in both places is ambiguous and dies. Neither existing prints the
  # flat dir - callers that need the brief check for it themselves.
  #
  # A roomchief (<family>-chief) never has a brief - the room IS its brief
  # (AGENTS.md section 8) - so the nested chief dir is accepted on its
  # FAMILY existing on disk instead (a promoted family always has
  # data/<family>/room.md before its roomchief is ever spawned), never on the
  # chief dir itself existing: ac_status_timeline_mirror's own mkdir is what
  # creates that dir, so this resolver cannot require it first
  # (chicken-and-egg). A family whose OWN name merely ends in -chief (no
  # parent data/<base>/ dir) never satisfies this and keeps resolving flat.
  local id="$1" d sub nested="" flat stage fam
  d="$(ac_data_dir)"
  flat="$d/$id"
  sub="$(ac_stage_dir_for_id "$id")"
  if [ -n "$sub" ]; then
    nested="$d/$sub"
    stage="${sub#*/}"
    fam="${sub%%/*}"
  elif [ -f "$flat/implement/brief.md" ]; then
    nested="$flat/implement"
  fi
  if [ -n "$nested" ] \
    && { [ -f "$nested/brief.md" ] || { [ "${stage:-}" = chief ] && [ -d "$d/$fam" ]; }; }; then
    [ -f "$flat/brief.md" ] \
      && ac_die "ambiguous task data for $id: briefs at both $nested and $flat"
    printf '%s\n' "$nested"
    return 0
  fi
  printf '%s\n' "$flat"
}

ac_room_file() {
  # ac_room_file <family> - the room path a HISTORY read must use: the live
  # data/<family>/room.md when it exists, else the archived copy that
  # bin/ac-archive.sh (that script's header owns the archive layout) moved to
  # data/archive/<year>/<family>/room.md. Neither existing prints the LIVE
  # path, so a caller that CREATES a room still writes it live.
  #
  # READ side only, deliberately. ac-room.sh's own room_file() stays the live
  # path for `post`/`close`: appending into an archived room would hide a
  # re-opened family from `list`, the captain inbox and the turn-end guard, all
  # of which glob data/*/room.md by design (every archived family is CLOSED, so
  # they contribute nothing there - measured, not assumed). Posting to an
  # archived family therefore opens a FRESH live room; restore it first
  # (`ac-archive.sh restore <family>`) when one continuous room is wanted.
  #
  # The charset guard is ac-room.sh cmd_post's, verbatim: an unsafe family name
  # would otherwise reach the archive GLOB below, where a `*` matches some other
  # family's archived room and answers confidently with the wrong file.
  local fam="$1" live archived
  live="$(ac_data_dir)/$fam/room.md"
  [ -f "$live" ] && { printf '%s\n' "$live"; return 0; }
  case "$fam" in *[!a-zA-Z0-9_-]*) printf '%s\n' "$live"; return 0 ;; esac
  for archived in "$(ac_data_dir)"/archive/*/"$fam"/room.md; do
    [ -f "$archived" ] || continue
    printf '%s\n' "$archived"
    return 0
  done
  printf '%s\n' "$live"
}

# --- backlog Done-line grammar: the ONE parser three sites share --------------
#
# AUTHORITATIVE for how a `records/backlog.md` line (AGENTS.md section 9) is
# decomposed into fields. THREE awk sites parse this line - ac-ready.sh's
# snapshot(), ac-curate.sh's _backlog_plan(), ac-learn.sh's
# learn_retro_snapshot() - and their private copies DRIFTED (the learn parser
# landed inert against the real ledger's date/verb shapes). This is their single
# source: an awk function block each site prepends to its own program with
# `awk "$AC_DONELINE_AWK"'<program>'`, so every site keeps its own surrounding
# walk (section tracking, line numbers, windowing) and only the field extraction
# is shared.
#
# ac_doneline(line, f) ALSO fills f["contract"] - the DELIVERY-CONTRACT token
# group (delivery-contract-on-the-row): the FIRST leading-run, unquoted `[...]`
# group whose EVERY whitespace-separated token is `key:value` with a key from
# the closed set src|flow|mode|rev|qa|promote - e.g.
# `[src:cap flow:direct mode:local-only rev:no qa:no]` - returned as the bare
# content, else "". The all-tokens-keyed test is the discriminator that keeps
# every EXISTING group class untouched: a provenance tag (`[CAPTAIN-ORDERED
# 2026-08-10 ...]`) carries non-kv words, `[EPIC]`/`[failed]`/`[@held]` carry
# none, and a backtick-quoted group is a mention exactly as it is for hold.
# VALUE validity is deliberately NOT judged here - the parser extracts,
# `ac_contract_lint` (after this block) judges - so a typo'd value surfaces at
# lint instead of silently vanishing the whole group.
#
# ac_doneline(line, f) fills the `f` array (passed by reference; named `f` so it
# never shadows a caller's own global `out` array - ac-curate has one) with:
#   f["id"]       - first whitespace token after the `- [ ]`/`- [x]` checkbox.
#   f["terminal"] - "epic"|"failed"|"abandoned" when that bracket token sits at
#                   the FIXED grammar position (rp[2], immediately after the id),
#                   else "". A token check, NEVER a substring match against the
#                   whole line: a prose mention of [failed] is not a terminal
#                   state (the ready-marker-matches-prose-not-position incident).
#   f["hold"]     - "1" when the row carries the captain-hold token `[@held]`
#                   as one of the line's top-level `[...]` groups AND that
#                   group sits in the LEADING RUN - the contiguous run of
#                   `[...]` groups starting immediately after the id, nothing
#                   but whitespace between them - else "". A hold is not a
#                   terminal state (nothing lands to clear it) and not the
#                   dependency token (no blocker id, no STUCK semantics) - its
#                   own field. NOT pinned to rp[2] the way `terminal` is: a
#                   live ledger row's rp[2] is usually ALREADY another bracket
#                   tag (`[CAPTAIN-ORDERED ...]`, `[MONITOR ...]`, `[EPIC]`),
#                   so `[@held]` has no legal rp[2] slot to occupy on most rows
#                   (measured: 3 of 4 open rows on the drydock ledger) - the
#                   WHOLE leading run is checked, not just its first group.
#                   THE TOKEN CARRIES A SENTINEL (`@`) FOR A MEASURED REASON:
#                   an earlier `[held]` (bare word, no sentinel) design was
#                   still structural - bracket syntax required - and STILL
#                   false-positived on a real ledger row, because this
#                   grammar's OTHER bracket tags (`[SLICE ...]`, `[CAPTAIN
#                   ORDER LANDED ...]`) carry free-text PROSE, and that prose
#                   uses "held"/"hold" as ordinary English verbs ("the
#                   guardrail held", "Held until now on a verified
#                   collision"). Bracket syntax alone cannot tell a token from
#                   a sentence inside a free-text tag. `@` immediately before
#                   the word is the part ordinary prose never writes -
#                   nobody types "the guardrail @held" - so matching on the
#                   SENTINEL rather than the bare word keeps both properties:
#                   structural (still requires `[...]`) AND immune to a
#                   free-text tag's ordinary prose.
#                   LEADING-RUN POSITION IS ALSO MEASURED, not assumed: bracket
#                   syntax and a sentinel still cannot tell a real token from a
#                   QUOTATION of one - a row, a receipt, or AGENTS.md itself
#                   documenting the grammar has to WRITE `[@held]` to describe
#                   it, and a whole-line scan would silently hold that row too
#                   (the exact bug this field exists to kill, reproduced on
#                   itself). Restricting authority to the leading run does not
#                   by itself fix that - a quotation sitting right after some
#                   OTHER id would still be positional - so position combines
#                   with the CODE-SPAN rule below; between them, a `[@held]`
#                   outside the leading run is never authoritative, and one
#                   wrapped in backticks is never authoritative even inside it.
#   f["hold_malformed"] - "1" when a `[...]` group is a mis-typed hold
#                   attempt and is NOT wrapped in a code span (see QUOTATION
#                   below), by EITHER of two rules, each catching a different
#                   slip:
#                   (1) the group case-insensitively contains "@held" or
#                       "@hold" but is not an AUTHORITATIVE `[@held]` (see
#                       f["hold"] above: exact text AND leading-run position) -
#                       `[@hold]`, `[@HELD]`, `[@Held]`, `[@helds]`, ... AND a
#                       well-formed `[@held]` sitting OUTSIDE the leading run,
#                       unquoted. That last case is deliberate: position
#                       decides AUTHORITY, so a token typed in the WRONG PLACE
#                       never earns hold=1, but it must not silently fall
#                       through to READY either - a real hold mis-placed by a
#                       keystroke is exactly the failure this field exists to
#                       catch, so it fails the SAME closed direction as any
#                       other mis-type instead of opening a second escape.
#                   (2) the group's content (bracket-stripped) is a SINGLE
#                       WORD - no whitespace - and case-insensitively
#                       contains "held" or "hold": `[held]`, `[hold]`,
#                       `[HELD]`, `[on-hold]`, ... (the sentinel itself
#                       forgotten - the single most likely slip on a
#                       sentinel-bearing token, and the one this field could
#                       not yet catch). A ONE-WORD group can never be prose -
#                       it is exactly one token, not a sentence - so it needs
#                       no sentinel to be recognized as a hold ATTEMPT; a
#                       free-text tag's prose (`[SLICE ...]`, `[CAPTAIN ORDER
#                       LANDED ...]`) is always multi-word and never matches
#                       rule (2) (measured against the live ledger's actual
#                       one-word bracket groups - `[x]`, `[abandoned]`,
#                       `[failed]`, `[project]`, `[needs-decision]`, `[0]` -
#                       zero false positives today). Position never gates this
#                       rule: a mis-typed shape is never authoritative to
#                       begin with, so there is no "wrong place" for it to be
#                       demoted from - only QUOTATION exempts it.
#                   Either rule failing CLOSED (HELD, not READY) is the same
#                   direction blockers_malformed already picked for a
#                   mis-typed `blocked-by` (below); "hold" is caught
#                   alongside "held" in both rules because it is the nearest
#                   possible miss: the feature's own name, present-tense.
#                   QUOTATION: a `[...]` group immediately wrapped in a code
#                   span - a backtick directly before `[` and directly after
#                   `]`, the same backtick-wrap convention `bin/ac-spawn.sh`
#                   already uses so a narrative marker verb never trips its
#                   own detector - is a documentation mention, exempt from
#                   BOTH f["hold"] and f["hold_malformed"] regardless of its
#                   content or position: a row explaining the grammar can
#                   write `` `[@held]` `` or `` `[held]` `` without holding or
#                   flagging itself.
#   f["epic"]     - the id in an `epic:<id>` token anywhere on the line, else "".
#   f["blockers"] - the comma-joined ids in a `blocked-by: <ids>` token, else "".
#   f["date"]     - the first YYYY-MM-DD inside the LAST top-level (non-nested)
#                   parenthetical group; fallback to the LAST YYYY-MM-DD anywhere
#                   on the line when that group carries none (a nested-paren tail,
#                   or a verb+date sitting outside any group). No date -> "".
#                   The real ledger annotates the date group with trailing prose
#                   (`(merged <date>; <note>)`) and trails more prose after it, so
#                   the group is not anchored to end-of-line.
#   f["verb"]     - the word immediately before that date; "unknown" when the
#                   group is a bare `(date)` or the word is not verb-shaped. The
#                   ledger uses done/closed/ended/delivered/merged/reported and
#                   more; this never invents a verb the ledger did not write.
# A site needing the failed/abandoned-OR-verb "marker" (ac-learn) composes it:
# terminal in {failed,abandoned} ? terminal : verb.
read -r -d '' AC_DONELINE_AWK <<'ACAWK' || true
function ac_doneline(line, f,    rest, rp, seg, grp, searchpos, pre, pp, i, n, fpos, fseg, flast, flaststart, cand, bafter, hpos, hseg, hgrp, hcontent, idend, runpos, inrun, gstart, gend, positional, between, leftch, rightch, quoted, ctok, cn, ci, callkv) {
  f["id"] = ""; f["terminal"] = ""; f["hold"] = ""; f["hold_malformed"] = ""; f["epic"] = ""
  f["blockers"] = ""; f["blockers_malformed"] = ""; f["date"] = ""; f["verb"] = ""; f["contract"] = ""
  rest = line
  sub(/^- \[[ x]\] /, "", rest)
  split(rest, rp, " ")
  f["id"] = rp[1]
  if (rp[2] == "[EPIC]")           f["terminal"] = "epic"
  else if (rp[2] == "[failed]")    f["terminal"] = "failed"
  else if (rp[2] == "[abandoned]") f["terminal"] = "abandoned"
  # Every top-level `[...]` group on the line, not just rp[2]; matched on the
  # `@` SENTINEL, not the bare word - see f["hold"] above for why. Structural
  # (requires the literal bracket syntax) AND immune to a free-text tag's
  # ordinary prose use of "held"/"hold" as a verb. hold_malformed's rule (2)
  # (see f["hold_malformed"] above) needs no sentinel: a ONE-WORD group is
  # never prose, so "held"/"hold" alone in one is still a hold attempt.
  # POSITION decides AUTHORITY: only a group in the LEADING RUN - the id's own
  # `[...]` groups, contiguous, nothing but whitespace between them - can set
  # hold=1. A CODE SPAN decides QUOTATION: a group wrapped in backticks is a
  # documentation mention, never a token and never an attempt, wherever it
  # sits. A bare (unquoted) token-shaped group OUTSIDE the leading run still
  # falls to hold_malformed instead of "no match" - never silently READY.
  match(line, /^- \[[ x]\] [^ \t]+/)
  idend = RLENGTH
  hpos = idend + 1
  runpos = hpos
  inrun = 1
  while (1) {
    hseg = substr(line, hpos)
    if (hseg == "" || !match(hseg, /\[[^][]*\]/)) break
    gstart = hpos + RSTART - 1
    hgrp = substr(line, gstart, RLENGTH)
    gend = gstart + RLENGTH - 1
    positional = 0
    if (inrun) {
      between = substr(line, runpos, gstart - runpos)
      if (between ~ /^[ \t]*$/) { positional = 1; runpos = gend + 1 }
      else inrun = 0
    }
    leftch = ""
    if (gstart > 1) leftch = substr(line, gstart - 1, 1)
    rightch = substr(line, gend + 1, 1)
    quoted = (leftch == "`" && rightch == "`")
    # The delivery-contract group (header note above): leading-run, unquoted,
    # EVERY token key:value from the closed key set, first one wins. No
    # contract-shaped content can also be a hold (the key set spells neither
    # "held" nor "hold"), so claiming the group here steals nothing.
    hcontent = substr(hgrp, 2, length(hgrp) - 2)
    callkv = 0
    if (!quoted && positional && f["contract"] == "" && hcontent != "") {
      cn = split(hcontent, ctok, /[ \t]+/)
      callkv = (cn > 0)
      for (ci = 1; ci <= cn; ci++)
        if (ctok[ci] !~ /^(src|flow|mode|rev|qa|promote):[a-z][a-z-]*$/) { callkv = 0; break }
    }
    if (callkv) {
      f["contract"] = hcontent
    } else if (quoted) {
      # a documentation mention - never a token, never an attempt
    } else if (positional && hgrp == "[@held]") {
      f["hold"] = "1"
    } else if (tolower(hgrp) ~ /@held|@hold/) {
      f["hold_malformed"] = "1"
    } else {
      hcontent = substr(hgrp, 2, length(hgrp) - 2)
      if (hcontent !~ /[ \t]/ && tolower(hcontent) ~ /held|hold/) f["hold_malformed"] = "1"
    }
    hpos = gend + 1
  }
  if (match(line, /epic:[a-zA-Z0-9_-]+/))
    f["epic"] = substr(line, RSTART + 5, RLENGTH - 5)
  # blocked-by is read STRICTLY and its slips are detected LENIENTLY. The
  # strict shape is the pinned one (AGENTS.md section 9, `blocked-by: id1,id2 -
  # reason`): one space, lowercase, comma-joined with no empty component, and
  # ended by whitespace or end-of-line. Anything else leaves blockers EMPTY -
  # which ac-ready.sh reads as READY - so a one-character slip would authorize
  # starting a story whose dependency is still flying. A line that carries a
  # blocked-by token the strict parse did not consume is therefore MALFORMED,
  # a state its consumers must refuse to schedule. A prose mention of the token
  # trips this too; that is the fail-VISIBLE direction, and the line is one
  # keystroke from legal.
  if (match(line, /blocked-by: [a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*/)) {
    bafter = substr(line, RSTART + RLENGTH, 1)
    if (bafter == "" || bafter == " " || bafter == "\t")
      f["blockers"] = substr(line, RSTART + 12, RLENGTH - 12)
  }
  if (f["blockers"] == "" && tolower(line) ~ /(^|[^a-z0-9_-])blocked-by/)
    f["blockers_malformed"] = "1"
  # Date in the LAST non-nested parenthetical group; verb = the word before it.
  searchpos = 1; grp = ""
  while (1) {
    seg = substr(line, searchpos)
    if (seg == "" || !match(seg, /\([^()]*\)/)) break
    grp = substr(seg, RSTART + 1, RLENGTH - 2)
    searchpos = searchpos + RSTART + RLENGTH - 1
  }
  if (grp != "" && match(grp, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
    f["date"] = substr(grp, RSTART, RLENGTH)
    pre = substr(grp, 1, RSTART - 1)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", pre)
    if (pre == "") f["verb"] = "unknown"
    else { split(pre, pp, /[[:space:]]+/); f["verb"] = (pp[1] ~ /^[A-Za-z][A-Za-z_-]*$/) ? pp[1] : "unknown" }
  }
  # Fallback: last YYYY-MM-DD anywhere; verb = the word immediately before it.
  if (f["date"] == "") {
    fpos = 1; flast = ""; flaststart = 0
    while (1) {
      fseg = substr(line, fpos)
      if (fseg == "" || !match(fseg, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) break
      flaststart = fpos + RSTART - 1
      flast = substr(fseg, RSTART, RLENGTH)
      fpos = flaststart + RLENGTH
    }
    if (flast != "") {
      f["date"] = flast
      pre = substr(line, 1, flaststart - 1)
      sub(/[[:space:]]+$/, "", pre)
      n = split(pre, pp, /[^A-Za-z_-]+/)
      cand = (n > 0) ? pp[n] : ""
      f["verb"] = (cand ~ /^[A-Za-z][A-Za-z_-]*$/) ? cand : "unknown"
    }
  }
}
ACAWK

# --- delivery-contract lint ----------------------------------------------------
# ac_contract_lint <contract-content> - one violation per line, empty output
# when clean, exit 0 always (a judge, not a gate). The VALUE vocabulary lives
# HERE, the one judge - the parser above extracts shape only. Also flags the
# two combinations AGENTS.md section 5 already outlaws (flow:staged with
# rev:no; mode:crew-ship with rev:no) so a contract contradicting the law is
# loud at the scheduler instead of surprising the pipeline.
ac_row_contract_for_id() {
  # ac_row_contract_for_id <id> <backlog-file> - the delivery-contract group
  # governing <id>: the exact row when one exists, else the FAMILY row (a
  # staged task's id is <family>-<stage>[-rN], but its pins live on the
  # family's ledger row - the escalation-gate demo caught the exact-only
  # lookup reading a pinned family as unpinned). An exact row's NON-EMPTY
  # contract wins over the family's (more specific consent beats broader);
  # a contractless exact row falls through - the grammar has no "empty
  # group revokes the family pin" concept. Prints "" when neither row
  # carries a contract.
  local id="$1" f="$2" fam sub out
  [ -f "$f" ] || { printf '\n'; return 0; }
  out="$(awk -v want="$id" "$AC_DONELINE_AWK"'
    /^- \[[ x]\] / { ac_doneline($0, o); if (o["id"] == want) { print o["contract"]; exit } }
  ' "$f")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  sub="$(ac_stage_dir_for_id "$id")"
  [ -n "$sub" ] || { printf '\n'; return 0; }
  fam="${sub%%/*}"
  awk -v want="$fam" "$AC_DONELINE_AWK"'
    /^- \[[ x]\] / { ac_doneline($0, o); if (o["id"] == want) { print o["contract"]; exit } }
  ' "$f"
}

ac_contract_lint() {
  local c="$1" tok key val flow="" mode="" rev=""
  [ -n "$c" ] || return 0
  for tok in $c; do
    key="${tok%%:*}"; val="${tok#*:}"
    case "$key" in
      src)
        case "$val" in cap|chief|mon|gh|crew|learn) ;; *) printf 'src:%s invalid - want cap|chief|mon|gh|crew|learn\n' "$val" ;; esac ;;
      flow)
        flow="$val"
        case "$val" in direct|staged) ;; *) printf 'flow:%s invalid - want direct|staged\n' "$val" ;; esac ;;
      mode)
        mode="$val"
        case "$val" in crew-ship|direct-pr|local-only) ;; *) printf 'mode:%s invalid - want crew-ship|direct-pr|local-only\n' "$val" ;; esac ;;
      rev)
        rev="$val"
        case "$val" in yes|no) ;; *) printf 'rev:%s invalid - want yes|no\n' "$val" ;; esac ;;
      qa)
        case "$val" in yes|no) ;; *) printf 'qa:%s invalid - want yes|no\n' "$val" ;; esac ;;
      promote)
        case "$val" in no) ;; *) printf 'promote:%s invalid - want no (always is the default and is never written)\n' "$val" ;; esac ;;
    esac
  done
  [ "$flow" = staged ] && [ "$rev" = no ] \
    && printf 'flow:staged with rev:no - staged review is mandatory (AGENTS.md section 5)\n'
  [ "$mode" = crew-ship ] && [ "$rev" = no ] \
    && printf 'mode:crew-ship with rev:no - crew-ship review is mandatory (AGENTS.md section 5)\n'
  return 0
}

# --- task state files ---------------------------------------------------------

ac_task_meta() { printf '%s/%s.meta\n' "$(ac_state_dir)" "$1"; }
ac_task_status() { printf '%s/%s.status\n' "$(ac_state_dir)" "$1"; }

ac_status_append() {
  # ac_status_append <id> <line> - timestamped append to the task event log.
  # Writes the VOLATILE state/<id>.status (reaped at teardown) AND MIRRORS the
  # same timestamped line to a DURABLE data-dir timeline.log so a task's full
  # lifecycle survives teardown (task-timeline). The PRIMARY write's own
  # failure is this function's return status - a caller that guards the call
  # (`ac_status_append ... || ...`) is told. The mirror stays fail-SOFT: it
  # never breaks or meaningfully slows this write, and never changes the
  # return status either way.
  local ts rc; ts="$(ac_iso)"
  printf '%s %s\n' "$ts" "$2" >>"$(ac_task_status "$1")"; rc=$?
  ac_status_timeline_mirror "$1" "$ts" "$2" 2>/dev/null || true
  return "$rc"
}

ac_status_timeline_mirror() {
  # ac_status_timeline_mirror <id> <iso-ts> <line> - append the SAME event line
  # to the task's DURABLE data dir ($(ac_task_dir <id>)/timeline.log), so every
  # lifecycle transition already flowing through ac_status_append is durable for
  # free (one chokepoint, no per-call-site instrumentation). Fail-SOFT and never
  # errors to its caller:
  #   - a verify-* pane owns no durable task dir -> skip;
  #   - ac_task_dir dying on ambiguous data -> skip;
  #   - a dir that does not exist yet is created only for a real task (a meta on
  #     disk), else skipped - never a phantom dir.
  local id="$1" ts="$2" line="$3" meta dir
  meta="$(ac_task_meta "$id")"
  ac_meta_is_verify "$meta" && return 0
  dir="$(ac_task_dir "$id" 2>/dev/null)" || return 0
  [ -n "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    [ -f "$meta" ] || return 0
    mkdir -p "$dir" 2>/dev/null || return 0
  fi
  printf '%s %s\n' "$ts" "$line" >>"$dir/timeline.log"
}

# --- the VERIFICATION-agent class ---------------------------------------------
#
# AUTHORITATIVE for what makes a `state/<id>.meta` a verification agent rather
# than a crewmate. `state/<id>.meta` is not storage, it is a NAMESPACE meaning
# "a crewmate in flight" (that is why the learn/curate counters at :332 and :454
# are dot-prefixed - a bare .meta there reads as a phantom crewmate). A
# verification pane agent - a ship reviewer, a gate judge, a qa run - lives in
# that namespace so the watcher can supervise it, but it is NOT crew: it holds
# no backlog row and no crew branch. Exact-ref codereview/qa verifiers do hold a
# short-lived isolated worktree lease, owned and returned by ac-verify.sh.
#
# The class is the `verify-*` PREFIX on the meta's own `kind` - a PREFIX and not
# an enumerated list, so a fifth pane kind is covered the day someone adds it,
# and read from the META and never re-derived from the id by a consumer. Every
# kind on disk today (ship, scout, roomchief, crewdeputy) fails CLOSED to
# "crewmate", which is what keeps behaviour byte-identical until a verifier
# actually writes one.
#
# EXCLUDED FROM ACCOUNTING, NEVER FROM SUPERVISION. Its six consumers:
#   - ac-watch.sh check_fleet     - does NOT branch: the watcher polls a verifier
#                                   exactly like a crewmate (gone:/ask:/ended:)
#   - ac_chief_child_live (ac-wake-lib.sh) - not a live family child
#   - ac-room.sh close            - never blocks a family room from closing
#   - ac-teardown.sh landed_proof - never blocks a roomchief demote
#   - ac-wake-drain.sh            - out of report_completions and the
#                                   WATCHER-DOWN inflight tally
#   - ac-fleets.sh                - reported in its own `verify[]` array, never
#                                   in crew.tasks[] or crew.count

ac_meta_is_verify() {
  # ac_meta_is_verify <meta-file> - 0 when this meta belongs to a VERIFICATION
  # agent, 1 otherwise (including an absent or kind-less meta - fail closed).
  case "$(ac_meta_get "$1" kind 2>/dev/null || true)" in
    verify-*) return 0 ;;
  esac
  return 1
}

# --- the SELF-TASK class -------------------------------------------------------
#
# AUTHORITATIVE for what makes a `state/<id>.meta` a chief SELF TASK. It is the
# meta bin/ac-self-task.sh writes (kind=self, exact match) so a small edit the
# CHIEF makes itself is still visible on herdr and in every fleet view - the
# "no invisible tasks" rule. Its pane holds a
# `tail -f` on the task's progress log and NOTHING ELSE.
#
# EXCLUDED FROM SUPERVISION, NEVER FROM ACCOUNTING - the exact mirror image of
# the verification class above, and for the one reason that separates them: a
# verifier pane holds an AGENT, so a chief must be woken about it; a self task's
# agent IS the chief. Demanding a watcher for that pane would demand coverage of
# a pane that can never emit a captain marker, and polling it would wake the
# chief about its own typing - a self-loop, and a turn end the chief could never
# reach while editing. So the four SUPERVISION-DEMAND surfaces skip it:
#   - ac-watch.sh check_fleet     - not polled (no markers, no stale/ended wakes)
#   - ac-guard.sh                 - out of the WATCHER-DOWN inflight tally
#   - ac-wake-drain.sh            - out of that same tally
#   - ac-watch-autoarm.sh / ac-turnend-guard.sh - owes no Stop-hook coverage
# ACCOUNTING is deliberately untouched: ac-dash.sh, ac-fleets.sh,
# ac-fleet-view.sh and ac-statusline.sh all render it as the crewmate row it is,
# which is the entire point of the mechanism. Landing is untouched too - teardown
# reads it as an ordinary committing task and ac-merge-local.sh needs no kind.
# Every other kind fails CLOSED to "not a self task", so nothing on disk today
# changes behaviour.

ac_meta_is_self() {
  # ac_meta_is_self <meta-file> - 0 when this meta belongs to a chief SELF TASK,
  # 1 otherwise (including an absent or kind-less meta - fail closed).
  [ "$(ac_meta_get "$1" kind 2>/dev/null || true)" = self ]
}

ac_crew_metas() {
  # ac_crew_metas <state_dir> [skip-class...] - print the task meta paths under
  # <state_dir>, one per line in glob order, dropping the named classes:
  #   verify - kind=verify-* pane agents (ac_meta_is_verify's prefix class)
  #   self   - kind=self chief self-tasks (ac_meta_is_self's class)
  #   chiefs - kind=roomchief|crewdeputy supervisor sessions
  # The ONE enumerator behind every "is this crew?" glob loop (audit-f4: the
  # loops had drifted into four independently-maintained filter policies, and
  # even their COUNT was disputed because each report counted a different
  # thing). The counting rule this file now fixes: an enumerator is a glob
  # loop over <state_dir>/*.meta that filters by crew-ness; each one calls
  # this and NAMES its policy as skip-classes. The policies stay deliberately
  # different per consumer - the watcher skips only self (verifier panes are
  # supervised; ac-watch.sh:1067's contract), supervision tallies skip
  # verify+self (a self task owes no watcher - the SELF-TASK block above),
  # accounting skips only verify (a self task is still listed) - but the
  # class DEFINITIONS live here once, in ONE awk pass for N metas instead of
  # one ac_meta_get fork per meta. kind reads last-write-wins, ac_meta_get's
  # rule; a meta that is empty or vanishes mid-read has no kind and is
  # COUNTED, fail-safe, exactly as the open-coded loops counted it.
  local sd="$1" c sv=0 ss=0 sc=0
  shift
  for c in "$@"; do
    case "$c" in
      verify) sv=1 ;;
      self) ss=1 ;;
      chiefs) sc=1 ;;
      *) ac_die "ac_crew_metas: unknown skip-class '$c' (verify|self|chiefs)" ;;
    esac
  done
  set -- "$sd"/*.meta
  [ -e "$1" ] || return 0
  awk -v sv="$sv" -v ss="$ss" -v sc="$sc" '
    BEGIN {
      for (i = 1; i < ARGC; i++) {
        file = ARGV[i]; kind = ""
        while ((getline line < file) > 0)
          if (line ~ /^kind=/) kind = substr(line, 6)
        close(file)
        if (sv && kind ~ /^verify-/) continue
        if (ss && kind == "self") continue
        if (sc && (kind == "roomchief" || kind == "crewdeputy")) continue
        print file
      }
    }
  ' "$@"
}

ac_task_stamps() {
  # ac_task_stamps <state_dir> <id> - print every per-id watcher stamp path,
  # one per line: the AUTHORITATIVE reap list (audit-f4). The writers stay in
  # bin/ac-watch.sh and bin/ac-done.sh; the reapers (ac-teardown.sh's
  # reap_watcher_stamps) iterate THIS list instead of a hand copy - the hand
  # list had already leaked once (11 orphan .change-* stamps observed live,
  # ac-teardown.sh's own comment), then leaked again by omission when
  # .seen-hash-/.report-hash-/.superseded- were added with no reaper at all.
  # A new stamp kind is added HERE, beside the ones it rides with.
  local sd="$1" tid="$2" b
  for b in hash change seen seen-hash stale gone ask unobservable \
    report-hash superseded; do
    printf '%s/.%s-%s\n' "$sd" "$b" "$tid"
  done
}

ac_task_backend() {
  # ac_task_backend <id> - backend the task was spawned on (meta), herdr default.
  local b
  b="$(ac_meta_get "$(ac_task_meta "$1")" backend)"
  printf '%s\n' "${b:-herdr}"
}

ac_captain() {
  # ac_captain - how to address the human. config/captain overrides the
  # default role word, e.g. `echo TN > config/captain`.
  ac_config_read captain captain
}

# --- landing ledger: the cross-family file interlock ---------------------------
#
# AUTHORITATIVE for the ledger at state/.landings and its two write/warn
# consumers. One TSV record per landed file - `epoch \t family \t path` -
# appended by the merge helpers (ac-merge-local.sh, ac-pr-merge.sh) after
# every landing. Paths are the branch's OWN changes since it diverged from the
# merge target, so a family records exactly the files it adds even when the
# target has advanced past the branch: ac-merge-local.sh takes the three-dot
# merge-base range `git diff $default...$branch` (NOT the two-dot tree diff,
# which would reverse-report other families' files and mis-attribute them to
# this family, pointing the warn at the wrong room); ac-pr-merge.sh takes
# `gh pr diff`, already the PR's own changes relative to its base.
# Bounded: every append prunes records older than 7 days, so the file never grows.
# Consumers:
#   - the LANDING WARN (same two helpers, BEFORE merging): a touched file
#     landed <24h ago by a DIFFERENT family gets one prominent
#     LANDING-OVERLAP line naming the file, the prior family, and its room
#     (data/<family>/room.md) as required reading. Warn-only, never refuses -
#     the chief judges. (The incident: two families landed OPPOSITE
#     conclusions on one file within hours because the second lander never
#     saw the first family's room evidence.)
#   - the INTAKE CHECK - `ac-ready.sh overlap` (that header owns the verb):
#     read-only ledger + in-flight lookups on an order's expected files.
# The family of a landing id is the id with its stage/revision suffix
# stripped (ac_family_of_id), so <task>-ship landing after <task>'s own
# stages stays silent and the named room is the family's.

ac_landings_path() { printf '%s/.landings\n' "$(ac_state_dir)"; }

ac_family_of_id() {
  # ac_family_of_id <id> - the family a task id belongs to: the family part
  # for staged/revision ids (audit-ship -> audit, audit-r2 -> audit), the id
  # itself for flat ids. Suffix grammar owner: ac_stage_dir_for_id.
  #
  # A plain stage suffix (no -rN) is trusted only when its nested dir
  # data/<family>/<stage> actually exists - a flat id that merely COLLIDES
  # with a stage suffix (dash-review, no data/dash/) stays its own family
  # instead of reading as a stage of a family nobody ever created
  # (family-of-id-suffix-collision).
  #
  # A STAGED revision (foo-spec-r2) checks the BASE stage dir
  # data/<family>/<stage> (the -rN stripped), never the revision-specific
  # data/<family>/<stage>-rN: a genuine revision's base stage was already
  # briefed (its first round exists before any revision is ever asked for),
  # while the -rN dir itself may not exist yet at THIS call - the same
  # chicken-and-egg ac-brief.sh's own crew_branch reorder works around. When
  # the base dir is absent, a stage-suffixed revision of a flat id must land
  # on the SAME family as the un-revised flat id, never on a family the
  # un-revised id itself does not have (dash-review-r2 with no data/dash/
  # resolves to dash-review, matching dash-review - a revision of a flat id
  # must never end up on a different crew branch than the task it revises).
  #
  # A BARE revision (foo-r2, no stage suffix at all) stays unconditional: no
  # stage suffix means nothing to doubt, and a direct task's own
  # data/<id>/implement never exists to check against (tests/ac-lib.test.sh's
  # ac_crew_branch 'foo-r2' case is exercised standalone, no dir ever
  # scaffolded).
  local sub stage base_stage
  sub="$(ac_stage_dir_for_id "$1")"
  [ -n "$sub" ] || { printf '%s\n' "$1"; return 0; }
  stage="${sub#*/}"
  case "$stage" in
    implement-r[0-9]|implement-r[0-9][0-9])
      printf '%s\n' "${sub%%/*}"; return 0 ;;
    *-r[0-9]|*-r[0-9][0-9])
      base_stage="${stage%-r*}"
      if [ -d "$(ac_data_dir)/${sub%%/*}/$base_stage" ]; then
        printf '%s\n' "${sub%%/*}"
      else
        printf '%s\n' "${1%-r*}"
      fi
      return 0 ;;
  esac
  if [ -d "$(ac_data_dir)/$sub" ]; then
    printf '%s\n' "${sub%%/*}"
  else
    printf '%s\n' "$1"
  fi
}

ac_crew_branch() {
  # ac_crew_branch <id> - canonical `crew/<family>` branch name for a task id.
  # The one derivation both the brief and the local-land agree on, so a
  # family-scoped id (staged/revision/epic story) never needs a hand-made
  # alias branch. Family grammar owner: ac_family_of_id.
  printf 'crew/%s\n' "$(ac_family_of_id "$1")"
}

ac_family_owned() {
  # ac_family_owned <id> <state_dir> - 0 when a task is in flight that already
  # owns crew/<family> for <id>'s family, 1 when none is. Shared by every entry
  # point that commits on crew/<id> and lands via ac-merge-local.sh
  # (ac-spawn.sh, ac-self-task.sh) as the second half of THE BRANCH COLLISION
  # REFUSAL (ac-spawn.sh header owns the contract): membership is
  # ac_family_of_id, the SAME derivation ac_crew_branch builds the branch name
  # from, so owner and branch can never disagree. A VERIFICATION agent is not
  # a family child and holds no crew branch (ac_meta_is_verify owns the class).
  local id="$1" state_dir="$2" m other fam
  fam="$(ac_family_of_id "$id")"
  for m in "$state_dir"/*.meta; do
    [ -e "$m" ] || continue
    ac_meta_is_verify "$m" && continue
    other="$(basename "$m" .meta)"
    [ "$(ac_family_of_id "$other")" = "$fam" ] && return 0
  done
  return 1
}

ac_landing_record() {
  # ac_landing_record <family> <path>... - append one record per path and
  # prune records older than 7 days in the same atomic rewrite (tmp+mv), so
  # the ledger stays bounded and a reader never sees a torn file.
  #
  # SERIALIZED, because that rewrite is a read-modify-write and this ledger
  # exists for exactly the concurrency that breaks it: with room-parallel
  # roomchiefs landing autonomously, two writers each commit a snapshot taken
  # before the other's mv and the loser's records vanish. Nothing fails - only
  # the <24h LANDING-OVERLAP warn quietly stops firing for the lost files,
  # which is the interlock's entire purpose. The lock is this file's own
  # primitive; no caller holds it (the merge helpers hold no lock at all), so
  # it cannot nest.
  #
  # An acquire that TIMES OUT records anyway, loudly. The ledger is ADVISORY -
  # ac_landing_warn never refuses a merge - so the unserialized write costs at
  # most a missed warn, while returning failure here would abort a merge
  # helper on the far side of the merge it has already performed.
  local fam="$1" f tmp now p lock locked=0 rc=0
  shift
  [ "$#" -gt 0 ] || return 0
  f="$(ac_landings_path)"
  lock="$f.lock"
  if ac_lock_acquire "$lock" 10; then
    locked=1
  else
    ac_warn "landing ledger: $lock could not be acquired within 10s - recording UNSERIALIZED, so a concurrent landing's records may be lost and its <24h LANDING-OVERLAP warn may not fire for them"
  fi
  now="$(ac_now)"
  tmp="$f.tmp.$$"
  {
    if [ -f "$f" ]; then awk -F'\t' -v now="$now" 'now - $1 <= 604800' "$f"; fi
    for p in "$@"; do printf '%s\t%s\t%s\n' "$now" "$fam" "$p"; done
  } >"$tmp"
  mv "$tmp" "$f" || rc=1
  # Released on the failure path too: a held lock outlives this call otherwise
  # and stalls every later landing for as long as this process lives.
  [ "$locked" = 0 ] || ac_lock_release "$lock"
  return "$rc"
}

ac_landing_overlaps() {
  # ac_landing_overlaps <max-age-secs> <exclude-family> <path>... - print
  # `family \t age-secs \t path` for every ledger record younger than
  # <max-age-secs> whose path is one of the given paths and whose family
  # differs from <exclude-family> ('' excludes nothing). Read-only; prints
  # nothing when clean.
  local max="$1" excl="$2" f now
  shift 2
  f="$(ac_landings_path)"
  { [ -f "$f" ] && [ "$#" -gt 0 ]; } || return 0
  now="$(ac_now)"
  # The path list travels in the ENVIRON, never through `-v`: awk rejects a
  # literal newline in a -v assignment (exit 2), so every >=2-path call died.
  AC_PLIST="$(printf '%s\n' "$@")" \
    awk -F'\t' -v now="$now" -v max="$max" -v excl="$excl" '
    BEGIN { n = split(ENVIRON["AC_PLIST"], ps, "\n"); for (i = 1; i <= n; i++) want[ps[i]] = 1 }
    now - $1 < max && $2 != excl && ($3 in want) { printf "%s\t%d\t%s\n", $2, now - $1, $3 }
  ' "$f"
}

ac_landing_warn() {
  # ac_landing_warn <family> <path>... - the pre-merge LANDING WARN (see the
  # block header above): one line per <24h record from a DIFFERENT family
  # touching one of the paths. Warn-only: always returns 0.
  local fam="$1" hits pf age p
  shift
  hits="$(ac_landing_overlaps 86400 "$fam" "$@")"
  [ -n "$hits" ] || return 0
  while IFS=$'\t' read -r pf age p; do
    ac_warn "LANDING-OVERLAP: $p landed $((age / 3600))h ago by family $pf - required reading: $(ac_room_file "$pf")"
  done <<<"$hits"
  return 0
}

ac_knowledge_warn() {
  # ac_knowledge_warn <family> <project-repo> - the landing KNOWLEDGE-GAP flag:
  # this family is landing on a project and left NO repo-knowledge entry
  # behind. Warn-only, ALWAYS returns 0 - ac_landing_warn's contract verbatim,
  # because a landing may never fail over knowledge.
  #
  # A SIBLING of ac_landing_warn rather than a fold-in, for a verified reason:
  # both helpers call that one guarded on a non-empty landed[] set, and a
  # knowledge flag must fire on EVERY landing regardless of the diff's shape -
  # folding in would silently drop it for exactly the landings whose file list
  # is empty or unresolvable. The two checks also answer different questions
  # and share no state.
  #
  # The trigger is R6's, and nothing more: ABSENCE of a live entry attributable
  # to this family. It cannot tell "learned nothing" from "learned something
  # and did not write it down", and it does not try - it is a PROMPT, not a
  # detector, which is what makes warn-only the right bargain. It never reads
  # the scope map either, only the `by:` field, so an ambiguous record cannot
  # reach a landing through this path.
  local fam="${1:-}" repo="${2:-}" rec name
  [ -n "$fam" ] && [ -n "$repo" ] && [ -d "$repo" ] || return 0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  rec="$(ac_knowledge_file "$repo" 2>/dev/null)" || return 0
  name="$(ac_project_config_name "$repo" 2>/dev/null || true)"
  # ONE awk, no pipeline. The `awk | grep -q` this replaces was a latent false
  # positive under the callers' `set -o pipefail`: grep -q exits the instant it
  # matches, so on a record whose LIVE section outgrows the 64 KiB pipe buffer
  # the still-writing awk takes SIGPIPE, pipefail reports 141, and the flag
  # fires WITH the family's entry present. R6 makes this record grow with every
  # landing, forever, so every busy project reaches that size - and a flag that
  # fires when the entry is there trains chiefs to dismiss it, which costs the
  # flag its whole value.
  # The suffix is matched as a STRING, never as a regex: the family arrives
  # from ac_family_of_id, not from the writer's validated grammar, so a
  # metacharacter in it would otherwise change what the test means.
  if [ -f "$rec" ] && awk -v suffix="| by: $fam" '
      /^## Superseded/ { exit }
      /^- / && substr($0, length($0) - length(suffix) + 1) == suffix { found = 1; exit }
      END { exit(found ? 0 : 1) }
    ' "$rec"; then
    return 0
  fi
  ac_warn "KNOWLEDGE-GAP: family $fam is landing on $name with no repo-knowledge entry -
record what it learned ($(ac_root)/bin/ac-know.sh add --home $(ac_home) --repo $repo --family $fam --src-file <path>:<line> --fact '<what you learned>')
or dismiss if it learned nothing about the codebase. Record: $rec"
  return 0
}

# Where the fleet layer lands when the harness's own instruction file is
# already taken (ac_seed_crewmate_md). NOT a file any harness loads - no such
# sidecar exists for codex, which reads <worktree>/AGENTS.md and nothing else -
# so it is delivered by the one channel every harness does consume, the kickoff
# prompt (bin/ac-spawn.sh).
AC_SEED_FALLBACK_REL='.claude/CREWMATE.md'

# Where ac_seed_install records the sha256 of what it wrote, one file per
# seeded path. A SIDECAR rather than an in-file marker so the seeded file stays
# byte-identical to its source, and inside the seed's own excluded space.
AC_SEED_STAMP_DIR_REL='.claude/.ac-seed'

# Appended to every stamp filename so it never carries a seeded path's own
# extension: `${rel//\//%}` alone keeps the ".json"/".md" suffix, and a
# stamp's content (a bare sha256 hex line, not JSON or a markdown doc) then
# reads as a syntax error to any host repo's formatter/linter that selects
# files by extension (measured: prettier 3.9.6 --check exits 2 on a
# `.claude%settings.json`-named file with this content). The suffix makes
# the stamp inert to every such tool regardless of which path gets seeded.
AC_SEED_STAMP_SUFFIX='.sha256'

ac_sha256_file() {
  # ac_sha256_file <file> - portable SHA-256 used by maintenance plans.
  shasum -a 256 <"$1" | awk '{print $1}'
}

ac_seed_exclude() {
  # ac_seed_exclude <worktree> <path-git-sees> - keep a seeded path out of git
  # status through the repo's info/exclude, so dirty checks stay meaningful.
  # KNOWN REACH: a pooled worktree is a LINKED one, and git resolves its
  # info/exclude to the MAIN repo's file, so an entry covers every worktree of
  # that repo and outlives the lease. Only ever called for a path the seed
  # itself owns - a tracked file could not be hidden this way anyway - so an
  # entry for the harness's own instruction file is still written ONLY in a
  # repo that ships none. The hazard that leaves is unchanged: in a project
  # where the fleet has spawned codex, a root AGENTS.md added LATER by a human
  # is invisible to git status until the entry is removed.
  local wt="$1" rel="$2" excl
  excl="$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 0
  grep -qxF "/$rel" "$excl" 2>/dev/null \
    || printf '/%s\n' "$rel" >>"$excl"
}

ac_seed_install() {
  # ac_seed_install <worktree> <rel> <staged> - install <staged> as
  # <worktree>/<rel> when the seed owns that path, stamping what it wrote.
  # Returns 0 when <rel> now carries the staged content, 1 when the path
  # belongs to someone else and was left EXACTLY as it is.
  #
  # OWNERSHIP is the stamp and NOTHING else: the seed owns <rel> only when it
  # recorded a stamp for it AND the file still hashes to that stamp. So a
  # repo-shipped file, a file a human or the crewmate edited (a crewmate
  # answering "always allow" writes exactly the seeded settings.json), and a
  # file seeded before stamps existed are all left untouched - the seed never
  # overwrites what it cannot PROVE it wrote. The stamp authorizes a refresh
  # of the seed's own copy and nothing beyond it; it is not a claim on the
  # path, and an unstamped file is never adopted.
  #
  # STAMP NAME carries $AC_SEED_STAMP_SUFFIX; `legacy` is the pre-suffix name
  # this function used to write. A `legacy` stamp is ALWAYS retired here - it
  # is the seed's own bookkeeping, never a claim on <rel>, so removing it
  # loses no ownership information. When it still verifies against the
  # current file it is MIGRATED (adopted under the new name, old name
  # removed), so a pool slot leased before the suffix existed keeps
  # refreshing instead of silently degrading to fallback. When it does NOT
  # verify, <rel> is left exactly where the ownership rule above already
  # leaves any unproven file (still `return 1`), but the legacy stamp is
  # removed anyway: it can no longer authorize a refresh either way, and
  # leaving it behind under its old, host-parseable-looking name is the exact
  # defect this stamp shape exists to kill.
  #
  # REFRESH, which is the point of the stamp: when the seed does own the path
  # and the composed content has moved on, the file is rewritten. A pool
  # worktree otherwise keeps what it got at LEASE time for ever - `ac-tree.sh
  # return` does not drop it, since reset_worktree cleans with `git clean
  # -fdq` (no -x) and the seeded file is info/excluded, i.e. IGNORED (verified
  # by a get/return/get cycle with a mutated source: the second lease still
  # read the first lease's copy). So a long-lived slot ran every later
  # crewmate on the fleet rules of whenever that slot was FIRST leased.
  # Refreshing at seed time covers every lease and every --resume-from; a
  # crewmate already running when the source changes is not covered, by
  # design - nothing here reaches into a live session.
  local wt="$1" rel="$2" staged="$3" dst="$1/$2" legacy stamp want have
  legacy="$wt/$AC_SEED_STAMP_DIR_REL/${rel//\//%}"
  stamp="$legacy$AC_SEED_STAMP_SUFFIX"
  want="$(ac_sha256_file "$staged")" || return 1
  if [ -e "$dst" ]; then
    if [ -f "$stamp" ]; then
      have="$(ac_sha256_file "$dst" 2>/dev/null)" || return 1
      [ "$have" = "$(cat "$stamp")" ] || return 1
    elif [ -f "$legacy" ]; then
      have="$(ac_sha256_file "$dst" 2>/dev/null)" || return 1
      if [ "$have" = "$(cat "$legacy")" ]; then
        printf '%s\n' "$have" >"$stamp"
        rm -f "$legacy"
      else
        rm -f "$legacy"
        return 1
      fi
    else
      return 1
    fi
    if [ "$have" = "$want" ]; then return 0; fi
  fi
  mkdir -p "$(dirname "$dst")" "$wt/$AC_SEED_STAMP_DIR_REL"
  cat "$staged" >"$dst"
  printf '%s\n' "$want" >"$stamp"
  rm -f "$legacy"
  ac_seed_exclude "$wt" "$rel"
  ac_seed_exclude "$wt" "$AC_SEED_STAMP_DIR_REL/"
}

ac_seed_crewmate_md() {
  # ac_seed_crewmate_md <worktree> [harness] - seed the fleet-wide crewmate
  # instructions to the file THE SPAWNED HARNESS actually reads, where it
  # concatenates them with the repo's own instructions.
  # A copy the repo already ships wins outright and is never touched; the
  # layer then lands at $AC_SEED_FALLBACK_REL instead and that path is PRINTED,
  # so the caller can point the crewmate at it (see FALLBACK below).
  # A copy the seed itself wrote is REFRESHED when the sources have moved on
  # (ownership and its limits: ac_seed_install).
  # Otherwise the seed MERGES the two sources:
  # <container>/.claude/CLAUDE.md (the baseline shared by every fleet
  # under the homes container) first, then
  # $AC_HOME/CREWMATE.md (the fleet-specific layer) - fleet rules read as
  # the later, more specific word. A single available source is copied
  # byte-identical (no markers). The seeded file is kept out of git
  # status via the repo's info/exclude so dirty checks stay meaningful.
  #
  # TARGET, one file and only the right one. codex reads <worktree>/AGENTS.md
  # and NOTHING else at session start - verified against codex-cli 0.144.6 with
  # `codex debug prompt-input`, which renders the model-visible prompt locally:
  # with AGENTS.md, .claude/CLAUDE.md and root CLAUDE.md all present carrying
  # distinct tokens, only the AGENTS.md token reached the prompt, and a nested
  # .claude/AGENTS.md / .codex/AGENTS.md / sub/AGENTS.md was loaded neither
  # additively nor as a fallback. opencode reads <worktree>/AGENTS.md too and
  # does NOT load .claude/CLAUDE.md - verified on 2026-07-27 on a live opencode
  # 1.18.5 pane holding both candidate files at once, each ordering a distinct
  # marker, with a control leg that SWAPPED the markers between the two files
  # and saw the surviving marker follow the PATH (harness-operations
  # references/harness-facts.md, opencode "Instruction files"). So codex and
  # opencode both take AGENTS.md; everything else - claude, a captain custom
  # launch template - keeps .claude/CLAUDE.md.
  # A repo shipping its own AGENTS.md (this distro does - it is the CHIEF law)
  # keeps it, by the same rule that protects a repo-shipped CLAUDE.md.
  # That is the only shape available AT THAT PATH: AGENTS.md is TRACKED there,
  # and info/exclude covers untracked paths only, so appending a fleet section
  # would show up as a modified tracked file in every dirty check - and could
  # be committed into the law itself.
  #
  # FALLBACK, for exactly that case. Refusing to clobber used to be SILENT, so
  # the fleet layer simply never reached the crewmate and no caller could tell.
  # It now lands at $AC_SEED_FALLBACK_REL - a path NO harness loads, chosen
  # because none is available: codex reads <worktree>/AGENTS.md and nothing
  # else, and a nested .claude/AGENTS.md / .codex/AGENTS.md was loaded neither
  # additively nor as a fallback (same probe as above). The channel that does
  # reach every harness is the KICKOFF PROMPT, so the path is PRINTED on stdout
  # and bin/ac-spawn.sh names it as required reading. Harness-agnostic on
  # purpose: a repo shipping .claude/CLAUDE.md hits the identical gap.
  # A repo that ships NO instruction file is untouched by all of this - the
  # layer reaches the harness's own file and nothing is printed.
  local wt="$1" harness="${2:-}" fleet cont dom rel staged learned
  fleet="$(ac_home)/CREWMATE.md"
  cont="$(dirname "$(ac_home)")/.claude/CLAUDE.md"
  # MACHINE-OWNED learned layer, written only by ac-learn.sh transactions
  # (never by the captain - their per-fleet layer stays CREWMATE.md). It reads
  # BEFORE the fleet layer on purpose: the captain's hand-written word must be
  # the later, more specific one, so a machine-distilled lesson can never
  # override a fleet rule.
  learned="$(ac_home)/CREWMATE-learned.md"
  # THIRD LAYER, appended LAST because the most specific word reads last: the
  # crewdomain instruction layer, when the SPAWNING session carries AC_DOMAIN.
  # Every other rule is untouched - a repo-shipped file still wins outright,
  # the fallback path and its notice still apply, and a single available layer
  # is still copied byte-identical with no markers.
  dom=""
  [ -z "${AC_DOMAIN:-}" ] || dom="$(ac_home)/crewdomains/$AC_DOMAIN/CREWMATE.md"
  # The registry owns the mapping AND fails closed on a harness it cannot
  # answer for (audit-f5: the old `*)` arm here handed .claude/CLAUDE.md to
  # anything unknown, seeding a file the harness never reads).
  rel="$(ac_harness_instruction_file "$harness")"
  # The AVAILABLE layers, in read order: container, learned, fleet, domain.
  local -a lsrc=() llabel=()
  [ ! -f "$cont" ]    || { lsrc+=("$cont");    llabel+=("container"); }
  [ ! -f "$learned" ] || { lsrc+=("$learned"); llabel+=("fleet-learned"); }
  [ ! -f "$fleet" ]   || { lsrc+=("$fleet");   llabel+=("fleet"); }
  [ -z "$dom" ] || [ ! -f "$dom" ] || { lsrc+=("$dom"); llabel+=("crewdomain"); }
  [ "${#lsrc[@]}" -gt 0 ] || return 0
  # Composed ONCE, then installed at whichever path the seed owns. A LOOP, not
  # a branch per combination: two sources needed three arms, three would need
  # seven, and the ordering rule is the same for all of them.
  staged="$(mktemp "${TMPDIR:-/tmp}/ac-seed.XXXXXX")" || return 0
  if [ "${#lsrc[@]}" = 1 ]; then
    cat "${lsrc[0]}" >"$staged"
  else
    local i
    for i in "${!lsrc[@]}"; do
      [ "$i" = 0 ] || printf '\n' >>"$staged"
      printf '<!-- agent-crew seed: %s %s -->\n' "${llabel[$i]}" "${lsrc[$i]}" >>"$staged"
      cat "${lsrc[$i]}" >>"$staged"
    done
  fi
  if ac_seed_install "$wt" "$rel" "$staged"; then
    :
  elif ac_seed_install "$wt" "$AC_SEED_FALLBACK_REL" "$staged"; then
    printf '%s\n' "$AC_SEED_FALLBACK_REL"
  fi
  rm -f "$staged"
  return 0
}

ac_seed_crew_settings() {
  # ac_seed_crew_settings <worktree> - copy the fleet harness settings
  # (enabled plugins, permission allowlists) to <worktree>/.claude/
  # settings.json, where the harness actually reads project settings - the
  # container copy is never on a worktree's settings path by itself.
  # Source resolution (first hit wins), mirroring ac_seed_crewmate_md:
  # $AC_HOME/.claude/settings.json (per-fleet) > <container>/.claude/
  # settings.json (shared by every fleet). A COPY, never a
  # symlink: a crewmate answering "always allow" writes project settings,
  # and through a symlink that grant would contaminate the fleet-wide file.
  # Installed through the SAME ac_seed_install as the instructions, so it
  # inherits both halves at no extra mechanism: a settings file the seed did
  # not write - repo-shipped, or carrying the grants a crewmate just made -
  # wins outright, and one the seed did write is refreshed when the fleet
  # source moves on. Kept out of git status via info/exclude.
  local wt="$1" src
  src="$(ac_home)/.claude/settings.json"
  [ -f "$src" ] || src="$(dirname "$(ac_home)")/.claude/settings.json"
  [ -f "$src" ] || return 0
  ac_seed_install "$wt" '.claude/settings.json' "$src" || return 0
}

# Crewmate-facing skills seeded into every crew worktree (ac_seed_crew_skills).
# ONLY crew-ship, qa, and document: the delivery pipeline, behavioral
# verification, and the doc-authoring pass are what a crewmate runs itself;
# everything else (rich-review, bearings, debrief) is captain/crewchief-facing and
# stays out of crew worktrees.
AC_CREW_SKILLS="${AC_CREW_SKILLS:-crew-ship crew-qa document}"

ac_seed_crew_skills() {
  # ac_seed_crew_skills <worktree> [harness] - symlink the crewmate-facing
  # skills into the DESTINATION that harness's skill discovery actually
  # scans, so a harness session in ANY project repo can invoke them. TWO
  # source classes, seeded in precedence order (first symlink to claim a
  # <name> wins; the dst-exists guard skips any name already linked, so an
  # earlier class always beats a later one):
  #   1. built-in (AC_CREW_SKILLS: crew-ship, crew-qa, document) - resolved
  #      <container>/.claude/skills/<name> > this checkout's .agents/skills
  #      (distro default), mirroring ac_seed_crewmate_md.
  #   2. fleet-learned - the per-fleet store $AC_HOME/skills/* (ac_skills_dir).
  #      Container-origin learned skills are a migration input only and are
  #      never seeded as an active skill. The reserved skills-consolidate archive
  #      subdir (AC_SKILLS_ARCHIVE_BASENAME) is skipped - it holds retired
  #      skills, not one.
  # A repo-shipped skill at <worktree>/.claude/skills/<name> (checked out)
  # wins over both - its dst already exists. Links are kept out of git
  # status via info/exclude. Symlinks, not copies: a skill update at the
  # source reaches every worktree immediately. With empty learned stores this
  # is byte-identical to seeding class 1 alone.
  # SEEDING-IS-USE telemetry: each NEW fleet-learned symlink (class 2 only,
  # never class-1 built-ins) bumps that skill's .usage.meta via
  # ac_skill_usage_bump - best-effort, never failing or blocking the seed.
  # An info/exclude entry must name the path GIT SEES. .claude/skills can be a
  # SYMLINK (this distro ships it tracked, -> ../.agents/skills) and git never
  # traverses one: an entry at the symlink path matches nothing, and the seeded
  # links show as untracked dirt at the REAL path. So resolve the skills dir
  # physically and write the entry relative to the worktree root - which is
  # byte-identical to /.claude/skills/<name> whenever the dir is real, i.e. in
  # every ordinary project repo. Portable resolution only (macOS bash 3.2 has
  # no readlink -f / realpath); the root is resolved the same way, or
  # /tmp vs /private/tmp would break the prefix match. Fail soft like a missing
  # excl: a dir resolving OUTSIDE the worktree gets no entry and no error.
  # The entry is ensured on EVERY seed, not only when the symlink is new: the
  # pool reuses worktrees, so an already-seeded one must heal its own entry.
  # It covers exactly the links THE SEED OWNS - hence the `-L "$dst"` guard, not
  # merely a name in the loop. A repo-shipped skill's dst is a REAL, TRACKED
  # directory: excluding it would swallow every file later added to that package
  # (info/exclude is repo-wide and unversioned), so it gets no entry, exactly as
  # before this ensure existed.
  # DESTINATION, by harness: mirrors ac_seed_crewmate_md's per-harness target
  # (bin/ac-harness.sh's registry doesn't cover this - deliberately kept local
  # to this function per the caller's scope). Verified 2026-07-31 with two
  # local renderers (codex debug prompt-input, opencode debug skill; repo-
  # knowledge multica-research): codex scans .agents/skills ONLY, never
  # .claude/skills; opencode and claude both scan .claude/skills (opencode
  # additionally sees .agents/skills and .opencode/skills, so it needs no
  # change here). codex is therefore the only harness that needs a different
  # dst; every other/absent harness keeps the existing .claude/skills target.
  local wt="$1" harness="${2:-}" excl name src dst pfx root sk skrel
  skrel=.claude/skills
  [ "$harness" = codex ] && skrel=.agents/skills
  excl="$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || excl=""
  pfx="/$skrel"
  if [ -d "$wt/$skrel" ]; then
    pfx=""
    root="$(cd "$wt" 2>/dev/null && pwd -P)" || root=""
    sk="$(cd "$wt/$skrel" 2>/dev/null && pwd -P)" || sk=""
    if [ -n "$root" ] && [ -n "$sk" ]; then
      case "$sk" in "$root"/*) pfx="/${sk#"$root"/}" ;; esac
    fi
  fi
  # Repair pass: heal any DANGLING symlink already at a name this function
  # owns, before either seed loop runs. A retired skill's name drops OUT of
  # both loops below (moved into skills-archive, or removed from
  # AC_CREW_SKILLS) - they are driven by SOURCE names, so only a scan of the
  # destination itself finds a link whose source is gone. Runs first so a
  # name still sourced gets relinked fresh by its own loop instead of being
  # skipped by the `-L` add-guard, which otherwise reads "already a link" as
  # "already seeded" even when that link is broken.
  if [ -d "$wt/$skrel" ]; then
    for dst in "$wt/$skrel"/*; do
      [ -L "$dst" ] && [ ! -e "$dst" ] && rm -f "$dst"
    done
  fi
  for name in $AC_CREW_SKILLS; do
    src="$(dirname "$(ac_home)")/.claude/skills/$name"
    [ -d "$src" ] || src="$(ac_root)/.agents/skills/$name"
    [ -d "$src" ] || continue
    dst="$wt/$skrel/$name"
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      mkdir -p "$wt/$skrel"
      ln -s "$src" "$dst"
    fi
    if [ -L "$dst" ] && [ -n "$excl" ] && [ -n "$pfx" ]; then
      grep -qxF "$pfx/$name" "$excl" 2>/dev/null \
        || printf '%s/%s\n' "$pfx" "$name" >>"$excl"
    fi
  done
  # Class 2 - fleet-learned: per-fleet store.
  # The skills-consolidate archive lives here (a reserved subdir, not a skill) -
  # skip it, or it would be seeded as a bogus "skills-archive" skill. Each NEW
  # symlink stamps the learned skill's .usage.meta (seeding-is-use telemetry).
  for src in "$(ac_skills_dir)"/*; do
    [ -d "$src" ] || continue
    name="$(basename "$src")"
    [ "$name" = "$AC_SKILLS_ARCHIVE_BASENAME" ] && continue
    dst="$wt/$skrel/$name"
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      mkdir -p "$wt/$skrel"
      ln -s "$src" "$dst"
      ac_skill_usage_bump "$src" || true
    fi
    if [ -L "$dst" ] && [ -n "$excl" ] && [ -n "$pfx" ]; then
      grep -qxF "$pfx/$name" "$excl" 2>/dev/null \
        || printf '%s/%s\n' "$pfx" "$name" >>"$excl"
    fi
  done
}

ac_fleet_name() {
  # The fleet token every herdr workspace label is built from ("<fleet>" for
  # the root workspace, "<fleet> · <family>" for a family's - ac-backend.sh
  # FAMILY WORKSPACE GROUPING). Ladder: AC_HOME names the fleet >
  # AC_FLEET_NAME, the name ac-spawn.sh threads onto every crewmate launch
  # line > a FIXED name, never a basename.
  #
  # AC_HOME first: a home in THIS process is first-hand evidence of the fleet
  # it runs against, while AC_FLEET_NAME is a hand-me-down for callers that
  # have none - and a crewdeputy pane is launched with its OWN AC_HOME, so it
  # must group under its own fleet whatever name ever reached it.
  #
  # Why not basename "$(ac_home)" for the homeless rungs: ac_home() REFUSES
  # with no AC_HOME, and before it did it answered ac_root, the checkout that
  # owns bin/ - which is where the damage below came from. A crewmate pane
  # carries no AC_HOME by design (ac-qa.sh header), so every pane agent it
  # launches resolved the
  # label against its POOL WORKTREE ("1") or, when it ran the
  # distro's bin/ by absolute path, against the distro repo ("agent-crew")
  # - a bogus group minted per repo, growing run after run, plus
  # a config/ dir written into a tree that is not a fleet home. What a homeless
  # caller cannot DERIVE it can still be TOLD: AC_FLEET_NAME carries exactly the
  # fleet token and nothing more (never AC_HOME - see the AC_FLEET_* contract in
  # ac-spawn.sh), so a crewmate's observation tabs land in ITS fleet's group.
  # A caller nobody told stays where it was: ONE deliberate fallback group,
  # shared, rather than a bogus per-repo one.
  if [ -n "${AC_HOME:-}" ]; then basename "$(ac_home)"
  elif [ -n "${AC_FLEET_NAME:-}" ]; then printf '%s\n' "$AC_FLEET_NAME"
  else printf 'agent-crew\n'; fi
}

ac_window_family() {
  # ac_window_family <id> - the FAMILY whose herdr workspace a new tab for
  # <id> belongs to (FAMILY WORKSPACE GROUPING, ac-backend.sh header).
  # Ladder: AC_SCOPE (a roomchief spawning its own crewmate - first-hand
  # evidence of the family, and an epic roomchief spawning a story crewmate
  # groups it under the epic's space, matching its watch-set) > AC_FLEET_SCOPE
  # (the scope a crewmate pane was TOLD at launch, same hand-me-down contract
  # as AC_FLEET_NAME) > ac_family_of_id (the id's own stage/revision suffix
  # stripped). Malformed scopes are refused by ac_wake_scope_ok's grammar
  # rather than minting a workspace label from garbage.
  local id="$1" s
  for s in "${AC_SCOPE:-}" "${AC_FLEET_SCOPE:-}"; do
    [ -n "$s" ] || continue
    case "$s" in *[!A-Za-z0-9_-]*) continue ;; esac
    printf '%s\n' "$s"
    return 0
  done
  ac_family_of_id "$id"
}

# --- git helpers ----------------------------------------------------------------

ac_repo_root() {
  # ac_repo_root <dir> - MAIN worktree root, even when <dir> is a linked worktree.
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dirname "$common"
}

ac_default_branch() {
  # ac_default_branch <repo> - origin/HEAD, else main/master, else current HEAD.
  local repo="$1" ref b
  ref="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then printf '%s\n' "${ref#refs/remotes/origin/}"; return 0; fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$b"; then printf '%s\n' "$b"; return 0; fi
  done
  git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || printf 'main\n'
}

ac_default_ref() {
  # ac_default_ref <repo> - freshest ref for the default branch (origin wins).
  local repo="$1" branch
  branch="$(ac_default_branch "$repo")"
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    printf 'origin/%s\n' "$branch"
  else
    printf '%s\n' "$branch"
  fi
}

ac_project_dir() {
  # ac_project_dir <name-or-path> - absolute repo root for a project argument:
  # a path to (inside) a git repo, or a directory name under projects/.
  local arg="$1" dir
  if [ -d "$arg" ]; then
    dir="$(cd "$arg" && pwd -P)"
  elif [ -d "$(ac_projects_dir)/$arg" ]; then
    dir="$(ac_projects_dir)/$arg"
  else
    return 1
  fi
  ac_repo_root "$dir"
}

ac_project_config_name() {
  # ac_project_config_name <repo-or-worktree> - the project's config name:
  # the MAIN repo dir basename. A linked pool worktree resolves through its
  # git-common-dir, so <repo>/.crew/worktrees/3 still answers <repo>.
  local repo="$1" main
  main="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  main="${main%/.git}"
  basename "$main"
}

ac_project_config_file() {
  # ac_project_config_file <repo> - the HOME-ONLY pipeline config file:
  #   $AC_HOME/projects/<name>.yaml
  # The project repo is never a config source. The home location is captain-
  # owned and branch-immune, so a branch under test cannot alter commands or
  # merge policy. Prints the path when it exists; returns 1 with no output when
  # the project has not installed a fleet-home config yet.
  # The legacy $AC_HOME/config/projects/<name>.yaml location is NO LONGER READ
  # (audit-f7; every fleet home was verified migrated). Its mere PRESENCE still
  # dies with the exact mv, rather than being ignored: a legacy-only home would
  # otherwise silently lose its pipeline config - and with it require_for_ship,
  # the merge gate's whole reason to resolve this file. Fail-closed beats a
  # transitional read that would carry the dead location forever.
  # A read mints nothing (see ac_config_read): resolve through ac_home, not
  # ac_config_dir/ac_projects_dir, so no stray dir grows in a homeless pool
  # worktree. Through ac_home and not $AC_HOME directly on purpose: a caller
  # with no home has no project config either, so ac_home's refusal names the
  # real reason on stderr instead of resolving one against whatever tree the
  # caller happens to sit in. The return stays 1 (the same "no config" every
  # caller already handles) - telling a phantom miss apart from a genuine one
  # is AC_FLEET_PROJECT_CONFIG's job, not this function's (ac-spawn.sh).
  # The home is bound ONCE, on its own statement, so a refusal is reported once
  # rather than per composed path.
  local repo="$1" name home canonical legacy
  name="$(ac_project_config_name "$repo")" || return 1
  home="$(ac_home)" || return 1
  canonical="$home/projects/$name.yaml"
  legacy="$home/config/projects/$name.yaml"
  if [ -f "$legacy" ]; then
    ac_die "project config for '$name' found at the RETIRED legacy path ($legacy), which is no longer read - move it: mv \"$legacy\" \"$canonical\" (or delete it if $canonical is already authoritative)"
  fi
  if [ -f "$canonical" ]; then printf '%s\n' "$canonical"; return 0; fi
  return 1
}

ac_knowledge_file() {
  # ac_knowledge_file <repo> - the per-project REPO-KNOWLEDGE record:
  #   $AC_HOME/records/repo-knowledge/<name>.md
  # Keyed by ac_project_config_name - the SAME key the config yaml uses - so
  # the record and projects/<name>.yaml are a pair BY CONSTRUCTION. A
  # registry-name key would let ac-brief.sh (which holds a registry name) and
  # ac-qa.sh (which holds a repo path) resolve DIFFERENT files whenever the two
  # names diverge (a renamed or symlinked clone), which is this mechanism's own
  # defect class re-entering through the file key.
  # Home-resident, like the config, and branch-immune for the same reason
  # (ac_project_config_file states it). ALWAYS prints, unlike its twin: callers
  # test -f. An exists-only shape forces every WRITER to re-derive the path
  # inline, and a second deriver is exactly what this key argument rules out.
  # Grammar of the file itself: bin/ac-know.sh, its only sanctioned writer.
  local repo="$1" name
  name="$(ac_project_config_name "$repo")" || return 1
  printf '%s/repo-knowledge/%s.md\n' "$(ac_records_dir)" "$name"
}

ac_knowledge_scopes() {
  # ac_knowledge_scopes <repo> - the LIVE scope map as `<scope>\t<app>,<app>`
  # rows, from the record's `- scope <name> = <app>, <app>` entries. Three
  # outcomes and they are all distinguishable:
  #   exit 0, rows   the map
  #   exit 0, empty  no scopes declared - a legal, common state
  #   exit 2, msg    the record is AMBIGUOUS: two live entries for one scope
  #                  name, or a malformed live scope line. BOTH offending
  #                  lines are printed and NO winner is picked.
  # Exit 2 must stay distinguishable from "no scopes": if a malformed map read
  # as empty, a scoped project would silently drop to FLAT, which is the exact
  # failure the whole mechanism exists to prevent. Callers treat it as
  # fail-closed.
  # This is not a tenth refusal invented at read time - it is the same
  # mechanical rejection the writer applies, enforced again where a
  # hand-edited file could bypass the writer.
  # An app appearing in two DIFFERENT scopes is NOT an ambiguity: an app may
  # belong to more than one scope (captain ruling), every resolution is
  # per-PAIR, and the map still answers determinately.
  local repo="$1" rec
  rec="$(ac_knowledge_file "$repo" 2>/dev/null)" || return 0
  [ -f "$rec" ] || return 0
  awk '
    /^## Superseded/ { exit }
    /^- scope / {
      line = $0
      subj = line
      sub(/^- scope /, "", subj)
      sub(/ \| src: .*$/, "", subj)
      i = index(subj, " = ")
      ok = 1; name = ""; apps = ""
      if (i == 0) ok = 0
      else {
        name = substr(subj, 1, i - 1)
        apps = substr(subj, i + 3)
        gsub(/[ \t]/, "", apps)
        if (name !~ /^[A-Za-z0-9_-]+$/ || apps == "") ok = 0
        else {
          n = split(apps, a, ",")
          for (j = 1; j <= n; j++) if (a[j] !~ /^[A-Za-z0-9_-]+$/) ok = 0
        }
      }
      if (!ok) { bad[++nb] = line; next }
      if (name in first) { bad[++nb] = first[name]; bad[++nb] = line; next }
      first[name] = line
      rows[++nrow] = name "\t" apps
    }
    END {
      if (nb > 0) {
        print "ac_knowledge_scopes: the scope map is AMBIGUOUS - refusing rather than picking a winner:" >"/dev/stderr"
        for (k = 1; k <= nb; k++) print "  " bad[k] >"/dev/stderr"
        exit 2
      }
      for (k = 1; k <= nrow; k++) print rows[k]
    }
  ' "$rec"
}

ac_home_resolve() {
  # ac_home_resolve <--home value|''> <repo> - THE fleet-home ladder for the
  # tools a HOMELESS pane runs (ac-know.sh, ac-qa.sh). ONE copy on purpose:
  # the same ladder written twice is how one site gets fixed and the other
  # stays broken.
  #   1. --home <abs>, guarded below;
  #   2. $AC_HOME tested DIRECTLY - never through ac_home(), which REFUSES
  #      when the variable is unset (and, before it refused, handed back a
  #      phantom home). This ladder must FALL THROUGH to rung 3, not die, so it
  #      tests the variable itself;
  #   3. neither - prints NOTHING and returns 0. What "no home" means is the
  #      caller's to decide: ac-know.sh REFUSES outright, every verb alike
  #      (settle_home, ac-know.sh:339-347 - cmd_verify was the last holdout
  #      and lost its own rung 3 too); ac-qa.sh's two verbs answer a homeless
  #      run DIFFERENTLY ON PURPOSE - `start` KEEPS RUNNING, freezing an empty
  #      config (or refusing when a selector was given), while `agent`
  #      RETURNS needs-profile, since every durable source it freezes
  #      descends from the home.
  # The two guards on --home: ABSOLUTE, and not INSIDE the project repo - a
  # branch under test must not become a config source or a knowledge sink.
  # Both sides are canonicalized with `pwd -P` FIRST, so `--home /tmp/x` where
  # /tmp/x -> <repo>/.crew/evil cannot walk past a textual comparison; the
  # containment test is DIRECTIONAL because a fleet home legitimately CONTAINS
  # its clones at $AC_HOME/projects/<name>, and the trailing slashes keep
  # /srv/repo-other from reading as inside /srv/repo.
  local flag="${1:-}" repo="${2:-}" home_real repo_real
  if [ -n "$flag" ]; then
    case "$flag" in
      /*) ;;
      *) ac_die "--home must be an ABSOLUTE path outside the project repo (got '$flag')" ;;
    esac
    home_real="$(cd "$flag" 2>/dev/null && pwd -P)" \
      || ac_die "--home is not a readable directory: $flag"
    repo_real="$(ac_repo_root "$repo" 2>/dev/null || true)"
    [ -n "$repo_real" ] || repo_real="$(cd "$repo" 2>/dev/null && pwd -P)" || repo_real=""
    if [ -n "$repo_real" ]; then
      case "$home_real/" in
        "$repo_real"/*) ac_die "--home must be an ABSOLUTE path outside the project repo: $flag resolves to $home_real, inside $repo_real" ;;
      esac
    fi
    printf '%s\n' "$home_real"
    return 0
  fi
  [ -n "${AC_HOME:-}" ] || return 0
  ( cd "$AC_HOME" && pwd -P )
}

ac_project_mode() {
  # ac_project_mode <project-name> - the registry line's bracket content
  # (`- <name> [+yolo] - <summary>`), empty when the project has no bracket
  # or no line. Only `+yolo` means anything any more: DELIVERY MODE IS
  # PER-TASK and a legacy `[<mode>]` here is
  # tolerated, ignored content - ac-project-mode.sh owns the read.
  local name="$1" reg line
  reg="$(ac_records_dir)/projects.md"
  [ -f "$reg" ] || { printf '\n'; return 0; }
  line="$(grep -E "^- $name \[" "$reg" 2>/dev/null | head -n1 || true)"
  if [ -z "$line" ]; then printf '\n'; return 0; fi
  printf '%s\n' "$line" | sed -n 's/^- [^[]*\[\([^]]*\)\].*/\1/p'
}

# --- orphaned shell-snapshot detection: the busy-loop backstop ----------------
#
# The incident: a `jobs -p` cleanup that returned EMPTY in the non-interactive
# `zsh -c` tool shell reaped nothing, orphaning 77 busy loops (ppid=1, ~760%
# CPU, ~48 min). Layer 0 (tests/helpers.sh) and layer 1 (docs/examples/
# CREWMATE.md) prevent it; this is the layer-2 DETECTION backstop, so an
# accumulation is visible within ONE session-start digest instead of an hour
# of burned cores. READ-ONLY: it counts and hints, never kills - killing is a
# deliberate captain/crewchief act.

ac_orphan_snapshot_ps() {
  # ac_orphan_snapshot_ps - emit the process table the scan reads:
  # pid, ppid, %cpu, command (one header line, then one row per process). This
  # is the SEAM: it is the single point of contact with the host, so a test
  # shadows it with a ps fixture rather than spawning real hogs (the
  # host-impact law binds the test too). `-A -o` is the portable form (macOS
  # and Linux both). Failure is swallowed - a digest never dies on a ps hiccup.
  ps -A -o pid,ppid,pcpu,command 2>/dev/null || true
}

ac_orphan_snapshot_scan() {
  # ac_orphan_snapshot_scan - warn about ORPHANED, CPU-burning Claude
  # shell-snapshot processes: ppid==1 (reparented to init once the tool shell
  # died) whose command references a shell-snapshot AND whose %cpu is at/above
  # AC_ORPHAN_CPU (default 50 - a busy loop sits near 100%, an idle orphan near
  # 0). Prints a one-line WARNING + inspect hint when any exist, NOTHING when
  # clean. Never kills. The ppid==1 gate is what keeps a healthy session's LIVE
  # snapshot shells (parented to claude) from tripping it.
  local cpu_min="${AC_ORPHAN_CPU:-50}" stats n total
  stats="$(ac_orphan_snapshot_ps | awk -v c="$cpu_min" '
    $1 !~ /^[0-9]+$/ { next }                          # skip the header
    $2 == 1 && ($3 + 0) >= c && index($0, "shell-snapshots/snapshot") { n++; t += $3 }
    END { if (n > 0) printf "%d %d\n", n, t + 0.5 }')"
  [ -n "$stats" ] || return 0
  n="${stats%% *}"; total="${stats##* }"
  printf 'WARNING: %s orphaned shell-snapshot process(es) burning CPU (ppid=1, >=%s%%, ~%s%% total)\n' \
    "$n" "$cpu_min" "$total"
  # shellcheck disable=SC2016  # the backticked ps command is hint text, not shell expansion
  printf '  inspect: `ps -A -o pid,ppid,pcpu,command | grep shell-snapshots/snapshot` - kill only orphans you confirm (never auto-killed)\n'
}
