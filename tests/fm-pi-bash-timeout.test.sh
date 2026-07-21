#!/usr/bin/env bash
# Behavior coverage for Firstmate's default Pi bash timeout resolver and both
# Pi extension surfaces: the tracked primary/secondmate extension and the
# per-crewmate extension generated outside its worktree by fm-spawn.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-pi-bash-timeout.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PRIMARY_EXTENSION="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
TMP_ROOT=$(fm_test_tmproot fm-pi-bash-timeout)

resolve_for_home() {
  local home=$1
  env -u FM_PI_BASH_TIMEOUT_SECS FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$RESOLVER"
}

test_resolver_precedence_disable_and_invalid_fallback() {
  local home out
  home="$TMP_ROOT/resolver-home"
  mkdir -p "$home/config"

  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "missing Pi timeout config should resolve to 900, got '$out'"

  printf '1200\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 1200 ] || fail "Pi timeout config should resolve to 1200, got '$out'"

  printf '0\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ -z "$out" ] || fail "config/pi-bash-timeout=0 should disable injection, got '$out'"

  printf 'not-a-timeout\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "invalid Pi timeout config should safely fall back to 900, got '$out'"

  printf '1200\n' > "$home/config/pi-bash-timeout"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=none "$RESOLVER")
  [ -z "$out" ] || fail "FM_PI_BASH_TIMEOUT_SECS=none should override and disable file config, got '$out'"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=2400 "$RESOLVER")
  [ "$out" = 2400 ] || fail "FM_PI_BASH_TIMEOUT_SECS should override file config, got '$out'"

  pass "Pi bash timeout resolver: default, file, env precedence, disable, and invalid fallback"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

generate_crew_extension() {
  local case_dir=$1 id=$2 home proj wt fakebin out status
  case_dir="$case_dir/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '{"type":"module"}\n' > "$home/package.json"
  printf 'pi\n' > "$home/config/crew-harness"
  printf 'Pi timeout test brief.\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" pi-timeout-worktree

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" 2>&1)
  status=$?
  expect_code 0 "$status" "Pi crewmate spawn should generate its extension"
  assert_contains "$out" "spawned $id harness=pi" "Pi crewmate spawn did not report success"
  printf '%s|%s|%s\n' "$home" "$wt" "$home/state/$id.pi-ext.ts"
}

test_generated_crew_extension_injects_timeout() {
  local rec home wt ext content out status id
  id=pi-timeout-crew-z1
  rec=$(generate_crew_extension "$TMP_ROOT/crew" "$id")
  IFS='|' read -r home wt ext <<EOF
$rec
EOF
  [ -f "$ext" ] || fail "Pi crewmate extension was not generated in state/"
  case "$ext" in
    "$wt"/*) fail "Pi crewmate extension was generated inside its worktree" ;;
  esac

  content=$(cat "$ext")
  assert_contains "$content" 'pi.on("tool_call"' "generated Pi extension does not handle bash tool calls"
  assert_contains "$content" 'fm-pi-bash-timeout.sh' "generated Pi extension does not use the shared timeout resolver"
  assert_contains "$content" 'input.timeout !== undefined && input.timeout !== null' "generated Pi extension does not preserve explicit timeouts"
  assert_contains "$content" 'input.timeout = timeout' "generated Pi extension does not inject a resolved timeout"
  assert_contains "$content" 'pi.on("turn_end"' "generated Pi extension lost its turn-end signal"

  out=$(env -u FM_PI_BASH_TIMEOUT_SECS PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const toolCall = handlers.get("tool_call");
if (!toolCall) throw new Error("generated extension did not register tool_call");
const config = `${process.env.FM_HOME}/config/pi-bash-timeout`;

let input = { command: "printf default" };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 900) throw new Error(`default timeout was ${input.timeout}`);

input = { command: "printf explicit", timeout: 987654 };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 987654) throw new Error(`explicit timeout was replaced with ${input.timeout}`);

writeFileSync(config, "0\n");
input = { command: "printf disabled" };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (Object.hasOwn(input, "timeout")) throw new Error(`disabled config injected ${input.timeout}`);

writeFileSync(config, "invalid\n");
input = { command: "printf invalid" };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 900) throw new Error(`invalid config resolved to ${input.timeout}`);
EOF
)
  status=$?
  expect_code 0 "$status" "generated Pi crewmate extension timeout behavior"
  [ -z "$out" ] || fail "generated Pi crewmate extension test printed output: $out"
  pass "generated Pi crewmate extension injects defaults, preserves explicit values, and honors config"
}

make_primary_fixture() {
  local repo=$1 home=$2
  mkdir -p "$repo/.pi/extensions" "$repo/bin" "$home/config" "$home/state"
  printf '{"type":"module"}\n' > "$repo/package.json"
  cp "$PRIMARY_EXTENSION" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$RESOLVER" "$repo/bin/fm-pi-bash-timeout.sh"
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/"*.sh
}

test_primary_extension_injects_without_breaking_blocks() {
  local repo home ext out status
  repo="$TMP_ROOT/primary/repo"
  home="$TMP_ROOT/primary/home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_primary_fixture "$repo" "$home"

  out=$(env -u FM_PI_BASH_TIMEOUT_SECS PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { chmodSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const toolCall = handlers.get("tool_call");
if (!toolCall) throw new Error("primary extension did not register tool_call");
const config = `${process.env.FM_HOME}/config/pi-bash-timeout`;

let input = { command: "printf default" };
let result = await toolCall({ type: "tool_call", toolName: "bash", input });
if (result?.block) throw new Error("ordinary bash call was blocked");
if (input.timeout !== 900) throw new Error(`default timeout was ${input.timeout}`);

input = { command: "printf explicit", timeout: 1234567 };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 1234567) throw new Error(`explicit timeout was replaced with ${input.timeout}`);

writeFileSync(config, "0\n");
input = { command: "printf disabled" };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (Object.hasOwn(input, "timeout")) throw new Error(`disabled config injected ${input.timeout}`);

writeFileSync(config, "bad-value\n");
input = { command: "printf invalid" };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 900) throw new Error(`invalid config resolved to ${input.timeout}`);

const cdCheck = new URL("../../bin/fm-cd-pretool-check.sh", import.meta.resolve(process.env.PLUGIN));
writeFileSync(cdCheck, "#!/usr/bin/env bash\nprintf 'blocked for test\\n' >&2\nexit 2\n");
chmodSync(cdCheck, 0o755);
input = { command: "cd /tmp" };
result = await toolCall({ type: "tool_call", toolName: "bash", input });
if (!result?.block) throw new Error("existing cd seatbelt no longer blocked");
if (input.timeout !== 900) throw new Error(`blocked call did not retain injected default: ${input.timeout}`);
EOF
)
  status=$?
  expect_code 0 "$status" "tracked primary Pi extension timeout behavior"
  [ -z "$out" ] || fail "tracked primary Pi extension test printed output: $out"
  pass "primary Pi extension injects defaults without replacing explicit timeouts or breaking blocks"
}

test_gitignore_and_shellcheck() {
  git -C "$ROOT" check-ignore -q config/pi-bash-timeout \
    || fail "config/pi-bash-timeout is not gitignored"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$RESOLVER" >/dev/null 2>&1 || fail "fm-pi-bash-timeout.sh is not shellcheck-clean"
  fi
  pass "Pi timeout config is local and the resolver is shellcheck-clean"
}

test_resolver_precedence_disable_and_invalid_fallback
test_generated_crew_extension_injects_timeout
test_primary_extension_injects_without_breaking_blocks
test_gitignore_and_shellcheck

echo "# all fm-pi-bash-timeout tests passed"
