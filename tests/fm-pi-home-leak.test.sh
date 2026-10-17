#!/usr/bin/env bash
# Regression: a persistent second mate's own session must resolve its OWN home
# even when the launcher that restarted it carried a leaked FM_HOME for another
# home.
#
# The recorded failure (data/learnings.md 2026-09-07/2026-09-13): a restored
# pane inherited the launcher server's environment, so FM_HOME named the MAIN
# home while the harness's code root was the secondmate home. The extension
# trusted the inherited override, evaluated the main home's lock as "other", and
# never took the secondmate's helm or armed its watcher - alive but without
# supervision. The fix is the marker-based correction in
# .pi/extensions/lib/fm-home-resolve.ts: a root carrying .fm-secondmate-home is
# always its own home.
#
# This drives the REAL Pi turn-end extension through its own event surface with
# both a leaked FM_HOME and a leaked FM_ROOT_OVERRIDE, and records what the
# spawned session-start chain actually sees. It asserts the extension's own
# marker and the child environment, which is the executable contract, rather
# than re-reading the resolver source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-home-leak)
SM="$TMP_ROOT/sm-secondmate"
MAIN="$TMP_ROOT/leaked-main-home"
LOG="$TMP_ROOT/child-env.log"

# install_secondmate_fixture: a marked secondmate root with the real tracked
# extension, its shared libraries, and a recorder session-start runner that logs
# the environment it was handed.
install_secondmate_fixture() {
  mkdir -p "$SM/.pi/extensions/lib" "$SM/bin" "$SM/state" "$SM/data" "$SM/config"
  mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config"
  printf 'bosun\n' > "$SM/.fm-secondmate-home"
  : > "$SM/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$SM/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$ROOT/.pi/extensions/lib/fm-home-resolve.ts" "$SM/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$SM/bin/"
  chmod +x "$SM/bin/fm-operational-input.sh"
  cat > "$SM/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'CHILD FM_HOME=%s FM_ROOT_OVERRIDE=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_LEAK_LOG:?}"
printf 'BOSUN DIGEST\n'
SH
  chmod +x "$SM/bin/fm-sessionstart-run.sh"
  touch "$SM/state/.last-watcher-beat"
}

# run_extension: fires one native session start under the leaked launcher
# environment and prints nothing on success. The extension resolves its own
# root from its file location, exactly as a restored pane does.
run_extension() {
  EXT="$SM/.pi/extensions/fm-primary-turnend-guard.ts" \
    FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$MAIN" FM_LEAK_LOG="$LOG" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?leak=${Date.now()}`);
extension.default(pi);
const ctx = {
  sessionManager: {
    getEntries: () => [],
    getHeader: () => ({ timestamp: new Date().toISOString() }),
    getSessionId: () => "restored-session",
  },
};
handlers.get("session_start")({ reason: "resume" }, ctx);
const result = await handlers.get("before_agent_start")({ prompt: "resume" }, ctx);
if (!result?.message?.content?.includes("BOSUN DIGEST")) {
  throw new Error(`restored session did not deliver its own digest: ${JSON.stringify(result)}`);
}
JS
}

command -v node >/dev/null 2>&1 || {
  echo "skip: node not found for the Pi home-leak regression"
  exit 0
}

install_secondmate_fixture
: > "$LOG"

out=$(run_extension) || {
  printf 'not ok - restored secondmate extension failed: %s\n' "$out" >&2
  exit 1
}

assert_present "$SM/state/.pi-turnend-extension-loaded" \
  "the extension did not mark itself loaded in the secondmate's own home"
assert_absent "$MAIN/state/.pi-turnend-extension-loaded" \
  "the extension marked itself loaded in the leaked main home"
assert_contains "$(cat "$LOG")" "CHILD FM_HOME=$SM FM_ROOT_OVERRIDE=$SM" \
  "the session-start chain inherited the leaked launcher environment instead of the secondmate home"

pass "Pi restored second mate resolves its own home despite a leaked launcher FM_HOME/FM_ROOT_OVERRIDE"

echo "# all fm-pi-home-leak tests passed"
