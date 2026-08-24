#!/usr/bin/env bash
# Portable logic tests for the omp primary supervision extensions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for omp extension logic test"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-omp-primary-extensions)
REPO="$TMP_ROOT/repo"
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$REPO/.omp/extensions" "$REPO/.pi/extensions/lib" "$REPO/bin" "$HOME_ROOT/state" "$HOME_ROOT/config"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$REPO/.omp/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$REPO/.omp/extensions/fm-primary-omp-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$REPO/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/bin/fm-operational-input.sh" "$REPO/bin/fm-operational-input.sh"
chmod +x "$REPO/bin/fm-operational-input.sh"

cat > "$REPO/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'OMP_GUARD_CONTEXT\n' >&2
exit 2
SH
chmod +x "$REPO/bin/fm-turnend-guard.sh"

cat > "$REPO/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$REPO/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REPO/bin/fm-cd-pretool-check.sh" "$REPO/bin/fm-arm-pretool-check.sh"

cat > "$REPO/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$" >> "${FM_ARM_LOG:?}"
trap 'printf "term\n" >> "${FM_ARM_LOG:?}"; exit 0' TERM INT
while :; do sleep 0.02; done
SH
chmod +x "$REPO/bin/fm-watch-arm.sh"

export FM_HOME="$HOME_ROOT" FM_ROOT_OVERRIDE="$REPO" FM_GUARD_LOG="$TMP_ROOT/guard.log" FM_ARM_LOG="$TMP_ROOT/arm.log"
export REPO="$REPO" HOME_ROOT="$HOME_ROOT"
node --input-type=module <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const repo = process.env.REPO;
const home = process.env.HOME_ROOT;
const handlers = new Map();
const guardApi = {
  on(name, handler) { handlers.set(name, handler); },
  sendMessage() { throw new Error("turn-end guard must use native continuation"); },
  sendUserMessage() { throw new Error("turn-end guard must not use sendUserMessage"); },
};
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const guard = await import(pathToFileURL(`${repo}/.omp/extensions/fm-primary-turnend-guard.ts`).href);
guard.default(guardApi);
const guardResult = await handlers.get("session_stop")({ type: "session_stop" }, {});
if (guardResult?.continue !== true) throw new Error(`session_stop did not continue: ${JSON.stringify(guardResult)}`);
if (typeof guardResult.additionalContext !== "string" || !guardResult.additionalContext.includes("FIRSTMATE_OP: v1 turn-end-guard:")) {
  throw new Error(`session_stop returned untyped or missing context: ${JSON.stringify(guardResult)}`);
}

const watchHandlers = new Map();
let watchTool;
const watchApi = {
  typebox: { Type: { Object: () => ({ type: "object" }) } },
  on(name, handler) { watchHandlers.set(name, handler); },
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_omp") watchTool = candidate; },
  sendUserMessage() {},
};
const watch = await import(pathToFileURL(`${repo}/.omp/extensions/fm-primary-omp-watch.ts`).href);
watch.default(watchApi);
if (!watchTool) throw new Error("fm_watch_arm_omp was not registered");
await watchHandlers.get("session_start")({ type: "session_start" }, {});
const first = await watchTool.execute("first", {}, undefined, undefined, {});
if (!first.content[0]?.text.includes("started omp extension arm child")) throw new Error(`first arm did not start: ${first.content[0]?.text}`);
for (let i = 0; i < 100 && (!existsSync(process.env.FM_ARM_LOG) || !readFileSync(process.env.FM_ARM_LOG, "utf8").includes("watcher: started")); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("first arm child did not execute");
await watchHandlers.get("session_shutdown")({ type: "session_shutdown" }, {});
for (let i = 0; i < 100 && !readFileSync(process.env.FM_ARM_LOG, "utf8").includes("term"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const stopped = await watchTool.execute("stopped", {}, undefined, undefined, {});
if (!stopped.content[0]?.text.includes("omp session is shutting down")) throw new Error(`retired generation was not inert: ${stopped.content[0]?.text}`);
await watchHandlers.get("session_start")({ type: "session_start" }, {});
const second = await watchTool.execute("second", {}, undefined, undefined, {});
if (!second.content[0]?.text.includes("started omp extension arm child")) throw new Error(`replacement generation did not re-arm: ${second.content[0]?.text}`);
await watchHandlers.get("session_shutdown")({ type: "session_shutdown" }, {});
EOF

assert_contains "$(cat "$TMP_ROOT/guard.log")" "guard" "guard script did not execute"
assert_contains "$(cat "$TMP_ROOT/arm.log")" "term" "session_shutdown did not retire the arm child"
pass "omp guard continuation and generation activate-retire ordering"
