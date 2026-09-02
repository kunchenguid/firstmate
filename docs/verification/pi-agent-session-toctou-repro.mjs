// Reproduction: AgentSession.prototype.prompt() has no atomic check-and-set
// between reading `isStreaming` and committing to a new agent run inside
// _runAgentPrompt(). Two concurrent prompt() calls that are both idle at the
// moment they check isStreaming can both fall through to _runAgentPrompt(),
// which unconditionally sets _isAgentRunActive = true and invokes
// this.agent.prompt(messages) again - a genuine concurrent double-invocation.
//
// This drives the REAL, unmodified AgentSession.prototype.prompt from the
// installed @earendil-works/pi-coding-agent package against a minimal stub
// `this`, so the method under test is production code, not a reimplementation.
import { pathToFileURL } from "node:url";

const SDK_PATH = process.env.SDK_PATH;
const { AgentSession } = await import(pathToFileURL(SDK_PATH).href);
const promptFn = AgentSession.prototype.prompt;

let concurrentRunAgentPromptCalls = 0;
let maxConcurrentRunAgentPromptCalls = 0;
const events = [];
// Extension-visible event order, exactly as .pi/extensions/fm-primary-turnend-guard.ts
// receives it. The losing prompt() call emits a settle of its own while the
// winner is still running, so a settle is NOT proof that the session is idle.
const extensionEvents = [];
let settlesWhileAnotherRunWasLive = 0;
// Everything the losing prompt() call manages to append. pi-agent-core's
// Agent.prototype.prompt throws before normalizePromptInput/runPromptMessages,
// so a losing captain message never becomes a transcript entry at all.
const transcript = [];
const capturedInputs = [];

function log(label) {
  events.push(`${(performance.now()).toFixed(2)}ms ${label}`);
}

// Faithful to agent-session.js lines 747-760 (_runAgentPrompt): sets
// _isAgentRunActive = true as its very first (synchronous) statement, then
// awaits the underlying agent run.
async function fakeRunAgentPrompt(messages) {
  this._isAgentRunActive = true;
  concurrentRunAgentPromptCalls++;
  maxConcurrentRunAgentPromptCalls = Math.max(maxConcurrentRunAgentPromptCalls, concurrentRunAgentPromptCalls);
  const isLoser = concurrentRunAgentPromptCalls > 1;
  log(`_runAgentPrompt ENTER (concurrent=${concurrentRunAgentPromptCalls}) messages=${JSON.stringify(messages).slice(0, 60)}`);
  try {
    if (isLoser) {
      // pi-agent-core Agent.prototype.prompt (dist/agent.js) rejects at once
      // when activeRun is set: "Agent is already processing a prompt." Nothing
      // is appended, which is why the caller's message simply disappears.
      throw new Error("Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion.");
    }
    // Only the winner ever reaches the append path (message_end persistence).
    for (const message of messages) transcript.push(message);
    // Simulate real inference/tool-call latency.
    await new Promise((r) => setTimeout(r, 40));
    transcript.push({ role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop" });
  } finally {
    concurrentRunAgentPromptCalls--;
    // agent-session.js _runAgentPrompt's finally block runs _emitAgentSettled()
    // unconditionally, which clears _isAgentRunActive and emits agent_settled
    // to every extension - even for a run that never produced anything.
    this._isAgentRunActive = false;
    log(`_runAgentPrompt EXIT -> _emitAgentSettled()`);
    if (concurrentRunAgentPromptCalls > 0) settlesWhileAnotherRunWasLive++;
    extensionEvents.push(`agent_settled(runsStillLive=${concurrentRunAgentPromptCalls})`);
  }
}

function makeStubSession() {
  return {
    _isAgentRunActive: false,
    get isStreaming() {
      return this._isAgentRunActive;
    },
    _compactionAbortController: undefined,
    _pendingNextTurnMessages: [],
    _systemPromptOverride: undefined,
    _baseSystemPrompt: "base",
    promptTemplates: [],
    model: { provider: "test" },
    _modelRuntime: {
      hasConfiguredAuth: () => true,
      checkAuth: async () => "ok",
      isUsingOAuth: () => false,
    },
    _extensionRunner: {
      // The turn-end guard registers an `input` handler, so this reports true
      // and prompt() really does emit the event - before its isStreaming
      // check, and therefore for the losing call too.
      hasHandlers: (event) => event === "input",
      emitInput: async (text, images, source) => {
        capturedInputs.push({ text, source });
        return { action: "pass" };
      },
      // A REAL before_agent_start handler in this repo
      // (.pi/extensions/fm-primary-turnend-guard.ts) awaits a spawned child
      // process here. This delay stands in for that genuine async gap - it is
      // not a contrived one - and is exactly the window a concurrently-fired
      // watcher wake (fm-primary-pi-watch.ts sendWake) races against.
      emitBeforeAgentStart: async () => {
        log("emitBeforeAgentStart (simulating a real extension awaiting a child process)");
        extensionEvents.push("before_agent_start");
        await new Promise((r) => setTimeout(r, 20));
        return undefined;
      },
    },
    _findLastAssistantMessage: () => undefined,
    _checkCompaction: async () => false,
    _flushPendingBashMessages: () => {},
    _expandSkillCommand: (t) => t,
    _throwIfExtensionCommand: () => {},
    _runAgentPrompt: fakeRunAgentPrompt,
    agent: { state: { systemPrompt: "base" } },
  };
}

const session = makeStubSession();

// The watcher wake is started first here so the CAPTAIN's call is the one that
// loses - the sub-case no tail inspection can detect, because the wake turn
// answers normally and leaves a perfectly healthy transcript behind.
log("watcher wake: prompt('FIRSTMATE WATCHER WAKE...') START");
const wakeCall = promptFn.call(session, "FIRSTMATE WATCHER WAKE: stale", { streamingBehavior: "followUp", source: "extension" });

// The wake above models fm-primary-pi-watch.ts's sendWake(): an unrelated
// background watcher-close callback calling pi.sendUserMessage(...,
// {deliverAs:"followUp"}) with zero coordination with the interactive call
// below. sendUserMessage forwards to prompt() with streamingBehavior:
// "followUp" and source: "extension" (agent-session.js sendUserMessage()).
const CAPTAIN_TEXT = "bitte den Stand zusammenfassen";
log(`captain call: prompt('${CAPTAIN_TEXT}') START`);
const captainCall = promptFn.call(session, CAPTAIN_TEXT, { source: "interactive" });

// allSettled, not all: the losing call rejects by design, exactly as the real
// nested agent.prompt() does when it finds an active run.
await Promise.allSettled([captainCall, wakeCall]);

console.log(events.join("\n"));
console.log(`\nmaxConcurrentRunAgentPromptCalls = ${maxConcurrentRunAgentPromptCalls}`);
console.log(`extension event order: ${extensionEvents.join(" -> ")}`);
console.log(`settlesWhileAnotherRunWasLive = ${settlesWhileAnotherRunWasLive}`);

const capturedCaptainInput = capturedInputs.some((i) => i.source === "interactive" && i.text === CAPTAIN_TEXT);
const captainTextInTranscript = transcript.some(
  (m) => m.role === "user" && JSON.stringify(m.content ?? "").includes(CAPTAIN_TEXT),
);
const transcriptTail = transcript[transcript.length - 1];
const tailLooksHealthy = transcriptTail?.role === "assistant" && transcriptTail?.stopReason === "stop";
console.log(`\ncaptain input seen by the "input" event: ${capturedCaptainInput}`);
console.log(`captain text present in the transcript: ${captainTextInTranscript}`);
console.log(`transcript tail looks healthy: ${tailLooksHealthy}`);
if (maxConcurrentRunAgentPromptCalls > 1) {
  console.log("REPRODUCED: two concurrent prompt() calls both reached _runAgentPrompt() concurrently.");
  if (settlesWhileAnotherRunWasLive > 0) {
    // This is what the extension has to survive: it sees two
    // before_agent_start events and then a settle that is NOT terminal. It
    // counts logical runs in flight and leaves such a settle unevaluated, so
    // only the trailing settle - the one that drains the counter - is judged.
    // tests/fm-turnend-guard.test.sh's test_pi_reply_recovery_skips_a_spurious_mid_turn_settle
    // and test_pi_reply_recovery_spurious_settle_never_doubles_a_healthy_answer
    // replay exactly this event order against the real handler.
    console.log("REPRODUCED: a spurious agent_settled fired while another logical run was still live.");
  }
  if (capturedCaptainInput && !captainTextInTranscript && tailLooksHealthy) {
    // The BEFORE state for captain-input-loss recovery: the captain's message
    // is gone from the transcript while the tail is a healthy assistant reply,
    // so no tail inspection can detect it - but prompt()'s `input` event did
    // see the message before the isStreaming check, which is what
    // .pi/extensions/fm-primary-turnend-guard.ts records and resubmits.
    // tests/fm-turnend-guard.test.sh's
    // test_pi_input_recovery_resubmits_a_captain_message_lost_to_the_race
    // drives the real handler through exactly this state (AFTER: exactly one
    // resubmission carrying the lost text), and
    // test_pi_input_recovery_stays_silent_for_a_delivered_captain_message is
    // the negative control.
    console.log("REPRODUCED: the captain's message was lost entirely while the transcript tail stayed healthy.");
  }
  process.exit(1);
} else {
  console.log("NOT REPRODUCED this run (race is timing-dependent).");
  process.exit(0);
}
