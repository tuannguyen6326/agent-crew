// room.ts - the per-room projection `ac-room.sh list` renders. The entry is
// ac_room_list_rows in bin/ac-wake-lib.sh, which starts this file through
// bin/ac-bun.sh inside a subshell because ac_bun_exec execs; THIS header is the
// authoritative spec of the rows. tests/sh/ac-room.test.sh holds it to
// tests/fixtures/room-list-rows.awk, the awk pass it replaced, frozen.
//
// Usage (the caller's cwd arrives first, from ac_bun_exec):
//   room.ts rows <room-file>...
//       one line "<pending>\x1f<hb>\x1f<family>\x1f<last>" per argument, in
//       argument order, an empty room included (0, 0, its family, "")
// Exit 0; 2 with no rows printed on a usage error or when any room cannot be
// read, as awk's open failure did - a caller reads no answer, never the
// others' rows.
//
// A room is bytes: read latin1, every byte one character, and a line ends at
// its first NUL - the C-locale awk reading. The counting grammar is the room
// grammar bin/ac-wake-lib.sh owns (ac_room_pending, ac_room_handback_families),
// copied pattern for pattern: <pending> is GATE/ASK items minus DECIDED, each
// DECIDED settling one open item and never going below 0; <hb> is 1 while the
// last HANDBACK: is not followed by HANDBACK-REFUSED:, DEMOTED: or CLOSED:.
// <family> is the room file's parent directory name and <last> is the whole
// last line opening "- [", untruncated - the caller truncates by character.
// State is keyed by the path as given, so a room named twice counts twice, as
// awk's FILENAME-keyed arrays did. The field separator is 0x1f, never a tab,
// because bash's `read` trims a trailing tab off the last field.

import { readFileSync, writeSync } from "node:fs";
import { isAbsolute } from "node:path";
import { records } from "./backlog.ts";
import { enterCaller } from "./lib.ts";

const OPEN = /^- \[[^\]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/;
const DECIDED = /^- \[[^\]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/;
const HANDBACK = /^- \[[^\]]*\] [^>]*> HANDBACK:/;
const REFUSED = /^- \[[^\]]*\] [^>]*> HANDBACK-REFUSED:/;
const RETIRED = /^- \[[^\]]*\] [^>]*> (DEMOTED|CLOSED):/;

function fail(msg: string): never {
  writeSync(2, `ERROR: ${msg}\n`);
  process.exit(2);
}

function family(path: string): string {
  const a = path.split("/");
  return a.length >= 2 ? a[a.length - 2] : path;
}

function main(args: string[], atCaller: boolean): void {
  if (args[0] !== "rows" || args.length < 2) fail("usage: room.ts rows <room-file>...");
  const files = args.slice(1);
  const state = new Map<string, { open: number; hb: number; last: string }>();
  for (const f of files) {
    if (!isAbsolute(f) && !atCaller) fail(`cannot read ${f}: the current directory has no name`);
    let text: string;
    try {
      text = readFileSync(f).toString("latin1");
    } catch {
      fail(`cannot read ${f}`);
    }
    let s = state.get(f);
    if (!s) state.set(f, (s = { open: 0, hb: 0, last: "" }));
    for (const l of records(text)) {
      if (OPEN.test(l)) s.open++;
      if (DECIDED.test(l) && s.open > 0) s.open--;
      if (HANDBACK.test(l)) s.hb = 1;
      if (REFUSED.test(l) || RETIRED.test(l)) s.hb = 0;
      if (l.startsWith("- [")) s.last = l;
    }
  }
  const out = files.map((f) => {
    const s = state.get(f) as { open: number; hb: number; last: string };
    return `${s.open}\x1f${s.hb}\x1f${family(f)}\x1f${s.last}\n`;
  });
  const buf = Buffer.from(out.join(""), "latin1");
  try {
    for (let off = 0; off < buf.length; ) off += writeSync(1, buf, off);
  } catch (e) {
    if ((e as { code?: string }).code !== "EPIPE") throw e;
  }
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  main(args, atCaller);
}
