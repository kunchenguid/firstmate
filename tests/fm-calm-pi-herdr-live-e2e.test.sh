#!/usr/bin/env bash
# Opt-in real Pi/Herdr regression for Calm's live intermediate-step presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CALM_PI_HERDR_LIVE_E2E herdr jq pi python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name calm-commentary-layout)
TMP_ROOT=$(fm_test_tmproot fm-calm-pi-herdr-live-e2e)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
PI_CONFIG="$TMP_ROOT/pi-config"
SESSIONS="$TMP_ROOT/sessions"
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

mkdir -p "$PROJECT/.pi/extensions/lib" "$HOME_DIR/config" "$PI_CONFIG" "$SESSIONS"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.current.ts"
cat >"$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts" <<'TS'
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];
type LegacyController = {
  render: (
    component: PiAssistantMessageComponent,
    message: AssistantMessage,
    isStreaming: boolean,
  ) => void;
  originalUpdateContent: PiAssistantMessageComponent["updateContent"];
  presentations: WeakMap<object, unknown>;
  ownedThinkingMessages: WeakSet<object>;
};
const LEGACY_CONTROLLER = Symbol.for(
  "firstmate:calm-assistant-layout-controller:pi-0.81.1",
);

// Reproduce the controller shape retained by the immediately preceding Calm source.
// The current module must upgrade this exact wrapper in place after Pi's real /reload.
export function installCalmToolLayout(): void {}

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: LegacyController | undefined;
  };
  if (registry[LEGACY_CONTROLLER]) return;
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  const controller: LegacyController = {
    render: (component, message, isStreaming) => {
      originalUpdateContent.call(component, message, isStreaming);
    },
    originalUpdateContent,
    presentations: new WeakMap(),
    ownedThinkingMessages: new WeakSet(),
  };
  registry[LEGACY_CONTROLLER] = controller;
  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
    isStreaming = false,
  ): void {
    controller.render(this, message, isStreaming);
  };
}
TS
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
printf 'on\n' >"$HOME_DIR/config/calm"
printf '%s\n' '{"terminal":{"clearOnShrink":false}}' >"$PI_CONFIG/settings.json"
printf '%s\n' '{"type":"module"}' >"$PROJECT/package.json"
printf '%s\n' 'calm live fixture' >"$PROJECT/calm-live-probe.txt"

cat >"$PROJECT/calm-live-provider.ts" <<'TS'
import { appendFileSync } from "node:fs";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  appendFileSync("calm-live-loads", "loaded\n");
  pi.registerProvider("calm-live", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "calm-live-api",
    models: [{
      id: "deterministic",
      name: "Calm live intermediate-step fixture",
      reasoning: true,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    streamSimple(model, context, options) {
      const stream = createAssistantMessageEventStream();
      const completedSteps = context.messages.filter((message) => message.role === "toolResult").length;
      const isFinal = completedSteps >= 3;
      const plan = ["LIVE_PLAN_ONE", "LIVE_PLAN_TWO", "LIVE_PLAN_THREE"][completedSteps];
      const output: AssistantMessage = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "pending",
        timestamp: Date.now(),
      };
      void (async () => {
        stream.push({ type: "start", partial: output });
        const thinking = { type: "thinking" as const, thinking: "" };
        output.content.push(thinking);
        stream.push({ type: "thinking_start", contentIndex: 0, partial: output });
        if (isFinal) {
          const text = { type: "text" as const, text: "CALM_LIVE_HERDR_FINAL" };
          output.content.push(text);
          stream.push({ type: "text_start", contentIndex: 1, partial: output });
          stream.push({ type: "text_delta", contentIndex: 1, delta: text.text, partial: output });
          stream.push({ type: "text_end", contentIndex: 1, content: text.text, partial: output });
          output.stopReason = "stop";
          stream.push({ type: "done", reason: "stop", message: output });
          stream.end();
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 250));
        if (options?.signal?.aborted) return;
        thinking.thinking = plan;
        stream.push({ type: "thinking_delta", contentIndex: 0, delta: plan, partial: output });
        await new Promise((resolve) => setTimeout(resolve, 1200));
        if (options?.signal?.aborted) return;
        stream.push({ type: "thinking_end", contentIndex: 0, content: plan, partial: output });
        const text = { type: "text" as const, text: `COMMENTARY_${completedSteps + 1}` };
        output.content.push(text);
        stream.push({ type: "text_start", contentIndex: 1, partial: output });
        stream.push({ type: "text_delta", contentIndex: 1, delta: text.text, partial: output });
        await new Promise((resolve) => setTimeout(resolve, 1200));
        if (options?.signal?.aborted) return;
        stream.push({ type: "text_end", contentIndex: 1, content: text.text, partial: output });
        const toolCall = {
          type: "toolCall" as const,
          id: `calm-live-read-${completedSteps + 1}`,
          name: "read",
          arguments: { path: "calm-live-probe.txt" },
        };
        output.content.push(toolCall);
        stream.push({ type: "toolcall_start", contentIndex: 2, partial: output });
        stream.push({ type: "toolcall_delta", contentIndex: 2, delta: JSON.stringify(toolCall.arguments), partial: output });
        stream.push({ type: "toolcall_end", contentIndex: 2, toolCall, partial: output });
        output.stopReason = "toolUse";
        stream.push({ type: "done", reason: "toolUse", message: output });
        stream.end();
      })();
      return stream;
    },
  });

  pi.registerCommand("calm-live-probe", {
    description: "Run the deterministic Calm intermediate-step fixture.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-live", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("Calm live model unavailable");
      await pi.sendUserMessage("CALM_LIVE_HERDR_PROMPT");
    },
  });
}
TS

OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$PROJECT" --label calm-live --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
PI_CMD=$(printf 'cd %q && env FM_HOME=%q PI_CODING_AGENT_DIR=%q PI_OFFLINE=1 pi --approve --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e calm-live-provider.ts --model calm-live/deterministic --session-dir %q' \
  "$PROJECT" "$HOME_DIR" "$PI_CONFIG" "$SESSIONS")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$PI_CMD" >/dev/null \
  || fail "could not launch the real Pi fixture in Herdr"

pane_text() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 120 --format ansi 2>/dev/null || true
}
wait_for_text() {
  local expected=$1 i=0 text
  while [ "$i" -lt 120 ]; do
    text=$(pane_text)
    printf '%s' "$text" | grep -Fq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$text" >&2
  return 1
}
wait_for_text "(calm-live)" || fail "real Pi did not reach its ready composer"
cp "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.current.ts" \
  "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/reload' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null
reloaded=0
for i in $(seq 1 120); do
  [ "$(wc -l <"$PROJECT/calm-live-loads" 2>/dev/null | tr -d ' ')" -ge 2 ] && { reloaded=1; break; }
  sleep 0.1
done
[ "$reloaded" -eq 1 ] || fail "real Pi did not reload the current Calm adapter over the legacy live wrapper"
wait_for_text "Reloaded keybindings, extensions, skills, prompts, themes, and context files" \
  || fail "real Pi did not finish the reload before the live probe"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/calm-live-probe' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null

seen_plan_one=0
seen_plan_two=0
seen_plan_three=0
plan_step_one=
plan_step_two=
plan_step_three=
seen_one=0
seen_two=0
seen_three=0
final_text=
MAGENTA_BACKGROUND=$'\033[48;2;122;31;92m'
assert_current_layout() { # <frame> <exact step text>
  local frame=$1 step=$2 step_line anchor_line
  step_line=$(printf '%s\n' "$frame" | grep -Fn "$step" | tail -1 | cut -d: -f1)
  anchor_line=$(printf '%s\n' "$frame" | grep -Fn '╲▁▁▁╱' | tail -1 | cut -d: -f1)
  [ -n "$anchor_line" ] || anchor_line=$(printf '%s\n' "$frame" | grep -Fn 'CALM_LIVE_HERDR_FINAL' | tail -1 | cut -d: -f1)
  [ -n "$step_line" ] && [ -n "$anchor_line" ] && [ "$step_line" -lt "$anchor_line" ] \
    || fail "$step was not kept in the main transcript before the final response"
}
assert_commentary_layout() { # <frame> <commentary number>
  local frame=$1 number=$2 count commentary_line final_line
  count=$(printf '%s\n' "$frame" | grep -Fc "COMMENTARY_$number")
  [ "$count" -eq 1 ] || fail "COMMENTARY_$number appeared $count times"
  final_line=$(printf '%s\n' "$frame" | grep -Fn 'CALM_LIVE_HERDR_FINAL' | tail -1 | cut -d: -f1)
  [ -n "$final_line" ] || return 0
  commentary_line=$(printf '%s\n' "$frame" | grep -Fn "COMMENTARY_$number" | tail -1 | cut -d: -f1)
  [ -n "$commentary_line" ] && [ "$commentary_line" -lt "$final_line" ] \
    || fail "COMMENTARY_$number was not kept in the main transcript before the final response"
}
for i in $(seq 1 200); do
  final_text=$(pane_text)
  step_count=$( (printf '%s\n' "$final_text" | grep -Eo 'Step [0-9]+:' || true) | sort -u | wc -l | tr -d ' ')
  [ "$step_count" -le 3 ] || fail "live frame $i rendered more than the three accumulated numbered steps"
  printf '%s\n' "$final_text" | grep -Fq 'Thinking...' \
    && fail "live frame $i rendered Pi's thinking placeholder"
  printf '%s\n' "$final_text" | grep -Fq 'calm live fixture' \
    && fail "live frame $i rendered the read tool result"
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: LIVE_PLAN_ONE'; then
    seen_plan_one=1
    plan_step_one=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: LIVE_PLAN_ONE' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    assert_current_layout "$final_text" "Step $plan_step_one: LIVE_PLAN_ONE"
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: LIVE_PLAN_TWO'; then
    seen_plan_two=1
    plan_step_two=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: LIVE_PLAN_TWO' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    assert_current_layout "$final_text" "Step $plan_step_two: LIVE_PLAN_TWO"
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: LIVE_PLAN_THREE'; then
    seen_plan_three=1
    plan_step_three=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: LIVE_PLAN_THREE' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    assert_current_layout "$final_text" "Step $plan_step_three: LIVE_PLAN_THREE"
  fi
  if printf '%s' "$final_text" | grep -Fq 'COMMENTARY_1'; then
    seen_one=1
    assert_commentary_layout "$final_text" 1
  fi
  if printf '%s' "$final_text" | grep -Fq 'COMMENTARY_2'; then
    seen_two=1
    assert_commentary_layout "$final_text" 2
  fi
  if printf '%s' "$final_text" | grep -Fq 'COMMENTARY_3'; then
    seen_three=1
    assert_commentary_layout "$final_text" 3
  fi
  printf '%s' "$final_text" | grep -Fq 'CALM_LIVE_HERDR_FINAL' && break
  sleep 0.1
done
[ "$seen_plan_one" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the first planning step"; }
[ "$seen_plan_two" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the second planning step"; }
[ "$seen_plan_three" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the third planning step"; }
[ "$seen_one" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the first durable commentary row"; }
[ "$seen_two" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the second durable commentary row"; }
[ "$seen_three" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the third durable commentary row"; }
[ "$plan_step_one" -lt "$plan_step_two" ] && [ "$plan_step_two" -lt "$plan_step_three" ] \
  || fail "Calm step numbers did not increase monotonically: $plan_step_one, $plan_step_two, $plan_step_three"
printf '%s' "$final_text" | grep -Fq 'CALM_LIVE_HERDR_FINAL' \
  || fail "real Pi/Herdr fixture did not settle its final response"
printf '%s' "$final_text" | grep -Fq "$MAGENTA_BACKGROUND" \
  || fail "real Pi/Herdr final assistant row did not carry Calm's magenta background ANSI"
for number in 1 2 3; do
  printf '%s' "$final_text" | grep -Fq "Step $number: LIVE_PLAN_" \
    || fail "final Pi response did not retain Step $number in the completed assistant row"
done
printf '%s' "$final_text" | grep -Fq 'calm live fixture' \
  && fail "final Pi response retained the read tool result"
for number in 1 2 3; do
  [ "$(printf '%s\n' "$final_text" | grep -Fc "COMMENTARY_$number")" -eq 1 ] \
    || fail "final Pi transcript did not retain COMMENTARY_$number exactly once"
done

session_file=$(find "$SESSIONS" -type f -name '*.jsonl' -exec grep -l 'CALM_LIVE_HERDR_FINAL' {} + 2>/dev/null | head -1)
[ -n "$session_file" ] || fail "real Pi did not persist its session transcript"
grep -Fq 'LIVE_PLAN_ONE' "$session_file" || fail "live planning context was not persisted"
grep -Fq 'LIVE_PLAN_TWO' "$session_file" || fail "second planning context was not persisted"
grep -Fq 'LIVE_PLAN_THREE' "$session_file" || fail "third planning context was not persisted"
grep -Fq 'COMMENTARY_1' "$session_file" || fail "first commentary context was not persisted"
grep -Fq 'COMMENTARY_2' "$session_file" || fail "second commentary context was not persisted"
grep -Fq 'COMMENTARY_3' "$session_file" || fail "third commentary context was not persisted"
printf 'ok - real Pi %s in Herdr upgraded the retained prior Calm controller through /reload, kept each commentary row once beside its accumulated numbered transcript steps, hid thinking placeholders and read rows, ordered the steps and commentary above the ship, and settled with the completed steps attached to the final answer\n' "$(pi --version)"
