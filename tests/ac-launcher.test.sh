#!/usr/bin/env bash
# ac-launcher.test.sh - the `ac` zsh launcher (docs/examples/ac.zsh) opens a
# herdr chief in the fleet's ROOT workspace "<fleet>" (bin/ac-backend.sh FAMILY
# WORKSPACE GROUPING), never the retired per-role "<fleet> (crewchief)" group,
# and writes no retired config/herdr-workspace* knob.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v zsh >/dev/null 2>&1 || { printf 'SKIP: zsh not available\n'; exit 0; }

make_fake_herdr
home="$TMP/h"
mkdir -p "$home/Work/ac-homes/lab/state" "$home/Work/ac-homes/lab/crewdeputies/mob/state"
# The launcher resolves the distro at ~/Work/agent-crew, the installed layout.
ln -s "$ROOT" "$home/Work/agent-crew"

launch() { # launch <fleet> <deputy>
  env -u HERDR_ENV HOME="$home" PATH="$TMP/stubbin:$PATH" \
    zsh -f -c "source '$ROOT/docs/examples/ac.zsh'; _ac_home '$1' true '$2' herdr ''" >/dev/null 2>&1 || true
}
labels() { cat "$FAKE_HERDR"/ws.* 2>/dev/null | sort; }

launch lab ''
assert_eq "$(labels)" "lab" "the chief opens in the fleet's root workspace"
assert_no_file "$home/Work/ac-homes/lab/config/herdr-workspace-chiefs" "the retired chiefs knob is never written"

launch lab mob
assert_eq "$(labels)" "lab" "a deputy launch joins the same root workspace instead of minting another"
case "$(cat "$FAKE_HERDR"/tabs/* 2>/dev/null)" in
  *ac-lab-mob*) ;;
  *) fail "the deputy launch opens its own ac-lab-mob tab" ;;
esac

# The root label is SHARED with the backend's fleet-level panes, so the
# launcher resolves it the backend's way (herdr_resolve_workspace): an
# existing label is adopted, never re-created beside a twin.
printf 'lab' >"$FAKE_HERDR/ws.w90"
before="$(ls "$FAKE_HERDR"/ws.* | wc -l | tr -d ' ')"
launch lab ''
assert_eq "$(ls "$FAKE_HERDR"/ws.* | wc -l | tr -d ' ')" "$before" "a launch beside twins adopts one instead of minting another"

# A fleet pinned to a herdr session: the launcher's own tab and the backend's
# workspace resolution must address that ONE session, or the chief's tab
# lands in a different server's workspace. A logging wrapper records argv.
mkdir -p "$TMP/logbin"
cat >"$TMP/logbin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/herdr.argv"
exec "$TMP/stubbin/herdr" "\$@"
EOF
chmod +x "$TMP/logbin/herdr"
mkdir -p "$home/Work/ac-homes/sess/state" "$home/Work/ac-homes/sess/config"
printf 's1\n' >"$home/Work/ac-homes/sess/config/herdr-session"
env -u HERDR_ENV -u AC_HERDR_SESSION HOME="$home" PATH="$TMP/logbin:$TMP/stubbin:$PATH" \
  zsh -f -c "source '$ROOT/docs/examples/ac.zsh'; _ac_home sess true '' herdr ''" >/dev/null 2>&1 || true
calls="$(grep -E '(^|--session [^ ]+ )(workspace create|tab create|pane run)' "$TMP/herdr.argv" 2>/dev/null)"
[ -n "$calls" ] || fail "the pinned-session launch made no workspace/tab calls"
case "$(printf '%s\n' "$calls" | grep -v -- '--session s1')" in
  '') ;;
  *) fail "every workspace/tab call must address the fleet's session s1: $calls" ;;
esac

pass
