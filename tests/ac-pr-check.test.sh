#!/usr/bin/env bash
# ac-pr-check.test.sh - records pr= and pr_head= on the task meta from a
# stubbed `gh pr view`, and refuses a malformed usage / non-PR URL.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"
export GHVIEW_HEAD=deadbeefcafe
export GHVIEW_STATE=OPEN

cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr view" ]; then
  case "$5" in
    headRefOid) printf '%s\n' "$GHVIEW_HEAD" ;;
    state) printf '%s\n' "$GHVIEW_STATE" ;;
  esac
  exit 0
fi
exit 1
EOF
chmod +x "$stub/gh"

check() { PATH="$stub:$PATH" "$BIN/ac-pr-check.sh" "$@"; }

url=https://github.com/acme/widget/pull/7
printf 'backend=tmux\n' >"$AC_HOME/state/t1.meta"

out="$(check t1 "$url")"
assert_contains "$out" "pr=$url" "prints the recorded pr"
assert_contains "$out" "pr_head=$GHVIEW_HEAD" "prints the recorded pr_head"
meta="$(cat "$AC_HOME/state/t1.meta")"
assert_contains "$meta" "pr=$url" "meta records pr="
assert_contains "$meta" "pr_head=$GHVIEW_HEAD" "meta records pr_head="

# Usage and URL-shape refusals.
assert_fails check t1
assert_fails check t1 "not-a-pr-url"
assert_fails check nosuchtask "$url"

pass
