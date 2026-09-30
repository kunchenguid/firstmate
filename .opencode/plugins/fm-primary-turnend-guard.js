// Turn-end guard for OpenCode: when a turn ends, let the watcher coordinator
// act first, and only when supervision is genuinely missing, run
// bin/fm-turnend-guard.sh and deliver its finding so the turn cannot end blind
// (see docs/turnend-guard.md).
//
// OpenCode 2 changed this plugin's contract, so the shape below is re-derived
// rather than transliterated. The v1 `event` hook is now an async subscription
// on the context, aborted from the cleanup function `setup` returns. Event
// payloads moved from `event.properties` to `event.data`. OpenCode 2 also no
// longer delivers v1's `session.idle` to a plugin subscription, so the turn-end
// trigger is the last step of a turn instead - see turnEndedSessionID in
// lib/fm-opencode-contract.js. Delivering the finding moved from
// `client.session.promptAsync({ path, body: { parts } })` to
// `ctx.session.prompt({ sessionID, text })`. The subscription is the whole
// server's stream, so the handler runs only for this instance's own location.

import { resolvePluginRoot, runProcess, subscribeOwnEvents, turnEndedSessionID } from "./lib/fm-opencode-contract.js";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;

// The guard reads its whole turn-end payload from stdin and exits 0 when stdin
// is empty, so the payload the v1 adapter sent is still sent here; dropping it
// would leave the guard permanently silent rather than loudly broken.
const GUARD_PAYLOAD = '{"stop_hook_active":false}';

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], { input: GUARD_PAYLOAD });
}

async function letWatchArmRun(sessionID, ctx) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, ctx);
  return status === "armed" || status === "wake" || status === "failed";
}

export default {
  id: "firstmate.primary.turnend-guard",
  async setup(ctx) {
    const root = await resolvePluginRoot(ctx);

    return subscribeOwnEvents(ctx, async (event) => {
      const sessionID = turnEndedSessionID(event);
      if (!sessionID) return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      if (await letWatchArmRun(sessionID, ctx)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await ctx.session.prompt({ sessionID, text });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    });
  },
};
