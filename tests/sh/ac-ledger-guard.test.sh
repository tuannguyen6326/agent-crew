#!/usr/bin/env bash
# ac-ledger-guard.test.sh - the PreToolUse fence that keeps a SCOPED session
# (a roomchief, AC_SCOPE set) from writing records/backlog.md,
# records/projects.md or records/captain.md - the crewchief's own ledgers.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

guard="$BIN/ac-ledger-guard.sh"

# hook <scope> <tool> <path-field> <path> -> exit code of the guard run there
hook() {
  local scope="$1" tool="$2" field="$3" path="$4" rc=0
  ( printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$tool" "$field" "$path" \
    | AC_SCOPE="$scope" "$guard" >/dev/null 2>&1 ) || rc=$?
  printf '%s\n' "$rc"
}

# --- unscoped (the crewchief itself): never fenced --------------------------

assert_eq "$(hook '' Edit file_path /home/fleet/records/backlog.md)" "0" \
  "an unscoped session (the crewchief) may edit backlog.md"
assert_eq "$(hook '' Write file_path /home/fleet/records/projects.md)" "0" \
  "an unscoped session may write projects.md"

# --- scoped (a roomchief): the two ledgers are refused ----------------------

for f in records/backlog.md records/projects.md; do
  assert_eq "$(hook fam1 Edit file_path "/home/fleet/$f")" "2" \
    "a scoped session editing $f (absolute path) is refused"
  assert_eq "$(hook fam1 Write file_path "$f")" "2" \
    "a scoped session writing $f (relative path) is refused"
done
err="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/home/fleet/records/backlog.md"}}' \
  | AC_SCOPE=fam1 "$guard" 2>&1 >/dev/null)" || true
assert_contains "$err" "the crewchief owns" "the deny message names the owner"
assert_contains "$err" "AC_SCOPE=fam1" "the deny message names the offending scope"

# NotebookEdit uses notebook_path, not file_path.
assert_eq "$(hook fam1 NotebookEdit notebook_path records/backlog.md)" "2" \
  "NotebookEdit on the ledger is refused too"

# --- scoped, but an unrelated file: untouched -------------------------------

# records/captain.md USED to be the example of an unfenced ledger here. RC-6
# moved it inside the fence - the fleet captain file now carries the
# `STANDING (domain:<name>): ` rules a domainchief reads as its law - so the
# unfenced example is a genuinely unrelated records file instead.
assert_eq "$(hook fam1 Edit file_path /home/fleet/records/learnings.md)" "0" \
  "a scoped session may still edit an unfenced ledger (learnings.md - it notes lessons there)"
assert_eq "$(hook fam1 Edit file_path /home/fleet/data/fam1/room.md)" "0" \
  "a scoped session may edit its own family's files"

# --- scoped, but not an Edit/Write/NotebookEdit shape: untouched ------------

assert_eq "$(hook fam1 Bash command 'true')" "0" \
  "Bash is not fenced by this guard (residual: sed/echo still get through)"
assert_eq "$(hook fam1 Read file_path /home/fleet/records/backlog.md)" "0" \
  "a read of the ledger is never refused"

# mcp__ tools are never classified, even when named suggestively.
rc=0
( AC_SCOPE=fam1 printf '{"tool_name":"mcp__thing__Edit","tool_input":{"file_path":"records/backlog.md"}}' \
  | AC_SCOPE=fam1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an mcp__ name is never classified"

# --- fail-open, every way ----------------------------------------------------

rc=0; ( printf '' | AC_SCOPE=fam1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an empty payload fails open"
rc=0; ( printf 'not json' | AC_SCOPE=fam1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an unparseable payload fails open"
rc=0; ( printf '{"tool_input":{"file_path":"records/backlog.md"}}' \
  | AC_SCOPE=fam1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a payload with no tool_name fails open"
rc=0; ( printf '{"tool_name":"Edit","tool_input":{}}' \
  | AC_SCOPE=fam1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an Edit payload with no file_path fails open"

# --- RC-6: records/captain.md joins the fence --------------------------------
# The FLEET captain file now carries domain standing rules - the
# `STANDING (domain:<name>): ` lines a domainchief reads as its LAW. A scoped
# session governed by a layer must not be able to edit that layer.

assert_eq "$(hook fam1 Edit file_path /home/fleet/records/captain.md)" "2" \
  "AC-7.5: a scoped session editing records/captain.md is refused"
assert_eq "$(hook fam1 Write file_path records/captain.md)" "2" \
  "AC-7.5: the relative form too"
assert_eq "$(hook '' Edit file_path /home/fleet/records/captain.md)" "0" \
  "AC-7.5: the crewchief itself is never fenced"

# The message shape matches the other two fenced ledgers, and it names all
# three - a refusal that named only two would read as a bug on the third.
msg="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/home/fleet/records/captain.md"}}' \
  | AC_SCOPE=fam1 "$guard" 2>&1 >/dev/null || true)"
assert_contains "$msg" "ac-ledger-guard:" "AC-7.5: same message shape"
for f in backlog.md projects.md captain.md; do
  assert_contains "$msg" "records/$f" "AC-7.5: the refusal names records/$f"
done

# --- RC-7: the crewdomain slice is EXEMPT, via an explicit branch ------------
# BOTH directions, because one without the other is exactly how this was got
# wrong once already. An earlier reading claimed the fence patterns "do not
# match a nested path" - false: in a bash `case`, `*` matches `/`, so
# `*/records/backlog.md` DOES match crewdomains/payments/records/backlog.md.
# Left implicit, the guard would refuse a domainchief both of its core write
# duties: moving rows through its own backlog, and enriching its projects
# detail before handback.

# NARROWED with the crewdomain-token refactor: the per-domain backlog.md no
# longer exists, so ONLY the projects detail file earns the exemption - a
# package-relative backlog path is refused like any other ledger-shaped write.
assert_eq "$(hook fam1 Edit file_path "/home/fleet/crewdomains/payments/records/projects.md")" "0" \
  "AC-7.4: a scoped domainchief MAY edit its own crewdomains/<name>/records/projects.md"
assert_eq "$(hook fam1 Write file_path "crewdomains/payments/records/projects.md")" "0" \
  "AC-7.4: the relative form too - the leading-slash and bare forms both exempt"
assert_eq "$(hook fam1 Edit file_path "/home/fleet/crewdomains/payments/records/backlog.md")" "2" \
  "AC-7.4 (revised): a package backlog path is fenced - no domain ledger exists to own"

# R5-CR-002 - a TRAVERSING path must not take the exemption. The allow arm
# matched the RAW path, so `crewdomains/p/records/../../../records/captain.md`
# was exempted and resolved to the FLEET captain file - handing a scoped session
# the very layer that governs it.
for esc in \
  'crewdomains/payments/records/../../../records/captain.md' \
  '/home/fleet/crewdomains/payments/records/../../../records/backlog.md'; do
  assert_eq "$(hook fam1 Edit file_path "$esc")" "2" \
    "R5-CR-002: a traversal out of the slice is refused, not exempted"
done

# A path need not arrive normalized, and APFS is case-insensitive by default:
# every shape below opens a fenced ledger, so every one is refused.
for alias in \
  '/home/fleet/records//backlog.md' \
  'records/./backlog.md' \
  'records/scenes/../backlog.md' \
  'records/repo-knowledge/../captain.md' \
  'Records/Backlog.md' \
  '/home/fleet/records/PROJECTS.md'; do
  assert_eq "$(hook fam1 Edit file_path "$alias")" "2" "an aliased ledger path is refused: $alias"
done
assert_eq "$(hook fam1 Edit file_path "Crewdomains/Payments/Records/Projects.md")" "0" \
  "...while the crewdomain exemption holds in any case"
assert_eq "$(hook fam1 Edit file_path "records//learnings.md")" "0" "...and an unfenced file stays unfenced"

# The allow branch is the REASON, not a pattern that happens to miss: with it
# removed, the very same paths are refused. This is the regression guard that
# keeps someone from "simplifying" the branch away later.
mkdir -p "$TMP/guard-no-allow/bin" "$TMP/guard-no-allow/src"
cp "$BIN/ac-bun.sh" "$guard" "$TMP/guard-no-allow/bin/"
ln -s "$ROOT"/src/*.ts "$TMP/guard-no-allow/src/"
rm "$TMP/guard-no-allow/src/ledger-guard.ts"
awk '/^if \(!canon\.includes\("\.\."\) && EXEMPT\.test\(canon\)\) process\.exit\(0\);$/ { next } { print }' \
  "$ROOT/src/ledger-guard.ts" >"$TMP/guard-no-allow/src/ledger-guard.ts"
noallow="$TMP/guard-no-allow/bin/ac-ledger-guard.sh"
rc=0; ( printf '{"tool_name":"Edit","tool_input":{"file_path":"/home/fleet/crewdomains/payments/records/projects.md"}}' \
  | AC_SCOPE=fam1 "$noallow" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "2" \
  "AC-7.4: without the explicit allow branch the package path IS refused - the branch is load-bearing"

# --- the verdict, payload by payload ------------------------------------------
# Each row hands the guard one payload on stdin from cwd $TMP, LC_ALL=C unless
# the row names another locale. An allow is silent; a deny is the refusal on
# stderr and nothing on stdout.
pl() { printf "$1" >"$TMP/lg.pl"; }  # pl <printf format> - the payload bytes of the rows after it
LG_LC=C
verdict() {  # verdict <0|2> [env words...] - the guard's verdict on the payload
  local want="$1" rc=0
  shift
  (cd "$TMP" && env "$@" LC_ALL="$LG_LC" "$BIN/ac-ledger-guard.sh" <"$TMP/lg.pl") >"$TMP/n.out" 2>"$TMP/n.err" || rc=$?
  assert_eq "$rc:$(cat "$TMP/n.out")" "$want:" "verdict ($*): $(cat "$TMP/lg.pl")"
  if [ "$want" = 0 ]; then
    assert_eq "$(cat "$TMP/n.err")" "" "an allow is silent ($*): $(cat "$TMP/lg.pl")"
  else
    assert_contains "$(cat "$TMP/n.err")" "ac-ledger-guard: " "a deny says why ($*): $(cat "$TMP/lg.pl")"
  fi
}
edit() {  # edit <0|2> <tool> <field> <path> [env words...] - one path, judged in scope fam1
  local want="$1" tool="$2" field="$3" path="$4"
  shift 4
  printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$tool" "$field" "$path" >"$TMP/lg.pl"
  verdict "$want" AC_SCOPE=fam1 "$@"
}
lgpath() {  # lgpath <dir> <tool...> - a PATH dir holding exactly these host tools
  local d="$1" t
  shift
  mkdir -p "$d"
  for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
}

# 1. who is fenced.
pl '{"tool_name":"Edit","tool_input":{"file_path":"records/backlog.md"}}'
verdict 0 -u AC_SCOPE
verdict 2 AC_SCOPE=fam1

# 2. the canonical shape, the fence and the crewdomain exemption.
for p in /h/RECORDS/PROJECTS.MD //records///captain.md \
         ./records/backlog.md ././records/backlog.md records/./././backlog.md \
         x/../projects.md ../captain.md crewdomains/records/projects.md \
         /h/crewdomains/p/records/../projects.md \
         'records/backlog.md\n'; do
  edit 2 Edit file_path "$p"
done
for p in ./crewdomains/p/records/projects.md \
         records/backlog.md/ records/backlog.mdx records/backlog.md.bak backlog.md x/..backlog.md; do
  edit 0 Edit file_path "$p"
done
# Under a UTF-8 locale a non-ASCII capital is lowercased before the fence judges.
LG_LC=en_US.UTF-8
edit 2 Edit file_path 'records/bacKlog.md'
edit 2 Edit file_path 'RÉCORDS/../BACKLOG.MD'
LG_LC=C

# 3. the payload as jq reads it: a value printed before a parse error counts,
# NULs are dropped, trailing LFs stripped, and a byte that is no UTF-8 does
# not hide the path.
for p in '{"tool_name":"Edit","tool_input":{"file_path":"records/backlog.md"}} junk' \
         '{"tool_name":"Ed\\u0000it","tool_input":{"file_path":"rec\\u0000ords/backlog.md"}}' \
         '{"tool_name":"Edit","tool_input":{"file_path":"records/backlog.md"}}\n\n' \
         '{"tool_name":"Write","tool_input":{"file_path":"r\351/../records/captain.md"}}'; do
  pl "$p"
  verdict 2 AC_SCOPE=fam1
done
# the refusal prints the raw path and the scope as given
edit 2 Edit file_path 'Records//./BACKLOG.md' AC_SCOPE='fam %s 100%'
assert_contains "$(cat "$TMP/n.err")" "Edit on Records//./BACKLOG.md is refused in a scoped session (AC_SCOPE=fam %s 100%)" "the refusal names the raw path and the scope"
pl '{"tool_name":"Edit","tool_input":{"file_path":"records/backlog.md"}}'
verdict 2 AC_SCOPE="$(printf 'f\351m')"

# 4. a missing jq allows.
lgpath "$TMP/lg-nojq" bash env cat dirname tr sed bun
verdict 0 AC_SCOPE=fam1 PATH="$TMP/lg-nojq"

# 5. no bun on PATH: the shim refuses at once, naming bun.
lgpath "$TMP/lg-nobun" bash env cat dirname jq tr sed
n_rc=0; (cd "$TMP" && AC_SCOPE=fam1 PATH="$TMP/lg-nobun" LC_ALL=C "$BIN/ac-ledger-guard.sh" <"$TMP/lg.pl") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out")" "2:" "no bun: the shim refuses, nothing on stdout"
assert_contains "$(cat "$TMP/n.err")" "ac-ledger-guard.sh: REFUSED - bun is not on PATH" "no bun: the shim's refusal names bun"
# A module that cannot load is the shim's no-op, never a refusal.
lg_lf="$TMP/lg-loadfail"
mkdir -p "$lg_lf/bin" "$lg_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-ledger-guard.sh" "$lg_lf/bin/"
printf 'throw new Error("ledger guard cannot load");\n' >"$lg_lf/src/ledger-guard.ts"
n_rc=0; (cd "$TMP" && AC_SCOPE=fam1 LC_ALL=C "$lg_lf/bin/ac-ledger-guard.sh" <"$TMP/lg.pl") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc" "0" "a module that cannot load allows"
assert_eq "$(cat "$TMP/n.out")" "" "a module that cannot load prints nothing on stdout"
assert_contains "$(cat "$TMP/n.err")" "ledger guard cannot load" "the load failure is bun's own diagnosis"
assert_contains "$(cat "$TMP/n.err")" "ac-ledger-guard.sh: src/ledger-guard.ts exited 1 - this hook did nothing" "the shim says it did nothing"
case "$(cat "$TMP/n.err")" in *"ac-ledger-guard:"*) fail "a module that cannot load must never print the refusal" ;; esac

pass
