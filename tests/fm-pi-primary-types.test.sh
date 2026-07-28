#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi extension typecheck"; exit 0; }

GLOBAL_NODE_MODULES=$(npm root -g)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$GLOBAL_NODE_MODULES/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
TSC_BIN=${FM_TSC_BIN:-"$(command -v tsc 2>/dev/null || true)"}
if [ ! -x "$TSC_BIN" ]; then
  TSC_BIN="$GLOBAL_NODE_MODULES/openclaw/node_modules/typescript/bin/tsc"
fi
if [ ! -x "$TSC_BIN" ]; then
  echo "skip: tsc not found for Pi extension typecheck"
  exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
  echo "not ok - installed Pi package is missing pi-tui, typebox, or Node declarations" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/fm-primary-footer.ts" "$TMP_ROOT/fm-primary-footer.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/lib/fm-primary-footer-layout.ts" "$TMP_ROOT/lib/fm-primary-footer-layout.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["*.ts", "lib/*.ts"]
}
JSON

"$TSC_BIN" -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"

if node --experimental-strip-types -e 'process.exit(0)' >/dev/null 2>&1; then
  FOOTER_ROOT="$TMP_ROOT" node --experimental-strip-types --input-type=module <<'JS' || exit 1
import assert from "node:assert/strict";
const { formatFooterLines, footerVisibleWidth } = await import(`file://${process.env.FOOTER_ROOT}/lib/fm-primary-footer-layout.ts`);
const { aggregateSessionUsage } = await import(`file://${process.env.FOOTER_ROOT}/fm-primary-footer.ts`);

const theme = { fg: (_color, text) => text };
const data = {
  state: "running",
  model: "gpt-5.6-sol",
  thinking: "high",
  project: "firstmate",
  branch: "fm/pi-ui-parity",
  context: "12.3k (18%)",
  input: "4.5k",
  output: "2.1k",
  cost: "0.042",
  statuses: [
    { key: "watcher\tz", value: "healthy\nnow" },
    { key: "guard", value: "armed\rnow" },
  ],
};
for (const width of [12, 32, 57, 80, 120]) {
  const lines = formatFooterLines(data, width, theme);
  const rendered = lines.join("\n");
  const compact = rendered.replace(/\s/g, "");
  for (const line of lines) {
    assert.ok(footerVisibleWidth(line) <= width, `footer overflow at ${width}: ${line}`);
  }
  for (const [field, expected] of [
    ["state", `●${data.state}`],
    ["model", `model${data.model}`],
    ["thinking", `think${data.thinking}`],
    ["directory", `dir${data.project}`],
    ["branch", `git${data.branch}`],
    ["context", `ctx${data.context}`],
    ["input", `↑${data.input}`],
    ["output", `↓${data.output}`],
    ["cost", `$${data.cost}`],
    ["guard status", "guard:armednow"],
    ["watcher status", "watcherz:healthynow"],
  ]) {
    assert.ok(compact.includes(expected.replace(/\s/g, "")), `footer omitted complete ${field} at ${width}: ${rendered}`);
  }
}
const statusLines = formatFooterLines(data, 120, theme).join("\n");
assert.ok(statusLines.indexOf("guard: armed now") < statusLines.indexOf("watcher z: healthy now"));
assert.doesNotMatch(statusLines, /[\r\t]/);

const usage = (input, output, total) => ({ input, output, cost: { total } });
assert.deepEqual(
  aggregateSessionUsage([
    { type: "message", message: { role: "assistant", usage: usage(10, 2, 1) } },
    { type: "message", message: { role: "toolResult", usage: usage(3, 4, 2) } },
    { type: "compaction", usage: usage(5, 6, 3) },
    { type: "branch_summary", usage: usage(7, 8, 4) },
    { type: "message", message: { role: "user" } },
  ]),
  { input: 25, output: 20, cost: 10 },
);
console.log("ok - Firstmate Pi footer preserves fields, statuses, and cumulative native usage");
JS
else
  printf 'skip: Node type stripping is unavailable for Pi footer formatting test\n'
fi

run_real_tui_contract() (
  PI_BIN=${FM_PI_BIN:-"$(command -v pi 2>/dev/null || true)"}
  if [ ! -x "$PI_BIN" ] || ! command -v tmux >/dev/null 2>&1; then
    printf 'skip: pi or tmux not found for real Pi footer contract\n'
    exit 0
  fi

  fail_tui() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
  }

  socket="fm-pi-primary-types-$$"
  session=pi-footer
  pi_home="$TMP_ROOT/pi-home"
  mkdir -p "$pi_home"
  trap 'tmux -L "$socket" kill-server 2>/dev/null || true' EXIT

  printf -v launch \
    'cd %q && env PI_OFFLINE=1 PI_CODING_AGENT_DIR=%q %q --approve --no-session --no-context-files --no-skills --no-prompt-templates --no-extensions -e .pi/extensions/fm-primary-footer.ts' \
    "$ROOT" "$pi_home" "$PI_BIN"
  tmux -L "$socket" new-session -d -s "$session" -x 120 -y 30 "$launch" \
    || fail_tui "could not launch Pi footer contract"

  pane=
  i=0
  while [ "$i" -lt 120 ]; do
    pane=$(tmux -L "$socket" capture-pane -p -t "$session" -S -80 2>/dev/null || true)
    printf '%s\n' "$pane" | grep -Fq "dir $(basename "$ROOT")" && break
    tmux -L "$socket" has-session -t "$session" 2>/dev/null \
      || fail_tui "Pi exited before rendering the Firstmate footer: $pane"
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pane" | grep -Fq "dir $(basename "$ROOT")" \
    || fail_tui "Pi did not render the Firstmate footer: $pane"

  title=$(tmux -L "$socket" display-message -p -t "$session" '#{pane_title}') \
    || fail_tui "could not read Pi terminal title"
  prefix="Firstmate · $(basename "$ROOT") · "
  rest=${title#"$prefix"}
  branch=${rest%%" · "*}
  model=${rest#*" · "}
  [ "$rest" != "$title" ] && [ -n "$branch" ] && [ "$model" != "$rest" ] && [ -n "$model" ] \
    || fail_tui "Pi did not retain the project/branch/model title: $title"

  printf 'ok - Pi %s real TUI rendered the Firstmate footer and retained its project/branch/model title\n' "$("$PI_BIN" --version)"
)

run_real_tui_contract

run_real_model_picker_contract() (
  PI_BIN=${FM_PI_BIN:-"$(command -v pi 2>/dev/null || true)"}
  if [ ! -x "$PI_BIN" ] || ! command -v tmux >/dev/null 2>&1; then
    printf 'skip: pi or tmux not found for real Pi model-picker contract\n'
    exit 0
  fi

  fail_picker() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
  }

  socket="fm-pi-model-picker-$$"
  session=pi-model-picker
  pi_home="$TMP_ROOT/pi-model-home"
  mkdir -p "$pi_home"
  trap 'tmux -L "$socket" kill-server 2>/dev/null || true' EXIT

  cat > "$pi_home/auth.json" <<'JSON'
{
  "anthropic": {
    "type": "oauth",
    "access": "fixture-access",
    "refresh": "fixture-refresh",
    "expires": 4102444800000
  },
  "openai-codex": {
    "type": "oauth",
    "access": "fixture-access",
    "refresh": "fixture-refresh",
    "expires": 4102444800000,
    "accountId": "fixture-account"
  },
  "openrouter": {
    "type": "api_key",
    "key": "fixture-key"
  }
}
JSON
  chmod 600 "$pi_home/auth.json"

  printf -v launch \
    'cd %q && env -u ANTHROPIC_API_KEY -u ANTHROPIC_OAUTH_TOKEN -u OPENAI_API_KEY -u OPENROUTER_API_KEY PI_OFFLINE=1 PI_CODING_AGENT_DIR=%q %q --approve --no-session --no-context-files --no-skills --no-prompt-templates --no-extensions' \
    "$ROOT" "$pi_home" "$PI_BIN"
  tmux -L "$socket" new-session -d -s "$session" -x 120 -y 34 "$launch" \
    || fail_picker "could not launch Pi model-picker contract"

  pane=
  i=0
  while [ "$i" -lt 120 ]; do
    pane=$(tmux -L "$socket" capture-pane -p -t "$session" -S -80 2>/dev/null || true)
    printf '%s\n' "$pane" | grep -Fq "ctrl+o more" && break
    tmux -L "$socket" has-session -t "$session" 2>/dev/null \
      || fail_picker "Pi exited before model-picker startup: $pane"
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pane" | grep -Fq "ctrl+o more" \
    || fail_picker "Pi did not reach model-picker startup: $pane"

  tmux -L "$socket" send-keys -t "$session" -l '/model'
  tmux -L "$socket" send-keys -t "$session" Enter
  sleep 0.2
  tmux -L "$socket" send-keys -t "$session" -l 'openai-codex'

  i=0
  while [ "$i" -lt 120 ]; do
    pane=$(tmux -L "$socket" capture-pane -p -t "$session" -S -80 2>/dev/null || true)
    printf '%s\n' "$pane" | grep -Fq "[openai-codex]" && break
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pane" | grep -Fq "Scope: all | scoped" \
    || fail_picker "Pi did not open the scoped model-picker view: $pane"
  printf '%s\n' "$pane" | grep -Fq "[openai-codex]" \
    || fail_picker "Pi scoped picker did not expose the ChatGPT OAuth model: $pane"
  if printf '%s\n' "$pane" | grep -Fq "[openrouter]"; then
    fail_picker "Pi scoped picker included OpenRouter models: $pane"
  fi

  tmux -L "$socket" send-keys -t "$session" Tab
  tmux -L "$socket" send-keys -t "$session" C-u
  tmux -L "$socket" send-keys -t "$session" -l 'openrouter'
  i=0
  while [ "$i" -lt 120 ]; do
    pane=$(tmux -L "$socket" capture-pane -p -t "$session" -S -80 2>/dev/null || true)
    printf '%s\n' "$pane" | grep -Fq "[openrouter]" && break
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pane" | grep -Fq "[openrouter]" \
    || fail_picker "Pi all-provider picker did not preserve OpenRouter access: $pane"

  printf 'ok - Pi %s model picker defaults to OAuth subscriptions and keeps OpenRouter under all providers\n' "$("$PI_BIN" --version)"
)

run_real_model_picker_contract
