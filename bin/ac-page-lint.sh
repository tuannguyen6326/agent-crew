#!/usr/bin/env bash
# ac-page-lint.sh - PAGE-SYNTAX LINT: catch a syntax error inside a served
# dashboard page's inline <script> content before it reaches the browser.
#
# WHY: dashboard/page.ts's PAGE constant (and dashboard/app.ts's other page
# builders) hold each page as a template-literal STRING. Everything after the
# opening backtick is plain text to tsc and unreachable to `bun test` - it
# exists as source only once interpolated into the served HTML - so a syntax
# error inside a page's inline <script> does not fail the build and is not
# caught by tsc. It fires at RENDER, in front of whoever opens the page. Every
# landing touching a dashboard page used to re-derive this check by hand
# (start the dashboard, curl a page, extract each <script> block, run
# `bun build --no-bundle` over it); this is the one shared script instead.
#
# Usage: ac-page-lint.sh
#   Starts its own dashboard on a free ephemeral port, fetches every page in
#   PAGES below, extracts each inline <script>...</script> block (a block
#   whose opening tag carries a src= attribute is external - nothing to
#   check), runs `bun build --no-bundle` over each one, and stops the
#   dashboard again. Prints one line per page: `OK <path> (<n> scripts)`, or
#   one `SYNTAX ERROR <path> script <i>: <bun stderr>` line per failing
#   script.
#
# PAGES is a FIXED list, not derived from the route table: every route in
# dashboard/app.ts that unconditionally serves a full HTML document belongs in
# it (checked against source 2026-08-22 - dashboard/app.ts:6474-6484 gates
# /term-frame and /attach-frame behind a ?path=<home> that must pass
# allowedHomePaths(), so those two are excluded). Adding a new unconditional
# HTML page route to dashboard/app.ts means adding it here too.
#
# Exit: 0 every script compiled clean; 1 at least one page has a confirmed
# syntax error (checked first - see below); 2 usage; 3 no page had a syntax
# error, but tooling could not run for at least one (dashboard failed to
# start, bun/curl/perl missing, a page fetch or script extraction failed).
# A confirmed syntax error always exits 1, even when ANOTHER page's own
# check also failed for tooling reasons (that page's TOOLING ERROR line
# still prints to stderr) - a real defect outranks an unrelated page's
# coverage gap, but exit 1 alone does not promise every page was actually
# checked; read stderr for that.
set -u

PAGES=(/ /term /whiteboard /whiteboard-frame /review)

case "${1:-}" in
  -h|--help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) printf 'ac-page-lint.sh: unknown arg: %s\n' "$1" >&2; exit 2 ;;
esac

for t in bun curl perl; do
  command -v "$t" >/dev/null 2>&1 \
    || { printf 'ac-page-lint.sh: %s not found\n' "$t" >&2; exit 3; }
done

root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmpdir="$(mktemp -d)" || { printf 'ac-page-lint.sh: mktemp failed\n' >&2; exit 3; }
dash_pid=""
cleanup() {
  [ -n "$dash_pid" ] && kill "$dash_pid" >/dev/null 2>&1
  [ -n "$dash_pid" ] && wait "$dash_pid" 2>/dev/null
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Picks our own port (rather than reusing ac-dashboard.sh's busy-port guard)
# because we need the port number back to curl against, and 0 (OS-assigned)
# has no way out: dashboardMain() prints the --port value it was given, not
# whatever Bun.serve actually bound.
find_free_port() {
  local p
  for _ in $(seq 1 30); do
    p=$(( (RANDOM % 20000) + 20000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

port="$(find_free_port)" \
  || { printf 'ac-page-lint.sh: could not find a free port\n' >&2; exit 3; }

bun run "$root/bin/dashboard.ts" --port "$port" >"$tmpdir/dashboard.log" 2>&1 &
dash_pid=$!

ready=0
for _ in $(seq 1 50); do
  if ! kill -0 "$dash_pid" 2>/dev/null; then
    break
  fi
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done

if [ "$ready" -ne 1 ]; then
  printf 'ac-page-lint.sh: dashboard did not come up on port %s\n' "$port" >&2
  sed 's/^/  /' "$tmpdir/dashboard.log" >&2
  exit 3
fi

# Slurps the whole page, walks <script...>...</script> pairs non-greedily
# (perl is already a dependency this repo shells out to - see ac-qa.sh), and
# writes each non-external, non-empty body to
# its own numbered file. A JS string inside a real inline script that embeds
# its own literal "<\/script>" (dashboard/app.ts's OVERLAY constant does, to
# build an HTML string) keeps its escaping backslash in the served page, so
# it never matches this pattern's bare </script> and never truncates the
# real block early.
extract_scripts() { # <html-file> <outdir> -> prints the extracted count
  perl -e '
    my ($html, $outdir) = @ARGV;
    local $/;
    open(my $fh, "<", $html) or die "read $html: $!";
    my $doc = <$fh>;
    close $fh;
    my $i = 0;
    while ($doc =~ /<script\b([^>]*)>(.*?)<\/script>/gs) {
      my ($attrs, $body) = ($1, $2);
      next if $attrs =~ /\bsrc\s*=/i;
      next if $body =~ /^\s*$/s;
      $i++;
      open(my $out, ">", "$outdir/$i.js") or die "write $outdir/$i.js: $!";
      print $out $body;
      close $out;
    }
    print $i;
  ' "$1" "$2"
}

tooling_error=0
pages_had_error=0

for path in "${PAGES[@]}"; do
  page_html="$tmpdir/page.html"
  if ! curl -fsS "http://127.0.0.1:$port$path" -o "$page_html" 2>"$tmpdir/curl.err"; then
    printf 'TOOLING ERROR %s: could not fetch (%s)\n' "$path" "$(cat "$tmpdir/curl.err")" >&2
    tooling_error=1
    continue
  fi

  scriptdir="$tmpdir/scripts"
  rm -rf "$scriptdir"
  mkdir -p "$scriptdir"
  n="$(extract_scripts "$page_html" "$scriptdir" 2>"$tmpdir/perl.err")" || {
    printf 'TOOLING ERROR %s: script extraction failed (%s)\n' "$path" "$(cat "$tmpdir/perl.err")" >&2
    tooling_error=1
    continue
  }

  page_error=0
  i=1
  while [ "$i" -le "$n" ]; do
    if ! bun build --no-bundle "$scriptdir/$i.js" >/dev/null 2>"$tmpdir/bun.err"; then
      printf 'SYNTAX ERROR %s script %s: %s\n' "$path" "$i" "$(cat "$tmpdir/bun.err")"
      page_error=1
      pages_had_error=1
    fi
    i=$((i + 1))
  done
  [ "$page_error" -eq 0 ] && printf 'OK %s (%s scripts)\n' "$path" "$n"
done

[ "$pages_had_error" -eq 1 ] && exit 1
[ "$tooling_error" -eq 1 ] && exit 3
exit 0
