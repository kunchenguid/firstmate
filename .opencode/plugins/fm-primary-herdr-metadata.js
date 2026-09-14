// Firstmate herdr panel metadata for the OpenCode primary session.
//
// Reports the model name to herdr's display-only metadata on every
// session.updated event so the herdr panel row for this opencode agent
// shows real, observed values instead of an empty token set.
//
// Only values directly observed from OpenCode's own event stream are
// reported.  Context percentage is NOT reported because OpenCode does not
// expose a context window size - computing one from an assumed window would
// be dishonest.  Quota is NOT reported because the OpenCode Go plan has no
// public usage API (upstream issues #31084, #16017, #18648).
//
// The metadata is display-only and carries a TTL so it expires rather than
// persisting as a stale claim after a worker dies.
import { execFile } from "node:child_process";
import { resolve } from "node:path";

const PANE_ID = process.env.HERDR_PANE_ID || "";
const FM_ROOT = process.env.FM_ROOT_OVERRIDE || resolve(import.meta.dirname, "../..");
const SCRIPT = resolve(FM_ROOT, "bin/fm-herdr-opencode-metadata.sh");

const reportMetadata = (modelID) => {
  if (!PANE_ID || !modelID) return;
  execFile(SCRIPT, [PANE_ID, modelID], () => {});
};

export const FmPrimaryHerdrMetadata = async () => {
  let lastModel = "";
  return {
    event: async ({ event }) => {
      if (event.type === "session.updated") {
        const model = event.properties?.info?.model;
        if (model && model.id && model.id !== lastModel) {
          lastModel = model.id;
          reportMetadata(model.id);
        }
      }
      if (event.type === "message.updated") {
        const modelID = event.properties?.info?.modelID;
        if (modelID && modelID !== lastModel) {
          lastModel = modelID;
          reportMetadata(modelID);
        }
      }
    },
  };
};
