#!/usr/bin/env bash
# ac-page-lint.test.sh - the page-syntax lint trick: extracts every inline
# <script> block from each fixed page, skips a block whose tag carries a
# src= attribute (nothing to check), runs `bun build --no-bundle` over the
# rest, and reports OK/SYNTAX ERROR per page with the three-way exit code
# (0 clean, 1 a page is broken, 2 usage, 3 tooling could not run).
# Runs against a FIXTURE dashboard (a copy of ac-page-lint.sh, with
# bin/ac-bun.sh beside it and src/ linked, in a throwaway repo whose own tiny
# dashboard/app.ts it boots - never the real dashboard, so the test pins the
# lint and not the pages). The fixture serves all 5
# fixed-list paths with one external <script src>, one inline <script>, and
# one inline <script type="module"> per page; PAGE_LINT_TEST_BAD=1 swaps the
# module script's body on "/" for one with a syntax error.
# Fail-closed sourcing: unsourced, errexit is never armed and $AC_HOME is the
# operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v bun >/dev/null 2>&1 || skip 'bun not available'
command -v curl >/dev/null 2>&1 || skip 'curl not available'
command -v perl >/dev/null 2>&1 || skip 'perl not available'

repo="$TMP/pagelintrepo"
mkdir -p "$repo/bin" "$repo/dashboard"
cp "$BIN/ac-page-lint.sh" "$BIN/ac-bun.sh" "$repo/bin/"
chmod +x "$repo/bin/ac-page-lint.sh"
ln -s "$ROOT/src" "$repo/src"

cat >"$repo/dashboard/app.ts" <<'EOF'
// FIXTURE dashboard for ac-page-lint.test.sh - not the real dashboard.
const args = process.argv.slice(2);
let port = 0;
for (let i = 0; i < args.length; i++) if (args[i] === "--port") port = Number(args[i + 1]);
const bad = process.env.PAGE_LINT_TEST_BAD === "1";

const GOOD_A = "const a = 1; console.log(a);";
const GOOD_B = "export const b = 2;";
const BAD_B = "const b = (\nfunction(){\n";

function page(secondScript: string): string {
  return `<!doctype html><html><head><title>fixture</title></head><body>
<script src="/assets/ext.js">this is not valid js !!! (((</script>
<script>${GOOD_A}</script>
<script type="module">${secondScript}</script>
</body></html>`;
}

const PAGES: Record<string, string> = {
  "/": page(bad ? BAD_B : GOOD_B),
  "/term": page(GOOD_B),
  "/whiteboard": page(GOOD_B),
  "/whiteboard-frame": page(GOOD_B),
  "/review": page(GOOD_B),
};

Bun.serve({
  port,
  fetch(req) {
    const path = new URL(req.url).pathname;
    const html = PAGES[path];
    return html
      ? new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
      : new Response("not found", { status: 404 });
  },
});
EOF

lint() { (cd "$repo" && ./bin/ac-page-lint.sh "$@"); }

# --- arg handling ------------------------------------------------------------
grep -q 'Usage: ac-page-lint.sh' < <(lint -h) || fail "-h prints usage"
rc=0; lint bogus >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 2 "an unknown arg exits 2"

# --- a clean run: every fixed page OK, external script never checked --------
out="$(lint 2>&1)"; rc=0; lint >"$TMP/clean.out" 2>&1 || rc=$?
assert_eq "$rc" 0 "a clean fixture dashboard exits 0"
out="$(cat "$TMP/clean.out")"
assert_contains "$out" "OK / (2 scripts)" "root page reports 2 checked scripts (the src= one is skipped)"
assert_contains "$out" "OK /term" "the /term page is checked too"
assert_contains "$out" "OK /whiteboard" "the /whiteboard page is checked too"
assert_contains "$out" "OK /whiteboard-frame" "the /whiteboard-frame page is checked too"
assert_contains "$out" "OK /review" "the /review page is checked too"

# --- a planted syntax error in one page's module script is caught -----------
rc=0; PAGE_LINT_TEST_BAD=1 lint >"$TMP/bad.out" 2>&1 || rc=$?
assert_eq "$rc" 1 "a page with a syntax error exits 1"
out="$(cat "$TMP/bad.out")"
assert_contains "$out" "SYNTAX ERROR / script 2" "names the page and the failing script's index"
assert_contains "$out" "OK /term" "an unaffected page still reports OK - failure is per-page, not global"

# --- bun missing from PATH: the shim's required-tool refusal -----------------
emptybin="$TMP/emptybin"
mkdir -p "$emptybin"
for t in bash sh curl perl mktemp cat grep sed kill sleep seq awk dirname; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$emptybin/$t"
done
rc=0; (cd "$repo" && PATH="$emptybin" ./bin/ac-page-lint.sh) >/dev/null 2>"$TMP/nobun.err" || rc=$?
assert_eq "$rc" 1 "bun missing from PATH exits 1 (the shim cannot start the lint)"
assert_eq "$(cat "$TMP/nobun.err")" "ERROR: required tool not found: bun" "bun missing from PATH is named"

# A caller whose cwd was deleted still gets a real lint: nothing the lint
# runs - the dashboard, bun build - works in that cwd.
gone="$TMP/pl-gone"
mkdir -p "$gone"
rc=0; (cd "$gone" && rmdir "$gone" && "$repo/bin/ac-page-lint.sh") >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 "a deleted cwd lints the good fixture clean"

# --- tooling could not run: the dashboard itself fails to start -------------
repo2="$TMP/pagelintrepo-broken"
mkdir -p "$repo2/bin" "$repo2/dashboard"
cp "$BIN/ac-page-lint.sh" "$BIN/ac-bun.sh" "$repo2/bin/"
chmod +x "$repo2/bin/ac-page-lint.sh"
ln -s "$ROOT/src" "$repo2/src"
printf 'throw new Error("fixture: dashboard intentionally broken");\n' >"$repo2/dashboard/app.ts"
rc=0; (cd "$repo2" && ./bin/ac-page-lint.sh) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 3 "a dashboard that fails to start exits 3, not 1"

# --- the run, row by row ------------------------------------------------------
# A second throwaway repo ($PN) whose fixture dashboard picks its pages by env
# per row; each run starts at $PN with stdin /dev/null and LC_ALL=C, and a PATH
# mktemp makes every tmpdir under one watched dir. After every run: no tmpdir
# is left and every dashboard the run booted is gone.
PN="$TMP/pl-n"
plstub="$TMP/pl-stub"; PLT="$TMP/pl-tmp"; PLP="$TMP/pl-pids"
mkdir -p "$plstub" "$PLT" "$PLP"
cat >"$plstub/mktemp" <<'EOS'
#!/bin/sh
[ "${PL_MKTEMP_FAIL:-}" = 1 ] && { printf 'mktemp: stub refused\n' >&2; exit 1; }
exec /usr/bin/mktemp -d "$PL_TMP/tmp.XXXXXXXXXX"
EOS
chmod +x "$plstub/mktemp"
cat >"$TMP/pl-app.ts" <<'EOS'
// FIXTURE dashboard for the ac-page-lint row-by-row leg - not the real dashboard.
import { writeFileSync } from "node:fs";
const env = process.env;
if (env.PL_THROW === "1") throw new Error("fixture: dashboard intentionally broken");
const args = process.argv.slice(2);
let port = 0;
for (let i = 0; i < args.length; i++) if (args[i] === "--port") port = Number(args[i + 1]);
writeFileSync(`${env.PL_PIDS}/${process.pid}`, "");
const GOOD_A = "const a = 1; console.log(a);";
const GOOD_B = "export const b = 2;";
const BAD_B = "const b = (\nfunction(){\n";
const page = (...scripts: string[]): string =>
  `<!doctype html><html><body>\n<script src="/assets/ext.js">this is not valid js !!! (((</script>\n${scripts.join("\n")}\n</body></html>`;
const std = (b: string): string => page(`<script>${GOOD_A}</script>`, `<script type="module">${b}</script>`);
const PAGES: Record<string, string> = {
  "/": std(env.PAGE_LINT_TEST_BAD === "1" ? BAD_B : GOOD_B),
  "/term": std(GOOD_B),
  "/whiteboard": std(GOOD_B),
  "/whiteboard-frame": std(GOOD_B),
  "/review": std(GOOD_B),
};
if (env.PL_ODD === "1")
  PAGES["/"] = page(
    "<script>   \n  </script>",
    '<script>const s = "<\\/script>"; console.log(s);</script>',
    `<script type="module">${GOOD_B}</script>`,
    "<script>this is not valid js (((",
  );
if (env.PL_NONE === "1") PAGES["/term"] = page();
if (env.PL_TWOBAD === "1") PAGES["/whiteboard"] = page(`<script>${BAD_B}</script>`, `<script>${GOOD_A}</script>`, "<script>let = ;</script>");
if (env.PL_404) delete PAGES[env.PL_404];
Bun.serve({
  port,
  idleTimeout: 0,
  async fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/" && env.PL_ROOT500 === "1") return new Response("down", { status: 500 });
    if (env.PL_HOLD && path === "/term") {
      writeFileSync(env.PL_HOLD, "");
      await new Promise(() => {});
    }
    const html = PAGES[path];
    return html
      ? new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
      : new Response("not found", { status: 404 });
  },
});
EOS
mkdir -p "$PN/bin" "$PN/dashboard"
cp "$BIN/ac-bun.sh" "$BIN/ac-page-lint.sh" "$PN/bin/"; ln -s "$ROOT/src" "$PN/src"; cp "$TMP/pl-app.ts" "$PN/dashboard/app.ts"
PPATH="$plstub:$PATH"; PENV=()
pswept() {  # pswept <what> - no tmpdir left, every dashboard the run booted gone
  local f n
  assert_eq "$(ls -A "$PLT")" "" "page-lint $1: no tmpdir left"
  for f in "$PLP"/*; do
    [ -e "$f" ] || continue
    n=0
    while kill -0 "${f##*/}" 2>/dev/null; do
      n=$((n + 1)); [ "$n" -lt 50 ] || fail "page-lint $1: dashboard ${f##*/} still alive"; sleep 0.1
    done
    rm -f "$f"
  done
}
prun() {  # prun <args...> - one run from $PN, swept; sets P_RC, stdout and stderr in $TMP/pn.out and pn.err
  P_RC=0
  (cd "$PN" && env LC_ALL=C PATH="$PPATH" PL_TMP="$PLT" PL_PIDS="$PLP" ${PENV[@]+"${PENV[@]}"} ./bin/ac-page-lint.sh "$@") </dev/null >"$TMP/pn.out" 2>"$TMP/pn.raw" || P_RC=$?
  pswept "'$*' (${PENV[*]-})"
  LC_ALL=C sed -E 's#port [0-9]+#port N#g' "$TMP/pn.raw" >"$TMP/pn.err"
}
pout() { cat "$TMP/pn.out"; }
perr() { cat "$TMP/pn.err"; }
ALL_OK="OK / (2 scripts)
OK /term (2 scripts)
OK /whiteboard (2 scripts)
OK /whiteboard-frame (2 scripts)
OK /review (2 scripts)"

# 1. a clean fixture: five OK lines, exit 0
prun
assert_eq "$P_RC $(pout)" "0 $ALL_OK" "row 1: clean"
assert_eq "$(perr)" "" "row 1: nothing on stderr"

# 2. -h / --help (extras ignored): exit 0, the src/page-lint.ts spec header on
#    stdout; an unknown first argument: exit 2
for a in -h --help '-h bogus'; do
  # shellcheck disable=SC2086
  prun $a
  assert_eq "$P_RC:$(perr)" "0:" "usage '$a': exit 0, nothing on stderr"
  assert_eq "$(pout)" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/page-lint.ts" | sed 's/^\/\/ \{0,1\}//')" "usage '$a': the src/page-lint.ts spec header"
done
for a in bogus --all -; do
  prun "$a" extra
  assert_eq "$P_RC $(perr)" "2 ac-page-lint.sh: unknown arg: $a" "row 2: '$a' exits 2"
  assert_eq "$(pout)" "" "row 2: '$a' prints nothing on stdout"
done

# 3. a missing tool, first one wins: curl, then perl - exit 3; without bun the
#    shim refuses every run, -h and a bad argument included
ptools() {  # ptools <dir> <tool...> - a PATH dir holding only these tools
  mkdir -p "$1"; local d="$1" t; shift
  for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
}
ptools "$TMP/pl-nocurl" bash dirname bun perl awk sed
ptools "$TMP/pl-noperl" bash dirname bun curl awk sed
ptools "$TMP/pl-nobun" bash dirname curl perl awk sed
PPATH="$plstub:$TMP/pl-nocurl"; prun
assert_eq "$P_RC $(perr)" "3 ac-page-lint.sh: curl not found" "row 3: no curl"
PPATH="$plstub:$TMP/pl-noperl"; prun
assert_eq "$P_RC $(perr)" "3 ac-page-lint.sh: perl not found" "row 3: no perl"
ptools "$TMP/pl-notools" bash dirname bun awk sed
PPATH="$plstub:$TMP/pl-notools"; prun
assert_eq "$P_RC $(perr)" "3 ac-page-lint.sh: curl not found" "row 3: neither - curl is checked first"
PPATH="$plstub:$TMP/pl-nobun"
for a in -h bogus; do
  prun "$a"
  assert_eq "$P_RC $(perr)" "1 ERROR: required tool not found: bun" "row 3: '$a' without bun is the shim's refusal"
done
PPATH="$plstub:$PATH"

# 4. a page that cannot be fetched: its TOOLING ERROR on stderr, the others
#    checked, exit 3 - and exit 1 when another page is broken, the TOOLING
#    ERROR still printed
PENV=(PL_404=/review); prun; PENV=()
assert_eq "$P_RC" 3 "row 4: a 404 exits 3"
assert_eq "$(perr | cut -c1-41)" "TOOLING ERROR /review: could not fetch (c" "row 4: the page and curl's own text"
assert_eq "$(pout)" "$(printf '%s\n' "$ALL_OK" | sed '$d')" "row 4: four OK"
PENV=(PL_404=/review PAGE_LINT_TEST_BAD=1); prun; PENV=()
assert_eq "$P_RC" 1 "row 4: a syntax error outranks a tooling error"
assert_contains "$(perr)" "TOOLING ERROR /review: could not fetch" "row 4: still reported"
assert_eq "$(pout | grep '^OK ')" "$(printf '%s\n' "$ALL_OK" | sed -e 1d -e '$d')" "row 4: the pages between still OK"

# 5. the extraction: a whitespace-only body is skipped, an escaped
#    `<\/script>` inside a string does not close a block, an unterminated
#    last block is dropped; a page of external scripts only checks 0; two
#    failing scripts are two blocks and no OK line
PENV=(PL_ODD=1 PL_NONE=1 PL_TWOBAD=1); prun; PENV=()
assert_eq "$P_RC" 1 "row 5: a broken page exits 1"
assert_eq "$(pout | grep -E '^(OK|SYNTAX ERROR) ' | cut -c1-34)" "OK / (2 scripts)
OK /term (0 scripts)
SYNTAX ERROR /whiteboard script 1:
SYNTAX ERROR /whiteboard script 3:
OK /whiteboard-frame (2 scripts)
OK /review (2 scripts)" "row 5: counts and blocks"

# 6. a dashboard that dies at start: the polls stop once it is gone (a
#    logging wrapper around the real sleep counts them), the log follows the
#    refusal two-space indented (a blank line indents to two spaces)
plslog="$TMP/pl-slog"; mkdir -p "$plslog"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$PL_SLEEPS"\nexec /bin/sleep "$@"\n' >"$plslog/sleep"; chmod +x "$plslog/sleep"
PPATH="$plslog:$plstub:$PATH"; PENV=(PL_THROW=1 "PL_SLEEPS=$TMP/pl-sleeps")
: >"$TMP/pl-sleeps"; prun; n_n="$(grep -c . "$TMP/pl-sleeps" || true)"
PPATH="$plstub:$PATH"; PENV=()
assert_eq "$P_RC" 3 "row 6: exit 3"
[ "$n_n" -lt 50 ] || fail "row 6: a dead dashboard stops the polls ($n_n sleeps)"
assert_eq "$(perr | head -n 1)" "ac-page-lint.sh: dashboard did not come up on port N" "row 6: the refusal"
assert_contains "$(perr)" "  error: fixture: dashboard intentionally broken" "row 6: the indented log"
grep -qx '  ' <<<"$(perr)" || fail "row 6: a blank log line indents to two spaces"
assert_eq "$(pout)" "" "row 6: nothing on stdout"

# 7. a dashboard that never answers `/` well: 50 polls, each followed by a
#    spawned `sleep 0.2` (a PATH stub here), then the refusal with an empty log
plsleep="$TMP/pl-sleep"; mkdir -p "$plsleep"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$PL_SLEEPS"\n' >"$plsleep/sleep"; chmod +x "$plsleep/sleep"
PPATH="$plsleep:$plstub:$PATH"; PENV=(PL_ROOT500=1 "PL_SLEEPS=$TMP/pl-sleeps")
: >"$TMP/pl-sleeps"; prun; n_n="$(grep -c '^0.2$' "$TMP/pl-sleeps" || true)"
PPATH="$plstub:$PATH"; PENV=()
assert_eq "$P_RC" 3 "row 7: exit 3"
assert_eq "$n_n" 50 "row 7: fifty polls"
assert_eq "$(perr)" "ac-page-lint.sh: dashboard did not come up on port N" "row 7: the refusal, an empty log"

# 8. mktemp failing: its own line, then the refusal, exit 3
PENV=(PL_MKTEMP_FAIL=1); prun; PENV=()
assert_eq "$P_RC $(perr)" "3 mktemp: stub refused
ac-page-lint.sh: mktemp failed" "row 8: mktemp failed"

# 9. a PATH perl that is not executable is FOUND and every extraction fails:
#    five TOOLING ERROR lines with nothing captured, exit 3
plnx="$TMP/pl-nxperl"
ptools "$plnx" bash dirname bun curl seq sleep sed cat rm mkdir awk
printf '#!/bin/sh\nexit 0\n' >"$plnx/perl"; chmod 644 "$plnx/perl"
PPATH="$plstub:$plnx"; prun; PPATH="$plstub:$PATH"
assert_eq "$P_RC" 3 "row 9: exit 3"
assert_eq "$(pout)" "" "row 9: no page passes"
assert_eq "$(perr)" "TOOLING ERROR /: script extraction failed ()
TOOLING ERROR /term: script extraction failed ()
TOOLING ERROR /whiteboard: script extraction failed ()
TOOLING ERROR /whiteboard-frame: script extraction failed ()
TOOLING ERROR /review: script extraction failed ()" "row 9: one line per page"

# 10. a signal while a page fetch hangs: the run ends 128+<signal>, no tmpdir
#     is left and the dashboard is gone. Started as an async job of this
#     non-interactive shell the run inherits SIGINT ignored, and still ends on it.
psignal() {  # psignal <signal> - a run held on /term, signalled; its status in P_RC
  local hold="$TMP/pl-hold" n=0 pid
  rm -f "$hold"
  (cd "$PN" && exec env LC_ALL=C PATH="$PPATH" PL_TMP="$PLT" PL_PIDS="$PLP" PL_HOLD="$hold" ./bin/ac-page-lint.sh) </dev/null >"$TMP/pn.out" 2>"$TMP/pn.raw" &
  pid=$!
  until [ -e "$hold" ]; do n=$((n + 1)); [ "$n" -lt 200 ] || { kill -TERM "$pid"; fail "row 10: the run never reached /term"; }; sleep 0.05; done
  kill "-$1" "$pid"
  n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 50 ] || { kill -TERM "$pid"; fail "row 10: the run did not end on $1"; }; sleep 0.1
  done
  P_RC=0; wait "$pid" 2>/dev/null || P_RC=$?
  pswept "after $1"
}
psignal TERM
assert_eq "$P_RC" 143 "row 10: TERM ends the run 143"
assert_eq "$(pout)" "OK / (2 scripts)" "row 10: the page before the hold"
psignal INT
assert_eq "$P_RC" 130 "row 10: INT ends the run 130"

pass
