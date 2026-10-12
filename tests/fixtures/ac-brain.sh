#!/usr/bin/env bash
# ac-brain.sh - CLI for the per-home memory engine (src/brain.ts is the
# authoritative spec; this entry only resolves the home and starts it through
# bin/ac-bun.sh, so nothing in the caller's cwd or environment configures bun).
#
# Usage: ac-brain.sh <verb> [args...] [--home <abs path>]
# Verbs: sync recall remember forget entity context_pack delta links-to
#        synthesize stats doctor serve
# Home resolution: --home flag > $AC_HOME. Every verb prints ONE JSON value;
# errors are {"error":...,"message":...,"suggestion":...} with exit 1.
# Works from any harness that has bash - pi and cursor included; no MCP needed
# (serve is the optional MCP stdio surface for harnesses that want it).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
command -v bun >/dev/null 2>&1 || {
  printf '{"error":"unavailable","message":"bun not on PATH","suggestion":"install bun (https://bun.sh) - the engine runs on it"}\n'
  exit 1
}

home=""
argv=()
while [ $# -gt 0 ]; do
  case "$1" in
    --home) home="${2-}"; shift 2 || { printf '{"error":"invalid_params","message":"--home needs a value","suggestion":"pass --home <abs path> or set AC_HOME"}\n'; exit 1; } ;;
    *) argv+=("$1"); shift ;;
  esac
done
home="${home:-${AC_HOME-}}"
[ -n "$home" ] && [ -d "$home" ] || {
  printf '{"error":"invalid_params","message":"no fleet home","suggestion":"pass --home <abs path> or set AC_HOME"}\n'
  exit 1
}

# ${argv[@]+...}: bash 3.2 calls an empty array unbound under set -u.
ac_bun_exec src/brain.ts ${argv[@]+"${argv[@]}"} --home "$home"
