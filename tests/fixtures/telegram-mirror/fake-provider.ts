// Registers the guard's local zero-cost model so the real Pi TUI can stream
// without a credential or vendor quota.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fakelab", {
    name: "Firstmate Telegram guard",
    baseUrl: `http://127.0.0.1:${process.env.FAKE_MODEL_PORT}/v1`,
    apiKey: "fake-key",
    api: "openai-completions",
    models: [{
      id: "slow-fake",
      name: "Slow Fake",
      reasoning: false,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 4096,
    }],
  });
}
