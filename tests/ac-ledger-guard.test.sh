#!/usr/bin/env bash
# ac-ledger-guard.test.sh - the PreToolUse fence that keeps a SCOPED session
# (a roomchief, AC_SCOPE set) from writing records/backlog.md or
# records/projects.md - the crewchief's own ledgers.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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

for f in backlog.md projects.md; do
  assert_eq "$(hook fam1 Edit file_path "/home/fleet/crewdomains/payments/records/$f")" "0" \
    "AC-7.4: a scoped domainchief MAY edit its own crewdomains/<name>/records/$f"
  assert_eq "$(hook fam1 Write file_path "crewdomains/payments/records/$f")" "0" \
    "AC-7.4: the relative form too - the leading-slash and bare forms both exempt"
done

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

# The allow branch is the REASON, not a pattern that happens to miss: with it
# removed, the very same paths are refused. This is the regression guard that
# keeps someone from "simplifying" the branch away later.
noallow="$TMP/guard-no-allow.sh"
awk '/^  crewdomains\/\*\/records\/\* \| \*\/crewdomains\/\*\/records\/\*\) exit 0 ;;$/ { next } { print }' \
  "$guard" >"$noallow"
chmod +x "$noallow"
rc=0; ( printf '{"tool_name":"Edit","tool_input":{"file_path":"/home/fleet/crewdomains/payments/records/backlog.md"}}' \
  | AC_SCOPE=fam1 "$noallow" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "2" \
  "AC-7.4: without the explicit allow branch the package path IS refused - the branch is load-bearing"

pass
