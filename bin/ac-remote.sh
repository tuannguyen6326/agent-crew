#!/usr/bin/env bash
# ac-remote.sh - remote captain orders over user-owned config/ hooks: poll,
# ingest and order stash an order and queue its fleet wake; show, reply, link,
# followup and ack work one stashed order; thread-post, done-stamp and
# push-pending work a family thread; gc prunes old stashes. The authoritative
# spec is the header of src/remote.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/remote.ts "$@"
