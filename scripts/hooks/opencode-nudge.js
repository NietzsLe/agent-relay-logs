// Relay nudge — surfaces `relay tick` to the model and records long tool runs.
//
// Managed by the agent-relay-logs installer (`install.sh --hooks` /
// `relay_setup.py install --hooks`). Do not hand-edit: the installer owns
// this file when copied to `.opencode/plugins/`.
//
// What it does (all best-effort, never throws):
// - shell hook: pins RELAY_KEY to the last seen session id, so every relay
//   command in any shell resolves to the same relay session without --session.
// - tool hooks: times `bash` calls; a call longer than
//   RELAY_MIN_DECLARE (default 120s) is recorded with `relay run --record`.
//   The late/over math (tolerance both ways) lives in relay itself.
// - session context hook: fires before model requests. The FIRST call
//   in a session injects a one-line `board` + `start` reminder (this is the
//   only net that catches short sessions — tick-based nudges never fire for
//   a 72-second task that never starts). Afterwards, at most once a minute,
//   runs `relay tick --hook`; only when tick prints a line (silence overdue,
//   scope drift, or unread news) is it appended to the system prompt.

import { Plugin } from "@opencode/plugin";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

export default Plugin.define({
  id: "relay-nudge",
  async setup(ctx) {
    const directory = ctx.location.directory;
    const relay = `${directory}/.relay/relay`;
    const starts = new Map(); // "<sessionID>:<callID>" -> epoch ms
    const minDeclareMs = (parseInt(process.env.RELAY_MIN_DECLARE || "120", 10) || 120) * 1000;
    let lastNudge = 0;
    let greeted = false; // one session-start reminder per plugin instance
    let lastSessionID = "";

    function tick() {
      try {
        if (!existsSync(relay)) return "";
        const out = execFileSync(relay, ["tick", "--hook"], {
          cwd: directory,
          timeout: 5000,
          stdio: ["ignore", "pipe", "ignore"],
          encoding: "utf-8",
        });
        return (out || "").split("\n").slice(0, 5).join("\n").trim();
      } catch {
        return "";
      }
    }

    function record(actualS) {
      try {
        if (!existsSync(relay)) return;
        execFileSync(
          relay,
          ["run", "--record", "--cmd", "bash tool call", "--actual", `${actualS}s`, "--exit", "0"],
          { cwd: directory, timeout: 5000, stdio: ["ignore", "ignore", "ignore"] }
        );
      } catch {
        /* logging must never block the main work */
      }
    }

    await ctx.shell.hook("create.before", (event) => {
      try {
        if (lastSessionID && event.env) event.env.RELAY_KEY = String(lastSessionID);
      } catch {
        /* ignore */
      }
    });

    await ctx.tool.hook("execute.before", (event) => {
      try {
        if (event && event.sessionID) lastSessionID = String(event.sessionID);
        if (event && event.tool === "bash" && event.id) {
          starts.set(`${event.sessionID}:${String(event.id)}`, Date.now());
        }
      } catch {
        /* ignore */
      }
    });

    await ctx.tool.hook("execute.after", (event) => {
      try {
        if (!event || event.tool !== "bash" || !event.id) return;
        const k = `${event.sessionID}:${String(event.id)}`;
        const t0 = starts.get(k);
        starts.delete(k);
        if (!t0) return;
        const actualS = Math.round((Date.now() - t0) / 1000);
        if (actualS * 1000 < minDeclareMs) return;
        record(actualS);
      } catch {
        /* ignore */
      }
    });

    await ctx.session.hook("context", (event) => {
      try {
        if (event && event.sessionID) lastSessionID = String(event.sessionID);
        if (!greeted) {
          greeted = true;
          event.system.push({
            type: "text",
            text:
              "[relay] Đầu phiên: chạy `.relay/relay board` để xem việc dở của phiên khác. " +
              "Mọi việc thật — kể cả task thử ngắn hay output ra /tmp — đều phải " +
              "`.relay/relay --agent <tên> start ...` trước khi làm. Không bao giờ nói \"không cần ghi\".",
          });
        }
        const now = Date.now();
        if (now - lastNudge < 60000) return;
        lastNudge = now;
        const line = tick();
        if (line) {
          event.system.push({
            type: "text",
            text: `[relay] ${line}\nGhi 1 dòng log (relay note ... / relay scope ...) rồi làm tiếp. Không bao giờ nói "không cần ghi".`,
          });
        }
      } catch {
        /* ignore */
      }
    });
  },
});
