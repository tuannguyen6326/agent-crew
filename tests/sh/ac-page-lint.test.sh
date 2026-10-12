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
# module script's body on "/" for one with a syntax error. The last leg holds
# src/page-lint.ts to the frozen bash original.
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
# (a named divergence: exit 1 where the bash original's own check exited 3)
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

# --- differential: src/page-lint.ts against the frozen bash original ----------
# DISPUTED: the implementation (tests/fixtures/ac-page-lint.sh as <side>/bin/ac-page-lint.sh vs src/page-lint.ts through the bin/ac-page-lint.sh shim)
# HELD-CONSTANT: two throwaway repos seeded alike ($PO for the oracle, $PN for the shim) - the same bin/ac-bun.sh copy, src link and fixture dashboard/app.ts (its pages chosen by env per row) - argv, PATH and env per row, cwd (the side root), stdin /dev/null, LC_ALL=C, a PATH mktemp that makes every tmpdir under one watched dir; exit status, stdout and stderr compared whole after the random tmp suffix, the port number and the side root are normalised. After every run of either side: no tmpdir is left and every dashboard the run booted is gone.
PO="$TMP/pl-o"; PN="$TMP/pl-n"
plstub="$TMP/pl-stub"; PLT="$TMP/pl-tmp"; PLP="$TMP/pl-pids"
mkdir -p "$plstub" "$PLT" "$PLP"
cat >"$plstub/mktemp" <<'EOF'
#!/bin/sh
[ "${PL_MKTEMP_FAIL:-}" = 1 ] && { printf 'mktemp: stub refused\n' >&2; exit 1; }
exec /usr/bin/mktemp -d "$PL_TMP/tmp.XXXXXXXXXX"
EOF
chmod +x "$plstub/mktemp"
cat >"$TMP/pl-app.ts" <<'EOF'
// FIXTURE dashboard for the ac-page-lint differential leg - not the real dashboard.
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
    "<SCRIPT>this is not valid js (((</SCRIPT>",
    '<script data-src="x">this is not valid js (((</script>',
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
    if (env.PL_HOLD && path === (env.PL_HOLDPATH || "/term")) {
      writeFileSync(env.PL_HOLD, "");
      await new Promise(() => {});
    }
    const html = PAGES[path];
    return html
      ? new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
      : new Response("not found", { status: 404 });
  },
});
EOF
pseed() { mkdir -p "$H/bin" "$H/dashboard"; cp "$BIN/ac-bun.sh" "$H/bin/"; ln -s "$ROOT/src" "$H/src"; cp "$TMP/pl-app.ts" "$H/dashboard/app.ts"; }
for H in "$PO" "$PN"; do pseed; done
cp "$ROOT/tests/fixtures/ac-page-lint.sh" "$PO/bin/ac-page-lint.sh"; cp "$BIN/ac-page-lint.sh" "$PN/bin/ac-page-lint.sh"
PPATH="$plstub:$PATH"; PENV=()
prun() {  # prun <side root> <prefix> <args...> - the side's own bin/ac-page-lint.sh, run from the side root
  local h="$1" p="$2"; shift 2
  (cd "$h" && env LC_ALL=C PATH="$PPATH" PL_TMP="$PLT" PL_PIDS="$PLP" ${PENV[@]+"${PENV[@]}"} ./bin/ac-page-lint.sh "$@") </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.rawerr"
}
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
pnorm() { LC_ALL=C sed -E -e "s#$2#ROOT#g" -e "s#$PLT/tmp\.[A-Za-z0-9]{10}#TMPDIR#g" -e 's#port [0-9]+#port N#g' "$1"; }
pside() {  # pside <side root> <prefix> <args...> - one run, swept and normalised; its status in P_SIDE
  local h="$1" p="$2"; shift 2
  P_SIDE=0; prun "$h" "$p" "$@" || P_SIDE=$?
  pswept "$p '$*'"
  pnorm "$TMP/$p.raw" "$h" >"$TMP/$p.out"; pnorm "$TMP/$p.rawerr" "$h" >"$TMP/$p.err"
}
psame() {  # psame <args...> - oracle on $PO and shim on $PN answer alike; P_RC is the shared status
  local o_rc
  pside "$PO" po "$@"; o_rc="$P_SIDE"
  pside "$PN" pn "$@"
  assert_eq "$P_SIDE" "$o_rc" "page-lint differential exit for '$*' (${PENV[*]-})"
  cmp -s "$TMP/po.out" "$TMP/pn.out" || fail "page-lint differential stdout differs for '$*' (${PENV[*]-}): $(diff "$TMP/po.out" "$TMP/pn.out" | head -n 8)"
  cmp -s "$TMP/po.err" "$TMP/pn.err" || fail "page-lint differential stderr differs for '$*' (${PENV[*]-}): $(diff "$TMP/po.err" "$TMP/pn.err" | head -n 8)"
  P_RC="$P_SIDE"
}
pout() { cat "$TMP/pn.out"; }
perr() { cat "$TMP/pn.err"; }
ALL_OK="OK / (2 scripts)
OK /term (2 scripts)
OK /whiteboard (2 scripts)
OK /whiteboard-frame (2 scripts)
OK /review (2 scripts)"

# 1. a clean fixture: five OK lines, exit 0
psame
assert_eq "$P_RC $(pout)" "0 $ALL_OK" "row 1: clean"
assert_eq "$(perr)" "" "row 1: nothing on stderr"

# 2. a broken script: its SYNTAX ERROR block on stdout - bun's text is several
#    lines naming the tmpdir (W2) - and the other pages still OK, exit 1
PENV=(PAGE_LINT_TEST_BAD=1); psame; PENV=()
assert_eq "$P_RC" 1 "row 2: a syntax error exits 1"
assert_eq "$(pout | head -n 1 | cut -c1-25)" "SYNTAX ERROR / script 2: " "row 2: the failing page and script"
assert_contains "$(pout | sed -n '2,$p')" "TMPDIR/scripts/2.js" "row 2: the block runs over several lines and names the tmpdir (W2)"
assert_eq "$(pout | grep '^OK ')" "$(printf '%s\n' "$ALL_OK" | sed 1d)" "row 2: the rest OK"

# 3. -h / --help (extras ignored): exit 0, each side's OWN spec header - the
#    named divergence (USAGE HEADER); an unknown first argument: exit 2
pusage() {
  local o_rc=0 n_rc=0
  prun "$PO" po "$@" || o_rc=$?
  prun "$PN" pn "$@" || n_rc=$?
  assert_eq "$o_rc $n_rc" "0 0" "usage '$*': both exit 0"
  assert_eq "$(cat "$TMP/po.rawerr" "$TMP/pn.rawerr")" "" "usage '$*': nothing on stderr"
  assert_eq "$(cat "$TMP/po.raw")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-page-lint.sh" | sed 's/^# \{0,1\}//')" "usage '$*': the original prints its bash header"
  assert_eq "$(cat "$TMP/pn.raw")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/page-lint.ts" | sed 's/^\/\/ \{0,1\}//')" "usage '$*': the port prints the src/page-lint.ts spec header"
  assert_contains "$(cat "$TMP/po.raw")" "Usage: ac-page-lint.sh" "usage '$*': the original's usage line"
  assert_contains "$(cat "$TMP/pn.raw")" "Usage: ac-page-lint.sh" "usage '$*': the port's usage line"
}
pusage -h
pusage --help
pusage -h bogus
for a in bogus --all -; do
  psame "$a" extra
  assert_eq "$P_RC $(perr)" "2 ac-page-lint.sh: unknown arg: $a" "row 3: '$a' exits 2"
done

# 4. a missing tool, first one wins: curl, then perl - exit 3; bun is the
#    shim's own refusal, exit 1 (a named divergence)
ptools() {  # ptools <dir> <tool...> - a PATH dir holding only these tools
  mkdir -p "$1"; local d="$1" t; shift
  for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
}
ptools "$TMP/pl-nocurl" bash dirname bun perl awk sed
ptools "$TMP/pl-noperl" bash dirname bun curl awk sed
ptools "$TMP/pl-nobun" bash dirname curl perl awk sed
PPATH="$plstub:$TMP/pl-nocurl"; psame
assert_eq "$P_RC $(perr)" "3 ac-page-lint.sh: curl not found" "row 4: no curl"
PPATH="$plstub:$TMP/pl-noperl"; psame
assert_eq "$P_RC $(perr)" "3 ac-page-lint.sh: perl not found" "row 4: no perl"
ptools "$TMP/pl-notools" bash dirname bun awk sed
PPATH="$plstub:$TMP/pl-notools"; psame
assert_eq "$P_RC $(perr)" "3 ac-page-lint.sh: curl not found" "row 4: neither - curl is checked first"
PPATH="$plstub:$TMP/pl-nobun"
for a in "" -h bogus; do
  pside "$PO" po ${a:+"$a"}; o_rc="$P_SIDE"
  pside "$PN" pn ${a:+"$a"}
  [ "$a" = "" ] && assert_eq "$o_rc $(cat "$TMP/po.err")" "3 ac-page-lint.sh: bun not found" "row 4: the original's own bun check"
  assert_eq "$P_SIDE $(perr)" "1 ERROR: required tool not found: bun" "row 4: '$a' without bun is the shim's refusal"
done
PPATH="$plstub:$PATH"

# 5. a page that cannot be fetched: its TOOLING ERROR on stderr, the others
#    checked, exit 3 - and exit 1 when another page is broken, the TOOLING
#    ERROR still printed
PENV=(PL_404=/review); psame; PENV=()
assert_eq "$P_RC $(perr)" "3 TOOLING ERROR /review: could not fetch (curl: (22) The requested URL returned error: 404)" "row 5: a 404"
assert_eq "$(pout)" "$(printf '%s\n' "$ALL_OK" | sed '$d')" "row 5: four OK"
PENV=(PL_404=/review PAGE_LINT_TEST_BAD=1); psame; PENV=()
assert_eq "$P_RC" 1 "row 5: a syntax error outranks a tooling error"
assert_contains "$(perr)" "TOOLING ERROR /review: could not fetch" "row 5: still reported"

# 6. the extraction: `<SCRIPT>` is never extracted (W3), a `data-src=` block is
#    skipped as external (W1), a whitespace-only body is skipped, an escaped
#    `<\/script>` inside a string does not close a block, an unterminated
#    last block is dropped; a page of external scripts only checks 0; two
#    failing scripts are two blocks and no OK line
PENV=(PL_ODD=1 PL_NONE=1 PL_TWOBAD=1); psame; PENV=()
assert_eq "$P_RC" 1 "row 6: a broken page exits 1"
assert_eq "$(pout | grep -E '^(OK|SYNTAX ERROR) ' | cut -c1-34)" "OK / (2 scripts)
OK /term (0 scripts)
SYNTAX ERROR /whiteboard script 1:
SYNTAX ERROR /whiteboard script 3:
OK /whiteboard-frame (2 scripts)
OK /review (2 scripts)" "row 6: counts and blocks"

# 7. a dashboard that dies at start: the polls stop once it is gone (a
#    logging wrapper around the real sleep counts them), the log follows the
#    refusal two-space indented (a blank line indents to two spaces)
plslog="$TMP/pl-slog"; mkdir -p "$plslog"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$PL_SLEEPS"\nexec /bin/sleep "$@"\n' >"$plslog/sleep"; chmod +x "$plslog/sleep"
PPATH="$plslog:$plstub:$PATH"; PENV=(PL_THROW=1 "PL_SLEEPS=$TMP/pl-sleeps")
: >"$TMP/pl-sleeps"; pside "$PO" po; o_rc="$P_SIDE"; o_n="$(grep -c . "$TMP/pl-sleeps" || true)"
: >"$TMP/pl-sleeps"; pside "$PN" pn; n_n="$(grep -c . "$TMP/pl-sleeps" || true)"
PPATH="$plstub:$PATH"; PENV=()
assert_eq "$P_SIDE $o_rc" "3 3" "row 7: exit 3 on both sides"
cmp -s "$TMP/po.out" "$TMP/pn.out" || fail "row 7: stdout differs"
cmp -s "$TMP/po.err" "$TMP/pn.err" || fail "row 7: stderr differs: $(diff "$TMP/po.err" "$TMP/pn.err" | head -n 6)"
[ "$o_n" -lt 50 ] && [ "$n_n" -lt 50 ] || fail "row 7: a dead dashboard stops the polls ($o_n/$n_n sleeps)"
assert_eq "$(perr | head -n 1)" "ac-page-lint.sh: dashboard did not come up on port N" "row 7: the refusal"
assert_contains "$(perr)" "  error: fixture: dashboard intentionally broken" "row 7: the indented log"
perr | grep -qx '  ' || fail "row 7: a blank log line indents to two spaces"
assert_eq "$(pout)" "" "row 7: nothing on stdout"

# 8. a dashboard that never answers `/` well: 50 polls, each followed by a
#    spawned `sleep 0.2` (a PATH stub here, binding both sides), then the
#    refusal with an empty log
plsleep="$TMP/pl-sleep"; mkdir -p "$plsleep"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$PL_SLEEPS"\n' >"$plsleep/sleep"; chmod +x "$plsleep/sleep"
PPATH="$plsleep:$plstub:$PATH"; PENV=(PL_ROOT500=1 "PL_SLEEPS=$TMP/pl-sleeps")
: >"$TMP/pl-sleeps"; pside "$PO" po; o_rc="$P_SIDE"; o_n="$(grep -c '^0.2$' "$TMP/pl-sleeps" || true)"
: >"$TMP/pl-sleeps"; pside "$PN" pn; n_n="$(grep -c '^0.2$' "$TMP/pl-sleeps" || true)"
PPATH="$plstub:$PATH"; PENV=()
assert_eq "$P_SIDE $o_rc" "3 3" "row 8: exit 3 on both sides"
assert_eq "$n_n $o_n" "50 50" "row 8: fifty polls on both sides"
assert_eq "$(perr)" "ac-page-lint.sh: dashboard did not come up on port N" "row 8: the refusal, an empty log"
cmp -s "$TMP/po.err" "$TMP/pn.err" || fail "row 8: stderr differs"

# 9. a caller cwd that is gone: the lint still runs
pgone() {
  local o_rc
  mkdir -p "$TMP/pl-gone"
  P_SIDE=0; (cd "$TMP/pl-gone" && rmdir "$TMP/pl-gone" && env LC_ALL=C PATH="$PPATH" PL_TMP="$PLT" PL_PIDS="$PLP" "$1/bin/ac-page-lint.sh") </dev/null >"$TMP/$2.raw" 2>"$TMP/$2.rawerr" || P_SIDE=$?
  pswept "$2 from a gone cwd"
}
pgone "$PO" po; o_rc="$P_SIDE"
pgone "$PN" pn
assert_eq "$P_SIDE $o_rc" "0 0" "row 9: a gone cwd lints clean"
assert_eq "$(cat "$TMP/pn.raw")" "$(cat "$TMP/po.raw")" "row 9: the same lines"

# 10. mktemp failing: its own line, then the refusal, exit 3
PENV=(PL_MKTEMP_FAIL=1); psame; PENV=()
assert_eq "$P_RC $(perr)" "3 mktemp: stub refused
ac-page-lint.sh: mktemp failed" "row 10: mktemp failed"

# 11. a PATH perl that is not executable is FOUND, as bash's `command -v`
#     finds it, and every extraction fails: five TOOLING ERROR lines, exit 3;
#     the shell's own `Permission denied` text inside the parentheses is not
#     reproduced (named: SHELL-OWN STDERR)
plnx="$TMP/pl-nxperl"
ptools "$plnx" bash dirname bun curl seq sleep sed cat rm mkdir awk
printf '#!/bin/sh\nexit 0\n' >"$plnx/perl"; chmod 644 "$plnx/perl"
PPATH="$plstub:$plnx"
pside "$PO" po; o_rc="$P_SIDE"
pside "$PN" pn
PPATH="$plstub:$PATH"
assert_eq "$P_SIDE $o_rc" "3 3" "row 11: exit 3 on both sides"
assert_eq "$(cat "$TMP/pn.out" "$TMP/po.out")" "" "row 11: no page passes"
assert_eq "$(cut -d'(' -f1 "$TMP/pn.err")" "$(cut -d'(' -f1 "$TMP/po.err")" "row 11: the same TOOLING ERROR lines"
assert_eq "$(grep -c '^TOOLING ERROR .*: script extraction failed ()$' "$TMP/pn.err")" 5 "row 11: the port's parentheses are empty (named)"
assert_contains "$(cat "$TMP/po.err")" "Permission denied" "row 11: the shell's own text on the original"

# 12. a TERM while a page fetch hangs: the EXIT trap's sweep runs - the run
#     ends 143, no tmpdir is left and the dashboard is gone
pterm() {  # pterm <side root> <prefix>
  local hold="$TMP/pl-hold" n=0 pid
  rm -f "$hold"
  (cd "$1" && exec env LC_ALL=C PATH="$PPATH" PL_TMP="$PLT" PL_PIDS="$PLP" PL_HOLD="$hold" ./bin/ac-page-lint.sh) </dev/null >"$TMP/$2.raw" 2>"$TMP/$2.rawerr" &
  pid=$!
  until [ -e "$hold" ]; do n=$((n + 1)); [ "$n" -lt 200 ] || { kill -TERM "$pid"; fail "row 12: $2 never reached /term"; }; sleep 0.05; done
  kill -TERM "$pid"
  P_SIDE=0; wait "$pid" 2>/dev/null || P_SIDE=$?
  pswept "$2 after TERM"
}
pterm "$PO" po; o_rc="$P_SIDE"
pterm "$PN" pn
assert_eq "$P_SIDE $o_rc" "143 143" "row 12: TERM ends both runs"
assert_eq "$(cat "$TMP/pn.raw")" "$(cat "$TMP/po.raw")" "row 12: the same lines before the signal"
assert_eq "$(cat "$TMP/pn.raw")" "OK / (2 scripts)" "row 12: the page before the hold"

# 13. W5: the readiness curl has no time limit - a dashboard that accepts `/`
#     and never answers holds the run in that poll (no sleep follows it)
#     until a signal. Started as an async job of this non-interactive shell,
#     the run inherits SIGINT ignored: the original runs on and a TERM ends
#     it, the port ends 130 on the INT and sweeps (named divergence)
pheld() {  # pheld <side root> <prefix> - start the side held on `/`; its pid in P_PID
  local n=0 c
  rm -f "$TMP/pl-hold"; : >"$TMP/pl-sleeps"
  (cd "$1" && exec env LC_ALL=C PATH="$plsleep:$PPATH" PL_TMP="$PLT" PL_PIDS="$PLP" PL_HOLD="$TMP/pl-hold" PL_HOLDPATH=/ PL_SLEEPS="$TMP/pl-sleeps" ./bin/ac-page-lint.sh) </dev/null >"$TMP/$2.raw" 2>"$TMP/$2.rawerr" &
  P_PID=$!
  until [ -e "$TMP/pl-hold" ]; do n=$((n + 1)); [ "$n" -lt 200 ] || { kill -TERM "$P_PID"; fail "row 13: $2 never polled /"; }; sleep 0.05; done
  c="$(grep -c . "$TMP/pl-sleeps" || true)"
  sleep 1
  kill -0 "$P_PID" 2>/dev/null || fail "row 13: $2 must still hang in the accepted poll (W5)"
  [ "$(grep -c . "$TMP/pl-sleeps" || true)" = "$c" ] || { kill -TERM "$P_PID"; fail "row 13: $2 polled again after / was accepted (W5)"; }
  kill -INT "$P_PID"
}
pended() {  # pended <what> - P_PID ended within 5 s, its status in P_SIDE
  local n=0
  while kill -0 "$P_PID" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 50 ] || { kill -TERM "$P_PID"; fail "row 13: $1 did not end"; }; sleep 0.1
  done
  P_SIDE=0; wait "$P_PID" 2>/dev/null || P_SIDE=$?
}
pheld "$PO" po
sleep 0.5
kill -0 "$P_PID" 2>/dev/null || fail "row 13: the original runs on through an ignored SIGINT"
kill -TERM "$P_PID"; o_rc=0; wait "$P_PID" 2>/dev/null || o_rc=$?
pswept "po after INT then TERM"
pheld "$PN" pn
pended "the port after INT"
pswept "pn after INT"
assert_eq "$o_rc $P_SIDE" "143 130" "row 13: the original ends on TERM, the port on INT"
assert_eq "$(cat "$TMP/po.raw" "$TMP/pn.raw")" "" "row 13: no page was ever checked"

# 14. without seq(1) on PATH the original's `$(seq 1 30)` loop ran zero
#     times - `could not find a free port`, exit 3 - where the port counts its
#     own draws and runs (named divergence)
ptools "$TMP/pl-noseq" bash dirname bun curl perl sleep sed cat rm mkdir awk
PPATH="$plstub:$TMP/pl-noseq"
pside "$PO" po; o_rc="$P_SIDE"
pside "$PN" pn
PPATH="$plstub:$PATH"
assert_eq "$o_rc" 3 "row 14: the original cannot count without seq"
assert_contains "$(cat "$TMP/po.err")" "ac-page-lint.sh: could not find a free port" "row 14: the original's refusal"
assert_eq "$P_SIDE $(cat "$TMP/pn.out")" "0 $ALL_OK" "row 14: the port runs"

# Named and not pinned here (the header lists them): under a UTF-8 locale BSD
# sed stopped the original's log dump at an invalid byte, the port prefixes
# every byte (this leg runs LC_ALL=C); a signal ends the port with 128+n where
# bash died by it - the same status to a shell; bun build no longer sees a
# caller's BUN_*/JSC_* names (BUN_OPTIONS with an unknown flag, probed, changed
# no verdict); a non-UTF-8 argument reaches the port as U+FFFD.

pass
