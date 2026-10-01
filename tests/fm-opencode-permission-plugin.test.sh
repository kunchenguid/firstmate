#!/usr/bin/env bash
# Behavior test for the OpenCode permission bridge plugin that bin/fm-spawn.sh
# generates into a worker's worktree.
#
# It runs the REAL fm-spawn against a fake tmux pane and an isolated worktree,
# then loads the generated plugin in a plain Node host and feeds it a real
# permission.asked event, so the generated artifact, the real
# bin/fm-opencode-permission.sh, and the durable record are exercised together
# with no live OpenCode server and no Discord send.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-permission-plugin)

test_plugin_records_a_permission_ask_and_grants_nothing() {
  local rec id=oc-perm-plugin-1 out plugin call_log
  rec=$(make_spawn_case oc-permission opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  plugin="$WT_DIR/.opencode/plugins/fm-opencode-permission.js"
  assert_present "$plugin" "opencode spawn did not write the permission plugin"

  # The bridge calls the owning script; point that at a recorder so this test
  # asserts what the plugin DELIVERED without granting or contacting anything.
  call_log="$TMP_ROOT/oc-permission/calls.log"
  : > "$call_log"
  cat > "$TMP_ROOT/oc-permission/bridge.sh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$call_log"
SH
  chmod +x "$TMP_ROOT/oc-permission/bridge.sh"

  # The generated plugin embeds the absolute path of the real script, so drive
  # it with that script shadowed by the recorder through a path-preserving copy.
  local shadow="$TMP_ROOT/oc-permission/shadow"
  mkdir -p "$shadow"
  sed "s|$ROOT/bin/fm-opencode-permission.sh|$TMP_ROOT/oc-permission/bridge.sh|" \
    "$plugin" > "$shadow/fm-opencode-permission.js"

  out=$(drive_oc_permission_plugin "$shadow/fm-opencode-permission.js" \
    '{"type":"permission.asked","data":{"id":"per_plugintest00001","sessionID":"ses_plugintest001","action":"external_directory","resources":["/tmp/x/*"],"save":["/tmp/x/*"]}}' \
    '{"type":"permission.asked","data":{"sessionID":"ses_plugintest001"}}' \
    '{"type":"session.idle","data":{"sessionID":"ses_plugintest001"}}') \
    || fail "driving the permission plugin failed: $out"

  # Exactly the permission.asked event with a complete identity is delivered,
  # with this task's id and the event's own session and request. The event
  # missing an id and the unrelated event type are both dropped.
  assert_equals "ask $id ses_plugintest001 per_plugintest00001" \
    "$(cat "$call_log")" "the plugin forwards only the complete permission.asked identity"
  pass "the generated plugin forwards a real permission.asked identity to the owning script and nothing else"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# drive_oc_permission_plugin <plugin> <event-json>...: load a generated plugin
# in a plain Node host, feed it the queued events, and wait for the stream to
# drain so an execFile the plugin awaits has actually run. The same seam
# tests/fm-busy-adapter-wiring.test.sh uses for the busy-state plugin.
drive_oc_permission_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
if (!mod.default || typeof mod.default.setup !== "function") {
  throw new Error("generated plugin is not an OpenCode 2 default export with setup()");
}
const queued = process.argv.slice(2).map((arg) => JSON.parse(arg));
let drained = false;
const ctx = {
  event: {
    subscribe({ signal } = {}) {
      return (async function* () {
        for (const event of queued) {
          if (signal?.aborted) return;
          yield event;
        }
        drained = true;
      })();
    },
  },
};
const cleanup = await mod.default.setup(ctx);
const deadline = Date.now() + 5000;
while (!drained && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!drained) throw new Error("plugin never drained the event stream");
await new Promise((resolve) => setTimeout(resolve, 500));
cleanup?.();
EOF
}

test_plugin_records_a_permission_ask_and_grants_nothing
echo "all fm-opencode-permission-plugin tests passed"
