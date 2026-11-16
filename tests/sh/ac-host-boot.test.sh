#!/usr/bin/env bash
# ac-host-boot.test.sh - bin/ac-host-boot.sh's own contract: this host's
# current boot-session TOKEN, verbatim, or `unknown`. Every case stubs
# `uname` (and `sysctl` for the macOS path) on PATH so no assertion here
# depends on this host's real OS or boot session - the test seam the brief
# requires, and the same technique tests/sh/ac-host-slept.test.sh already
# uses for its own uname/pmset dispatch. The token is NEVER parsed as a
# number or a time by the caller (src/learn.ts compares it for equality
# only) - this file proves PASSTHROUGH and the fail-closed paths, never a
# numeric format.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

SCRIPT="$BIN/ac-host-boot.sh"
assert_file "$SCRIPT" "ac-host-boot.sh must exist"
BASH_BIN="$(command -v bash)"

run_check() {
  # run_check - the script's one output line, under a PATH that carries
  # whatever stub this case installed ahead of the real one.
  "$BASH_BIN" "$SCRIPT"
}

stub="$TMP/stub"
mkdir -p "$stub"

darwin_uname() {
  printf '#!/usr/bin/env bash\necho Darwin\n' >"$stub/uname"
  chmod +x "$stub/uname"
}

# Every real directory on $PATH that actually holds a `sysctl` binary,
# excluded - never just a hardcoded /usr/sbin: a "missing sysctl" case that
# still finds the HOST'S OWN real sysctl further down $PATH would prove
# nothing (a real sysctl on this exact macOS host answers kern.bootsessionuuid
# correctly, same as the stub would). env's and bash's own directories stay
# in, so the stub script's `#!/usr/bin/env bash` shebang still resolves.
no_sysctl_path() {
  local d result=""
  IFS=: read -ra __dirs <<<"$PATH"
  for d in "${__dirs[@]}"; do
    [ -x "$d/sysctl" ] && continue
    result="${result:+$result:}$d"
  done
  printf '%s:%s\n' "$stub" "$result"
}

# --- macOS: a well-formed sysctl answer is passed through VERBATIM --------
darwin_uname
printf '#!/usr/bin/env bash\nprintf "00000000-0000-4000-8000-000000000001\\n"\n' >"$stub/sysctl"
chmod +x "$stub/sysctl"
out="$(PATH="$stub:$PATH" run_check)"
assert_eq "$out" "00000000-0000-4000-8000-000000000001" "a well-formed kern.bootsessionuuid answer must pass through verbatim"

# --- macOS: no sysctl reachable at all ---------------------------------------
rm -f "$stub/sysctl"
out="$(PATH="$(no_sysctl_path)" run_check)"
assert_eq "$out" "unknown" "no sysctl on PATH must fail closed to unknown"

# --- macOS: sysctl present but failing ---------------------------------------
printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/sysctl"
chmod +x "$stub/sysctl"
out="$(PATH="$stub:$PATH" run_check)"
assert_eq "$out" "unknown" "a failing sysctl must fail closed to unknown"

# --- macOS: sysctl succeeds, empty output ------------------------------------
printf '#!/usr/bin/env bash\ntrue\n' >"$stub/sysctl"
chmod +x "$stub/sysctl"
out="$(PATH="$stub:$PATH" run_check)"
assert_eq "$out" "unknown" "empty sysctl output is no evidence - unknown, not a guess"

# --- macOS: sysctl prints more than one line - not a single token ----------
printf '#!/usr/bin/env bash\nprintf "line-one\\nline-two\\n"\n' >"$stub/sysctl"
chmod +x "$stub/sysctl"
out="$(PATH="$stub:$PATH" run_check)"
assert_eq "$out" "unknown" "multi-line output is not a single token - unknown, never the first line guessed"

# --- macOS: a source that literally answers "unknown" collapses into the
#     same sentinel the probe itself uses for no-evidence - the caller
#     (src/learn.ts's hostBootToken) must never mistake it for a real token --
printf '#!/usr/bin/env bash\nprintf "unknown\\n"\n' >"$stub/sysctl"
chmod +x "$stub/sysctl"
out="$(PATH="$stub:$PATH" run_check)"
assert_eq "$out" "unknown" "a literal 'unknown' answer stays unknown, never mistaken for a real token"

# --- unrecognised OS: unknown even with a perfectly good sysctl on PATH -----
printf '#!/usr/bin/env bash\nprintf "00000000-0000-4000-8000-000000000001\\n"\n' >"$stub/sysctl"
chmod +x "$stub/sysctl"
printf '#!/usr/bin/env bash\necho SunOS\n' >"$stub/uname"
chmod +x "$stub/uname"
out="$(PATH="$stub:$PATH" run_check)"
assert_eq "$out" "unknown" "an unrecognised OS must fail closed to unknown regardless of sysctl"
rm -f "$stub/uname" "$stub/sysctl"

# --- Linux: the real /proc/sys/kernel/random/boot_id on an ACTUAL Linux
#     host, unstubbed -------------------------------------------------------
# /proc/sys/kernel/random/boot_id is a kernel-exposed path, not a
# PATH-resolved command, so unlike the macOS branch above it cannot be faked
# with a synthetic fixture; this case only proves the read against whatever
# real boot_id this host's own kernel reports, and is a no-op everywhere else.
if [ "$(uname -s 2>/dev/null)" = Linux ]; then
  out="$(run_check)"
  case "$out" in
    ????????-????-????-????-????????????) : ;;
    *) fail "a real Linux host with a readable boot_id must report its UUID, got: $out" ;;
  esac
else
  : # nothing to prove here on a non-Linux host; the dispatch is covered by
    # the stubbed-uname "unrecognised OS" case above.
fi

pass
