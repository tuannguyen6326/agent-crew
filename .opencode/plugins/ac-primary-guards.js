// ac-primary-guards.js - the fleet guards for an opencode PRIMARY, one file.
//
// opencode has no Stop hook and no PreToolUse config surface; a worktree
// plugin is the hook mechanism, and this single plugin wires BOTH duties so
// there is exactly one root resolution and one process runner:
//
// - tool.execute.before (bash tool): the command is wrapped in the claude
//   hook-payload shape and piped to bin/ac-watch-policy-hook.sh - the guard
//   scripts keep their one input mode, the plugin adapts. Exit 2 THROWS,
//   which blocks the command and surfaces the reason as the tool result
//   (documented opencode plugin behavior, 1.17+).
// - session.idle (the turn-end signal): bin/ac-turnend-guard.sh judges the
//   would-be turn end; exit 2 injects the objection back into the session as
//   a prompt. That injected prompt settles into another idle, and swallowIdle
//   eats exactly that one, so the guard never argues with itself.
//
// Every path fails OPEN - a broken guard must never wedge the harness - and
// both guard scripts self-scope, so outside a real primary checkout the
// plugin is inert. AC_HOME reaches the guards through plain process env (the
// `ac` launcher exports it before exec'ing the harness). Live probe on this
// rig pending; tests/ac-harness-hooks.test.sh fences the wiring.

import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

const sh = (cmd, args = [], stdin = "") =>
  new Promise((done) => {
    let out = "";
    let err = "";
    const p = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("error", () => done({ code: 0, out: "", err: "" }));
    p.on("close", (code) => done({ code: code ?? 0, out, err }));
    p.stdin.end(stdin);
  });

const real = (p) => {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
};

async function repoRoot(directory, worktree) {
  if (worktree) return real(worktree);
  if (!directory) return "";
  const { code, out } = await sh("git", ["-C", directory, "rev-parse", "--show-toplevel"]);
  const top = out.trim();
  return code === 0 && top ? top : real(directory);
}

export const AcPrimaryGuards = async ({ client, directory, worktree }) => {
  const root = await repoRoot(directory, worktree);
  const guard = (script, stdin) =>
    root ? sh(`${root}/bin/${script}`, [], stdin) : Promise.resolve({ code: 0, err: "" });
  let swallowIdle = false;

  return {
    "tool.execute.before": async (input, output) => {
      const command = output?.args?.command;
      if (input?.tool !== "bash" || typeof command !== "string" || !command) return;
      const { code, err } = await guard(
        "ac-watch-policy-hook.sh",
        JSON.stringify({ tool_name: "Bash", tool_input: { command } }),
      );
      if (code !== 2) return;
      throw new Error(err.trim() || "denied by the watcher-policy PreToolUse seatbelt");
    },

    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      if (swallowIdle) {
        swallowIdle = false;
        return;
      }
      const id = event.properties?.sessionID;
      if (!id) return;
      const { code, err } = await guard("ac-turnend-guard.sh", '{"stop_hook_active":false}');
      if (code !== 2) return;
      try {
        await client.session.promptAsync({
          path: { id },
          body: {
            parts: [
              {
                type: "text",
                text:
                  "TURN WOULD END BLIND - supervision is off. " +
                  "Drain queued wakes and re-arm the watcher (bin/ac-watch.sh, or a bounded --once checkpoint) before ending the turn.\n\n" +
                  err,
              },
            ],
          },
        });
        swallowIdle = true;
      } catch {
        swallowIdle = false;
      }
    },
  };
};
