#!/usr/bin/env bash
# ac-bun.test.sh - bin/ac-bun.sh's ac_bun_exec: a module started under bun
# gets the caller's physical cwd as its first argument and runs in the distro
# root, and nothing of the caller's own bun configuration reaches it - no cwd
# .env, bunfig.toml (whose preload runs code) or tsconfig paths, no BUN_* or
# JSC_* knob. A write to a closed stdout or stderr fails in the module as it
# failed in the bash original, unless that original ran without errexit. Its
# hook form, ac_bun_exec_hook, starts a module the same way, a closed channel
# left to bun, and answers only the module's 0 or 2, every other ending the
# hook's no-op.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# --- a closed channel: bun would open /dev/null read-write over it -----------
# fd.ts <caller> <report> writes to fd 1 and fd 2 and reads fd 0, then reports
# each outcome; src/guard.ts is the same probe under a name whose original ran
# without errexit, so its closed channels stay bun's.
cat >"$distro/src/fd.ts" <<'EOF'
import { readSync, writeFileSync, writeSync } from "node:fs";
const r: string[] = [];
for (const fd of [1, 2]) {
  try {
    writeSync(fd, "x");
    r.push(`${fd}=ok`);
  } catch (e) {
    r.push(`${fd}=${(e as { code?: string }).code}`);
  }
}
try {
  r.push(`0=${readSync(0, Buffer.alloc(1))}`);
} catch (e) {
  r.push(`0=${(e as { code?: string }).code}`);
}
writeFileSync(process.argv[3], r.join(" "));
EOF
cp "$distro/src/fd.ts" "$distro/src/guard.ts"
for m in fd guard; do
  sed "s|src/probe.ts|src/$m.ts|" "$distro/bin/ac-probe.sh" >"$distro/bin/ac-$m.sh"
  chmod +x "$distro/bin/ac-$m.sh"
done
fdrun() {  # fdrun <shim> <closes> - the probe's report with those fds closed
  : >"$TMP/fd.out"
  bash -c "exec $2; exec \"\$0\" \"\$1\"" "$distro/bin/$1" "$TMP/fd.out" </dev/null >/dev/null 2>/dev/null
  cat "$TMP/fd.out"
}
assert_eq "$(fdrun ac-fd.sh '')" "1=ok 2=ok 0=0" "open channels reach the module as they are"
assert_eq "$(fdrun ac-fd.sh '1>&-')" "1=EBADF 2=ok 0=0" "a write to a closed stdout fails, as the original's printf did"
assert_eq "$(fdrun ac-fd.sh '2>&-')" "1=ok 2=EBADF 0=0" "a write to a closed stderr fails, as the original's printf did"
assert_eq "$(fdrun ac-fd.sh '1>&- 2>&-')" "1=EBADF 2=EBADF 0=0" "both channels closed: both writes fail"
assert_eq "$(fdrun ac-fd.sh '0<&-')" "1=ok 2=ok 0=0" "a closed stdin stays bun's /dev/null, read as at EOF"
assert_eq "$(fdrun ac-guard.sh '1>&- 2>&-')" "1=ok 2=ok 0=0" "a module whose original ran without errexit keeps bun's /dev/null"

# --- ac_bun_exec_hook: a harness hook's start, which fails open --------------
# A hook's 2 is its refusal, so only the module's own 0 or 2 may come back; a
# missing bun, a module that cannot load and a crash are all the hook's no-op.
for m in probe broken; do
  cat >"$distro/bin/ac-hook-$m.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$(dirname "\${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec_hook src/hook-$m.ts "\$@"
EOF
  chmod +x "$distro/bin/ac-hook-$m.sh"
done
cat >"$distro/src/hook-probe.ts" <<'EOF'
import { readFileSync, writeSync } from "node:fs";
const [, , caller, mode = "0"] = process.argv;
if (mode === "throw") throw new Error("hook probe threw");
if (mode === "signal") {
  process.kill(process.pid, "SIGTERM");
  await Bun.sleep(5000);
  process.exit(2);
}
const env = Object.keys(process.env).filter((k) => /^(BUN_|JSC_|PROBE_)/.test(k)).sort();
writeSync(1, JSON.stringify({ caller, cwd: process.cwd(), env, stdin: readFileSync(0, "utf8") }));
writeSync(2, `hook said ${mode}`);
process.exit(Number(mode));
EOF
printf 'const x = ;\n' >"$distro/src/hook-broken.ts"

out="$(cd "$trap_dir" && printf '{"tool_name":"Task"}' \
  | BUN_OPTIONS="--preload=$trap_dir/p.ts" BUN_PROBE=1 JSC_dumpOptions=1 "$distro/bin/ac-hook-probe.sh" 2>/dev/null)"
assert_eq "$out" "{\"caller\":\"$caller\",\"cwd\":\"$root\",\"env\":[],\"stdin\":\"{\\\"tool_name\\\":\\\"Task\\\"}\"}" \
  "a hook module is started as any module is, its payload on stdin"

for m in 0 2; do
  rc=0
  err="$(printf '' | "$distro/bin/ac-hook-probe.sh" "$m" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "$m" "the module's own $m is the hook's answer"
  assert_eq "$err" "hook said $m" "the module's stderr reaches the harness as written ($m)"
done
rc=0
printf '' | bash -c 'exec 1>&- 2>&-; exec "$0" 2' "$distro/bin/ac-hook-probe.sh" || rc=$?
assert_eq "$rc" "2" "a hook's refusal survives closed channels, as the original's lost printf left its exit 2"
for m in 1 3 125 255 throw signal; do
  rc=0
  printf '' | "$distro/bin/ac-hook-probe.sh" "$m" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "a hook module ending $m is the hook's no-op, never a refusal"
done
rc=0
err="$(printf '{"tool_name":"Task"}' | "$distro/bin/ac-hook-broken.sh" 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "0" "a hook module that cannot load is the hook's no-op"
[ -n "$err" ] || fail "a hook module that cannot load leaves bun's own diagnosis on stderr"

rc=0
out="$(printf '{"tool_name":"Task"}' | PATH="$TMP/nobun" "$distro/bin/ac-hook-probe.sh" 2 2>"$TMP/nobun.err")" || rc=$?
assert_eq "$rc" "0" "no bun on PATH is the hook's no-op"
assert_eq "$out$(cat "$TMP/nobun.err")" "" "no bun on PATH: the hook says nothing"

pass
