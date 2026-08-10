#!/usr/bin/env bash
# ac-project-mode.test.sh - the registry answers YOLO ONLY (captain order
# 2026-08-10: delivery mode is per-task, resolved from the backlog row's
# contract pin / --mode by ac-brief.sh - never from records/projects.md).
# A legacy [<mode>] bracket is tolerated, ignored content: old registries
# keep resolving yolo without a migration, and a bogus legacy mode is not
# an error any more because the field carries no authority to misuse.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
cat >"$AC_HOME/records/projects.md" <<'REG'
- alpha [direct-pr] - legacy mode bracket, no yolo (added 2026-07-13)
- beta [local-only +yolo] - legacy mode bracket with yolo (added 2026-07-13)
- gamma [+yolo] - the new bracket shape (added 2026-08-10)
- delta [bogus-mode] - a legacy mode nobody validates now (added 2026-07-13)
- plain - no bracket at all (added 2026-08-10)
REG

assert_eq "$("$BIN/ac-project-mode.sh" alpha)" "yolo=off" "legacy mode bracket is ignored"
assert_eq "$("$BIN/ac-project-mode.sh" beta)" "yolo=on" "+yolo read out of a legacy bracket"
assert_eq "$("$BIN/ac-project-mode.sh" gamma)" "yolo=on" "the new [+yolo]-only bracket"
assert_eq "$("$BIN/ac-project-mode.sh" delta)" "yolo=off" "a bogus legacy mode is dead content, not an error"
assert_eq "$("$BIN/ac-project-mode.sh" plain)" "yolo=off" "a bracketless line defaults yolo off"
assert_eq "$("$BIN/ac-project-mode.sh" unregistered)" "yolo=off" "an unregistered project defaults yolo off"
out="$("$BIN/ac-project-mode.sh" alpha)"
case "$out" in *mode=*) fail "the registry must not answer mode any more (got: $out)" ;; esac

# The interim-layout migration is RETIRED (audit-f7): records/ is the ONE
# registry location - a record at the data/ root or data/records/ is never
# read, never moved, never overwrites the records/ copy.
rm -f "$AC_HOME/records/projects.md"
printf -- '- legacy [+yolo] - pre-split registry (added 2026-07-13)\n' >"$AC_HOME/data/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" legacy)" "yolo=off" "a data/-root registry is not read: the default answers"
assert_file "$AC_HOME/data/projects.md" "and it is not moved either - the migration is retired"

mkdir -p "$AC_HOME/data/records"
printf -- '- interim [+yolo] - interim-layout registry (added 2026-07-17)\n' >"$AC_HOME/data/records/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" interim)" "yolo=off" "an interim data/records/ registry is not read either"

printf -- '- realrow [+yolo] - the one live registry (added 2026-07-29)\n' >"$AC_HOME/records/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" realrow)" "yolo=on" "the records/ copy is the only one consulted"
rm -f "$AC_HOME/data/projects.md" "$AC_HOME/data/records/projects.md"

# --- AC12: scope data never disturbs the registry parser ---------------------
# The repo-knowledge record is a SIDECAR file, so the registry line the yolo
# parser reads is byte-identical whether the project carries scope data or
# not. Vacuous today by construction - and that is exactly what it guards: the
# day someone moves scope data back onto a registry line, this reds.
rm -f "$AC_HOME/data/projects.md" "$AC_HOME/records/projects.md"
cat >"$AC_HOME/records/projects.md" <<'REG'
- scoped [+yolo] - a monorepo with scopes (added 2026-07-21)
- flat - a single-app repo (added 2026-07-21)
REG
before="$("$BIN/ac-project-mode.sh" scoped)"
mkdir -p "$AC_HOME/records/repo-knowledge"
cat >"$AC_HOME/records/repo-knowledge/scoped.md" <<'RK'
# Repo knowledge: scoped

- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam
- scope cedar = cedar-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam

## Superseded
RK
assert_eq "$("$BIN/ac-project-mode.sh" scoped)" "$before" "scope data leaves the yolo answer untouched"
assert_eq "$("$BIN/ac-project-mode.sh" scoped)" "yolo=on" "the registry line still resolves in full"
assert_eq "$("$BIN/ac-project-mode.sh" flat)" "yolo=off" "a sibling project is unaffected"

pass
