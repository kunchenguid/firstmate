// The early-access Claude API is restricted to individually verified releases.
// No terminal bytes and no rendered-screen decisions enter this transaction.
let active = false;
let conflict = false;
let ready;
let channel;
let timer;

async function bridge($, action, extra = {}) {
    const result = await $.process.run([
      "python3", `${$.plugin.root}/bridge.py`, action, channel,
    ], {stdin: JSON.stringify({...ready, ...extra}), timeoutMs: 2000});
    if (result.exitCode !== 0) throw new Error(result.stderr);
    return result.stdout ? JSON.parse(result.stdout) : null;
}

export const register = (on) => {
  on("session.start", async ($, event, next) => {
    timer?.cancel();
    channel = await $.env.get("FM_CLAUDE_NATIVE_CHANNEL");
    if (await $.env.get("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS") !== "1" || !channel)
      return next(event);
    const version = (await $.session.version()).base;
    if (!["2.1.288", "2.1.292"].includes(version)) return next(event);
    ready = {pid: Number(await $.env.get("FM_CLAUDE_NATIVE_PID")),
      session: await $.session.id(), version};
    ready = await bridge($, "ready");
    timer = $.clock.every(250, async () => {
      if (active) return;
      active = true;
      conflict = false;
      let request;
      let mutated = false;
      const check = async () => {
        const status = await bridge($, "check", {nonce: request.nonce});
        if (!status.authorized || conflict) throw new Error("expired request or concurrent input");
      };
      const receipt = (phase, reason = "") => bridge($, "receipt", {
        nonce: request.nonce, phase, reason, mutated,
      });
      try {
        request = await bridge($, "poll");
        if (!request) return;
        await check();
        // read() alone returns default-empty under dialogs and headless mode.
        const mounted = await $.prompt.fill({text: "", mode: "append"});
        if (!mounted.isFilled) throw new Error(`composer unavailable: ${mounted.refusal ?? "unknown"}`);
        await check();
        const sentinel = `FM_DISCARD_${request.nonce}`;
        await receipt("clearing");
        await check();
        mutated = true;
        const filled = await $.prompt.fill({text: sentinel, mode: "replace"});
        const proof = await $.prompt.read();
        if (!filled.isFilled || proof.text !== sentinel) throw new Error("sentinel readback failed");
        await check();
        const cleared = await $.prompt.fill({text: "", mode: "replace"});
        const empty = await $.prompt.read();
        if (!cleared.isFilled || empty.text !== "" || empty.cursor !== 0)
          throw new Error("empty readback failed");
        await check();
        await receipt("exit-ready");
        // Last native read and synchronous conflict check before enqueue.
        const final = await $.prompt.read();
        await check();
        if (conflict || final.text !== "" || final.cursor !== 0 || Date.now() / 1000 >= request.expires)
          throw new Error("input changed before native exit");
        // Enqueue is asynchronous. A new edit after this call may still be lost
        // on exit; the measured ~114 ms held handoff is documented in CLI help.
        const exit = $.command.run({command: "exit"}).then(
          () => ({ok: true}), error => ({error}));
        await receipt("exit-sent");
        const outcome = await exit;
        if (outcome.error) throw outcome.error;
      } catch (error) {
        if (request) {
          try { await receipt("refused", String(error)); } catch { /* caller also fails closed */ }
        }
      } finally {
        active = false;
      }
    });
    return next(event);
  });
  // Pass edits through unchanged. Never swallow user input to fake exclusivity.
  on("prompt.edit", ($, input, next) => {
    if (active) conflict = true;
    return next(input);
  });
  on("prompt.fill", ($, input, next) => {
    if (active) conflict = true;
    return next(input);
  });
  on("prompt.submit", ($, input, next) => {
    if (active) conflict = true;
    return next(input);
  });
};
