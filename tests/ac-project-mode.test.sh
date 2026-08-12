#!/usr/bin/env bash
# ac-project-mode.test.sh - delivery-mode resolution from records/projects.md:
# defaults, explicit modes, +yolo flag, unknown-mode rejection; a registry
# left at a legacy spot (data/records/ or the data/ root) is auto-migrated
# into records/ on resolve, and a stale legacy copy never overwrites.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
cat >"$AC_HOME/records/projects.md" <<'EOF'
- alpha [direct-pr] - a project (added 2026-07-13)
- beta [local-only +yolo] - another (added 2026-07-13)
- gamma [crew-ship] - a third (added 2026-07-13)
- delta [bogus-mode] - broken (added 2026-07-13)
- epsilon [retired-mode] - removed mode must now be rejected (added 2026-07-13)
EOF

assert_eq "$("$BIN/ac-project-mode.sh" alpha)" "mode=direct-pr yolo=off" "explicit mode"
assert_eq "$("$BIN/ac-project-mode.sh" beta)" "mode=local-only yolo=on" "yolo flag"
assert_eq "$("$BIN/ac-project-mode.sh" gamma)" "mode=crew-ship yolo=off" "crew-ship"
assert_eq "$("$BIN/ac-project-mode.sh" unregistered)" "mode=crew-ship yolo=off" "default mode"
assert_fails "$BIN/ac-project-mode.sh" epsilon
assert_fails "$BIN/ac-project-mode.sh" delta

# The interim-layout migration is RETIRED (audit-f7: every fleet home was
# verified clean, and the per-call sweep cost 10 stats x 47 call sites).
# records/ is the ONE registry location: a record still sitting at the data/
# root or the interim data/records/ is never read, never moved, and never
# overwrites the records/ copy.
rm -f "$AC_HOME/records/projects.md"
printf -- '- legacy [direct-pr] - pre-split registry (added 2026-07-13)\n' >"$AC_HOME/data/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" legacy)" "mode=crew-ship yolo=off" "a data/-root registry is not read: the default answers"
assert_file "$AC_HOME/data/projects.md" "and it is not moved either - the migration is retired"

mkdir -p "$AC_HOME/data/records"
printf -- '- interim [direct-pr] - interim-layout registry (added 2026-07-17)\n' >"$AC_HOME/data/records/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" interim)" "mode=crew-ship yolo=off" "an interim data/records/ registry is not read either"

printf -- '- realrow [direct-pr] - the one live registry (added 2026-07-29)\n' >"$AC_HOME/records/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" realrow)" "mode=direct-pr yolo=off" "the records/ copy is the only one consulted"
rm -f "$AC_HOME/data/projects.md" "$AC_HOME/data/records/projects.md"

# --- AC12: scope data never disturbs the registry parser ---------------------
# The repo-knowledge record is a SIDECAR file, so the registry line the mode
# parser reads is byte-identical whether the project carries scope data or
# not. Vacuous today by construction - and that is exactly what it guards: the
# day someone moves scope data back onto a registry line, this reds.
rm -f "$AC_HOME/data/projects.md" "$AC_HOME/records/projects.md"
cat >"$AC_HOME/records/projects.md" <<'EOF'
- scoped [local-only +yolo] - a monorepo with scopes (added 2026-07-21)
- flat [direct-pr] - a single-app repo (added 2026-07-21)
EOF
before="$("$BIN/ac-project-mode.sh" scoped)"
mkdir -p "$AC_HOME/records/repo-knowledge"
cat >"$AC_HOME/records/repo-knowledge/scoped.md" <<'EOF'
# Repo knowledge: scoped

- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam
- scope cedar = cedar-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam

## Superseded
EOF
assert_eq "$("$BIN/ac-project-mode.sh" scoped)" "$before" "scope data leaves the delivery mode untouched"
assert_eq "$("$BIN/ac-project-mode.sh" scoped)" "mode=local-only yolo=on" "the registry line still resolves in full"
assert_eq "$("$BIN/ac-project-mode.sh" flat)" "mode=direct-pr yolo=off" "a sibling project is unaffected"

pass
