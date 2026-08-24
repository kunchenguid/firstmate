#!/usr/bin/env bash
# Opt-in live guard for Calm's collapsed presentation of a supervision-branch
# outcome read, against the REAL installed pi binary in a real terminal.
#
# The verdict this guard answers is harness-dependent by construction: whether a
# row disappears, and what is left on screen when it does not, is decided by Pi's
# own renderer, so no stub can confirm it. A fixture provider makes the real
# model surface ask for the real fm_branch_outcomes tool, which reads a real
# store written by bin/fm-branch-outcome.sh, and the assertions read what Pi
# actually painted.
#
# No credentials are read and no provider call leaves the machine: the fixture
# provider answers locally and PI_OFFLINE is set.
#
# Run after every Pi upgrade and before trusting refreshed Calm evidence
# (docs/verification/runtime-backends.md).
set -u

if [ "${FM_CALM_BRANCH_OUTCOMES_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CALM_BRANCH_OUTCOMES_LIVE_E2E=1 to run the real-Pi Calm branch-outcome guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export NODE_NO_WARNINGS=1

command -v pi >/dev/null 2>&1 || fail "pi absent: the live Calm branch-outcome guard needs the real pi binary and refuses to pass having checked nothing"
command -v tmux >/dev/null 2>&1 || fail "tmux absent: the live Calm branch-outcome guard needs a real terminal and refuses to pass having checked nothing"
PI_VERSION=$(pi --version 2>/dev/null || true)
[ -n "$PI_VERSION" ] || fail "pi did not report a version: the live Calm branch-outcome guard refuses to record evidence it cannot attribute"

TMP_ROOT=$(fm_test_tmproot fm-calm-branch-outcomes-live)
TMUX_SOCKET="fm-calm-outcomes-$$"
cleanup() {
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

project="$TMP_ROOT/project"
home="$TMP_ROOT/home"
config="$TMP_ROOT/pi-config"
broken_root="$TMP_ROOT/no-firstmate-scripts"
mkdir -p "$project/.pi/extensions/lib" "$home/state" "$home/config" "$config" "$broken_root/bin"
fm_git_init_commit "$project"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$project/.pi/extensions/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$project/.pi/extensions/fm-calm.ts"
# Named one by one rather than globbed so a change to any of them selects this
# guard through bin/fm-test-run.sh's changed-path reference scan.
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$project/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$project/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-branch-outcomes.ts" "$project/.pi/extensions/lib/fm-calm-branch-outcomes.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$project/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$project/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$project/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$project/.pi/extensions/lib/fm-operational-input.ts"
printf '%s\n' '{"tui.input.submit":"alt+s"}' >"$config/keybindings.json"

# One fixture model that calls a Calm-collapsed built-in first and the tool under
# test second, so a single transcript proves Calm was actually on (the built-in
# row is gone) at the same moment it shows what became of the outcome read.
cat >"$project/.pi/extensions/fm-calm-outcomes-e2e.ts" <<'TS'
import {
  type AssistantMessage,
  createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  pi.registerProvider("calm-outcomes-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "calm-outcomes-e2e-api",
    models: [
      {
        id: "call-outcomes",
        name: "Calm branch-outcome row fixture",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 8192,
        maxTokens: 128,
      },
    ],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const priorResults = (context.messages ?? []).filter(
        (message: { role?: string }) => message.role === "toolResult",
      ).length;
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
        stopReason: "stop",
        timestamp: Date.now(),
      };
      void (async () => {
        await new Promise((resolve) => setTimeout(resolve, 20));
        stream.push({ type: "start", partial: output });
        if (priorResults >= 2) {
          const block = { type: "text" as const, text: "" };
          output.content.push(block);
          stream.push({ type: "text_start", contentIndex: 0, partial: output });
          block.text = "CALM_OUTCOMES_E2E_DONE";
          stream.push({ type: "text_delta", contentIndex: 0, delta: block.text, partial: output });
          stream.push({ type: "text_end", contentIndex: 0, content: block.text, partial: output });
          stream.push({ type: "done", reason: "stop", message: output });
          stream.end();
          return;
        }
        const call =
          priorResults === 0
            ? {
                type: "toolCall" as const,
                id: "call_calm_outcomes_bash",
                name: "bash",
                arguments: { command: "printf 'CALM_OUTCOMES_E2E_BASH\\n'" },
              }
            : {
                type: "toolCall" as const,
                id: "call_calm_outcomes_read",
                name: "fm_branch_outcomes",
                arguments: { recent: 16 },
              };
        output.content.push(call);
        output.stopReason = "toolUse";
        stream.push({ type: "toolCall_start", contentIndex: 0, partial: output });
        stream.push({ type: "toolCall_end", contentIndex: 0, content: call, partial: output });
        stream.push({ type: "done", reason: "toolUse", message: output });
        stream.end();
      })();
      return stream;
    },
  });

  pi.registerCommand("calm-outcomes-e2e", {
    description: "Ask the fixture model to read the branch outcome store.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-outcomes-e2e", "call-outcomes");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("could not select the Calm branch-outcome fixture model");
      }
      await pi.sendUserMessage("CALM_OUTCOMES_E2E_PROMPT");
    },
  });
}
TS

outcome() { # <verdict> <task> <summary>
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    bash "$ROOT/bin/fm-branch-outcome.sh" append \
      --task "$2" --verdict "$1" --summary "$3" --wake "signal: $2" >/dev/null \
    || fail "the real outcome writer refused a $1 record for $2"
}

# More records than Pi previews unexpanded, so the Calm-off path also proves the
# stock clip-and-expand shape survived taking the render slots over.
outcome captain task-12 "PR https://example.com/pr/12 checks green, ready for review"
i=1
while [ "$i" -le 14 ]; do
  outcome routine "task-r$i" "CALM_OUTCOMES_ROUTINE_$i"
  i=$((i + 1))
done
outcome captain task-4 "blocked: cannot reach the forge, credentials rejected"

# Capture one full fixture turn from a fresh real Pi session, optionally taking
# Pi's own HTML export of that same turn before the session ends.
# capture_turn <calm-preference> <firstmate-root> <snapshot-path> [export-path]
capture_turn() {
  local calm=$1 fm_root=$2 snapshot=$3 export_path=${4:-} waited=0
  printf '%s\n' "$calm" >"$home/config/calm"
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  tmux -L "$TMUX_SOCKET" new-session -d -s live -x 180 -y 44 \
    "cd '$project' && env FM_HOME='$home' FM_ROOT_OVERRIDE='$fm_root' PI_CODING_AGENT_DIR='$config' PI_OFFLINE=1 pi --approve --no-skills --no-prompt-templates --no-context-files; sleep 120"
  waited=0
  while [ "$waited" -lt 400 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t live -S -400 >"$snapshot" 2>/dev/null || true
    grep -Fq "Pi can explain its own features" "$snapshot" && break
    sleep 0.05
    waited=$((waited + 1))
  done
  grep -Fq "Pi can explain its own features" "$snapshot" \
    || fail "pi $PI_VERSION never reached its prompt for the live Calm branch-outcome guard"
  tmux -L "$TMUX_SOCKET" send-keys -t live -l "/calm-outcomes-e2e"
  tmux -L "$TMUX_SOCKET" send-keys -t live M-s
  waited=0
  while [ "$waited" -lt 600 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t live -S -400 >"$snapshot" 2>/dev/null || true
    grep -Fq "CALM_OUTCOMES_E2E_DONE" "$snapshot" && break
    sleep 0.05
    waited=$((waited + 1))
  done
  grep -Fq "CALM_OUTCOMES_E2E_DONE" "$snapshot" \
    || fail "pi $PI_VERSION never completed the fixture turn for the live Calm branch-outcome guard (calm=$calm)"
  if [ -n "$export_path" ]; then
    tmux -L "$TMUX_SOCKET" send-keys -t live -l "/export $export_path"
    tmux -L "$TMUX_SOCKET" send-keys -t live M-s
    waited=0
    while [ "$waited" -lt 600 ]; do
      tmux -L "$TMUX_SOCKET" capture-pane -p -t live -S -400 >"$snapshot.export" 2>/dev/null || true
      grep -Fq "Session exported to: $export_path" "$snapshot.export" && break
      sleep 0.05
      waited=$((waited + 1))
    done
    grep -Fq "Session exported to: $export_path" "$snapshot.export" \
      || fail "pi $PI_VERSION never completed the export for the live Calm branch-outcome guard (calm=$calm)"
  fi
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
}

test_calm_off_keeps_the_stock_row() {
  local snapshot="$TMP_ROOT/calm-off.txt"
  capture_turn off "$ROOT" "$snapshot"
  assert_grep 'CALM_OUTCOMES_E2E_BASH' "$snapshot" \
    "pi $PI_VERSION hid an ordinary tool row while Calm was off, so this snapshot cannot judge the branch-outcome row"
  assert_grep 'fm_branch_outcomes' "$snapshot" \
    "pi $PI_VERSION dropped the branch-outcome tool row while Calm was off"
  assert_grep '"verdict":"routine"' "$snapshot" \
    "pi $PI_VERSION no longer shows the raw branch-outcome records while Calm is off"
  assert_grep 'more lines,' "$snapshot" \
    "pi $PI_VERSION lost the stock clip-and-expand shape for a long branch-outcome read while Calm was off"
  pass "real Pi $PI_VERSION keeps the whole stock branch-outcome row, raw records and clip-and-expand shape included, while Calm is off"
}

test_calm_on_collapses_to_what_needs_attention() {
  local snapshot="$TMP_ROOT/calm-on.txt"
  capture_turn on "$ROOT" "$snapshot" "$TMP_ROOT/calm-on-export.html"
  assert_no_grep 'CALM_OUTCOMES_E2E_BASH' "$snapshot" \
    "Calm was not actually collapsing tool rows in this pi $PI_VERSION session, so its branch-outcome result proves nothing"
  assert_no_grep 'fm_branch_outcomes' "$snapshot" \
    "pi $PI_VERSION left the branch-outcome tool row's own shell on screen while Calm was on"
  assert_no_grep '"verdict":"routine"' "$snapshot" \
    "pi $PI_VERSION still dumps the raw branch-outcome records into the transcript while Calm is on"
  assert_no_grep 'CALM_OUTCOMES_ROUTINE_' "$snapshot" \
    "Calm kept an outcome the supervision branch already handled on screen in pi $PI_VERSION"
  assert_grep 'task-12: PR https://example.com/pr/12 checks green, ready for review' "$snapshot" \
    "Calm collapsed away a captain-relevant branch outcome in pi $PI_VERSION"
  assert_grep 'task-4: blocked: cannot reach the forge, credentials rejected' "$snapshot" \
    "Calm collapsed away a branch outcome reporting a blocker in pi $PI_VERSION"
  assert_grep '⛵' "$snapshot" \
    "Calm dropped the supervision glyph from what it kept in pi $PI_VERSION"
  pass "real Pi $PI_VERSION collapses a branch-outcome read under Calm to one dim line per outcome that still needs the captain, and nothing else"
}

test_calm_on_export_keeps_every_record() {
  # Same session, same collapsed row: Calm's presentation must not reach what
  # /export writes, which is the copy the captain keeps.
  local export_file="$TMP_ROOT/calm-on-export.html"
  [ -s "$export_file" ] || fail "pi $PI_VERSION wrote no export for the live Calm branch-outcome guard"
  node - "$export_file" "$PI_VERSION" <<'JS' || fail "Calm's collapse reached the HTML export in the pi run above, so the exported copy lost branch-outcome records"
const { readFileSync } = require("node:fs");
const html = readFileSync(process.argv[2], "utf8");
const version = process.argv[3];
const match = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/);
if (!match) {
  console.error(`pi ${version} export carried no session data`);
  process.exit(1);
}
const session = JSON.parse(Buffer.from(match[1], "base64").toString("utf8"));
const entries = JSON.stringify(session.session?.entries ?? session.entries ?? []);
const rowsIn = (text) => (String(text).match(/&quot;verdict&quot;/g) || []).length;
const rendered = session.renderedTools?.call_calm_outcomes_read;
const problems = [];
if (!entries.includes('\\"verdict\\":\\"routine\\"') && !entries.includes('"verdict":"routine"')) {
  problems.push("the exported session entries lost the raw outcome records");
}
if (!rendered?.resultHtmlExpanded) {
  problems.push("the export rendered no result for the branch-outcome row");
} else if (rowsIn(rendered.resultHtmlExpanded) !== 16) {
  problems.push(`the exported branch-outcome row carried ${rowsIn(rendered.resultHtmlExpanded)} of 16 records`);
}
if (problems.length > 0) {
  console.error(`pi ${version}: ${problems.join("; ")}`);
  process.exit(1);
}
JS
  pass "real Pi $PI_VERSION exports every branch-outcome record from a session where Calm collapsed that row on screen"
}

test_calm_on_never_hides_a_failed_read() {
  local snapshot="$TMP_ROOT/calm-on-failure.txt"
  # No fm-branch-outcome.sh under this root, so the real tool takes its real
  # failure path and the row must survive the collapse.
  capture_turn on "$broken_root" "$snapshot"
  assert_no_grep 'CALM_OUTCOMES_E2E_BASH' "$snapshot" \
    "Calm was not actually collapsing tool rows in this pi $PI_VERSION session, so its branch-outcome result proves nothing"
  assert_grep 'could not read the outcome store' "$snapshot" \
    "Calm hid a failed branch-outcome read in pi $PI_VERSION, leaving the captain unable to see the fleet with no sign of it"
  pass "real Pi $PI_VERSION keeps a failed branch-outcome read visible under Calm instead of collapsing it to nothing"
}

test_calm_off_keeps_the_stock_row
test_calm_on_collapses_to_what_needs_attention
test_calm_on_export_keeps_every_record
test_calm_on_never_hides_a_failed_read
