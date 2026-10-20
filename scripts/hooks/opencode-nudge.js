// Relay nudge — surfaces `relay tick` to the model and records long tool runs.
//
// Managed by the agent-relay-logs installer (`install.sh --hooks` /
// `relay_setup.py install --hooks`). Do not hand-edit: the installer owns
// everything between the BEGIN/END marker comments when merged.
//
// What it does (all best-effort, never throws):
// - shell.env: pins RELAY_KEY to the harness session id, so every relay
//   command in any shell resolves to the same relay session without --session.
// - tool.execute.before/after: times `bash` calls; a call longer than
//   RELAY_MIN_DECLARE (default 120s) is recorded with `relay run --record`.
//   The late/over math (tolerance both ways) lives in relay itself.
// - experimental.chat.system.transform: at most once a minute, runs
//   `relay tick --hook`; only when tick prints a line (silence overdue,
//   scope drift, or unread news) is it appended to the system prompt.

export const RelayNudgePlugin = async ({ $, directory }) => {
  const relay = `${directory}/.relay/relay`;
  const starts = new Map(); // "<sessionID>:<callID>" -> epoch ms
  const minDeclareMs = (parseInt(process.env.RELAY_MIN_DECLARE || "120", 10) || 120) * 1000;
  let lastNudge = 0;

  async function tick() {
    try {
      const out = await $`sh -c ${`cd ${JSON.stringify(directory)} && ${JSON.stringify(relay)} tick --hook 2>/dev/null | head -5`}`.text();
      return (out || "").trim();
    } catch {
      return "";
    }
  }

  async function record(actualS) {
    try {
      await $`sh -c ${`cd ${JSON.stringify(directory)} && ${JSON.stringify(relay)} run --record --cmd "bash tool call" --actual ${`${actualS}s`} --exit 0 2>/dev/null`}`.quiet();
    } catch {
      /* logging must never block the main work */
    }
  }

  return {
    "shell.env": async (input, output) => {
      try {
        if (input && input.sessionID) output.env.RELAY_KEY = String(input.sessionID);
      } catch {
        /* ignore */
      }
    },

    "tool.execute.before": async (input) => {
      try {
        if (input && input.tool === "bash" && input.callID) {
          starts.set(`${input.sessionID}:${input.callID}`, Date.now());
        }
      } catch {
        /* ignore */
      }
    },

    "tool.execute.after": async (input) => {
      try {
        if (!input || input.tool !== "bash" || !input.callID) return;
        const k = `${input.sessionID}:${input.callID}`;
        const t0 = starts.get(k);
        starts.delete(k);
        if (!t0) return;
        const actualS = Math.round((Date.now() - t0) / 1000);
        if (actualS * 1000 < minDeclareMs) return;
        await record(actualS);
      } catch {
        /* ignore */
      }
    },

    "experimental.chat.system.transform": async (_input, output) => {
      try {
        const now = Date.now();
        if (now - lastNudge < 60000) return;
        lastNudge = now;
        const line = await tick();
        if (line) {
          output.system.push(
            `[relay] ${line}\nGhi 1 dòng log (relay note ... / relay scope ...) rồi làm tiếp. Không bao giờ nói "không cần ghi".`
          );
        }
      } catch {
        /* ignore */
      }
    },
  };
};
