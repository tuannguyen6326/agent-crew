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
#   ac-review.sh poll <file> [--after N] [--agent-reply <reply>]
#   ac-review.sh reply <file> <reply>
#   ac-review.sh end <file>
#   ac-review.sh url <file>                    print the captain's viewer URL
#
# A <reply> is the text itself, `@<path>` (read from that file) or `-` (read
# from stdin) - the file/stdin forms carry a multi-paragraph reply with every
# newline intact, where one quoted argv line gets flattened or cut. Either
# form is bounded at dashboard/app.ts REVIEW_REPLY_MAX_BYTES (the reply route
# answers 413 past it); the shim refuses an over-cap reply BEFORE sending,
# naming the cap.
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

# Mirrors dashboard/app.ts REVIEW_REPLY_MAX_BYTES - the one number both ends
# refuse at, so the agent reads the cap here instead of a bare 413.
reply_max=$((1024 * 1024))
post_reply() { # post_reply <text | @<path> | -> - POST one reply, exit non-zero on refusal
  # A file or stdin reply is spooled to a temp file and handed to curl as
  # @<spool>: an argv cannot carry every byte (ARG_MAX, no NUL) and curl
  # already reads a leading "@" as a file name, so `@<path>` costs the
  # argv form nothing it did not already lack.
  local src="$1" body spool="" size
  case "$src" in
    @* | -)
      spool="$(mktemp "${TMPDIR:-/tmp}/ac-review-reply.XXXXXX")"
      if [ "$src" = - ]; then
        cat >"$spool"
      else
        [ -f "${src#@}" ] || { rm -f "$spool"; ac_die "no such reply file: ${src#@}"; }
        cat "${src#@}" >"$spool"
      fi
      size="$(wc -c <"$spool" | tr -d ' ')"
      if [ "$size" -gt "$reply_max" ]; then
        rm -f "$spool"
        ac_die "reply is $size bytes, over the dashboard's $reply_max-byte cap (dashboard/app.ts REVIEW_REPLY_MAX_BYTES) - shorten it"
      fi
      [ "$size" -gt 0 ] || { rm -f "$spool"; ac_die "reply text required"; }
      body="@$spool" ;;
    "") ac_die "reply text required" ;;
    *) body="$src" ;;
  esac
  local out rc=0
  out="$(req POST "/api/review/reply?$q" "$body")" || rc=$?
  [ -z "$spool" ] || rm -f "$spool"
  [ "$rc" -eq 0 ] || exit "$rc"
  jq -e '.ok' >/dev/null <<<"$out" \
    || ac_die "reply refused: $(jq -r '.error // .' <<<"$out")"
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
    post_reply "${1:-}"
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
          post_reply "${2:?}"
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
