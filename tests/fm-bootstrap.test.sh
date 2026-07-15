#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh tool detection.
#
# Bootstrap prints one block or line per problem or capability fact and is silent when all
# is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', and 'TASKS_AXI: available' lines, so those
# contracts are pinned verbatim. The cases are table-driven over the inputs that
# vary: whether `treehouse get --help` advertises --lease, which (if any)
# tasks-axi version is on PATH, whether the local backend config opts out, and
# which no-mistakes version is on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)
export FM_BROWSER_HOOK_HOME_OVERRIDE="$TMP_ROOT/browser-hook-home"
mkdir -p "$FM_BROWSER_HOOK_HOME_OVERRIDE"

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi lavish-axi
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_CHROME_DEVTOOLS_AXI_VERSION:-0.1.26}"
fi
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

add_fake_codex() {
  local fakebin=$1
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = app-server ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: codex app-server --listen <url>'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/codex"
}

add_fake_codex_without_app_server() {
  local fakebin=$1
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = app-server ]; then
  printf '%s\n' 'error: unrecognized subcommand app-server' >&2
  exit 2
fi
exit 0
SH
  chmod +x "$fakebin/codex"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch profile validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<backend or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks backend mode expect notcontains case_dir fakebin out n
  n=0
  while IFS='^' read -r label lease tasks backend mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    if [ "$backend" != "-" ]; then
      mkdir -p "$case_dir/home/config"
      printf '%s\n' "$backend" > "$case_dir/home/config/backlog-backend"
    fi
    fakebin=$(make_fake_toolchain "$case_dir")
    [ "$tasks" = "-" ] || add_tasks_axi "$fakebin" "$tasks"
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^-^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is reported available by default^1^0.1.1^-^exact^TASKS_AXI: available^
missing tasks-axi is suggested by default^1^-^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is suggested by default^1^0.1.0^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses missing tasks-axi^1^-^manual^empty^^
manual backlog backend suppresses tasks-axi availability^1^0.1.1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi default/backend contracts"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_tasks_axi "$fakebin" "0.1.1"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_axi_isolation_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: chrome-devtools-axi (install: npm install -g chrome-devtools-axi)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/axi-version-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_CHROME_DEVTOOLS_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum isolated-session AXI version is accepted^0.1.26^empty
newer isolated-session AXI version is accepted^0.2.0^empty
older AXI is unavailable for isolated fallback^0.1.25^missing
unparseable AXI version is unavailable for isolated fallback^development build^missing
ROWS
  pass "bootstrap requires AXI isolated-session support"
}

test_axi_install_commands_keep_browser_fallback_hook_free() {
  local label tool expect case_dir fakebin out n
  n=0
  while IFS='^' read -r label tool expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/axi-install-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    rm -f "$fakebin/$tool"

    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    [ "$out" = "MISSING: $tool (install: $expect)" ] || \
      fail "$label: expected hook policy in install output, got: $out"
  done <<'ROWS'
Chrome AXI installs without ambient session hooks^chrome-devtools-axi^npm install -g chrome-devtools-axi
GitHub AXI retains session hook setup^gh-axi^npm install -g gh-axi && gh-axi setup hooks
Lavish AXI retains session hook setup^lavish-axi^npm install -g lavish-axi && lavish-axi setup hooks
ROWS
  pass "bootstrap gives browser AXI a hook-free install command while retaining other AXI hooks"
}

test_legacy_browser_hooks_are_detected_and_retired_selectively() {
  local case_dir fakebin out hook_home claude codex plugin config
  case_dir="$TMP_ROOT/legacy-browser-hooks"
  hook_home="$case_dir/browser-home"
  claude="$hook_home/.claude/settings.json"
  codex="$hook_home/.codex/hooks.json"
  plugin="$hook_home/.config/opencode/plugins/axi-chrome-devtools-axi.js"
  config="$hook_home/.codex/config.toml"
  mkdir -p "$case_dir/home/config" "$(dirname "$claude")" "$(dirname "$codex")" "$(dirname "$plugin")"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  cat > "$claude" <<'JSON'
{
  "permissions": {"allow": ["Bash"]},
  "hooks": {
    "session_start": [
      {"type": "command", "command": "/opt/bin/chrome-devtools-axi", "timeout": 10},
      {"type": "command", "command": "keep-legacy-hook", "timeout": 3}
    ],
    "SessionStart": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "chrome-devtools-axi", "timeout": 10},
        {"type": "command", "command": "keep-group-hook", "timeout": 5}
      ]},
      {"matcher": "keep-empty-group", "hooks": []}
    ],
    "Stop": [{"hooks": [{"type": "command", "command": "keep-stop-hook"}]}]
  }
}
JSON
  cat > "$codex" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/chrome-devtools-axi", "timeout": 10}]},
      {"matcher": "other", "hooks": [{"type": "command", "command": "keep-codex-hook", "timeout": 7}]}
    ]
  },
  "keep": true
}
JSON
  printf '%s\n' '// axi-sdk-js managed opencode plugin: chrome-devtools-axi' 'keep plugin body' > "$plugin"
  printf '%s\n' '[features]' 'hooks = true' 'other = true' > "$config"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BROWSER_HOOK_HOME_OVERRIDE="$hook_home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "BROWSER_HOOKS: chrome-devtools-axi ambient hooks detected; after captain approval run: bin/fm-bootstrap.sh migrate-browser-hooks" ] || \
    fail "legacy browser hooks should produce a consent-gated migration diagnostic, got: $out"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BROWSER_HOOK_HOME_OVERRIDE="$hook_home" "$ROOT/bin/fm-bootstrap.sh" migrate-browser-hooks)
  [ "$out" = "BROWSER_HOOKS: chrome-devtools-axi ambient hooks retired" ] || \
    fail "browser-hook migration output mismatch: $out"
  ! grep -Fq 'chrome-devtools-axi' "$claude" || fail "Claude managed browser hooks were not removed"
  ! grep -Fq 'chrome-devtools-axi' "$codex" || fail "Codex managed browser hooks were not removed"
  assert_absent "$plugin" "managed OpenCode browser plugin was not removed"
  jq -e '.permissions.allow == ["Bash"] and .hooks.session_start[0].command == "keep-legacy-hook" and .hooks.SessionStart[0].hooks[0].command == "keep-group-hook" and .hooks.SessionStart[1].matcher == "keep-empty-group" and .hooks.Stop[0].hooks[0].command == "keep-stop-hook"' "$claude" >/dev/null || \
    fail "Claude migration did not preserve unrelated settings and hooks"
  jq -e '.keep == true and (.hooks.SessionStart | length) == 1 and .hooks.SessionStart[0].hooks[0].command == "keep-codex-hook"' "$codex" >/dev/null || \
    fail "Codex migration did not preserve unrelated settings and hooks"
  [ "$(cat "$config")" = $'[features]\nhooks = true\nother = true' ] || \
    fail "migration changed shared Codex hooks support"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BROWSER_HOOK_HOME_OVERRIDE="$hook_home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "bootstrap should be silent after managed browser hooks are retired, got: $out"
  pass "bootstrap detects and selectively retires legacy browser hooks after consent"
}

test_unmanaged_opencode_plugin_is_preserved() {
  local case_dir hook_home plugin fakebin out
  case_dir="$TMP_ROOT/unmanaged-browser-plugin"
  hook_home="$case_dir/browser-home"
  plugin="$hook_home/.config/opencode/plugins/axi-chrome-devtools-axi.js"
  mkdir -p "$case_dir/home/config" "$(dirname "$plugin")"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '// user-owned plugin with a colliding filename' > "$plugin"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BROWSER_HOOK_HOME_OVERRIDE="$hook_home" "$ROOT/bin/fm-bootstrap.sh" migrate-browser-hooks)
  [ "$out" = "BROWSER_HOOKS: chrome-devtools-axi ambient hooks retired" ] || \
    fail "no-op browser-hook migration output mismatch: $out"
  assert_present "$plugin" "migration removed an unmanaged OpenCode plugin"
  pass "browser-hook migration preserves an unmanaged colliding OpenCode plugin"
}

test_legacy_browser_hook_symlinks_are_preserved() {
  local case_dir hook_home claude codex claude_target codex_target fakebin out
  case_dir="$TMP_ROOT/legacy-browser-hook-symlinks"
  hook_home="$case_dir/browser-home"
  claude="$hook_home/.claude/settings.json"
  codex="$hook_home/.codex/hooks.json"
  claude_target="$hook_home/dotfiles/claude-settings.json"
  codex_target="$hook_home/dotfiles/codex-hooks.json"
  mkdir -p "$case_dir/home/config" "$(dirname "$claude")" "$(dirname "$codex")" "$(dirname "$claude_target")"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"chrome-devtools-axi"},{"type":"command","command":"keep-claude-hook"}]}]}}' > "$claude_target"
  printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"chrome-devtools-axi"},{"type":"command","command":"keep-codex-hook"}]}]}}' > "$codex_target"
  ln -s ../dotfiles/claude-settings.json "$claude"
  ln -s ../dotfiles/codex-hooks.json "$codex"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BROWSER_HOOK_HOME_OVERRIDE="$hook_home" "$ROOT/bin/fm-bootstrap.sh" migrate-browser-hooks)
  [ "$out" = "BROWSER_HOOKS: chrome-devtools-axi ambient hooks retired" ] || \
    fail "symlinked browser-hook migration output mismatch: $out"
  [ -L "$claude" ] || fail "Claude config symlink was replaced"
  [ -L "$codex" ] || fail "Codex config symlink was replaced"
  [ "$(readlink "$claude")" = ../dotfiles/claude-settings.json ] || fail "Claude config symlink target changed"
  [ "$(readlink "$codex")" = ../dotfiles/codex-hooks.json ] || fail "Codex config symlink target changed"
  ! grep -Fq chrome-devtools-axi "$claude_target" || fail "Claude symlink target retained managed browser hook"
  ! grep -Fq chrome-devtools-axi "$codex_target" || fail "Codex symlink target retained managed browser hook"
  jq -e '.hooks.SessionStart[0].hooks[0].command == "keep-claude-hook"' "$claude_target" >/dev/null || \
    fail "Claude symlink target did not preserve its unrelated hook"
  jq -e '.hooks.SessionStart[0].hooks[0].command == "keep-codex-hook"' "$codex_target" >/dev/null || \
    fail "Codex symlink target did not preserve its unrelated hook"
  pass "browser-hook migration updates symlink targets without replacing links"
}

test_orca_backend_gates_orca_tool_only_when_selected() {
  local case_dir fakebin out missing_orca
  missing_orca="MISSING: orca (install: brew install orca  # or the platform's package manager)"

  case_dir="$TMP_ROOT/orca-backend-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_orca" ] || fail "backend=orca should require only the Orca-specific missing tool, got: $out"

  case_dir="$TMP_ROOT/orca-backend-not-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: orca" "bootstrap should not require orca unless backend=orca is selected"

  case_dir="$TMP_ROOT/orca-backend-selected-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  fm_fake_exit0 "$fakebin" orca
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=0 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "backend=orca should ignore an old treehouse when treehouse is not required, got: $out"
  pass "bootstrap: backend=orca gates the Orca CLI without requiring it on the default backend"
}

test_codex_app_backend_gates_codex_cli_only_when_selected() {
  local case_dir fakebin out missing_codex missing_app_server
  missing_codex="MISSING: codex (install: brew install codex  # or install the Codex CLI from OpenAI)"
  missing_app_server="MISSING: codex app-server (install: brew install codex  # or install the Codex CLI from OpenAI)"

  case_dir="$TMP_ROOT/codex-app-backend-missing-cli"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' codex-app > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_codex" ] || fail "backend=codex-app should require the Codex CLI, got: $out"

  case_dir="$TMP_ROOT/codex-app-backend-missing-app-server"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' codex-app > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_codex_without_app_server "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_app_server" ] || fail "backend=codex-app should require Codex app-server support, got: $out"

  case_dir="$TMP_ROOT/codex-app-env-backend-missing-app-server"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_codex_without_app_server "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" FM_BACKEND=codex-app FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_app_server" ] || fail "FM_BACKEND=codex-app should require Codex app-server support, got: $out"

  case_dir="$TMP_ROOT/codex-app-backend-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' codex-app > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_codex "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=0 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "backend=codex-app should ignore an old treehouse when treehouse is not required, got: $out"

  case_dir="$TMP_ROOT/codex-app-backend-selected-no-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' codex-app > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_codex "$fakebin"
  rm -f "$fakebin/tmux" "$fakebin/treehouse"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "backend=codex-app with Codex CLI present should not require tmux/treehouse, got: $out"
  pass "bootstrap: backend=codex-app gates the Codex CLI without requiring tmux or treehouse"
}

test_crew_dispatch_active_rules_are_surfaced() {
  local case_dir fakebin out expect
  case_dir="$TMP_ROOT/dispatch-active"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":{"harness":"codex","model":"gpt-5.5","effort":"high"}}],"default":{"harness":"claude","model":"haiku","effort":"low"}}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'CREW_DISPATCH: active config/crew-dispatch.json\n  rule: fresh news -> grok\n  rule: big feature -> codex/gpt-5.5/high\n  default: claude/haiku/low'
  [ "$out" = "$expect" ] || fail "active dispatch profile block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules and default"
}

test_crew_dispatch_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/dispatch-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
    esac
  done <<'ROWS'
malformed dispatch config is flagged^{"rules":[^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON
unverified dispatch harness is flagged^{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"codex"}}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship
unsupported codex max effort is flagged^{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
unsupported grok max effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:max
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_axi_isolation_min_version
test_axi_install_commands_keep_browser_fallback_hook_free
test_legacy_browser_hooks_are_detected_and_retired_selectively
test_unmanaged_opencode_plugin_is_preserved
test_legacy_browser_hook_symlinks_are_preserved
test_orca_backend_gates_orca_tool_only_when_selected
test_codex_app_backend_gates_codex_cli_only_when_selected
test_crew_dispatch_active_rules_are_surfaced
test_crew_dispatch_validation
