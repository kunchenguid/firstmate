#!/usr/bin/env bash
# Opt-in real-Pi regular-TUI regression for transcript shrink: a viewport-filling
# tool result is expanded and collapsed, and a render that is taller before the
# shrink than after must not leave stale empty rows below the new content.
set -u

if [ "${FM_PI_CLEAR_ON_SHRINK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_CLEAR_ON_SHRINK_LIVE_E2E=1 to run the isolated Pi shrink regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

LAB=$(fm_test_tmproot fm-pi-clear-on-shrink-live-e2e)
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
CONFIG_DIR="$LAB/pi-config"
SESSIONS_DIR="$LAB/sessions"
SOCKET="fm-pi-shrink-$$"
SESSION=pi-shrink
SNAPSHOT="$LAB/pane.txt"
PREV_SNAPSHOT="$LAB/pane-prev.txt"
PANE_ROWS=36
PANE_COLUMNS=100

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

capture_viewport() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" >"$SNAPSHOT" 2>/dev/null || true
}

capture_history() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -500 >"$SNAPSHOT" 2>/dev/null || true
}

wait_for_text() {
  local text=$1 attempt=0
  while [ "$attempt" -lt 240 ]; do
    capture_viewport
    grep -Fq "$text" "$SNAPSHOT" && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_text_gone() {
  local text=$1 attempt=0
  while [ "$attempt" -lt 240 ]; do
    capture_viewport
    grep -Fq "$text" "$SNAPSHOT" || return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_history_text() {
  local text=$1 attempt=0
  while [ "$attempt" -lt 240 ]; do
    capture_history
    grep -Fq "$text" "$SNAPSHOT" && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

send_line() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

CALM_SHIP_HULL='\__/'
SETTLE_SAMPLE_SECONDS=0.06
SETTLE_STABLE_INTERVALS=4
DRAFT_TOKEN=draftfill
# 130 repeats wrap to about ten composer rows in a 100-column pane, so clearing
# the draft shrinks the render far past the tolerated blank-row slack.
DRAFT_TEXT=$(awk 'BEGIN { for (i = 0; i < 130; i++) printf "draftfill " }')
DRAFT_MIN_ROWS=6

settle_viewport() {
  local marker=$1 label=$2 attempt=0 stable=0
  : >"$PREV_SNAPSHOT"
  while [ "$attempt" -lt 400 ]; do
    cp "$SNAPSHOT" "$PREV_SNAPSHOT" 2>/dev/null || true
    sleep "$SETTLE_SAMPLE_SECONDS"
    capture_viewport
    if grep -Fq "$marker" "$SNAPSHOT" \
      && ! tail -12 "$SNAPSHOT" | grep -Fq "$CALM_SHIP_HULL" \
      && cmp -s "$SNAPSHOT" "$PREV_SNAPSHOT"; then
      stable=$((stable + 1))
      [ "$stable" -ge "$SETTLE_STABLE_INTERVALS" ] && return 0
    else
      stable=0
    fi
    attempt=$((attempt + 1))
  done
  cat "$SNAPSHOT" >&2
  fail "$label did not hold $marker in a viewport that stayed unchanged across $SETTLE_STABLE_INTERVALS samples with the Calm working ship gone"
}

assert_no_empty_region_before() {
  local marker=$1 label=$2 blank_run
  blank_run=$(awk -v marker="$marker" '
    BEGIN { run = 0 }
    index($0, marker) { print run; found=1; exit }
    /^[[:space:]]*$/ { run += 1; next }
    { run = 0 }
    END { if (!found) exit 2 }
  ' "$SNAPSHOT") || fail "$label did not render $marker in the visible viewport"
  [ "$blank_run" -le 3 ] \
    || fail "$label left a $blank_run-row empty region above $marker"
}

# The transcript is taller than the pane throughout, so a correctly cleared
# shrink always redraws content down to the last terminal row. Rows left blank
# under the final rendered row are the stale region the fix must prevent.
assert_no_stale_rows_below() {
  local label=$1 last_row stale
  last_row=$(awk '!/^[[:space:]]*$/ { row = NR } END { print row + 0 }' "$SNAPSHOT")
  [ "$last_row" -gt 0 ] || {
    cat "$SNAPSHOT" >&2
    fail "$label left the whole viewport blank"
  }
  stale=$((PANE_ROWS - last_row))
  [ "$stale" -le 2 ] || {
    cat "$SNAPSHOT" >&2
    fail "$label left a $stale-row empty region below the last rendered row"
  }
}

# Grow the render with a wrapped composer draft, then clear it. The shrink is
# confined to the bottom of the viewport, which is the case Pi renders
# differentially instead of redrawing in full.
shrink_render_and_assert() {
  local label=$1 anchor=$2 draft_rows attempt=0
  # The shrink only proves anything while the transcript is taller than the
  # pane, so require a full viewport before growing the render.
  assert_no_stale_rows_below "$label baseline"
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$DRAFT_TEXT"
  wait_for_text "$DRAFT_TOKEN" || fail "$label draft never reached the composer"
  while [ "$attempt" -lt 120 ]; do
    capture_viewport
    draft_rows=$(grep -c "$DRAFT_TOKEN" "$SNAPSHOT")
    [ "$draft_rows" -ge "$DRAFT_MIN_ROWS" ] && break
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ "$draft_rows" -ge "$DRAFT_MIN_ROWS" ] || {
    cat "$SNAPSHOT" >&2
    fail "$label draft only grew the render by $draft_rows rows, so the shrink would prove nothing"
  }
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    tmux -L "$SOCKET" send-keys -t "$SESSION" C-u
    sleep 0.05
  done
  wait_for_text_gone "$DRAFT_TOKEN" || fail "$label could not clear the composer draft"
  settle_viewport "$anchor" "$label"
  assert_no_stale_rows_below "$label"
}

mkdir -p \
  "$PROJECT/.pi/extensions/lib" \
  "$PROJECT/node_modules/@earendil-works" \
  "$HOME_DIR/config" \
  "$CONFIG_DIR" \
  "$SESSIONS_DIR"
fm_git_init_commit "$PROJECT"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || fail "installed @earendil-works/pi-coding-agent package not found"
ln -s "$PI_PACKAGE_DIR" "$PROJECT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$PROJECT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$PROJECT/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$PROJECT/package.json"
printf '%s\n' on >"$HOME_DIR/config/calm"
printf '%s\n' '{"compaction":{"keepRecentTokens":200}}' >"$CONFIG_DIR/settings.json"

cat >"$PROJECT/shrink-provider.ts" <<'TS'
import {
  createFauxCore,
  fauxAssistantMessage,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const tallResult = (label: string): string => Array.from(
  { length: 96 },
  (_, index) => `${label}_ROW_${String(index + 1).padStart(3, "0")}`,
).join("\n");

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "pi-shrink-e2e-api",
    provider: "pi-shrink-e2e",
    models: [{
      id: "deterministic",
      name: "Pi clear-on-shrink E2E",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 100000,
      maxTokens: 10000,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  faux.setResponses([
    fauxAssistantMessage(fauxText(`${"context prose ".repeat(450)}\nTRANSCRIPT_TALLER_THAN_PANE`)),
    fauxAssistantMessage(
      fauxToolCall("viewport_fill", { label: "BEFORE_COMPACT" }, { id: "viewport_before" }),
      { stopReason: "toolUse" },
    ),
    fauxAssistantMessage(fauxText("AFTER_TOOL_RESULT")),
    fauxAssistantMessage(fauxText("NEXT_VISIBLE_CONTENT")),
    // A real /compact rebuild consumes two model calls before the next turn.
    fauxAssistantMessage(fauxText("COMPACTED_SHRINK_FIXTURE")),
    fauxAssistantMessage(fauxText("COMPACTION_REBUILD_FILLER")),
    fauxAssistantMessage(
      fauxToolCall("viewport_fill", { label: "AFTER_COMPACT" }, { id: "viewport_after" }),
      { stopReason: "toolUse" },
    ),
    fauxAssistantMessage(fauxText("AFTER_COMPACT_TOOL_RESULT")),
    fauxAssistantMessage(fauxText("NEXT_VISIBLE_AFTER_COMPACT")),
  ]);
  pi.registerProvider("pi-shrink-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerTool({
    name: "viewport_fill",
    label: "Viewport fill",
    description: "Return a deterministic viewport-filling result.",
    parameters: Type.Object({ label: Type.String() }),
    async execute(_toolCallId, params) {
      return {
        content: [{ type: "text", text: tallResult(params.label) }],
        details: {},
      };
    },
  });
  pi.registerCommand("pi-shrink-e2e", {
    description: "Select the deterministic shrink-regression model.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("pi-shrink-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("Pi shrink-regression model unavailable");
      }
    },
  });
}
TS

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x "$PANE_COLUMNS" -y "$PANE_ROWS" \
  "cd '$PROJECT' && env FM_HOME='$HOME_DIR' PI_CODING_AGENT_DIR='$CONFIG_DIR' PI_OFFLINE=1 PI_CLEAR_ON_SHRINK=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions --tui-mode regular -e ./.pi/extensions/fm-calm.ts -e ./shrink-provider.ts --session-dir '$SESSIONS_DIR'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 20"

wait_for_text "shrink-provider.ts" || fail "Pi shrink E2E did not reach the ready composer"
send_line /pi-shrink-e2e
sleep 0.1
send_line "Fill the transcript past the pane height."
wait_for_text TRANSCRIPT_TALLER_THAN_PANE || fail "Pi shrink E2E did not fill the transcript past the pane height"
send_line "Run viewport_fill once, then finish."
wait_for_text AFTER_TOOL_RESULT || fail "Pi shrink E2E did not complete the pre-compaction tool turn"

tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_history_text BEFORE_COMPACT_ROW_096 || {
  cat "$SNAPSHOT" >&2
  fail "Ctrl+O did not expand the viewport-filling tool result"
}
tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_text AFTER_TOOL_RESULT || fail "collapsed pre-compaction result hid the next visible reply"
send_line "Reply after the collapsed tool result."
wait_for_text NEXT_VISIBLE_CONTENT || fail "Pi shrink E2E did not render content after the pre-compaction collapse"
settle_viewport NEXT_VISIBLE_CONTENT "pre-compaction collapse"
assert_no_empty_region_before NEXT_VISIBLE_CONTENT "pre-compaction collapse"
shrink_render_and_assert "pre-compaction shrink" NEXT_VISIBLE_CONTENT

send_line /compact
wait_for_text "Compacted from" || fail "Pi shrink E2E did not complete a real compaction rebuild"
send_line "Run viewport_fill once after compaction, then finish."
wait_for_text AFTER_COMPACT_TOOL_RESULT || fail "Pi shrink E2E did not complete the post-compaction tool turn"
tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_history_text AFTER_COMPACT_ROW_096 || {
  cat "$SNAPSHOT" >&2
  fail "Ctrl+O did not expand the post-compaction tool result"
}
tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_text AFTER_COMPACT_TOOL_RESULT || fail "collapsed post-compaction result hid the next visible reply"
send_line "Reply after the post-compaction collapsed tool result."
wait_for_text NEXT_VISIBLE_AFTER_COMPACT || fail "Pi shrink E2E did not render content after the post-compaction collapse"
settle_viewport NEXT_VISIBLE_AFTER_COMPACT "post-compaction collapse"
assert_no_empty_region_before NEXT_VISIBLE_AFTER_COMPACT "post-compaction collapse"
shrink_render_and_assert "post-compaction shrink" NEXT_VISIBLE_AFTER_COMPACT

printf 'ok - Pi %s regular TUI leaves no stale rows when the render shrinks, before and after compaction\n' "$(pi --version 2>/dev/null | head -n 1)"
