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

  printf '2147483\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 2147483 ] || fail "Pi's maximum integer timeout should be accepted, got '$out'"

  printf '2147484\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "timeout above Pi's maximum should fall back to 900, got '$out'"

  printf '999999999999999999999999999999999999999\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "oversized timeout should safely fall back to 900, got '$out'"

  printf '0\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ -z "$out" ] || fail "config/pi-bash-timeout=0 should disable injection, got '$out'"

  printf 'not-a-timeout\n' > "$home/config/pi-bash-timeout"
  out=$(resolve_for_home "$home")
  [ "$out" = 900 ] || fail "invalid Pi timeout config should safely fall back to 900, got '$out'"

  printf '1200\n' > "$home/config/pi-bash-timeout"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=NoNe "$RESOLVER")
  [ -z "$out" ] || fail "FM_PI_BASH_TIMEOUT_SECS=NoNe should override and disable file config, got '$out'"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_PI_BASH_TIMEOUT_SECS=OFF "$RESOLVER")
  [ -z "$out" ] || fail "FM_PI_BASH_TIMEOUT_SECS=OFF should override and disable file config, got '$out'"
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
  assert_not_contains "$content" 'pi.registerTool' "generated Pi extension replaces the active bash tool"
  assert_not_contains "$content" 'createBashToolDefinition' "generated Pi extension creates a replacement bash tool"
  assert_contains "$content" 'fm-pi-bash-timeout.sh' "generated Pi extension does not use the shared timeout resolver"
  assert_contains "$content" 'applyDefaultBashTimeout(event.input)' "generated Pi extension does not default validated bash calls"
  assert_contains "$content" 'pi.on("turn_end"' "generated Pi extension lost its turn-end signal"

  out=$(env -u FM_PI_BASH_TIMEOUT_SECS PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerTool() { throw new Error("generated extension replaced bash"); },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const toolCall = handlers.get("tool_call");
if (!toolCall) throw new Error("generated extension did not register tool_call");
const config = `${process.env.FM_HOME}/config/pi-bash-timeout`;

async function call(input) {
  await toolCall({ type: "tool_call", toolName: "bash", input });
  return input;
}

let input = await call({ command: "printf default" });
if (input.timeout !== 900) throw new Error(`default timeout was ${input.timeout}`);

input = await call({ command: "printf post-validation-zero", timeout: 0 });
if (input.timeout !== 900) throw new Error(`post-validation zero timeout was ${input.timeout}`);

input = await call({ command: "printf null", timeout: null });
if (input.timeout !== 900) throw new Error(`null timeout was ${input.timeout}`);

input = await call({ command: "printf negative", timeout: -1 });
if (input.timeout !== 900) throw new Error(`negative timeout was ${input.timeout}`);

input = await call({ command: "printf nan", timeout: Number.NaN });
if (input.timeout !== 900) throw new Error(`NaN timeout was ${input.timeout}`);

input = await call({ command: "printf infinity", timeout: Number.POSITIVE_INFINITY });
if (input.timeout !== 900) throw new Error(`infinite timeout was ${input.timeout}`);

input = await call({ command: "printf explicit-valid", timeout: 987654 });
if (input.timeout !== 987654) throw new Error(`explicit valid timeout was replaced with ${input.timeout}`);

input = await call({ command: "printf explicit-max", timeout: 2_147_483 });
if (input.timeout !== 2_147_483) throw new Error(`explicit maximum timeout was replaced with ${input.timeout}`);

writeFileSync(config, "0\n");
input = await call({ command: "printf disabled" });
if (Object.hasOwn(input, "timeout")) throw new Error(`disabled config injected ${input.timeout}`);

writeFileSync(config, "invalid\n");
input = await call({ command: "printf invalid", timeout: undefined });
if (input.timeout !== 900) throw new Error(`invalid config resolved to ${input.timeout}`);
EOF
)
  status=$?
  expect_code 0 "$status" "generated Pi crewmate extension timeout behavior"
  [ -z "$out" ] || fail "generated Pi crewmate extension test printed output: $out"
  pass "generated Pi extension defaults validated calls without replacing bash"
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
  local repo home ext content out status
  repo="$TMP_ROOT/primary/repo"
  home="$TMP_ROOT/primary/home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  make_primary_fixture "$repo" "$home"
  content=$(cat "$ext")
  assert_not_contains "$content" 'pi.registerTool' "primary Pi extension replaces the active bash tool"
  assert_not_contains "$content" 'createBashToolDefinition' "primary Pi extension creates a replacement bash tool"

  out=$(env -u FM_PI_BASH_TIMEOUT_SECS PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { chmodSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerTool() { throw new Error("primary extension replaced bash"); },
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

input = { command: "printf post-validation-zero", timeout: 0 };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 900) throw new Error(`post-validation zero timeout was ${input.timeout}`);

input = { command: "printf nan", timeout: Number.NaN };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 900) throw new Error(`NaN timeout was ${input.timeout}`);

input = { command: "printf explicit", timeout: 2_147_483 };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (input.timeout !== 2_147_483) throw new Error(`explicit timeout was replaced with ${input.timeout}`);

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
input = { command: "cd /tmp", timeout: 0 };
result = await toolCall({ type: "tool_call", toolName: "bash", input });
if (!result?.block) throw new Error("existing cd seatbelt no longer blocked");
if (input.timeout !== 900) throw new Error(`blocked call did not retain injected default: ${input.timeout}`);

const resolver = new URL("../../bin/fm-pi-bash-timeout.sh", import.meta.resolve(process.env.PLUGIN));
unlinkSync(resolver);
input = { command: "printf missing-resolver" };
await toolCall({ type: "tool_call", toolName: "bash", input });
if (Object.hasOwn(input, "timeout")) throw new Error(`missing resolver injected ${input.timeout}`);
EOF
)
  status=$?
  expect_code 0 "$status" "tracked primary Pi extension timeout behavior"
  [ -z "$out" ] || fail "tracked primary Pi extension test printed output: $out"
  pass "primary Pi extension defaults validated calls without replacing bash or breaking blocks"
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
