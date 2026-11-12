#!/usr/bin/env bash
# ac-spawn-differential.test.sh - src/spawn.ts, started by bin/ac-spawn.sh, on
# the paths no other ac-spawn suite drives: the grammar, the knobs, the brief
# and project reads, the orca and crewdeputy edges and the signals. Every row
# rebuilds one world, runs its calls and asserts their exit, stdout and stderr
# and the world they leave.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# The world ($XW): a home (config/, records/, data/, state/, projects/proj
# linking the repo), the repo $XW/proj made under one git identity and one
# commit date, the container's .claude/CLAUDE.md, the fake herdr's and fake
# orca's dirs, HOME=$XW/hh, TMPDIR=$XW/tmp, AC_CLAUDE_TRANSCRIPT_ROOT=$XW/cp and
# AC_GUARD_ROOT=$XW/cwd (no repo: the guard's distro checks stay silent). Each
# call runs from $XW/cwd with stdin /dev/null, LC_ALL=C unless a row names
# en_US.UTF-8, and PATH stubs ahead of the fakes: date answering one instant,
# sleep returning at once (holding where a row says), uuidgen answering one
# uuid, every harness CLI a never-run stand-in.
make_fake_herdr
make_fake_orca
cd "$TMP" || fail "cd TMP"
XW="$TMP/xw"; XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig" \
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case " $* " in *" -r "*|*" -j "*|*" -f "*) exec /bin/date "$@" ;; esac
exec /bin/date -r 1767225600 "$@"
STUB
# sleep: a call whose argument is the world's stub/hold-sleep holds until
# stub/release (stub/held marks it), so a signal row can land inside it.
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$XSTUB/sleep.log"
if [ -n "$*" ] && [ "$*" = "$(cat "$XSTUB/hold-sleep" 2>/dev/null)" ]; then
  : >"$XSTUB/held"
  i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done
fi
case "$*" in *[0-9]*) case "$*" in *[!0-9.]*) ;; *) exit 0 ;; esac ;; esac
exec /bin/sleep "$@"
STUB
cat >"$XSTUBS/uuidgen" <<'STUB'
#!/bin/sh
echo 0F4A1B2C-3D4E-4F50-8A61-72B3C4D5E6F7
STUB
for h in claude codex opencode pi cursor-agent; do printf '#!/bin/sh\nexit 0\n' >"$XSTUBS/$h"; done
chmod +x "$XSTUBS"/*

xworld() {  # xworld - a fresh world: the home, the repo $XW/proj (one commit on main) linked as projects/proj, the container .claude, both fakes' dirs
  rm -rf "$XW"
  mkdir -p "$XW/home/state" "$XW/home/data" "$XW/home/records" "$XW/home/config" "$XW/home/projects" \
    "$XW/tmp" "$XW/stub" "$XW/hh" "$XW/cwd" "$XW/cp" "$XW/herdr/panes" "$XW/herdr/tabs" "$XW/orca/terminals" "$XW/.claude"
  printf 'off\n' >"$XW/home/config/wedge-alarm"
  printf 'echo crew __ID__ reading __BRIEF__\n' >"$XW/home/config/launch-fake"
  printf 'the container crewmate layer\n' >"$XW/.claude/CLAUDE.md"
  : >"$XW/herdr/.pane-idle-by-default"
  git init -q "$XW/proj"
  printf 'base\n' >"$XW/proj/f.txt"; git -C "$XW/proj" add f.txt; git -C "$XW/proj" commit -qm base
  ln -s "$XW/proj" "$XW/home/projects/proj"
}
XLC=C; XENV=(); XPATH=""; XHOME=1
xe() {  # xe - the call environment into XE: the stubs ahead of the fakes and the host, the world's home, tmp, HOME and backends, then the row's XENV
  local path="$XSTUBS:$PATH" x
  [ -z "$XPATH" ] || path="$XPATH"
  XE=(env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_FLEET_SCOPE -u AC_CREW_ID -u AC_DOMAIN
    -u AC_BACKEND -u AC_HERDR_SESSION -u AC_ROOM_OVERCAP_REASON -u AC_WINDOW_FAMILY -u CLAUDE_CONFIG_DIR -u CDPATH
    -u AC_SPAWN_META_CLAIM_TIMEOUT -u AC_SPAWN_META_CLAIM_STALE_GRACE -u AC_ULTRACODE_SETTLE -u AC_CHIEF_SOLO
    "LC_ALL=$XLC" "PATH=$path" "HOME=$XW/hh" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub" "FAKE_HERDR=$XW/herdr" "FAKE_ORCA=$XW/orca"
    "AC_CLAUDE_TRANSCRIPT_ROOT=$XW/cp" "AC_GUARD_ROOT=$XW/cwd" "AC_SPAWN_SETTLE=0" "AC_KICKOFF_READY_BUDGET=5"
    "AC_SEND_SETTLE=0" "AC_STARTUP_DIALOG_BUDGET=2" "AC_HERDR_RPC_TIMEOUT=10")
  [ -z "$XHOME" ] || XE+=("AC_HOME=$XW/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do XE+=("$x"); done
}
xrun() {  # xrun <cmd> <args...> - a setup step in the world's environment, quiet; a failure ends the suite
  xe; (cd "$XW/cwd" && exec "${XE[@]}" "$@") </dev/null >/dev/null 2>&1 || fail "spawn setup failed at line $(xrow): $*"
}
xbrief() { xrun "$BIN/ac-brief.sh" "$@"; }   # xbrief <ac-brief args> - a brief in the world
xroom() { xrun "$BIN/ac-room.sh" post "$1" crewchief "${2:-the order for $1, posted before the promote}"; }   # xroom <family> [<text>] - the room's order
xput() { mkdir -p "$(dirname "$XW/$1")"; printf '%b' "$2" >"$XW/$1"; }   # xput <path under the world> <printf %b bytes>
xc() {  # xc <args...> - one spawn, its transcript appended
  local rc=0
  xe
  (cd "$XW/cwd" && exec "${XE[@]}" "$BIN/ac-spawn.sh" "$@") </dev/null >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?
  { printf '== %s\nrc=%s\n-- out\n' "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt"
}
xsig() {  # xsig <signal> <args...> - one spawn in the background; once the world holds stub/held, <signal> to its pid alone, then the hold released
  local sig="$1" wrap pid rc i=0; shift
  xe
  rm -f "$TMP/x.rc"
  # Job control gives the job its own group with SIGINT at its default - a
  # plain `&` job of a non-interactive shell starts with SIGINT ignored. The
  # job is a wrapper and the run its FOREGROUND child, so the status is the
  # wrapper's own `$?`: bash 3.2's `wait` on a signalled background job
  # answers 0 now and then (measured: its `Killed: 9` notice printed, then
  # `wait` 0), and a foreground wait does not.
  {
    set -m
    (set +e; cd "$XW/cwd" && "${XE[@]}" "$BIN/ac-spawn.sh" "$@" </dev/null >"$TMP/x.out" 2>"$TMP/x.err"; printf '%s\n' "$?" >"$TMP/x.rc") &
    wrap=$!
    set +m
    while [ ! -e "$XW/stub/held" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.05; i=$((i + 1)); done
    [ -e "$XW/stub/held" ] || fail "spawn at line $(xrow): the run never reached its hold"
    pid="$(pgrep -P "$wrap")" || pid=""
    case "$pid" in '' | *[!0-9]*) fail "spawn at line $(xrow): the run's pid was not found under its job (got '$pid')" ;; esac
    kill -"$sig" "$pid"
    /bin/sleep 0.5
    : >"$XW/stub/release"
    wait "$wrap" || true
  } 2>/dev/null
  rc="$(cat "$TMP/x.rc" 2>/dev/null)"
  case "$rc" in '' | *[!0-9]*) fail "spawn at line $(xrow): the run left no exit status (got '$rc')" ;; esac
  /bin/sleep 0.3
  rm -f "$XW/stub/held" "$XW/stub/release" "$XW/stub/hold-sleep"
  { printf '== %s %s\nrc=%s\n-- out\n' "$sig" "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt"
}
xnorm() {  # xnorm <file> - the world XW, the root ROOT, a mktemp suffix XXXXXX, a temp or wake-record pid PID
  # The `child setpgid` line is bash's job control losing a fork race in a
  # bash sibling's background child - SHELL-OWN, printed on no fixed call.
  LC_ALL=C sed -E -e "s#$XW#XW#g" -e "s#$ROOT#ROOT#g" \
    -e 's#(/archive/[^/]+/[0-9]+)\.[A-Za-z0-9]{6}#\1.XXXXXX#g' -e 's#\.tmp\.[0-9]+#.tmp.PID#g' \
    -e 's#(/\.wake-spool[^/]*/[0-9]+)\.[0-9]+\.#\1.PID.#g' \
    -e '/^ROOT\/bin\/[a-z-]+\.sh: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted$/d' "$1"
}
xsnap() {  # xsnap - the world as one listing: every path under $XW but hh/ and the repo's .git with mode and bytes, then the repo's refs, worktrees and exclude
  local n f
  (cd "$XW" && find . \( -path ./hh -o -path ./proj/.git \) -prune -o -print) | sed 's#^\./##' >"$TMP/xnames"
  xnorm "$TMP/xnames" | paste - "$TMP/xnames" | LC_ALL=C sort | while IFS=$'\t' read -r n f; do
    if [ -L "$XW/$f" ]; then printf '== %s -> %s\n' "$n" "$(readlink "$XW/$f")"; continue; fi
    printf '== %s %s\n' "$n" "$(stat -f %Sp "$XW/$f")"
    case "$f" in
      */.meta-claims/*/pid) printf '<pid>\n' ;;
      */.git/index | */.git/worktrees/*/index) printf '<git index>\n' ;;
      *) [ -d "$XW/$f" ] || { cat "$XW/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'; } ;;
    esac
  done >"$TMP/xw.snap"
  { printf -- '-- refs\n'; git -C "$XW/proj" for-each-ref --format='%(refname) %(objectname)'
    printf -- '-- worktrees\n'; git -C "$XW/proj" worktree list --porcelain
    printf -- '-- exclude\n'; cat "$XW/proj/.git/info/exclude" 2>/dev/null || true
  } >>"$TMP/xw.snap"
}
xgo() {  # xgo <setup> <body> - rebuild the world, run the body's calls, read the transcript and the world
  : >"$TMP/xt"
  XLC=C; XENV=(); XPATH=""; XHOME=1
  $1; $2; xsnap
  xnorm "$TMP/xt" >"$TMP/xt2"; xnorm "$TMP/xw.snap" >"$TMP/xw2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the line that started this row
xt() { cat "$TMP/xt2"; }
xhas() { assert_contains "$(xt)" "$1" "spawn at line $(xrow)"; }   # xhas <text> - the normalised transcript holds <text>
xlacks() { case "$(xt)" in *"$1"*) fail "spawn at line $(xrow): '$1' found" ;; esac; }
xwhas() { assert_contains "$(cat "$TMP/xw2")" "$1" "spawn world at line $(xrow)"; }
xwlacks() { case "$(cat "$TMP/xw2")" in *"$1"*) fail "spawn world at line $(xrow): '$1' found" ;; esac; }
xrcs() { assert_eq "$(grep -a '^rc=' "$TMP/xt2" | cut -d= -f2 | tr '\n' ' ')" "$1" "spawn exits at line $(xrow)"; }   # xrcs '<rc> <rc> ... ' - every call's exit, in order
xwithout() {  # xwithout <tool> - the stubs and PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$XSTUBS:$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/no$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do [ "$(basename "$f")" = "$1" ] || ln -sf "$f" "$mirror/$(basename "$f")" 2>/dev/null || true; done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
xt1() { xworld; xbrief t1 proj --mode local-only; }   # a world holding the brief of t1
xdeadpane() { local p t; read -r p t <"$XW/home/state/.pane-$1"; rm -f "$XW/herdr/panes/$p".* "$XW/herdr/tabs/$t"; }   # xdeadpane <id> - the task's pane is gone
xchief() { printf 'kind=roomchief\nbackend=herdr\n%s' "${2:-}" >"$XW/home/state/$1-chief.meta"; }   # xchief <family> [<more meta lines>] - a flying roomchief

# -- 1: preamble ------------------------------------------------------------
x1a() {
  xc; xc -h; xc --bogus; xc t1 proj extra; xc --captain-initiated x; xc --solo t1 proj
  xc t1 proj --recover --resume-from t0; xc --roomchief f --codereview-rule 1; xc t1 --crewdeputy --base-branch main
  xc t1 proj --base-branch ''
}
xgo xworld x1a
xrcs '1 1 1 1 1 1 1 1 1 1 '
xhas $'== \nrc=1\n-- out\n-- err\nERROR: usage: ac-spawn.sh <id> <project> [--scout]'
xhas $'== -h\nrc=1\n-- out\n-- err\nERROR: unknown flag: -h'
xhas $'== --bogus\nrc=1\n-- out\n-- err\nERROR: unknown flag: --bogus'
xhas $'== t1 proj extra\nrc=1\n-- out\n-- err\nERROR: unexpected arg: extra'
xhas 'ERROR: --captain-initiated/--system-initiated/--over-cap require --roomchief'
xhas 'ERROR: --solo requires --roomchief'
xhas 'ERROR: --recover and --resume-from are mutually exclusive'
xhas 'ERROR: --codereview-rule requires a plain crew spawn'
xhas 'ERROR: --base-branch requires a plain crew spawn'
xhas $'-- err\nERROR: --base-branch names the branch the orca lease is cut from'
xwlacks 'home/state/.meta-claims'
x1b() {
  XENV=(AC_SOLO=1); xc t1 proj
  XENV=(AC_SOLO=1 AC_BACKEND=tmux); xc t1 proj
  XENV=(AC_BACKEND=tmux); xc t1 proj
  XENV=(); printf 'tmux\n' >"$XW/home/config/backend"; xc t1 proj
}
xgo xworld x1b
xrcs '1 1 1 1 '
xhas $'== t1 proj\nrc=1\n-- out\n-- err\nERROR: a solo session (AC_SOLO=1) never spawns crew'
assert_eq "$(grep -ac "^ERROR: unsupported backend 'tmux' (valid backends: herdr, orca" "$TMP/xt2")" "3" "spawn at line $LINENO: a tmux backend is refused by env and by config"
x1c() { XHOME=""; xc t1 proj --harness fake; xc --roomchief fa --harness fake; }
xgo xt1 x1c
xrcs '1 1 '
xhas $'== t1 proj --harness fake\nrc=1\n-- out\n-- err\nERROR: AC_HOME is not set'
xhas $'== --roomchief fa --harness fake\nrc=1\n-- out\n-- err\nERROR: AC_HOME is not set'
x1d() { XPATH="$(xwithout git)"; xc t1 proj --harness fake; }
xgo xt1 x1d
xhas $'== t1 proj --harness fake\nrc=1\n-- out\n-- err\nERROR: required tool not found: git'
xwlacks 'home/state/t1.meta'
# No bun: the shim refuses before anything.
x1e() { XPATH="$(xwithout bun)"; xc -h; xc t1 proj --harness fake; }
xgo xt1 x1e
xhas $'== -h\nrc=1\n-- out\n-- err\nERROR: required tool not found: bun\n== '
xhas $'== t1 proj --harness fake\nrc=1\n-- out\n-- err\nERROR: required tool not found: bun'
xwlacks 'home/state/.meta-claims'
# A value flag given as the last word exits 1 with nothing said.
x1f() { xc t1 proj --harness; xc --roomchief; xc t1 proj --mode; }
xgo xt1 x1f
assert_eq "$(xt)" $'== t1 proj --harness\nrc=1\n-- out\n-- err\n== --roomchief\nrc=1\n-- out\n-- err\n== t1 proj --mode\nrc=1\n-- out\n-- err' "spawn at line $LINENO: a valueless flag"

# -- 2: grammar and order -----------------------------------------------------
x2a() {
  xc bad_id proj; xc BadId proj; xc --roomchief bad_family; xc --roomchief Café; xc --roomchief f --scout
  xc --roomchief f t1; xc t1 --crewdeputy --scout; xc t1 proj --crewdeputy; xc --crewdeputy; xc t1 proj --effort bogus
}
xgo xworld x2a
xrcs '1 1 1 1 1 1 1 1 1 1 '
xhas 'ERROR: id must be [a-z0-9-]: bad_id'
xhas 'ERROR: id must be [a-z0-9-]: BadId'
xhas 'ERROR: family must be [a-z0-9-]: bad_family'
xhas 'ERROR: family must be [a-z0-9-]: Café'
xhas 'ERROR: --roomchief excludes --scout/--crewdeputy'
xhas 'ERROR: usage: ac-spawn.sh --roomchief <family> (id is derived: <family>-chief)'
xhas 'ERROR: --crewdeputy and --scout are mutually exclusive'
xhas "ERROR: crewdeputies run in their home, not a project (drop 'proj')"
xhas 'ERROR: usage: ac-spawn.sh <id> --crewdeputy'
xhas 'ERROR: invalid effort: bogus'
x2b() { XLC=en_US.UTF-8; xc --roomchief Café; xc Café proj; xc t1 proj --effort ultracodé; }
xgo xworld x2b
xrcs '1 1 1 '
xhas $'== --roomchief Café\nrc=1\n-- out\n-- err\nERROR: family must be [a-z0-9-]: Café'
xhas $'== Café proj\nrc=1\n-- out\n-- err\nERROR: id must be [a-z0-9-]: Café'
xhas 'ERROR: invalid effort: ultracodé'
x2c() {
  XENV=(AC_SPAWN_SETTLE=abc); xc t1 proj --harness fake
  XENV=(AC_KICKOFF_READY_BUDGET=1.5); xc t1 proj --harness fake
  XENV=(AC_ULTRACODE_SETTLE=x); xc t1 proj --harness fake
  XENV=(AC_ULTRACODE_SETTLE=x); xc t2 proj --harness claude --effort ultracode
  XENV=(); xc t3 proj --harness fake --base-branch main
}
xknobs() { xt1; xbrief t2 proj --mode local-only; xbrief t3 proj --mode local-only; }
xgo xknobs x2c
xrcs '1 1 0 1 1 '
xhas 'ERROR: AC_SPAWN_SETTLE must be a non-negative number: abc'
xhas 'ERROR: AC_KICKOFF_READY_BUDGET must be a non-negative integer: 1.5'
xhas 'spawned t1 harness=fake'
xhas 'ERROR: AC_ULTRACODE_SETTLE must be a non-negative number: x'
xhas 'ERROR: --base-branch requires an orca-backend fleet'
x2d() {
  xc t9 proj --harness fake
  xc t1 proj --harness fake --mode bogus
  xc t1 proj --harness fake --mode direct-pr
  sed -i.bak '/^Review: /d' "$XW/home/data/t1/brief.md"; xc t1 proj --harness fake
  printf 'Review: maybe\n' >>"$XW/home/data/t1/brief.md"; xc t1 proj --harness fake
  sed -i.bak -e '/^Review: /d' -e '/^Mode: /d' "$XW/home/data/t1/brief.md"; printf 'Review: no\n' >>"$XW/home/data/t1/brief.md"; xc t1 proj --harness fake
  rm -f "$XW/home/data/t1/brief.md.bak"
}
xgo xt1 x2d
xrcs '1 1 1 1 1 1 '
xhas 'ERROR: no brief at XW/home/data/t9/brief.md; run ac-brief.sh first'
xhas 'ERROR: invalid --mode: bogus'
xhas "ERROR: --mode direct-pr contradicts the brief's recorded Mode: local-only"
assert_eq "$(grep -ac '^ERROR: execution brief must carry exactly one Review: yes|no obligation: XW/home/data/t1/brief.md$' "$TMP/xt2")" "2" "spawn at line $LINENO: a missing and an unknown Review"
xhas "ERROR: no 'Mode:' line in XW/home/data/t1/brief.md"
xwlacks 'home/state/t1.meta'
# --resume-from: a meta that never existed, a non-claude one, one with no session.
xresumeworld() {
  xt1
  xput home/state/t8.meta "kind=ship\nbackend=herdr\nharness=codex\nworktree=$XW/proj\n"
  xput home/state/t7.meta "kind=ship\nbackend=herdr\nharness=claude\nworktree=$XW/proj\n"
}
x2e() { xc t1 proj --resume-from t5; xc t1 proj --resume-from t8; xc t1 proj --resume-from t7; }
xgo xresumeworld x2e
xrcs '1 1 1 '
xhas 'ERROR: --resume-from: no meta for t5'
xhas 'ERROR: --resume-from: t8 was not a claude session'
xhas 'ERROR: --resume-from: t7 has no recorded session_id'

# -- 3: the crew path on herdr --------------------------------------------------
x3a() { xc t1 proj --harness fake --mode local-only; xc t1 proj --harness fake; }
xgo xt1 x3a
xhas 'spawned t1 harness=fake kind=ship mode=local-only yolo=off backend=herdr'
xrcs '0 1 '
xhas 'ERROR: crewmate t1 already exists (see XW/home/state/t1.meta); tear it down first'
xwhas 'kickoff order at'
# pi takes the effort as --thinking; cursor-agent takes the model.
xharnesses() { xworld; xbrief t4 proj --mode local-only; xbrief t5 proj --mode local-only; }
x3b() { xc t4 proj --harness pi --effort max; xc t5 proj --harness cursor --model gpt; }
xgo xharnesses x3b
xrcs '0 0 '
xwhas 'AGENTMEMORY_PROJECT_NAME=proj pi --tui-mode regular --thinking max'
xwhas $'harness=pi\neffort=max\n'
xwhas 'AGENTMEMORY_PROJECT_NAME=proj cursor-agent --yolo --model gpt'
xwhas $'harness=cursor\nmodel=gpt\n'
xscopes() { xworld; xbrief fam-s1 proj --mode local-only; xbrief fam-s2 proj --mode local-only; }
x3e() { XENV=(AC_SCOPE=fam); xc fam-s1 proj --harness fake; XENV=('AC_SCOPE=Bad!'); xc fam-s2 proj --harness fake; }
xgo xscopes x3e
xrcs '0 0 '
xwhas $'fleet_scope=fam\n'
xwlacks 'fleet_scope=Bad'
# A scope outside [A-Za-z0-9_-] is dropped under a UTF-8 locale too.
x3f() { XLC=en_US.UTF-8; XENV=(AC_SCOPE=café); xc fam-s1 proj --harness fake; }
xgo xscopes x3f
xrcs '0 '
xwlacks 'fleet_scope='
xhas 'spawned fam-s1 harness=fake'
# A domain's view holds the fleet clone; a repo elsewhere with the same
# basename is not a member.
x3g() { XENV=(AC_DOMAIN=dz); xc t2 "$XW/alt/proj" --harness fake; xc t1 proj --harness fake; }
xdomains() {
  xt1; xbrief t2 proj --mode local-only; mkdir -p "$XW/home/crewdomains/dz/projects" "$XW/alt"
  printf -- '- dz - the dz domain - scope: dz work (added 2026-01-01T00:00:00Z)\n' >"$XW/home/records/crewdomains.md"
  ln -s "$XW/home/projects/proj" "$XW/home/crewdomains/dz/projects/proj"
  git init -q "$XW/alt/proj"; printf 'alt\n' >"$XW/alt/proj/f.txt"; git -C "$XW/alt/proj" add f.txt; git -C "$XW/alt/proj" commit -qm alt
}
xgo xdomains x3g
xrcs '1 0 '
xhas "ERROR: crewdomain dz links 'proj' but this spawn would lease XW/alt/proj, not XW/proj - a matching basename is not membership"
xhas 'spawned t1 harness=fake'
# An ambiguous brief: the task's data holds both a flat and a nested one.
xambiguous() { xworld; xbrief t3 proj --mode local-only; mkdir -p "$XW/home/data/t3/implement"; cp "$XW/home/data/t3/brief.md" "$XW/home/data/t3/implement/brief.md"; }
x3h() { xc t3 proj --harness fake; }
xgo xambiguous x3h
xrcs '1 '
xhas 'ERROR: ambiguous task data for t3: briefs at both XW/home/data/t3/implement and XW/home/data/t3'
x3i() { xc t1 "$XW/proj" --harness fake; xc t2 nope --harness fake; }
xtwo() { xt1; xbrief t2 proj --mode local-only; }
xgo xtwo x3i
xrcs '0 1 '
xhas 'spawned t1 harness=fake kind=ship mode=local-only yolo=off backend=herdr window=herdr:pane-p1 worktree=XW/proj/.crew/worktrees/1-proj'
xhas 'ERROR: project not found: nope'
xmodes() {
  xworld; xbrief c1 proj --mode crew-ship --captain-requested 'order 1' --reason 'a probe'; sed -i.bak 's/^Review: .*/Review: no/' "$XW/home/data/c1/brief.md"; rm -f "$XW/home/data/c1/brief.md.bak"
  xbrief s1 proj --scout; xbrief y1 proj --mode local-only
  printf -- '- proj [+yolo] - the project (added 2026-01-01)\n' >"$XW/home/records/projects.md"
}
x3j() { xc c1 proj --harness fake; xc s1 proj --scout --harness fake; xc y1 proj --harness fake; }
xgo xmodes x3j
xrcs '1 0 0 '
xhas 'ERROR: crew-ship execution requires review=yes in XW/home/data/c1/brief.md'
xhas 'spawned s1 harness=fake kind=scout mode= yolo=on'
xhas 'spawned y1 harness=fake kind=ship mode=local-only yolo=on'
# A handle whose window is gone is no collision.
x3k() { xput home/state/.pane-t1 'p77 t77\n'; xc t1 proj --harness fake; }
xgo xt1 x3k
xrcs '0 '
xhas 'spawned t1 harness=fake'
x3l() { : >"$XW/proj/.crew"; xc t1 proj --harness fake; }
xgo xt1 x3l
xrcs '1 '
xwlacks 'home/state/t1.meta'

# -- 5: the crew path on orca -----------------------------------------------------
xorca() { xt1; printf 'orca\n' >"$XW/home/config/backend"; printf '\342\234\263 fake\n' >"$XW/orca/.default-title"; }
x5b() { : >"$XW/orca/.create-no-path"; xc t1 proj --harness fake; }
xgo xorca x5b
xrcs '1 '
xhas 'ERROR: orca worktree create failed for t1'
xwlacks 'home/state/t1.meta'
x5c() { xc t1 proj --harness fake --base-branch nope; : >"$XW/orca/.unreachable"; xc t1 proj --harness fake; }
xgo xorca x5c
xrcs '1 1 '
assert_eq "$(grep -ac '^ERROR: orca worktree create failed for t1 ' "$TMP/xt2")" "2" "spawn at line $LINENO: an unknown base and an unreachable orca"
xhas 'WARN: orca repo add failed for XW/proj'
xwlacks 'home/state/t1.meta'

# -- 6: roomchiefs ------------------------------------------------------------------
xrooms() { xworld; xroom fa; xroom fb; xroom fc; xroom fd; }
x6b() { xc --roomchief fb --harness fake --captain-initiated ''; }
xgo xrooms x6b
xrcs '1 '
xhas 'ERROR: --captain-initiated needs a non-empty order ref'
xwlacks 'home/state/fb-chief.meta'
x6c() {
  printf '1\n' >"$XW/home/config/room-parallel"; xchief fy
  xc --roomchief fa --harness fake
  XENV=(AC_ROOM_OVERCAP_REASON='the captain said'); xc --roomchief fa --harness fake
}
xgo xrooms x6c
xrcs '1 0 '
xhas 'ERROR: room-parallel cap reached: 1/1 roomchiefs in flight (fy)'
xhas 'spawned fa-chief harness=fake kind=roomchief'
xwhas 'DECIDED: fa over-cap promote, +1 past room-parallel=1 - captain sanction: the captain said'
xwhas 'initiated_by=chief'
x6e() { xput home/config/crew-dispatch.json '{"panes":{"roomchief":{"harness":"nope"}}}\n'; xc --roomchief fb; }
xgo xrooms x6e
xrcs '1 '
xhas 'ERROR: crew-dispatch panes.roomchief is present but unresolvable'
xwlacks 'home/state/fb-chief.meta'
xchiefdomain() {
  xrooms
  printf -- '- dz - the dz domain - scope: dz work (added 2026-01-01T00:00:00Z)\n' >"$XW/home/records/crewdomains.md"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] fa - work; domain:dz (repo: proj)\n- [ ] fb - work; domain:ghost (repo: proj)\n- [ ] big [EPIC] - the epic; domain:dz (repo: proj)\n- [ ] fc - a story; epic:big; domain:other (repo: proj)\n\n## Done\n' >"$XW/home/records/backlog.md"
}
x6i() { xc --roomchief fa --harness fake; xc --roomchief fb --harness fake; xc --roomchief fc --harness fake; }
xgo xchiefdomain x6i
xrcs '0 1 1 '
xwhas $'domain=dz\n'
xhas "ERROR: family fb carries domain:ghost but 'ghost' is not a VALID entry in records/crewdomains.md"
xhas 'ERROR: family fc carries domain:other but its epic row carries domain:dz - one family, one domain'
# An unreadable ledger refuses the promote.
x6l() { chmod 000 "$XW/home/records/backlog.md"; xc --roomchief fd --harness fake; chmod 644 "$XW/home/records/backlog.md"; }
xgo xchiefdomain x6l
xrcs '1 '
assert_eq "$(xt | tail -n 1)" 'ERROR: cannot read the ledger for the domain binding of fd' "spawn at line $LINENO: the refusal is the run's last line"
xwlacks 'home/state/fd-chief.meta'
xorcarooms() { xrooms; printf 'orca\n' >"$XW/home/config/backend"; printf '\342\234\263 fake\n' >"$XW/orca/.default-title"; }
x6j() { xc --roomchief fa --harness fake; xc --roomchief fb --harness fake; }
xgo xorcarooms x6j
xrcs '0 0 '
xhas 'spawned fa-chief harness=fake kind=roomchief mode=- yolo=off backend=orca window=orca:term1 scope=fa'
xhas 'spawned fb-chief harness=fake kind=roomchief mode=- yolo=off backend=orca window=orca:term2 scope=fb'
xwhas 'backend=orca'

# -- 7: crewdeputies ----------------------------------------------------------------
xdeputy() {
  xworld; xrun "$BIN/ac-home-seed.sh" dep1 --no-projects
  local d; for d in dep1 dep8 dep9; do mkdir -p "$XW/home/data/$d"; printf 'charter for %s\n' "$d" >"$XW/home/data/$d/brief.md"; done
}
x7a() { xc dep9 --crewdeputy --harness fake; }
xgo xdeputy x7a
xrcs '1 '
xhas 'ERROR: crewdeputy home not seeded: run ac-home-seed.sh dep9 first'
xwlacks 'home/state/dep9.meta'
# A custom template's first word is answered as bash 3.2's `command -v`
# answers it: a builtin passes on each path (no `exec` file on PATH).
xexec() { xdeputy; xbrief t1 proj --mode local-only; xroom fa; }
x7d() {
  printf 'exec echo crew __ID__ reading __BRIEF__\n' >"$XW/home/config/launch-fake"
  xc t1 proj --harness fake; xc --roomchief fa --harness fake; xc dep1 --crewdeputy --harness fake
}
xgo xexec x7d
xrcs '0 0 0 '
xhas 'spawned t1 harness=fake'
xhas 'spawned fa-chief harness=fake'
xhas 'spawned dep1 harness=fake'
xwhas 'exec echo crew t1 reading'

# -- 8: crew recovery ---------------------------------------------------------------
x8b() { xc t1 proj --harness fake; xdeadpane t1; xc t1 proj --recover; xbrief t2 proj --mode local-only; xc t2 proj --harness claude; xdeadpane t2; rm -rf "$XW/proj/.crew/worktrees/2-proj"; xc t2 proj --recover; }
xgo xt1 x8b
xrcs '0 1 0 1 '
xhas 'ERROR: --recover: t1 has no resumable claude session on record'
xhas 'ERROR: --recover: the recorded worktree of t2 is gone (XW/proj/.crew/worktrees/2-proj)'

# -- 9: concurrency and signals --------------------------------------------------------
x9a() {
  mkdir -p "$XW/home/state/.meta-claims/t1"; printf '%s\n' "$$" >"$XW/home/state/.meta-claims/t1/pid"
  XENV=(AC_SPAWN_META_CLAIM_TIMEOUT=2); xc t1 proj --harness fake
  printf '999999\n' >"$XW/home/state/.meta-claims/t1/pid"; touch -t 202512312300 "$XW/home/state/.meta-claims/t1"
  XENV=(); xc t1 proj --harness fake
}
xgo xt1 x9a
xrcs '1 0 '
xhas $'-- err\nERROR: another spawn still owns the pre-meta claim for t1\n'
xhas 'spawned t1 harness=fake'
# SIGNALS: TERM and HUP inside the settle sleep exit 143/129 with the cleanup
# run (lease returned, tab closed, claim released, no meta).
x9c() { printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig TERM t1 proj --harness fake; }
xgo xt1 x9c
xhas $'== TERM t1 proj --harness fake\nrc=143'
xwlacks 'home/state/t1.meta'
xwlacks 'leased=1'
xwlacks '.meta-claims/t1'
xwhas 'tab close'
x9d() { printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig HUP --roomchief fa --harness fake; }
xgo xrooms x9d
xhas $'== HUP --roomchief fa --harness fake\nrc=129'
xwlacks 'home/state/fa-chief.meta'
xwlacks '.meta-claims/fa-chief'
xwhas 'tab close'
# INT to the pid alone ends the run 130 with the cleanup run.
x9f() { printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig INT t1 proj --harness fake; }
xgo xt1 x9f
xhas $'== INT t1 proj --harness fake\nrc=130'
xwlacks 'home/state/t1.meta'
xwlacks '.meta-claims/t1'
xwlacks 'leased=1'
xwhas 'tab close'
xholder() {  # xholder <tool> <exec> <sh condition> - stub/hold/<tool>: the first call meeting <condition> holds like sleep's hold-sleep, then every call execs <exec>
  mkdir -p "$XW/stub/hold"
  printf '#!/bin/sh\nif [ ! -e "$XSTUB/hold-once" ] && { %s; }; then\n  : >"$XSTUB/hold-once"; : >"$XSTUB/held"\n  i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done\nfi\nexec %s "$@"\n' "$3" "$2" >"$XW/stub/hold/$1"
  chmod +x "$XW/stub/hold/$1"
}
# The tail hold: spawned_at's date, the meta otherwise complete.
xtailhold() { xholder date "$XSTUBS/date" "grep -q '^yolo=' \"\$XSTUB/../home/state/$1.meta\" 2>/dev/null && ! grep -q '^spawned_at=' \"\$XSTUB/../home/state/$1.meta\""; }
xheld() { XPATH="$XW/stub/hold:$XSTUBS:$PATH"; xsig "$@"; XPATH=""; }   # xheld <signal> <args...> - xsig with the world's hold stubs first on PATH
# SIGNALS: TERM before the lease (inside the brief's Mode read) ends the run
# 143 with the claim released and no slot or orca worktree leased.
xmodehold() { xholder sed /usr/bin/sed 'case "$*" in *"s/^Mode: //p"*) true ;; *) false ;; esac'; }
x9h() { xmodehold; xheld TERM t1 proj --harness fake; }
xgo xt1 x9h
xhas $'== TERM t1 proj --harness fake\nrc=143'
xwlacks 'leased=1'
xwlacks '== home/state/t1.meta '
xwlacks '.meta-claims/t1'
x9i() { xmodehold; xheld TERM t1 proj --harness fake; }
xgo xorca x9i
xhas $'== TERM t1 proj --harness fake\nrc=143'
xwlacks 'refs/heads/crew/t1'
# SIGNALS: TERM after the run's last wait, in the meta tail, still runs the
# armed cleanup - 143, the lease returned, the tab closed, no meta - on the
# crew, roomchief and crewdeputy paths.
x9j() { xtailhold t1; xheld TERM t1 proj --harness fake; }
xgo xt1 x9j
xhas $'== TERM t1 proj --harness fake\nrc=143'
xwlacks 'leased=1'
xwlacks '== home/state/t1.meta '
xwlacks 'working: spawned'
# SIGNALS: TERM in the status line's date, the meta complete, still runs the
# crew cleanup once the line is written.
x9n() { xholder date "$XSTUBS/date" "grep -q '^spawned_at=' \"\$XSTUB/../home/state/t1.meta\" 2>/dev/null"; xheld TERM t1 proj --harness fake; }
xgo xt1 x9n
xhas $'== TERM t1 proj --harness fake\nrc=143'
xwlacks 'leased=1'
xwlacks '== home/state/t1.meta '
xwhas 'working: spawned'
x9k() { xtailhold fa-chief; xheld TERM --roomchief fa --harness fake; }
xgo xrooms x9k
xhas $'== TERM --roomchief fa --harness fake\nrc=143'
xwlacks '== home/state/fa-chief.meta '
x9l() { xtailhold dep1; xheld TERM dep1 --crewdeputy --harness fake; }
xgo xdeputy x9l
xhas $'== TERM dep1 --crewdeputy --harness fake\nrc=143'
xwlacks '== home/state/dep1.meta '
# SIGNALS: TERM in a recovery's notice send ends it 143 once the send is
# whole, before its window is recorded, the claim released.
x9m() {
  xc t1 proj --harness claude; xdeadpane t1
  xholder herdr "$TMP/stubbin/herdr" 'case "$*" in *"has been RECOVERED"*) true ;; *) false ;; esac'; xheld TERM t1 proj --recover
}
xgo xt1 x9m
xhas $'== TERM t1 proj --recover\nrc=143'
xwlacks 'recovered: pane reopened'
xwlacks 'window=herdr:pane-p2'
xwlacks '.meta-claims/t1'

pass
