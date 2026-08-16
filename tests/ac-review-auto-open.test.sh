#!/usr/bin/env bash
# ac-review-auto-open.test.sh - `ac-review.sh open --auto-open`, the
# gate-review-only flag that pops the captain's viewer instead of leaving
# them to copy a link out of a pane. Covers:
#   1. an opener present on PATH gets launched with the exact printed URL;
#   2. SILENT DEGRADATION - no opener anywhere on PATH (a faithful headless/
#      cron stand-in): the link still prints and the command still exits 0
#      with no stderr noise, never a failure (brief hard requirement);
#   3. the boundary - a plain `open` with no --auto-open (the rich-review
#      path) never launches anything.
#
# curl is stubbed to a canned {"ok":true}, so none of this needs a running
# dashboard - only the CLI-layer open/no-open decision is under test.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not installed\n'; exit 0; }

make_home

artifact="$TMP/gate.html"
printf '<html></html>\n' >"$artifact"

mkdir -p "$TMP/stub"
cat >"$TMP/stub/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/stub/curl"

# ---- Case 1: an opener is present -> --auto-open launches it ---------------
mkdir -p "$TMP/opener"
OPEN_LOG="$TMP/open.log"
cat >"$TMP/opener/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$OPEN_LOG"
EOF
chmod +x "$TMP/opener/open"

rc=0
out="$(PATH="$TMP/opener:$TMP/stub:$PATH" BROWSER= "$BIN/ac-review.sh" \
  open "$artifact" --auto-open)" || rc=$?
assert_eq "$rc" 0 "auto-open with an opener present still exits 0"
assert_contains "$out" "review open - captain viewer: http" \
  "auto-open still prints the captain viewer URL"
url="${out#*captain viewer: }"
assert_file "$OPEN_LOG" "the opener was launched"
assert_eq "$(cat "$OPEN_LOG")" "$url" "the opener received the exact printed URL"

# ---- Case 2: no opener anywhere on PATH (headless/cron stand-in) -----------
# A faithful no-GUI PATH: mirror every command the real host PATH actually
# resolves (by basename, first dir wins - same as real PATH lookup) EXCEPT
# `open`/`xdg-open`, so curl(stubbed)/jq/bash/dirname/head/... all resolve
# exactly as they do outside this test, and only the two browser openers are
# genuinely absent - the same shape as a real headless box. $BROWSER unset.
noopener="$TMP/path-no-opener"
mkdir -p "$noopener"
IFS=':' read -r -a pdirs <<<"$PATH"
for d in "${pdirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    b="${f##*/}"
    case "$b" in open | xdg-open) continue ;; esac
    [ -e "$noopener/$b" ] || ln -s "$f" "$noopener/$b" 2>/dev/null || true
  done
done

rc2=0
out2="$(PATH="$TMP/stub:$noopener" BROWSER= "$BIN/ac-review.sh" \
  open "$artifact" --auto-open 2>"$TMP/stderr2")" || rc2=$?
assert_eq "$rc2" 0 "no opener available: still exits 0"
assert_contains "$out2" "review open - captain viewer: http" \
  "no opener available: the link still printed"
assert_eq "$(cat "$TMP/stderr2")" "" "no opener available: no error output"

# ---- Case 3: plain `open` (the rich-review path) never launches -----------
rm -f "$OPEN_LOG"
rc3=0
out3="$(PATH="$TMP/opener:$TMP/stub:$PATH" BROWSER= "$BIN/ac-review.sh" \
  open "$artifact" --reopen)" || rc3=$?
assert_eq "$rc3" 0 "plain open still exits 0"
assert_contains "$out3" "review open - captain viewer: http" \
  "plain open (rich-review path) still prints the URL"
assert_no_file "$OPEN_LOG" "plain open with no --auto-open never launches a browser"

pass
