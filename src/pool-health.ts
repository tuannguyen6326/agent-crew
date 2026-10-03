// pool-health.ts - render the worktree-pool health ride-along for the
// session-start digest (task-lifecycle skill): per project repo, how many
// .crew/slots pool slots are leasable vs stuck available-dirty (unleasable
// until a chief runs `ac-tree.sh remove --force <path>` - `get` skips a dirty
// slot by design and never resets it silently, and this module never does
// either) vs broken (worktree dir survives, gitdir unreadable - `ac-tree.sh
// list` reports this as its own `broken` state, because is_dirty is blind on
// such a tree) vs aged-leased (a durable lease - empty owner_pid, ac-tree.sh
// lease_reclaimable "No owner = durable" - held past 24h with no reclaim path
// of its own: acquire_slot, prune_pass and remove_slot all skip a leased slot
// by design, so nothing else ever names it). Reads pool state ONLY via
// `ac-tree.sh list --repo <repo>`, never by re-deriving lease/dirty/broken
// state itself; age comes from the leased_at/owner_pid fields that wire
// carries. The entry is bin/ac-pool-health.sh (a shim that starts this file
// through bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-pool-health.sh as the
// oracle the differential leg of tests/sh/ac-pool-health.test.sh holds this
// module to.
//
// The aged-leased signal is SUSPICION, not death: an absent state/<id>.meta
// for the holder proves nothing while the holder may simply not have
// published it yet (bin/ac-verify.sh leases in verify_lease and publishes meta
// only later in publish_meta). This module never reclaims, resets or expires
// anything - it only names the slot and the exact `remove --include-leased` a
// chief may choose to run: that command's own broken/dirty/unmerged gates
// (remove_slot, bin/ac-tree.sh) stay armed without --force, so it REFUSES
// instead of discarding if the slot still holds real content.
//
//   ac-pool-health.sh [--repo <path>]...
//
// Args: `--repo <path>`, repeatable, scanned in the order given and never
// canonicalised (the block names `basename <path>`, so `--repo .` prints
// `.:`); an empty path is skipped. Any other word: `ERROR: ac-pool-health.sh:
// unknown argument <word>`, exit 1. A dangling `--repo`: exit 1 (the original
// died on bash's own `$2: unbound variable`; the text is not reproduced).
// stdin is never read. Exit 0 on every report path, even when every
// `ac-tree.sh list` failed.
//
// Discovery (no --repo): the dirs of `$(ac_projects_dir)/*/` in byte order -
// projects/ is minted, a dotdir is never matched, a symlink to a dir is
// followed - kept when `git -C <p> rev-parse --git-dir` succeeds and
// `<p>/.crew/slots` is a directory; each path carries the glob's trailing `/`.
// With no AC_HOME the refusal `ERROR: AC_HOME is not set - ...` goes to stderr
// and the run ends with nothing on stdout, exit 0: the original printed the
// same line from inside its `$(ac_projects_dir)` and went on to glob `/*/`,
// scanning the filesystem root for pools, an artifact this port drops.
//
// Per repo: the rows of `<bin>/ac-tree.sh list --repo <repo>` (the sibling
// bin/ of this module's entry, run from the caller's cwd; stderr discarded,
// exit status ignored - a dying list reads as an empty, healthy pool), read as
// `IFS=$'\t' read -r n state task wt leased_at owner` reads them (tabFields,
// src/lib.ts): runs of tabs collapse, so a leased row with an empty leased_at
// lands its owner in leased_at, which then misses the date pattern and is
// never aged; an unterminated last line and a row with an empty n are
// skipped. Buckets: total = every row; leasable = state `available`; stuck =
// `available dirty`; broken = `broken`; aged = `leased` or `leased dirty` with
// an EMPTY owner and leaseAgeSecs(leased_at) >= 86400 (BSD strptime decides
// what a stamp is worth - see leaseAgeSecs); any other state counts in total
// only.
//
// stdout, only when some scanned repo has stuck + broken + aged >= 1 (else
// NOTHING, not even a newline):
//
//   -- pool (worktree health) --
//   <basename>: <leasable> leasable / <total> total, <stuck> stuck-dirty (unleasable), <broken> broken (unleasable), <aged> aged-leased (>=24h, unconfirmed)
//     reclaim each dirty slot: bin/ac-tree.sh remove --force <worktree-path>                       [stuck >= 1]
//     reclaim each broken slot: bin/ac-tree.sh remove --force <worktree-path>                      [broken >= 1]
//     reclaim each aged lease (the broken/dirty/unmerged gates stay armed - it refuses instead of discarding if the slot still holds real content): bin/ac-tree.sh remove --include-leased <worktree-path>   [aged >= 1]
//     slot <n>  <task>  <wt>                              one per stuck row, list order
//     slot <n>  <task>  <wt>                              one per broken row
//     slot <n>  <task>  leased <h>h ago  <wt>             one per aged row, h = age / 3600 truncated
//
// Two spaces between columns, <task> verbatim (the quoted '-' when the meta
// has none); a healthy repo contributes nothing; unhealthy blocks follow in
// repo order with no separator; the header once; every line LF-terminated.
// The list rows and the repo name are handled as latin1 bytes and written
// back as those bytes, so a path prints as the shell printed it.
import { readdirSync, statSync, writeSync } from "node:fs";
import { basename, join } from "node:path";
import { die, enterCaller, leaseAgeSecs, NO_HOME, projectsDir, tabFields } from "./lib.ts";

const bin = join(import.meta.dir, "..", "bin");
const AGED_LEASE_THRESHOLD_SECS = 86400;
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};

const { args } = enterCaller(process.argv.slice(2));
const repos: string[] = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] !== "--repo") die(Buffer.from(`ac-pool-health.sh: unknown argument ${bytes(args[i])}`, "latin1"));
  if (i + 1 >= args.length) die("ac-pool-health.sh: --repo takes a path");
  repos.push(args[++i]);
}

if (repos.length === 0) {
  if (!process.env.AC_HOME) {
    writeSync(2, `ERROR: ${NO_HOME}\n`);
    process.exit(0);
  }
  const dir = projectsDir();
  const names = readdirSync(dir).filter((n) => !n.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const name of names) {
    const p = `${join(dir, name)}/`;
    if (!isDir(p)) continue;
    if (Bun.spawnSync(["git", "-C", p, "rev-parse", "--git-dir"], { stdout: "ignore", stderr: "ignore" }).exitCode !== 0) continue;
    if (!isDir(join(p, ".crew", "slots"))) continue;
    repos.push(p);
  }
}

let block = "";
for (const repo of repos) {
  if (repo === "") continue;
  let leasable = 0, total = 0, stuck = 0, broken = 0, aged = 0;
  let slotLines = "", brokenLines = "", agedLines = "";
  const list = Bun.spawnSync([join(bin, "ac-tree.sh"), "list", "--repo", repo], { stdout: "pipe", stderr: "ignore" });
  const rows = list.stdout.toString("latin1").split("\n");
  rows.pop();
  for (const row of rows) {
    const [n, state, task, wt, leasedAt, owner] = tabFields(row, 6);
    if (n === "") continue;
    total++;
    if (state === "available") leasable++;
    else if (state === "available dirty") {
      stuck++;
      slotLines += `  slot ${n}  ${task}  ${wt}\n`;
    } else if (state === "broken") {
      broken++;
      brokenLines += `  slot ${n}  ${task}  ${wt}\n`;
    } else if (state === "leased" || state === "leased dirty") {
      if (owner !== "") continue;
      const age = leaseAgeSecs(leasedAt);
      if (age === null || age < AGED_LEASE_THRESHOLD_SECS) continue;
      aged++;
      agedLines += `  slot ${n}  ${task}  leased ${Math.floor(age / 3600)}h ago  ${wt}\n`;
    }
  }
  if (stuck < 1 && broken < 1 && aged < 1) continue;
  let hints = "";
  if (stuck >= 1) hints += "  reclaim each dirty slot: bin/ac-tree.sh remove --force <worktree-path>\n";
  if (broken >= 1) hints += "  reclaim each broken slot: bin/ac-tree.sh remove --force <worktree-path>\n";
  if (aged >= 1)
    hints += "  reclaim each aged lease (the broken/dirty/unmerged gates stay armed - it refuses instead of discarding if the slot still holds real content): bin/ac-tree.sh remove --include-leased <worktree-path>\n";
  block += `${bytes(basename(repo))}: ${leasable} leasable / ${total} total, ${stuck} stuck-dirty (unleasable), ${broken} broken (unleasable), ${aged} aged-leased (>=${AGED_LEASE_THRESHOLD_SECS / 3600}h, unconfirmed)\n${hints}${slotLines}${brokenLines}${agedLines}`;
}

if (block !== "") writeSync(1, Buffer.from(`-- pool (worktree health) --\n${block}`, "latin1"));
