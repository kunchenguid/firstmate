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

command -v expect >/dev/null 2>&1 || fail "expect not found"
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
process.stdout.write(JSON.stringify({
  generatedAt,
  schemaVersion: 5,
  providers: [{
    provider: "codex",
    label: "Codex",
    source: "oauth",
    plan: "pro",
    windows: [
      { id: "weekly", label: "week", kind: "weekly", percentRemaining: 94, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
      { id: "model:spark:5h", label: "GPT-5.3-Codex-Spark session", kind: "model", percentRemaining: 100, resetsAt: reset(5 * 60 * 60 * 1000) },
      { id: "model:spark:7d", label: "GPT-5.3-Codex-Spark week", kind: "model", percentRemaining: 100, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
    ],
    credits: { remaining: 0, unlimited: false, unit: "credits" },
    state: { status: "fresh", stale: false, refreshedAt: generatedAt, sourcesTried: ["live-fake"] },
  }],
}));
JS
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$PI_CONFIG/auth.json" <<'JSON'
{
  "openai-codex": {
    "type": "oauth",
    "refresh": "credential-free-live-fixture",
    "access": "credential-free-live-fixture",
    "expires": 4102444800000
  }
}
JSON
chmod 600 "$PI_CONFIG/auth.json"

checked=0
cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

run_harness() {
  local harness=$1 binary=$2 version project calls stdin_log capture_log expect_script launch_script pane status=0
  version=$($binary --version 2>/dev/null) || fail "$harness version probe failed"
  project="$LAB/project-$harness"
  calls="$LIVE_CALLS"
  stdin_log="$LIVE_STDIN"
  capture_log="$LAB/$harness.capture"
  expect_script="$LAB/$harness.expect"
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
sleep 0.5
exec "$binary" --approve --no-session --no-context-files --no-skills --model openai-codex/gpt-5.3-codex-spark --tui-mode regular
EOF
  chmod +x "$launch_script"
  cat > "$expect_script" <<EOF
log_user 1
log_file -noappend "$capture_log"
set timeout 45
spawn -noecho env COLUMNS=260 LINES=40 PATH="$FAKEBIN:$PATH" PI_CODING_AGENT_DIR="$PI_CONFIG" PI_OFFLINE=1 "$launch_script"
stty columns 260 rows 40
expect {
  -exact "GPT-5.3-Codex-Spark week" {}
  timeout { exit 124 }
  eof { exit 125 }
}
send -- "/quit\r"
expect {
  eof {}
  timeout { exit 126 }
}
set wait_result [wait]
exit [lindex \$wait_result 3]
EOF
  (cd "$project" && expect "$expect_script" >/dev/null) || status=$?
  [ "$status" -eq 0 ] || {
    tr -d '\r' < "$capture_log" >&2 || true
    fail "$harness live Pi process failed with status $status"
  }
  pane=$(tr -d '\r' < "$capture_log")
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
  grep -Fvx -- '--json' "$calls" >/dev/null \
    && fail "$harness used unexpected quota-axi argv: $(tr '\n' '|' < "$calls")"
  grep -Fvx -- eof "$stdin_log" >/dev/null \
    && fail "$harness left quota-axi stdin readable: $(tr '\n' '|' < "$stdin_log")"

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
