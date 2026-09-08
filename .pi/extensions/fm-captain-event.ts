// Optional semantic captain-message producer for a Pi Firstmate primary.
// Storage, activation, privacy, and compatibility are owned by
// bin/fm-captain-event.sh and docs/captain-event-outbox.md.
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installCaptainEventPublisher } from "./lib/fm-captain-event.ts";

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const config = process.env.FM_CONFIG_OVERRIDE || join(fmHome, "config");

export default function captainEventExtension(pi: ExtensionAPI): void {
  if (process.env.FM_TASK_ID) return;
  installCaptainEventPublisher(pi, {
    fmHome,
    fmRoot,
    state,
    config,
    sourceRole: "primary",
  });
}
