#!/usr/bin/env bash
# ac-pipeline-lib.sh - shared helpers for the two pipeline state machines
# (ac-ship.sh + ac-qa.sh). Not an entrypoint; sourced after ac-lib.sh.
#
# Owns: the flat nested-scalar YAML subset reader (ac_yaml_get, its
# block-enumerating sibling ac_yaml_keys, and the presence predicate
# ac_yaml_has) - the single authoritative copy of
# the awk reader both pipelines use for their fleet-home project config. This
# retires the hand-synced byte-locked duplicate that ac-ship.sh and ac-qa.sh
# each carried. WHICH file each tool reads stays in the
# callers (ac-ship reads the installed home config; ac-qa reads its frozen
# per-run <run>/config.yaml snapshot) - only the READER lives here.
#
# Also owns: the findings-wire normalizer + summary (ac_findings_normalize,
# ac_findings_summary) - the fail-closed action/description normalization and
# the action-count summary both pipelines' cmd_findings share.
#
# Also owns: the transcript-final reader (ac_transcript_final) - the last
# assistant message text pulled from a Claude Code session transcript, the
# pane agent's verdict both pipelines read - and ac_verdict_json, which pulls
# the bare JSON verdict object out of that (often prose-wrapped) final message.

ac_yaml_get() {
  # ac_yaml_get <file> <dotted.key> - flat nested-scalar YAML subset reader.
  local file="$1" key="$2"
  awk -v key="$key" '
    function unquote(s) { sub(/^["'\''"]/, "", s); sub(/["'\''"]$/, "", s); return s }
    BEGIN { n = split(key, parts, ".") ; depth = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); ind = int(RLENGTH / 2)
      line = $0; sub(/^ */, "", line)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      k = line; sub(/:.*$/, "", k)
      v = line; sub(/^[^:]*:[[:space:]]*/, "", v)
      if (ind < depth) depth = ind
      if (ind == depth && k == parts[depth + 1]) {
        if (depth + 1 == n) { print unquote(v); exit }
        depth++
      }
    }
  ' "$file"
}

ac_yaml_keys() {
  # ac_yaml_keys <file> <dotted.key> - the IMMEDIATE child key names of a
  # block, one per line, in file order. Empty for a scalar, an absent key, or
  # a block with no children.
  #
  # Why it exists: ac_yaml_get FETCHES one named path and cannot tell a PRESENT
  # block from an ABSENT one - `qa.scopes` returns empty from a file that has
  # the block and from a file that does not. Three callers need that
  # distinction (scoped/flat mode detection, closed-list enforcement over the
  # whole file, and the merge gate), so one reader serves all three.
  #
  # It reuses ac_yaml_get's descent VERBATIM - same indent arithmetic, same
  # line filter - and adds a collect-and-stop phase after the path is found.
  # The two must stay in lockstep; that is why they live beside each other.
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { n = split(key, parts, ".") ; depth = 0 ; found = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); ind = int(RLENGTH / 2)
      line = $0; sub(/^ */, "", line)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      k = line; sub(/:.*$/, "", k)
      if (found) {
        # A sibling or anything shallower ends the block; deeper lines are
        # descendants, not children, and are skipped.
        if (ind < want) exit
        if (ind == want) print k
        next
      }
      if (ind < depth) depth = ind
      if (ind == depth && k == parts[depth + 1]) {
        if (depth + 1 == n) { found = 1; want = ind + 1; next }
        depth++
      }
    }
  ' "$file"
}

ac_redact_publish() {
  # stdin -> stdout: scrub what must never leave the operator's machine from
  # text the fleet PUBLISHES (a PR comment quoting a local error, a body
  # naming a run path). One boundary at the publish call, deliberately not
  # per-source - a per-source scrub has to be complete to work. Home paths
  # (the live $HOME first, then any /Users/<name> and /home/<name>) collapse
  # to ~; a URL's userinfo (user:token@) is masked; everything else passes
  # byte-intact.
  sed -e "s|$HOME|~|g" \
      -e 's|/Users/[A-Za-z0-9._-]\{1,\}|~|g' \
      -e 's|/home/[A-Za-z0-9._-]\{1,\}|~|g' \
      -e 's|://[^/@[:space:]]\{1,\}@|://***@|g'
}

ac_delivery_mode_block() {
  # ac_delivery_mode_block <mode> <crew-branch> <pr-base-phrase>
  #                        <integration-branch> <loop-phrase>
  # The ONE renderer of the per-mode delivery contract: ac-brief.sh scaffolds
  # it into every execution brief and ac-promote.sh hands it to a promoted
  # scout - two contracts, one renderer, so they cannot drift (a promoted
  # worker otherwise gets the mode NAME while a briefed worker gets the
  # never-push and PR rules).
  local mode="$1" branch="$2" base="$3" integ="$4" loop="$5"
  case "$mode" in
    crew-ship)
      printf -- '- Mode crew-ship: run the `crew-ship` skill. Its `ac-ship` engine owns the guarded 8-step delivery pipeline (intent, rebase, review, test, document, lint, push, pr). Hand over only after checks pass and include the PR URL.' ;;
    direct-pr)
      printf -- '- Mode direct-pr: after %s, push `%s` and open a PR against %s. The PR body covers intent, changes, and verification evidence.' "$loop" "$branch" "$base" ;;
    feature-pr)
      printf -- '- Mode feature-pr: after %s, leave `%s` clean and fully committed - it lands onto the feature integration branch `%s` (the chief runs ac-merge-local). Never push or open a PR; publication happens ONCE at the feature ship.' "$loop" "$branch" "$integ" ;;
    local-only)
      printf -- '- Mode local-only: after %s, leave `%s` clean and fully committed. Never push or open a PR.' "$loop" "$branch" ;;
  esac
}

ac_yaml_has() {
  # ac_yaml_has <file> <dotted.key> - is the key PRESENT at all? 0 yes, 1 no.
  #
  # ac_yaml_keys answers with a block's CHILDREN, which cannot distinguish an
  # ABSENT block from a PRESENT-but-EMPTY one - and the empty case is reached by
  # the ordinary authoring order, because `scopes:` lands before the first block
  # under it. Any caller whose question is "does this file declare X" must ask
  # THIS, not "does X have children": treating a half-authored block as absent
  # is how a project falls through to flat and runs the stale profile.
  # Same descent as its two siblings, so all three stay in lockstep.
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { n = split(key, parts, ".") ; depth = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); ind = int(RLENGTH / 2)
      line = $0; sub(/^ */, "", line)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      k = line; sub(/:.*$/, "", k)
      if (ind < depth) depth = ind
      if (ind == depth && k == parts[depth + 1]) {
        if (depth + 1 == n) { found = 1; exit }
        depth++
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

ac_config_sha256() {
  # ac_config_sha256 <file> - stable content identity for a frozen pipeline
  # config or proposal base. All callers pass an existing file, including an
  # intentionally empty snapshot for an unconfigured project.
  shasum -a 256 <"$1" | awk '{print $1}'
}

ac_findings_normalize() {
  # ac_findings_normalize <outfile> - normalize a findings JSON array read from
  # stdin into <outfile>, atomically: a temp file in <outfile>'s own directory
  # is written first and moved into place, so a jq failure or an aborted
  # ingest leaves any existing <outfile> byte-identical. The temp file never
  # survives a failure, and the function's exit status is jq's own.
  # Fail closed: a missing OR empty action becomes ask-user. Normalize the wire
  # field `description` from legacy title/detail. Every ask-user leaves this
  # boundary with the captain-relay shape (question, 2-4 options, matching
  # tradeoffs, recommendation). Canonical verifiers must supply it themselves;
  # legacy/normalized findings get conservative defaults that keep delivery
  # held rather than inventing authority.
  # An optional `decision` is the captain's durable answer to an ask-user
  # finding. Re-posting findings is the one decision-recording path shared by
  # ship and QA, so the normalizer must preserve that field and scrub row-
  # breaking whitespace instead of silently dropping or reshaping it.
  # SEVERITY FLOOR (same enforcement point, same style as the authority
  # downgrade below): a finding with severity `info` and action `fix`
  # contradicts its own severity - info means no action required - so it is
  # DOWNGRADED to no-op, marked `severity_floored: true`, and still lands in
  # findings JSON/report with its `suggested_fix` advisory. Bound to `fix`
  # alone, same reasoning as the authority clause: `ask-user` is a captain
  # decision and is never floored, `no-op` already asserts no defect. Applied
  # BEFORE the authority clause so an already-floored finding cannot also be
  # authority-downgraded - deliberate, not incidental: this means an info+fix
  # finding with NO authority also floors straight to no-op instead of
  # escalating to ask-user. The authority clause's purpose is stopping an
  # unfounded `fix` from becoming a commit; once severity has already
  # retargeted the action to no-op nothing is ever assigned to a fixer, so
  # that purpose no longer applies, and holding delivery to ask the captain
  # about an unfounded no-op nit would cost more than the review loop this
  # floor exists to remove.
  # LATE-FINDING (ROUND) FLOOR (review-round-convergence -
  # the authority for relaxing the fresh-full-diff rule's action here): a
  # round>=2 NEW `fix` finding whose file lies OUTSIDE the immediately previous
  # round's fix delta is churn on code this round never touched - by
  # construction a PRE-EXISTING concern, routed as advisory (no-op,
  # `round_floored: true`, suggested_fix
  # kept) instead of buying another fix-and-rereview loop. Round + delta ride
  # env (AC_FINDINGS_ROUND, a positive integer; AC_FINDINGS_DELTA, a newline
  # file list; AC_FINDINGS_PRIOR_OPEN, a JSON string-id array) set ONLY by
  # ac-ship's review-agent. The previous-open set prevents an unresolved
  # finding from being mistaken for a new out-of-delta finding and floored.
  # Absent or malformed metadata floors NOTHING, so the QA pipeline and every
  # legacy caller are byte-identical (the floor fails toward reviewing too
  # much). CARVE-OUT,
  # non-overridable and failing toward FIXING: severity=error WITH class
  # correctness|security|data-loss keeps `fix` at any round on any surface -
  # and a finding the floor cannot AFFIRMATIVELY clear (error severity with
  # no class, or no file to locate it by) is NOT floored. Runs after the
  # severity floor (an info nit needs no round reasoning) and before the
  # authority clause, same already-retargeted logic as the severity floor's
  # precedence note above.
  # FINDING AUTHORITY (the single enforcement point for both pipelines): a
  # finding names the authority for its EXPECTED behaviour. `authority_class`
  # outside {internal, external}, or an empty `authority`, normalizes to class
  # `none` - and a `none` finding that claims action `fix` is DOWNGRADED to
  # ask-user with authority_downgraded: true. Only `fix` is bound: it is the
  # only action that ASSIGNS work to a fixer, so it is the one that turns an
  # unfounded statement into commits; `ask-user` is already the parked state
  # the rule wants and `no-op` asserts no defect, which is why a legacy clean
  # run still finishes exactly as before.
  local outfile="$1" tmp round="${AC_FINDINGS_ROUND:-1}" delta="${AC_FINDINGS_DELTA:-}"
  local prior_open="${AC_FINDINGS_PRIOR_OPEN:-}"
  case "$round" in '' | *[!0-9]*) round=1 ;; esac
  if [ "$round" -ge 2 ]; then
    if [ -z "$prior_open" ] \
      || ! jq -e 'type == "array" and all(.[]; type == "string")' \
           <<<"$prior_open" >/dev/null 2>&1; then
      # Without a trustworthy previous-open set, the normalizer cannot tell a
      # new late finding from an unresolved one. Disable the round floor rather
      # than risk clearing a blocker.
      round=1
      prior_open='[]'
    fi
  else
    prior_open='[]'
  fi
  tmp="$(mktemp "$outfile.XXXXXX")" || return 1
  if jq --argjson round "$round" --arg delta "$delta" --argjson prior_open "$prior_open" '
    ($delta | split("\n") | map(select(. != ""))) as $dfiles
    | [.[]
       | .action = (if ((.action // "") | tostring) == "" then "ask-user"
                    elif (.action == "fix" or .action == "ask-user" or .action == "no-op") then .action
                    else "ask-user" end)
       | .description = (.description // .detail // .title // "")
       | if has("decision") then
           .decision = ((.decision // "") | tostring | gsub("[\\t\\r\\n]+"; " "))
         else . end
       | .authority = ((.authority // "") | tostring)
       | .authority_class =
           (if (.authority | gsub("^\\s+|\\s+$"; "")) == "" then "none"
            elif ((.authority_class // "") | tostring) as $c
                 | ($c == "internal" or $c == "external") then .authority_class
            else "none" end)
       | if .action == "fix" and ((.severity // "") | tostring) == "info"
         then .action = "no-op" | .severity_floored = true
         else . end
       | ((.file // "") | tostring) as $ffile
       | ((.class // "") | tostring) as $fclass
       | ((.id // "") | tostring) as $fid
       | if $round >= 2 and .action == "fix"
            and (($prior_open | index($fid)) == null)
            and ($ffile != "")
            and (($dfiles | index($ffile)) == null)
            and ((((.severity // "") | tostring) != "error")
                 or ($fclass != ""
                     and ((["correctness","security","data-loss"] | index($fclass)) == null)))
         then .action = "no-op" | .round_floored = true
         else . end
       | if .action == "fix" and .authority_class == "none"
         then .action = "ask-user" | .authority_downgraded = true
         else . end
       | if .action == "ask-user" then
           .question = ((.question // "") | tostring)
           | if (.question | gsub("^\\s+|\\s+$"; "")) == "" then
               .question =
                 (if (.description | gsub("^\\s+|\\s+$"; "")) != "" then .description
                  else "What decision should resolve finding \((.id // "unknown") | tostring)?" end)
             else . end
           | .options =
               (if ((.options // null) | type) == "array"
                   and (.options | length) >= 2 and (.options | length) <= 4
                   and all(.options[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != ""))
                then .options
                else ["accept the finding as delivery direction",
                      "keep delivery held for more evidence"] end)
           | .tradeoffs =
               (if ((.tradeoffs // null) | type) == "array"
                   and (.tradeoffs | length) == (.options | length)
                   and all(.tradeoffs[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != ""))
                then .tradeoffs
                else (.options | map("Tradeoff not supplied for option: " + .)) end)
           | .recommendation = ((.recommendation // "") | tostring)
           | if (.recommendation | gsub("^\\s+|\\s+$"; "")) == "" then
               .recommendation = "Keep delivery held until the captain records a decision."
             else . end
           # The DECIDER shape - who answers, what kind of choice, what each
           # option does to a user or operator - is optional on the wire and
           # kept only when well-formed: axis in its enum, decider a non-empty
           # string, impact one line per option. A malformed value is dropped,
           # never defaulted - inventing "implementer" or an impact line would
           # put words in the mouth of the reviewer on the one finding the
           # captain reads most closely.
           | if (.axis as $a | ["impl","security","product","compliance"] | index($a)) == null
             then del(.axis) else . end
           | if ((.decider // "") | tostring | gsub("^\\s+|\\s+$"; "")) == "" then del(.decider)
             else .decider = (.decider | tostring) end
           | if ((.impact // null) | type) == "array"
                and (.impact | length) == (.options | length)
                and all(.impact[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != ""))
             then . else del(.impact) end
         else . end
      ]' >"$tmp"; then
    mv "$tmp" "$outfile"
  else
    rm -f "$tmp"
    return 1
  fi
}

ac_findings_summary() {
  # ac_findings_summary <file> - action counts, "none" for an empty array.
  jq -r 'if length == 0 then "none"
         else group_by(.action) | map("\(.[0].action)=\(length)") | join(" ") end' "$1"
}

ac_transcript_final() {
  # ac_transcript_final <transcript.jsonl> - the last assistant message's text
  # from a Claude Code session transcript (the pane agent's verdict).
  jq -rs '[.[] | select(.type == "assistant")] | last
          | .message.content | map(select(.type == "text") | .text) | join("\n")' "$1" 2>/dev/null
}

ac_verdict_json() {
  # ac_verdict_json - read a pane agent's final message on stdin and print the
  # LAST top-level balanced JSON object it contains that parses as an object.
  # The verdict is asked for JSON-only, but reviewers routinely wrap it in a
  # human summary and/or a ```json fence; this tolerates prose and fences on
  # either side of the bare object. Prints nothing when none is present, so the
  # caller's schema check fails closed. Deliberately separate from
  # ac_transcript_final, whose full-prose output the second-chief gate
  # (ac-gate.sh) still validates - do not fold JSON extraction into it.
  #
  # The awk pass is string-aware (a { or } or an escaped \" inside a JSON string
  # never moves the brace depth), so an object whose values contain braces is not
  # truncated. It emits every top-level object NUL-delimited; the shell keeps the
  # last one jq accepts, so a non-JSON brace region in the prose is skipped.
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; instr = 0; esc = 0; start = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (instr) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0 }
          continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "{") { if (depth == 0) start = i; depth += 1 }
        else if (c == "}" && depth > 0) {
          depth -= 1
          if (depth == 0) { printf "%s%c", substr(buf, start, i - start + 1), 0; start = 0 }
        }
      }
    }
  ' | {
    best=""
    while IFS= read -r -d '' cand; do
      if printf '%s' "$cand" | jq -e 'type == "object"' >/dev/null 2>&1; then
        best="$cand"
      fi
    done
    [ -z "$best" ] || printf '%s\n' "$best"
  }
}
