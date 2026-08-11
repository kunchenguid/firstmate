import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  captainInboxIsEnabled,
  listCaptainInbox,
  markCaptainInboxMessage,
  resolveCaptainInboxPaths,
} from "../.pi/extensions/lib/fm-captain-inbox-store.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDirectory, "..");
const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${home}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${home}/config`;
const paths = resolveCaptainInboxPaths({ home, state, config });

function usage() {
  process.stdout.write(
    "Usage: fm-captain-inbox.sh list\n" +
      "       fm-captain-inbox.sh mark <ci_v1_message_id> read|unread\n",
  );
}

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exitCode = 1;
}

async function main(args) {
  if (args.length === 1 && (args[0] === "-h" || args[0] === "--help")) {
    usage();
    return;
  }
  if (!captainInboxIsEnabled(paths)) {
    throw new Error("Captain's Inbox is disabled; set config/captain-inbox to on");
  }
  if (args.length === 1 && args[0] === "list") {
    process.stdout.write(`${JSON.stringify(await listCaptainInbox(paths))}\n`);
    return;
  }
  if (args.length === 3 && args[0] === "mark" && (args[2] === "read" || args[2] === "unread")) {
    process.stdout.write(`${JSON.stringify(await markCaptainInboxMessage(paths, args[1], args[2] === "read"))}\n`);
    return;
  }
  usage();
  throw new Error("invalid Captain's Inbox command");
}

main(process.argv.slice(2)).catch((error) => {
  fail(error instanceof Error ? error.message : "Captain's Inbox request failed");
});
