#!/usr/bin/env bash
# ac-bootstrap.sh - toolchain doctor: verify every tool agent-crew leans on
# and say exactly what is missing and why it matters.
#
# Usage:
#   ac-bootstrap.sh [--quiet]
#
# Output contract (one line per check, stable prefixes the orchestrator can
# act on):
#   OK: <tool>                     present and usable
#   MISSING: <tool> - <hint>       required tool absent -> exit 1
#   NEEDS_GH_AUTH: <hint>          gh present but not authenticated
#   OPTIONAL: <tool> missing - <what it unlocks>
#   INERT: <tool> installed but inert - <active> shadows <newer> -
#          PATH hint (moves the whole dir, may re-shadow another tool
#          there): export PATH="<dir>:$PATH"
#                                   a newer copy of TOOL sits later on PATH
#                                   than the one that actually answers, for
#                                   ANY tool this doctor names (required or
#                                   optional tier alike) - DIAGNOSTIC ONLY,
#                                   never sets rc (some inert states, like
#                                   an nvm pin, are deliberate; the herdr
#                                   compat check below is the real gate).
#                                   The hint is a directory-level PATH move,
#                                   not a guaranteed per-tool fix: PATH
#                                   orders directories, so prepending one
#                                   can re-shadow a DIFFERENT tool that also
#                                   lives there (measured: jq's own fix
#                                   re-shadows git on this host).
#   CHECK-FAILED: <tool> - <path> did not report a parseable version
#                                   a copy on PATH would not answer --version
#                                   with anything version-shaped -
#                                   diagnostic only, never sets rc
#
# --quiet suppresses OK lines (problems only). Exit 1 ONLY when a REQUIRED
# tool is missing, the backend protocol-compat check below fails, or that
# check's status probe does not answer within its ceiling; auth gaps, INERT
# and CHECK-FAILED are advisory and never affect the exit code.
#
# Knobs: AC_BOOTSTRAP_PROBE_TIMEOUT (seconds, default 10) bounds the backend
# status probe (probe_bounded below); 0 runs it unbounded, the pre-ceiling
# shape, for a host whose backend is known slow rather than wedged.
#
# Every tool this doctor checks (need()/opt()/the gh block below) is also
# probed for PATH shadowing there - one call site, so the shadowed-tool set
# can never drift from the checked-tool set.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

rc=0

ok() { [ "$quiet" = 1 ] || printf 'OK: %s\n' "$1"; }

# ac_path_copies <tool> - every executable named <tool> found on PATH, in
# PATH order, duplicates and symlink twins included (the caller dedupes by
# realpath). A manual walk rather than `type -a`: a test can then simulate
# a stale-shadows-newer tree by setting PATH before sourcing, with no
# dependence on how the builtin formats its own output.
ac_path_copies() {
  local tool="$1" dir
  local -a dirs
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    [ -f "$dir/$tool" ] && [ -x "$dir/$tool" ] && printf '%s\n' "$dir/$tool"
  done
  # A trailing PATH dir with no copy of $tool leaves the loop's last test
  # false, which would otherwise become this function's own exit status and
  # abort the whole doctor under set -e.
  return 0
}

# ac_tool_version <path> - the first dotted-number token `<path> --version`
# prints, on any line (shellcheck's version sits on line 2, not line 1) so
# one regex covers every shape measured on this fleet: `git version 2.55.0`,
# `jq-1.7.1-apple`, `gh version 2.51.0 (2024-06-13)`, `v22.19.0`,
# `herdr 0.8.0`, `1.3.13`, `Docker version 29.4.0, build 9d7ad9f`. Empty
# means the copy would not answer with anything version-shaped - a check
# failure the caller must report, never treat as "older" or "newer".
#
# Bounded with the same background+poll+kill watchdog shape as
# ac-sync.sh's fetch_bounded: a wedged daemon binary (docker's own
# incident, 2026-07-28 - `docker ps -a` hung 6m27s) must not block the
# whole toolchain doctor, and by extension session start, just to learn
# one version string.
ac_tool_version() {
  local path="$1" secs=3 out="" pid start tmp
  tmp="$(mktemp)"
  # orca has NO --version (it prints usage - measured 1.4.188): its version
  # lives in `status --json` .result.runtime.appVersion, and the generic
  # dotted-number grep below reads it out of that JSON like any other shape.
  # Same bounded watchdog either way.
  if [ "${path##*/}" = orca ]; then
    "$path" status --json >"$tmp" 2>/dev/null &
  else
    "$path" --version >"$tmp" 2>/dev/null &
  fi
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$tmp"
      return 0
    fi
    sleep 0.05
  done
  wait "$pid" 2>/dev/null || true
  out="$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' "$tmp" 2>/dev/null | head -1)" || true
  rm -f "$tmp"
  printf '%s' "$out"
}

# shadow_check <tool> - PATH is measured, never inferred: every copy on
# PATH is asked for its OWN version and those answers are compared, so a
# directory name or install order never stands in for a version (a
# version manager's "latest" dir can hold an older build). Fired from
# need()/opt()/the gh block below, each only after the tool was already
# found - so the shadowed set is exactly the checked set, never a second
# list to keep in sync.
#
# DIAGNOSES, NEVER GATES: an inert tool prints INERT: and rc is left
# untouched, deliberately - some inert states are chosen (this host's nvm
# pin on node, homebrew jq pinned ahead of the OS copy), and a line that
# blocks every session over a deliberate config teaches chiefs to ignore
# it. The one case that must actually stop the fleet - herdr client/server
# incompatibility - already has its own MISSING/rc=1 gate below (the
# `compat` check); this function only explains a shadow, it does not
# duplicate that gate.
shadow_check() {
  local tool="$1"
  local copies active_path active_real active_ver
  local newest_path newest_real newest_ver
  local seen_reals line real ver

  copies="$(ac_path_copies "$tool")"
  [ -n "$copies" ] || return 0

  active_path="$(printf '%s\n' "$copies" | head -1)"
  active_real="$(readlink -f "$active_path" 2>/dev/null)" || active_real="$active_path"
  active_ver="$(ac_tool_version "$active_path")"
  if [ -z "$active_ver" ]; then
    printf 'CHECK-FAILED: %s - %s (active) did not report a parseable version\n' \
      "$tool" "$active_path"
    return 0
  fi

  newest_path="$active_path"
  newest_real="$active_real"
  newest_ver="$active_ver"
  seen_reals="$active_real"$'\n'

  while IFS= read -r line; do
    [ -n "$line" ] && [ "$line" != "$active_path" ] || continue
    real="$(readlink -f "$line" 2>/dev/null)" || real="$line"
    case "$seen_reals" in *"$real"$'\n'*) continue ;; esac
    seen_reals="$seen_reals$real"$'\n'

    ver="$(ac_tool_version "$line")"
    if [ -z "$ver" ]; then
      printf 'CHECK-FAILED: %s - %s did not report a parseable version\n' "$tool" "$line"
      continue
    fi
    if [ "$ver" != "$newest_ver" ] &&
      [ "$(printf '%s\n%s\n' "$newest_ver" "$ver" | sort -V | tail -1)" = "$ver" ]; then
      newest_path="$line"
      newest_real="$real"
      newest_ver="$ver"
    fi
  done <<<"$copies"

  [ "$newest_real" = "$active_real" ] && return 0

  # PATH orders DIRECTORIES, not tools: prepending $fixdir moves every tool
  # it holds, not just $tool. Measured live: fixing jq this way (prepend
  # /usr/bin) re-shadows git, whose newer copy sits in /opt/homebrew/bin -
  # the two fixes then ping-pong. No PATH command can be an exact per-tool
  # fix, so the line says what it actually does (a directory move) instead
  # of promising a guarantee it cannot keep.
  local fixdir
  fixdir="$(dirname "$newest_path")"
  # shellcheck disable=SC2016  # the printed $PATH is the hint command's literal text, not this script's expansion
  printf 'INERT: %s installed but inert - %s (%s) shadows %s (%s) - PATH hint (moves the whole dir, may re-shadow another tool there): export PATH="%s:$PATH"\n' \
    "$tool" "$active_path" "$active_ver" "$newest_path" "$newest_ver" "$fixdir"
}

need() {
  # need <tool> <hint>
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1"
    shadow_check "$1"
  else
    printf 'MISSING: %s - %s\n' "$1" "$2"
    rc=1
  fi
}

opt() {
  # opt <tool> <what it unlocks>
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1"
    shadow_check "$1"
  else
    printf 'OPTIONAL: %s missing - %s\n' "$1" "$2"
  fi
}

need git "brew install git"
need jq "brew install jq (worktree pool state, herdr backend)"

# Session backend: the configured one is required, the others stay optional.
backend="$(ac_config_read backend herdr)"
case "$backend" in
  herdr|orca) : ;;
  *)
    printf 'MISSING: config/backend names unsupported backend %s (valid backends: herdr, orca)\n' "$backend"
    rc=1
    backend=herdr
    ;;
esac
# The hint names the binary outright rather than "$backend": the case above
# already forced any unknown value back to herdr, so the name is fixed per
# branch - and "MISSING: <backend> - configured session backend" told an
# operator the one thing they already knew, while withholding the one thing
# they needed. Nothing spawns without the configured backend's CLI.
case "$backend" in
  orca) need orca "install the Orca app - its CLI ships with it (the fleet's session backend; nothing spawns without it)" ;;
  *) need herdr "brew install herdr (the fleet's session backend; nothing spawns without it)" ;;
esac

# Present is not enough: a client/server PROTOCOL mismatch (brew upgrades the CLI
# while the old server keeps running - herdr's README: a running server keeps its
# process until stopped) fails EVERY socket call, so nothing can be spawned, seen
# or steered. Lived 2026-07-25, and it cost a diagnosis instead of one digest
# line. herdr reports the condition itself, so ask it - and flag ONLY an explicit
# `false`: an absent binary, an old herdr with no --json, or any unparseable reply
# says NOTHING about compatibility, and a doctor that grounds the fleet on silence
# is worse than the outage. Neither jq shorthand can express that: `jq -e` exits 0
# on EMPTY input (silence would read as a mismatch), and `// empty` swallows the
# very value being looked for (jq's alternative operator fires on false as well as
# null). So the field is printed raw and compared here - "" or "null" is silence.
#
# AND IT IS BOUNDED. This is the one herdr call left on a chief's OWN
# session-start path, and a hang here does not degrade a sweep the way a wedged
# pane pass does - it stops the chief from starting, which is the fleet losing
# its supervisor before it has one. A TIMEOUT is not the silence above: an
# absent binary or an unparseable reply says nothing about the backend, while a
# server that accepts and never answers has been observed to be unusable, so it
# gets its own MISSING line and its own remedy.
probe_bounded() {
  # probe_bounded <secs> <argv...> - one status probe under a ceiling; prints
  # its stdout, or nothing and returns 124 when the ceiling is reached. The
  # local copy of the idiom is deliberate: this doctor sources ac-lib.sh alone,
  # and pulling the whole backend layer into a toolchain check would make the
  # check depend on more of the tree than it is checking.
  local secs="$1"; shift
  local out pid start rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/ac-bootstrap-probe.XXXXXX")" || return 1
  set -m
  "$@" >"$out" 2>/dev/null &
  pid=$!
  set +m
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      kill -TERM -"$pid" 2>/dev/null || true
      sleep 0.5
      kill -KILL -"$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 0.2
  done
  [ "$rc" -eq 124 ] || wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 124 ] || cat "$out"
  rm -f "$out"
  return "$rc"
}
probe_secs="${AC_BOOTSTRAP_PROBE_TIMEOUT:-10}"
case "$probe_secs" in ''|*[!0-9]*) probe_secs=10 ;; esac
if [ "$probe_secs" = 0 ]; then
  # 0 is "no ceiling", never "a ceiling of nothing": an instant-answering
  # backend measurably lost the race to a 0s deadline and read as wedged.
  probe_bounded() { shift; "$@"; }
fi

if [ "$backend" = herdr ]; then
  probe_rc=0
  compat_json="$(probe_bounded "$probe_secs" herdr status server --json)" || probe_rc=$?
  if [ "$probe_rc" = 124 ]; then
    printf 'MISSING: herdr status server did not answer within %ss - the backend is wedged or unreachable, so every socket call this fleet makes will block the same way; restart the herdr server (it exits every pane, the captain owns that call)\n' "$probe_secs"
    rc=1
  fi
  compat="$(printf '%s' "$compat_json" | jq -r '.compatible' 2>/dev/null || true)"
  if [ "$compat" = false ]; then
    printf 'MISSING: herdr protocol compat - the running server disagrees with the client (herdr status server: compatible false), so EVERY socket call fails and no pane can be spawned, read or steered; restart the herdr server (it exits every pane, the captain owns that call)\n'
    rc=1
  fi
else
  # Same flag-only-explicit-false philosophy for the orca runtime: silence
  # (no binary, no --json, unparseable) says nothing about reachability -
  # and a REACHABLE runtime still starting (or errored) cannot spawn either,
  # so an explicit non-ready state flags the same way.
  # Bounded for the same reason and on the same path as the herdr branch above:
  # an orca fleet's chief starts through this line too.
  probe_rc=0
  orca_status_json="$(probe_bounded "$probe_secs" orca status --json)" || probe_rc=$?
  if [ "$probe_rc" = 124 ]; then
    printf 'MISSING: orca status did not answer within %ss - the runtime is wedged or unreachable, so no terminal can be spawned, read or steered; restart it (orca open, or orca serve for headless)\n' "$probe_secs"
    rc=1
  fi
  reachable="$(jq -r '.result.runtime.reachable' <<<"$orca_status_json" 2>/dev/null || true)"
  orca_state="$(jq -r '.result.runtime.state // empty' <<<"$orca_status_json" 2>/dev/null || true)"
  if [ "$reachable" = false ]; then
    printf 'MISSING: orca runtime not reachable - no terminal can be spawned, read or steered; start it (orca open, or orca serve for headless)\n'
    rc=1
  elif [ -n "$orca_state" ] && [ "$orca_state" != ready ]; then
    printf 'MISSING: orca runtime is %s, not ready - no terminal can be spawned until it is; wait and re-check (orca status)\n' "$orca_state"
    rc=1
  fi
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh (authenticated)"
  else
    printf 'NEEDS_GH_AUTH: run gh auth login (PR + CI steps need it)\n'
  fi
  shadow_check gh
else
  printf 'MISSING: gh - brew install gh (PR + CI steps)\n'
  rc=1
fi

opt bun "web dashboard + native review loop (bin/ac-dashboard.sh runs bin/dashboard.ts)"
opt node "npx-driven helpers (crew-qa's playwright screenshots)"
# Not "dev only" any more: with no CI workflow, a local run is the ONLY thing
# that ever lints this repo, so an absent shellcheck means nothing is checked.
opt shellcheck "brew install shellcheck - bin/ac-lint.sh is the only lint there is; nothing else runs it"
opt docker "qa pipeline infra (bin/ac-qa.sh: postgres/redis/temporal/mock profiles)"

exit "$rc"
