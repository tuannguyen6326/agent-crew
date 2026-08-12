#!/usr/bin/env bash
# public-source-scrub-base64.test.sh - regression coverage for the base64
# data-URI redaction inside public-source-scrub.test.sh's scrub_scan: a
# forbidden identifier that occurs only by chance inside an image payload's
# base64 bytes must not fire, while a real leak in ordinary prose - including
# one written on the same line as an unrelated data URI - must still be
# caught.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }
. "$(dirname "$0")/public-source-scrub.test.sh"

NEEDLE='zqxkw77'   # neutral synthetic identifier, never a real forbidden entry

# --- (b): a chance collision inside a base64 payload must NOT be reported ---
r1="$(make_repo b64repo)"
payload="$(head -c 20000 /dev/urandom | base64 | tr -d '\n')${NEEDLE}$(head -c 2000 /dev/urandom | base64 | tr -d '\n')"
printf '<img src="data:image/png;base64,%s">\n' "$payload" >"$r1/page.html"
git -C "$r1" add -A && git -C "$r1" commit -qm "add page"
scrub_scan "$r1" "$NEEDLE" \
  || fail "(b): a needle occurring only inside a base64 payload must not be reported as a leak"

# --- (a): a real leak in ordinary prose is still caught ---------------------
r2="$(make_repo proserepo)"
printf 'contact us at %s for details\n' "$NEEDLE" >"$r2/notes.txt"
git -C "$r2" add -A && git -C "$r2" commit -qm "add notes"
if out="$(scrub_scan "$r2" "$NEEDLE")"; then
  fail "(a): a real leak in ordinary prose must be reported"
fi
assert_contains "$out" "notes.txt" "(a): the reported hit names the leaking file"

# --- (a variant): a real leak sharing a line with an unrelated data URI is
#     still caught - redaction must strip only the payload, not the prose.
r3="$(make_repo mixedrepo)"
other_payload="$(head -c 5000 /dev/urandom | base64 | tr -d '\n')"
printf '<img alt="contact %s" src="data:image/png;base64,%s">\n' "$NEEDLE" "$other_payload" >"$r3/page.html"
git -C "$r3" add -A && git -C "$r3" commit -qm "add page"
if out="$(scrub_scan "$r3" "$NEEDLE")"; then
  fail "(a variant): a leak sharing a line with a data URI must still be caught"
fi
assert_contains "$out" "page.html" "(a variant): the reported hit names the leaking file"

pass
