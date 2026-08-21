#!/usr/bin/env bash
# Opt-in live Pi/pi-signed footer composition check with credential-free fake quota data.
set -u

if [ "${FM_PI_QUOTA_STATUS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_PI_QUOTA_STATUS_LIVE=1 to run the live Pi quota footer regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
command -v node >/dev/null 2>&1 || fail "node not found"

LAB="$ROOT/.pi-quota-live.$$"
FAKEBIN="$LAB/fakebin"
PI_CONFIG="$LAB/pi-config"
LIVE_CALLS="$LAB/quota.calls"
LIVE_STDIN="$LAB/quota.stdin"
mkdir -p "$FAKEBIN" "$PI_CONFIG"

cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$*" >> "$LIVE_CALLS"
if IFS= read -r input; then
  printf 'data:%s\\n' "\$input" >> "$LIVE_STDIN"
else
  printf '%s\\n' eof >> "$LIVE_STDIN"
fi
node <<'JS'
const now = Date.now();
const reset = (milliseconds) => new Date(now + milliseconds).toISOString();
const generatedAt = new Date(now).toISOString();
const windows = [
  { id: "weekly", label: "week", kind: "weekly", percentUsed: 6, percentRemaining: 94, resetsAt: reset(6 * 24 * 60 * 60 * 1000), pace: { status: "unknown", reason: "missing_cycle" } },
  { id: "model:spark:5h", label: "GPT-5.3-Codex-Spark session", kind: "model", percentUsed: 0, percentRemaining: 100, resetsAt: reset(5 * 60 * 60 * 1000), pace: { status: "unknown", reason: "missing_cycle" } },
  { id: "model:spark:7d", label: "GPT-5.3-Codex-Spark week", kind: "model", percentUsed: 0, percentRemaining: 100, resetsAt: reset(6 * 24 * 60 * 60 * 1000), pace: { status: "unknown", reason: "missing_cycle" } },
];
const availability = (scope, bounded) => {
  const boundedBy = bounded.map((window) => window.id);
  const effectivePercentRemaining = Math.min(...bounded.map((window) => window.percentRemaining));
  return {
    scope,
    status: "known",
    effectivePercentRemaining,
    boundedBy,
    limitingWindowIds: bounded
      .filter((window) => window.percentRemaining === effectivePercentRemaining)
      .map((window) => window.id),
    pace: { status: "unknown", unknownWindowIds: boundedBy },
    runway: { status: "unknown", unmeasurableWindowIds: boundedBy },
    selection: { status: "unknown", unmeasurableWindowIds: boundedBy },
  };
};
process.stdout.write(JSON.stringify({
  generatedAt,
  schemaVersion: 5,
  providers: [{
    provider: "codex",
    label: "Codex",
    source: "oauth",
    plan: "pro",
    account: { accountId: "live-codex-account" },
    windows,
    quotaSemantics: {
      status: "known",
      description: "Codex base account windows bound every model.",
      effectiveAvailability: [
        availability("all_models", [windows[0]]),
        availability("model:spark", windows),
      ],
    },
    credits: { remaining: 0, unlimited: false, unit: "credits" },
    state: { status: "fresh", stale: false, refreshedAt: generatedAt, sourcesTried: ["oauth"] },
    attempts: [{ source: "oauth", status: "success" }],
  }],
}));
JS
SH
chmod +x "$FAKEBIN/quota-axi"

LIVE_ACCESS=$(node -e '
const payload = Buffer.from(JSON.stringify({
  "https://api.openai.com/auth": { chatgpt_account_id: "live-codex-account" },
})).toString("base64url");
process.stdout.write(`eyJhbGciOiJub25lIn0.${payload}.fixture`);
')
cat > "$PI_CONFIG/auth.json" <<JSON
{
  "openai-codex": {
    "type": "oauth",
    "refresh": "credential-free-live-fixture",
    "access": "$LIVE_ACCESS",
    "expires": 4102444800000
  }
}
JSON
chmod 600 "$PI_CONFIG/auth.json"

checked=0
cleanup() {
  local session
  while IFS= read -r session; do
    case "$session" in
      fm-pi-quota-live.$$.*) tmux kill-session -t "$session" 2>/dev/null || true ;;
    esac
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
  rm -rf "$LAB"
}
trap cleanup EXIT

run_harness() {
  local harness=$1 binary=$2 version project calls stdin_log capture_log launch_script
  local pane session launch_command attempt pane_dead pane_status
  version=$($binary --version 2>/dev/null) || fail "$harness version probe failed"
  project="$LAB/project-$harness"
  calls="$LIVE_CALLS"
  stdin_log="$LIVE_STDIN"
  capture_log="$LAB/$harness.capture"
  launch_script="$LAB/$harness-launch.sh"
  mkdir -p "$project/.pi/extensions" "$project/.pi/quota-fixture/lib"
  cp "$ROOT/.pi/extensions/fm-pi-quota-status.ts" "$project/.pi/quota-fixture/"
  cp "$ROOT/.pi/extensions/lib/fm-pi-quota-status.ts" "$project/.pi/quota-fixture/lib/"
  cat > "$project/.pi/extensions/fm-pi-quota-status.ts" <<TS
import { createFirstmateQuotaStatusExtension } from "../quota-fixture/fm-pi-quota-status.ts";
export default createFirstmateQuotaStatusExtension({ command: "$FAKEBIN/quota-axi" });
TS
  cat > "$project/.pi/extensions/aaa-unrelated-status.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setStatus("aaa-live-unrelated", "LIVE_UNRELATED_STATUS");
  });
}
TS
  git -C "$project" init -q -b quota-live
  git -C "$project" config user.email live@example.invalid
  git -C "$project" config user.name "Live Fixture"
  git -C "$project" add .
  git -C "$project" commit -qm fixture
  : > "$calls"
  : > "$stdin_log"

  cat > "$launch_script" <<EOF
#!/usr/bin/env bash
export COLUMNS=260 LINES=40
export PATH="$FAKEBIN:$PATH"
export PI_CODING_AGENT_DIR="$PI_CONFIG" PI_OFFLINE=1
sleep 0.5
exec "$binary" --approve --no-session --no-context-files --no-skills --model openai-codex/gpt-5.3-codex-spark --tui-mode regular
EOF
  chmod +x "$launch_script"
  session="fm-pi-quota-live.$$.$harness"
  printf -v launch_command 'exec %q' "$launch_script"
  tmux new-session -d -s "$session" -x 260 -y 40 -c "$project" "$launch_command" \
    || fail "$harness live tmux session did not start"
  tmux set-window-option -t "$session:0" remain-on-exit on >/dev/null \
    || fail "$harness live tmux session could not retain its final screen"
  pane=
  for attempt in $(seq 1 450); do
    pane=$(tmux capture-pane -p -t "$session:0.0" 2>/dev/null | tr -d '\r')
    case "$pane" in
      *"GPT-5.3-Codex-Spark week"*) break ;;
    esac
    pane_dead=$(tmux display-message -p -t "$session:0.0" '#{pane_dead}' 2>/dev/null || printf 1)
    [ "$pane_dead" != 1 ] || break
    sleep 0.1
  done
  printf '%s\n' "$pane" > "$capture_log"
  case "$pane" in
    *"GPT-5.3-Codex-Spark week"*) ;;
    *)
      printf '%s\n' "$pane" >&2
      fail "$harness live Pi process did not render quota in its final terminal screen"
      ;;
  esac
  printf '%s\n' "$pane" | grep -Fq '(quota-live)' \
    || fail "$harness quota extension hid Pi's built-in cwd/git footer information"
  printf '%s\n' "$pane" | grep -Fq 'gpt-5.3-codex-spark' \
    || fail "$harness quota extension hid Pi's built-in model footer information"
  printf '%s\n' "$pane" | grep -Eq '/[0-9.]+[kM]' \
    || fail "$harness quota extension hid Pi's built-in context footer information"
  printf '%s\n' "$pane" | grep -Fq 'LIVE_UNRELATED_STATUS' \
    || fail "$harness quota extension hid an unrelated extension status"
  for expected in \
    'Quota Codex (plan pro)' \
    'week 94% left' \
    'GPT-5.3-Codex-Spark session 100% left' \
    'GPT-5.3-Codex-Spark week 100% left' \
    'credits 0'
  do
    printf '%s\n' "$pane" | grep -Fq "$expected" \
      || fail "$harness live footer omitted '$expected'"
  done
  [ "$(wc -l < "$calls" | tr -d ' ')" -ge 1 ] || fail "$harness never invoked fake quota-axi"
  grep -Fvx -- '--json --full --provider codex' "$calls" >/dev/null \
    && fail "$harness used unexpected quota-axi argv: $(tr '\n' '|' < "$calls")"
  grep -Fvx -- eof "$stdin_log" >/dev/null \
    && fail "$harness left quota-axi stdin readable: $(tr '\n' '|' < "$stdin_log")"

  tmux send-keys -t "$session:0.0" -l '/quit' \
    || fail "$harness live Pi process did not accept quit input"
  tmux send-keys -t "$session:0.0" Enter \
    || fail "$harness live Pi process did not accept quit submission"
  pane_dead=0
  for attempt in $(seq 1 200); do
    pane_dead=$(tmux display-message -p -t "$session:0.0" '#{pane_dead}' 2>/dev/null || printf 1)
    [ "$pane_dead" != 1 ] || break
    sleep 0.1
  done
  [ "$pane_dead" = 1 ] || fail "$harness live Pi process did not exit after /quit"
  pane_status=$(tmux display-message -p -t "$session:0.0" '#{pane_dead_status}' 2>/dev/null)
  [ "$pane_status" = 0 ] || fail "$harness live Pi process failed with status $pane_status"
  tmux kill-session -t "$session" 2>/dev/null || true

  printf 'ok - %s %s auto-discovered complete quota in a width-aware row while preserving the built-in footer and unrelated status\n' "$harness" "$version"
  checked=$((checked + 1))
}

for harness in pi pi-signed; do
  if command -v "$harness" >/dev/null 2>&1; then
    run_harness "$harness" "$(command -v "$harness")"
  else
    printf '# harness absent, not verified here: %s\n' "$harness"
  fi
done

[ "$checked" -gt 0 ] || fail "live Pi quota guard checked no installed Pi-family harness"
printf 'ok - live Pi quota guard verified %s installed Pi-family harness(es)\n' "$checked"
