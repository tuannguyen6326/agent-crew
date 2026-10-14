#!/usr/bin/env bash
# ac-compact-advise.sh - "should this session /compact now?" at the System One
# `compact` site: the CLI judge (`<transcript> --role chief|crew`, the
# watcher's), the claude Stop hook (`--hook`) and AUTO's detached sender
# (`--send <id>`). The authoritative spec is the header of
# src/compact-advise.ts; this entry only starts it through bin/ac-bun.sh's
# ac_bun_exec_hook, so the wiring and the watcher keep this path, and no bun
# on PATH, a module that cannot load or a crash exits 0 with one stderr line -
# advice is never worth a broken turn end. Exit codes: 0. The module is found at <this
# bin/>/../src physically, so a per-home override bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" || exit 0
ac_bun_exec_hook src/compact-advise.ts "$@"
