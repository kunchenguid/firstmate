// Stands in for any other extension that publishes a footer status, such as the
// captain's voice extension. Its key sorts after the mirror's, so Pi renders it
// immediately after Telegram on the shared status line.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setStatus("pi-voice", "voice: alt+m \u2022 parakeet-v3-q8");
  });
}
