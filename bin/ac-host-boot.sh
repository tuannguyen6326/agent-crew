#!/usr/bin/env bash
# ac-host-boot.sh - the ONE check for this host's current BOOT SESSION, as an
# opaque token. src/learn.ts's suite-inflight reclaim compares it against the
# token a run recorded at its own launch: a run from an EARLIER boot session
# cannot be the process its pane now holds, however that pane answers.
#
# A WALL-CLOCK TIMESTAMP (sysctl kern.boottime / proc/stat btime) was tried
# first and rejected: that field is adjusted forward whenever the system
# clock itself is stepped (an NTP correction, a sleep/wake clock fixup) -
# with no reboot at all - which would let a clock jump reclaim a run that is
# genuinely still going, the one outcome this path must never produce. A
# boot-session TOKEN, minted once by the kernel at boot and never touched by
# a later clock change, has no such failure mode - it is only ever compared
# for equality, never arithmetic. macOS (`sysctl -n kern.bootsessionuuid`)
# and Linux (`/proc/sys/kernel/random/boot_id`, man random(4): "a random ID
# that is regenerated on every boot") are both this shape. Any other host, a
# missing/failing source, or output that is not a single line all fail
# closed to `unknown` - a public distro cannot assume either source exists.
#
# Output (stdout, exactly one line; exit is always 0 - the caller reads the
# line, never the exit status):
#   <token>    the current boot session's opaque id - compared for EQUALITY
#              only, never parsed as a number or a time
#   unknown    no evidence source: unrecognised OS, the source missing or
#              failing, or output that is not a single non-empty line
set -euo pipefail

token=""
case "$(uname -s 2>/dev/null)" in
  Darwin)
    sysctl_bin="$(command -v sysctl 2>/dev/null)" || { printf 'unknown\n'; exit 0; }
    token="$("$sysctl_bin" -n kern.bootsessionuuid 2>/dev/null)" || { printf 'unknown\n'; exit 0; }
    ;;
  Linux)
    [ -r /proc/sys/kernel/random/boot_id ] || { printf 'unknown\n'; exit 0; }
    token="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || { printf 'unknown\n'; exit 0; }
    ;;
  *)
    printf 'unknown\n'
    exit 0
    ;;
esac

case "$token" in
  '') printf 'unknown\n' ;;
  *$'\n'*) printf 'unknown\n' ;;
  unknown) printf 'unknown\n' ;;
  *) printf '%s\n' "$token" ;;
esac
