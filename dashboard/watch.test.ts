// watch.test.ts - the fleet-state watcher (dashboard/watch.ts) fires its
// per-home change hook on the files ac-fleets.sh --json reads, and ONLY on
// those, so the dashboard's snapshot memo is dropped the moment fleet state
// moves instead of waiting out the TTL. Run: bun test dashboard/watch.test.ts
//
// Timing here is the OS notifying a watcher, not a poll: each assertion waits
// on the hook itself (bounded), never on a fixed sleep judged "long enough".

import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { watchHomes } from "./watch.ts";
import { ttlMemo } from "./app.ts";

function fleetHome(): string {
  const home = mkdtempSync(`${tmpdir()}/dash-watch-`);
  mkdirSync(`${home}/state`);
  mkdirSync(`${home}/records`);
  mkdirSync(`${home}/data/fam`, { recursive: true });
  writeFileSync(`${home}/state/t1.status`, "started\n");
  writeFileSync(`${home}/records/backlog.md`, "# backlog\n");
  writeFileSync(`${home}/data/fam/room.md`, "# room\n");
  return home;
}

// A watcher needs a beat to be live before the first write lands - the
// event source is the OS, armed asynchronously.
const settle = () => new Promise((r) => setTimeout(r, 300));

function waiter() {
  let fired = 0;
  let wake: (() => void) | null = null;
  return {
    hook: () => { fired++; if (wake) { const w = wake; wake = null; w(); } },
    count: () => fired,
    next: (ms = 3000) => new Promise<boolean>((resolve) => {
      const t = setTimeout(() => { wake = null; resolve(false); }, ms);
      wake = () => { clearTimeout(t); resolve(true); };
    }),
  };
}

test("a status write invalidates the snapshot memo through the watcher's hook", async () => {
  const home = fleetHome();
  let gathers = 0;
  const memo = ttlMemo(60_000, async () => ++gathers);
  expect(await memo()).toBe(1);
  const w = waiter();
  const watcher = watchHomes((h) => { expect(h).toBe(home); memo.invalidate(); w.hook(); }, { debounceMs: 20 });
  watcher.sync([home]);
  await settle();
  const p = w.next();
  appendFileSync(`${home}/state/t1.status`, "done\n");
  expect(await p).toBe(true);
  expect(await memo()).toBe(2);
  watcher.close();
  rmSync(home, { recursive: true, force: true });
});

test("backlog.md and data/<family>/room.md writes fire; unrelated files in the same dirs do not", async () => {
  const home = fleetHome();
  const w = waiter();
  const watcher = watchHomes(() => w.hook(), { debounceMs: 20 });
  watcher.sync([home]);
  await settle();
  let p = w.next();
  appendFileSync(`${home}/records/backlog.md`, "- [ ] x - y (repo: r)\n");
  expect(await p).toBe(true);
  p = w.next();
  appendFileSync(`${home}/data/fam/room.md`, "entry\n");
  expect(await p).toBe(true);
  const before = w.count();
  p = w.next(600);
  writeFileSync(`${home}/state/watcher.beacon`, "1\n");
  writeFileSync(`${home}/records/learnings.md`, "1\n");
  writeFileSync(`${home}/data/fam/report.md`, "1\n");
  expect(await p).toBe(false);
  expect(w.count()).toBe(before);
  watcher.close();
  rmSync(home, { recursive: true, force: true });
});

test("a burst of writes inside the debounce window fires the hook once", async () => {
  const home = fleetHome();
  const w = waiter();
  const watcher = watchHomes(() => w.hook(), { debounceMs: 150 });
  watcher.sync([home]);
  await settle();
  const p = w.next();
  for (let i = 0; i < 5; i++) appendFileSync(`${home}/state/t1.status`, `line ${i}\n`);
  expect(await p).toBe(true);
  await new Promise((r) => setTimeout(r, 300));
  expect(w.count()).toBe(1);
  watcher.close();
  rmSync(home, { recursive: true, force: true });
});

test("a home with no watchable dirs, or one removed underneath, is logged and never throws", async () => {
  const logged: string[] = [];
  const watcher = watchHomes(() => {}, { debounceMs: 20, log: (l) => logged.push(l) });
  expect(() => watcher.sync(["/nonexistent/home"])).not.toThrow();
  expect(logged.length).toBeGreaterThan(0);
  const home = fleetHome();
  watcher.sync([home]);
  await settle();
  rmSync(home, { recursive: true, force: true });
  await settle();
  expect(watcher.watched()).toContain(home);
  watcher.close();
});

test("sync adds new homes and drops ones no longer surveyed", async () => {
  const a = fleetHome(), b = fleetHome();
  const watcher = watchHomes(() => {}, { debounceMs: 20 });
  watcher.sync([a]);
  expect(watcher.watched()).toEqual([a]);
  watcher.sync([a, b]);
  expect(watcher.watched().sort()).toEqual([a, b].sort());
  watcher.sync([b]);
  expect(watcher.watched()).toEqual([b]);
  watcher.close();
  expect(watcher.watched()).toEqual([]);
  rmSync(a, { recursive: true, force: true });
  rmSync(b, { recursive: true, force: true });
});
