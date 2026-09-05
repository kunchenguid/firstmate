// Pending notification visibility is independent of Calm's transcript preference.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installPendingNotificationLayout } from "./lib/fm-pending-notification-layout.ts";

export default function (pi: ExtensionAPI): void {
  try {
    const layout = installPendingNotificationLayout();
    pi.on("session_start", () => layout.refresh());
    pi.on("session_shutdown", () => layout.dispose());
  } catch (error) {
    console.error(`Firstmate: pending-notification presentation adapter unavailable, skipping. ${String(error)}`);
  }
}
