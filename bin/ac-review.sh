#!/usr/bin/env bash
# ac-review.sh - crewmate CLI for the dashboard's native annotate loop
# (dash-review; spec: the drydock family's spec report). Thin curl shim over
# the dashboard review API - the DASHBOARD owns sessions, anchors, and the
# viewer; this script only speaks the open/poll/reply/end verb set the
# rich-review skill teaches.
#
# Usage (the artifact is an .html OR .md file under the home's artifact roots;
# an md file reviews as-is - the dashboard renders it and pins carry the
# source line):
#   ac-review.sh open <file> [--reopen] [--auto-open]  announce/reopen a
#                                               session; --auto-open also
#                                               launches the captain's
#                                               browser (silent no-op, still
#                                               exit 0, with no opener)
#   ac-review.sh poll <file> [--after N] [--agent-reply <text>]
#   ac-review.sh reply <file> <text>
#   ac-review.sh end <file>
#   ac-review.sh url <file>                    print the captain's viewer URL
#
# poll BLOCKS via the server's long-poll (25s hold per round) and LOOPS until
# it can print annotations newer than --after (JSON: {state, items:[...]}) or
# the session is ended; --agent-reply posts the reply FIRST, then polls - the
# exact `poll --agent-reply` shape the skill already teaches.
# open with no --reopen refuses a HUMAN-ended session (409 from the server,
# surfaced verbatim); --reopen is the deliberate override.
#
# The dashboard must be RUNNING (bin/ac-dashboard.sh; port from
# config/dash-port, default 8787, AC_DASH_PORT overrides). A down dashboard is
# a LOUD refusal naming the fix, never a hang: curl gets 2s to connect. req()
# CLASSIFIES the failure instead of collapsing every curl exit into that one
# diagnosis: a genuine connection refusal (curl exit 7 - nothing listening)
# says "start it"; a timeout (28) or a dropped connection/empty reply (52/56 -
# the long-poll hold can outlast a transport idle timeout) says what actually
# happened and does NOT tell the reader to start a dashboard that is already
# running - a channel that reports wrongly is exactly the moment an agent
# must stop, not go looking for the answer elsewhere.
# The home passed as ?path= is AC_HOME (required - the server validates it
# against its own discovered homes, and the artifact must live under that
# home's artifact roots or the API answers 403).
set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
ac_require curl jq

cmd="${1:-}"; file="${2:-}"
case "$cmd" in open|poll|reply|end|url) ;; *)
  ac_die "usage: ac-review.sh open|poll|reply|end|url <file>.html [options]" ;;
esac
[ -n "$file" ] || ac_die "usage: ac-review.sh $cmd <file>.html [options]"
[ -f "$file" ] || ac_die "no such artifact: $file"
file="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
home="$(ac_home)" || ac_die "AC_HOME required: the review session belongs to a fleet home"
shift 2

port="${AC_DASH_PORT:-$(ac_config_read dash-port 8787)}"
base="http://127.0.0.1:$port"
q="path=$(jq -rn --arg v "$home" '$v|@uri')&file=$(jq -rn --arg v "$file" '$v|@uri')"

req() { # req <method> <route-with-extra-query> [body]
  local method="$1" route="$2" body="${3:-}" out rc=0
  out="$(curl -sS --connect-timeout 2 --max-time 40 -X "$method" \
      ${body:+--data-binary "$body"} "$base$route" 2>&1)" || rc=$?
  case "$rc" in
    0) ;;
    7) ac_die "dashboard unreachable on port $port - start it: bin/ac-dashboard.sh" ;;
    28) ac_die "dashboard on port $port timed out - it may be overloaded, retry" ;;
    52 | 56) ac_die "dashboard on port $port dropped the connection (a transport hiccup, not a dead process) - retry" ;;
    *) ac_die "dashboard request on port $port failed (curl exit $rc): $out" ;;
  esac
  printf '%s\n' "$out"
}

ac_try_open() { # ac_try_open <url> - best-effort browser launch, never fails
  # Headless/cron/no-GUI hosts are the common case here, not the exception,
  # so a missing opener is silent success, never a failure this script
  # surfaces (set -euo pipefail stays intact through every branch below).
  local url="$1" opener=""
  if [ -n "${BROWSER:-}" ] && command -v "$BROWSER" >/dev/null 2>&1; then
    opener="$BROWSER"
  elif command -v open >/dev/null 2>&1; then
    opener=open
  elif command -v xdg-open >/dev/null 2>&1; then
    opener=xdg-open
  fi
  [ -n "$opener" ] || return 0
  "$opener" "$url" >/dev/null 2>&1 || true
}

case "$cmd" in
  url)
    printf '%s/review?%s\n' "$base" "$q" ;;
  open)
    reopen=0 auto_open=0
    for a in "$@"; do
      case "$a" in
        --reopen) reopen=1 ;;
        --auto-open) auto_open=1 ;;
        *) ac_die "unknown open option: $a" ;;
      esac
    done
    if [ "$reopen" = 1 ]; then
      req POST "/api/review/end?$q&reopen=1&force=1" | jq -e '.ok' >/dev/null \
        || ac_die "reopen failed"
    else
      out="$(req POST "/api/review/end?$q&reopen=1")"
      jq -e '.ok' >/dev/null <<<"$out" \
        || ac_die "open refused: $(jq -r '.error // .' <<<"$out") "
    fi
    url="$base/review?$q"
    printf 'review open - captain viewer: %s\n' "$url"
    # --auto-open is gate-review's own opt-in (a captain-required gate is
    # already blocking on this URL); rich-review omits the flag so an
    # ordinary artifact publish never pops a window uninvited.
    if [ "$auto_open" = 1 ]; then ac_try_open "$url"; fi ;;
  reply)
    [ -n "${1:-}" ] || ac_die "reply text required"
    req POST "/api/review/reply?$q" "$1" | jq -e '.ok' >/dev/null || ac_die "reply failed"
    printf 'replied\n' ;;
  end)
    req POST "/api/review/end?$q&by=agent" | jq -e '.ok' >/dev/null || ac_die "end failed"
    printf 'session ended\n' ;;
  poll)
    after=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --after) after="${2:?}"; shift 2 ;;
        --agent-reply)
          req POST "/api/review/reply?$q" "${2:?}" | jq -e '.ok' >/dev/null \
            || ac_die "agent-reply failed"
          shift 2 ;;
        *) ac_die "unknown poll option: $1" ;;
      esac
    done
    while :; do
      out="$(req GET "/api/review/poll?$q&after=$after")"
      jq -e 'has("items")' >/dev/null <<<"$out" \
        || ac_die "poll failed: $(jq -r '.error // .' <<<"$out")"
      state="$(jq -r '.state' <<<"$out")"
      items_n="$(jq '.items | length' <<<"$out")"
      if [ "$state" = ended ] || [ "$items_n" -gt 0 ]; then
        printf '%s\n' "$out"
        exit 0
      fi
      # A non-zero `pending` (guest feedback withheld at the moderation wall)
      # with empty `items` must reach the caller too, not loop forever in
      # silence: the rich-review skill promises "a non-zero pending with
      # empty items means WAIT". The COUNT only rides this line - never
      # content, never a `by`, never a pending item's text; those never
      # leave pollSlice's wall regardless. The stderr hint names the ONE
      # correct move (stop and ask, never re-poll in a loop for the same
      # non-answer - the fix-round-1 finding: an agent doing that recreates
      # the exact pressure that led to reading the session file directly
      # once already) so the shim teaches it even to a caller that has not
      # loaded the skill text this line duplicates.
      pending_n="$(jq -r '.pending // 0' <<<"$out")"
      if [ "$pending_n" -gt 0 ]; then
        printf 'pending: %s item(s) awaiting captain approval - stop and ask your chief; resume with: bin/ac-review.sh poll %s --after %s\n' \
          "$pending_n" "$file" "$after" >&2
        printf '%s\n' "$out"
        exit 0
      fi
    done ;;
esac
