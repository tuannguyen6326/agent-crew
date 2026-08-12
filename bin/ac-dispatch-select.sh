#!/usr/bin/env bash
# ac-dispatch-select.sh - resolve a crew-dispatch profile for ac-spawn.
#
# config/crew-dispatch.json (see docs/examples/crew-dispatch.json) maps
# natural-language `when` clauses to harness profiles. MATCHING a rule is the
# orchestrator's judgment call (the clauses are prose); this script owns the
# deterministic part: listing the rules and resolving one into spawn flags.
#
# Usage:
#   ac-dispatch-select.sh --list          # <n><TAB><when><TAB><profile summary>
#   ac-dispatch-select.sh [--rule <n>]    # resolve rule n (1-based);
#                                         # no --rule = the config's default
#   ac-dispatch-select.sh --pane <kind>   # resolve .panes[<kind>] by KEY
#   ac-dispatch-select.sh --pane <qa|gate|codereview|roomchief> --list
#   ac-dispatch-select.sh --pane <qa|gate|codereview|roomchief> --rule <number|default>
#   ac-dispatch-select.sh --pane qa --receipt <number|default>
#
# --pane without a trailing operation is the JUDGMENT-FREE half of this
# resolver: a caller with no selector to offer. Four kinds may be ROUTED
# (`rules` + `default`, the same shape a top-level rule's `use` takes) and
# support --list/--rule: qa, gate, codereview, roomchief. They differ in ONE
# way - whether `default` is MANDATORY:
#   - qa: `default` stays OPTIONAL, and a routed lookup with no --rule prints
#     NOTHING (exit 0) rather than resolve one - the execution caller reads
#     --list, judges the prose `when` clauses, and passes exactly one --rule
#     selector; caller judgment only, never pane judgment.
#   - gate, codereview, roomchief: `default` is MANDATORY once routed
#     (validation REFUSES a routed panes.<kind> with none), so a lookup with
#     no --rule resolves it deterministically instead of dying or going
#     absent - this is what a mechanism with no agent in the loop to judge a
#     `when` clause needs (e.g. the --system-initiated roomchief promote
#     ac-learn.sh:1758 makes, which passes no --harness and no selector). A
#     caller that DOES have an agent in the loop (ac-gate.sh's owning
#     roomchief; the execution crewmate via ac-verify codereview) may still
#     pass its own --rule to choose deliberately.
# Any other kind (a flat profile, or a kind outside this set of four) never
# takes an operation: only `--pane <kind>` with no trailing flag is valid.
# The dispatcher never evaluates prose, falls through, or combines fields from
# different rules. --receipt returns the same selection as durable JSON and is
# QA-ONLY (its frozen routing receipt has no consumer for the other kinds);
# `use` remains one atomic harness/model/effort object.
# ABSENT is not an error and must stay distinguishable from one: no config
# file, no `panes` block, or no entry for that kind all print NOTHING and exit
# 0 - that is the fall-through to the pane agent's own ladder, i.e. the
# behaviour of a fleet that configured nothing. An entry that EXISTS and names
# no harness (flat), or a routed entry that fails its schema (non-empty
# when/why, atomic use, and - for the three mandatory-default kinds - a valid
# `default`), dies rather than falling back: a misconfigured profile is not an
# absent one, and ignoring it would launch something other than what it says.
#
# Output: `harness=<h> model=<m> effort=<e>` (model/effort may be empty).
# A rule whose `use` is a LIST alternates round-robin between its profiles
# (persisted in state/.dispatch-rr-<n>); `select: quota-balanced` maps onto
# this until a quota source exists. Without a config file the fallback is
# config/crew-harness (default claude).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

# Resolved WITHOUT ac_config_dir, the rule ac_config_read states: a READ must
# mint nothing. --pane is now called from a HOMELESS pane agent, where
# ac_config_dir's mkdir would grow a stray config/ in every pool worktree and
# checkout. Without ac_home either, for its twin: ac_home fails CLOSED with no
# AC_HOME, and this caller is legitimately homeless. An empty $cfg reads as
# "no dispatch config" at every use site below ([ -f "$cfg" ] guards them all),
# which is exactly what a homeless run resolved to before.
cfg=""
_home="$(ac_home_resolve '' '')"
[ -z "$_home" ] || cfg="$_home/config/crew-dispatch.json"

emit() {
  # emit <json-profile-object>
  local h m e
  h="$(jq -r '.harness // empty' <<<"$1")"
  m="$(jq -r '.model // empty' <<<"$1")"
  e="$(jq -r '.effort // empty' <<<"$1")"
  [ -n "$h" ] || ac_die "dispatch profile has no harness: $1"
  printf 'harness=%s model=%s effort=%s\n' "$h" "$m" "$e"
}

fallback() { printf 'harness=%s model= effort=\n' "$(ac_config_read crew-harness claude)"; }

dispatch_sha() {
  shasum -a 256 <"$cfg" | awk '{print $1}'
}

qa_pane_validate() {
  jq -e '
    (.panes.qa | type) == "object"
    and (
      if (.panes.qa | has("rules")) then
        ((.panes.qa | has("harness") or has("model") or has("effort")) | not)
        and (.panes.qa.rules | type) == "array"
        and (.panes.qa.rules | length) > 0
        and all(.panes.qa.rules[];
          (.when | type) == "string"
          and (.when | gsub("^\\s+|\\s+$"; "") | length) > 0
          and (.use | type) == "object"
          and (.use.harness | type) == "string"
          and (.use.harness | gsub("^\\s+|\\s+$"; "") | length) > 0
          and ((.use.model // "") | type) == "string"
          and ((.use.effort // "") | type) == "string"
          and (.why | type) == "string"
          and (.why | gsub("^\\s+|\\s+$"; "") | length) > 0)
        and (
          if (.panes.qa | has("default")) then
            (.panes.qa.default | type) == "object"
            and (.panes.qa.default.harness | type) == "string"
            and (.panes.qa.default.harness | gsub("^\\s+|\\s+$"; "") | length) > 0
            and ((.panes.qa.default.model // "") | type) == "string"
            and ((.panes.qa.default.effort // "") | type) == "string"
          else true end)
      else
        (.panes.qa.harness | type) == "string"
        and (.panes.qa.harness | gsub("^\\s+|\\s+$"; "") | length) > 0
        and ((.panes.qa.model // "") | type) == "string"
        and ((.panes.qa.effort // "") | type) == "string"
        and ((.panes.qa | has("default")) | not)
      end
    )
  ' "$cfg" >/dev/null 2>&1 \
    || ac_die "panes.qa must be either one static harness/model/effort profile or routed rules with non-empty when, atomic object use, non-empty why, and an optional bare default"
}

qa_pane_rule_json() {
  # qa_pane_rule_json <number|default> - resolve exactly one caller selection.
  local selector="$1" rule
  qa_pane_validate
  jq -e '.panes.qa | has("rules")' "$cfg" >/dev/null \
    || ac_die "panes.qa is static and does not accept --rule"
  if [ "$selector" = default ]; then
    rule="$(jq -c '.panes.qa.default // empty' "$cfg")"
    [ -n "$rule" ] || ac_die "panes.qa has no default profile"
    printf '%s\n' "$rule"
    return 0
  fi
  case "$selector" in ''|*[!0-9]*|0) ac_die "qa rule must be a positive number or default" ;; esac
  rule="$(jq -c --argjson n "$selector" '.panes.qa.rules[$n - 1] // empty' "$cfg")"
  [ -n "$rule" ] || ac_die "no panes.qa rule $selector in $cfg"
  jq -c '.use' <<<"$rule"
}

qa_pane_receipt() {
  local selector="$1" sha
  qa_pane_rule_json "$selector" >/dev/null
  sha="$(dispatch_sha)"
  if [ "$selector" = default ]; then
    jq -c --arg sha "$sha" '
      {
        kind: "qa",
        rule: "default",
        use: {
          harness: .panes.qa.default.harness,
          model: (.panes.qa.default.model // ""),
          effort: (.panes.qa.default.effort // "")
        },
        dispatch_sha256: $sha
      }
    ' "$cfg"
  else
    jq -c --argjson n "$selector" --arg sha "$sha" '
      .panes.qa.rules[$n - 1] as $r
      | {
          kind: "qa",
          rule: $n,
          when: $r.when,
          use: {
            harness: $r.use.harness,
            model: ($r.use.model // ""),
            effort: ($r.use.effort // "")
          },
          why: $r.why,
          dispatch_sha256: $sha
        }
    ' "$cfg"
  fi
}

routed_pane_validate() {
  # routed_pane_validate <kind> - validate a ROUTED .panes[<kind>] (it has
  # "rules") for gate/codereview/roomchief: unlike panes.qa, `default` is
  # MANDATORY here (captain ruling 2026-07-28,
  # routed-pane-rules-for-gate-codereview-roomchief) so a caller that passes
  # no selector can resolve one deterministically instead of dying.
  local k="$1"
  jq -e --arg k "$k" '
    ((.panes[$k] | has("harness") or has("model") or has("effort")) | not)
    and (.panes[$k].rules | type) == "array"
    and (.panes[$k].rules | length) > 0
    and all(.panes[$k].rules[];
      (.when | type) == "string"
      and (.when | gsub("^\\s+|\\s+$"; "") | length) > 0
      and (.use | type) == "object"
      and (.use.harness | type) == "string"
      and (.use.harness | gsub("^\\s+|\\s+$"; "") | length) > 0
      and ((.use.model // "") | type) == "string"
      and ((.use.effort // "") | type) == "string"
      and (.why | type) == "string"
      and (.why | gsub("^\\s+|\\s+$"; "") | length) > 0)
    and (.panes[$k] | has("default"))
    and (.panes[$k].default | type) == "object"
    and (.panes[$k].default.harness | type) == "string"
    and (.panes[$k].default.harness | gsub("^\\s+|\\s+$"; "") | length) > 0
    and ((.panes[$k].default.model // "") | type) == "string"
    and ((.panes[$k].default.effort // "") | type) == "string"
  ' "$cfg" >/dev/null 2>&1 \
    || ac_die "panes.$k routed rules require non-empty when, atomic object use, non-empty why on every rule, and a mandatory default profile"
}

routed_pane_rule_json() {
  # routed_pane_rule_json <kind> <number|default> - resolve exactly one
  # caller selection (or the mandatory default) for a routed panes.<kind>.
  local k="$1" selector="$2" rule
  routed_pane_validate "$k"
  if [ "$selector" = default ]; then
    jq -c --arg k "$k" '.panes[$k].default' "$cfg"
    return 0
  fi
  case "$selector" in ''|*[!0-9]*|0) ac_die "$k rule must be a positive number or default" ;; esac
  rule="$(jq -c --arg k "$k" --argjson n "$selector" '.panes[$k].rules[$n - 1] // empty' "$cfg")"
  [ -n "$rule" ] || ac_die "no panes.$k rule $selector in $cfg"
  jq -c '.use' <<<"$rule"
}

case "${1:-}" in
  --list)
    [ -f "$cfg" ] || ac_die "no dispatch config at $cfg"
    ac_require jq
    jq -e . "$cfg" >/dev/null 2>&1 || ac_die "invalid JSON: $cfg"
    jq -r '.rules // [] | to_entries[] |
      "\(.key + 1)\t\(.value.when)\t\(
        if (.value.use | type) == "array"
        then ([.value.use[].harness] | join("/")) + " (balanced)"
        else (.value.use.harness // "?")
             + (if .value.use.model then " " + .value.use.model else "" end)
             + (if .value.use.effort then " " + .value.use.effort else "" end)
        end)"' "$cfg"
    ;;
  --rule)
    n="${2:-}"
    [ -n "$n" ] || ac_die "--rule needs an index (see --list)"
    case "$n" in ''|*[!0-9]*|0) ac_die "rule must be a positive number" ;; esac
    [ -f "$cfg" ] || ac_die "no dispatch config at $cfg"
    ac_require jq
    rule="$(jq -c ".rules[$((n - 1))] // empty" "$cfg")"
    [ -n "$rule" ] || ac_die "no rule $n in $cfg"
    use="$(jq -c '.use' <<<"$rule")"
    if [ "$(jq -r 'type' <<<"$use")" = "array" ]; then
      len="$(jq 'length' <<<"$use")"
      [ "$len" -gt 0 ] || ac_die "rule $n has an empty use list"
      rr="$(ac_state_dir)/.dispatch-rr-$n"
      count="$(cat "$rr" 2>/dev/null || printf 0)"
      emit "$(jq -c ".[$((count % len))]" <<<"$use")"
      printf '%s\n' "$((count + 1))" >"$rr"
    else
      emit "$use"
    fi
    ;;
  --pane)
    k="${2:-}"
    [ -n "$k" ] || ac_die "--pane needs a kind (e.g. codereview, qa)"
    [ -f "$cfg" ] || exit 0
    ac_require jq
    jq -e . "$cfg" >/dev/null 2>&1 || ac_die "invalid JSON: $cfg"
    pane="$(jq -c --arg k "$k" '.panes[$k] // empty' "$cfg")"
    [ -n "$pane" ] || exit 0
    if [ "$k" = qa ]; then
      qa_pane_validate
      case "${3:-}" in
        --list)
          [ "$#" = 3 ] || ac_die "usage: ac-dispatch-select.sh --pane qa --list"
          jq -r '
            .panes.qa.rules
            | to_entries[]
            | "\(.key + 1)\t\(.value.when)\t\(.value.use.harness)\(
                if (.value.use.model // "") != "" then " " + .value.use.model else "" end)\(
                if (.value.use.effort // "") != "" then " " + .value.use.effort else "" end)\t\(.value.why)"
          ' "$cfg"
          if jq -e '.panes.qa | has("default")' "$cfg" >/dev/null; then
            jq -r '
              .panes.qa.default
              | "default\t\t\(.harness)\(
                  if (.model // "") != "" then " " + .model else "" end)\(
                  if (.effort // "") != "" then " " + .effort else "" end)\t"
            ' "$cfg"
          fi
          ;;
        --rule)
          [ "$#" = 4 ] || ac_die "usage: ac-dispatch-select.sh --pane qa --rule <number|default>"
          emit "$(qa_pane_rule_json "${4:-}")"
          ;;
        --receipt)
          [ "$#" = 4 ] || ac_die "usage: ac-dispatch-select.sh --pane qa --receipt <number|default>"
          qa_pane_receipt "${4:-}"
          ;;
        "")
          # Routed QA needs caller judgment, so an unselected lookup is absent
          # to downstream pane agents and ac-spawn. Static QA stays byte-for-byte.
          if jq -e '.panes.qa | has("rules")' "$cfg" >/dev/null; then
            exit 0
          fi
          emit "$pane"
          ;;
        *) ac_die "usage: ac-dispatch-select.sh --pane qa [--list | --rule <number|default> | --receipt <number|default>]" ;;
      esac
    elif { [ "$k" = gate ] || [ "$k" = codereview ] || [ "$k" = roomchief ]; } \
      && jq -e --arg k "$k" '.panes[$k] | has("rules")' "$cfg" >/dev/null 2>&1; then
      routed_pane_validate "$k"
      case "${3:-}" in
        --list)
          [ "$#" = 3 ] || ac_die "usage: ac-dispatch-select.sh --pane $k --list"
          jq -r --arg k "$k" '
            .panes[$k].rules
            | to_entries[]
            | "\(.key + 1)\t\(.value.when)\t\(.value.use.harness)\(
                if (.value.use.model // "") != "" then " " + .value.use.model else "" end)\(
                if (.value.use.effort // "") != "" then " " + .value.use.effort else "" end)\t\(.value.why)"
          ' "$cfg"
          jq -r --arg k "$k" '
            .panes[$k].default
            | "default\t\t\(.harness)\(
                if (.model // "") != "" then " " + .model else "" end)\(
                if (.effort // "") != "" then " " + .effort else "" end)\t"
          ' "$cfg"
          ;;
        --rule)
          [ "$#" = 4 ] || ac_die "usage: ac-dispatch-select.sh --pane $k --rule <number|default>"
          emit "$(routed_pane_rule_json "$k" "${4:-}")"
          ;;
        "")
          # `default` is MANDATORY once routed, so a caller with no selector
          # to offer resolves it deterministically instead of dying - unlike
          # panes.qa, which stays caller judgment only.
          emit "$(routed_pane_rule_json "$k" default)"
          ;;
        *) ac_die "usage: ac-dispatch-select.sh --pane $k [--list | --rule <number|default>]" ;;
      esac
    else
      [ "$#" = 2 ] || ac_die "--pane operations are supported only for routed qa/gate/codereview/roomchief"
      emit "$pane"
    fi
    ;;
  "")
    if [ -f "$cfg" ]; then
      ac_require jq
      d="$(jq -c '.default // empty' "$cfg")"
      if [ -n "$d" ]; then emit "$d"; else fallback; fi
    else
      fallback
    fi
    ;;
  *) ac_die "usage: ac-dispatch-select.sh [--list | --rule <n> | --pane <kind> [--list|--rule <selection>|--receipt <selection>]]" ;;
esac
