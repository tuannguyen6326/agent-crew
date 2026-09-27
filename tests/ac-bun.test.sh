#!/usr/bin/env bash
# ac-bun.test.sh - bin/ac-bun.sh's ac_bun_exec: a module started under bun
# gets the caller's physical cwd as its first argument and runs in the distro
# root, and nothing of the caller's own bun configuration reaches it - no cwd
# .env, bunfig.toml (whose preload runs code) or tsconfig paths, no BUN_* or
# JSC_* knob.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

distro="$TMP/distro"
mkdir -p "$distro/bin" "$distro/src"
cp "$BIN/ac-bun.sh" "$distro/bin/"
cat >"$distro/bin/ac-probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/probe.ts "$@"
EOF
chmod +x "$distro/bin/ac-probe.sh"
cat >"$distro/src/probe.ts" <<'EOF'
const env = Object.keys(process.env).filter((k) => /^(BUN_|JSC_|PROBE_)/.test(k)).sort();
console.log(JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd(), env }));
EOF
root="$(cd "$distro" && pwd -P)"

trap_dir="$TMP/caller"
mkdir -p "$trap_dir"
printf 'PROBE_DOTENV=leaked\n' >"$trap_dir/.env"
printf 'console.log("PRELOAD");\n' >"$trap_dir/p.ts"
printf 'preload = ["./p.ts"]\n' >"$trap_dir/bunfig.toml"
printf '{"compilerOptions":{"paths":{"*":["./p.ts"]}}}\n' >"$trap_dir/tsconfig.json"
caller="$(cd "$trap_dir" && pwd -P)"

out="$(cd "$trap_dir" && BUN_OPTIONS="--preload=$trap_dir/p.ts" BUN_PROBE=1 JSC_dumpOptions=1 "$distro/bin/ac-probe.sh" a -- 'b c' 2>&1)"
assert_eq "$out" "{\"argv\":[\"$caller\",\"a\",\"--\",\"b c\"],\"cwd\":\"$root\",\"env\":[]}" \
  "the module runs in the distro root with the caller's cwd first and no caller bun config"

home="$TMP/home-link"
mkdir -p "$home"
ln -s "$distro/bin" "$home/bin"
out="$(cd "$trap_dir" && "$home/bin/ac-probe.sh" x 2>&1)"
assert_eq "$out" "{\"argv\":[\"$caller\",\"x\"],\"cwd\":\"$root\",\"env\":[]}" \
  "through a fleet home's symlinked bin/ the root is still the distro's"

gone="$TMP/gone"
mkdir -p "$gone"
out="$(cd "$gone" && rmdir "$gone" && "$distro/bin/ac-probe.sh" 2>/dev/null)"
assert_eq "$out" "{\"argv\":[\"\"],\"cwd\":\"$root\",\"env\":[]}" "a cwd with no name arrives as an empty first argument"

mkdir -p "$TMP/nobun"
for t in bash env dirname; do ln -s "$(command -v "$t")" "$TMP/nobun/$t"; done
rc=0
err="$(PATH="$TMP/nobun" "$distro/bin/ac-probe.sh" 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "1" "no bun on PATH fails the entry"
assert_eq "$err" "ERROR: required tool not found: bun" "no bun on PATH names the missing tool"

pass
