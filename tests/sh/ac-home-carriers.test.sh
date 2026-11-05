#!/usr/bin/env bash
# ac-home-carriers.test.sh - bin/ac-home-carriers.sh, the shim of
# src/home-carriers.ts: the refusals, the `carried:` lines, a converged home's
# silence, and the shape of what a harness then reads from the home - valid
# hooks files whose every command names the home first, loadable modules.
# The per-entry rules (links, overrides, the pinned env) are
# tests/ts/home-carriers.test.ts's.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

home="$TMP/fleet"
mkdir -p "$home"
for f in bin CLAUDE.md .claude AGENTS.md .agents; do ln -s "$ROOT/$f" "$home/$f"; done

rc=0; err="$(env -u AC_HOME "$BIN/ac-home-carriers.sh" 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "1" "no AC_HOME: refused"
assert_contains "$err" "ERROR: AC_HOME is not set" "... with ac_home's own line"

rc=0; err="$(AC_HOME="$home" "$BIN/ac-home-carriers.sh" --force 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "1" "an argument: refused"
assert_contains "$err" "ERROR: unknown argument: --force" "... named"
[ -L "$home/.claude" ] || fail "a refused run must change nothing"

out="$(AC_HOME="$home" "$BIN/ac-home-carriers.sh" 2>"$TMP/err")"
assert_eq "$(cat "$TMP/err")" "" "a seeded home: nothing on stderr"
assert_eq "$out" "carried: .claude/settings.local.json
carried: .codex/hooks.json
carried: .cursor/hooks.json
carried: .opencode/plugins/ac-home.js
carried: .pi/extensions/ac-home.ts" "one line per carrier, in harness order"
for d in .claude .codex .cursor .opencode .pi; do
  [ -d "$home/$d" ] && [ ! -L "$home/$d" ] || fail "$d must be a real per-home directory"
done
for f in bin CLAUDE.md AGENTS.md .agents; do
  [ -L "$home/$f" ] || fail "the other runtime links stay: $f"
done
assert_eq "$(readlink "$home/.claude/settings.json")" "$ROOT/.claude/settings.json" "the chief hook wiring is the distro's, linked"
assert_eq "$(jq -r .env.AC_HOME "$home/.claude/settings.local.json")" "$home" "claude: env.AC_HOME names the home"

# The two hooks files: valid JSON, every command names the home before the
# distro's own text, and the shell reads that name back verbatim.
for f in .codex/hooks.json .cursor/hooks.json; do
  jq -e . "$home/$f" >/dev/null 2>&1 || fail "$f is not valid JSON"
done
n_all="$(jq '[.hooks[][] | .hooks[]?.command] | length' "$home/.codex/hooks.json")"
n_named="$(jq --arg h "$home" '[.hooks[][] | .hooks[]?.command | select(startswith("AC_HOME=\"${AC_HOME:-\"" + $h + "\"}\" "))] | length' "$home/.codex/hooks.json")"
assert_eq "$n_named" "$n_all" "codex: every command is prefixed with the home"
[ "$n_all" -gt 0 ] || fail "codex: the distro's hooks were carried"
n_all="$(jq '[.hooks[][] | .command] | length' "$home/.cursor/hooks.json")"
n_named="$(jq --arg h "$home" '[.hooks[][] | .command | select(startswith("AC_HOME=\"${AC_HOME:-\"" + $h + "\"}\" "))] | length' "$home/.cursor/hooks.json")"
assert_eq "$n_named" "$n_all" "cursor: every command is prefixed with the home"
[ "$n_all" -gt 0 ] || fail "cursor: the distro's hooks were carried"
prefix="$(jq -r '.hooks.Stop[0].hooks[0].command' "$home/.codex/hooks.json" | sed 's/ bash -lc .*//')"
assert_eq "$(env -u AC_HOME bash -c "$prefix; printf '%s' \"\$AC_HOME\"")" "$home" "the prefix fills a missing AC_HOME"
assert_eq "$(AC_HOME=/launch/line bash -c "$prefix; printf '%s' \"\$AC_HOME\"")" "/launch/line" "... and keeps a launch line's"

if command -v bun >/dev/null 2>&1; then
  for f in "$home/.opencode/plugins/ac-home.js" "$home/.pi/extensions/ac-home.ts"; do
    [ -f "$f" ] && [ ! -L "$f" ] || fail "a REAL module, never a link: $f"
    bun build --no-bundle "$f" >/dev/null 2>&1 || fail "carrier module does not parse: $f"
  done
  assert_eq "$(readlink "$home/.opencode/plugins/ac-primary-guards.js")" "$ROOT/.opencode/plugins/ac-primary-guards.js" "the distro's own plugin rides beside the carrier, linked"
fi

out="$(AC_HOME="$home" "$BIN/ac-home-carriers.sh" 2>&1)"
assert_eq "$out" "" "a converged home: silence"

pass
