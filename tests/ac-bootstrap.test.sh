#!/usr/bin/env bash
# ac-bootstrap.test.sh - toolchain doctor: OK lines on a healthy machine,
# NEEDS_GH_AUTH when gh is unauthenticated, MISSING + exit 1 when a required
# tool is absent.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# The backend comes from the fake, never from the box. "the dev box has herdr"
# held on a mac and nowhere else: on a box without herdr the doctor reported
# MISSING: herdr, the assignment below took its exit 1, errexit killed the file
# before its first assert, and this was the ONE test reddening every run - while
# the tool it was really testing worked fine.
make_fake_herdr

# Healthy machine: exit 0, OK lines present.
out="$("$BIN/ac-bootstrap.sh")"
assert_contains "$out" "OK: git" "git detected"
assert_contains "$out" "OK: herdr" "herdr detected"

# --quiet hides OK lines.
quiet_out="$("$BIN/ac-bootstrap.sh" --quiet)"
case "$quiet_out" in
  *"OK: git"*) fail "--quiet must suppress OK lines" ;;
  *) : ;;
esac

# Unauthenticated gh (stub earlier in PATH that fails `auth status`).
mkdir -p "$TMP/stub"
cat >"$TMP/stub/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] && exit 1
exit 0
EOF
chmod +x "$TMP/stub/gh"
out="$(PATH="$TMP/stub:$PATH" "$BIN/ac-bootstrap.sh" --quiet)"
assert_contains "$out" "NEEDS_GH_AUTH" "unauthenticated gh surfaces NEEDS_GH_AUTH"

# Missing required tool: stub-only PATH with everything but herdr.
mkdir -p "$TMP/thin"
for t in git jq gh dirname date mkdir head cat; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$TMP/thin/$t"
done
ln -s "$(command -v bash)" "$TMP/thin/bash"
out="$(PATH="$TMP/thin" bash "$BIN/ac-bootstrap.sh" --quiet)" && fail "expected exit 1 when herdr missing"
assert_contains "$out" "MISSING: herdr" "missing herdr reported"

# A herdr client/server PROTOCOL mismatch is a fleet-wide supervision outage -
# every socket call fails, so nothing can be spawned, seen or steered (lived
# 2026-07-25). herdr reports it itself; the doctor must name it in ONE line
# instead of leaving the digest looking healthy.
mkdir -p "$TMP/mismatch"
cat >"$TMP/mismatch/herdr" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "status server" ] \
  && { printf '{"status":"running","version":"0.7.5","protocol":17,"compatible":false,"restart_needed":true}\n'; exit 0; }
exit 0
EOF
chmod +x "$TMP/mismatch/herdr"
out="$(PATH="$TMP/mismatch:$PATH" "$BIN/ac-bootstrap.sh" --quiet)" \
  && fail "an incompatible herdr server must exit 1 like any other missing requirement"
assert_contains "$out" "MISSING: herdr" "the mismatch is one MISSING line"
assert_contains "$out" "restart" "the line names the remedy"

# A compatible server says nothing extra, and an unparseable answer is NOT read
# as an outage: no evidence of a mismatch may never fail the doctor closed.
mkdir -p "$TMP/compat"
cat >"$TMP/compat/herdr" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "status server" ] \
  && { printf '{"status":"running","compatible":true,"restart_needed":false}\n'; exit 0; }
exit 0
EOF
chmod +x "$TMP/compat/herdr"
out="$(PATH="$TMP/compat:$PATH" "$BIN/ac-bootstrap.sh" --quiet)"
case "$out" in *"MISSING: herdr"*) fail "a compatible server must not be flagged" ;; esac
out="$("$BIN/ac-bootstrap.sh" --quiet)"   # the fake herdr answers status server with nothing
case "$out" in *"MISSING: herdr"*) fail "an unreadable answer is not evidence of a mismatch" ;; esac

pass
