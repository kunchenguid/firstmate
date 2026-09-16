#!/usr/bin/env bash
# Opt-in real Pi/Herdr regression for Calm's live intermediate-step presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CALM_PI_HERDR_LIVE_E2E herdr jq pi python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name calm-live-rotation-counter)
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
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
printf 'on\n' >"$HOME_DIR/config/calm"
printf '%s\n' '{"terminal":{"clearOnShrink":false}}' >"$PI_CONFIG/settings.json"
printf '%s\n' '{"type":"module"}' >"$PROJECT/package.json"
printf '%s\n' 'calm live fixture' >"$PROJECT/calm-live-probe.txt"

cat >"$PROJECT/calm-live-provider.ts" <<'TS'
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
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
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 120 2>/dev/null || true
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
step_one=
step_two=
step_three=
final_text=
for i in $(seq 1 160); do
  final_text=$(pane_text)
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: LIVE_PLAN_ONE'; then
    seen_plan_one=1
    plan_step_one=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: LIVE_PLAN_ONE' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    step_count=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+:' | wc -l | tr -d ' ')
    [ "$step_count" -eq 1 ] || fail "first planning frame rendered $step_count numbered rows"
    if printf '%s' "$final_text" | grep -Eq 'LIVE_PLAN_[23]|COMMENTARY_'; then
      printf '%s\n' "$final_text" >&2
      fail "first planning frame accumulated another planning or commentary row"
    fi
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: LIVE_PLAN_TWO'; then
    seen_plan_two=1
    plan_step_two=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: LIVE_PLAN_TWO' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    step_count=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+:' | wc -l | tr -d ' ')
    [ "$step_count" -eq 1 ] || fail "second planning frame rendered $step_count numbered rows"
    if printf '%s' "$final_text" | grep -Eq 'LIVE_PLAN_ONE|LIVE_PLAN_THREE|COMMENTARY_'; then
      printf '%s\n' "$final_text" >&2
      fail "second planning frame retained another planning or commentary row"
    fi
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: LIVE_PLAN_THREE'; then
    seen_plan_three=1
    plan_step_three=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: LIVE_PLAN_THREE' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    step_count=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+:' | wc -l | tr -d ' ')
    [ "$step_count" -eq 1 ] || fail "third planning frame rendered $step_count numbered rows"
    if printf '%s' "$final_text" | grep -Eq 'LIVE_PLAN_[12]|COMMENTARY_'; then
      printf '%s\n' "$final_text" >&2
      fail "third planning frame retained another planning or commentary row"
    fi
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: COMMENTARY_1'; then
    seen_one=1
    step_one=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: COMMENTARY_1' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    step_count=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+:' | wc -l | tr -d ' ')
    [ "$step_count" -eq 1 ] || fail "first frame rendered $step_count numbered rows"
    if printf '%s' "$final_text" | grep -Eq 'LIVE_PLAN_|COMMENTARY_[23]'; then
      printf '%s\n' "$final_text" >&2
      fail "first frame accumulated a later planning or commentary row"
    fi
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: COMMENTARY_2'; then
    seen_two=1
    step_two=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: COMMENTARY_2' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    step_count=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+:' | wc -l | tr -d ' ')
    [ "$step_count" -eq 1 ] || fail "second frame rendered $step_count numbered rows"
    if printf '%s' "$final_text" | grep -Eq 'LIVE_PLAN_ONE|COMMENTARY_[13]'; then
      printf '%s\n' "$final_text" >&2
      fail "second frame retained an earlier or later planning or commentary row"
    fi
  fi
  if printf '%s' "$final_text" | grep -Eq 'Step [0-9]+: COMMENTARY_3'; then
    seen_three=1
    step_three=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+: COMMENTARY_3' | sed -E 's/Step ([0-9]+).*/\1/' | tail -1)
    step_count=$(printf '%s' "$final_text" | grep -Eo 'Step [0-9]+:' | wc -l | tr -d ' ')
    [ "$step_count" -eq 1 ] || fail "third frame rendered $step_count numbered rows"
    if printf '%s' "$final_text" | grep -Eq 'LIVE_PLAN_[12]|COMMENTARY_[12]'; then
      printf '%s\n' "$final_text" >&2
      fail "third frame retained an earlier planning or commentary row"
    fi
  fi
  printf '%s' "$final_text" | grep -Fq 'CALM_LIVE_HERDR_FINAL' && break
  sleep 0.1
done
[ "$seen_plan_one" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the first planning step"; }
[ "$seen_plan_two" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the second planning step"; }
[ "$seen_plan_three" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the third planning step"; }
[ "$seen_one" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the first commentary step"; }
[ "$seen_two" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the second commentary step"; }
[ "$seen_three" -eq 1 ] || { printf '%s\n' "$final_text" >&2; fail "real Pi/Herdr never displayed the third commentary step"; }
[ "$plan_step_one" -lt "$plan_step_two" ] && [ "$plan_step_two" -lt "$plan_step_three" ] \
  && [ "$step_one" -lt "$step_two" ] && [ "$step_two" -lt "$step_three" ] \
  || fail "Calm step numbers did not increase monotonically: plans $plan_step_one, $plan_step_two, $plan_step_three; commentary $step_one, $step_two, $step_three"
printf '%s' "$final_text" | grep -Fq 'CALM_LIVE_HERDR_FINAL' \
  || fail "real Pi/Herdr fixture did not settle its final response"
printf '%s' "$final_text" | grep -Fq 'Step ' \
  && fail "final Pi response retained an intermediate-step row"
printf '%s' "$final_text" | grep -Fq 'LIVE_PLAN_' \
  && fail "final Pi response retained planning narration"
printf '%s' "$final_text" | grep -Fq 'COMMENTARY_' \
  && fail "final Pi response retained intermediate commentary"

session_file=$(find "$SESSIONS" -type f -name '*.jsonl' -exec grep -l 'CALM_LIVE_HERDR_FINAL' {} + 2>/dev/null | head -1)
[ -n "$session_file" ] || fail "real Pi did not persist its session transcript"
grep -Fq 'LIVE_PLAN_ONE' "$session_file" || fail "live planning context was not persisted"
grep -Fq 'LIVE_PLAN_TWO' "$session_file" || fail "second planning context was not persisted"
grep -Fq 'LIVE_PLAN_THREE' "$session_file" || fail "third planning context was not persisted"
grep -Fq 'COMMENTARY_1' "$session_file" || fail "first commentary context was not persisted"
grep -Fq 'COMMENTARY_2' "$session_file" || fail "second commentary context was not persisted"
grep -Fq 'COMMENTARY_3' "$session_file" || fail "third commentary context was not persisted"
printf 'ok - real Pi %s in Herdr displayed one replacing numbered Calm step around three tool calls, settled to the final response, and preserved planning context\n' "$(pi --version)"
