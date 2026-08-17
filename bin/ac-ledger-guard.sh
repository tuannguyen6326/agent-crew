#!/usr/bin/env bash
# ac-ledger-guard.sh - PreToolUse hook: refuse a SCOPED session (a roomchief,
# AC_SCOPE set) writing records/backlog.md, records/projects.md or
# records/captain.md.
#
# Wired in .claude/settings.json under hooks.PreToolUse; reads the hook
# payload JSON on stdin and inspects .tool_name / .tool_input. Pure bash + jq,
# no other runtime - the sibling of ac-delegation-guard.sh, same shape.
#
# WHY IT EXISTS. AGENTS.md section 8 states the roomchief charter in prose
# only ("it never touches the backlog/registry - the crewchief keeps those"):
# nothing mechanically held it. A roomchief with no fleet-wide context can
# renumber an epic rollup or move a line while the crewchief is mid-decision,
# and nothing would detect it - lived 2026-07-21 (gate-via-pane-agent
# roomchief edited records/backlog.md and ran crewchief-owned landing verbs
# itself; only its own self-declared handback caught it). A WARN-only receipt
# was considered and rejected: it needs a baseline-snapshot mechanism that
# does not exist, and a guard running inside the roomchief's own session
# cannot tell a crewchief's legitimate edit from its own - a real refusal
# is cheaper and cannot false-positive that way.
#
# SCOPE: only a session with AC_SCOPE set (a roomchief) is fenced - the
# crewchief itself runs unscoped and owns these files. Matched by PATH SUFFIX
# (a session's cwd may be the fleet home or a path relative to it), never a
# fixed absolute value, since the fleet home path varies per operator.
#
# Fails open: no AC_SCOPE, non-matching tool, missing jq, an unparseable
# payload, or a path that resolves empty all exit 0 - a broken guard must
# never wedge the harness. Exit codes: 0 allow, 2 deny. Files: none.
#
# RESIDUAL: this hook covers the `claude` harness's Edit/Write/NotebookEdit
# tools only. A write performed through the Bash tool (sed, echo >, a
# heredoc) still gets through - the same fail-open shape
# ac-delegation-guard.sh already accepts, not extended here to close it.

set -uo pipefail

[ -n "${AC_SCOPE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$tool" ] || exit 0
case "$tool" in mcp__*) exit 0 ;; esac

path=""
case "$tool" in
  Edit|Write) path="$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null || true)" ;;
  NotebookEdit) path="$(jq -r '.tool_input.notebook_path // empty' <<<"$payload" 2>/dev/null || true)" ;;
  *) exit 0 ;;
esac
[ -n "$path" ] || exit 0

# A CREWDOMAIN SLICE IS EXEMPT, and the exemption has to be an EXPLICIT branch
# rather than the absence of a matching pattern. In a bash `case`, `*` matches
# `/` - so `*/records/backlog.md` MATCHES
# crewdomains/payments/records/backlog.md, and `*/records/projects.md` matches
# the package's detail file. An earlier reading of this file claimed those
# patterns "do not match a nested path"; that claim is FALSE, verified by
# running the patterns rather than reasoning about them. Left implicit, this
# guard would refuse a domainchief BOTH of its core write duties: moving rows
# through its own domain backlog, and enriching its projects detail before
# handback. Placed BEFORE the fence so it wins outright.
# A `..` ANYWHERE disqualifies the exemption before it is considered:
# `crewdomains/payments/records/../../../records/captain.md` matches the allow
# glob and resolves to the FLEET captain file, so a raw-path allow arm would
# hand a scoped session the very layer it is governed by. Refusing to exempt a
# traversing path is fail-closed - the fence below still judges it.
case "$path" in
  *..*) : ;;
  crewdomains/*/records/* | */crewdomains/*/records/*) exit 0 ;;
esac

case "$path" in
  records/backlog.md | */records/backlog.md \
  | records/projects.md | */records/projects.md \
  | records/captain.md | */records/captain.md) : ;;
  *) exit 0 ;;
esac

# records/captain.md joins the fence because the FLEET captain file now carries
# domain standing rules - the `STANDING (domain:<name>): ` lines a domainchief
# reads as its LAW. A scoped session that is governed by a layer must not be
# able to edit that layer; it is the same argument this guard already makes for
# the backlog, arriving at a file that only just became load-bearing for scoped
# sessions.
printf 'ac-ledger-guard: %s on %s is refused in a scoped session (AC_SCOPE=%s) - the crewchief owns records/backlog.md, records/projects.md and records/captain.md; a scoped chief (roomchief or domainchief) reads them but never edits them. Report the change instead (hand it back to the crewchief, or note it in your report.md) rather than editing the ledger yourself. A crewdomain slice at crewdomains/<name>/records/ is YOURS to edit and is not fenced.\n' \
  "$tool" "$path" "$AC_SCOPE" >&2
exit 2
