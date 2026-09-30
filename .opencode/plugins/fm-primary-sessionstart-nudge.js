// Session-start nudge for OpenCode: when a session appears in this instance's
// own location, run bin/fm-sessionstart-nudge.sh and, when the wrapper prints a
// nudge, deliver it to that session (see docs/sessionstart-nudge.md).
//
// OpenCode 2 changed both halves of this plugin's contract, so the shape below
// is re-derived rather than transliterated. The v1 `event` hook returned from
// the plugin factory is now an async subscription taken on the context and
// aborted from the cleanup function `setup` returns. Event payloads moved from
// `event.properties` to `event.data`, so the created session's id is
// `event.data.sessionID` rather than `event.properties.info.id`. Delivering the
// nudge moved from `client.session.promptAsync({ path, body: { parts } })` to
// `ctx.session.prompt({ sessionID, text })`. The subscription is also the whole
// server's stream, so the handler runs only for this instance's own location -
// see lib/fm-opencode-contract.js.

import { resolvePluginRoot, runProcess, subscribeOwnEvents } from "./lib/fm-opencode-contract.js";

const handledSessions = new Set();

function runNudge(root) {
  return runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
}

export default {
  id: "firstmate.primary.sessionstart-nudge",
  async setup(ctx) {
    const root = await resolvePluginRoot(ctx);
    if (!root) return;

    return subscribeOwnEvents(ctx, async (event) => {
      if (event.type !== "session.created") return;
      const sessionID = event.data?.sessionID;
      if (!sessionID || handledSessions.has(sessionID)) return;
      handledSessions.add(sessionID);

      const result = await runNudge(root);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      try {
        await ctx.session.prompt({ sessionID, text: nudge });
      } catch {
        // A nudge that cannot be delivered is not worth failing the session over.
      }
    });
  },
};
