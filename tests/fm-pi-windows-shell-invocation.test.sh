#!/usr/bin/env bash
# Native-Windows Pi extension regression for invoking tracked Bash owners through bash.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-windows-shell-invocation)

if [ "$(node -p 'process.platform')" != win32 ]; then
  echo "skip: native Windows Node required"
  exit 0
fi

project="$TMP_ROOT/project"
mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$project/state"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$project/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
  "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$project/.pi/extensions/lib/"

cat >"$project/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'sessionstart:%s\n' "$*" >> "$FM_WINDOWS_SHELL_LOG"
SH
cat >"$project/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'cd:%s\n' "$*" >> "$FM_WINDOWS_SHELL_LOG"
SH
cat >"$project/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm:%s\n' "$*" >> "$FM_WINDOWS_SHELL_LOG"
SH
cat >"$project/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'turnend:%s\n' "$*" >> "$FM_WINDOWS_SHELL_LOG"
SH
cat >"$project/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf 'operational:%s\n' "$*" >> "$FM_WINDOWS_SHELL_LOG"
printf 'not-operational\n'
SH
chmod +x "$project/bin/"*.sh

log="$project/state/calls"
out=$(EXT="$project/.pi/extensions/fm-primary-turnend-guard.ts" \
  FM_HOME="$project" FM_ROOT_OVERRIDE="$project" FM_WINDOWS_SHELL_LOG="$log" \
  FM_OPERATIONAL_INPUT_SCRIPT="$project/bin/fm-operational-input.sh" \
  node --input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?windows=${Date.now()}`);
extension.default(pi);
const ctx = { sessionManager: { getSessionId: () => "windows-test" } };
handlers.get("session_start")({ reason: "startup" }, ctx);
await handlers.get("before_agent_start")({}, ctx);
await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "printf test" } });
await handlers.get("agent_settled")({}, ctx);
const operational = await import(`${new URL("./lib/fm-operational-input.ts", pathToFileURL(process.env.EXT)).href}?windows=${Date.now()}`);
operational.classifyFirstmateOperationalText("probe");
const calls = readFileSync(process.env.FM_WINDOWS_SHELL_LOG, "utf8");
for (const expected of [
  "sessionstart:--source startup --pi-prerequisite",
  "cd:--command printf test",
  "arm:--command printf test",
  "turnend:",
  "operational:classify",
]) {
  if (!calls.includes(expected)) throw new Error(`missing ${expected} in:\n${calls}`);
}
JS
)
status=$?
expect_code 0 "$status" "native-Windows Pi shell seams"
[ -z "$out" ] || fail "native-Windows Pi shell seam test printed output: $out"
pass "Pi session-start, pre-tool, turn-end, and operational-input seams invoke Bash owners on native Windows"
