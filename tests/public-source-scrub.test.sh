#!/usr/bin/env bash
# public-source-scrub.test.sh - keep private project and identity data out of
# the tracked public source tree.
#
# A data: URI base64 image payload (e.g. an inlined screenshot) is scanned
# like any other tracked text, but a short forbidden identifier can collide
# with the payload's own bytes by pure chance on a large enough blob - noise,
# not a leak. scrub_scan redacts only the payload segment matched by the
# data-URI pattern before testing a hit, so any real text sharing the same
# line (alt text, surrounding markup) stays fully scanned.
set -euo pipefail

# Reduce a line to a form where a chance base64-payload collision cannot
# match: replace each data:<type>;base64,<payload> segment with a fixed
# placeholder, leaving everything else on the line untouched.
scrub_redact_base64() {
  sed -E 's#data:[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+#[base64]#g'
}

# scrub_scan <repo> <forbidden> - prints each surviving hit as
# "path:line:redacted-content"; returns 1 if any hit survives redaction.
scrub_scan() {
  local repo="$1" forbidden="$2" hit path rest lineno content redacted found=0
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    path="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"
    redacted="$(printf '%s' "$content" | scrub_redact_base64)"
    if printf '%s' "$redacted" | grep -qiF -- "$forbidden"; then
      printf '%s:%s:%s\n' "$path" "$lineno" "$redacted"
      found=1
    fi
  done < <(git -C "$repo" grep -n -I -i -F "$forbidden" -- . \
    ':!tests/public-source-scrub.test.sh')
  [ "$found" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cd "$(git rev-parse --show-toplevel)"

  # Two entries formerly on this list matched the project's own public
  # repository location - not private data - captain 2026-08-03.
  for encoded in \
    '\x69\x6e\x66\x69\x6e\x61' \
    '\x7a\x6c\x70' \
    '\x74\x70\x62' \
    '\x62\x76\x62' \
    '\x70\x69\x70\x6f' \
    '\x70\x61\x72\x74\x6e\x65\x72\x2d\x73\x64\x6b' \
    '\x62\x32\x62\x2d\x61\x75\x74\x6f' \
    '\x69\x6e\x74\x65\x72\x65\x73\x74\x2d\x61\x75\x64\x69\x74' \
    '\x61\x75\x64\x69\x74\x2d\x73\x63\x61\x6c\x65' \
    '\x6e\x6f\x74\x69\x66\x79\x2d\x69\x73\x6f\x6c\x61\x74\x69\x6f\x6e' \
    '\x7a\x61\x6c\x6f\x70\x61\x79' \
    '\x2f\x55\x73\x65\x72\x73\x2f\x74\x75\x61\x6e\x6e\x67\x75\x79\x65\x6e' \
    '\x2f\x55\x73\x65\x72\x73\x2f\x74\x6e' \
    '\x74\x75\x61\x6e\x2e\x6e\x67\x75\x79\x65\x6e\x40\x72\x65\x61\x6c\x73\x74\x61\x6b\x65\x2e\x69\x6f' \
    '\x74\x6e\x79\x74\x74\x6d\x61\x40\x67\x6d\x61\x69\x6c\x2e\x63\x6f\x6d'
  do
    forbidden="$(printf '%b' "$encoded")"
    if ! scrub_scan "$PWD" "$forbidden"; then
      printf 'private identifier remains in tracked source: %s\n' "$forbidden" >&2
      exit 1
    fi
  done

  printf 'PASS: public-source-scrub.test.sh\n'
fi
