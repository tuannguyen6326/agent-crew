#!/usr/bin/env bash
# ac-remote.sh - transport-agnostic remote captain orders (slack-mode core).
#
# The fleet's throughput bound is captain attention, and gate answers are one
# word by design - the perfect remote message class. This script is the
# durable state machine around a remote transport: inbox stash, wake queue,
# task links, landing follow-ups. The transport itself is NEVER built in -
# user-owned hooks in config/ carry it (Slack or anything else), and absent
# hooks every subcommand degrades safely: remote-poll (fetch), remote-reply
# (post), remote-ack (OPTIONAL seen-receipt, below).
#
# Usage:
#   ac-remote.sh poll                                 # fetch new remote orders
#   ac-remote.sh ingest                               # stash orders fed on stdin
#   ac-remote.sh show <rid>                           # print a stashed order
#   ac-remote.sh reply <rid> [--text-file <f>]        # text into the order's thread
#   ac-remote.sh link <task-id> <rid>                 # bind a task to an order
#   ac-remote.sh followup <task-id> [--text-file <f>] # landing follow-up, clears link
#   ac-remote.sh ack <rid> <working|done>             # lifecycle edge for INLINE-handled orders
#   ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]
#                                                     # text into the family's thread
#   ac-remote.sh done-stamp <family>                  # mark the family's landing done-report as posted
#   ac-remote.sh push-pending                         # batch pending gates/asks out
#   ac-remote.sh gc [--days <n>]                      # prune old unlinked stashes
#
# poll - HARD no-op (exit 0, no output) unless config/remote-poll exists and
#   is executable. Runs the hook; the hook prints ZERO OR MORE JSON objects,
#   one per line, each at minimum {rid, text, author, thread}. For each rid
#   not already stashed (rid is the idempotency key): the object is stashed
#   atomically to state/remote-inbox/<rid>.json, one durable wake record -
#   kind=remote, id=captain, payload=remote-order <rid>; the same record
#   shape ac-watch.sh queue_wake publishes - goes to the fleet spool
#   state/.wake-spool/ (ac_wake_publish, hard-wired fleet), and one
#   `remote-order <rid>` line is printed. A re-poll of a stashed rid changes
#   nothing (exactly one wake per rid; the stash publish is exclusive).
#   Malformed lines and guard-refused rids are warned and skipped; a failing
#   hook is warned and poll still exits 0 - poll must never kill a watcher.
#   The per-line handling is the shared ingest core: one implementation, two
#   entrances (poll pipes its hook output through it; ingest reads stdin).
#   LIFECYCLE-ACK: when an executable config/remote-ack hook exists, the core
#   runs it at each lifecycle edge of an order, with AC_REMOTE_RID,
#   AC_REMOTE_THREAD and AC_REMOTE_ACK_STATE in env, stdin/stdout to
#   /dev/null (stderr is the warn channel). States, in order:
#     ingested - once per NEWLY stashed rid, right after the stash+wake
#                commit (the moment the fleet durably owns the order);
#     working  - `link <task-id> <rid>` bound a task to the order;
#     done     - `followup` delivered the landing reply (fired only AFTER
#                the reply went out - a failed reply keeps the link and
#                fires nothing).
#   Purpose: a transport-side receipt trail the captain can SEE (the Slack
#   example walks :eyes: -> :gear: -> :white_check_mark: on the captain's
#   own message). Fire-and-forget at every edge: absent hook = no-op,
#   failing hook = ONE warning - an ack can never affect ingest, dedup,
#   links, replies, or the printed lines. A re-poll of a stashed rid never
#   re-acks; a hook that ignores AC_REMOTE_ACK_STATE simply acks every edge
#   the same way.
# ingest - the push-gateway entrance: reads the SAME JSON lines a poll hook
#   would print, from THIS command's stdin, and runs them through the exact
#   per-line core poll uses (one implementation, two entrances). Needs NO
#   config/remote-poll - a push gateway may be the fleet's only transport.
#   Per new rid: exclusive stash, durable wake, one printed `remote-order
#   <rid>` line, identical dedup (rid is the idempotency key across BOTH
#   entrances); malformed lines and refused rids are warned and skipped, and
#   bad input never hard-fails ingest - it always exits 0.
# show <rid> - print the stashed JSON. Orchestrators read order text from
#   DISK, never from the wake payload.
# reply <rid> [--text-file <f>] - requires an executable config/remote-reply
#   hook; runs it with AC_REMOTE_RID and AC_REMOTE_THREAD (from the stash) in
#   env and the reply text on the hook's STDIN (--text-file, else this
#   command's stdin). Text is never a hook argument. A failing hook is a hard
#   error: the reply did NOT go out.
# link <task-id> <rid> - record remote_request=<rid> and remote_request_ts=
#   <now> in state/<task-id>.meta (atomic ac_meta_set), so the landing can
#   notify the thread that asked. The rid must be stashed.
# followup <task-id> [--text-file <f>] - read remote_request= from the task
#   meta (live state/<id>.meta first, else archive state/archive/<id>/meta),
#   reply into that order's thread, then clear the link from the meta it was
#   read from. One landing follow-up per link: a second followup without a
#   re-link warns and exits 0. A failed reply keeps the link (fail-closed).
# thread-post <family> [--text-file <f>] [--mention-captain] - text (file,
#   else stdin) into the family's remote thread, via the SHARED family
#   sender (family_send): the thread is created and registered at
#   state/remote-threads/<family>.thread on the first post, exactly the
#   push-pending bootstrap. On delivery prints `posted <family>` (plus the
#   message ts in parens when the hook printed one) - the one positive
#   confirmation the sibling verbs already emit, so a re-run to check
#   delivery is never the only way to know (LIVED 2026-07-25: total silence
#   on success drove a caller to re-run this verb just to read its exit
#   code, duplicating a captain-facing message). Without an executable
#   config/remote-reply hook: stdin is still drained and exit stays 0 (a
#   fleet with no transport configured must not hard-fail), but a `WARN:`
#   line says nothing was delivered instead of a delivered confirmation - a
#   caller must never read "posted" when nothing went out. A FAILING hook
#   is still a hard error (the text did NOT go out), with no confirmation
#   printed either. This is the CHIEF'S OWN posting verb
#   (captain order 2026-07-18): chiefs COMPOSE their family's Slack
#   narrative themselves - task start, progress, gates/asks (with
#   --mention-captain), landings - in the captain's recorded style; a
#   captain reply INSIDE the thread comes back through poll as a tier-1
#   order bound to the family. The AUTO-mirror (every ac-room.sh post +
#   ac-spawn.sh announce riding along mechanically) is OPT-IN via
#   config/remote-mirror=on and gates at those callers, never here - a
#   deliberate thread-post always goes out. --mention-captain rides to the
#   hook as AC_REMOTE_MENTION=captain (the Slack example prepends <@id> per
#   config/slack-captain-id line); push-pending always mentions - the
#   pending safety net stays automatic regardless of who writes the
#   narrative.
# done-stamp <family> - record that the family's landing done-report has been
#   posted to its Slack thread, so the turn-end guard's landing-receipt check
#   (bin/ac-turnend-guard.sh) stays silent for it. The CHIEF calls this right
#   after it posts the landing done-report - an EXPLICIT verb, not an
#   auto-wrapper on thread-post: the least machinery and the fewest ways to get
#   it wrong (no landing-vs-progress heuristic on post text, no coupling of the
#   stamp to what the chief wrote). A pure local write to a per-family stamp
#   (family -> marker in state/.landing-receipt-stamp, the .remote-push-stamp
#   single-file/per-family-key shape); needs NO transport hook, so the stamp
#   lands even when the reply hook is down. Keyed on the FAMILY (not the raw
#   task id): a staged family rolls many stage ids into ONE done-report.
# push-pending - batch the captain's pending inbox OUT to the remote channel.
#   Silent no-op (exit 0) without an executable config/remote-reply hook. Per
#   family with a room (data/<family>/room.md), the unanswered GATE/ASK lines
#   (count from `ac-room.sh pending` - the authoritative accounting; because
#   decisions settle oldest-first, the unanswered items are exactly the LAST
#   <count> GATE/ASK entries) are hashed against the family's stamp in
#   state/.remote-push-stamp: only a family whose pending set is NEW since
#   the last push gets a message, and it gets exactly ONE - a compact list
#   of the pending lines - through the reply hook. Threading: the mapping
#   state/remote-threads/<family>.thread supplies AC_REMOTE_THREAD from its
#   thread_ts= key; absent, the hook posts top-level (AC_REMOTE_THREAD
#   empty, AC_REMOTE_RID=<family>, so a self-registering hook records the
#   mapping itself) and the ts the hook prints on stdout (the remote-reply
#   new-thread contract) is recorded as thread_ts=/cursor= when the hook did
#   not. The stamp advances only after a delivered message: a failing hook
#   is warned, kept unstamped, and retried on the next push. Nothing pending
#   anywhere = silent.
# gc [--days <n>] - prune stashes older than n days (default 14, file mtime)
#   that no task meta (live or archived) links via remote_request=.
#
# SECURITY - remote message text is UNTRUSTED, non-negotiable: it is never
#   eval'd, never interpolated into a shell command line, never used to
#   derive a file name. Only the rid names files, and only after the slug
#   guard ([A-Za-z0-9._-]+ - no slash, so no path traversal). Hooks receive
#   text on stdin and identifiers in env, never as argv. Wake payloads carry
#   the rid alone, never the text.
#
# Hook contracts (config/, executable, transport-owned - this header is the
# authoritative spec, including for the Slack pair):
#   remote-poll  - stdout: zero or more JSON lines {rid,text,author,thread,...}
#   remote-reply - env AC_REMOTE_RID, AC_REMOTE_THREAD; reply text on stdin

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

# This script always resolves ac-lib.sh trivially (colocated in bin/), so it
# is the natural place to self-heal state/.ac-root for the transport hooks it
# runs (config/remote-poll/-reply/-ack) - they have no fixed relative path
# back to the distro checkout and cannot rely on their caller's cwd.
ac_seed_root_pointer

ac_require jq

state_dir="$(ac_state_dir)"
inbox="$state_dir/remote-inbox"

rid_ok() {
  # rid_ok <rid> - the ONLY gate between remote input and a file name.
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  # all-dot rids ('.', '..', '...') pass the class but make hostile filenames
  case "$1" in *[!.]*) : ;; *) return 1 ;; esac
}

rid_guard() { rid_ok "${1:-}" || ac_die "rid must be [A-Za-z0-9._-]+: '${1:-}'"; }

task_guard() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) ac_die "task id must be [A-Za-z0-9._-]+: '${1:-}'" ;;
  esac
}

quote_offender() {
  # quote_offender <text> - first line, capped, for an `ac_die` refusal that
  # quotes a caller-supplied argument verbatim. ac_die prints one `ERROR: %s`
  # line; an unbounded multi-line/long argument pushes ERROR: off the tail of
  # `| tail -N`, so a caller reading only the tail sees its own text and reads
  # it as success (LIVED 2026-07-25). Truncating keeps the diagnostic on the
  # one line ac_die prints.
  local text="$1" first="${1%%$'\n'*}" cap=60
  if [ "$first" != "$text" ] || [ "${#first}" -gt "$cap" ]; then
    printf '%s...' "${first:0:$cap}"
  else
    printf '%s' "$first"
  fi
}

meta_unset() {
  # meta_unset <file> <key> - atomic key removal (ac_meta_set idiom).
  local file="$1" key="$2" tmp="$1.tmp.$$"
  [ -f "$file" ] || return 0
  grep -v "^$key=" "$file" >"$tmp" || true
  mv "$tmp" "$file"
}

run_ack() {
  # run_ack <label> <rid> <state> [<thread>] - one LIFECYCLE-ACK hook call
  # (header contract): best-effort at every edge, stdout muzzled, one
  # warning on failure, never blocks the caller.
  local label="$1" rid="$2" ackstate="$3" thread="${4:-}" ack
  ack="$(ac_config_dir)/remote-ack"
  [ -x "$ack" ] || return 0
  AC_REMOTE_RID="$rid" AC_REMOTE_THREAD="$thread" AC_REMOTE_ACK_STATE="$ackstate" \
    "$ack" </dev/null >/dev/null \
    || ac_warn "$label: remote-ack hook failed for $rid ($ackstate)"
  return 0
}

ingest_stream() {
  # ingest_stream <label> - THE per-line order core, shared by poll and
  # ingest (one implementation, two entrances). Reads JSON lines on stdin;
  # per valid NEW rid: exclusive stash, durable wake, one printed line.
  # Malformed lines and refused rids are warned (prefixed <label>) and
  # skipped - bad input is never a hard failure; always returns 0.
  local label="$1" line rid stash tmp
  mkdir -p "$inbox"
  # `|| [ -n "$line" ]` keeps a final unterminated line (a gateway may not
  # end its stream with a newline) from being silently dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # Validate BEFORE trusting anything: a JSON object carrying the four
    # required keys, rid a string. The line itself is never re-parsed by
    # the shell - herestrings and printf %s keep it inert bytes.
    if ! jq -e 'type=="object" and (.rid|type)=="string"
                and has("text") and has("author") and has("thread")' \
        >/dev/null 2>&1 <<<"$line"; then
      ac_warn "$label: skipped a malformed line (need JSON {rid,text,author,thread})"
      continue
    fi
    rid="$(jq -r '.rid' <<<"$line")"
    if ! rid_ok "$rid"; then
      ac_warn "$label: refused rid (must be [A-Za-z0-9._-]+): $rid"
      continue
    fi
    stash="$inbox/$rid.json"
    [ -e "$stash" ] && continue
    tmp="$inbox/.stash.$rid.$$"
    printf '%s\n' "$line" >"$tmp"
    # Exclusive publish: ln fails when the stash already exists, so a racing
    # ingester can never double-queue the wake for one rid. The wake itself
    # is published the same way (ac_wake_publish), HARD-WIRED FLEET (scope
    # '' - never AC_SCOPE): a remote order addresses the crewchief, and the
    # single poller is the fleet watcher. Published from this script's main
    # shell (ac_wake_publish's subshell contract).
    if ln "$tmp" "$stash" 2>/dev/null; then
      rm -f "$tmp"
      ac_wake_publish "$state_dir" '' remote captain "remote-order $rid"
      # A remote order is the captain SPEAKING, not waiting - they already
      # get the ac-remote reply as confirmation, and captain 2026-07-30
      # ("block boi captain") confined the one captain notification to the
      # blocked-by-captain edge (bin/ac-room.sh's cmd_post). No ac-notify.sh
      # call here anymore.
      # LIFECYCLE-ACK `ingested` (header contract): once per newly stashed
      # rid, after the durable commit.
      run_ack "$label" "$rid" ingested "$(jq -r '.thread // empty' <<<"$line")"
      printf 'remote-order %s\n' "$rid"
    else
      rm -f "$tmp"
    fi
  done
  return 0
}

cmd_poll() {
  local hook out rc=0 errfile err
  hook="$(ac_config_dir)/remote-poll"
  if [ ! -f "$hook" ] || [ ! -x "$hook" ]; then exit 0; fi
  errfile="$(mktemp "${TMPDIR:-/tmp}/ac-remote-poll-err.XXXXXX")"
  out="$("$hook" 2>"$errfile")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err="$(cat "$errfile")"
    rm -f "$errfile"
    if [ -n "$err" ]; then
      ac_warn "remote-poll hook failed (exit $rc): $(quote_offender "$err") - skipping this poll"
    else
      ac_warn "remote-poll hook failed (exit $rc) - skipping this poll"
    fi
    exit 0
  fi
  # A successful hook may still write stderr (e.g. a 429 backoff warn) - pass
  # it through byte-identically, the same as before this capture existed.
  cat "$errfile" >&2
  rm -f "$errfile"
  ingest_stream remote-poll <<<"$out"
}

cmd_ingest() {
  # Push-gateway entrance: JSON lines arrive on OUR stdin - no hook, no
  # config/remote-poll needed (a gateway may be the only transport).
  ingest_stream ingest
}

cmd_show() {
  local rid="${1:-}"
  [ -n "$rid" ] || ac_die "usage: ac-remote.sh show <rid>"
  rid_guard "$rid"
  [ -f "$inbox/$rid.json" ] || ac_die "no stashed remote order: $rid"
  cat "$inbox/$rid.json"
}

cmd_reply() {
  local rid="${1:-}" textfile=""
  [ -n "$rid" ] || ac_die "usage: ac-remote.sh reply <rid> [--text-file <f>]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --text-file) [ -n "${2:-}" ] || ac_die "--text-file needs a path"; textfile="$2"; shift 2 ;;
      *) ac_die "unknown reply option: $(quote_offender "$1")" ;;
    esac
  done
  rid_guard "$rid"
  local hook stash thread
  hook="$(ac_config_dir)/remote-reply"
  [ -f "$hook" ] || ac_die "reply needs a config/remote-reply hook (transport not configured)"
  [ -x "$hook" ] || ac_die "config/remote-reply is not executable (chmod +x it)"
  stash="$inbox/$rid.json"
  [ -f "$stash" ] || ac_die "no stashed remote order: $rid"
  thread="$(jq -r '.thread // empty' "$stash")"
  # Identifiers in env, text on stdin - never as arguments (see SECURITY).
  if [ -n "$textfile" ]; then
    [ -f "$textfile" ] || ac_die "text file not found: $textfile"
    AC_REMOTE_RID="$rid" AC_REMOTE_THREAD="$thread" "$hook" <"$textfile" \
      || ac_die "remote-reply hook failed for $rid (reply NOT delivered)"
  else
    AC_REMOTE_RID="$rid" AC_REMOTE_THREAD="$thread" "$hook" \
      || ac_die "remote-reply hook failed for $rid (reply NOT delivered)"
  fi
  printf 'replied %s\n' "$rid"
}

cmd_link() {
  local task="${1:-}" rid="${2:-}" meta
  { [ -n "$task" ] && [ -n "$rid" ]; } || ac_die "usage: ac-remote.sh link <task-id> <rid>"
  task_guard "$task"
  rid_guard "$rid"
  [ -f "$inbox/$rid.json" ] || ac_die "no stashed remote order: $rid (poll first)"
  meta="$(ac_task_meta "$task")"
  ac_meta_set "$meta" remote_request "$rid"
  ac_meta_set "$meta" remote_request_ts "$(ac_now)"
  run_ack link "$rid" working "$(jq -r '.thread // empty' "$inbox/$rid.json" 2>/dev/null)"
  printf 'linked %s -> %s\n' "$task" "$rid"
}

cmd_ack() {
  # cmd_ack <rid> <working|done> - fire one LIFECYCLE-ACK edge by hand, for
  # orders handled INLINE (answered with `reply`, no task ever linked):
  # link/followup ack their own edges, but an inline answer has neither, so
  # the captain's emoji parks at the ingest state forever (live miss
  # 2026-07-18: an order answered in-thread kept :eyes: after completion).
  # The chief calls `ack <rid> working` when it starts, `ack <rid> done`
  # after the delivered answer. Explicit by design - never inferred from
  # reply, which also carries questions and intermediate notes.
  local rid="${1:-}" ackstate="${2:-}"
  { [ -n "$rid" ] && [ -n "$ackstate" ]; } || ac_die "usage: ac-remote.sh ack <rid> <working|done>"
  rid_guard "$rid"
  case "$ackstate" in
    working|done) : ;;
    *) ac_die "ack state must be working|done: $ackstate" ;;
  esac
  [ -f "$inbox/$rid.json" ] || ac_die "no stashed remote order: $rid"
  run_ack ack "$rid" "$ackstate" "$(jq -r '.thread // empty' "$inbox/$rid.json" 2>/dev/null)"
  printf 'acked %s (%s)\n' "$rid" "$ackstate"
}

cmd_followup() {
  local task="${1:-}" textfile=""
  [ -n "$task" ] || ac_die "usage: ac-remote.sh followup <task-id> [--text-file <f>]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --text-file) [ -n "${2:-}" ] || ac_die "--text-file needs a path"; textfile="$2"; shift 2 ;;
      *) ac_die "unknown followup option: $(quote_offender "$1")" ;;
    esac
  done
  task_guard "$task"
  local meta rid=""
  meta="$(ac_task_meta "$task")"
  [ -f "$meta" ] && rid="$(ac_meta_get "$meta" remote_request)"
  if [ -z "$rid" ] && [ -f "$state_dir/archive/$task/meta" ]; then
    meta="$state_dir/archive/$task/meta"
    rid="$(ac_meta_get "$meta" remote_request)"
  fi
  if [ -z "$rid" ]; then
    ac_warn "no remote order linked to $task (already followed up, or never linked) - nothing sent"
    exit 0
  fi
  rid_guard "$rid"
  # Reply first, clear after: a failed reply dies above this line and the
  # link survives for a retry (fail-closed, one follow-up per link).
  if [ -n "$textfile" ]; then
    cmd_reply "$rid" --text-file "$textfile" >/dev/null
  else
    cmd_reply "$rid" >/dev/null
  fi
  meta_unset "$meta" remote_request
  meta_unset "$meta" remote_request_ts
  # LIFECYCLE-ACK `done`: only past the delivered reply above (fail-closed
  # parity - a failed reply died before the link was cleared).
  run_ack followup "$rid" "done" "$(jq -r '.thread // empty' "$inbox/$rid.json" 2>/dev/null)"
  printf 'followed up %s -> %s (link cleared)\n' "$task" "$rid"
}

family_send() {
  # family_send <family> [<mention>] - text on stdin into the family's
  # remote thread, the SHARED sender behind push-pending and thread-post.
  # Resolves the thread from state/remote-threads/<family>.thread; on a
  # first post whose hook did not self-register, records thread_ts/cursor
  # from the ts the hook printed (the remote-reply new-thread contract).
  # <mention>=captain rides to the hook as AC_REMOTE_MENTION - the hook
  # pings the captain (approval-needed posts notify, receipts stay quiet).
  # Silent 0 with stdin drained when no executable hook exists; 1 when the
  # hook fails (the text did NOT go out). Identifiers in env, text on
  # stdin - never as arguments (see SECURITY).
  # Sets the global _family_send_ts to the first line the hook printed on
  # this call (empty if it printed nothing - the real hook only prints a ts
  # for a top-level post, per its own contract) so a caller that wants the
  # message ts for its own confirmation can read it right after the call
  # returns. A plain global is safe for thread-post, which calls this
  # function directly (same shell, no subshell); push-pending calls it as
  # the right-hand side of a pipe, which runs in ITS OWN subshell, so a ts
  # it sets there never reaches push-pending's shell - harmless, since
  # push-pending never reads it.
  local family="$1" hook tdir tfile thread out
  _family_send_ts=""
  hook="$(ac_config_dir)/remote-reply"
  if [ ! -f "$hook" ] || [ ! -x "$hook" ]; then cat >/dev/null; return 0; fi
  tdir="$state_dir/remote-threads"
  tfile="$tdir/$family.thread"
  thread=""
  [ -f "$tfile" ] && thread="$(ac_meta_get "$tfile" thread_ts)"
  out="$(AC_REMOTE_RID="$family" AC_REMOTE_THREAD="$thread" AC_REMOTE_MENTION="${2:-}" "$hook")" || return 1
  _family_send_ts="$(printf '%s\n' "$out" | head -n 1)"
  if [ -z "$thread" ] && [ ! -e "$tfile" ]; then
    if [ -n "$_family_send_ts" ]; then
      mkdir -p "$tdir"
      ac_meta_set "$tfile" thread_ts "$_family_send_ts"
      ac_meta_set "$tfile" cursor "$_family_send_ts"
    else
      ac_warn "family thread: $family posted top-level but the hook printed no ts - thread mapping not recorded"
    fi
  fi
  return 0
}

cmd_thread_post() {
  local family="${1:-}" textfile="" mention="" hook
  [ -n "$family" ] || ac_die "usage: ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --text-file) [ -n "${2:-}" ] || ac_die "--text-file needs a path"; textfile="$2"; shift 2 ;;
      --mention-captain) mention="captain"; shift ;;
      *) ac_die "unknown thread-post option: $(quote_offender "$1")" ;;
    esac
  done
  rid_guard "$family"
  hook="$(ac_config_dir)/remote-reply"
  if [ -n "$textfile" ]; then
    [ -f "$textfile" ] || ac_die "thread-post: no such file: $textfile"
    family_send "$family" "$mention" <"$textfile" \
      || ac_die "thread-post: remote-reply hook failed for $family - text NOT delivered"
  else
    family_send "$family" "$mention" \
      || ac_die "thread-post: remote-reply hook failed for $family - text NOT delivered"
  fi
  # HONESTY: a "delivered" confirmation must never print when nothing was
  # delivered (LIVED 2026-07-25: the prior total silence made a caller
  # re-run this verb just to read its exit code, duplicating a captain-
  # facing message). No hook = warn, not a delivered line; carry the
  # message ts when the hook printed one (verifiable, not just reassuring).
  if [ ! -f "$hook" ] || [ ! -x "$hook" ]; then
    ac_warn "thread-post: no config/remote-reply hook - $family NOT delivered (transport not configured)"
  elif [ -n "$_family_send_ts" ]; then
    printf 'posted %s (%s)\n' "$family" "$_family_send_ts"
  else
    printf 'posted %s\n' "$family"
  fi
}

cmd_done_stamp() {
  # cmd_done_stamp <family> - stamp the family's landing done-report as posted
  # (header contract). Presence of the family key in state/.landing-receipt-
  # stamp is what silences the turn-end guard's landing-receipt reminder.
  local family="${1:-}"
  [ -n "$family" ] || ac_die "usage: ac-remote.sh done-stamp <family>"
  rid_guard "$family"
  ac_meta_set "$state_dir/.landing-receipt-stamp" "$family" "$(ac_now)"
  printf 'done-stamped %s\n' "$family"
}

cmd_push_pending() {
  # Batch NEW captain-pending room items out to the remote channel (spec:
  # header). Sends via family_send - there is no rid stash for a family
  # thread; AC_REMOTE_RID carries the family so a self-registering hook
  # creates state/remote-threads/<family>.thread itself.
  local hook stamp f family count lines hash prev
  hook="$(ac_config_dir)/remote-reply"
  if [ ! -f "$hook" ] || [ ! -x "$hook" ]; then return 0; fi
  stamp="$state_dir/.remote-push-stamp"
  for f in "$(ac_data_dir)"/*/room.md; do
    [ -f "$f" ] || continue
    family="$(basename "$(dirname "$f")")"
    if ! rid_ok "$family"; then
      ac_warn "push-pending: skipped family with unsafe name: $family"
      continue
    fi
    count="$("$(dirname "$0")/ac-room.sh" pending "$family" 2>/dev/null || printf '0')"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    [ "$count" -gt 0 ] || continue
    # Decisions settle oldest-first (ac-wake-lib.sh ac_room_pending), so the
    # unanswered items are exactly the LAST <count> GATE/ASK entries.
    lines="$(grep -E '^- \[.*\] .*> (GATE|ASK):' "$f" | tail -n "$count")"
    hash="$(printf '%s' "$lines" | shasum -a 256 | awk '{print $1}')"
    prev="$(ac_meta_get "$stamp" "$family")"
    [ "$hash" = "$prev" ] && continue
    # Header follows the captain's Slack rules (AGENTS.md section 8):
    # `*[UTC+7 ts] [VERB] [<family>]*`, Vietnamese framing, ids and grammar
    # verbs verbatim; the pending record lines drop their ISO prefix and
    # render as bullets (the room keeps the raw record).
    if ! printf '⏳ *[%s] [ĐANG CHỜ captain] [%s]* (%s mục)\n%s\n' \
        "$(ac_vn_ts)" "$family" "$count" \
        "$(printf '%s\n' "$lines" | sed -E 's/^- \[[^]]*\] /• /')" \
        | family_send "$family" captain; then
      ac_warn "push-pending: remote-reply hook failed for $family - kept for the next push"
      continue
    fi
    ac_meta_set "$stamp" "$family" "$hash"
    printf 'pushed %s (%s pending)\n' "$family" "$count"
  done
  return 0
}

cmd_gc() {
  local days=14 stash rid m linked
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) [ -n "${2:-}" ] || ac_die "--days needs a number"; days="$2"; shift 2 ;;
      *) ac_die "unknown gc option: $(quote_offender "$1")" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) ac_die "--days must be a whole number: $days" ;; esac
  [ -d "$inbox" ] || return 0
  while IFS= read -r stash; do
    [ -n "$stash" ] || continue
    rid="$(basename "$stash" .json)"
    linked=0
    for m in "$state_dir"/*.meta "$state_dir"/archive/*/meta; do
      [ -f "$m" ] || continue
      if grep -qxF "remote_request=$rid" "$m" 2>/dev/null; then linked=1; break; fi
    done
    [ "$linked" = 1 ] && continue
    rm -f "$stash"
    printf 'pruned %s\n' "$rid"
  done < <(find "$inbox" -type f -name '*.json' -mtime "+$days" 2>/dev/null)
  # Visibility for the stash-published/wake-lost crash window: a young
  # unlinked stash whose rid is not in the wake spool may be a stranded
  # order - surface it so an inbox audit is one gc away.
  while IFS= read -r stash; do
    [ -n "$stash" ] || continue
    rid="$(basename "$stash" .json)"
    grep -qrF "remote-order $rid" "$(ac_wake_spool_path "$state_dir" '')" \
      2>/dev/null && continue
    linked=0
    for m in "$state_dir"/*.meta "$state_dir"/archive/*/meta; do
      [ -f "$m" ] || continue
      if grep -qxF "remote_request=$rid" "$m" 2>/dev/null; then linked=1; break; fi
    done
    [ "$linked" = 1 ] && continue
    printf 'unwoken %s (stashed, no queued wake, unlinked - inspect with: ac-remote.sh show %s)\n' "$rid" "$rid" >&2
  done < <(find "$inbox" -type f -name '*.json' ! -mtime "+$days" 2>/dev/null)
  return 0
}

case "${1:-}" in
  poll) shift; cmd_poll ;;
  ingest) shift; cmd_ingest ;;
  show) shift; cmd_show "$@" ;;
  reply) shift; cmd_reply "$@" ;;
  link) shift; cmd_link "$@" ;;
  followup) shift; cmd_followup "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  thread-post) shift; cmd_thread_post "$@" ;;
  done-stamp) shift; cmd_done_stamp "$@" ;;
  push-pending) shift; cmd_push_pending ;;
  gc) shift; cmd_gc "$@" ;;
  *) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
