#!/usr/bin/env bash
# ac-qa-lib.sh - the ac_qa_* validation block, split out of ac-lib.sh
# (audit-f3, codebase-audit-2026-07-29 finding 3). Not an entrypoint; sourced
# after ac-lib.sh by any script that needs it - ac-lib.sh does NOT source this
# file (the ac-pipeline-lib.sh pattern: the CALLER sources both, and a
# function here that needs a sibling from ac-pipeline-lib.sh - e.g.
# ac_yaml_has - fails closed with `command -v` rather than assuming its
# caller sourced correctly).
#
# Owns: the qa.require_for_ship merge-gate policy read (ac_qa_required), the
# attestation/bundle/testplan/coverage/receipt validators that make up the QA
# COVERAGE MANIFEST and QA BOUNDARY POLICY RECEIPTS blocks (ac_qa_attestation_parse
# / ac_qa_bundle_validate / ac_qa_testplan_manifest_render /
# ac_qa_testplan_manifest_validate / ac_qa_timestamp_epoch /
# ac_qa_coverage_validate / ac_qa_ship_receipt_status /
# ac_qa_runtime_receipt_validate / ac_qa_runtime_gate_validate /
# ac_qa_boundary_coherent / ac_qa_path_sha / ac_qa_receipt_path_ok /
# ac_qa_browser_manifest_ok / ac_qa_boundary_receipt_validate), and the merge-time
# QA gate (ac_qa_gate_matrix / ac_qa_gate_ok).
#
# LIVE PRODUCTION CALLERS (derived from the tree, not the audit - see
# report.md): bin/ac-qa.sh, bin/ac-verify.sh, bin/ac-merge-local.sh
# (ac_qa_gate_ok) and bin/ac-pr-merge.sh (ac_qa_required, ac_qa_gate_matrix,
# ac_qa_gate_ok) - the merge helpers are load-bearing: ac-merge-local.sh is
# the script that lands THIS split's own family.
#
# LAYERING: depends only on ac-lib.sh core (ac_die, ac_warn, ac_config_read,
# ac_project_config_file, ac_repo_root, ...) and, for the scoped-config path,
# ac-pipeline-lib.sh's ac_yaml_has/ac_yaml_get/ac_yaml_keys - checked with
# `command -v` and skipped when absent, never assumed sourced. Never depended
# on by another sub-lib.

ac_qa_required() {
  # ac_qa_required <project-repo> - is the qa.require_for_ship merge gate
  # ENFORCED for this target? Returns 0 when the policy source sets
  # qa.require_for_ship: true, 1 otherwise. Reads the policy WITHOUT a head
  # sha, so a caller can decide enforcement even when the PR head cannot be
  # resolved - the fail-closed contract in ac-pr-merge.sh depends on this to
  # refuse (never skip) a required gate on an unknown head.
  # Policy source: the canonical $AC_HOME/projects/<name>.yaml (legacy path while
  # un-migrated). It is captain-owned and outside the project repo, so no branch
  # can alter the gate. Resolve through ac_project_config_file, the ONE config
  # producer + migration guard: a DIRECT guard call first, so an ambiguous dual
  # copy fails the gate CLOSED (its ac_die propagates - a $(...) capture would
  # swallow it) instead of silently selecting a copy; then read its RESOLVED path
  # so the gate stays correct on an un-migrated (legacy) home too.
  local repo="$1" cfg required hc
  ac_project_config_file "$repo" >/dev/null || true
  if hc="$(ac_project_config_file "$repo" 2>/dev/null)"; then cfg="$(cat "$hc")"; else cfg=""; fi
  required="$(printf '%s\n' "$cfg" | awk '
    /^qa:[[:space:]]*$/ { inq = 1; next }
    inq && /^[^[:space:]#]/ { inq = 0 }
    inq && /^[[:space:]]+require_for_ship:/ {
      v = $0; sub(/.*:[[:space:]]*/, "", v); gsub(/["'\'' ]/, "", v); print v; exit
    }')"
  [ "$required" = true ]
}

ac_qa_attestation_parse() {
  # ac_qa_attestation_parse <file> <source-sha> <scope> <app>
  #                         [<required-profile-sha>] [<required-e2e-sha>]
  # The one v2 receipt parser used by flat, scoped, and required-profile gates,
  # and by the writer before atomic publication.
  local file="$1" want_sha="$2" want_scope="$3" want_app="$4"
  local want_profile="${5:-}" want_e2e="${6:-}" line key seen="" value
  local schema="" outcome="" run="" task="" completed="" source=""
  local profile_key="" profile_sha="" config_sha="" cases_passed="" cases_total=""
  local scope="" app="" qa_rule="" e2e_repo="" e2e_sha=""
  AC_QA_ATTESTATION_ERROR=""
  [ -f "$file" ] || { AC_QA_ATTESTATION_ERROR="not a regular file"; return 1; }
  [ -s "$file" ] || { AC_QA_ATTESTATION_ERROR="empty marker"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key="${line%%=*}"; value="${line#*=}" ;;
      *) AC_QA_ATTESTATION_ERROR="malformed line"; return 1 ;;
    esac
    case "$key" in
      schema|outcome|run|task|completed_at|source_sha|profile_key|profile_sha256|config_sha256|cases_passed|cases_total|scope|app|qa_rule|e2e_repo|e2e_sha) ;;
      *) AC_QA_ATTESTATION_ERROR="unknown key '$key'"; return 1 ;;
    esac
    case " $seen " in *" $key "*) AC_QA_ATTESTATION_ERROR="duplicate key '$key'"; return 1 ;; esac
    seen="$seen $key"
    case "$key" in
      schema) schema="$value" ;;
      outcome) outcome="$value" ;;
      run) run="$value" ;;
      task) task="$value" ;;
      completed_at) completed="$value" ;;
      source_sha) source="$value" ;;
      profile_key) profile_key="$value" ;;
      profile_sha256) profile_sha="$value" ;;
      config_sha256) config_sha="$value" ;;
      cases_passed) cases_passed="$value" ;;
      cases_total) cases_total="$value" ;;
      scope) scope="$value" ;;
      app) app="$value" ;;
      qa_rule) qa_rule="$value" ;;
      e2e_repo) e2e_repo="$value" ;;
      e2e_sha) e2e_sha="$value" ;;
    esac
  done <"$file"
  [ "$schema" = "agentcrew.qa-attestation/v2" ] \
    || { AC_QA_ATTESTATION_ERROR="unsupported schema"; return 1; }
  [ "$outcome" = passed ] \
    || { AC_QA_ATTESTATION_ERROR="outcome is not passed"; return 1; }
  [ -n "$run" ] && [ -n "$task" ] && [ -n "$completed" ] \
    || { AC_QA_ATTESTATION_ERROR="missing run/task/completed_at"; return 1; }
  [ "$source" = "$want_sha" ] \
    || { AC_QA_ATTESTATION_ERROR="source_sha mismatch"; return 1; }
  [ -n "$profile_key" ] && [ -n "$profile_sha" ] && [ -n "$config_sha" ] \
    || { AC_QA_ATTESTATION_ERROR="missing profile/config identity"; return 1; }
  case "$cases_passed:$cases_total" in
    *[!0-9:]*|0:*|*:0|:*) AC_QA_ATTESTATION_ERROR="invalid case counts"; return 1 ;;
  esac
  [ "$cases_passed" = "$cases_total" ] \
    || { AC_QA_ATTESTATION_ERROR="case counts differ"; return 1; }
  if [ -n "$want_scope" ]; then
    [ "$scope" = "$want_scope" ] && [ "$app" = "$want_app" ] \
      || { AC_QA_ATTESTATION_ERROR="scope/app body mismatch"; return 1; }
  else
    case " $seen " in *" scope "*|*" app "*) AC_QA_ATTESTATION_ERROR="flat marker carries scope/app"; return 1 ;; esac
  fi
  case " $seen " in
    *" qa_rule "*)
    case "$qa_rule" in default) ;; *[!0-9]*|0|"") AC_QA_ATTESTATION_ERROR="invalid qa_rule"; return 1 ;; esac
    ;;
  esac
  case " $seen " in
    *" e2e_repo "*|*" e2e_sha "*)
    [ -n "$e2e_repo" ] && [ -n "$e2e_sha" ] \
      || { AC_QA_ATTESTATION_ERROR="partial E2E identity"; return 1; }
    ;;
  esac
  [ -z "$want_profile" ] || [ "$profile_sha" = "$want_profile" ] \
    || { AC_QA_ATTESTATION_ERROR="profile hash mismatch"; return 1; }
  [ -z "$want_e2e" ] || [ "$e2e_sha" = "$want_e2e" ] \
    || { AC_QA_ATTESTATION_ERROR="E2E hash mismatch"; return 1; }
  return 0
}

ac_qa_bundle_validate() {
  # ac_qa_bundle_validate <bundle/profile.json> <exact-source-sha>
  # Validate the immutable, path-closed profile bundle before either verifier
  # handoff or run consumption. The profile hash intentionally excludes local
  # source paths and timestamps while binding every snapshot content hash.
  local profile="$1" want_sha="$2" bundle config scopes manifest ship_receipt
  local config_sha scopes_sha manifest_sha ship_receipt_sha canonical got rel want actual
  local listed actual_files fixture_manifest pack rel root_entry
  AC_QA_BUNDLE_ERROR=""
  [ "$(basename "$profile")" = profile.json ] \
    || { AC_QA_BUNDLE_ERROR="profile filename must be profile.json"; return 1; }
  bundle="$(cd "$(dirname "$profile")" 2>/dev/null && pwd -P)" \
    || { AC_QA_BUNDLE_ERROR="bundle directory is unreadable"; return 1; }
  [ "$profile" = "$bundle/profile.json" ] \
    || { AC_QA_BUNDLE_ERROR="profile path is not the fixed bundle file"; return 1; }
  [ -z "$(find "$bundle" -type l -print -quit 2>/dev/null)" ] \
    || { AC_QA_BUNDLE_ERROR="bundle contains a symlink"; return 1; }
  while IFS= read -r root_entry; do
    case "$(basename "$root_entry")" in
      profile.json|config.yaml|scopes.tsv|store|runtime.json|ship) ;;
      *) AC_QA_BUNDLE_ERROR="unknown bundle root entry: $(basename "$root_entry")"; return 1 ;;
    esac
  done < <(find "$bundle" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
  config="$bundle/config.yaml"
  scopes="$bundle/scopes.tsv"
  manifest="$bundle/store/manifest.json"
  ship_receipt="$bundle/ship/test-receipt.env"
  [ -d "$bundle/store" ] && [ ! -L "$bundle/store" ] \
    || { AC_QA_BUNDLE_ERROR="bundle store is missing or symlinked"; return 1; }
  [ -d "$bundle/ship" ] && [ ! -L "$bundle/ship" ] \
    || { AC_QA_BUNDLE_ERROR="bundle ship receipt directory is missing or symlinked"; return 1; }
  for got in "$profile" "$config" "$scopes" "$manifest" "$ship_receipt"; do
    [ -f "$got" ] && [ ! -L "$got" ] \
      || { AC_QA_BUNDLE_ERROR="missing or symlinked bundle file: $got"; return 1; }
  done
  jq -e '
    type == "object"
    and .schema == "agentcrew.qa-profile/v1"
    and (.profile_key | type == "string" and length > 0)
    and (.profile_sha256 | type == "string" and length > 0)
    and (.source.ref | type == "string" and length > 0)
    and .snapshots.config_file == "config.yaml"
    and .snapshots.scopes_file == "scopes.tsv"
    and .snapshots.store_manifest_file == "store/manifest.json"
    and .snapshots.ship_test_receipt_file == "ship/test-receipt.env"
    and (.snapshots.ship_test_receipt_sha256 | type == "string" and length > 0)
    and (
      if has("routing") then
        (.routing | type) == "object"
        and .routing.kind == "qa"
        and (.routing.use | type) == "object"
        and (.routing.use.harness | type) == "string"
        and (.routing.use.harness | length) > 0
        and (.routing.use.model | type) == "string"
        and (.routing.use.effort | type) == "string"
        and (.routing.dispatch_sha256 | type) == "string"
        and (.routing.dispatch_sha256 | test("^[0-9a-f]{64}$"))
        and (
          if .routing.rule == "default" then
            (((.routing | has("when")) or (.routing | has("why"))) | not)
          else
            (.routing.rule | type) == "number"
            and .routing.rule >= 1
            and (.routing.rule | floor) == .routing.rule
            and (.routing.when | type) == "string"
            and (.routing.when | length) > 0
            and (.routing.why | type) == "string"
            and (.routing.why | length) > 0
          end)
      else true end
    )
  ' "$profile" >/dev/null 2>&1 \
    || { AC_QA_BUNDLE_ERROR="invalid profile schema or fixed snapshot names"; return 1; }
  [ "$(jq -r '.source.ref' "$profile")" = "$want_sha" ] \
    || { AC_QA_BUNDLE_ERROR="profile source ref does not match exact source lease"; return 1; }
  config_sha="$(ac_config_sha256 "$config")"
  scopes_sha="$(ac_config_sha256 "$scopes")"
  manifest_sha="$(ac_config_sha256 "$manifest")"
  [ "$config_sha" = "$(jq -r '.snapshots.config_sha256 // ""' "$profile")" ] \
    || { AC_QA_BUNDLE_ERROR="config snapshot hash mismatch"; return 1; }
  [ "$scopes_sha" = "$(jq -r '.snapshots.scopes_sha256 // ""' "$profile")" ] \
    || { AC_QA_BUNDLE_ERROR="scope snapshot hash mismatch"; return 1; }
  [ "$manifest_sha" = "$(jq -r '.snapshots.store_manifest_sha256 // ""' "$profile")" ] \
    || { AC_QA_BUNDLE_ERROR="store manifest hash mismatch"; return 1; }
  ship_receipt_sha="$(ac_config_sha256 "$ship_receipt")"
  [ "$ship_receipt_sha" = "$(jq -r '.snapshots.ship_test_receipt_sha256 // ""' "$profile")" ] \
    || { AC_QA_BUNDLE_ERROR="frozen ship test receipt hash mismatch"; return 1; }
  [ "$(ac_meta_get "$ship_receipt" schema)" = "agentcrew.ship-test-receipt/v1" ] \
    || { AC_QA_BUNDLE_ERROR="frozen ship test receipt has the wrong schema"; return 1; }
  [ "$(ac_meta_get "$ship_receipt" source_sha)" = "$want_sha" ] \
    || { AC_QA_BUNDLE_ERROR="frozen ship test receipt binds another source sha"; return 1; }
  jq -e '
    type == "object"
    and .schema == "agentcrew.qa-store-snapshot/v1"
    and (.entries | type == "array")
    and all(.entries[];
      type == "object"
      and (.path | type == "string" and length > 0)
      and (.sha256 | type == "string" and length > 0))
  ' "$manifest" >/dev/null 2>&1 \
    || { AC_QA_BUNDLE_ERROR="invalid store manifest"; return 1; }
  listed="$(jq -r '.entries[].path' "$manifest" | LC_ALL=C sort)"
  actual_files="$(find "$bundle/store" -type f ! -path "$manifest" -print \
    | sed "s#^$bundle/store/##" | LC_ALL=C sort)"
  [ "$listed" = "$actual_files" ] \
    || { AC_QA_BUNDLE_ERROR="store manifest/file inventory mismatch"; return 1; }
  while IFS="$(printf '\t')" read -r rel want; do
    [ -n "$rel" ] || continue
    case "$rel" in /*|..|../*|*/../*|*/..|*$'\t'*|*$'\n'*)
      AC_QA_BUNDLE_ERROR="unsafe store entry path: $rel"; return 1 ;;
    esac
    [ -f "$bundle/store/$rel" ] && [ ! -L "$bundle/store/$rel" ] \
      || { AC_QA_BUNDLE_ERROR="missing store entry: $rel"; return 1; }
    actual="$(ac_config_sha256 "$bundle/store/$rel")"
    [ "$actual" = "$want" ] \
      || { AC_QA_BUNDLE_ERROR="store entry hash mismatch: $rel"; return 1; }
  done < <(jq -r '.entries[] | [.path,.sha256] | @tsv' "$manifest")
  while IFS= read -r fixture_manifest; do
    [ -n "$fixture_manifest" ] || continue
    pack="$(dirname "$fixture_manifest")"
    jq -e '
      type == "object"
      and .schema == "agentcrew.qa-fixture-pack/v1"
      and (.id | type) == "string" and (.id | length) > 0
      and (.runner | type) == "string" and (.runner | length) > 0
      and (.selectors | type) == "array" and (.selectors | length) > 0
      and all(.selectors[]; type == "string" and length > 0)
      and ((.selectors | unique | length) == (.selectors | length))
      and (.capabilities | type) == "array"
      and (.mutation as $m | ["read-only","read-write"] | index($m) != null)
      and (.retry as $r | ["idempotent","read-only"] | index($r) != null)
      and (if .mutation == "read-write" then .retry == "idempotent" else true end)
      and ((.assets // []) | type) == "array"
      and all((.assets // [])[]; type == "string" and length > 0)
    ' "$fixture_manifest" >/dev/null 2>&1 \
      || { AC_QA_BUNDLE_ERROR="invalid fixture-pack manifest: ${fixture_manifest#"$bundle/store/"}"; return 1; }
    while IFS= read -r rel; do
      case "$rel" in ''|/*|..|../*|*/../*|*/..)
        AC_QA_BUNDLE_ERROR="unsafe fixture-pack path: $rel"; return 1 ;;
      esac
      [ -f "$pack/$rel" ] && [ ! -L "$pack/$rel" ] \
        || { AC_QA_BUNDLE_ERROR="missing fixture-pack file: $rel"; return 1; }
    done < <(jq -r '.runner, (.assets // [])[]' "$fixture_manifest")
  done < <(find "$bundle/store/fixtures" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | LC_ALL=C sort)
  canonical="$(jq -S '
    del(.profile_sha256,
        .provenance.resolved_at,
        .provenance.project_config_path,
        .provenance.repo_knowledge_path,
        .e2e.repo_path)
  ' "$profile" | shasum -a 256 | awk '{print $1}')"
  # shellcheck disable=SC2034 # Callers read this diagnostic after validation fails.
  [ "$canonical" = "$(jq -r '.profile_sha256 // ""' "$profile")" ] \
    || { AC_QA_BUNDLE_ERROR="canonical profile hash mismatch"; return 1; }
  return 0
}

# --- QA COVERAGE MANIFEST -------------------------------------------------------
# The test plan's machine-readable coverage/full-flow declarations are frozen
# before any case-producing command runs. ac-qa.sh writes and gates the
# manifest; ac-verify.sh independently re-renders it before export. Keep the
# parser and evidence ladder here so both actors make one closed decision.

ac_qa_testplan_manifest_render() {
  # ac_qa_testplan_manifest_render <source-repo> <target-sha> <testplan>
  # Print canonical agentcrew.qa-testplan-manifest/v1 JSON. The parser accepts
  # declarations only in the exact H2 sections and ignores fenced examples.
  local source_repo="$1" target_sha="$2" testplan="$3" parsed error
  local kind ac rung proof case_id path selector prefix part mode
  AC_QA_MANIFEST_ERROR=""
  [ -d "$source_repo" ] && git -C "$source_repo" cat-file -e "$target_sha^{commit}" 2>/dev/null \
    || { AC_QA_MANIFEST_ERROR="target source commit is unavailable: $target_sha"; return 1; }
  [ -f "$testplan" ] \
    || { AC_QA_MANIFEST_ERROR="test plan is missing: $testplan"; return 1; }
  if ! parsed="$(awk '
    function fail(message) {
      print message >"/dev/stderr"
      failed=1
      exit 1
    }
    function valid_id(value) {
      return value ~ /^[A-Za-z0-9_.-]+$/ \
        && value != "." && value != ".." \
        && value !~ /\.\./ && value ~ /[A-Za-z0-9]/
    }
    /^[[:space:]]*```/ || /^[[:space:]]*~~~/ { fenced = !fenced; next }
    fenced { next }
    /^## / {
      section=""
      if ($0 == "## Coverage") {
        coverage_sections++
        section="coverage"
      } else if ($0 == "## Full Flow") {
        flow_sections++
        section="flow"
      }
      next
    }
    section == "coverage" && /^coverage:/ {
      if ($0 !~ /^coverage: / || $0 ~ /[[:space:]]$/)
        fail("malformed coverage declaration at line " NR)
      rest=substr($0, 11)
      count=split(rest, field, / [|] /)
      if (count != 4)
        fail("coverage declaration needs four exact fields at line " NR)
      for (i=1; i<=4; i++)
        if (field[i] == "" || field[i] ~ /^[[:space:]]/ || field[i] ~ /[[:space:]]$/)
          fail("coverage declaration has an empty or padded field at line " NR)
      ac=field[1]; rung=field[2]; proof=field[3]; case_id=field[4]
      if (!valid_id(ac))
        fail("invalid acceptance-criterion id at line " NR ": " ac)
      if (rung != "ut" && rung != "it" && rung != "e2e")
        fail("invalid coverage rung at line " NR ": " rung)
      if (rung == "ut") {
        if (proof == "-" || case_id != "-")
          fail("UT coverage needs a test reference and no QA case at line " NR)
      } else if (proof != "-" || !valid_id(case_id)) {
        fail("IT/E2E coverage needs a case id and no test reference at line " NR)
      }
      key=ac SUBSEP rung SUBSEP proof SUBSEP case_id
      if (coverage_seen[key]++)
        fail("duplicate coverage declaration at line " NR)
      if (rung != "ut")
        covered_case[case_id]=1
      coverage_count++
      printf "C\t%s\t%s\t%s\t%s\n", ac, rung, proof, case_id
      next
    }
    section == "flow" && /^full-flow:/ {
      if ($0 !~ /^full-flow: / || $0 ~ /[[:space:]]$/)
        fail("malformed full-flow declaration at line " NR)
      case_id=substr($0, 12)
      if (!valid_id(case_id))
        fail("invalid full-flow case id at line " NR ": " case_id)
      if (flow_seen[case_id]++)
        fail("duplicate full-flow declaration at line " NR ": " case_id)
      flow_order[++flow_count]=case_id
      printf "F\t%s\n", case_id
      next
    }
    END {
      if (failed) exit 1
      if (fenced)
        fail("unterminated fenced code block in test plan")
      if (coverage_sections != 1)
        fail("test plan needs exactly one ## Coverage section")
      if (flow_sections != 1)
        fail("test plan needs exactly one ## Full Flow section")
      if (coverage_count < 1)
        fail("test plan needs at least one coverage declaration")
      if (flow_count < 1)
        fail("test plan needs at least one full-flow declaration")
      for (i=1; i<=flow_count; i++)
        if (!covered_case[flow_order[i]])
          fail("full-flow case is not cited by IT/E2E coverage: " flow_order[i])
    }
  ' "$testplan" 2>&1)"; then
    AC_QA_MANIFEST_ERROR="${parsed:-test-plan manifest parse failed}"
    return 1
  fi

  # A UT reference is evidence, never a command. Resolve its tracked blob from
  # the exact Git tree and reject every symlinked parent/leaf.
  while IFS="$(printf '\t')" read -r kind ac rung proof case_id; do
    [ "$kind" = C ] && [ "$rung" = ut ] || continue
    case "$proof" in
      *'#'*)
        path="${proof%%#*}"
        selector="${proof#*#}"
        case "$selector" in ''|*'#'*|*'|'*|*$'\t'*|*$'\r'*|*$'\n'*)
          AC_QA_MANIFEST_ERROR="UT coverage $ac has an invalid selector: $proof"
          return 1 ;;
        esac ;;
      *) path="$proof" ;;
    esac
    case "$path" in
      ''|/*|.|..|./*|*/./*|*/.|../*|*/../*|*/..|*'#'*|*'|'*|*$'\t'*|*$'\r'*|*$'\n'*)
        AC_QA_MANIFEST_ERROR="UT coverage $ac has an unsafe repository test path: $path"
        return 1 ;;
    esac
    prefix=""
    while IFS= read -r part; do
      [ -n "$part" ] || {
        AC_QA_MANIFEST_ERROR="UT coverage $ac has an unsafe repository test path: $path"
        return 1
      }
      prefix="${prefix}${prefix:+/}$part"
      mode="$(git -C "$source_repo" ls-tree "$target_sha" -- "$prefix" \
        | awk 'NR==1 { print $1 }')"
      if [ "$prefix" = "$path" ]; then
        case "$mode" in 100644|100755) ;; *)
          AC_QA_MANIFEST_ERROR="UT coverage $ac does not name a regular tracked blob at $target_sha: $path"
          return 1 ;;
        esac
      else
        [ "$mode" = 040000 ] || {
          AC_QA_MANIFEST_ERROR="UT coverage $ac crosses a missing or symlinked Git-tree parent: $prefix"
          return 1
        }
      fi
    done < <(printf '%s\n' "$path" | tr '/' '\n')
  done <<<"$parsed"

  error="$(shasum -a 256 <"$testplan" | awk '{print $1}')"
  printf '%s\n' "$parsed" | jq -Rsc --arg plan_sha "$error" '
    split("\n")
    | map(select(length > 0) | split("\t")) as $rows
    | {
        schema: "agentcrew.qa-testplan-manifest/v1",
        testplan_sha256: $plan_sha,
        coverage: [
          $rows[]
          | select(.[0] == "C")
          | {ac: .[1], rung: .[2], proof: .[3], case: .[4]}
        ],
        full_flow: [
          $rows[]
          | select(.[0] == "F")
          | .[1]
        ]
      }
  ' | jq -cS .
}

ac_qa_testplan_manifest_validate() {
  # ac_qa_testplan_manifest_validate <source-repo> <target-sha> <testplan>
  #                                      <manifest> <expected-manifest-sha>
  local source_repo="$1" target_sha="$2" testplan="$3" manifest="$4" expected_sha="$5"
  local rendered_file actual_sha
  AC_QA_MANIFEST_ERROR=""
  [ -f "$manifest" ] \
    || { AC_QA_MANIFEST_ERROR="frozen test-plan manifest is missing: $manifest"; return 1; }
  rendered_file="$(mktemp "${TMPDIR:-/tmp}/ac-qa-manifest-validate.XXXXXX")"
  if ! ac_qa_testplan_manifest_render "$source_repo" "$target_sha" "$testplan" \
      >"$rendered_file"; then
    rm -f "$rendered_file"
    return 1
  fi
  cmp -s "$rendered_file" "$manifest" \
    || { rm -f "$rendered_file"; AC_QA_MANIFEST_ERROR="current test plan disagrees with the frozen manifest"; return 1; }
  rm -f "$rendered_file"
  actual_sha="$(shasum -a 256 <"$manifest" | awk '{print $1}')"
  [ -n "$expected_sha" ] && [ "$actual_sha" = "$expected_sha" ] \
    || { AC_QA_MANIFEST_ERROR="frozen manifest hash mismatch"; return 1; }
  return 0
}

ac_qa_timestamp_epoch() {
  # Canonical receipt timestamps are UTC ISO-8601 seconds. jq owns the portable
  # parser on both BSD and GNU hosts.
  jq -nr --arg timestamp "$1" '$timestamp | fromdateiso8601' 2>/dev/null
}

ac_qa_coverage_validate() {
  # ac_qa_coverage_validate <run-dir> <source-repo> <target-sha>
  # Validate the frozen ladder against the effective ledger and receipt times.
  local run="$1" source_repo="$2" target_sha="$3"
  local evidence_root testplan manifest manifest_sha ship_status
  local ac rung proof case_id row tier status boundary receipt count
  local id started completed start_epoch completed_epoch min_flow="" max_component=""
  AC_QA_MANIFEST_ERROR=""
  evidence_root="$(ac_meta_get "$run/run.meta" evidence)"
  [ -n "$evidence_root" ] || evidence_root="$run/evidence"
  testplan="$(ac_meta_get "$run/run.meta" testplan_path)"
  [ -n "$testplan" ] || testplan="$(dirname "$evidence_root")/testplan.md"
  manifest="$run/testplan-manifest.json"
  manifest_sha="$(ac_meta_get "$run/run.meta" testplan_manifest_sha256)"
  ac_qa_testplan_manifest_validate "$source_repo" "$target_sha" "$testplan" \
    "$manifest" "$manifest_sha" || return 1

  ship_status="$(ac_qa_ship_receipt_status "$run/profile/ship/test-receipt.env" "$target_sha")"
  while IFS="$(printf '\t')" read -r ac rung proof case_id; do
    case "$rung" in
      ut)
        case "$ship_status" in qualifies:*) ;; *)
          AC_QA_MANIFEST_ERROR="UT coverage $ac requires a qualifying exact-SHA ship receipt (got $ship_status); escalate this AC to IT"
          return 1 ;;
        esac ;;
      it|e2e)
        count="$(awk -F'\t' -v id="$case_id" '$1 == id { n++ } END { print n+0 }' "$run/cases.tsv")"
        [ "$count" = 1 ] || {
          AC_QA_MANIFEST_ERROR="$rung coverage $ac needs exactly one effective case row for $case_id"
          return 1
        }
        row="$(awk -F'\t' -v id="$case_id" '$1 == id { print; exit }' "$run/cases.tsv")"
        tier="$(printf '%s\n' "$row" | awk -F'\t' '{print $2}')"
        status="$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')"
        boundary="$(printf '%s\n' "$row" | awk -F'\t' '{print $11}')"
        [ "$status" = pass ] || {
          AC_QA_MANIFEST_ERROR="$rung coverage $ac cites non-passing case $case_id"
          return 1
        }
        if [ "$rung" = it ]; then
          case "$tier" in api|db|workflow) ;; *)
            AC_QA_MANIFEST_ERROR="IT coverage $ac cites case $case_id with non-IT tier $tier"
            return 1 ;;
          esac
        else
          { [ "$tier" = web ] || [ "$boundary" = e2e ]; } || {
            AC_QA_MANIFEST_ERROR="E2E coverage $ac cites case $case_id without web or e2e evidence"
            return 1
          }
        fi ;;
    esac
  done < <(jq -r '.coverage[] | [.ac,.rung,.proof,.case] | @tsv' "$manifest")

  while IFS="$(printf '\t')" read -r id tier status _ _ _ _ _ _ _ boundary receipt; do
    [ -n "$id" ] || continue
    started="$(ac_meta_get "$receipt" started_at)"
    completed="$(ac_meta_get "$receipt" completed_at)"
    start_epoch="$(ac_qa_timestamp_epoch "$started")" || {
      AC_QA_MANIFEST_ERROR="case $id has an invalid boundary started_at timestamp: $started"
      return 1
    }
    completed_epoch="$(ac_qa_timestamp_epoch "$completed")" || {
      AC_QA_MANIFEST_ERROR="case $id has an invalid boundary completed_at timestamp: $completed"
      return 1
    }
    [ "$completed_epoch" -ge "$start_epoch" ] || {
      AC_QA_MANIFEST_ERROR="case $id boundary completed_at precedes started_at"
      return 1
    }
    if jq -e --arg id "$id" '.full_flow | index($id) != null' "$manifest" >/dev/null; then
      [ "$status" = pass ] || {
        AC_QA_MANIFEST_ERROR="full-flow case $id is not passing"
        return 1
      }
      case "$tier" in api|db|workflow|web) ;; *)
        AC_QA_MANIFEST_ERROR="full-flow case $id has invalid tier $tier"
        return 1 ;;
      esac
      [ -n "$min_flow" ] && [ "$min_flow" -le "$start_epoch" ] \
        || min_flow="$start_epoch"
    else
      [ -n "$max_component" ] && [ "$max_component" -ge "$completed_epoch" ] \
        || max_component="$completed_epoch"
    fi
  done <"$run/cases.tsv"
  [ -n "$min_flow" ] || {
    AC_QA_MANIFEST_ERROR="no declared full-flow case exists in the effective ledger"
    return 1
  }
  if [ -n "$max_component" ] && [ "$min_flow" -lt "$max_component" ]; then
    AC_QA_MANIFEST_ERROR="full-flow final group started before all component cases completed"
    return 1
  fi
  return 0
}

# --- QA BOUNDARY POLICY RECEIPTS ------------------------------------------------
# The closed validators for the four receipts the QA boundary policy binds:
# the frozen ship-test receipt (unit-suite health as a READ), the runtime boot
# receipt (the deliverable was actually booted), the final runtime gate (it was
# still alive when the pass was minted), and the per-case boundary execution
# receipt (each behavioral case was driven from OUTSIDE the process).
# ONE owner each, because three actors must agree byte-for-byte on every
# answer: ac-qa.sh records and gates, ac-verify.sh reconciles the exported run,
# and the merge gate reads what they published. Every validator is a pure READ:
# it never checks process liveness (post-teardown reconciliation validates the
# immutable record, and requiring a terminated process to still be alive would
# reject every honest run) and never writes.

ac_qa_ship_receipt_status() {
  # ac_qa_ship_receipt_status <receipt-file|''> <exact-source-sha>
  # THE single qualification decision for a ship test receipt: the QA profile
  # freeze computes it, and `ac-qa.sh baseline` re-checks the frozen copy with
  # the same call, so a freeze and a gate can never disagree.
  # Prints `qualifies:<reason>` or `not-qualifies:<reason>` on ONE closed reason
  # (executed|execution-attestation|absent|incomplete|non-zero|stale|invalid|
  # scoped - a green changed-file-only run, deliberately never suite proof;
  # ac-ship.sh's SCOPED TEST block owns why) and always returns 0: an
  # unreadable receipt is a NOT-qualifying answer, not an error a caller could
  # mistake for proof.
  local src="$1" want_sha="$2" qual reason sha exit_code cmd_sha out_sha started ended
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    printf 'not-qualifies:absent\n'; return 0
  fi
  [ "$(ac_meta_get "$src" schema)" = "agentcrew.ship-test-receipt/v1" ] \
    || { printf 'not-qualifies:invalid\n'; return 0; }
  qual="$(ac_meta_get "$src" qualification)"
  reason="$(ac_meta_get "$src" reason)"
  sha="$(ac_meta_get "$src" source_sha)"
  case "$reason" in
    executed|execution-attestation|absent|incomplete|non-zero|stale|invalid|scoped) ;;
    *) printf 'not-qualifies:invalid\n'; return 0 ;;
  esac
  # A receipt for another commit is STALE before anything else is judged: a
  # qualifying suite run on a different tree proves nothing about this target.
  [ -n "$want_sha" ] && [ "$sha" = "$want_sha" ] \
    || { printf 'not-qualifies:stale\n'; return 0; }
  if [ "$qual" != qualifies ]; then
    case "$reason" in
      executed|execution-attestation) printf 'not-qualifies:invalid\n' ;;
      *) printf 'not-qualifies:%s\n' "$reason" ;;
    esac
    return 0
  fi
  exit_code="$(ac_meta_get "$src" exit_code)"
  cmd_sha="$(ac_meta_get "$src" command_sha256)"
  out_sha="$(ac_meta_get "$src" output_sha256)"
  started="$(ac_meta_get "$src" started_at)"
  ended="$(ac_meta_get "$src" completed_at)"
  case "$reason" in executed|execution-attestation) ;; *) printf 'not-qualifies:invalid\n'; return 0 ;; esac
  { [ "$exit_code" = 0 ] \
    && [ -n "$cmd_sha" ] && [ "$cmd_sha" != "-" ] \
    && [ -n "$out_sha" ] && [ "$out_sha" != "-" ] \
    && [ -n "$started" ] && [ "$started" != "-" ] \
    && [ -n "$ended" ] && [ "$ended" != "-" ]; } \
    || { printf 'not-qualifies:invalid\n'; return 0; }
  printf 'qualifies:%s\n' "$reason"
}

ac_qa_runtime_receipt_validate() {
  # ac_qa_runtime_receipt_validate <file> <source-sha> <profile-sha> \
  #                                <serve-cmd-sha> <health-cmd-sha> <descriptor-sha>
  # The boot receipt only a zero-exit managed health probe can publish. Shape,
  # closed schema, and identity only - liveness is the caller's separate act.
  local f="$1" source_sha="$2" profile_sha="$3" serve_sha="$4" health_sha="$5" desc_sha="$6" pgid
  AC_QA_RECEIPT_ERROR=""
  [ -f "$f" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt is missing: $f"; return 1; }
  [ "$(ac_meta_get "$f" schema)" = "agentcrew.qa-runtime-receipt/v1" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt has the wrong schema"; return 1; }
  [ "$(ac_meta_get "$f" source_sha)" = "$source_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt binds another source sha"; return 1; }
  [ "$(ac_meta_get "$f" profile_sha256)" = "$profile_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt binds another profile hash"; return 1; }
  [ "$(ac_meta_get "$f" serve_command_sha256)" = "$serve_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt binds another serve command"; return 1; }
  [ "$(ac_meta_get "$f" health_command_sha256)" = "$health_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt binds another health command"; return 1; }
  [ "$(ac_meta_get "$f" runtime_descriptor_sha256)" = "$desc_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt binds another runtime descriptor"; return 1; }
  [ -n "$(ac_meta_get "$f" serve_started_at)" ] && [ -n "$(ac_meta_get "$f" health_completed_at)" ] \
    || { AC_QA_RECEIPT_ERROR="runtime receipt has no boot/health timestamps"; return 1; }
  pgid="$(ac_meta_get "$f" process_group)"
  case "$pgid" in ''|*[!0-9]*|0) AC_QA_RECEIPT_ERROR="runtime receipt has no positive process group"; return 1 ;; esac
  return 0
}

ac_qa_runtime_gate_validate() {
  # ac_qa_runtime_gate_validate <file> <source-sha> <profile-sha> \
  #                             <runtime-receipt-sha> <health-cmd-sha> <process-group>
  # The final live-process + repeated-health record published immediately
  # before managed teardown. Reconciliation validates THIS, never the process.
  local f="$1" source_sha="$2" profile_sha="$3" runtime_sha="$4" health_sha="$5" pgid="$6"
  AC_QA_RECEIPT_ERROR=""
  [ -f "$f" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt is missing: $f"; return 1; }
  [ "$(ac_meta_get "$f" schema)" = "agentcrew.qa-runtime-gate/v1" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt has the wrong schema"; return 1; }
  [ "$(ac_meta_get "$f" source_sha)" = "$source_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt binds another source sha"; return 1; }
  [ "$(ac_meta_get "$f" profile_sha256)" = "$profile_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt binds another profile hash"; return 1; }
  [ "$(ac_meta_get "$f" runtime_receipt_sha256)" = "$runtime_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt binds another boot receipt"; return 1; }
  [ "$(ac_meta_get "$f" health_command_sha256)" = "$health_sha" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt binds another health command"; return 1; }
  [ "$(ac_meta_get "$f" process_group)" = "$pgid" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt binds another process group"; return 1; }
  [ "$(ac_meta_get "$f" alive)" = 1 ] && [ "$(ac_meta_get "$f" health_exit_code)" = 0 ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt does not record a live zero-exit probe"; return 1; }
  [ -n "$(ac_meta_get "$f" validated_at)" ] \
    || { AC_QA_RECEIPT_ERROR="runtime gate receipt has no validation timestamp"; return 1; }
  return 0
}

ac_qa_boundary_coherent() {
  # ac_qa_boundary_coherent <tier> <boundary> - the closed tier/boundary table
  # from the QA boundary policy. The tier names the client boundary that
  # stimulated the behavior plus the primary assertion surface, so a `web` tier
  # can never be satisfied by an http receipt and a `workflow` tier can never be
  # satisfied by a plain request.
  case "$1" in
    api)      case "$2" in http|grpc|client-cli|e2e) return 0 ;; esac ;;
    db)       case "$2" in http|grpc|client-cli|workflow|queue|schedule|e2e) return 0 ;; esac ;;
    workflow) case "$2" in workflow|queue|schedule|e2e) return 0 ;; esac ;;
    web)      case "$2" in web|e2e) return 0 ;; esac ;;
  esac
  return 1
}

ac_qa_path_sha() {
  # ac_qa_path_sha <file-or-dir> - content identity for a registered artifact.
  # A directory hashes as a canonical `<relpath> <sha>` manifest so a tree with
  # one changed byte gets a different identity. ONE owner: the receipt writers
  # (ac-qa.sh) and every re-prover (record time, finish gate, verifier
  # reconciliation) must compute the identical identity or tamper detection
  # would refuse honest artifacts.
  local p="$1"
  if [ -d "$p" ]; then
    ( cd "$p" && find . -type f -print | LC_ALL=C sort \
      | while IFS= read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | awk '{print $1}')"; done ) \
      | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 <"$p" | awk '{print $1}'
  fi
}

ac_qa_receipt_path_ok() {
  # ac_qa_receipt_path_ok <run-dir> <case-id> <path> - a boundary receipt is a
  # REGULAR file (never a symlink) whose canonical parent IS this run's own
  # boundaries/<case-id> directory. A textual prefix match admits `..`
  # traversal and symlink escapes; this canonical check is what the recorder,
  # the finish gate, and verifier reconciliation all share.
  local rd="$1" case_id="$2" path="$3"
  python3 - "$rd" "$case_id" "$path" <<'PY'
import os
import sys

rd, case_id, path = sys.argv[1:]
if not rd or not case_id or not path or path == "-":
    raise SystemExit(1)
if os.path.islink(path) or not os.path.isfile(path):
    raise SystemExit(1)
expected = os.path.realpath(os.path.join(rd, "boundaries", case_id))
parent = os.path.realpath(os.path.dirname(path))
raise SystemExit(0 if parent == expected else 1)
PY
}

ac_qa_browser_manifest_ok() {
  # ac_qa_browser_manifest_ok <run-dir> <case-id> <receipt> - re-prove a
  # browser receipt's evidence identity: some manifest in the case's own
  # boundary directory must still hash to the receipt's evidence_sha256, and
  # the case's registered visual must still hash to that manifest's `visual`
  # line. A screenshot or manifest edited after registration refuses.
  local rd="$1" case_id="$2" f="$3" want m cand vsha path rest
  AC_QA_RECEIPT_ERROR=""
  want="$(ac_meta_get "$f" evidence_sha256)"
  m=""
  for cand in "$rd/boundaries/$case_id"/*.manifest; do
    [ -f "$cand" ] || continue
    [ "$(ac_config_sha256 "$cand")" = "$want" ] && { m="$cand"; break; }
  done
  [ -n "$m" ] \
    || { AC_QA_RECEIPT_ERROR="browser evidence manifest for case $case_id is missing or tampered"; return 1; }
  vsha="$(awk '$1=="visual"{print $2}' "$m")"
  [ -n "$vsha" ] \
    || { AC_QA_RECEIPT_ERROR="browser evidence manifest for case $case_id names no visual"; return 1; }
  while IFS="$(printf '\t')" read -r path _ _ rest _; do
    [ "$rest" = "$case_id" ] || continue
    [ -f "$path" ] || continue
    [ "$(ac_qa_path_sha "$path")" = "$vsha" ] && return 0
  done <"$rd/visuals.tsv"
  AC_QA_RECEIPT_ERROR="the registered screenshot for case $case_id no longer matches its browser boundary receipt"
  return 1
}

ac_qa_boundary_receipt_validate() {
  # ac_qa_boundary_receipt_validate <file> <case-id> <tier> <case-status> \
  #     <source-sha> <profile-sha> <runtime-receipt-sha> [<expected-evidence-sha>]
  # One immutable client-boundary execution receipt per terminal behavioral
  # case. Record time and the finish gate call it with the same arguments, so a
  # hand-forged ledger row is refused by exactly the check that admitted the
  # honest one. When the caller re-hashed the registered artifact, the eighth
  # argument makes tampering after receipt publication refuse.
  local f="$1" case_id="$2" tier="$3" status="$4" source_sha="$5" profile_sha="$6" runtime_sha="$7"
  local expected_evidence="${8:-}"
  local boundary driver exit_code
  AC_QA_RECEIPT_ERROR=""
  [ -f "$f" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt is missing: $f"; return 1; }
  [ "$(ac_meta_get "$f" schema)" = "agentcrew.qa-boundary-receipt/v1" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt has the wrong schema"; return 1; }
  [ "$(ac_meta_get "$f" case_id)" = "$case_id" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt names another case id"; return 1; }
  [ "$(ac_meta_get "$f" source_sha)" = "$source_sha" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt binds another source sha"; return 1; }
  [ "$(ac_meta_get "$f" profile_sha256)" = "$profile_sha" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt binds another profile hash"; return 1; }
  [ "$(ac_meta_get "$f" runtime_receipt_sha256)" = "$runtime_sha" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt is not bound to this run's booted runtime"; return 1; }
  boundary="$(ac_meta_get "$f" boundary)"
  case "$boundary" in http|grpc|client-cli|workflow|queue|schedule|web|e2e) ;;
    *) AC_QA_RECEIPT_ERROR="boundary receipt has an unknown boundary '$boundary'"; return 1 ;;
  esac
  ac_qa_boundary_coherent "$tier" "$boundary" \
    || { AC_QA_RECEIPT_ERROR="tier '$tier' cannot be satisfied by boundary '$boundary'"; return 1; }
  driver="$(ac_meta_get "$f" driver)"
  case "$boundary:$driver" in
    web:browser|e2e:e2e) ;;
    web:*|e2e:*) AC_QA_RECEIPT_ERROR="boundary '$boundary' cannot be driven by '$driver'"; return 1 ;;
    *:command) ;;
    *) AC_QA_RECEIPT_ERROR="boundary '$boundary' cannot be driven by '$driver'"; return 1 ;;
  esac
  [ -n "$(ac_meta_get "$f" stimulus_sha256)" ] && [ -n "$(ac_meta_get "$f" evidence_sha256)" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt has no stimulus/evidence identity"; return 1; }
  if [ -n "$expected_evidence" ] && [ "$expected_evidence" != "-" ]; then
    [ "$(ac_meta_get "$f" evidence_sha256)" = "$expected_evidence" ] \
      || { AC_QA_RECEIPT_ERROR="boundary receipt's registered evidence hash no longer matches the artifact on disk (tampered or substituted after publication)"; return 1; }
  fi
  [ -n "$(ac_meta_get "$f" started_at)" ] && [ -n "$(ac_meta_get "$f" completed_at)" ] \
    || { AC_QA_RECEIPT_ERROR="boundary receipt has no execution timestamps"; return 1; }
  if [ "$driver" = e2e ]; then
    [ -n "$(ac_meta_get "$f" upstream_receipt_sha256)" ] \
      && [ "$(ac_meta_get "$f" upstream_receipt_sha256)" != "-" ] \
      || { AC_QA_RECEIPT_ERROR="e2e boundary wrapper binds no upstream receipt"; return 1; }
  fi
  exit_code="$(ac_meta_get "$f" exit_code)"
  case "$exit_code" in ''|*[!0-9]*) AC_QA_RECEIPT_ERROR="boundary receipt has no numeric exit code"; return 1 ;; esac
  [ "$status" != pass ] || [ "$exit_code" = 0 ] \
    || { AC_QA_RECEIPT_ERROR="a passing case cannot bind a non-zero boundary execution (exit $exit_code)"; return 1; }
  return 0
}

ac_qa_gate_matrix() {
  # ac_qa_gate_matrix <manifest.json> <passed-dir> <head-sha> - the Story 4
  # required-profile gate. Returns 0 only when EVERY profile in the task's
  # required set has a PROFILED passing attestation at exactly <head-sha>;
  # returns 1 (with a message) on the first unmet profile. Doc authority:
  # Evidence-and-Merge-Gate bullets (l.449-455) - every required profile has a
  # passing attestation, every attestation matches the exact merge-head SHA and
  # carries the profile hash, and stale/legacy markers cannot satisfy it.
  #  - The marker filename is <sha>.<scope>.<app> (ac-qa.sh cmd_finish); a
  #    required profile_key <project>/<scope>/<app> maps to it by its LAST two
  #    path segments, so a bare or off-head legacy marker matches no key.
  #  - The body must carry a non-empty profile_sha256: a legacy/unprofiled
  #    marker (no hash) cannot satisfy a required-profile manifest.
  #  - A manifest entry may PIN profile_sha256 and/or e2e_sha; when pinned, the
  #    marker's value must match, so a pass for a different profile revision or a
  #    different explicitly requested E2E ref does not satisfy the requirement.
  #    Nothing re-resolves the E2E branch here, so later branch movement does
  #    not retroactively invalidate a recorded result.
  # Requires jq (a bootstrap-required tool); a present-but-empty or malformed
  # manifest fails CLOSED rather than merging against an undefined set.
  local manifest="$1" dir="$2" sha="$3"
  local rows n=0 key want_psha want_e2e app rest scope marker satisfied=""
  rows="$(jq -r '.required_profiles[]? | [.profile_key // "", .profile_sha256 // "", .e2e_sha // ""] | @tsv' "$manifest" 2>/dev/null)" || rows=""
  if [ -z "$rows" ]; then
    ac_warn "qa.require_for_ship: the task's required-profile manifest is empty or unreadable ($manifest) - refusing rather than merging against an undefined required set"
    return 1
  fi
  while IFS=$'\t' read -r key want_psha want_e2e; do
    [ -n "$key" ] || { ac_warn "qa.require_for_ship: a required-profile manifest entry has no profile_key ($manifest) - refusing rather than guessing which profile it means"; return 1; }
    n=$((n + 1))
    # profile_key is <project>/<scope>/<app>; the marker is keyed <sha>.<scope>.<app>.
    app="${key##*/}"; rest="${key%/*}"; scope="${rest##*/}"
    case "$scope" in ''|*[!A-Za-z0-9_-]*) ac_warn "qa.require_for_ship: required profile '$key' does not parse to <project>/<scope>/<app> (scope segment invalid) - fix the task manifest"; return 1 ;; esac
    case "$app" in ''|*[!A-Za-z0-9_-]*) ac_warn "qa.require_for_ship: required profile '$key' does not parse to <project>/<scope>/<app> (app segment invalid) - fix the task manifest"; return 1 ;; esac
    marker="$dir/$sha.$scope.$app"
    if [ ! -f "$marker" ]; then
      ac_warn "qa.require_for_ship: required profile '$key' has no passing crew-qa attestation for ${sha:0:12} - run crew-qa for EVERY required profile at this head before merging"
      return 1
    fi
    if ! ac_qa_attestation_parse "$marker" "$sha" "$scope" "$app" "$want_psha" "$want_e2e"; then
      ac_warn "qa.require_for_ship: the attestation for '$key' is invalid ($AC_QA_ATTESTATION_ERROR) - re-run crew-qa for this exact profile and head"
      return 1
    fi
    satisfied="$satisfied $key"
  done <<EOF
$rows
EOF
  printf 'qa: all %s required profile(s) satisfied for %s:%s\n' "$n" "${sha:0:12}" "$satisfied"
  return 0
}

ac_qa_gate_ok() {
  # ac_qa_gate_ok <project-repo> <head-sha> [<task-id>] - the qa.require_for_ship
  # merge gate. Returns 0 when the gate is NOT enforced, or a passing crew-qa run
  # is on record for <head-sha>; returns 1 (with a message) when the project
  # requires qa and no passing run exists for exactly that commit.
  # When <task-id> names a task that recorded a required-profile manifest
  # (data/<family>/qa/manifest.json), the gate adjudicates the whole required SET
  # via ac_qa_gate_matrix instead of accepting any one passing scope/app pair -
  # the manifest's mere presence selects that arm. Absent a manifest (every flat
  # project, and any task that declared no required set) behavior is UNCHANGED.
  # The mode is read TWO-SIDED (map + yaml), like ac-qa.sh start, so a
  # half-migrated project refuses at BOTH ends instead of silently accepting a
  # marker that proves nothing. On a scoped project a bare sha-only marker
  # NEVER satisfies the gate; on a flat project it remains the whole truth.
  # Callers must source ac-pipeline-lib.sh alongside ac-lib.sh: the yaml side
  # reads ac_yaml_has, which lives there.
  # Enforcement is ac_qa_required (policy read from the merge target); the pass
  # attestation is the durable marker ac-qa.sh finish writes to
  # <main>/.crew/qa/passed/<sha>. Binding to the exact head is what refuses a
  # DRIFTED head: a pass recorded for an old sha has no marker under the new
  # sha, so the gate refuses. Callers that cannot guarantee a resolved head
  # (ac-pr-merge.sh) MUST gate on ac_qa_required first and refuse an
  # unresolvable head themselves - this function trusts <head-sha> as given.
  local repo="$1" sha="$2" task="${3:-}" main dir cfg map_scoped yaml_scoped rc=0
  local m base rest scope app pairs="" skipped="" manifest
  ac_qa_required "$repo" || return 0
  main="$(ac_repo_root "$repo")" || main="$repo"
  dir="$main/.crew/qa/passed"

  # Required-profile matrix arm (Story 4): the task's manifest, when present,
  # SELECTS the set gate and short-circuits the two-sided read below - a
  # manifest declares scoped profiles, and the matrix requires <sha>.<scope>.<app>
  # markers directly, so a bare marker is never accepted and the mode-mismatch
  # concern does not arise. A malformed/empty manifest fails closed inside it.
  if [ -n "$task" ]; then
    manifest="$(ac_data_dir)/$(ac_family_of_id "$task")/qa/manifest.json"
    if [ -f "$manifest" ]; then
      ac_qa_gate_matrix "$manifest" "$dir" "$sha"
      return
    fi
  fi

  # FAIL-CLOSED BY CONSTRUCTION, not by comment. The yaml side below reads
  # ac_yaml_has, which lives in ac-pipeline-lib.sh; in a caller that sourced
  # only ac-lib.sh, `ac_yaml_has ... && yaml_scoped=1` is a command-not-found
  # INSIDE an &&-list - errexit does not catch it, and rc=127 is
  # indistinguishable from "the yaml declares no scopes". With no scope map
  # either, that steers a SCOPED project into the FLAT arm, where a bare
  # sha-only marker satisfies the gate: precisely the fail-open the two-sided
  # read exists to refuse, at the last gate before a merge. Both merge helpers
  # source the sibling and say why; this makes the gate itself prove it,
  # because a caller's sourcing discipline is not something a gate may assume.
  command -v ac_yaml_has >/dev/null 2>&1 || {
    ac_warn "qa.require_for_ship: this merge gate cannot read the project yaml - its caller sourced ac-lib.sh WITHOUT its sibling ac-pipeline-lib.sh, so the scoped/flat mode cannot be determined. Refusing the merge rather than reading an unbound command as 'no scopes'. Fix the caller: source bin/ac-pipeline-lib.sh after bin/ac-lib.sh."
    return 1
  }

  # TWO-SIDED, at the gate, because a map-only reading is fail-OPEN under
  # partial migration: with qa.scopes in the yaml and the map absent or
  # unreadable, it would classify the project FLAT and accept a legacy bare
  # marker - defeating the whole point in precisely the state a migration
  # passes through, and at the last gate.
  map_scoped="$(ac_knowledge_scopes "$repo" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    ac_warn "qa.require_for_ship: the project's scope map is AMBIGUOUS (two live entries for one scope, or a malformed line) - refusing the merge rather than guessing which profile a marker proves. Fix it with bin/ac-know.sh scope-proposal, then re-run: bin/ac-know.sh verify"
    return 1
  fi
  # PRESENCE, not children: an empty `qa.scopes:` block is a half-authored
  # migration, and reading it as absent lands this gate in the FLAT arm, where
  # a bare sha-only marker is accepted - the very state two-sided detection
  # exists to refuse.
  yaml_scoped=0
  if cfg="$(ac_project_config_file "$repo" 2>/dev/null)"; then
    ac_yaml_has "$cfg" qa.scopes && yaml_scoped=1
  fi

  if [ -z "$map_scoped" ] && [ "$yaml_scoped" = 0 ]; then
    # FLAT still uses the bare filename, but its body is a complete v2 receipt.
    if [ -f "$dir/$sha" ] && ac_qa_attestation_parse "$dir/$sha" "$sha" "" ""; then
      return 0
    fi
    [ ! -f "$dir/$sha" ] \
      || ac_warn "qa.require_for_ship: ignored invalid flat QA attestation for ${sha:0:12}: $AC_QA_ATTESTATION_ERROR"
    ac_warn "qa.require_for_ship: no passing crew-qa run recorded for ${sha:0:12} - run crew-qa on this head before merging"
    return 1
  fi
  if [ -z "$map_scoped" ] || [ "$yaml_scoped" = 0 ]; then
    if [ -z "$map_scoped" ]; then
      ac_warn "qa.require_for_ship: MODE MISMATCH - the fleet-home config declares scopes but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge."
    else
      ac_warn "qa.require_for_ship: MODE MISMATCH - the repo-knowledge record declares scopes but the fleet-home config carries no qa.scopes block, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge."
    fi
    return 1
  fi

  # SCOPED. A candidate must clear THREE tests before it counts, and one that
  # fails any of them can never satisfy the gate: a regular FILE (-f, not -e,
  # so a directory left by an aborted write is not an attestation), EXACTLY
  # two components, and both inside the declared name grammar. Because no
  # legal scope or app name may contain a dot, "one dot" is a total parse.
  # A failing candidate is SKIPPED and NAMED: a stray file must not be able to
  # block a merge that has a genuine pair beside it, and it must not be able
  # to authorise one either. Both halves are load-bearing.
  for m in "$dir/$sha".*; do
    [ -f "$m" ] || continue
    base="$(basename "$m")"
    rest="${base#"$sha".}"
    case "$rest" in
      *.*.*) skipped="$skipped $base"; continue ;;
      *.*) ;;
      *) skipped="$skipped $base"; continue ;;
    esac
    scope="${rest%%.*}"; app="${rest#*.}"
    case "$scope" in ''|*[!A-Za-z0-9_-]*) skipped="$skipped $base"; continue ;; esac
    case "$app" in ''|*[!A-Za-z0-9_-]*) skipped="$skipped $base"; continue ;; esac
    if ac_qa_attestation_parse "$m" "$sha" "$scope" "$app"; then
      pairs="$pairs $scope/$app"
    else
      skipped="$skipped $base($AC_QA_ATTESTATION_ERROR)"
    fi
  done
  if [ -n "$pairs" ]; then
    # Coverage is PRINTED, never adjudicated: deciding which scopes a head
    # OUGHT to cover means knowing which scopes it changed, which is diff
    # derivation, which this system does not do. The chief and captain judge.
    printf 'qa: passed profiles for %s:%s
' "${sha:0:12}" "$pairs"
    return 0
  fi
  ac_warn "qa.require_for_ship: no passing crew-qa run recorded for ${sha:0:12} on this SCOPED project - a run must name the scope+app it proved.$([ -f "$dir/$sha" ] && printf ' A bare sha-only marker IS on disk; it names no scope+app, so it proves nothing about WHICH profile ran and cannot satisfy the gate here - re-run crew-qa naming the scope and app.')${skipped:+ Malformed markers ignored:$skipped}"
  return 1
}

