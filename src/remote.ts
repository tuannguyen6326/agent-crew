// remote.ts - transport-agnostic remote captain orders: the durable state
// machine around a remote transport (inbox stash, wake queue, task links,
// landing follow-ups). The entry is bin/ac-remote.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, including
// for the Slack hook pair under docs/examples/slack-remote/, and the bash
// original it replaced stays frozen at tests/fixtures/ac-remote.sh as the
// oracle the differential leg of tests/sh/ac-remote.test.sh holds this module
// to. Prose elsewhere naming the original's functions resolves here:
// ingest_stream is the INGEST CORE, cmd_poll is poll, run_ack the
// LIFECYCLE-ACK call and family_send the family sender.
//
// The transport is NEVER built in: user-owned hooks in config/ carry it
// (Slack or anything else) - remote-poll (fetch), remote-reply (post),
// remote-ack (an OPTIONAL seen-receipt) - and absent hooks every verb degrades
// safely.
//
// Usage:
//   ac-remote.sh poll                                 # fetch new remote orders
//   ac-remote.sh ingest                               # stash orders fed on stdin
//   ac-remote.sh order [--text-file <f>] ['<text>']   # stash ONE local order (thread "local")
//   ac-remote.sh show <rid>                           # print a stashed order
//   ac-remote.sh reply <rid> [--text-file <f>]        # text into the order's thread
//   ac-remote.sh link <task-id> <rid>                 # bind a task to an order
//   ac-remote.sh followup <task-id> [--text-file <f>] # landing follow-up, clears link
//   ac-remote.sh ack <rid> <working|done>             # lifecycle edge for INLINE-handled orders
//   ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]
//                                                     # text into the family's thread
//   ac-remote.sh done-stamp <family>                  # mark the family's landing done-report as posted
//   ac-remote.sh push-pending                         # batch pending gates/asks out
//   ac-remote.sh gc [--days <n>]                      # MANUAL: prune old unlinked stashes
//
// Every refusal is `ERROR: <msg>` on stderr, exit 1, every warning `WARN:
// <msg>`; a verb's own lines go to stdout. Words: <rid> passes the RID GUARD
// - one or more of [A-Za-z0-9._-], read per that text under any locale, and
// not all dots - the ONLY gate between remote input and a file name; a
// <task-id> passes the TASK GUARD, the same class without the all-dot rule; a
// <family> passes the rid guard. A refused argv is `rid must be
// [A-Za-z0-9._-]+: '<rid>'` / `task id must be [A-Za-z0-9._-]+: '<task>'`. An
// unknown option of reply, followup, thread-post or gc is `unknown <verb>
// option: <q>` where <q> is QUOTE_OFFENDER of it: its first line, cut to 60
// characters (bytes under the C locale; under a UTF-8 one a valid sequence is
// one character and any other byte one on its own - W13) and followed by `...`
// when it was cut or had more lines, so the ERROR survives a caller's `| tail
// -1`. `--text-file` with no value or an empty one is `--text-file needs a
// path`; a relative path is the caller's. Options are parsed before any guard
// (`reply --text-file f` refuses `f` as an option - W25).
//
// PREAMBLE, every argv, usage included, in this order: with AC_HOME non-empty
// the home is bound through physicalDir (an AC_HOME cd cannot enter is
// `AC_HOME is not a readable directory: <h>` - W3, named below), state/ is
// minted and state/.ac-root - the distro checkout this home's hooks resolve
// bin/ac-lib.sh through - is rewritten with `<root>\n` (the physical root of
// the checkout whose bin/ started this, ac-bun.sh's cwd) unless what it holds,
// NULs and trailing LFs read away, already equals <root>; the write follows a
// symlink, and one that fails ends EVERY verb, show and usage included,
// `cannot write <ptr>: <errno>` (W2); then jq must be on PATH (`required tool
// not found: jq` - after the pointer was written, homeless too - W1); then the
// home (homeless: ac_home's AC_HOME refusal). An unknown verb, none or `-h`
// prints this header on stdout, exit 2. Extra words are ignored by poll,
// ingest, push-pending, show, link, ack and done-stamp.
//
// poll - HARD no-op (exit 0, no output) unless config/remote-poll is a regular
//   file (a symlink followed) and executable. stderr is captured to a file
//   `mktemp ${TMPDIR:-/tmp}/ac-remote-poll-err.XXXXXX` (spawned; a TMPDIR it
//   cannot use ends poll with mktemp's own line and status - W11), the hook
//   runs (HOOKS), and its stdout is captured to EOF (NULs dropped, trailing LFs
//   stripped). A non-zero status (128+n for a signal) is `WARN: remote-poll
//   hook failed (exit <rc>): <QUOTE_OFFENDER of its stderr, NULs and trailing
//   LFs dropped> - skipping this poll`, or with empty stderr `WARN: remote-poll
//   hook failed (exit <rc>) - skipping this poll`, nothing ingested, exit 0.
//   Status 0: the hook's stderr is replayed on ours byte for byte, then the
//   capture plus one LF runs through the INGEST CORE labelled `remote-poll`.
//   poll must never kill a watcher: only W11 and the core's own deaths exit
//   non-zero.
// ingest - the push-gateway entrance: our own stdin through the INGEST CORE
//   labelled `ingest`, each line handled AS IT ARRIVES (a gateway may hold its
//   pipe open between orders); no config/remote-poll needed. Exit 0 but for
//   the core's deaths.
// order - the LOCAL entrance (a SOLO session handing the captain's word to
//   the chief): the text is the --text-file's (spawned `cat`, its line and
//   status on failure; a path that is no regular file is `text file not
//   found: <f>`; NULs and trailing LFs dropped) or else the LAST positional
//   word (W14). `tr -d '[:space:]'` (spawned, the caller's locale: NBSP is
//   space only under UTF-8, an invalid byte there is tr's own `Illegal byte
//   sequence` - W16) leaving nothing is `order needs its text: ac-remote.sh
//   order [--text-file <f>] ['<text>']`. rid = `local-<date -u
//   +%Y%m%dT%H%M%SZ>-<pid>` (a failing date ends the run with its status; the
//   pid is the shim's, which exec'd into this process). jq builds the line
//   `jq -cn --arg rid <rid> --arg text <text> '{rid: $rid, text: $text, author:
//   "captain", thread: "local"}'`, the text handed over as the bytes the shell
//   handed it (through /bin/sh, since argv from here is UTF-8): jq escapes `"`
//   `\` and the controls (DEL as \u007f), keeps U+2028 raw and decodes an
//   invalid sequence its own way (W15); a text past ARG_MAX fails jq's exec,
//   exit 1, nothing stashed (W17). The line runs through the INGEST CORE
//   labelled `order`; a failing jq then ends the run with its status. Then,
//   unless watcherPid finds a live fleet watcher (the lock's pid alive and its
//   `ps -o command=` naming ac-watch or /src/watch.ts), a second line: `no live fleet watcher
//   right now - <rid> waits in the spool until a chief session drains it
//   (bin/ac-wake-drain.sh, or the next session-start)` - DELIVERY PROSPECTS: a
//   caller parsing the rid reads line 1 only.
// show <rid> - `usage: ac-remote.sh show <rid>`; the guard; `no stashed remote
//   order: <rid>`; else the stash's bytes (spawned `cat`, its line and status
//   when it cannot read). Orchestrators read order text from DISK, never from
//   the wake payload.
// reply <rid> [--text-file <f>] - `usage: ac-remote.sh reply <rid> [--text-file
//   <f>]`; options; the guard; `no stashed remote order: <rid>`; the thread is
//   `jq -r '.thread // empty' <stash>` (jq's stderr passes; a stash jq cannot
//   parse ends the run with jq's status - W26). A thread of exactly `local`
//   (an order's, or a polled one's whose thread is the string "local" - W22)
//   has no transport: `## <iso>\n`, the text (the file through `cat`, else our
//   stdin through `cat`), `\n` are appended to <inbox>/<rid>.replies.md (a
//   missing file is `text file not found: <f>`; empty stdin still appends; a
//   cat that fails leaves the header and ends the run with cat's status -
//   W23) and stdout says `replied <rid> (local thread: <path>)`, the path
//   physical. Any other thread needs config/remote-reply: absent is `reply
//   needs a config/remote-reply hook (transport not configured)`, not
//   executable `config/remote-reply is not executable (chmod +x it)`, a
//   missing file `text file not found: <f>`; the hook gets AC_REMOTE_RID and
//   AC_REMOTE_THREAD and the text on stdin (the file, else ours), its stdout
//   and stderr ours; a non-zero status - or a file that cannot be opened
//   (W24) - is `remote-reply hook failed for <rid> (reply NOT delivered)`;
//   else `replied <rid>`.
// link <task-id> <rid> - `usage: ac-remote.sh link <task-id> <rid>`; the task
//   guard; the rid guard; `no stashed remote order: <rid> (poll first)`; then
//   remote_request=<rid> and remote_request_ts=<NOW> set in state/<id>.meta
//   (META SET; any id mints a meta - W29), the `working` ack (thread from the
//   stash, jq's stderr dropped: an unparseable stash acks with none), `linked
//   <task> -> <rid>`. NOW is a non-empty EPOCHSECONDS as `$(ac_now)` read it,
//   trailing LFs cut (bash 3.2 has no such builtin, so an exported one won -
//   W35), else `date +%s`'s capture, "" when date fails.
// followup <task-id> [--text-file <f>] - `usage: ac-remote.sh followup
//   <task-id> [--text-file <f>]`; options; the task guard; the rid is the LAST
//   remote_request= of state/<id>.meta, else of state/archive/<id>/meta (a meta
//   that cannot be read is metaGet's `WARN: cannot read meta file <f>`, exit 1
//   - W30); none is `WARN: no remote order linked to <task> (already followed
//   up, or never linked) - nothing sent`, exit 0. The stored rid passes the
//   guard; reply runs as above with its stdout - the hook's too - discarded
//   and its refusals ours; then every remote_request= and remote_request_ts=
//   line leaves the meta it was read from (META SET), the `done` ack, and
//   `followed up <task> -> <rid> (link cleared)`. One follow-up per link: a
//   failed reply keeps it.
// ack <rid> <working|done> - for orders handled INLINE: `usage: ac-remote.sh
//   ack <rid> <working|done>`; the guard; `ack state must be working|done:
//   <state>`; `no stashed remote order: <rid>`; the ack; `acked <rid>
//   (<state>)`.
// thread-post <family> [--text-file <f>] [--mention-captain] - `usage:
//   ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]`;
//   options; the rid guard on the family (dots pass - W27); a --text-file that
//   is no regular file is `thread-post: no such file: <f>`; the text (the
//   file, else our stdin) goes through FAMILY SEND with mention `captain` under
//   --mention-captain, else empty. A failed send - or a file that cannot be
//   opened (W24) - is `thread-post: remote-reply hook failed for <family> -
//   text NOT delivered`. Then, the hook re-checked: none is `WARN: thread-post:
//   no config/remote-reply hook - <family> NOT delivered (transport not
//   configured)`, exit 0; else `posted <family> (<ts>)` when the hook printed a
//   first line, `posted <family>` when not. A caller never reads "posted" when
//   nothing went out. config/remote-mirror gates only the AUTO-mirror callers
//   (ac-room.sh, ac-spawn.sh), never this verb.
// done-stamp <family> - `usage: ac-remote.sh done-stamp <family>`; the guard;
//   <family>=<NOW> set in state/.landing-receipt-stamp (META SET - its key a
//   BRE, so `a.b` also drops an `aXb=` stamp - W28); `done-stamped <family>`.
//   The turn-end guard's landing-receipt check reads that file; no hook needed.
// push-pending - silent exit 0 without an executable config/remote-reply.
//   Each data/<family>/room.md that is a regular file, families in BYTE order
//   (dot names never; the original's glob followed the caller's collation -
//   ORDER rule, named): a family the rid guard refuses is `WARN: push-pending:
//   skipped family with unsafe name: <family>` (every run); its PENDING LINES
//   (roomPendingLines, src/lib.ts: the unanswered GATE/ASK lines oldest first,
//   each DECIDED settling the oldest open one, a room that cannot be read
//   skipped) - none skips; <count> is their number and <hash> the sha256 of
//   them LF-joined; the family's stamp in state/.remote-push-stamp is read as
//   ac_meta_get read it - awk's `$1==k`, numeric when both sides look like
//   numbers (`07` reads a `7=` line, `nan` every line), the value from byte
//   length(k)+2 of whichever line matched, the last match winning (W37) - a
//   stamp that cannot be read is metaGet's WARN, exit 1 (W33); an equal stamp
//   skips. The message `⏳ *[<vn stamp>] [ĐANG CHỜ captain] [<family>]*
//   (<count> mục)\n<lines through spawned sed -E 's/^- \[[^]]*\] /• /' under
//   the caller's locale>\n` (vn stamp: `TZ=Asia/Ho_Chi_Minh date '+%Y-%m-%d
//   %H:%M'`) goes through FAMILY SEND with mention captain: a failure is `WARN:
//   push-pending: remote-reply hook failed for <family> - kept for the next
//   push`; a delivery sets <family>=<hash> (META SET) and prints `pushed
//   <family> (<count> pending)`. Exit 0 but W33.
// gc [--days <n>] - MANUAL, deliberately: nothing in the tree calls it, and a
//   stash is also the dedup sign, so deleting one re-opens its rid to
//   ingestion. `--days needs a number`, `unknown gc option: <q>`, `--days must
//   be a whole number: <d>` (default 14); no inbox is exit 0. Spawned `find
//   <inbox> -type f -name '*.json' -mtime +<days>` (stderr dropped; -mtime +N
//   is floor(age/86400) > N, `08` is eight, a window past 64 bits makes find
//   fail and nothing prunes), in find's own order; the rid is the line's
//   basename less `.json`; one linked by an exact `remote_request=<rid>` line
//   in a regular state/*.meta or state/archive/*/meta is kept (an older-epoch
//   archive dir's meta never protects - W34); else it is removed (rm(1)'s line
//   and status when it cannot be) and `pruned <rid>` printed. A replies file is
//   never pruned (W34).
//
// THE INGEST CORE, one implementation behind poll, ingest and order, <label>
// their name. state/remote-inbox (<inbox>) is minted by mkdir(1), whose failure
// ends the run. Lines are read as `IFS= read -r` read them: split on LF, each
// cut at its first NUL (W9 - poll's capture had already DROPPED its NULs, so
// `{..}\0junk` is ingested through ingest and malformed through poll), CR and
// blanks kept (W10), an unterminated last line read, an empty one skipped. Per
// line, in this order:
//   1. `jq -e 'type=="object" and (.rid|type)=="string" and has("text") and
//      has("author") and has("thread")'` over the line + LF (output dropped)
//      failing is `WARN: <label>: skipped a malformed line (need JSON
//      {rid,text,author,thread})`. jq decides: two objects on a line are two
//      values, the last one judged (W5); a number, an array, a missing thread
//      are malformed; NaN text and a duplicate key pass.
//   2. rid = `jq -r '.rid'`'s capture (its stderr ours; a non-zero status ends
//      the run with it): `1 {valid}` is ingested with jq's own error line.
//   3. the rid guard failing is `WARN: <label>: refused rid (must be
//      [A-Za-z0-9._-]+): <rid>` - raw, so two values make it two lines (W5).
//   4. <inbox>/<rid>.json existing (a symlink followed) skips silently: the
//      rid is the idempotency key - a re-poll, a re-delivery through the other
//      entrance, a duplicate inside the batch. A DANGLING symlink there is no
//      stash, yet blocks the link below, so that rid is skipped for ever (W7).
//   5. the line + LF is written to a temp `<inbox>/.stash.<rid>.<pid>`, created
//      exclusively (the next name `.<n>` on EEXIST); a temp that cannot be
//      written - an unwritable inbox, a rid too long for the name (W8) - is
//      `cannot write <temp>: <errno>`, exit 1, every later line unread.
//   6. UNINTERRUPTIBLE FROM THE STASH LINK TO THE WAKE'S LINK, and no wider:
//      the stash is also the dedup sign, so an INT between the two commits
//      burns the rid - permanently for a LOCAL rid, minted once and re-offered
//      by nothing. A death BETWEEN the two is not covered and cannot be from
//      here. SIGINT is ignored there by this process and by every child started
//      there (MECHANICS 2). link(2) of the temp to <inbox>/<rid>.json failing
//      (it exists) is a silent skip; else the temp goes and wakePublish
//      (src/lib.ts) publishes `<ts10>\tremote\tcaptain\tremote-order <rid>\n` as
//      `state/.wake-spool/<date +%s%N>.<pid>.<seq6>` - the FLEET spool whatever
//      AC_SCOPE says (a remote order addresses the crewchief). A publish that
//      fails (a spool path a file sits on: mkdir's own line; the record's
//      `.wake-tmp.` temp left as litter) rolls the stash back - a stash with no
//      wake would burn the rid - and dies `<label>: no wake could be published
//      for <rid> - NOT ingested. Re-send it AND anything after it in the same
//      batch: this exits before reading the rest`; a stash the rollback cannot
//      remove dies `<label>: no wake for <rid> and its stash survived - <stash>
//      now blocks every re-delivery of this rid: remove it, then re-send`.
//   7. after the window: the `ingested` ack with the thread `jq -r '.thread //
//      empty'` prints (spawned whether or not an ack hook exists; jq's
//      spelling - `1.0`, a bigint, `false` as "", an object pretty-printed over
//      lines - W6), THEN `remote-order <rid>` on stdout, one write per line:
//      ac-watch.sh reads a killed poll's partial capture, so a line is printed
//      only for an rid whose ack is over.
//
// LIFECYCLE-ACK: an executable config/remote-ack (a DIRECTORY passes that test
// and fails to run - W20) is run at each lifecycle edge of an order -
// `ingested` once per NEWLY stashed rid, `working` from link, `done` from a
// delivered followup, either from `ack` - fire-and-forget: absent is a no-op,
// a failing hook ONE warning, never a change to ingest, dedup, links, replies
// or the printed lines (a skipped ack costs a transport receipt, never an
// order).
// BOUNDED: AC_REMOTE_ACK_TIMEOUT (20) bounds one call, AC_REMOTE_ACK_BUDGET (30)
// the whole process's time inside the hook - each '' or holding a non-digit
// reads as its default. Budget spent (`[ spent -ge budget ]`, decimal) is, once
// per process, `WARN: <label>: remote-ack budget (<budget>s) spent this round -
// skipping remaining acks`, the call skipped. Else the timeout is clamped to
// `$((budget - spent))` - shell arithmetic: a leading 0 reads octal, so `010`
// is 10 in the test and 8 in the clamp, and `08` ends the run, exit 1, before
// the line the ack precedes - after an ingested order's commit, after link's
// meta writes (W18); past 2^63 the test is no number (false) and the
// arithmetic wraps. The hook starts in its OWN process
// group (MECHANICS 4) with AC_REMOTE_RID, AC_REMOTE_THREAD,
// AC_REMOTE_ACK_STATE, stdin and stdout /dev/null, stderr ours; it is polled
// every spawned `sleep 0.2`, and once whole wall-clock seconds since its start
// (the shell's $SECONDS) reach the timeout its GROUP gets TERM, `sleep 0.5`,
// KILL, rc 124. Seconds spent add to the budget. rc 124 - also a hook's own
// exit 124 (W19) - is `WARN: <label>: remote-ack hook timed out after
// <timeout>s for <rid> (<state>)` (<timeout> as written, `02` stays `02`), any
// other non-zero `WARN: <label>: remote-ack hook failed for <rid> (<state>)`.
//
// FAMILY SEND (push-pending and thread-post), the text on <stdin>: with no
// executable config/remote-reply, `cat` drains stdin, and that is a success.
// Else the thread is thread_ts= of state/remote-threads/<family>.thread when
// that is a regular file (one that cannot be read is metaGet's WARN and NO
// thread: a TOP-LEVEL post, exit 0 - W31); the hook gets AC_REMOTE_RID=<family>,
// AC_REMOTE_THREAD, AC_REMOTE_MENTION (captain or set EMPTY, never unset - W32)
// and the text on stdin, its stdout captured to EOF, its stderr ours; a
// non-zero status fails the send. <ts> is the capture's first line (`\n111.1`
// is none). With no thread AND no .thread file a <ts> registers the mapping -
// remote-threads/ minted, thread_ts=<ts> and cursor=<ts> set (META SET) -
// while none is `WARN: family thread: <family> posted top-level but the hook
// printed no ts - thread mapping not recorded`; an existing .thread (even one
// with no thread_ts) is never registered (W31). The send swallows its own
// write failures.
//
// META SET, every key=value file this writes: the lines `grep -v "^<key>="`
// keeps - a BRE whose `.` is any one character (a byte under C, a valid UTF-8
// sequence under a UTF-8 locale, never an invalid byte) and whose other key
// bytes are themselves - in order, an unterminated tail terminated, then
// `<key>=<value>\n` when setting (none when unsetting; unsetting an absent file
// is a no-op). Through a sibling temp `<file>.tmp.<pid>` created exclusively
// and a spawned `mv` over the file (a symlinked meta becomes a regular file);
// an mv that fails ends the run with its status, any other failure is `cannot
// rewrite <file>: <errno>`, exit 1. Setting runs under ac_meta_set's lock
// <dir>/.<file>.lock (metaLocked, src/lib.ts: 10 PATH `sleep 1` waits), so it
// excludes every bash and TypeScript writer of that file; a lock it cannot
// take is `WARN: cannot lock meta file <file> - nothing written` and exit 1
// (inside the family send, the next key). Unsetting takes no lock, as the
// original's meta_unset took none.
//
// HOOKS (config/, executable, transport-owned), each started as bash started
// `"$hook"`: `/bin/sh -c 'if (set +o posix) 2>/dev/null; then set +o posix;
// fi; exec "$0"' <hook>` (`set -m` beside the posix change for the ack). sh reads no startup file, so $BASH_ENV reaches the
// hook and never the launcher; dropping the posix flag hands an exported
// SHELLOPTS on unchanged; the hook replaces the sh and keeps its pid. A hook
// whose #! interpreter cannot start runs without the `exec` (a forked attempt:
// the shell's 126, as for a directory); a shebang-less hook runs as a shell
// script. Identifiers ride the environment,
// text rides stdin, never argv:
//   remote-poll  - no args, no added env, stdin /dev/null (a hook that reads
//                  it gets EOF, never the caller's bytes), stdout captured to
//                  EOF, stderr to the poll's temp file, IN this process's group
//                  (the watcher reaps a hung poll by its group, hook and
//                  children with it); prints zero or more JSON lines
//                  {rid,text,author,thread,...}
//   remote-reply - from reply: env AC_REMOTE_RID, AC_REMOTE_THREAD; stdin the
//                  text; stdout and stderr ours. From FAMILY SEND: env
//                  AC_REMOTE_RID=<family>, AC_REMOTE_THREAD (empty = post
//                  top-level), AC_REMOTE_MENTION; stdin the text; stdout
//                  captured to EOF - its first line the new thread's ts (the
//                  new-thread contract); stderr ours
//   remote-ack   - env AC_REMOTE_RID, AC_REMOTE_THREAD, AC_REMOTE_ACK_STATE;
//                  stdin/stdout /dev/null (a write succeeds and is discarded);
//                  stderr ours; its OWN process group; bounded as above
//
// MECHANICS, the four places a naive port reads differently, each pinned by a
// leg row (tests/sh/ac-remote.test.sh) and a unit test (tests/ts/remote.test.ts):
//   1. A capture reads its pipe to EOF, as `$(...)` did - never only to the
//      child's exit: a hook that exits while a child it forked keeps stdout
//      open holds the poll and the family send until that child lets go
//      (ac-watch.sh's ceiling then reaps the group: its `remote-timeout:`).
//   2. Bun resets SIGINT to the default in every child it starts, where a
//      shell's `trap '' INT` was inherited: inside the commit window this
//      process ignores INT (a listener held one loop turn past the window,
//      since Bun delivers signals on the loop) and every spawn starts through
//      `/bin/sh -c 'trap "" INT; exec "$0" "$@"'` (childrenIgnoreInt,
//      src/lib.ts); outside it an INT ends the run at once.
//   3. A hook's added names reach it through the spawn helpers' env(1) prefix,
//      set on process.env for that one spawn and restored, never an env object
//      (Bun would re-encode every value as UTF-8); a TZ goes as an env(1)
//      argument (Bun keeps a TZ written to process.env out of the names it
//      enumerates). The hook itself is launched by /bin/sh, never bash: a
//      non-interactive bash sources an inherited $BASH_ENV before the hook
//      and its output would land in the capture, where the original's
//      `"$hook"` ran from a shell that had sourced it once, at its own start.
//      The sh drops its posix flag before the exec, or an exported SHELLOPTS
//      would reach the hook ending in `:posix` and a #!/bin/bash hook would
//      skip its own $BASH_ENV; the ack launcher's `set -m` gives it the
//      `monitor` the original's backgrounding under `set -m` gave it.
//   4. The ack hook starts detached - setsid, so it leads its own group and
//      session where `set -m` gave the original's job a group only (named) -
//      and a TERM to the poll's group (ac-watch.sh's reap) leaves it alive
//      under ppid 1, its rid's stash and wake committed and its `remote-order`
//      line never printed (W21).
//
// FILES, byte-identical with the original's: the stash
// state/remote-inbox/<rid>.json (the raw line + LF, jq's line for an order);
// <rid>.replies.md beside it; the wake record above; state/<id>.meta and
// state/archive/<id>/meta (remote_request=, remote_request_ts=);
// state/remote-threads/<family>.thread (thread_ts=, cursor=);
// state/.landing-receipt-stamp (<family>=<epoch>); state/.remote-push-stamp
// (<family>=<sha256>); state/.ac-root (<root>\n).
//
// SECURITY - remote message text is UNTRUSTED: never evaluated, never on a
// command line, never a file name. Only a guarded rid names a file, and hooks
// get identifiers in env and text on stdin.
//
// DIVERGENCES from the original, each named in the differential leg:
// - the USAGE HEADER is this one; an AC_HOME cd cannot enter is physicalDir's
//   refusal (the original printed cd's line, then tried to write the
//   filesystem root's /.ac-root - W3).
// - shell-own stderr is not reproduced: the redirect failures (the pointer -
//   W2 -, the stash temp - W8 -, an unreadable --text-file - W23, W24), bash's
//   arithmetic and `[` noise (W18), its exec text for a bad interpreter or a
//   directory hook (each side's own shell's - W12, W20) and for a text past
//   ARG_MAX (W17); the exit statuses are kept, and the port names a failed
//   write `cannot write <path>: <errno>`.
// - EXCLUSIVE temps (W36): the original wrote `.stash.<rid>.<$$>` and
//   `<meta>.tmp.<$$>` THROUGH a planted symlink; here each is created
//   exclusively and a meta's mode is kept. A meta set over a file it cannot
//   read is a refusal here (swallowed inside the family send) where the
//   original's grep failed and its mv left
//   the file holding the one new line, exit 0; a NUL byte in one is kept where
//   the original's grep printed `Binary file ... matches` into it.
// - argv arrives decoded: a byte that is not UTF-8 in an argv text reaches jq
//   as one U+FFFD per byte where the original's jq made one per sequence
//   (`\xed\xa0\x80` is three here); a rid or family with a non-ASCII letter is
//   refused under every locale, where bash 3.2's range let one through under
//   UTF-8; a .thread value that is not UTF-8 cannot cross into a hook's env.
// - families and rooms are walked in BYTE order (ORDER rule); the leg runs the
//   original under LC_ALL=C.
// - the ack hook's own group is a session too (setsid); nothing observable to
//   a hook that does not ask. A shebang-less hook runs under /bin/sh (bash in
//   POSIX mode on macOS) where the original's bash ran it in its own mode.
//
// CALLERS, all fail soft (a bun-less PATH makes the shim print `ERROR:
// required tool not found: bun`, exit 1): bin/ac-watch.sh's remote slot runs
// `poll` backgrounded under `set -m`, reads its status and queues ONE
// `remote-failed` wake carrying that last stderr line; bin/ac-wake-drain.sh
// runs `push-pending || true`; bin/ac-room.sh's mirror runs `thread-post
// [--mention-captain] >/dev/null 2>&1 || ac_warn ...`; bin/ac-spawn.sh's two
// announces run `thread-post ... >/dev/null 2>&1 || true`. No caller runs it
// bare under errexit; the solo session's `order` and the chief's
// show/reply/link/ack/followup/done-stamp are by hand. Without bun, poll no
// longer self-heals state/.ac-root (the Slack hooks' only way back to
// bin/ac-lib.sh) - nothing else depends on the entry's process.
import { accessSync, chmodSync, closeSync, constants, existsSync, linkSync, openSync, readdirSync, readFileSync, readSync, statSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { createHash } from "node:crypto";
import {
  NO_HOME,
  awkNumber,
  childrenIgnoreInt,
  die,
  enterCaller,
  iso,
  launchable,
  metaGet,
  metaLocked,
  nowRaw,
  physicalDir,
  require,
  roomPendingLines,
  shellStatus,
  spawnShell,
  spawnShellSync,
  vnTs,
  wakePublish,
  warn,
  watcherPid,
} from "./lib.ts";

let callerCwd = "";
let atCaller = true;
// A caller cwd bun could not enter leaves this process in the distro root; a
// relative --text-file is still the caller's.
const at = (p: string): string => (!atCaller && callerCwd !== "" && !p.startsWith("/") ? `${callerCwd}/${p}` : p);

// Bytes travel as latin1 strings; argv and paths are UTF-8 strings.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const L = (s: string): Buffer => Buffer.from(s, "latin1");
const captured = (b: Buffer): string => b.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const dieB = (s: string): never => die(L(s));
const warnB = (s: string): void => warn(L(s));

function say(fd: number, s: string): void {
  const buf = L(s);
  for (let off = 0; off < buf.length; ) off += writeSync(fd, buf, off);
}

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// `[ -x ]`: a directory passes.
function isExec(p: string): boolean {
  try {
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function utf8Locale(): boolean {
  return /utf-?8/i.test(process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "");
}

// One character of `bytes` at `i` as bash 3.2 counts under a UTF-8 locale: a
// valid sequence is one, any byte that starts none is one on its own.
function charLen(bytes: Buffer, i: number): number {
  const c = bytes[i]!;
  if (c < 0x80) return 1;
  const n = c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
  if (n === 0 || i + n > bytes.length) return 1;
  for (let k = 1; k < n; k++) if ((bytes[i + k]! & 0xc0) !== 0x80) return 1;
  let cp = c & (0xff >> (n + 1));
  for (let k = 1; k < n; k++) cp = (cp << 6) | (bytes[i + k]! & 0x3f);
  if (cp < [0, 0, 0x80, 0x800, 0x10000][n]! || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff) return 1;
  return n;
}

// quote_offender: the first line, cut to 60 characters (bytes under C) and
// marked `...` when it was cut or more lines followed.
export function quoteOffender(text: string): string {
  const nl = text.indexOf("\n");
  const first = nl === -1 ? text : text.slice(0, nl);
  const bytes = L(first);
  let end = bytes.length;
  let count = bytes.length;
  if (utf8Locale()) {
    count = 0;
    end = -1;
    for (let i = 0; i < bytes.length; i += charLen(bytes, i)) {
      if (count === 60) end = i;
      count++;
    }
    if (end === -1) end = bytes.length;
  } else end = Math.min(60, bytes.length);
  if (first === text && count <= 60) return first;
  return `${bytes.subarray(0, end).toString("latin1")}...`;
}

const RID = /^[A-Za-z0-9._-]+$/;
const ridOk = (s: string): boolean => RID.test(s) && /[^.]/.test(s);
// The guards take bytes: an argv value goes through b8 first.
const ridGuard = (s: string): void => {
  if (!ridOk(s)) dieB(`rid must be [A-Za-z0-9._-]+: '${s}'`);
};
const taskGuard = (s: string): void => {
  if (!RID.test(s)) dieB(`task id must be [A-Za-z0-9._-]+: '${s}'`);
};

// The home was bound once, as every `$(ac_*_dir)` re-bound it to the same
// physical path; each subdir is minted by mkdir(1) when absent, whose failure
// the substitution swallowed after its own line.
let home = "";
function homeDir(name: string): string {
  const dir = `${home}/${name}`;
  if (!isDir(dir)) {
    try {
      spawnShellSync(["mkdir", "-p", dir], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
    } catch {}
  }
  return dir;
}

function exitWith(r: { exitCode: number | null; signalCode?: string | null } | null): void {
  const s = shellStatus(r);
  if (s !== 0) process.exit(s);
}

// A hook starts as `"$hook"` started it from the original's bash, which had
// read $BASH_ENV once at its own start and exported its SHELLOPTS to the
// hook: through /bin/sh, which reads no startup file, its posix flag dropped
// again so an exported SHELLOPTS reaches the hook as it came (the ack's,
// launched under `set -m`, with `monitor` as the original's had). Both option
// changes are bash's alone - SHELLOPTS is bash's, dash refuses `-o posix` and
// warns of a missing tty on `set -m` - so they run only when the shell takes
// `set +o posix`, tried first in a subshell: a refused special builtin ends
// only that subshell, and no exported variable can claim a shell is bash.
// The hook
// replaces the sh and keeps its pid - the ack's group leader - unless its #!
// interpreter cannot start: a forked attempt then gives the shell's 126, where
// a failed exec under an inherited errexit ends bash 3.2 with 1. A hook path
// holding `=` is never read as one more assignment by the spawn helpers'
// env(1) prefix.
export const hookArgv = (hook: string, monitor = false): string[] => [
  "/bin/sh",
  "-c",
  `if (set +o posix) 2>/dev/null; then set +o posix${monitor ? "; set -m" : ""}; fi; ${launchable(hook, undefined) ? "exec " : ""}"$0"`,
  hook,
];

// `NAME=value "$hook"`: the names reach that one child, and this process's
// environment is as it was once the child has started.
function withEnv<T>(vars: Record<string, string>, fn: () => T): T {
  const saved = Object.keys(vars).map((k) => [k, process.env[k]] as const);
  for (const [k, v] of Object.entries(vars)) process.env[k] = v;
  try {
    return fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

type Stdio = "inherit" | "ignore" | "pipe" | number | Buffer;

function run(argv: string[], stdin: Stdio, stdout: Stdio, stderr: Stdio): ReturnType<typeof Bun.spawnSync> | null {
  try {
    return spawnShellSync(argv, { stdin: stdin as "inherit", stdout: stdout as "pipe", stderr: stderr as "inherit" });
  } catch {
    return null;
  }
}

// `$(child)` reads the pipe to EOF, never only to the child's exit: a child it
// forked that still holds stdout holds the capture, as it held the shell's.
async function capture(argv: string[], stdin: Stdio, stderr: Stdio): Promise<{ status: number; out: string }> {
  let child: ReturnType<typeof Bun.spawn>;
  try {
    child = spawnShell(argv, { stdin: stdin as "inherit", stdout: "pipe", stderr: stderr as "inherit" });
  } catch {
    return { status: 127, out: "" };
  }
  const out = Buffer.from(await new Response(child.stdout as ReadableStream<Uint8Array>).arrayBuffer());
  await child.exited;
  return { status: shellStatus(child), out: captured(out) };
}

const sleep = async (secs: string): Promise<void> => {
  try {
    await spawnShell(["sleep", secs], { stdin: "inherit", stdout: "ignore", stderr: "ignore" }).exited;
  } catch {}
};

function rmF(p: string): number {
  try {
    unlinkSync(p);
    return 0;
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") return 0;
  }
  // rm(1)'s own line and status, as the shell's `rm -f` gave them.
  return shellStatus(run(["rm", "-f", p], "inherit", "inherit", "inherit"));
}

// `grep -v "^<key>="` as the shell ran it, a BRE whose `.` is any one
// character - one byte under C, one valid UTF-8 character under a UTF-8 locale
// (never a byte that starts none) - and whose other key bytes, from the
// [A-Za-z0-9._-] alphabet, are themselves.
export function keyOpens(line: Buffer, key: string, utf8: boolean): boolean {
  let i = 0;
  for (const ch of key) {
    if (i >= line.length) return false;
    if (ch === ".") {
      if (!utf8) i++;
      else {
        const n = charLen(line, i);
        if (n === 1 && line[i]! >= 0x80) return false;
        i += n;
      }
    } else if (line[i] === ch.charCodeAt(0)) i++;
    else return false;
  }
  return line[i] === 0x3d;
}

// ac_meta_set (add = the value) and meta_unset (add = null) over one file:
// every line the key opens dropped, every other kept byte for byte in order,
// an unterminated tail newline-terminated, `<key>=<value>\n` appended. The
// rewrite goes through a sibling temp that a spawned `mv` renames over the file
// as the bash did; a failing mv throws EMV with its status, its own line
// already written. Named divergences, as lib's metaSet: the temp is created
// exclusively, the mode is kept, NUL bytes are kept, an unreadable file
// throws.
function metaRewrite(file: string, key: string, add: string | null): void {
  let data: Buffer | null = null;
  let mode: number | null = null;
  try {
    const st = statSync(file);
    if (st.isFile()) {
      mode = st.mode & 0o7777;
      data = readFileSync(file);
    }
  } catch (e) {
    if ((e as { code?: string }).code !== "ENOENT") throw e;
  }
  if (data === null && add === null) return;
  const utf8 = utf8Locale();
  const parts: Buffer[] = [];
  if (data !== null) {
    for (let start = 0; start < data.length; ) {
      const nl = data.indexOf(10, start);
      const end = nl === -1 ? data.length : nl;
      const line = data.subarray(start, end);
      if (!keyOpens(line, key, utf8)) parts.push(line, Buffer.from("\n"));
      start = end + 1;
    }
  }
  if (add !== null) parts.push(L(`${key}=${add}\n`));
  let tmp = `${file}.tmp.${process.pid}`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, Buffer.concat(parts), { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      tmp = `${file}.tmp.${process.pid}.${i}`;
    }
  }
  if (mode !== null) chmodSync(tmp, mode);
  const status = shellStatus(run(["mv", tmp, file], "inherit", "inherit", "inherit"));
  if (status !== 0) throw Object.assign(new Error(`mv ${tmp} ${file} failed`), { code: "EMV", status });
}

// ac_meta_set's lock around the rewrite; meta_unset never took one.
function metaWrite(file: string, key: string, add: string | null): void {
  if (add === null) metaRewrite(file, key, null);
  else metaLocked(file, () => metaRewrite(file, key, add));
}

// A bare `ac_meta_set` / meta_unset: errexit ended the run where it failed.
function metaRewriteOrExit(file: string, key: string, add: string | null): void {
  try {
    metaWrite(file, key, add);
  } catch (e) {
    const err = e as { code?: string; status?: number };
    if (err.code === "EMV" || err.code === "ELOCK") process.exit(err.status ?? 1);
    dieB(`cannot rewrite ${b8(file)}: ${err.code ?? "error"}`);
  }
}

// ac_meta_get, `$(...)`-read: the value cut at its first NUL as awk's C string
// was; an unreadable file is metaGet's WARN and a throw.
const metaValue = (file: string, key: string): string => metaGet(file, key).replace(/\0[\s\S]*$/, "");

// ac_meta_get over a family-keyed stamp: awk's `$1==k` compares as numbers
// when both sides look like one (`07` reads the `7=` line, `nan` every line),
// and the value is the line past `length(k)+1` bytes, whichever line matched.
export function metaValueAwk(file: string, key: string): string {
  if (!isFile(file)) return "";
  let text: string;
  try {
    text = readFileSync(file, "latin1");
  } catch (e) {
    if (!existsSync(file)) return "";
    warnB(`cannot read meta file ${b8(file)}`);
    throw e;
  }
  const kn = awkNumber(key);
  let v = "";
  for (const raw of text.split("\n")) {
    const line = raw.split("\0", 1)[0]!;
    const eq = line.indexOf("=");
    const f1 = eq === -1 ? line : line.slice(0, eq);
    const fn = kn === null ? null : awkNumber(f1);
    const hit = fn !== null && kn !== null ? !(fn < kn) && !(fn > kn) : f1 === key;
    if (hit) v = line.slice(key.length + 1);
  }
  return v;
}

// --- LIFECYCLE-ACK ----------------------------------------------------------

let ackSpent = 0n;
let ackWarned = false;

// `[ a -ge b ]` / `-le`: decimal, leading zeros fine; a number past 64 bits is
// the builtin's error, the test false.
export function testInt(s: string): bigint | null {
  if (!/^-?[0-9]+$/.test(s)) return null;
  const v = BigInt(s);
  return v > 0x7fffffffffffffffn || v < -0x8000000000000000n ? null : v;
}

// `$(( ))` over a digit string: a leading 0 reads octal, where 8 or 9 is the
// shell's fatal `value too great for base`; past 64 bits it wraps.
export function arithConst(s: string): bigint | null {
  if (s.length > 1 && s.startsWith("0")) return /[89]/.test(s) ? null : BigInt.asIntN(64, BigInt(`0o${s}`));
  return BigInt.asIntN(64, BigInt(s));
}

async function runAck(label: string, rid: string, state: string, thread: string): Promise<void> {
  const ack = `${homeDir("config")}/remote-ack`;
  if (!isExec(ack)) return;
  let budget = process.env.AC_REMOTE_ACK_BUDGET || "30";
  if (!/^[0-9]+$/.test(budget)) budget = "30";
  const b = testInt(budget);
  if (b !== null && ackSpent >= b) {
    if (!ackWarned) {
      warn(`${label}: remote-ack budget (${budget}s) spent this round - skipping remaining acks`);
      ackWarned = true;
    }
    return;
  }
  let timeout = process.env.AC_REMOTE_ACK_TIMEOUT || "20";
  if (!/^[0-9]+$/.test(timeout)) timeout = "20";
  const bc = arithConst(budget);
  if (bc === null) process.exit(1);
  const remaining = BigInt.asIntN(64, bc - ackSpent);
  const t = testInt(timeout);
  if (t === null || t > remaining) timeout = String(remaining);
  let child: ReturnType<typeof Bun.spawn> | null = null;
  try {
    child = withEnv({ AC_REMOTE_RID: rid, AC_REMOTE_THREAD: u8(thread), AC_REMOTE_ACK_STATE: state }, () =>
      spawnShell(hookArgv(ack, true), { detached: true, stdin: "ignore", stdout: "ignore", stderr: "inherit" }),
    );
  } catch {}
  const start = Math.floor(Date.now() / 1000);
  let rc = 127;
  if (child !== null) {
    let status: number | null = null;
    const proc = child;
    const ended = proc.exited.then(() => {
      status = shellStatus(proc);
    });
    const limit = BigInt(timeout);
    const group = (sig: "SIGTERM" | "SIGKILL"): void => {
      try {
        process.kill(-proc.pid, sig);
      } catch {}
    };
    for (;;) {
      if (status !== null) {
        rc = status;
        break;
      }
      if (BigInt(Math.floor(Date.now() / 1000) - start) >= limit) {
        group("SIGTERM");
        await sleep("0.5");
        group("SIGKILL");
        await ended;
        rc = 124;
        break;
      }
      await sleep("0.2");
    }
  }
  ackSpent = BigInt.asIntN(64, ackSpent + BigInt(Math.floor(Date.now() / 1000) - start));
  if (rc === 124) warnB(`${label}: remote-ack hook timed out after ${timeout}s for ${rid} (${state})`);
  else if (rc !== 0) warnB(`${label}: remote-ack hook failed for ${rid} (${state})`);
}

// `$(jq -r '.thread // empty' <stash> [2>/dev/null])`.
function stashThread(stash: string, stderr: "inherit" | "ignore"): string {
  const r = run(["jq", "-r", ".thread // empty", stash], "inherit", "pipe", stderr);
  return r === null ? "" : captured(r.stdout);
}

// --- the ingest core ----------------------------------------------------------

const VALIDATE = 'type=="object" and (.rid|type)=="string"\n                and has("text") and has("author") and has("thread")';

let stateDir = "";
const inbox = (): string => `${stateDir}/remote-inbox`;
const noop = (): void => {};

async function ingestLine(label: string, line: string): Promise<void> {
  const input = L(`${line}\n`);
  if (shellStatus(run(["jq", "-e", VALIDATE], input, "ignore", "ignore")) !== 0) {
    warn(`${label}: skipped a malformed line (need JSON {rid,text,author,thread})`);
    return;
  }
  const r = run(["jq", "-r", ".rid"], input, "pipe", "inherit");
  exitWith(r);
  const rid = captured(r!.stdout);
  if (!ridOk(rid)) {
    warnB(`${label}: refused rid (must be [A-Za-z0-9._-]+): ${rid}`);
    return;
  }
  const stash = `${inbox()}/${rid}.json`;
  if (existsSync(stash)) return;
  let tmp = `${inbox()}/.stash.${rid}.${process.pid}`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, input, { flag: "wx" });
      break;
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code !== "EEXIST") dieB(`cannot write ${b8(tmp)}: ${code ?? "error"}`);
      tmp = `${inbox()}/.stash.${rid}.${process.pid}.${i}`;
    }
  }
  // UNINTERRUPTIBLE from the stash link to the wake's link: the stash is also
  // the dedup sign, so an INT between the two commits would burn the rid.
  process.on("SIGINT", noop);
  childrenIgnoreInt(true);
  let linked = true;
  try {
    linkSync(tmp, stash);
  } catch {
    linked = false;
  }
  try {
    unlinkSync(tmp);
  } catch {}
  if (linked && !wakePublish(stateDir, "", "remote", "captain", `remote-order ${rid}`)) {
    if (rmF(stash) !== 0) dieB(`${label}: no wake for ${rid} and its stash survived - ${b8(stash)} now blocks every re-delivery of this rid: remove it, then re-send`);
    dieB(`${label}: no wake could be published for ${rid} - NOT ingested. Re-send it AND anything after it in the same batch: this exits before reading the rest`);
  }
  childrenIgnoreInt(false);
  // A SIGINT that landed inside the window is delivered on the loop, so the
  // listener stays until the loop has turned once.
  await new Promise((r) => setTimeout(r, 0));
  process.off("SIGINT", noop);
  if (!linked) return;
  const t = run(["jq", "-r", ".thread // empty"], input, "pipe", "inherit");
  await runAck(label, rid, "ingested", t === null ? "" : captured(t.stdout));
  say(1, `remote-order ${rid}\n`);
}

async function ingestStream(label: string, next: () => string | null): Promise<void> {
  if (!isDir(inbox())) exitWith(run(["mkdir", "-p", inbox()], "inherit", "inherit", "inherit"));
  for (let line = next(); line !== null; line = next()) {
    if (line !== "") await ingestLine(label, line);
  }
}

// `while IFS= read -r line || [ -n "$line" ]` over a byte string: LF-split, a
// line cut at its first NUL, an unterminated last line read.
function linesOf(text: string): () => string | null {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  let i = 0;
  return () => (i < lines.length ? lines[i++]!.split("\0", 1)[0]! : null);
}

// The same read over fd 0, one line at a time as it arrives - a push gateway
// may hold its pipe open between orders.
function stdinLines(): () => string | null {
  let buf = Buffer.alloc(0);
  let eof = false;
  const chunk = Buffer.alloc(65536);
  return () => {
    for (;;) {
      const lf = buf.indexOf(10);
      if (lf !== -1) {
        const line = buf.subarray(0, lf).toString("latin1");
        buf = buf.subarray(lf + 1);
        return line.split("\0", 1)[0]!;
      }
      if (eof) {
        if (buf.length === 0) return null;
        const line = buf.toString("latin1");
        buf = Buffer.alloc(0);
        return line.split("\0", 1)[0]!;
      }
      let n = 0;
      try {
        n = readSync(0, chunk, 0, chunk.length, null);
      } catch (e) {
        if ((e as { code?: string }).code === "EAGAIN") {
          Bun.sleepSync(10);
          continue;
        }
        n = 0;
      }
      if (n === 0) eof = true;
      else buf = Buffer.concat([buf, chunk.subarray(0, n)]);
    }
  };
}

// --- verbs ------------------------------------------------------------------------

async function poll(): Promise<void> {
  const hook = `${homeDir("config")}/remote-poll`;
  if (!isFile(hook) || !isExec(hook)) process.exit(0);
  const mk = run(["mktemp", `${process.env.TMPDIR || "/tmp"}/ac-remote-poll-err.XXXXXX`], "inherit", "pipe", "inherit");
  exitWith(mk);
  const errfile = u8(captured(mk!.stdout));
  let fd: number;
  try {
    fd = openSync(errfile, "w");
  } catch (e) {
    dieB(`cannot write ${b8(errfile)}: ${(e as { code?: string }).code ?? "error"}`);
  }
  const r = await capture(hookArgv(hook), "ignore", fd);
  closeSync(fd);
  let err = Buffer.alloc(0);
  try {
    err = readFileSync(errfile);
  } catch {}
  rmF(errfile);
  if (r.status !== 0) {
    const text = captured(err);
    if (text !== "") warnB(`remote-poll hook failed (exit ${r.status}): ${quoteOffender(text)} - skipping this poll`);
    else warn(`remote-poll hook failed (exit ${r.status}) - skipping this poll`);
    process.exit(0);
  }
  for (let off = 0; off < err.length; ) off += writeSync(2, err, off);
  await ingestStream("remote-poll", linesOf(`${r.out}\n`));
}

const ORDER_JQ = 't=$(cat; printf x); exec jq -cn --arg rid "$1" --arg text "${t%x}" \'{rid: $rid, text: $text, author: "captain", thread: "local"}\'';

async function order(argv: string[]): Promise<void> {
  let textfile = "";
  let text = "";
  for (let i = 0; i < argv.length; ) {
    if (argv[i] === "--text-file") {
      const v = argv[i + 1] ?? "";
      if (v === "") die("--text-file needs a path");
      textfile = v;
      i += 2;
    } else text = b8(argv[i++]!);
  }
  if (textfile !== "") {
    if (!isFile(at(textfile))) die(`text file not found: ${textfile}`);
    const c = run(["cat", at(textfile)], "inherit", "pipe", "inherit");
    exitWith(c);
    text = captured(c!.stdout);
  }
  const tr = run(["tr", "-d", "[:space:]"], L(text), "pipe", "inherit");
  if (tr === null || captured(tr.stdout) === "") die("order needs its text: ac-remote.sh order [--text-file <f>] ['<text>']");
  const date = run(["date", "-u", "+%Y%m%dT%H%M%SZ"], "inherit", "pipe", "inherit");
  exitWith(date);
  const rid = `local-${captured(date!.stdout)}-${process.pid}`;
  // The text goes to jq as the bytes the shell handed it, through a shell:
  // argv from here is UTF-8, and jq decodes a byte that is not by its own rules.
  const jq = run(["/bin/sh", "-c", ORDER_JQ, "sh", u8(rid)], L(text), "pipe", "inherit");
  await ingestStream("order", linesOf(jq === null ? "" : jq.stdout.toString("latin1")));
  exitWith(jq);
  if (watcherPid(stateDir, "") === null) {
    say(1, `no live fleet watcher right now - ${rid} waits in the spool until a chief session drains it (bin/ac-wake-drain.sh, or the next session-start)\n`);
  }
}

function show(argv: string[]): void {
  const rid = argv[0] ?? "";
  if (rid === "") die("usage: ac-remote.sh show <rid>");
  ridGuard(b8(rid));
  const stash = `${inbox()}/${rid}.json`;
  if (!isFile(stash)) die(`no stashed remote order: ${rid}`);
  exitWith(run(["cat", stash], "inherit", "inherit", "inherit"));
}

function textFileOpt(argv: string[], verb: string, flags: string[] = []): { textfile: string; seen: Set<string> } {
  let textfile = "";
  const seen = new Set<string>();
  for (let i = 0; i < argv.length; ) {
    const a = argv[i]!;
    if (a === "--text-file") {
      const v = argv[i + 1] ?? "";
      if (v === "") die("--text-file needs a path");
      textfile = v;
      i += 2;
    } else if (flags.includes(a)) {
      seen.add(a);
      i++;
    } else dieB(`unknown ${verb} option: ${quoteOffender(b8(a))}`);
  }
  return { textfile, seen };
}

function reply(argv: string[], out: "inherit" | "ignore"): void {
  const rid = argv[0] ?? "";
  if (rid === "") die("usage: ac-remote.sh reply <rid> [--text-file <f>]");
  const { textfile } = textFileOpt(argv.slice(1), "reply");
  ridGuard(b8(rid));
  const stash = `${inbox()}/${rid}.json`;
  if (!isFile(stash)) die(`no stashed remote order: ${rid}`);
  const j = run(["jq", "-r", ".thread // empty", stash], "inherit", "pipe", "inherit");
  exitWith(j);
  const thread = captured(j!.stdout);
  const tell = (s: string): void => {
    if (out === "inherit") say(1, s);
  };
  if (thread === "local") {
    const replies = `${inbox()}/${rid}.replies.md`;
    if (textfile !== "" && !isFile(at(textfile))) die(`text file not found: ${textfile}`);
    let fd: number;
    try {
      fd = openSync(replies, "a");
    } catch (e) {
      dieB(`cannot write ${b8(replies)}: ${(e as { code?: string }).code ?? "error"}`);
    }
    say(fd, `## ${iso()}\n`);
    exitWith(run(textfile !== "" ? ["cat", at(textfile)] : ["cat"], "inherit", fd, "inherit"));
    say(fd, "\n");
    closeSync(fd);
    tell(`replied ${rid} (local thread: ${b8(replies)})\n`);
    return;
  }
  const hook = `${homeDir("config")}/remote-reply`;
  if (!isFile(hook)) die("reply needs a config/remote-reply hook (transport not configured)");
  if (!isExec(hook)) die("config/remote-reply is not executable (chmod +x it)");
  const failed = (): never => die(`remote-reply hook failed for ${rid} (reply NOT delivered)`);
  let stdin: "inherit" | number = "inherit";
  if (textfile !== "") {
    if (!isFile(at(textfile))) die(`text file not found: ${textfile}`);
    try {
      stdin = openSync(at(textfile), "r");
    } catch {
      failed();
    }
  }
  const r = withEnv({ AC_REMOTE_RID: rid, AC_REMOTE_THREAD: u8(thread) }, () => run(hookArgv(hook), stdin, out, "inherit"));
  if (typeof stdin === "number") closeSync(stdin);
  if (shellStatus(r) !== 0) failed();
  tell(`replied ${rid}\n`);
}

async function link(argv: string[]): Promise<void> {
  const task = argv[0] ?? "";
  const rid = argv[1] ?? "";
  if (task === "" || rid === "") die("usage: ac-remote.sh link <task-id> <rid>");
  taskGuard(b8(task));
  ridGuard(b8(rid));
  const stash = `${inbox()}/${rid}.json`;
  if (!isFile(stash)) die(`no stashed remote order: ${rid} (poll first)`);
  const meta = `${homeDir("state")}/${task}.meta`;
  metaRewriteOrExit(meta, "remote_request", rid);
  metaRewriteOrExit(meta, "remote_request_ts", nowRaw());
  await runAck("link", rid, "working", stashThread(stash, "ignore"));
  say(1, `linked ${task} -> ${rid}\n`);
}

async function ack(argv: string[]): Promise<void> {
  const rid = argv[0] ?? "";
  const state = argv[1] ?? "";
  if (rid === "" || state === "") die("usage: ac-remote.sh ack <rid> <working|done>");
  ridGuard(b8(rid));
  if (state !== "working" && state !== "done") die(`ack state must be working|done: ${state}`);
  const stash = `${inbox()}/${rid}.json`;
  if (!isFile(stash)) die(`no stashed remote order: ${rid}`);
  await runAck("ack", rid, state, stashThread(stash, "ignore"));
  say(1, `acked ${rid} (${state})\n`);
}

async function followup(argv: string[]): Promise<void> {
  const task = argv[0] ?? "";
  if (task === "") die("usage: ac-remote.sh followup <task-id> [--text-file <f>]");
  const { textfile } = textFileOpt(argv.slice(1), "followup");
  taskGuard(b8(task));
  let meta = `${homeDir("state")}/${task}.meta`;
  let rid = "";
  try {
    if (isFile(meta)) rid = metaValue(meta, "remote_request");
    const archived = `${stateDir}/archive/${task}/meta`;
    if (rid === "" && isFile(archived)) {
      meta = archived;
      rid = metaValue(meta, "remote_request");
    }
  } catch {
    process.exit(1);
  }
  if (rid === "") {
    warn(`no remote order linked to ${task} (already followed up, or never linked) - nothing sent`);
    process.exit(0);
  }
  ridGuard(rid);
  reply(textfile !== "" ? [rid, "--text-file", textfile] : [rid], "ignore");
  metaRewriteOrExit(meta, "remote_request", null);
  metaRewriteOrExit(meta, "remote_request_ts", null);
  await runAck("followup", rid, "done", stashThread(`${inbox()}/${rid}.json`, "ignore"));
  say(1, `followed up ${task} -> ${rid} (link cleared)\n`);
}

// family_send: the text on <stdin> into the family's thread; false when the
// hook failed (the text did NOT go out), else the first line the hook printed.
async function familySend(family: string, mention: string, stdin: "inherit" | number | Buffer): Promise<{ ok: boolean; ts: string }> {
  const hook = `${homeDir("config")}/remote-reply`;
  if (!isFile(hook) || !isExec(hook)) {
    run(["cat"], stdin, "ignore", "inherit");
    return { ok: true, ts: "" };
  }
  const tdir = `${stateDir}/remote-threads`;
  const tfile = `${tdir}/${family}.thread`;
  let thread = "";
  try {
    if (isFile(tfile)) thread = metaValue(tfile, "thread_ts");
  } catch {}
  const r = await withEnv({ AC_REMOTE_RID: family, AC_REMOTE_THREAD: u8(thread), AC_REMOTE_MENTION: mention }, () => capture(hookArgv(hook), stdin, "inherit"));
  if (r.status !== 0) return { ok: false, ts: "" };
  const ts = r.out.split("\n", 1)[0]!;
  if (thread === "" && !existsSync(tfile)) {
    if (ts !== "") {
      if (!isDir(tdir)) run(["mkdir", "-p", tdir], "inherit", "inherit", "inherit");
      for (const key of ["thread_ts", "cursor"]) {
        try {
          metaWrite(tfile, key, ts);
        } catch {}
      }
    } else warn(`family thread: ${family} posted top-level but the hook printed no ts - thread mapping not recorded`);
  }
  return { ok: true, ts };
}

async function threadPost(argv: string[]): Promise<void> {
  const family = argv[0] ?? "";
  if (family === "") die("usage: ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]");
  const { textfile, seen } = textFileOpt(argv.slice(1), "thread-post", ["--mention-captain"]);
  const mention = seen.has("--mention-captain") ? "captain" : "";
  ridGuard(b8(family));
  const hook = `${homeDir("config")}/remote-reply`;
  const failed = (): never => die(`thread-post: remote-reply hook failed for ${family} - text NOT delivered`);
  let sent: { ok: boolean; ts: string };
  if (textfile !== "") {
    if (!isFile(at(textfile))) die(`thread-post: no such file: ${textfile}`);
    let fd = -1;
    try {
      fd = openSync(at(textfile), "r");
    } catch {
      failed();
    }
    sent = await familySend(family, mention, fd);
    closeSync(fd);
  } else sent = await familySend(family, mention, "inherit");
  if (!sent.ok) failed();
  if (!isFile(hook) || !isExec(hook)) warn(`thread-post: no config/remote-reply hook - ${family} NOT delivered (transport not configured)`);
  else if (sent.ts !== "") say(1, `posted ${family} (${sent.ts})\n`);
  else say(1, `posted ${family}\n`);
}

function doneStamp(argv: string[]): void {
  const family = argv[0] ?? "";
  if (family === "") die("usage: ac-remote.sh done-stamp <family>");
  ridGuard(b8(family));
  metaRewriteOrExit(`${stateDir}/.landing-receipt-stamp`, family, nowRaw());
  say(1, `done-stamped ${family}\n`);
}

const byteOrder = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));

async function pushPending(): Promise<void> {
  const hook = `${homeDir("config")}/remote-reply`;
  if (!isFile(hook) || !isExec(hook)) return;
  const stamp = `${stateDir}/.remote-push-stamp`;
  const data = homeDir("data");
  let names: string[] = [];
  try {
    names = readdirSync(data);
  } catch {}
  for (const family of names.filter((n) => !n.startsWith(".")).sort(byteOrder)) {
    const room = `${data}/${family}/room.md`;
    if (!isFile(room)) continue;
    if (!ridOk(family)) {
      warnB(`push-pending: skipped family with unsafe name: ${b8(family)}`);
      continue;
    }
    const lines = roomPendingLines(room);
    if (lines === null || lines === "") continue;
    const count = lines.split("\n").length;
    const hash = createHash("sha256").update(L(lines)).digest("hex");
    let prev: string;
    try {
      prev = metaValueAwk(stamp, family);
    } catch {
      process.exit(1);
    }
    if (hash === prev) continue;
    const vn = vnTs().stamp;
    const sed = run(["sed", "-E", "s/^- \\[[^]]*\\] /• /"], L(`${lines}\n`), "pipe", "inherit");
    const msg = `${b8("⏳")} *[${vn}] [${b8("ĐANG CHỜ")} captain] [${family}]* (${count} ${b8("mục")})\n${sed === null ? "" : captured(sed.stdout)}\n`;
    if (!(await familySend(family, "captain", L(msg))).ok) {
      warn(`push-pending: remote-reply hook failed for ${family} - kept for the next push`);
      continue;
    }
    metaRewriteOrExit(stamp, family, hash);
    say(1, `pushed ${family} (${count} pending)\n`);
  }
}

// basename <path> .json
function stashRid(p: string): string {
  const base = p.replace(/\/+$/, "").replace(/^.*\//, "");
  return base.endsWith(".json") && base !== ".json" ? base.slice(0, -5) : base;
}

function linkedAnywhere(rid: string): boolean {
  const want = `remote_request=${rid}`;
  const metas: string[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(stateDir);
  } catch {}
  for (const n of names) if (!n.startsWith(".") && n.endsWith(".meta")) metas.push(`${stateDir}/${n}`);
  let arch: string[] = [];
  try {
    arch = readdirSync(`${stateDir}/archive`);
  } catch {}
  for (const n of arch) if (!n.startsWith(".")) metas.push(`${stateDir}/archive/${n}/meta`);
  for (const m of metas) {
    if (!isFile(m)) continue;
    let text: string;
    try {
      text = readFileSync(m, "latin1");
    } catch {
      continue;
    }
    if (text.split("\n").includes(want)) return true;
  }
  return false;
}

function gc(argv: string[]): void {
  let days = "14";
  for (let i = 0; i < argv.length; ) {
    if (argv[i] === "--days") {
      const v = argv[i + 1] ?? "";
      if (v === "") die("--days needs a number");
      days = v;
      i += 2;
    } else dieB(`unknown gc option: ${quoteOffender(b8(argv[i]!))}`);
  }
  if (!/^[0-9]+$/.test(days)) dieB(`--days must be a whole number: ${b8(days)}`);
  if (!isDir(inbox())) return;
  const f = run(["find", inbox(), "-type", "f", "-name", "*.json", "-mtime", `+${days}`], "inherit", "pipe", "ignore");
  const next = linesOf(f === null ? "" : f.stdout.toString("latin1"));
  for (let stash = next(); stash !== null; stash = next()) {
    if (stash === "") continue;
    const rid = stashRid(stash);
    if (linkedAnywhere(rid)) continue;
    const s = rmF(u8(stash));
    if (s !== 0) process.exit(s);
    say(1, `pruned ${rid}\n`);
  }
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  say(1, b8(`${head.join("\n")}\n`));
  process.exit(2);
}

async function main(): Promise<never> {
  // ac-bun.sh started this process in the shim's physical root, which is what
  // ac_root answered for the bash; the caller's cwd is entered next.
  const shimRoot = process.cwd();
  callerCwd = process.argv[2] ?? "";
  const entered = enterCaller(process.argv.slice(2));
  atCaller = entered.atCaller;
  // The preamble every verb ran, usage included: the root pointer, jq, the home.
  const homeVar = process.env.AC_HOME ?? "";
  if (homeVar !== "") {
    home = physicalDir(homeVar) ?? die(`AC_HOME is not a readable directory: ${homeVar}`);
    const ptr = `${homeDir("state")}/.ac-root`;
    let cur = "";
    try {
      cur = readFileSync(ptr, "latin1").replace(/\0/g, "").replace(/\n+$/, "");
    } catch {}
    if (cur !== b8(shimRoot)) {
      try {
        writeFileSync(ptr, `${shimRoot}\n`);
      } catch (e) {
        dieB(`cannot write ${b8(ptr)}: ${(e as { code?: string }).code ?? "error"}`);
      }
    }
  }
  require("jq");
  if (homeVar === "") die(NO_HOME);
  stateDir = homeDir("state");

  const [verb = "", ...rest] = entered.args;
  switch (verb) {
    case "poll":
      await poll();
      break;
    case "ingest":
      await ingestStream("ingest", stdinLines());
      break;
    case "order":
      await order(rest);
      break;
    case "show":
      show(rest);
      break;
    case "reply":
      reply(rest, "inherit");
      break;
    case "link":
      await link(rest);
      break;
    case "followup":
      await followup(rest);
      break;
    case "ack":
      await ack(rest);
      break;
    case "thread-post":
      await threadPost(rest);
      break;
    case "done-stamp":
      doneStamp(rest);
      break;
    case "push-pending":
      await pushPending();
      break;
    case "gc":
      gc(rest);
      break;
    default:
      usage();
  }
  process.exit(0);
}

if (import.meta.main) await main();
