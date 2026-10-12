// pool-health.test.ts - the lib.ts twins src/pool-health.ts introduced, held to
// their bash originals differentially: now against ac_now, tabFields against `IFS=$'\t' read -r`, and leaseAgeSecs
// against lease_age_secs lifted from the frozen original, over the stamps BSD
// strptime rolls or refuses - with date(1) stubbed on PATH so `date +%s`
// answers one instant to both sides. The CLI contract itself is
// tests/sh/ac-pool-health.test.sh's, whose differential leg runs the frozen
// original beside the shim.
import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { leaseAgeSecs, now, tabFields } from "../../src/lib.ts";

const root = join(import.meta.dir, "..", "..");
const binDir = join(root, "bin");
const oracle = join(root, "tests", "fixtures", "ac-pool-health.sh");
const savedEnv = { ...process.env };
afterEach(() => {
  for (const k of Object.keys(process.env)) if (!(k in savedEnv)) delete process.env[k];
  Object.assign(process.env, savedEnv);
});

function bash(body: string, ...args: string[]) {
  const r = Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; ${body}`, binDir, ...args], { stdout: "pipe", stderr: "pipe", env: process.env });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString(), rc: r.exitCode ?? -1 };
}

// `date +%s` answers one fixed instant; every other call reaches the real date,
// so the strptime read stays the host's own.
function stubDate(): string {
  const d = mkdtempSync(join(tmpdir(), "ac-pool-health-date-"));
  writeFileSync(join(d, "date"), '#!/bin/sh\ncase "$*" in "+%s") echo 1800000000 ;; *) exec /bin/date "$@" ;; esac\n', { mode: 0o755 });
  process.env.PATH = `${d}:${process.env.PATH}`;
  return d;
}



test("now reads date(1) like ac_now's bash-3.2 rung, so one PATH stub binds both", () => {
  const d = stubDate();
  try {
    // EPOCHSECONDS is unset so a bash 5 on PATH takes the same date rung.
    expect(bash("unset EPOCHSECONDS; ac_now").out).toBe("1800000000\n");
    expect(now()).toBe(1800000000);
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});

// The ac-tree list wire is read with `IFS=$'\t' read -r`: tab is IFS whitespace,
// so runs collapse, leading and trailing ones go, and the last name keeps the
// rest of the row with its own tabs.
test("tabFields splits a row as IFS=$'\\t' read -r assigns six names", () => {
  const rows = [
    "1-a\tavailable\t'-'\t/wt/1\t\t",
    "1-a\tleased\tt1\t/wt/1\t2026-01-01T00:00:00Z\t123",
    "1-a\tleased\tt1\t/wt/1\t\t123",
    "\t1-a\tavailable dirty\tt1\t/wt/1",
    "a\t\t\tb",
    "a\tb\tc\td\te\tf\tg\th\t",
    "a\tb\tc\td\te\tf\t\tg",
    "",
    "\t\t",
    "only",
    "a b\tc\\d\te\r",
  ];
  for (const row of rows) {
    const want = bash(
      'printf "%s\\n" "$1" | { IFS=$\'\\t\' read -r n s t w l o; printf "%s\\x1f" "$n" "$s" "$t" "$w" "$l" "$o"; }',
      row,
    );
    expect(want.rc).toBe(0);
    expect([row, tabFields(row, 6)]).toEqual([row, want.out.split("\x1f").slice(0, 6)]);
  }
});

// The stamps BSD strptime rolls (Feb 30, day 00, :60) or refuses (month 00/13,
// day 32, hour 24, minute 60), the pattern's own refusals, and a plain one;
// the bash side is the original's lease_age_secs itself, lifted from the
// frozen oracle, and the stub freezes `now` for both so the ages are exact.
test("leaseAgeSecs answers exactly what lease_age_secs does over BSD strptime's acceptance set", () => {
  const d = stubDate();
  try {
    const stamps = [
      "2024-02-30T00:00:00Z",
      "2024-01-00T00:00:00Z",
      "2026-01-01T00:00:60Z",
      "2026-13-01T00:00:00Z",
      "2026-00-10T00:00:00Z",
      "2026-01-32T00:00:00Z",
      "2026-01-01T24:00:00Z",
      "2026-01-01T00:60:00Z",
      "2026-01-01T00:00:00Z",
      "2099-01-01T00:00:00Z",
      "2026-1-01T00:00:00Z",
      "2026-01-01T00:00:00",
      " 2026-01-01T00:00:00Z",
      "bogus",
      "",
    ];
    for (const tz of ["Asia/Ho_Chi_Minh", "America/Los_Angeles"]) {
      process.env.TZ = tz;
      for (const ts of stamps) {
        const want = bash(
          'unset EPOCHSECONDS; eval "$(sed -n "/^lease_age_secs()/,/^}/p" "$1")"; lease_age_secs "$2"',
          oracle,
          ts,
        );
        expect(want.rc).toBe(0);
        const got = leaseAgeSecs(ts);
        expect([tz, ts, got === null ? "" : `${got}\n`]).toEqual([tz, ts, want.out]);
      }
    }
    expect(leaseAgeSecs("2024-02-30T00:00:00Z")).toBe(1800000000 - 1709251200);
    expect(leaseAgeSecs("2026-13-01T00:00:00Z")).toBeNull();
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});

// No `date` on PATH at all: the spawn cannot start, and that reads as no age too.
test("leaseAgeSecs reads no age when date(1) is not on PATH", () => {
  const d = mkdtempSync(join(tmpdir(), "ac-pool-health-nopath-"));
  try {
    process.env.PATH = d;
    expect(leaseAgeSecs("2026-01-01T00:00:00Z")).toBeNull();
    expect(now()).toBeNaN();
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});

// A `date` that is not there at all: the bash's `|| return 0` reads as no age.
test("leaseAgeSecs reads no age when date(1) cannot run", () => {
  const d = mkdtempSync(join(tmpdir(), "ac-pool-health-nodate-"));
  try {
    writeFileSync(join(d, "date"), "#!/bin/sh\nexit 1\n");
    chmodSync(join(d, "date"), 0o755);
    process.env.PATH = `${d}:${process.env.PATH}`;
    expect(leaseAgeSecs("2026-01-01T00:00:00Z")).toBeNull();
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});
