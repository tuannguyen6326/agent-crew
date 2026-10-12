#!/usr/bin/env bash
# ac-spawn-differential.test.sh - src/spawn.ts, started by bin/ac-spawn.sh,
# held to the frozen bash original tests/fixtures/ac-spawn.sh. Every row
# rebuilds one world at one path for each side and compares the calls (exit,
# stdout, stderr) and the world they leave; a named divergence (the
# DIVERGENCES block of the src/spawn.ts header) is pinned per side instead.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# DISPUTED: the implementation (tests/fixtures/ac-spawn.sh under bash vs src/spawn.ts through bin/ac-spawn.sh)
# HELD-CONSTANT: ONE world path ($XW) rebuilt by the row's own setup before each pass - a home (config/, records/, data/, state/, projects/proj linking the repo), the repo $XW/proj made under one git identity and one commit date, the container's .claude/CLAUDE.md, the fake herdr's and fake orca's dirs ($XW/herdr, $XW/orca), HOME=$XW/hh (bun's cache, never compared), TMPDIR=$XW/tmp, AC_CLAUDE_TRANSCRIPT_ROOT=$XW/cp, AC_GUARD_ROOT=$XW/cwd (no repo: the guard's distro checks stay silent on both sides); argv, env (AC_SPAWN_SETTLE=0, AC_KICKOFF_READY_BUDGET=5, AC_SEND_SETTLE=0, AC_STARTUP_DIALOG_BUDGET=2, AC_HERDR_RPC_TIMEOUT=10 unless a row names others), cwd $XW/cwd, stdin /dev/null, LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - date answering one instant for every format, sleep logging each call and returning at once (holding where a row says), uuidgen answering one uuid, od answering /dev/urandom from a per-world counter, and every harness CLI a never-run stand-in - ahead of the fake herdr and orca; the live bin/ siblings beside each entry, the oracle's root also linking .agents. Every call's exit, stdout and stderr compared whole once normalised (either root ROOT, a mktemp suffix XXXXXX, a temp or wake-record pid), then the world: every path under $XW but hh/ and the repo's .git with mode and bytes (a link: its target; a claim's pid: <pid>; a git index, whose stat cache differs per pass: its name), and the repo's refs, worktrees and info/exclude.
make_fake_herdr
make_fake_orca
cd "$TMP" || fail "cd TMP"
xobin="$(make_oracle_bin ac-spawn)"
cmp -s "$xobin/ac-spawn.sh" "$ROOT/tests/fixtures/ac-spawn.sh" || fail "the oracle bin holds the frozen original"
cmp -s "$BIN/ac-spawn.sh" "$ROOT/tests/fixtures/ac-spawn.sh" && fail "the live entry is the shim, not the original"
# The crew seed links skills from <root>/.agents/skills: the oracle's root
# must offer the same tree the port's does.
ln -s "$ROOT/.agents" "$TMP/oracle-ac-spawn/.agents"
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
# od: /dev/urandom is the n-th read's own bytes (lease ids differ per lease,
# match per pass); with stub/hold-od it holds like sleep does.
cat >"$XSTUBS/od" <<'STUB'
#!/bin/bash
args=()
for a in "$@"; do
  if [ "$a" = /dev/urandom ]; then
    n=$(( $(cat "$XSTUB/od.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" >"$XSTUB/od.n"
    printf '%064d' "$n" >"$XSTUB/od.rand"; a="$XSTUB/od.rand"
    if [ -e "$XSTUB/hold-od" ]; then
      : >"$XSTUB/held"
      i=0; while [ ! -e "$XSTUB/release" ] && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    fi
  fi
  args+=("$a")
done
exec /usr/bin/od "${args[@]}"
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
XLC=C; XENV=(); XPATH=""; XHOME=1; XCLOSE=""; XPASS=o; XALT=(o); XCALL=0
xe() {  # xe - the call environment into XE: the leg's stubs ahead of the fakes and the host, the world's home, tmp, HOME and backends, then the row's XENV
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
xrun() {  # xrun <cmd> <args...> - a setup step in the world's environment, quiet; a failure ends the leg
  xe; (cd "$XW/cwd" && exec "${XE[@]}" "$@") </dev/null >/dev/null 2>&1 || fail "spawn differential setup failed at line $(xrow): $*"
}
xbrief() { xrun "$BIN/ac-brief.sh" "$@"; }   # xbrief <ac-brief args> - a brief in the world
xroom() { xrun "$BIN/ac-room.sh" post "$1" crewchief "${2:-the order for $1, posted before the promote}"; }   # xroom <family> [<text>] - the room's order
xput() { mkdir -p "$(dirname "$XW/$1")"; printf '%b' "$2" >"$XW/$1"; }   # xput <path under the world> <printf %b bytes>
xside() { local side="${XALT[$((XCALL % ${#XALT[@]}))]}"; XCALL=$((XCALL + 1)); XBIN="$xobin"; [ "$side" != n ] || XBIN="$BIN"; }   # xside - this call's entry dir into XBIN, the sides taken in turn
xc() {  # xc <args...> - one spawn by this pass's side for the call, its transcript appended
  local bin rc=0
  xside; bin="$XBIN"; xe
  if [ -n "$XCLOSE" ]; then (cd "$XW/cwd" && exec "${XE[@]}" "$bin/ac-spawn.sh" "$@" >&-) </dev/null 2>"$TMP/x.err" || rc=$?; : >"$TMP/x.out"
  else (cd "$XW/cwd" && exec "${XE[@]}" "$bin/ac-spawn.sh" "$@") </dev/null >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?; fi
  { printf '== %s\nrc=%s\n-- out\n' "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
xsig() {  # xsig <signal> <args...> - one spawn in the background; once the world holds stub/held, <signal> to its pid alone, then the hold released
  local sig="$1" bin pid rc=0 i=0; shift
  xside; bin="$XBIN"; xe
  # Job control gives the job its own group with SIGINT at its default - a
  # plain `&` job of a non-interactive shell starts with SIGINT ignored.
  {
    set -m
    (cd "$XW/cwd" && exec "${XE[@]}" "$bin/ac-spawn.sh" "$@") </dev/null >"$TMP/x.out" 2>"$TMP/x.err" &
    pid=$!
    set +m
    while [ ! -e "$XW/stub/held" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.05; i=$((i + 1)); done
    [ -e "$XW/stub/held" ] || fail "spawn differential at line $(xrow): the run never reached its hold"
    kill -"$sig" "$pid"
    /bin/sleep 0.5
    : >"$XW/stub/release"
    wait "$pid" || rc=$?
  } 2>/dev/null
  /bin/sleep 0.3
  rm -f "$XW/stub/held" "$XW/stub/release" "$XW/stub/hold-sleep" "$XW/stub/hold-od"
  { printf '== %s %s\nrc=%s\n-- out\n' "$sig" "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
xnorm() {  # xnorm <file> - either root ROOT, a mktemp suffix XXXXXX, a temp or wake-record pid PID
  # The `child setpgid` line is bash's job control losing a fork race in a
  # herdr RPC's background child - SHELL-OWN, printed on no fixed call.
  LC_ALL=C sed -E -e "s#$TMP/oracle-ac-spawn#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e 's#(/archive/[^/]+/[0-9]+)\.[A-Za-z0-9]{6}#\1.XXXXXX#g' -e 's#\.tmp\.[0-9]+#.tmp.PID#g' \
    -e 's#(/\.wake-spool[^/]*/[0-9]+)\.[0-9]+\.#\1.PID.#g' \
    -e '/^ROOT\/bin\/[a-z-]+\.sh: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted$/d' "$1"
}
xsnap() {  # xsnap <pass> - the world as one listing
  local n k f us=$'\037'
  (cd "$XW" && find . \( -path ./hh -o -path ./proj/.git \) -prune -o -print) | sed 's#^\./##' >"$TMP/xnames"
  # Wake records published in one stamp share a name once their pids are
  # normalised; their bytes order them instead of the pids.
  xnorm "$TMP/xnames" | paste -d "$us" - "$TMP/xnames" | while IFS="$us" read -r n f; do
    k=""; case "$f" in */.wake-spool*/*) [ ! -f "$XW/$f" ] || k="$(tr '\t\n' '  ' <"$XW/$f")" ;; esac
    printf '%s\n' "$n$us$k$us$f"
  done | LC_ALL=C sort | while IFS="$us" read -r n k f; do
    if [ -L "$XW/$f" ]; then printf '== %s -> %s\n' "$n" "$(readlink "$XW/$f")"; continue; fi
    printf '== %s %s\n' "$n" "$(stat -f %Sp "$XW/$f")"
    case "$f" in
      */.meta-claims/*/pid) printf '<pid>\n' ;;
      */.git/index | */.git/worktrees/*/index) printf '<git index>\n' ;;
      *) [ -d "$XW/$f" ] || { cat "$XW/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'; } ;;
    esac
  done >"$TMP/xw.$1"
  { printf -- '-- refs\n'; git -C "$XW/proj" for-each-ref --format='%(refname) %(objectname)'
    printf -- '-- worktrees\n'; git -C "$XW/proj" worktree list --porcelain
    printf -- '-- exclude\n'; cat "$XW/proj/.git/info/exclude" 2>/dev/null || true
  } >>"$TMP/xw.$1"
}
xpass() {  # xpass <pass> <setup> <body> <side>... - rebuild the world, then the body's calls by the sides in turn (<setup> may carry its words)
  XPASS="$1"; : >"$TMP/xt.$1"; XCALL=0; XALT=("${@:4}")
  XLC=C; XENV=(); XPATH=""; XHOME=1; XCLOSE=""
  $2; $3; xsnap "$1"
  xnorm "$TMP/xt.$1" >"$TMP/xt2.$1"; xnorm "$TMP/xw.$1" >"$TMP/xw2.$1"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xcmpt() { cmp -s "$TMP/xt2.$1" "$TMP/xt2.$2" || fail "spawn differential calls differ ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xt2.$1" "$TMP/xt2.$2" | head -n 14)"; }
xcmpw() { cmp -s "$TMP/xw2.$1" "$TMP/xw2.$2" || fail "spawn differential world differs ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xw2.$1" "$TMP/xw2.$2" | head -n 14)"; }
xcmp() { xcmpt "$1" "$2"; xcmpw "$1" "$2"; }   # xcmp <pass> <pass> - transcripts and worlds identical
xsame() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; xcmp o n; }   # xsame <setup> <body> - the oracle alone, then the port alone
xboth() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; }   # xboth <setup> <body> - both passes, compared by the row (a named divergence)
xcont() {  # xcont <setup> <body> - the oracle alone, then the two sides alternating call by call, either side first
  xpass o "$1" "$2" o; xpass a "$1" "$2" o n; xpass b "$1" "$2" n o; xcmp o a; xcmp o b
}
xt() { cat "$TMP/xt2.${1:-n}"; }
xhas() { assert_contains "$(xt "${2:-n}")" "$1" "spawn differential at line $(xrow)"; }   # xhas <text> [<pass>] - the normalised transcript holds <text>
xlacks() { case "$(xt "${2:-n}")" in *"$1"*) fail "spawn differential at line $(xrow): '$1' found" ;; esac; }
xwhas() { assert_contains "$(cat "$TMP/xw2.${2:-n}")" "$1" "spawn differential world at line $(xrow)"; }
xwlacks() { case "$(cat "$TMP/xw2.${2:-n}")" in *"$1"*) fail "spawn differential world at line $(xrow): '$1' found" ;; esac; }
# SHELL-OWN STDERR (named): bash's own error lines - an unbound $2, `[`'s
# integer complaint, a redirection or a printf write error - are not
# reproduced; xownless sets them aside in the oracle's transcript.
xownless() { LC_ALL=C sed -E -i.bak '/^ROOT\/bin\/[a-z-]+\.sh: line [0-9]+: /d' "$TMP/xt2.o"; }
xwithout() {  # xwithout <tool> - the leg's stubs and PATH with every dir holding <tool> mirrored without it
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

# -- leg 1: preamble ------------------------------------------------------------
x1a() {
  xc; xc -h; xc --bogus; xc t1 proj extra; xc --captain-initiated x; xc --solo t1 proj
  xc t1 proj --recover --resume-from t0; xc --roomchief f --codereview-rule 1; xc t1 --crewdeputy --base-branch main
  xc t1 proj --base-branch ''
}
xsame xworld x1a
xhas 'unknown flag: -h'
xhas 'unexpected arg: extra'
xhas '--base-branch names the branch the orca lease is cut from'
x1b() {
  XENV=(AC_SOLO=1); xc t1 proj
  XENV=(AC_SOLO=1 AC_BACKEND=tmux); xc t1 proj
  XENV=(AC_BACKEND=tmux); xc t1 proj
  XENV=(); printf 'tmux\n' >"$XW/home/config/backend"; xc t1 proj
}
xsame xworld x1b
xhas 'a solo session (AC_SOLO=1) never spawns crew'
xhas "unsupported backend 'tmux'"
x1c() { XHOME=""; xc t1 proj --harness fake; xc --roomchief fa --harness fake; }
xsame xt1 x1c
xhas 'AC_HOME is not set'
x1d() { XPATH="$(xwithout git)"; xc t1 proj --harness fake; }
xsame xt1 x1d
xhas 'required tool not found: git'
# BUN (named): with no bun the original runs on until a bun-started child (the
# advisory guard, then the lease) refuses; the shim refuses before anything.
x1e() { XPATH="$(xwithout bun)"; xc -h; xc t1 proj --harness fake; }
xboth xt1 x1e
xhas $'== -h\nrc=1\n-- out\n-- err\nERROR: required tool not found: bun\nERROR: unknown flag: -h' o
assert_eq "$(grep -c '^ERROR: required tool not found: bun$' "$TMP/xt2.n")" "2" "the port's shim refuses both calls on bun alone"
xhas $'== -h\nrc=1\n-- out\n-- err\nERROR: required tool not found: bun\n== ' n
xwlacks 'home/state/.meta-claims' n
# W14 (named): a valueless value flag ended the original on bash's own
# `$2: unbound variable`; the port exits 1 with no line of its own.
x1f() { xc t1 proj --harness; xc --roomchief; xc t1 proj --mode; }
xboth xt1 x1f
assert_eq "$(grep -c '^rc=1$' "$TMP/xt2.o")" "3" "every valueless flag ends the original 1"
assert_eq "$(grep -c '^rc=1$' "$TMP/xt2.n")" "3" "every valueless flag ends the port 1"
xhas 'unbound variable' o
xlacks 'unbound variable' n
xownless; xcmp o n

# -- leg 2: grammar and order -----------------------------------------------------
x2a() {
  xc bad_id proj; xc BadId proj; xc --roomchief bad_family; xc --roomchief Café; xc --roomchief f --scout
  xc --roomchief f t1; xc t1 --crewdeputy --scout; xc t1 proj --crewdeputy; xc --crewdeputy; xc t1 proj --effort bogus
}
xsame xworld x2a
xhas 'id must be [a-z0-9-]: bad_id'
xhas 'family must be [a-z0-9-]: Café'
xhas 'invalid effort: bogus'
x2b() { XLC=en_US.UTF-8; xc --roomchief Café; xc Café proj; xc t1 proj --effort ultracodé; }
xsame xworld x2b
xhas 'family must be [a-z0-9-]: Café'
x2c() {
  XENV=(AC_SPAWN_SETTLE=abc); xc t1 proj --harness fake
  XENV=(AC_KICKOFF_READY_BUDGET=1.5); xc t1 proj --harness fake
  XENV=(AC_ULTRACODE_SETTLE=x); xc t1 proj --harness fake
  XENV=(AC_ULTRACODE_SETTLE=x); xc t2 proj --harness claude --effort ultracode
  XENV=(); xc t3 proj --harness fake --base-branch main
}
xknobs() { xt1; xbrief t2 proj --mode local-only; xbrief t3 proj --mode local-only; }
xsame xknobs x2c
xhas 'AC_SPAWN_SETTLE must be'
xhas 'spawned t1 harness=fake'
xhas 'requires an orca-backend'
x2d() {
  xc t9 proj --harness fake
  xc t1 proj --harness fake --mode bogus
  xc t1 proj --harness fake --mode direct-pr
  sed -i.bak '/^Review: /d' "$XW/home/data/t1/brief.md"; xc t1 proj --harness fake
  printf 'Review: maybe\n' >>"$XW/home/data/t1/brief.md"; xc t1 proj --harness fake
  sed -i.bak -e '/^Review: /d' -e '/^Mode: /d' "$XW/home/data/t1/brief.md"; printf 'Review: no\n' >>"$XW/home/data/t1/brief.md"; xc t1 proj --harness fake
  rm -f "$XW/home/data/t1/brief.md.bak"
}
xsame xt1 x2d
xhas 'invalid --mode: bogus'
xhas "no 'Mode:' line in"
# --resume-from: a meta that never existed, a non-claude one, one with no
# session, and W12 (at parity) - --harness overridden by the resumed claude.
xresumeworld() {
  xt1
  xput home/state/t0.meta "kind=ship\nbackend=herdr\nharness=claude\nsession_id=0f4a1b2c-3d4e-4f50-8a61-72b3c4d5e6f7\nworktree=$XW/proj/.crew/worktrees/1-proj\nproject_dir=$XW/proj\n"
  xput home/state/t8.meta "kind=ship\nbackend=herdr\nharness=codex\nworktree=$XW/proj\n"
  xput home/state/t7.meta "kind=ship\nbackend=herdr\nharness=claude\nworktree=$XW/proj\n"
}
x2e() { xc t1 proj --resume-from t5; xc t1 proj --resume-from t8; xc t1 proj --resume-from t7; xc t1 proj --harness fake --resume-from t0; }
xsame xresumeworld x2e
xhas 'was not a claude session'
xhas 'spawned t1 harness=claude'

# -- leg 3: the crew path on herdr --------------------------------------------------
x3a() { xc t1 proj --harness fake --mode local-only; xc t1 proj --harness fake; }
xsame xt1 x3a
xhas 'spawned t1 harness=fake kind=ship mode=local-only yolo=off backend=herdr'
xhas 'already exists'
xwhas 'kickoff order at'
xharnesses() { xworld; local i; for i in 1 2 3 4 5 6; do xbrief "t$i" proj --mode local-only; done; }
x3b() {
  xc t1 proj --harness claude --model opus --effort high; xc t2 proj --harness codex --effort ultracode
  xc t3 proj --harness opencode --model m/x --effort low; xc t4 proj --harness pi --effort max
  xc t5 proj --harness cursor --model gpt; xc t6 proj --harness claude --effort ultracode
}
xsame xharnesses x3b
xhas 'spawned t6 harness=claude'
xwhas '/effort ultracode'
xdispatch() { xt1; xput home/config/crew-dispatch.json '{"rules":[],"default":{"harness":"fake"},"panes":{"qa":{"harness":"nope"},"codereview":{"harness":"fake"}}}\n'; }
x3c() { xc t1 proj; xc t1 proj --harness fake --codereview-rule 1; xc t1 proj --harness fake; }
xsame xdispatch x3c
xhas 'config/crew-dispatch.json is configured: pick a profile'
x3d() {
  local k; for k in codereview-agent:codex codereview-model:sonnet qa-effort:low; do printf '%s\n' "${k#*:}" >"$XW/home/config/${k%%:*}"; done
  printf 'gpt\n' >"$XW/home/config/model"; printf 'high\n' >"$XW/home/config/effort"
  XENV=(CLAUDE_CONFIG_DIR="$XW/ccd"); xc t1 proj --harness claude
}
xsame xt1 x3d
xwhas 'AC_FLEET_AGENT_CODEREVIEW=codex'
xscopes() { xworld; xbrief fam-s1 proj --mode local-only; xbrief fam-s2 proj --mode local-only; }
x3e() { XENV=(AC_SCOPE=fam); xc fam-s1 proj --harness fake; XENV=('AC_SCOPE=Bad!'); xc fam-s2 proj --harness fake; }
xsame xscopes x3e
xwhas 'fleet_scope=fam'
# W10 (named): a scope outside [A-Za-z0-9_-] under a UTF-8 locale - the
# original's bracket range let `café` through; the port reads the grammar per
# its text and drops it.
x3f() { XLC=en_US.UTF-8; XENV=(AC_SCOPE=café); xc fam-s1 proj --harness fake; }
xboth xscopes x3f
xwhas 'fleet_scope=café' o
xwlacks 'fleet_scope=café' n
xhas 'spawned fam-s1 harness=fake' o
xhas 'spawned fam-s1 harness=fake' n
x3g() {
  XENV=(AC_DOMAIN=dz); xc t1 proj --harness fake
  ln -s "$XW/elsewhere" "$XW/home/crewdomains/dz/projects/proj"; xc t1 proj --harness fake
  rm "$XW/home/crewdomains/dz/projects/proj"; ln -s "$XW/proj" "$XW/home/crewdomains/dz/projects/proj"; xc t1 proj --harness fake
  rm "$XW/home/crewdomains/dz/projects/proj"; ln -s "$XW/home/projects/proj" "$XW/home/crewdomains/dz/projects/proj"
  xc t2 "$XW/alt/proj" --harness fake; xc t1 proj --harness fake
}
xdomains() {
  xt1; xbrief t2 proj --mode local-only; mkdir -p "$XW/home/crewdomains/dz/projects" "$XW/alt"
  printf -- '- dz - the dz domain - scope: dz work (added 2026-01-01T00:00:00Z)\n' >"$XW/home/records/crewdomains.md"
  git init -q "$XW/alt/proj"; printf 'alt\n' >"$XW/alt/proj/f.txt"; git -C "$XW/alt/proj" add f.txt; git -C "$XW/alt/proj" commit -qm alt
}
xsame xdomains x3g
xhas 'not-symlink'
xhas 'a matching basename is not membership'
xhas 'spawned t1 harness=fake'
# The branch collision (crew/<family> with no task in flight to own it, then
# owned by an in-flight stage of the family) and an ambiguous brief.
xcollide() {
  xworld; xbrief t1 proj --mode local-only; xbrief fam2 proj --mode local-only; xbrief t3 proj --mode local-only
  git -C "$XW/proj" branch crew/t1; git -C "$XW/proj" branch crew/fam2
  mkdir -p "$XW/home/data/fam2/plan" "$XW/home/data/t3/implement"; xput home/state/fam2-plan.meta 'kind=ship\nbackend=herdr\n'
  cp "$XW/home/data/t3/brief.md" "$XW/home/data/t3/implement/brief.md"
}
x3h() { xc t1 proj --harness fake; xc fam2 proj --harness fake; xc t3 proj --harness fake; }
xsame xcollide x3h
xhas 'then spawn again'
xhas 'spawned fam2 harness=fake'
xhas 'ambiguous task data for t3'
x3i() { xc t1 "$XW/proj" --harness fake; xc t2 nope --harness fake; }
xtwo() { xt1; xbrief t2 proj --mode local-only; }
xsame xtwo x3i
xhas 'project not found: nope'
xmodes() {
  xworld; xbrief c1 proj --mode crew-ship --captain-requested 'order 1' --reason 'a probe'; sed -i.bak 's/^Review: .*/Review: no/' "$XW/home/data/c1/brief.md"; rm -f "$XW/home/data/c1/brief.md.bak"
  xbrief s1 proj --scout; xbrief y1 proj --mode local-only
  printf -- '- proj [+yolo] - the project (added 2026-01-01)\n' >"$XW/home/records/projects.md"
}
x3j() { xc c1 proj --harness fake; xc s1 proj --scout --harness fake; xc y1 proj --harness fake; }
xsame xmodes x3j
xhas 'requires review=yes'
xhas 'spawned s1 harness=fake kind=scout'
xhas 'yolo=on'
# The window collision: alive, unobservable, gone.
x3k() {
  xput home/state/.pane-t1 'p77 t77\n'; xput herdr/tabs/t77 'p77 crew:t1\n'; : >"$XW/herdr/panes/p77.buf"
  xc t1 proj --harness fake
  : >"$XW/herdr/.pane-api-down"; xc t1 proj --harness fake; rm -f "$XW/herdr/.pane-api-down"
  rm -f "$XW/herdr/tabs/t77" "$XW/herdr/panes/p77.buf"; xc t1 proj --harness fake
}
xsame xt1 x3k
xhas 'already exists'
xhas 'spawned t1 harness=fake'
x3l() { : >"$XW/proj/.crew"; xc t1 proj --harness fake; }
xsame xt1 x3l
xwlacks 'home/state/t1.meta'
# W8 (at parity): a retired legacy project config beside the canonical one
# leaves the launch line with no AC_FLEET_PROJECT_CONFIG.
x3m() { xput home/projects/proj.yaml 'commands:\n  test: "true"\n'; xput home/config/projects/proj.yaml 'commands:\n  test: "false"\n'; xc t1 proj --harness fake; xc t2 proj --harness fake; }
xlegacy() { xt1; xbrief t2 proj --mode local-only; }
xsame xlegacy x3m
xwhas 'AC_FLEET_HOME_CHECKED=1'
xmirror() {
  xt1; printf 'on\n' >"$XW/home/config/remote-mirror"
  xput home/config/remote-reply '#!/bin/sh\n{ cat; printf "rid=%s\\n" "$AC_REMOTE_RID"; } >>"$XSTUB/remote.log"\nprintf "1700.11\\n"\n'
  chmod +x "$XW/home/config/remote-reply"
}
x3n() { xc t1 proj --harness fake; }
xsame xmirror x3n
xwhas 'rid=t1'

# -- leg 4: crew failure tails --------------------------------------------------------
# W1a (at parity): an unwritable status after the complete meta ends the run 1,
# and the still-armed cleanup deletes the meta, returns the slot, closes the tab
# (bash's own `Is a directory` lines set aside - SHELL-OWN).
x4a() { mkdir -p "$XW/home/state/t1.status"; xc t1 proj --harness fake; }
xboth xt1 x4a
xhas 'Is a directory' o
xownless; xcmp o n
xhas $'rc=1'
xwlacks 'home/state/t1.meta'
# W1b (at parity): a closed stdout exits 1 after the meta is durable (bash's
# own `printf: write error` set aside - SHELL-OWN).
x4b() { XCLOSE=1; xc t1 proj --harness fake; }
xboth xt1 x4b
xhas 'printf: write error' o
xownless; xcmp o n
xhas $'rc=1'
xwhas 'home/state/t1.meta'
# W5 (at parity): a non-JSON `tab list --workspace` ends the spawn with jq's
# status, after the tab exists and before its handle.
x4c() {
  mkdir -p "$XW/stub/w5"
  printf '#!/bin/sh\ncase "$*" in "tab list --workspace"*) echo garbage; exit 0 ;; esac\nexec "%s" "$@"\n' "$TMP/stubbin/herdr" >"$XW/stub/w5/herdr"
  chmod +x "$XW/stub/w5/herdr"; XPATH="$XSTUBS:$XW/stub/w5:$PATH"; xc t1 proj --harness fake
}
xsame xt1 x4c
xhas $'rc=5'
# W6 (at parity): `.` passes the settle grammar and dies in sleep.
x4d() { XENV=(AC_SPAWN_SETTLE=.); xc t1 proj --harness fake; }
xsame xt1 x4d
xhas $'rc=1'
x4e() { : >"$XW/herdr/.spawn-dead"; xc t1 proj --harness fake; }
xsame xt1 x4e
xhas 'fake did NOT come up in herdr:pane-p1'
x4f() { printf 'kickoff order\n' >"$XW/herdr/.die-on-text"; xc t1 proj --harness fake; }
xsame xt1 x4f
x4g() { rm -f "$XW/herdr/.pane-idle-by-default"; XENV=(AC_KICKOFF_READY_BUDGET=2); xc t1 proj --harness fake; }
xsame xt1 x4g
xhas "fake's input surface did NOT become ready"
x4h() { : >"$XW/herdr/.probe-unreadable"; xc t1 proj --harness fake; }
xsame xt1 x4h
x4i() { printf '1 kickoff order\n' >"$XW/herdr/panes/p1.drop-enters"; xc t1 proj --harness fake; }
xsame xt1 x4i
x4j() { printf '9 /effort\n' >"$XW/herdr/panes/p1.drop-enters"; xc t1 proj --harness claude --effort ultracode; }
xsame xt1 x4j
xhas "WARNING: '/effort ultracode' NOT acknowledged"
x4k() { printf '9 echo crew\n' >"$XW/herdr/panes/p1.drop-enters"; xc t1 proj --harness fake; }
xsame xt1 x4k
x4l() { printf '1 kickoff order\n' >"$XW/herdr/panes/p1.drop-enters"; xc t1 proj --harness claude; }
xsame xt1 x4l

# -- leg 5: the crew path on orca -----------------------------------------------------
xorca() { xt1; printf 'orca\n' >"$XW/home/config/backend"; printf '\342\234\263 fake\n' >"$XW/orca/.default-title"; }
x5a() { xc t1 proj --harness fake --base-branch main; }
xsame xorca x5a
xhas 'spawned t1 harness=fake'
xwhas 'worktree_backend=orca'
x5b() { : >"$XW/orca/.create-no-path"; xc t1 proj --harness fake; }
xsame xorca x5b
x5c() { xc t1 proj --harness fake --base-branch nope; : >"$XW/orca/.unreachable"; xc t1 proj --harness fake; }
xsame xorca x5c

# -- leg 6: roomchiefs ------------------------------------------------------------------
x6a() { xc --roomchief fa --harness fake; xc --roomchief fz --harness fake; }
xrooms() { xworld; xroom fa; xroom fb; xroom fc; xroom fd; }
xsame xrooms x6a
xhas 'holds no entry'
xwhas 'kind=roomchief'
x6b() { xc --roomchief fa --harness fake --solo; xc --roomchief fb --harness fake --captain-initiated ''; xc --roomchief fb --harness fake --captain-initiated 'order 1'; xc --roomchief fc --harness fake --system-initiated 'rule 2'; }
xsame xrooms x6b
xwhas 'solo=1'
xwhas 'initiated_by=captain'
x6c() {
  printf '1\n' >"$XW/home/config/room-parallel"; xchief fy
  xc --roomchief fa --harness fake; xc --roomchief fa --harness fake --over-cap ''
  XENV=(AC_ROOM_OVERCAP_REASON='the captain said'); xc --roomchief fa --harness fake
  XENV=(); xc --roomchief fb --harness fake --over-cap 'the captain said'
}
xsame xrooms x6c
xhas 'room-parallel cap reached: 1/1'
xhas 'over-cap promote needs'
# W7 (at parity): an unreadable chief meta does not count toward the cap.
x6d() { printf '1\n' >"$XW/home/config/room-parallel"; xchief fy; chmod 000 "$XW/home/state/fy-chief.meta"; xc --roomchief fa --harness fake; chmod 644 "$XW/home/state/fy-chief.meta"; }
xsame xrooms x6d
xhas 'cannot read meta file'
xhas 'scope=fa'
x6e() {
  xput home/config/crew-harness 'fake\n'; xc --roomchief fa
  xput home/config/crew-dispatch.json '{"panes":{"roomchief":{"harness":"nope"}}}\n'; xc --roomchief fb
}
xsame xrooms x6e
xhas 'panes.roomchief is present but unresolvable'
# The orphan reap: a live tab still labelled for the id is reaped first.
x6f() { xput home/state/.pane-fa-chief 'p77 t77\n'; xput herdr/tabs/t77 'p77 crew:fa-chief\n'; : >"$XW/herdr/panes/p77.buf"; xc --roomchief fa --harness fake; }
xsame xrooms x6f
xwhas 'tab close t77'
xchiefmirror() {
  xrooms; printf 'chief\n' >"$XW/home/config/remote-mirror"
  xput home/config/remote-reply '#!/bin/sh\n{ cat; printf "rid=%s\\n" "$AC_REMOTE_RID"; } >>"$XSTUB/remote.log"\nprintf "1700.11\\n"\n'
  chmod +x "$XW/home/config/remote-reply"
  xroom fa 'ORDER: build the thing the captain asked for'
  xroom fb "ORDER: $(printf '%0400d' 7)"
}
x6g() { xc --roomchief fa --harness fake; xc --roomchief fb --harness fake; XLC=en_US.UTF-8; xc --roomchief fc --harness fake; }
xsame xchiefmirror x6g
xwhas 'ORDER: build the thing'
# W9 (at parity): an invalid byte in the ORDER line ends a UTF-8 promote 1
# after its meta.
# The room post itself would decode the byte, so the line is planted raw.
xbadorder() { xchiefmirror; printf -- '- [2026-01-01T00:00:00Z] crewchief> ORDER: caf\351 order\n' >>"$XW/home/data/fd/room.md"; }
x6h() { XLC=en_US.UTF-8; xc --roomchief fd --harness fake; }
xsame xbadorder x6h
xhas 'sed: RE error: illegal byte sequence'
xwhas 'home/state/fd-chief.meta'
# A closed stdout after a promote's meta warns and exits 0. SHELL-OWN (named):
# the original's printf also reported its write error, and the outcome line its
# stdio still held came out on stderr through the warning's redirection.
x6k() { XCLOSE=1; xc --roomchief fa --harness fake; }
xboth xrooms x6k
xhas 'printf: write error' o
xhas $'\nspawned fa-chief harness=fake' o
LC_ALL=C sed -i.bak '/^spawned fa-chief /d' "$TMP/xt2.o"
xownless; xcmp o n
xhas 'its outcome line could not be printed'
xchiefdomain() {
  xrooms
  printf -- '- dz - the dz domain - scope: dz work (added 2026-01-01T00:00:00Z)\n' >"$XW/home/records/crewdomains.md"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] fa - work; domain:dz (repo: proj)\n- [ ] fb - work; domain:ghost (repo: proj)\n- [ ] big [EPIC] - the epic; domain:dz (repo: proj)\n- [ ] fc - a story; epic:big; domain:other (repo: proj)\n\n## Done\n' >"$XW/home/records/backlog.md"
}
x6i() { xc --roomchief fa --harness fake; xc --roomchief fb --harness fake; xc --roomchief fc --harness fake; }
xsame xchiefdomain x6i
xwhas 'domain=dz'
xhas 'one family, one domain'
# An unreadable ledger refuses the promote; the original's awk also printed its
# own `can't open file` pair, which the in-process parser does not (named).
x6l() { chmod 000 "$XW/home/records/backlog.md"; xc --roomchief fd --harness fake; chmod 644 "$XW/home/records/backlog.md"; }
xboth xchiefdomain x6l
xhas "awk: can't open file" o
LC_ALL=C sed -i.bak -e "/^awk: can't open file /d" -e '/^ source line number /d' "$TMP/xt2.o"
xcmp o n
xhas 'cannot read the ledger for the domain binding of fd'
xorcarooms() { xrooms; printf 'orca\n' >"$XW/home/config/backend"; printf '\342\234\263 fake\n' >"$XW/orca/.default-title"; }
x6j() { xc --roomchief fa --harness fake; xc --roomchief fb --harness fake; }
xsame xorcarooms x6j
xwhas 'backend=orca'

# -- leg 7: crewdeputies ----------------------------------------------------------------
xdeputy() {
  xworld; xrun "$BIN/ac-home-seed.sh" dep1 --no-projects
  local d; for d in dep1 dep8 dep9; do mkdir -p "$XW/home/data/$d"; printf 'charter for %s\n' "$d" >"$XW/home/data/$d/brief.md"; done
}
x7a() {
  xc dep9 --crewdeputy --harness fake; xc dep8 --crewdeputy --harness fake --recover; xc dep1 --crewdeputy --harness fake --recover
  xc dep1 --crewdeputy --harness fake; xc dep1 --crewdeputy --harness fake --recover
  xdeadpane dep1; xc dep1 --crewdeputy --harness fake --recover
}
xsame xdeputy x7a
xhas 'crewdeputy home not seeded'
xhas 'is LIVE'
xwhas 'kind=crewdeputy'
x7b() { xc dep1 --crewdeputy --harness fake; sed -i.bak 's/^backend=.*/backend=tmux/' "$XW/home/state/dep1.meta"; rm -f "$XW/home/state/dep1.meta.bak"; xc dep1 --crewdeputy --harness fake --recover; }
xsame xdeputy x7b
# W1 (at parity): a closed stdout ends a crewdeputy spawn 1 after its meta is
# durable, and its recovery the same (bash's own `printf: write error` set
# aside - SHELL-OWN).
x7c() { XCLOSE=1; xc dep1 --crewdeputy --harness fake; xdeadpane dep1; xc dep1 --crewdeputy --harness fake --recover; }
xboth xdeputy x7c
xhas 'printf: write error' o
xownless; xcmp o n
xhas $'== dep1 --crewdeputy --harness fake\nrc=1'
xhas $'== dep1 --crewdeputy --harness fake --recover\nrc=1'
xwhas 'kind=crewdeputy'
# A custom template's first word is answered as bash 3.2's `command -v`
# answers it: a builtin passes on each path (no `exec` file on PATH), and a
# leading assignment stays refused (W11, at parity).
xexec() { xdeputy; xbrief t1 proj --mode local-only; xroom fa; }
x7d() {
  printf 'X=1 echo crew __ID__ reading __BRIEF__\n' >"$XW/home/config/launch-fake"; xc t1 proj --harness fake
  printf 'exec echo crew __ID__ reading __BRIEF__\n' >"$XW/home/config/launch-fake"
  xc t1 proj --harness fake; xc --roomchief fa --harness fake; xc dep1 --crewdeputy --harness fake
}
xsame xexec x7d
xhas 'harness binary not found: X=1'
xhas 'spawned t1 harness=fake'
xhas 'spawned fa-chief harness=fake'
xhas 'spawned dep1 harness=fake'
xwhas 'exec echo crew t1 reading'

# -- leg 8: crew and roomchief recovery ---------------------------------------------------
x8a() {
  xc t1 proj --recover; xc t1 proj --harness claude; xc t1 proj --recover
  xdeadpane t1; xc t1 proj --recover --harness fake --model m
  : >"$XW/herdr/.unreachable"; xc t1 proj --recover; rm -f "$XW/herdr/.unreachable"
}
xsame xt1 x8a
xhas 'recovered t1'
x8b() { xc t1 proj --harness fake; xdeadpane t1; xc t1 proj --recover; xbrief t2 proj --mode local-only; xc t2 proj --harness claude; xdeadpane t2; rm -rf "$XW/proj/.crew/worktrees/2-proj"; xc t2 proj --recover; }
xsame xt1 x8b
xhas 'no resumable claude session'
# W12c (at parity): a scout recovered without --scout meets the execution
# brief's Review gate.
xscout() { xworld; xbrief s1 proj --scout; }
x8c() { xc s1 proj --scout --harness claude; xdeadpane s1; xc s1 proj --recover; xc s1 proj --scout --recover; }
xsame xscout x8c
xhas 'execution brief must carry exactly one Review'
x8d() { xc --roomchief fa --harness claude; xdeadpane fa-chief; xc --roomchief fa --recover; }
xsame xrooms x8d
xhas 'recovered fa-chief'
# W12b (at parity): a recovery dying between the new window and the meta
# leaves the new pane up while the meta keeps the old window.
x8e() { xc t1 proj --harness claude; xdeadpane t1; XENV=(AC_SPAWN_SETTLE=.); xc t1 proj --recover; XENV=(); xc t1 proj --recover; }
xsame xt1 x8e
xhas 'is LIVE'

# -- leg 9: concurrency and signals --------------------------------------------------------
x9a() {
  mkdir -p "$XW/home/state/.meta-claims/t1"; printf '%s\n' "$$" >"$XW/home/state/.meta-claims/t1/pid"
  XENV=(AC_SPAWN_META_CLAIM_TIMEOUT=2); xc t1 proj --harness fake
  printf '999999\n' >"$XW/home/state/.meta-claims/t1/pid"; touch -t 202512312300 "$XW/home/state/.meta-claims/t1"
  XENV=(); xc t1 proj --harness fake
}
xsame xt1 x9a
xhas 'another spawn still owns the pre-meta claim for t1'
xhas 'spawned t1 harness=fake'
# W13 (named): a non-integer grace - the original's `[` prints its own line
# each round; the claim verdicts match once those lines are set aside.
x9b() {
  mkdir -p "$XW/home/state/.meta-claims/t1"; printf '999999\n' >"$XW/home/state/.meta-claims/t1/pid"; touch -t 202512312300 "$XW/home/state/.meta-claims/t1"
  XENV=(AC_SPAWN_META_CLAIM_TIMEOUT=2 AC_SPAWN_META_CLAIM_STALE_GRACE=abc); xc t1 proj --harness fake
}
xboth xt1 x9b
xhas 'integer expression expected' o
xownless; xcmp o n
xhas 'another spawn still owns the pre-meta claim for t1'
# SIGNALS: TERM and HUP inside the settle sleep exit 143/129 with the cleanup
# run (lease returned, tab closed, claim released, no meta).
x9c() { printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig TERM t1 proj --harness fake; }
xsame xt1 x9c
xhas $'== TERM t1 proj --harness fake\nrc=143'
xwlacks 'home/state/t1.meta'
x9d() { printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig HUP --roomchief fa --harness fake; }
xsame xrooms x9d
xhas $'== HUP --roomchief fa --harness fake\nrc=129'
# W2 (at parity): TERM inside the lease is deferred until the lease returns;
# the run then ends 143 with the claim released and the slot still leased.
x9e() { : >"$XW/stub/hold-od"; xsig TERM t1 proj --harness fake; }
xsame xt1 x9e
xhas 'rc=143'
xwhas 'leased=1'
# INT (named): to the pid alone the original swallows it and completes; the
# port ends 130 with the cleanup run.
x9f() { printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig INT t1 proj --harness fake; }
xboth xt1 x9f
xhas $'== INT t1 proj --harness fake\nrc=0' o
xwhas 'home/state/t1.meta' o
xhas $'== INT t1 proj --harness fake\nrc=130' n
xwlacks 'home/state/t1.meta' n
xwlacks '.meta-claims/t1' n
# W3 (at parity): KILL strands claim, lease, tab and handle; a re-spawn past
# the grace leases another slot, then refuses the existing window.
x9g() {
  printf '7\n' >"$XW/stub/hold-sleep"; XENV=(AC_SPAWN_SETTLE=7); xsig KILL t1 proj --harness fake
  touch -t 202512312300 "$XW/home/state/.meta-claims/t1"; XENV=(); xc t1 proj --harness fake
}
xsame xt1 x9g
xhas 'rc=137'
xhas 'already exists'

# -- leg 10: continuation -----------------------------------------------------------------
# A task spawned by one side is recovered by the other, and a promote by one
# side is counted by the other's cap - either side first.
x10a() {
  xc t1 proj --harness claude; xdeadpane t1; xc t1 proj --recover
  printf '1\n' >"$XW/home/config/room-parallel"; xc --roomchief fa --harness fake; xc --roomchief fb --harness fake
}
xcontworld() { xrooms; xbrief t1 proj --mode local-only; }
xcont xcontworld x10a
xhas 'recovered t1' a
xhas 'room-parallel cap reached: 1/1' b

pass
