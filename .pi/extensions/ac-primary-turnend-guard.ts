// ac-primary-turnend-guard.ts - "no turn ends blind" plus the bash-tool
// seatbelt for a pi PRIMARY, in ONE extension file so a single -e flag loads
// both (pi has no Stop hook or PreToolUse config surface; extensions are the
// hook mechanism).
//
// - tool_call on the bash tool pipes the command to
//   bin/ac-watch-policy-hook.sh (the claude payload shape, synthesized here);
//   exit 2 answers { block: true, reason } - documented pi extension
//   behavior: a blocked tool_call never runs the command.
// - agent_settled (pi's turn-end signal) runs bin/ac-turnend-guard.sh; exit
//   2 injects the objection back as a follow-up user message, and
//   guardFollowupActive swallows exactly the settle that follow-up causes,
//   so the guard cannot loop on itself.
//
// Every path fails OPEN, both guards self-scope outside a real primary
// checkout, and AC_HOME reaches them through plain process env (the `ac`
// launcher exports it before exec'ing the harness). The root is resolved
// from this file's own location (.pi/extensions/ -> repo root), never cwd.
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

let guardFollowupActive = false;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");

function runProcess(
  command: string,
  input = "",
): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(command, { stdio: ["pipe", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end(input);
  });
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const payload = JSON.stringify({ tool_name: "Bash", tool_input: { command } });
    const result = await runProcess(`${root}/bin/ac-watch-policy-hook.sh`, payload);
    if (result.code !== 2) return {};
    return {
      block: true,
      reason: result.stderr.trim() || "denied by the watcher-policy PreToolUse seatbelt",
    };
  });

  pi.on("agent_settled", async () => {
    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    const result = await runProcess(
      `${root}/bin/ac-turnend-guard.sh`,
      '{"stop_hook_active":false}',
    );
    if (result.code !== 2) return;

    guardFollowupActive = true;
    try {
      await pi.sendUserMessage(
        "TURN WOULD END BLIND - supervision is off. " +
          "Drain queued wakes and re-arm the watcher (bin/ac-watch.sh, or a bounded --once checkpoint) before ending the turn.\n\n" +
          result.stderr,
        { deliverAs: "followUp" },
      );
    } catch {
      guardFollowupActive = false;
    }
  });
}
