#!/usr/bin/env bash
# ac-bootstrap.test.sh - toolchain doctor: OK lines on a healthy machine,
# NEEDS_GH_AUTH when gh is unauthenticated, MISSING + exit 1 when a required
# tool is absent, and the PATH-shadow probe (INERT:/CHECK-FAILED:, always
# diagnostic - never sets rc, whatever tier the shadowed tool is).

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

# A single canonical copy of every required tool, symlinked from the real
# host - no tool can have more than one PATH entry here, so the PATH-shadow
# probe below can never fire from ambient duplicates a dev box happens to
# have (this box genuinely has one: homebrew jq shadows a newer /usr/bin/jq
# - real, not a fixture; without this base the very first assertion below
# reds on THIS host). Every assertion that expects exit 0 for a reason
# unrelated to PATH shadowing runs against this base, not the bare ambient
# $PATH, from here on.
mkdir -p "$TMP/single"
for t in git jq gh dirname date mkdir head tail cat bash sort grep readlink mktemp sleep rm; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$TMP/single/$t"
done
HEALTHY_PATH="$TMP/single:$TMP/stubbin"

# Same base, minus jq: the PATH-shadow scenarios below plant their OWN jq
# fakes and must never see this host's real jq (a genuine shadow) leak in
# as a third, uncontrolled copy alongside them.
mkdir -p "$TMP/single-nojq"
for t in git gh dirname date mkdir head tail cat bash sort grep readlink mktemp sleep rm; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$TMP/single-nojq/$t"
done

# Healthy machine: exit 0, OK lines present.
out="$(PATH="$HEALTHY_PATH" "$BIN/ac-bootstrap.sh")"
assert_contains "$out" "OK: git" "git detected"
assert_contains "$out" "OK: herdr" "herdr detected"

# --quiet hides OK lines.
quiet_out="$(PATH="$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)"
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
out="$(PATH="$TMP/stub:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)"
assert_contains "$out" "NEEDS_GH_AUTH" "unauthenticated gh surfaces NEEDS_GH_AUTH"

# Missing required tool: stub-only PATH with everything but herdr.
mkdir -p "$TMP/thin"
for t in git jq gh dirname date mkdir head tail cat sort grep readlink mktemp sleep rm; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$TMP/thin/$t"
done
ln -s "$(command -v bash)" "$TMP/thin/bash"
rc=0
out="$(PATH="$TMP/thin" bash "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
# Proves the PATH-shadow probe (diagnostic only, never sets rc) did not
# weaken this pre-existing gate: a genuinely ABSENT required tool must
# still block.
assert_eq "$rc" "1" "a missing required tool must still set rc=1"
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
rc=0
out="$(PATH="$TMP/mismatch:$PATH" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
# Proves the real gate (the case that must actually stop the fleet) is
# untouched by the new diagnostic-only PATH-shadow probe.
assert_eq "$rc" "1" "an incompatible herdr server must still set rc=1"
assert_contains "$out" "MISSING: herdr" "the mismatch is one MISSING line"
assert_contains "$out" "restart" "the line names the remedy"

# A WEDGED server - one that accepts and never answers - is a definite
# observation, not silence. This probe is the one unbounded herdr call left on
# a chief's own session-start path, and a hang there does not degrade a sweep:
# it stops the chief from starting, which is the fleet losing its supervisor
# before it has one. So the probe is bounded and a timeout is its own MISSING
# line, distinct from the mismatch above and from the no-evidence case below.
mkdir -p "$TMP/wedged"
cat >"$TMP/wedged/herdr" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "status server" ] && { sleep 60; exit 0; }
exit 0
EOF
chmod +x "$TMP/wedged/herdr"
rc=0
began=$SECONDS
out="$(AC_BOOTSTRAP_PROBE_TIMEOUT=2 PATH="$TMP/wedged:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
elapsed=$((SECONDS - began))
[ "$elapsed" -lt 30 ] || fail "a wedged backend must not hang the doctor (took ${elapsed}s)"
assert_eq "$rc" "1" "a backend that never answers sets rc=1"
assert_contains "$out" "MISSING: herdr" "the wedge is one MISSING line"
assert_contains "$out" "did not answer" "...and it says the probe timed out rather than claiming a mismatch"
case "$out" in *compatible\ false*) fail "a timeout must not be reported as a protocol mismatch" ;; esac

# A compatible server says nothing extra, and an unparseable answer is NOT read
# as an outage: no evidence of a mismatch may never fail the doctor closed.
mkdir -p "$TMP/compat"
cat >"$TMP/compat/herdr" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf 'herdr 0.8.0\n'; exit 0; }
[ "$1 $2" = "status server" ] \
  && { printf '{"status":"running","running":true,"compatible":true,"restart_needed":false}\n'; exit 0; }
exit 0
EOF
chmod +x "$TMP/compat/herdr"
out="$(PATH="$TMP/compat:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)"
case "$out" in *"MISSING: herdr"*) fail "a compatible server must not be flagged" ;; esac
out="$(PATH="$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)"   # the fake herdr answers status server with nothing
case "$out" in *"MISSING: herdr"*) fail "an unreadable answer is not evidence of a mismatch" ;; esac
# ...and 0 means UNBOUNDED, never a 0s ceiling: an instant backend under
# AC_BOOTSTRAP_PROBE_TIMEOUT=0 measurably lost the race and read as wedged.
out="$(AC_BOOTSTRAP_PROBE_TIMEOUT=0 PATH="$TMP/compat:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)" || true
case "$out" in *"did not answer"*) fail "a 0 ceiling must disable the bound, not fire it instantly: $out" ;; esac

# --- PATH-shadow probe (installed but inert) --------------------------------
#
# fake_ver <path> <version-line> - a stub answering --version with a
# SPECIFIC version regardless of what the real host has installed; every
# other call is handed to the host's real copy (when it has one), so the
# capability probe judges a real build and only the VERSION is faked.
fake_ver() {
  local real
  real="$(command -v "$(basename "$1")" 2>/dev/null || true)"
  cat >"$1" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { printf '%s\n' '$2'; exit 0; }
[ -n '$real' ] && exec '$real' "\$@"
exit 0
EOF
  chmod +x "$1"
}

# Acceptance (1): an older copy sits before a newer one on PATH -> the
# digest MUST print the line - PROVEN BY RUNNING, and the detector
# DIAGNOSES ONLY: rc stays 0, deliberately (captain, 2026-08-23 - some
# inert states, like this host's real nvm/homebrew pins, are chosen on
# purpose, and a blocking line would fire every session forever over
# them). The herdr protocol-compat check below is the real gate; this
# probe never duplicates it.
mkdir -p "$TMP/jq-old" "$TMP/jq-new"
fake_ver "$TMP/jq-old/jq" "jq-1.6"
fake_ver "$TMP/jq-new/jq" "jq-1.9"
shadow_path="$TMP/jq-old:$TMP/single-nojq:$TMP/jq-new:$TMP/stubbin"
out="$(PATH="$shadow_path" "$BIN/ac-bootstrap.sh" --quiet)"
rc=$?
assert_eq "$rc" "0" "an inert tool must NEVER set rc - it diagnoses, it does not gate"
assert_contains "$out" "INERT: jq installed but inert" "shadow reported at INERT grade"
assert_contains "$out" "$TMP/jq-old/jq (1.6)" "active copy and its version named"
assert_contains "$out" "$TMP/jq-new/jq (1.9)" "newer copy and its version named"

# PATH orders directories, not tools: prepending a fix directory can
# re-shadow a DIFFERENT tool that also lives there (chief-verified live on
# this host: fixing jq this way re-shadows git). The line must not promise
# an unconditional per-tool "fix" it cannot keep - it names the command AS
# a directory-level hint instead.
assert_contains "$out" "PATH hint" "the command is framed as a directory-level hint, not an exact per-tool fix"
case "$out" in *" - fix: export PATH"*) fail "must not promise an unconditional per-tool fix" ;; esac

# Acceptance (3): the printed hint command must actually RUN, not just look
# plausible - eval it and prove `command -v` now resolves the newer copy.
fix="$(printf '%s\n' "$out" | grep -o 'export PATH="[^"]*"')"
[ -n "$fix" ] || fail "no PATH hint command printed"
(
  eval "$fix"
  [ "$(command -v jq)" = "$TMP/jq-new/jq" ] || exit 1
) || fail "the printed PATH hint command did not resolve jq to the newer copy"

# Acceptance (2), negative: the active copy is ALREADY the newest -> no line.
shadow_path="$TMP/jq-new:$TMP/single-nojq:$TMP/jq-old:$TMP/stubbin"
out="$(PATH="$shadow_path" "$BIN/ac-bootstrap.sh" --quiet)"
case "$out" in *"jq installed but inert"*) fail "active-is-newest must not false-positive" ;; esac

# Acceptance (2), symlink dupes: two PATH entries resolving to the SAME real
# file must not make the detector compare a tool against itself.
mkdir -p "$TMP/jq-dup"
ln -s "$TMP/jq-old/jq" "$TMP/jq-dup/jq"
shadow_path="$TMP/jq-old:$TMP/single-nojq:$TMP/jq-dup:$TMP/stubbin"
out="$(PATH="$shadow_path" "$BIN/ac-bootstrap.sh" --quiet)"
case "$out" in *"jq installed but inert"*) fail "symlink dupes must not false-positive" ;; esac

# The rule is uniform and tier-blind (there is no tier branching left in
# the detector): the SAME shadow shape on bun ALSO prints INERT: and
# ALSO leaves rc untouched.
mkdir -p "$TMP/bun-old" "$TMP/bun-new"
fake_ver "$TMP/bun-old/bun" "1.0.0"
fake_ver "$TMP/bun-new/bun" "1.3.13"
shadow_path="$TMP/bun-old:$TMP/single:$TMP/bun-new:$TMP/stubbin"
out="$(PATH="$shadow_path" "$BIN/ac-bootstrap.sh" --quiet)"
rc=$?
assert_eq "$rc" "0" "an inert OPTIONAL tool must not set rc either"
assert_contains "$out" "INERT: bun installed but inert" "bun shadow reported at INERT grade too"

# A copy that will not report a parseable version is a CHECK FAILURE, not a
# silent pass - and it must not be mistaken for "newer" or "older".
mkdir -p "$TMP/jq-unparseable"
fake_ver "$TMP/jq-unparseable/jq" "not-a-version"
shadow_path="$TMP/jq-unparseable:$TMP/single-nojq:$TMP/stubbin"
out="$(PATH="$shadow_path" "$BIN/ac-bootstrap.sh" --quiet)"
assert_contains "$out" "CHECK-FAILED: jq" "an unparseable active copy is reported, not swallowed"
case "$out" in *"jq installed but inert"*) fail "an unparseable version must never be treated as a comparison result" ;; esac

# orca has NO --version (it prints usage - measured on 1.4.188): its version
# lives in `status --json` .result.runtime.appVersion. The version probe must
# ask THAT, so the fleet's own backend never reads CHECK-FAILED at every
# session start (measured live, twice, before this arm existed).
mkdir -p "$TMP/orca-bin"
cat >"$TMP/orca-bin/orca" <<'FAKEORCA'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"9.9.9"}}}
'
  exit 0
fi
printf 'orca

Usage: orca <command> [options]
'
exit 0
FAKEORCA
chmod +x "$TMP/orca-bin/orca"
printf 'orca
' >"$AC_HOME/config/backend"
out="$(PATH="$TMP/orca-bin:$TMP/single:$TMP/stubbin" "$BIN/ac-bootstrap.sh" --quiet)"
case "$out" in *"CHECK-FAILED: orca"*) fail "orca must not read CHECK-FAILED - its version lives in status --json" ;; esac

# A REACHABLE runtime that is not READY (still starting, or errored) cannot
# spawn either - an explicit non-ready state is flagged, same flag-only-
# explicit philosophy as reachable=false (silence still says nothing).
cat >"$TMP/orca-bin/orca" <<'FAKEORCA'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"state":"starting","reachable":true,"appVersion":"9.9.9"}}}
'
  exit 0
fi
exit 0
FAKEORCA
rc=0
out="$(PATH="$TMP/orca-bin:$TMP/single:$TMP/stubbin" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
assert_contains "$out" "orca runtime is starting, not ready" "an explicit non-ready state is flagged"
[ "$rc" != 0 ] || fail "a non-ready runtime must fail the toolchain check"
printf 'herdr
' >"$AC_HOME/config/backend"

# --- version floors and capability probes ----------------------------------
#
# Present is not "the right build": the fleet's code targets a specific herdr
# (0.8.0 - `status server --json` .running decides GONE vs unobservable in
# ac-backend.sh), git (2.15 - the commit-msg guard's `interpret-trailers
# --parse` fails OPEN on an older git, so every agent trailer would pass) and
# jq (1.6 - `--args`/`$ARGS` in ac-brief.sh). A wrong build reads as its own
# line class, never OK and never MISSING, naming the floor and the probe.
# fake_herdr <dir> <version-line> <status-json> - a herdr answering --version
# and `status server --json` with the given shapes.
fake_herdr() {
  mkdir -p "$1"
  cat >"$1/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$1/calls"
[ "\${1:-}" = --version ] && { printf '%s\\n' '$2'; exit 0; }
[ "\${1:-} \${2:-}" = "status server" ] && { printf '%s\\n' '$3'; exit 0; }
exit 0
EOF
  chmod +x "$1/herdr"
}
real_status='{"status":"running","running":true,"version":"0.8.0","protocol":19,"compatible":true,"restart_needed":false}'

# An older herdr is BELOW-FLOOR: a required tool, so it blocks like MISSING.
fake_herdr "$TMP/herdr-old" "herdr 0.7.5" "$real_status"
rc=0
out="$(PATH="$TMP/herdr-old:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
assert_eq "$rc" "1" "a required tool below its floor blocks the toolchain"
assert_contains "$out" "BELOW-FLOOR: herdr" "an older herdr is reported at BELOW-FLOOR grade"
assert_contains "$out" "0.7.5" "...naming the version found"
assert_contains "$out" "floor 0.8.0" "...and the floor"
assert_contains "$out" "probe: herdr --version" "...and the probe that measured it"
case "$out" in *"MISSING: herdr -"*) fail "below-floor is not MISSING: $out" ;; esac
full="$(PATH="$TMP/herdr-old:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" || true)"
case "$full" in *"OK: herdr"*) fail "a below-floor tool must never read OK: $full" ;; esac

# A herdr AT the floor whose status server does not report .running lacks the
# capability the backend calls: NO-CAPABILITY, also blocking.
fake_herdr "$TMP/herdr-nocap" "herdr 0.8.0" '{"status":"running","compatible":true}'
rc=0
out="$(PATH="$TMP/herdr-nocap:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
assert_eq "$rc" "1" "a required tool lacking its capability blocks the toolchain"
assert_contains "$out" "NO-CAPABILITY: herdr" "a herdr without .running is reported at NO-CAPABILITY grade"
assert_contains "$out" "probe: herdr status server --json" "...naming the probe"
case "$out" in *"BELOW-FLOOR: herdr"*) fail "at the floor is not below it: $out" ;; esac
case "$out" in *"MISSING: herdr -"*) fail "a missing capability is not MISSING: $out" ;; esac
full="$(PATH="$TMP/herdr-nocap:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" || true)"
case "$full" in *"OK: herdr"*) fail "a tool lacking its capability must never read OK: $full" ;; esac

# The real-shaped build is OK, and the doctor asks the server ONCE: the
# capability reads the same bounded status probe the compat gate uses.
fake_herdr "$TMP/herdr-real" "herdr 0.8.0" "$real_status"
rc=0
out="$(PATH="$TMP/herdr-real:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh")" || rc=$?
assert_eq "$rc" "0" "the targeted build passes"
assert_contains "$out" "OK: herdr" "the real-shaped herdr reads OK"
case "$out" in *"BELOW-FLOOR"*|*"NO-CAPABILITY"*) fail "the real-shaped build must raise no floor line: $out" ;; esac
assert_eq "$(grep -c 'status server' "$TMP/herdr-real/calls")" "1" "the status server is probed exactly once per run"

# A wedged server already owns its MISSING line; the capability probe must not
# pile a second verdict on the same silence.
rc=0
out="$(AC_BOOTSTRAP_PROBE_TIMEOUT=2 PATH="$TMP/wedged:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
case "$out" in *"NO-CAPABILITY: herdr"*) fail "a timeout is not a missing capability: $out" ;; esac

# The same table covers git and jq: an old jq is BELOW-FLOOR (required, blocks).
mkdir -p "$TMP/jq-below"
fake_ver "$TMP/jq-below/jq" "jq-1.5"
rc=0
out="$(PATH="$TMP/jq-below:$TMP/single-nojq:$TMP/stubbin" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
assert_eq "$rc" "1" "a below-floor jq blocks"
assert_contains "$out" "BELOW-FLOOR: jq" "an old jq is reported at BELOW-FLOOR grade"
assert_contains "$out" "floor 1.6" "...naming the jq floor"

# An OPTIONAL tool's floor line is advisory, like its OPTIONAL: line - bun at
# a fine version but lacking the API the dashboard/brain engine call.
mkdir -p "$TMP/bun-nocap"
cat >"$TMP/bun-nocap/bun" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '1.3.13\n'; exit 0; }
exit 0
EOF
chmod +x "$TMP/bun-nocap/bun"
rc=0
out="$(PATH="$TMP/bun-nocap:$HEALTHY_PATH" "$BIN/ac-bootstrap.sh" --quiet)" || rc=$?
assert_eq "$rc" "0" "an optional tool's capability gap never sets rc"
assert_contains "$out" "NO-CAPABILITY: bun" "an optional tool's gap is still reported"

pass
