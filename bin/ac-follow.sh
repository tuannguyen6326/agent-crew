#!/usr/bin/env bash
# ac-follow.sh - realtime, full-fidelity stream of a crewmate's claude
# session (the captain's x-ray: full tool inputs/results, not the 40-line
# pane tail ac-peek gives).
#
# Usage:
#   ac-follow.sh <id>              # follow the crewmate's transcript live
#   ac-follow.sh --render <jsonl>  # one-shot render of a transcript (tests)
#
# Resolution: the task meta gives worktree= (claude keys transcripts by cwd:
# ~/.claude/projects/<slugified-worktree>/) and session_id=. The stream
# follows the DIRECTORY, auto-switching to the newest transcript when the
# crewmate forks/starts sub-sessions. ctrl-c to stop; the crewmate is
# never touched (read-only).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
ac_require python3

renderer() {
  # renderer <mode> <path> - mode `file` renders once; mode `dir` follows.
  python3 -u - "$1" "$2" <<'PY'
import glob, json, os, sys, time

mode, target = sys.argv[1], sys.argv[2]
tty = sys.stdout.isatty()
DIM, RST, CYA, RED, B = (
    ("\033[2m", "\033[0m", "\033[36m", "\033[31m", "\033[1m") if tty else ("",) * 5
)
MAX = 1500  # bound huge tool payloads; full detail stays in the jsonl

def clip(s, n=MAX):
    s = str(s)
    return s if len(s) <= n else s[:n] + f"...{DIM}[+{len(s)-n} chars]{RST}"

def render(line):
    try:
        d = json.loads(line)
    except Exception:
        return
    msg = d.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        if d.get("type") == "user":
            print(f"\n{B}user:{RST} {clip(content, 2000)}")
        return
    for c in content or []:
        t = c.get("type")
        if t == "text" and c.get("text"):
            print(c["text"], end="", flush=True)
        elif t == "tool_use":
            inp = json.dumps(c.get("input", {}), ensure_ascii=False)
            print(f"\n{CYA}tool {c.get('name','?')}{RST} {clip(inp)}")
        elif t == "tool_result":
            body = c.get("content")
            if isinstance(body, list):
                body = "".join(x.get("text", "") for x in body if isinstance(x, dict))
            mark = f"{RED}ERR" if c.get("is_error") else f"{DIM}->"
            print(f"{mark} {clip(body)}{RST}")

if mode == "file":
    with open(target) as f:
        for line in f:
            render(line)
    print()
    sys.exit(0)

cur, off = None, 0
waiting = False
while True:
    files = glob.glob(os.path.join(target, "*.jsonl"))
    path = max(files, key=os.path.getmtime) if files else None
    if path is None:
        if not waiting:
            print(f"{DIM}waiting for the first transcript in {target} ...{RST}")
            waiting = True
        time.sleep(1)
        continue
    if path != cur:
        cur, off = path, 0
        print(f"\n{B}-- session: {os.path.basename(path)} --{RST}")
        if os.path.getsize(path) > 200_000:  # first attach mid-run: tail only
            with open(path) as f:
                lines = f.readlines()
            for line in lines[-15:]:
                render(line)
            off = sum(len(l) for l in lines)
    try:
        sz = os.path.getsize(path)
    except FileNotFoundError:
        cur = None
        continue
    if sz < off:
        off = 0
    if sz > off:
        with open(path) as f:
            f.seek(off)
            chunk = f.read()
        off = sz
        for line in chunk.splitlines():
            render(line)
    time.sleep(1)
PY
}

if [ "${1:-}" = "--render" ]; then
  f="${2:?usage: ac-follow.sh --render <jsonl>}"
  [ -f "$f" ] || ac_die "no such transcript: $f"
  renderer file "$f"
  exit 0
fi

id="${1:-}"
[ -n "$id" ] || ac_die "usage: ac-follow.sh <id> | --render <jsonl>"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || meta="$(ac_state_dir)/archive/$id/meta"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
worktree="$(ac_meta_get "$meta" worktree)"
[ -n "$worktree" ] || ac_die "meta for $id has no worktree"
[ "$(ac_meta_get "$meta" harness)" = "claude" ] \
  || ac_die "$id is not a claude crewmate; use ac-peek.sh instead"

# claude slugs the cwd: / and . become -
slug="$(printf '%s' "$worktree" | sed 's/[/.]/-/g')"
proj="$HOME/.claude/projects/$slug"
[ -d "$proj" ] || ac_warn "no transcripts yet at $proj (crewmate still booting?)"
printf '%s\n' "following $id ($proj) - ctrl-c to stop" >&2
renderer dir "$proj"
