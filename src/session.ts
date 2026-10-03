// session.ts - open (or print) a claude resume of a crewmate's session. The
// entry is bin/ac-session.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-session.sh as the oracle the
// differential leg of tests/sh/ac-session.test.sh holds this module to.
//
//   ac-session.sh <id>          # SAFE view: resume with --fork-session -
//                               # reading/replying never mutates the
//                               # crewmate's real session
//   ac-session.sh <id> --talk   # UN-FORKED resume: what you say lands in the
//                               # session a later --resume-from continues -
//                               # REFUSED while the crewmate is busy (two
//                               # writers corrupt one session)
//
// Prints the command by default (run it in any pane). Works on live and
// archived tasks (teardown keeps session_id in state/archive/<id>/meta).
// Exit 0 with the command on stdout; 1 on a refusal (ERROR: on stderr, the
// usage line included). A worktree that is gone is a WARN, never a refusal.
//
// The meta is read as bytes (latin1) and written back the same way, so a path
// the bash original printed byte for byte still is; the id arrives from Bun's
// UTF-8 argv and is folded into that byte space before it meets them.
import { statSync, writeSync } from "node:fs";
import { join } from "node:path";
import { die, enterCaller, metaGet, stateDir, warn } from "./lib.ts";

const bin = join(import.meta.dir, "..", "bin");
const b = (s: string): Buffer => Buffer.from(s, "latin1");
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};

const { args } = enterCaller(process.argv.slice(2));
const id = Buffer.from(args[0] ?? "", "utf8").toString("latin1");
if (!id) die("usage: ac-session.sh <id> [--talk]");
const talk = args[1] === "--talk";

let meta = join(stateDir(), `${id}.meta`);
let live = true;
if (!isFile(meta)) {
  meta = join(stateDir(), "archive", id, "meta");
  live = false;
}
if (!isFile(meta)) die(b(`no crewmate meta for ${id}`));
// ac_meta_get's unreadable-file status is lost inside the bash `[ ... ]` the
// harness check runs in, so an unreadable meta reads as no harness there.
const field = (key: string): string => {
  try {
    return metaGet(meta, key);
  } catch {
    return "";
  }
};
if (field("harness") !== "claude") die(b(`${id} is not a claude crewmate`));
const sid = field("session_id");
if (!sid) die(b(`${id} has no recorded session_id (pre-plumbing task)`));
const worktree = field("worktree");

if (talk && live) {
  // `$(... || printf unknown)`: a failed state read keeps whatever it printed
  // first, then "unknown"; the substitution drops every trailing newline.
  const r = Bun.spawnSync([join(bin, "ac-crew-state.sh"), id], { stdout: "pipe", stderr: "ignore" });
  const state = (r.stdout.toString("latin1") + (r.exitCode === 0 ? "" : "unknown")).replace(/\n+$/, "");
  if (state.startsWith("busy") || state.includes("working:") || state.startsWith("validate:"))
    die(b(`REFUSED: ${id} is mid-turn (${state}) - two writers corrupt one session. Talk when it parks, or ac-follow.sh to watch now.`));
  // An unknown backend must not proceed here, the same direction as the
  // collision-refusal guard (ac-spawn.sh reap_orphan_window): writing an
  // un-forked --talk into a pane that turns out to still be mid-turn corrupts
  // the session, the same class of harm the collision guard refuses to risk
  // on an unknown backend (a REAP guard on the other hand must not ACT on
  // unknown - there is no write here to withhold, so refusing IS this
  // guard's "do nothing").
  if (state.startsWith("unobservable"))
    die(b(`REFUSED: the backend for ${id} could not be read (${state}) - liveness is UNKNOWN, and two writers corrupt one session if it is still mid-turn. Check the backend (herdr status server), then talk again once it is readable.`));
}

if (!isDir(worktree)) warn(b(`worktree ${worktree} is gone; mkdir -p it to let --resume load the transcript`));
if (talk) {
  writeSync(1, b(`# TALK: un-forked - your words become part of what --resume-from continues\ncd '${worktree}' && claude --resume ${sid}\n`));
} else {
  writeSync(1, b(`# VIEW: forked - safe to read and poke, never mutates the real session\ncd '${worktree}' && claude --resume ${sid} --fork-session\n`));
}
