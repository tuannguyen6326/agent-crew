#!/usr/bin/env bash
# ac-scripts-doc.test.sh - docs/scripts.md is the map of bin/ and src/, and a
# hand-kept map drifts silently: every bin/ entry has a row, every src/ module
# is named somewhere on it, a shim's row names the module it execs, and no row
# names a file that is gone. Negative cases prove each rule bites.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# map_drift <root> - one line per violation in <root>/docs/scripts.md, nothing
# when the map matches <root>/bin and <root>/src.
map_drift() {
  local root="$1" doc="$1/docs/scripts.md" f b m n
  for f in "$root"/bin/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    grep -q "^| \`$b[ \`]" "$doc" || echo "no row: bin/$b"
  done
  for f in "$root"/src/*.ts; do
    [ -f "$f" ] || continue
    grep -qF "\`src/$(basename "$f")" "$doc" || echo "never named: src/$(basename "$f")"
  done
  for f in "$root"/bin/*.sh; do
    m="$(sed -n 's|^ac_bun_exec\(_hook\)\{0,1\} \(src/[a-z0-9-]*\.ts\) "\$@"$|\2|p' "$f" | head -n 1)"
    [ -n "$m" ] || continue
    b="$(basename "$f")"
    grep -qF "\`$m" <<<"$(grep "^| \`$b[ \`]" "$doc")" || echo "shim row misses its module: bin/$b -> $m"
  done
  grep -o '^| `[^` ]*' "$doc" | sed 's/^| `//' | sort -u | while IFS= read -r n; do
    case "$n" in src/*) [ -e "$root/$n" ] ;; *) [ -e "$root/bin/$n" ] ;; esac || echo "stale row: $n"
  done
}

assert_eq "$(map_drift "$ROOT")" "" "docs/scripts.md maps bin/ and src/ exactly"

# Each rule bites on a minimal map.
fx="$TMP/scripts-doc"
mkdir -p "$fx/bin" "$fx/src" "$fx/docs"
printf '#!/usr/bin/env bash\nac_bun_exec src/shimmed.ts "$@"\n' >"$fx/bin/ac-shim.sh"
: >"$fx/bin/ac-plain.sh"
: >"$fx/src/shimmed.ts"
: >"$fx/src/lib.ts"
cat >"$fx/docs/scripts.md" <<'EOF'
| `ac-shim.sh <id>` | Spec: `src/shimmed.ts` header. |
| `ac-plain.sh` | Spec: `bin/ac-plain.sh` header. |
| `src/lib.ts` | Shared library. |
EOF
assert_eq "$(map_drift "$fx")" "" "the fixture map starts clean"
: >"$fx/bin/ac-new.sh"
assert_contains "$(map_drift "$fx")" "no row: bin/ac-new.sh" "an entry with no row is caught"
rm "$fx/bin/ac-new.sh"
: >"$fx/src/orphan.ts"
assert_contains "$(map_drift "$fx")" "never named: src/orphan.ts" "a module named nowhere is caught"
rm "$fx/src/orphan.ts"
sed -i.bak 's/Spec: `src\/shimmed.ts` header/Spec: `bin\/ac-shim.sh` header/' "$fx/docs/scripts.md"
printf '| `src/shimmed.ts` | named elsewhere |\n' >>"$fx/docs/scripts.md"
assert_contains "$(map_drift "$fx")" "shim row misses its module: bin/ac-shim.sh -> src/shimmed.ts" "a shim row pointing at the shim's own header is caught"
mv "$fx/docs/scripts.md.bak" "$fx/docs/scripts.md"
rm "$fx/bin/ac-plain.sh"
assert_contains "$(map_drift "$fx")" "stale row: ac-plain.sh" "a row for a removed entry is caught"

pass
